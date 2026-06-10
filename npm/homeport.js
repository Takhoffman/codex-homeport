#!/usr/bin/env node

const { spawnSync } = require("node:child_process");
const { existsSync } = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const binary = path.join(root, ".build", "release", "homeport");
const args = process.argv.slice(2);
const command = args[0];

function run(executable, runArgs) {
  const result = spawnSync(executable, runArgs, { stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
    process.exit(1);
  }
  process.exit(result.status ?? 0);
}

function hasRepoArgument(values) {
  return values.includes("--repo");
}

function withPackageRoot(values) {
  if (hasRepoArgument(values)) {
    return values;
  }
  return [...values, "--repo", root];
}

if (!existsSync(binary)) {
  const build = spawnSync("swift", ["build", "--package-path", root, "-c", "release", "--product", "homeport"], {
    stdio: "inherit"
  });
  if (build.error) {
    console.error(build.error.message);
    process.exit(1);
  }
  if (build.status !== 0) {
    process.exit(build.status ?? 1);
  }
}

switch (command) {
  case "install":
  case "onboard":
    run(binary, withPackageRoot(args));
    break;
  case "update":
    console.log("For npm installs, update Multihome with: npm install -g codex-multihome@latest");
    run(binary, withPackageRoot(["install", "--with-app", ...args.slice(1)]));
    break;
  default:
    run(binary, args);
}
