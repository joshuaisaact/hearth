/**
 * Example: Running Claude Code inside a Hearth sandbox.
 *
 * This demonstrates the core use case — an AI agent running with full
 * autonomy inside an isolated Firecracker microVM. The agent can:
 * - Read and write any file
 * - Install packages
 * - Run arbitrary commands
 * - Access the internet (for API calls)
 *
 * Nothing it does can affect the host machine.
 *
 * Prerequisites:
 *   1. npx hearth setup (Linux) or hearth lima setup (macOS M3+)
 *   2. node --experimental-strip-types examples/create-claude-snapshot.ts [--daemon]
 *   3. CLAUDE_CODE_OAUTH_TOKEN set in .env (generate with: claude setup-token)
 *
 * Usage:
 *   node --experimental-strip-types examples/claude-in-sandbox.ts
 *   node --experimental-strip-types examples/claude-in-sandbox.ts --daemon  # macOS
 */

import { readFileSync } from "node:fs";
import {
  Sandbox,
  DaemonClient,
  ClaudeSandbox,
  CLAUDE_SNAPSHOT_NAME,
} from "../dist/index.js";

// Load .env
try {
  const lines = readFileSync(".env", "utf-8").trim().split("\n");
  for (const line of lines) {
    if (!line || line.startsWith("#")) continue;
    const i = line.indexOf("=");
    if (i !== -1) process.env[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
} catch {}

const useDaemon = process.argv.includes("--daemon");

async function main() {
  // 1. Restore from the claude-base snapshot
  let sandbox;
  if (useDaemon) {
    const client = new DaemonClient();
    await client.connect();
    console.time("restore");
    sandbox = await client.fromSnapshot(CLAUDE_SNAPSHOT_NAME);
    console.timeEnd("restore");
  } else {
    console.time("restore");
    sandbox = await Sandbox.fromSnapshot(CLAUDE_SNAPSHOT_NAME);
    console.timeEnd("restore");
  }

  await sandbox.enableInternet();

  // 2. Wrap it with ClaudeSandbox
  const claude = ClaudeSandbox.create(sandbox);

  // 3. Give it a task
  console.log("\n=== Asking Claude to write and test code ===\n");

  const result = await claude.prompt(
    "Create a file called hello.js that exports a greet(name) function returning " +
    "'Hello, <name>!'. If run directly, call greet('World') and print the result. " +
    "Then create hello.test.js using Node's built-in test runner, and run the tests.",
    { timeout: 120000 },
  );

  console.log(result.stdout);
  if (result.exitCode !== 0) {
    console.error("Claude exited with code", result.exitCode);
  }

  // 4. Check what Claude created
  console.log("\n=== Results ===\n");

  const files = await sandbox.exec("ls -la /home/agent/");
  console.log(files.stdout);

  const hello = await sandbox.exec("cat /home/agent/hello.js 2>/dev/null || echo '[not created]'");
  console.log("hello.js:\n" + hello.stdout);

  const run = await sandbox.exec("su - agent -s /bin/sh -c 'cd /home/agent && node hello.js' 2>&1");
  console.log("Output:", run.stdout.trim());

  // 5. Clean up
  await claude.destroy();
  console.log("\nDone.");
}

main().catch((err) => {
  console.error("Failed:", err.message);
  process.exit(1);
});
