// Vcpu: wraps a KVM vCPU fd.
// Provides register access and the VM run loop.

const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;
const Kvm = @import("system.zig");

const log = std.log.scoped(.vcpu);

const Self = @This();

fd: std.posix.fd_t,
kvm_run: *volatile c.kvm_run,
kvm_run_mmap_size: usize,

pub fn create(vm_fd: std.posix.fd_t, vcpu_id: u32, mmap_size: usize) !Self {
    const fd: i32 = @intCast(try abi.ioctl(vm_fd, c.KVM_CREATE_VCPU, vcpu_id));
    errdefer abi.close(fd);

    const mapped = std.posix.mmap(
        null,
        mmap_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    ) catch return error.MmapFailed;

    const kvm_run: *volatile c.kvm_run = @ptrCast(@alignCast(mapped.ptr));

    log.info("vCPU {} created (fd={})", .{ vcpu_id, fd });
    return .{
        .fd = fd,
        .kvm_run = kvm_run,
        .kvm_run_mmap_size = mmap_size,
    };
}

pub fn deinit(self: Self) void {
    const ptr: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(@constCast(@volatileCast(self.kvm_run))));
    std.posix.munmap(ptr[0..self.kvm_run_mmap_size]);
    abi.close(self.fd);
}

pub fn getRegs(self: Self) !c.kvm_regs {
    var regs: c.kvm_regs = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_REGS, @intFromPtr(&regs));
    return regs;
}

pub fn setRegs(self: Self, regs: *const c.kvm_regs) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_REGS, @intFromPtr(regs));
}

pub fn getSregs(self: Self) !c.kvm_sregs {
    var sregs: c.kvm_sregs = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_SREGS, @intFromPtr(&sregs));
    return sregs;
}

pub fn setSregs(self: Self, sregs: *const c.kvm_sregs) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_SREGS, @intFromPtr(sregs));
}

/// Execute the vCPU until it exits. Returns the exit reason.
/// Unlike the generic ioctl helper, this does NOT retry on EINTR —
/// KVM_RUN returns EINTR when interrupted by a signal (e.g., for
/// pause), and the caller needs to see that.
pub fn run(self: Self) !u32 {
    const linux = std.os.linux;
    const rc = linux.syscall3(.ioctl, @bitCast(@as(isize, self.fd)), c.KVM_RUN, 0);
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        const errno: linux.E = @enumFromInt(@as(u16, @intCast(-signed)));
        return switch (errno) {
            .INTR => error.Interrupted,
            .AGAIN => error.Again,
            .BADF => error.BadFd,
            .INVAL => error.InvalidArgument,
            else => error.Unexpected,
        };
    }
    return self.kvm_run.exit_reason;
}

/// Get the IO exit data (valid when exit_reason == KVM_EXIT_IO).
pub fn getIoData(self: Self) IoExit {
    const io = self.kvm_run.unnamed_0.io;
    const base: [*]u8 = @constCast(@ptrCast(@volatileCast(self.kvm_run)));
    return .{
        .direction = io.direction,
        .port = io.port,
        .size = io.size,
        .count = io.count,
        .data = base + io.data_offset,
    };
}

pub fn setCpuid(self: Self, cpuid: *Kvm.CpuidBuffer) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_CPUID2, @intFromPtr(cpuid));
}

/// Read back the CPUID entries currently set on this vCPU.
/// Needed for snapshot: the guest may see filtered CPUID vs host's supported set.
pub fn getCpuid(self: Self, cpuid: *Kvm.CpuidBuffer) !void {
    cpuid.nent = Kvm.MAX_CPUID_ENTRIES;
    cpuid.padding = 0;
    try abi.ioctlVoid(self.fd, c.KVM_GET_CPUID2, @intFromPtr(cpuid));
}

// --- Snapshot state accessors ---
// KVM requires strict ordering when saving/restoring vCPU state.
// See PLAN-snapshot.md for the full ordering rationale.

/// MP_STATE must be saved first — the ioctl internally calls
/// kvm_apic_accept_events() which flushes pending APIC state.
pub fn getMpState(self: Self) !c.kvm_mp_state {
    var state: c.kvm_mp_state = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_MP_STATE, @intFromPtr(&state));
    return state;
}

pub fn setMpState(self: Self, state: *const c.kvm_mp_state) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_MP_STATE, @intFromPtr(state));
}

pub fn getVcpuEvents(self: Self) !c.kvm_vcpu_events {
    var events: c.kvm_vcpu_events = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_VCPU_EVENTS, @intFromPtr(&events));
    return events;
}

