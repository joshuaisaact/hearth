// Linux kernel loader.
// Loads a bzImage into guest memory following the x86 Linux boot protocol.

const std = @import("std");
const params = @import("params.zig");
const Memory = @import("../memory.zig");

const log = std.log.scoped(.loader);
const linux = std.os.linux;

pub const LoadResult = struct {
    /// Entry point (guest physical address of protected-mode kernel).
    entry_addr: u64,
    /// Where boot_params is in guest memory.
    boot_params_addr: u64,
    /// Whether to add STARTUP_64_OFFSET to entry_addr.
    /// bzImage needs it (entry is start of protected-mode code).
    /// ELF kernels already point to the 64-bit entry.
    needs_startup_offset: bool = true,
};

/// Read an entire file into memory using linux syscalls.
/// Caller owns the returned slice and must free it with page_allocator.
fn readFile(path: [*:0]const u8) ![]u8 {
    const open_rc: isize = @bitCast(linux.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (open_rc < 0) return error.OpenFailed;
    const fd: i32 = @intCast(open_rc);
    defer _ = linux.close(fd);

    // Get file size via statx
    var stx: linux.Statx = undefined;
    const stat_rc = linux.statx(fd, "", @as(u32, linux.AT.EMPTY_PATH), .{}, &stx);
    const stat_signed: isize = @bitCast(stat_rc);
    if (stat_signed < 0) return error.StatFailed;
    const file_size: usize = @intCast(stx.size);

    const buf = try std.heap.page_allocator.alloc(u8, file_size);
    errdefer std.heap.page_allocator.free(buf);

    var total: usize = 0;
    while (total < file_size) {
        const rc: isize = @bitCast(linux.read(fd, buf.ptr + total, file_size - total));
        if (rc > 0) {
            total += @intCast(rc);
        } else if (rc == 0) {
            return error.UnexpectedEof;
        } else {
            const errno: linux.E = @enumFromInt(@as(u16, @intCast(-rc)));
            if (errno == .INTR) continue;
            return error.ReadFailed;
        }
    }

    return buf;
}

/// Load a Linux kernel from disk into guest memory, with an optional initrd.
/// Supports both bzImage and raw vmlinux (ELF) formats — auto-detected.
pub fn loadBzImage(mem: *Memory, kernel_path: [*:0]const u8, initrd_path: ?[*:0]const u8, cmdline_ptr: [*:0]const u8) !LoadResult {
    const cmdline = cmdline_ptr[0..std.mem.indexOfSentinel(u8, 0, cmdline_ptr)];
    const kernel_data = try readFile(kernel_path);
    defer std.heap.page_allocator.free(kernel_data);

    // Detect format: ELF magic (\x7FELF) or bzImage setup header
    if (kernel_data.len >= 4 and std.mem.eql(u8, kernel_data[0..4], "\x7FELF")) {
        return loadElfKernel(mem, kernel_data, initrd_path, cmdline);
    }

    if (kernel_data.len < params.OFF_SETUP_HEADER + @sizeOf(params.SetupHeader)) {
        return error.KernelTooSmall;
    }

    // Parse the setup header at offset 0x1F1 (unaligned, so we copy it out)
    var hdr: params.SetupHeader = undefined;
    const hdr_src = kernel_data[params.OFF_SETUP_HEADER..][0..@sizeOf(params.SetupHeader)];
    @memcpy(std.mem.asBytes(&hdr), hdr_src);

    if (hdr.header != params.HDRS_MAGIC) {
        log.err("invalid kernel: not an ELF and missing bzImage HdrS magic (got 0x{x})", .{hdr.header});
        return error.InvalidKernel;
    }

    log.info("boot protocol version: {}.{}", .{ hdr.version >> 8, hdr.version & 0xFF });

    if (hdr.version < 0x0200) {
        log.err("boot protocol version too old: 0x{x}", .{hdr.version});
        return error.UnsupportedProtocol;
    }

    // Number of 512-byte setup sectors (0 means 4)
    const setup_sects: u32 = if (hdr.setup_sects == 0) 4 else hdr.setup_sects;
    const setup_size = (setup_sects + 1) * 512; // +1 for the boot sector
    const kernel_offset: usize = setup_size;

    // Validate setup_sects doesn't exceed the file
    if (kernel_offset >= kernel_data.len) {
        log.err("setup_sects={} implies offset {} but file is only {} bytes", .{ setup_sects, kernel_offset, kernel_data.len });
        return error.InvalidKernel;
    }

    const kernel_size = kernel_data.len - kernel_offset;
    log.info("setup sectors: {}, kernel size: {} bytes", .{ setup_sects, kernel_size });

    if (hdr.loadflags & params.LOADED_HIGH == 0) {
        log.err("kernel does not support loading high", .{});
        return error.UnsupportedKernel;
    }

    // Validate 64-bit entry support (protocol >= 2.06 has xloadflags)
    if (hdr.version >= 0x0206) {
        if (hdr.xloadflags & params.XLF_KERNEL_64 == 0) {
            log.err("kernel does not support 64-bit handoff (xloadflags=0x{x})", .{hdr.xloadflags});
            return error.UnsupportedKernel;
        }
    }

    // Copy protected-mode kernel code to 1MB
    try mem.write(params.KERNEL_ADDR, kernel_data[kernel_offset..]);
    log.info("kernel loaded at guest 0x{x} ({} bytes)", .{ params.KERNEL_ADDR, kernel_size });

    // Copy command line
    if (cmdline.len > 0) {
        try mem.write(params.CMDLINE_ADDR, cmdline);
        // Null-terminate
        const term = try mem.slice(params.CMDLINE_ADDR + cmdline.len, 1);
        term[0] = 0;
    }

    // Set up boot_params (zero page) -- work with a slice starting at BOOT_PARAMS_ADDR
    const bp = try mem.slice(params.BOOT_PARAMS_ADDR, params.BOOT_PARAMS_SIZE);
    @memset(bp, 0);

    // Copy the ENTIRE setup header from the kernel image into boot_params.
    // The setup header extends from offset 0x1F1 well beyond our SetupHeader struct
    // (the kernel reads fields up to at least 0x264, e.g. init_size).
    const raw_hdr_max = @min(setup_size, params.BOOT_PARAMS_SIZE) - params.OFF_SETUP_HEADER;
    const src_hdr = kernel_data[params.OFF_SETUP_HEADER..][0..raw_hdr_max];
    @memcpy(bp[params.OFF_SETUP_HEADER..][0..raw_hdr_max], src_hdr);

    // Patch the specific fields we need to override
    bp[params.OFF_TYPE_OF_LOADER] = 0xFF;
    bp[params.OFF_LOADFLAGS] |= params.CAN_USE_HEAP;
    std.mem.writeInt(u16, bp[params.OFF_HEAP_END_PTR..][0..2], 0xFE00, .little);
    std.mem.writeInt(u32, bp[params.OFF_CMD_LINE_PTR..][0..4], params.CMDLINE_ADDR, .little);

    // Load initrd if provided
    if (initrd_path) |path| {
        try loadInitrd(bp, mem, path, kernel_size);
    }

    // Set up e820 memory map
    setupE820(bp, mem.size());

    log.info("boot_params at guest 0x{x}, cmdline at 0x{x}", .{
        params.BOOT_PARAMS_ADDR, params.CMDLINE_ADDR,
    });

    return .{
        .entry_addr = params.KERNEL_ADDR,
        .boot_params_addr = params.BOOT_PARAMS_ADDR,
    };
}

fn loadInitrd(bp: []u8, mem: *Memory, path: [*:0]const u8, kernel_size: usize) !void {
    const initrd_data = try readFile(path);
    defer std.heap.page_allocator.free(initrd_data);

    if (initrd_data.len == 0) return error.EmptyInitrd;

    // Place initrd at end of RAM, page-aligned down.
    // Respect initrd_addr_max from the kernel header.
    const initrd_max = std.mem.readInt(u32, bp[params.OFF_INITRD_ADDR_MAX..][0..4], .little);
    const mem_top = mem.size();
    const top = if (initrd_max > 0 and initrd_max < mem_top) initrd_max else mem_top;

    if (initrd_data.len > top) {
        log.err("initrd ({} bytes) larger than available memory ({})", .{ initrd_data.len, top });
        return error.InitrdTooLarge;
    }

    const initrd_addr = (top - initrd_data.len) & ~@as(usize, 0xFFF); // page-align down

    if (initrd_addr < params.KERNEL_ADDR + kernel_size) {
        log.err("initrd too large: needs 0x{x} but only 0x{x} available", .{
            initrd_data.len, top - (params.KERNEL_ADDR + kernel_size),
        });
        return error.InitrdTooLarge;
    }

    try mem.write(initrd_addr, initrd_data);

    std.mem.writeInt(u32, bp[params.OFF_RAMDISK_IMAGE..][0..4], @intCast(initrd_addr), .little);
    std.mem.writeInt(u32, bp[params.OFF_RAMDISK_SIZE..][0..4], @intCast(initrd_data.len), .little);

    log.info("initrd loaded at guest 0x{x} ({} bytes)", .{ initrd_addr, initrd_data.len });
}

/// Load a raw vmlinux ELF kernel into guest memory.
/// This is the format used by Firecracker CI kernels (built with CONFIG_VIRTIO=y).
/// The ELF file contains PT_LOAD segments that map to guest physical addresses.
fn loadElfKernel(mem: *Memory, kernel_data: []const u8, initrd_path: ?[*:0]const u8, cmdline: []const u8) !LoadResult {
    // ELF64 header: https://en.wikipedia.org/wiki/Executable_and_Linkable_Format
    if (kernel_data.len < 64) return error.KernelTooSmall;

    // Verify ELF64 (class=2), little-endian (data=1), executable (type=2)
    if (kernel_data[4] != 2) { // EI_CLASS: must be 64-bit
        log.err("ELF kernel is not 64-bit", .{});
        return error.UnsupportedKernel;
    }
    if (kernel_data[5] != 1) { // EI_DATA: must be little-endian
        log.err("ELF kernel is not little-endian", .{});
        return error.UnsupportedKernel;
    }

    const entry = std.mem.readInt(u64, kernel_data[24..32], .little);
    const phoff = std.mem.readInt(u64, kernel_data[32..40], .little);
    const phentsize = std.mem.readInt(u16, kernel_data[54..56], .little);
    const phnum = std.mem.readInt(u16, kernel_data[56..58], .little);

    log.info("ELF kernel: entry=0x{x}, {} program headers", .{ entry, phnum });

    // Load all PT_LOAD segments into guest memory
    var kernel_end: u64 = 0;
    var i: u16 = 0;
    while (i < phnum) : (i += 1) {
        const ph_start = phoff + @as(u64, i) * phentsize;
        if (ph_start + phentsize > kernel_data.len) return error.InvalidKernel;
        const ph = kernel_data[ph_start..][0..phentsize];

        const p_type = std.mem.readInt(u32, ph[0..4], .little);
        if (p_type != 1) continue; // PT_LOAD = 1

        const p_offset = std.mem.readInt(u64, ph[8..16], .little);
        const p_paddr = std.mem.readInt(u64, ph[24..32], .little);
        const p_filesz = std.mem.readInt(u64, ph[32..40], .little);
        const p_memsz = std.mem.readInt(u64, ph[40..48], .little);

        // Convert virtual address to physical if needed (Linux kernels
        // use virtual addresses starting at 0xffffffff81000000, physical at 0x1000000)
        const paddr: usize = blk: {
            if (p_paddr < mem.size()) break :blk @intCast(p_paddr);
            // Try using a standard kernel text offset (16MB)
            const PHYS_OFFSET: u64 = 0x1000000;
            if (p_paddr >= 0xffffffff80000000) {
                const phys = p_paddr - 0xffffffff80000000 + PHYS_OFFSET;
                if (phys < mem.size()) break :blk @intCast(phys);
            }
            log.err("PT_LOAD segment paddr 0x{x} out of guest memory bounds", .{p_paddr});
            return error.InvalidKernel;
        };

        if (p_filesz > 0) {
            const end = p_offset + p_filesz;
            if (end > kernel_data.len) return error.InvalidKernel;
            try mem.write(paddr, kernel_data[@intCast(p_offset)..@intCast(end)]);
        }

        // Zero BSS (memsz > filesz)
        if (p_memsz > p_filesz) {
            const bss_start = paddr + @as(usize, @intCast(p_filesz));
            const bss_size: usize = @intCast(p_memsz - p_filesz);
            if (bss_start + bss_size <= mem.size()) {
                const bss = try mem.slice(bss_start, bss_size);
                @memset(bss, 0);
            }
        }

        const seg_end = paddr + @as(usize, @intCast(p_memsz));
        if (seg_end > kernel_end) kernel_end = seg_end;
        log.info("  PT_LOAD: paddr=0x{x} filesz=0x{x} memsz=0x{x}", .{ paddr, p_filesz, p_memsz });
    }

    // Resolve entry point to physical address
    const entry_phys: u64 = blk: {
        if (entry < mem.size()) break :blk entry;
        const PHYS_OFFSET: u64 = 0x1000000;
        if (entry >= 0xffffffff80000000) {
            break :blk entry - 0xffffffff80000000 + PHYS_OFFSET;
        }
        break :blk entry;
    };

    log.info("ELF kernel loaded, entry_phys=0x{x}", .{entry_phys});

    // Copy command line
    if (cmdline.len > 0) {
        try mem.write(params.CMDLINE_ADDR, cmdline);
        const term = try mem.slice(params.CMDLINE_ADDR + cmdline.len, 1);
        term[0] = 0;
    }

    // Set up boot_params (zero page)
    const bp = try mem.slice(params.BOOT_PARAMS_ADDR, params.BOOT_PARAMS_SIZE);
    @memset(bp, 0);

    // Minimal setup header for ELF boot
    bp[params.OFF_TYPE_OF_LOADER] = 0xFF;
    bp[params.OFF_LOADFLAGS] = params.LOADED_HIGH | params.CAN_USE_HEAP;
    std.mem.writeInt(u16, bp[params.OFF_HEAP_END_PTR..][0..2], 0xFE00, .little);
    std.mem.writeInt(u32, bp[params.OFF_CMD_LINE_PTR..][0..4], params.CMDLINE_ADDR, .little);

    // Write setup header magic so the kernel recognizes valid boot_params
    std.mem.writeInt(u32, bp[params.OFF_SETUP_HEADER + 6 ..][0..4], params.HDRS_MAGIC, .little);
    // Boot protocol version 2.15
    std.mem.writeInt(u16, bp[params.OFF_SETUP_HEADER + 10 ..][0..2], 0x020F, .little);

    // Load initrd if provided
    if (initrd_path) |path| {
        const kernel_size = kernel_end - params.KERNEL_ADDR;
        try loadInitrd(bp, mem, path, @intCast(kernel_size));
    }

    // Set up e820 memory map
    setupE820(bp, mem.size());

    log.info("boot_params at guest 0x{x}, cmdline at 0x{x}", .{
        params.BOOT_PARAMS_ADDR, params.CMDLINE_ADDR,
    });

    // For ELF kernels, we enter at the physical entry point directly.
    // The STARTUP_64_OFFSET is already accounted for in the ELF entry.
    return .{
        .entry_addr = entry_phys,
        .boot_params_addr = params.BOOT_PARAMS_ADDR,
        .needs_startup_offset = false,
    };
}

fn setupE820(bp: []u8, mem_size: usize) void {
    const e820_entries = [_]params.E820Entry{
        .{ .addr = 0, .size = 0x9FC00, .type_ = params.E820Entry.RAM }, // Conventional memory (below EBDA)
        .{ .addr = 0x9FC00, .size = 0x60400, .type_ = params.E820Entry.RESERVED }, // EBDA + VGA + ROM (0x9FC00-0x100000)
        .{ .addr = 0x100000, .size = mem_size - 0x100000, .type_ = params.E820Entry.RAM }, // Main RAM from 1MB
    };
    for (e820_entries, 0..) |entry, i| {
        const off = params.OFF_E820_TABLE + i * 20;
        std.mem.writeInt(u64, bp[off..][0..8], entry.addr, .little);
        std.mem.writeInt(u64, bp[off + 8 ..][0..8], entry.size, .little);
        std.mem.writeInt(u32, bp[off + 16 ..][0..4], entry.type_, .little);
    }
    bp[params.OFF_E820_ENTRIES] = e820_entries.len;
    log.info("e820: {} entries", .{e820_entries.len});
}
