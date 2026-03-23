// Virtio network device backend.
// Relays ethernet frames between guest virtqueues and a host TAP device.

const std = @import("std");
const linux = std.os.linux;
const Memory = @import("../../memory.zig");
const Queue = @import("queue.zig");
const virtio = @import("../virtio.zig");

const log = std.log.scoped(.virtio_net);

const Self = @This();

// Feature bits
pub const F_MAC: u64 = 1 << 5;
pub const F_STATUS: u64 = 1 << 16;

// Config space layout: mac[6] + status(u16) = 8 bytes
const CONFIG_SIZE: usize = 8;
const STATUS_LINK_UP: u16 = 1;

// virtio_net_hdr_v1 (12 bytes, used with VIRTIO_F_VERSION_1)
const NET_HDR_SIZE: usize = 12;

// TAP device constants
const TUNSETIFF: u32 = 0x400454ca;
const TUNSETVNETHDRSZ: u32 = 0x400454d8;
const IFF_TAP: c_short = 0x0002;
const IFF_NO_PI: c_short = 0x1000;
const IFF_VNET_HDR: c_short = 0x4000;
const IFNAMSIZ = 16;

// Queue indices
pub const RX_QUEUE: u32 = 0;
pub const TX_QUEUE: u32 = 1;
pub const NUM_QUEUES: u32 = 2;

tap_fd: i32,
mac: [6]u8,

