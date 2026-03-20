import { execSync } from "node:child_process";
import type { Hearthfile } from "./hearthfile.js";

/**
 * Resolve a GitHub token from the host environment.
 * Tries in order:
 *   1. Explicit env var from Hearthfile (github_token_env)
 *   2. GITHUB_TOKEN env var
 *   3. `gh auth token` CLI
 *   4. null (public repos only)
 */
export function resolveGitHubToken(hf: Hearthfile): string | null {
  // 1. Explicit env var name from Hearthfile
  if (hf.github_token_env) {
    const token = process.env[hf.github_token_env];
    if (token) return token;
  }

  // 2. Standard GITHUB_TOKEN
  if (process.env["GITHUB_TOKEN"]) {
    return process.env["GITHUB_TOKEN"];
  }

  // 3. gh CLI
  try {
    const token = execSync("gh auth token", { encoding: "utf-8", timeout: 5000 }).trim();
    if (token) return token;
  } catch {
    // gh not installed or not authenticated
  }

  return null;
}
