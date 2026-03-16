# Core Beliefs

These are non-negotiable principles that guide every design decision in Hearth. When two options conflict, these beliefs break the tie.

## 1. Local-first, always

Hearth runs entirely on the developer's machine. No cloud accounts, no API keys, no SaaS dependencies. A developer with a Linux box and KVM should be able to `npm install hearth` and have sandboxes running in minutes.

**Why**: Cloud sandboxes add latency, cost, and a dependency on someone else's uptime. AI agent development is iterative — agents may spin up hundreds of sandboxes in a session. That feedback loop must be sub-second and free.

## 2. Real isolation, not theater

Firecracker microVMs provide hardware-level isolation via KVM. This is not Docker, not namespaces, not a chroot. Each sandbox is a real virtual machine with its own kernel. An agent that `rm -rf /` inside a sandbox destroys nothing on the host.

**Why**: Agents will run arbitrary, untrusted code. The isolation boundary must be the hardware, not a configuration file.

## 3. Milliseconds matter

VM boot times must be under 150ms. Snapshot restore must be under 50ms. Exec latency (command submission to first byte of output) must be under 10ms. These are hard targets, not aspirations.

**Why**: Agents operate in tight loops. If sandbox creation takes seconds, agents will batch work to avoid the cost, leading to larger, harder-to-debug changes. Fast sandboxes enable small, focused, disposable work units.

## 4. Snapshots are the primitive

The primary way to create a sandbox is to clone from a snapshot. Base images are snapshots. Templates are snapshots. "Restoring to a known state" is restoring a snapshot. The entire state model is built around copy-on-write snapshot trees.

**Why**: Boot-from-scratch is slow. Snapshot restore is fast. Building on snapshots also gives us free versioning, branching, and rollback — exactly what agents need.

## 5. The SDK is the product

The TypeScript SDK must be beautiful. `Sandbox.create()` should feel as natural as `fetch()`. No configuration objects with 40 fields. No "modes" or "strategies." Progressive disclosure: simple things are simple, complex things are possible.

**Why**: If the SDK is hard to use, people will use Docker instead. Our competition isn't other VM tools — it's `docker run`.

## 6. Agents are first-class users

The API is designed for programmatic use by AI agents, not for humans clicking buttons. This means: structured output for all operations, deterministic behavior, clear error messages that an LLM can act on, and no interactive prompts.

**Why**: This is an agent development tool. Every API surface should assume the caller is a language model.

## 7. No daemons required (but supported)

The SDK must work without a long-running daemon. Direct mode: the SDK manages Firecracker processes itself. Daemon mode: for shared pools and multi-agent scenarios. The user shouldn't have to think about this until they need to.

**Why**: Developer friction. "Install this, then start this service, then configure this" is the death of adoption. `npm install && sandbox.create()` must work.

## 8. Composable, not monolithic

Hearth is a set of composable primitives (VM, snapshot, network, exec), not a monolithic platform. Users can use just the VM layer, or just snapshots, or the full Sandbox API. Each layer has a clean interface and can be used independently.

**Why**: Different agents need different things. A code execution agent doesn't need port forwarding. A web testing agent doesn't need filesystem snapshots. Don't force everyone through the same abstraction.
