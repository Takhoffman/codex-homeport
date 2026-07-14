#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const root = __dirname;

function run(command, args) {
  const result = spawnSync(command, args, { cwd: root, stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function runNpm(args) {
  if (process.platform === "win32") {
    const result = spawnSync("cmd.exe", ["/d", "/s", "/c", `npm ${args.join(" ")}`], { cwd: root, stdio: "inherit" });
    if (result.error) {
      console.error(result.error.message);
      process.exit(1);
    }
    if (result.status !== 0) {
      process.exit(result.status ?? 1);
    }
    return;
  }
  run("npm", args);
}

if (process.platform !== "win32") {
  console.error("Windows release checks must run on Windows.");
  process.exit(1);
}
run(process.execPath, [path.join(root, "build.js")]);
run(process.execPath, ["--test", path.join(root, "test", "codex-multihome-win.test.js")]);
run(process.execPath, [path.join(root, "codex-multihome.js"), "--help"]);
runNpm(["pack", "--dry-run"]);
