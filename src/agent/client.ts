import net from "node:net";
import { unlinkSync } from "node:fs";
import { AgentError } from "../errors.js";

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

    const json = JSON.stringify(payload);
    const buf = Buffer.alloc(4 + json.length);
    buf.writeUInt32LE(json.length, 0);
    buf.write(json, 4);

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
