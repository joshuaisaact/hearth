#!/usr/bin/env node

interface Command {
  description: string;
  run: (args: string[]) => void | Promise<void>;
}

const commands: Record<string, Command> = {
  setup: {
    description: "Download and configure all dependencies",
    run: async () => { await import("./setup.js"); },
  },
  build: {
    description: "Build an environment from a Hearthfile.toml",
    run: async (args) => {
      const { buildCommand } = await import("./build.js");
      await buildCommand(args);
    },
  },
  rebuild: {
    description: "Rebuild an existing environment from scratch",
    run: async (args) => {
      const { rebuildCommand } = await import("./build.js");
      await rebuildCommand(args);
    },
  },
  envs: {
    description: "List, inspect, or remove environments",
    run: async (args) => {
      const { envsCommand } = await import("./envs.js");
      envsCommand(args);
    },
  },
  claude: {
    description: "Launch Claude Code in an isolated sandbox",
    run: async (args) => {
      const { claudeCommand } = await import("./claude.js");
      await claudeCommand(args);
    },
  },
  shell: {
    description: "Start an interactive shell in a sandbox",
    run: async (args) => {
      const { shellCommand } = await import("./shell.js");
      await shellCommand(args);
    },
  },
  checkpoint: {
    description: "Save a running sandbox's state (restore with 'hearth claude <name>')",
    run: async (args) => {
      const { checkpointCommand } = await import("./checkpoint.js");
      await checkpointCommand(args);
    },
  },
  status: {
    description: "Show KSM memory deduplication status",
    run: async () => {
      const { statusCommand } = await import("./status.js");
      statusCommand();
    },
  },
  daemon: {
    description: "Start the Hearth daemon (for multi-process/remote access)",
    run: async (args) => {
      const { daemonCommand } = await import("./daemon.js");
      daemonCommand(args);
    },
  },
  connect: {
    description: "Configure remote daemon connection (hearth connect <host>)",
    run: async (args) => {
      const { connectCommand } = await import("./connect.js");
      connectCommand(args);
    },
  },
};

const command = process.argv[2];
const args = process.argv.slice(3);

if (command && Object.hasOwn(commands, command)) {
  await commands[command].run(args);
} else {
  console.log("Usage: hearth <command>");
  console.log("");
  console.log("Commands:");
  for (const [name, cmd] of Object.entries(commands)) {
    console.log(`  ${name.padEnd(14)}${cmd.description}`);
  }
  process.exit(command ? 1 : 0);
}
