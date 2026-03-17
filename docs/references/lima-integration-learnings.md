# Lima Integration Learnings

**Date**: 2026-03-17
**Context**: First end-to-end test of Lima macOS support on M4 Pro

## What we discovered

### 1. Unix sockets don't cross the virtiofs boundary — use Lima's portForwards

Lima mounts macOS `~` into the guest via virtiofs. Socket files created by a Linux process inside the VM are visible as files from macOS (`ls` shows them), but `net.connect()` from macOS gets `ECONNREFUSED`. The kernel can't route Unix domain socket connections across the VM boundary — this is a fundamental limitation of virtiofs/sshfs ([lima-vm/lima#648](https://github.com/lima-vm/lima/issues/648)).

**Fix**: Lima has built-in socket forwarding via `portForwards` in the lima.yaml config. The daemon listens on `/run/hearth/daemon.sock` inside the guest, and Lima forwards it to `~/.hearth/daemon.sock` on macOS via SSH tunneling:

```yaml
portForwards:
  - guestSocket: "/run/hearth/daemon.sock"
    hostSocket: "{{.Home}}/.hearth/daemon.sock"
```

This means `DaemonClient.connect()` just works with the default socket path — no TCP, no special addresses. The same API on both Linux and macOS.

### 2. Lima homedir != macOS homedir

Inside Lima, `os.homedir()` returns `/home/<user>.guest/`, not `/Users/<user>/`. But the macOS home directory is mounted at `/Users/<user>` inside the VM via virtiofs.

This means `getHearthDir()` (which uses `homedir() + "/.hearth"`) points to a different location inside the VM than on macOS.

**Fix**: Added `HEARTH_DIR` environment variable support in `vm/binary.ts`. When running inside Lima, we set `HEARTH_DIR=/Users/<user>/.hearth` so all hearth operations use the shared mount path.

### 3. KVM permissions reset on every boot

The Lima provisioning script runs `chmod 666 /dev/kvm`, but udev resets permissions to `crw-rw---- root:kvm` on every boot. The `usermod -aG kvm` from provisioning also doesn't take effect until the user re-logs in, which doesn't happen with `limactl shell`.

**Fix**:
- Added udev rule in provisioning: `echo 'KERNEL=="kvm", GROUP="kvm", MODE="0666"' > /etc/udev/rules.d/99-kvm.rules`
- `startDaemonInLima()` runs `sudo chmod 666 /dev/kvm` before starting the daemon (belt and suspenders — udev rule handles future boots, chmod handles the current session)

### 4. Docker group membership needs re-login

Same issue as KVM — `usermod -aG docker` in provisioning doesn't take effect for the current session. `limactl shell` connects as the user but group membership is stale.

**Fix**: Run `hearth setup` inside Lima as root (`sudo bash -c "..."`), since it needs both docker and KVM access. The files end up on the shared mount with correct ownership because virtiofs maps UIDs.

### 5. Rootfs tar extraction fails on virtiofs

`tar xf` of a full Ubuntu rootfs onto virtiofs hits `ENOTEMPTY` errors on directories like `/etc/alternatives`. This is a virtiofs filesystem semantics issue — some operations that work on native ext4 don't work identically on virtiofs.

**Fix**: Changed `setupRootfs()` to use `os.tmpdir()` (VM-local `/tmp`) for the tar extraction and Docker build, instead of putting the temp dir on the shared mount. Only the final `rootfs.ext4` file is written to the shared mount.

### 6. Lima needs full ~ mount, not just ~/.hearth

The original design only mounted `~/.hearth` into the VM. But `hearth setup` and the daemon need access to the project source code (`node dist/cli/hearth.js`), which is under `~/Documents/hearth`.

**Fix**: Mount all of `~` (which is Lima's default behavior anyway). Added validation in `findHearthRoot()` that the project is under `homedir()`.

### 7. Agent binary download URL

The GitHub release was created with tag `agent-v0.1.0` but the download URL in `setup.ts` used `v0.1.0`. The `AGENT_VERSION` constant needed to include the `agent-` prefix.

## Architecture decisions made

- **Lima portForwards for socket sharing**: The daemon stays on a Unix socket everywhere. Lima's built-in `portForwards` config forwards the guest socket to the host via SSH tunneling. No TCP, no extra transport code.
- **HEARTH_DIR env var**: Simple, composable, works everywhere. No Lima-specific code paths in the core — just a different env var.
- **HEARTH_DAEMON_SOCK env var**: Inside Lima, the daemon listens at `/run/hearth/daemon.sock` (not under `~/.hearth`) because Lima forwards it to the host. The env var overrides the default.
- **sudo for setup, user for daemon**: Setup needs root (docker, KVM). Daemon runs as the regular user after KVM permissions are fixed.

## What works end-to-end

```
macOS M4 Pro
  └─ hearth lima setup       # creates Lima VM, provisions, runs hearth setup inside
  └─ hearth lima start       # starts VM, fixes /dev/kvm, starts daemon on port 8787
  └─ hearth lima stop        # stops daemon, stops VM
  └─ hearth lima status      # shows VM state, daemon state
  └─ hearth lima teardown    # destroys VM entirely

  └─ DaemonClient.connect()  # connects via ~/.hearth/daemon.sock (Lima forwards it)
     └─ client.create()      # creates Firecracker microVM inside Lima
     └─ sandbox.exec(...)    # runs commands inside the microVM
     └─ sandbox.destroy()    # tears down the microVM
```
