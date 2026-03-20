import { describe, it, expect } from "vitest";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { parseHearthfile, findHearthfile, defaultWorkdir, resolveWorkdir } from "./hearthfile.js";

const TMP = join(tmpdir(), "hearth-test-hearthfile");

function writeTmp(filename: string, content: string): string {
  mkdirSync(TMP, { recursive: true });
  const path = join(TMP, filename);
  writeFileSync(path, content);
  return path;
}

describe("parseHearthfile", () => {
  it("parses a minimal Hearthfile", () => {
    const path = writeTmp("minimal.toml", `name = "my-api"\n`);
    const hf = parseHearthfile(path);
    expect(hf.name).toBe("my-api");
    expect(hf.repo).toBeUndefined();
    expect(hf.setup).toBeUndefined();
  });

  it("parses a full Hearthfile", () => {
    const path = writeTmp("full.toml", `
name = "my-api"
repo = "github.com/user/my-api"
branch = "main"
workdir = "/workspace"
setup = ["npm install", "npm run build"]
start = ["npm run dev"]
ports = [3000, 5173]
ready = "http://localhost:3000/health"
github_token_env = "MY_TOKEN"

[[files]]
from = "~/.gitconfig"
to = "/home/agent/.gitconfig"

[[files]]
from = "~/.ssh/id_ed25519"
to = "/home/agent/.ssh/id_ed25519"
mode = "0600"
`);
    const hf = parseHearthfile(path);
    expect(hf.name).toBe("my-api");
    expect(hf.repo).toBe("github.com/user/my-api");
    expect(hf.branch).toBe("main");
    expect(hf.workdir).toBe("/workspace");
    expect(hf.setup).toEqual(["npm install", "npm run build"]);
    expect(hf.start).toEqual(["npm run dev"]);
    expect(hf.ports).toEqual([3000, 5173]);
    expect(hf.ready).toBe("http://localhost:3000/health");
    expect(hf.github_token_env).toBe("MY_TOKEN");
    expect(hf.files).toHaveLength(2);
    expect(hf.files![0].from).toBe("~/.gitconfig");
    expect(hf.files![1].mode).toBe("0600");
  });

  it("rejects missing name", () => {
    const path = writeTmp("no-name.toml", `repo = "github.com/user/repo"\n`);
    expect(() => parseHearthfile(path)).toThrow("'name' is required");
  });

  it("rejects invalid name characters", () => {
    const path = writeTmp("bad-name.toml", `name = "my api!"\n`);
    expect(() => parseHearthfile(path)).toThrow("'name' must match");
  });

  it("rejects invalid port numbers", () => {
    const path = writeTmp("bad-port.toml", `name = "test"\nports = [99999]\n`);
    expect(() => parseHearthfile(path)).toThrow("invalid port");
  });

  it("rejects non-string setup entries", () => {
    const path = writeTmp("bad-setup.toml", `name = "test"\nsetup = [123]\n`);
    expect(() => parseHearthfile(path)).toThrow("'setup' must be an array of strings");
  });
});

describe("findHearthfile", () => {
  it("finds Hearthfile.toml in a directory", () => {
    writeTmp("Hearthfile.toml", `name = "test"\n`);
    expect(findHearthfile(TMP)).toBe(join(TMP, "Hearthfile.toml"));
  });

  it("returns null when no Hearthfile exists", () => {
    const emptyDir = join(TMP, "empty");
    mkdirSync(emptyDir, { recursive: true });
    expect(findHearthfile(emptyDir)).toBeNull();
  });
});

describe("defaultWorkdir", () => {
  it("extracts repo name from github URL", () => {
    expect(defaultWorkdir("github.com/user/my-api")).toBe("/home/agent/my-api");
  });

  it("strips .git suffix", () => {
    expect(defaultWorkdir("github.com/user/my-api.git")).toBe("/home/agent/my-api");
  });
});

describe("resolveWorkdir", () => {
  it("uses explicit workdir", () => {
    expect(resolveWorkdir({ name: "test", workdir: "/workspace" })).toBe("/workspace");
  });

  it("derives from repo when no workdir", () => {
    expect(resolveWorkdir({ name: "test", repo: "github.com/user/my-api" })).toBe("/home/agent/my-api");
  });

  it("falls back to /home/agent", () => {
    expect(resolveWorkdir({ name: "test" })).toBe("/home/agent");
  });
});

// Cleanup
rmSync(TMP, { recursive: true, force: true });
