# Flint Migration Findings

## What was done

Replaced Firecracker (downloaded binary, v1.15.0) with Flint (custom Zig VMM built from source) as Hearth's underlying VM engine. PR #13.

### Completed
- Flint VMM source copied to `vmm/`, stripped of redundant files (agent, pool, sandbox)
- `FirecrackerApi` → `FlintApi` with Flint-compatible payloads
- Setup builds Flint from source (`zig build -Doptimize=ReleaseSafe`)
- Deleted dm-thin provisioning (~360 lines), always use `cp --reflink=auto`
- Removed pool CLI command, thin pool from status/setup
- ELF vmlinux loader added to Flint (alongside existing bzImage support)
- `Sandbox.create()` → `exec()` → `destroy()` works end-to-end via fresh boot

### Architecture change
- `Sandbox.create()` now does a **fresh boot** (~6s) instead of snapshot restore (~135ms)
- This is a temporary workaround — snapshot restore has a KVM vCPU resume bug

---

## Bugs found and fixed

### 1. ELF kernel boot stall after "LSM: Security Framework initializing"
**Symptom:** Kernel boots, prints up to LSM init (~0.087s), then freezes.
**Root cause:** Missing initial MSR setup. Flint didn't call `KVM_SET_MSRS` before the first `KVM_RUN`. Without `IA32_MISC_ENABLE` and `IA32_APICBASE`, the kernel's perf_event_init and APIC setup fail silently.
**Fix:** Set `IA32_MISC_ENABLE=1`, `IA32_APICBASE=0xFEE00900`, `IA32_TSC=0` in `setupRegisters()`.

### 2. Phantom UART detection hang
**Symptom:** After fixing MSRs, kernel still stalls — stuck in `io_serial_in` polling COM2/COM3/COM4.
**Root cause:** Unhandled IO port reads returned whatever was in KVM's data buffer (often zeros). The 8250 serial driver interprets zero as "UART present" and spins trying to initialize phantom UARTs.
**Fix:** Return `0xFF` for all unhandled `KVM_EXIT_IO_IN` ports (= no device present).

### 3. Wrong kernel version (6.1 vs 5.10)
**Symptom:** Kernel boots fully but can't find rootfs — no virtio-blk device detected.
**Root cause:** Firecracker CI kernel 6.1.x dropped `CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y`. Flint discovers devices via `virtio_mmio.device=` kernel cmdline params, which requires this config.
**Fix:** Download the 5.10.x kernel instead, which has the config enabled.

### 4. PIT SPEAKER_DUMMY flag = HPET_LEGACY
**Symptom:** After snapshot restore, PIT timer never fires, guest stays in HLT forever.
**Root cause:** `KVM_PIT_SPEAKER_DUMMY` (value `0x1`) has the **same bit value** as `KVM_PIT_FLAGS_HPET_LEGACY`. Setting it in `kvm_pit_state2.flags` during restore tells KVM the HPET has taken over, so `create_pit_timer()` returns early without starting the hrtimer. The PIT is silently disabled.
**Fix:** Don't modify `pit.flags` during restore. `KVM_PIT_SPEAKER_DUMMY` is a creation-time flag for `kvm_pit_config`, not a runtime flag for `kvm_pit_state2`.

### 5. Wrong KVM_KVMCLOCK_CTRL ioctl number
**Symptom:** `KVM_KVMCLOCK_CTRL` returned `EINVAL`.
**Root cause:** Hardcoded `0xAED5` (wrong). Correct value from kernel headers is `0xAEAD` (ioctl number `0xad`, not `0xd5`).
**Fix:** Use `c.KVM_KVMCLOCK_CTRL` from the auto-generated C import.

### 6. Vsock listener race condition
**Symptom:** Agent times out connecting — Flint reports `connect to vsock_1024 failed: .NOENT`.
**Root cause:** Node.js `server.listen()` is async. The vsock socket file doesn't exist until libuv processes the bind. The VM boots and the agent tries to connect before the file is ready.
**Fix:** `waitForFile()` on the vsock listener path before spawning the VM.

### 7. Parallel API calls race in snapshot creation
**Symptom:** Base snapshot creation intermittently fails.
**Root cause:** `Promise.all([putMachineConfig, putBootSource, putDrive, putVsock])` could cause `InstanceStart` to be processed before all config was received.
**Fix:** Sequential API calls.

---

## Unresolved: Snapshot restore KVM_RUN hang

### Symptom
After restoring all KVM state from a snapshot, `KVM_RUN` blocks forever. The vCPU never exits. Zero VM exits in any timeout period.

