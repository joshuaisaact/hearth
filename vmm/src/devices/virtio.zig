// Virtio common constants and types.
// Reference: OASIS virtio spec v1.1

// MMIO register offsets (all 32-bit, 4-byte aligned)
pub const MMIO_MAGIC_VALUE = 0x000;
pub const MMIO_VERSION = 0x004;
pub const MMIO_DEVICE_ID = 0x008;
pub const MMIO_VENDOR_ID = 0x00C;
pub const MMIO_DEVICE_FEATURES = 0x010;
pub const MMIO_DEVICE_FEATURES_SEL = 0x014;
pub const MMIO_DRIVER_FEATURES = 0x020;
pub const MMIO_DRIVER_FEATURES_SEL = 0x024;
pub const MMIO_QUEUE_SEL = 0x030;
pub const MMIO_QUEUE_NUM_MAX = 0x034;
pub const MMIO_QUEUE_NUM = 0x038;
pub const MMIO_QUEUE_READY = 0x044;
pub const MMIO_QUEUE_NOTIFY = 0x050;
pub const MMIO_INTERRUPT_STATUS = 0x060;
pub const MMIO_INTERRUPT_ACK = 0x064;
pub const MMIO_STATUS = 0x070;
pub const MMIO_QUEUE_DESC_LOW = 0x080;
pub const MMIO_QUEUE_DESC_HIGH = 0x084;
pub const MMIO_QUEUE_DRIVER_LOW = 0x090;
pub const MMIO_QUEUE_DRIVER_HIGH = 0x094;
pub const MMIO_QUEUE_DEVICE_LOW = 0x0A0;
pub const MMIO_QUEUE_DEVICE_HIGH = 0x0A4;
pub const MMIO_CONFIG_GENERATION = 0x0FC;
pub const MMIO_CONFIG = 0x100;

// Magic value: "virt" in little-endian
pub const MAGIC_VALUE: u32 = 0x74726976;
pub const MMIO_VERSION_2: u32 = 2;
pub const VENDOR_ID: u32 = 0x554D4551; // "QEMU" style

// Device IDs
pub const DEVICE_ID_NET: u32 = 1;
pub const DEVICE_ID_BLOCK: u32 = 2;
pub const DEVICE_ID_VSOCK: u32 = 19;

// Device status bits
pub const STATUS_ACKNOWLEDGE: u8 = 1;
pub const STATUS_DRIVER: u8 = 2;
pub const STATUS_DRIVER_OK: u8 = 4;
pub const STATUS_FEATURES_OK: u8 = 8;
pub const STATUS_DEVICE_NEEDS_RESET: u8 = 64;
pub const STATUS_FAILED: u8 = 128;

// Feature bits (common)
pub const F_VERSION_1: u64 = 1 << 32;

// Interrupt status bits
pub const INT_USED_RING: u32 = 1;
pub const INT_CONFIG_CHANGE: u32 = 2;

// Descriptor flags
pub const DESC_F_NEXT: u16 = 1;
pub const DESC_F_WRITE: u16 = 2;

// MMIO region size per device
pub const MMIO_SIZE: u64 = 0x1000;

// Base address and IRQ for virtio-mmio devices
pub const MMIO_BASE: u64 = 0xd0000000;
pub const IRQ_BASE: u32 = 5;

// Maximum number of virtio-mmio device slots
pub const MAX_DEVICES: u32 = 8;
