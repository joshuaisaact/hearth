// Kvm: wraps the /dev/kvm system fd.
// Provides system-level operations: version check, VM creation.

const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;
const Vm = @import("vm.zig");

const log = std.log.scoped(.kvm);

const Self = @This();

fd: std.posix.fd_t,

pub fn open() !Self {
    const fd = std.posix.openat(std.posix.AT.FDCWD, "/dev/kvm", .{
        .ACCMODE = .RDWR,
        .CLOEXEC = true,
    }, 0) catch |err| {
        log.err("failed to open /dev/kvm: {}", .{err});
        return error.KvmUnavailable;
    };

    errdefer abi.close(fd);

    // Check API version
    const version = try abi.ioctl(fd, c.KVM_GET_API_VERSION, 0);
    if (version != 12) {
        log.err("unexpected KVM API version: {}, expected 12", .{version});
        return error.UnsupportedApiVersion;
    }

    log.info("KVM API version {}", .{version});
    return .{ .fd = fd };
}

pub fn deinit(self: Self) void {
    abi.close(self.fd);
}

pub fn createVm(self: Self) !Vm {
    return Vm.create(self.fd);
}

/// Get the mmap size for vCPU run structures.
pub fn getVcpuMmapSize(self: Self) !usize {
    return try abi.ioctl(self.fd, c.KVM_GET_VCPU_MMAP_SIZE, 0);
}

/// Maximum CPUID entries we support.
pub const MAX_CPUID_ENTRIES = 256;

/// Buffer for KVM_GET_SUPPORTED_CPUID / KVM_SET_CPUID2.
/// Matches the layout of kvm_cpuid2 with a fixed-size entries array.
pub const CpuidBuffer = extern struct {
    nent: u32,
    padding: u32 = 0,
    entries: [MAX_CPUID_ENTRIES]c.kvm_cpuid_entry2,
};

/// Get the CPUID entries supported by this host.
pub fn getSupportedCpuid(self: Self) !CpuidBuffer {
    var buf: CpuidBuffer = undefined;
    buf.nent = MAX_CPUID_ENTRIES;
    buf.padding = 0;
    try abi.ioctlVoid(self.fd, c.KVM_GET_SUPPORTED_CPUID, @intFromPtr(&buf));
    log.info("got {} supported CPUID entries", .{buf.nent});
    return buf;
}
