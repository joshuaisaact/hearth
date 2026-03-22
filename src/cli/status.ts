import { getKsmStats } from "../vm/ksm.js";
import { getThinPoolStatus } from "../vm/thin.js";

export function statusCommand() {
  try {
    const ksm = getKsmStats();
    if (ksm.enabled) {
      const sharedPages = ksm.pagesSharing.toLocaleString();
      console.log(`KSM: active — ${ksm.memorySaved} saved (${sharedPages} shared pages, ${ksm.fullScans} full scans)`);
    } else {
      console.log("KSM: inactive — enable with: echo 1 | sudo tee /sys/kernel/mm/ksm/run");
    }
  } catch {
    console.log("KSM: not available");
  }

  console.log("");
  const pool = getThinPoolStatus();
  if (pool) {
    console.log(`Thin pool: active (${pool.usedDataPercent}% data, ${pool.thinCount} volumes)`);
  } else {
    console.log("Thin pool: not active");
  }
}
