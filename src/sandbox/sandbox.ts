import { randomBytes } from "node:crypto";
import {
  mkdirSync, rmSync, unlinkSync, existsSync, constants,
  readdirSync, readFileSync, writeFileSync,
} from "node:fs";
import { copyFile, rename } from "node:fs/promises";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import { FirecrackerApi } from "../vm/api.js";
import { AgentClient } from "../agent/client.js";
import { getFirecrackerPath, getHearthDir } from "../vm/binary.js";
import {
  ensureBaseSnapshot,
  getSnapshotDir,
  ROOTFS_NAME,
  VMSTATE_NAME,
  MEMORY_NAME,
  VSOCK_NAME,
  SOCKET_NAME,
} from "../vm/snapshot.js";
import { startProxy } from "../network/proxy.js";
import { createThinSnapshot, destroyThinSnapshot, isThinPoolAvailable } from "../vm/thin.js";
import { VmBootError } from "../errors.js";
import { waitForFile, errorMessage } from "../util.js";
import type { SpawnHandle } from "../agent/client.js";
import type { SnapshotInfo, ExecResult, ExecOptions, SpawnOptions } from "./types.js";

function userSnapshotDir(name: string): string {
  if (!/^[a-zA-Z0-9_-]+$/.test(name)) {
    throw new Error(`Invalid snapshot name: ${name}`);
  }
  return join(getHearthDir(), "snapshots", name);
}

const activeSandboxes = new Set<Sandbox>();

process.on("exit", () => {
  for (const sb of activeSandboxes) {
    sb.destroySync();
  }
});

export class Sandbox {
  private process: ChildProcess;
  private api: FirecrackerApi;
  private agent: AgentClient;
  private runDir: string;
  private sandboxId: string;
  private vsockPath: string;
  private thinDevice: string | null = null;
  private portForwardServers: net.Server[] = [];
  private proxyServer: net.Server | null = null;
  private internetEnabled = false;
  private destroyed = false;

  private constructor(
    proc: ChildProcess,
    api: FirecrackerApi,
    agent: AgentClient,
    runDir: string,
    sandboxId: string,
    vsockPath: string,
    thinDevice: string | null,
  ) {
    this.process = proc;
    this.api = api;
    this.agent = agent;
    this.runDir = runDir;
    this.sandboxId = sandboxId;
    this.vsockPath = vsockPath;
    this.thinDevice = thinDevice;
    activeSandboxes.add(this);
  }

  /** Create a sandbox from the base snapshot. */
  static async create(): Promise<Sandbox> {
    await ensureBaseSnapshot();
    return Sandbox.restoreFromDir(getSnapshotDir());
  }

  /** Create a sandbox from a named user snapshot. */
  static async fromSnapshot(name: string): Promise<Sandbox> {
    return Sandbox.restoreFromDir(userSnapshotDir(name));
  }

  /** List all available user snapshots (excludes the internal "base" snapshot). */
  static listSnapshots(): SnapshotInfo[] {
    const snapshotsDir = join(getHearthDir(), "snapshots");
    if (!existsSync(snapshotsDir)) return [];

    return readdirSync(snapshotsDir)
      .filter((name) => {
        if (name === "base") return false;
        return existsSync(join(snapshotsDir, name, VMSTATE_NAME));
      })
      .map((name) => {
        let createdAt = "";
        try {
          createdAt = JSON.parse(readFileSync(join(snapshotsDir, name, "metadata.json"), "utf-8")).createdAt;
        } catch {}
        return { id: name, createdAt };
      });
  }

  /** Delete a named snapshot. */
  static deleteSnapshot(name: string): void {
    if (name === "base") throw new Error("Cannot delete the base snapshot");
    rmSync(userSnapshotDir(name), { recursive: true, force: true });
  }

