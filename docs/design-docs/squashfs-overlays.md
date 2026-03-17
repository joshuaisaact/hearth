# Design Doc: Squashfs Base Layers + Overlay Filesystem

**Status**: Proposed (v0.4+)
**Last updated**: 2026-03-17

## Problem

Today every sandbox gets a full copy of the rootfs (~2GB ext4 image). Reflinks make this instant on btrfs/XFS, but:

- **ext4 and virtiofs (Lima)**: full 2GB copy per sandbox
- **Snapshots are large**: a snapshot of a sandbox that changed 10 files still stores the full 2GB rootfs
- **Not shippable**: the ext4 image is build-machine-specific, built via Docker. There's no way to distribute a pre-built environment as an artifact
- **Memory**: each sandbox loads its own rootfs into Firecracker's memory-mapped I/O, no sharing

## Proposal

Split the filesystem into a **read-only compressed base layer** (squashfs) and a **thin writable overlay** (ext4).

```
┌─────────────────────────────┐
│ Writable overlay (ext4)     │  ← per-sandbox, small (starts empty)
├─────────────────────────────┤
│ Read-only base (squashfs)   │  ← shared across all sandboxes
└─────────────────────────────┘
```

### How it works

1. **Base image**: Ubuntu 24.04 + Node.js + Claude Code + tools, compressed as squashfs (~400MB vs ~2GB ext4)
2. **Overlay**: Small ext4 image (e.g. 256MB, grows on demand) for per-sandbox writes
3. **Mount in guest init**: The init script mounts squashfs as lower, overlay ext4 as upper, exposes merged view
4. **Firecracker drives**: Two drives — `rootfs.squashfs` (read-only) and `overlay.ext4` (read-write)

### Init script changes

```sh
#!/bin/sh
mount -t squashfs /dev/vda /mnt/base
mount -t ext4 /dev/vdb /mnt/overlay
mkdir -p /mnt/overlay/upper /mnt/overlay/work
mount -t overlay overlay \
  -o lowerdir=/mnt/base,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work \
  /mnt/merged
pivot_root /mnt/merged /mnt/merged/mnt
# ... continue with proc/sys/dev mounts and agent start
```

## Benefits

### Shippable environments

A squashfs image is a self-contained, versioned, reproducible environment. Distribution options:

- **npm package asset**: `npx hearth pull ubuntu-claude` downloads `ubuntu-claude.squashfs`
- **OCI registry**: push/pull squashfs images like containers (they're just blobs)
- **GitHub releases**: same as the prebuilt agent binaries
- **Local build**: `hearth build --from Dockerfile --output my-env.squashfs`

Users can share environments: "here's a squashfs with Python 3.12 + PyTorch + CUDA stubs, use it with Hearth."

### Smaller snapshots

Snapshots only capture the overlay, not the base. A sandbox that installed a few npm packages might have a 50MB overlay vs 2GB full rootfs. This makes:

- Snapshot creation faster (less data to copy)
- Snapshot storage smaller
- Snapshot restore faster
- User snapshot sharing practical (ship the overlay + reference to the base)

### Memory efficiency

Multiple sandboxes sharing the same squashfs base can share the host page cache for the read-only layer. Firecracker maps drives into memory — if 10 sandboxes use the same `ubuntu-claude.squashfs`, the kernel caches it once.

### Faster sandbox creation

Instead of copying 2GB (even with reflinks), create a fresh 256MB overlay image. On any filesystem — no btrfs/XFS requirement for good performance.

## Tradeoffs

### Complexity

- Two Firecracker drives instead of one
- Init script needs overlay mount logic
- Snapshot format changes (overlay only, not full rootfs)
- Need to handle overlay exhaustion (full overlay ext4)
- Migration from current single-ext4 format

### Performance

- **Read performance**: squashfs is compressed — decompression adds CPU overhead on first read. Subsequent reads hit page cache. For agent workloads (mostly writing code, running tests), this is negligible.
- **Write performance**: overlay writes go to ext4, same as today. No regression.
- **Boot time**: additional mount step in init (~1-2ms). Negligible.

### Kernel requirements

- Guest kernel needs `CONFIG_SQUASHFS=y` and `CONFIG_OVERLAY_FS=y`. Firecracker CI kernels have both.

## Implementation sketch

### Phase 1: squashfs base

- Modify `setupRootfs()` to produce both `ubuntu-24.04.squashfs` and a small `overlay-template.ext4`
- Update Firecracker config to mount two drives
- Update init script with overlay mount logic
- Update snapshot to only copy the overlay

### Phase 2: shippable environments

- `hearth build` command: Dockerfile → squashfs
- `hearth pull` command: download pre-built squashfs from a registry
- Manifest format: `{ name, version, arch, sha256, size, squashfsUrl }`
- Base image selection in `Sandbox.create({ base: "ubuntu-claude" })`

### Phase 3: overlay-only snapshots

- Snapshot stores: `overlay.ext4` + `vmstate.snap` + `memory.snap` + reference to base squashfs
- Restore checks base squashfs exists, creates fresh overlay from snapshot
- Snapshot sharing: ship overlay + base reference (receiver must have the base)

## Open questions

1. **Overlay size**: start at 256MB? 1GB? Auto-grow? Firecracker drives can't resize at runtime, so we'd need to pick a max up front or use a sparse file.
2. **Multiple bases**: can a sandbox compose multiple squashfs layers? overlayfs supports multiple lowerdirs. Useful for `base + language + framework` stacking.
3. **Registry**: build our own, use OCI, or just GitHub releases? OCI is the industry standard but adds complexity.
4. **Migration**: how to handle existing ext4 snapshots when the format changes? Convert on first use? Keep both paths?
