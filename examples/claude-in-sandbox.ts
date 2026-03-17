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
 * - npx hearth setup (already done)
 * - Claude Code logged in on the host (the auth credentials are copied into the sandbox)
 *
 * Usage:
 *   node --experimental-strip-types examples/claude-in-sandbox.ts
 */

import { Sandbox } from "../dist/index.js";
import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

async function main() {
  // Check for Claude Code credentials on the host
  const claudeDir = join(homedir(), ".claude");
  const credsFile = join(claudeDir, ".credentials.json");
  if (!existsSync(credsFile)) {
    console.error("Claude Code not logged in. Run 'claude' first to authenticate.");
    process.exit(1);
  }

  console.log("=== Claude Code in Hearth Sandbox ===\n");

  // 1. Create sandbox
  console.log("1. Creating sandbox...");
  const t0 = performance.now();
  const sandbox = await Sandbox.create();
  console.log(`   Done in ${(performance.now() - t0).toFixed(0)}ms\n`);

  // 2. Enable internet (needed for Anthropic API calls)
  console.log("2. Enabling internet access...");
  await sandbox.enableInternet();
  console.log("   Done\n");

  // 3. Copy Claude Code credentials into the sandbox
  console.log("3. Copying Claude credentials...");
  await sandbox.exec("mkdir -p /root/.claude");
  const creds = await import("node:fs").then((fs) =>
    fs.readFileSync(credsFile, "utf-8"),
  );
  await sandbox.writeFile("/root/.claude/.credentials.json", creds);
  // Copy settings too if they exist
  const settingsFile = join(claudeDir, "settings.json");
  if (existsSync(settingsFile)) {
    const settings = await import("node:fs").then((fs) =>
      fs.readFileSync(settingsFile, "utf-8"),
    );
    await sandbox.writeFile("/root/.claude/settings.json", settings);
  }
  console.log("   Done\n");

  // 4. Create a non-root user (Claude Code refuses --dangerously-skip-permissions as root)
  console.log("4. Creating sandbox user...");
  await sandbox.exec("useradd -m -s /bin/bash sandboxuser");
  console.log("   Done\n");

  // 5. Install Claude Code inside the sandbox
  console.log("5. Installing Claude Code...");
  const t1 = performance.now();
  const install = await sandbox.exec(
    "npm install -g @anthropic-ai/claude-code 2>&1 | tail -3",
    { timeout: 180000 },
  );
  console.log(`   ${install.stdout.trim()}`);
  console.log(`   Done in ${((performance.now() - t1) / 1000).toFixed(1)}s\n`);

  if (install.exitCode !== 0) {
    console.error("   Failed to install Claude Code");
    console.error(install.stderr);
    await sandbox.destroy();
    process.exit(1);
  }

  // 6. Copy credentials for the sandbox user and verify
  await sandbox.exec("mkdir -p /home/sandboxuser/.claude");
  await sandbox.exec("cp /root/.claude/.credentials.json /home/sandboxuser/.claude/.credentials.json");
  await sandbox.exec("cp /root/.claude/settings.json /home/sandboxuser/.claude/settings.json 2>/dev/null || true");
  await sandbox.exec("chown -R sandboxuser:sandboxuser /home/sandboxuser/.claude");
  const claudeVer = await sandbox.exec("su - sandboxuser -c 'claude --version' 2>&1 || echo NOT_FOUND");
  console.log(`   Claude: ${claudeVer.stdout.trim()}\n`);

  // 7. Create a workspace with a simple task
  console.log("7. Setting up workspace...");
  await sandbox.exec("mkdir -p /workspace && chown sandboxuser:sandboxuser /workspace");
  await sandbox.writeFile(
    "/workspace/task.md",
    [
      "# Task",
      "",
      "Create a file called `hello.js` that:",
      "1. Defines a function `greet(name)` that returns `Hello, ${name}!`",
      "2. Exports the function",
      "3. If run directly, calls greet('World') and prints the result",
      "",
      "Then create a test file `hello.test.js` that tests the greet function.",
      "Run the test and make sure it passes.",
    ].join("\n"),
  );
  console.log("   Task written to /workspace/task.md\n");

  // 8. Run Claude Code with --dangerously-skip-permissions as non-root user
  console.log("8. Running Claude Code (streaming output)...\n");
  console.log("--- Claude Code output ---");

  // Run as sandboxuser with proxy env vars preserved.
  // We write a wrapper script to avoid shell quoting issues with su -c.
  await sandbox.writeFile("/tmp/run-claude.sh", [
    "#!/bin/bash",
    "export HOME=/home/sandboxuser",
    "export HTTP_PROXY=http://127.0.0.1:3128",
    "export HTTPS_PROXY=http://127.0.0.1:3128",
    "export http_proxy=http://127.0.0.1:3128",
    "export https_proxy=http://127.0.0.1:3128",
    "cd /workspace",
    'claude -p "Read /workspace/task.md and complete the task. Work in /workspace." --dangerously-skip-permissions',
  ].join("\n"));
  await sandbox.exec("chmod +x /tmp/run-claude.sh");

  const proc = sandbox.spawn(
    "su - sandboxuser -c /tmp/run-claude.sh",
    { timeout: 300 },
  );

  proc.stdout.on("data", (chunk: string) => process.stdout.write(chunk));
  proc.stderr.on("data", (chunk: string) => process.stderr.write(chunk));

  const { exitCode } = await proc.wait();
  console.log("\n--- End output ---\n");
  console.log(`   Exit code: ${exitCode}\n`);

  // 9. Check what Claude created
  console.log("9. Checking results...");
  const files = await sandbox.exec("ls -la /workspace/");
  console.log(`   Files:\n${files.stdout}`);

  const hello = await sandbox.exec("cat /workspace/hello.js 2>/dev/null || echo '[not created]'");
  console.log(`   hello.js:\n${hello.stdout}`);

  const test = await sandbox.exec("cat /workspace/hello.test.js 2>/dev/null || echo '[not created]'");
  console.log(`   hello.test.js:\n${test.stdout}`);

  // 10. Run the code Claude wrote
  console.log("10. Running hello.js...");
  const run = await sandbox.exec("cd /workspace && node hello.js 2>&1 || true");
  console.log(`   Output: ${run.stdout.trim()}\n`);

  // 11. Download the results
  console.log("11. Downloading workspace...");
  await sandbox.download("/workspace", "/tmp/hearth-claude-output");
  console.log("    Saved to /tmp/hearth-claude-output/\n");

  // 12. Clean up
  await sandbox.destroy();
  console.log("Done. Sandbox destroyed.");
}

main().catch((err) => {
  console.error("Failed:", err.message);
  process.exit(1);
});
