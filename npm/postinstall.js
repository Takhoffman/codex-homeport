#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

if (process.platform !== "darwin") {
  console.error("Codex Multihome is a macOS app and only installs on macOS.");
  process.exit(1);
}

const root = path.resolve(__dirname, "..");
const result = spawnSync("swift", ["build", "--package-path", root, "-c", "release", "--product", "homeport"], {
  stdio: "inherit"
});

if (result.error) {
  console.error("Swift is required. Install Xcode Command Line Tools with: xcode-select --install");
  console.error(result.error.message);
  process.exit(1);
}

process.exit(result.status ?? 0);
