# Changelog

## Unreleased

## 0.3.0 — 2026-03-21

### Added
- **Global defaults** (`~/.hearth/defaults.toml`) — define `setup` commands and `files` that get merged into every `hearth build`. No more repeating `npm install -g @anthropic-ai/claude-code` in every Hearthfile.
- **Shared TOML validators** — `parseSetupField()` and `parseFilesField()` extracted from Hearthfile parsing for reuse.

### Fixed
- **Proxy race condition** — `enableInternet()` now waits for the guest-side proxy bridge (TCP 3128) to be ready before returning, eliminating intermittent `EAI_AGAIN` DNS errors.
- **Proxy env in Claude startup** — proxy environment variables are set directly in the startup script instead of relying on `.bashrc` sourcing, which failed because `su -` resets the environment.
- **Proxy readiness timeout** — `enableInternet()` throws `TimeoutError` if the guest proxy bridge doesn't start within 2s instead of silently proceeding with a broken proxy.
- **Consolidated proxy constants** — proxy port and URL defined once in `proxy.ts` (`PROXY_GUEST_PORT`, `PROXY_URL`) instead of hardcoded in multiple files.

## 0.2.0 — 2026-03-18

### Added
- **Interactive shell** (`hearth shell [snapshot-name]`) — drops you into a live bash session inside a sandbox. PTY-based, with full terminal support (colors, readline, Ctrl-C, tab completion, window resize).
- **Spawn stdin/resize** — `SpawnHandle` now exposes `stdin.write()` and `resize()` for interactive use.
- **Daemon stdin forwarding** — `spawn_stdin` and `spawn_resize` daemon protocol messages.
- **Race-safe event buffering** — daemon client buffers spawn events that arrive before the listener is registered.

### Changed
- **Guest agent migrated to std.posix + libc** — replaced raw Linux syscalls with idiomatic `std.posix` (fork, read, write, close, dup2, pipe, poll, waitpid, open, mkdir, kill). libc used only for `openpty` and `setitimer` (no posix equivalent). Raw `linux.*` retained only for vsock/TCP sockets and `accept4`.
- **Agent links musl libc** — statically linked, no runtime dependency. Binary size: 2.4MB → 2.6MB.
- **SpawnOptions** extended from type alias to interface with `interactive`, `cols`, `rows` fields.

### Fixed
- Child processes now exit on `dup2`/`setsid` failure instead of silently continuing with wrong fds.
- Socket setup functions use `errdefer posix.close(fd)` instead of manual close on each error path.
- Port values from JSON are bounds-checked before `u32→u16` cast (prevents panic on port > 65535).
- `SockaddrVm` size check uses `@compileError` instead of `std.debug.assert` (removed in ReleaseFast).
- PTY master/slave fds initialized to `-1` instead of `undefined`.
- Interactive spawn recv buffer carries partial frames across reads (previously dropped).
- Child process killed with `SIGHUP` on socket disconnect to prevent `waitpid` blocking indefinitely.
- Remaining PTY output drained before sending exit message.

## 0.1.0 — 2026-03-17

Initial release.

- Sandbox create/destroy with Firecracker snapshot restore (~135ms)
- `exec()` and `spawn()` with streaming stdout/stderr
- File read/write, upload/download (tar streaming over vsock)
- Port forwarding over vsock
- Internet access via HTTP CONNECT proxy
- Named snapshots (save/restore/list/delete)
- Daemon server/client for macOS (via Lima)
- Prebuilt agent binaries (x86_64 + aarch64)