  /** Restore a sandbox from a snapshot directory. */
  private static async restoreFromDir(snapshotDir: string): Promise<Sandbox> {
    const id = randomBytes(8).toString("hex");
    const runDir = join(getHearthDir(), "run", id);
    mkdirSync(runDir, { recursive: true });

    // Try dm-thin for the rootfs (instant CoW), fall back to file copy
    let thinDevice: string | null = null;
    if (isThinPoolAvailable()) {
      thinDevice = createThinSnapshot(id);
    }

    if (thinDevice) {
      // Thin snapshot for rootfs — only copy vmstate and memory
      await Promise.all([
        copyFile(join(snapshotDir, VMSTATE_NAME), join(runDir, VMSTATE_NAME)),
        copyFile(join(snapshotDir, MEMORY_NAME), join(runDir, MEMORY_NAME)),
      ]);
      // Symlink rootfs to the thin device so Firecracker finds it at the expected path
      const { symlinkSync } = await import("node:fs");
      symlinkSync(thinDevice, join(runDir, ROOTFS_NAME));
    } else {
      // File copy fallback (reflink on btrfs/XFS)
      const clone = constants.COPYFILE_FICLONE;
      await Promise.all([
        copyFile(join(snapshotDir, ROOTFS_NAME), join(runDir, ROOTFS_NAME), clone),
        copyFile(join(snapshotDir, VMSTATE_NAME), join(runDir, VMSTATE_NAME), clone),
        copyFile(join(snapshotDir, MEMORY_NAME), join(runDir, MEMORY_NAME), clone),
      ]);
    }

    const vsockPath = join(runDir, VSOCK_NAME);
    const agent = new AgentClient(vsockPath);
    const agentConnected = agent.waitForConnection(10000);

    const proc = spawn(
      getFirecrackerPath(),
      ["--api-sock", SOCKET_NAME],
      {
        stdio: ["ignore", "pipe", "pipe"],
        cwd: runDir,
        detached: false,
      },
    );

    let stderrBuf = "";
    proc.stderr?.on("data", (chunk: Buffer) => {
      if (stderrBuf.length < 2000) stderrBuf += chunk.toString();
    });

    const cleanup = () => {
      try { proc.kill("SIGKILL"); } catch {}
      if (thinDevice) destroyThinSnapshot(id);
      rmSync(runDir, { recursive: true, force: true });
    };

    try {
      await waitForFile(join(runDir, SOCKET_NAME), 5000);
    } catch {
      cleanup();
      throw new VmBootError(
        `Firecracker failed to start. stderr: ${stderrBuf.slice(0, 500)}`,
      );
    }

    const api = new FirecrackerApi(join(runDir, SOCKET_NAME));
    try {
      await api.loadSnapshot(VMSTATE_NAME, MEMORY_NAME, true);
    } catch (err) {
      cleanup();
      throw new VmBootError(`Failed to load snapshot: ${errorMessage(err)}`);
    }

    try {
      await agentConnected;
    } catch (err) {
      cleanup();
      throw new VmBootError(
        `Agent failed to reconnect after snapshot restore: ${errorMessage(err)}`,
      );
    }

    await agent.ping();

    return new Sandbox(proc, api, agent, runDir, id, vsockPath, thinDevice);
  }

  /**
   * Capture the current sandbox state as a named snapshot.
   * The sandbox is destroyed after snapshotting (Firecracker pauses the VM).
   * Returns the snapshot name.
   */
  async snapshot(name: string): Promise<string> {
    this.ensureAlive();

    const snapDir = userSnapshotDir(name);
    if (existsSync(snapDir)) {
      throw new Error(`Snapshot "${name}" already exists`);
    }

    // Pause first — if this fails, the sandbox is still usable
    await this.api.pause();

    // Close agent and port forwards after pause succeeded
    for (const s of this.portForwardServers) {
      try { s.close(); } catch {}
    }
    this.agent.close();

    mkdirSync(snapDir, { recursive: true });

    try {
      await this.api.createSnapshot(VMSTATE_NAME, MEMORY_NAME);

      // Rename (move) files from runDir to snapDir — O(1) on same filesystem
      await Promise.all([
        rename(join(this.runDir, ROOTFS_NAME), join(snapDir, ROOTFS_NAME)),
        rename(join(this.runDir, VMSTATE_NAME), join(snapDir, VMSTATE_NAME)),
        rename(join(this.runDir, MEMORY_NAME), join(snapDir, MEMORY_NAME)),
      ]);

      writeFileSync(
        join(snapDir, "metadata.json"),
        JSON.stringify({ name, createdAt: new Date().toISOString() }),
      );
    } catch (err) {
      rmSync(snapDir, { recursive: true, force: true });
      throw new Error(`Failed to create snapshot: ${errorMessage(err)}`);
    }

    this.destroySync();
    return name;
  }

  async exec(command: string, opts?: ExecOptions): Promise<ExecResult> {
    this.ensureAlive();
    return this.agent.exec(wrapCommand(command, this.mergeProxyEnv(opts)), { timeout: opts?.timeout });
  }

  /** Spawn a long-running command with streaming stdout/stderr. */
  spawn(command: string, opts?: SpawnOptions): SpawnHandle {
    this.ensureAlive();
    return this.agent.spawn(wrapCommand(command, this.mergeProxyEnv(opts)), {
      timeout: opts?.timeout,
      interactive: opts?.interactive,
      cols: opts?.cols,
      rows: opts?.rows,
    });
  }

  /**
   * Enable internet access inside the sandbox.
   * Starts an HTTP CONNECT proxy on the host, tunneled over vsock.
   * All exec/spawn calls will automatically have HTTP_PROXY set.
   */
  async enableInternet(): Promise<void> {
    this.ensureAlive();
    if (this.internetEnabled) return;

    this.proxyServer = await startProxy(join(this.runDir, VSOCK_NAME));
    this.internetEnabled = true;
  }

  private mergeProxyEnv(opts?: ExecOptions): ExecOptions | undefined {
    if (!this.internetEnabled) return opts;
    const proxyUrl = "http://127.0.0.1:3128";
    const proxyEnv = {
      HTTP_PROXY: proxyUrl,
      HTTPS_PROXY: proxyUrl,
      http_proxy: proxyUrl,
      https_proxy: proxyUrl,
    };
    return {
      ...opts,
      env: { ...proxyEnv, ...opts?.env },
    };
  }

