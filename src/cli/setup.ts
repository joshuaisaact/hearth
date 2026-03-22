#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  chmodSync,
  rmSync,
  copyFileSync,
  accessSync,
  constants,
  writeFileSync,
  statfsSync,
} from "node:fs";
import { join } from "node:path";
import { execSync, execFileSync } from "node:child_process";
import { arch, tmpdir } from "node:os";
import { download } from "./download.js";
import { getHearthDir } from "../vm/binary.js";
import { errorMessage } from "../util.js";
import { initKsm } from "../vm/ksm.js";

const HEARTH_DIR = getHearthDir();
const BIN_DIR = join(HEARTH_DIR, "bin");
const BASES_DIR = join(HEARTH_DIR, "bases");

function fcArch(): string {
  const a = arch();
  if (a === "x64") return "x86_64";
  if (a === "arm64") return "aarch64";
  throw new Error(`Unsupported architecture: ${a}`);
}

const AGENT_VERSION = "agent-v0.3.0";
const GITHUB_REPO = "joshuaisaact/hearth";

async function main() {
  console.log("hearth setup\n");

  checkKvm();

  mkdirSync(BIN_DIR, { recursive: true });
  mkdirSync(BASES_DIR, { recursive: true });

  // These three are independent — run in parallel
  await Promise.all([setupFlint(), setupKernel(), setupAgent()]);
  // Rootfs depends on agent binary; snapshot depends on rootfs
  await setupRootfs();
  await createBaseSnapshot();
  setupKsm();

  reportFilesystem();

  console.log("\nSetup complete. You can now use hearth:");
  console.log('  import { Sandbox } from "hearth";');
  console.log("  const sandbox = await Sandbox.create();");
}

function checkKvm() {
  if (!existsSync("/dev/kvm")) {
    console.error("ERROR: /dev/kvm not found. Flint requires KVM.");
    console.error("  - Ensure KVM kernel module is loaded: sudo modprobe kvm");
    console.error("  - On a VM, enable nested virtualization");
    process.exit(1);
  }
  try {
    accessSync("/dev/kvm", constants.R_OK | constants.W_OK);
  } catch {
    console.error("ERROR: No read/write access to /dev/kvm.");
    console.error("  - Add your user to the kvm group: sudo usermod -aG kvm $USER");
    console.error("  - Or set ACL: sudo setfacl -m u:$USER:rw /dev/kvm");
    process.exit(1);
  }
  console.log("  /dev/kvm: OK");
}

async function setupFlint() {
  const flintPath = join(BIN_DIR, "flint");
  if (existsSync(flintPath)) {
    console.log("  flint: already installed");
    return;
  }

  // Check for Zig
  try {
    execSync("zig version", { stdio: "pipe" });
  } catch {
    console.error("ERROR: Zig not found on PATH. Flint requires Zig 0.16+ to build.");
    console.error("  Install Zig: https://ziglang.org/download/");
    process.exit(1);
  }

  const vmmDir = findVmmDir();
  console.log("  flint: building with Zig...");
  try {
    execSync("zig build -Doptimize=ReleaseSafe", { cwd: vmmDir, stdio: "pipe" });
  } catch (err: unknown) {
    const e = err as { stderr?: Buffer };
    if (e.stderr) {
      console.error(e.stderr.toString());
    }
    throw err;
  }
  copyFileSync(join(vmmDir, "zig-out", "bin", "flint"), flintPath);
  chmodSync(flintPath, 0o755);
  console.log("  flint: built and installed");
}

function findVmmDir(): string {
  const candidates = [
    join(import.meta.dirname ?? "", "..", "..", "vmm"),
    join(process.cwd(), "vmm"),
  ];
  for (const dir of candidates) {
    if (existsSync(join(dir, "build.zig"))) return dir;
  }
  throw new Error("Could not find vmm/ directory. Run from the hearth repo root.");
}

