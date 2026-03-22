import { getThinPoolStatus, destroyThinPool } from "../vm/thin.js";

export function poolCommand(args: string[]) {
  const sub = args[0];

  if (sub === "status") {
    const status = getThinPoolStatus();
    if (!status) {
      console.log("Thin pool: not active");
      console.log("  Run hearth setup as root to enable instant snapshots");
    } else {
      console.log("Thin pool: active");
      console.log(`  Data usage:     ${status.usedDataPercent}%`);
      console.log(`  Metadata usage: ${status.usedMetaPercent}%`);
      console.log(`  Active volumes: ${status.thinCount}`);
    }
  } else if (sub === "destroy") {
    destroyThinPool();
    console.log("Thin pool destroyed");
  } else {
    console.log("Usage: hearth pool <command>");
    console.log("");
    console.log("Commands:");
    console.log("  status   Show thin pool usage");
    console.log("  destroy  Tear down thin pool");
  }
}
