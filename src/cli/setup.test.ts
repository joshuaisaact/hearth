import { describe, it, expect } from "vitest";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { execSync } from "node:child_process";

const HEARTH_DIR = join(homedir(), ".hearth");

describe("hearth setup", () => {
  it("should have installed firecracker", () => {
    const fcPath = join(HEARTH_DIR, "bin", "firecracker");
    expect(existsSync(fcPath)).toBe(true);

    const version = execSync(`${fcPath} --version`, { stdio: "pipe" })
      .toString()
      .trim()
      .split("\n")[0];
    expect(version).toContain("Firecracker v1.15.0");
  });

  it("should have installed the kernel", () => {
    expect(existsSync(join(HEARTH_DIR, "bases", "vmlinux"))).toBe(true);
  });

  it("should have built the rootfs", () => {
    expect(existsSync(join(HEARTH_DIR, "bases", "ubuntu-24.04.ext4"))).toBe(true);
  });

  it("should have built the hearth-agent", () => {
    expect(existsSync(join(HEARTH_DIR, "bin", "hearth-agent"))).toBe(true);
  });

  it("should have created the base snapshot", () => {
    expect(existsSync(join(HEARTH_DIR, "snapshots", "base", "vmstate.snap"))).toBe(true);
    expect(existsSync(join(HEARTH_DIR, "snapshots", "base", "memory.snap"))).toBe(true);
    expect(existsSync(join(HEARTH_DIR, "snapshots", "base", "rootfs.ext4"))).toBe(true);
  });

  it("should be idempotent", () => {
    // Running setup again should succeed and not redownload
    const output = execSync("node dist/cli/hearth.js setup", {
      stdio: "pipe",
      timeout: 10000,
    }).toString();

    expect(output).toContain("already installed");
    expect(output).toContain("already built");
    expect(output).toContain("already created");
  });
});
