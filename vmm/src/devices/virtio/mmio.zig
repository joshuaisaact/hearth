// Virtio-MMIO transport layer.
// Implements the MMIO register interface (v2/modern) for a single device.
// Supports multiple backend device types via tagged union.

const std = @import("std");
const Memory = @import("../../memory.zig");
const virtio = @import("../virtio.zig");
const Queue = @import("queue.zig");
const Blk = @import("blk.zig");
const Net = @import("net.zig");
const Vsock = @import("vsock.zig");

const log = std.log.scoped(.virtio_mmio);

const Self = @This();

const Backend = union(enum) {
    blk: Blk,
    net: Net,
    vsock: Vsock,
};

// Device identity
device_id: u32,
mmio_base: u64,
irq: u32,

// Device state
status: u8 = 0,
device_features_sel: u32 = 0,
driver_features_sel: u32 = 0,
driver_features: u64 = 0,
queue_sel: u32 = 0,
interrupt_status: u32 = 0,
config_generation: u32 = 0,

// Queues: blk uses 1, net uses 2 (RX + TX), vsock uses 3 (RX + TX + EVT)
queues: [3]Queue = .{ .{}, .{}, .{} },

// Backend
backend: Backend,

pub fn initBlk(mmio_base: u64, irq: u32, disk_path: [*:0]const u8) !Self {
    const blk = try Blk.init(disk_path);
    log.info("virtio-blk at MMIO 0x{x} IRQ {}", .{ mmio_base, irq });
    return .{
        .device_id = virtio.DEVICE_ID_BLOCK,
        .mmio_base = mmio_base,
        .irq = irq,
        .backend = .{ .blk = blk },
    };
}

pub fn initNet(mmio_base: u64, irq: u32, tap_name: [*:0]const u8) !Self {
    const net = try Net.init(tap_name);
    log.info("virtio-net at MMIO 0x{x} IRQ {}", .{ mmio_base, irq });
    return .{
        .device_id = virtio.DEVICE_ID_NET,
        .mmio_base = mmio_base,
        .irq = irq,
        .backend = .{ .net = net },
    };
}

pub fn initVsock(mmio_base: u64, irq: u32, guest_cid: u64, uds_path: [*:0]const u8) !Self {
    const vsock = try Vsock.init(guest_cid, uds_path);
    log.info("virtio-vsock at MMIO 0x{x} IRQ {} CID {}", .{ mmio_base, irq, guest_cid });
    return .{
        .device_id = virtio.DEVICE_ID_VSOCK,
        .mmio_base = mmio_base,
        .irq = irq,
        .backend = .{ .vsock = vsock },
    };
}

pub fn deinit(self: *Self) void {
    switch (self.backend) {
        .blk => |b| b.deinit(),
        .net => |n| n.deinit(),
        .vsock => |*v| v.deinit(),
    }
}

// --- Snapshot support ---
// Transport state is saved/restored as a fixed-size header (25 bytes) plus
// per-queue state. Backend-specific data (disk path, TAP name, etc.) is
// saved so the device can be reopened on restore — but live connections
// (vsock sockets, TAP fd state) are NOT preserved.

// Identity (16) + transport (29) + queues (31*3=93) = 138 bytes before backend data
const IDENTITY_SIZE = 16; // device_id:u32 + mmio_base:u64 + irq:u32
const TRANSPORT_STATE_SIZE = 29; // status:u8 + features_sel:u32 + driver_features_sel:u32 + driver_features:u64 + queue_sel:u32 + interrupt_status:u32 + config_generation:u32