async function setupKernel() {
  // Prefer bzImage for snapshot restore support (ELF vmlinux breaks resume from HLT)
  const bzImagePath = join(BASES_DIR, "bzImage");
  if (existsSync(bzImagePath)) {
    console.log("  kernel: already installed (bzImage)");
    return;
  }

  // Also accept legacy ELF vmlinux (fresh boot still works)
  const vmlinuxPath = join(BASES_DIR, "vmlinux");
  if (existsSync(vmlinuxPath)) {
    console.log("  kernel: already installed (vmlinux, no snapshot restore support)");
    return;
  }

  // Download pre-built 5.10 bzImage from GitHub releases.
  // We need bzImage format (not ELF vmlinux) because the kernel's own setup header
  // is required for snapshot restore — the ELF loader synthesizes boot_params from
  // scratch, and the synthetic values break resume from HLT after snapshot restore.
  // The 5.10 kernel is used because it has CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y.
  const url = "https://github.com/joshuaisaact/hearth/releases/download/kernel-5.10.245/bzImage";
  console.log("  kernel: downloading bzImage 5.10.245...");
  await download(url, bzImagePath);
  console.log("  kernel: installed");
}

async function setupAgent() {
  const agentPath = join(BIN_DIR, "hearth-agent");
  if (existsSync(agentPath)) {
    console.log("  hearth-agent: already installed");
    return;
  }

  // Try downloading prebuilt binary first
  const architecture = fcArch();
  const assetName = `hearth-agent-${architecture}-linux`;
  const url = `https://github.com/${GITHUB_REPO}/releases/download/${AGENT_VERSION}/${assetName}`;

  try {
    console.log(`  hearth-agent: downloading prebuilt (${architecture})...`);
    await download(url, agentPath);
    chmodSync(agentPath, 0o755);
    console.log("  hearth-agent: installed");
    return;
  } catch {
    console.log("  hearth-agent: prebuilt download failed, trying Zig build...");
  }

  // Fallback: build from source with Zig
  try {
    execSync("zig version", { stdio: "pipe" });
  } catch {
    console.error("ERROR: Could not download prebuilt agent and Zig not found on PATH.");
    console.error("  Either create a GitHub release with agent binaries,");
    console.error("  or install Zig: https://ziglang.org/download/");
    process.exit(1);
  }

  const agentDir = findAgentDir();
  console.log("  hearth-agent: building with Zig...");
  execSync("zig build", { cwd: agentDir, stdio: "pipe" });
  copyFileSync(join(agentDir, "zig-out", "bin", "hearth-agent"), agentPath);
  chmodSync(agentPath, 0o755);
  console.log("  hearth-agent: built");
}

function findAgentDir(): string {
  const candidates = [
    join(import.meta.dirname ?? "", "..", "..", "agent"),
    join(process.cwd(), "agent"),
  ];
  for (const dir of candidates) {
    if (existsSync(join(dir, "build.zig"))) return dir;
  }
  throw new Error("Could not find agent/ directory. Run from the hearth repo root.");
}

