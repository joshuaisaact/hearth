# Hearth — Claude Code Standards

## What is Hearth?

Local-first microVM sandboxes for AI agent development. Think E2B, but runs entirely on your machine. Agents get isolated Linux VMs they can boot, snapshot, exec into, and tear down in milliseconds.

## Tech Stack

- **Language**: TypeScript (strict mode, ESM)
- **Runtime**: Node.js 20+
- **Build**: tsc
- **Test**: vitest
- **Underlying VM**: Flint (custom Zig VMM) via `/dev/kvm`

## Architecture

See `ARCHITECTURE.md` for the full system map. Key layers:

- `src/vm/` — VMM interaction, API client, snapshot management
- `vmm/` — Flint VMM source (Zig), built during setup
- `src/snapshot/` — Copy-on-write snapshots, restore
- `src/network/` — TAP device management, port forwarding
- `src/agent/` — Guest agent protocol (vsock-based)
- `src/sandbox/` — High-level Sandbox API (user-facing)
- `src/api/` — REST/gRPC daemon for multi-tenant access

## Spec-First Development

This project follows a spec-first approach. Before implementing a feature:

1. Write or update the relevant spec in `docs/product-specs/`
2. Create an execution plan in `docs/exec-plans/active/`
3. Implement against the spec
4. Move the exec plan to `docs/exec-plans/completed/` when done

## Key Docs

- `ARCHITECTURE.md` — System architecture and module map
- `docs/design-docs/core-beliefs.md` — Non-negotiable design principles
- `docs/product-specs/index.md` — Product spec index
- `docs/exec-plans/active/` — Current work in progress

## Conventions

- All async operations return Promises (no callbacks)
- Errors are typed: each module defines its own error types
- Tests live next to source files as `*.test.ts`
- No `any` — use `unknown` and narrow
