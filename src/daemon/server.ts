import net from "node:net";
import { unlinkSync } from "node:fs";
import { join } from "node:path";
import { Sandbox } from "../sandbox/sandbox.js";
import { getHearthDir } from "../vm/binary.js";
import { errorMessage } from "../util.js";
import type { SpawnHandle } from "../agent/client.js";

const DAEMON_SOCK = join(getHearthDir(), "daemon.sock");

interface ActiveSandbox {
  sandbox: Sandbox;
  spawns: Map<number, SpawnHandle>;
}

/**
 * Start the Hearth daemon. Listens on ~/.hearth/daemon.sock.
 * Exposes the full Sandbox API over length-prefixed JSON RPC.
 */
export function startDaemon(): net.Server {
  try { unlinkSync(DAEMON_SOCK); } catch {}

  const sandboxes = new Map<string, ActiveSandbox>();
  let nextId = 1;
  let nextSpawnId = 1;

  const server = net.createServer((conn) => {
    let recvBuf = Buffer.alloc(0);

    conn.on("data", (chunk: Buffer) => {
      recvBuf = Buffer.concat([recvBuf, chunk]);

      while (recvBuf.length >= 4) {
        const msgLen = recvBuf.readUInt32LE(0);
        if (recvBuf.length < 4 + msgLen) break;

        const json = recvBuf.subarray(4, 4 + msgLen).toString("utf-8");
        recvBuf = recvBuf.subarray(4 + msgLen);

        handleMessage(json, sandboxes, nextId, nextSpawnId, conn)
          .then(({ response, idInc, spawnIdInc }) => {
            if (idInc) nextId++;
            if (spawnIdInc) nextSpawnId++;
            sendMessage(conn, response);
          })
          .catch((err) => {
            sendMessage(conn, { error: errorMessage(err) });
          });
      }
    });

    conn.on("close", () => {
      // Clean up sandboxes owned by this connection
      // (In a production daemon, sandboxes would outlive connections.
      //  For now, each connection owns its sandboxes.)
    });
  });

  server.listen(DAEMON_SOCK, () => {
    // Daemon ready
  });

  return server;
}

async function handleMessage(
  json: string,
  sandboxes: Map<string, ActiveSandbox>,
  nextId: number,
  nextSpawnId: number,
  conn: net.Socket,
): Promise<{ response: object; idInc?: boolean; spawnIdInc?: boolean }> {
  const msg = JSON.parse(json);
  const { method, id } = msg;

  switch (method) {
    case "create": {
      const sandbox = await Sandbox.create();
      const sandboxId = `sb_${nextId}`;
      sandboxes.set(sandboxId, { sandbox, spawns: new Map() });
      return { response: { ok: true, sandboxId }, idInc: true };
    }

    case "fromSnapshot": {
      const sandbox = await Sandbox.fromSnapshot(msg.name);
      const sandboxId = `sb_${nextId}`;
      sandboxes.set(sandboxId, { sandbox, spawns: new Map() });
      return { response: { ok: true, sandboxId }, idInc: true };
    }

    case "exec": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const result = await active.sandbox.exec(msg.command, msg.opts);
      return { response: { ok: true, ...result } };
    }

    case "spawn": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const handle = active.sandbox.spawn(msg.command, msg.opts);
      const spawnId = nextSpawnId;
      active.spawns.set(spawnId, handle);

      // Stream stdout/stderr as separate messages
      handle.stdout.on("data", (data: string) => {
        sendMessage(conn, { event: "stdout", spawnId, data });
      });
      handle.stderr.on("data", (data: string) => {
        sendMessage(conn, { event: "stderr", spawnId, data });
      });
      handle.wait().then(({ exitCode }) => {
        sendMessage(conn, { event: "exit", spawnId, exitCode });
        active.spawns.delete(spawnId);
      });

      return { response: { ok: true, spawnId }, spawnIdInc: true };
    }

    case "writeFile": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.writeFile(msg.path, msg.content);
      return { response: { ok: true } };
    }

    case "readFile": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const content = await active.sandbox.readFile(msg.path);
      return { response: { ok: true, content } };
    }

    case "upload": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.upload(msg.hostPath, msg.guestPath);
      return { response: { ok: true } };
    }

    case "download": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.download(msg.guestPath, msg.hostPath);
      return { response: { ok: true } };
    }

    case "forwardPort": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const { host, port } = await active.sandbox.forwardPort(msg.guestPort);
      return { response: { ok: true, host, port } };
    }

    case "enableInternet": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.enableInternet();
      return { response: { ok: true } };
    }

    case "snapshot": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      const name = await active.sandbox.snapshot(msg.name);
      sandboxes.delete(msg.sandboxId); // sandbox is destroyed after snapshot
      return { response: { ok: true, name } };
    }

    case "destroy": {
      const active = getSandbox(sandboxes, msg.sandboxId);
      await active.sandbox.destroy();
      sandboxes.delete(msg.sandboxId);
      return { response: { ok: true } };
    }

    case "listSnapshots": {
      const snapshots = Sandbox.listSnapshots();
      return { response: { ok: true, snapshots } };
    }

    case "deleteSnapshot": {
      Sandbox.deleteSnapshot(msg.name);
      return { response: { ok: true } };
    }

    case "ping": {
      return { response: { ok: true } };
    }

    default:
      return { response: { error: `unknown method: ${method}` } };
  }
}

function getSandbox(sandboxes: Map<string, ActiveSandbox>, id: string): ActiveSandbox {
  const active = sandboxes.get(id);
  if (!active) throw new Error(`Sandbox "${id}" not found`);
  return active;
}

function sendMessage(conn: net.Socket, msg: object): void {
  const json = JSON.stringify(msg);
  const buf = Buffer.alloc(4 + json.length);
  buf.writeUInt32LE(json.length, 0);
  buf.write(json, 4);
  conn.write(buf);
}

export { DAEMON_SOCK };
