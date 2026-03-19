import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Hearthfile } from "./hearthfile.js";
import { resolveWorkdir } from "./hearthfile.js";
import { resolveGitHubToken } from "./github.js";
import { writeEnvironmentMeta } from "./metadata.js";
import type { ExecResult } from "../sandbox/types.js";

/** Minimal sandbox interface — works with both Sandbox and RemoteSandbox. */
interface BuildSandbox {
  exec(command: string, opts?: { cwd?: string; timeout?: number }): Promise<ExecResult>;
  writeFile(path: string, content: string | Buffer): Promise<void>;
  enableInternet(): Promise<void>;
  snapshot(name: string): Promise<string>;
  destroy(): Promise<void>;
}

export interface BuildOptions {
  hearthfile: Hearthfile;
  createSandbox: () => Promise<BuildSandbox>;
  snapshotsDir?: string;
  log?: (msg: string) => void;
}

export async function buildEnvironment(opts: BuildOptions): Promise<void> {
  const { hearthfile: hf, createSandbox, log = console.log } = opts;
  const snapshotsDir = opts.snapshotsDir ?? join(homedir(), ".hearth", "snapshots");
  const snapDir = join(snapshotsDir, hf.name);

  if (existsSync(snapDir)) {
    throw new Error(`Environment "${hf.name}" already exists. Use 'hearth rebuild ${hf.name}' to rebuild.`);
  }

  const workdir = resolveWorkdir(hf);
  const token = hf.repo ? resolveGitHubToken(hf) : null;

  log(`Building environment "${hf.name}"...`);
  const startTime = Date.now();

  const sandbox = await createSandbox();

  try {
    await sandbox.enableInternet();

    // Inject files from host
    if (hf.files) {
      for (const f of hf.files) {
        const from = f.from.replace(/^~/, homedir());
        if (!existsSync(from)) {
          throw new Error(`File not found on host: ${f.from} (resolved to ${from})`);
        }
        const { readFileSync } = await import("node:fs");
        const content = readFileSync(from);
        // Ensure parent directory exists
        const dir = f.to.substring(0, f.to.lastIndexOf("/"));
        if (dir) await sandbox.exec(`mkdir -p ${dir}`);
        await sandbox.writeFile(f.to, content);
        if (f.mode) {
          await sandbox.exec(`chmod ${f.mode} ${f.to}`);
        }
      }
    }

    // Clone repo — embed token in URL for private repos, plain https for public
    if (hf.repo) {
      log(`Cloning ${hf.repo}...`);
      const cloneUrl = token
        ? `https://x-access-token:${token}@${hf.repo}`
        : `https://${hf.repo}`;
      const branchFlag = hf.branch ? ` --branch ${hf.branch}` : "";
      const result = await sandbox.exec(
        `git clone${branchFlag} ${cloneUrl} ${workdir}`,
        { timeout: 120_000 },
      );
      if (result.exitCode !== 0) {
        throw new Error(`git clone failed (exit ${result.exitCode}): ${result.stderr}`);
      }

      // If we used a token in the URL, rewrite the remote to strip it
      // so the snapshot doesn't contain credentials
      if (token) {
        await sandbox.exec(
          `git -C ${workdir} remote set-url origin https://${hf.repo}`,
        );
      }
    } else {
      // No repo — just ensure workdir exists
      await sandbox.exec(`mkdir -p ${workdir}`);
    }

    // Run setup commands
    if (hf.setup) {
      for (const cmd of hf.setup) {
        log(`> ${cmd}`);
        const result = await sandbox.exec(cmd, { cwd: workdir, timeout: 300_000 });
        if (result.stdout) process.stdout.write(result.stdout);
        if (result.stderr) process.stderr.write(result.stderr);
        if (result.exitCode !== 0) {
          throw new Error(`Setup command failed (exit ${result.exitCode}): ${cmd}`);
        }
      }
    }

    // Snapshot
    log("Snapshotting...");
    await sandbox.snapshot(hf.name);

    // Write environment metadata alongside the snapshot
    writeEnvironmentMeta(snapDir, {
      name: hf.name,
      repo: hf.repo,
      branch: hf.branch,
      builtAt: new Date().toISOString(),
      hearthfile: hf,
    });

    const elapsed = ((Date.now() - startTime) / 1000).toFixed(1);
    log(`Built "${hf.name}" in ${elapsed}s`);
  } catch (err) {
    // Clean up on failure
    await sandbox.destroy().catch(() => {});
    throw err;
  }
}
