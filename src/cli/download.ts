import { createWriteStream, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { get as httpsGet } from "node:https";
import { get as httpGet, type IncomingMessage } from "node:http";

const MAX_REDIRECTS = 10;

/** Download a file from a URL, following redirects. */
export function download(url: string, dest: string, redirectCount = 0): Promise<void> {
  if (redirectCount > MAX_REDIRECTS) {
    return Promise.reject(new Error(`Too many redirects (>${MAX_REDIRECTS}) for ${url}`));
  }

  mkdirSync(dirname(dest), { recursive: true });

  return new Promise((resolve, reject) => {
    const get = url.startsWith("https") ? httpsGet : httpGet;

    get(url, (res: IncomingMessage) => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        download(res.headers.location, dest, redirectCount + 1).then(resolve, reject);
        return;
      }

      if (res.statusCode && res.statusCode >= 400) {
        res.resume();
        reject(new Error(`Download failed: ${res.statusCode} ${url}`));
        return;
      }

      const file = createWriteStream(dest);
      const totalBytes = parseInt(res.headers["content-length"] || "0", 10);
      let downloaded = 0;
      let lastProgressTime = 0;

      res.on("data", (chunk: Buffer) => {
        downloaded += chunk.length;
        if (totalBytes > 0) {
          const now = Date.now();
          if (now - lastProgressTime > 250) {
            lastProgressTime = now;
            const pct = Math.round((downloaded / totalBytes) * 100);
            process.stdout.write(`\r  ${formatBytes(downloaded)} / ${formatBytes(totalBytes)} (${pct}%)`);
          }
        }
      });

      res.pipe(file);
      file.on("finish", () => {
        if (totalBytes > 0) {
          process.stdout.write(`\r  ${formatBytes(totalBytes)} / ${formatBytes(totalBytes)} (100%)\n`);
        }
        file.close(() => resolve());
      });
      file.on("error", (err) => {
        file.close();
        reject(err);
      });
    }).on("error", reject);
  });
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(0)}KB`;
  return `${(bytes / 1024 / 1024).toFixed(1)}MB`;
}

/** Fetch text content from a URL, following redirects. */
export function fetchText(url: string, redirectCount = 0): Promise<string> {
  if (redirectCount > MAX_REDIRECTS) {
    return Promise.reject(new Error(`Too many redirects (>${MAX_REDIRECTS}) for ${url}`));
  }

  return new Promise((resolve, reject) => {
    const get = url.startsWith("https") ? httpsGet : httpGet;

    get(url, (res: IncomingMessage) => {
      if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        res.resume();
        fetchText(res.headers.location, redirectCount + 1).then(resolve, reject);
        return;
      }

      if (res.statusCode && res.statusCode >= 400) {
        res.resume();
        reject(new Error(`Fetch failed: ${res.statusCode} ${url}`));
        return;
      }

      let data = "";
      res.on("data", (chunk) => (data += chunk));
      res.on("end", () => resolve(data));
      res.on("error", reject);
    }).on("error", reject);
  });
}
