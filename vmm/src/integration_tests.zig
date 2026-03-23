// Integration tests for flint.
// Spawn the flint binary and test end-to-end behavior.
// Requires /dev/kvm and a kernel bzImage at /tmp/vmlinuz-minimal.
//
// Run with: zig build integration-test

const std = @import("std");
const linux = std.os.linux;
const process = std.process;

const FLINT_BIN = "zig-out/bin/flint";
const DEFAULT_KERNEL = "/tmp/vmlinuz-minimal";

var threaded_io: ?std.Io.Threaded = null;

fn io() std.Io {
    if (threaded_io == null) {
        threaded_io = std.Io.Threaded.init(std.testing.allocator, .{});
    }
    return threaded_io.?.io();
}

fn kernelAvailable() bool {
    const rc: isize = @bitCast(linux.open(DEFAULT_KERNEL, .{ .ACCMODE = .RDONLY }, 0));
    if (rc < 0) return false;
    _ = linux.close(@intCast(rc));
    return true;
}

/// Build a minimal cpio initrd with a single init script.
/// Returns allocated stdout containing the path to the initrd file.
fn buildInitrd(comptime init_script: []const u8) ![]const u8 {
    const allocator = std.testing.allocator;
    const result = try process.run(allocator, io(), .{
        .argv = &.{
            "/bin/sh", "-c",
            "TMPDIR=$(mktemp -d) && cd \"$TMPDIR\" && " ++
                "printf '" ++ init_script ++ "' > init && " ++
                "chmod +x init && " ++
                "echo init | bsdcpio -o -H newc 2>/dev/null | gzip > initrd.cpio.gz && " ++
                "echo \"$TMPDIR/initrd.cpio.gz\"",
        },
    });
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        allocator.free(result.stdout);
        return error.InitrdBuildFailed;
    }

    return result.stdout;
}

fn trimNewline(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\n') return s[0 .. s.len - 1];
    return s;
}

/// Connect to a Unix socket, send an HTTP request, return the full response.
fn httpRequest(sock_path: []const u8, method: []const u8, target: []const u8, body: ?[]const u8) ![]u8 {
    const allocator = std.testing.allocator;

    const sock_rc: isize = @bitCast(linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);
    defer _ = linux.close(fd);

    var addr: linux.sockaddr.un = .{ .family = linux.AF.UNIX, .path = undefined };
    @memset(&addr.path, 0);
    for (0..sock_path.len) |i| {
        addr.path[i] = @intCast(sock_path[i]);
    }

    const connect_rc: isize = @bitCast(linux.connect(fd, @ptrCast(&addr), @intCast(@sizeOf(linux.sockaddr.un))));
    if (connect_rc < 0) return error.ConnectFailed;

    var req_buf: [2048]u8 = undefined;
    const req = if (body) |b|
        std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{ method, target, b.len, b }) catch return error.RequestTooLarge
    else
        std.fmt.bufPrint(&req_buf, "{s} {s} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n", .{ method, target }) catch return error.RequestTooLarge;

    var written: usize = 0;
    while (written < req.len) {
        const rc: isize = @bitCast(linux.write(fd, req[written..].ptr, req.len - written));
        if (rc <= 0) return error.WriteFailed;
        written += @intCast(rc);
    }

    // Read response into allocated buffer
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    while (total < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[total..].ptr, buf.len - total));
        if (rc <= 0) break;
        total += @intCast(rc);
    }

    const result = try allocator.alloc(u8, total);
    @memcpy(result, buf[0..total]);
    return result;
}

fn sleep_ms(ms: u64) void {
    const ts = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    _ = linux.nanosleep(&ts, null);
}

// ============================================================
// Tests
// ============================================================

test "flint prints usage with no args" {
    const allocator = std.testing.allocator;
    const result = try process.run(allocator, io(), .{
        .argv = &.{FLINT_BIN},
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expectEqual(@as(u8, 1), result.term.exited);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "usage: flint") != null);
}

