import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { Sandbox } from "../sandbox/sandbox.js";
import { DaemonClient } from "../daemon/client.js";
import type { SpawnHandle } from "../agent/client.js";

interface SandboxLike {
  enableInternet(): Promise<void>;
  spawn(command: string, opts: { interactive: boolean; cols: number; rows: number }): SpawnHandle;
  destroy(): Promise<void>;
}

async function createSandbox(snapshotName?: string): Promise<{ sandbox: SandboxLike; cleanup: () => void }> {
  const daemonSock = process.env.HEARTH_DAEMON_SOCK ?? join(homedir(), ".hearth", "daemon.sock");

  if (existsSync(daemonSock)) {
    const client = new DaemonClient();
    await client.connect(daemonSock);
    const sandbox = snapshotName
      ? await client.fromSnapshot(snapshotName)
      : await client.create();
    return {
      sandbox,
      cleanup: () => {
        if (process.stdin.isTTY) process.stdin.setRawMode(false);
        sandbox.destroy().catch(() => {});
        client.close();
      },
    };
  }

  const sandbox = snapshotName
    ? await Sandbox.fromSnapshot(snapshotName)
    : await Sandbox.create();
  return {
    sandbox,
    cleanup: () => {
      if (process.stdin.isTTY) process.stdin.setRawMode(false);
      sandbox.destroySync();
    },
  };
}

export async function shellCommand(args: string[]): Promise<void> {
  const noInternet = args.includes("--no-internet");
  const snapshotName = args.find(a => !a.startsWith("--"));

  console.log(snapshotName
    ? `Restoring sandbox from snapshot "${snapshotName}"...`
    : "Creating sandbox...");

  const { sandbox, cleanup } = await createSandbox(snapshotName);

  if (!noInternet) {
    await sandbox.enableInternet();
  }

  const cols = process.stdout.columns || 80;
  const rows = process.stdout.rows || 24;

  const handle: SpawnHandle = sandbox.spawn("/bin/bash -l", {
    interactive: true,
    cols,
    rows,
  });

  // Set terminal to raw mode to pass keystrokes directly
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();

  // Forward host stdin to VM
  process.stdin.on("data", (chunk: Buffer) => {
    handle.stdin.write(chunk);
  });

  // Forward VM stdout to host
  handle.stdout.on("data", (data: string) => {
    process.stdout.write(data);
  });

  // Handle terminal resize
  process.stdout.on("resize", () => {
    handle.resize(process.stdout.columns || 80, process.stdout.rows || 24);
  });

  // Graceful cleanup on signals
  process.on("SIGINT", () => {
    cleanup();
    process.exit(130);
  });
  process.on("SIGTERM", () => {
    cleanup();
    process.exit(143);
  });

  // Wait for shell to exit
  const { exitCode } = await handle.wait();

  cleanup();
  process.exit(exitCode);
}