### What we tried
- Matching Firecracker's exact restore order (vCPU state first, VM state second)
- Memory region registered before vCPU state
- `KVM_KVMCLOCK_CTRL` after vCPU restore
- Adding xsave save/restore
- Adding x2APIC MSR range (0x800-0x83F) to save/restore
- Adding KVM paravirt MSRs (kvm-clock, steal time, async PF)
- Removing `KVM_SET_IDENTITY_MAP_ADDR` (Firecracker doesn't call it)
- Disabling APICv (`enable_apicv=0`)
- Forcing `mp_state = KVM_MP_STATE_RUNNABLE`
- Injecting IRQ 0 (PIT) after restore via `KVM_IRQ_LINE`
- `immediate_exit` KVM_RUN cycle before real KVM_RUN
- Artificially kicking device queues after restore
- Various PIT flag combinations

### What we know
- vCPU state after restore: `mp_state=0` (RUNNABLE), `rflags=0x246` (IF=1), `rip=0xffffffff815e8ed1` (`vm_notify` in virtio_mmio.c)
- All `KVM_SET_*` ioctls succeed without errors
- All MSRs read/write successfully (validated return counts)
- PIT flags are 0 (no HPET_LEGACY)
- Snapshot file format is self-consistent (header, sizes match)
- With APICv=N: got 3 MMIO exits initially (one-time), then hung
- With APICv=Y: zero exits from the start
- Firecracker's snapshot restore ALSO fails for vsock (different error: "Address in use" — Firecracker binds its own vsock listener)

### What Firecracker does differently (from source analysis)
1. **60+ MSRs** via `KVM_GET_MSR_INDEX_LIST` (dynamic discovery) — we save ~22 hardcoded
2. **`KVM_SET_XSAVE2`** (not `KVM_SET_XSAVE`) — newer API with dynamic size
3. **`KVM_SET_DEBUG_REGS`** — we don't save/restore debug registers
4. **`KVM_IOEVENTFD`** per virtio queue — Firecracker uses ioeventfd for zero-exit queue notifications
5. **`KVM_IRQFD`** per device — Firecracker wires device IRQs directly into KVM
6. **"Artificially kick devices"** — calls `process_virtio_queues()` on each device after restore, logs `[Block:rootfs] notifying queues`
7. **Device activation** — calls `device.activate(mem, interrupt)` to reinitialize backend threads
8. No `KVM_SET_IDENTITY_MAP_ADDR` — Firecracker doesn't call this

### Most likely root cause
The combination of missing ioeventfd/irqfd registration and incomplete MSR list. Without ioeventfd, virtio device notifications require full VM exits. Without a complete MSR list (dynamic via `KVM_GET_MSR_INDEX_LIST`), critical CPU state may not be restored. The APICv interaction (zero exits with APICv=Y vs 3 exits with APICv=N) strongly suggests the virtual APIC page state isn't being correctly synchronized.

### Recommended next steps
1. Implement `KVM_GET_MSR_INDEX_LIST` to dynamically discover all MSRs the host supports
2. Add `KVM_SET_DEBUG_REGS` to snapshot save/restore
3. Consider `KVM_SET_XSAVE2` instead of `KVM_SET_XSAVE`
4. Test with ioeventfd/irqfd registered for virtio devices after restore
5. Compare actual byte-level LAPIC state between Firecracker and Flint snapshots

---

## Unresolved: Multiple sequential execs hang

### Symptom
First `sb.exec()` works. Second `sb.exec()` on the same sandbox hangs forever.

### Likely cause
The hearth-agent's control channel protocol may only handle one request per connection. After the first exec completes, the agent may close the connection or enter an unexpected state. This needs investigation in `agent/src/main.zig`.

---

## Performance comparison

| Operation | Firecracker (old) | Flint fresh boot (current) | Flint snapshot (target) |
|-----------|------------------|---------------------------|------------------------|
| Setup | ~60s (download FC) | ~30s (build from source) | Same |
| Sandbox.create() | ~135ms | ~6s | ~135ms (blocked) |
| exec() | ~2ms | ~2ms | ~2ms |
| destroy() | instant | instant | instant |

---

## Files changed (summary)

### New
- `vmm/` — entire Flint VMM source (Zig)
- `vmm/build.zig`, `vmm/build.zig.zon`

### Modified
- `src/vm/api.ts` — `FirecrackerApi` → `FlintApi`, Flint-compatible payloads
- `src/vm/binary.ts` — `getFirecrackerPath()` → `getVmmPath()`
- `src/vm/snapshot.ts` — `root=/dev/vda rw` in boot args, absolute vsock path, sequential API calls
- `src/sandbox/sandbox.ts` — `freshBoot()` method, removed thin pool, CLI restore mode
- `src/cli/setup.ts` — build Flint from source, 5.10.x kernel, removed thin pool
- `src/cli/hearth.ts` — removed pool command
- `src/cli/status.ts` — removed thin pool status
- Various docs (README, ARCHITECTURE, CLAUDE.md, package.json)

### Deleted
- `src/vm/thin.ts` (~360 lines)
- `src/cli/pool.ts`