test "flint fails with nonexistent kernel" {
    const allocator = std.testing.allocator;
    const result = try process.run(allocator, io(), .{
        .argv = &.{ FLINT_BIN, "/nonexistent/kernel" },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    try std.testing.expect(result.term.exited != 0);
}

test "boot to userspace" {
    if (!kernelAvailable()) {
        std.debug.print("SKIP: no kernel at {s}\n", .{DEFAULT_KERNEL});
        return;
    }

    const allocator = std.testing.allocator;
    const initrd_stdout = try buildInitrd("#!/bin/sh\\necho FLINT_BOOT_OK\\nwhile true; do echo -n \\\"\\\" > /dev/null 2>&1; done\\n");
    defer allocator.free(initrd_stdout);
    const initrd = trimNewline(initrd_stdout);

    // Use spawn+kill since the VM doesn't exit cleanly
    var child = try process.spawn(io(), .{
        .argv = &.{ FLINT_BIN, DEFAULT_KERNEL, initrd },
        .stdout = .pipe,
        .stderr = .ignore,
    });
    defer {
        child.kill(io());
    }

    // Read stdout until we see the marker or timeout
    var buf: [8192]u8 = undefined;
    var total: usize = 0;
    var start_ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &start_ts);
    while (total < buf.len) {
        var now_ts: linux.timespec = undefined;
        _ = linux.clock_gettime(.MONOTONIC, &now_ts);
        if (now_ts.sec - start_ts.sec > 10) break; // 10s timeout
        if (child.stdout) |stdout| {
            const rc: isize = @bitCast(linux.read(stdout.handle, buf[total..].ptr, buf.len - total));
            if (rc <= 0) break;
            total += @intCast(rc);
            if (std.mem.indexOf(u8, buf[0..total], "FLINT_BOOT_OK") != null) break;
        } else break;
    }

    try std.testing.expect(std.mem.indexOf(u8, buf[0..total], "FLINT_BOOT_OK") != null);
}

test "API boot and VM status" {
    if (!kernelAvailable()) {
        std.debug.print("SKIP: no kernel at {s}\n", .{DEFAULT_KERNEL});
        return;
    }

    const allocator = std.testing.allocator;
    const initrd_stdout = try buildInitrd("#!/bin/sh\nwhile true; do echo -n '' > /dev/null 2>&1; done\n");
    defer allocator.free(initrd_stdout);
    const initrd = trimNewline(initrd_stdout);

    const sock_path = "/tmp/flint-test-api.sock";
    _ = linux.unlink(sock_path);

    var child = try process.spawn(io(), .{
        .argv = &.{ FLINT_BIN, "--api-sock", sock_path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        child.kill(io());
    }

    sleep_ms(500);

    // Configure and boot
    var boot_cmd_buf: [512]u8 = undefined;
    const boot_cmd = std.fmt.bufPrint(&boot_cmd_buf,
        "{{\"kernel_image_path\":\"{s}\",\"initrd_path\":\"{s}\"}}", .{ DEFAULT_KERNEL, initrd },
    ) catch unreachable;

    var r = try httpRequest(sock_path, "PUT", "/boot-source", boot_cmd);
    allocator.free(r);

    r = try httpRequest(sock_path, "PUT", "/actions", "{\"action_type\":\"InstanceStart\"}");
    allocator.free(r);

    sleep_ms(2000);

    // Check VM status
    const status = try httpRequest(sock_path, "GET", "/vm", null);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "Running") != null);
}

test "API pause and resume" {
    if (!kernelAvailable()) {
        std.debug.print("SKIP: no kernel at {s}\n", .{DEFAULT_KERNEL});
        return;
    }

    const allocator = std.testing.allocator;
    const initrd_stdout = try buildInitrd("#!/bin/sh\nwhile true; do echo -n '' > /dev/null 2>&1; done\n");
    defer allocator.free(initrd_stdout);
    const initrd = trimNewline(initrd_stdout);

    const sock_path = "/tmp/flint-test-pause.sock";
    _ = linux.unlink(sock_path);

    var child = try process.spawn(io(), .{
        .argv = &.{ FLINT_BIN, "--api-sock", sock_path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        child.kill(io());
    }

    sleep_ms(500);

    var boot_cmd_buf: [512]u8 = undefined;
    const boot_cmd = std.fmt.bufPrint(&boot_cmd_buf,
        "{{\"kernel_image_path\":\"{s}\",\"initrd_path\":\"{s}\"}}", .{ DEFAULT_KERNEL, initrd },
    ) catch unreachable;

    var r = try httpRequest(sock_path, "PUT", "/boot-source", boot_cmd);
    allocator.free(r);
    r = try httpRequest(sock_path, "PUT", "/actions", "{\"action_type\":\"InstanceStart\"}");
    allocator.free(r);

    sleep_ms(2000);

    // Pause
    r = try httpRequest(sock_path, "PATCH", "/vm", "{\"state\":\"Paused\"}");
    allocator.free(r);

    const paused = try httpRequest(sock_path, "GET", "/vm", null);
    defer allocator.free(paused);
    try std.testing.expect(std.mem.indexOf(u8, paused, "Paused") != null);

    // Resume
    r = try httpRequest(sock_path, "PATCH", "/vm", "{\"state\":\"Resumed\"}");
    allocator.free(r);

    const resumed = try httpRequest(sock_path, "GET", "/vm", null);
    defer allocator.free(resumed);
    try std.testing.expect(std.mem.indexOf(u8, resumed, "Running") != null);
}

test "snapshot requires pause" {
    if (!kernelAvailable()) {
        std.debug.print("SKIP: no kernel at {s}\n", .{DEFAULT_KERNEL});
        return;
    }

    const allocator = std.testing.allocator;
    const initrd_stdout = try buildInitrd("#!/bin/sh\nwhile true; do echo -n '' > /dev/null 2>&1; done\n");
    defer allocator.free(initrd_stdout);
    const initrd = trimNewline(initrd_stdout);

    const sock_path = "/tmp/flint-test-snap.sock";
    _ = linux.unlink(sock_path);

    var child = try process.spawn(io(), .{
        .argv = &.{ FLINT_BIN, "--api-sock", sock_path },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        child.kill(io());
    }

    sleep_ms(500);

    var boot_cmd_buf: [512]u8 = undefined;
    const boot_cmd = std.fmt.bufPrint(&boot_cmd_buf,
        "{{\"kernel_image_path\":\"{s}\",\"initrd_path\":\"{s}\"}}", .{ DEFAULT_KERNEL, initrd },
    ) catch unreachable;

    var r = try httpRequest(sock_path, "PUT", "/boot-source", boot_cmd);
    allocator.free(r);
    r = try httpRequest(sock_path, "PUT", "/actions", "{\"action_type\":\"InstanceStart\"}");
    allocator.free(r);

    sleep_ms(2000);

    // Snapshot without pausing should fail
    const snap_resp = try httpRequest(sock_path, "PUT", "/snapshot/create",
        "{\"snapshot_path\":\"/tmp/flint-test.vmstate\",\"mem_file_path\":\"/tmp/flint-test.mem\"}",
    );
    defer allocator.free(snap_resp);
    try std.testing.expect(std.mem.indexOf(u8, snap_resp, "must be paused") != null);
}

test "snapshot create and restore" {
    if (!kernelAvailable()) {
        std.debug.print("SKIP: no kernel at {s}\n", .{DEFAULT_KERNEL});
        return;
    }

    const allocator = std.testing.allocator;
    const initrd_stdout = try buildInitrd("#!/bin/sh\nwhile true; do echo -n '' > /dev/null 2>&1; done\n");
    defer allocator.free(initrd_stdout);
    const initrd = trimNewline(initrd_stdout);

    const sock_path = "/tmp/flint-test-snapcreate.sock";
    const vmstate = "/tmp/flint-test-snapcreate.vmstate";
    const memfile = "/tmp/flint-test-snapcreate.mem";
    _ = linux.unlink(sock_path);
    _ = linux.unlink(vmstate);
    _ = linux.unlink(memfile);

    // Boot VM
    var child = try process.spawn(io(), .{
        .argv = &.{ FLINT_BIN, "--api-sock", sock_path },
        .stdout = .ignore,
        .stderr = .ignore,
    });

    sleep_ms(500);

    var boot_cmd_buf: [512]u8 = undefined;
    const boot_cmd = std.fmt.bufPrint(&boot_cmd_buf,
        "{{\"kernel_image_path\":\"{s}\",\"initrd_path\":\"{s}\"}}", .{ DEFAULT_KERNEL, initrd },
    ) catch unreachable;

    var r = try httpRequest(sock_path, "PUT", "/boot-source", boot_cmd);
    allocator.free(r);
    r = try httpRequest(sock_path, "PUT", "/actions", "{\"action_type\":\"InstanceStart\"}");
    allocator.free(r);

    sleep_ms(2000);

    // Pause and snapshot
    r = try httpRequest(sock_path, "PATCH", "/vm", "{\"state\":\"Paused\"}");
    allocator.free(r);

    var snap_cmd_buf: [512]u8 = undefined;
    const snap_cmd = std.fmt.bufPrint(&snap_cmd_buf,
        "{{\"snapshot_path\":\"{s}\",\"mem_file_path\":\"{s}\"}}", .{ vmstate, memfile },
    ) catch unreachable;

    r = try httpRequest(sock_path, "PUT", "/snapshot/create", snap_cmd);
    allocator.free(r);

    // Kill original VM
    child.kill(io());

    // Verify snapshot files exist
    const vm_rc: isize = @bitCast(linux.open(vmstate, .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expect(vm_rc >= 0);
    _ = linux.close(@intCast(vm_rc));

    const mem_rc: isize = @bitCast(linux.open(memfile, .{ .ACCMODE = .RDONLY }, 0));
    try std.testing.expect(mem_rc >= 0);
    _ = linux.close(@intCast(mem_rc));

    // Restore and verify it runs
    const restore_sock = "/tmp/flint-test-restored.sock";
    _ = linux.unlink(restore_sock);

    var restored = try process.spawn(io(), .{
        .argv = &.{ FLINT_BIN, "--restore", "--vmstate-path", vmstate, "--mem-path", memfile, "--api-sock", restore_sock },
        .stdout = .ignore,
        .stderr = .ignore,
    });
    defer {
        restored.kill(io());
    }

    sleep_ms(1000);

    const status = try httpRequest(restore_sock, "GET", "/vm", null);
    defer allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "Running") != null);

    // Clean up snapshot files
    _ = linux.unlink(vmstate);
    _ = linux.unlink(memfile);
}
