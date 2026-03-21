import { readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { parse } from "smol-toml";
import type { Hearthfile, HearthfileFiles } from "./hearthfile.js";
import { parseSetupField, parseFilesField } from "./hearthfile.js";

export interface HearthDefaults {
  setup?: string[];
  files?: HearthfileFiles[];
}

/**
 * Load user-level defaults from ~/.hearth/defaults.toml.
 * Returns null if the file doesn't exist.
 */
export function loadDefaults(path?: string): HearthDefaults | null {
  const filePath = path ?? join(homedir(), ".hearth", "defaults.toml");
  if (!existsSync(filePath)) return null;

  const raw = readFileSync(filePath, "utf-8");
  const parsed = parse(raw) as Record<string, unknown>;

  const defaults: HearthDefaults = {};

  const setup = parseSetupField(parsed, "defaults.toml");
  if (setup) defaults.setup = setup;

  const files = parseFilesField(parsed, "defaults.toml");
  if (files) defaults.files = files;

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
