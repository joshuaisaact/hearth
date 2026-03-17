import { existsSync } from "node:fs";

export function waitForFile(path: string, timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const check = () => {
      if (existsSync(path)) {
        resolve();
      } else if (Date.now() - start > timeoutMs) {
        reject(new Error(`Timed out waiting for: ${path}`));
      } else {
        setTimeout(check, 10);
      }
    };
    check();
  });
}

export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** Encode a JSON object as a length-prefixed buffer (4-byte LE length + UTF-8 JSON). */
export function encodeMessage(msg: object): Buffer {
  const json = JSON.stringify(msg);
  const byteLen = Buffer.byteLength(json, "utf-8");
  const buf = Buffer.alloc(4 + byteLen);
  buf.writeUInt32LE(byteLen, 0);
  buf.write(json, 4, "utf-8");
  return buf;
}

/**
 * Parse length-prefixed messages from a buffer.
 * Returns parsed messages and any remaining incomplete bytes.
 */
export function parseFrames(data: Buffer): { messages: string[]; remainder: Buffer } {
  const messages: string[] = [];
  let offset = 0;

  while (offset + 4 <= data.length) {
    const msgLen = data.readUInt32LE(offset);
    if (offset + 4 + msgLen > data.length) break;
    messages.push(data.subarray(offset + 4, offset + 4 + msgLen).toString("utf-8"));
    offset += 4 + msgLen;
  }

  const remainder = offset < data.length ? data.subarray(offset) : Buffer.alloc(0);
  return { messages, remainder };
}
