import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { parse } from "smol-toml";
import type { Hearthfile, HearthfileFiles } from "./hearthfile.js";

export interface HearthDefaults {
  setup?: string[];
  files?: HearthfileFiles[];
}

const DEFAULTS_PATH = join(homedir(), ".hearth", "defaults.toml");

/**
 * Load user-level defaults from ~/.hearth/defaults.toml.
 * Returns null if the file doesn't exist.
 */
export function loadDefaults(path?: string): HearthDefaults | null {
  const filePath = path ?? DEFAULTS_PATH;
  if (!existsSync(filePath)) return null;

  const raw = readFileSync(filePath, "utf-8");
  const parsed = parse(raw) as Record<string, unknown>;

  const defaults: HearthDefaults = {};

  if (parsed["setup"] !== undefined) {
    if (!Array.isArray(parsed["setup"]) || !parsed["setup"].every((s) => typeof s === "string")) {
      throw new Error("defaults.toml: 'setup' must be an array of strings");
    }
    defaults.setup = parsed["setup"] as string[];
  }

  if (parsed["files"] !== undefined) {
    if (!Array.isArray(parsed["files"])) throw new Error("defaults.toml: 'files' must be an array of tables");
    defaults.files = (parsed["files"] as Record<string, unknown>[]).map((f, i) => {
      if (typeof f["from"] !== "string") throw new Error(`defaults.toml: files[${i}].from must be a string`);
      if (typeof f["to"] !== "string") throw new Error(`defaults.toml: files[${i}].to must be a string`);
      const entry: HearthfileFiles = { from: f["from"], to: f["to"] };
      if (f["mode"] !== undefined) {
        if (typeof f["mode"] !== "string") throw new Error(`defaults.toml: files[${i}].mode must be a string`);
        entry.mode = f["mode"];
      }
      return entry;
    });
  }

  return defaults;
}

/**
 * Merge user-level defaults into a Hearthfile.
 * Default setup commands run after the project's setup commands.
 * Default files are appended after the project's files.
 */
export function mergeDefaults(hf: Hearthfile, defaults: HearthDefaults | null): Hearthfile {
  if (!defaults) return hf;

  const merged = { ...hf };

  if (defaults.setup) {
    merged.setup = [...(hf.setup ?? []), ...defaults.setup];
  }

  if (defaults.files) {
    merged.files = [...(hf.files ?? []), ...defaults.files];
  }

  return merged;
}
