import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { CLAUDE_SNAPSHOT_NAME } from "../claude.js";
import type { SpawnHandle } from "../agent/client.js";

interface SandboxLike {
  exec(command: string, opts?: { timeout?: number }): Promise<{ stdout: string; stderr: string; exitCode: number }>;
  spawn(command: string, opts: { interactive: boolean; cols: number; rows: number; timeout?: number }): SpawnHandle;
  writeFile(path: string, content: string | Buffer): Promise<void>;
  enableInternet(): Promise<void>;
  destroy(): Promise<void>;
}

function loadCredentials(): string {
  const credPath = join(homedir(), ".claude", ".credentials.json");
  if (!existsSync(credPath)) {
    console.error("No Claude Code credentials found at ~/.claude/.credentials.json");
    console.error("Run 'claude auth login' on your host first.");
    process.exit(1);
  }
  return readFileSync(credPath, "utf-8");
}

export async function claudeCommand(args: string[]): Promise<void> {
  const credentials = loadCredentials();

  const { resolveConnection } = await import("../daemon/config.js");
  const { DaemonClient } = await import("../daemon/client.js");

  const DAEMON_SOCK = join(homedir(), ".hearth", "daemon.sock");

  async function tryConnect(path: string): Promise<InstanceType<typeof DaemonClient> | null> {
    const client = new DaemonClient();
    try {
      await client.connect(path);
      return client;
    } catch {
      return null;
    }
  }

  async function ensureDaemon(): Promise<InstanceType<typeof DaemonClient>> {
    let client = await tryConnect(DAEMON_SOCK);
    if (client) return client;

    const { spawn } = await import("node:child_process");
    const { dirname } = await import("node:path");
    const { fileURLToPath } = await import("node:url");
    const hearthBin = join(dirname(fileURLToPath(import.meta.url)), "hearth.js");
    const child = spawn(process.execPath, [hearthBin, "daemon"], {
      stdio: "ignore",
      detached: true,
    });
    child.unref();

    for (let i = 0; i < 30; i++) {
      await new Promise((r) => setTimeout(r, 100));
      client = await tryConnect(DAEMON_SOCK);
      if (client) return client;
    }
    throw new Error("Failed to start daemon");
  }

  // Restore the claude-base snapshot
  console.log("Restoring Claude Code sandbox...");
  const target = resolveConnection();
  const client = target.type === "ws"
    ? await (async () => { const c = new DaemonClient(); await c.connect(); return c; })()
    : await ensureDaemon();

  let sandbox: SandboxLike;
  try {
    console.time("restore");
    sandbox = await client.fromSnapshot(CLAUDE_SNAPSHOT_NAME) as unknown as SandboxLike;
    console.timeEnd("restore");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("not found") || msg.includes("does not exist")) {
      console.error(`Snapshot "${CLAUDE_SNAPSHOT_NAME}" not found.`);
      console.error("Create it first: npx hearth snapshot-claude");
    } else {
      console.error("Failed to restore snapshot:", msg);
    }
    process.exit(1);
  }

  await sandbox.enableInternet();

  // Ensure localhost resolves (needed for Claude Code OAuth callback)
  await sandbox.exec("grep -q localhost /etc/hosts || echo '127.0.0.1 localhost' >> /etc/hosts");

  // Inject host credentials into the VM
  await sandbox.exec("mkdir -p /home/agent/.claude");
  await sandbox.writeFile("/home/agent/.claude/.credentials.json", credentials);
  await sandbox.writeFile("/home/agent/.claude/settings.json", JSON.stringify({
    skipDangerousModePermissionPrompt: true,
  }));

  // Write global config to skip onboarding and trust dialog (Claude Code reads ~/.claude.json)
  const globalConfig = JSON.stringify({
    hasCompletedOnboarding: true,
    theme: "dark",
    numStartups: 1,
    projects: {
      "/home/agent": {
        allowedTools: [],
        hasTrustDialogAccepted: true,
        hasCompletedProjectOnboarding: true,
        projectOnboardingSeenCount: 1,
      },
    },
  });
  await sandbox.writeFile("/home/agent/.claude.json", globalConfig);
  await sandbox.exec("chown -R agent:agent /home/agent/.claude /home/agent/.claude.json");

  // Write the startup script
  const claudeArgs = args.length > 0 ? args.join(" ") : "";
  const script = [
    "#!/bin/bash",
    "export HOME=/home/agent",
    "source $HOME/.bashrc",
    "cd /home/agent",
    claudeArgs
      ? `exec claude ${claudeArgs} --dangerously-skip-permissions`
      : "exec claude --dangerously-skip-permissions",
  ].join("\n");

  await sandbox.writeFile("/tmp/claude-start.sh", script);
  await sandbox.exec("chmod +x /tmp/claude-start.sh");

  const cols = process.stdout.columns || 80;
  const rows = process.stdout.rows || 24;

  const handle: SpawnHandle = sandbox.spawn(
    "su - agent -s /bin/sh -c /tmp/claude-start.sh",
    { interactive: true, cols, rows },
  );

  // Raw mode for interactive use
  if (process.stdin.isTTY) {
    process.stdin.setRawMode(true);
  }
  process.stdin.resume();

  process.stdin.on("data", (chunk: Buffer) => {
    handle.stdin.write(chunk);
  });

  handle.stdout.on("data", (data: string) => {
    process.stdout.write(data);
  });

  process.stdout.on("resize", () => {
    handle.resize(process.stdout.columns || 80, process.stdout.rows || 24);
  });

  const cleanup = () => {
    if (process.stdin.isTTY) process.stdin.setRawMode(false);
    sandbox.destroy().catch(() => {});
    client.close();
  };

  process.on("SIGINT", () => { cleanup(); process.exit(130); });
  process.on("SIGTERM", () => { cleanup(); process.exit(143); });

  const { exitCode } = await handle.wait();
  cleanup();
  process.exit(exitCode);
}
