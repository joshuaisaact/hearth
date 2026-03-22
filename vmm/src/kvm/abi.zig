// KVM ABI: ioctl constants and struct definitions imported from Linux headers,
// plus a generic ioctl helper to eliminate repetitive errno checking.

const std = @import("std");
const linux = std.os.linux;

pub const c = @cImport({
    @cInclude("linux/kvm.h");
});

/// Generic ioctl helper that translates errno into Zig errors.
/// Returns the ioctl result as a usize on success.
pub fn ioctl(fd: std.posix.fd_t, request: u32, arg: usize) !usize {
    while (true) {
        const rc = linux.syscall3(.ioctl, @bitCast(@as(isize, fd)), request, arg);
        const signed: isize = @bitCast(rc);
        if (signed >= 0) return rc;
        const errno: linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
        switch (errno) {
            .INTR => continue,
            .AGAIN => return error.Again,
            .BADF => return error.BadFd,
            .FAULT => return error.Fault,
            .INVAL => return error.InvalidArgument,
            .NOMEM => return error.OutOfMemory,
            .NXIO => return error.NoDevice,
            .PERM, .ACCES => return error.PermissionDenied,
            else => return error.Unexpected,
        }
    }
}

/// Convenience: ioctl that ignores the return value.
pub fn ioctlVoid(fd: std.posix.fd_t, request: u32, arg: usize) !void {
    _ = try ioctl(fd, request, arg);
}

/// Close a file descriptor via the linux syscall.
pub fn close(fd: std.posix.fd_t) void {
    _ = linux.close(fd);
}