pub fn init(tap_name: [*:0]const u8) !Self {
    // Open /dev/net/tun
    const open_rc: isize = @bitCast(linux.open("/dev/net/tun", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    if (open_rc < 0) {
        log.err("failed to open /dev/net/tun", .{});
        return error.OpenFailed;
    }
    const fd: i32 = @intCast(open_rc);
    errdefer _ = linux.close(fd);

    // Create TAP device with IFF_TAP | IFF_NO_PI | IFF_VNET_HDR
    var ifr: [40]u8 = .{0} ** 40; // struct ifreq is 40 bytes (name[16] + union[24])
    const name_len = std.mem.indexOfSentinel(u8, 0, tap_name);
    if (name_len >= IFNAMSIZ) return error.TapNameTooLong;
    @memcpy(ifr[0..name_len], tap_name[0..name_len]);

    // ifr_flags at offset 16 (little-endian i16)
    const flags: i16 = IFF_TAP | IFF_NO_PI | IFF_VNET_HDR;
    std.mem.writeInt(i16, ifr[16..18], flags, .little);

    const ioctl_rc: isize = @bitCast(linux.ioctl(fd, TUNSETIFF, @intFromPtr(&ifr)));
    if (ioctl_rc < 0) {
        log.err("TUNSETIFF failed", .{});
        return error.TunSetiffFailed;
    }

    // Set vnet header size to 12 (virtio_net_hdr_v1)
    var hdr_sz: i32 = NET_HDR_SIZE;
    const hdr_rc: isize = @bitCast(linux.ioctl(fd, TUNSETVNETHDRSZ, @intFromPtr(&hdr_sz)));
    if (hdr_rc < 0) {
        log.err("TUNSETVNETHDRSZ failed", .{});
        return error.TunSetVnetHdrFailed;
    }

    // Set TAP fd to non-blocking for RX polling
    const fl_rc: isize = @bitCast(linux.fcntl(fd, linux.F.GETFL, @as(usize, 0)));
    if (fl_rc < 0) return error.FcntlFailed;
    const new_flags = @as(usize, @bitCast(@as(isize, fl_rc))) | 0o4000; // O_NONBLOCK
    const set_rc: isize = @bitCast(linux.fcntl(fd, linux.F.SETFL, new_flags));
    if (set_rc < 0) return error.FcntlFailed;

    // Generate a locally-administered MAC address from tap name
    var mac: [6]u8 = .{ 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
    for (tap_name[0..name_len], 0..) |c, i| {
        mac[(i % 4) + 2] ^= c;
    }

    log.info("TAP device: {s}, MAC {x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}:{x:0>2}", .{
        tap_name, mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    });

    return .{ .tap_fd = fd, .mac = mac };
}

pub fn deinit(self: Self) void {
    _ = linux.close(self.tap_fd);
}

/// Device features offered to the driver.
pub fn deviceFeatures() u64 {
    return virtio.F_VERSION_1 | F_MAC | F_STATUS;
}

/// Read from device config space.
pub fn readConfig(self: Self, offset: u64, data: []u8) void {
    // Config: mac[6] at offset 0, status(u16) at offset 6
    var config: [CONFIG_SIZE]u8 = undefined;
    @memcpy(config[0..6], &self.mac);
    std.mem.writeInt(u16, config[6..8], STATUS_LINK_UP, .little);

    if (offset + data.len <= CONFIG_SIZE) {
        const start: usize = @intCast(offset);
        @memcpy(data, config[start..][0..data.len]);
    } else {
        @memset(data, 0);
    }
}

/// Process TX queue: read frames from guest, write to TAP.
pub fn processTx(self: Self, mem: *Memory, queue: *Queue) bool {
    var did_work = false;
    var processed: u16 = 0;
    while (processed < queue.size) : (processed += 1) {
        const head = queue.popAvail(mem) catch |err| {
            log.err("TX popAvail failed: {}", .{err});
            break;
        } orelse break;

        self.transmitChain(mem, queue, head) catch |err| {
            log.err("TX failed: {}", .{err});
            queue.pushUsed(mem, head, 0) catch |e| log.warn("TX pushUsed failed: {}", .{e});
        };
        did_work = true;
    }
    return did_work;
}

/// Transmit a single descriptor chain to the TAP device.
fn transmitChain(self: Self, mem: *Memory, queue: *Queue, head: u16) !void {
    // Collect all descriptors upfront (with cycle detection)
    var descs: [16]Queue.Desc = undefined;
    const desc_count = try queue.collectChain(mem, head, &descs);

    // Validate TX descriptors are device-readable (guest provides data to send)
    for (descs[0..desc_count]) |desc| {
        if (desc.flags & virtio.DESC_F_WRITE != 0) {
            log.err("TX descriptor is device-writable (expected readable)", .{});
            try queue.pushUsed(mem, head, 0);
            return;
        }
    }

    // Build iovec from collected descriptors for writev
    var iov: [16]std.posix.iovec = undefined;
    for (descs[0..desc_count], 0..) |desc, i| {
        const buf = try mem.slice(@intCast(desc.addr), desc.len);
        iov[i] = .{ .base = buf.ptr, .len = buf.len };
    }

    if (desc_count > 0) {
        const rc: isize = @bitCast(linux.writev(self.tap_fd, @ptrCast(&iov), @intCast(desc_count)));
        if (rc < 0) {
            log.warn("TAP writev failed", .{});
        }
    }

    try queue.pushUsed(mem, head, 0); // TX: device writes 0 bytes back
}

/// Poll for incoming frames from TAP and deliver to guest RX queue.
/// Non-blocking: returns immediately if no data available.
/// Returns true if any frames were delivered (caller should inject IRQ).
pub fn pollRx(self: Self, mem: *Memory, queue: *Queue) bool {
    if (!queue.isReady()) return false;

    var did_work = false;
    var processed: u16 = 0;
    while (processed < queue.size) : (processed += 1) {
        // Need an available RX buffer from the guest
        const head = queue.popAvail(mem) catch break orelse break;

        const bytes_written = self.receiveFrame(mem, queue, head) catch |err| {
            // EAGAIN/EWOULDBLOCK means no more frames
            if (err == error.WouldBlock) {
                // Already popped descriptor, push back as unused
                queue.pushUsed(mem, head, 0) catch |e| log.warn("RX pushUsed failed: {}", .{e});
                break;
            }
            log.err("RX failed: {}", .{err});
            queue.pushUsed(mem, head, 0) catch |e| log.warn("RX pushUsed failed: {}", .{e});
            break;
        };

        if (bytes_written == 0) {
            queue.pushUsed(mem, head, 0) catch |e| log.warn("RX pushUsed failed: {}", .{e});
            break;
        }

        queue.pushUsed(mem, head, bytes_written) catch |e| log.warn("RX pushUsed failed: {}", .{e});
        did_work = true;
    }
    return did_work;
}

/// Receive a single frame from TAP into the guest RX descriptor chain.
fn receiveFrame(self: Self, mem: *Memory, queue: *Queue, head: u16) !u32 {
    // Collect all descriptors upfront (with cycle detection)
    var descs: [16]Queue.Desc = undefined;
    const desc_count = try queue.collectChain(mem, head, &descs);

    // Validate RX descriptors are device-writable (VMM writes frame data into them)
    for (descs[0..desc_count]) |desc| {
        if (desc.flags & virtio.DESC_F_WRITE == 0) {
            log.err("RX descriptor is not device-writable", .{});
            return 0;
        }
    }

    // Build iovec from collected descriptors for readv
    var iov: [16]std.posix.iovec = undefined;
    for (descs[0..desc_count], 0..) |desc, i| {
        const buf = try mem.slice(@intCast(desc.addr), desc.len);
        iov[i] = .{ .base = buf.ptr, .len = buf.len };
    }

    if (desc_count == 0) return 0;

    const rc: isize = @bitCast(linux.readv(self.tap_fd, @ptrCast(&iov), @intCast(desc_count)));
    if (rc < 0) {
        const errno: linux.E = @enumFromInt(@as(u16, @intCast(-rc)));
        if (errno == .AGAIN) {
            return error.WouldBlock;
        }
        return error.ReadFailed;
    }
    if (rc == 0) return 0;

    return @intCast(rc);
}
