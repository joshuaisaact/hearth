import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { existsSync } from "node:fs";
import net from "node:net";
import { startDaemon, DAEMON_SOCK, type DaemonServers } from "./server.js";
import { DaemonClient } from "./client.js";

const hasKvm = existsSync("/dev/kvm");

describe.skipIf(!hasKvm)("Daemon", () => {
  let servers: DaemonServers;
  let client: DaemonClient;

  beforeAll(async () => {
    servers = startDaemon();
    client = new DaemonClient();
    // Wait for server to be listening
    await new Promise<void>((resolve) => {
      const check = () => {
        if (existsSync(DAEMON_SOCK)) resolve();
        else setTimeout(check, 20);
      };
      check();
    });
    await client.connect(DAEMON_SOCK);
  }, 10000);

  afterAll(() => {
    client.close();
    servers.close();
  });

  it("should create a sandbox and exec via daemon", async () => {
    const sandbox = await client.create();
    const result = await sandbox.exec("echo daemon works");

    expect(result.stdout).toBe("daemon works\n");
    expect(result.exitCode).toBe(0);

    await sandbox.destroy();
  }, 30000);

  it("should write and read files via daemon", async () => {
    const sandbox = await client.create();

    await sandbox.writeFile("/tmp/daemon-test.txt", "hello daemon");
    const content = await sandbox.readFile("/tmp/daemon-test.txt");
    expect(content).toBe("hello daemon");

    await sandbox.destroy();
  }, 30000);

  it("should forward ports via daemon", async () => {
    const sandbox = await client.create();

    await sandbox.exec("mkdir -p /tmp/www");
    await sandbox.writeFile("/tmp/www/index.html", "daemon port forward");
    await sandbox.exec("busybox httpd -p 8080 -h /tmp/www");

    const { host, port } = await sandbox.forwardPort(8080);
    const resp = await fetch(`http://${host}:${port}/index.html`);
    expect(await resp.text()).toBe("daemon port forward");

    await sandbox.destroy();
  }, 30000);

  it("should list and manage snapshots via daemon", async () => {
    const snapshots = await client.listSnapshots();
    expect(Array.isArray(snapshots)).toBe(true);
  }, 5000);
});
