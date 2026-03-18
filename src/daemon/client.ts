import net from "node:net";
import { join } from "node:path";
import { homedir, platform } from "node:os";
import { existsSync } from "node:fs";
import { EventEmitter } from "node:events";
import { encodeMessage, parseFrames } from "../util.js";
import type { ExecResult, ExecOptions, SpawnOptions, SnapshotInfo } from "../sandbox/types.js";
import type { SpawnHandle } from "../agent/client.js";

const DEFAULT_SOCKET = join(homedir(), ".hearth", "daemon.sock");
const DEFAULT_PORT = 7117;

/** Connection target: Unix socket path, TCP host:port, or auto-detect. */
export type DaemonTarget = string | { host: string; port: number };
/** A parsed JSON response from the daemon. */
interface DaemonResponse {
  reqId?: number;
  ok?: boolean;
  error?: string;
  sandboxId?: string;
  spawnId?: number;
  stdout?: string;
  stderr?: string;
  exitCode?: number;
  content?: string;
  host?: string;
  port?: number;
  name?: string;
  snapshots?: SnapshotInfo[];
  event?: string;
  data?: string;
}

export class DaemonClient {
  private conn: net.Socket | null = null;
  private pending = new Map<number, {
    resolve: (value: DaemonResponse) => void;
    reject: (err: Error) => void;
  }>();
  private spawnListeners = new Map<number, {
    stdout: EventEmitter;
    stderr: EventEmitter;
    exitResolve: (result: { exitCode: number }) => void;
  }>();
  private pendingSpawnEvents = new Map<number, DaemonResponse[]>();
  private nextReqId = 1;

  /**
   * Connect to the daemon.
   * - No args: auto-detect (macOS tries TCP first, Linux tries Unix socket first)
   * - String: Unix socket path
   * - { host, port }: TCP connection
   */
  async connect(target?: DaemonTarget): Promise<void> {
    if (target === undefined) {
      return this.autoConnect();
    }
    return this.connectTo(target);
  }

  private async autoConnect(): Promise<void> {
    // Check env var first
    const envUrl = process.env.HEARTH_DAEMON_URL;
    if (envUrl) {
      if (envUrl.startsWith("tcp://")) {
        const [host, portStr] = envUrl.slice(6).split(":");
        return this.connectTo({ host, port: parseInt(portStr, 10) });
      }
      if (envUrl.startsWith("unix://")) {
        return this.connectTo(envUrl.slice(7));
      }
      return this.connectTo(envUrl);
    }

    const isMac = platform() === "darwin";

    if (isMac) {
      // macOS: try TCP first (Lima port forwarding), fall back to Unix socket
      try {
        return await this.connectTo({ host: "127.0.0.1", port: DEFAULT_PORT });
      } catch {
        return this.connectTo(DEFAULT_SOCKET);
      }
    }

    // Linux/WSL: try Unix socket first, fall back to TCP
    if (existsSync(DEFAULT_SOCKET)) {
      try {
        return await this.connectTo(DEFAULT_SOCKET);
      } catch {}
    }
    return this.connectTo({ host: "127.0.0.1", port: DEFAULT_PORT });
  }

  private connectTo(target: DaemonTarget): Promise<void> {
    return new Promise((resolve, reject) => {
      const conn = typeof target === "string"
        ? net.connect({ path: target })
        : net.connect({ host: target.host, port: target.port });
      conn.once("connect", () => {
        if (typeof target !== "string") conn.setNoDelay(true);
        this.conn = conn;
        this.startReading();
        resolve();
      });
      conn.once("error", reject);
    });
  }

  private startReading(): void {
    if (!this.conn) return;

    let remainder: Buffer = Buffer.alloc(0);

    this.conn.on("data", (chunk: Buffer) => {
      const combined: Buffer = remainder.length > 0
        ? Buffer.concat([remainder, chunk])
        : chunk;

      const result = parseFrames(combined);
      remainder = result.remainder;

      for (const json of result.messages) {
        try {
          this.handleResponse(JSON.parse(json) as DaemonResponse);
        } catch {}
      }
    });
  }

