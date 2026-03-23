// Virtio vsock device backend.
// Provides host↔guest communication via AF_VSOCK over Unix domain sockets.
// Follows Firecracker's model: guest connects to host CID 2, port P,
// and the VMM connects to {uds_path}_{P} on the host side.

const std = @import("std");
const linux = std.os.linux;
const Memory = @import("../../memory.zig");
const Queue = @import("queue.zig");
const virtio = @import("../virtio.zig");

const log = std.log.scoped(.virtio_vsock);

const Self = @This();

// Queue indices
pub const RX_QUEUE: u32 = 0;
pub const TX_QUEUE: u32 = 1;
pub const EVT_QUEUE: u32 = 2;
pub const NUM_QUEUES: u32 = 3;

// Host CID is always 2
const HOST_CID: u64 = 2;

// Vsock header size: 44 bytes (virtio spec v1.2)
const HDR_SIZE: u32 = 44;

// Vsock socket types
const TYPE_STREAM: u16 = 1;

// Vsock operations
const OP_REQUEST: u16 = 1;
const OP_RESPONSE: u16 = 2;
const OP_RST: u16 = 3;
const OP_SHUTDOWN: u16 = 4;
const OP_RW: u16 = 5;
const OP_CREDIT_UPDATE: u16 = 6;
const OP_CREDIT_REQUEST: u16 = 7;

// Shutdown flags
const SHUTDOWN_RCV: u32 = 1;
const SHUTDOWN_SEND: u32 = 2;

// Per-connection receive buffer size
const CONN_BUF_ALLOC: u32 = 262144; // 256KB

// Maximum simultaneous connections
const MAX_CONNECTIONS: usize = 64;

// Maximum UDS path length
const MAX_UDS_PATH: usize = 107; // sun_path max (108) minus null

// Per-connection write buffer for backpressure handling.
// When the host socket returns EAGAIN, unsent data is stashed here
// and flushed on the next poll cycle. Without this, data was silently
// dropped — the guest had no way to know the write failed.
// 256 bytes per connection × 64 connections = 16KB total (fits on stack).
// This only needs to buffer one partial write between poll cycles.
const WRITE_BUF_SIZE: usize = 256;

const Connection = struct {
    state: State = .idle,
    guest_port: u32 = 0,
    host_port: u32 = 0,
    fd: i32 = -1,
    // Flow control: what the guest can receive
    guest_buf_alloc: u32 = 0,
    guest_fwd_cnt: u32 = 0,
    // Flow control: what we've sent to the guest
    tx_cnt: u32 = 0,
    // Flow control: our receive buffer tracking
    rx_cnt: u32 = 0,
    // Write buffer for backpressure (data pending write to host socket)
    write_buf: [WRITE_BUF_SIZE]u8 = undefined,
    write_len: u32 = 0,

    const State = enum { idle, established, closing };

    fn availableForTx(self: Connection) u32 {
        // How many bytes can we send to the guest
        const sent = self.tx_cnt;
        const acked = self.guest_fwd_cnt;
        const window = self.guest_buf_alloc;
        if (window == 0) return 0;
        const in_flight = sent -% acked;
        if (in_flight >= window) return 0;
        return window - in_flight;
    }

    /// Try to flush the write buffer to the host socket.
    /// Returns true if the buffer is now empty.
    fn flushWriteBuffer(self: *Connection) bool {
        if (self.write_len == 0) return true;
        if (self.fd < 0) {
            self.write_len = 0;
            return true;
        }
        while (self.write_len > 0) {
            const rc: isize = @bitCast(linux.write(self.fd, self.write_buf[0..self.write_len].ptr, self.write_len));
            if (rc < 0) {
                const errno: linux.E = @enumFromInt(@as(u16, @intCast(-rc)));
                if (errno == .AGAIN) return false; // still blocked
                // Real error — drop buffer, connection will be cleaned up
                self.write_len = 0;
                return true;
            }
            if (rc == 0) return false;
            const written: u32 = @intCast(rc);
            // Shift remaining data to front of buffer
            if (written < self.write_len) {
                const remaining = self.write_len - written;
                std.mem.copyForwards(u8, self.write_buf[0..remaining], self.write_buf[written..self.write_len]);
                self.write_len = remaining;
            } else {
                self.write_len = 0;
            }
        }
        return true;
    }

    /// Stash data in the write buffer. Returns how many bytes were stashed.
    fn stashWrite(self: *Connection, data: []const u8) u32 {
        const space = WRITE_BUF_SIZE - self.write_len;
        const to_copy = @min(data.len, space);
        if (to_copy == 0) return 0;
        @memcpy(self.write_buf[self.write_len..][0..to_copy], data[0..to_copy]);
        self.write_len += @intCast(to_copy);
        return @intCast(to_copy);
    }
};

