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

- Node.js 20+
- Docker (for building the rootfs)

### Platform Support

**Linux** — native. Works out of the box on any Linux with `/dev/kvm`.

```bash
npx hearth setup
```

**Windows (WSL2)** — works natively. WSL2 has a real Linux kernel with KVM support:

```bash
wsl --install && wsl            # one-time
npx hearth setup
```

**macOS** — use a remote Linux host. Firecracker requires KVM which is not available on macOS. Connect to a Linux server running `hearth daemon` over WebSocket:

```bash
# On your Linux server
npx hearth setup
hearth daemon --remote   # starts UDS + WebSocket listener, prints token

# On your Mac, save the connection
hearth connect <server-ip> --token <token>
```

That's it. `hearth shell`, `DaemonClient`, and the SDK all auto-resolve the remote connection via `~/.hearthrc`:

```typescript
import { DaemonClient } from "hearth";

const client = new DaemonClient();
await client.connect();                     // reads ~/.hearthrc, connects via ws://
const sandbox = await client.create();      // same API as Sandbox
```

Works over any network where the Mac can reach the server (ZeroTier, Tailscale, LAN, etc.). A Hetzner bare-metal server (~$35/mo) can serve an entire team.

## Setup

```bash
npx hearth setup
```

Downloads Firecracker v1.15.0, guest kernel, prebuilt agent binary, builds an Ubuntu rootfs via Docker, and captures a base snapshot. Takes ~1-2 minutes on first run, idempotent after that.

## Environments

Environments are pre-built, snapshotted sandbox configurations. Go from "I have a repo" to "isolated VM with code cloned, deps installed, and Claude Code ready" in one command.

### Hearthfile

Define your environment in a `Hearthfile.toml`:

```toml
name = "my-api"
repo = "github.com/user/my-api"
branch = "main"

# Run once during build, baked into snapshot
setup = [
  "npm install",
  "npm install -g @anthropic-ai/claude-code",
]

# Run on every start (after snapshot restore)
start = ["redis-server --daemonize yes"]

# Ports to auto-forward to host
ports = [8000, 6379]

# Optional: poll before handing control to user
ready = "http://localhost:8000/health"

# Optional: inject files from host
[[files]]
from = "~/.ssh/id_ed25519"
to = "/home/agent/.ssh/id_ed25519"
mode = "0600"
```

### Build and use

```bash
hearth build                    # build from Hearthfile.toml in current dir
hearth claude my-api            # Claude Code inside the environment
hearth shell my-api             # plain shell inside the environment
```

The first build takes seconds to minutes (clone + install). After that, every restore is from snapshot (~200ms). Rebuild when deps change:

```bash
hearth rebuild my-api
```

### Quick build (no Hearthfile)

```bash
hearth build my-api --repo github.com/user/my-api
```

### Managing environments

```bash
hearth envs                     # list all environments
hearth envs inspect my-api      # show Hearthfile + metadata
hearth envs rm my-api           # delete environment and snapshot
```

## Interactive Shell

`hearth shell` drops you into a live bash session inside a sandbox:

```bash
hearth shell                    # boot from base snapshot
hearth shell my-project-ready   # boot from a named snapshot
hearth shell my-api             # boot an environment (runs start commands)
```

The daemon is auto-started if not already running. On macOS with `~/.hearthrc` configured, it connects to the remote daemon over WebSocket. The host terminal is set to raw mode — keystrokes are forwarded directly, Ctrl-C/Ctrl-D work as expected, and window resizes propagate via SIGWINCH.

## Checkpoint and Rollback

Save a running sandbox's state as a named snapshot. The active session is terminated (vsock device reset), but you can immediately restore from the checkpoint.

```bash
# Terminal 1: working in a sandbox
hearth claude my-api

# Terminal 2: save state (terminates the active session)
hearth checkpoint before-refactor

# Restore from the checkpoint
hearth claude before-refactor
```

Checkpoints are full VM snapshots (memory + disk). Restoring one gives you the exact state at checkpoint time — files, processes, everything.

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

### `sandbox.checkpoint(name)`

Save the current sandbox state as a named snapshot **without destroying the VM**. The sandbox remains running and usable. This is the core primitive for branching and rollback workflows.

```typescript
const sandbox = await Sandbox.create();
await sandbox.exec("npm install", { cwd: "/workspace" });

// Save state — sandbox keeps running
await sandbox.checkpoint("before-refactor");

// Try something risky
await sandbox.exec("rm -rf src && rewrite-everything");

// Oops — restore the checkpoint (new sandbox, old state)
await sandbox.destroy();
const rollback = await Sandbox.fromSnapshot("before-refactor");
```

### `sandbox.snapshot(name)`

Capture the current sandbox state as a named snapshot. The sandbox is destroyed after snapshotting. Restore from it later with `Sandbox.fromSnapshot()`. Use `checkpoint()` instead if you want to keep the sandbox running.

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

### `Environment.build(config)`

Build an environment from a `Hearthfile` config object. Boots a sandbox, clones the repo, runs setup commands, and captures a snapshot.

```typescript
import { Environment } from "hearth";
import type { Hearthfile } from "hearth";

const config: Hearthfile = {
  name: "my-api",
  repo: "github.com/user/my-api",
  setup: ["npm install"],
  start: ["npm run dev"],
  ports: [3000],
};

await Environment.build(config);
```

