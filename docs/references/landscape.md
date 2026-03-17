# Reference: Agent Sandbox Landscape (March 2026)

## Overview

The agent sandbox market has matured rapidly. Nearly every major cloud platform and several startups now offer purpose-built sandboxing for AI agent code execution. This document maps the landscape and positions Hearth within it.

## The Players

### Cloud-native, agent-focused

**E2B** (e2b.dev) — The category leader. Cloud-hosted Firecracker microVMs with Python/TypeScript SDKs. ~11.3k GitHub stars. Sub-200ms startup. Used by ~half of Fortune 500. Pricing: $150/mo + ~$0.05/vCPU-hr. 24hr max session on Pro. No GPU, no local option, no user-facing snapshots.

**Daytona** (daytona.io) — Pivoted from dev environments to agent sandboxes in Feb 2025. $24M Series A. Docker containers with optional Kata/Sysbox isolation. Cloud + self-host. Sub-90ms cold start (fastest in category). Python/TS/Go/Ruby SDKs. Pricing: ~$0.067/hr. Default Docker isolation is weaker than microVM.

**Runloop** (runloop.ai) — Enterprise-grade agent sandboxes. MicroVM isolation, SOC2 certified. Python/TS SDKs. $0.108/CPU-hr. 10k+ parallel sandboxes. 2s startup for 10GB images. Raised $7M seed.

### General compute platforms with sandbox features

**Modal** (modal.com) — High-performance serverless compute. gVisor-sandboxed containers. Python-first. The only major sandbox platform with first-class GPU support (H100 at ~$3.95/hr). Sandbox pricing ~$0.142/vCPU-hr (3x standard). Raised $80M.

**Fly Sprites** (fly.io) — Persistent Firecracker microVMs launched Jan 2026. Auto-idle billing. 100GB persistent NVMe. 1-12s creation. $0.07/CPU-hr. Good for long-running agent sessions, less so for high-throughput ephemeral sandboxes.

**Cloudflare Sandboxes** — Edge-deployed containers on Cloudflare infrastructure. JS/TS SDK. ~$0.072/vCPU-hr. Global edge, Workers integration. Limited to Cloudflare ecosystem.

**Vercel Sandbox** — Firecracker microVMs on Vercel. Active CPU billing only. $0.128/active-CPU-hr. Good for Vercel/Next.js ecosystem.

### VM snapshot / branching

**Morph Cloud** (morph.so) — Full VMs with "Infinibranch" technology. Clone a running VM in <250ms with full process state. Python/TS SDKs. Enables parallel agent exploration (fork, try different approaches, merge). Newer, less proven at scale.

**Freestyle** (freestyle.sh) — KVM VMs with live forking (clone in ms). TypeScript SDK. Sub-800ms provisioning. Nested virtualization. Free-$500/mo tiers. Interesting forking primitive, smaller platform.

### Open source / self-hosted

**Kubernetes Agent Sandbox** (kubernetes-sigs) — Launched KubeCon NA Nov 2025. K8s controller with SandboxTemplate/SandboxClaim CRDs. gVisor (default) or Kata isolation. Warm pool orchestrator for sub-second startup. The emerging standard for K8s-based agent sandboxes.

**Alibaba OpenSandbox** (github.com/alibaba/OpenSandbox) — Released March 2026. ~3.8k stars in 72 hours. Docker + K8s runtimes with gVisor/Kata/Firecracker options. SDKs in Python, Java, JS/TS, C#. Supports coding agents, GUI agents (VNC), browser automation. Most comprehensive open-source offering.

**Kata Containers** — Lightweight VMs via QEMU/Cloud Hypervisor/Firecracker. OCI-compatible runtime. 7.6k stars. Production-proven (2M+ workloads/month at Northflank). Strong isolation but significant I/O overhead. No checkpoint/restore.

**gVisor** — Google's userspace kernel. Intercepts syscalls in a Go-based kernel. Millisecond startup, minimal overhead. Powers GKE Sandbox and K8s Agent Sandbox. Weaker isolation than true VMs; not all syscalls implemented.

### Local-only

**Docker Sandboxes** — Built into Docker Desktop 4.60+. MicroVMs for specific coding agents (Claude Code, Codex, Copilot, etc.). Local-only. Free. Not programmable — no SDK, no API for custom agent frameworks.

## Comparison Matrix

