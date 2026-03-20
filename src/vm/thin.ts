/**
 * Device-mapper thin provisioning for instant CoW snapshots.
 *
 * Creates a thin pool backed by a sparse loopback file. Each sandbox gets
 * a thin snapshot of the base volume — block-level CoW means creation is
 * a metadata operation (~1ms) regardless of rootfs size.
 *
 * Falls back gracefully: if dm-thin isn't available (no root, missing
 * kernel module), callers use the existing file-copy approach.
 */

import { existsSync, statSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { getHearthDir } from "./binary.js";

const POOL_NAME = "hearth-pool";
const DATA_FILE = "thin-data.img";
const META_FILE = "thin-meta.img";
const BASE_VOLUME_ID = 0;
const SECTOR_SIZE = 512;

// Default sizes (sparse — only allocate on write)
const DEFAULT_DATA_SIZE_GB = 20;
const DEFAULT_META_SIZE_MB = 128;

/** Check if dm-thin is available and the pool exists. */
export function isThinPoolAvailable(): boolean {
  try {
    execFileSync("dmsetup", ["status", POOL_NAME], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

/** Check if the system supports dm-thin (has dmsetup and device-mapper). */
export function canUseThinPool(): boolean {
  try {
    execFileSync("dmsetup", ["version"], { stdio: "pipe" });
    // Check if we have root (needed for dmsetup operations)
    return process.getuid?.() === 0;
  } catch {
    return false;
  }
}

/** Attach loopback devices and create the thin-pool dm target. Detaches loops on failure. */
function attachPool(dataFile: string, metaFile: string): boolean {
  let dataLoop = "";
  let metaLoop = "";

  try {
    dataLoop = execFileSync("losetup", ["--find", "--show", dataFile], { stdio: "pipe" })
      .toString().trim();
    metaLoop = execFileSync("losetup", ["--find", "--show", metaFile], { stdio: "pipe" })
      .toString().trim();

    const dataSectors = execFileSync("blockdev", ["--getsz", dataLoop], { stdio: "pipe" })
      .toString().trim();

    execFileSync("dmsetup", [
      "create", POOL_NAME,
      "--table", `0 ${dataSectors} thin-pool ${metaLoop} ${dataLoop} 128 0`,
    ], { stdio: "pipe" });

    return true;
  } catch {
    if (dataLoop) try { execFileSync("losetup", ["-d", dataLoop], { stdio: "pipe" }); } catch {}
    if (metaLoop) try { execFileSync("losetup", ["-d", metaLoop], { stdio: "pipe" }); } catch {}
    return false;
  }
}

/**
 * Re-activate an existing thin pool after reboot.
 * The data/meta files persist on disk but loopback devices are ephemeral.
 * Returns true if the pool was successfully activated.
 */
export function activateThinPool(): boolean {
  if (!canUseThinPool()) return false;
  if (isThinPoolAvailable()) return true;

  const hearthDir = getHearthDir();
  const dataFile = join(hearthDir, DATA_FILE);
  const metaFile = join(hearthDir, META_FILE);

  if (!existsSync(dataFile) || !existsSync(metaFile)) return false;

  return attachPool(dataFile, metaFile);
}

/** Create the thin pool and import the base rootfs. Returns true on success. */
export function setupThinPool(rootfsPath: string): boolean {
  if (!canUseThinPool()) return false;

  const hearthDir = getHearthDir();
  const dataFile = join(hearthDir, DATA_FILE);
  const metaFile = join(hearthDir, META_FILE);

  try {
    if (isThinPoolAvailable()) {
      return true; // Already set up
    }

    // Create sparse data and metadata files
    if (!existsSync(dataFile)) {
      execFileSync("truncate", ["-s", `${DEFAULT_DATA_SIZE_GB}G`, dataFile], { stdio: "pipe" });
    }
    if (!existsSync(metaFile)) {
      execFileSync("truncate", ["-s", `${DEFAULT_META_SIZE_MB}M`, metaFile], { stdio: "pipe" });
    }

    // Zero first block of metadata (required for fresh thin-pool, conv=notrunc preserves file size)
    execFileSync("dd", ["if=/dev/zero", `of=${metaFile}`, "bs=4096", "count=1", "conv=notrunc"], { stdio: "pipe" });

    // Attach loopback devices and create the pool
    if (!attachPool(dataFile, metaFile)) {
      return false;
    }

    // Create base thin volume (ID 0)
    execFileSync("dmsetup", ["message", POOL_NAME, "0", `create_thin ${BASE_VOLUME_ID}`], { stdio: "pipe" });

    // Get rootfs size in sectors
    const rootfsSize = statSync(rootfsPath).size;
    const rootfsSectors = Math.ceil(rootfsSize / SECTOR_SIZE);

    // Activate base volume
    execFileSync("dmsetup", [
      "create", `${POOL_NAME}-base`,
      "--table", `0 ${rootfsSectors} thin /dev/mapper/${POOL_NAME} ${BASE_VOLUME_ID}`,
    ], { stdio: "pipe" });

    // Copy rootfs into the thin volume
    execFileSync("dd", [
      `if=${rootfsPath}`,
      `of=/dev/mapper/${POOL_NAME}-base`,
      "bs=1M",
    ], { stdio: "pipe" });

    // Deactivate base volume (we'll snapshot from it, not use it directly)
    execFileSync("dmsetup", ["remove", `${POOL_NAME}-base`], { stdio: "pipe" });

    return true;
  } catch {
    // Clean up on failure
    try { execFileSync("dmsetup", ["remove", `${POOL_NAME}-base`], { stdio: "pipe" }); } catch {}
    try { execFileSync("dmsetup", ["remove", POOL_NAME], { stdio: "pipe" }); } catch {}
    return false;
  }
}

/** Get the next available thin ID by scanning existing thin devices. */
function allocateThinId(): number {
  let maxId = 0;
  try {
    const output = execFileSync("dmsetup", ["table", "--target", "thin"], { stdio: "pipe" }).toString();
    for (const line of output.trim().split("\n")) {
      // Each line: "devname: 0 <sectors> thin <pool_dev> <thin_id>"
      const parts = line.split(/\s+/);
      const id = parseInt(parts[parts.length - 1], 10);
      if (!isNaN(id) && id > maxId) maxId = id;
    }
  } catch {}
  // Also account for the base volume (ID 0)
  return Math.max(maxId, BASE_VOLUME_ID) + 1;
}

/** Create a thin snapshot for a sandbox. Returns the device path, or null if dm-thin unavailable. */
export function createThinSnapshot(sandboxId: string): string | null {
  if (!isThinPoolAvailable()) return null;

  const thinId = allocateThinId();
  const devName = `${POOL_NAME}-sb-${sandboxId}`;

  try {
    // Create thin snapshot of the base volume
    execFileSync("dmsetup", [
      "message", POOL_NAME, "0", `create_snap ${thinId} ${BASE_VOLUME_ID}`,
    ], { stdio: "pipe" });

    // Get rootfs sector count from the base
    const rootfsSectors = getRootfsSectors();

    // Activate the snapshot as a device
    execFileSync("dmsetup", [
      "create", devName,
      "--table", `0 ${rootfsSectors} thin /dev/mapper/${POOL_NAME} ${thinId}`,
    ], { stdio: "pipe" });

    return `/dev/mapper/${devName}`;
  } catch {
    // Clean up on failure
    try { execFileSync("dmsetup", ["remove", devName], { stdio: "pipe" }); } catch {}
    try { execFileSync("dmsetup", ["message", POOL_NAME, "0", `delete ${thinId}`], { stdio: "pipe" }); } catch {}
    return null;
  }
}

/** Create a thin snapshot from a user snapshot's thin volume. */
export function createThinSnapshotFrom(sandboxId: string, sourceThinId: number): string | null {
  if (!isThinPoolAvailable()) return null;

  const thinId = allocateThinId();
  const devName = `${POOL_NAME}-sb-${sandboxId}`;

  try {
    execFileSync("dmsetup", [
      "message", POOL_NAME, "0", `create_snap ${thinId} ${sourceThinId}`,
    ], { stdio: "pipe" });

    const rootfsSectors = getRootfsSectors();

    execFileSync("dmsetup", [
      "create", devName,
      "--table", `0 ${rootfsSectors} thin /dev/mapper/${POOL_NAME} ${thinId}`,
    ], { stdio: "pipe" });

    return `/dev/mapper/${devName}`;
  } catch {
    try { execFileSync("dmsetup", ["remove", devName], { stdio: "pipe" }); } catch {}
    try { execFileSync("dmsetup", ["message", POOL_NAME, "0", `delete ${thinId}`], { stdio: "pipe" }); } catch {}
    return null;
  }
}

/** Read the thin ID from an activated dm-thin device. */
function readThinId(devName: string): number | null {
  try {
    const table = execFileSync("dmsetup", ["table", devName], { stdio: "pipe" }).toString();
    const id = parseInt(table.split(" ").pop() ?? "", 10);
    return isNaN(id) ? null : id;
  } catch {
    return null;
  }
}

/** Get the thin ID for a sandbox's thin device. */
export function getThinId(sandboxId: string): number | null {
  return readThinId(`${POOL_NAME}-sb-${sandboxId}`);
}

/** Destroy a thin snapshot. */
export function destroyThinSnapshot(sandboxId: string): void {
  const devName = `${POOL_NAME}-sb-${sandboxId}`;
  try {
    const thinId = readThinId(devName);
    execFileSync("dmsetup", ["remove", devName], { stdio: "pipe" });
    if (thinId !== null) {
      execFileSync("dmsetup", ["message", POOL_NAME, "0", `delete ${thinId}`], { stdio: "pipe" });
    }
  } catch {}
}

/**
 * Create a persistent thin snapshot for a user snapshot (checkpoint/snapshot).
 * Activated under hearth-pool-snap-<name> so allocateThinId() sees it.
 * Returns the thin ID, or null on failure.
 */
export function createSnapshotThin(snapshotName: string, sourceThinId: number): number | null {
  if (!isThinPoolAvailable()) return null;

  const thinId = allocateThinId();
  const devName = `${POOL_NAME}-snap-${snapshotName}`;

  try {
    execFileSync("dmsetup", [
      "message", POOL_NAME, "0", `create_snap ${thinId} ${sourceThinId}`,
    ], { stdio: "pipe" });

    const rootfsSectors = getRootfsSectors();
    execFileSync("dmsetup", [
      "create", devName,
      "--table", `0 ${rootfsSectors} thin /dev/mapper/${POOL_NAME} ${thinId}`,
    ], { stdio: "pipe" });

    return thinId;
  } catch {
    try { execFileSync("dmsetup", ["remove", devName], { stdio: "pipe" }); } catch {}
    try { execFileSync("dmsetup", ["message", POOL_NAME, "0", `delete ${thinId}`], { stdio: "pipe" }); } catch {}
    return null;
  }
}

/** Destroy a persistent snapshot thin device. */
export function destroySnapshotThin(snapshotName: string): void {
  const devName = `${POOL_NAME}-snap-${snapshotName}`;
  try {
    const thinId = readThinId(devName);
    execFileSync("dmsetup", ["remove", devName], { stdio: "pipe" });
    if (thinId !== null) {
      execFileSync("dmsetup", ["message", POOL_NAME, "0", `delete ${thinId}`], { stdio: "pipe" });
    }
  } catch {}
}

/** Get thin pool status. Returns null if pool doesn't exist. */
export function getThinPoolStatus(): { usedDataPercent: number; usedMetaPercent: number; thinCount: number } | null {
  if (!isThinPoolAvailable()) return null;

  try {
    const status = execFileSync("dmsetup", ["status", POOL_NAME], { stdio: "pipe" }).toString();
    // Format: "0 <len> thin-pool <transaction> <used_meta>/<total_meta> <used_data>/<total_data> - ..."
    const parts = status.split(" ");
    const [usedMeta, totalMeta] = parts[4].split("/").map(Number);
    const [usedData, totalData] = parts[5].split("/").map(Number);

    // Count active thin devices
    const ls = execFileSync("dmsetup", ["ls", "--target", "thin"], { stdio: "pipe" }).toString();
    const thinCount = ls.trim().split("\n").filter(l => l.includes(POOL_NAME)).length;

    return {
      usedDataPercent: Math.round((usedData / totalData) * 100),
      usedMetaPercent: Math.round((usedMeta / totalMeta) * 100),
      thinCount,
    };
  } catch {
    return null;
  }
}

/** Tear down the thin pool completely. */
export function destroyThinPool(): void {
  try {
    // Remove all thin devices first
    const ls = execFileSync("dmsetup", ["ls", "--target", "thin"], { stdio: "pipe" }).toString();
    for (const line of ls.trim().split("\n")) {
      const name = line.split("\t")[0];
      if (name?.includes(POOL_NAME)) {
        try { execFileSync("dmsetup", ["remove", name], { stdio: "pipe" }); } catch {}
      }
    }

    // Remove the pool
    execFileSync("dmsetup", ["remove", POOL_NAME], { stdio: "pipe" });

    // Detach loopback devices
    const hearthDir = getHearthDir();
    for (const file of [DATA_FILE, META_FILE]) {
      try {
        const output = execFileSync("losetup", ["-j", join(hearthDir, file)], { stdio: "pipe" }).toString();
        const loopDev = output.split(":")[0];
        if (loopDev) {
          execFileSync("losetup", ["-d", loopDev], { stdio: "pipe" });
        }
      } catch {}
    }
  } catch {}
}

function getRootfsSectors(): number {
  // Read from the base volume's table to get the sector count
  try {
    // Try reading from a stored value first
    const rootfsPath = join(getHearthDir(), "bases", "ubuntu-24.04.ext4");
    const rootfsSize = statSync(rootfsPath).size;
    return Math.ceil(rootfsSize / SECTOR_SIZE);
  } catch {
    // Fallback: 2GB / 512 = 4194304 sectors
    return 4194304;
  }
}