guest_cid: u64,
uds_path: [MAX_UDS_PATH + 1]u8,
uds_path_len: usize,
connections: [MAX_CONNECTIONS]Connection = [_]Connection{.{}} ** MAX_CONNECTIONS,
pending: [MAX_PENDING]PendingPacket = undefined,
pending_count: usize = 0,

pub fn init(guest_cid: u64, uds_path: [*:0]const u8) !Self {
    if (guest_cid < 3) {
        log.err("guest CID must be >= 3 (got {})", .{guest_cid});
        return error.InvalidCid;
    }

    const path_len = std.mem.indexOfSentinel(u8, 0, uds_path);
    if (path_len == 0 or path_len > MAX_UDS_PATH) {
        log.err("uds_path too long or empty: {} bytes", .{path_len});
        return error.InvalidUdsPath;
    }

    var self: Self = .{
        .guest_cid = guest_cid,
        .uds_path = undefined,
        .uds_path_len = path_len,
    };
    @memcpy(self.uds_path[0..path_len], uds_path[0..path_len]);
    self.uds_path[path_len] = 0;

    log.info("vsock device: guest_cid={}, uds_path={s}", .{ guest_cid, uds_path[0..path_len] });
    return self;
}

pub fn deinit(self: *Self) void {
    for (&self.connections) |*conn| {
        if (conn.fd >= 0) {
            _ = linux.close(conn.fd);
            conn.fd = -1;
        }
        conn.state = .idle;
    }
}

/// Device features offered to the driver.
pub fn deviceFeatures() u64 {
    return virtio.F_VERSION_1;
}

/// Read from device config space.
/// Config space: le64 guest_cid at offset 0.
pub fn readConfig(self: Self, offset: u64, data: []u8) void {
    var config: [8]u8 = undefined;
    std.mem.writeInt(u64, &config, self.guest_cid, .little);
    if (offset + data.len <= 8) {
        const start: usize = @intCast(offset);
        @memcpy(data, config[start..][0..data.len]);
    } else {
        @memset(data, 0);
    }
}

/// Flush pending write buffers on all connections.
/// Called from the run loop between KVM exits.
pub fn flushPendingWrites(self: *Self) void {
    for (&self.connections) |*conn| {
        if (conn.state != .idle and conn.write_len > 0) {
            _ = conn.flushWriteBuffer();
        }
    }
}

/// Process TX queue: handle packets from guest to host.
pub fn processTx(self: *Self, mem: *Memory, queue: *Queue) bool {
    var did_work = false;
    var processed: u16 = 0;
    while (processed < queue.size) : (processed += 1) {
        const head = queue.popAvail(mem) catch |err| {
            log.err("TX popAvail failed: {}", .{err});
            break;
        } orelse break;

        self.handleTxPacket(mem, queue, head) catch |err| {
            log.err("TX packet failed: {}", .{err});
            queue.pushUsed(mem, head, 0) catch |e| log.warn("TX pushUsed failed: {}", .{e});
        };
        did_work = true;
    }
    return did_work;
}

/// Poll for incoming data from host-side sockets and deliver to guest RX queue.
pub fn pollRx(self: *Self, mem: *Memory, queue: *Queue) bool {
    if (!queue.isReady()) return false;

    var did_work = false;
    for (&self.connections) |*conn| {
        if (conn.state != .established or conn.fd < 0) continue;
        if (conn.availableForTx() == 0) continue;

        // Try to deliver data from this connection to the guest
        if (self.deliverRxData(mem, queue, conn)) |delivered| {
            if (delivered) did_work = true;
        } else |err| {
            if (err == error.NoBuffers) break; // no more guest RX buffers
            log.warn("RX delivery failed for port {}: {}", .{ conn.guest_port, err });
        }
    }
    return did_work;
}

