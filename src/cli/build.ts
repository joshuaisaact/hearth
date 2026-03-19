import { join } from "node:path";
import { homedir } from "node:os";
import { existsSync, rmSync } from "node:fs";
import { parseHearthfile, findHearthfile } from "../environment/hearthfile.js";
import { readEnvironmentMeta } from "../environment/metadata.js";
import { buildEnvironment } from "../environment/build.js";
import { DaemonClient } from "../daemon/client.js";
import { resolveConnection } from "../daemon/config.js";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname } from "node:path";
import type { Hearthfile } from "../environment/hearthfile.js";

const DAEMON_SOCK = join(homedir(), ".hearth", "daemon.sock");

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

async function getClient(): Promise<DaemonClient> {
  const target = resolveConnection();
  if (target.type === "ws") {
    const client = new DaemonClient();
    await client.connect();
    return client;
  }
  return ensureDaemon();
}

export async function buildCommand(args: string[]): Promise<void> {
  let name: string | undefined;
  let filePath: string | undefined;
  let repoOverride: string | undefined;
  let branchOverride: string | undefined;

  // Parse args
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--file" && args[i + 1]) {
      filePath = args[++i];
    } else if (args[i] === "--repo" && args[i + 1]) {
      repoOverride = args[++i];
    } else if (args[i] === "--branch" && args[i + 1]) {
      branchOverride = args[++i];
    } else if (!args[i].startsWith("-")) {
      name = args[i];
    }
  }

  // Resolve Hearthfile
  let hf: Hearthfile;

  if (filePath) {
    hf = parseHearthfile(filePath);
  } else {
    const found = findHearthfile(process.cwd());
    if (found) {
      hf = parseHearthfile(found);
    } else if (repoOverride && name) {
      // No Hearthfile — minimal build from --repo
      hf = { name, repo: repoOverride };
    } else if (repoOverride) {
      console.error("Error: --repo requires a name argument. Usage: hearth build <name> --repo <url>");
      process.exit(1);
    } else {
      console.error("Error: No Hearthfile.toml found in current directory.");
      console.error("Either create one or use: hearth build <name> --repo <url>");
      process.exit(1);
    }
  }

  // CLI overrides
  if (name) hf.name = name;
  if (repoOverride) hf.repo = repoOverride;
  if (branchOverride) hf.branch = branchOverride;

  const client = await getClient();

  try {
    await buildEnvironment({
      hearthfile: hf,
      createSandbox: () => client.create(),
    });
  } finally {
    client.close();
  }
}

export async function rebuildCommand(args: string[]): Promise<void> {
  const name = args[0];
  if (!name) {
    console.error("Usage: hearth rebuild <name>");
    process.exit(1);
  }

  let branchOverride: string | undefined;
  for (let i = 1; i < args.length; i++) {
    if (args[i] === "--branch" && args[i + 1]) {
      branchOverride = args[++i];
    }
  }

  const snapshotsDir = join(homedir(), ".hearth", "snapshots");
  const snapDir = join(snapshotsDir, name);

  const meta = readEnvironmentMeta(snapDir);
  if (!meta) {
    console.error(`Error: "${name}" is not an environment or doesn't exist.`);
    process.exit(1);
  }

  // Delete existing snapshot
  rmSync(snapDir, { recursive: true, force: true });

  const hf = meta.hearthfile;
  if (branchOverride) hf.branch = branchOverride;

  const client = await getClient();

  try {
    await buildEnvironment({
      hearthfile: hf,
      createSandbox: () => client.create(),
    });
  } finally {
    client.close();
  }
}
