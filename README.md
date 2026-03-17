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

- `/dev/kvm` access (Linux kernel with KVM support)
- Node.js 20+
- Docker (for building the rootfs)
- Zig (for building the guest agent)

### Platform Support

**Linux** — native. Works out of the box on any Linux with KVM.

**Windows (WSL2)** — works natively. WSL2 includes a real Linux kernel with `/dev/kvm` support. Install WSL2 and run everything inside it:

```bash
wsl --install                  # one-time
wsl                            # enter Linux environment
# Everything below runs inside WSL2 — /dev/kvm is available
npx hearth setup
```

No additional configuration needed. WSL2 has supported KVM since 2022.

**macOS (M3+ with macOS 15+)** — via Lima. Requires nested virtualization, which Apple only supports on M3 and newer chips:

```bash
brew install lima
limactl create --name hearth --set '.nestedVirtualization=true' template://default
limactl start hearth
limactl shell hearth            # enter Linux environment
npx hearth setup                # Firecracker runs inside the Lima VM
hearth daemon                   # start daemon, accessible from macOS via shared mount
```

**macOS (M1/M2)** — use a remote Linux host. M1/M2 Macs cannot do nested virtualization. Options:
- Connect to a Linux server running `hearth daemon` (Hetzner bare metal from ~$35/mo)
- Use the `DaemonClient` from the SDK to connect over SSH tunnel

## Setup

Requires Docker and Zig on PATH.

```bash
npx hearth setup
```

This downloads Firecracker v1.15.0, the guest kernel, builds the Zig agent, creates an Ubuntu rootfs via Docker, and captures a base snapshot. Takes ~1-2 minutes on first run, idempotent on subsequent runs.

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

### `sandbox.enableInternet()`

Enable internet access inside the sandbox. Tunnels HTTP/HTTPS traffic over vsock — no root, no TAP devices.

```typescript
await sandbox.enableInternet();
await sandbox.exec("npm install");     // works
await sandbox.exec("curl https://example.com");  // works
await sandbox.exec("git clone https://github.com/user/repo");  // works
```

All `exec()` and `spawn()` calls automatically get `HTTP_PROXY`/`HTTPS_PROXY` set after this.

### `sandbox.spawn(command, opts?)`

Run a long-running command with streaming stdout/stderr. Unlike `exec()`, output arrives as it's produced.

```typescript
const proc = sandbox.spawn("npm run dev", { cwd: "/workspace" });
proc.stdout.on("data", (chunk) => console.log(chunk));
proc.stderr.on("data", (chunk) => console.error(chunk));
const { exitCode } = await proc.wait();
```

### `sandbox.upload(hostPath, guestPath)`

Recursively copy a directory from the host into the guest. Uses tar streaming over vsock — no base64, no memory buffering.

```typescript
await sandbox.upload("./my-project", "/workspace");
```

### `sandbox.download(guestPath, hostPath)`

Recursively copy a directory from the guest to the host.

```typescript
await sandbox.download("/workspace/dist", "./output");
```

### `sandbox.forwardPort(guestPort)`

Forward a guest TCP port to a random host port via vsock tunnel. No root or TAP devices required.

```typescript
await sandbox.exec("busybox httpd -p 8080 -h /tmp/www");
const { host, port } = await sandbox.forwardPort(8080);
const resp = await fetch(`http://${host}:${port}/index.html`);
```

### `sandbox.snapshot(name)`

Capture the current sandbox state as a named snapshot. The sandbox is destroyed after snapshotting. Restore from it later with `Sandbox.fromSnapshot()`.

```typescript
const setup = await Sandbox.create();
await setup.upload("./my-project", "/workspace");
await setup.exec("cd /workspace && npm install", { timeout: 120000 });
await setup.snapshot("my-project-ready"); // sandbox destroyed

// Later — instant restore with deps pre-installed
const sandbox = await Sandbox.fromSnapshot("my-project-ready"); // ~130ms
await sandbox.exec("cd /workspace && npm test");

// Manage snapshots
Sandbox.listSnapshots();              // [{ id: "my-project-ready", createdAt: "..." }]
Sandbox.deleteSnapshot("my-project-ready");
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
│ Sandbox.create()     │  control (1024) │ - exec via fork/sh   │
│ sandbox.exec()       │───── vsock ────►│ - file I/O           │
│ sandbox.upload()     │  forward (1025) │ - port forwarding    │
│ sandbox.download()   │  transfer(1026) │ - tar streaming      │
│ sandbox.forwardPort()│◄──── vsock ─────│ - reconnect on       │
│ sandbox.destroy()    │   proxy (1027)  │   snapshot restore   │
│                      │                 │ - HTTP proxy bridge  │
│ Firecracker API      │                 │                      │
│ Snapshot manager     │                 │ Linux kernel 6.1     │
│ Process lifecycle    │                 │ Ubuntu 24.04 rootfs  │
│ (or Daemon client)   │                 │ Node.js 22           │
└──────────────────────┘                 └──────────────────────┘
```

## Project structure

```
src/                    TypeScript SDK
  sandbox/sandbox.ts    Sandbox class (create, exec, spawn, snapshot, forwardPort, etc.)
  agent/client.ts       Host-side vsock agent client (control channel)
  daemon/server.ts      Daemon for macOS/multi-process (hearth daemon)
  daemon/client.ts      DaemonClient + RemoteSandbox (same API as Sandbox)
  network/proxy.ts      HTTP CONNECT proxy for internet access over vsock
  vm/api.ts             Firecracker REST API client
  vm/snapshot.ts        Base snapshot creation and management
  vm/binary.ts          Binary/image path resolution
  cli/setup.ts          `npx hearth setup` — downloads and configures everything
  cli/download.ts       HTTP download with progress and redirect handling
  errors.ts             Typed error hierarchy
  util.ts               Shared utilities (encodeMessage, parseFrames, etc.)

agent/                  Zig guest agent (runs inside VM)
  src/main.zig          vsock control server, exec, file I/O, port forward relay
  build.zig             Cross-compile for x86_64-linux

docs/                   Specs, design docs, references
```

## Roadmap

**v0.1**: Working `create → exec → destroy` loop with snapshot restore.

**v0.2 (current)**: `npx hearth setup` CLI, vsock port forwarding, tar-based upload/download, user-facing snapshots, streaming exec, internet access via HTTPS proxy, daemon server/client. 28 tests passing.

**v0.3**: macOS support via Lima, observability (Victoria Logs/Metrics), npm publish.

See [docs/exec-plans/](docs/exec-plans/) for detailed execution plans.

## License

MIT