fn handleTxPacket(self: *Self, mem: *Memory, queue: *Queue, head: u16) !void {
    var descs: [16]Queue.Desc = undefined;
    const desc_count = try queue.collectChain(mem, head, &descs);

    if (desc_count == 0) return;

    // First descriptor must contain the vsock header (44 bytes)
    const hdr_desc = descs[0];
    if (hdr_desc.len < HDR_SIZE) {
        log.err("vsock TX header too small: {}", .{hdr_desc.len});
        try queue.pushUsed(mem, head, 0);
        return;
    }
    const hdr_bytes = try mem.slice(@intCast(hdr_desc.addr), HDR_SIZE);

    const src_cid = std.mem.readInt(u64, hdr_bytes[0..8], .little);
    const dst_cid = std.mem.readInt(u64, hdr_bytes[8..16], .little);
    const src_port = std.mem.readInt(u32, hdr_bytes[16..20], .little);
    const dst_port = std.mem.readInt(u32, hdr_bytes[20..24], .little);
    const payload_len = std.mem.readInt(u32, hdr_bytes[24..28], .little);
    const sock_type = std.mem.readInt(u16, hdr_bytes[28..30], .little);
    const op = std.mem.readInt(u16, hdr_bytes[30..32], .little);
    const flags = std.mem.readInt(u32, hdr_bytes[32..36], .little);
    const buf_alloc = std.mem.readInt(u32, hdr_bytes[36..40], .little);
    const fwd_cnt = std.mem.readInt(u32, hdr_bytes[40..44], .little);

    // Only stream sockets are supported
    if (sock_type != TYPE_STREAM) {
        log.warn("unsupported vsock type: {} (only STREAM supported)", .{sock_type});
        try queue.pushUsed(mem, head, 0);
        return;
    }

    // Verify source CID matches guest
    if (src_cid != self.guest_cid) {
        log.warn("TX packet with wrong src_cid: {} (expected {})", .{ src_cid, self.guest_cid });
        try queue.pushUsed(mem, head, 0);
        return;
    }

    // We only handle packets destined for the host (CID 2)
    if (dst_cid != HOST_CID) {
        log.warn("TX packet to unknown CID: {}", .{dst_cid});
        try queue.pushUsed(mem, head, 0);
        return;
    }

    switch (op) {
        OP_REQUEST => {
            self.handleRequest(src_port, dst_port, buf_alloc, fwd_cnt);
        },
        OP_RW => {
            self.handleRw(mem, &descs, desc_count, src_port, dst_port, payload_len, buf_alloc, fwd_cnt);
        },
        OP_SHUTDOWN => {
            self.handleShutdown(src_port, dst_port, flags);
        },
        OP_RST => {
            self.closeConnection(src_port, dst_port);
        },
        OP_CREDIT_UPDATE => {
            if (self.findConnection(src_port, dst_port)) |conn| {
                conn.guest_buf_alloc = buf_alloc;
                conn.guest_fwd_cnt = fwd_cnt;
            }
        },
        OP_CREDIT_REQUEST => {
            // Guest wants our credit info; we'll send it in the next RX packet
        },
        else => {
            log.warn("unknown vsock op: {}", .{op});
        },
    }

    try queue.pushUsed(mem, head, 0);
}

fn handleRequest(self: *Self, guest_port: u32, host_port: u32, buf_alloc: u32, fwd_cnt: u32) void {
    // Guest is requesting a connection to host port
    // Connect to {uds_path}_{host_port} on the host
    log.info("vsock connect: guest_port={} -> host_port={}", .{ guest_port, host_port });

    // Build Unix socket path: {uds_path}_{port}
    var path_buf: [MAX_UDS_PATH + 12]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}_{d}", .{
        self.uds_path[0..self.uds_path_len],
        host_port,
    }) catch {
        log.err("socket path too long", .{});
        self.queueRst(guest_port, host_port);
        return;
    };

    if (path.len > MAX_UDS_PATH) {
        log.err("socket path too long: {} bytes", .{path.len});
        self.queueRst(guest_port, host_port);
        return;
    }

    // Create Unix stream socket
    const sock_rc: isize = @bitCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) {
        log.err("socket() failed", .{});
        self.queueRst(guest_port, host_port);
        return;
    }
    const fd: i32 = @intCast(sock_rc);

    // Build sockaddr_un
    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    const path_with_z: []const u8 = path;
    @memcpy(addr.path[0..path_with_z.len], path_with_z);

    // Connect
    const conn_rc: isize = @bitCast(linux.connect(fd, @ptrCast(&addr), @intCast(@sizeOf(linux.sockaddr.un))));
    if (conn_rc < 0) {
        const errno: linux.E = @enumFromInt(@as(u16, @intCast(-conn_rc)));
        // EINPROGRESS is fine for non-blocking sockets, but for simplicity
        // we treat it as an error for now; the socket should be listening
        if (errno != .INPROGRESS) {
            log.err("connect to {s} failed: {}", .{ path, errno });
            _ = linux.close(fd);
            self.queueRst(guest_port, host_port);
            return;
        }
    }

    // Find a free connection slot
    const conn = self.allocConnection() orelse {
        log.err("too many connections", .{});
        _ = linux.close(fd);
        self.queueRst(guest_port, host_port);
        return;
    };

    conn.* = .{
        .state = .established,
        .guest_port = guest_port,
        .host_port = host_port,
        .fd = fd,
        .guest_buf_alloc = buf_alloc,
        .guest_fwd_cnt = fwd_cnt,
        .tx_cnt = 0,
        .rx_cnt = 0,
    };

    // Queue a RESPONSE packet for the RX queue
    self.queueResponse(guest_port, host_port);
}

