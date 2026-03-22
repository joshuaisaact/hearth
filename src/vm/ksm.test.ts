import { describe, it, expect, vi, beforeEach } from "vitest";
import { readFileSync, writeFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { enableKsm, getKsmStats, tuneKsm, initKsm } from "./ksm.js";

vi.mock("node:fs", () => ({
  readFileSync: vi.fn(),
  writeFileSync: vi.fn(),
}));

vi.mock("node:child_process", () => ({
  execFileSync: vi.fn(() => Buffer.from("4096\n")),
}));

const mockRead = vi.mocked(readFileSync);
const mockWrite = vi.mocked(writeFileSync);

function stubKsmFiles(files: Record<string, string>) {
  mockRead.mockImplementation((path) => {
    const name = String(path).split("/").pop()!;
    if (name in files) return files[name];
    throw Object.assign(new Error(`ENOENT: ${path}`), { code: "ENOENT" });
  });
}

beforeEach(() => {
  vi.resetAllMocks();
  vi.mocked(execFileSync).mockReturnValue(Buffer.from("4096\n"));
});

describe("enableKsm", () => {
  it("writes 1 to run when KSM is disabled", () => {
    stubKsmFiles({ run: "0" });
    enableKsm();
    expect(mockWrite).toHaveBeenCalledWith("/sys/kernel/mm/ksm/run", "1");
  });

  it("is a no-op when KSM is already enabled", () => {
    stubKsmFiles({ run: "1" });
    enableKsm();
    expect(mockWrite).not.toHaveBeenCalled();
  });

  it("throws a clear error on EACCES", () => {
    stubKsmFiles({ run: "0" });
    mockWrite.mockImplementation(() => {
      throw Object.assign(new Error("EACCES"), { code: "EACCES" });
    });
    expect(() => enableKsm()).toThrow("KSM requires root privileges");
  });
});

describe("getKsmStats", () => {
  it("returns parsed stats with computed savings", () => {
    stubKsmFiles({
      run: "1",
      pages_shared: "100",
      pages_sharing: "500",
      pages_unshared: "200",
      full_scans: "42",
    });

    const stats = getKsmStats();
    expect(stats).toEqual({
      enabled: true,
      pagesShared: 100,
      pagesSharing: 500,
      pagesUnshared: 200,
      fullScans: 42,
      bytesSaved: 500 * 4096,
      memorySaved: "2 MB",
    });
  });

  it("reports disabled when run is 0", () => {
    stubKsmFiles({
      run: "0",
      pages_shared: "0",
      pages_sharing: "0",
      pages_unshared: "0",
      full_scans: "0",
    });

    expect(getKsmStats().enabled).toBe(false);
  });

  it("formats GB correctly", () => {
    stubKsmFiles({
      run: "1",
      pages_shared: "100",
      pages_sharing: String(Math.ceil((1.5 * 1024 * 1024 * 1024) / 4096)),
      pages_unshared: "0",
      full_scans: "10",
    });

    const stats = getKsmStats();
    expect(stats.memorySaved).toBe("1.5 GB");
  });

  it("throws on unparseable sysfs value", () => {
    stubKsmFiles({
      run: "1",
      pages_shared: "not_a_number",
      pages_sharing: "0",
      pages_unshared: "0",
      full_scans: "0",
    });

    expect(() => getKsmStats()).toThrow('Failed to parse KSM pages_shared: "not_a_number"');
  });
});

describe("name validation", () => {
  it("allows valid sysfs names", () => {
    stubKsmFiles({ run: "0" });
    enableKsm();
    expect(mockWrite).toHaveBeenCalledWith("/sys/kernel/mm/ksm/run", "1");
  });
});

describe("tuneKsm", () => {
  it("writes default values when called with no args", () => {
    tuneKsm();
    expect(mockWrite).toHaveBeenCalledWith("/sys/kernel/mm/ksm/pages_to_scan", "1000");
    expect(mockWrite).toHaveBeenCalledWith("/sys/kernel/mm/ksm/sleep_millisecs", "20");
  });

  it("writes custom values", () => {
    tuneKsm({ pagesToScan: 2000, sleepMs: 50 });
    expect(mockWrite).toHaveBeenCalledWith("/sys/kernel/mm/ksm/pages_to_scan", "2000");
    expect(mockWrite).toHaveBeenCalledWith("/sys/kernel/mm/ksm/sleep_millisecs", "50");
  });

  it("rejects invalid pagesToScan", () => {
    expect(() => tuneKsm({ pagesToScan: 0 })).toThrow("pagesToScan must be an integer between 1 and 10000");
    expect(() => tuneKsm({ pagesToScan: -1 })).toThrow("pagesToScan");
    expect(() => tuneKsm({ pagesToScan: 99999 })).toThrow("pagesToScan");
  });

  it("rejects invalid sleepMs", () => {
    expect(() => tuneKsm({ sleepMs: 0 })).toThrow("sleepMs must be an integer between 1 and 1000");
    expect(() => tuneKsm({ sleepMs: -5 })).toThrow("sleepMs");
    expect(() => tuneKsm({ sleepMs: 9999 })).toThrow("sleepMs");
  });
});

describe("initKsm", () => {
  it("returns true when KSM is enabled successfully", () => {
    stubKsmFiles({ run: "0" });
    expect(initKsm()).toBe(true);
  });

  it("returns false on permission error without throwing", () => {
    stubKsmFiles({ run: "0" });
    mockWrite.mockImplementation(() => {
      throw Object.assign(new Error("EACCES"), { code: "EACCES" });
    });
    expect(initKsm()).toBe(false);
  });

  it("returns false on any error without throwing", () => {
    stubKsmFiles({ run: "0" });
    mockWrite.mockImplementation(() => {
      throw new Error("disk on fire");
    });
    expect(initKsm()).toBe(false);
  });

  it("returns false when KSM sysfs is missing", () => {
    mockRead.mockImplementation(() => {
      throw Object.assign(new Error("ENOENT"), { code: "ENOENT" });
    });
    expect(initKsm()).toBe(false);
  });
});
