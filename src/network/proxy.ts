import net from "node:net";
import { unlinkSync } from "node:fs";

const PROXY_VSOCK_PORT = 1027;

/**
 * HTTP CONNECT proxy that listens on a vsock UDS path.
 * Guest connects via AF_VSOCK → Flint proxies to this UDS.
 * Each connection: guest sends "CONNECT host:port HTTP/1.1\r\n\r\n",
 * host connects to the real server, replies 200, relays bidirectionally.
 */
export function startProxy(vsockUdsPath: string): Promise<net.Server> {
  const udsPath = `${vsockUdsPath}_${PROXY_VSOCK_PORT}`;

  try { unlinkSync(udsPath); } catch {}

  const server = net.createServer((guestConn) => {
    let buf = "";

    guestConn.on("data", function onConnect(chunk: Buffer) {
      buf += chunk.toString();

      const headerEnd = buf.indexOf("\r\n\r\n");
      if (headerEnd === -1) return;

      guestConn.removeListener("data", onConnect);
      guestConn.pause();

      // Parse: "CONNECT host:port HTTP/1.1\r\n..."
      const firstLine = buf.slice(0, buf.indexOf("\r\n"));
      const match = firstLine.match(/^CONNECT\s+(\S+):(\d+)\s+HTTP\/\d\.\d$/);
      if (!match) {
        guestConn.write("HTTP/1.1 400 Bad Request\r\n\r\n");
        guestConn.destroy();
        return;
      }

      const host = match[1];
      const port = parseInt(match[2], 10);

      const remote = net.connect(port, host, () => {
        guestConn.write("HTTP/1.1 200 Connection Established\r\n\r\n");

        // Forward any data after the CONNECT headers (e.g., pipelined TLS ClientHello)
        const remainder = buf.slice(headerEnd + 4);
        if (remainder.length > 0) {
          remote.write(remainder);
        }

        guestConn.pipe(remote);
        remote.pipe(guestConn);
        guestConn.resume();
      });

      remote.on("error", () => guestConn.destroy());
      guestConn.on("error", () => remote.destroy());
      remote.on("close", () => guestConn.destroy());
      guestConn.on("close", () => remote.destroy());
    });
  });

  return new Promise((resolve, reject) => {
    server.on("error", reject);
    server.listen(udsPath, () => resolve(server));
  });
}

/** TCP port the guest-side proxy bridge listens on. */
export const PROXY_GUEST_PORT = 3128;

export const PROXY_URL = `http://127.0.0.1:${PROXY_GUEST_PORT}`;

export { PROXY_VSOCK_PORT };