/// Write full device snapshot to buffer. Returns bytes written.
pub fn snapshotSave(self: *const Self, buf: []u8) usize {
    var pos: usize = 0;

    // Device identity
    std.mem.writeInt(u32, buf[pos..][0..4], self.device_id, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], self.mmio_base, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], self.irq, .little);
    pos += 4;

    // Transport state
    buf[pos] = self.status;
    pos += 1;
    std.mem.writeInt(u32, buf[pos..][0..4], self.device_features_sel, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], self.driver_features_sel, .little);
    pos += 4;
    std.mem.writeInt(u64, buf[pos..][0..8], self.driver_features, .little);
    pos += 8;
    std.mem.writeInt(u32, buf[pos..][0..4], self.queue_sel, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], self.interrupt_status, .little);
    pos += 4;
    std.mem.writeInt(u32, buf[pos..][0..4], self.config_generation, .little);
    pos += 4;

    // Queue state (all 3 slots, even if unused — simpler and only 93 bytes)
    for (&self.queues) |*q| {
        const qdata = q.snapshotSave();
        @memcpy(buf[pos..][0..Queue.SNAPSHOT_SIZE], &qdata);
        pos += Queue.SNAPSHOT_SIZE;
    }

    std.debug.assert(pos == IDENTITY_SIZE + TRANSPORT_STATE_SIZE + Queue.SNAPSHOT_SIZE * 3);

    // Backend-specific config
    switch (self.backend) {
        .blk => |b| {
            std.mem.writeInt(u64, buf[pos..][0..8], b.capacity, .little);
            pos += 8;
        },
        .net => |n| {
            @memcpy(buf[pos..][0..6], &n.mac);
            pos += 6;
        },
        .vsock => |v| {
            std.mem.writeInt(u64, buf[pos..][0..8], v.guest_cid, .little);
            pos += 8;
        },
    }

    return pos;
}

/// Restore transport and queue state from buffer. Backend must already be
/// initialized (disk reopened, TAP recreated, etc.) before calling this.
/// Returns bytes consumed.
pub fn snapshotRestore(self: *Self, buf: []const u8) usize {
    var pos: usize = 0;

    // Skip device identity (4+8+4 = 16 bytes) — already set by init*()
    pos += 16;

    // Transport state
    self.status = buf[pos];
    pos += 1;
    self.device_features_sel = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    self.driver_features_sel = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    self.driver_features = std.mem.readInt(u64, buf[pos..][0..8], .little);
    pos += 8;
    self.queue_sel = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    self.interrupt_status = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;
    self.config_generation = std.mem.readInt(u32, buf[pos..][0..4], .little);
    pos += 4;

    // Queue state
    for (&self.queues) |*q| {
        q.snapshotRestore(buf[pos..][0..Queue.SNAPSHOT_SIZE].*);
        pos += Queue.SNAPSHOT_SIZE;
    }

    std.debug.assert(pos == IDENTITY_SIZE + TRANSPORT_STATE_SIZE + Queue.SNAPSHOT_SIZE * 3);

    // Skip backend-specific data (already used during init)
    switch (self.backend) {
        .blk => pos += 8,
        .net => pos += 6,
        .vsock => pos += 8,
    }

    return pos;
}

fn numQueues(self: Self) u32 {
    return switch (self.backend) {
        .blk => 1,
        .net => Net.NUM_QUEUES,
        .vsock => Vsock.NUM_QUEUES,
    };
}

fn deviceFeatures(self: Self) u64 {
    return switch (self.backend) {
        .blk => Blk.deviceFeatures(),
        .net => Net.deviceFeatures(),
        .vsock => Vsock.deviceFeatures(),
    };
}

fn reset(self: *Self) void {
    self.status = 0;
    self.device_features_sel = 0;
    self.driver_features_sel = 0;
    self.driver_features = 0;
    self.queue_sel = 0;
    self.interrupt_status = 0;
    for (&self.queues) |*q| q.reset();
}

fn selectedQueue(self: *Self) ?*Queue {
    if (self.queue_sel < self.numQueues()) return &self.queues[self.queue_sel];
    return null;
}

fn setLow32(target: *u64, val: u32) void {
    target.* = (target.* & 0xFFFFFFFF00000000) | val;
}

fn setHigh32(target: *u64, val: u32) void {
    target.* = (target.* & 0x00000000FFFFFFFF) | (@as(u64, val) << 32);
}

