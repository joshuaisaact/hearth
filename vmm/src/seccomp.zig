// Seccomp BPF filter for sandboxing the VMM process.
// Whitelists the minimum syscalls needed to run a KVM VM with
// virtio devices and an API socket. Everything else kills the process.
//
// Three syscalls have argument-level filtering:
//   clone  — only thread-creation flags (blocks CLONE_NEWUSER escape)
//   socket — only AF_UNIX (blocks network exfiltration)
//   mprotect — blocks PROT_EXEC (no shellcode execution)

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.seccomp);

// Seccomp constants (stable kernel ABI — hardcoded to avoid Zig 0.16-dev
// compilation bug in AUDIT.ARCH enum)
const SECCOMP_SET_MODE_FILTER: u32 = 1;
const SECCOMP_RET_KILL_PROCESS: u32 = 0x80000000;
const SECCOMP_RET_ALLOW: u32 = 0x7FFF0000;
const SECCOMP_RET_LOG: u32 = 0x7FFC0000;
const AUDIT_ARCH_X86_64: u32 = 0xC000003E;

// seccomp_data field offsets (stable ABI)
const DATA_OFF_NR: u32 = 0;
const DATA_OFF_ARCH: u32 = 4;
const DATA_OFF_ARG0: u32 = 16; // after nr(4) + arch(4) + instruction_pointer(8)
const DATA_OFF_ARG2: u32 = 32;

// Classic BPF structs (not in Zig stdlib)
const SockFilter = extern struct {
    code: u16,
    jt: u8,
    jf: u8,
    k: u32,
};

const SockFprog = extern struct {
    len: u16,
    filter: [*]const SockFilter,
};

// BPF instruction encoding
const BPF_LD: u16 = 0x00;
const BPF_ALU: u16 = 0x04;
const BPF_JMP: u16 = 0x05;
const BPF_RET: u16 = 0x06;
const BPF_W: u16 = 0x00;
const BPF_ABS: u16 = 0x20;
const BPF_K: u16 = 0x00;
const BPF_JEQ: u16 = 0x10;
const BPF_AND: u16 = 0x50;

fn bpf_stmt(code: u16, k: u32) SockFilter {
    return .{ .code = code, .jt = 0, .jf = 0, .k = k };
}

fn bpf_jump(code: u16, k: u32, jt: u8, jf: u8) SockFilter {
    return .{ .code = code, .jt = jt, .jf = jf, .k = k };
}

// Argument filter constants
const AF_UNIX: u32 = 1;
const PROT_EXEC: u32 = 4;
// Thread-creation clone flags (everything else is blocked — especially CLONE_NEWUSER)
const ALLOWED_CLONE_FLAGS: u32 = 0x003D0F00;
// CLONE_VM|FS|FILES|SIGHAND|THREAD|SYSVSEM|SETTLS|PARENT_SETTID|CHILD_CLEARTID

// Syscall numbers for argument-filtered calls
const SYS_MPROTECT: u32 = 10;
const SYS_SOCKET: u32 = 41;
const SYS_CLONE: u32 = 56;

// Simple whitelist — allowed unconditionally (no argument checks).
// clone, socket, mprotect are excluded; they have argument-level filters below.
const simple_syscalls = [_]u32{
    // Core I/O
    0,   // read
    1,   // write
    3,   // close
    8,   // lseek
    16,  // ioctl (KVM, FIONBIO, TUNSETIFF)
    17,  // pread64 (virtio-blk)
    18,  // pwrite64 (virtio-blk)
    19,  // readv (virtio-net TAP)
    20,  // writev (virtio-net TAP)
    72,  // fcntl (O_NONBLOCK)
    74,  // fsync (disk flush)
    87,  // unlink (API socket cleanup)
    257, // openat

    // Memory (mprotect excluded — has argument filter)
    9,   // mmap
    11,  // munmap
    12,  // brk
    25,  // mremap

    // Networking (socket excluded — has argument filter)
    42,  // connect (vsock UDS)
    44,  // sendto
    45,  // recvfrom
    49,  // bind
    50,  // listen
    288, // accept4

    // Threading (clone excluded — has argument filter)
    24,  // sched_yield
    158, // arch_prctl (TLS)
    186, // gettid
    202, // futex
    218, // set_tid_address
    273, // set_robust_list (thread cleanup)

    // Signals
    13,  // rt_sigaction
    14,  // rt_sigprocmask
    15,  // rt_sigreturn
    131, // sigaltstack

    // Process lifecycle
    60,  // exit
    200, // tkill
    219, // restart_syscall (kernel injects after interrupted sleep)
    231, // exit_group

    // Snapshot / file metadata
    77,  // ftruncate
    262, // newfstatat

    // Clock / random
    228, // clock_gettime
    318, // getrandom (HashMap seeding)
};