async function setupRootfs() {
  const rootfsPath = join(BASES_DIR, "ubuntu-24.04.ext4");
  if (existsSync(rootfsPath)) {
    console.log("  rootfs: already built");
    return;
  }

  const agentBin = join(BIN_DIR, "hearth-agent");
  if (!existsSync(agentBin)) {
    throw new Error("hearth-agent not found. Agent must be built before rootfs.");
  }

  try {
    execSync("docker info", { stdio: "pipe" });
  } catch {
    console.error("ERROR: Docker is required to build the rootfs.");
    console.error("  Install Docker: https://docs.docker.com/get-docker/");
    process.exit(1);
  }

  console.log("  rootfs: building via Docker...");

  // Use system temp dir (not HEARTH_DIR) to avoid virtiofs issues when running inside Lima.
  const tmpDir = join(tmpdir(), "hearth-rootfs-build");
  mkdirSync(tmpDir, { recursive: true });

  try {
    copyFileSync(agentBin, join(tmpDir, "hearth-agent"));

    writeFileSync(
      join(tmpDir, "Dockerfile"),
      [
        "FROM ubuntu:24.04",
        "RUN apt-get update && apt-get install -y --no-install-recommends \\",
        "    ca-certificates curl iproute2 busybox git python3 make g++ \\",
        "    && rm -rf /var/lib/apt/lists/*",
        "RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \\",
        "    && apt-get install -y --no-install-recommends nodejs \\",
        "    && rm -rf /var/lib/apt/lists/* \\",
        "    && npm install -g node-gyp \\",
        "    && node-gyp install",
        "RUN echo 'root:root' | chpasswd",
        "RUN useradd -m -s /bin/bash agent",
        "COPY hearth-agent /usr/local/bin/hearth-agent",
        "RUN chmod +x /usr/local/bin/hearth-agent",
        "",
      ].join("\n"),
    );

    const platform = fcArch() === "aarch64" ? "linux/arm64" : "linux/amd64";
    execSync(`docker build --platform ${platform} -t hearth-rootfs .`, { cwd: tmpDir, stdio: "pipe" });

    console.log("  rootfs: exporting container...");
    const cid = execFileSync("docker", ["create", "hearth-rootfs"], { stdio: "pipe" })
      .toString()
      .trim();
    execFileSync("docker", ["export", "-o", join(tmpDir, "rootfs.tar"), cid], {
      stdio: "pipe",
    });
    execFileSync("docker", ["rm", cid], { stdio: "pipe" });

    const extractDir = join(tmpDir, "rootfs");
    mkdirSync(extractDir, { recursive: true });
    execFileSync("tar", ["xf", join(tmpDir, "rootfs.tar"), "-C", extractDir], { stdio: "pipe" });

    // Minimal init that mounts essential filesystems and starts the agent
    writeFileSync(
      join(extractDir, "sbin", "init"),
      [
        "#!/bin/sh",
        "mount -t proc proc /proc",
        "mount -t sysfs sysfs /sys",
        "mount -t devtmpfs devtmpfs /dev 2>/dev/null",
        "mkdir -p /dev/pts /dev/shm",
        "mount -t devpts devpts /dev/pts",
        "mount -t tmpfs tmpfs /dev/shm",
        "mount -t tmpfs tmpfs /tmp",
        "mount -t tmpfs tmpfs /run",
        "hostname hearth",
        "echo '127.0.0.1 localhost hearth' > /etc/hosts",
        "ip link set lo up 2>/dev/null",
        "exec /usr/local/bin/hearth-agent",
        "",
      ].join("\n"),
      { mode: 0o755 },
    );

    console.log("  rootfs: creating ext4 image...");
    execFileSync("truncate", ["-s", "2G", rootfsPath], { stdio: "pipe" });
    execFileSync("mkfs.ext4", ["-F", "-q", "-d", extractDir, rootfsPath], {
      stdio: "pipe",
    });

    console.log("  rootfs: built");
  } finally {
    rmSync(tmpDir, { recursive: true, force: true });
  }
}

async function createBaseSnapshot() {
  const { ensureBaseSnapshot, hasBaseSnapshot } = await import("../vm/snapshot.js");
  if (hasBaseSnapshot()) {
    console.log("  snapshot: already created");
    return;
  }

  console.log("  snapshot: creating base snapshot (booting VM, ~2s)...");
  await ensureBaseSnapshot();
  console.log("  snapshot: created");
}

function setupKsm() {
  try {
    if (initKsm()) {
      console.log("  KSM: enabled (kernel same-page merging for memory deduplication)");
    } else {
      console.log("  KSM: skipped (requires root — enable manually: echo 1 | sudo tee /sys/kernel/mm/ksm/run)");
    }
  } catch {
    console.log("  KSM: not available on this system");
  }
}

function reportFilesystem() {
  console.log("");
  try {
    // statfsSync type field indicates filesystem — btrfs, XFS, or ext4
    const stats = statfsSync(HEARTH_DIR) as unknown as Record<string, unknown>;
    const fsType = typeof stats.type === "number" ? stats.type : undefined;
    if (fsType === 0x9123683e) {
      console.log("  storage: btrfs — reflink CoW enabled (instant snapshots)");
    } else if (fsType === 0x58465342) {
      console.log("  storage: XFS — reflink CoW enabled (instant snapshots)");
    } else if (fsType === 0xef53) {
      console.log("  storage: ext4 — no reflink support (snapshots use full copies)");
      console.log("  tip: place ~/.hearth on btrfs or XFS for instant snapshot clones");
    }
  } catch {
    // statfsSync may not expose type on all Node versions
  }
}

main().catch((err) => {
  console.error(`\nSetup failed: ${errorMessage(err)}`);
  process.exit(1);
});
