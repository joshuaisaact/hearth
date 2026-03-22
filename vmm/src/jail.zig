// Process jail: mount namespace, pivot_root, device nodes, privilege drop.
// Called early in VMM startup (before opening /dev/kvm) so the entire
// VMM lifecycle runs inside the jail.

const std = @import("std");
const linux = std.os.linux;

const log = std.log.scoped(.jail);

const S_IFCHR: u32 = 0o020000;
// Device major/minor encoding: (major << 8) | minor (valid for major < 4096, minor < 256)
const DEV_KVM = (10 << 8) | 232;
const DEV_NET_TUN = (10 << 8) | 200;

fn check(rc: usize, comptime what: []const u8) !void {
    const signed: isize = @bitCast(rc);
    if (signed < 0) {
        log.err("{s} failed: errno {}", .{ what, -signed });
        return error.JailSetupFailed;
    }
}

pub const Config = struct {
    jail_dir: [*:0]const u8,
    uid: u32,
    gid: u32,
    cgroup: ?[*:0]const u8 = null,
    cpu_pct: u32 = 0, // 0 = no limit, 100 = 1 core, 200 = 2 cores
    memory_mib: u32 = 0, // 0 = no limit
    io_mbps: u32 = 0, // 0 = no limit, applies to disk backing device
    disk_major: u32 = 0, // block device major:minor for io.max
    disk_minor: u32 = 0,
    need_tun: bool = false,
};

pub fn setup(config: Config) !void {
    // Close inherited FDs above stderr to prevent leaks from parent
    try check(linux.close_range(3, std.math.maxInt(linux.fd_t), .{ .UNSHARE = false, .CLOEXEC = false }), "close_range");

    // Cgroup: move process into cgroup before pivot_root (needs /sys/fs/cgroup)
    if (config.cgroup) |cg| {
        try setupCgroup(cg, config);
    }

    // New mount namespace — isolates our mount table from the host
    try check(linux.unshare(linux.CLONE.NEWNS), "unshare(NEWNS)");

    // Stop mount event propagation to parent namespace
    try check(linux.mount(null, "/", null, linux.MS.SLAVE | linux.MS.REC, 0), "mount(MS_SLAVE)");

    // Bind-mount jail dir on itself (pivot_root requires a mount point)
    try check(linux.mount(config.jail_dir, config.jail_dir, null, linux.MS.BIND | linux.MS.REC, 0), "mount(MS_BIND)");

    // Swap filesystem root: jail_dir becomes /, old root goes to old_root
    try check(linux.chdir(config.jail_dir), "chdir(jail)");
    try check(linux.mkdir("old_root", 0o700), "mkdir(old_root)");
    try check(linux.pivot_root(".", "old_root"), "pivot_root");
    try check(linux.chdir("/"), "chdir(/)");

    // Detach host filesystem — no way back
    try check(linux.umount2("old_root", linux.MNT.DETACH), "umount2(old_root)");
    _ = linux.rmdir("old_root");

    // Create device nodes inside the jail (only what the VMM needs)
    try check(linux.mkdir("dev", 0o755), "mkdir(/dev)");
    try check(linux.mknod("dev/kvm", S_IFCHR | 0o660, DEV_KVM), "mknod(/dev/kvm)");

    if (config.need_tun) {
        try check(linux.mkdir("dev/net", 0o755), "mkdir(/dev/net)");
        try check(linux.mknod("dev/net/tun", S_IFCHR | 0o660, DEV_NET_TUN), "mknod(/dev/net/tun)");
    }

    // Drop privileges — last step requiring root
    try check(linux.setgid(config.gid), "setgid");
    try check(linux.setuid(config.uid), "setuid");

    // Prevent ptrace and core dumps from leaking VM memory
    const rc: isize = @bitCast(linux.prctl(@intFromEnum(linux.PR.SET_DUMPABLE), 0, 0, 0, 0));
    if (rc < 0) {
        log.warn("prctl(SET_DUMPABLE) failed: {}", .{rc});
    }

    log.info("jail active: uid={} gid={}", .{ config.uid, config.gid });
}

