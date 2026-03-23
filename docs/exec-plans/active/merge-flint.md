# Replace Firecracker with Flint VMM

## Context

Hearth currently uses Firecracker (downloaded binary, v1.15.0) as its VMM. We built Flint — a custom KVM-based microVMM in Zig — at `../flint`. Flint covers everything Hearth needs and we want to merge it in, replacing Firecracker entirely.

The Flint source lives at `../flint/`. Key directories: `src/` (VMM core), `build.zig`. The guest agent in Flint (`src/agent.zig`) is redundant — `agent/src/main.zig` in this repo (hearth-agent) is the superset. Flint's pool mode (`src/pool.zig`, `src/pool_api.zig`) and sandbox proxy (`src/sandbox.zig`) are also redundant since Hearth manages those at a higher level.

## What to do

### Phase 1: Copy Flint VMM into this repo

Create `vmm/` at the repo root. Copy from `../flint/`:
- `src/` → `vmm/src/` (the VMM source)
- `build.zig` → `vmm/build.zig`
- `build.zig.zon` → `vmm/build.zig.zon` (if it exists)

Then delete the files Hearth doesn't need from `vmm/src/`:
- `agent.zig` — hearth-agent replaces this
- `pool.zig` — Hearth manages sandbox lifecycle
- `pool_api.zig` — Hearth manages acquire/release
- `sandbox.zig` — Hearth talks to hearth-agent directly

Update `vmm/src/main.zig` to remove imports and code paths that reference the deleted files (pool mode, sandbox agent setup). The pool subcommand, `--ready-cmd`, `--pool-size`, `--pool-sock` flags, agent listener/accept logic, and sandbox API endpoints in the post-boot API should all be removed. Keep the core: boot, restore, pre-boot API, post-boot API (pause/resume/snapshot-create/vm-status), jail, seccomp.

Update `vmm/build.zig` to remove the `flint-agent` build target. Only build the `flint` (VMM) binary.

Verify: `cd vmm && zig build` succeeds. Tests that reference deleted modules will need updating — remove pool and sandbox tests from `tests.zig`.

### Phase 2: Replace FirecrackerApi with FlintApi

**`src/vm/api.ts`** — Rename class to `FlintApi` (or `VmmApi`). The only method that needs changing is `loadSnapshot`:

Current (Firecracker format):
```typescript
loadSnapshot(snapshotPath: string, memFilePath: string, resumeVm: boolean = false): Promise<void> {
  return this.request("PUT", "/snapshot/load", {
    snapshot_path: snapshotPath,
    mem_backend: { backend_path: memFilePath, backend_type: "File" },
    resume_vm: resumeVm,
  });
}
```

New (Flint format — two-phase protocol):
```typescript
loadSnapshot(snapshotPath: string, memFilePath: string): Promise<void> {
  return this.request("PUT", "/snapshot/load", {
    snapshot_path: snapshotPath,
    mem_file_path: memFilePath,
  });
}
```

Flint uses a two-phase protocol: `PUT /snapshot/load` stores config, then `PUT /actions InstanceStart` triggers restore. So everywhere that currently calls `api.loadSnapshot(path, mem, true)` needs to call `api.loadSnapshot(path, mem)` followed by `api.start()`.

All other methods (`putMachineConfig`, `putBootSource`, `putDrive`, `putVsock`, `start`, `pause`, `resume`, `createSnapshot`) have compatible payloads — just rename the class.

Update all imports from `FirecrackerApi` to the new name across:
- `src/sandbox/sandbox.ts`
- `src/vm/snapshot.ts`

### Phase 3: Update sandbox restore to use CLI args (skip HTTP roundtrips)

The current `restoreFromDir()` in `src/sandbox/sandbox.ts` does:
1. Spawn Firecracker with `--api-sock firecracker.sock`
2. Wait for socket file
3. `PUT /snapshot/load` (with resume_vm: true)
4. Wait for agent

Flint supports restoring directly via CLI flags, skipping the pre-boot API entirely:
```
flint --restore --vmstate-path vmstate.snap --mem-path memory.snap \
  --disk rootfs.ext4 --vsock-cid 100 --vsock-uds vsock \
  --api-sock flint.sock
```

This boots directly into restore + post-boot API mode. No HTTP roundtrips needed for setup. Change `restoreFromDir()` to spawn Flint with these flags instead of using the pre-boot API. The post-boot API (pause/resume/snapshot-create) is still available on the socket.

The base snapshot creation flow in `src/vm/snapshot.ts` still needs the pre-boot API (it does a fresh boot, not a restore), so keep the API client for that path. The flow there is: spawn with `--api-sock` → PUT /machine-config → PUT /boot-source → PUT /drives → PUT /vsock → PUT /actions InstanceStart → wait for agent → pause → snapshot/create → kill. This is identical between Firecracker and Flint.

### Phase 4: Replace binary management

**`src/vm/binary.ts`** — Replace `getFirecrackerPath()`:
```typescript
export function getVmmPath(): string {
  const bundled = join(HEARTH_DIR, "bin", "flint");
  if (existsSync(bundled)) return bundled;
  throw new ResourceError("Flint VMM binary not found. Run: npx hearth setup");
}
```

