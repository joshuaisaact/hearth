import { existsSync, mkdirSync, copyFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { FirecrackerApi } from "./api.js";
import { AgentClient } from "../agent/client.js";
import {
  getFirecrackerPath,
  getKernelPath,
  getRootfsPath,
  getHearthDir,
} from "./binary.js";
import { VmBootError } from "../errors.js";
import { waitForFile, errorMessage } from "../util.js";

const SNAPSHOT_DIR = join(getHearthDir(), "snapshots", "base");

export const ROOTFS_NAME = "rootfs.ext4";
export const VMSTATE_NAME = "vmstate.snap";
export const MEMORY_NAME = "memory.snap";
export const VSOCK_NAME = "vsock";
export const SOCKET_NAME = "firecracker.sock";

let baseSnapshotReady: Promise<void> | null = null;

export function ensureBaseSnapshot(): Promise<void> {
  if (!baseSnapshotReady) {
    baseSnapshotReady = createBaseSnapshotIfNeeded();
  }
  return baseSnapshotReady;
}

export function getSnapshotDir(): string {
  return SNAPSHOT_DIR;
}

export function hasBaseSnapshot(): boolean {
  return (
    existsSync(join(SNAPSHOT_DIR, VMSTATE_NAME)) &&
    existsSync(join(SNAPSHOT_DIR, MEMORY_NAME)) &&
    existsSync(join(SNAPSHOT_DIR, ROOTFS_NAME))
  );
}

async function createBaseSnapshotIfNeeded(): Promise<void> {
  if (hasBaseSnapshot()) return;

  mkdirSync(SNAPSHOT_DIR, { recursive: true });
  copyFileSync(getRootfsPath(), join(SNAPSHOT_DIR, ROOTFS_NAME));

  const agent = new AgentClient(join(SNAPSHOT_DIR, VSOCK_NAME));
  const agentConnected = agent.waitForConnection(15000);

  const proc = spawn(
    getFirecrackerPath(),
    ["--api-sock", SOCKET_NAME],
    {
      stdio: ["ignore", "pipe", "pipe"],
      cwd: SNAPSHOT_DIR,
      detached: false,
    },
  );

  let stderrBuf = "";
  proc.stderr?.on("data", (chunk: Buffer) => {
    if (stderrBuf.length < 2000) stderrBuf += chunk.toString();
  });

  const cleanup = () => {
    try { proc.kill("SIGKILL"); } catch {}
    rmSync(SNAPSHOT_DIR, { recursive: true, force: true });
    baseSnapshotReady = null;
  };

  try {
    await waitForFile(join(SNAPSHOT_DIR, SOCKET_NAME), 5000);
  } catch {
    cleanup();
    throw new VmBootError(`Firecracker failed to start for snapshot creation. stderr: ${stderrBuf.slice(0, 500)}`);
  }

  const api = new FirecrackerApi(join(SNAPSHOT_DIR, SOCKET_NAME));

  try {
    // Configure VM — these are independent, run in parallel
    await Promise.all([
      api.putMachineConfig(2, 512),
      api.putBootSource(
        getKernelPath(),
        "console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init",
      ),
      api.putDrive("rootfs", ROOTFS_NAME, true, false),
      api.putVsock(100, VSOCK_NAME),
    ]);
    await api.start();
  } catch (err) {
    cleanup();
    throw new VmBootError(`Failed to configure VM for snapshot: ${errorMessage(err)}`);
  }

  try {
    await agentConnected;
  } catch (err) {
    cleanup();
    throw new VmBootError(`Agent failed to connect during snapshot creation: ${errorMessage(err)}`);
  }

  const ok = await agent.ping();
  if (!ok) {
    cleanup();
    throw new VmBootError("Agent ping failed during snapshot creation");
  }

  agent.close();

  try {
    await api.pause();
    await api.createSnapshot(VMSTATE_NAME, MEMORY_NAME);
  } catch (err) {
    cleanup();
    throw new VmBootError(`Failed to create snapshot: ${errorMessage(err)}`);
  }

  try { proc.kill("SIGKILL"); } catch {}

  // Clean up socket files not needed in snapshot
  for (const f of [SOCKET_NAME, `${VSOCK_NAME}_1024`, VSOCK_NAME]) {
    try { rmSync(join(SNAPSHOT_DIR, f), { force: true }); } catch {}
  }
}
