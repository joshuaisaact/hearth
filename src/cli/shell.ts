import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { existsSync } from "node:fs";
import { DaemonClient } from "../daemon/client.js";
import { resolveConnection } from "../daemon/config.js";
import { isEnvironment } from "../environment/metadata.js";
import { startEnvironment } from "../environment/start.js";
import type { SpawnHandle } from "../agent/client.js";
import type { ExecResult } from "../sandbox/types.js";

const DAEMON_SOCK = join(homedir(), ".hearth", "daemon.sock");

interface SandboxLike {
  exec(command: string, opts?: { cwd?: string; timeout?: number }): Promise<ExecResult>;
  writeFile(path: string, content: string | Buffer): Promise<void>;
  spawn(command: string, opts: { interactive: boolean; cols: number; rows: number }): SpawnHandle;
  enableInternet(): Promise<void>;
  forwardPort(guestPort: number): Promise<{ host: string; port: number }>;
  destroy(): Promise<void>;
}

/** Try connecting to the daemon. Returns the client on success, null on failure. */
async function tryConnect(path: string): Promise<DaemonClient | null> {
  const client = new DaemonClient();
  try {
    await client.connect(path);
    return client;
  } catch {
    return null;
  }
}

/** Start the daemon as a detached background process and wait until it's connectable. */
async function ensureDaemon(): Promise<DaemonClient> {
  // Try existing socket first
  let client = await tryConnect(DAEMON_SOCK);
  if (client) return client;

  // Fork the daemon in the background
  const hearthBin = join(dirname(fileURLToPath(import.meta.url)), "hearth.js");
  const child = spawn(process.execPath, [hearthBin, "daemon"], {
    stdio: "ignore",
    detached: true,
  });
  child.unref();

  // Poll until the socket is connectable (up to 3s)
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 100));
    client = await tryConnect(DAEMON_SOCK);
    if (client) return client;
  }

  throw new Error("Failed to start daemon");
}

async function createSandbox(snapshotName?: string): Promise<{ sandbox: SandboxLike; cleanup: () => void }> {
  const target = resolveConnection();

  // Remote WS connection — always use daemon client
  if (target.type === "ws") {
    const client = new DaemonClient();
    await client.connect();
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

  // Local — auto-start daemon if needed
  const client = await ensureDaemon();
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

export async function shellCommand(args: string[]): Promise<void> {
  const snapshotName = args[0];

  console.log(snapshotName
    ? `Restoring sandbox from snapshot "${snapshotName}"...`
    : "Creating sandbox...");

  const { sandbox, cleanup } = await createSandbox(snapshotName);

  // If this is an environment, run start phase
  let shellCwd: string | undefined;
  if (snapshotName) {
    const snapDir = join(homedir(), ".hearth", "snapshots", snapshotName);
    if (existsSync(snapDir) && isEnvironment(snapDir)) {
      try {
        const result = await startEnvironment({ name: snapshotName, sandbox });
        shellCwd = result.workdir;
      } catch (err) {
        console.error(`Warning: start phase failed: ${err instanceof Error ? err.message : err}`);
      }
    }
  }

  const cols = process.stdout.columns || 80;
  const rows = process.stdout.rows || 24;

  const shellCmd = shellCwd ? `cd ${shellCwd} && /bin/bash -l` : "/bin/bash -l";
  const handle: SpawnHandle = sandbox.spawn(shellCmd, {
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