fn setupCgroup(name: [*:0]const u8, config: Config) !void {
    const name_len = std.mem.indexOfSentinel(u8, 0, name);
    const name_slice = name[0..name_len];

    // Reject path traversal and absolute paths in cgroup name
    if (name_len == 0 or name_slice[0] == '/' or
        std.mem.indexOf(u8, name_slice, "..") != null)
    {
        log.err("invalid cgroup name: {s}", .{name_slice});
        return error.InvalidCgroupName;
    }

    const prefix = "/sys/fs/cgroup/";

    var path_buf: [256]u8 = undefined;
    const base_len = prefix.len + name_len;
    if (base_len >= path_buf.len - 20) return error.CgroupPathTooLong;
    @memcpy(path_buf[0..prefix.len], prefix);
    @memcpy(path_buf[prefix.len..][0..name_len], name_slice);
    path_buf[base_len] = 0;

    // Create cgroup directory (may already exist)
    _ = linux.mkdir(@ptrCast(path_buf[0..base_len :0]), 0o755);

    // Set resource limits before moving process into cgroup.
    // Requires cpu and memory controllers enabled in parent's
    // cgroup.subtree_control (e.g. echo '+cpu +memory' > /sys/fs/cgroup/cgroup.subtree_control)
    if (config.cpu_pct > 0) {
        var val_buf: [32]u8 = undefined;
        const quota = @as(u64, config.cpu_pct) * 1000; // period = 100000us
        const val = std.fmt.bufPrint(&val_buf, "{} 100000", .{quota}) catch return error.FormatFailed;
        try writeCgroupSetting(&path_buf, base_len, "/cpu.max", val);
        log.info("cgroup cpu.max: {s}", .{val});
    }
    if (config.memory_mib > 0) {
        var val_buf: [20]u8 = undefined;
        const bytes = @as(u64, config.memory_mib) * 1024 * 1024;
        const val = std.fmt.bufPrint(&val_buf, "{}", .{bytes}) catch return error.FormatFailed;
        try writeCgroupSetting(&path_buf, base_len, "/memory.max", val);
        log.info("cgroup memory.max: {} MiB", .{config.memory_mib});
    }
    if (config.io_mbps > 0) {
        // cgroups v2 io.max format: "major:minor rbps=N wbps=N"
        // This is coarser than virtio-level rate limiting — the guest sees
        // I/O stalls rather than clean virtqueue backpressure. Good enough
        // for controlled workloads; for multi-tenant SLA guarantees on I/O
        // latency, virtio-blk/net token bucket rate limiters are needed.
        var val_buf: [64]u8 = undefined;
        const bps = @as(u64, config.io_mbps) * 1024 * 1024;
        const val = std.fmt.bufPrint(&val_buf, "{}:{} rbps={} wbps={}", .{
            config.disk_major, config.disk_minor, bps, bps,
        }) catch return error.FormatFailed;
        try writeCgroupSetting(&path_buf, base_len, "/io.max", val);
        log.info("cgroup io.max: {} MB/s ({}:{})", .{ config.io_mbps, config.disk_major, config.disk_minor });
    }

    // Move current process into the cgroup
    var pid_buf: [20]u8 = undefined;
    const pid: u64 = @intCast(linux.getpid());
    const pid_str = std.fmt.bufPrint(&pid_buf, "{}", .{pid}) catch return error.FormatFailed;
    try writeCgroupSetting(&path_buf, base_len, "/cgroup.procs", pid_str);
    log.info("joined cgroup: {s}", .{name_slice});
}

fn writeCgroupSetting(path_buf: *[256]u8, base_len: usize, comptime suffix: []const u8, data: []const u8) !void {
    @memcpy(path_buf[base_len..][0..suffix.len], suffix);
    path_buf[base_len + suffix.len] = 0;
    try writeFile(@ptrCast(path_buf[0 .. base_len + suffix.len :0]), data);
    path_buf[base_len] = 0; // restore null terminator
}

fn writeFile(path: [*:0]const u8, data: []const u8) !void {
    const rc: isize = @bitCast(linux.open(path, .{ .ACCMODE = .WRONLY }, 0));
    if (rc < 0) return error.OpenFailed;
    const fd: linux.fd_t = @intCast(rc);
    defer _ = linux.close(fd);
    const wrc: isize = @bitCast(linux.write(fd, data.ptr, data.len));
    if (wrc < 0) return error.WriteFailed;
}