/// Build the BPF filter at comptime. Layout:
///   [0-3]      header: load arch, verify x86_64, load nr
///   [4..4+N-1] simple syscall checks (unconditional allow)
///   [4+N..+2]  filtered syscall dispatch (jump to arg check blocks)
///   [4+N+3]    default KILL
///   [4+N+4..]  argument check blocks for clone, socket, mprotect
///   [last]      ALLOW
fn buildFilter(comptime simple: []const u32, comptime default_action: u32) [simple.len + 20]SockFilter {
    const N = simple.len;
    // Total: 4 header + N simple + 3 dispatch + 1 kill + 4 clone + 3 socket + 4 mprotect + 1 allow = N+20
    const ALLOW_POS = N + 19;
    const CLONE_BLK = 4 + N + 4;
    const SOCKET_BLK = 4 + N + 8;
    const MPROT_BLK = 4 + N + 11;

    var f: [N + 20]SockFilter = undefined;

    // Header: verify arch, load syscall nr
    f[0] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_ARCH);
    f[1] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, AUDIT_ARCH_X86_64, 1, 0);
    f[2] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);
    f[3] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_NR);

    // Simple syscalls: match → jump to ALLOW
    for (simple, 0..) |nr, i| {
        f[4 + i] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, nr,
            @intCast(ALLOW_POS - (4 + i) - 1), 0);
    }

    // Filtered syscall dispatch: match → jump to argument check block
    f[4 + N + 0] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, SYS_CLONE,
        @intCast(CLONE_BLK - (4 + N + 0) - 1), 0);
    f[4 + N + 1] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, SYS_SOCKET,
        @intCast(SOCKET_BLK - (4 + N + 1) - 1), 0);
    f[4 + N + 2] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, SYS_MPROTECT,
        @intCast(MPROT_BLK - (4 + N + 2) - 1), 0);

    // Default: kill (or log)
    f[4 + N + 3] = bpf_stmt(BPF_RET | BPF_K, default_action);

    // Clone check: only allow thread-creation flags (block CLONE_NEWUSER etc.)
    f[CLONE_BLK + 0] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_ARG0);
    f[CLONE_BLK + 1] = bpf_stmt(BPF_ALU | BPF_AND | BPF_K, ~ALLOWED_CLONE_FLAGS);
    f[CLONE_BLK + 2] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, 0,
        @intCast(ALLOW_POS - (CLONE_BLK + 2) - 1), 0);
    f[CLONE_BLK + 3] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);

    // Socket check: only allow AF_UNIX (block AF_INET/AF_INET6 exfiltration)
    f[SOCKET_BLK + 0] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_ARG0);
    f[SOCKET_BLK + 1] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, AF_UNIX,
        @intCast(ALLOW_POS - (SOCKET_BLK + 1) - 1), 0);
    f[SOCKET_BLK + 2] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);

    // Mprotect check: deny PROT_EXEC (no shellcode execution)
    f[MPROT_BLK + 0] = bpf_stmt(BPF_LD | BPF_W | BPF_ABS, DATA_OFF_ARG2);
    f[MPROT_BLK + 1] = bpf_stmt(BPF_ALU | BPF_AND | BPF_K, PROT_EXEC);
    f[MPROT_BLK + 2] = bpf_jump(BPF_JMP | BPF_JEQ | BPF_K, 0,
        @intCast(ALLOW_POS - (MPROT_BLK + 2) - 1), 0);
    f[MPROT_BLK + 3] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS);

    // ALLOW
    f[ALLOW_POS] = bpf_stmt(BPF_RET | BPF_K, SECCOMP_RET_ALLOW);

    return f;
}

pub const kill_filter = buildFilter(&simple_syscalls, SECCOMP_RET_KILL_PROCESS);
pub const log_filter = buildFilter(&simple_syscalls, SECCOMP_RET_LOG);

/// Install the seccomp BPF filter. After this, unlisted syscalls kill
/// the process (or log in audit mode for development).
pub fn install(audit: bool) !void {
    const rc1: isize = @bitCast(linux.prctl(@intFromEnum(linux.PR.SET_NO_NEW_PRIVS), 1, 0, 0, 0));
    if (rc1 < 0) {
        log.err("prctl(NO_NEW_PRIVS) failed: {}", .{rc1});
        return error.PrctlFailed;
    }

    const filter = if (audit) &log_filter else &kill_filter;
    const prog = SockFprog{
        .len = @intCast(filter.len),
        .filter = filter,
    };

    const rc2: isize = @bitCast(linux.seccomp(SECCOMP_SET_MODE_FILTER, 0, &prog));
    if (rc2 < 0) {
        log.err("seccomp(SET_MODE_FILTER) failed: {}", .{rc2});
        return error.SeccompFailed;
    }

    if (audit) {
        log.warn("seccomp in AUDIT mode — violations logged, not killed", .{});
    } else {
        log.info("seccomp filter installed ({} syscalls whitelisted)", .{simple_syscalls.len + 3});
    }
}
