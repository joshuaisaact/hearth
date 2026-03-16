import { describe, it, expect, afterEach } from "vitest";
import { existsSync } from "node:fs";
import { Sandbox } from "./sandbox.js";

// These tests require KVM — skip if not available
const hasKvm = existsSync("/dev/kvm");

describe.skipIf(!hasKvm)("Sandbox", () => {
  let sandbox: Sandbox | null = null;

  afterEach(async () => {
    if (sandbox) {
      await sandbox.destroy();
      sandbox = null;
    }
  });

  it("should create a sandbox and exec a command", async () => {
    sandbox = await Sandbox.create();
    const result = await sandbox.exec("echo hello world");

    expect(result.stdout).toBe("hello world\n");
    expect(result.stderr).toBe("");
    expect(result.exitCode).toBe(0);
  }, 30000);

  it("should handle non-zero exit codes", async () => {
    sandbox = await Sandbox.create();
    const result = await sandbox.exec("exit 42");

    expect(result.exitCode).toBe(42);
  }, 30000);

  it("should capture stderr", async () => {
    sandbox = await Sandbox.create();
    const result = await sandbox.exec("echo error >&2");

    expect(result.stderr).toBe("error\n");
    expect(result.exitCode).toBe(0);
  }, 30000);

  it("should write and read files", async () => {
    sandbox = await Sandbox.create();

    await sandbox.writeFile("/tmp/hearth-test.txt", "test content 123");
    const content = await sandbox.readFile("/tmp/hearth-test.txt");

    expect(content).toBe("test content 123");
  }, 30000);

  it("should run commands with env vars", async () => {
    sandbox = await Sandbox.create();
    const result = await sandbox.exec("echo $MY_VAR", {
      env: { MY_VAR: "hello" },
    });

    expect(result.stdout).toBe("hello\n");
  }, 30000);

  it("should run commands with cwd", async () => {
    sandbox = await Sandbox.create();
    const result = await sandbox.exec("pwd", { cwd: "/tmp" });

    expect(result.stdout).toBe("/tmp\n");
  }, 30000);

  it("should clean up after destroy", async () => {
    sandbox = await Sandbox.create();
    await sandbox.destroy();

    await expect(sandbox.exec("echo test")).rejects.toThrow(
      "Sandbox has been destroyed",
    );
    sandbox = null; // Prevent double-destroy in afterEach
  }, 30000);
});
