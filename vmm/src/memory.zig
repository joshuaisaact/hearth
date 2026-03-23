// Guest physical memory management.
// Allocates host memory via mmap and provides access for loading kernels
// and handling guest memory operations.

const std = @import("std");

const log = std.log.scoped(.memory);

const Self = @This();

/// The raw mmap'd memory region backing guest physical RAM.
mem: []align(std.heap.page_size_min) u8,

pub fn init(mem_size: usize) !Self {
    const mem = std.posix.mmap(
        null,
        mem_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
        -1,
        0,
    ) catch return error.GuestMemoryAlloc;

    log.info("guest memory: {} MB at host 0x{x}", .{ mem_size / (1024 * 1024), @intFromPtr(mem.ptr) });
    return .{ .mem = mem };
}

/// Restore guest memory by mmap'ing a snapshot file with MAP_PRIVATE.
/// Pages are demand-loaded from the file via kernel page faults (copy-on-write).
/// This is the key to ~5ms restore: no upfront memory read regardless of VM size.
/// The file can be closed after mmap — the kernel holds a reference.
pub fn initFromFile(path: [*:0]const u8, expected_size: usize) !Self {
    const linux = std.os.linux;

    const open_rc: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (open_rc < 0) return error.SnapshotOpenFailed;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    // Validate file size matches expected guest memory size
    var stx: linux.Statx = undefined;
    const stat_rc: isize = @bitCast(linux.statx(fd, "", @as(u32, linux.AT.EMPTY_PATH), .{}, &stx));
    if (stat_rc < 0) return error.SnapshotStatFailed;
    if (@as(u64, @intCast(stx.size)) != expected_size) {
        log.err("memory file size mismatch: got {} expected {}", .{ stx.size, expected_size });
        return error.SnapshotSizeMismatch;
    }

    // MAP_PRIVATE: writes go to anonymous COW pages, reads demand-page from file
    const mem = std.posix.mmap(
        null,
        expected_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    ) catch return error.SnapshotMmapFailed;

    log.info("guest memory restored: {} MB from file (demand-paged)", .{expected_size / (1024 * 1024)});
    return .{ .mem = mem };
}

pub fn deinit(self: Self) void {
    std.posix.munmap(self.mem);
}

pub fn size(self: Self) usize {
    return self.mem.len;
}

/// Get a slice of guest memory starting at the given guest physical address.
pub fn slice(self: Self, guest_addr: usize, len: usize) ![]u8 {
    const end = std.math.add(usize, guest_addr, len) catch return error.GuestMemoryOutOfBounds;
    if (end > self.mem.len) return error.GuestMemoryOutOfBounds;
    return self.mem[guest_addr..][0..len];
}

/// Get a pointer to a struct at the given guest physical address.
pub fn ptrAt(self: Self, comptime T: type, guest_addr: usize) !*T {
    const end = std.math.add(usize, guest_addr, @sizeOf(T)) catch return error.GuestMemoryOutOfBounds;
    if (end > self.mem.len) return error.GuestMemoryOutOfBounds;
    if (guest_addr % @alignOf(T) != 0) return error.GuestMemoryMisaligned;
    return @ptrCast(@alignCast(&self.mem[guest_addr]));
}

/// Write bytes into guest memory at the given guest physical address.
pub fn write(self: Self, guest_addr: usize, data: []const u8) !void {
    const dest = try self.slice(guest_addr, data.len);
    @memcpy(dest, data);
}

/// Get the aligned slice for passing to KVM setMemoryRegion.
pub fn alignedMem(self: Self) []align(std.heap.page_size_min) u8 {
    return self.mem;
}
