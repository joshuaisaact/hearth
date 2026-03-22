# Flint Migration Findings

## What was done

Replaced Firecracker (downloaded binary, v1.15.0) with Flint (custom Zig VMM built from source) as Hearth's underlying VM engine.

### Completed
- Flint VMM source copied to `vmm/`, stripped of redundant files (agent, pool, sandbox)
- `FirecrackerApi` → `FlintApi` with Flint-compatible payloads
- Setup builds Flint from source (`zig build -Doptimize=ReleaseSafe`)
- Setup downloads pre-built 5.10.245 bzImage from GitHub releases
- Deleted dm-thin provisioning (~360 lines), always use `cp --reflink=auto`
- Removed pool CLI command, thin pool from status/setup
- ELF vmlinux loader added to Flint (alongside existing bzImage support)
- Snapshot restore working — `Sandbox.create()` ~145ms via snapshot restore
- Code review fixes: SA_RESTART deadlock, seccomp gaps, virtio descriptor validation, path traversal checks, spin loop backoff, jail permissions

### Performance

| Operation | Firecracker (old) | Flint (current) |
|-----------|------------------|-----------------|
| Setup | ~60s (download FC) | ~30s (build Flint + download kernel) |
| Sandbox.create() | ~135ms | ~145ms |
| exec() | ~2ms | ~2ms |
| destroy() | instant | instant |

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

### 8. ELF vmlinux breaks snapshot restore
**Symptom:** After snapshot restore, `KVM_RUN` blocks forever with zero VM exits (ELF kernel) or 5 MMIO exits then stuck (with other fixes applied).
**Root cause:** The ELF loader synthesizes the entire `boot_params` struct from scratch with hardcoded values. On snapshot restore, the kernel re-reads `boot_params` from guest memory during resume code paths and the synthetic values are wrong. bzImage format works because the kernel's own setup header (at offset 0x1F1) provides authoritative `boot_params`.
**Fix:** Switch from ELF vmlinux to bzImage kernel format. Pre-built 5.10.245 bzImage hosted on GitHub releases.

### 9. Snapshot captured with vCPU in wrong state
**Symptom:** Restored VM hangs — `mp_state=0` (RUNNABLE) with `rip` mid-execution instead of `mp_state=3` (HALTED).
**Root cause:** `ensureBaseSnapshot()` paused the VM immediately after `agent.ping()` returned, before the guest had time to settle back into HLT. The vCPU was captured mid-instruction.
**Fix:** 200ms delay after `agent.close()` before pausing, so the vCPU enters HALTED state.

### 10. SA_RESTART on SIGUSR1 defeated pause mechanism
**Symptom:** VM pause deadlocks — `kickVcpu()` sends SIGUSR1 but KVM_RUN doesn't return.
**Root cause:** `SA_RESTART` flag on the signal handler causes the kernel to auto-restart the KVM_RUN ioctl after the handler returns, so it never returns `-EINTR`.
**Fix:** Remove `SA_RESTART` from the SIGUSR1 handler flags.

---

## Unresolved: Multiple sequential execs hang

### Symptom
First `sb.exec()` works. Second `sb.exec()` on the same sandbox hangs forever.

### Likely cause
The hearth-agent's control channel protocol only handles one request per connection. After the first exec completes, the agent closes the connection or enters an unexpected state. This needs investigation in `agent/src/main.zig`.

---

## Files changed (summary)

### New
- `vmm/` — entire Flint VMM source (Zig)
- `vmm/build.zig`, `vmm/build.zig.zon`

### Modified
- `src/vm/api.ts` — `FirecrackerApi` → `FlintApi`, Flint-compatible payloads
- `src/vm/binary.ts` — `getFirecrackerPath()` → `getVmmPath()`, prefers bzImage
- `src/vm/snapshot.ts` — sequential API calls, settle delay before snapshot capture
- `src/sandbox/sandbox.ts` — snapshot restore path, CLI restore mode, removed thin pool
- `src/cli/setup.ts` — build Flint from source, download bzImage, removed thin pool
- `src/cli/hearth.ts` — removed pool command
- `src/cli/status.ts` — removed thin pool status
- `vmm/src/seccomp.zig` — added missing syscalls (epoll, nanosleep, statx)
- `vmm/src/main.zig` — SA_RESTART fix, identity map on restore, pause backoff, exit signal
- `vmm/src/api.zig` — path validation, memory leak fix, SendCtrlAltDel, accept loop fix
- `vmm/src/snapshot.zig` — device type validation, mem_size bounds, debug regs, format v2
- `vmm/src/devices/virtio/blk.zig` — DESC_F_WRITE validation
- `vmm/src/devices/virtio/net.zig` — DESC_F_WRITE validation
- `vmm/src/devices/virtio/vsock.zig` — EAGAIN recovery fix
- `vmm/src/jail.zig` — /dev/kvm permissions (0666 in private namespace)
- `vmm/src/kvm/vcpu.zig` — dynamic MSR discovery, debug register save/restore
- Various docs (README, ARCHITECTURE, CLAUDE.md, package.json)

### Deleted
- `src/vm/thin.ts` (~360 lines)
- `src/cli/pool.ts`
