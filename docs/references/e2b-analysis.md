# Reference: E2B Analysis

**Source**: https://github.com/e2b-dev/E2B, https://github.com/e2b-dev/desktop
**Date**: 2026-03-16

## What E2B Does

E2B provides cloud-hosted sandboxes for AI agent code execution. SDKs in TypeScript and Python. Firecracker underneath, fully managed.

## SDK Design (what we're learning from)

```typescript
import { Sandbox } from "@e2b/code-interpreter";
const sandbox = await Sandbox.create();
await sandbox.runCode("x = 1");
const execution = await sandbox.runCode("x+=1; x");
```

Clean, minimal API. `create()` → `runCode()` → done.

E2B Desktop extends this with mouse/keyboard control via streaming:
```python
desktop = Sandbox.create()
desktop.leftClick(100, 200)
desktop.write("hello")
```

## Strengths

- **DX**: Extremely simple to get started. One import, one line to create.
- **Code interpreter**: Built-in Jupyter-style code execution, not just shell exec.
- **Ephemeral by default**: Sandboxes are disposable. No state management burden.
- **Multi-language SDKs**: TypeScript + Python covers most agent frameworks.

## Gaps (Hearth's opportunity)

1. **Cloud-only**: Requires E2B account + API key. Every sandbox is a network round-trip. Latency and cost scale with usage.
2. **No local option**: Can't run air-gapped, can't run offline, can't run at zero marginal cost.
3. **No snapshots exposed**: Users can't snapshot/restore arbitrary VM state.
4. **Opaque infrastructure**: Users can't customize the VM, kernel, or init system.
5. **Rate limits**: Cloud resource contention. Can't spin up 50 sandboxes simultaneously for free.

## What Hearth Should Match

- API simplicity: `Sandbox.create()` with zero config must work
- TypeScript-first SDK
- Async/await everywhere
- Structured return types

## What Hearth Should Beat

- Latency: Local Firecracker < Cloud Firecracker
- Cost: Free (your hardware) vs per-second billing
- Customization: Full control over rootfs, kernel, init, networking
- Snapshots: First-class, user-controlled snapshot trees
- Privacy: Code never leaves your machine