| Platform | Isolation | Local | Cloud | Create Time | Exec Latency | Cost | GPU | Snapshots |
|---|---|---|---|---|---|---|---|---|
| E2B | Firecracker | No | Yes | ~150ms | Network RTT | $0.05/vCPU-hr | No | Hidden |
| Daytona | Docker/Kata | Self-host | Yes | ~90ms | Network RTT | $0.067/hr | No | No |
| Modal | gVisor | No | Yes | <1s | Network RTT | $0.142/vCPU-hr | Yes | No |
| Fly Sprites | Firecracker | No | Yes | 1-12s | Network RTT | $0.07/CPU-hr | No | Persistent |
| Morph Cloud | Full VM | No | Yes | <250ms (branch) | Network RTT | Usage | No | Branching |
| Freestyle | KVM | No | Yes | <800ms | Network RTT | $0-500/mo | No | Forking |
| K8s Agent Sandbox | gVisor/Kata | Self-host | No | <1s (warm) | Local | Free OSS | Via K8s | No |
| OpenSandbox | Docker/Kata/FC | Self-host | No | Varies | Local | Free OSS | No | No |
| Docker Sandboxes | microVM | Yes | No | Seconds | Local | Free | No | No |
| **Hearth** | **Firecracker** | **Yes** | **No** | **~135ms** | **~2ms (vsock)** | **Free** | **No** | **Yes (first-class)** |

## Where Hearth Fits

### The gap we fill

There is no local-first agent sandbox with an E2B-level SDK. The options are:

1. **Cloud SDKs** (E2B, Daytona, Modal) — great DX but add latency, cost, and cloud dependency.
2. **Self-hosted runtimes** (Kata, gVisor, K8s Agent Sandbox, OpenSandbox) — strong isolation but they're container runtimes, not agent SDKs. You build the orchestration yourself.
3. **Docker Sandboxes** — local but not programmable. Locked to specific coding agents via the Docker Desktop GUI.

Hearth is: **Firecracker microVMs + TypeScript SDK + snapshot-first design + zero cost, all on your local machine.**

### Where Hearth wins

1. **Zero marginal cost.** At agent scale (hundreds of sandboxes/session, hours of runtime), cloud billing adds up fast. Hearth is free — it's your hardware.

2. **2ms exec latency.** vsock is local memory, not a network round-trip. In tight agent loops (exec → inspect → exec), this compounds. Cloud sandboxes add 20-100ms per operation.

3. **Privacy.** Code never leaves your machine. For enterprise agent workflows with proprietary code, this is a hard requirement that disqualifies all cloud options.

4. **Observability (planned).** No other sandbox SDK exposes `sandbox.logs.query()` or `sandbox.metrics.query()`. Agents can observe what happened inside the sandbox — logs, CPU, memory, errors — not just stdout/stderr. This is the OpenAI harness engineering insight.

5. **User-facing snapshots.** E2B uses snapshots internally but doesn't expose them. Hearth's snapshot-first design enables branching, checkpointing, and rollback — similar to Morph's Infinibranch or Freestyle's forking, but local and free.

### Where Hearth loses

1. **Linux-only.** Requires `/dev/kvm`. macOS/Windows developers need WSL2 or Lima.
2. **No GPU.** Firecracker doesn't support GPU passthrough. Modal is the only good option here.
3. **Single machine.** No multi-host orchestration. For scaling beyond one box, use a cloud solution.
4. **TypeScript SDK only.** No Python SDK yet. Most agent frameworks (LangChain, CrewAI, AutoGen) are Python.
5. **Newer, less proven.** E2B powers half the Fortune 500. Hearth is v0.1.

### Strategic bet

Local-first + observability + snapshots is the winning combination for serious agent development. The OpenAI harness article validated the pattern: agents need isolated environments with full observability, running for hours, at high throughput. Cloud sandboxes work for demos and light use. When you're running an agent harness that spins up hundreds of sandboxes per day, you want:

- No per-second billing eating your budget
- No network latency on every exec call
- Logs and metrics queryable by the agent itself
- Snapshot trees for branching and rollback
- Everything running on hardware you control

## Platform Support

Hearth's local-first approach means dealing with KVM access on each platform:

| Platform | Approach | Snapshot | Audience |
|---|---|---|---|
| Linux | Native KVM | Yes | 100% of Linux devs |
| Windows | WSL2 (native KVM) | Yes | ~all Windows devs |
| macOS M3+ | Lima + nested KVM | Yes | ~40-55% of Mac devs (growing) |
| macOS M1/M2 | Remote daemon | Yes | Remaining Mac devs |

WSL2 is the easiest win — zero code changes. Lima on M3+ works today with the daemon we already built. M1/M2 is the gap — libkrun (native microVMs via Apple HVF, used by Podman) could fill it in a future release, trading snapshot support for universal Mac coverage.

## Entrants to Watch

- **Alibaba OpenSandbox** — most comprehensive OSS offering. If they add a clean agent-first SDK, they compete directly with Hearth's self-hosted positioning.
- **K8s Agent Sandbox** — the natural path if your infra is Kubernetes. Warm pools bring startup under 1s.
- **Freestyle** — live VM forking is close to our snapshot vision. Cloud-only today.
- **Daytona** — self-hostable with the best cold start. If they add Firecracker isolation (not just Docker), they cover more of our space.
- **libkrun/krunvm** — native microVMs on all Apple Silicon via HVF. No nested KVM needed. Potential future Hearth backend for macOS M1/M2.
- **Apple Containerization** — WWDC 2025, full macOS 26. Per-container VM isolation on all Apple Silicon. Could be a future Hearth backend.
