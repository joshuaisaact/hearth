// Vm: wraps the KVM VM fd.
// Provides VM-level operations: memory regions, vCPU creation, IRQ chip, PIT.

const std = @import("std");
const abi = @import("abi.zig");
const c = abi.c;
const Vcpu = @import("vcpu.zig");

const log = std.log.scoped(.vm);

const Self = @This();

fd: std.posix.fd_t,

pub fn create(kvm_fd: std.posix.fd_t) !Self {
    const fd: i32 = @intCast(try abi.ioctl(kvm_fd, c.KVM_CREATE_VM, 0));
    log.info("VM created (fd={})", .{fd});
    return .{ .fd = fd };
}

pub fn deinit(self: Self) void {
    abi.close(self.fd);
}

/// Register a guest physical memory region backed by host memory.
pub fn setMemoryRegion(self: Self, slot: u32, guest_phys_addr: u64, memory: []align(std.heap.page_size_min) u8) !void {
    var region = c.kvm_userspace_memory_region{
        .slot = slot,
        .flags = 0,
        .guest_phys_addr = guest_phys_addr,
        .memory_size = memory.len,
        .userspace_addr = @intFromPtr(memory.ptr),
    };
    try abi.ioctlVoid(self.fd, c.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&region));
    log.info("memory region: slot={} guest=0x{x} size=0x{x}", .{ slot, guest_phys_addr, memory.len });
}

/// Create a vCPU with the given ID.
pub fn createVcpu(self: Self, vcpu_id: u32, vcpu_mmap_size: usize) !Vcpu {
    return Vcpu.create(self.fd, vcpu_id, vcpu_mmap_size);
}

/// Set TSS address (required on Intel before running vCPUs).
pub fn setTssAddr(self: Self, addr: u32) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_TSS_ADDR, addr);
}

/// Set identity map address (required on Intel).
pub fn setIdentityMapAddr(self: Self, addr: u64) !void {
    var a = addr;
    try abi.ioctlVoid(self.fd, c.KVM_SET_IDENTITY_MAP_ADDR, @intFromPtr(&a));
}

/// Create the in-kernel IRQ chip (PIC + IOAPIC).
pub fn createIrqChip(self: Self) !void {
    try abi.ioctlVoid(self.fd, c.KVM_CREATE_IRQCHIP, 0);
    log.info("in-kernel IRQ chip created", .{});
}

/// Create the in-kernel PIT (i8254 timer).
pub fn createPit2(self: Self) !void {
    var pit_config = std.mem.zeroes(c.kvm_pit_config);
    pit_config.flags = c.KVM_PIT_SPEAKER_DUMMY;
    try abi.ioctlVoid(self.fd, c.KVM_CREATE_PIT2, @intFromPtr(&pit_config));
    log.info("in-kernel PIT created", .{});
}

// --- Snapshot state accessors ---
// These read/write the in-kernel interrupt controller and timer state.
// The devices must be created (createIrqChip/createPit2) before SET
// calls — SET overwrites state on an existing device, it doesn't create one.

/// kvm_irqchip contains a union that Zig's cImport can't represent (opaque),
/// so we use raw bytes and hardcoded ioctl numbers. The struct is 520 bytes
/// on x86_64: chip_id(u32) + pad(u32) + union(512, largest = kvm_ioapic_state).
pub const IRQCHIP_SIZE = 520;
// ioctl numbers encode struct size, so we can't use c.KVM_GET/SET_IRQCHIP
const KVM_GET_IRQCHIP: u32 = 0xc208ae62;
const KVM_SET_IRQCHIP: u32 = 0x8208ae63;

/// KVM_IRQCHIP_PIC_MASTER=0, KVM_IRQCHIP_PIC_SLAVE=1, KVM_IRQCHIP_IOAPIC=2.
pub fn getIrqChip(self: Self, chip_id: u32) ![IRQCHIP_SIZE]u8 {
    var buf: [IRQCHIP_SIZE]u8 = undefined;
    // chip_id is the first u32 field
    std.mem.writeInt(u32, buf[0..4], chip_id, .little);
    try abi.ioctlVoid(self.fd, KVM_GET_IRQCHIP, @intFromPtr(&buf));
    return buf;
}

pub fn setIrqChip(self: Self, buf: *const [IRQCHIP_SIZE]u8) !void {
    try abi.ioctlVoid(self.fd, KVM_SET_IRQCHIP, @intFromPtr(buf));
}

pub fn getPit2(self: Self) !c.kvm_pit_state2 {
    var pit: c.kvm_pit_state2 = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_PIT2, @intFromPtr(&pit));
    return pit;
}

pub fn setPit2(self: Self, pit: *const c.kvm_pit_state2) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_PIT2, @intFromPtr(pit));
}

pub fn getClock(self: Self) !c.kvm_clock_data {
    var clock: c.kvm_clock_data = undefined;
    try abi.ioctlVoid(self.fd, c.KVM_GET_CLOCK, @intFromPtr(&clock));
    return clock;
}

pub fn setClock(self: Self, clock: *const c.kvm_clock_data) !void {
    try abi.ioctlVoid(self.fd, c.KVM_SET_CLOCK, @intFromPtr(clock));
}

/// Inject an IRQ line level change.
pub fn setIrqLine(self: Self, irq: u32, level: u32) !void {
    var irq_level: c.kvm_irq_level = .{};
    irq_level.unnamed_0.irq = irq;
    irq_level.level = level;
    try abi.ioctlVoid(self.fd, c.KVM_IRQ_LINE, @intFromPtr(&irq_level));
}