fn handleRw(self: *Self, mem: *Memory, descs: []const Queue.Desc, desc_count: usize, guest_port: u32, host_port: u32, payload_len: u32, buf_alloc: u32, fwd_cnt: u32) void {
    const conn = self.findConnection(guest_port, host_port) orelse {
        log.warn("RW for unknown connection: guest_port={} host_port={}", .{ guest_port, host_port });
        return;
    };

    // Update flow control from guest
    conn.guest_buf_alloc = buf_alloc;
    conn.guest_fwd_cnt = fwd_cnt;

    if (payload_len == 0 or conn.fd < 0) return;

    // Cap payload_len to actual descriptor data to prevent flow control skew
    var total_desc_data: u32 = 0;
    for (descs[1..desc_count]) |desc| {
        total_desc_data += desc.len;
    }
    const effective_payload = @min(payload_len, total_desc_data);

    // Flush any pending write buffer first
    if (!conn.flushWriteBuffer()) {
        // Still blocked — stash new data in write buffer
        var remaining: u32 = effective_payload;
        for (descs[1..desc_count]) |desc| {
            if (remaining == 0) break;
            const chunk_len = @min(desc.len, remaining);
            const buf = mem.slice(@intCast(desc.addr), chunk_len) catch return;
            const stashed = conn.stashWrite(buf[0..chunk_len]);
            conn.rx_cnt +%= stashed;
            remaining -= chunk_len;
        }
        return;
    }

    // Write payload from data descriptors to host socket
    var remaining: u32 = effective_payload;
    var desc_idx: usize = 1; // start after header descriptor
    while (desc_idx < desc_count) : (desc_idx += 1) {
        if (remaining == 0) break;
        const desc = descs[desc_idx];
        const chunk_len = @min(desc.len, remaining);
        const buf = mem.slice(@intCast(desc.addr), chunk_len) catch {
            log.err("RW: bad guest address", .{});
            return;
        };

        var written: usize = 0;
        while (written < chunk_len) {
            const rc: isize = @bitCast(linux.write(conn.fd, buf[written..].ptr, chunk_len - written));
            if (rc < 0) {
                const errno: linux.E = @enumFromInt(@as(u16, @intCast(-rc)));
                if (errno == .AGAIN) {
                    // Stash unwritten data in buffer instead of dropping it
                    const unsent = buf[written..chunk_len];
                    const stashed = conn.stashWrite(unsent);
                    conn.rx_cnt +%= @intCast(written + stashed);
                    // Stash remaining descriptors starting from the NEXT one
                    remaining -= chunk_len;
                    var rem_idx = desc_idx + 1;
                    while (rem_idx < desc_count) : (rem_idx += 1) {
                        if (remaining == 0) break;
                        const rem_desc = descs[rem_idx];
                        const rem_len = @min(rem_desc.len, remaining);
                        const rem_buf = mem.slice(@intCast(rem_desc.addr), rem_len) catch break;
                        const rem_stashed = conn.stashWrite(rem_buf[0..rem_len]);
                        conn.rx_cnt +%= rem_stashed;
                        remaining -= rem_len;
                    }
                    return;
                }
                log.warn("write to host socket failed: {}", .{errno});
                return;
            }
            if (rc == 0) break;
            written += @intCast(rc);
        }
        conn.rx_cnt +%= @intCast(written);
        remaining -= chunk_len;
    }
}

