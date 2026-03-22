import { getKsmStats } from "../vm/ksm.js";

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
}
