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

## macOS — M3+ via Lima

### How it works

Lima runs a Linux VM using Apple's Virtualization.framework with `nestedVirtualization: true`. This exposes `/dev/kvm` inside the Linux guest, allowing Firecracker to run.

**Requires**: Apple Silicon M3 or newer, macOS 15 (Sequoia) or later. Apple added nested virtualization support to the Virtualization.framework starting with the M3 chip. M1 and M2 Macs cannot do this.

### Setup

```bash
brew install lima

# Create a Lima instance with nested KVM
limactl create --name hearth --set '.nestedVirtualization=true' template://default
limactl start hearth

# Enter the Lima VM
limactl shell hearth

# Install dependencies inside the VM
# (Node.js, Docker, Zig)
npx hearth setup
```

### Daemon mode for transparent access

For a seamless experience, run the Hearth daemon inside the Lima VM. The daemon listens on `~/.hearth/daemon.sock`, which is accessible from macOS via Lima's shared filesystem mount:

```bash
# Inside Lima VM
hearth daemon &

# From macOS — connect to the daemon
import { DaemonClient } from "hearth/daemon";
const client = new DaemonClient();
await client.connect("~/.hearth/daemon.sock");
const sandbox = await client.create();
```

### Shared filesystem

Lima mounts `~` (home directory) into the VM by default. Add `~/.hearth` as a writable mount:

```yaml
# ~/.lima/hearth/lima.yaml
mounts:
  - location: "~/.hearth"
    writable: true
```

This means:
- Snapshots are accessible from both macOS and the Lima VM
- The daemon socket is accessible from macOS
- Upload/download paths must be within the mounted area

### Performance

- VM overhead: ~5% (Virtualization.framework is near-native)
- Nested KVM overhead: ~10-20% for CPU-bound workloads
- Firecracker boot time: ~150ms (slightly slower than bare metal ~125ms)
- Shared filesystem: virtiofs, good performance for most operations

### Chip support

| Chip | Nested KVM | Status |
|------|-----------|--------|
| M1, M1 Pro, M1 Max | No | Use remote daemon |
| M2, M2 Pro, M2 Max | No | Use remote daemon |
| M3, M3 Pro, M3 Max | Yes | Full support via Lima |
| M4, M4 Pro, M4 Max | Yes | Full support via Lima |
| Intel Mac | No | Use remote daemon |

As of late 2025, ~40-55% of Mac developers have M3+ chips. This percentage is growing as M1/M2 machines age out.

## macOS — M1/M2 via Remote Daemon

M1/M2 Macs cannot run Firecracker locally. The recommended approach is connecting to a remote Linux host running the Hearth daemon.

### Setup

```bash
# On a Linux server (e.g., Hetzner bare metal ~$35/mo)
npx hearth setup
hearth daemon

# On the Mac, SSH tunnel the daemon socket
ssh -L ~/.hearth/daemon.sock:/home/user/.hearth/daemon.sock user@server

# From macOS
import { DaemonClient } from "hearth/daemon";
const client = new DaemonClient();
await client.connect("~/.hearth/daemon.sock");
```

### Latency

| Scenario | Round-trip | Experience |
|----------|-----------|------------|
| Same region (US East → US East) | 10-30ms | Excellent |
| Same continent | 30-80ms | Good |
| Cross-continent | 100-200ms | Usable for most workflows |

For agent workloads (programmatic API calls, not interactive), even 100ms latency is acceptable since operations are batched.

### Cost

| Provider | Specs | Monthly | Notes |
|----------|-------|---------|-------|
| Hetzner AX41-NVMe | 6-core, 64GB | ~$44/mo | Shared among team |
| Hetzner AX52 | 8-core, 64GB | ~$53/mo | More CPU |
| AWS EC2 metal | Variable | ~$3,500/mo | Expensive |

A single Hetzner server can serve an entire team via the daemon.

## Future: libkrun Backend

libkrun (used by Podman on macOS) provides native microVM isolation on ALL Apple Silicon via Hypervisor.framework — no nested KVM needed. A future Hearth backend using libkrun would give M1/M2 users local sandboxes, but without Firecracker's snapshot/restore capability.

This is tracked as a potential v0.4+ item. The effort is medium (new VMM backend, different API), and the tradeoff is no snapshots (fresh boot only, ~1s instead of ~130ms).

## Future: Apple Containerization

Apple's Containerization framework (WWDC 2025, full support macOS 26) provides per-container VM isolation with sub-second boot on all Apple Silicon. It's OCI-compatible and built on Virtualization.framework. When it matures, it could serve as a macOS-native Hearth backend. Tracked for evaluation in 2027.
