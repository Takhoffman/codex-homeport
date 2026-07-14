#!/usr/bin/env node

if (process.platform !== "win32") {
  console.error("codex-multihome-windows only runs on Windows.");
  process.exit(1);
}

require("./codex-multihome-win").main(process.argv.slice(2), { packageRoot: __dirname });
