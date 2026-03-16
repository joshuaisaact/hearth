# Product Spec: Filesystem Operations

**Status**: Draft
**Last updated**: 2026-03-16

## Overview

Agents need to read and write files inside sandboxes. This spec defines how host↔guest file operations work.

## Operations

### writeFile(path, content)
Write string or Buffer content to a file in the guest.

- Creates parent directories as needed
- Supports optional file mode (permissions)
- Content encoding: UTF-8 for strings, raw for Buffers
- Max single-file size: 100MB (larger files use streaming upload)

### readFile(path)
Read file content from the guest.

- Returns string (UTF-8) or Buffer (binary)
- Throws if file doesn't exist
- Max single-file size: 100MB (larger files use streaming download)

### upload(hostPath, guestPath)
Recursively copy a file or directory from the host into the guest.

- Uses tar streaming over vsock for efficiency
- Preserves file permissions and directory structure
- Supports glob patterns for selective upload

### download(guestPath, hostPath)
Recursively copy a file or directory from the guest to the host.

- Uses tar streaming over vsock
- Creates host directories as needed

### listDir(path)
List directory contents.

```typescript
const entries = await sandbox.listDir("/workspace");
// [{ name: "main.py", type: "file", size: 1234 }, ...]
```

### stat(path)
Get file metadata.

```typescript
const info = await sandbox.stat("/workspace/main.py");
// { type: "file", size: 1234, mode: 0o644, mtime: "2026-03-16T..." }
```

## Transfer Protocol

For small files (< 1MB), content is sent inline in the vsock JSON message (base64 encoded for binary).

For larger files and directories, we use a streaming protocol:
1. Host sends a `transfer_start` message with metadata
2. Data flows as raw bytes over a dedicated vsock connection
3. Transfer completes with a `transfer_end` message on the control channel

This avoids base64 overhead and memory pressure for large transfers.

## Performance Targets

| Operation | Target | Notes |
|-----------|--------|-------|
| writeFile (1KB) | < 5ms | Inline in vsock message |
| readFile (1KB) | < 5ms | Inline in vsock message |
| upload (10MB dir) | < 200ms | Tar streaming |
| download (10MB dir) | < 200ms | Tar streaming |

## Open Questions

1. **Watch/notify**: Should we support filesystem watches (inotify-style) from host? Useful for agents that want to react to file changes.
2. **Symlinks**: Follow or preserve? Both have valid use cases.
3. **Large file streaming**: For files > 100MB, do we stream through vsock or mount a shared virtio-fs device?
