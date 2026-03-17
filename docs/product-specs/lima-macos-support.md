# Product Spec: Lima macOS Support

**Status**: Draft
**Last updated**: 2026-03-17

## Overview

macOS users with M3+ Apple Silicon can run Hearth locally via Lima, which provides a Linux VM with nested KVM support. This spec defines the CLI commands, automation, and developer experience for macOS Lima integration.

## Problem

Hearth requires `/dev/kvm` (Firecracker). macOS doesn't have KVM natively. Lima runs a Linux VM using Apple's Virtualization.framework with `nestedVirtualization: true`, exposing `/dev/kvm` inside the guest. The daemon already exists — what's missing is the automation to make this seamless.

Today a macOS user must manually:
1. Install Lima
2. Create an instance with the right settings
3. Shell into it
4. Install Node.js, Zig, Docker inside the VM
5. Run `hearth setup`
6. Start the daemon
7. Know to use `DaemonClient` from macOS

This should be a single command.

## Requirements

### Must have

- `hearth lima setup` — creates and provisions a Lima instance with everything needed
- `hearth lima start` — starts the Lima VM and daemon
- `hearth lima stop` — stops the daemon and Lima VM
- `hearth lima status` — reports whether Lima VM and daemon are running
- `hearth lima teardown` — destroys the Lima instance completely
- Platform detection: `hearth setup` on macOS prints a helpful message pointing to `hearth lima setup`
- Works on M3, M3 Pro, M3 Max, M4, M4 Pro, M4 Max

### Nice to have

- `hearth lima shell` — convenience wrapper for `limactl shell hearth`
- Auto-detect Lima daemon and use `DaemonClient` when `Sandbox.create()` is called on macOS
- Health check that verifies nested KVM works inside the Lima VM

### Out of scope

- M1/M2 support (no nested virt — use remote daemon, already documented)
- libkrun backend (v0.4+)
- Apple Containerization backend (v0.4+)
- GUI or menu bar app

## User Experience

### First-time setup

```bash
$ npx hearth lima setup

hearth lima setup

  Checking prerequisites...
    macOS: OK (Darwin arm64)
    Apple Silicon: M4 Pro (nested virtualization supported)
    Lima: OK (limactl v1.1.0)
    Docker: OK (needed for rootfs build inside VM)

  Creating Lima instance "hearth"...
    CPU: 4 cores
    Memory: 4 GiB
    Disk: 50 GiB
    Nested virtualization: enabled
    Shared mount: ~/.hearth (writable)
    ✓ Instance created

  Starting Lima VM...
    ✓ VM running

  Provisioning VM...
    Installing Node.js 22...  ✓
    ✓ Dependencies installed

  Running hearth setup inside VM...
    firecracker: downloading v1.15.0 for aarch64...  ✓
    kernel: downloading vmlinux-6.1.102...  ✓
    hearth-agent: building with Zig...  ✓
    rootfs: building via Docker...  ✓
    snapshot: creating base snapshot...  ✓

  Starting daemon...
    ✓ Daemon listening on ~/.hearth/daemon.sock

  Setup complete. From macOS, use DaemonClient:

    import { DaemonClient } from "hearth";
    const client = new DaemonClient();
    await client.connect();
    const sandbox = await client.create();
    const result = await sandbox.exec("echo hello from a microVM");
```

### Daily workflow

```bash
# Start (if not already running)
$ hearth lima start
Lima VM "hearth" started
Daemon listening on ~/.hearth/daemon.sock

# Check status
$ hearth lima status
Lima VM:  running (4 CPU, 4 GiB RAM, uptime 2h 15m)
Daemon:   running (3 active sandboxes)
Socket:   ~/.hearth/daemon.sock

# Stop when done
$ hearth lima stop
Daemon stopped
Lima VM stopped
```

### SDK usage from macOS

```typescript
import { DaemonClient } from "hearth";

// connect() with no args defaults to ~/.hearth/daemon.sock
const client = new DaemonClient();
await client.connect();

const sandbox = await client.create();
const { stdout } = await sandbox.exec("uname -a");
console.log(stdout); // Linux hearth 6.1.102 ... aarch64

await sandbox.destroy();
client.close();
```

## Lima Instance Configuration

```yaml
# Generated lima.yaml for the "hearth" instance
images:
  - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
    arch: "aarch64"

cpus: 4
memory: "4GiB"
disk: "50GiB"

nestedVirtualization: true

mounts:
  - location: "~/.hearth"
    writable: true

provision:
  - mode: system
    script: |
      #!/bin/bash
      set -eux
      # Install Node.js 22
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs
      # Docker (for rootfs build)
      curl -fsSL https://get.docker.com | bash -
      usermod -aG docker $LIMA_CIDATA_USER
      # KVM access
      [ -e /dev/kvm ] && chmod 666 /dev/kvm
```

## Constraints

- **Lima must be installed by the user** — we don't install it (requires Homebrew or manual install, user's choice)
- **M3+ only** — nested virtualization is a hardware requirement. We detect the chip and fail early on M1/M2 with a clear message pointing to the remote daemon docs
- **macOS 15+ (Sequoia)** — Apple added nested virt to Virtualization.framework in macOS 15
- **Shared filesystem for socket** — Lima mounts `~` by default but we need `~/.hearth` writable. The lima.yaml config handles this
- **Docker inside Lima** — rootfs build needs Docker. Lima can run Docker natively

## Error Handling

| Scenario | Behavior |
|----------|----------|
| Lima not installed | "Lima is required. Install: brew install lima" |
| M1/M2 chip | "Your chip doesn't support nested virtualization. See: docs/design-docs/platform-support.md for remote daemon setup" |
| macOS < 15 | "macOS 15 (Sequoia) or later required for nested virtualization" |
| Lima VM won't start | Show `limactl` stderr, suggest `limactl delete hearth && hearth lima setup` |
| /dev/kvm missing inside VM | "Nested virtualization not available. Ensure your Mac has an M3+ chip and macOS 15+" |
| Daemon socket not accessible from macOS | "Socket not found. Check Lima shared mount: limactl list" |
| `hearth lima start` when already running | No-op, print status |
| `hearth lima stop` when not running | No-op, print status |

## Decisions

1. **CPU/memory defaults** — 4 CPU / 4 GiB defaults, configurable via `--cpus` and `--memory` flags on `hearth lima setup`.
2. **Zig dependency** — Ship prebuilt agent binaries (cross-compiled aarch64-linux). No Zig inside Lima VM. Binary hosted as a GitHub release asset and downloaded during `hearth lima setup`.
3. **Auto-routing** — Explicit. macOS users use `DaemonClient` directly. No magic auto-detection in `Sandbox.create()`.
