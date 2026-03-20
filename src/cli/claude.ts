import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import { CLAUDE_SNAPSHOT_NAME } from "../claude.js";
import { DaemonClient } from "../daemon/client.js";
import { resolveConnection } from "../daemon/config.js";
import { isEnvironment } from "../environment/metadata.js";
import { startEnvironment } from "../environment/start.js";
import type { SpawnHandle } from "../agent/client.js";
import type { ExecResult } from "../sandbox/types.js";

interface SandboxLike {
  exec(command: string, opts?: { cwd?: string; timeout?: number }): Promise<ExecResult>;
  spawn(command: string, opts: { interactive: boolean; cols: number; rows: number; timeout?: number }): SpawnHandle;
  writeFile(path: string, content: string | Buffer): Promise<void>;
  enableInternet(): Promise<void>;
  forwardPort(guestPort: number): Promise<{ host: string; port: number }>;
  destroy(): Promise<void>;
}

const DAEMON_SOCK = join(homedir(), ".hearth", "daemon.sock");

function loadCredentials(): string {
  const credPath = join(homedir(), ".claude", ".credentials.json");
  if (!existsSync(credPath)) {
    console.error("No Claude Code credentials found at ~/.claude/.credentials.json");
    console.error("Run 'claude auth login' on your host first.");
    process.exit(1);
  }
  return readFileSync(credPath, "utf-8");
}

async function tryConnect(path: string): Promise<DaemonClient | null> {
  const client = new DaemonClient();
  try {
    await client.connect(path);
    return client;
  } catch {
    return null;
  }
}

async function ensureDaemon(): Promise<DaemonClient> {
  let client = await tryConnect(DAEMON_SOCK);
  if (client) return client;

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

export async function claudeCommand(args: string[]): Promise<void> {
  const credentials = loadCredentials();

  const target = resolveConnection();
  const client = target.type === "ws"
    ? await (async () => { const c = new DaemonClient(); await c.connect(); return c; })()
    : await ensureDaemon();

  // Determine snapshot: first non-flag arg could be an environment name
  let envName: string | undefined;
  let claudeArgs: string[] = [];

  // Split args at "--" if present, otherwise check first arg
  const dashDash = args.indexOf("--");
  if (dashDash !== -1) {
    envName = args.slice(0, dashDash)[0];
    claudeArgs = args.slice(dashDash + 1);
  } else if (args.length > 0 && !args[0].startsWith("-")) {
    // Check if first arg is an environment name
    const snapDir = join(homedir(), ".hearth", "snapshots", args[0]);
    if (existsSync(snapDir) && isEnvironment(snapDir)) {
      envName = args[0];
      claudeArgs = args.slice(1);
    } else {
      // Not an environment — treat all args as claude args
      claudeArgs = args;
    }
  } else {
    claudeArgs = args;
  }

  const snapshotName = envName ?? CLAUDE_SNAPSHOT_NAME;

  console.log(envName
    ? `Restoring Claude Code in environment "${envName}"...`
    : "Restoring Claude Code sandbox...");

  let sandbox: SandboxLike;
  try {
    console.time("restore");
    sandbox = await client.fromSnapshot(snapshotName) as unknown as SandboxLike;
    console.timeEnd("restore");
  } catch (err: unknown) {
    const msg = err instanceof Error ? err.message : String(err);
    if (msg.includes("not found") || msg.includes("does not exist")) {
      console.error(`Snapshot "${snapshotName}" not found.`);
      if (!envName) {
        console.error("Create it first: npx hearth snapshot-claude");
      }
    } else {
      console.error("Failed to restore snapshot:", msg);
    }
    process.exit(1);
  }

  await sandbox.enableInternet();

  // Run environment start phase if this is an environment
  let workdir = "/home/agent";
  if (envName) {
    try {
      const result = await startEnvironment({ name: envName, sandbox });
      workdir = result.workdir;
    } catch (err) {
      console.error(`Warning: start phase failed: ${err instanceof Error ? err.message : err}`);
    }
  }

  // Ensure localhost resolves (needed for Claude Code OAuth callback)
  await sandbox.exec("grep -q localhost /etc/hosts || echo '127.0.0.1 localhost' >> /etc/hosts");

  // Ensure Claude Code is installed (environments don't have it by default)
  const hasClaudeCode = await sandbox.exec("which claude");
  if (hasClaudeCode.exitCode !== 0) {
    console.log("Installing Claude Code...");
    const install = await sandbox.exec(
      "npm install -g @anthropic-ai/claude-code 2>&1",
      { timeout: 180_000 },
    );
    if (install.exitCode !== 0) {
      console.error("Failed to install Claude Code:", install.stderr);
      process.exit(1);
    }
  }

  // Ensure agent user owns their home directory
  await sandbox.exec("chown -R agent:agent /home/agent");

  // Set up proxy env vars in a separate file, sourced from .bashrc
  const claudeEnv = [
    "export PATH=\"$HOME/.claude/bin:$PATH\"",
    "export HTTP_PROXY=http://127.0.0.1:3128",
    "export HTTPS_PROXY=http://127.0.0.1:3128",
    "export http_proxy=http://127.0.0.1:3128",
    "export https_proxy=http://127.0.0.1:3128",
  ].join("\n");
  await sandbox.writeFile("/home/agent/.hearth-claude.env", claudeEnv);
  await sandbox.exec(
    "touch /home/agent/.bashrc && " +
    "grep -qxF 'source /home/agent/.hearth-claude.env' /home/agent/.bashrc || " +
    "printf '\\nsource /home/agent/.hearth-claude.env\\n' >> /home/agent/.bashrc",
  );

  // Inject host credentials into the VM
  await sandbox.exec("mkdir -p /home/agent/.claude");
  await sandbox.writeFile("/home/agent/.claude/.credentials.json", credentials);
  await sandbox.writeFile("/home/agent/.claude/settings.json", JSON.stringify({
    skipDangerousModePermissionPrompt: true,
  }));

  // Write global config to skip onboarding and trust dialog
  const globalConfig = JSON.stringify({
    hasCompletedOnboarding: true,
    theme: "dark",
    numStartups: 1,
    projects: {
      [workdir]: {
        allowedTools: [],
        hasTrustDialogAccepted: true,
        hasCompletedProjectOnboarding: true,
        projectOnboardingSeenCount: 1,
      },
    },
  });
  await sandbox.writeFile("/home/agent/.claude.json", globalConfig);
  await sandbox.exec("chown -R agent:agent /home/agent");

  // Write the startup script
  const shellEscape = (v: string) => "'" + v.replace(/'/g, "'\\''") + "'";
  const claudeArgsStr = claudeArgs.length > 0 ? claudeArgs.map(shellEscape).join(" ") : "";
  const script = [
    "#!/bin/bash",
    "export HOME=/home/agent",
    "source $HOME/.bashrc",
    `cd -- ${shellEscape(workdir)}`,
    claudeArgsStr
      ? `exec claude ${claudeArgsStr} --dangerously-skip-permissions`
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
