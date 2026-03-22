import { loadConfig, saveConfig } from "../daemon/config.js";

export function connectCommand(args: string[]) {
  const host = args[0];
  if (!host) {
    console.error("Usage: hearth connect <host> [--port <port>] [--token <token>]");
    process.exit(1);
  }

  const flags = args.slice(1);
  const portIdx = flags.indexOf("--port");
  const tokenIdx = flags.indexOf("--token");
  const port = portIdx !== -1 ? parseInt(flags[portIdx + 1], 10) : 9100;
  const token = tokenIdx !== -1 ? flags[tokenIdx + 1] : undefined;

  const config = loadConfig();
  config.host = host;
  config.port = port;
  if (token) config.token = token;
  saveConfig(config);

  console.log(`Saved connection: ws://${host}:${port}`);
  if (!token && !config.token) {
    console.log("Note: no token set. Use --token <token> or edit ~/.hearthrc");
  }
}
