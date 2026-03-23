// Minimal hand-written Linux x86 boot protocol structs.
// Only the fields we actually use -- not the full 4KB boot_params.
// Reference: Documentation/x86/boot.rst in the Linux kernel source.

const std = @import("std");

/// The setup header, located at offset 0x1F1 in the bzImage.
/// We only define the fields we read/write.
pub const SetupHeader = packed struct {
    setup_sects: u8,
    root_flags: u16,
    syssize: u32,
    ram_size: u16,
    vid_mode: u16,
    root_dev: u16,
    boot_flag: u16,
    jump: u16,
    header: u32, // Must be "HdrS" (0x53726448)
    version: u16,
    realmode_swtch: u32,
    start_sys_seg: u16,
    kernel_version: u16,
    type_of_loader: u8,
    loadflags: u8,
    setup_move_size: u16,
    code32_start: u32,
    ramdisk_image: u32,
    ramdisk_size: u32,
    bootsect_kludge: u32,
    heap_end_ptr: u16,
    ext_loader_ver: u8,
    ext_loader_type: u8,
    cmd_line_ptr: u32,
    initrd_addr_max: u32,
    kernel_alignment: u32,
    relocatable_kernel: u8,
    min_alignment: u8,
    xloadflags: u16,
    cmdline_size: u32,
};

/// E820 memory map entry.
pub const E820Entry = packed struct {
    addr: u64,
    size: u64,
    type_: u32,

    pub const RAM: u32 = 1;
    pub const RESERVED: u32 = 2;
};

/// The boot_params struct (the "zero page") at 0x7000 in guest memory.
/// Full struct is 4096 bytes. We define it as a fixed-size block and
/// write individual fields at known offsets.
pub const BOOT_PARAMS_SIZE = 4096;

// Offsets within boot_params (the 4KB zero page)
pub const OFF_E820_ENTRIES = 0x1E8; // u8: number of e820 entries
pub const OFF_SETUP_HEADER = 0x1F1; // setup header starts here
pub const OFF_TYPE_OF_LOADER = 0x210;
pub const OFF_LOADFLAGS = 0x211;
pub const OFF_RAMDISK_IMAGE = 0x218;
pub const OFF_RAMDISK_SIZE = 0x21C;
pub const OFF_HEAP_END_PTR = 0x224;
pub const OFF_CMD_LINE_PTR = 0x228;
pub const OFF_INITRD_ADDR_MAX = 0x22C;
pub const OFF_BOOT_FLAG = 0x1FE;
pub const OFF_HEADER = 0x202;
pub const OFF_VERSION = 0x206;
pub const OFF_CODE32_START = 0x214;
pub const OFF_KERNEL_ALIGNMENT = 0x230;
pub const OFF_RELOCATABLE = 0x234;
pub const OFF_MIN_ALIGNMENT = 0x235;
pub const OFF_XLOADFLAGS = 0x236;
pub const OFF_CMDLINE_SIZE = 0x238;
pub const OFF_INIT_SIZE = 0x260;
pub const OFF_E820_TABLE = 0x2D0; // e820 table (array of E820Entry, max 128)

// Well-known guest physical addresses for the Linux boot protocol
pub const BOOT_PARAMS_ADDR: u32 = 0x7000;
pub const CMDLINE_ADDR: u32 = 0x20000;
pub const KERNEL_ADDR: u32 = 0x100000; // 1MB - where protected-mode kernel is loaded

/// 64-bit entry point offset from start of protected-mode kernel
pub const STARTUP_64_OFFSET: u32 = 0x200;

/// Load flags
pub const LOADED_HIGH: u8 = 0x01;
pub const CAN_USE_HEAP: u8 = 0x80;

/// xloadflags
pub const XLF_KERNEL_64: u16 = 0x01;

/// "HdrS" magic
pub const HDRS_MAGIC: u32 = 0x53726448;
