// VM snapshot save/restore orchestrator.
// Writes complete VM state (vCPU registers, interrupt controllers, device
// state) to a binary vmstate file and guest memory to a raw memory file.
// On restore, memory is mmap'd with MAP_PRIVATE for demand-paging —
// the kernel loads pages lazily via faults, giving ~5ms restore times
// regardless of VM size.

const std = @import("std");
const linux = std.os.linux;
const Vcpu = @import("kvm/vcpu.zig");
const Vm = @import("kvm/vm.zig");
const Kvm = @import("kvm/system.zig");
const Memory = @import("memory.zig");
const Serial = @import("devices/serial.zig");
const VirtioMmio = @import("devices/virtio/mmio.zig");
const virtio = @import("devices/virtio.zig");
const abi = @import("kvm/abi.zig");
const c = abi.c;

const log = std.log.scoped(.snapshot);

const MAGIC = "FLINTSNP".*;
const FORMAT_VERSION: u32 = 2; // v2: added debug_regs, dynamic MSR list

// Manually serialized to avoid alignment padding issues with extern/packed structs.
// Layout: magic(8) + mem_size(8) + version(4) + device_count(4) + reserved(8) = 32 bytes
pub const HEADER_SIZE = 32;

pub fn writeHeader(buf: *[HEADER_SIZE]u8, mem_size: u64, device_count: u32) void {
    @memcpy(buf[0..8], &MAGIC);
    std.mem.writeInt(u64, buf[8..16], mem_size, .little);
    std.mem.writeInt(u32, buf[16..20], FORMAT_VERSION, .little);
    std.mem.writeInt(u32, buf[20..24], device_count, .little);
    @memset(buf[24..32], 0);
}

const HeaderData = struct {
    mem_size: u64,
    version: u32,
    device_count: u32,
};

pub fn readHeader(buf: [HEADER_SIZE]u8) !HeaderData {
    if (!std.mem.eql(u8, buf[0..8], &MAGIC)) {
        log.warn("invalid snapshot magic", .{});
        return error.InvalidSnapshot;
    }
    const version = std.mem.readInt(u32, buf[16..20], .little);
    if (version != FORMAT_VERSION) {
        log.warn("unsupported snapshot version: {} (expected {})", .{ version, FORMAT_VERSION });
        return error.InvalidSnapshot;
    }
    const mem_size = std.mem.readInt(u64, buf[8..16], .little);
    // Reject unreasonable mem_size to prevent excessive mmap from crafted snapshots
    const MAX_MEM_BYTES: u64 = 16384 * 1024 * 1024; // 16384 MiB, matches API validation
    if (mem_size > MAX_MEM_BYTES) {
        log.warn("snapshot mem_size {} exceeds maximum {}", .{ mem_size, MAX_MEM_BYTES });
        return error.InvalidSnapshot;
    }
    return .{
        .mem_size = mem_size,
        .version = version,
        .device_count = std.mem.readInt(u32, buf[20..24], .little),
    };
}

const DeviceArray = [virtio.MAX_DEVICES]?VirtioMmio;

// Large enough for any single device snapshot (transport + queues + backend)
const DEVICE_BUF_SIZE = 512;

/// Save complete VM state to two files.
/// The vCPU must be stopped (not in KVM_RUN) before calling this.
pub fn save(
    vmstate_path: [*:0]const u8,
    mem_path: [*:0]const u8,
    vcpu: *Vcpu,
    vm: *const Vm,
    mem: *const Memory,
    serial: *const Serial,
    devices: *const DeviceArray,
    device_count: u32,
) !void {
    log.info("saving snapshot...", .{});

    // --- Save vmstate ---
    const state_fd = try openCreate(vmstate_path);
    defer _ = linux.close(state_fd);

    // Header
    var header_buf: [HEADER_SIZE]u8 = undefined;
    writeHeader(&header_buf, mem.size(), device_count);
    try writeAll(state_fd, &header_buf);

    // vCPU state — save order matters (see PLAN-snapshot.md)
    // MP_STATE first: flushes pending APIC events inside KVM
    const mp_state = try vcpu.getMpState();
    try writeAll(state_fd, std.mem.asBytes(&mp_state));

    const regs = try vcpu.getRegs();
    try writeAll(state_fd, std.mem.asBytes(&regs));

    const sregs = try vcpu.getSregs();
    try writeAll(state_fd, std.mem.asBytes(&sregs));

    const xcrs = try vcpu.getXcrs();
    try writeAll(state_fd, std.mem.asBytes(&xcrs));

    const xsave = try vcpu.getXsave();
    try writeAll(state_fd, std.mem.asBytes(&xsave));

    const lapic = try vcpu.getLapic();
    try writeAll(state_fd, std.mem.asBytes(&lapic));

    var cpuid: Kvm.CpuidBuffer = undefined;
    try vcpu.getCpuid(&cpuid);
    try writeAll(state_fd, std.mem.asBytes(&cpuid));

    var msrs: Vcpu.MsrBuffer = undefined;
    try vcpu.getMsrs(&msrs);
    try writeAll(state_fd, std.mem.asBytes(&msrs));

    // vcpu_events last: contains pending exceptions that other GETs might affect
    const events = try vcpu.getVcpuEvents();
    try writeAll(state_fd, std.mem.asBytes(&events));

    // VM state — interrupt controllers and timers
    for (0..3) |chip_id| {
        const chip = try vm.getIrqChip(@intCast(chip_id));
        try writeAll(state_fd, &chip);
    }

    const pit = try vm.getPit2();
    try writeAll(state_fd, std.mem.asBytes(&pit));

    var clock = try vm.getClock();
    // Clear TSC_STABLE flag — KVM rejects it on restore
    clock.flags &= ~@as(u32, 2); // KVM_CLOCK_TSC_STABLE = 2
    try writeAll(state_fd, std.mem.asBytes(&clock));

    // Device state — all slots 0..device_count must be non-null.
    // The header encodes device_count and restore reads exactly that many blobs.
    for (devices[0..device_count]) |*dev_opt| {
        std.debug.assert(dev_opt.* != null);
        if (dev_opt.*) |*dev| {
            var dev_buf: [DEVICE_BUF_SIZE]u8 = undefined;
            const dev_len = dev.snapshotSave(&dev_buf);
            // Write length prefix so restore knows how much to read
            var len_buf: [4]u8 = undefined;
            std.mem.writeInt(u32, &len_buf, @intCast(dev_len), .little);
            try writeAll(state_fd, &len_buf);
            try writeAll(state_fd, dev_buf[0..dev_len]);
        }
    }

    // Serial state
    const serial_data = serial.snapshotSave();
    try writeAll(state_fd, &serial_data);

    // --- Save guest memory ---
    const mem_fd = try openCreate(mem_path);
    defer _ = linux.close(mem_fd);
    try writeAll(mem_fd, mem.mem);

    log.info("snapshot saved: vmstate + {} MB memory", .{mem.size() / (1024 * 1024)});
}

