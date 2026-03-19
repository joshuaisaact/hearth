import net from "node:net";
import type WebSocket from "ws";
import { encodeMessage, parseFrames } from "../util.js";

export interface Transport {
  send(msg: object): void;
  onMessage: ((msg: object) => void) | null;
  onClose: (() => void) | null;
  close(): void;
}

export class UdsTransport implements Transport {
  onMessage: ((msg: object) => void) | null = null;
  onClose: (() => void) | null = null;
  private socket: net.Socket;

  constructor(socket: net.Socket) {
    this.socket = socket;

    let remainder: Buffer = Buffer.alloc(0);

    socket.on("data", (chunk: Buffer) => {
      const combined = remainder.length > 0
        ? Buffer.concat([remainder, chunk])
        : chunk;

      const result = parseFrames(combined);
      remainder = result.remainder;

      for (const json of result.messages) {
        try {
          this.onMessage?.(JSON.parse(json) as object);
        } catch {}
      }
    });

    socket.on("close", () => this.onClose?.());
  }

  send(msg: object): void {
    this.socket.write(encodeMessage(msg));
  }

  close(): void {
    this.socket.destroy();
  }
}

export class WsTransport implements Transport {
  onMessage: ((msg: object) => void) | null = null;
  onClose: (() => void) | null = null;
  private ws: WebSocket;

  constructor(ws: WebSocket) {
    this.ws = ws;

    ws.on("message", (data: Buffer | string) => {
      try {
        const str = typeof data === "string" ? data : data.toString("utf-8");
        this.onMessage?.(JSON.parse(str) as object);
      } catch {}
    });

    ws.on("close", () => this.onClose?.());
  }

  send(msg: object): void {
    this.ws.send(JSON.stringify(msg));
  }

  close(): void {
    this.ws.close();
  }
}
