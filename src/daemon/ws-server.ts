import http from "node:http";
import { WebSocketServer } from "ws";
import { WsTransport, type Transport } from "./transport.js";

export function startWsListener(
  port: number,
  token: string,
  onConnection: (transport: Transport) => void,
): http.Server {
  const httpServer = http.createServer((_req, res) => {
    res.writeHead(404);
    res.end();
  });

  const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false });

  httpServer.on("upgrade", (req, socket, head) => {
    // Validate token from Authorization header
    const auth = req.headers.authorization;
    if (auth !== `Bearer ${token}`) {
      socket.write("HTTP/1.1 401 Unauthorized\r\n\r\n");
      socket.destroy();
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws) => {
      // Disable Nagle on the underlying TCP socket for lower latency
      const rawSocket = (ws as unknown as { _socket?: { setNoDelay?: (v: boolean) => void } })._socket;
      rawSocket?.setNoDelay?.(true);

      const transport = new WsTransport(ws);
      onConnection(transport);
    });
  });

  httpServer.listen(port, "0.0.0.0");
  return httpServer;
}
