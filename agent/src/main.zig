// hearth-agent: guest-side sandbox daemon.
// Runs inside the VM, connects to host over vsock, executes commands.
// Protocol: 4-byte LE length prefix + JSON payload over vsock.

const std = @import("std");
const linux = std.os.linux;

const VSOCK_CID_HOST: u32 = 2;
const AGENT_PORT: u32 = 1024;
const AF_VSOCK: u16 = 40;
const MAX_MSG_SIZE: u32 = 16 * 1024 * 1024; // 16MB max message

// sockaddr_vm layout (linux/vm_sockets.h) — must be exactly 16 bytes
const SockaddrVm = extern struct {
    family: u16 = AF_VSOCK,
    reserved1: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(SockaddrVm) == 16);
    }
};

fn writeAll(fd: linux.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc: isize = @bitCast(linux.write(fd, data[written..].ptr, data[written..].len));
        if (rc < 0) return error.WriteFailed;
        if (rc == 0) return error.WriteFailed;
        written += @intCast(rc);
    }
}

fn readAll(fd: linux.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[got..].ptr, buf[got..].len));
        if (rc < 0) return error.ReadFailed;
        if (rc == 0) return error.ConnectionClosed;
        got += @intCast(rc);
    }
}

fn sendMsg(fd: linux.fd_t, payload: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
    try writeAll(fd, &len_buf);
    try writeAll(fd, payload);
}

fn recvMsg(fd: linux.fd_t, buf: []u8) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readAll(fd, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len > buf.len or len > MAX_MSG_SIZE) return error.MessageTooLarge;
    try readAll(fd, buf[0..len]);
    return buf[0..len];
}

fn connectVsock() !linux.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);

    const addr = SockaddrVm{ .port = AGENT_PORT, .cid = VSOCK_CID_HOST };
    const connect_rc: isize = @bitCast(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm)));
    if (connect_rc < 0) {
        _ = linux.close(fd);
        return error.ConnectFailed;
    }

    return fd;
}

// Retry vsock connect with backoff (VMM may not be ready at early boot)
fn connectWithRetry() !linux.fd_t {
    var attempts: u32 = 0;
    while (attempts < 50) : (attempts += 1) {
        return connectVsock() catch {
            const ts = linux.timespec{ .sec = 0, .nsec = 100_000_000 }; // 100ms
            _ = linux.nanosleep(&ts, null);
            continue;
        };
    }
    return error.ConnectFailed;
}

// Static buffers — avoids blowing the stack.
var main_msg_buf: [64 * 1024]u8 = undefined;
var main_resp_buf: [1024 * 1024]u8 = undefined;
var exec_stdout: [256 * 1024]u8 = undefined;
var exec_stderr: [64 * 1024]u8 = undefined;
var exec_b64_stdout: [512 * 1024]u8 = undefined;
var exec_b64_stderr: [128 * 1024]u8 = undefined;

