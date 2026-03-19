# Product Spec: Environments

**Status**: Draft
**Last updated**: 2026-03-19

## Overview

Environments are pre-built, snapshotted sandbox configurations that let users go from "I have a repo" to "I have an isolated VM with the repo cloned, dependencies installed, and services running" in one command. After the first build, environments restore from snapshot in ~30-50ms.

## Problem

Today, `hearth shell` gives you a blank VM. Getting productive requires manual steps: enable internet, clone a repo, install dependencies, configure tools, start services. `hearth claude` solves this for one specific case (Claude Code) by hardcoding the provisioning steps. Environments generalize this pattern for any project, any language, any toolchain.

## Target User

- Developers who want isolated, reproducible dev environments (like devcontainers but faster)
- AI agent frameworks that need sandboxes pre-loaded with a codebase
- Teams that want to define a standard environment once and share it

## Core Concepts

### Hearthfile

A declarative TOML config that describes what an environment needs. Lives in the repo root as `Hearthfile.toml` or at `~/.hearth/snapshots/<name>/Hearthfile.toml`.

TOML over YAML: no implicit type coercion (`"no"` silently becoming `false`), no significant whitespace, stricter parsing. Matches the direction of modern tooling (Cargo.toml, pyproject.toml).

```toml
name = "my-api"

# Where to get the code
repo = "github.com/user/my-api"
branch = "main"

# Run once during build, baked into snapshot
setup = [
  "pip install -r requirements.txt",
  "python manage.py migrate",
]

# Run on every start (after snapshot restore)
start = [
  "redis-server --daemonize yes",
  "python manage.py runserver 0.0.0.0:8000",
]

# Ports to auto-forward to host
ports = [8000, 6379]

# Optional: poll this before handing control to user
ready = "http://localhost:8000/health"

# Optional: files to inject from host
[[files]]
from = "~/.ssh/id_ed25519"
to = "/home/agent/.ssh/id_ed25519"
mode = "0600"

[[files]]
from = "~/.gitconfig"
to = "/home/agent/.gitconfig"
```

The Hearthfile is intentionally language-agnostic. The `setup` and `start` fields are shell commands — they work the same whether you're running `npm install`, `cargo build`, `pip install`, `go mod download`, or `mix deps.get`.

### Build Phase

`hearth build` reads the Hearthfile and executes a provisioning sequence:

1. Boot a fresh sandbox
2. Enable internet
3. Inject credentials (GitHub token, SSH keys, files from `files:`)
4. Clone the repo
5. Run `setup` commands sequentially
6. Snapshot the result

This is the slow path (seconds to minutes depending on the project). It only runs once, or when the user explicitly rebuilds.

### Start Phase

`hearth shell <env-name>` restores the snapshot, then:

1. Restore from snapshot (~30-50ms)
2. Run `start` commands (if any)
3. Wait for `ready` check to pass (if defined)
4. Forward `ports` to host
5. Hand interactive control to user

### Rebuild

`hearth rebuild <env-name>` re-runs the full build. Useful when:

- Dependencies changed (`package-lock.json`, `requirements.txt`, etc.)
- You want a fresh clone (new branch, rebased code)
- The base image was updated

## CLI Interface

```
hearth build [name]              Build an environment from a Hearthfile
  --file <path>                  Path to Hearthfile (default: ./Hearthfile.toml)
  --repo <url>                   Override repo (for quick one-off builds)
  --branch <branch>              Override branch

hearth rebuild <name>            Rebuild an existing environment from scratch

hearth shell [name]              Start a shell in an environment
                                 (no name = blank sandbox, as today)

hearth claude [name] [args]      Start Claude Code in an environment
                                 (no name = claude-base, as today)

hearth envs                      List built environments
hearth envs rm <name>            Delete an environment and its snapshot
hearth envs inspect <name>       Show Hearthfile + snapshot metadata
```

### Quick build (no Hearthfile)

For one-off use without writing a Hearthfile:

```bash
hearth build my-api --repo github.com/user/my-api
```

This clones the repo and looks for a `Hearthfile.toml` in the repo root. If none exists, it just clones and snapshots — the user gets a VM with the code but no setup steps.

## SDK Interface

### Declarative

```typescript
import { Environment } from "hearth";

// Build or restore transparently
const sandbox = await Environment.get({
  name: "my-api",
  repo: "github.com/user/my-api",
  setup: ["pip install -r requirements.txt", "python manage.py migrate"],
  start: ["python manage.py runserver 0.0.0.0:8000"],
  ports: [8000],
  ready: "http://localhost:8000/health",
});

// First call with a new name: builds + snapshots
// Subsequent calls: restores from snapshot + runs start commands
// sandbox is a normal Sandbox — exec, spawn, readFile, etc. all work

const result = await sandbox.exec("python manage.py test");
```

### Explicit build/restore

