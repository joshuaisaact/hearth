import { existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { ResourceError } from "../errors.js";

const HEARTH_DIR = join(homedir(), ".hearth");

export function getVmmPath(): string {
  const bundled = join(HEARTH_DIR, "bin", "flint");
  if (existsSync(bundled)) return bundled;

  throw new ResourceError(
    "Flint VMM binary not found. Run: npx hearth setup",
  );
}

export function getKernelPath(): string {
  const kernel = join(HEARTH_DIR, "bases", "vmlinux");
  if (existsSync(kernel)) return kernel;

  throw new ResourceError("Kernel not found. Run: npx hearth setup");
}

export function getRootfsPath(): string {
  const rootfs = join(HEARTH_DIR, "bases", "ubuntu-24.04.ext4");
  if (existsSync(rootfs)) return rootfs;

  throw new ResourceError("Rootfs not found. Run: npx hearth setup");
}

export function getHearthDir(): string {
  return HEARTH_DIR;
}
