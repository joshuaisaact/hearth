# Architecture

## System Overview

Hearth provides local Firecracker microVM sandboxes for AI agent development. The architecture has three main layers:

```
┌─────────────────────────────────────────────┐
│              SDK / Public API                │
│  Sandbox.create() → exec() → snapshot()     │
├─────────────────────────────────────────────┤
│              Backend Interface               │
│  DirectBackend (v0.1) │ DaemonBackend (future)
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
- **Port 1024** (control): exec, writeFile, readFile, ping. Length-prefixed JSON protocol. Single-threaded, reconnects on snapshot restore.
- **Port 1025** (forward): TCP port forwarding. Host initiates via Firecracker CONNECT protocol. Agent dials guest localhost, relays bidirectionally via poll(). Fork-per-connection.
- **Port 1026** (transfer): Tar streaming upload/download. Host initiates via CONNECT. Agent fork+exec's busybox tar with vsock fd redirected to stdin/stdout.

#### Interactive shell protocol

The control channel (port 1024) supports an interactive shell mode used by `hearth shell`. The guest agent allocates a PTY via libc `openpty()` and spawns `/bin/bash` attached to it. Two additional host→guest message types extend the protocol:

- **`stdin`**: base64-encoded keystrokes forwarded from the host terminal
- **`resize`**: terminal dimensions (`cols`, `rows`) sent on SIGWINCH

All PTY output (stdout and stderr merged by the PTY) is streamed back to the host over the same control channel.

### `src/agent/` (TypeScript — host-side client)
Host-side client that talks to the guest agent:
- Control channel: length-prefixed JSON requests over vsock UDS (guest-initiated connection)
- Port forwarding + transfers: Firecracker CONNECT protocol (host-initiated via `vsockConnect` helper)

### `src/backend/`
Backend interface that abstracts how VMs are managed:
- `DirectBackend` (v0.1): SDK spawns and manages Firecracker processes in-process
- `DaemonBackend` (future): SDK talks to a long-running daemon over Unix socket
- User code is identical regardless of backend — `Sandbox.create()` works the same way
- Lockfile at `~/.hearth/lock` prevents resource collisions between concurrent processes

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
Backend (DirectBackend in-process, or DaemonBackend via Unix socket)
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
5. **In-process v0.1, daemon later**: `DirectBackend` manages VMs in-process. `DaemonBackend` (with pool, pre-warming) comes later. Same `Sandbox.create()` API either way.
6. **Zig guest agent**: Zero-allocation, <1MB binary, ported from flint. Internal component — users never touch it.
7. **Observability-first**: Every sandbox gets logs + metrics via Vector (guest) → Victoria (host). Agents query via SDK, not manual tooling. This is the key differentiator vs E2B.
