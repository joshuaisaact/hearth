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

/// Set a SIGALRM timer using setitimer (works on both x86_64 and aarch64).
fn setAlarm(seconds: usize) void {
    // struct itimerval: { it_interval: timeval, it_value: timeval }
    // timeval: { tv_sec: isize, tv_usec: isize }
    // On aarch64 Linux there's no alarm syscall — use setitimer(ITIMER_REAL, ...).
    const Timeval = extern struct { tv_sec: isize, tv_usec: isize };
    const Itimerval = extern struct { it_interval: Timeval, it_value: Timeval };
    const val = Itimerval{
        .it_interval = .{ .tv_sec = 0, .tv_usec = 0 },
        .it_value = .{ .tv_sec = @intCast(seconds), .tv_usec = 0 },
    };
    // setitimer(ITIMER_REAL=0, &val, null)
    const rc = linux.syscall3(.setitimer, 0, @intFromPtr(&val), 0);
    if (@as(isize, @bitCast(rc)) < 0) {
        // If setitimer fails, write a warning to stderr. The process will run without a timeout.
        const msg = "warning: setitimer failed, no exec timeout\n";
        _ = linux.write(2, msg, msg.len);
    }
}

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

fn connectVsock(port: u32) !linux.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(AF_VSOCK, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);

    const addr = SockaddrVm{ .port = port, .cid = VSOCK_CID_HOST };
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
        return connectVsock(AGENT_PORT) catch {
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
            setAlarm(timeout);
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

var spawn_chunk: [8192]u8 = undefined;
var spawn_b64: [16384]u8 = undefined;
var spawn_msg: [32768]u8 = undefined;

fn handleSpawn(sock: linux.fd_t, cmd_str: []const u8, timeout: u32) void {
    var sh_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", null };

    var cmd_buf: [4096]u8 = undefined;
    if (cmd_str.len >= cmd_buf.len) {
        const e = formatError(&spawn_msg, "command too long");
        sendMsg(sock, e) catch {};
        return;
    }
    @memcpy(cmd_buf[0..cmd_str.len], cmd_str);
    cmd_buf[cmd_str.len] = 0;
    sh_argv[2] = @ptrCast(cmd_buf[0..cmd_str.len :0]);

    var stdout_fds: [2]linux.fd_t = undefined;
    var stderr_fds: [2]linux.fd_t = undefined;

    const p1: isize = @bitCast(linux.pipe2(&stdout_fds, .{ .CLOEXEC = true }));
    if (p1 < 0) { sendMsg(sock, formatError(&spawn_msg, "pipe failed")) catch {}; return; }
    const p2: isize = @bitCast(linux.pipe2(&stderr_fds, .{ .CLOEXEC = true }));
    if (p2 < 0) {
        _ = linux.close(stdout_fds[0]);
        _ = linux.close(stdout_fds[1]);
        sendMsg(sock, formatError(&spawn_msg, "pipe failed")) catch {};
        return;
    }

    const fork_rc: isize = @bitCast(linux.fork());
    if (fork_rc < 0) {
        _ = linux.close(stdout_fds[0]); _ = linux.close(stdout_fds[1]);
        _ = linux.close(stderr_fds[0]); _ = linux.close(stderr_fds[1]);
        sendMsg(sock, formatError(&spawn_msg, "fork failed")) catch {};
        return;
    }

    if (fork_rc == 0) {
        _ = linux.dup2(stdout_fds[1], 1);
        _ = linux.dup2(stderr_fds[1], 2);
        _ = linux.close(stdout_fds[0]); _ = linux.close(stdout_fds[1]);
        _ = linux.close(stderr_fds[0]); _ = linux.close(stderr_fds[1]);
        if (timeout > 0) setAlarm(timeout);
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

    // Stream chunks as they arrive
    var pfds = [2]linux.pollfd{
        .{ .fd = stdout_fds[0], .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = stderr_fds[0], .events = linux.POLL.IN, .revents = 0 },
    };
    var open_fds: u8 = 2;

    while (open_fds > 0) {
        const poll_rc: isize = @bitCast(linux.poll(@ptrCast(&pfds), 2, 300_000));
        if (poll_rc <= 0) break;

        if (pfds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n: isize = @bitCast(linux.read(stdout_fds[0], &spawn_chunk, spawn_chunk.len));
            if (n > 0) {
                sendStreamChunk(sock, "stdout", spawn_chunk[0..@intCast(n)]) catch break;
            } else {
                pfds[0].fd = -1;
                open_fds -= 1;
            }
        }

        if (pfds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n: isize = @bitCast(linux.read(stderr_fds[0], &spawn_chunk, spawn_chunk.len));
            if (n > 0) {
                sendStreamChunk(sock, "stderr", spawn_chunk[0..@intCast(n)]) catch break;
            } else {
                pfds[1].fd = -1;
                open_fds -= 1;
            }
        }
    }

    _ = linux.close(stdout_fds[0]);
    _ = linux.close(stderr_fds[0]);

    var wstatus: u32 = 0;
    _ = linux.waitpid(child_pid, &wstatus, 0);
    const exit_code: i32 = if (wstatus & 0x7f == 0) @intCast((wstatus >> 8) & 0xff) else -1;

    // Send exit message
    const exit_msg = std.fmt.bufPrint(&spawn_msg,
        \\{{"type":"exit","code":{}}}
    , .{exit_code}) catch return;
    sendMsg(sock, exit_msg) catch {};
}

// Static buffers for interactive spawn
var stdin_buf: [4096]u8 = undefined;
var interactive_recv_buf: [32768]u8 = undefined;

const c = @cImport({
    @cInclude("pty.h");
    @cInclude("poll.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
});

fn handleInteractiveSpawn(sock: linux.fd_t, cmd_str: []const u8, cols: u16, rows: u16) void {
    var sh_argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", null };

    var cmd_buf: [4096]u8 = undefined;
    if (cmd_str.len >= cmd_buf.len) {
        sendMsg(sock, formatError(&spawn_msg, "command too long")) catch {};
        return;
    }
    @memcpy(cmd_buf[0..cmd_str.len], cmd_str);
    cmd_buf[cmd_str.len] = 0;
    sh_argv[2] = @ptrCast(cmd_buf[0..cmd_str.len :0]);

    // Use libc openpty() — handles ptmx open, grantpt, unlockpt, slave open
    var master_fd: c_int = undefined;
    var slave_fd: c_int = undefined;
    var ws = c.winsize{ .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };

    if (c.openpty(&master_fd, &slave_fd, null, null, &ws) < 0) {
        sendMsg(sock, formatError(&spawn_msg, "openpty failed")) catch {};
        return;
    }

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(master_fd);
        _ = c.close(slave_fd);
        sendMsg(sock, formatError(&spawn_msg, "fork failed")) catch {};
        return;
    }

    if (pid == 0) {
        // Child: new session + controlling terminal
        _ = c.close(master_fd);
        _ = c.setsid();
        _ = c.ioctl(slave_fd, c.TIOCSCTTY, @as(c_int, 0));
        _ = c.dup2(slave_fd, 0);
        _ = c.dup2(slave_fd, 1);
        _ = c.dup2(slave_fd, 2);
        if (slave_fd > 2) _ = c.close(slave_fd);

        const envp = [_:null]?[*:0]const u8{
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
            "HOME=/root",
            "TERM=xterm-256color",
        };
        _ = linux.execve("/bin/sh", @ptrCast(&sh_argv), @ptrCast(&envp));
        linux.exit_group(127);
    }

    // Parent
    _ = c.close(slave_fd);
    const child_pid: linux.pid_t = @intCast(pid);

    var pfds = [2]c.struct_pollfd{
        .{ .fd = master_fd, .events = c.POLLIN, .revents = 0 },
        .{ .fd = sock, .events = c.POLLIN, .revents = 0 },
    };

    var child_exited = false;
    var recv_carry: usize = 0; // bytes carried over from partial frame reads

    while (true) {
        const poll_rc = c.poll(&pfds, 2, 300);
        if (poll_rc < 0) continue; // EINTR or other — retry

        // Check child exit on every iteration
        {
            var wstatus: c_int = 0;
            if (c.waitpid(child_pid, &wstatus, c.WNOHANG) > 0) {
                // Drain remaining PTY output
                while (true) {
                    const drain_n: isize = @bitCast(linux.read(master_fd, &spawn_chunk, spawn_chunk.len));
                    if (drain_n <= 0) break;
                    sendStreamChunk(sock, "stdout", spawn_chunk[0..@intCast(drain_n)]) catch break;
                }
                child_exited = true;
                const exit_code: i32 = if (c.WIFEXITED(wstatus)) c.WEXITSTATUS(wstatus) else -1;
                const exit_msg = std.fmt.bufPrint(&spawn_msg,
                    \\{{"type":"exit","code":{}}}
                , .{exit_code}) catch break;
                sendMsg(sock, exit_msg) catch {};
                break;
            }
        }

        if (poll_rc == 0) continue;

        // Read PTY output → send to host
        if (pfds[0].revents & (c.POLLIN | c.POLLHUP) != 0) {
            const n: isize = @bitCast(linux.read(master_fd, &spawn_chunk, spawn_chunk.len));
            if (n > 0) {
                sendStreamChunk(sock, "stdout", spawn_chunk[0..@intCast(n)]) catch break;
            } else if (pfds[0].revents & c.POLLHUP != 0) {
                break;
            }
        }

        // Read vsock → parse stdin/resize messages
        if (pfds[1].revents & (c.POLLIN | c.POLLHUP) != 0) {
            if (pfds[1].revents & c.POLLHUP != 0) break;

            const space = interactive_recv_buf.len - recv_carry;
            if (space == 0) { recv_carry = 0; continue; } // buffer full, drop
            const n: isize = @bitCast(linux.read(sock, interactive_recv_buf[recv_carry..].ptr, space));
            if (n <= 0) break;

            const recv_len: usize = recv_carry + @as(usize, @intCast(n));
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
                    writeAll(master_fd, stdin_buf[0..decoded_len]) catch break;
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

            // Carry over any partial frame to next read
            if (offset < recv_len) {
                const remaining = recv_len - offset;
                std.mem.copyForwards(u8, interactive_recv_buf[0..remaining], interactive_recv_buf[offset..recv_len]);
                recv_carry = remaining;
            } else {
                recv_carry = 0;
            }
        }
    }

    if (!child_exited) {
        // Drain remaining PTY output before closing
        while (true) {
            const drain_n: isize = @bitCast(linux.read(master_fd, &spawn_chunk, spawn_chunk.len));
            if (drain_n <= 0) break;
            sendStreamChunk(sock, "stdout", spawn_chunk[0..@intCast(drain_n)]) catch break;
        }

        // Signal the child to exit so waitpid doesn't block indefinitely
        _ = c.kill(child_pid, c.SIGHUP);
    }

    _ = c.close(master_fd);

    if (!child_exited) {
        var wstatus: c_int = 0;
        _ = c.waitpid(child_pid, &wstatus, 0);
        const exit_code: i32 = if (c.WIFEXITED(wstatus)) c.WEXITSTATUS(wstatus) else -1;
        const exit_msg = std.fmt.bufPrint(&spawn_msg,
            \\{{"type":"exit","code":{}}}
        , .{exit_code}) catch return;
        sendMsg(sock, exit_msg) catch {};
    }
}

fn sendStreamChunk(sock: linux.fd_t, stream_type: []const u8, data: []const u8) !void {
    const b64_len = std.base64.standard.Encoder.calcSize(data.len);
    if (b64_len > spawn_b64.len) return;
    _ = std.base64.standard.Encoder.encode(spawn_b64[0..b64_len], data);

    const msg = std.fmt.bufPrint(&spawn_msg,
        \\{{"type":"{s}","data":"{s}"}}
    , .{ stream_type, spawn_b64[0..b64_len] }) catch return;
    try sendMsg(sock, msg);
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

fn handleForwardConn(vsock_fd: linux.fd_t) void {
    const header = readLine(vsock_fd, &line_buf) orelse return;
    const port = jsonU32(header, "port");
    if (port == 0) return;

    const tcp_fd = tcpConnect(port);
    if (tcp_fd < 0) return;
    defer _ = linux.close(tcp_fd);

    proxyRelay(vsock_fd, tcp_fd);
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

// HTTP proxy bridge: TCP 127.0.0.1:3128 → vsock port 1027.
// Allows guest processes to use HTTP_PROXY for internet access.
// Each TCP connection is relayed to the host-side CONNECT proxy via vsock.
fn startProxyBridge() void {
    const fork_rc: isize = @bitCast(linux.fork());
    if (fork_rc != 0) return;

    // Listen on TCP 127.0.0.1:3128
    const listen_fd = tcpListen(PROXY_TCP_PORT) catch linux.exit_group(1);

    while (true) {
        const accept_rc: isize = @bitCast(linux.accept4(listen_fd, null, null, linux.SOCK.CLOEXEC));
        if (accept_rc < 0) continue;
        const tcp_fd: linux.fd_t = @intCast(accept_rc);

        const child_rc: isize = @bitCast(linux.fork());
        if (child_rc < 0) {
            _ = linux.close(tcp_fd);
            continue;
        }
        if (child_rc > 0) {
            _ = linux.close(tcp_fd);
            var dummy: u32 = 0;
            while (true) {
                const w: isize = @bitCast(linux.waitpid(-1, &dummy, 1));
                if (w <= 0) break;
            }
            continue;
        }

        // Child: connect to host via vsock and relay
        _ = linux.close(listen_fd);
        const vsock_fd = connectVsock(PROXY_VSOCK_PORT) catch {
            _ = linux.close(tcp_fd);
            linux.exit_group(1);
        };
        proxyRelay(tcp_fd, vsock_fd);
        _ = linux.close(tcp_fd);
        _ = linux.close(vsock_fd);
        linux.exit_group(0);
    }
}

fn tcpListen(port: u16) !linux.fd_t {
    const sock_rc: isize = @bitCast(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0));
    if (sock_rc < 0) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);

    var one: u32 = 1;
    _ = linux.setsockopt(fd, 1, 2, @ptrCast(&one), @sizeOf(u32)); // SO_REUSEADDR

    var addr: linux.sockaddr.in = .{
        .family = linux.AF.INET,
        .port = @byteSwap(port),
        .addr = @byteSwap(@as(u32, 0x7f000001)), // 127.0.0.1
        .zero = .{0} ** 8,
    };

    const bind_rc: isize = @bitCast(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in)));
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

var proxy_buf: [64 * 1024]u8 = undefined;

fn proxyRelay(fd_a: linux.fd_t, fd_b: linux.fd_t) void {
    var pfds = [2]linux.pollfd{
        .{ .fd = fd_a, .events = linux.POLL.IN, .revents = 0 },
        .{ .fd = fd_b, .events = linux.POLL.IN, .revents = 0 },
    };

    while (true) {
        const poll_rc: isize = @bitCast(linux.poll(@ptrCast(&pfds), 2, 300_000));
        if (poll_rc <= 0) break;

        if (pfds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n: isize = @bitCast(linux.read(fd_a, &proxy_buf, proxy_buf.len));
            if (n <= 0) break;
            writeAll(fd_b, proxy_buf[0..@intCast(n)]) catch break;
        }

        if (pfds[1].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n: isize = @bitCast(linux.read(fd_b, &proxy_buf, proxy_buf.len));
            if (n <= 0) break;
            writeAll(fd_a, proxy_buf[0..@intCast(n)]) catch break;
        }
    }
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
        startProxyBridge();

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
            } else if (std.mem.eql(u8, method, "spawn")) blk: {
                const cmd = jsonStr(payload, "cmd") orelse {
                    break :blk formatError(&main_resp_buf, "missing cmd");
                };
                const is_interactive = if (jsonStr(payload, "interactive")) |v| std.mem.eql(u8, v, "true") else false;
                if (is_interactive) {
                    const cols_val = jsonU32(payload, "cols");
                    const rows_val = jsonU32(payload, "rows");
                    const cols: u16 = if (cols_val == 0) 80 else @intCast(@min(cols_val, 65535));
                    const rows: u16 = if (rows_val == 0) 24 else @intCast(@min(rows_val, 65535));
                    handleInteractiveSpawn(sock, cmd, cols, rows);
                } else {
                    const timeout = jsonU32(payload, "timeout");
                    handleSpawn(sock, cmd, timeout);
                }
                continue;
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
