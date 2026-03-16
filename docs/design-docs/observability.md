# Design Doc: Observability-First Sandboxes

**Status**: Partial (collection strategy decided, traces deferred)
**Author**: —
**Last updated**: 2026-03-16

## Context

The OpenAI harness engineering team identified observability as the unlock for agent autonomy. When Codex could query logs with LogQL and metrics with PromQL, prompts like "ensure service startup completes in under 800ms" became tractable. Without observability, agents are blind — they can only see stdout/stderr from the commands they explicitly run.

Hearth should be observability-first: every sandbox automatically collects logs, metrics, and traces, and the SDK exposes them as queryable, structured data that agents can reason over.

This is our key differentiator. E2B gives you `exec()` and stdout. Hearth gives you `exec()`, stdout, **and** the full observability picture of what happened inside the VM.

## Goals

- Every sandbox automatically collects structured logs and system metrics
- Agents can query logs and metrics via the SDK (no manual setup)
- Observability data is ephemeral — destroyed with the sandbox (no accumulation)
- Zero extra binaries in the guest — the Zig agent handles collection natively
- Observability stack is lightweight enough to run per-sandbox without significant overhead
- OTel trace collection deferred to post-v0.1

## Architecture

**Decision**: No Vector. The Zig guest agent handles log and metric collection natively. No extra binaries in the guest.

```
Guest VM                          Host
┌────────────────────┐           ┌──────────────────────────┐
│ App (user code)    │           │                          │
│   │ stdout/stderr  │           │  Victoria Logs           │
│   │ syslog         │           │  Victoria Metrics        │
│   ▼                │           │  (shared, sandbox_id     │
│ hearth-agent (Zig) │──vsock──► │   labeled)               │
│   │ journald tail  │           │                          │
│   │ /proc scrape   │           │  SDK query interface     │
│   │ process table  │           │  sandbox.logs.query()    │
└────────────────────┘           │  sandbox.metrics.query() │
                                 └──────────────────────────┘
```

### Inside the guest: hearth-agent

The Zig guest agent (already needed for exec/file I/O) adds two collection loops alongside its command handler:

**Log collection** (~100-150 lines of Zig):
- Tails `/dev/kmsg` (kernel messages) and `/dev/log` (syslog socket)
- If journald is present, reads from the journal API
- Buffers entries and ships to host over vsock as structured JSON

**Metric collection** (~100-150 lines of Zig):
- Scrapes `/proc/stat` (CPU), `/proc/meminfo` (memory), `/proc/diskstats` (disk I/O), `/proc/net/dev` (network)
- Reads `/proc/[pid]/stat` for per-process CPU/memory
- Pushes to host on a configurable interval (default: 5s)

This adds ~300 lines to the agent and zero bytes to the rootfs (agent is already there). Compare to Vector: 15MB binary, 30MB RSS, separate config file.

**What we don't get (v0.1):**
- No OTel OTLP receiver — apps can't push traces/metrics to the agent via OpenTelemetry protocol. No production-ready Zig OTLP implementation exists (only alpha-stage SDKs).
- No Prometheus scraping — agent doesn't pull from `/metrics` endpoints inside the guest
- No file tailing — agent doesn't watch arbitrary log files

These can be added later. For v0.1, journald/syslog + /proc covers the core agent use cases.

### On the host: Victoria stack

