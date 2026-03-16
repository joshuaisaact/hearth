import { describe, it, expect, afterEach } from "vitest";
import { existsSync } from "node:fs";
import { Sandbox } from "./sandbox.js";

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

  it("should forward a guest port to the host via vsock", async () => {
    sandbox = await Sandbox.create();

    await sandbox.exec("mkdir -p /tmp/www");
    await sandbox.writeFile("/tmp/www/index.html", "hello hearth!");
    await sandbox.exec("busybox httpd -p 8080 -h /tmp/www");

    const { host, port } = await sandbox.forwardPort(8080);
    expect(host).toBe("127.0.0.1");
    expect(port).toBeGreaterThan(0);

    const resp = await fetch(`http://${host}:${port}/index.html`);
    expect(resp.status).toBe(200);
    expect(await resp.text()).toBe("hello hearth!");
  }, 30000);

  it("should clean up after destroy", async () => {
    sandbox = await Sandbox.create();
    await sandbox.destroy();

    await expect(sandbox.exec("echo test")).rejects.toThrow(
      "Sandbox has been destroyed",
    );
    sandbox = null;
  }, 30000);
});
