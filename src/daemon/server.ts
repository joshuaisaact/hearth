import net from "node:net";
import { unlinkSync } from "node:fs";
import { join } from "node:path";
import { Sandbox } from "../sandbox/sandbox.js";
import { getHearthDir } from "../vm/binary.js";
import { errorMessage, encodeMessage, requireStr, requireNum } from "../util.js";
import { UdsTransport, type Transport } from "./transport.js";
import { startWsListener } from "./ws-server.js";
import type { SpawnHandle } from "../agent/client.js";
import type { ExecOptions, SpawnOptions } from "../sandbox/types.js";

const DAEMON_SOCK = join(getHearthDir(), "daemon.sock");

interface DaemonResponse {
  ok?: boolean;
  error?: string;
  sandboxId?: string;
  spawnId?: number;
  stdout?: string;
  stderr?: string;
  exitCode?: number;
  content?: string;
  host?: string;
  port?: number;
  name?: string;
  snapshots?: unknown;
}

/** Incoming daemon request — discriminated by method. */
interface DaemonRequest {
  reqId: number;
  method: string;
  sandboxId?: string;
  name?: string;
  command?: string;
  opts?: ExecOptions | SpawnOptions;
  path?: string;
  content?: string;
  hostPath?: string;
  guestPath?: string;
  guestPort?: number;
  spawnId?: number;
  data?: string;
  cols?: number;
  rows?: number;
}

interface ActiveSandbox {
  sandbox: Sandbox;
  spawns: Map<number, SpawnHandle>;
}

export function startDaemon(opts?: { wsPort?: number; wsToken?: string }): net.Server {
  try { unlinkSync(DAEMON_SOCK); } catch {}

  const server = net.createServer((conn) => {
    const transport = new UdsTransport(conn);
    handleConnection(transport, false);
  });

  server.listen(DAEMON_SOCK);

  if (opts?.wsPort !== undefined && opts.wsToken) {
    startWsListener(opts.wsPort, opts.wsToken, (transport) => {
      handleConnection(transport, true);
    });
  }

  return server;
}

function handleConnection(transport: Transport, isRemote: boolean): void {
  const sandboxes = new Map<string, ActiveSandbox>();
  let nextId = 1;
  let nextSpawnId = 1;

  // Serial message queue — process one at a time to prevent races
  let processing = Promise.resolve();

  transport.onMessage = (raw: object) => {
    processing = processing.then(async () => {
      let reqId: number | undefined;
      try {
        const msg = raw as DaemonRequest;
        reqId = typeof msg.reqId === "number" ? msg.reqId : undefined;
        const response = await handleMessage(
          msg, sandboxes, () => nextId++, () => nextSpawnId++,
          (m) => transport.send(m), isRemote,
        );
        transport.send({ ...response, reqId });
      } catch (err) {
        transport.send({ error: errorMessage(err), reqId });
      }
    });
  };

  transport.onClose = () => {
    // Clean up all sandboxes owned by this connection
    for (const [_id, active] of sandboxes) {
      try { active.sandbox.destroySync(); } catch {}
    }
    sandboxes.clear();
  };
}

