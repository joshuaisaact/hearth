// hearth-agent: guest-side sandbox daemon.
// Runs inside the VM, connects to host over vsock, executes commands.
// Protocol: 4-byte LE length prefix + JSON payload over vsock.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// libc imports for functions not available in std.posix
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/time.h");
});

const VSOCK_CID_HOST: u32 = 2;
const VMADDR_CID_ANY: u32 = 0xFFFF_FFFF;
const AGENT_PORT: u32 = 1024;
const AF_VSOCK: u16 = 40;
const MAX_MSG_SIZE: u32 = 16 * 1024 * 1024; // sized for base64-encoded file transfers
const SOL_SOCKET: u32 = 1;
const SO_REUSEADDR: u32 = 2;

// sockaddr_vm layout (linux/vm_sockets.h) — must be exactly 16 bytes
const SockaddrVm = extern struct {
    family: u16 = AF_VSOCK,
    reserved1: u16 = 0,
    port: u32,
    cid: u32,
    flags: u8 = 0,
    zero: [3]u8 = .{ 0, 0, 0 },

    comptime {
        if (@sizeOf(SockaddrVm) != 16) @compileError("SockaddrVm must be exactly 16 bytes");
    }
};

/// Set a SIGALRM timer (works on both x86_64 and aarch64 via libc setitimer).
fn setAlarm(seconds: usize) void {
    const val = c.struct_itimerval{
        .it_interval = .{ .tv_sec = 0, .tv_usec = 0 },
        .it_value = .{ .tv_sec = @intCast(seconds), .tv_usec = 0 },
    };
    if (c.setitimer(c.ITIMER_REAL, &val, null) < 0) {
        const msg = "warning: setitimer failed, no exec timeout\n";
        _ = posix.write(2, msg) catch {};
    }
}

fn writeAll(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        written += posix.write(fd, data[written..]) catch return error.WriteFailed;
    }
}

fn readAll(fd: posix.fd_t, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        const n = posix.read(fd, buf[got..]) catch return error.ReadFailed;
        if (n == 0) return error.ConnectionClosed;
        got += n;
    }
}

fn sendMsg(fd: posix.fd_t, payload: []const u8) !void {
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .little);
    try writeAll(fd, &len_buf);
    try writeAll(fd, payload);
}

fn recvMsg(fd: posix.fd_t, buf: []u8) ![]u8 {
    var len_buf: [4]u8 = undefined;
    try readAll(fd, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len > buf.len or len > MAX_MSG_SIZE) return error.MessageTooLarge;
    try readAll(fd, buf[0..len]);
    return buf[0..len];
}

fn connectVsock(port: u32) !posix.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(sock_rc);
    errdefer posix.close(fd);

    const addr = SockaddrVm{ .port = port, .cid = VSOCK_CID_HOST };
    const connect_rc: isize = @bitCast(linux.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrVm)));
    if (connect_rc < 0) return error.ConnectFailed;

    return fd;
}

