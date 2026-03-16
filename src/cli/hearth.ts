#!/usr/bin/env node

const command = process.argv[2];

if (command === "setup") {
  await import("./setup.js");
} else {
  console.log("Usage: hearth <command>");
  console.log("");
  console.log("Commands:");
  console.log("  setup    Download and configure all dependencies");
  process.exit(command ? 1 : 0);
}
