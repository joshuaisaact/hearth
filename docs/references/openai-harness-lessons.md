# Reference: Lessons from OpenAI Harness Engineering

**Source**: https://openai.com/index/harness-engineering/
**Date**: February 11, 2026
**Author**: Ryan Lopopolo, OpenAI

## Summary

OpenAI built and shipped an internal product with 0 lines of manually-written code using Codex agents. ~1M lines of code, ~1500 PRs, 3 engineers (later 7). Key learnings for Hearth:

## Relevant Takeaways

### 1. Agents need isolated, bootable environments per task
They made their app "bootable per git worktree" so Codex could launch one instance per change. Each agent gets a fully isolated environment including its own observability stack (logs, metrics, traces) that gets torn down after the task.

**Hearth implication**: This is literally our product. We replace "worktree + docker-compose" with "Firecracker microVM snapshot." Faster, more isolated, true disposal.

### 2. Spec-first, repo-local knowledge
They rejected the "one big AGENTS.md" approach. Instead: structured `docs/` directory as system of record, short AGENTS.md as table of contents with pointers. Progressive disclosure. Mechanically enforced freshness.

**Hearth implication**: We adopt this structure directly. Our `docs/` is the system of record.

### 3. Single Codex runs lasting 6+ hours
Agents work for hours autonomously on single tasks. They need environments that stay stable for extended periods — no timeouts, no resource leaks, no state drift.

**Hearth implication**: Sandbox stability is critical. We need robust lifecycle management, health monitoring, and automatic recovery.

### 4. Agent-to-agent review loops
Codex reviews its own changes, requests additional agent reviews, responds to feedback, and iterates until satisfied. Multiple agents working on the same codebase simultaneously.

**Hearth implication**: Multi-sandbox scenarios are a key use case. Each agent needs its own sandbox. The pool/daemon model supports this.

### 5. Observability inside the sandbox
They wired Chrome DevTools Protocol, LogQL, PromQL, and TraceQL into the agent runtime. Agents can query logs and metrics to validate their work.

**Hearth implication**: We should make it easy to expose observability endpoints from guest to host. Port forwarding + structured log streaming.

### 6. "Boring" technology wins
Technologies that are composable, API-stable, and well-represented in training data work best with agents. Custom reimplementation sometimes beats opaque upstream libraries.

**Hearth implication**: Keep our SDK API simple, stable, and conventional. No clever abstractions. Boring is good.

### 7. Entropy requires continuous garbage collection
Agent-generated code drifts over time. They run background cleanup agents on a cadence. Technical debt is paid continuously in small increments.

**Hearth implication**: Sandbox templates should be rebuildable from specs. Snapshot freshness matters.
