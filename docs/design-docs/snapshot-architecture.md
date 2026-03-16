# Design Doc: Snapshot Architecture

**Status**: Partial (CoW strategy decided, memory/versioning/sharing open)
**Author**: —
**Last updated**: 2026-03-16

## Context

Snapshots are Hearth's core primitive for fast sandbox creation. Instead of booting a VM from scratch every time, we restore from a pre-captured snapshot of a fully-booted, configured VM.

## Goals

- Snapshot restore under 50ms
- Support snapshot trees (base → customized → agent-specific)
- Copy-on-write disk state (no full copies)
- Deterministic restore (same snapshot → same initial state)

## Snapshot Components

A Hearth snapshot consists of three artifacts:

### 1. Firecracker VM Snapshot
- **vmstate**: CPU registers, device state, interrupt controller state (~2MB)
- **memory**: Full guest memory dump (size = VM memory config, e.g., 256MB)
  - Firecracker supports diff snapshots (only dirty pages), which we should use for incremental snapshots

### 2. Disk State
- **Base rootfs**: Read-only, shared across all VMs using this template
- **Overlay**: Copy-on-write layer capturing guest filesystem mutations
  - Options: device-mapper snapshots, btrfs reflinks, or overlayfs with a file-backed block device

### 3. Metadata
```json
{
  "id": "snap_abc123",
  "parent": "snap_base_ubuntu2404",
  "created_at": "2026-03-16T12:00:00Z",
  "vm_config": {
    "vcpus": 2,
    "memory_mb": 256,
    "kernel": "vmlinux-6.1",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off"
  },
  "disk_layers": [
    {"type": "base", "path": "ubuntu-24.04.ext4", "sha256": "..."},
    {"type": "overlay", "path": "snap_abc123.overlay"}
  ],
  "agent_state": {
    "ready": true,
    "vsock_port": 52
  }
}
```

## Snapshot Lifecycle

```
1. PREPARE
   Boot VM from base image
   Wait for guest agent ready
   Install packages, configure environment

2. CAPTURE
   Pause VM (Firecracker PATCH /vm → Paused)
   Create Firecracker snapshot (PUT /snapshot/create)
   Snapshot overlay disk (reflink copy or dm-snapshot)
   Record metadata

3. STORE
   Move artifacts to snapshot store (~/.hearth/snapshots/{id}/)
   Register in snapshot index

4. RESTORE
   Copy/reflink snapshot artifacts to new VM directory
   Boot Firecracker with --restore-from-snapshot
   Wait for guest agent reconnect (vsock)
   Return new Sandbox handle
```

## Snapshot Store Layout

```
~/.hearth/
├── snapshots/
│   ├── index.json
│   ├── snap_base_ubuntu2404/
│   │   ├── metadata.json
│   │   ├── vmstate.snap
│   │   ├── memory.snap
│   │   └── overlay.ext4
│   └── snap_with_python/
│       ├── metadata.json
│       ├── vmstate.snap
│       ├── memory.snap (diff from parent)
│       └── overlay.ext4
├── bin/
│   ├── firecracker
│   ├── jailer
│   ├── victoria-logs
│   └── victoria-metrics
├── bases/
│   ├── ubuntu-24.04.ext4    (patched with hearth-agent)
│   └── vmlinux-6.1          (from Firecracker CI)
└── config.json
```

## Copy-on-Write Strategy

**Decision**: Reflinks with plain-copy fallback. Device-mapper as future opt-in.

### v0.1: `cp --reflink=auto`

A single `cp --reflink=auto` call handles disk cloning for both snapshot capture and restore:

- On **btrfs/XFS**: Instant, zero-copy reflink clone. The kernel shares underlying blocks between source and copy. Only blocks that are subsequently written to consume additional disk space.
- On **ext4/other**: Falls back to a full file copy. Correct but slower (~1-2s for a 2GB rootfs) and uses full disk space per snapshot.

This is the entire CoW implementation for v0.1. No setup, no root, no daemons, no filesystem assumptions. Works everywhere, fast where the filesystem supports it.

```typescript
// Pseudocode — this is all it takes
import { execFile } from "node:child_process";
await execFile("cp", ["--reflink=auto", srcOverlay, dstOverlay]);
```

### Detection and user guidance

On first run (`npx hearth setup`), we detect the filesystem backing `~/.hearth/` and report:

```
✓ Firecracker v1.6.0 downloaded
✓ Storage: /home/user/.hearth on btrfs — reflink CoW enabled (instant snapshots)
```

or:

```
✓ Firecracker v1.6.0 downloaded
⚠ Storage: /home/user/.hearth on ext4 — no reflink support (snapshots will use full copies)
  Tip: For instant snapshots, place ~/.hearth on a btrfs or XFS filesystem
```

### Future: device-mapper thin provisioning (opt-in)

For daemon mode / multi-agent scenarios with dozens of concurrent VMs, device-mapper thin provisioning gives true block-level CoW on any filesystem:

- Create a loopback-backed thin pool at `~/.hearth/dm-pool`
- Allocate thin volumes per VM overlay
- Snapshots are instant block-level clones

This requires root (or dm permissions) and explicit opt-in via config:

```json
{
  "storage": {
    "driver": "device-mapper",
    "pool_size_gb": 50
  }
}
```

Not planned for v0.1. Add when we have real users hitting the scaling wall on ext4.

## Open Questions

1. **Memory snapshot size**: A 256MB VM = 256MB memory snapshot. For a pool of 10 VMs, that's 2.5GB just in snapshots. Diff snapshots help but add restore-time overhead. What's the right tradeoff?
2. **Snapshot versioning**: Should snapshots be content-addressed (like git objects)? This would enable deduplication.
3. **Snapshot sharing**: Can users publish/pull snapshot templates? Like Docker Hub but for VM snapshots.