fn handleExec(cmd_str: []const u8, timeout: u32, resp_buf: []u8) []const u8 {
    var sh_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", null };

    var cmd_buf: [4096]u8 = undefined;
    if (cmd_str.len >= cmd_buf.len) {
        return formatError(resp_buf, "command too long");
    }
    @memcpy(cmd_buf[0..cmd_str.len], cmd_str);
    cmd_buf[cmd_str.len] = 0;
    sh_argv[2] = @ptrCast(cmd_buf[0..cmd_str.len :0]);

    var stdout_fds: [2]linux.fd_t = undefined;
    var stderr_fds: [2]linux.fd_t = undefined;

    const p1: isize = @bitCast(linux.pipe2(&stdout_fds, .{ .CLOEXEC = true }));
    if (p1 < 0) return formatError(resp_buf, "pipe failed");
    const p2: isize = @bitCast(linux.pipe2(&stderr_fds, .{ .CLOEXEC = true }));
    if (p2 < 0) {
        _ = linux.close(stdout_fds[0]);
        _ = linux.close(stdout_fds[1]);
        return formatError(resp_buf, "pipe failed");
    }

    const fork_rc: isize = @bitCast(linux.fork());
    if (fork_rc < 0) {
        _ = linux.close(stdout_fds[0]);
        _ = linux.close(stdout_fds[1]);
        _ = linux.close(stderr_fds[0]);
        _ = linux.close(stderr_fds[1]);
        return formatError(resp_buf, "fork failed");
    }

    if (fork_rc == 0) {
        _ = linux.dup2(stdout_fds[1], 1);
        _ = linux.dup2(stderr_fds[1], 2);
        _ = linux.close(stdout_fds[0]);
        _ = linux.close(stdout_fds[1]);
        _ = linux.close(stderr_fds[0]);
        _ = linux.close(stderr_fds[1]);

        if (timeout > 0) {
            _ = linux.syscall1(.alarm, timeout);
        }

        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=linux",
        };
        _ = linux.execve("/bin/sh", @ptrCast(&sh_argv), @ptrCast(&envp));
        linux.exit_group(127);
    }

    _ = linux.close(stdout_fds[1]);
    _ = linux.close(stderr_fds[1]);

    const child_pid: linux.pid_t = @intCast(fork_rc);

    // Read both pipes concurrently using poll() to avoid deadlock.
    // If child fills stderr pipe buffer while we're blocked reading stdout,
    // both processes would deadlock without concurrent reads.
    const out = readPipesPoll(stdout_fds[0], stderr_fds[0]);
    const stdout_len = out.stdout_len;
    const stderr_len = out.stderr_len;
    _ = linux.close(stdout_fds[0]);
    _ = linux.close(stderr_fds[0]);

    var wstatus: u32 = 0;
    _ = linux.waitpid(child_pid, &wstatus, 0);
    const exit_code: i32 = if (wstatus & 0x7f == 0) @intCast((wstatus >> 8) & 0xff) else -1;

    const b64_stdout_len = std.base64.standard.Encoder.calcSize(stdout_len);
    if (b64_stdout_len > exec_b64_stdout.len) return formatError(resp_buf, "stdout too large");
    _ = std.base64.standard.Encoder.encode(exec_b64_stdout[0..b64_stdout_len], exec_stdout[0..stdout_len]);

    const b64_stderr_len = std.base64.standard.Encoder.calcSize(stderr_len);
    if (b64_stderr_len > exec_b64_stderr.len) return formatError(resp_buf, "stderr too large");
    _ = std.base64.standard.Encoder.encode(exec_b64_stderr[0..b64_stderr_len], exec_stderr[0..stderr_len]);

    return std.fmt.bufPrint(resp_buf,
        \\{{"ok":true,"exit_code":{},"stdout":"{s}","stderr":"{s}"}}
    , .{
        exit_code,
        exec_b64_stdout[0..b64_stdout_len],
        exec_b64_stderr[0..b64_stderr_len],
    }) catch formatError(resp_buf, "response too large");
}

fn readFully(fd: linux.fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[total..].ptr, buf[total..].len));
        if (rc <= 0) break;
        total += @intCast(rc);
    }
    return total;
}

const PipesResult = struct { stdout_len: usize, stderr_len: usize };

fn readPipesPoll(stdout_fd: linux.fd_t, stderr_fd: linux.fd_t) PipesResult {
    var stdout_total: usize = 0;
    var stderr_total: usize = 0;
    var open_fds: u8 = 2;

    var pfds = [2]linux.pollfd{
        .{ .fd = stdout_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = stderr_fd, .events = linux.POLL.IN, .revents = 0 },
    };

    while (open_fds > 0) {
        const poll_rc: isize = @bitCast(linux.poll(@ptrCast(&pfds), 2, -1));
        if (poll_rc <= 0) break;

        // Read stdout
        if (pfds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            if (stdout_total < exec_stdout.len) {
                const rc: isize = @bitCast(linux.read(stdout_fd, exec_stdout[stdout_total..].ptr, exec_stdout[stdout_total..].len));
                if (rc > 0) {
                    stdout_total += @intCast(rc);
                } else {
                    pfds[0].fd = -1; // Stop polling this fd
                    open_fds -= 1;
                }
            } else {
                pfds[0].fd = -1;
                open_fds -= 1;
            }
        }

        // Read stderr
        if (pfds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            if (stderr_total < exec_stderr.len) {
                const rc: isize = @bitCast(linux.read(stderr_fd, exec_stderr[stderr_total..].ptr, exec_stderr[stderr_total..].len));
                if (rc > 0) {
                    stderr_total += @intCast(rc);
                } else {
                    pfds[1].fd = -1;
                    open_fds -= 1;
                }
            } else {
                pfds[1].fd = -1;
                open_fds -= 1;
            }
        }
    }

    return .{ .stdout_len = stdout_total, .stderr_len = stderr_total };
}

var file_buf: [256 * 1024]u8 = undefined;
var file_b64_buf: [512 * 1024]u8 = undefined;