/// Handle an MMIO read. Returns the value to write back to the guest.
pub fn handleRead(self: *Self, offset: u64, data: []u8) void {
    if (offset >= virtio.MMIO_CONFIG) {
        switch (self.backend) {
            .blk => |b| b.readConfig(offset - virtio.MMIO_CONFIG, data),
            .net => |n| n.readConfig(offset - virtio.MMIO_CONFIG, data),
            .vsock => |v| v.readConfig(offset - virtio.MMIO_CONFIG, data),
        }
        return;
    }

    // All standard registers are 32-bit
    if (data.len != 4) {
        @memset(data, 0);
        return;
    }

    const val: u32 = switch (offset) {
        virtio.MMIO_MAGIC_VALUE => virtio.MAGIC_VALUE,
        virtio.MMIO_VERSION => virtio.MMIO_VERSION_2,
        virtio.MMIO_DEVICE_ID => self.device_id,
        virtio.MMIO_VENDOR_ID => virtio.VENDOR_ID,
        virtio.MMIO_DEVICE_FEATURES => val: {
            const features = self.deviceFeatures();
            break :val if (self.device_features_sel == 0)
                @truncate(features)
            else
                @truncate(features >> 32);
        },
        virtio.MMIO_QUEUE_NUM_MAX => val: {
            if (self.selectedQueue()) |_| {
                break :val Queue.MAX_QUEUE_SIZE;
            }
            break :val 0;
        },
        virtio.MMIO_QUEUE_READY => val: {
            if (self.selectedQueue()) |q| {
                break :val @intFromBool(q.ready);
            }
            break :val 0;
        },
        virtio.MMIO_INTERRUPT_STATUS => self.interrupt_status,
        virtio.MMIO_STATUS => self.status,
        virtio.MMIO_CONFIG_GENERATION => self.config_generation,
        else => 0,
    };

    std.mem.writeInt(u32, data[0..4], val, .little);
}

/// Handle an MMIO write from the guest.
pub fn handleWrite(self: *Self, offset: u64, data: []const u8) void {
    if (offset >= virtio.MMIO_CONFIG) {
        return;
    }

    if (data.len != 4) return;

    const val = std.mem.readInt(u32, data[0..4], .little);

    switch (offset) {
        virtio.MMIO_DEVICE_FEATURES_SEL => self.device_features_sel = val,
        virtio.MMIO_DRIVER_FEATURES => {
            // Filter against advertised features — guest cannot enable unsupported features
            const supported = self.deviceFeatures();
            if (self.driver_features_sel == 0) {
                setLow32(&self.driver_features, val & @as(u32, @truncate(supported)));
            } else {
                setHigh32(&self.driver_features, val & @as(u32, @truncate(supported >> 32)));
            }
        },
        virtio.MMIO_DRIVER_FEATURES_SEL => self.driver_features_sel = val,
        virtio.MMIO_QUEUE_SEL => self.queue_sel = val,
        virtio.MMIO_QUEUE_NUM => {
            if (self.selectedQueue()) |q| {
                const size: u16 = @intCast(val & 0xFFFF);
                if (size == 0 or size > Queue.MAX_QUEUE_SIZE or @popCount(size) != 1) {
                    log.warn("rejected invalid queue size: {}", .{size});
                } else {
                    q.size = size;
                }
            }
        },
        virtio.MMIO_QUEUE_READY => {
            if (self.selectedQueue()) |q| {
                q.ready = val == 1;
                if (q.ready) {
                    log.info("queue {} ready (size={})", .{ self.queue_sel, q.size });
                }
            }
        },
        virtio.MMIO_QUEUE_NOTIFY => {
            // Handled by caller (triggers queue processing in run loop)
        },
        virtio.MMIO_INTERRUPT_ACK => {
            self.interrupt_status &= ~val;
        },
        virtio.MMIO_STATUS => {
            if (val == 0) {
                self.reset();
                log.info("device reset", .{});
            } else {
                self.status = @truncate(val);
                if (self.status & virtio.STATUS_FAILED != 0) {
                    log.err("driver set FAILED status", .{});
                }
            }
        },
        virtio.MMIO_QUEUE_DESC_LOW => {
            if (self.selectedQueue()) |q| setLow32(&q.desc_addr, val);
        },
        virtio.MMIO_QUEUE_DESC_HIGH => {
            if (self.selectedQueue()) |q| setHigh32(&q.desc_addr, val);
        },
        virtio.MMIO_QUEUE_DRIVER_LOW => {
            if (self.selectedQueue()) |q| setLow32(&q.avail_addr, val);
        },
        virtio.MMIO_QUEUE_DRIVER_HIGH => {
            if (self.selectedQueue()) |q| setHigh32(&q.avail_addr, val);
        },
        virtio.MMIO_QUEUE_DEVICE_LOW => {
            if (self.selectedQueue()) |q| setLow32(&q.used_addr, val);
        },
        virtio.MMIO_QUEUE_DEVICE_HIGH => {
            if (self.selectedQueue()) |q| setHigh32(&q.used_addr, val);
        },
        else => {},
    }
}

