import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { HearthError, isPermissionError } from "../errors.js";

const MAX_PAGES_TO_SCAN = 10000;
const MAX_SLEEP_MS = 1000;

const KSM_BASE = "/sys/kernel/mm/ksm";
/** @internal Exported for testing only. */
export const VALID_KSM_FILES = /^[a-z_]+$/;

export class KsmError extends HearthError {
  constructor(message: string, options?: ErrorOptions) {
    super(message, options);
    this.name = "KsmError";
  }
}

export interface KsmStats {
  /** Number of page slots shared (deduplicated originals). */
  pagesShared: number;
  /** Number of pages that are sharing (pointing to a shared slot). */
  pagesSharing: number;
  /** Number of pages unique but repeatedly checked. */
  pagesUnshared: number;
  /** Number of full scans KSM has completed. */
  fullScans: number;
  /** Whether KSM is currently enabled. */
  enabled: boolean;
  /** Bytes saved via page deduplication (pagesSharing * pageSize). */
  bytesSaved: number;
  /** Human-readable memory savings string. */
  memorySaved: string;
}

export interface KsmTuneOptions {
  /** Pages to scan per sleep cycle. Default: 1000. */
  pagesToScan?: number;
  /** Milliseconds to sleep between scan cycles. Default: 20. */
  sleepMs?: number;
}

function validateName(name: string): void {
  if (!VALID_KSM_FILES.test(name)) {
    throw new KsmError(`Invalid KSM parameter name: ${name}`);
  }
}

function shellQuote(s: string): string {
  return `'${s.replace(/'/g, "'\\''")}'`;
}

function wrapPermissionError(err: unknown, path: string, value?: string): never {
  const hint = value !== undefined
    ? `echo ${shellQuote(value)} | sudo tee ${shellQuote(path)}`
    : `cat ${shellQuote(path)}`;
  throw new KsmError(
    `KSM requires root privileges. Run hearth setup with sudo, or manually: ${hint}`,
    { cause: err },
  );
}

function readKsmFile(name: string): string {
  validateName(name);
  const path = `${KSM_BASE}/${name}`;
  try {
    return readFileSync(path, "utf-8").trim();
  } catch (err) {
    if (isPermissionError(err)) {
      wrapPermissionError(err, path);
    }
    throw err;
  }
}

function writeKsmFile(name: string, value: string): void {
  validateName(name);
  const path = `${KSM_BASE}/${name}`;
  try {
    writeFileSync(path, value);
  } catch (err) {
    if (isPermissionError(err)) {
      wrapPermissionError(err, path, value);
    }
    throw err;
  }
}

function formatBytes(bytes: number): string {
  if (bytes >= 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024 * 1024)).toFixed(1)} GB`;
  }
  if (bytes >= 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(0)} MB`;
  }
  if (bytes >= 1024) {
    return `${(bytes / 1024).toFixed(0)} KB`;
  }
  return `${bytes} B`;
}

/**
 * Enable KSM (Kernel Same-page Merging).
 * Idempotent — no-op if already enabled.
 */
export function enableKsm(): void {
  const current = readKsmFile("run");
  if (current === "1") return;
  writeKsmFile("run", "1");
}

function parseKsmInt(name: string): number {
  const raw = readKsmFile(name);
  const value = parseInt(raw, 10);
  if (Number.isNaN(value)) {
    throw new KsmError(`Failed to parse KSM ${name}: "${raw}"`);
  }
  return value;
}

/** System page size in bytes. 4096 on x86_64, may be 65536 on aarch64. */
let pageSize: number | null = null;
function getPageSize(): number {
  if (pageSize === null) {
    try {
      const parsed = parseInt(execFileSync("getconf", ["PAGE_SIZE"], { stdio: "pipe" }).toString().trim(), 10);
      pageSize = Number.isNaN(parsed) ? 4096 : parsed;
    } catch {
      pageSize = 4096;
    }
  }
  return pageSize;
}

/**
 * Read current KSM statistics.
 */
export function getKsmStats(): KsmStats {
  const enabled = readKsmFile("run") === "1";
  const pagesShared = parseKsmInt("pages_shared");
  const pagesSharing = parseKsmInt("pages_sharing");
  const pagesUnshared = parseKsmInt("pages_unshared");
  const fullScans = parseKsmInt("full_scans");
  const bytesSaved = pagesSharing * getPageSize();

  return {
    pagesShared,
    pagesSharing,
    pagesUnshared,
    fullScans,
    enabled,
    bytesSaved,
    memorySaved: formatBytes(bytesSaved),
  };
}

/**
 * Tune KSM aggressiveness.
 * Default: pages_to_scan=1000, sleep_millisecs=20
 * (more aggressive than kernel defaults, reasonable for a VM host).
 */
export function tuneKsm(opts: KsmTuneOptions = {}): void {
  const { pagesToScan = 1000, sleepMs = 20 } = opts;
  if (!Number.isInteger(pagesToScan) || pagesToScan < 1 || pagesToScan > MAX_PAGES_TO_SCAN) {
    throw new KsmError(`pagesToScan must be an integer between 1 and ${MAX_PAGES_TO_SCAN}, got ${pagesToScan}`);
  }
  if (!Number.isInteger(sleepMs) || sleepMs < 1 || sleepMs > MAX_SLEEP_MS) {
    throw new KsmError(`sleepMs must be an integer between 1 and ${MAX_SLEEP_MS}, got ${sleepMs}`);
  }
  writeKsmFile("pages_to_scan", String(pagesToScan));
  writeKsmFile("sleep_millisecs", String(sleepMs));
}

/**
 * Enable and tune KSM in one call. Returns true if successful,
 * false on any error (permission, missing sysfs, etc.). Never throws.
 */
export function initKsm(): boolean {
  try {
    enableKsm();
    tuneKsm();
    return true;
  } catch {
    return false;
  }
}
