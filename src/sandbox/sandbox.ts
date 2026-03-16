import { randomBytes } from "node:crypto";
import { mkdirSync, rmSync, unlinkSync } from "node:fs";
import { copyFile } from "node:fs/promises";
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
import { VmBootError } from "../errors.js";
import { waitForFile, errorMessage } from "../util.js";
import type { ExecResult, ExecOptions } from "./types.js";

const activeSandboxes = new Set<Sandbox>();

process.on("exit", () => {
  for (const sb of activeSandboxes) {
    sb.destroySync();
  }
});

export class Sandbox {
  private process: ChildProcess;
  private agent: AgentClient;
  private runDir: string;
  private vsockPath: string;
  private portForwardServers: net.Server[] = [];
  private destroyed = false;

  private constructor(
    proc: ChildProcess,
    agent: AgentClient,
    runDir: string,
    vsockPath: string,
  ) {
    this.process = proc;
    this.agent = agent;
    this.runDir = runDir;
    this.vsockPath = vsockPath;
    activeSandboxes.add(this);
  }

  static async create(): Promise<Sandbox> {
    await ensureBaseSnapshot();
    return Sandbox.createFromSnapshot();
  }

  private static async createFromSnapshot(): Promise<Sandbox> {
    const id = randomBytes(8).toString("hex");
    const runDir = join(getHearthDir(), "run", id);
    mkdirSync(runDir, { recursive: true });

    const snapshotDir = getSnapshotDir();

    await Promise.all([
      copyFile(join(snapshotDir, ROOTFS_NAME), join(runDir, ROOTFS_NAME)),
      copyFile(join(snapshotDir, VMSTATE_NAME), join(runDir, VMSTATE_NAME)),
      copyFile(join(snapshotDir, MEMORY_NAME), join(runDir, MEMORY_NAME)),
    ]);

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

    // Ping to ensure the agent's command loop (and background listeners) are ready.
    // The agent starts listeners after connecting but before entering the command loop,
    // so by the time the ping response arrives, all listeners are active.
    await agent.ping();

    return new Sandbox(proc, agent, runDir, vsockPath);
  }

  async exec(command: string, opts?: ExecOptions): Promise<ExecResult> {
    this.ensureAlive();

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

    return this.agent.exec(cmd, { timeout: opts?.timeout });
  }

  async writeFile(path: string, content: string | Buffer): Promise<void> {
    this.ensureAlive();
    return this.agent.writeFile(path, content);
  }

  async readFile(path: string): Promise<string> {
    this.ensureAlive();
    return this.agent.readFile(path);
  }

  /** Upload a file or directory from the host into the guest via tar streaming over vsock. */
  async upload(hostPath: string, guestPath: string): Promise<void> {
    this.ensureAlive();
    await this.tarTransfer("upload", guestPath, hostPath);
  }

  /** Download a file or directory from the guest to the host via tar streaming over vsock. */
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

    // Send the transfer header (properly escaped JSON)
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

  /** Forward a guest port to a host port via vsock tunnel. No root required. */
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
    try { this.agent.close(); } catch {}
    try { this.process.kill("SIGKILL"); } catch {}
    try { rmSync(this.runDir, { recursive: true, force: true }); } catch {}
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.destroy();
  }

  /** Connect to a guest vsock port via Firecracker's CONNECT protocol. */
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

function shellEscape(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}