  async writeFile(path: string, content: string | Buffer): Promise<void> {
    this.ensureAlive();
    return this.agent.writeFile(path, content);
  }

  async readFile(path: string): Promise<string> {
    this.ensureAlive();
    return this.agent.readFile(path);
  }

  async upload(hostPath: string, guestPath: string): Promise<void> {
    this.ensureAlive();
    await this.tarTransfer("upload", guestPath, hostPath);
  }

  async download(guestPath: string, hostPath: string): Promise<void> {
    this.ensureAlive();
    mkdirSync(hostPath, { recursive: true });
    await this.tarTransfer("download", guestPath, hostPath);
  }

  private async tarTransfer(
    method: "upload" | "download",
    guestPath: string,
    hostPath: string,
  ): Promise<void> {
    const vsock = await this.vsockConnect(1026);

    vsock.write(JSON.stringify({ method, path: guestPath }) + "\n");

    return new Promise((resolve, reject) => {
      if (method === "upload") {
        const tar = spawn("tar", ["c", "-C", hostPath, "."], {
          stdio: ["ignore", "pipe", "ignore"],
        });
        tar.stdout!.pipe(vsock);
        tar.on("close", () => vsock.end());
        vsock.on("close", () => resolve());
        vsock.on("error", reject);
        tar.on("error", reject);
      } else {
        const tar = spawn("tar", ["x", "-C", hostPath], {
          stdio: ["pipe", "ignore", "ignore"],
        });
        vsock.pipe(tar.stdin!);
        tar.on("close", () => resolve());
        vsock.on("error", reject);
        tar.on("error", reject);
      }
    });
  }

  async forwardPort(guestPort: number): Promise<{ host: string; port: number }> {
    this.ensureAlive();

    return new Promise((resolve, reject) => {
      const tcpServer = net.createServer((clientConn) => {
        this.vsockConnect(1025).then((vsock) => {
          vsock.write(JSON.stringify({ port: guestPort }) + "\n");

          clientConn.pipe(vsock);
          vsock.pipe(clientConn);
          clientConn.on("error", () => vsock.destroy());
          vsock.on("error", () => clientConn.destroy());
          clientConn.on("close", () => vsock.destroy());
          vsock.on("close", () => clientConn.destroy());
        }).catch(() => clientConn.destroy());
      });

      tcpServer.listen(0, "127.0.0.1", () => {
        const addr = tcpServer.address();
        if (!addr || typeof addr === "string") {
          tcpServer.close();
          reject(new Error("Failed to bind port forward listener"));
          return;
        }
        this.portForwardServers.push(tcpServer);
        resolve({ host: "127.0.0.1", port: addr.port });
      });

      tcpServer.on("error", reject);
    });
  }

  async destroy(): Promise<void> {
    if (this.destroyed) return;
    this.destroySync();
  }

  destroySync(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    activeSandboxes.delete(this);
    for (const s of this.portForwardServers) {
      try { s.close(); } catch {}
    }
    if (this.proxyServer) {
      try { this.proxyServer.close(); } catch {}
    }
    try { this.agent.close(); } catch {}
    try { this.process.kill("SIGKILL"); } catch {}
    if (this.thinDevice) {
      try { destroyThinSnapshot(this.sandboxId); } catch {}
    }
    try { rmSync(this.runDir, { recursive: true, force: true }); } catch {}
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.destroy();
  }

  private vsockConnect(guestPort: number): Promise<net.Socket> {
    const vsockUds = join(this.runDir, VSOCK_NAME);

    return new Promise((resolve, reject) => {
      const vsock = net.connect({ path: vsockUds });

      vsock.once("connect", () => {
        vsock.write(`CONNECT ${guestPort}\n`);
      });

      let buf = "";

      vsock.on("data", function onHandshake(chunk: Buffer) {
        buf += chunk.toString();
        if (!buf.includes("\n")) return;

        vsock.removeListener("data", onHandshake);

        if (!buf.startsWith("OK")) {
          vsock.destroy();
          reject(new Error(`vsock CONNECT ${guestPort} failed: ${buf.trim()}`));
          return;
        }

        resolve(vsock);
      });

      vsock.on("error", reject);
    });
  }

  private ensureAlive(): void {
    if (this.destroyed) throw new Error("Sandbox has been destroyed");
  }
}

function wrapCommand(command: string, opts?: { cwd?: string; env?: Record<string, string> }): string {
  let cmd = command;
  if (opts?.cwd) {
    cmd = `cd ${shellEscape(opts.cwd)} && ${cmd}`;
  }
  if (opts?.env) {
    const exports = Object.entries(opts.env)
      .map(([k, v]) => `export ${k}=${shellEscape(v)}`)
      .join("; ");
    cmd = `${exports}; ${cmd}`;
  }
  return cmd;
}

function shellEscape(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}