async function handleMessage(
  msg: DaemonRequest,
  sandboxes: Map<string, ActiveSandbox>,
  allocId: () => number,
  allocSpawnId: () => number,
  send: (msg: object) => void,
  isRemote: boolean,
): Promise<DaemonResponse> {
  switch (msg.method) {
    case "create": {
      const sandbox = await Sandbox.create();
      const sandboxId = `sb_${allocId()}`;
      sandboxes.set(sandboxId, { sandbox, spawns: new Map() });
      return { ok: true, sandboxId };
    }

    case "fromSnapshot": {
      const sandbox = await Sandbox.fromSnapshot(requireStr(msg.name, "name"));
      const sandboxId = `sb_${allocId()}`;
      sandboxes.set(sandboxId, { sandbox, spawns: new Map() });
      return { ok: true, sandboxId };
    }

    case "exec": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      const result = await active.sandbox.exec(requireStr(msg.command, "command"), msg.opts);
      return { ok: true, ...result };
    }

    case "spawn": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      const handle = active.sandbox.spawn(requireStr(msg.command, "command"), msg.opts);
      const spawnId = allocSpawnId();
      active.spawns.set(spawnId, handle);

      handle.stdout.on("data", (data: string) => {
        send({ event: "stdout", spawnId, data });
      });
      handle.stderr.on("data", (data: string) => {
        send({ event: "stderr", spawnId, data });
      });
      handle.wait().then(({ exitCode }) => {
        send({ event: "exit", spawnId, exitCode });
        active.spawns.delete(spawnId);
      }).catch(() => {
        send({ event: "exit", spawnId, exitCode: 1 });
        active.spawns.delete(spawnId);
      });

      return { ok: true, spawnId };
    }

    case "spawn_stdin": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      const spawnId = requireNum(msg.spawnId, "spawnId");
      const handle = active.spawns.get(spawnId);
      if (!handle) throw new Error(`Spawn ${spawnId} not found`);
      handle.stdin.write(requireStr(msg.data, "data"));
      return { ok: true };
    }

    case "spawn_resize": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      const spawnId = requireNum(msg.spawnId, "spawnId");
      const handle = active.spawns.get(spawnId);
      if (!handle) throw new Error(`Spawn ${spawnId} not found`);
      handle.resize(requireNum(msg.cols, "cols"), requireNum(msg.rows, "rows"));
      return { ok: true };
    }

    case "writeFile": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      await active.sandbox.writeFile(requireStr(msg.path, "path"), requireStr(msg.content, "content"));
      return { ok: true };
    }

    case "readFile": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      const content = await active.sandbox.readFile(requireStr(msg.path, "path"));
      return { ok: true, content };
    }

    case "upload": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      await active.sandbox.upload(requireStr(msg.hostPath, "hostPath"), requireStr(msg.guestPath, "guestPath"));
      return { ok: true };
    }

    case "download": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      await active.sandbox.download(requireStr(msg.guestPath, "guestPath"), requireStr(msg.hostPath, "hostPath"));
      return { ok: true };
    }

    case "forwardPort": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      const bindAddress = isRemote ? "0.0.0.0" : "127.0.0.1";
      const { host, port } = await active.sandbox.forwardPort(
        requireNum(msg.guestPort, "guestPort"), bindAddress,
      );
      return { ok: true, host, port };
    }

    case "enableInternet": {
      const active = getSandbox(sandboxes, requireStr(msg.sandboxId, "sandboxId"));
      await active.sandbox.enableInternet();
      return { ok: true };
    }

    case "checkpoint": {
      const sid = requireStr(msg.sandboxId, "sandboxId");
      const active = getSandbox(sandboxes, sid);
      const name = await active.sandbox.checkpoint(requireStr(msg.name, "name"));
      return { ok: true, name };
    }

    case "snapshot": {
      const sid = requireStr(msg.sandboxId, "sandboxId");
      const active = getSandbox(sandboxes, sid);
      const name = await active.sandbox.snapshot(requireStr(msg.name, "name"));
      sandboxes.delete(sid);
      return { ok: true, name };
    }

    case "destroy": {
      const sid = requireStr(msg.sandboxId, "sandboxId");
      const active = getSandbox(sandboxes, sid);
      await active.sandbox.destroy();
      sandboxes.delete(sid);
      return { ok: true };
    }

    case "listSnapshots": {
      const snapshots = Sandbox.listSnapshots();
      return { ok: true, snapshots };
    }

    case "deleteSnapshot": {
      Sandbox.deleteSnapshot(requireStr(msg.name, "name"));
      return { ok: true };
    }

    case "ping": {
      return { ok: true };
    }

    default:
      return { error: `unknown method: ${msg.method}` };
  }
}

function getSandbox(sandboxes: Map<string, ActiveSandbox>, id: string): ActiveSandbox {
  const active = sandboxes.get(id);
  if (!active) throw new Error(`Sandbox "${id}" not found`);
  return active;
}

export { DAEMON_SOCK };