/// vcpu_events must be restored last — it contains pending exceptions
/// that would be lost if other SET ioctls clear them.
pub fn setVcpuEvents(self: Self, events: *const c.kvm_vcpu_events) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_VCPU_EVENTS, @intFromPtr(events));
}

pub fn getLapic(self: Self) !c.kvm_lapic_state {
    var lapic: c.kvm_lapic_state = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_LAPIC, @intFromPtr(&lapic));
    return lapic;
}

/// LAPIC restore must follow SREGS — KVM needs the APIC base MSR
/// (set via SREGS) before it can apply LAPIC register state.
pub fn setLapic(self: Self, lapic: *const c.kvm_lapic_state) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_LAPIC, @intFromPtr(lapic));
}

pub fn getXcrs(self: Self) !c.kvm_xcrs {
    var xcrs: c.kvm_xcrs = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_XCRS, @intFromPtr(&xcrs));
    return xcrs;
}

pub fn setXcrs(self: Self, xcrs: *const c.kvm_xcrs) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_XCRS, @intFromPtr(xcrs));
}

/// MSR buffer layout matches kvm_msrs: nmsrs:u32 + pad:u32 + entries[].
/// KVM limits the number of MSRs per ioctl call so we use a fixed buffer.
pub const MAX_MSR_ENTRIES = 32;
pub const MsrBuffer = extern struct {
    nmsrs: u32,
    pad: u32 = 0,
    entries: [MAX_MSR_ENTRIES]c.kvm_msr_entry,
};

/// The MSR indices we save/restore. Must include all MSRs that the guest
/// kernel programs during boot — missing any causes hangs on restore.
/// MSR_IA32_TSC (0x10) must appear before MSR_IA32_TSC_DEADLINE (0x6E0)
/// in the restore buffer because the deadline is relative to TSC.
pub const snapshot_msr_indices = [_]u32{
    0x10, // MSR_IA32_TSC — must be first (TSC_DEADLINE depends on it)
    0x1B, // MSR_IA32_APICBASE
    0x3B, // MSR_IA32_TSC_ADJUST
    0x174, // MSR_IA32_SYSENTER_CS
    0x175, // MSR_IA32_SYSENTER_ESP
    0x176, // MSR_IA32_SYSENTER_EIP
    0x1A0, // MSR_IA32_MISC_ENABLE
    0x277, // MSR_IA32_CR_PAT
    0x6E0, // MSR_IA32_TSC_DEADLINE — must be after TSC
    // KVM paravirt clock — critical for guest timekeeping after restore
    0x4b564d00, // MSR_KVM_WALL_CLOCK_NEW
    0x4b564d01, // MSR_KVM_SYSTEM_TIME_NEW
    0x4b564d02, // MSR_KVM_ASYNC_PF_EN
    0x4b564d03, // MSR_KVM_STEAL_TIME
    0x4b564d04, // MSR_KVM_PV_EOI_EN
    // Syscall entry points
    0xC0000081, // MSR_STAR
    0xC0000082, // MSR_LSTAR
    0xC0000083, // MSR_CSTAR
    0xC0000084, // MSR_SYSCALL_MASK
    0xC0000102, // MSR_KERNEL_GS_BASE
};

/// Populate buffer with MSR indices and read their current values.
pub fn getMsrs(self: Self, buf: *MsrBuffer) !void {
    buf.nmsrs = snapshot_msr_indices.len;
    buf.pad = 0;
    for (snapshot_msr_indices, 0..) |idx, i| {
        buf.entries[i] = .{ .index = idx, .reserved = 0, .data = 0 };
    }
    try abi.ioctlVoid(self.fd, c.KVM_GET_MSRS, @intFromPtr(buf));
}

pub fn setMsrs(self: Self, buf: *const MsrBuffer) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_MSRS, @intFromPtr(buf));
}

/// Notify KVM that the guest was paused (prevents soft lockup watchdog
/// false positives on resume). Non-fatal if the guest doesn't support kvmclock.
pub fn kvmclockCtrl(self: Self) !void {
    try abi.ioctlVoid(self.fd, 0xAED5, 0); // KVM_KVMCLOCK_CTRL
}

pub const IoExit = struct {
    direction: u8,
    port: u16,
    size: u8,
    count: u32,
    data: [*]u8,
};

/// Get the MMIO exit data (valid when exit_reason == KVM_EXIT_MMIO).
pub fn getMmioData(self: Self) MmioExit {
    const mmio = self.kvm_run.unnamed_0.mmio;
    return .{
        .phys_addr = mmio.phys_addr,
        .data = mmio.data,
        .len = mmio.len,
        .is_write = mmio.is_write != 0,
    };
}

pub const MmioExit = struct {
    phys_addr: u64,
    data: [8]u8,
    len: u32,
    is_write: bool,
};
