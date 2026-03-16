# Product Spec: SDK API Design

**Status**: Partial (core API implemented, spawn/snapshots/observability planned)
**Last updated**: 2026-03-16

## Overview

The Hearth SDK is the primary interface for creating and managing sandboxes. It should feel as natural as working with containers but provide real VM isolation.

## Target User

AI agent frameworks and developers building agent tooling. The SDK is called programmatically, not interactively.

## API Surface

### Sandbox Creation

```typescript
import { Sandbox } from "hearth";

// Minimal — boot from default template
const sandbox = await Sandbox.create();

// From a specific template
const sandbox = await Sandbox.create({
  template: "ubuntu-24.04-python",
});

// With resource limits
const sandbox = await Sandbox.create({
  template: "ubuntu-24.04",
  vcpus: 2,
  memoryMb: 512,
  diskSizeMb: 2048,
});

// From a snapshot
const sandbox = await Sandbox.fromSnapshot("snap_abc123");
```

### Command Execution

```typescript
// Simple exec
const result = await sandbox.exec("ls -la /");
// result: { stdout: string, stderr: string, exitCode: number }

// With options
const result = await sandbox.exec("python train.py", {
  cwd: "/workspace",
  env: { CUDA_VISIBLE_DEVICES: "0" },
  timeout: 60_000,
});

// Streaming
const proc = await sandbox.spawn("npm run dev");
proc.stdout.on("data", (chunk) => console.log(chunk));
proc.stderr.on("data", (chunk) => console.error(chunk));
await proc.wait();
```

### Filesystem

```typescript
// Write a file
await sandbox.writeFile("/workspace/main.py", "print('hello')");

// Read a file
const content = await sandbox.readFile("/workspace/output.txt");

// Upload from host
await sandbox.upload("./local-dir", "/workspace");

// Download to host
await sandbox.download("/workspace/results", "./output");
```

### Snapshots

```typescript
// Capture current state
const snapshot = await sandbox.snapshot("after-setup");

// Restore into a new sandbox
const fresh = await Sandbox.fromSnapshot(snapshot.id);

// List snapshots
const snapshots = await Sandbox.listSnapshots();
```

### Networking

```typescript
// Forward guest port to host
const { host, port } = await sandbox.forwardPort(8080);
// Access at http://localhost:{port}

// Disable outbound networking
const sandbox = await Sandbox.create({
  network: { outbound: false },
});
```

### Observability

```typescript
// Quick snapshot of sandbox state — the go-to for agents
const obs = await sandbox.observe();
// {
//   cpu: { percent: 23.5, cores: 2 },
//   memory: { usedMb: 142, totalMb: 256 },
//   disk: { usedMb: 890, totalMb: 2048 },
//   recentLogs: [...],    // last 20 entries
//   errors: [...],         // errors in last 5m
//   processes: [{ pid, name, cpuPercent, memMb }, ...],
// }

// Query logs (LogQL)
const errors = await sandbox.logs.query({
  filter: "level:error",
  since: "5m",
  limit: 50,
});

// Stream logs in real-time
const stream = sandbox.logs.tail({ filter: "service:myapp" });
stream.on("entry", (entry) => console.log(entry.message));

// Query metrics (PromQL)
const cpu = await sandbox.metrics.query({
  query: 'rate(cpu_usage_seconds_total[1m])',
});

// Boolean check — ideal for agent assertions
const healthy = await sandbox.metrics.check(
  'rate(http_requests_total{status=~"5.."}[5m]) < 0.01'
);
```

### Lifecycle

```typescript
// Pause/resume
await sandbox.pause();
await sandbox.resume();

// Destroy
await sandbox.destroy();

// Auto-cleanup with using
await using sandbox = await Sandbox.create();
// sandbox.destroy() called automatically
```

## Design Principles

1. **Minimal required config**: `Sandbox.create()` with zero args must work.
2. **Structured returns**: All operations return typed objects, never raw strings that need parsing.
3. **Explicit Resource Disposal**: Support `using` (TC39 Explicit Resource Management) and manual `.destroy()`.
4. **No global state**: Multiple Sandbox instances are fully independent.
5. **Errors are typed**: Each failure mode has a specific error type with actionable message.

## Error Types

```typescript
HearthError (base)
├── VmBootError        — Firecracker failed to start
├── SnapshotError      — Snapshot capture/restore failed
├── ExecError          — Command execution failed (distinct from non-zero exit)
├── TimeoutError       — Operation exceeded deadline
├── NetworkError       — Network setup/forwarding failed
├── AgentError         — Guest agent unreachable or protocol error
└── ResourceError      — Out of memory, disk, or KVM capacity
```

## Non-Goals (v0.1)

- GUI or web dashboard
- Multi-host orchestration
- GPU passthrough
- Windows guests
- macOS host support (requires Linux VM layer)
