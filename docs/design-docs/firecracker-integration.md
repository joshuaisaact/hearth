# Design Doc: Firecracker Integration

**Status**: Partial (binary, kernel, rootfs decided; jailer details draft)
**Author**: —
**Last updated**: 2026-03-16

## Context

Hearth uses Firecracker as its microVM engine. This document describes how we interface with Firecracker, what we manage ourselves, and where the boundaries are.

## Background

Firecracker is Amazon's microVM monitor, designed for serverless workloads. Key properties:

- Boots a Linux guest in ~125ms
- Minimal device model (virtio-net, virtio-block, vsock, serial)
- Snapshot/restore support (full VM state including memory)
- Jailer for host-side isolation (chroot, seccomp, cgroups)
- REST API over Unix socket for configuration

Firecracker expects to be managed by an external orchestrator. It does not manage networking, storage, or lifecycle on its own. That's our job.

## Integration Architecture

```
hearth SDK
  │
  ├── Spawns firecracker binary (or communicates with daemon)
  │
  ├── Configures VM via Firecracker REST API (Unix socket)
  │   ├── PUT /machine-config (vCPUs, memory)
  │   ├── PUT /boot-source (kernel, boot args)
  │   ├── PUT /drives/{id} (rootfs, overlay drives)
  │   ├── PUT /network-interfaces/{id} (TAP device)
  │   ├── PUT /vsock (guest CID for agent comms)
  │   └── PUT /actions (InstanceStart)
  │
  ├── Manages jailer (optional, for unprivileged operation)
  │
  └── Communicates with guest agent over vsock
```

## Firecracker Binary Management

**Decision**: Stock Firecracker binary, auto-downloaded with system fallback.

We use the upstream Firecracker release binary (Apache 2.0). The binary is managed Playwright-style:

1. `npx hearth setup` downloads the correct Firecracker + jailer binaries for the host architecture from GitHub releases
2. Binaries are verified via SHA256 checksum and cached in `~/.hearth/bin/`
3. If `firecracker` is already on PATH and meets the minimum version, we use that instead
4. Version pinned in `package.json` under `hearth.firecrackerVersion`

### Resolution Flow

```
SDK needs firecracker binary
  │
  ├─ Check ~/.hearth/bin/firecracker → use if present + version matches
  ├─ Check PATH for firecracker     → use if present + version >= minimum
  └─ Otherwise                      → error with "run npx hearth setup"
```

### Why not a custom VMM?

The flint project (~/Coding/flint) is a custom Zig-based VMM in this workspace. We chose stock Firecracker for Hearth because:

- **Adoption**: Users trust a well-known, AWS-backed project
- **Maintenance**: Firecracker has a full team; we'd be maintaining a VMM AND an SDK
- **Snapshots**: Firecracker's snapshot/restore is battle-tested in Lambda
- **Compatibility**: Ecosystem tooling (rootfs builders, kernel configs) targets Firecracker

We can revisit this if we hit Firecracker limitations that a custom VMM would solve (e.g., faster boot, custom device model, tighter integration).

## Pinned Version

**Firecracker v1.15.0** (latest as of 2026-03-16).

`npx hearth setup` downloads:
- `firecracker-v1.15.0-{arch}.tgz` from GitHub releases (contains `firecracker` + `jailer` binaries)
- SHA256 verified via `firecracker-v1.15.0-{arch}.tgz.sha256.txt`

## Guest Kernel

**Decision**: Use Firecracker CI's recommended guest kernel.

Firecracker CI publishes tested guest kernels on S3 at:
```
s3://spec.ccfc.min/firecracker-ci/v1.15/$ARCH/vmlinux-*
```

`npx hearth setup` downloads the latest kernel for the pinned Firecracker version. This kernel is:
- Tested by Firecracker's own CI against the pinned version
- Minimal config (no modules, no initrd needed, serial console)
- Available for both x86_64 and aarch64

Stored at `~/.hearth/bases/vmlinux-{version}`.

## Base Rootfs

**Decision**: Start from Firecracker CI's Ubuntu rootfs, patched with hearth-agent.

Firecracker CI publishes Ubuntu rootfs images on S3 at:
```
s3://spec.ccfc.min/firecracker-ci/v1.15/$ARCH/ubuntu-*.squashfs
```

`npx hearth setup`:
1. Downloads the Ubuntu squashfs image
2. Unsquashes it
3. Patches in the `hearth-agent` binary at `/usr/local/bin/hearth-agent`
4. Adds an init hook to start the agent on boot
5. Packs as ext4 image at `~/.hearth/bases/ubuntu-{version}.ext4`

This gives us a known-good, Firecracker-tested Ubuntu base with our agent baked in. Users get a working sandbox with `apt`, `systemd`, and standard tooling out of the box.

### Future: Alpine / minimal rootfs

For users who want smaller images and faster snapshots, we can add an Alpine-based template later. The Ubuntu base is the safe default — familiar, well-tested, and matches what most agent workloads expect.

## KVM Access

Firecracker requires `/dev/kvm`. This means:

- **Linux only** for native operation (no macOS/Windows without a Linux VM host)
- User must have read/write access to `/dev/kvm` (typically via `kvm` group)
- Nested virtualization works but with performance penalty

### Non-Linux Platforms

For macOS/Windows developers, we should document a lightweight Linux VM approach (e.g., Lima, WSL2) as the host for Firecracker. This is out of scope for v0.1 but important for adoption.

## Jailer

The Firecracker jailer provides:
- chroot filesystem isolation
- seccomp-bpf syscall filtering
- cgroup resource limits
- UID/GID remapping

We should use the jailer by default in daemon mode. In direct mode (no daemon), the jailer adds complexity (needs root or CAP_SYS_ADMIN for cgroups). We may want a "lightweight" mode that skips the jailer for development.

## Snapshot/Restore

Firecracker snapshots capture:
- Guest memory (full or diff)
- Device state
- vCPU state

They do NOT capture:
- Disk contents (handled separately by our overlay system)
- Network state (connections are lost)
- vsock state (agent must reconnect)

Our snapshot system layers on top:
1. Pause VM via Firecracker API
2. Create Firecracker snapshot (memory + vmstate)
3. Snapshot the overlay filesystem (reflink copy or btrfs snapshot)
4. Resume or terminate original VM
5. Store snapshot metadata (config, network, mounts)

## Open Questions

1. **Jailer in direct mode**: How much isolation do we provide without root? Could we use user namespaces + seccomp without the full jailer?

2. **Memory overcommit**: How do we handle multiple VMs competing for memory? Firecracker supports balloon devices — do we use them?

3. **GPU passthrough**: Not supported by Firecracker. Is this a dealbreaker for ML agent use cases? What's the workaround?

4. **Rootfs customization**: Should `npx hearth setup` support `--template alpine` to build different base images? Or defer to post-v0.1?
