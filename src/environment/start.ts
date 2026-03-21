import { homedir } from "node:os";
import { join } from "node:path";
import { existsSync, readFileSync } from "node:fs";
import { readEnvironmentMeta, type EnvironmentMeta } from "./metadata.js";
import { resolveWorkdir } from "./hearthfile.js";
import { resolveGitHubToken } from "./github.js";
import { loadDefaults } from "./defaults.js";
import type { ExecResult } from "../sandbox/types.js";

/** Minimal sandbox interface — works with both Sandbox and RemoteSandbox. */
interface StartSandbox {
  exec(command: string, opts?: { cwd?: string; timeout?: number }): Promise<ExecResult>;
  writeFile(path: string, content: string | Buffer): Promise<void>;
  enableInternet(): Promise<void>;
  forwardPort(guestPort: number): Promise<{ host: string; port: number }>;
}

export interface StartResult {
  meta: EnvironmentMeta;
  workdir: string;
  ports: Array<{ guest: number; host: string; hostPort: number }>;
}

export interface StartOptions {
  name: string;
  sandbox: StartSandbox;
  snapshotsDir?: string;
  log?: (msg: string) => void;
}

/**
 * Run the start phase on an already-restored sandbox.
 * Re-injects credentials, runs start commands, polls ready URL, forwards ports.
 */
export async function startEnvironment(opts: StartOptions): Promise<StartResult> {
  const { name, sandbox, log = console.log } = opts;
  const snapshotsDir = opts.snapshotsDir ?? join(homedir(), ".hearth", "snapshots");
  const snapDir = join(snapshotsDir, name);

  const meta = readEnvironmentMeta(snapDir);
  if (!meta) {
    throw new Error(`"${name}" is not an environment (no environment.toml found)`);
  }

  const hf = meta.hearthfile;
  const workdir = resolveWorkdir(hf);

  // Re-inject git credentials (never baked into snapshot)
  const token = hf.repo ? resolveGitHubToken(hf) : null;
  if (token) {
    // Configure credential helper that returns the token for git operations
    await sandbox.exec(
      `printf '[credential]\\n\\thelper = "!f() { echo username=x-access-token; echo password='${token}'; }; f"\\n' > /home/agent/.gitconfig`,
    );
  }

  // Re-inject files (project files + user defaults)
  // Metadata stores the original hearthfile, so we merge current defaults here
  const defaults = loadDefaults();
  const allFiles = [...(hf.files ?? []), ...(defaults?.files ?? [])];
  for (const f of allFiles) {
    const from = f.from.replace(/^~/, homedir());
    if (!existsSync(from)) continue; // skip missing files on start (non-fatal)
    const content = readFileSync(from);
    const dir = f.to.substring(0, f.to.lastIndexOf("/"));
    if (dir) await sandbox.exec(`mkdir -p ${dir}`);
    await sandbox.writeFile(f.to, content);
    if (f.mode) {
      await sandbox.exec(`chmod ${f.mode} ${f.to}`);
    }
  }

  // Run start commands
  if (hf.start) {
    for (const cmd of hf.start) {
      log(`> ${cmd}`);
      const result = await sandbox.exec(cmd, { cwd: workdir, timeout: 30_000 });
      if (result.stdout) process.stdout.write(result.stdout);
      if (result.stderr) process.stderr.write(result.stderr);
      if (result.exitCode !== 0) {
        log(`Warning: start command failed (exit ${result.exitCode}): ${cmd}`);
        // Don't abort — drop into shell so user can debug
      }
    }
  }

  // Poll ready URL
  if (hf.ready) {
    log(`Waiting for ${hf.ready}...`);
    const readyTimeout = 30_000;
    const start = Date.now();
    let ready = false;
    while (Date.now() - start < readyTimeout) {
      const result = await sandbox.exec(`curl -sf ${hf.ready}`, { timeout: 5_000 });
      if (result.exitCode === 0) {
        ready = true;
        break;
      }
      await new Promise((r) => setTimeout(r, 500));
    }
    if (!ready) {
      log(`Warning: ready check timed out after ${readyTimeout / 1000}s`);
    }
  }

  // Forward ports
  const forwarded: StartResult["ports"] = [];
  if (hf.ports) {
    await sandbox.enableInternet(); // needed for port forwarding connectivity
    for (const guestPort of hf.ports) {
      const { host, port } = await sandbox.forwardPort(guestPort);
      forwarded.push({ guest: guestPort, host, hostPort: port });
      log(`Port ${guestPort} → ${host}:${port}`);
    }
  }

  // Print age
  const age = timeSince(meta.builtAt);
  log(`Restored "${name}" (built ${age})`);

  return { meta, workdir, ports: forwarded };
}

function timeSince(iso: string): string {
  const diff = Date.now() - new Date(iso).getTime();
  const minutes = Math.floor(diff / 60_000);
  if (minutes < 1) return "just now";
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  return `${days}d ago`;
}