// Retry vsock connect with backoff (VMM may not be ready at early boot)
fn connectWithRetry() !posix.fd_t {
    var attempts: u32 = 0;
    while (attempts < 50) : (attempts += 1) {
        return connectVsock(AGENT_PORT) catch {
            posix.nanosleep(0, 100_000_000); // 100ms
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

    const stdout_fds = posix.pipe() catch return formatError(resp_buf, "pipe failed");
    const stderr_fds = posix.pipe() catch {
        posix.close(stdout_fds[0]);
        posix.close(stdout_fds[1]);
        return formatError(resp_buf, "pipe failed");
    };

    const fork_result = posix.fork() catch {
        posix.close(stdout_fds[0]);
        posix.close(stdout_fds[1]);
        posix.close(stderr_fds[0]);
        posix.close(stderr_fds[1]);
        return formatError(resp_buf, "fork failed");
    };

    if (fork_result == 0) {
        // Child
        posix.dup2(stdout_fds[1], 1) catch linux.exit_group(126);
        posix.dup2(stderr_fds[1], 2) catch linux.exit_group(126);
        posix.close(stdout_fds[0]);
        posix.close(stdout_fds[1]);
        posix.close(stderr_fds[0]);
        posix.close(stderr_fds[1]);

        if (timeout > 0) setAlarm(timeout);

        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=linux",
        };
        _ = linux.execve("/bin/sh", @ptrCast(&sh_argv), @ptrCast(&envp));
        linux.exit_group(127);
    }

    posix.close(stdout_fds[1]);
    posix.close(stderr_fds[1]);

    const child_pid: posix.pid_t = @intCast(fork_result);

    const out = readPipesPoll(stdout_fds[0], stderr_fds[0]);
    posix.close(stdout_fds[0]);
    posix.close(stderr_fds[0]);

    const wresult = posix.waitpid(child_pid, 0);
    const exit_code: i32 = if (posix.W.IFEXITED(wresult.status)) @intCast(posix.W.EXITSTATUS(wresult.status)) else -1;

    const b64_stdout_len = std.base64.standard.Encoder.calcSize(out.stdout_len);
    if (b64_stdout_len > exec_b64_stdout.len) return formatError(resp_buf, "stdout too large");
    _ = std.base64.standard.Encoder.encode(exec_b64_stdout[0..b64_stdout_len], exec_stdout[0..out.stdout_len]);

    const b64_stderr_len = std.base64.standard.Encoder.calcSize(out.stderr_len);
    if (b64_stderr_len > exec_b64_stderr.len) return formatError(resp_buf, "stderr too large");
    _ = std.base64.standard.Encoder.encode(exec_b64_stderr[0..b64_stderr_len], exec_stderr[0..out.stderr_len]);

    return std.fmt.bufPrint(resp_buf,
        \\{{"ok":true,"exit_code":{},"stdout":"{s}","stderr":"{s}"}}
    , .{
        exit_code,
        exec_b64_stdout[0..b64_stdout_len],
        exec_b64_stderr[0..b64_stderr_len],
    }) catch formatError(resp_buf, "response too large");
}

var spawn_chunk: [8192]u8 = undefined;
var spawn_b64: [16384]u8 = undefined;
var spawn_msg: [32768]u8 = undefined;

fn handleSpawn(sock: posix.fd_t, cmd_str: []const u8, timeout: u32) void {
    var sh_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", null };

    var cmd_buf: [4096]u8 = undefined;
    if (cmd_str.len >= cmd_buf.len) {
        sendMsg(sock, formatError(&spawn_msg, "command too long")) catch {};
        return;
    }
    @memcpy(cmd_buf[0..cmd_str.len], cmd_str);
    cmd_buf[cmd_str.len] = 0;
    sh_argv[2] = @ptrCast(cmd_buf[0..cmd_str.len :0]);

    const stdout_fds = posix.pipe() catch { sendMsg(sock, formatError(&spawn_msg, "pipe failed")) catch {}; return; };
    const stderr_fds = posix.pipe() catch {
        posix.close(stdout_fds[0]);
        posix.close(stdout_fds[1]);
        sendMsg(sock, formatError(&spawn_msg, "pipe failed")) catch {};
        return;
    };

    const fork_result = posix.fork() catch {
        posix.close(stdout_fds[0]); posix.close(stdout_fds[1]);
        posix.close(stderr_fds[0]); posix.close(stderr_fds[1]);
        sendMsg(sock, formatError(&spawn_msg, "fork failed")) catch {};
        return;
    };

    if (fork_result == 0) {
        posix.dup2(stdout_fds[1], 1) catch linux.exit_group(126);
        posix.dup2(stderr_fds[1], 2) catch linux.exit_group(126);
        posix.close(stdout_fds[0]); posix.close(stdout_fds[1]);
        posix.close(stderr_fds[0]); posix.close(stderr_fds[1]);
        if (timeout > 0) setAlarm(timeout);
        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=linux",
        };
        _ = linux.execve("/bin/sh", @ptrCast(&sh_argv), @ptrCast(&envp));
        linux.exit_group(127);
    }

    posix.close(stdout_fds[1]);
    posix.close(stderr_fds[1]);

    const child_pid: posix.pid_t = @intCast(fork_result);
    streamPipesLoop(sock, stdout_fds[0], stderr_fds[0]);
    posix.close(stdout_fds[0]);
    posix.close(stderr_fds[0]);

    const wresult = posix.waitpid(child_pid, 0);
    sendExitMessage(sock, wresult.status);
}

