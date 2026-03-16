import { randomBytes } from "node:crypto";
import { mkdirSync, rmSync } from "node:fs";
import { copyFile } from "node:fs/promises";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
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
  private destroyed = false;

  private constructor(
    proc: ChildProcess,
    agent: AgentClient,
    runDir: string,
  ) {
    this.process = proc;
    this.agent = agent;
    this.runDir = runDir;
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

    // Copy snapshot files in parallel (async, non-blocking)
    await Promise.all([
      copyFile(join(snapshotDir, ROOTFS_NAME), join(runDir, ROOTFS_NAME)),
      copyFile(join(snapshotDir, VMSTATE_NAME), join(runDir, VMSTATE_NAME)),
      copyFile(join(snapshotDir, MEMORY_NAME), join(runDir, MEMORY_NAME)),
    ]);

    // Start agent listener BEFORE loading snapshot
    const agent = new AgentClient(join(runDir, VSOCK_NAME));
    const agentConnected = agent.waitForConnection(10000);

    // Spawn firecracker with cwd = run dir (relative paths match snapshot)
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

    // Wait for API socket
    try {
      await waitForFile(join(runDir, SOCKET_NAME), 5000);
    } catch {
      cleanup();
      throw new VmBootError(
        `Firecracker failed to start. stderr: ${stderrBuf.slice(0, 500)}`,
      );
    }

    // Load snapshot and resume
    const api = new FirecrackerApi(join(runDir, SOCKET_NAME));
    try {
      await api.loadSnapshot(VMSTATE_NAME, MEMORY_NAME, true);
    } catch (err) {
      cleanup();
      throw new VmBootError(`Failed to load snapshot: ${errorMessage(err)}`);
    }

    // Wait for agent to reconnect
    try {
      await agentConnected;
    } catch (err) {
      cleanup();
      throw new VmBootError(
        `Agent failed to reconnect after snapshot restore: ${errorMessage(err)}`,
      );
    }

    return new Sandbox(proc, agent, runDir);
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

  async destroy(): Promise<void> {
    if (this.destroyed) return;
    this.destroySync();
  }

  destroySync(): void {
    if (this.destroyed) return;
    this.destroyed = true;
    activeSandboxes.delete(this);
    try { this.agent.close(); } catch {}
    try { this.process.kill("SIGKILL"); } catch {}
    try { rmSync(this.runDir, { recursive: true, force: true }); } catch {}
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.destroy();
  }

  private ensureAlive(): void {
    if (this.destroyed) throw new Error("Sandbox has been destroyed");
  }
}

function shellEscape(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}
