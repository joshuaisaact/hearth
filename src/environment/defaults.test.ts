import { describe, it, expect } from "vitest";
import { writeFileSync, mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { loadDefaults, mergeDefaults } from "./defaults.js";
import type { Hearthfile } from "./hearthfile.js";

const TMP = join(tmpdir(), "hearth-test-defaults");

function writeTmp(filename: string, content: string): string {
  mkdirSync(TMP, { recursive: true });
  const path = join(TMP, filename);
  writeFileSync(path, content);
  return path;
}

describe("loadDefaults", () => {
  it("returns null when no file exists", () => {
    expect(loadDefaults(join(TMP, "nonexistent.toml"))).toBeNull();
  });

  it("parses a valid defaults.toml with setup", () => {
    const path = writeTmp("setup.toml", `setup = ["npm install -g claude"]\n`);
    const defaults = loadDefaults(path);
    expect(defaults).not.toBeNull();
    expect(defaults!.setup).toEqual(["npm install -g claude"]);
    expect(defaults!.files).toBeUndefined();
  });

  it("parses a valid defaults.toml with files", () => {
    const path = writeTmp("files.toml", `
[[files]]
from = "~/.gitconfig"
to = "/home/agent/.gitconfig"

[[files]]
from = "~/.ssh/id_ed25519"
to = "/home/agent/.ssh/id_ed25519"
mode = "0600"
`);
    const defaults = loadDefaults(path);
    expect(defaults).not.toBeNull();
    expect(defaults!.files).toHaveLength(2);
    expect(defaults!.files![0].from).toBe("~/.gitconfig");
    expect(defaults!.files![1].mode).toBe("0600");
  });

  it("parses a valid defaults.toml with both setup and files", () => {
    const path = writeTmp("both.toml", `
setup = ["npm install -g claude"]

[[files]]
from = "~/.gitconfig"
to = "/home/agent/.gitconfig"
`);
    const defaults = loadDefaults(path);
    expect(defaults!.setup).toEqual(["npm install -g claude"]);
    expect(defaults!.files).toHaveLength(1);
  });

  it("throws on invalid setup type", () => {
    const path = writeTmp("bad-setup.toml", `setup = "not an array"\n`);
    expect(() => loadDefaults(path)).toThrow("'setup' must be an array of strings");
  });

  it("throws on invalid files entry", () => {
    const path = writeTmp("bad-files.toml", `
[[files]]
from = 123
to = "/home/agent/.gitconfig"
`);
    expect(() => loadDefaults(path)).toThrow("files[0].from must be a string");
  });
});

describe("mergeDefaults", () => {
  const baseHf: Hearthfile = {
    name: "test",
    repo: "github.com/user/test",
    setup: ["npm install"],
    files: [{ from: "~/.env", to: "/home/agent/.env" }],
  };

  it("returns original when defaults is null", () => {
    const result = mergeDefaults(baseHf, null);
    expect(result).toBe(baseHf);
  });

  it("appends default setup after project setup", () => {
    const result = mergeDefaults(baseHf, {
      setup: ["npm install -g claude"],
    });
    expect(result.setup).toEqual(["npm install", "npm install -g claude"]);
  });

  it("appends default files after project files", () => {
    const result = mergeDefaults(baseHf, {
      files: [{ from: "~/.gitconfig", to: "/home/agent/.gitconfig" }],
    });
    expect(result.files).toHaveLength(2);
    expect(result.files![1].from).toBe("~/.gitconfig");
  });

  it("handles undefined setup on Hearthfile", () => {
    const hf: Hearthfile = { name: "test" };
    const result = mergeDefaults(hf, { setup: ["npm install -g claude"] });
    expect(result.setup).toEqual(["npm install -g claude"]);
  });

  it("handles undefined files on Hearthfile", () => {
    const hf: Hearthfile = { name: "test" };
    const result = mergeDefaults(hf, {
      files: [{ from: "~/.gitconfig", to: "/home/agent/.gitconfig" }],
    });
    expect(result.files).toHaveLength(1);
  });

  it("does not mutate the original Hearthfile", () => {
    const original = { ...baseHf, setup: [...baseHf.setup!] };
    mergeDefaults(baseHf, { setup: ["extra"] });
    expect(baseHf.setup).toEqual(original.setup);
  });

  it("preserves all other Hearthfile fields", () => {
    const result = mergeDefaults(baseHf, { setup: ["extra"] });
    expect(result.name).toBe("test");
    expect(result.repo).toBe("github.com/user/test");
  });
});

// Cleanup
rmSync(TMP, { recursive: true, force: true });
