// Virtio block device backend.
// Handles read/write/flush requests against a backing file.

const std = @import("std");
const linux = std.os.linux;
const Memory = @import("../../memory.zig");
const Queue = @import("queue.zig");
const virtio = @import("../virtio.zig");

const log = std.log.scoped(.virtio_blk);

const Self = @This();

// Block request types
pub const T_IN: u32 = 0; // read
pub const T_OUT: u32 = 1; // write
pub const T_FLUSH: u32 = 4;
pub const T_GET_ID: u32 = 8;

// Status values
pub const S_OK: u8 = 0;
pub const S_IOERR: u8 = 1;
pub const S_UNSUPP: u8 = 2;

// Feature bits
pub const F_FLUSH: u64 = 1 << 9;

const SECTOR_SIZE: u64 = 512;
const REQ_HDR_SIZE: u32 = 16; // type: u32, reserved: u32, sector: u64

fd: i32,
capacity: u64, // in 512-byte sectors

pub fn init(path: [*:0]const u8) !Self {
    const open_rc: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0));
    if (open_rc < 0) return error.OpenFailed;
    const fd: i32 = @intCast(open_rc);
    errdefer _ = linux.close(fd);

    // Get file size
    var stx: linux.Statx = undefined;
    const stat_rc: isize = @bitCast(linux.statx(fd, "", @as(u32, linux.AT.EMPTY_PATH), .{}, &stx));
    if (stat_rc < 0) return error.StatFailed;

    const file_size: u64 = @intCast(stx.size);
    const capacity = file_size / SECTOR_SIZE;

    log.info("block device: {s}, {} sectors ({} MB)", .{ path, capacity, file_size / (1024 * 1024) });

    return .{ .fd = fd, .capacity = capacity };
}

pub fn deinit(self: Self) void {
    _ = linux.close(self.fd);
}

/// Device features offered to the driver.
pub fn deviceFeatures() u64 {
    return virtio.F_VERSION_1 | F_FLUSH;
}

/// Read from device config space.
pub fn readConfig(self: Self, offset: u64, data: []u8) void {
    // Config space: le64 capacity at offset 0
    if (offset + data.len <= 8) {
        var cap_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &cap_bytes, self.capacity, .little);
        const start: usize = @intCast(offset);
        @memcpy(data, cap_bytes[start..][0..data.len]);
    } else {
        @memset(data, 0);
    }
}

/// Validate that a sector range fits within the disk capacity.
fn validateSectorRange(self: Self, sector: u64, data_len: u64) bool {
    const end_sector = std.math.add(u64, sector, (data_len + SECTOR_SIZE - 1) / SECTOR_SIZE) catch return false;
    return end_sector <= self.capacity;
}

