/**
 * Creates the "claude-base" snapshot with Claude Code pre-installed.
 *
 * This snapshot contains Ubuntu 24.04 + Node.js 22 + Claude Code + a non-root
 * "agent" user with proxy env vars configured. No credentials are baked in —
 * pass CLAUDE_CODE_OAUTH_TOKEN at runtime.
 *
 * Run once:
 *   node --experimental-strip-types examples/create-claude-snapshot.ts
 *
 * On macOS (via Lima daemon):
 *   hearth lima start
 *   node --experimental-strip-types examples/create-claude-snapshot.ts --daemon
 */

import { Sandbox, DaemonClient, CLAUDE_SNAPSHOT_NAME } from "../dist/index.js";

const useDaemon = process.argv.includes("--daemon");

async function main() {
  let sandbox;

  if (useDaemon) {
    const client = new DaemonClient();
    await client.connect();
    sandbox = await client.create();
  } else {
    sandbox = await Sandbox.create();
  }

  await sandbox.enableInternet();
  console.log("Sandbox created with internet");

  await sandbox.exec("useradd -m -s /bin/bash agent 2>/dev/null || true");

  // Ensure localhost resolves (needed for Claude Code OAuth callback)
  await sandbox.exec("grep -q localhost /etc/hosts || echo '127.0.0.1 localhost' >> /etc/hosts");

  console.log("Installing Claude Code...");
  const install = await sandbox.exec(
    "npm install -g @anthropic-ai/claude-code 2>&1 | tail -3",
    { timeout: 180000 },
  );
  console.log(install.stdout.trim());

  // Proxy env vars in .bashrc — no credentials
  await sandbox.writeFile("/home/agent/.bashrc", [
    "export HTTP_PROXY=http://127.0.0.1:3128",
    "export HTTPS_PROXY=http://127.0.0.1:3128",
    "export http_proxy=http://127.0.0.1:3128",
    "export https_proxy=http://127.0.0.1:3128",
  ].join("\n"));
  await sandbox.exec("chown -R agent:agent /home/agent");

  const ver = await sandbox.exec("claude --version 2>&1");
  console.log(`Claude Code: ${ver.stdout.trim()}`);

  console.log(`Snapshotting as "${CLAUDE_SNAPSHOT_NAME}"...`);
  await sandbox.snapshot(CLAUDE_SNAPSHOT_NAME);
  console.log("Done. Use ClaudeSandbox to run prompts.");
}

main().catch((err) => {
  console.error("Failed:", err.message);
  process.exit(1);
});
