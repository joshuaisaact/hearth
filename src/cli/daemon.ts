import { loadConfig, saveConfig, generateToken } from "../daemon/config.js";
import { startDaemon, DAEMON_SOCK } from "../daemon/server.js";

export function daemonCommand(args: string[]) {
  const isRemote = args.includes("--remote");

  if (isRemote) {
    const config = loadConfig();

    if (!config.token) {
      config.token = generateToken();
      if (!config.port) config.port = 9100;
      saveConfig(config);
    }

    const port = config.port ?? 9100;
    const server = startDaemon({ wsPort: port, wsToken: config.token });

    console.log(`hearth daemon listening on ${DAEMON_SOCK}`);
    console.log(`WebSocket listening on ws://0.0.0.0:${port}`);
    console.log(`Token: ${config.token}`);
    console.log();
    console.log("On remote machine, create ~/.hearthrc:");
    console.log(`  { "host": "<this-machine-ip>", "port": ${port}, "token": "${config.token}" }`);

    process.on("SIGINT", () => { server.close(); process.exit(0); });
    process.on("SIGTERM", () => { server.close(); process.exit(0); });
  } else {
    const server = startDaemon();
    console.log(`hearth daemon listening on ${DAEMON_SOCK}`);
    process.on("SIGINT", () => { server.close(); process.exit(0); });
    process.on("SIGTERM", () => { server.close(); process.exit(0); });
  }
}