/// Stream stdout/stderr from two pipe fds to the host via the control socket.
fn streamPipesLoop(sock: posix.fd_t, stdout_fd: posix.fd_t, stderr_fd: posix.fd_t) void {
    var pfds = [2]posix.pollfd{
        .{ .fd = stdout_fd, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
        .{ .fd = stderr_fd, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
    };
    var open_fds: u8 = 2;

    while (open_fds > 0) {
        const ready = posix.poll(&pfds, 300_000) catch break;
        if (ready == 0) continue;


        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(stdout_fd, &spawn_chunk) catch 0;
            if (n > 0) {
                sendStreamChunk(sock, "stdout", spawn_chunk[0..n]) catch break;
            } else {
                pfds[0].fd = -1;
                open_fds -= 1;
            }
        }

        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(stderr_fd, &spawn_chunk) catch 0;
            if (n > 0) {
                sendStreamChunk(sock, "stderr", spawn_chunk[0..n]) catch break;
            } else {
                pfds[1].fd = -1;
                open_fds -= 1;
            }
        }
    }
}

/// Format and send a {"type":"exit","code":N} message from a waitpid status.
fn sendExitMessage(sock: posix.fd_t, status: u32) void {
    const exit_code: i32 = if (posix.W.IFEXITED(status)) @intCast(posix.W.EXITSTATUS(status)) else -1;
    const exit_msg = std.fmt.bufPrint(&spawn_msg,
        \\{{"type":"exit","code":{}}}
    , .{exit_code}) catch return;
    sendMsg(sock, exit_msg) catch {};
}

// Static buffers for interactive spawn
var stdin_buf: [4096]u8 = undefined;
var interactive_recv_buf: [32768]u8 = undefined;

fn handleInteractiveSpawn(sock: posix.fd_t, cmd_str: []const u8, cols: u16, rows: u16) void {
    var sh_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", null };

    var cmd_buf: [4096]u8 = undefined;
    if (cmd_str.len >= cmd_buf.len) {
        sendMsg(sock, formatError(&spawn_msg, "command too long")) catch {};
        return;
    }
    @memcpy(cmd_buf[0..cmd_str.len], cmd_str);
    cmd_buf[cmd_str.len] = 0;
    sh_argv[2] = @ptrCast(cmd_buf[0..cmd_str.len :0]);

    // libc openpty() handles ptmx open, grantpt, unlockpt, slave open
    var master_fd: posix.fd_t = -1;
    var slave_fd: posix.fd_t = -1;
    var ws = c.winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };

    if (c.openpty(&master_fd, &slave_fd, null, null, &ws) < 0) {
        sendMsg(sock, formatError(&spawn_msg, "openpty failed")) catch {};
        return;
    }

    const fork_result = posix.fork() catch {
        posix.close(master_fd);
        posix.close(slave_fd);
        sendMsg(sock, formatError(&spawn_msg, "fork failed")) catch {};
        return;
    };

    if (fork_result == 0) {
        // Child: new session + controlling terminal
        posix.close(master_fd);
        _ = posix.setsid() catch linux.exit_group(126);
        _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0));
        posix.dup2(slave_fd, 0) catch linux.exit_group(126);
        posix.dup2(slave_fd, 1) catch linux.exit_group(126);
        posix.dup2(slave_fd, 2) catch linux.exit_group(126);
        if (slave_fd > 2) posix.close(slave_fd);

        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=xterm-256color",
        };
        _ = linux.execve("/bin/sh", @ptrCast(&sh_argv), @ptrCast(&envp));
        linux.exit_group(127);
    }

    // Parent
    posix.close(slave_fd);
    const child_pid: posix.pid_t = @intCast(fork_result);
    const child_exited = interactivePollLoop(sock, master_fd, child_pid);

    if (!child_exited) {
        drainPty(sock, master_fd);
        posix.kill(child_pid, posix.SIG.HUP) catch {};
    }

    posix.close(master_fd);

    if (!child_exited) {
        const wresult = posix.waitpid(child_pid, 0);
        sendExitMessage(sock, wresult.status);
    }
}

