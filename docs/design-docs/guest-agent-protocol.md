# Design Doc: Guest Agent Protocol

**Status**: Implemented
**Author**: —
**Last updated**: 2026-03-16

## Context

The guest agent is a lightweight process that runs inside each Firecracker VM. It provides the control plane between the host SDK and the guest operating system. All sandbox operations (exec, file I/O, health checks) go through this agent.

## Communication Channel: vsock

We use virtio-vsock for host↔guest communication. Advantages over network-based approaches:

- **No network dependency**: Works even if guest networking is disabled or broken
- **Low latency**: Bypasses the network stack entirely
- **Simple addressing**: Host connects to guest CID + port
- **No configuration**: No IP addresses, no DNS, no firewall rules

### Connection Model

```
Host (SDK/Daemon)                    Guest (Agent)
     │                                    │
     │  connect(guest_cid, port=52)       │
     │───────────────────────────────────►│
     │                                    │
     │  Request (JSON-framed)             │
     │───────────────────────────────────►│
     │                                    │
     │  Response (JSON-framed + stream)   │
     │◄───────────────────────────────────│
```

The guest agent connects outbound to the host on vsock port 1024 (host listens on a UDS that Firecracker proxies). Auxiliary listeners on ports 1025-1027 handle port forwarding, tar transfers, and HTTP proxy.

## Wire Protocol

Length-prefixed JSON messages over the vsock stream.

```
┌──────────┬──────────────────┐
│ len (u32)│ JSON payload      │
│ 4 bytes  │ variable length   │
│ little-  │                   │
│ endian   │                   │
└──────────┴──────────────────┘
```

### Request Types (implemented)

All requests use `"method"` to identify the operation. Responses are `{"ok":true,...}` or `{"ok":false,"error":"..."}`. Data fields use base64 encoding.

#### `exec`
Execute a command synchronously. Returns after the process exits.

```json
{"method": "exec", "cmd": "ls -la /", "timeout": 30}
```

Response (single message):
```json
{"ok": true, "exit_code": 0, "stdout": "<base64>", "stderr": "<base64>"}
```

#### `spawn`
Spawn a long-running process with streaming output. Non-interactive spawns use pipe-based stdout/stderr capture. Interactive spawns allocate a PTY.

```json
{"method": "spawn", "cmd": "/bin/bash", "interactive": true, "cols": 80, "rows": 24}
```

No ok response — the agent enters a streaming loop immediately. Stream messages:
```json
{"type": "stdout", "data": "<base64>"}
{"type": "stderr", "data": "<base64>"}
{"type": "exit", "code": 0}
```

Host→agent messages during an interactive spawn:
```json
{"type": "stdin", "data": "<base64>"}
{"type": "resize", "cols": 120, "rows": 40}
```

#### `write_file`
```json
{"method": "write_file", "path": "/tmp/script.py", "data": "<base64>", "mode": 493}
```

#### `read_file`
```json
{"method": "read_file", "path": "/etc/hostname"}
```
Response: `{"ok": true, "data": "<base64>"}`

#### `ping`
Health check.
```json
{"method": "ping"}
```
Response: `{"ok": true}`

## Guest Agent Implementation

**Decision**: Zig. Zero-allocation, static binary, ported from flint's agent.

The guest agent is written in Zig and compiled as a single static binary (`hearth-agent`). It is an internal component — users never interact with it directly. It ships baked into rootfs images.

### Constraints

- Single static binary, links libc (needed for `openpty`, `ioctl`)
- ~2.3MB on disk
- < 3MB RSS at runtime
- Zero dynamic allocation — all buffers are static, sized at compile time
- Runs as a service inside the guest (started by init)

### Design (ported from flint)

The agent follows flint's proven architecture:

- **Static buffers**: Fixed-size buffers for messages, exec output, file I/O, base64 encoding. No allocator needed after startup.
- **Single-threaded**: Blocking I/O on vsock. One request at a time. Simple, predictable, no concurrency bugs.
- **Shell exec**: All commands run via `fork` + `execve("/bin/sh", ["-c", cmd])`. Supports pipelines, redirects, env vars without parsing.
- **Pipe-based output capture**: stdout/stderr captured via pipe pairs, read in parent after child exits.
- **Timeout via SIGALRM**: Kernel-level timeout on command execution. Child killed on alarm.
- **Retry-on-connect**: Agent retries vsock connection to host with backoff during early boot (VMM may not be ready yet).

### Buffer Layout

```
msg_buf:        64 KB   — incoming request JSON
resp_buf:        1 MB   — outgoing response JSON
exec_stdout:   256 KB   — raw stdout from child process
exec_stderr:    64 KB   — raw stderr from child process
b64_stdout:    512 KB   — base64-encoded stdout
b64_stderr:    128 KB   — base64-encoded stderr
file_buf:      256 KB   — file read/write content
file_b64_buf:  512 KB   — base64-encoded file content
```

### Init Integration

Two modes:
1. **PID 1 mode**: Agent IS init. For minimal rootfs images where we control everything. Agent handles SIGCHLD reaping.
2. **Service mode**: Agent runs alongside a standard init (systemd, OpenRC). For full OS images where users need package managers, services, etc.

### Build

The agent lives in `agent/` at the repo root, separate from the TypeScript SDK in `src/`. Built with Zig's cross-compilation targeting `x86_64-linux` (and `aarch64-linux`). The compiled binary is checked into `agent/bin/` or downloaded during `npx hearth setup`.

### Multi-port architecture

The agent uses four vsock ports:

| Port | Purpose | Connection model |
|------|---------|-----------------|
| 1024 | Control (exec, spawn, file I/O, ping) | Agent connects outbound to host |
| 1025 | Port forwarding (TCP relay) | Host connects via Firecracker CONNECT |
| 1026 | Tar transfer (upload/download) | Host connects via Firecracker CONNECT |
| 1027 | HTTP proxy bridge (internet access) | Guest TCP 127.0.0.1:3128 → host vsock |

Ports 1025-1027 are forked listener processes, restarted on each snapshot restore reconnect.

## Multiplexing

The control channel is single-threaded and synchronous — one request at a time. The `spawn` method blocks the command loop for the duration of the spawned process (streaming events are sent inline). This is sufficient because the daemon server maintains one agent connection per sandbox, and the daemon's serial message queue prevents concurrent requests.

## Known issues

### vsock POLLIN not reliable in Firecracker guests

Firecracker's virtio-vsock implementation doesn't reliably trigger `POLLIN` in the guest kernel's `poll()` syscall. This means `poll()` on a vsock socket fd can return 0 (timeout) even when data is available to read. Blocking `read()` works correctly.

**Impact**: The interactive spawn poll loop couldn't detect incoming stdin/resize messages from the host.

**Workaround**: The interactive poll loop sets the vsock socket to `O_NONBLOCK` and tries a non-blocking `read()` on every poll iteration (50ms), regardless of `poll()` revents. If the read returns `EAGAIN`, no data is available — the loop continues. PTY master output is still detected normally via `poll()` since PTY fds don't have this issue.
