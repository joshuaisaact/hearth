# Design Documents Index

## Active

| Document | Status | Summary |
|----------|--------|---------|
| [Core Beliefs](core-beliefs.md) | Ratified | Non-negotiable design principles |
| [Firecracker Integration](firecracker-integration.md) | Draft | How we interface with Firecracker |
| [Guest Agent Protocol](guest-agent-protocol.md) | Draft | vsock-based control plane |
| [Snapshot Architecture](snapshot-architecture.md) | Partial | CoW snapshots and fast clone |
| [Networking](networking.md) | Done | Internet via HTTPS proxy over vsock. No root needed |
| [Platform Support](platform-support.md) | Partial | Linux native, WSL2, macOS M3+ via Lima, M1/M2 via remote |
| [Observability](observability.md) | Partial | Logs + metrics via Zig agent → Victoria. OTel traces deferred |