### `Environment.start(name)`

Restore a previously built environment from snapshot. Re-injects credentials, runs start commands, forwards ports. Returns the sandbox and start metadata.

```typescript
const { sandbox, meta, workdir, ports } = await Environment.start("my-api");
await sandbox.exec("npm test", { cwd: workdir });
await sandbox.destroy();
```

### `Environment.get(config)`

Build-if-needed, then start. Idempotent — if the snapshot already exists, skips the build.

```typescript
const { sandbox, workdir } = await Environment.get(config);
```

### `Environment.rebuild(name)`

Delete the existing snapshot and rebuild from the stored Hearthfile. The previous snapshot is backed up and restored if the rebuild fails.

```typescript
await Environment.rebuild("my-api");
```

### `Environment.list()`

List all built environments with their metadata.

```typescript
const envs = Environment.list();
for (const env of envs) {
  console.log(`${env.name} — built ${env.builtAt}`);
}
```

### `Environment.remove(name)`

Delete an environment and its snapshot.

```typescript
Environment.remove("my-api");
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
  daemon/server.ts      Daemon server (UDS + optional WebSocket)
  daemon/client.ts      DaemonClient + RemoteSandbox (same API as Sandbox)
  daemon/transport.ts   Transport interface (UDS length-prefixed, WS text frames)
  daemon/ws-server.ts   WebSocket listener with Bearer token auth
  daemon/config.ts      ~/.hearthrc config resolution + env var overrides
  environment/          Environments — Hearthfile parsing, build, start, metadata
  claude.ts             ClaudeSandbox helper (pre-installed Claude Code + runtime auth)
  cli/claude.ts         `hearth claude` — interactive Claude Code in a sandbox or environment
  cli/build.ts          `hearth build` — build environment from Hearthfile
  cli/envs.ts           `hearth envs` — list, inspect, remove environments
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
  build.zig             Cross-compile for x86_64-linux and aarch64-linux

examples/               Working examples
  claude-in-sandbox.ts  Run Claude Code in a sandbox
  create-claude-snapshot.ts  Build the reusable claude-base snapshot

docs/                   Specs, design docs, references
```

## Running Claude Code in a Sandbox

The primary use case — run an AI agent with full autonomy in a safe, isolated environment. `--dangerously-skip-permissions` is actually safe because the sandbox *is* the permission boundary.

### Quick start: environment (recommended)

1. Create a `Hearthfile.toml` for your project:

```toml
name = "my-api"
repo = "github.com/user/my-api"
setup = [
  "npm install",
  "npm install -g @anthropic-ai/claude-code",
]
```

2. Build and launch:

```bash
hearth build
hearth claude my-api
```

Restores the snapshot in ~200ms, injects your host's Claude Code credentials, enables internet, and drops you into an interactive Claude Code session inside an isolated VM. Your host credentials are read from `~/.claude/.credentials.json` — no manual token setup required.

### Quick start: bare sandbox

If you don't need a project environment, use the `claude-base` snapshot:

1. Create the `claude-base` snapshot (one-time, ~2 minutes):

```bash
node --experimental-strip-types examples/create-claude-snapshot.ts           # Linux
node --experimental-strip-types examples/create-claude-snapshot.ts --daemon  # macOS
```

2. Launch Claude Code:

```bash
hearth claude
```

### CLI args

Pass args through to Claude Code:

```bash
hearth claude my-api -- -p "Build a REST API with Express"   # non-interactive, in environment
hearth claude -p "Build a REST API with Express"             # non-interactive, bare sandbox
```

### Programmatic API

Use `ClaudeSandbox` for scripted/automated use:

```typescript
import { DaemonClient, ClaudeSandbox, CLAUDE_SNAPSHOT_NAME } from "hearth";

const client = new DaemonClient();
await client.connect();
const sandbox = await client.fromSnapshot(CLAUDE_SNAPSHOT_NAME);
await sandbox.enableInternet();

const claude = ClaudeSandbox.create(sandbox);

const result = await claude.prompt("Build a REST API with Express");
console.log(result.stdout);

// Or stream output in real time
const handle = await claude.promptStream("Write and test a hello world");
handle.stdout.on("data", (data) => process.stdout.write(data));
await handle.wait();

// Pull the results out
await sandbox.download("/home/agent", "./output");
await claude.destroy();
```

The `claude-base` snapshot has Claude Code pre-installed but no credentials — auth is injected at runtime from your host. The snapshot is shareable.

See [examples/claude-in-sandbox.ts](examples/claude-in-sandbox.ts) for a complete working example.

## Roadmap

**v0.1**: Working `create → exec → destroy` loop with snapshot restore.

**v0.2**: `npx hearth setup` CLI, vsock port forwarding, tar-based upload/download, user-facing snapshots, streaming exec, internet access via HTTPS proxy, daemon server/client.

**v0.3**: Prebuilt agent binaries, dm-thin instant snapshots.

**v0.5**: Environments — declarative `Hearthfile.toml`, `hearth build`/`rebuild`/`envs`, environment-aware `hearth claude` and `hearth shell`.

**v0.6 (current)**: Checkpoint — `sandbox.checkpoint()` saves VM state without destroying the sandbox, enabling rollback and branching workflows for agents.

See [docs/exec-plans/](docs/exec-plans/) for detailed execution plans.

## License

MIT