/// Restore VM state from snapshot files.
/// Memory must already be registered with KVM (Firecracker restore order).
/// Returns the restored Memory (mmap'd from file, demand-paged).
pub fn load(
    vmstate_path: [*:0]const u8,
    mem_path: [*:0]const u8,
    vcpu: *Vcpu,
    vm: *const Vm,
    serial: *Serial,
    devices: *DeviceArray,
    device_count: *u32,
) !Memory {
    log.info("loading snapshot...", .{});

    // --- Read vmstate ---
    const state_fd = try openRead(vmstate_path);
    defer _ = linux.close(state_fd);

    // Header
    var header_buf: [HEADER_SIZE]u8 = undefined;
    try readExact(state_fd, &header_buf);
    const header = try readHeader(header_buf);

    // --- Restore guest memory via demand-paged mmap ---
    // Register with KVM immediately — Firecracker sets memory BEFORE vCPU state
    // because LAPIC/MSR state restoration may reference guest memory addresses.
    var mem = try Memory.initFromFile(mem_path, header.mem_size);
    errdefer mem.deinit();
    try vm.setMemoryRegion(0, 0, mem.alignedMem());

    // --- Restore vCPU state FIRST (matches Firecracker's order) ---

    var mp_state: c.kvm_mp_state = undefined;
    try readExact(state_fd, std.mem.asBytes(&mp_state));

    var regs: c.kvm_regs = undefined;
    try readExact(state_fd, std.mem.asBytes(&regs));

    var sregs: c.kvm_sregs = undefined;
    try readExact(state_fd, std.mem.asBytes(&sregs));

    var xcrs: c.kvm_xcrs = undefined;
    try readExact(state_fd, std.mem.asBytes(&xcrs));

    var xsave: c.kvm_xsave = undefined;
    try readExact(state_fd, std.mem.asBytes(&xsave));

    var lapic: c.kvm_lapic_state = undefined;
    try readExact(state_fd, std.mem.asBytes(&lapic));

    var cpuid: Kvm.CpuidBuffer = undefined;
    try readExact(state_fd, std.mem.asBytes(&cpuid));
    if (cpuid.nent > Kvm.MAX_CPUID_ENTRIES) return error.InvalidSnapshot;

    var msrs: Vcpu.MsrBuffer = undefined;
    try readExact(state_fd, std.mem.asBytes(&msrs));
    if (msrs.nmsrs > Vcpu.MAX_MSR_ENTRIES) return error.InvalidSnapshot;

    var events: c.kvm_vcpu_events = undefined;
    try readExact(state_fd, std.mem.asBytes(&events));

    // --- Restore vCPU state FIRST (matches Firecracker's order) ---
    // Memory region must be registered by the caller BEFORE this function.
    // Order matches Firecracker: CPUID → mp_state → regs → sregs → xsave → xcrs → LAPIC → MSRs → debug_regs → events
    try vcpu.setCpuid(&cpuid);
    try vcpu.setMpState(&mp_state);
    try vcpu.setRegs(&regs);
    try vcpu.setSregs(&sregs);
    try vcpu.setXsave(&xsave);
    try vcpu.setXcrs(&xcrs);
    try vcpu.setLapic(&lapic);
    try vcpu.setMsrs(&msrs);
    try vcpu.setVcpuEvents(&events);

    // KVM_KVMCLOCK_CTRL: notify the host that the guest was paused.
    // Prevents soft lockup watchdog false positives on resume.
    // Errors are non-fatal (guest may not support kvmclock).
    vcpu.kvmclockCtrl() catch |err| {
        log.warn("KVM_KVMCLOCK_CTRL failed (non-fatal): {}", .{err});
    };

    // --- Read VM state from file (in file order: irqchip, PIT, clock) ---
    var irqchips: [3][Vm.IRQCHIP_SIZE]u8 = undefined;
    for (0..3) |chip_id| {
        try readExact(state_fd, &irqchips[chip_id]);
        std.mem.writeInt(u32, irqchips[chip_id][0..4], @intCast(chip_id), .little);
    }

    var pit: c.kvm_pit_state2 = undefined;
    try readExact(state_fd, std.mem.asBytes(&pit));
    // Do NOT modify pit.flags — KVM_PIT_SPEAKER_DUMMY (0x1) has the same
    // value as KVM_PIT_FLAGS_HPET_LEGACY, which disables the PIT timer entirely.

    var clock: c.kvm_clock_data = undefined;
    try readExact(state_fd, std.mem.asBytes(&clock));

    // --- Apply VM state (Firecracker order: PIT, clock, irqchip) ---
    // This must come AFTER vCPU state so injected interrupts from
    // irqchip restore aren't overwritten by vCPU state restore.
    try vm.setPit2(&pit);
    try vm.setClock(&clock);
    for (0..3) |i| {
        try vm.setIrqChip(&irqchips[i]);
    }

    // --- Restore devices ---
    if (header.device_count > virtio.MAX_DEVICES) {
        log.warn("snapshot has {} devices, max is {}", .{ header.device_count, virtio.MAX_DEVICES });
        return error.InvalidSnapshot;
    }
    device_count.* = header.device_count;
    for (0..header.device_count) |i| {
        var len_buf: [4]u8 = undefined;
        try readExact(state_fd, &len_buf);
        const dev_len = std.mem.readInt(u32, &len_buf, .little);

        var dev_buf: [DEVICE_BUF_SIZE]u8 = undefined;
        // Minimum: identity(16) + transport(29) + 3*queue(31) + smallest backend(6) = 144
        if (dev_len < 144 or dev_len > DEVICE_BUF_SIZE) return error.InvalidSnapshot;
        try readExact(state_fd, dev_buf[0..dev_len]);

        // Read device identity from the saved data
        const dev_type = std.mem.readInt(u32, dev_buf[0..4], .little);
        const mmio_base = std.mem.readInt(u64, dev_buf[4..12], .little);
        const irq = std.mem.readInt(u32, dev_buf[12..16], .little);

        // Caller must have re-created device backends (via CLI --disk/--tap/--vsock-*)
        // before calling load(). We apply the saved transport/queue state on top.
        if (devices[i]) |*dev| {
            if (dev.device_id != dev_type) {
                log.err("device type mismatch at slot {}: snapshot has {} but backend is {}", .{ i, dev_type, dev.device_id });
                return error.InvalidSnapshot;
            }
            const consumed = dev.snapshotRestore(dev_buf[0..dev_len]);
            if (consumed != dev_len) {
                log.warn("device {} consumed {} bytes but dev_len is {}", .{ i, consumed, dev_len });
            }
            log.info("restore: device type {} at 0x{x} IRQ {}", .{ dev_type, mmio_base, irq });
        } else {
            log.err("snapshot has device type {} at slot {} but no backend was provided", .{ dev_type, i });
            return error.InvalidSnapshot;
        }
    }

    // --- Restore serial ---
    var serial_data: [Serial.SNAPSHOT_SIZE]u8 = undefined;
    try readExact(state_fd, &serial_data);
    serial.snapshotRestore(serial_data);

    log.info("restore complete (pit.flags={})", .{pit.flags});

    log.info("snapshot loaded: {} MB memory (demand-paged), {} devices", .{
        header.mem_size / (1024 * 1024),
        header.device_count,
    });

    return mem;
}

// --- File I/O helpers (raw linux syscalls, consistent with rest of codebase) ---

fn openCreate(path: [*:0]const u8) !i32 {
    const rc: isize = @bitCast(linux.open(path, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, 0o600)); // 0600: snapshots may contain guest secrets
    if (rc < 0) return error.SnapshotOpenFailed;
    return @intCast(rc);
}

fn openRead(path: [*:0]const u8) !i32 {
    const rc: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (rc < 0) return error.SnapshotOpenFailed;
    return @intCast(rc);
}

fn writeAll(fd: i32, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc: isize = @bitCast(linux.write(fd, data[written..].ptr, data.len - written));
        if (rc <= 0) return error.SnapshotWriteFailed;
        written += @intCast(rc);
    }
}

fn readExact(fd: i32, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[total..].ptr, buf.len - total));
        if (rc <= 0) return error.SnapshotReadFailed;
        total += @intCast(rc);
    }
}