  private handleResponse(msg: DaemonResponse): void {
    // Spawn stream events
    if (msg.event && msg.spawnId !== undefined) {
      const listener = this.spawnListeners.get(msg.spawnId);
      if (!listener) {
        // Events may arrive before the spawn request resolves.
        // Buffer them and replay once the listener is registered.
        let buf = this.pendingSpawnEvents.get(msg.spawnId);
        if (!buf) {
          buf = [];
          this.pendingSpawnEvents.set(msg.spawnId, buf);
        }
        if (buf.length < 1000) buf.push(msg); // cap to prevent unbounded growth
        return;
      }

      if (msg.event === "stdout") {
        listener.stdout.emit("data", msg.data);
      } else if (msg.event === "stderr") {
        listener.stderr.emit("data", msg.data);
      } else if (msg.event === "exit") {
        listener.exitResolve({ exitCode: msg.exitCode ?? 1 });
        this.spawnListeners.delete(msg.spawnId);
      }
      return;
    }

    // Request/response — match by reqId
    if (msg.reqId !== undefined) {
      const handler = this.pending.get(msg.reqId);
      if (handler) {
        this.pending.delete(msg.reqId);
        if (msg.error) {
          handler.reject(new Error(msg.error));
        } else {
          handler.resolve(msg);
        }
      }
    }
  }

  /** Replay any spawn events that arrived before the listener was registered. */
  private drainPendingEvents(spawnId: number): void {
    const buffered = this.pendingSpawnEvents.get(spawnId);
    if (!buffered) return;
    this.pendingSpawnEvents.delete(spawnId);
    for (const msg of buffered) {
      this.handleResponse(msg);
    }
  }

  private request(msg: object): Promise<DaemonResponse> {
    return new Promise((resolve, reject) => {
      if (!this.conn) {
        reject(new Error("Not connected to daemon"));
        return;
      }
      const reqId = this.nextReqId++;
      this.pending.set(reqId, { resolve, reject });
      this.conn.write(encodeMessage({ ...msg, reqId }));
    });
  }

  /** Send a message without waiting for a response (fire-and-forget). */
  private sendNoReply(msg: object): void {
    if (!this.conn) return;
    const reqId = this.nextReqId++;
    const cleanup = () => { this.pending.delete(reqId); };
    this.pending.set(reqId, { resolve: cleanup as (v: DaemonResponse) => void, reject: cleanup as (e: Error) => void });
    this.conn.write(encodeMessage({ ...msg, reqId }));
  }

  async create(): Promise<RemoteSandbox> {
    const resp = await this.request({ method: "create" });
    if (!resp.sandboxId) throw new Error("Daemon did not return sandboxId");
    return new RemoteSandbox(this, resp.sandboxId);
  }

  async fromSnapshot(name: string): Promise<RemoteSandbox> {
    const resp = await this.request({ method: "fromSnapshot", name });
    if (!resp.sandboxId) throw new Error("Daemon did not return sandboxId");
    return new RemoteSandbox(this, resp.sandboxId);
  }

  listSnapshots(): Promise<SnapshotInfo[]> {
    return this.request({ method: "listSnapshots" }).then((r) => r.snapshots ?? []);
  }

  async deleteSnapshot(name: string): Promise<void> {
    await this.request({ method: "deleteSnapshot", name });
  }

  /** @internal Called by RemoteSandbox */
  _exec(sandboxId: string, command: string, opts?: ExecOptions): Promise<ExecResult> {
    return this.request({ method: "exec", sandboxId, command, opts }).then((r) => ({
      stdout: r.stdout ?? "",
      stderr: r.stderr ?? "",
      exitCode: r.exitCode ?? 1,
    }));
  }

