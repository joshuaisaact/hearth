/**
 * Helper for running Claude Code inside a Hearth sandbox.
 *
 * Provides a high-level API for creating sandboxes with Claude Code
 * pre-installed and authenticated, using the "claude-base" snapshot.
 *
 * Prerequisites:
 *   - "claude-base" snapshot must exist (run examples/create-claude-snapshot.ts)
 *   - CLAUDE_CODE_OAUTH_TOKEN env var set (generate with: claude setup-token)
 */

import type { ExecResult, SpawnOptions } from "./sandbox/types.js";
import type { SpawnHandle } from "./agent/client.js";

const SNAPSHOT_NAME = "claude-base";
const AGENT_USER = "agent";

interface ClaudeSandboxOptions {
  /** OAuth token. Defaults to process.env.CLAUDE_CODE_OAUTH_TOKEN. */
  token?: string;
}

interface ClaudeExecOptions {
  /** Working directory inside the sandbox. Defaults to /home/agent. */
  cwd?: string;
  /** Extra environment variables. */
  env?: Record<string, string>;
  /** Timeout in milliseconds. Defaults to 300000 (5 minutes). */
  timeout?: number;
  /** Additional CLI flags for Claude Code. */
  flags?: string[];
}

/**
 * A sandbox with Claude Code pre-installed and ready to use.
 *
 * Usage:
 * ```typescript
 * const claude = await ClaudeSandbox.create(sandbox);
 * const result = await claude.prompt("Write a hello world program");
 * console.log(result.stdout);
 * await claude.destroy();
 * ```
 */
export class ClaudeSandbox {
  private sandbox: SandboxLike;
  private token: string;

  private constructor(sandbox: SandboxLike, token: string) {
    this.sandbox = sandbox;
    this.token = token;
  }

  /**
   * Create a ClaudeSandbox from an existing sandbox (Sandbox or RemoteSandbox).
   * The sandbox should be restored from the "claude-base" snapshot with internet enabled.
   */
  static create(sandbox: SandboxLike, opts?: ClaudeSandboxOptions): ClaudeSandbox {
    const token = opts?.token ?? process.env.CLAUDE_CODE_OAUTH_TOKEN;
    if (!token) {
      throw new Error(
        "No Claude Code OAuth token. Set CLAUDE_CODE_OAUTH_TOKEN or pass opts.token.\n" +
        "Generate one with: claude setup-token",
      );
    }
    return new ClaudeSandbox(sandbox, token);
  }

  /** Run a prompt with Claude Code and return the result. */
  async prompt(prompt: string, opts?: ClaudeExecOptions): Promise<ExecResult> {
    const script = this.buildScript(prompt, opts);
    await this.sandbox.writeFile("/tmp/claude-run.sh", script);
    await this.sandbox.exec("chmod +x /tmp/claude-run.sh");

    return this.sandbox.exec(
      `su - ${AGENT_USER} -s /bin/sh -c /tmp/claude-run.sh`,
      { timeout: opts?.timeout ?? 300000 },
    );
  }

  /** Run a prompt with streaming output. */
  async promptStream(prompt: string, opts?: ClaudeExecOptions & SpawnOptions): Promise<SpawnHandle> {
    const script = this.buildScript(prompt, opts);

    await this.sandbox.writeFile("/tmp/claude-run.sh", script);
    await this.sandbox.exec("chmod +x /tmp/claude-run.sh");

    return this.sandbox.spawn(
      `su - ${AGENT_USER} -s /bin/sh -c /tmp/claude-run.sh`,
      { timeout: opts?.timeout ? opts.timeout / 1000 : 300, interactive: true },
    );
  }

  /** Get the underlying sandbox for direct operations. */
  get inner(): SandboxLike {
    return this.sandbox;
  }

  async destroy(): Promise<void> {
    await this.sandbox.destroy();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.destroy();
  }

  private buildScript(prompt: string, opts?: ClaudeExecOptions): string {
    const cwd = opts?.cwd ?? "/home/agent";
    const flags = opts?.flags ?? [];
    const extraEnv = opts?.env ?? {};

    const envLines = [
      `export HOME=/home/${AGENT_USER}`,
      "source $HOME/.bashrc",
      `export CLAUDE_CODE_OAUTH_TOKEN=${this.token}`,
      ...Object.entries(extraEnv).map(([k, v]) => `export ${k}='${v.replace(/'/g, "'\\''")}'`),
    ];

    // Escape the prompt for shell embedding
    const escapedPrompt = prompt.replace(/'/g, "'\\''");

    return [
      "#!/bin/bash",
      ...envLines,
      `cd '${cwd.replace(/'/g, "'\\''")}'`,
      `exec claude -p '${escapedPrompt}' --dangerously-skip-permissions --output-format stream-json --verbose ${flags.join(" ")}`,
    ].join("\n");
  }
}

/** Minimal interface matching both Sandbox and RemoteSandbox. */
interface SandboxLike {
  exec(command: string, opts?: { timeout?: number }): Promise<ExecResult>;
  spawn(command: string, opts?: SpawnOptions): SpawnHandle;
  writeFile(path: string, content: string | Buffer): Promise<void>;
  enableInternet(): Promise<void>;
  destroy(): Promise<void>;
}

export { SNAPSHOT_NAME as CLAUDE_SNAPSHOT_NAME };