**`src/cli/setup.ts`** — Replace `setupFirecracker()` with `setupFlint()`:
- Build from source: `cd vmm && zig build -Doptimize=ReleaseSafe` → copy `vmm/zig-out/bin/flint` to `~/.hearth/bin/flint`
- Requires Zig 0.16+ on the system. Check for it and give a clear error if missing.
- Remove the Firecracker download logic and GitHub release URL.
- Remove jailer binary handling (Flint has built-in `--jail`).

Update all references from `getFirecrackerPath()` to `getVmmPath()`.

### Phase 5: Simplify rootfs handling

Delete `src/vm/thin.ts` entirely (~360 lines). The dm-thin provisioning is unnecessary complexity. Use `cp --reflink=auto` for all rootfs copies (Flint's pool mode already validated this approach).

In `src/sandbox/sandbox.ts` `restoreFromDir()`:
- Remove all `isThinPoolAvailable()` / `createThinSnapshot()` / `createThinSnapshotFrom()` logic
- Remove `thinDevice` tracking from the Sandbox class
- Always use the file copy path with `COPYFILE_FICLONE`
- Remove dm-thin cleanup from `destroySync()`

In `src/sandbox/sandbox.ts` `saveSnapshotArtifacts()`:
- Remove dm-thin snapshot logic (`getThinId`, `createSnapshotThin`)
- Always copy/move rootfs files directly

In `src/cli/setup.ts`:
- Remove `setupThinPool()` call and related code

Remove thin pool imports from all files.

### Phase 6: Clean up

- Update error messages from "Firecracker" to "Flint" across all files
- Update `CLAUDE.md`: change "Underlying VM: Firecracker" to "Underlying VM: Flint (custom Zig VMM)"
- Update `ARCHITECTURE.md` references
- Update `README.md`
- Remove Firecracker version constant and download URL from setup.ts
- The socket filename can stay as `firecracker.sock` or be renamed to `flint.sock` — up to you, but if you rename it, update `SOCKET_NAME` in `snapshot.ts` and anywhere it's referenced

## Flint API reference (what's available)

### Pre-boot API (configure, then InstanceStart)
```
PUT /boot-source        {"kernel_image_path": "...", "boot_args": "...", "initrd_path": "..."}
PUT /drives/{id}        {"drive_id": "...", "path_on_host": "...", "is_root_device": bool, "is_read_only": bool}
PUT /network-interfaces/{id}  {"iface_id": "...", "host_dev_name": "..."}
PUT /vsock              {"guest_cid": N, "uds_path": "..."}
PUT /machine-config     {"mem_size_mib": N}
GET /machine-config     → {"mem_size_mib": N, "vcpu_count": 1}
PUT /snapshot/load      {"snapshot_path": "...", "mem_file_path": "..."}
PUT /actions            {"action_type": "InstanceStart"}  ← triggers boot or restore
```

### Post-boot API (VM is running)
```
PATCH /vm               {"state": "Paused"} or {"state": "Resumed"}
PUT /snapshot/create     {"snapshot_path": "...", "mem_file_path": "..."}
GET /vm                 → {"state": "Running"/"Paused"/"Exited"}
PUT /actions            {"action_type": "SendCtrlAltDel"}
```

### CLI restore mode (skip pre-boot API)
```
flint --restore --vmstate-path X --mem-path Y --disk Z \
  --vsock-cid N --vsock-uds PATH --api-sock PATH
```
Boots directly into post-boot API mode with restored VM.

## Key differences from Firecracker

1. **snapshot/load is two-phase**: `PUT /snapshot/load` stores config, `PUT /actions InstanceStart` triggers it. Firecracker triggered on the PUT itself.
2. **No `resume_vm` field**: Execution is always triggered by InstanceStart.
3. **No `mem_backend` nesting**: Flint uses `mem_file_path` directly, not `{"mem_backend": {"backend_path": ..., "backend_type": "File"}}`.
4. **Single vCPU only**: Flint doesn't support multi-vCPU yet. `vcpu_count` in machine-config is accepted but ignored. Hearth's base snapshot creation should send `vcpu_count: 1` (or just not send it — default is 1).
5. **`snapshot_type` accepted but ignored**: Always does full snapshots.
6. **Built-in jail**: `--jail` flag does mount namespace + pivot_root + cgroups + seccomp. No separate jailer binary needed.

## What NOT to change

- `agent/` (hearth-agent) — unchanged, it's VMM-agnostic
- `src/agent/client.ts` — unchanged, talks to hearth-agent over vsock
- `src/network/proxy.ts` — unchanged, vsock-based networking
- `src/daemon/` — unchanged, higher-level orchestration
- `src/environment/` — unchanged, Hearthfile parsing
- `src/vm/ksm.ts` — unchanged, KSM works with any VMM
- `src/vm/snapshot.ts` `ensureBaseSnapshot()` — logic stays the same, just uses FlintApi instead of FirecrackerApi

## Verification

1. `cd vmm && zig build` — VMM compiles
2. `cd vmm && zig build test` — VMM unit tests pass
3. `npm run build` — TypeScript compiles
4. `npm run typecheck` — No type errors
5. `npx hearth setup` — Builds Flint, downloads kernel, builds rootfs, creates base snapshot
6. `npx hearth shell` — Boots a sandbox, interactive shell works
7. Sandbox.create() → exec → destroy cycle works programmatically
