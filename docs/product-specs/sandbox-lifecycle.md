# Product Spec: Sandbox Lifecycle

**Status**: Draft
**Last updated**: 2026-03-16

## Overview

This spec defines the lifecycle states of a Hearth sandbox and the transitions between them.

## State Machine

```
                    create()
                       │
                       ▼
               ┌──────────────┐
               │   Booting    │
               └──────┬───────┘
                      │ agent ready
                      ▼
               ┌──────────────┐
        ┌─────►│   Running    │◄─────┐
        │      └──────┬───────┘      │
        │             │              │
        │    pause()  │   snapshot() │  resume()
        │             ▼              │
        │      ┌──────────────┐      │
        │      │   Paused     │──────┘
        │      └──────┬───────┘
        │             │
        │             │ destroy()
        │             ▼
        │      ┌──────────────┐
        └──────│   Error      │
               └──────┬───────┘
                      │ destroy()
                      ▼
               ┌──────────────┐
               │  Destroyed   │
               └──────────────┘
```

## States

### Booting
The Firecracker process has been spawned and the VM is starting. The guest kernel is loading and the guest agent is initializing. No operations are available except `destroy()`.

**Duration target**: < 150ms from `create()` call to `Running`.

### Running
The VM is active and the guest agent is connected. All operations (exec, file I/O, networking, snapshot) are available.

### Paused
The VM is suspended. CPU is halted, memory is frozen. No operations except `resume()`, `snapshot()`, and `destroy()`. Useful for:
- Reducing resource usage when idle
- Capturing consistent snapshots
- Queueing sandboxes for later use

### Error
The VM encountered a fatal error (crash, OOM, agent disconnect). Limited operations: `destroy()` and diagnostic reads (logs, last known state). Transitions here from any active state.

### Destroyed
Terminal state. All resources (VM process, network, disk) have been cleaned up. The Sandbox object is inert — all method calls throw `SandboxDestroyedError`.

## Creation Paths

### 1. Fresh boot
```
Sandbox.create() → spawn firecracker → boot kernel → start agent → Running
```
~125-150ms. Used for first-time setup or when no suitable snapshot exists.

### 2. Snapshot restore
```
Sandbox.fromSnapshot(id) → load snapshot artifacts → restore firecracker → reconnect agent → Running
```
~30-50ms. The fast path. Used for all routine sandbox creation once a template has been captured.

### 3. Pool allocation (daemon mode)
```
Sandbox.create() → daemon picks pre-booted VM from pool → Running
```
~5-10ms. Fastest path. Daemon maintains warm VMs ready for assignment.

## Cleanup Guarantees

Hearth must clean up all host resources when a sandbox is destroyed, whether explicitly or via crash/exit:

- Kill Firecracker process
- Remove jailer chroot directory
- Delete overlay filesystem
- Remove TAP network interface
- Release vsock CID
- Remove port forwarding rules

We register cleanup handlers via:
1. `sandbox.destroy()` — explicit
2. `using` / `Symbol.dispose` — scoped
3. `process.on('exit')` — best-effort on host process exit
4. Daemon periodic reaping — catch orphans from crashed host processes

## Open Questions

1. **Timeout on Booting**: How long do we wait for the agent before declaring a boot failure? 5s? 10s? Configurable?
2. **Error recovery**: Can we auto-recover from transient errors (agent disconnect) by restarting the agent? Or is the VM always toast?
3. **Hibernate**: Should we support serializing a Running sandbox to disk and restoring it later (not just pause/resume in memory)?
