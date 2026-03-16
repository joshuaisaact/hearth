# hearth

Local-first Firecracker microVM sandboxes for AI agent development. Think [E2B](https://e2b.dev), but runs entirely on your machine.

```typescript
import { Sandbox } from "hearth";

const sandbox = await Sandbox.create();              // ~135ms (snapshot restore)
const result = await sandbox.exec("echo hello");     // ~2ms (vsock, no network)
console.log(result.stdout);                          // "hello\n"
await sandbox.destroy();                             // cleanup: kill VM, delete overlay
```

Each sandbox is a real Firecracker microVM with its own Linux kernel. Not a container, not a namespace hack. An agent that `rm -rf /` inside a sandbox destroys nothing on your host.

## Why

Cloud sandboxes (E2B, Daytona, Modal) add latency, cost, and a dependency on someone else's uptime. AI agents spin up hundreds of sandboxes in a session. That feedback loop should be sub-second and free.

|  | E2B | Daytona | hearth |
|---|---|---|---|
| Isolation | Firecracker | Docker | Firecracker |
| Create | ~150ms | ~90ms | ~135ms |
| Exec latency | Network RTT | Network RTT | ~2ms |
| Cost | $0.05/vCPU-hr | $0.067/hr | Free |
| Local | No | Self-host | Yes |
| Snapshots | Hidden | No | First-class |

## How it works

1. **First `Sandbox.create()`**: Boots a fresh Firecracker VM, waits for the guest agent, pauses, captures a snapshot (vmstate + memory + rootfs). Takes ~1s one time.
2. **Every subsequent create**: Copies the snapshot files (reflink on btrfs/XFS = instant), restores Firecracker from snapshot, agent reconnects over vsock. ~135ms.
3. **`exec()`**: Sends a command to the Zig guest agent over virtio-vsock. Agent forks `/bin/sh -c <cmd>`, captures stdout/stderr, returns base64-encoded result. ~2ms round-trip.
4. **`destroy()`**: Kills the Firecracker process, deletes the run directory. Process exit handler catches orphans.

## Requirements

- Linux with `/dev/kvm` access (bare metal or nested virt)
- Node.js 20+
- Firecracker v1.15.0, guest kernel, and Ubuntu rootfs at `~/.hearth/` (see setup below)

macOS/Windows: use WSL2 or a Linux VM. Firecracker requires KVM.

## Setup (manual, v0.1)

Automated `npx hearth setup` is coming in v0.2. For now:

```bash
# 1. Download Firecracker
mkdir -p ~/.hearth/bin
cd ~/.hearth/bin
curl -fSL "https://github.com/firecracker-microvm/firecracker/releases/download/v1.15.0/firecracker-v1.15.0-$(uname -m).tgz" -o fc.tgz
tar xzf fc.tgz
mv release-v1.15.0-$(uname -m)/firecracker-v1.15.0-$(uname -m) firecracker
mv release-v1.15.0-$(uname -m)/jailer-v1.15.0-$(uname -m) jailer
chmod +x firecracker jailer
rm -rf release-v1.15.0-* fc.tgz

# 2. Download guest kernel
mkdir -p ~/.hearth/bases
ARCH="$(uname -m)"
KERNEL=$(curl -s "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/v1.15/$ARCH/vmlinux-&list-type=2" \
  | grep -oP "(?<=<Key>)(firecracker-ci/v1.15/$ARCH/vmlinux-[0-9.]+)(?=</Key>)" | sort -V | tail -1)
curl -fSL "https://s3.amazonaws.com/spec.ccfc.min/$KERNEL" -o ~/.hearth/bases/vmlinux

# 3. Build rootfs (requires Docker + Zig)
cd /path/to/hearth
cd agent && zig build && cd ..
# Then build a rootfs with the agent baked in — see docs/design-docs/firecracker-integration.md
```

## API

### `Sandbox.create()`

Boot a sandbox from snapshot. Returns when the guest agent is connected and ready.

### `sandbox.exec(command, opts?)`

Run a shell command. Returns `{ stdout, stderr, exitCode }`.

```typescript
const result = await sandbox.exec("python3 -c 'print(1+1)'");
// result.stdout === "2\n"
// result.exitCode === 0

// With options
await sandbox.exec("npm test", {
  cwd: "/workspace",
  env: { NODE_ENV: "test" },
  timeout: 30000,
});
```

### `sandbox.writeFile(path, content)`

Write a file inside the sandbox.

```typescript
await sandbox.writeFile("/tmp/script.py", "print('hello')");
```

### `sandbox.readFile(path)`

Read a file from the sandbox.

```typescript
const content = await sandbox.readFile("/etc/hostname");
```

### `sandbox.destroy()`

Kill the VM and clean up all resources. Also supports `await using`:

```typescript
await using sandbox = await Sandbox.create();
// sandbox.destroy() called automatically at end of scope
```

## Architecture

```
Host                                      Guest (Firecracker microVM)
┌──────────────────────┐                 ┌──────────────────────┐
│ TypeScript SDK       │                 │ hearth-agent (Zig)   │
│ Sandbox.create()     │                 │ - exec via fork/sh   │
│ sandbox.exec()       │───── vsock ────►│ - file I/O           │
│ sandbox.destroy()    │                 │ - reconnect on       │
│                      │                 │   snapshot restore   │
│ Firecracker API      │                 │                      │
│ Snapshot manager     │                 │ Linux kernel 6.1     │
│ Process lifecycle    │                 │ Ubuntu 24.04 rootfs  │
└──────────────────────┘                 └──────────────────────┘
```

## Project structure

```
src/                    TypeScript SDK
  sandbox/sandbox.ts    Sandbox class (create, exec, destroy)
  agent/client.ts       Host-side vsock agent client
  vm/api.ts             Firecracker REST API client
  vm/snapshot.ts        Base snapshot creation and management
  vm/binary.ts          Binary/image path resolution
  errors.ts             Typed error hierarchy
  util.ts               Shared utilities

agent/                  Zig guest agent (runs inside VM)
  src/main.zig          vsock server, exec, file I/O
  build.zig             Cross-compile for x86_64-linux

docs/                   Specs, design docs, references
```

## Roadmap

**v0.1 (current)**: Working `create → exec → destroy` loop with snapshot restore. 7 integration tests passing.

**v0.2**: `npx hearth setup` CLI, networking (TAP + port forwarding), streaming exec, upload/download.

**v0.3**: Observability (Victoria Logs/Metrics, `sandbox.logs.query()`, `sandbox.observe()`), daemon backend with VM pooling.

See [docs/exec-plans/](docs/exec-plans/) for detailed execution plans.

## License

MIT