fn handleShutdown(self: *Self, guest_port: u32, host_port: u32, flags: u32) void {
    log.info("vsock shutdown: guest_port={} host_port={} flags={}", .{ guest_port, host_port, flags });
    const conn = self.findConnection(guest_port, host_port) orelse return;

    if (flags & (SHUTDOWN_RCV | SHUTDOWN_SEND) == (SHUTDOWN_RCV | SHUTDOWN_SEND)) {
        // Full shutdown — close and send RST
        self.closeConnectionPtr(conn);
    } else {
        // Partial shutdown
        if (conn.fd >= 0) {
            const how: i32 = if (flags & SHUTDOWN_RCV != 0) 0 // SHUT_RD
            else if (flags & SHUTDOWN_SEND != 0) 1 // SHUT_WR
            else return;
            _ = linux.shutdown(conn.fd, how);
        }
    }
}

fn deliverRxData(self: *Self, mem: *Memory, queue: *Queue, conn: *Connection) !bool {
    // Pop an RX descriptor from the guest
    const head = (try queue.popAvail(mem)) orelse return error.NoBuffers;

    var descs: [16]Queue.Desc = undefined;
    const desc_count = queue.collectChain(mem, head, &descs) catch |err| {
        queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
        return err;
    };

    if (desc_count == 0 or descs[0].len < HDR_SIZE) {
        queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
        return false;
    }

    // Calculate available data buffer space
    var data_space: u32 = 0;
    for (descs[1..desc_count]) |desc| {
        data_space += desc.len;
    }

    // Also respect flow control
    const tx_window = conn.availableForTx();
    if (tx_window == 0 and data_space > 0) {
        // No TX window — push descriptor back unused
        queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
        return false;
    }
    const max_read = @min(data_space, tx_window);

    // Try to read from the host socket into data descriptors using readv
    var total_read: u32 = 0;
    const data_descs = descs[1..desc_count];
    if (max_read > 0 and data_descs.len > 0) {
        var iov: [16]std.posix.iovec = undefined;
        var iov_count: usize = 0;
        var remaining = max_read;
        for (data_descs) |desc| {
            if (remaining == 0) break;
            const read_len = @min(desc.len, remaining);
            const buf = mem.slice(@intCast(desc.addr), read_len) catch break;
            iov[iov_count] = .{ .base = buf.ptr, .len = buf.len };
            iov_count += 1;
            remaining -= read_len;
        }

        if (iov_count == 0) {
            queue.pushUsed(mem, head, 0) catch |e| log.warn("RX pushUsed failed: {}", .{e});
            return false;
        }

        const rc: isize = @bitCast(linux.readv(conn.fd, @ptrCast(&iov), @intCast(iov_count)));
        if (rc < 0) {
            const errno: linux.E = @enumFromInt(@as(u16, @intCast(-rc)));
            if (errno == .AGAIN) {
                // No data available
                queue.pushUsed(mem, head, 0) catch |e| log.warn("RX pushUsed failed: {}", .{e});
                return false;
            }
            // Socket error — close connection, send RST to guest
            log.warn("read from host socket failed: {}", .{errno});
            self.sendRstToGuest(mem, queue, head, &descs, conn);
            self.closeConnectionPtr(conn);
            return true;
        }
        if (rc == 0) {
            // EOF — host closed connection, send RST to guest
            self.sendRstToGuest(mem, queue, head, &descs, conn);
            self.closeConnectionPtr(conn);
            return true;
        }
        total_read = @intCast(rc);
    }

    if (total_read == 0 and data_space > 0) {
        // No data to deliver
        queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
        return false;
    }

    // Write RW header to first descriptor
    const hdr_buf = try mem.slice(@intCast(descs[0].addr), HDR_SIZE);
    self.writeHdr(hdr_buf, conn.host_port, conn.guest_port, OP_RW, total_read, conn);
    conn.tx_cnt +%= total_read;

    const total_written: u32 = HDR_SIZE + total_read;
    queue.pushUsed(mem, head, total_written) catch |e| log.warn("RX pushUsed failed: {}", .{e});
    return true;
}

fn sendRstToGuest(self: *Self, mem: *Memory, queue: *Queue, head: u16, descs: []const Queue.Desc, conn: *Connection) void {
    if (descs[0].len < HDR_SIZE) {
        queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
        return;
    }
    const hdr_buf = mem.slice(@intCast(descs[0].addr), HDR_SIZE) catch {
        queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
        return;
    };
    self.writeHdr(hdr_buf, conn.host_port, conn.guest_port, OP_RST, 0, conn);
    queue.pushUsed(mem, head, HDR_SIZE) catch |e| log.warn("RST pushUsed failed: {}", .{e});
}

