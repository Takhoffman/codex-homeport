#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const path = require("node:path");

const root = __dirname;

function run(command, args) {
  const result = spawnSync(windowsCommand(command), args, { cwd: root, stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

function windowsCommand(command) {
  if (process.platform !== "win32") return command;
  return command === "npm" ? "npm.cmd" : command;
}

if (process.platform !== "win32") {
  console.error("Windows package build checks must run on Windows.");
  process.exit(1);
}

run("node", ["--check", path.join(root, "codex-multihome.js")]);
run("node", ["--check", path.join(root, "codex-multihome-win.js")]);
run("powershell.exe", [
  "-NoProfile",
  "-ExecutionPolicy",
  "Bypass",
  "-Command",
  "$errors = $null; $null = [System.Management.Automation.PSParser]::Tokenize((Get-Content -Raw codex-multihome-tray.ps1), [ref]$errors); if ($errors.Count) { $errors | Format-List; exit 1 }"
]);
console.log("Windows build checks passed.");