  /** @internal */
  _spawn(sandboxId: string, command: string, opts?: SpawnOptions): SpawnHandle {
    const stdout = new EventEmitter();
    const stderr = new EventEmitter();
    let exitResolve: (result: { exitCode: number }) => void;
    const exitPromise = new Promise<{ exitCode: number }>((resolve) => {
      exitResolve = resolve;
    });

    let resolvedSpawnId: number | undefined;
    const spawnReady = this.request({ method: "spawn", sandboxId, command, opts }).then((r) => {
      if (r.spawnId === undefined) { exitResolve({ exitCode: 1 }); return; }
      resolvedSpawnId = r.spawnId;
      this.spawnListeners.set(r.spawnId, { stdout, stderr, exitResolve });
      this.drainPendingEvents(r.spawnId);
    }).catch(() => {
      exitResolve({ exitCode: 1 });
    });

    const client = this;

    return {
      stdout,
      stderr,
      stdin: {
        write(data: string | Buffer): void {
          const strData = Buffer.isBuffer(data) ? data.toString("utf-8") : data;
          if (resolvedSpawnId !== undefined) {
            client.sendNoReply({ method: "spawn_stdin", sandboxId, spawnId: resolvedSpawnId, data: strData });
          } else {
            spawnReady.then(() => {
              if (resolvedSpawnId !== undefined) {
                client.sendNoReply({ method: "spawn_stdin", sandboxId, spawnId: resolvedSpawnId, data: strData });
              }
            });
          }
        },
        close(): void {},
      },
      resize(cols: number, rows: number): void {
        if (resolvedSpawnId !== undefined) {
          client.sendNoReply({ method: "spawn_resize", sandboxId, spawnId: resolvedSpawnId, cols, rows });
        } else {
          spawnReady.then(() => {
            if (resolvedSpawnId !== undefined) {
              client.sendNoReply({ method: "spawn_resize", sandboxId, spawnId: resolvedSpawnId, cols, rows });
            }
          });
        }
      },
      wait: () => exitPromise,
      kill: () => {},
    };
  }

  /** @internal */
  _writeFile(sandboxId: string, path: string, content: string | Buffer): Promise<void> {
    const strContent = Buffer.isBuffer(content) ? content.toString("utf-8") : content;
    return this.request({ method: "writeFile", sandboxId, path, content: strContent }).then(() => {});
  }

  /** @internal */
  _readFile(sandboxId: string, path: string): Promise<string> {
    return this.request({ method: "readFile", sandboxId, path }).then((r) => r.content ?? "");
  }

  /** @internal */
  _upload(sandboxId: string, hostPath: string, guestPath: string): Promise<void> {
    return this.request({ method: "upload", sandboxId, hostPath, guestPath }).then(() => {});
  }

  /** @internal */
  _download(sandboxId: string, guestPath: string, hostPath: string): Promise<void> {
    return this.request({ method: "download", sandboxId, guestPath, hostPath }).then(() => {});
  }

  /** @internal */
  _forwardPort(sandboxId: string, guestPort: number): Promise<{ host: string; port: number }> {
    return this.request({ method: "forwardPort", sandboxId, guestPort }).then((r) => ({
      host: r.host ?? "127.0.0.1",
      port: r.port ?? 0,
    }));
  }

  /** @internal */
  _enableInternet(sandboxId: string): Promise<void> {
    return this.request({ method: "enableInternet", sandboxId }).then(() => {});
  }

  /** @internal */
  _snapshot(sandboxId: string, name: string): Promise<string> {
    return this.request({ method: "snapshot", sandboxId, name }).then((r) => r.name ?? name);
  }

  /** @internal */
  _destroy(sandboxId: string): Promise<void> {
    return this.request({ method: "destroy", sandboxId }).then(() => {});
  }

  close(): void {
    if (this.conn) {
      this.conn.destroy();
      this.conn = null;
    }
  }
}

export class RemoteSandbox {
  private client: DaemonClient;
  private sandboxId: string;

  constructor(client: DaemonClient, sandboxId: string) {
    this.client = client;
    this.sandboxId = sandboxId;
  }

  exec(command: string, opts?: ExecOptions): Promise<ExecResult> {
    return this.client._exec(this.sandboxId, command, opts);
  }

  spawn(command: string, opts?: SpawnOptions): SpawnHandle {
    return this.client._spawn(this.sandboxId, command, opts);
  }

  writeFile(path: string, content: string | Buffer): Promise<void> {
    return this.client._writeFile(this.sandboxId, path, content);
  }

  readFile(path: string): Promise<string> {
    return this.client._readFile(this.sandboxId, path);
  }

  upload(hostPath: string, guestPath: string): Promise<void> {
    return this.client._upload(this.sandboxId, hostPath, guestPath);
  }

  download(guestPath: string, hostPath: string): Promise<void> {
    return this.client._download(this.sandboxId, guestPath, hostPath);
  }

  forwardPort(guestPort: number): Promise<{ host: string; port: number }> {
    return this.client._forwardPort(this.sandboxId, guestPort);
  }

  enableInternet(): Promise<void> {
    return this.client._enableInternet(this.sandboxId);
  }

  snapshot(name: string): Promise<string> {
    return this.client._snapshot(this.sandboxId, name);
  }

  destroy(): Promise<void> {
    return this.client._destroy(this.sandboxId);
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.destroy();
  }
}