fn handleWriteFile(path: []const u8, data_b64: []const u8, mode: u32, resp_buf: []u8) []const u8 {
    const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(data_b64) catch {
        return formatError(resp_buf, "invalid base64");
    };
    if (decoded_len > file_buf.len) return formatError(resp_buf, "file too large");

    std.base64.standard.Decoder.decode(file_buf[0..decoded_len], data_b64) catch {
        return formatError(resp_buf, "base64 decode failed");
    };

    var path_buf: [512]u8 = undefined;
    const path_z = toPathZ(path, &path_buf) orelse return formatError(resp_buf, "path too long");

    const open_rc: isize = @bitCast(linux.open(path_z, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .CLOEXEC = true,
    }, mode));
    if (open_rc < 0) return formatError(resp_buf, "open failed");
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    writeAll(fd, file_buf[0..decoded_len]) catch {
        return formatError(resp_buf, "write failed");
    };

    return std.fmt.bufPrint(resp_buf, "{{\"ok\":true}}", .{}) catch "{}";
}

fn handleReadFile(path: []const u8, resp_buf: []u8) []const u8 {
    var path_buf: [512]u8 = undefined;
    const path_z = toPathZ(path, &path_buf) orelse return formatError(resp_buf, "path too long");

    const open_rc: isize = @bitCast(linux.open(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0));
    if (open_rc < 0) return formatError(resp_buf, "open failed");
    const fd: linux.fd_t = @intCast(open_rc);
    defer _ = linux.close(fd);

    const file_len = readFully(fd, &file_buf);

    const b64_len = std.base64.standard.Encoder.calcSize(file_len);
    if (b64_len > file_b64_buf.len) return formatError(resp_buf, "file too large");
    _ = std.base64.standard.Encoder.encode(file_b64_buf[0..b64_len], file_buf[0..file_len]);

    return std.fmt.bufPrint(resp_buf,
        \\{{"ok":true,"data":"{s}"}}
    , .{file_b64_buf[0..b64_len]}) catch formatError(resp_buf, "response too large");
}

const FORWARD_PORT: u32 = 1025;
const TRANSFER_PORT: u32 = 1026;

// Shared helpers for vsock listeners

fn toPathZ(path: []const u8, buf: *[512]u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf[0..path.len :0]);
}

var line_buf: [1024]u8 = undefined;

fn readLine(fd: linux.fd_t, buf: []u8) ?[]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const rc: isize = @bitCast(linux.read(fd, buf[total..].ptr, 1));
        if (rc <= 0) return null;
        if (buf[total] == '\n') return buf[0..total];
        total += 1;
    }
    return null;
}

/// Fork a child process that listens on a vsock port and dispatches connections.
fn startListener(port: u32, handler: *const fn (linux.fd_t) void) void {
    const fork_rc: isize = @bitCast(linux.fork());
    if (fork_rc != 0) return;

    const listen_fd = listenVsock(port) catch linux.exit_group(1);

    while (true) {
        const accept_rc: isize = @bitCast(linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (accept_rc < 0) continue;
        const conn_fd: linux.fd_t = @intCast(accept_rc);

        const child_rc: isize = @bitCast(linux.fork());
        if (child_rc < 0) {
            _ = linux.close(conn_fd);
            continue;
        }
        if (child_rc > 0) {
            _ = linux.close(conn_fd);
            var dummy: u32 = 0;
            while (true) {
                const w: isize = @bitCast(linux.waitpid(-1, &dummy, 1));
                if (w <= 0) break;
            }
            continue;
        }

        _ = linux.close(listen_fd);
        handler(conn_fd);
        _ = linux.close(conn_fd);
        linux.exit_group(0);
    }
}

fn listenVsock(port: u32) !linux.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);

    // SO_REUSEADDR: allow rebinding after snapshot restore (old listeners are dead
    // but the kernel's vsock port table was restored with them still bound)
    var one: u32 = 1;
    _ = linux.setsockopt(fd, 1, 2, @ptrCast(&one), @sizeOf(u32)); // SOL_SOCKET=1, SO_REUSEADDR=2

    const addr = SockaddrVm{ .port = port, .cid = 0xFFFFFFFF }; // VMADDR_CID_ANY
    const bind_rc: isize = @bitCast(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm)));
    if (bind_rc < 0) {
        _ = linux.close(fd);
        return error.BindFailed;
    }

    const listen_rc: isize = @bitCast(linux.listen(fd, 16));
    if (listen_rc < 0) {
        _ = linux.close(fd);
        return error.ListenFailed;
    }

    return fd;
}

var forward_relay_buf: [64 * 1024]u8 = undefined;

