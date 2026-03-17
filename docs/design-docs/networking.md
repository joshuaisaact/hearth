# Design Doc: Internet Access via HTTPS Proxy over vsock

**Status**: Implementing
**Last updated**: 2026-03-17

## Context

Sandboxes need internet access for common agent operations: `npm install`, `pip install`, `git clone`, `curl`, and AI API calls (e.g., Claude Code reaching `api.anthropic.com`). The original plan was TAP networking + NAT, which requires root for bridge/iptables setup.

## Decision: HTTP CONNECT proxy over vsock

Instead of TAP networking, we tunnel HTTP/HTTPS traffic over the existing vsock channel using an HTTP CONNECT proxy. No root, no TAP devices, no iptables. Works with snapshot restore.

### Architecture

```
Guest VM                              Host
┌──────────────────────┐             ┌──────────────────────┐
│                      │             │                      │
│ npm install          │             │                      │
│   ↓ HTTPS_PROXY      │             │                      │
│ 127.0.0.1:3128       │             │                      │
│   ↓ TCP              │             │                      │
│ proxy-bridge (agent)  │── vsock ──►│ HTTP CONNECT proxy    │
│   connects to host    │  port 1027 │   dials real servers  │
│   via AF_VSOCK        │             │   on the internet    │
└──────────────────────┘             └──────────────────────┘
```

### How it works

1. **Host side**: The SDK listens on a vsock UDS for guest-initiated connections on port 1027. When a guest connects, the host reads an HTTP CONNECT request (`CONNECT api.anthropic.com:443 HTTP/1.1`), connects to the real server, replies `200 Connection Established`, and relays bidirectionally.

2. **Guest side**: The agent starts a TCP listener on `127.0.0.1:3128` that bridges each connection to vsock port 1027 (host CID 2). The agent sets `HTTP_PROXY` and `HTTPS_PROXY` env vars so all child processes use the proxy.

3. **HTTPS works correctly**: The proxy does CONNECT tunneling — the TLS handshake happens end-to-end between the guest app and the real server. The proxy only sees the hostname:port from the CONNECT request, never the encrypted payload. No cert issues.

### SDK API

```typescript
// Enable internet access in the sandbox
const sandbox = await Sandbox.create();
await sandbox.enableInternet();

// Now everything that respects HTTP_PROXY works
await sandbox.exec("npm install");
await sandbox.exec("curl https://example.com");
await sandbox.exec("git clone https://github.com/user/repo");
```

`enableInternet()`:
- Starts the host-side CONNECT proxy (listens on `{vsock_uds}_1027`)
- Tells the agent to start the guest-side TCP→vsock bridge on `127.0.0.1:3128`
- Sets `HTTP_PROXY` and `HTTPS_PROXY` in the agent's environment for all future exec/spawn calls

### Why not TAP networking

| | HTTPS proxy over vsock | TAP + NAT |
|---|---|---|
| Root required | No | Yes |
| Setup complexity | Zero | Bridge + iptables + DHCP |
| Works with snapshots | Yes (vsock survives restore) | No (TAP names baked in) |
| HTTP/HTTPS | Full support | Full support |
| Raw TCP/UDP | No | Yes |
| DNS | Via proxy (CONNECT uses hostnames) | Via system resolver |
| Performance | Good (userspace relay) | Wire speed |

For agent use cases (npm, pip, git, API calls), the proxy covers everything. Raw TCP (databases, custom protocols) is the gap — if needed later, TAP can be added as an opt-in advanced mode.

### Implementation details

**Host-side proxy** (`src/network/proxy.ts`):
- Listens on `{vsock_uds}_1027` for guest-initiated connections
- Parses HTTP CONNECT request (one line: `CONNECT host:port HTTP/1.1\r\n\r\n`)
- Connects to `host:port` via Node's `net.connect`
- Replies `HTTP/1.1 200 Connection Established\r\n\r\n`
- Pipes bidirectionally

**Guest-side bridge** (in the Zig agent):
- Listens on `127.0.0.1:3128` (TCP)
- For each connection, opens AF_VSOCK to host CID 2, port 1027
- Relays bidirectionally

**Environment setup**:
- The agent's exec/spawn adds `HTTP_PROXY=http://127.0.0.1:3128` and `HTTPS_PROXY=http://127.0.0.1:3128` to the env when internet is enabled
- Alternatively, write to `/etc/environment` so all processes inherit it

### Limitations

- Only works for programs that respect `HTTP_PROXY`/`HTTPS_PROXY`
- No raw TCP (databases with custom protocols)
- No UDP (DNS goes through the proxy's CONNECT hostname resolution)
- Adds ~1ms latency per connection (vsock relay)

### Security considerations

- The proxy runs on the host and has full internet access. A malicious guest could use it to reach any host:port on the internet.
- For production use, the proxy should support allowlists (e.g., only `registry.npmjs.org`, `api.anthropic.com`).
- The proxy never terminates TLS — it's a transparent tunnel. No MITM risk.
