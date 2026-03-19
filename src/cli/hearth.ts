#!/usr/bin/env node

const command = process.argv[2];

if (command === "setup") {
  await import("./setup.js");
} else if (command === "daemon") {
  const flags = process.argv.slice(3);
  const isRemote = flags.includes("--remote");

  if (isRemote) {
    const { loadConfig, saveConfig, generateToken } = await import("../daemon/config.js");
    const config = loadConfig();

    if (!config.token) {
      config.token = generateToken();
      if (!config.port) config.port = 9100;
      saveConfig(config);
    }

    const port = config.port ?? 9100;
    const { startDaemon, DAEMON_SOCK } = await import("../daemon/server.js");
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
    const { startDaemon, DAEMON_SOCK } = await import("../daemon/server.js");
    const server = startDaemon();
    console.log(`hearth daemon listening on ${DAEMON_SOCK}`);
    process.on("SIGINT", () => { server.close(); process.exit(0); });
    process.on("SIGTERM", () => { server.close(); process.exit(0); });
  }
} else if (command === "connect") {
  const host = process.argv[3];
  if (!host) {
    console.error("Usage: hearth connect <host> [--port <port>] [--token <token>]");
    process.exit(1);
  }

  const flags = process.argv.slice(4);
  const portIdx = flags.indexOf("--port");
  const tokenIdx = flags.indexOf("--token");
  const port = portIdx !== -1 ? parseInt(flags[portIdx + 1], 10) : 9100;
  const token = tokenIdx !== -1 ? flags[tokenIdx + 1] : undefined;

  const { loadConfig, saveConfig } = await import("../daemon/config.js");
  const config = loadConfig();
  config.host = host;
  config.port = port;
  if (token) config.token = token;
  saveConfig(config);

  console.log(`Saved connection: ws://${host}:${port}`);
  if (!token && !config.token) {
    console.log("Note: no token set. Use --token <token> or edit ~/.hearthrc");
  }
} else if (command === "build") {
  const { buildCommand } = await import("./build.js");
  await buildCommand(process.argv.slice(3));
} else if (command === "rebuild") {
  const { rebuildCommand } = await import("./build.js");
  await rebuildCommand(process.argv.slice(3));
} else if (command === "envs") {
  const { envsCommand } = await import("./envs.js");
  envsCommand(process.argv.slice(3));
} else if (command === "claude") {
  const { claudeCommand } = await import("./claude.js");
  await claudeCommand(process.argv.slice(3));
} else if (command === "shell") {
  const { shellCommand } = await import("./shell.js");
  await shellCommand(process.argv.slice(3));
} else if (command === "pool") {
  const sub = process.argv[3];
  const { isThinPoolAvailable, getThinPoolStatus, destroyThinPool } = await import("../vm/thin.js");
  if (sub === "status") {
    const status = getThinPoolStatus();
    if (!status) {
      console.log("Thin pool: not active");
      console.log("  Run hearth setup as root to enable instant snapshots");
    } else {
      console.log("Thin pool: active");
      console.log(`  Data usage:     ${status.usedDataPercent}%`);
      console.log(`  Metadata usage: ${status.usedMetaPercent}%`);
      console.log(`  Active volumes: ${status.thinCount}`);
    }
  } else if (sub === "destroy") {
    destroyThinPool();
    console.log("Thin pool destroyed");
  } else {
    console.log("Usage: hearth pool <command>");
    console.log("");
    console.log("Commands:");
    console.log("  status   Show thin pool usage");
    console.log("  destroy  Tear down thin pool");
  }
} else {
  console.log("Usage: hearth <command>");
  console.log("");
  console.log("Commands:");
  console.log("  setup    Download and configure all dependencies");
  console.log("  build    Build an environment from a Hearthfile.toml");
  console.log("  rebuild  Rebuild an existing environment from scratch");
  console.log("  envs     List, inspect, or remove environments");
  console.log("  claude   Launch Claude Code in an isolated sandbox");
  console.log("  shell    Start an interactive shell in a sandbox");
  console.log("  daemon   Start the Hearth daemon (for multi-process/remote access)");
  console.log("  connect  Configure remote daemon connection (hearth connect <host>)");
  console.log("  pool     Manage dm-thin snapshot pool (status, destroy)");
  process.exit(command ? 1 : 0);
}
