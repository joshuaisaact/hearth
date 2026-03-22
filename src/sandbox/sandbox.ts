import { randomBytes } from "node:crypto";
import {
  mkdirSync, rmSync, existsSync, constants,
  readdirSync, readFileSync, writeFileSync,
} from "node:fs";
import { copyFile, rename } from "node:fs/promises";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import net from "node:net";
import { FlintApi } from "../vm/api.js";
import { AgentClient } from "../agent/client.js";
import { getVmmPath, getKernelPath, getRootfsPath, getHearthDir } from "../vm/binary.js";
import {
  ensureBaseSnapshot,
  getSnapshotDir,
  ROOTFS_NAME,
  VMSTATE_NAME,
  MEMORY_NAME,
  VSOCK_NAME,
  SOCKET_NAME,
} from "../vm/snapshot.js";
import { startProxy, PROXY_URL, PROXY_GUEST_PORT } from "../network/proxy.js";
import { VmBootError, TimeoutError } from "../errors.js";
import { waitForFile, errorMessage } from "../util.js";
import type { SpawnHandle } from "../agent/client.js";
import { initKsm } from "../vm/ksm.js";
import type { SnapshotInfo, ExecResult, ExecOptions, SpawnOptions, CreateOptions } from "./types.js";

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
  private api: FlintApi;
  private agent: AgentClient;
  private runDir: string;
  private sandboxId: string;
  private vsockPath: string;
  private portForwardServers: net.Server[] = [];
  private proxyServer: net.Server | null = null;
  private internetEnabled = false;
  private destroyed = false;

  private constructor(
    proc: ChildProcess,
    api: FlintApi,
    agent: AgentClient,
    runDir: string,
    sandboxId: string,
    vsockPath: string,
  ) {
    this.process = proc;
    this.api = api;
    this.agent = agent;
    this.runDir = runDir;
    this.sandboxId = sandboxId;
    this.vsockPath = vsockPath;
    activeSandboxes.add(this);
  }

  /** Create a sandbox from the base snapshot (fast path, ~135ms). */
  static async create(opts?: CreateOptions): Promise<Sandbox> {
    initKsm(); // best-effort, idempotent, never throws
    await ensureBaseSnapshot(opts?.memoryMib);
    return Sandbox.restoreFromDir(getSnapshotDir());
  }

  /** Boot a fresh VM from the rootfs (no snapshot restore). */
  private static async freshBoot(memoryMib: number): Promise<Sandbox> {
    const id = randomBytes(8).toString("hex");
    const runDir = join(getHearthDir(), "run", id);
    mkdirSync(runDir, { recursive: true });

    // Copy rootfs (reflink on btrfs/XFS)
    const clone = constants.COPYFILE_FICLONE;
    await copyFile(getRootfsPath(), join(runDir, ROOTFS_NAME), clone);

    const vsockPath = join(runDir, VSOCK_NAME);
    const agent = new AgentClient(vsockPath);
    const agentConnected = agent.waitForConnection(15000);

    // Wait for vsock listener to be ready
    await waitForFile(`${vsockPath}_1024`, 2000);

    const proc = spawn(
      getVmmPath(),
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
      rmSync(runDir, { recursive: true, force: true });
    };

    try {
      await waitForFile(join(runDir, SOCKET_NAME), 5000);
    } catch {
      cleanup();
      throw new VmBootError(`Flint failed to start. stderr: ${stderrBuf.slice(0, 500)}`);
    }

    const api = new FlintApi(join(runDir, SOCKET_NAME));

    try {
      await api.putMachineConfig(1, memoryMib);
      await api.putBootSource(
        getKernelPath(),
        "console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init root=/dev/vda rw",
      );
      await api.putDrive("rootfs", ROOTFS_NAME, true, false);
      await api.putVsock(100, join(runDir, VSOCK_NAME));
      await api.start();
    } catch (err) {
      cleanup();
      throw new VmBootError(`Failed to boot VM: ${errorMessage(err)}`);
    }

    try {
      await agentConnected;
    } catch (err) {
      cleanup();
      throw new VmBootError(`Agent failed to connect: ${errorMessage(err)}. stderr: ${stderrBuf.slice(0, 500)}`);
    }

    const pingOk = await agent.ping();
    if (!pingOk) {
      cleanup();
      throw new VmBootError("Agent ping failed after boot");
    }

    return new Sandbox(proc, api, agent, runDir, id, vsockPath);
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

  /** Restore a sandbox from a snapshot directory using Flint CLI restore mode. */
  private static async restoreFromDir(snapshotDir: string): Promise<Sandbox> {
    const id = randomBytes(8).toString("hex");
    const runDir = join(getHearthDir(), "run", id);
    mkdirSync(runDir, { recursive: true });

    // Copy snapshot files (reflink on btrfs/XFS)
    const clone = constants.COPYFILE_FICLONE;
    await Promise.all([
      copyFile(join(snapshotDir, ROOTFS_NAME), join(runDir, ROOTFS_NAME), clone),
      copyFile(join(snapshotDir, VMSTATE_NAME), join(runDir, VMSTATE_NAME), clone),
      copyFile(join(snapshotDir, MEMORY_NAME), join(runDir, MEMORY_NAME), clone),
    ]);

    const vsockPath = join(runDir, VSOCK_NAME);
    const agent = new AgentClient(vsockPath);
    // 15s timeout: checkpoint snapshots may have the agent in a spawn poll loop.
    // The agent's idle timeout (~3s without host keepalives) will cause it to
    // disconnect and reconnect, so 15s gives plenty of headroom.
    const agentConnected = agent.waitForConnection(15000);

    // Ensure the vsock listener socket exists before spawning the VMM.
    // server.listen() is async — the socket file may not exist immediately.
    // CLI restore boots the VM instantly, so the listener must be ready.
    await waitForFile(`${vsockPath}_1024`, 2000);

    // Use Flint CLI restore mode — boots directly into post-boot API mode,
    // no HTTP roundtrips needed for snapshot loading
    const proc = spawn(
      getVmmPath(),
      [
        "--restore",
        "--vmstate-path", VMSTATE_NAME,
        "--mem-path", MEMORY_NAME,
        "--disk", ROOTFS_NAME,
        "--vsock-cid", "100",
        "--vsock-uds", VSOCK_NAME,
        "--api-sock", SOCKET_NAME,
      ],
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
      rmSync(runDir, { recursive: true, force: true });
    };

    try {
      await agentConnected;
    } catch (err) {
      cleanup();
      throw new VmBootError(
        `Agent failed to reconnect after snapshot restore: ${errorMessage(err)}. stderr: ${stderrBuf.slice(0, 500)}`,
      );
    }

    const pingOk = await agent.ping();
    if (!pingOk) {
      cleanup();
      throw new VmBootError("Agent ping failed after snapshot restore");
    }

    const api = new FlintApi(join(runDir, SOCKET_NAME));
    return new Sandbox(proc, api, agent, runDir, id, vsockPath);
  }

  /**
   * Save snapshot artifacts to a named directory.
   * VM must already be paused. Caller handles resume/destroy.
   *
   * @param keepRunning - If true, copies rootfs (VM keeps using it).
   *                      If false, moves rootfs (faster, VM being destroyed).
   */
  async saveSnapshotArtifacts(name: string, keepRunning: boolean): Promise<string> {
    const snapDir = userSnapshotDir(name);
    if (existsSync(snapDir)) {
      throw new Error(`Snapshot "${name}" already exists`);
    }

    mkdirSync(snapDir, { recursive: true });

    try {
      await this.api.createSnapshot(VMSTATE_NAME, MEMORY_NAME);

      // vmstate + memory: always move (VM doesn't read these after resume)
      const ops: Promise<void>[] = [
        rename(join(this.runDir, VMSTATE_NAME), join(snapDir, VMSTATE_NAME)),
        rename(join(this.runDir, MEMORY_NAME), join(snapDir, MEMORY_NAME)),
      ];

      if (keepRunning) {
        ops.push(copyFile(
          join(this.runDir, ROOTFS_NAME),
          join(snapDir, ROOTFS_NAME),
          constants.COPYFILE_FICLONE,
        ));
      } else {
        ops.push(rename(join(this.runDir, ROOTFS_NAME), join(snapDir, ROOTFS_NAME)));
      }

      await Promise.all(ops);

      writeFileSync(join(snapDir, "metadata.json"), JSON.stringify({
        name,
        createdAt: new Date().toISOString(),
      }));
    } catch (err) {
      rmSync(snapDir, { recursive: true, force: true });
      throw new Error(`Failed to create snapshot: ${errorMessage(err)}`);
    }

    return name;
  }

  /** Pause the VM. */
  async pause(): Promise<void> {
    this.ensureAlive();
    await this.api.pause();
  }

  /**
   * Close the current agent connection and wait for the guest agent to reconnect.
   * This forces the agent out of any active spawn poll loop back into commandLoop.
   */
  async reconnectAgent(timeoutMs: number = 10000): Promise<void> {
    this.ensureAlive();
    this.agent.close();
    this.agent = new AgentClient(this.vsockPath);
    await this.agent.waitForConnection(timeoutMs);
    const ok = await this.agent.ping();
    if (!ok) throw new Error("Agent ping failed after reconnect");
  }

  /**
   * Checkpoint the current sandbox state as a named snapshot.
   * The sandbox remains running and usable after this call.
   * Returns the snapshot name.
   */
  async checkpoint(name: string): Promise<string> {
    this.ensureAlive();

    await this.api.pause();

    try {
      await this.saveSnapshotArtifacts(name, true);
    } catch (err) {
      await this.api.resume().catch(() => {});
      throw err;
    }

    await this.api.resume();

    // createSnapshot resets the vsock device, so the old connection is dead.
    await this.reconnectAgent(10000);

    return name;
  }

  /**
   * Capture the current sandbox state as a named snapshot.
   * The sandbox is destroyed after snapshotting.
   * Returns the snapshot name.
   */
  async snapshot(name: string): Promise<string> {
    this.ensureAlive();

    await this.api.pause();

    // Close connections — VM is being destroyed
    for (const s of this.portForwardServers) {
      try { s.close(); } catch {}
    }
    this.agent.close();

    try {
      await this.saveSnapshotArtifacts(name, false);
    } finally {
      this.destroySync();
    }

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

    // Wait for the guest-side proxy bridge to be ready.
    // The guest agent forks startProxyBridge() asynchronously, so there's
    // a brief window where the host proxy is listening but the guest
    // TCP listener isn't yet accepting connections.
    const portHex = PROXY_GUEST_PORT.toString(16).toUpperCase().padStart(4, "0");
    let proxyReady = false;
    for (let i = 0; i < 40; i++) {
      const check = await this.agent.exec(
        `grep -q '0100007F:${portHex}' /proc/net/tcp 2>/dev/null`,
      );
      if (check.exitCode === 0) {
        proxyReady = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 50));
    }
    if (!proxyReady) {
      throw new TimeoutError("Guest proxy bridge did not start within 2s");
    }

    this.internetEnabled = true;
  }

  private mergeProxyEnv(opts?: ExecOptions): ExecOptions | undefined {
    if (!this.internetEnabled) return opts;
    const proxyEnv = {
      HTTP_PROXY: PROXY_URL,
      HTTPS_PROXY: PROXY_URL,
      http_proxy: PROXY_URL,
      https_proxy: PROXY_URL,
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

  async forwardPort(guestPort: number, bindAddress = "127.0.0.1"): Promise<{ host: string; port: number }> {
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

      tcpServer.listen(0, bindAddress, () => {
        const addr = tcpServer.address();
        if (!addr || typeof addr === "string") {
          tcpServer.close();
          reject(new Error("Failed to bind port forward listener"));
          return;
        }
        this.portForwardServers.push(tcpServer);
        resolve({ host: bindAddress, port: addr.port });
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