/// Process pending requests on the virtqueue(s).
/// Returns true if any work was done (interrupt should be raised).
pub fn processQueues(self: *Self, mem: *Memory) bool {
    if (self.status & virtio.STATUS_DRIVER_OK == 0) return false;

    var did_work = false;
    switch (self.backend) {
        .blk => |b| {
            if (!self.queues[0].isReady()) return false;
            var processed: u16 = 0;
            while (processed < self.queues[0].size) : (processed += 1) {
                const head = self.queues[0].popAvail(mem) catch |err| {
                    log.err("popAvail failed: {}", .{err});
                    break;
                } orelse break;

                b.processRequest(mem, &self.queues[0], head) catch |err| {
                    log.err("block request failed: {}", .{err});
                    self.queues[0].pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
                };
                did_work = true;
            }
        },
        .net => |n| {
            // Process TX queue (queue 1)
            if (self.queues[Net.TX_QUEUE].isReady()) {
                if (n.processTx(mem, &self.queues[Net.TX_QUEUE])) did_work = true;
            }
        },
        .vsock => |*v| {
            // Process TX queue (queue 1) and deliver pending control packets
            if (self.queues[Vsock.TX_QUEUE].isReady()) {
                if (v.processTx(mem, &self.queues[Vsock.TX_QUEUE])) did_work = true;
            }
            if (self.queues[Vsock.RX_QUEUE].isReady()) {
                if (v.deliverPending(mem, &self.queues[Vsock.RX_QUEUE])) did_work = true;
            }
        },
    }

    if (did_work) {
        self.interrupt_status |= virtio.INT_USED_RING;
    }
    return did_work;
}

/// Poll for incoming RX data (net devices only).
/// Returns true if frames were delivered (caller should inject IRQ).
pub fn pollRx(self: *Self, mem: *Memory) bool {
    if (self.status & virtio.STATUS_DRIVER_OK == 0) return false;
    switch (self.backend) {
        .net => |n| {
            if (!self.queues[Net.RX_QUEUE].isReady()) return false;
            if (n.pollRx(mem, &self.queues[Net.RX_QUEUE])) {
                self.interrupt_status |= virtio.INT_USED_RING;
                return true;
            }
        },
        .vsock => |*v| {
            if (!self.queues[Vsock.RX_QUEUE].isReady()) return false;
            if (v.pollRx(mem, &self.queues[Vsock.RX_QUEUE])) {
                self.interrupt_status |= virtio.INT_USED_RING;
                return true;
            }
        },
        else => {},
    }
    return false;
}

/// Flush pending write buffers (vsock only). No-op for other device types.
pub fn flushPendingWrites(self: *Self) void {
    switch (self.backend) {
        .vsock => |*v| v.flushPendingWrites(),
        else => {},
    }
}

/// Return the pollable fd for this device (TAP fd for net, -1 for others).
/// Used by the run loop to register device fds with epoll instead of
/// blind-polling every device after each KVM exit.
pub fn getPollFd(self: Self) i32 {
    return switch (self.backend) {
        .net => |n| n.tap_fd,
        else => -1,
    };
}

/// Check if address falls within this device's MMIO range.
pub fn matchesAddr(self: Self, addr: u64) bool {
    return addr >= self.mmio_base and addr < self.mmio_base + virtio.MMIO_SIZE;
}