/// Process a single request from the virtqueue.
pub fn processRequest(self: Self, mem: *Memory, queue: *Queue, head: u16) !void {
    // Walk the chain collecting descriptors (with cycle detection)
    var descs: [16]Queue.Desc = undefined;
    const desc_count = try queue.collectChain(mem, head, &descs);

    // Need at least header (desc 0) + status (last desc)
    if (desc_count < 2) {
        log.err("block request with only {} descriptors", .{desc_count});
        return error.MalformedRequest;
    }

    // Parse header (first descriptor)
    const hdr_desc = descs[0];
    if (hdr_desc.len < REQ_HDR_SIZE) {
        log.err("block request header too small: {}", .{hdr_desc.len});
        return error.MalformedRequest;
    }
    const hdr_bytes = try mem.slice(@intCast(hdr_desc.addr), REQ_HDR_SIZE);
    const req_type = std.mem.readInt(u32, hdr_bytes[0..4], .little);
    const sector = std.mem.readInt(u64, hdr_bytes[8..16], .little);

    // Status descriptor is always the last one — must be device-writable
    const status_desc = descs[desc_count - 1];
    if (status_desc.flags & virtio.DESC_F_WRITE == 0) {
        log.err("block status descriptor is not device-writable", .{});
        return error.MalformedRequest;
    }
    const status_ptr = try mem.slice(@intCast(status_desc.addr), 1);

    // Calculate total data length across all data descriptors
    var total_data_len: u64 = 0;
    for (descs[1 .. desc_count - 1]) |desc| {
        total_data_len += desc.len;
    }

    var status: u8 = S_OK;
    // Bytes written to device-writable descriptors (for used ring len).
    // T_IN: data buffers + status byte. T_OUT/T_FLUSH/others: status byte only.
    var device_written: u64 = 1; // always at least the status byte

    switch (req_type) {
        T_IN => {
            // Validate data descriptors are device-writable (VMM writes disk data into them)
            for (descs[1 .. desc_count - 1]) |desc| {
                if (desc.flags & virtio.DESC_F_WRITE == 0) {
                    log.err("T_IN data descriptor is not device-writable", .{});
                    status = S_IOERR;
                    break;
                }
            }
            // Validate sector range before any I/O
            if (status == S_OK and !self.validateSectorRange(sector, total_data_len)) {
                log.err("read past end of disk: sector={} len={}", .{ sector, total_data_len });
                status = S_IOERR;
            } else if (status == S_OK) {
                // Read from disk into guest buffers
                // sector is validated by validateSectorRange — multiplication is safe
                var file_offset: u64 = sector * SECTOR_SIZE;
                for (descs[1 .. desc_count - 1]) |desc| {
                    const buf = try mem.slice(@intCast(desc.addr), desc.len);
                    const rc: isize = @bitCast(linux.pread(self.fd, buf.ptr, buf.len, @bitCast(file_offset)));
                    if (rc < 0) {
                        status = S_IOERR;
                        break;
                    }
                    const bytes_read: u32 = @intCast(rc);
                    // Zero-fill remainder if short read
                    if (bytes_read < desc.len) {
                        @memset(buf[bytes_read..], 0);
                    }
                    file_offset = std.math.add(u64, file_offset, desc.len) catch {
                        status = S_IOERR;
                        break;
                    };
                }
                device_written += total_data_len;
            }
        },
        T_OUT => {
            // Validate data descriptors are device-readable (VMM reads guest data from them)
            for (descs[1 .. desc_count - 1]) |desc| {
                if (desc.flags & virtio.DESC_F_WRITE != 0) {
                    log.err("T_OUT data descriptor is device-writable (expected readable)", .{});
                    status = S_IOERR;
                    break;
                }
            }
            // Validate sector range before any I/O
            if (status == S_OK and !self.validateSectorRange(sector, total_data_len)) {
                log.err("write past end of disk: sector={} len={}", .{ sector, total_data_len });
                status = S_IOERR;
            } else if (status == S_OK) {
                // Write from guest buffers to disk
                // sector is validated by validateSectorRange — multiplication is safe
                var file_offset: u64 = sector * SECTOR_SIZE;
                for (descs[1 .. desc_count - 1]) |desc| {
                    const buf = try mem.slice(@intCast(desc.addr), desc.len);
                    // Retry short writes to prevent silent data loss
                    var written: u32 = 0;
                    while (written < desc.len) {
                        const rc: isize = @bitCast(linux.pwrite(self.fd, buf[written..].ptr, desc.len - written, @bitCast(file_offset + written)));
                        if (rc <= 0) {
                            status = S_IOERR;
                            break;
                        }
                        written += @intCast(rc);
                    }
                    if (status != S_OK) break;
                    file_offset = std.math.add(u64, file_offset, desc.len) catch {
                        status = S_IOERR;
                        break;
                    };
                }
            }
        },
        T_FLUSH => {
            const rc: isize = @bitCast(linux.fdatasync(self.fd));
            if (rc < 0) status = S_IOERR;
        },
        T_GET_ID => {
            // Write device ID string (up to 20 bytes)
            if (desc_count >= 3) {
                const id_desc = descs[1];
                const id_buf = try mem.slice(@intCast(id_desc.addr), @min(id_desc.len, 20));
                const id = "flint-virtio-blk";
                const copy_len = @min(id.len, id_buf.len);
                @memcpy(id_buf[0..copy_len], id[0..copy_len]);
                if (copy_len < id_buf.len) @memset(id_buf[copy_len..], 0);
                device_written += id_desc.len;
            }
        },
        else => {
            status = S_UNSUPP;
        },
    }

    // Write status byte
    status_ptr[0] = status;

    // Push to used ring with bytes written to device-writable descriptors
    const used_len: u32 = @intCast(@min(device_written, std.math.maxInt(u32)));
    try queue.pushUsed(mem, head, used_len);
}
