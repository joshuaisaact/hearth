import { join } from "node:path";
import { homedir } from "node:os";
import { existsSync, readdirSync, renameSync, rmSync } from "node:fs";
import { Sandbox } from "../sandbox/sandbox.js";
import { buildEnvironment } from "./build.js";
import { startEnvironment, type StartResult } from "./start.js";
import { readEnvironmentMeta, isEnvironment, type EnvironmentMeta } from "./metadata.js";
import { resolveWorkdir, SNAPSHOT_NAME_RE, type Hearthfile } from "./hearthfile.js";
import { loadDefaults, mergeDefaults } from "./defaults.js";

function snapshotsDir(): string {
  return join(homedir(), ".hearth", "snapshots");
}

export class Environment {
  /**
   * Build an environment from a Hearthfile config.
   * Boots a sandbox, clones the repo, runs setup, and snapshots.
   */
  static async build(config: Hearthfile): Promise<void> {
    const defaults = loadDefaults();
    const merged = mergeDefaults(config, defaults);
    await buildEnvironment({
      hearthfile: merged,
      createSandbox: () => Sandbox.create(),
    });
  }

  /**
   * Start a previously built environment.
   * Restores the snapshot, re-injects credentials, runs start commands.
   */
  static async start(name: string): Promise<{ sandbox: Sandbox } & StartResult> {
    const sandbox = await Sandbox.fromSnapshot(name);
    try {
      const result = await startEnvironment({ name, sandbox });
      return { sandbox, ...result };
    } catch (err) {
      await sandbox.destroy().catch(() => {});
      throw err;
    }
  }

  /**
   * Get an environment — build if it doesn't exist, then start.
   */
  static async get(config: Hearthfile): Promise<{ sandbox: Sandbox } & StartResult> {
    const snapDir = join(snapshotsDir(), config.name);
    if (!existsSync(snapDir)) {
      await Environment.build(config);
    }
    return Environment.start(config.name);
  }

  /**
   * Rebuild an environment — delete existing snapshot and re-build.
   */
  static async rebuild(name: string): Promise<void> {
    const snapDir = join(snapshotsDir(), name);
    const meta = readEnvironmentMeta(snapDir);
    if (!meta) {
      throw new Error(`"${name}" is not an environment or doesn't exist`);
    }
    const backupDir = snapDir + ".bak";
    renameSync(snapDir, backupDir);
    try {
      await Environment.build(meta.hearthfile);
      rmSync(backupDir, { recursive: true, force: true });
    } catch (err) {
      // Restore backup on failure
      if (existsSync(backupDir) && !existsSync(snapDir)) {
        renameSync(backupDir, snapDir);
      }
      throw err;
    }
  }

  /** List all built environments. */
  static list(): EnvironmentMeta[] {
    const dir = snapshotsDir();
    if (!existsSync(dir)) return [];

    return readdirSync(dir)
      .filter((name) => isEnvironment(join(dir, name)))
      .map((name) => readEnvironmentMeta(join(dir, name))!)
      .filter(Boolean);
  }

  /** Remove an environment and its snapshot. */
  static remove(name: string): void {
    if (!SNAPSHOT_NAME_RE.test(name)) {
      throw new Error(`Invalid environment name: "${name}"`);
    }
    const snapDir = join(snapshotsDir(), name);
    if (!existsSync(snapDir)) {
      throw new Error(`Environment "${name}" not found`);
    }
    if (!isEnvironment(join(snapshotsDir(), name))) {
      throw new Error(`"${name}" is a snapshot, not an environment`);
    }
    rmSync(snapDir, { recursive: true, force: true });
  }
}
