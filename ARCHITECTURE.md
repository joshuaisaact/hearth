# Architecture

## System Overview

Hearth provides local Firecracker microVM sandboxes for AI agent development. The architecture has three main layers:

```
┌─────────────────────────────────────────────┐
│              SDK / Public API                │
│  Sandbox.create() → exec() → snapshot()     │
├─────────────────────────────────────────────┤
│              Backend Interface               │
│  Direct (in-process)  │ Daemon (UDS / WebSocket)
├──────────┬──────────┬───────────────────────┤
│ VM Layer │ Network  │ Storage               │
│ firecracker│ TAP/NAT │ rootfs + overlays    │
│ jailer   │ port fwd │ snapshots (CoW)       │
└──────────┴──────────┴───────────────────────┘
         Linux host (KVM + user namespaces)
```

## Module Map

### `src/sandbox/`
The user-facing API. A `Sandbox` represents a running microVM with methods for exec, filesystem access, port forwarding, and lifecycle management. This is the only module that external consumers import.

### `src/vm/`
Manages Firecracker processes. Handles:
- Spawning `firecracker` with the correct config
- Jailer setup for unprivileged isolation
- Machine configuration (vCPUs, memory, drives)
- Graceful shutdown and kill

### `src/snapshot/`
Copy-on-write snapshot system. Supports:
- Full VM snapshots (memory + disk state)
- Restore from snapshot into a new Sandbox
- Snapshot diffing for incremental saves
- Base image layering (rootfs → overlay → snapshot)

### `src/network/`
Networking stack:
- TAP device creation and cleanup
- NAT/masquerade for outbound internet
- Port forwarding from host to guest
- Optional network isolation (no outbound)

### `agent/` (Zig — separate from TypeScript SDK)
Guest agent binary that runs inside the VM. Written in Zig, zero-allocation, ported from flint's agent. Three vsock listeners:
- **Port 1024** (control): exec, writeFile, readFile, ping, interactive spawn. Length-prefixed JSON protocol. Single-threaded, reconnects on snapshot restore.
- **Port 1025** (forward): TCP port forwarding. Host initiates via Firecracker CONNECT protocol. Agent dials guest localhost, relays bidirectionally via poll(). Fork-per-connection.
- **Port 1026** (transfer): Tar streaming upload/download. Host initiates via CONNECT. Agent fork+exec's busybox tar with vsock fd redirected to stdin/stdout.
- **Port 1027** (proxy): HTTP CONNECT proxy bridge. Guest TCP listener at 127.0.0.1:3128 relays to host-side proxy over vsock for internet access.

#### Interactive shell protocol

The control channel (port 1024) supports an interactive shell mode used by `hearth shell`. The guest agent allocates a PTY via libc `openpty()` and spawns the command attached to it. The agent enters a bidirectional poll loop:

- **PTY → host**: agent reads PTY master output, sends `{"type":"stdout","data":"<base64>"}` messages
- **host → PTY**: agent reads `{"type":"stdin","data":"<base64>"}` and `{"type":"resize","cols":N,"rows":N}` messages, writes decoded data to PTY master

**vsock POLLIN workaround**: Firecracker's virtio-vsock doesn't reliably trigger `POLLIN` in the guest kernel. The agent sets the vsock socket to `O_NONBLOCK` and tries a non-blocking read every 50ms poll iteration instead of relying on `poll()` to detect incoming host data.

### `src/agent/` (TypeScript — host-side client)
Host-side client that talks to the guest agent:
- Control channel: length-prefixed JSON requests over vsock UDS (guest-initiated connection)
- Port forwarding + transfers: Firecracker CONNECT protocol (host-initiated via `vsockConnect` helper)

### `src/daemon/`
Daemon server and client for multi-process and remote access:
- `server.ts`: UDS listener + optional WebSocket listener (via `--remote`). Extracts connection handling into a transport-agnostic `handleConnection()`.
- `client.ts`: `DaemonClient` auto-resolves connection target: env vars (`HEARTH_HOST/PORT/TOKEN`) → `~/.hearthrc` config → local UDS socket. Supports both `ws://` and Unix socket transports.
- `transport.ts`: `Transport` interface with `UdsTransport` (length-prefixed framing) and `WsTransport` (JSON text frames — WS provides its own framing).
- `ws-server.ts`: WebSocket listener with Bearer token auth validated in the HTTP upgrade handler. Binds `0.0.0.0`, disables `perMessageDeflate` for latency.
- `config.ts`: `~/.hearthrc` resolution, `generateToken()`, `resolveConnection()`.
- Port forwarding binds `0.0.0.0` for remote connections; the client fixes up the host address from the WS URL.

### `src/observe/`
Observability interface — the key differentiator. Every sandbox gets structured logs and metrics:
- Shared Victoria Logs + Victoria Metrics on the host, scoped by sandbox ID
- Vector runs inside each guest VM, collecting journald, /proc stats, OTel
- `sandbox.logs.query()` — LogQL queries over sandbox logs
- `sandbox.metrics.query()` — PromQL queries over sandbox metrics
- `sandbox.observe()` — single-call snapshot (CPU, memory, errors, recent logs)
- Data is ephemeral — deleted on `sandbox.destroy()`

## Data Flow

```
Agent (Claude, Codex, etc.)
  │
  ▼
SDK client (TypeScript)
  │  Sandbox.create({ template: "ubuntu-24.04" })
  ▼
Backend (in-process, or daemon via UDS / WebSocket)
  │  1. Clone rootfs overlay (cp --reflink=auto)
  │  2. Spawn firecracker + configure via REST API
  │  3. Configure networking (TAP, NAT)
  ▼
Firecracker microVM
  │  Boots in <150ms
  │  Guest agent on vsock
  ▼
Guest Linux (minimal rootfs)
  │  Runs agent commands
  │  Reports results over vsock
```

## Key Design Decisions

See `docs/design-docs/core-beliefs.md` for principles. Notable decisions:

1. **Local-only**: No cloud dependency. Everything runs on the developer's machine.
2. **Stock Firecracker**: Upstream binary, auto-downloaded. Not containers, not a custom VMM.
3. **Snapshot-first**: Fast clone from snapshots is the primary creation path.
4. **vsock for guest communication**: No network dependency for control plane.
5. **In-process or daemon**: `Sandbox` manages VMs in-process. `DaemonClient` connects via UDS (local) or WebSocket (remote) for multi-process and macOS access. `hearth shell` auto-starts the daemon if needed.
6. **Zig guest agent**: Zero-allocation, <1MB binary, ported from flint. Internal component — users never touch it.
7. **Observability-first**: Every sandbox gets logs + metrics via Vector (guest) → Victoria (host). Agents query via SDK, not manual tooling. This is the key differentiator vs E2B.
