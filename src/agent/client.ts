import net from "node:net";
import { unlinkSync } from "node:fs";
import { EventEmitter } from "node:events";
import { AgentError } from "../errors.js";
import { encodeMessage } from "../util.js";

/** Exit code returned when the socket is closed before the spawn exits (128 + SIGKILL). */
const EXIT_KILLED = 137;

export interface SpawnHandle {
  stdout: EventEmitter;
  stderr: EventEmitter;
  stdin: {
    write(data: string | Buffer): void;
    close(): void;
  };
  resize(cols: number, rows: number): void;
  wait(): Promise<{ exitCode: number }>;
  kill(): void;
  keepalive(): void;
}

export class AgentClient {
  private socket: net.Socket | null = null;

  constructor(private vsockUdsPath: string, private port: number = 1024) {}

  async waitForConnection(timeoutMs: number = 10000): Promise<void> {
    const udsPath = `${this.vsockUdsPath}_${this.port}`;

    // Remove stale socket file from previous runs
    try { unlinkSync(udsPath); } catch {}

    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        server.close();
        try { unlinkSync(udsPath); } catch {}
        reject(new AgentError(`Agent connection timed out after ${timeoutMs}ms`));
      }, timeoutMs);

      const server = net.createServer((conn) => {
        clearTimeout(timer);
        this.socket = conn;
        conn.on("error", () => {});
        server.close();
        resolve();
      });

      server.on("error", (err) => {
        clearTimeout(timer);
        reject(new AgentError(`Failed to listen for agent: ${err.message}`));
      });

      server.listen(udsPath);
    });
  }

  private async sendRequest(payload: object): Promise<Record<string, unknown>> {
    if (!this.socket) throw new AgentError("Agent not connected");

    const buf = encodeMessage(payload);

    return new Promise((resolve, reject) => {
      const socket = this.socket!;
      const chunks: Buffer[] = [];
      let totalLen = 0;

      const onData = (chunk: Buffer) => {
        chunks.push(chunk);
        totalLen += chunk.length;

        if (totalLen < 4) return;

        const combined = Buffer.concat(chunks);
        const msgLen = combined.readUInt32LE(0);
        if (combined.length < 4 + msgLen) return;

        socket.removeListener("data", onData);
        socket.removeListener("error", onError);

        const responseJson = combined.subarray(4, 4 + msgLen).toString("utf-8");
        try {
          resolve(JSON.parse(responseJson));
        } catch {
          reject(new AgentError(`Invalid JSON response: ${responseJson.slice(0, 200)}`));
        }
      };

      const onError = (err: Error) => {
        socket.removeListener("data", onData);
        reject(new AgentError(`Agent communication error: ${err.message}`));
      };

      socket.on("data", onData);
      socket.on("error", onError);
      socket.write(buf);
    });
  }

  async exec(
    command: string,
    opts?: { timeout?: number },
  ): Promise<{ stdout: string; stderr: string; exitCode: number }> {
    const payload: Record<string, unknown> = {
      method: "exec",
      cmd: command,
    };
    if (opts?.timeout) payload.timeout = Math.ceil(opts.timeout / 1000);

    const resp = await this.sendRequest(payload);

    if (!resp.ok) {
      throw new AgentError(`exec failed: ${resp.error}`);
    }

    return {
      stdout: Buffer.from(resp.stdout as string, "base64").toString("utf-8"),
      stderr: Buffer.from(resp.stderr as string, "base64").toString("utf-8"),
      exitCode: resp.exit_code as number,
    };
  }

  async writeFile(path: string, content: string | Buffer, mode?: number): Promise<void> {
    const data = Buffer.isBuffer(content)
      ? content.toString("base64")
      : Buffer.from(content, "utf-8").toString("base64");

    const payload: Record<string, unknown> = {
      method: "write_file",
      path,
      data,
    };
    if (mode !== undefined) payload.mode = mode;

    const resp = await this.sendRequest(payload);
    if (!resp.ok) {
      throw new AgentError(`writeFile failed: ${resp.error}`);
    }
  }

  async readFile(path: string): Promise<string> {
    const resp = await this.sendRequest({
      method: "read_file",
      path,
    });

    if (!resp.ok) {
      throw new AgentError(`readFile failed: ${resp.error}`);
    }

    return Buffer.from(resp.data as string, "base64").toString("utf-8");
  }

  spawn(
    command: string,
    opts?: { timeout?: number; interactive?: boolean; cols?: number; rows?: number },
  ): SpawnHandle {
    if (!this.socket) throw new AgentError("Agent not connected");

    const payload: Record<string, unknown> = {
      method: "spawn",
      cmd: command,
    };
    if (opts?.timeout) payload.timeout = Math.ceil(opts.timeout / 1000);
    if (opts?.interactive) {
      payload.interactive = true;
      if (opts.cols) payload.cols = opts.cols;
      if (opts.rows) payload.rows = opts.rows;
    }

    const stdoutEmitter = new EventEmitter();
    const stderrEmitter = new EventEmitter();
    let exitResolve: (result: { exitCode: number }) => void;
    const exitPromise = new Promise<{ exitCode: number }>((resolve) => {
      exitResolve = resolve;
    });

    const socket = this.socket;
    const chunks: Buffer[] = [];
    let totalLen = 0;

    const processMessages = () => {
      const recvBuf = Buffer.concat(chunks);
      chunks.length = 0;

      let offset = 0;
      while (offset + 4 <= recvBuf.length) {
        const msgLen = recvBuf.readUInt32LE(offset);
        if (offset + 4 + msgLen > recvBuf.length) break;

        const msgJson = recvBuf.subarray(offset + 4, offset + 4 + msgLen).toString("utf-8");
        offset += 4 + msgLen;

        try {
          const msg = JSON.parse(msgJson);
          if (msg.type === "stdout" && msg.data) {
            stdoutEmitter.emit("data", Buffer.from(msg.data, "base64").toString("utf-8"));
          } else if (msg.type === "stderr" && msg.data) {
            stderrEmitter.emit("data", Buffer.from(msg.data, "base64").toString("utf-8"));
          } else if (msg.type === "exit") {
            socket.removeListener("data", onData);
            exitResolve({ exitCode: msg.code ?? -1 });
          } else if (msg.ok === false) {
            socket.removeListener("data", onData);
            exitResolve({ exitCode: -1 });
          }
        } catch {}
      }

      // Keep any incomplete message for next round
      if (offset < recvBuf.length) {
        chunks.push(recvBuf.subarray(offset));
        totalLen = recvBuf.length - offset;
      } else {
        totalLen = 0;
      }
    };

    const onData = (chunk: Buffer) => {
      chunks.push(chunk);
      totalLen += chunk.length;
      processMessages();
    };

    const onClose = () => {
      socket.removeListener("data", onData);
      exitResolve({ exitCode: EXIT_KILLED });
    };

    socket.on("data", onData);
    socket.once("close", onClose);
    socket.once("error", onClose);
    socket.write(encodeMessage(payload));

    // Send keepalives so the guest agent's idle timeout doesn't trigger.
    const keepaliveInterval = setInterval(() => {
      try { socket.write(encodeMessage({ type: "keepalive" })); } catch {}
    }, 1000);
    exitPromise.then(() => clearInterval(keepaliveInterval));

    return {
      stdout: stdoutEmitter,
      stderr: stderrEmitter,
      stdin: {
        write(data: string | Buffer): void {
          const buf = Buffer.isBuffer(data) ? data : Buffer.from(data, "utf-8");
          const msg = encodeMessage({ type: "stdin", data: buf.toString("base64") });
          socket.write(msg);
        },
        close(): void {
          // Not currently handled by the guest agent — the child process
          // receives EOF when the PTY master is closed on sandbox destroy.
        },
      },
      resize(cols: number, rows: number): void {
        socket.write(encodeMessage({ type: "resize", cols, rows }));
      },
      wait: () => exitPromise,
      kill: () => {
        try {
          socket.write(encodeMessage({ type: "kill" }));
        } catch {}
      },
      keepalive: () => {
        try {
          socket.write(encodeMessage({ type: "keepalive" }));
        } catch {}
      },
    };
  }

  async ping(): Promise<boolean> {
    try {
      const resp = await this.sendRequest({ method: "ping" });
      return resp.ok === true;
    } catch {
      return false;
    }
  }

  close(): void {
    if (this.socket) {
      this.socket.destroy();
      this.socket = null;
    }
  }
}
