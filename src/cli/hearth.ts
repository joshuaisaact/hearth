#!/usr/bin/env node

const command = process.argv[2];

if (command === "setup") {
  await import("./setup.js");
} else if (command === "daemon") {
  const { startDaemon, DAEMON_SOCK } = await import("../daemon/server.js");
  const server = startDaemon();
  console.log(`hearth daemon listening on ${DAEMON_SOCK}`);
  process.on("SIGINT", () => { server.close(); process.exit(0); });
  process.on("SIGTERM", () => { server.close(); process.exit(0); });
} else if (command === "shell") {
  const { shellCommand } = await import("./shell.js");
  await shellCommand(process.argv.slice(3));
} else if (command === "lima") {
  const { limaCommand } = await import("./lima.js");
  await limaCommand(process.argv.slice(3));
} else if (command === "pool") {
  const sub = process.argv[3];
  const { isThinPoolAvailable, getThinPoolStatus, destroyThinPool } = await import("../vm/thin.js");
  if (sub === "status") {
    const status = getThinPoolStatus();
    if (!status) {
      console.log("Thin pool: not active");
      console.log("  Run hearth setup as root to enable instant snapshots");
    } else {
      console.log(`Thin pool: active`);
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
  console.log("  shell    Start an interactive shell in a sandbox");
  console.log("  daemon   Start the Hearth daemon (for macOS/multi-process)");
  console.log("  lima     Manage Lima VM for macOS (setup, start, stop, status, teardown)");
  console.log("  pool     Manage dm-thin snapshot pool (status, destroy)");
  process.exit(command ? 1 : 0);
}
