export interface SnapshotInfo {
  id: string;
  createdAt: string;
}

export interface ExecResult {
  stdout: string;
  stderr: string;
  exitCode: number;
}

export interface CommandOptions {
  cwd?: string;
  env?: Record<string, string>;
  timeout?: number;
}

export type ExecOptions = CommandOptions;
export type SpawnOptions = CommandOptions;
