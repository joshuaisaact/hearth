import { existsSync, mkdirSync, copyFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { FlintApi } from "./api.js";
import { AgentClient } from "../agent/client.js";
import {
  getVmmPath,
  getKernelPath,
  getRootfsPath,
  getHearthDir,
} from "./binary.js";
import { VmBootError, ResourceError } from "../errors.js";
import { waitForFile, errorMessage } from "../util.js";

const SNAPSHOT_DIR = join(getHearthDir(), "snapshots", "base");

export const ROOTFS_NAME = "rootfs.ext4";
export const VMSTATE_NAME = "vmstate.snap";
export const MEMORY_NAME = "memory.snap";
export const VSOCK_NAME = "vsock";
export const SOCKET_NAME = "flint.sock";

/** Default guest memory in MiB. Safe for concurrent sandboxes thanks to KSM page deduplication. */
export const DEFAULT_MEMORY_MIB = 2048;

const MIN_MEMORY_MIB = 128;
const MAX_MEMORY_MIB = 32768;

let baseSnapshotReady: Promise<void> | null = null;
let baseSnapshotMemoryMib: number | null = null;

export function ensureBaseSnapshot(memoryMib: number = DEFAULT_MEMORY_MIB): Promise<void> {
  if (!Number.isInteger(memoryMib) || memoryMib < MIN_MEMORY_MIB || memoryMib > MAX_MEMORY_MIB) {
    throw new ResourceError(`memoryMib must be an integer between ${MIN_MEMORY_MIB} and ${MAX_MEMORY_MIB}, got ${memoryMib}`);
  }
  if (baseSnapshotReady) {
    if (baseSnapshotMemoryMib !== null && memoryMib !== baseSnapshotMemoryMib) {
      console.warn(
        `Warning: ignoring memoryMib=${memoryMib}, base snapshot already created with ${baseSnapshotMemoryMib} MiB. ` +
        `Delete ${SNAPSHOT_DIR} to recreate with a different size.`,
      );
    }
    return baseSnapshotReady;
  }
  baseSnapshotMemoryMib = memoryMib;
  baseSnapshotReady = createBaseSnapshotIfNeeded(memoryMib);
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

async function createBaseSnapshotIfNeeded(memoryMib: number): Promise<void> {
  if (hasBaseSnapshot()) return;

  mkdirSync(SNAPSHOT_DIR, { recursive: true });
  copyFileSync(getRootfsPath(), join(SNAPSHOT_DIR, ROOTFS_NAME));

  const agent = new AgentClient(join(SNAPSHOT_DIR, VSOCK_NAME));
  const agentConnected = agent.waitForConnection(15000);

  // Ensure the vsock listener socket exists before spawning the VMM.
  // server.listen() in AgentClient is async — the socket file may not
  // exist immediately after waitForConnection() returns the Promise.
  await waitForFile(join(SNAPSHOT_DIR, `${VSOCK_NAME}_1024`), 2000);

  const proc = spawn(
    getVmmPath(),
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
    baseSnapshotMemoryMib = null;
  };

  try {
    await waitForFile(join(SNAPSHOT_DIR, SOCKET_NAME), 5000);
  } catch {
    cleanup();
    throw new VmBootError(`Flint failed to start for snapshot creation. stderr: ${stderrBuf.slice(0, 500)}`);
  }

  const api = new FlintApi(join(SNAPSHOT_DIR, SOCKET_NAME));

  try {
    // Configure VM
    await api.putMachineConfig(1, memoryMib);
    await api.putBootSource(
      getKernelPath(),
      "console=ttyS0 reboot=k panic=1 pci=off init=/sbin/init root=/dev/vda rw",
    );
    await api.putDrive("rootfs", ROOTFS_NAME, true, false);
    await api.putVsock(100, join(SNAPSHOT_DIR, VSOCK_NAME));
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

  // Wait briefly for the guest to settle into HLT (idle) after the agent
  // disconnects. The snapshot captures mp_state — if the vCPU is RUNNABLE
  // (mid-execution) instead of HALTED (in HLT), restore fails because
  // KVM can't properly resume mid-instruction context.
  await new Promise((resolve) => setTimeout(resolve, 200));

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
