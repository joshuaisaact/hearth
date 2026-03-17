import net from "node:net";
import { unlinkSync } from "node:fs";
import { join } from "node:path";
import { Sandbox } from "../sandbox/sandbox.js";
import { getHearthDir } from "../vm/binary.js";
import { errorMessage, encodeMessage, parseFrames } from "../util.js";
import type { SpawnHandle } from "../agent/client.js";

const DAEMON_SOCK = join(getHearthDir(), "daemon.sock");

interface ActiveSandbox {
  sandbox: Sandbox;
  spawns: Map<number, SpawnHandle>;
}

export function startDaemon(): net.Server {
  try { unlinkSync(DAEMON_SOCK); } catch {}

  const server = net.createServer((conn) => {
    const sandboxes = new Map<string, ActiveSandbox>();
    let nextId = 1;
    let nextSpawnId = 1;
    const chunks: Buffer[] = [];
    let totalLen = 0;

    // Serial message queue — process one at a time to prevent races
    let processing = Promise.resolve();

    conn.on("data", (chunk: Buffer) => {
      chunks.push(chunk);
      totalLen += chunk.length;

      const combined = Buffer.concat(chunks);
      chunks.length = 0;
      const { messages, remainder } = parseFrames(combined);

      if (remainder.length > 0) {
        chunks.push(remainder);
        totalLen = remainder.length;
      } else {
        totalLen = 0;
      }

      for (const json of messages) {
        processing = processing.then(async () => {
          try {
            const msg = JSON.parse(json);
            const reqId = msg.reqId;
            const response = await handleMessage(msg, sandboxes, () => nextId++, () => nextSpawnId++, conn);
            sendResponse(conn, { ...response, reqId });
          } catch (err) {
            sendResponse(conn, { error: errorMessage(err) });
          }
        });
      }
    });

    conn.on("close", () => {
      // Clean up all sandboxes owned by this connection
      for (const [id, active] of sandboxes) {
        try { active.sandbox.destroySync(); } catch {}
      }
      sandboxes.clear();
    });
  });

  server.listen(DAEMON_SOCK);
  return server;
}

async function handleMessage(
  msg: any,
  sandboxes: Map<string, ActiveSandbox>,
  allocId: () => number,
  allocSpawnId: () => number,
  conn: net.Socket,
): Promise<object> {
  const { method } = msg;

  switch (method) {
    case "create": {
      const sandbox = await Sandbox.create();
      const sandboxId = `sb_${allocId()}`;
      sandboxes.set(sandboxId, { sandbox, spawns: new Map() });
      return { ok: true, sandboxId };
    }

    case "fromSnapshot": {
      const sandbox = await Sandbox.fromSnapshot(msg.name);
      const sandboxId = `sb_${allocId()}`;
      sandboxes.set(sandboxId, { sandbox, spawns: new Map() });
      return { ok: true, sandboxId };
    }

    case "exec": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const result = await active.sandbox.exec(msg.command, msg.opts);
      return { ok: true, ...result };
    }

    case "spawn": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const handle = active.sandbox.spawn(msg.command, msg.opts);
      const spawnId = allocSpawnId();
      active.spawns.set(spawnId, handle);

      handle.stdout.on("data", (data: string) => {
        sendResponse(conn, { event: "stdout", spawnId, data });
      });
      handle.stderr.on("data", (data: string) => {
        sendResponse(conn, { event: "stderr", spawnId, data });
      });
      handle.wait().then(({ exitCode }) => {
        sendResponse(conn, { event: "exit", spawnId, exitCode });
        active.spawns.delete(spawnId);
      });

      return { ok: true, spawnId };
    }

    case "writeFile": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.writeFile(msg.path, msg.content);
      return { ok: true };
    }

    case "readFile": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const content = await active.sandbox.readFile(msg.path);
      return { ok: true, content };
    }

    case "upload": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.upload(msg.hostPath, msg.guestPath);
      return { ok: true };
    }

    case "download": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.download(msg.guestPath, msg.hostPath);
      return { ok: true };
    }

    case "forwardPort": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const { host, port } = await active.sandbox.forwardPort(msg.guestPort);
      return { ok: true, host, port };
    }

    case "enableInternet": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.enableInternet();
      return { ok: true };
    }

    case "snapshot": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const name = await active.sandbox.snapshot(msg.name);
      sandboxes.delete(msg.sandboxId);
      return { ok: true, name };
    }

    case "destroy": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.destroy();
      sandboxes.delete(msg.sandboxId);
      return { ok: true };
    }

    case "listSnapshots": {
      const snapshots = Sandbox.listSnapshots();
      return { ok: true, snapshots };
    }

    case "deleteSnapshot": {
      Sandbox.deleteSnapshot(msg.name);
      return { ok: true };
    }

    case "ping": {
      return { ok: true };
    }

    default:
      return { error: `unknown method: ${method}` };
  }
}

function getSandbox(sandboxes: Map<string, ActiveSandbox>, id: string): ActiveSandbox {
  const active = sandboxes.get(id);
  if (!active) throw new Error(`Sandbox "${id}" not found`);
  return active;
}

function sendResponse(conn: net.Socket, msg: object): void {
  conn.write(encodeMessage(msg));
}

export { DAEMON_SOCK };
