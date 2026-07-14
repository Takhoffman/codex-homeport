const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const test = require("node:test");

const { HomeportWin, makePaths, slugify, presetPolicies, policySummary } = require("../codex-multihome-win");

function withTempEnv(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "codex-multihome-win-"));
  const oldHome = process.env.USERPROFILE;
  const oldAppData = process.env.APPDATA;
  const oldLocalAppData = process.env.LOCALAPPDATA;
  const oldSkipTasks = process.env.CODEX_MULTIHOME_TEST_SKIP_SCHTASKS;
  const oldSkipStart = process.env.CODEX_MULTIHOME_TEST_SKIP_START;
  const oldAssumeRunning = process.env.CODEX_MULTIHOME_TEST_ASSUME_RUNNING;
  process.env.USERPROFILE = root;
  process.env.APPDATA = path.join(root, "AppData", "Roaming");
  process.env.LOCALAPPDATA = path.join(root, "AppData", "Local");
  process.env.CODEX_MULTIHOME_TEST_SKIP_SCHTASKS = "1";
  process.env.CODEX_MULTIHOME_TEST_SKIP_START = "1";
  process.env.CODEX_MULTIHOME_TEST_ASSUME_RUNNING = "1";
  try {
    return fn(root);
  } finally {
    restoreEnv("USERPROFILE", oldHome);
    restoreEnv("APPDATA", oldAppData);
    restoreEnv("LOCALAPPDATA", oldLocalAppData);
    restoreEnv("CODEX_MULTIHOME_TEST_SKIP_SCHTASKS", oldSkipTasks);
    restoreEnv("CODEX_MULTIHOME_TEST_SKIP_START", oldSkipStart);
    restoreEnv("CODEX_MULTIHOME_TEST_ASSUME_RUNNING", oldAssumeRunning);
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function restoreEnv(name, value) {
  if (value === undefined) delete process.env[name];
  else process.env[name] = value;
}

test("slugify produces safe selectors", () => {
  assert.equal(slugify("My Clean Room!"), "my-clean-room");
  assert.equal(slugify("   "), "home");
});

test("create clean room persists Windows paths", () => withTempEnv((root) => {
  const app = new HomeportWin(root);
  app.run(["create", "--kind", "clean-room", "--name", "Blank Slate"]);
  const state = app.state();
  const home = state.homes.find((item) => item.slug === "blank-slate");
  assert.ok(home);
  assert.equal(home.homePath, path.join(root, ".codex-homes", "blank-slate"));
  assert.equal(home.profilePath, path.join(root, "AppData", "Roaming", "CodexMultihome", "Profiles", "blank-slate"));
  assert.ok(fs.existsSync(home.homePath));
}));

test("clone copies working setup but skips sessions", () => withTempEnv((root) => {
  const source = path.join(root, ".codex");
  fs.mkdirSync(source, { recursive: true });
  fs.writeFileSync(path.join(source, "AGENTS.md"), "instructions");
  fs.writeFileSync(path.join(source, "config.toml"), "model = \"gpt\"");
  fs.writeFileSync(path.join(source, "auth.json"), "secret");
  fs.writeFileSync(path.join(source, "session_index.jsonl"), "history");

  const app = new HomeportWin(root);
  app.run(["clone", "--preset", "working-setup", "--name", "Plugin Lab"]);

  const destination = path.join(root, ".codex-homes", "plugin-lab");
  assert.ok(fs.existsSync(path.join(destination, "AGENTS.md")));
  assert.ok(fs.existsSync(path.join(destination, "config.toml")));
  assert.ok(fs.existsSync(path.join(destination, "auth.json")));
  assert.equal(fs.existsSync(path.join(destination, "session_index.jsonl")), false);
}));

test("clone can copy instructions without config", () => withTempEnv((root) => {
  const source = path.join(root, ".codex");
  fs.mkdirSync(source, { recursive: true });
  fs.writeFileSync(path.join(source, "AGENTS.md"), "instructions");
  fs.writeFileSync(path.join(source, "config.toml"), "model = \"gpt\"");

  const app = new HomeportWin(root);
  app.run(["clone", "--preset", "empty", "--include", "agents.md", "--name", "Instructions Only"]);

  const destination = path.join(root, ".codex-homes", "instructions-only");
  assert.ok(fs.existsSync(path.join(destination, "AGENTS.md")));
  assert.equal(fs.existsSync(path.join(destination, "config.toml")), false);
}));

test("link-safe creates junctions or hard links for safe categories only", () => withTempEnv((root) => {
  const source = path.join(root, ".codex");
  fs.mkdirSync(path.join(source, "skills"), { recursive: true });
  fs.mkdirSync(path.join(source, "browser"), { recursive: true });
  fs.writeFileSync(path.join(source, "config.toml"), "model = \"gpt\"");
  fs.writeFileSync(path.join(source, "auth.json"), "secret");

  const app = new HomeportWin(root);
  app.run(["clone", "--preset", "everything", "--name", "Linked Lab", "--link-safe"]);

  const destination = path.join(root, ".codex-homes", "linked-lab");
  assert.ok(fs.lstatSync(path.join(destination, "skills")).isSymbolicLink());
  assert.equal(fs.statSync(path.join(destination, "config.toml")).ino, fs.statSync(path.join(source, "config.toml")).ino);
  assert.equal(fs.lstatSync(path.join(destination, "auth.json")).isSymbolicLink(), false);
  assert.equal(fs.lstatSync(path.join(destination, "browser")).isSymbolicLink(), false);
}));

test("policy summaries are stable", () => {
  assert.equal(policySummary(presetPolicies("empty")), "Empty");
  assert.match(policySummary(presetPolicies("working-setup")), /Copy/);
});

test("remove-state can move app support without trashing into itself", () => withTempEnv((root) => {
  const app = new HomeportWin(root);
  app.run(["configure", "--show"]);
  assert.ok(fs.existsSync(path.join(root, "AppData", "Roaming", "CodexMultihome", "homeport.json")));

  app.run(["uninstall", "--remove-state"]);

  assert.equal(fs.existsSync(path.join(root, "AppData", "Roaming", "CodexMultihome")), false);
  assert.ok(fs.existsSync(path.join(root, "AppData", "Roaming", "CodexMultihome Trash")));
}));

test("install with app writes Windows tray launcher and start uses it", () => withTempEnv((root) => {
  const app = new HomeportWin(path.resolve(__dirname, ".."));
  const appDir = path.join(root, "CustomApp");

  app.run(["install", "--prefix", path.join(root, "bin"), "--with-app", "--app-dir", appDir]);

  const shim = path.join(root, "bin", "codex-multihome.cmd");
  const launcher = path.join(appDir, "Codex Multihome.cmd");
  const trayScript = path.join(appDir, "codex-multihome-tray.ps1");
  assert.ok(fs.existsSync(shim));
  assert.ok(fs.existsSync(launcher));
  assert.ok(fs.existsSync(trayScript));
  assert.match(fs.readFileSync(launcher, "utf8"), /codex-multihome-tray\.ps1/);

  app.run(["start", "--app-dir", appDir]);
}));

test("onboard installs tray app before autostart by default", () => withTempEnv((root) => {
  const app = new HomeportWin(path.resolve(__dirname, ".."));
  const appDir = path.join(root, "OnboardApp");

  app.run(["onboard", "--prefix", path.join(root, "bin"), "--app-dir", appDir, "--no-start"]);

  assert.ok(fs.existsSync(path.join(appDir, "Codex Multihome.cmd")));
  assert.ok(fs.existsSync(path.join(appDir, "codex-multihome-tray.ps1")));
}));

test("autostart uses the per-user Startup folder without administrator access", () => withTempEnv((root) => {
  delete process.env.CODEX_MULTIHOME_TEST_SKIP_SCHTASKS;
  const app = new HomeportWin(path.resolve(__dirname, ".."));
  const appDir = path.join(root, "AutostartApp");
  const startupScript = path.join(root, "AppData", "Roaming", "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "Codex Multihome.vbs");

  app.run(["install", "--prefix", path.join(root, "bin"), "--with-app", "--app-dir", appDir]);
  app.run(["autostart", "enable", "--app-dir", appDir]);

  assert.ok(fs.existsSync(startupScript));
  assert.match(fs.readFileSync(startupScript, "utf8"), /AutostartApp/);

  app.run(["autostart", "disable"]);
  assert.equal(fs.existsSync(startupScript), false);
}));

test("dev channel uses separate state, homes, and tray app defaults", () => withTempEnv((root) => {
  const app = new HomeportWin(path.resolve(__dirname, ".."));

  app.run(["create", "--kind", "clean-room", "--name", "Live Room"]);
  app.run(["create", "--channel", "dev", "--kind", "clean-room", "--name", "Dev Room"]);
  app.run(["install", "--channel", "dev", "--prefix", path.join(root, "bin"), "--with-app"]);

  assert.ok(fs.existsSync(path.join(root, ".codex-homes", "live-room")));
  assert.ok(fs.existsSync(path.join(root, ".codex-homes-dev", "dev-room")));
  assert.ok(fs.existsSync(path.join(root, "AppData", "Roaming", "CodexMultihome", "homeport.json")));
  assert.ok(fs.existsSync(path.join(root, "AppData", "Roaming", "CodexMultihomeDev", "homeport.json")));
  assert.ok(fs.existsSync(path.join(root, "AppData", "Local", "CodexMultihomeDev", "App", "Codex Multihome Dev.cmd")));
}));

test("channel option works before the command for tray callers", () => withTempEnv((root) => {
  const app = new HomeportWin(path.resolve(__dirname, ".."));

  app.run(["--channel", "dev", "create", "--kind", "clean-room", "--name", "Before Command"]);

  assert.ok(fs.existsSync(path.join(root, ".codex-homes-dev", "before-command")));
  assert.equal(fs.existsSync(path.join(root, ".codex-homes", "before-command")), false);
}));

test("product option creates isolated Claude homes and state", () => withTempEnv((root) => {
  const source = path.join(root, ".claude");
  fs.mkdirSync(path.join(source, "commands"), { recursive: true });
  fs.writeFileSync(path.join(source, "settings.json"), "{}");
  fs.writeFileSync(path.join(source, "CLAUDE.md"), "Use this memory.");
  fs.writeFileSync(path.join(source, "history.jsonl"), "history");

  const app = new HomeportWin(root);
  app.run(["--product", "claude", "clone", "--preset", "working-setup", "--name", "Claude Lab"]);

  const destination = path.join(root, ".claude-homes", "claude-lab");
  assert.ok(fs.existsSync(path.join(destination, "settings.json")));
  assert.ok(fs.existsSync(path.join(destination, "CLAUDE.md")));
  assert.ok(fs.existsSync(path.join(destination, "commands")));
  assert.equal(fs.existsSync(path.join(destination, "history.jsonl")), false);
  assert.ok(fs.existsSync(path.join(root, "AppData", "Roaming", "ClaudeMultihome", "homeport.json")));
  assert.equal(fs.existsSync(path.join(root, "AppData", "Roaming", "CodexMultihome", "homeport.json")), false);
}));

test("product option works after command for Claude clean rooms", () => withTempEnv((root) => {
  const app = new HomeportWin(root);

  app.run(["create", "--product", "claude", "--kind", "clean-room", "--name", "Claude Clean"]);

  assert.ok(fs.existsSync(path.join(root, ".claude-homes", "claude-clean")));
  assert.equal(fs.existsSync(path.join(root, ".codex-homes", "claude-clean")), false);
}));

test("configure persists Windows preferences and clone policies", () => withTempEnv((root) => {
  const app = new HomeportWin(root);

  app.run([
    "configure",
    "--launch-target", "terminal",
    "--workspace", path.join(root, "workspace"),
    "--clone-preset", "working-setup",
    "--clone-exclude", "auth,sessions",
    "--temporary", "on",
    "--install-app", "off",
    "--update-checks", "off",
    "--update-interval", "weekly",
    "--auto-install-updates", "off"
  ]);

  const state = app.state();
  assert.equal(state.lastWorkspacePath, path.join(root, "workspace"));
  assert.equal(state.preferences.defaultLaunchTarget, "terminal");
  assert.equal(state.preferences.clonePolicies.auth, "skip");
  assert.equal(state.preferences.clonePolicies.sessions, "skip");
  assert.equal(state.preferences.launchTemporaryByDefault, true);
  assert.equal(state.preferences.installAppByDefault, false);
  assert.equal(state.preferences.autoUpdateChecksEnabled, false);
  assert.equal(state.preferences.updateCheckInterval, "weekly");
}));

test("custom home paths derive a name and survive normal delete", () => withTempEnv((root) => {
  const customPath = path.join(root, "Projects With Spaces", "Custom Lab");
  const app = new HomeportWin(path.resolve(__dirname, ".."));

  app.run(["create", "--kind", "clean-room", "--path", customPath]);

  let state = app.state();
  const home = state.homes.find((item) => item.slug === "custom-lab");
  assert.ok(home);
  assert.equal(home.name, "Custom Lab");
  assert.equal(home.homePath, customPath);
  assert.equal(home.usesCustomPath, true);

  app.run(["delete", "custom-lab"]);
  state = app.state();
  assert.equal(state.homes.some((item) => item.slug === "custom-lab"), false);
  assert.ok(fs.existsSync(customPath));
  assert.equal(fs.existsSync(home.profilePath), false);
}));

test("path --move relocates homes and instance references", () => withTempEnv((root) => {
  const app = new HomeportWin(path.resolve(__dirname, ".."));
  app.run(["create", "--kind", "clean-room", "--name", "Movable"]);
  const before = app.state().homes.find((item) => item.slug === "movable");
  const destination = path.join(root, "Elsewhere", "Moved Home");

  app.run(["path", "movable", "--path", destination, "--move"]);

  const after = app.state().homes.find((item) => item.slug === "movable");
  assert.equal(after.homePath, destination);
  assert.equal(after.usesCustomPath, true);
  assert.equal(fs.existsSync(before.homePath), false);
  assert.ok(fs.existsSync(destination));
}));

test("main home cannot be moved or deleted", () => withTempEnv((root) => {
  const app = new HomeportWin(path.resolve(__dirname, ".."));
  assert.throws(() => app.run(["path", "main", "--path", path.join(root, "other"), "--move"]), /cannot be changed/);
  assert.throws(() => app.run(["delete", "main"]), /cannot be deleted/);
  assert.ok(app.state().homes.some((item) => item.kind === "main"));
}));

test("version 1 state migrates without renaming the legacy state file", () => withTempEnv((root) => {
  const paths = makePaths();
  fs.mkdirSync(paths.appSupport, { recursive: true });
  const customPath = path.join(root, "adopted");
  fs.mkdirSync(customPath, { recursive: true });
  fs.writeFileSync(paths.stateFile, JSON.stringify({
    version: 1,
    homes: [{ id: "legacy", name: "Legacy", slug: "legacy", kind: "cleanRoom", homePath: customPath }],
    instances: [],
    pinnedHomeIDs: [],
    preferences: { clonePolicies: { config: "skip" } }
  }));

  const state = new HomeportWin(path.resolve(__dirname, "..")).state();
  assert.equal(state.version, 2);
  assert.equal(state.homes.find((item) => item.id === "legacy").usesCustomPath, true);
  assert.ok(state.homes.some((item) => item.kind === "main"));
  assert.equal(path.basename(paths.stateFile), "homeport.json");
  assert.equal(state.preferences.clonePolicies.config, "skip");
  assert.equal(state.preferences.clonePolicies.instructions, "copy");
  assert.equal(state.preferences.clonePolicies.commands, "copy");
}));

test("new environment names override legacy channel names", () => withTempEnv((root) => {
  const oldNew = process.env.CODEX_MULTIHOME_CHANNEL;
  const oldLegacy = process.env.HOMEPORT_CHANNEL;
  process.env.CODEX_MULTIHOME_CHANNEL = "dev";
  process.env.HOMEPORT_CHANNEL = "live";
  try {
    assert.match(makePaths().managedHomes, /\.codex-homes-dev$/);
  } finally {
    restoreEnv("CODEX_MULTIHOME_CHANNEL", oldNew);
    restoreEnv("HOMEPORT_CHANNEL", oldLegacy);
  }
}));

test("simultaneous desktop launches isolate CODEX_HOME and profile arguments", () => withTempEnv((root) => {
  const launches = [];
  const runtime = {
    findCodexApp: () => "C:\\Program Files\\WindowsApps\\OpenAI.Codex\\app\\ChatGPT.exe",
    spawn: (executable, args, options) => {
      launches.push({ executable, args, options });
      return { pid: process.pid, unref() {} };
    }
  };
  const app = new HomeportWin(path.resolve(__dirname, ".."), runtime);
  app.run(["create", "--kind", "clean-room", "--name", "First"]);
  app.run(["create", "--kind", "clean-room", "--name", "Second"]);
  const originalHome = process.env.CODEX_HOME;

  app.run(["launch", "first", "--target", "desktop", "--workspace", root]);
  app.run(["launch", "second", "--target", "desktop", "--workspace", root]);

  assert.equal(process.env.CODEX_HOME, originalHome);
  assert.equal(launches.length, 2);
  assert.notEqual(launches[0].options.env.CODEX_HOME, launches[1].options.env.CODEX_HOME);
  assert.notEqual(launches[0].args[0], launches[1].args[0]);
  assert.match(launches[0].args[0], /^--user-data-dir=/);
  assert.equal(launches[0].options.detached, true);
  assert.equal(launches[1].options.detached, true);
  assert.equal(app.state().instances.length, 2);
}));
