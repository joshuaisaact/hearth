// 16550 UART serial port emulation.
// Emulates COM1 at IO port 0x3F8, enough to capture kernel boot output.

const std = @import("std");

const log = std.log.scoped(.serial);

const Self = @This();

pub const COM1_PORT: u16 = 0x3F8;
pub const PORT_COUNT: u16 = 8;
pub const IRQ: u32 = 4;

// Register offsets from base port
const THR = 0; // Transmit Holding Register (write)
const RBR = 0; // Receive Buffer Register (read)
const IER = 1; // Interrupt Enable Register
const IIR = 2; // Interrupt Identification Register (read)
const FCR = 2; // FIFO Control Register (write)
const LCR = 3; // Line Control Register
const MCR = 4; // Modem Control Register
const LSR = 5; // Line Status Register
const MSR = 6; // Modem Status Register
const SCR = 7; // Scratch Register

// LSR bits
const LSR_DR = 0x01; // Data Ready
const LSR_THRE = 0x20; // Transmitter Holding Register Empty
const LSR_TEMT = 0x40; // Transmitter Empty

// MSR bits
const MSR_DCD = 0x80; // Data Carrier Detect
const MSR_DSR = 0x20; // Data Set Ready
const MSR_CTS = 0x10; // Clear to Send

// IER bits
const IER_RDA = 0x01; // Received Data Available
const IER_THRE = 0x02; // Transmitter Holding Register Empty

// IIR bits
const IIR_NO_INT = 0x01; // No interrupt pending
const IIR_THR_EMPTY = 0x02; // THR empty (priority 3)

// LCR bits
const LCR_DLAB = 0x80; // Divisor Latch Access Bit

ier: u8 = 0,
iir: u8 = IIR_NO_INT,
lcr: u8 = 0,
mcr: u8 = 0,
lsr: u8 = LSR_THRE | LSR_TEMT,
msr: u8 = MSR_DCD | MSR_DSR | MSR_CTS,
scr: u8 = 0,
dll: u8 = 0, // Divisor Latch Low (when DLAB=1)
dlh: u8 = 0, // Divisor Latch High (when DLAB=1)

output_fd: std.posix.fd_t,
irq_pending: bool = false,

pub fn init(output_fd: std.posix.fd_t) Self {
    return .{ .output_fd = output_fd };
}

/// Returns true if an IRQ should be raised (call after handleIo).
pub fn hasPendingIrq(self: *Self) bool {
    if (self.irq_pending) {
        self.irq_pending = false;
        return true;
    }
    return false;
}

// --- Snapshot support ---
// The serial device has no external fd state to reopen — the output_fd is
// always stdout (fd 1) and is passed fresh on restore. We only persist
// the register file that the guest driver has configured.
pub const SNAPSHOT_SIZE = 10;

pub fn snapshotSave(self: *const Self) [SNAPSHOT_SIZE]u8 {
    return .{ self.ier, self.iir, self.lcr, self.mcr, self.lsr, self.msr, self.scr, self.dll, self.dlh, @intFromBool(self.irq_pending) };
}

pub fn snapshotRestore(self: *Self, data: [SNAPSHOT_SIZE]u8) void {
    self.ier = data[0];
    self.iir = data[1];
    self.lcr = data[2];
    self.mcr = data[3];
    self.lsr = data[4];
    self.msr = data[5];
    self.scr = data[6];
    self.dll = data[7];
    self.dlh = data[8];
    self.irq_pending = data[9] != 0;
}

pub fn handleIo(self: *Self, port: u16, data: []u8, is_write: bool) void {
    const offset = port - COM1_PORT;

    if (is_write) {
        self.writeReg(offset, data[0]);
    } else {
        data[0] = self.readReg(offset);
    }
}

pub fn handleIoWrite(self: *Self, port: u16, data: []const u8) void {
    self.writeReg(port - COM1_PORT, data[0]);
}

pub fn handleIoRead(self: *Self, port: u16, data: []u8) void {
    data[0] = self.readReg(port - COM1_PORT);
}

fn writeReg(self: *Self, offset: u16, value: u8) void {
    if (self.lcr & LCR_DLAB != 0 and offset <= 1) {
        switch (offset) {
            0 => self.dll = value,
            1 => self.dlh = value,
            else => {},
        }
        return;
    }

    switch (offset) {
        THR => {
            // Write character to output
            const buf = [1]u8{value};
            if (self.output_fd >= 0) {
                const rc: isize = @bitCast(std.os.linux.write(self.output_fd, &buf, 1));
                if (rc < 0) log.warn("serial write failed", .{});
            }
            // If THRE interrupt enabled, signal TX complete
            if (self.ier & IER_THRE != 0) {
                self.iir = (self.iir & 0xF0) | IIR_THR_EMPTY;
                self.irq_pending = true;
            }
        },
        IER => {
            self.ier = value & 0x0F;
            self.updateIir();
        },
        FCR => self.iir = (self.iir & 0x0F) | 0xC0, // FIFO enabled bits in IIR
        LCR => self.lcr = value,
        MCR => self.mcr = value,
        MSR => {}, // MSR is read-only in real hardware
        SCR => self.scr = value,
        else => log.warn("unhandled serial write: offset={} value=0x{x}", .{ offset, value }),
    }
}

fn updateIir(self: *Self) void {
    const fifo_bits = self.iir & 0xC0;
    if (self.ier & IER_THRE != 0) {
        self.iir = fifo_bits | IIR_THR_EMPTY;
        self.irq_pending = true;
    } else {
        self.iir = fifo_bits | IIR_NO_INT;
    }
}

fn readReg(self: *Self, offset: u16) u8 {
    if (self.lcr & LCR_DLAB != 0 and offset <= 1) {
        return switch (offset) {
            0 => self.dll,
            1 => self.dlh,
            else => 0,
        };
    }

    return switch (offset) {
        RBR => 0, // No input for now
        IER => self.ier,
        IIR => blk: {
            const val = self.iir;
            // Reading IIR clears THR empty interrupt
            if (val & 0x0F == IIR_THR_EMPTY) {
                self.iir = (self.iir & 0xF0) | IIR_NO_INT;
            }
            break :blk val;
        },
        LCR => self.lcr,
        MCR => self.mcr,
        LSR => self.lsr,
        MSR => self.msr,
        SCR => self.scr,
        else => blk: {
            log.warn("unhandled serial read: offset={}", .{offset});
            break :blk 0;
        },
    };
}