/// Bidirectional poll loop: PTY master output → host, host stdin/resize → PTY master.
/// Returns true if the child exited during the loop.
fn interactivePollLoop(sock: posix.fd_t, master_fd: posix.fd_t, child_pid: posix.pid_t) bool {
    var pfds = [2]posix.pollfd{
        .{ .fd = master_fd, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
        .{ .fd = sock, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
    };
    var recv_carry: usize = 0;

    while (true) {
        _ = posix.poll(&pfds, 300) catch break; // 300ms — child exit checked each iteration

        // Check child exit on every iteration
        const wresult = posix.waitpid(child_pid, posix.W.NOHANG);
        if (wresult.pid != 0) {
            drainPty(sock, master_fd);
            sendExitMessage(sock, wresult.status);
            return true;
        }

        // PTY output → host
        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(master_fd, &spawn_chunk) catch 0;
            if (n > 0) {
                sendStreamChunk(sock, "stdout", spawn_chunk[0..n]) catch break;
            } else if (pfds[0].revents & posix.POLL.HUP != 0) {
                break;
            }
        }

        // Host → PTY (stdin/resize)
        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (pfds[1].revents & posix.POLL.HUP != 0) break;
            recv_carry = processVsockInput(sock, master_fd, recv_carry) orelse break;
        }
    }
    return false;
}

/// Read framed messages from vsock and dispatch stdin/resize to the PTY master.
/// Returns updated recv_carry, or null if the connection closed.
fn processVsockInput(sock: posix.fd_t, master_fd: posix.fd_t, recv_carry: usize) ?usize {
    const space = interactive_recv_buf.len - recv_carry;
    if (space == 0) return 0; // buffer full, reset
    const n = posix.read(sock, interactive_recv_buf[recv_carry..][0..space]) catch return null;
    if (n == 0) return null;

    const recv_len: usize = recv_carry + n;
    var offset: usize = 0;
    while (offset + 4 <= recv_len) {
        const msg_len = std.mem.readInt(u32, interactive_recv_buf[offset..][0..4], .little);
        if (offset + 4 + msg_len > recv_len) break;
        const msg_data = interactive_recv_buf[offset + 4 .. offset + 4 + msg_len];
        offset += 4 + msg_len;

        const msg_type = jsonStr(msg_data, "type") orelse continue;

        if (std.mem.eql(u8, msg_type, "stdin")) {
            const b64_data = jsonStr(msg_data, "data") orelse continue;
            const decoded_len = std.base64.standard.Decoder.calcSizeForSlice(b64_data) catch continue;
            if (decoded_len > stdin_buf.len) continue;
            std.base64.standard.Decoder.decode(stdin_buf[0..decoded_len], b64_data) catch continue;
            writeAll(master_fd, stdin_buf[0..decoded_len]) catch return null;
        } else if (std.mem.eql(u8, msg_type, "resize")) {
            const new_cols = jsonU32(msg_data, "cols");
            const new_rows = jsonU32(msg_data, "rows");
            if (new_cols > 0 and new_cols <= 65535 and new_rows > 0 and new_rows <= 65535) {
                var new_ws = c.winsize{
                    .ws_row = @intCast(new_rows),
                    .ws_col = @intCast(new_cols),
                    .ws_xpixel = 0,
                    .ws_ypixel = 0,
                };
                _ = c.ioctl(master_fd, c.TIOCSWINSZ, &new_ws);
            }
        }
    }

    // Carry over partial frame
    if (offset < recv_len) {
        const remaining = recv_len - offset;
        std.mem.copyForwards(u8, interactive_recv_buf[0..remaining], interactive_recv_buf[offset..recv_len]);
        return remaining;
    }
    return 0;
}

/// Drain any remaining data from the PTY master and send to host.
fn drainPty(sock: posix.fd_t, master_fd: posix.fd_t) void {
    while (true) {
        const n = posix.read(master_fd, &spawn_chunk) catch break;
        if (n == 0) break;
        sendStreamChunk(sock, "stdout", spawn_chunk[0..n]) catch break;
    }
}

fn sendStreamChunk(sock: posix.fd_t, stream_type: []const u8, data: []const u8) !void {
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    if (b64_len > spawn_b64.len) return;
    _ = std.base64.standard.Encoder.encode(spawn_b64[0..b64_len], data);

    const msg = std.fmt.bufPrint(&spawn_msg,
        \\{{"type":"{s}","data":"{s}"}}
    , .{ stream_type, spawn_b64[0..b64_len] }) catch return;
    try sendMsg(sock, msg);
}

fn readFully(fd: posix.fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..]) catch break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

const PipesResult = struct { stdout_len: usize, stderr_len: usize };

