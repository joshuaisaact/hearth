# Design Doc: Guest Agent Protocol

**Status**: Partial (language decided, protocol draft)
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

The guest agent listens on a well-known vsock port (52). The host initiates all connections.

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

### Request Types

#### `exec`
Execute a command in the guest.

```json
{
  "type": "exec",
  "id": "req_001",
  "command": ["ls", "-la", "/"],
  "cwd": "/home/user",
  "env": {"FOO": "bar"},
  "timeout_ms": 30000
}
```

Response: streamed stdout/stderr chunks, then a final status message.

```json
{"type": "stdout", "id": "req_001", "data": "total 64\n..."}
{"type": "stderr", "id": "req_001", "data": ""}
{"type": "exit", "id": "req_001", "code": 0}
```

#### `write_file`
Write content to a file in the guest.

```json
{
  "type": "write_file",
  "id": "req_002",
  "path": "/tmp/script.py",
  "content": "cHJpbnQoJ2hlbGxvJyk=",
  "encoding": "base64",
  "mode": "0755"
}
```

#### `read_file`
Read a file from the guest.

```json
{
  "type": "read_file",
  "id": "req_003",
  "path": "/etc/hostname"
}
```

#### `health`
Check if the agent is ready.

```json
{
  "type": "health",
  "id": "req_004"
}
```

Response:
```json
{
  "type": "health_ok",
  "id": "req_004",
  "uptime_ms": 1234,
  "load": [0.1, 0.05, 0.01]
}
```

## Guest Agent Implementation

**Decision**: Zig. Zero-allocation, static binary, ported from flint's agent.

The guest agent is written in Zig and compiled as a single static binary (`hearth-agent`). It is an internal component — users never interact with it directly. It ships baked into rootfs images.

### Constraints

- Single static binary, no runtime dependencies, no libc
- < 1MB on disk (flint's agent is ~500KB)
- < 1MB RSS at runtime
- Zero dynamic allocation — all buffers are static, sized at compile time
- Starts as PID 1 or via init system

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

## Multiplexing

v0.1 is single-threaded and synchronous — one request at a time. This matches flint's model and is sufficient for most agent workloads (send command, wait for result).

If we need concurrent exec in the future, we add request ID correlation and a simple event loop. The wire protocol already includes `id` fields to support this without a breaking change.

## Open Questions

1. **Binary protocol vs JSON**: JSON is debuggable but has overhead for large file transfers. Should we support a binary mode for bulk data? (Flint uses base64 in JSON — simple but ~33% overhead on binary data.)
2. **Authentication**: Do we need auth on the vsock channel? It's host-local, but in daemon mode multiple users might share a host.
3. **Agent binary distribution**: Check compiled binary into git (simple, reproducible) or build from source during `npx hearth setup` (requires Zig toolchain)?
