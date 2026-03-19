import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { existsSync } from "node:fs";
import { Sandbox } from "../sandbox/sandbox.js";

const hasKvm = existsSync("/dev/kvm");

describe.skipIf(!hasKvm)("Interactive spawn", () => {
  let sandbox: Sandbox;

  beforeAll(async () => {
    sandbox = await Sandbox.create();
  }, 15000);

  afterAll(async () => {
    await sandbox?.destroy();
  });

  it("should receive stdout from a non-interactive spawn", async () => {
    const handle = sandbox.spawn("echo hello", { interactive: false });
    let output = "";
    handle.stdout.on("data", (d: string) => { output += d; });
    const { exitCode } = await handle.wait();
    expect(exitCode).toBe(0);
    expect(output).toContain("hello");
  }, 10000);

  it("should receive stdout from a short-lived interactive spawn", async () => {
    const handle = sandbox.spawn("echo interactive-out", {
      interactive: true,
      cols: 80,
      rows: 24,
    });
    let output = "";
    handle.stdout.on("data", (d: string) => { output += d; });
    const { exitCode } = await handle.wait();
    expect(exitCode).toBe(0);
    expect(output).toContain("interactive-out");
  }, 10000);

  it("should receive stdout from a long-running command that self-exits", async () => {
    // Command produces output then stays alive briefly
    const handle = sandbox.spawn("sh -c 'echo started; sleep 0.5; echo done'", {
      interactive: true,
      cols: 80,
      rows: 24,
    });
    let output = "";
    handle.stdout.on("data", (d: string) => { output += d; });
    const { exitCode } = await handle.wait();
    expect(exitCode).toBe(0);
    expect(output).toContain("started");
    expect(output).toContain("done");
  }, 10000);

  it("should echo stdin back through an interactive process", async () => {
    // cat reads stdin, writes to stdout — PTY echo also mirrors input
    const handle = sandbox.spawn("cat", {
      interactive: true,
      cols: 80,
      rows: 24,
    });
    let output = "";
    handle.stdout.on("data", (d: string) => { output += d; });

    // Give the process time to start, then write
    await new Promise((r) => setTimeout(r, 200));
    handle.stdin.write("hello\n");

    // Wait for output to arrive
    await new Promise((r) => setTimeout(r, 1000));
    expect(output).toContain("hello");

    // Send EOF (Ctrl+D) to make cat exit
    handle.stdin.write("\x04");
    const { exitCode } = await handle.wait();
    expect(exitCode).toBe(0);
  }, 10000);

  it("should receive output from interactive bash and respond to stdin", async () => {
    const handle = sandbox.spawn("/bin/bash", {
      interactive: true,
      cols: 80,
      rows: 24,
    });
    let output = "";
    handle.stdout.on("data", (d: string) => { output += d; });

    // Give bash time to start
    await new Promise((r) => setTimeout(r, 300));

    handle.stdin.write("echo test-from-bash\n");

    // Wait for output
    await new Promise((r) => setTimeout(r, 1000));
    expect(output).toContain("test-from-bash");

    handle.stdin.write("exit\n");
    const { exitCode } = await handle.wait();
    expect(exitCode).toBe(0);
  }, 10000);
});
