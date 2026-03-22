// Split virtqueue implementation.
// Reads/writes descriptor table, available ring, and used ring in guest memory.

const std = @import("std");
const Memory = @import("../../memory.zig");
const virtio = @import("../virtio.zig");

const log = std.log.scoped(.virtqueue);

const Self = @This();

/// Maximum queue size (must be power of 2).
pub const MAX_QUEUE_SIZE: u16 = 256;
comptime {
    std.debug.assert(@popCount(MAX_QUEUE_SIZE) == 1);
}

// Queue configuration (set during device init)
size: u16 = 0,
ready: bool = false,

// Guest physical addresses of the three regions
desc_addr: u64 = 0,
avail_addr: u64 = 0,
used_addr: u64 = 0,

// Device-side tracking (host-authoritative, not read from guest memory)
last_avail_idx: u16 = 0,
next_used_idx: u16 = 0,

pub fn reset(self: *Self) void {
    self.* = .{};
}

pub fn isReady(self: Self) bool {
    return self.ready and self.size > 0 and
        self.desc_addr != 0 and self.avail_addr != 0 and self.used_addr != 0;
}

/// Descriptor table entry (16 bytes).
pub const Desc = packed struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

/// Read a descriptor from guest memory.
pub fn getDesc(self: Self, mem: *Memory, index: u16) !Desc {
    if (index >= self.size) return error.InvalidDescIndex;
    const offset: usize = @intCast(self.desc_addr + @as(u64, index) * 16);
    const bytes = try mem.slice(offset, 16);
    return .{
        .addr = std.mem.readInt(u64, bytes[0..8], .little),
        .len = std.mem.readInt(u32, bytes[8..12], .little),
        .flags = std.mem.readInt(u16, bytes[12..14], .little),
        .next = std.mem.readInt(u16, bytes[14..16], .little),
    };
}

/// Read the current avail.idx (free-running u16).
fn getAvailIdx(self: Self, mem: *Memory) !u16 {
    const offset: usize = @intCast(self.avail_addr + 2); // avail.idx at offset 2
    const bytes = try mem.slice(offset, 2);
    return std.mem.readInt(u16, bytes[0..2], .little);
}

/// Read an entry from the available ring.
fn getAvailRing(self: Self, mem: *Memory, ring_idx: u16) !u16 {
    const pos = ring_idx % self.size;
    const offset: usize = @intCast(self.avail_addr + 4 + @as(u64, pos) * 2);
    const bytes = try mem.slice(offset, 2);
    return std.mem.readInt(u16, bytes[0..2], .little);
}

/// Write an entry to the used ring and advance used.idx.
/// Tracks used_idx on the host side to prevent guest TOCTOU attacks.
pub fn pushUsed(self: *Self, mem: *Memory, desc_head: u16, len: u32) !void {
    const pos = self.next_used_idx % self.size;

    // Write used element (id + len) at ring[pos]
    const elem_offset: usize = @intCast(self.used_addr + 4 + @as(u64, pos) * 8);
    const elem_bytes = try mem.slice(elem_offset, 8);
    std.mem.writeInt(u32, elem_bytes[0..4], desc_head, .little);
    std.mem.writeInt(u32, elem_bytes[4..8], len, .little);

    // Increment host-tracked used.idx and write to guest memory
    self.next_used_idx +%= 1;
    const idx_offset: usize = @intCast(self.used_addr + 2);
    const idx_bytes = try mem.slice(idx_offset, 2);
    std.mem.writeInt(u16, idx_bytes[0..2], self.next_used_idx, .little);
}

// --- Snapshot support ---
// Queue state is entirely in these struct fields — the actual descriptor/ring
// data lives in guest memory and is saved/restored with the memory file.
// We only need to persist our host-side tracking indices.
pub const SNAPSHOT_SIZE = 31; // 2+1+8+8+8+2+2

pub fn snapshotSave(self: *const Self) [SNAPSHOT_SIZE]u8 {
    var buf: [SNAPSHOT_SIZE]u8 = undefined;
    std.mem.writeInt(u16, buf[0..2], self.size, .little);
    buf[2] = @intFromBool(self.ready);
    std.mem.writeInt(u64, buf[3..11], self.desc_addr, .little);
    std.mem.writeInt(u64, buf[11..19], self.avail_addr, .little);
    std.mem.writeInt(u64, buf[19..27], self.used_addr, .little);
    std.mem.writeInt(u16, buf[27..29], self.last_avail_idx, .little);
    std.mem.writeInt(u16, buf[29..31], self.next_used_idx, .little);
    return buf;
}

pub fn snapshotRestore(self: *Self, buf: [SNAPSHOT_SIZE]u8) void {
    const size = std.mem.readInt(u16, buf[0..2], .little);
    // Validate queue size: must be 0, or a power-of-2 <= MAX_QUEUE_SIZE.
    // Invalid sizes would cause division-by-zero in ring index modular arithmetic.
    if (size != 0 and (size > MAX_QUEUE_SIZE or @popCount(size) != 1)) {
        log.warn("snapshot: invalid queue size {}, resetting to 0", .{size});
        self.reset();
        return;
    }
    self.size = size;
    self.ready = buf[2] != 0;
    self.desc_addr = std.mem.readInt(u64, buf[3..11], .little);
    self.avail_addr = std.mem.readInt(u64, buf[11..19], .little);
    self.used_addr = std.mem.readInt(u64, buf[19..27], .little);
    self.last_avail_idx = std.mem.readInt(u16, buf[27..29], .little);
    self.next_used_idx = std.mem.readInt(u16, buf[29..31], .little);
}

/// Walk a descriptor chain starting at `head`, collecting up to `max` descriptors.
/// Returns the number of descriptors collected. Detects cycles via a visited bitset.
pub fn collectChain(self: Self, mem: *Memory, head: u16, descs: []Desc) !usize {
    var visited: [MAX_QUEUE_SIZE / 8]u8 = .{0} ** (MAX_QUEUE_SIZE / 8);
    var count: usize = 0;
    var idx = head;

    while (true) {
        if (count >= descs.len) return error.DescChainTooLong;
        if (idx >= self.size) return error.InvalidDescIndex;

        // Cycle detection
        const byte = idx / 8;
        const bit: u3 = @intCast(idx % 8);
        if (visited[byte] & (@as(u8, 1) << bit) != 0) return error.DescChainCycle;
        visited[byte] |= @as(u8, 1) << bit;

        descs[count] = try self.getDesc(mem, idx);
        count += 1;
        if (descs[count - 1].flags & virtio.DESC_F_NEXT != 0) {
            idx = descs[count - 1].next;
        } else {
            break;
        }
    }
    return count;
}

/// Pop the next available descriptor chain head. Returns null if none available.
pub fn popAvail(self: *Self, mem: *Memory) !?u16 {
    const avail_idx = try self.getAvailIdx(mem);
    if (avail_idx == self.last_avail_idx) return null;

    const head = try self.getAvailRing(mem, self.last_avail_idx);
    self.last_avail_idx +%= 1;
    return head;
}
