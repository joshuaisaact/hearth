import { readFileSync, existsSync } from "node:fs";
import { join, basename } from "node:path";
import { parse } from "smol-toml";

export interface HearthfileFiles {
  from: string;
  to: string;
  mode?: string;
}

export interface Hearthfile {
  name: string;
  repo?: string;
  branch?: string;
  workdir?: string;
  setup?: string[];
  start?: string[];
  ports?: number[];
  ready?: string;
  files?: HearthfileFiles[];
  github_token_env?: string;
}

const SNAPSHOT_NAME_RE = /^[a-zA-Z0-9_-]+$/;

export function parseHearthfile(path: string): Hearthfile {
  const raw = readFileSync(path, "utf-8");
  const parsed = parse(raw) as Record<string, unknown>;

  const name = parsed["name"];
  if (typeof name !== "string" || !name) {
    throw new Error(`Hearthfile: 'name' is required`);
  }
  if (!SNAPSHOT_NAME_RE.test(name)) {
    throw new Error(`Hearthfile: 'name' must match ${SNAPSHOT_NAME_RE} (got "${name}")`);
  }

  const hf: Hearthfile = { name };

  if (parsed["repo"] !== undefined) {
    if (typeof parsed["repo"] !== "string") throw new Error("Hearthfile: 'repo' must be a string");
    hf.repo = parsed["repo"];
  }

  if (parsed["branch"] !== undefined) {
    if (typeof parsed["branch"] !== "string") throw new Error("Hearthfile: 'branch' must be a string");
    hf.branch = parsed["branch"];
  }

  if (parsed["workdir"] !== undefined) {
    if (typeof parsed["workdir"] !== "string") throw new Error("Hearthfile: 'workdir' must be a string");
    hf.workdir = parsed["workdir"];
  }

  if (parsed["setup"] !== undefined) {
    if (!Array.isArray(parsed["setup"]) || !parsed["setup"].every((s) => typeof s === "string")) {
      throw new Error("Hearthfile: 'setup' must be an array of strings");
    }
    hf.setup = parsed["setup"] as string[];
  }

  if (parsed["start"] !== undefined) {
    if (!Array.isArray(parsed["start"]) || !parsed["start"].every((s) => typeof s === "string")) {
      throw new Error("Hearthfile: 'start' must be an array of strings");
    }
    hf.start = parsed["start"] as string[];
  }

  if (parsed["ports"] !== undefined) {
    if (!Array.isArray(parsed["ports"]) || !parsed["ports"].every((p) => typeof p === "number" && Number.isInteger(p))) {
      throw new Error("Hearthfile: 'ports' must be an array of integers");
    }
    const ports = parsed["ports"] as number[];
    for (const p of ports) {
      if (p < 1 || p > 65535) throw new Error(`Hearthfile: invalid port ${p}`);
    }
    hf.ports = ports;
  }

  if (parsed["ready"] !== undefined) {
    if (typeof parsed["ready"] !== "string") throw new Error("Hearthfile: 'ready' must be a string");
    hf.ready = parsed["ready"];
  }

  if (parsed["files"] !== undefined) {
    if (!Array.isArray(parsed["files"])) throw new Error("Hearthfile: 'files' must be an array of tables");
    hf.files = (parsed["files"] as Record<string, unknown>[]).map((f, i) => {
      if (typeof f["from"] !== "string") throw new Error(`Hearthfile: files[${i}].from must be a string`);
      if (typeof f["to"] !== "string") throw new Error(`Hearthfile: files[${i}].to must be a string`);
      const entry: HearthfileFiles = { from: f["from"], to: f["to"] };
      if (f["mode"] !== undefined) {
        if (typeof f["mode"] !== "string") throw new Error(`Hearthfile: files[${i}].mode must be a string`);
        entry.mode = f["mode"];
      }
      return entry;
    });
  }

  if (parsed["github_token_env"] !== undefined) {
    if (typeof parsed["github_token_env"] !== "string") throw new Error("Hearthfile: 'github_token_env' must be a string");
    hf.github_token_env = parsed["github_token_env"];
  }

  return hf;
}

export function findHearthfile(dir: string): string | null {
  const path = join(dir, "Hearthfile.toml");
  return existsSync(path) ? path : null;
}

/** Derive the default workdir from a repo URL. */
export function defaultWorkdir(repo: string): string {
  // github.com/user/my-api -> my-api
  // git@github.com:user/my-api.git -> my-api
  const name = basename(repo).replace(/\.git$/, "");
  return `/home/agent/${name}`;
}

/** Resolve the effective workdir for a Hearthfile. */
export function resolveWorkdir(hf: Hearthfile): string {
  if (hf.workdir) return hf.workdir;
  if (hf.repo) return defaultWorkdir(hf.repo);
  return "/home/agent";
}
