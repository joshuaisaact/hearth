import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join, dirname } from "node:path";
import { homedir } from "node:os";
import { randomBytes } from "node:crypto";

const RC_PATH = join(homedir(), ".hearthrc");

export interface HearthConfig {
  host?: string;
  port?: number;
  token?: string;
}

export type ConnectionTarget =
  | { type: "uds"; path: string }
  | { type: "ws"; url: string; token: string };

export function loadConfig(): HearthConfig {
  try {
    return JSON.parse(readFileSync(RC_PATH, "utf-8")) as HearthConfig;
  } catch {
    return {};
  }
}

export function saveConfig(config: HearthConfig): void {
  writeFileSync(RC_PATH, JSON.stringify(config, null, 2) + "\n", { mode: 0o600 });
}

export function generateToken(): string {
  return randomBytes(32).toString("hex");
}

export function resolveConnection(): ConnectionTarget {
  const envHost = process.env.HEARTH_HOST;
  const envPort = process.env.HEARTH_PORT;
  const envToken = process.env.HEARTH_TOKEN;

  const host = envHost ?? loadConfig().host;
  const port = envPort ? parseInt(envPort, 10) : loadConfig().port;
  const token = envToken ?? loadConfig().token;

  if (host) {
    return {
      type: "ws",
      url: `ws://${host}:${port ?? 9100}`,
      token: token ?? "",
    };
  }

  const daemonSock = process.env.HEARTH_DAEMON_SOCK
    ?? join(homedir(), ".hearth", "daemon.sock");
  return { type: "uds", path: daemonSock };
}
