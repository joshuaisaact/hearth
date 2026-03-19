import { join } from "node:path";
import { homedir } from "node:os";
import { existsSync, readdirSync, rmSync, statSync } from "node:fs";
import { readEnvironmentMeta, isEnvironment } from "../environment/metadata.js";

const SNAPSHOTS_DIR = join(homedir(), ".hearth", "snapshots");

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

function dirSizeMb(dir: string): string {
  let total = 0;
  try {
    for (const entry of readdirSync(dir)) {
      const stat = statSync(join(dir, entry));
      if (stat.isFile()) total += stat.size;
    }
  } catch {}
  return (total / (1024 * 1024)).toFixed(1);
}

function listEnvs(): void {
  if (!existsSync(SNAPSHOTS_DIR)) {
    console.log("No environments found.");
    return;
  }

  const entries = readdirSync(SNAPSHOTS_DIR)
    .filter((name) => isEnvironment(join(SNAPSHOTS_DIR, name)))
    .map((name) => {
      const meta = readEnvironmentMeta(join(SNAPSHOTS_DIR, name));
      return {
        name,
        repo: meta?.repo ?? "-",
        built: meta?.builtAt ? timeSince(meta.builtAt) : "unknown",
        size: dirSizeMb(join(SNAPSHOTS_DIR, name)),
      };
    });

  if (entries.length === 0) {
    console.log("No environments found. Build one with: hearth build <name> --repo <url>");
    return;
  }

  // Column widths
  const nameW = Math.max(4, ...entries.map((e) => e.name.length));
  const repoW = Math.max(4, ...entries.map((e) => e.repo.length));
  const builtW = Math.max(5, ...entries.map((e) => e.built.length));

  console.log(
    "NAME".padEnd(nameW + 2) +
    "REPO".padEnd(repoW + 2) +
    "BUILT".padEnd(builtW + 2) +
    "SIZE",
  );

  for (const e of entries) {
    console.log(
      e.name.padEnd(nameW + 2) +
      e.repo.padEnd(repoW + 2) +
      e.built.padEnd(builtW + 2) +
      `${e.size} MB`,
    );
  }
}

function removeEnv(name: string): void {
  const snapDir = join(SNAPSHOTS_DIR, name);
  if (!existsSync(snapDir)) {
    console.error(`Environment "${name}" not found.`);
    process.exit(1);
  }
  if (!isEnvironment(snapDir)) {
    console.error(`"${name}" is a snapshot, not an environment. Use 'hearth snapshot rm' instead.`);
    process.exit(1);
  }
  rmSync(snapDir, { recursive: true, force: true });
  console.log(`Removed environment "${name}".`);
}

function inspectEnv(name: string): void {
  const snapDir = join(SNAPSHOTS_DIR, name);
  const meta = readEnvironmentMeta(snapDir);
  if (!meta) {
    console.error(`"${name}" is not an environment or doesn't exist.`);
    process.exit(1);
  }

  console.log(`Name:    ${meta.name}`);
  console.log(`Repo:    ${meta.repo ?? "-"}`);
  console.log(`Branch:  ${meta.branch ?? "default"}`);
  console.log(`Built:   ${meta.builtAt}`);
  console.log(`Size:    ${dirSizeMb(snapDir)} MB`);
  console.log();

  const hf = meta.hearthfile;
  if (hf.workdir) console.log(`Workdir: ${hf.workdir}`);
  if (hf.setup?.length) {
    console.log("Setup:");
    for (const cmd of hf.setup) console.log(`  ${cmd}`);
  }
  if (hf.start?.length) {
    console.log("Start:");
    for (const cmd of hf.start) console.log(`  ${cmd}`);
  }
  if (hf.ports?.length) {
    console.log(`Ports:   ${hf.ports.join(", ")}`);
  }
  if (hf.ready) console.log(`Ready:   ${hf.ready}`);
}

export function envsCommand(args: string[]): void {
  const sub = args[0];

  if (!sub) {
    listEnvs();
  } else if (sub === "rm") {
    const name = args[1];
    if (!name) {
      console.error("Usage: hearth envs rm <name>");
      process.exit(1);
    }
    removeEnv(name);
  } else if (sub === "inspect") {
    const name = args[1];
    if (!name) {
      console.error("Usage: hearth envs inspect <name>");
      process.exit(1);
    }
    inspectEnv(name);
  } else {
    console.log("Usage: hearth envs [command]");
    console.log("");
    console.log("Commands:");
    console.log("  (none)       List environments");
    console.log("  rm <name>    Delete an environment");
    console.log("  inspect <name>  Show environment details");
  }
}