// Pending control packets to send to guest (RESPONSE, RST, CREDIT_UPDATE)
const PendingPacket = struct {
    guest_port: u32,
    host_port: u32,
    op: u16,
};
const MAX_PENDING: usize = 64;

fn queueResponse(self: *Self, guest_port: u32, host_port: u32) void {
    if (self.pending_count < self.pending.len) {
        self.pending[self.pending_count] = .{
            .guest_port = guest_port,
            .host_port = host_port,
            .op = OP_RESPONSE,
        };
        self.pending_count += 1;
    }
}

fn queueRst(self: *Self, guest_port: u32, host_port: u32) void {
    if (self.pending_count < self.pending.len) {
        self.pending[self.pending_count] = .{
            .guest_port = guest_port,
            .host_port = host_port,
            .op = OP_RST,
        };
        self.pending_count += 1;
    }
}

/// Deliver pending control packets (RESPONSE, RST) to the guest RX queue.
pub fn deliverPending(self: *Self, mem: *Memory, queue: *Queue) bool {
    if (!queue.isReady()) return false;
    var did_work = false;

    while (self.pending_count > 0) {
        const head = queue.popAvail(mem) catch break orelse break;

        var descs: [16]Queue.Desc = undefined;
        const desc_count = queue.collectChain(mem, head, &descs) catch {
            queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
            break;
        };

        if (desc_count == 0 or descs[0].len < HDR_SIZE) {
            queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
            break;
        }

        self.pending_count -= 1;
        const pkt = self.pending[self.pending_count];

        const hdr_buf = mem.slice(@intCast(descs[0].addr), HDR_SIZE) catch {
            queue.pushUsed(mem, head, 0) catch |e| log.warn("pushUsed failed: {}", .{e});
            continue;
        };

        const conn = self.findConnection(pkt.guest_port, pkt.host_port);
        self.writeHdr(hdr_buf, pkt.host_port, pkt.guest_port, pkt.op, 0, conn);
        queue.pushUsed(mem, head, HDR_SIZE) catch |e| log.warn("pending pushUsed failed: {}", .{e});
        did_work = true;
    }

    return did_work;
}

fn writeHdr(self: *Self, buf: []u8, src_port: u32, dst_port: u32, op: u16, payload_len: u32, conn: ?*Connection) void {
    // src_cid: le64
    std.mem.writeInt(u64, buf[0..8], HOST_CID, .little);
    // dst_cid: le64
    std.mem.writeInt(u64, buf[8..16], self.guest_cid, .little);
    // src_port: le32
    std.mem.writeInt(u32, buf[16..20], src_port, .little);
    // dst_port: le32
    std.mem.writeInt(u32, buf[20..24], dst_port, .little);
    // len: le32
    std.mem.writeInt(u32, buf[24..28], payload_len, .little);
    // type: le16 (STREAM)
    std.mem.writeInt(u16, buf[28..30], TYPE_STREAM, .little);
    // op: le16
    std.mem.writeInt(u16, buf[30..32], op, .little);
    // flags: le32
    std.mem.writeInt(u32, buf[32..36], 0, .little);
    // buf_alloc: le32 (our receive buffer)
    std.mem.writeInt(u32, buf[36..40], CONN_BUF_ALLOC, .little);
    // fwd_cnt: le32 (bytes we've forwarded to host app)
    const fwd = if (conn) |c| c.rx_cnt else 0;
    std.mem.writeInt(u32, buf[40..44], fwd, .little);
}

fn findConnection(self: *Self, guest_port: u32, host_port: u32) ?*Connection {
    for (&self.connections) |*conn| {
        if (conn.state != .idle and conn.guest_port == guest_port and conn.host_port == host_port) {
            return conn;
        }
    }
    return null;
}

fn allocConnection(self: *Self) ?*Connection {
    for (&self.connections) |*conn| {
        if (conn.state == .idle) return conn;
    }
    return null;
}

fn closeConnection(self: *Self, guest_port: u32, host_port: u32) void {
    if (self.findConnection(guest_port, host_port)) |conn| {
        self.closeConnectionPtr(conn);
    }
}

fn closeConnectionPtr(_: *Self, conn: *Connection) void {
    if (conn.fd >= 0) {
        _ = linux.close(conn.fd);
        conn.fd = -1;
    }
    conn.state = .idle;
}
