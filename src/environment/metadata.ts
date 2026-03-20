import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { parse, stringify } from "smol-toml";
import type { Hearthfile } from "./hearthfile.js";

const META_FILENAME = "environment.toml";

export interface EnvironmentMeta {
  name: string;
  repo?: string;
  branch?: string;
  builtAt: string;
  hearthfile: Hearthfile;
}

export function writeEnvironmentMeta(snapshotDir: string, meta: EnvironmentMeta): void {
  const path = join(snapshotDir, META_FILENAME);
  writeFileSync(path, stringify(meta as unknown as Record<string, unknown>));
}

export function readEnvironmentMeta(snapshotDir: string): EnvironmentMeta | null {
  const path = join(snapshotDir, META_FILENAME);
  if (!existsSync(path)) return null;
  const raw = readFileSync(path, "utf-8");
  const parsed = parse(raw) as Record<string, unknown>;

  if (typeof parsed["name"] !== "string") return null;
  if (typeof parsed["builtAt"] !== "string") return null;
  if (typeof parsed["hearthfile"] !== "object" || parsed["hearthfile"] === null) return null;

  return {
    name: parsed["name"],
    builtAt: parsed["builtAt"],
    repo: typeof parsed["repo"] === "string" ? parsed["repo"] : undefined,
    branch: typeof parsed["branch"] === "string" ? parsed["branch"] : undefined,
    hearthfile: parsed["hearthfile"] as Hearthfile,
  };
}

export function isEnvironment(snapshotDir: string): boolean {
  return existsSync(join(snapshotDir, META_FILENAME));
}
