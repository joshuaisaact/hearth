# Product Spec: Filesystem Operations

**Status**: Partial (writeFile/readFile implemented, upload/download planned)
**Last updated**: 2026-03-16

## Overview

Agents need to read and write files inside sandboxes. This spec defines how host↔guest file operations work.

## Implemented (v0.1)

### writeFile(path, content)
Write string or Buffer content to a file in the guest.

- Content is base64-encoded and sent over the control channel (vsock port 1024)
- Creates file at the target path (parent dirs must exist)
- Supports optional file mode (permissions)
- Max single-file size: ~256KB (agent static buffer limit)

### readFile(path)
Read file content from the guest.

- Returns string (UTF-8)
- Throws if file doesn't exist
- Max single-file size: ~256KB (agent static buffer limit)

## Planned (v0.2)

### upload(hostPath, guestPath)
Recursively copy a file or directory from the host into the guest.

```typescript
await sandbox.upload("./my-project", "/workspace");
```

#### Implementation: tar streaming over vsock CONNECT

```
Host                                     Guest
tar c -C ./my-project . ──stream──►   tar x -C /workspace
                          (vsock)
```

1. Host connects to vsock UDS, sends `CONNECT 1026\n`, waits for `OK\n`
2. Sends JSON header: `{"method":"upload","path":"/workspace"}\n`
3. Streams raw tar bytes from `tar c` stdout directly into vsock
4. Agent reads header, forks `busybox tar x -C /workspace`, pipes vsock → tar stdin
5. Agent closes connection when tar exits

No base64. No memory buffering. Constant memory usage regardless of directory size.

### download(guestPath, hostPath)
Recursively copy a file or directory from the guest to the host.

```typescript
await sandbox.download("/workspace/dist", "./output");
```

Same mechanism in reverse:

1. Host connects to vsock, CONNECT 1026
2. Sends header: `{"method":"download","path":"/workspace/dist"}\n`
3. Agent forks `busybox tar c -C /workspace/dist .`, pipes tar stdout → vsock
4. Host pipes vsock → `tar x -C ./output`

### Why tar over vsock

- **No base64 overhead**: Current `writeFile` base64-encodes everything (33% bloat). Tar streams raw bytes.
- **No memory limits**: Streams directly between tar and vsock. Never buffers the full archive.
- **Uses busybox tar**: Already in the rootfs. Zero additional dependencies.
- **Same vsock CONNECT pattern**: Reuses the port forwarding infrastructure (host connects to vsock UDS, CONNECT handshake, then raw stream).
- **Idiomatic**: This is how `docker cp`, firecracker-containerd, and Kata Containers handle file transfer.

### Agent architecture

The agent listens on vsock port 1026 for transfer requests (same forking model as the port-forward listener on 1025):

- Port 1024: Control channel (exec, writeFile, readFile, ping)
- Port 1025: Port forwarding (TCP relay)
- Port 1026: File transfer (tar streaming)

Each transfer runs in a forked child process. The control channel is never blocked.

## Performance Targets

| Operation | Target | Notes |
|-----------|--------|-------|
| writeFile (1KB) | < 5ms | Inline base64 over control channel |
| readFile (1KB) | < 5ms | Inline base64 over control channel |
| upload (10MB dir) | < 200ms | Tar streaming over vsock |
| download (10MB dir) | < 200ms | Tar streaming over vsock |

## Open Questions

1. **Symlinks**: Follow or preserve during tar? Default to preserve (`tar` default behavior).
2. **Excludes**: Should `upload()` support a glob/pattern for excluding files (e.g., `node_modules`)?
3. **Permissions**: tar preserves permissions by default. Do we need uid/gid mapping?