fn readPipesPoll(stdout_fd: posix.fd_t, stderr_fd: posix.fd_t) PipesResult {
    var stdout_total: usize = 0;
    var stderr_total: usize = 0;
    var open_fds: u8 = 2;

    var pfds = [2]posix.pollfd{
        .{ .fd = stdout_fd, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
        .{ .fd = stderr_fd, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
    };

    while (open_fds > 0) {
        const ready = posix.poll(&pfds, -1) catch break;
        if (ready == 0) continue;


        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (stdout_total < exec_stdout.len) {
                const n = posix.read(stdout_fd, exec_stdout[stdout_total..]) catch 0;
                if (n > 0) {
                    stdout_total += n;
                } else {
                    pfds[0].fd = -1;
                    open_fds -= 1;
                }
            } else {
                pfds[0].fd = -1;
                open_fds -= 1;
            }
        }

        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            if (stderr_total < exec_stderr.len) {
                const n = posix.read(stderr_fd, exec_stderr[stderr_total..]) catch 0;
                if (n > 0) {
                    stderr_total += n;
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

    const fd = posix.openZ(path_z, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, mode) catch {
        return formatError(resp_buf, "open failed");
    };
    defer posix.close(fd);

    writeAll(fd, file_buf[0..decoded_len]) catch {
        return formatError(resp_buf, "write failed");
    };

    return std.fmt.bufPrint(resp_buf, "{{\"ok\":true}}", .{}) catch "{}";
}

fn handleReadFile(path: []const u8, resp_buf: []u8) []const u8 {
    var path_buf: [512]u8 = undefined;
    const path_z = toPathZ(path, &path_buf) orelse return formatError(resp_buf, "path too long");

    const fd = posix.openZ(path_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch {
        return formatError(resp_buf, "open failed");
    };
    defer posix.close(fd);

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
const PROXY_VSOCK_PORT: u32 = 1027;
const PROXY_TCP_PORT: u16 = 3128;

// Shared helpers for vsock listeners

fn toPathZ(path: []const u8, buf: *[512]u8) ?[*:0]const u8 {
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return @ptrCast(buf[0..path.len :0]);
}

var line_buf: [1024]u8 = undefined;

fn readLine(fd: posix.fd_t, buf: []u8) ?[]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.read(fd, buf[total..][0..1]) catch return null;
        if (n == 0) return null;
        if (buf[total] == '\n') return buf[0..total];
        total += 1;
    }
    return null;
}

/// Fork a child process that listens on a vsock port and dispatches connections.
fn startListener(port: u32, handler: *const fn (posix.fd_t) void) void {
    const fork_result = posix.fork() catch return;
    if (fork_result != 0) return;

    const listen_fd = listenVsock(port) catch linux.exit_group(1);

    while (true) {
        const accept_rc: isize = @bitCast(linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (accept_rc < 0) continue;
        const conn_fd: posix.fd_t = @intCast(accept_rc);

        const child = posix.fork() catch {
            posix.close(conn_fd);
            continue;
        };
        if (child > 0) {
            posix.close(conn_fd);
            // Reap any finished children (use raw syscall — posix.waitpid
            // panics on ECHILD when no children exist)
            while (true) {
                var dummy: u32 = 0;
                const w: isize = @bitCast(linux.waitpid(-1, &dummy, linux.W.NOHANG));
                if (w <= 0) break;
            }
            continue;
        }

        posix.close(listen_fd);
        handler(conn_fd);
        posix.close(conn_fd);
        linux.exit_group(0);
    }
}

fn listenVsock(port: u32) !posix.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(sock_rc);
    errdefer posix.close(fd);

    // SO_REUSEADDR: allow rebinding after snapshot restore (old listeners are dead
    // but the kernel's vsock port table was restored with them still bound)
    var one: u32 = 1;
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(u32));

    const addr = SockaddrVm{ .port = port, .cid = VMADDR_CID_ANY };
    const bind_rc: isize = @bitCast(linux.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrVm)));
    if (bind_rc < 0) return error.BindFailed;

    const listen_rc: isize = @bitCast(linux.listen(fd, 16));
    if (listen_rc < 0) return error.ListenFailed;

    return fd;
}

fn handleForwardConn(vsock_fd: posix.fd_t) void {
    const header = readLine(vsock_fd, &line_buf) orelse return;
    const port = jsonU32(header, "port");
    if (port == 0) return;

    const tcp_fd = tcpConnect(port) orelse return;
    defer posix.close(tcp_fd);

    proxyRelay(vsock_fd, tcp_fd);
}

fn tcpConnect(port: u32) ?posix.fd_t {
    const port16 = std.math.cast(u16, port) orelse return null;
    const sock_rc: isize = @bitCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return null;
    const fd: posix.fd_t = @intCast(sock_rc);

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = @byteSwap(port16),
        .addr = @byteSwap(@as(u32, 0x7f000001)), // 127.0.0.1
        .zero = .{0} ** 8,
    };

    const connect_rc: isize = @bitCast(linux.connect(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    if (connect_rc < 0) {
        posix.close(fd);
        return null;
    }
    return fd;
}

// HTTP proxy bridge: TCP 127.0.0.1:3128 → vsock port 1027.
// Allows guest processes to use HTTP_PROXY for internet access.
// Each TCP connection is relayed to the host-side CONNECT proxy via vsock.
fn startProxyBridge() void {
    const fork_result = posix.fork() catch return;
    if (fork_result != 0) return;

    const listen_fd = tcpListen(PROXY_TCP_PORT) catch linux.exit_group(1);

    while (true) {
        const accept_rc: isize = @bitCast(linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (accept_rc < 0) continue;
        const tcp_fd: posix.fd_t = @intCast(accept_rc);

        const child = posix.fork() catch {
            posix.close(tcp_fd);
            continue;
        };
        if (child > 0) {
            posix.close(tcp_fd);
            while (true) {
                var dummy: u32 = 0;
                const w: isize = @bitCast(linux.waitpid(-1, &dummy, linux.W.NOHANG));
                if (w <= 0) break;
            }
            continue;
        }

        // Child: connect to host via vsock and relay
        posix.close(listen_fd);
        const vsock_fd = connectVsock(PROXY_VSOCK_PORT) catch {
            posix.close(tcp_fd);
            linux.exit_group(1);
        };
        proxyRelay(tcp_fd, vsock_fd);
        posix.close(tcp_fd);
        posix.close(vsock_fd);
        linux.exit_group(0);
    }
}

fn tcpListen(port: u16) !posix.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: posix.fd_t = @intCast(sock_rc);
    errdefer posix.close(fd);

    var one: u32 = 1;
    _ = linux.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, @ptrCast(&one), @sizeOf(u32));

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = @byteSwap(port),
        .addr = @byteSwap(@as(u32, 0x7f000001)), // 127.0.0.1
        .zero = .{0} ** 8,
    };

    const bind_rc: isize = @bitCast(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
    if (bind_rc < 0) return error.BindFailed;

    const listen_rc: isize = @bitCast(linux.listen(fd, 16));
    if (listen_rc < 0) return error.ListenFailed;

    return fd;
}

var proxy_buf: [64 * 1024]u8 = undefined;

fn proxyRelay(fd_a: posix.fd_t, fd_b: posix.fd_t) void {
    var pfds = [2]posix.pollfd{
        .{ .fd = fd_a, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
        .{ .fd = fd_b, .events = posix.POLL.IN | posix.POLL.HUP, .revents = 0 },
    };

    while (true) {
        const ready = posix.poll(&pfds, 300_000) catch break;
        if (ready == 0) continue;


        if (pfds[0].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(fd_a, &proxy_buf) catch break;
            if (n == 0) break;
            writeAll(fd_b, proxy_buf[0..n]) catch break;
        }

        if (pfds[1].revents & (posix.POLL.IN | posix.POLL.HUP) != 0) {
            const n = posix.read(fd_b, &proxy_buf) catch break;
            if (n == 0) break;
            writeAll(fd_a, proxy_buf[0..n]) catch break;
        }
    }
}

fn handleTransferConn(vsock_fd: posix.fd_t) void {
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

/// Create a directory and parents.
fn mkdirp(path_z: [*:0]const u8) void {
    posix.mkdirZ(path_z, 0o755) catch |err| {
        if (err == error.PathAlreadyExists) return;
        // Walk the path creating each component
        const path = std.mem.sliceTo(path_z, 0);
        var i: usize = 1;
        while (i < path.len) : (i += 1) {
            if (path[i] == '/') {
                var component: [512]u8 = undefined;
                @memcpy(component[0..i], path[0..i]);
                component[i] = 0;
                posix.mkdirZ(@ptrCast(component[0..i :0]), 0o755) catch {};
            }
        }
        posix.mkdirZ(path_z, 0o755) catch {};
    };
}

/// Fork+exec a command with one fd redirected (stdin or stdout).
fn execWithFdRedirect(
    bin: [*:0]const u8,
    args: []const [*:0]const u8,
    fd: posix.fd_t,
    target_fd: posix.fd_t, // 0 for stdin, 1 for stdout
) void {
    var argv: [8:null]?[*:0]const u8 = .{null} ** 8;
    argv[0] = bin;
    for (args, 0..) |arg, j| {
        if (j + 1 >= argv.len - 1) break;
        argv[j + 1] = arg;
    }

    const fork_result = posix.fork() catch return;

    if (fork_result == 0) {
        posix.dup2(fd, target_fd) catch linux.exit_group(126);
        posix.close(fd);
        _ = linux.execve(bin, @ptrCast(&argv), @ptrCast(&[_:null]?[*:0]const u8{}));
        linux.exit_group(127);
    }

    _ = posix.waitpid(@intCast(fork_result), 0);
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

/// Process commands from the host until the connection drops.
fn commandLoop(sock: posix.fd_t) void {
    while (true) {
        const payload = recvMsg(sock, &main_msg_buf) catch break;

        const method = jsonStr(payload, "method") orelse {
            sendMsg(sock, formatError(&main_resp_buf, "missing method")) catch break;
            continue;
        };

        // Spawn methods send multiple messages directly — no single response.
        if (std.mem.eql(u8, method, "spawn")) {
            dispatchSpawn(sock, payload);
            continue;
        }

        const response = dispatchCommand(method, payload);
        sendMsg(sock, response) catch break;
    }
}

fn dispatchCommand(method: []const u8, payload: []const u8) []const u8 {
    if (std.mem.eql(u8, method, "exec")) {
        const cmd = jsonStr(payload, "cmd") orelse return formatError(&main_resp_buf, "missing cmd");
        return handleExec(cmd, jsonU32(payload, "timeout"), &main_resp_buf);
    } else if (std.mem.eql(u8, method, "write_file")) {
        const path = jsonStr(payload, "path") orelse return formatError(&main_resp_buf, "missing path");
        const data = jsonStr(payload, "data") orelse return formatError(&main_resp_buf, "missing data");
        const file_mode = jsonU32(payload, "mode");
        return handleWriteFile(path, data, if (file_mode == 0) 0o644 else file_mode, &main_resp_buf);
    } else if (std.mem.eql(u8, method, "read_file")) {
        const path = jsonStr(payload, "path") orelse return formatError(&main_resp_buf, "missing path");
        return handleReadFile(path, &main_resp_buf);
    } else if (std.mem.eql(u8, method, "ping")) {
        return std.fmt.bufPrint(&main_resp_buf, "{{\"ok\":true}}", .{}) catch "{}";
    } else {
        return formatError(&main_resp_buf, "unknown method");
    }
}

fn dispatchSpawn(sock: posix.fd_t, payload: []const u8) void {
    const cmd = jsonStr(payload, "cmd") orelse {
        sendMsg(sock, formatError(&main_resp_buf, "missing cmd")) catch {};
        return;
    };
    const is_interactive = if (jsonStr(payload, "interactive")) |v| std.mem.eql(u8, v, "true") else false;
    if (is_interactive) {
        const cols_val = jsonU32(payload, "cols");
        const rows_val = jsonU32(payload, "rows");
        const cols: u16 = if (cols_val == 0) 80 else @intCast(@min(cols_val, 65535));
        const rows: u16 = if (rows_val == 0) 24 else @intCast(@min(rows_val, 65535));
        handleInteractiveSpawn(sock, cmd, cols, rows);
    } else {
        handleSpawn(sock, cmd, jsonU32(payload, "timeout"));
    }
}

pub fn main() !void {
    // Outer reconnect loop: after disconnect (e.g. snapshot restore),
    // the agent reconnects to the new host vsock listener.
    while (true) {
        _ = posix.write(1, "hearth-agent: connecting to host...\n") catch {};

        const sock = connectWithRetry() catch {
            posix.nanosleep(1, 0);
            continue;
        };

        _ = posix.write(1, "hearth-agent: connected to host\n") catch {};

        // (Re)start background listeners after each reconnect.
        // Forked children don't survive snapshot restore, so we
        // must restart them every time the control channel reconnects.
        startListener(FORWARD_PORT, handleForwardConn);
        startListener(TRANSFER_PORT, handleTransferConn);
        startProxyBridge();

        commandLoop(sock);

        posix.close(sock);

        // Brief pause before reconnect attempt
        posix.nanosleep(0, 100_000_000); // 100ms
    }
}