fn handleForwardConn(vsock_fd: linux.fd_t) void {
    const header = readLine(vsock_fd, &line_buf) orelse return;
    const port = jsonU32(header, "port");
    if (port == 0) return;

    // Connect to guest localhost:port
    const tcp_fd = tcpConnect(port);
    if (tcp_fd < 0) return;
    defer _ = linux.close(tcp_fd);

    // Bidirectional relay: vsock ↔ TCP
    var pfds = [2]linux.pollfd{
        .{ .fd = vsock_fd, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = tcp_fd, .events = linux.POLL.IN, .revents = 0 },
    };

    while (true) {
        const poll_rc: isize = @bitCast(linux.poll(@ptrCast(&pfds), 2, 300_000));
        if (poll_rc <= 0) break;

        if (pfds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n: isize = @bitCast(linux.read(vsock_fd, &forward_relay_buf, forward_relay_buf.len));
            if (n <= 0) break;
            writeAll(tcp_fd, forward_relay_buf[0..@intCast(n)]) catch break;
        }

        if (pfds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n: isize = @bitCast(linux.read(tcp_fd, &forward_relay_buf, forward_relay_buf.len));
            if (n <= 0) break;
            writeAll(vsock_fd, forward_relay_buf[0..@intCast(n)]) catch break;
        }
    }
}

fn tcpConnect(port: u32) linux.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return -1;
    const fd: linux.fd_t = @intCast(sock_rc);

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = @byteSwap(@as(u16, @intCast(port))),
        .addr = @byteSwap(@as(u32, 0x7f000001)), // 127.0.0.1
        .zero = .{0} ** 8,
    };

    const connect_rc: isize = @bitCast(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    if (connect_rc < 0) {
        _ = linux.close(fd);
        return -1;
    }
    return fd;
}

fn handleTransferConn(vsock_fd: linux.fd_t) void {
    const header = readLine(vsock_fd, &line_buf) orelse return;
    const method = jsonStr(header, "method") orelse return;
    const path = jsonStr(header, "path") orelse return;

    var path_buf: [512]u8 = undefined;
    const path_z = toPathZ(path, &path_buf) orelse return;

    if (std.mem.eql(u8, method, "upload")) {
        mkdirp(path_z);
        execWithFdRedirect("/bin/busybox", &.{ "tar", "x", "-C", path_z }, vsock_fd, 0);
    } else if (std.mem.eql(u8, method, "download")) {
        execWithFdRedirect("/bin/busybox", &.{ "tar", "c", "-C", path_z, "." }, vsock_fd, 1);
    }
}

/// Create a directory and parents via mkdir syscall (no fork/exec).
fn mkdirp(path_z: [*:0]const u8) void {
    // Try creating the leaf directory first
    const rc: isize = @bitCast(linux.mkdir(path_z, 0o755));
    if (rc >= 0 or rc == -@as(isize, @intCast(@intFromEnum(linux.E.EXIST)))) return;

    // Walk the path creating each component
    const path = std.mem.sliceTo(path_z, 0);
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/') {
            var component: [512]u8 = undefined;
            @memcpy(component[0..i], path[0..i]);
            component[i] = 0;
            _ = linux.mkdir(@ptrCast(component[0..i :0]), 0o755);
        }
    }
    _ = linux.mkdir(path_z, 0o755);
}

/// Fork+exec a command with one fd redirected (stdin or stdout).
fn execWithFdRedirect(
    bin: [*:0]const u8,
    args: []const [*:0]const u8,
    fd: linux.fd_t,
    target_fd: linux.fd_t, // 0 for stdin, 1 for stdout
) void {
    // Build argv with null terminator
    var argv: [8:null]?[*:0]const u8 = .{null} ** 8;
    argv[0] = bin;
    for (args, 0..) |arg, j| {
        if (j + 1 >= argv.len - 1) break;
        argv[j + 1] = arg;
    }

    const fork_rc: isize = @bitCast(linux.fork());
    if (fork_rc < 0) return;

    if (fork_rc == 0) {
        _ = linux.dup2(fd, target_fd);
        _ = linux.close(fd);
        _ = linux.execve(bin, @ptrCast(&argv), @ptrCast(&[_:null]?[*:0]const u8{}));
        linux.exit_group(127);
    }

    var status: u32 = 0;
    _ = linux.waitpid(@intCast(fork_rc), &status, 0);
}

fn formatError(buf: []u8, msg: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg}) catch "{}";
}

