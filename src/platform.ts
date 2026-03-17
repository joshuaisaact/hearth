import { platform, homedir } from "node:os";
import { existsSync, readFileSync } from "node:fs";
import { execSync, execFileSync } from "node:child_process";
import { join } from "node:path";

export type Platform = "linux" | "macos" | "wsl";

export function getPlatform(): Platform {
  const p = platform();
  if (p === "darwin") return "macos";
  if (p === "linux") {
    try {
      const procVersion = readFileSync("/proc/version", "utf-8");
      if (/microsoft|wsl/i.test(procVersion)) return "wsl";
    } catch {}
    return "linux";
  }
  return "linux";
}

/**
 * Detect Apple Silicon chip generation from sysctl.
 * Returns the chip name (e.g. "Apple M4 Pro") or null if not detectable.
 */
export function getAppleChip(): string | null {
  if (getPlatform() !== "macos") return null;
  try {
    return execFileSync("sysctl", ["-n", "machdep.cpu.brand_string"], { stdio: "pipe" })
      .toString()
      .trim();
  } catch {
    return null;
  }
}

/**
 * Check if the current Apple Silicon chip supports nested virtualization.
 * M3+ chips support it; M1 and M2 do not.
 */
export function chipSupportsNestedVirt(): boolean {
  const chip = getAppleChip();
  if (!chip) return false;
  // Match "Apple M3", "Apple M4 Pro", etc. — M3+ supports nested virt
  const match = chip.match(/Apple M(\d+)/);
  if (!match) return false;
  return parseInt(match[1], 10) >= 3;
}

/** Get macOS major version (e.g. 15 for Sequoia). Returns 0 if not macOS. */
export function getMacosVersion(): number {
  if (getPlatform() !== "macos") return 0;
  try {
    const version = execFileSync("sw_vers", ["-productVersion"], { stdio: "pipe" })
      .toString()
      .trim();
    return parseInt(version.split(".")[0], 10);
  } catch {
    return 0;
  }
}

/** Check if Lima CLI is installed. */
export function isLimaInstalled(): boolean {
  try {
    execFileSync("limactl", ["--version"], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

export type LimaStatus = "running" | "stopped" | "not-found";

export interface LimaInstanceInfo {
  status: LimaStatus;
  cpus?: number;
  memory?: number;
}

/** Get the status and details of a Lima instance by name. */
export function getLimaInstanceInfo(name: string): LimaInstanceInfo {
  try {
    const output = execFileSync("limactl", ["list", "--json"], { stdio: "pipe" }).toString();
    // limactl list --json outputs one JSON object per line
    for (const line of output.trim().split("\n")) {
      if (!line) continue;
      try {
        const instance = JSON.parse(line) as Record<string, unknown>;
        if (instance.name === name) {
          const status: LimaStatus = instance.status === "Running" ? "running" : "stopped";
          return {
            status,
            cpus: typeof instance.cpus === "number" ? instance.cpus : undefined,
            memory: typeof instance.memory === "number" ? instance.memory : undefined,
          };
        }
      } catch {
        // skip malformed JSON lines
      }
    }
    return { status: "not-found" };
  } catch {
    return { status: "not-found" };
  }
}

/** Run a command inside the Lima instance via bash -c. Returns stdout. */
export function limaExec(instance: string, command: string): string {
  return execFileSync("limactl", ["shell", instance, "--", "bash", "-c", command], {
    stdio: "pipe",
  }).toString();
}

/** Run a limactl command with an argv array. Inherits stdio. */
export function limactlSync(args: string[]): void {
  execFileSync("limactl", args, { stdio: "inherit" });
}