```typescript
import { Environment } from "hearth";

// Build (always runs full provisioning)
await Environment.build({
  name: "my-api",
  repo: "github.com/user/my-api",
  setup: ["pip install -r requirements.txt"],
});

// Start (restore + run start commands)
const sandbox = await Environment.start("my-api", {
  start: ["python manage.py runserver 0.0.0.0:8000"],
  ports: [8000],
});
```

### Programmatic build hook

For complex setup that can't be expressed as shell commands:

```typescript
const sandbox = await Environment.get({
  name: "my-api",
  repo: "github.com/user/my-api",
  onBuild: async (sandbox) => {
    await sandbox.exec("pip install -r requirements.txt");
    await sandbox.writeFile("/etc/myapp/config.json", JSON.stringify(config));
    await sandbox.exec("python manage.py migrate");
  },
  onStart: async (sandbox) => {
    const handle = sandbox.spawn("python manage.py runserver 0.0.0.0:8000");
    // custom readiness logic
    await pollUntilReady("http://localhost:8000/health", sandbox);
  },
});
```

## GitHub Authentication

Cloning private repos requires credentials. Environments support these strategies, tried in order:

1. **`GITHUB_TOKEN` env var** — if set on host, injected into VM as `GITHUB_TOKEN` and used via `git config credential.helper`
2. **`gh auth token`** — if `gh` CLI is installed on host, extract token automatically
3. **SSH key injection** — via the `files:` block in the Hearthfile
4. **Explicit token in Hearthfile** — `github_token_env: MY_TOKEN_VAR` (reads named env var from host)

The resolved token is injected into the VM's git credential helper during build. It is **not** baked into the snapshot — on restore, credentials are re-injected from the host.

## Staleness & Updates

Snapshots are point-in-time. The repo will drift from `main` after the build.

**v1 (manual):** `hearth rebuild` is the only way to update. The CLI prints the snapshot age when starting an environment:

```
Restoring my-api (built 3 days ago)...
```

**v2 (optional auto-check):** On restore, optionally run `git fetch --dry-run` to detect if the branch has new commits. If behind, print a warning:

```
Restoring my-api (built 3 days ago, 5 commits behind origin/main)
Run 'hearth rebuild my-api' to update.
```

**Not planned:** automatic rebuild on restore. Too surprising and slow.

## Interaction with `hearth claude`

`hearth claude` becomes a special case of environments. The current hardcoded Claude provisioning logic moves into a built-in environment:

```bash
# These become equivalent:
hearth claude                    # uses built-in claude environment
hearth claude my-api             # Claude Code inside the my-api environment
```

When given an environment name, `hearth claude <env-name>` restores that environment's snapshot and layers Claude Code on top (credentials, config, skip-permissions). This is the primary workflow for AI agent development: "give me Claude Code in a sandbox with my project ready to go."

## Design Principles

1. **Language-agnostic**: `setup` and `start` are shell commands. No magic for any particular ecosystem.
2. **Snapshot-first**: The build phase is a one-time cost. The common path is always a snapshot restore.
3. **Credentials never snapshotted**: Auth tokens and keys are injected at start time, not baked into the snapshot. Safe to share snapshots.
4. **Hearthfile is optional**: `hearth build --repo <url>` works without one. The Hearthfile adds `setup`/`start`/`ports` on top.
5. **Composable with existing API**: An environment produces a normal `Sandbox`. All existing operations (exec, spawn, readFile, forwardPort, etc.) work unchanged.

## Non-Goals (v1)

- **Multi-VM environments** (docker-compose style) — single VM with all services is fine for v1
- **Base image customization** — use the standard rootfs; install extra packages in `setup`
- **Hearthfile templating / variables** — plain TOML, no interpolation
- **Shared/published environments** — local only; sharing comes with the template marketplace (v0.4)
- **Automatic dependency detection** — no magic; user writes their setup commands
- **Hot reload / file sync** — no live-syncing host files into the VM; rebuild or use `upload()`

## Resolved Decisions

1. **Snapshot-with-process:** Not a dedicated feature. Users who want this can take a second snapshot manually after starting services (e.g., `hearth build my-api`, then start services in the shell, then snapshot as `my-api-running`). The existing snapshot primitive already supports this — no new abstraction needed.

2. **Environment inheritance:** Deferred to v2. Single-level Hearthfiles only for now.

3. **Config format:** TOML. No implicit type coercion, no significant whitespace, stricter parsing. Matches modern tooling conventions (Cargo.toml, pyproject.toml). The Hearthfile structure is flat enough that TOML reads cleanly.

4. **Storage:** Environments live in the existing `~/.hearth/snapshots/<name>/` namespace. An `environment.toml` metadata file alongside the snapshot artifacts distinguishes an environment from a bare snapshot. This keeps the snapshot namespace unified — `hearth shell my-api` works regardless of whether `my-api` was built from an environment or captured manually.

## Resolved Decisions (continued)

5. **Clone destination:** `/home/agent/<repo-name>` by default. Override with an optional `workdir` field in the Hearthfile. The shell and `start` commands run from this directory.

6. **Start command failure:** Print the error, then drop the user into a shell so they can debug. Don't destroy the sandbox — the environment is still useful for investigation.