[VictoriaMetrics](https://victoriametrics.com) and [VictoriaLogs](https://docs.victoriametrics.com/victorialogs/) are single-binary, low-resource observability backends.

Shared instance with sandbox labels: one Victoria Logs + one Victoria Metrics process on the host, shared across all sandboxes. Data is labeled with `sandbox_id`. Queries scoped by label automatically.

- Started lazily on first `Sandbox.create()`
- Stopped when last sandbox is destroyed (or process exits)
- On `sandbox.destroy()`, data for that sandbox_id is deleted

### Data flow

```
1. Sandbox boots → hearth-agent starts inside guest
2. Agent tails journald/syslog, scrapes /proc every 5s
3. Agent ships structured JSON to host over vsock
4. Host-side SDK parses and pushes to Victoria with sandbox_id label
5. Agent calls sandbox.logs.query("level:error") → SDK queries Victoria → returns structured results
6. Sandbox destroyed → SDK deletes data for that sandbox_id
```

### Future: OTel trace collection (post-v0.1)

When we need app-level traces, two paths:

1. **Zig OTLP receiver**: Implement a minimal OTLP/HTTP receiver in the guest agent. OTLP over HTTP is protobuf POSTs — non-trivial but bounded scope. Apps in the guest would send traces to `localhost:4318` (standard OTLP port), the agent receives and forwards to host.

2. **Optional Vector sidecar**: For rootfs templates that need full OTel support, optionally bake in Vector. Not the default path, but available for power users who need Prometheus scraping, file tailing, etc.

## SDK API

### Logs

```typescript
// Query logs from the sandbox
const logs = await sandbox.logs.query({
  filter: 'level:error',
  since: '5m',
  limit: 100,
});
// logs: [{ timestamp, level, message, fields: {} }, ...]

// Stream logs in real-time
const stream = sandbox.logs.tail({ filter: 'service:myapp' });
stream.on('entry', (entry) => console.log(entry.message));

// Get all logs (no filter)
const all = await sandbox.logs.query({ since: '1h' });
```

### Metrics

```typescript
// Query a metric
const cpu = await sandbox.metrics.query({
  query: 'rate(cpu_usage_seconds_total[1m])',
  // PromQL — agents already know this from training data
});

// Instant query
const memUsage = await sandbox.metrics.instant('process_resident_memory_bytes');

// Check a condition (useful for agent assertions)
const healthy = await sandbox.metrics.check(
  'rate(http_requests_total{status=~"5.."}[5m]) < 0.01'
);
// healthy: boolean
```

### Convenience: `sandbox.observe()`

A high-level method for agents that want a snapshot of what's happening:

```typescript
const observation = await sandbox.observe();
// {
//   cpu: { percent: 23.5, cores: 2 },
//   memory: { usedMb: 142, totalMb: 256 },
//   disk: { usedMb: 890, totalMb: 2048 },
//   network: { rxBytes: 1024000, txBytes: 512000 },
//   recentLogs: [{ timestamp, level, message }, ...],  // last 20
//   errors: [{ timestamp, message, source }, ...],      // last 5m
//   processes: [{ pid, name, cpuPercent, memMb }, ...],
// }
```

This single call gives an agent enough context to decide what to investigate further. No PromQL knowledge needed.

## What agents can do with this

### Self-validation
```
Agent prompt: "Deploy the app and verify it starts correctly"
Agent actions:
  1. sandbox.exec("npm start &")
  2. Wait 3 seconds
  3. sandbox.observe() → check errors array is empty, CPU stabilized
  4. sandbox.metrics.check('up{job="myapp"} == 1')
  5. sandbox.logs.query({ filter: 'level:error', since: '30s' })
  → Decision: app is healthy / app has errors, investigate
```

### Performance validation
```
Agent prompt: "Ensure API response times are under 200ms"
Agent actions:
  1. sandbox.exec("npm start &")
  2. sandbox.exec("hey -n 1000 http://localhost:3000/api/health")
  3. sandbox.metrics.query({ query: 'histogram_quantile(0.99, http_duration_seconds)' })
  → Decision: p99 is 180ms, passes / p99 is 450ms, needs optimization
```

### Debugging
```
Agent prompt: "The app crashes on startup, fix it"
Agent actions:
  1. sandbox.exec("npm start")  → exit code 1
  2. sandbox.logs.query({ filter: 'level:error OR level:fatal', since: '1m' })
  → Sees: "Error: EADDRINUSE: address already in use :3000"
  → Understands the problem, can fix it
```

## Guest rootfs requirements

The base rootfs images must include:
- `hearth-agent` (Zig binary, handles exec, file I/O, AND observability collection)
- Basic system logging (journald or syslog)

Total additional footprint for observability: 0 bytes — the agent is already in the rootfs.

## Resource overhead

| Component | Location | RSS | Disk |
|-----------|----------|-----|------|
| hearth-agent (with collection) | Guest | ~2MB | ~500KB binary |
| Victoria Logs | Host (shared) | ~50MB | Variable (log volume) |
| Victoria Metrics | Host (shared) | ~30MB | Variable (metric volume) |

Total host overhead for the shared observability stack: ~80MB RSS, amortized across all sandboxes. Guest overhead: negligible (agent is already running).

## Setup

`npx hearth setup` handles everything:
1. Download Firecracker binary
2. Download Victoria Logs + Victoria Metrics binaries
3. Build/download base rootfs with hearth-agent baked in

Three binaries to manage: `firecracker`, `victoria-logs`, `victoria-metrics`. All Playwright-style auto-download with SHA256 verification.

The shared Victoria instances are started lazily on first `Sandbox.create()` and stopped when the last sandbox is destroyed (or when the process exits).

## Open Questions

1. **Retention**: How long do we keep observability data for active sandboxes? Default 1 hour? Configurable?
2. **Prometheus scraping**: Should the agent scrape `/metrics` endpoints inside the guest? Useful for apps that expose Prometheus metrics natively. Could add post-v0.1.
3. **Log format parsing**: Should the agent attempt to parse structured log formats (JSON logs, logfmt)? Or just forward raw lines and let Victoria/the SDK handle it?
