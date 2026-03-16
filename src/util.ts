import { existsSync } from "node:fs";

export function waitForFile(path: string, timeoutMs: number): Promise<void> {
  return new Promise((resolve, reject) => {
    const start = Date.now();
    const check = () => {
      if (existsSync(path)) {
        resolve();
      } else if (Date.now() - start > timeoutMs) {
        reject(new Error(`Timed out waiting for: ${path}`));
      } else {
        setTimeout(check, 10);
      }
    };
    check();
  });
}

export function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}
