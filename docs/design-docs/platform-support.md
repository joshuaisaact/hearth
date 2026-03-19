# Design Doc: Platform Support

**Status**: Partial (Linux native, Windows/macOS documented)
**Last updated**: 2026-03-17

## Overview

Hearth requires `/dev/kvm` for Firecracker. This document describes how each platform gets KVM access.

## Linux — Native

Works out of the box. Hearth's primary platform.

- Bare metal: direct KVM access
- VMs: nested virtualization (most cloud providers support this)
- Requirements: user must be in the `kvm` group or have ACL access to `/dev/kvm`

## Windows — WSL2

WSL2 runs a real Linux kernel on Hyper-V with KVM support since 2022. Firecracker runs directly inside WSL2 with no additional virtualization layer.

### Setup

```bash
# One-time WSL2 installation (PowerShell as admin)
wsl --install

# Enter WSL2
wsl

# Install Node.js, Docker, Zig inside WSL2
# Then run hearth setup as normal
npx hearth setup
```

### How it works

- WSL2 uses a Microsoft-maintained Linux kernel (5.15+) with `CONFIG_KVM=y`
- `/dev/kvm` is available natively — no nested virtualization needed
- Docker runs natively inside WSL2 (Docker Desktop optional)
- File system: WSL2 has its own ext4 filesystem. Accessing Windows drives via `/mnt/c/` is slow; keep `~/.hearth` on the Linux filesystem

### Limitations

- WSL2 networking: uses NAT. Ports forwarded to localhost are accessible from Windows
- Memory: WSL2 defaults to 50% of host RAM, configurable via `.wslconfig`
- Disk: default 256GB VHD, expandable

### Performance

Near-native. WSL2 is a real Linux kernel, not emulation. Firecracker inside WSL2 performs identically to bare metal Linux.

## macOS — Remote Daemon via WebSocket

Firecracker requires KVM, which is not available on macOS. The recommended approach is connecting to a remote Linux host running the Hearth daemon over WebSocket. This works on all Macs (M1, M2, M3, M4, Intel).

### Setup

```bash
# On the Linux server
npx hearth setup
hearth daemon --remote
# Prints: ws://0.0.0.0:9100, token, and ~/.hearthrc template

# On the Mac
hearth connect <server-ip> --token <token>
# Saves to ~/.hearthrc — all commands auto-resolve from here
```

Everything works transparently after this:

```bash
hearth shell                    # interactive bash over WebSocket
hearth shell claude-base        # restore a named snapshot
```

```typescript
import { DaemonClient } from "hearth";

const client = new DaemonClient();
await client.connect();                  // reads ~/.hearthrc automatically
const sandbox = await client.create();   // same API as local
```

### Connection config

`~/.hearthrc` (JSON):

```json
{ "host": "10.147.20.5", "port": 9100, "token": "a3f8c2..." }
```

Resolution order: env vars (`HEARTH_HOST`, `HEARTH_PORT`, `HEARTH_TOKEN`) → `~/.hearthrc` → local UDS socket.

### Auth model

Shared token (64 hex chars), generated automatically on first `hearth daemon --remote`. Validated in the HTTP upgrade handler before the WebSocket handshake completes. For LAN/VPN use (ZeroTier, Tailscale), plaintext token over WS is sufficient since the network layer is already encrypted.

### Network options

| Network | Setup | Latency | Notes |
|---------|-------|---------|-------|
| ZeroTier / Tailscale | Flat LAN, direct IP | <5ms | Recommended — simple, no port forwarding |
| SSH tunnel | `ssh -L 9100:localhost:9100 user@server` | 10-30ms | Fallback if VPN not available |
| Direct internet | Open port 9100 | Varies | Use only with token auth + firewall |

### Port forwarding

When connected remotely, `sandbox.forwardPort()` binds on `0.0.0.0` (not `127.0.0.1`) on the server, and the client automatically replaces the returned host address with the server's IP from the WebSocket URL. On ZeroTier/Tailscale the forwarded port is directly reachable from the Mac.

### Latency

| Scenario | Round-trip | Experience |
|----------|-----------|------------|
| Same LAN / ZeroTier | <5ms | Identical to local |
| Same region cloud | 10-30ms | Excellent |
| Same continent | 30-80ms | Good |
| Cross-continent | 100-200ms | Usable for agent workloads |

For agent workloads (programmatic API calls, not interactive), even 100ms latency is acceptable since operations are batched.

### Cost

| Provider | Specs | Monthly | Notes |
|----------|-------|---------|-------|
| Hetzner AX41-NVMe | 6-core, 64GB | ~$44/mo | Shared among team |
| Hetzner AX52 | 8-core, 64GB | ~$53/mo | More CPU |
| Home server | Any x86 + KVM | Free | Best latency on LAN |

A single server can serve an entire team via the daemon.

### Limitations

- `upload()` / `download()` pass local `hostPath` to the daemon — these don't work over remote connections (the daemon can't access the Mac's filesystem). Use `writeFile()` / `readFile()` for small files. Streaming tar over WS is planned as a follow-up.

## Future: libkrun Backend

libkrun (used by Podman on macOS) provides native microVM isolation on ALL Apple Silicon via Hypervisor.framework — no nested KVM needed. A future Hearth backend using libkrun would give M1/M2 users local sandboxes, but without Firecracker's snapshot/restore capability.

This is tracked as a potential v0.4+ item. The effort is medium (new VMM backend, different API), and the tradeoff is no snapshots (fresh boot only, ~1s instead of ~130ms).

## Future: Apple Containerization

Apple's Containerization framework (WWDC 2025, full support macOS 26) provides per-container VM isolation with sub-second boot on all Apple Silicon. It's OCI-compatible and built on Virtualization.framework. When it matures, it could serve as a macOS-native Hearth backend. Tracked for evaluation in 2027.