fn jsonStr(json: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [256]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\"", .{key}) catch return null;

    const key_pos = blk: {
        var pos: usize = 0;
        while (pos < json.len) {
            const found = std.mem.indexOf(u8, json[pos..], search) orelse return null;
            const abs = pos + found;
            if (abs == 0 or json[abs - 1] == '{' or json[abs - 1] == ',' or json[abs - 1] == ' ' or json[abs - 1] == '\t') {
                break :blk abs;
            }
            pos = abs + 1;
        }
        return null;
    };

    var i = key_pos + search.len;
    while (i < json.len and (json[i] == ' ' or json[i] == ':' or json[i] == '\t')) : (i += 1) {}

    if (i >= json.len) return null;

    if (json[i] == '"') {
        i += 1;
        const start = i;
        while (i < json.len) {
            if (json[i] == '\\' and i + 1 < json.len) {
                i += 2;
            } else if (json[i] == '"') {
                break;
            } else {
                i += 1;
            }
        }
        return json[start..i];
    } else if (json[i] >= '0' and json[i] <= '9') {
        const start = i;
        while (i < json.len and json[i] >= '0' and json[i] <= '9') : (i += 1) {}
        return json[start..i];
    } else if (i + 4 <= json.len and std.mem.eql(u8, json[i..][0..4], "true")) {
        return "true";
    } else if (i + 5 <= json.len and std.mem.eql(u8, json[i..][0..5], "false")) {
        return "false";
    }
    return null;
}

fn jsonU32(json: []const u8, key: []const u8) u32 {
    const s = jsonStr(json, key) orelse return 0;
    return std.fmt.parseUnsigned(u32, s, 10) catch 0;
}

pub fn main() !void {
    // Outer reconnect loop: after disconnect (e.g. snapshot restore),
    // the agent reconnects to the new host vsock listener.
    while (true) {
        const msg = "hearth-agent: connecting to host...\n";
        _ = linux.write(1, msg.ptr, msg.len);

        const sock = connectWithRetry() catch {
            const ts = linux.timespec{ .sec = 1, .nsec = 0 };
            _ = linux.nanosleep(&ts, null);
            continue;
        };

        const ready = "hearth-agent: connected to host\n";
        _ = linux.write(1, ready.ptr, ready.len);

        // (Re)start background listeners after each reconnect.
        // Forked children don't survive snapshot restore, so we
        // must restart them every time the control channel reconnects.
        startListener(FORWARD_PORT, handleForwardConn);
        startListener(TRANSFER_PORT, handleTransferConn);

        // Inner command loop
        while (true) {
            const payload = recvMsg(sock, &main_msg_buf) catch |err| {
                if (err == error.ConnectionClosed) break;
                break;
            };

            const method = jsonStr(payload, "method") orelse {
                const e = formatError(&main_resp_buf, "missing method");
                sendMsg(sock, e) catch break;
                continue;
            };

            const response = if (std.mem.eql(u8, method, "exec")) blk: {
                const cmd = jsonStr(payload, "cmd") orelse {
                    break :blk formatError(&main_resp_buf, "missing cmd");
                };
                const timeout = jsonU32(payload, "timeout");
                break :blk handleExec(cmd, timeout, &main_resp_buf);
            } else if (std.mem.eql(u8, method, "write_file")) blk: {
                const path = jsonStr(payload, "path") orelse {
                    break :blk formatError(&main_resp_buf, "missing path");
                };
                const data = jsonStr(payload, "data") orelse {
                    break :blk formatError(&main_resp_buf, "missing data");
                };
                const file_mode = jsonU32(payload, "mode");
                break :blk handleWriteFile(path, data, if (file_mode == 0) 0o644 else file_mode, &main_resp_buf);
            } else if (std.mem.eql(u8, method, "read_file")) blk: {
                const path = jsonStr(payload, "path") orelse {
                    break :blk formatError(&main_resp_buf, "missing path");
                };
                break :blk handleReadFile(path, &main_resp_buf);
            } else if (std.mem.eql(u8, method, "ping")) blk: {
                break :blk std.fmt.bufPrint(&main_resp_buf, "{{\"ok\":true}}", .{}) catch "{}";
            } else blk: {
                break :blk formatError(&main_resp_buf, "unknown method");
            };

            sendMsg(sock, response) catch break;
        }

        _ = linux.close(sock);

        // Brief pause before reconnect attempt
        const ts = linux.timespec{ .sec = 0, .nsec = 100_000_000 }; // 100ms
        _ = linux.nanosleep(&ts, null);
    }
}
