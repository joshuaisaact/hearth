import { join } from "node:path";
import { homedir } from "node:os";
import { DaemonClient } from "../daemon/client.js";
import { resolveConnection } from "../daemon/config.js";

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

async function getClient(): Promise<DaemonClient> {
  const target = resolveConnection();
  if (target.type === "ws") {
    const client = new DaemonClient();
    await client.connect();
    return client;
  }

  const client = await tryConnect(DAEMON_SOCK);
  if (client) return client;

  console.error("No running daemon found. Start a sandbox first with 'hearth shell' or 'hearth claude'.");
  process.exit(1);
}

async function resolveSession(client: DaemonClient, sessionFlag?: string): Promise<string> {
  const sessions = await client.listSessions();

  if (sessions.length === 0) {
    console.error("No active sandboxes. Start one with 'hearth shell' or 'hearth claude'.");
    process.exit(1);
  }

  if (sessionFlag) {
    if (!sessions.includes(sessionFlag)) {
      console.error(`Sandbox "${sessionFlag}" not found. Active: ${sessions.join(", ")}`);
      process.exit(1);
    }
    return sessionFlag;
  }

  if (sessions.length > 1) {
    console.error("Multiple active sandboxes. Specify one with --sandbox <id>:");
    for (const s of sessions) {
      console.error(`  ${s}`);
    }
    process.exit(1);
  }

  return sessions[0];
}

export async function checkpointCommand(args: string[]): Promise<void> {
  let name: string | undefined;
  let sessionFlag: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--sandbox" && args[i + 1]) {
      sessionFlag = args[++i];
    } else if (!args[i].startsWith("-")) {
      name = args[i];
    }
  }

  if (!name) {
    console.error("Usage: hearth checkpoint <name> [--sandbox <id>]");
    process.exit(1);
  }

  const client = await getClient();

  try {
    const sandboxId = await resolveSession(client, sessionFlag);
    const t0 = Date.now();
    await client._checkpoint(sandboxId, name);
    console.log(`Checkpoint "${name}" created (${Date.now() - t0}ms)`);
    console.log(`Note: the active session was terminated. Restore with: hearth claude ${name}`);
  } finally {
    client.close();
  }
}
