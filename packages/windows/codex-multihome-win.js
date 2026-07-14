#!/usr/bin/env node

const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawn, spawnSync } = require("node:child_process");

const VERSION = "0.15.0-windows.1";
const COMMAND = "codex-multihome";
const MAIN_HOME_ID = "00000000-0000-0000-0000-000000000001";

const categories = {
  instructions: ["AGENTS.md", "CLAUDE.md", "CLAUDE.local.md"],
  config: ["config.toml", "keybindings.json", "version.json", "settings.json", "settings.local.json", "claude.json", ".mcp.json"],
  skills: ["skills", "skills-disabled", "skill-backups"],
  plugins: ["plugins", "vendor_imports"],
  prompts: ["prompts"],
  rules: ["rules"],
  profiles: ["profiles"],
  auth: ["auth.json", ".credentials.json", "oauth_creds.json"],
  agents: ["agents"],
  commands: ["commands"],
  workflows: ["workflows"],
  outputStyles: ["output-styles"],
  browser: ["browser", "chrome-cdp-profile", "chrome-native-hosts.json", "chrome-native-hosts-v2.json", "computer-use", "mcp-auth"],
  memories: ["memories", "memories_1.sqlite", "memories_1.sqlite-shm", "memories_1.sqlite-wal"],
  sessions: [
    "session_index.jsonl",
    "sessions",
    "projects",
    "todos",
    "history.jsonl",
    "statsig",
    "logs",
    "archived_sessions",
    "logs_2.sqlite",
    "logs_2.sqlite-shm",
    "logs_2.sqlite-wal",
    "goals_1.sqlite",
    "goals_1.sqlite-shm",
    "goals_1.sqlite-wal",
    "state_5.sqlite",
    "state_5.sqlite-shm",
    "state_5.sqlite-wal",
    "shell_snapshots",
    "attachments"
  ]
};

const linkable = new Set(["instructions", "config", "skills", "plugins", "prompts", "rules", "profiles", "auth", "agents", "commands", "workflows", "outputStyles"]);

const products = {
  codex: {
    key: "codex",
    label: "Codex",
    cli: "codex",
    envName: "CODEX_HOME",
    mainHomeName: ".codex",
    managedHomesName: ".codex-homes",
    managedHomesDevName: ".codex-homes-dev",
    appSupportName: "CodexMultihome",
    appSupportDevName: "CodexMultihomeDev",
    normalProfileName: "Codex",
    hasDesktop: true
  },
  claude: {
    key: "claude",
    label: "Claude",
    cli: "claude",
    envName: "CLAUDE_CONFIG_DIR",
    mainHomeName: ".claude",
    managedHomesName: ".claude-homes",
    managedHomesDevName: ".claude-homes-dev",
    appSupportName: "ClaudeMultihome",
    appSupportDevName: "ClaudeMultihomeDev",
    normalProfileName: null,
    hasDesktop: false
  }
};

function main(args = process.argv.slice(2), context = {}) {
  try {
    const app = new HomeportWin(context.packageRoot || __dirname, context);
    app.run(args);
  } catch (error) {
    console.error(`${COMMAND}: ${error.message}`);
    process.exitCode = 1;
  }
}

class HomeportWin {
  constructor(packageRoot, runtime = {}) {
    this.packageRoot = packageRoot;
    this.spawnProcess = runtime.spawn || spawn;
    this.findCodexApp = runtime.findCodexApp || findCodexApp;
    this.findCommand = runtime.findCommand || findCommand;
    this.channel = channelFromEnvironment();
    this.product = productFromEnvironment();
    this.paths = makePaths(this.channel, this.product);
  }

  run(args) {
    this.setChannel(option(args, "--channel") || channelFromEnvironment());
    this.setProduct(option(args, "--product") || option(args, "--tool") || productFromEnvironment());
    const effectiveArgs = removeOption(removeOption(removeOption(args, "--channel"), "--product"), "--tool");
    const command = effectiveArgs[0];
    if (!command || command === "--help" || command === "-h" || command === "help") {
      this.printHelp(args[1]);
      return;
    }
    if (command === "--version" || command === "-v" || command === "version") {
      console.log(`Codex Multihome ${VERSION} (windows)`);
      return;
    }

    const rest = effectiveArgs.slice(1);
    switch (command) {
      case "doctor": return this.doctor(rest);
      case "launch": return this.launch(rest);
      case "throwaway": return this.throwaway(rest);
      case "clone": return this.clone(rest);
      case "create": return this.create(rest);
      case "rename": return this.rename(rest);
      case "path": return this.changePath(rest);
      case "delete": return this.delete(rest);
      case "list": return this.list();
      case "review": return this.review();
      case "reconcile": return this.reconcile();
      case "cleanup": return this.cleanup(rest);
      case "promote": return this.promote(rest);
      case "repair": return this.repair();
      case "install": return this.install(rest);
      case "update": return this.update(rest);
      case "start": return this.start(rest);
      case "restart": return this.start(rest);
      case "autostart": return this.autostart(rest);
      case "configure": return this.configure(rest);
      case "onboard": return this.onboard(rest);
      case "uninstall": return this.uninstall(rest);
      default:
        throw new Error(`Unsupported command: ${command}`);
    }
  }

  setChannel(channel) {
    this.channel = channel === "dev" ? "dev" : "live";
    this.paths = makePaths(this.channel, this.product || productFromEnvironment());
  }

  setProduct(product) {
    const key = normalizeProduct(product);
    this.product = products[key];
    this.paths = makePaths(this.channel, this.product);
  }

  state() {
    ensureDir(this.paths.appSupport);
    if (!fs.existsSync(this.paths.stateFile)) {
      return { version: 2, homes: [this.mainHome()], instances: [], pinnedHomeIDs: [], preferredTerminal: "terminal", preferences: defaultPreferences(), updater: {} };
    }
    const state = JSON.parse(fs.readFileSync(this.paths.stateFile, "utf8"));
    state.homes ||= [];
    state.instances ||= [];
    state.pinnedHomeIDs ||= [];
    state.preferences = { ...defaultPreferences(), ...(state.preferences || {}) };
    state.updater ||= {};
    state.version = Math.max(Number(state.version) || 1, 2);
    if (!state.homes.some((home) => home.kind === "main")) {
      state.homes.unshift(this.mainHome());
    }
    for (const home of state.homes) {
      if (home.kind === "main") home.usesCustomPath = false;
      else home.usesCustomPath = !isPathInside(home.homePath, this.paths.managedHomes);
    }
    return state;
  }

  save(state) {
    ensureDir(this.paths.appSupport);
    fs.writeFileSync(this.paths.stateFile, `${JSON.stringify(state, null, 2)}\n`);
  }

  mainHome() {
    return {
      id: MAIN_HOME_ID,
      name: "Main",
      slug: "main",
      kind: "main",
      homePath: this.paths.mainHome,
      profilePath: this.paths.normalProfile,
      product: this.product.key,
      createdAt: new Date().toISOString(),
      isTemporary: false
    };
  }

  doctor(args) {
    const report = this.report();
    console.log(`${this.product.label} Multihome Doctor`);
    console.log(`Product: ${this.product.label}`);
    console.log(`Main ${this.product.envName}: ${this.paths.mainHome}`);
    console.log(`Main sessions: ${report.mainSessionCount}`);
    if (this.product.hasDesktop) console.log(`${this.product.label} desktop app: ${report.appPath || "missing"}`);
    else console.log(`${this.product.label} desktop app: terminal-only`);
    console.log(`${this.product.cli} CLI: ${report.cliPath || "missing"}`);
    console.log(`Main auth: ${authStatusLabel(report.authStatus)}`);
    console.log(`Auth mode: ${report.authStatus.mode || "unknown"}`);
    console.log(`Account: ${report.authStatus.accountLabel || "unknown"}`);
    console.log(`User ${this.product.envName}: ${process.env[this.product.envName] || "not set"}`);
    if (report.suspiciousLaunchers.length) {
      console.log("Suspicious launchers:");
      for (const item of report.suspiciousLaunchers) console.log(`  ${item}`);
    } else {
      console.log("Suspicious launchers: none");
    }
    if (args.includes("--repair")) this.repair();
  }

  report() {
    const cliPath = this.findCommand(this.product.cli);
    const appPath = this.product.hasDesktop ? this.findCodexApp() : null;
    const mainAuthStatus = this.product.key === "claude" ? readClaudeAuthStatus(this.paths.mainHome) : readCodexAuthStatus(this.paths.mainHome);
    const notes = [];
    if (process.env[this.product.envName]) notes.push(`This shell has ${this.product.envName} set to ${process.env[this.product.envName]}.`);
    if (!cliPath) notes.push(`The ${this.product.cli} CLI was not found on PATH.`);
    if (this.product.hasDesktop && !appPath) notes.push(`The ${this.product.label} desktop app executable was not found.`);
    return {
      globalHome: process.env[this.product.envName] || null,
      mainSessionCount: sessionCount(this.paths.mainHome),
      suspiciousLaunchers: suspiciousLaunchers(this.paths.desktop),
      cliPath,
      appPath,
      appExists: Boolean(appPath),
      authStatus: mainAuthStatus,
      notes
    };
  }

  launch(args) {
    const selector = args[0] || "main";
    const state = this.state();
    const target = option(args, "--target") || state.preferences.defaultLaunchTarget || "desktop";
    const workspace = option(args, "--workspace") || state.lastWorkspacePath || process.cwd();
    let home;
    if (selector === "temp" || selector === "temporary") {
      home = this.createManagedHome("Temporary", uniqueSlug("temp", state.homes), "temporary", emptyPolicies(), null, true);
    } else {
      home = this.resolveHome(selector, this.state());
    }
    const effectiveTarget = this.product.hasDesktop ? target : "terminal";
    const pid = effectiveTarget === "terminal" ? this.launchTerminal(home, workspace) : this.launchDesktop(home);
    const next = this.state();
    const instance = {
      id: cryptoRandomUUID(),
      homeID: home.id,
      homeName: home.name,
      homePath: home.homePath,
      profilePath: home.profilePath,
      target: effectiveTarget,
      pid,
      workspacePath: workspace,
      terminalApp: target === "terminal" ? "terminal" : null,
      launchedAt: new Date().toISOString(),
      status: pid ? "running" : "unknown",
      cleanupReviewRequired: Boolean(home.isTemporary)
    };
    next.instances.unshift(instance);
    next.lastWorkspacePath = workspace;
    this.save(next);
    console.log(`Launched ${instance.homeName} as ${effectiveTarget}.`);
    console.log(`${this.product.envName}=${instance.homePath}`);
    if (pid) console.log(`pid=${pid}`);
    if (instance.cleanupReviewRequired) console.log(`instance=${instance.id}`);
  }

  launchDesktop(home) {
    ensureDir(home.homePath);
    if (home.profilePath) ensureDir(home.profilePath);
    if (!this.product.hasDesktop) throw new Error(`${this.product.label} Code is terminal-only. Use --target terminal.`);
    const executable = this.findCodexApp();
    if (!executable) throw new Error("Codex desktop app was not found. Use --target terminal or install Codex for Windows.");
    const child = this.spawnProcess(executable, home.profilePath ? [`--user-data-dir=${home.profilePath}`] : [], {
      detached: true,
      stdio: "ignore",
      env: { ...process.env, [this.product.envName]: home.homePath }
    });
    child.unref();
    return child.pid;
  }

  launchTerminal(home, workspace) {
    ensureDir(home.homePath);
    const command = `cd /d ${cmdQuote(workspace)} && set "${this.product.envName}=${home.homePath}" && ${this.product.cli}`;
    const terminal = this.findCommand("wt");
    const title = `${this.product.label} Multihome`;
    const child = terminal
      ? this.spawnProcess(terminal, ["new-tab", "cmd", "/k", command], { detached: true, stdio: "ignore" })
      : this.spawnProcess("cmd.exe", ["/c", "start", title, "cmd", "/k", command], { detached: true, stdio: "ignore" });
    child.unref();
    return child.pid;
  }

  throwaway(args) {
    const target = option(args, "--target") || "desktop";
    const next = ["temp", "--target", target];
    const workspace = option(args, "--workspace");
    if (workspace) next.push("--workspace", workspace);
    this.launch(next);
  }

  clone(args) {
    const state = this.state();
    const preset = option(args, "--preset") || state.preferences.defaultClonePreset || "working-setup";
    const requestedPath = option(args, "--path");
    const name = option(args, "--name") || positionalName(args) || nameFromPath(requestedPath) || "Multihome Clone";
    const sourceSelector = option(args, "--source") || "main";
    const policies = policiesFromArgs(args, preset, state.preferences.clonePolicies);
    const source = hasCopiedPolicy(policies) ? this.resolveHome(sourceSelector, state).homePath : null;
    const home = this.createManagedHome(name, uniqueSlug(slugify(name), state.homes), "clone", policies, source, false, preset, requestedPath);
    printCreatedHome(home, this.product.envName);
  }

  create(args) {
    const kind = option(args, "--kind") || args[0] || "clean-room";
    const requestedPath = option(args, "--path");
    const name = option(args, "--name") || nameFromPath(requestedPath);
    if (kind === "temporary" || kind === "temp") {
      const state = this.state();
      return printCreatedHome(this.createManagedHome(name || "Temporary", uniqueSlug(slugify(name || timestampSlug("temp")), state.homes), "temporary", emptyPolicies(), null, true, "empty", requestedPath), this.product.envName);
    }
    if (kind === "clone") return this.clone(["--name", name || "Multihome Clone", ...args]);
    if (kind !== "clean-room" && kind !== "cleanRoom") throw new Error(`Unsupported command: create ${kind}`);
    const state = this.state();
    printCreatedHome(this.createManagedHome(name || "Clean Room", uniqueSlug(slugify(name || timestampSlug("clean-room")), state.homes), "cleanRoom", emptyPolicies(), null, false, "empty", requestedPath), this.product.envName);
  }

  createManagedHome(name, slug, kind, policies, source, temporary, preset = "working-setup", requestedHomePath = null) {
    ensureDir(this.paths.managedHomes);
    ensureDir(this.paths.profiles);
    const homePath = path.resolve(requestedHomePath || path.join(this.paths.managedHomes, slug));
    const profilePath = path.join(this.paths.profiles, slug);
    if (fs.existsSync(homePath)) throw new Error(`${this.product.label} home already exists: ${homePath}`);
    ensureDir(homePath);
    try {
      if (source) materializeHome(source, homePath, policies);
      ensureDir(profilePath);
      const home = {
        id: cryptoRandomUUID(),
        name,
        slug,
        kind,
        product: this.product.key,
        homePath,
        profilePath,
        sourceHomePath: source || undefined,
        clonePreset: source ? preset : undefined,
        cloneMaterialization: source ? materializationForPolicies(policies) : undefined,
        clonePolicies: source ? policies : undefined,
        createdAt: new Date().toISOString(),
        isTemporary: temporary
      };
      home.usesCustomPath = !isPathInside(homePath, this.paths.managedHomes);
      const state = this.state();
      state.homes.push(home);
      this.save(state);
      return home;
    } catch (error) {
      fs.rmSync(homePath, { recursive: true, force: true });
      fs.rmSync(profilePath, { recursive: true, force: true });
      throw error;
    }
  }

  rename(args) {
    const selector = args[0];
    const name = option(args, "--name");
    if (!selector || !name) return this.printHelp("rename");
    const state = this.state();
    const index = state.homes.findIndex((home) => matchesHome(home, selector));
    if (index < 0) throw new Error(`${this.product.label} home does not exist: ${selector}`);
    if (state.homes[index].kind === "main") throw new Error(`The main ${this.paths.mainHomeName} home cannot be renamed.`);
    const oldHomePath = state.homes[index].homePath;
    const oldProfilePath = state.homes[index].profilePath;
    const newSlug = uniqueSlug(slugify(name), state.homes.filter((_, i) => i !== index));
    if (args.includes("--move-folders")) {
      const newHomePath = path.join(this.paths.managedHomes, newSlug);
      const newProfilePath = path.join(this.paths.profiles, newSlug);
      if (fs.existsSync(newHomePath)) throw new Error(`${this.product.label} home already exists: ${newHomePath}`);
      if (fs.existsSync(newProfilePath)) throw new Error(`${this.product.label} home already exists: ${newProfilePath}`);
      fs.renameSync(oldHomePath, newHomePath);
      if (oldProfilePath && fs.existsSync(oldProfilePath)) fs.renameSync(oldProfilePath, newProfilePath);
      state.homes[index].homePath = newHomePath;
      state.homes[index].profilePath = newProfilePath;
      for (const home of state.homes) if (home.sourceHomePath === oldHomePath) home.sourceHomePath = newHomePath;
      for (const instance of state.instances) if (instance.homeID === state.homes[index].id) instance.homePath = newHomePath;
    }
    state.homes[index].name = name.trim();
    state.homes[index].slug = newSlug;
    for (const instance of state.instances) if (instance.homeID === state.homes[index].id) instance.homeName = name.trim();
    this.save(state);
    console.log(`Renamed ${selector} to ${name.trim()}${args.includes("--move-folders") ? " and moved managed folders" : ""}.`);
  }

  changePath(args) {
    const selector = args[0];
    const requestedPath = option(args, "--path");
    if (!selector || !requestedPath) return this.printHelp("path");
    const state = this.state();
    const index = state.homes.findIndex((home) => matchesHome(home, selector));
    if (index < 0) throw new Error(`${this.product.label} home does not exist: ${selector}`);
    const home = state.homes[index];
    if (home.kind === "main") throw new Error(`The main ${this.paths.mainHomeName} home path cannot be changed.`);
    const oldPath = path.resolve(home.homePath);
    const newPath = path.resolve(requestedPath);
    if (samePath(oldPath, newPath)) return;
    if (args.includes("--move")) {
      if (fs.existsSync(newPath)) throw new Error(`${this.product.label} home already exists: ${newPath}`);
      ensureDir(path.dirname(newPath));
      fs.renameSync(oldPath, newPath);
    } else if (!fs.existsSync(newPath) || !fs.statSync(newPath).isDirectory()) {
      throw new Error(`Use --move to relocate the existing home, or select an existing directory: ${newPath}`);
    }
    home.homePath = newPath;
    home.usesCustomPath = !isPathInside(newPath, this.paths.managedHomes);
    for (const candidate of state.homes) if (samePath(candidate.sourceHomePath, oldPath)) candidate.sourceHomePath = newPath;
    for (const instance of state.instances) if (instance.homeID === home.id) instance.homePath = newPath;
    this.save(state);
    console.log(`${args.includes("--move") ? "Moved" : "Adopted"} ${home.name}: ${newPath}`);
  }

  delete(args) {
    const selector = args[0];
    if (!selector) return this.printHelp("delete");
    const state = this.state();
    const index = state.homes.findIndex((home) => matchesHome(home, selector));
    if (index < 0) throw new Error(`${this.product.label} home does not exist: ${selector}`);
    const home = state.homes[index];
    if (home.kind === "main") throw new Error(`The main ${this.paths.mainHomeName} home cannot be deleted.`);
    const targets = cleanupTargets(home, this.paths, args.includes("--remove-files"));
    if (home.usesCustomPath && !args.includes("--remove-files")) {
      console.log(`Preserved custom home path: ${home.homePath} (pass --remove-files to move it to Trash)`);
    }
    for (const target of targets) moveToTrash(target, this.paths.trash);
    state.homes.splice(index, 1);
    state.pinnedHomeIDs = state.pinnedHomeIDs.filter((id) => id !== home.id);
    for (const instance of state.instances) if (instance.homeID === home.id) instance.status = "cleaned";
    this.save(state);
    console.log("Moved to Trash:");
    for (const target of targets) console.log(`- ${target}`);
  }

  list() {
    const state = this.state();
    if (reconcileInstances(state)) this.save(state);
    console.log("Homes");
    for (const home of state.homes) {
      console.log(`- ${home.slug}: ${home.name} [${home.kind}${home.isTemporary ? " temporary" : ""}]`);
      console.log(`  home: ${home.homePath}`);
      if (home.profilePath) console.log(`  profile: ${home.profilePath}`);
      if (home.sourceHomePath) console.log(`  source: ${home.sourceHomePath}`);
      if (home.clonePolicies) console.log(`  policies: ${policySummary(home.clonePolicies)}`);
    }
    if (state.instances.length) {
      console.log("");
      console.log("Instances");
      for (const instance of state.instances.slice(0, 20)) console.log(`- ${instance.id} ${instance.homeName} ${instance.target} ${instance.status}`);
    }
  }

  review() {
    const state = this.state();
    if (reconcileInstances(state)) this.save(state);
    const pending = state.instances.filter((instance) => instance.cleanupReviewRequired);
    if (!pending.length) {
      console.log("No temporary homes need cleanup review.");
      return;
    }
    console.log("Cleanup Review");
    for (const instance of pending) {
      console.log(`- ${instance.id} ${instance.homeName} ${instance.status}`);
      console.log(`  home: ${instance.homePath}`);
      if (instance.profilePath) console.log(`  profile: ${instance.profilePath}`);
      console.log(`  actions: ${COMMAND} cleanup ${instance.id} | ${COMMAND} promote ${instance.id}`);
    }
  }

  reconcile() {
    const state = this.state();
    if (reconcileInstances(state)) this.save(state);
  }

  cleanup(args) {
    const id = args[0];
    if (!id) return this.printHelp("cleanup");
    const state = this.state();
    const instance = state.instances.find((item) => item.id === id);
    if (!instance) return;
    const index = state.homes.findIndex((home) => home.id === instance.homeID);
    if (index < 0) return;
    const home = state.homes[index];
    const targets = cleanupTargets(home, this.paths, args.includes("--remove-files"));
    if (home.usesCustomPath && !args.includes("--remove-files")) {
      throw new Error(`Temporary home uses a custom path. Pass --remove-files to move it to Trash: ${home.homePath}`);
    }
    for (const target of targets) moveToTrash(target, this.paths.trash);
    state.homes.splice(index, 1);
    instance.status = "cleaned";
    instance.cleanupReviewRequired = false;
    this.save(state);
    console.log("Cleaned:");
    for (const target of targets) console.log(`- ${target}`);
  }

  promote(args) {
    const id = args[0];
    if (!id) return this.printHelp("promote");
    const state = this.state();
    const instance = state.instances.find((item) => item.id === id);
    if (!instance) return;
    const home = state.homes.find((item) => item.id === instance.homeID);
    if (!home) return;
    const name = option(args, "--name");
    if (name) {
      home.name = name;
      home.slug = uniqueSlug(slugify(name), state.homes.filter((item) => item.id !== home.id));
    }
    home.isTemporary = false;
    home.kind = "clone";
    home.promotedAt = new Date().toISOString();
    instance.status = "promoted";
    instance.cleanupReviewRequired = false;
    this.save(state);
    console.log(`Promoted ${id}.`);
  }

  repair() {
    console.log(`Windows has no launchctl GUI ${this.product.envName} to clear. Close shells that set ${this.product.envName} or remove it from your user environment.`);
  }

  configure(args) {
    const state = this.state();
    if (args.includes("--reset")) {
      state.preferences = defaultPreferences();
      state.preferredTerminal = "terminal";
      delete state.lastWorkspacePath;
      this.save(state);
      console.log("Reset Multihome preferences to defaults.");
      return;
    }
    const terminal = option(args, "--terminal");
    if (terminal) {
      state.preferredTerminal = terminal;
      console.log(`Preferred terminal: ${terminal}`);
    }
    const workspace = option(args, "--workspace");
    if (workspace) {
      state.lastWorkspacePath = workspace;
      console.log(`Default workspace: ${workspace}`);
    }
    const target = option(args, "--launch-target");
    if (target) {
      state.preferences.defaultLaunchTarget = target;
      console.log(`Default launch target: ${target}`);
    }
    const preset = option(args, "--clone-preset");
    if (preset) {
      state.preferences.defaultClonePreset = preset;
      state.preferences.clonePolicies = presetPolicies(preset);
      state.preferences.cloneMaterialization = materializationForPolicies(state.preferences.clonePolicies);
      console.log(`Default clone preset: ${preset}`);
    }
    const include = option(args, "--clone-include");
    if (include) {
      applyPolicyList(state.preferences.clonePolicies, include, "copy");
      state.preferences.defaultClonePreset = presetForPolicies(state.preferences.clonePolicies);
      state.preferences.cloneMaterialization = materializationForPolicies(state.preferences.clonePolicies);
      console.log(`Clone include: ${include}`);
    }
    const exclude = option(args, "--clone-exclude");
    if (exclude) {
      applyPolicyList(state.preferences.clonePolicies, exclude, "skip");
      state.preferences.defaultClonePreset = presetForPolicies(state.preferences.clonePolicies);
      state.preferences.cloneMaterialization = materializationForPolicies(state.preferences.clonePolicies);
      console.log(`Clone exclude: ${exclude}`);
    }
    const temporary = option(args, "--temporary");
    if (temporary) {
      state.preferences.launchTemporaryByDefault = onOff(temporary, state.preferences.launchTemporaryByDefault);
      console.log(`Temporary by default: ${state.preferences.launchTemporaryByDefault ? "on" : "off"}`);
    }
    const installApp = option(args, "--install-app");
    if (installApp) {
      state.preferences.installAppByDefault = onOff(installApp, state.preferences.installAppByDefault);
      console.log(`Install app by default: ${state.preferences.installAppByDefault ? "on" : "off"}`);
    }
    const updateChecks = option(args, "--update-checks");
    if (updateChecks) {
      state.preferences.autoUpdateChecksEnabled = onOff(updateChecks, state.preferences.autoUpdateChecksEnabled);
      if (!state.preferences.autoUpdateChecksEnabled) state.preferences.autoInstallUpdates = false;
      console.log(`Update checks: ${state.preferences.autoUpdateChecksEnabled ? "on" : "off"}`);
    }
    const updateInterval = option(args, "--update-interval");
    if (updateInterval) {
      state.preferences.updateCheckInterval = updateInterval;
      console.log(`Update interval: ${updateInterval}`);
    }
    const autoInstallUpdates = option(args, "--auto-install-updates");
    if (autoInstallUpdates) {
      state.preferences.autoInstallUpdates = onOff(autoInstallUpdates, state.preferences.autoInstallUpdates);
      if (state.preferences.autoInstallUpdates) state.preferences.autoUpdateChecksEnabled = true;
      console.log(`Auto-install updates: ${state.preferences.autoInstallUpdates ? "on" : "off"}`);
    }
    if (args.includes("--show")) {
      console.log(`Channel: ${this.channel}`);
      console.log(`State: ${this.paths.stateFile}`);
      console.log(`Managed homes: ${this.paths.managedHomes}`);
      console.log(`Default target: ${state.preferences.defaultLaunchTarget}`);
      console.log(`Default clone: ${state.preferences.defaultClonePreset}`);
      console.log(`Clone policies: ${policySummary(state.preferences.clonePolicies)}`);
      console.log(`Workspace: ${state.lastWorkspacePath || "not set"}`);
    }
    this.save(state);
    const autostart = option(args, "--autostart");
    if (autostart) {
      if (autostart === "status") this.autostart(["status"]);
      else this.autostart([onOff(autostart, false) ? "enable" : "disable"]);
    }
  }

  install(args) {
    const prefix = option(args, "--prefix") || path.join(os.homedir(), "bin");
    ensureDir(prefix);
    const shim = path.join(prefix, `${COMMAND}.cmd`);
    const script = `@echo off\r\nnode "${path.join(this.packageRoot, "codex-multihome.js")}" %*\r\n`;
    fs.writeFileSync(shim, script);
    console.log(`Installed CLI shim: ${shim}`);
    if (args.includes("--with-app")) {
      const app = this.installTrayApp(option(args, "--app-dir"));
      console.log(`Installed tray app: ${app.launcher}`);
    }
  }

  update(args) {
    console.log("For npm installs, update Windows Multihome with: npm install -g codex-multihome-windows@latest");
    this.install(args);
  }

  start(args) {
    const app = this.installedTrayApp(option(args, "--app-dir"));
    if (!fs.existsSync(app.trayScript)) {
      throw new Error(`Codex Multihome tray app was not found at ${app.trayScript}. Run ${COMMAND} install --with-app first.`);
    }
    if (environmentValue("CODEX_MULTIHOME_TEST_SKIP_START", "HOMEPORT_TEST_SKIP_START") === "1") {
      console.log(`Started Codex Multihome: ${app.launcher}`);
      return;
    }
    const startArgs = [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-WindowStyle",
      "Hidden",
      "-File",
      app.trayScript,
      "-HomeportScript",
      path.join(this.packageRoot, "codex-multihome.js"),
      "-WorkingDirectory",
      process.cwd(),
      "-Channel",
      this.channel
    ];
    const command = `$arguments = @(${startArgs.map(powerShellSingleQuote).join(", ")}); Start-Process -FilePath powershell.exe -ArgumentList $arguments -WindowStyle Hidden`;
    const result = spawnSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", command], { encoding: "utf8" });
    if (result.status !== 0) {
      throw new Error(result.stderr || result.stdout || "Failed to start Codex Multihome tray app.");
    }
    console.log(`Started Codex Multihome: ${app.launcher}`);
  }

  autostart(args) {
    const action = args[0] || "status";
    const taskName = this.channel === "dev" ? "Codex Multihome Dev" : "Codex Multihome";
    if (environmentValue("CODEX_MULTIHOME_TEST_SKIP_SCHTASKS", "HOMEPORT_TEST_SKIP_SCHTASKS") === "1") {
      console.log(`Autostart (live): ${action === "status" ? "disabled" : `${action} skipped in tests`}`);
      return;
    }
    if (action === "status") {
      const result = spawnSync("schtasks.exe", ["/Query", "/TN", taskName], { encoding: "utf8" });
      console.log(`Autostart (live): ${result.status === 0 ? "enabled" : "disabled"}`);
      return;
    }
    if (action === "disable" || action === "off") {
      spawnSync("schtasks.exe", ["/Delete", "/TN", taskName, "/F"], { stdio: "ignore" });
      console.log("Autostart disabled.");
      return;
    }
    if (action === "enable" || action === "on") {
      const app = this.installedTrayApp(option(args, "--app-dir"));
      if (!fs.existsSync(app.launcher)) {
        throw new Error(`Codex Multihome tray app was not found at ${app.launcher}. Run ${COMMAND} install --with-app first.`);
      }
      const command = `"${app.launcher}"`;
      const result = spawnSync("schtasks.exe", ["/Create", "/SC", "ONLOGON", "/TN", taskName, "/TR", command, "/F"], { encoding: "utf8" });
      if (result.status !== 0) throw new Error(result.stderr || result.stdout || "schtasks failed");
      console.log("Autostart enabled.");
      return;
    }
    throw new Error(`Unsupported command: autostart ${action}`);
  }

  onboard(args) {
    const installArgs = [...args];
    if (!installArgs.includes("--with-app") && !installArgs.includes("--no-app")) {
      installArgs.push("--with-app");
    }
    this.install(installArgs.filter((arg) => arg !== "--no-app"));
    const state = this.state();
    const workspace = option(args, "--workspace");
    if (workspace) state.lastWorkspacePath = workspace;
    this.save(state);
    if (!args.includes("--no-autostart")) this.autostart(["enable"]);
    if (!args.includes("--no-start")) this.start([]);
  }

  uninstall(args) {
    this.autostart(["disable"]);
    if (args.includes("--remove-app")) {
      const app = this.installedTrayApp(option(args, "--app-dir"));
      moveToTrash(app.directory, this.paths.trash);
      console.log(`Moved tray app to Trash: ${app.directory}`);
    }
    if (args.includes("--remove-cli")) {
      const cli = option(args, "--cli") || path.join(os.homedir(), "bin", `${COMMAND}.cmd`);
      fs.rmSync(cli, { force: true });
      console.log(`Removed CLI: ${cli}`);
    }
    if (args.includes("--remove-state")) {
      moveToTrash(this.paths.appSupport, this.paths.trash);
      console.log(`Moved state to Trash: ${this.paths.appSupport}`);
    }
    if (args.includes("--remove-managed-homes")) {
      moveToTrash(this.paths.managedHomes, this.paths.trash);
      console.log(`Moved managed homes to Trash: ${this.paths.managedHomes}`);
    }
  }

  resolveHome(selector, state) {
    if (selector === "main") return state.homes.find((home) => home.kind === "main") || this.mainHome();
    const home = state.homes.find((item) => matchesHome(item, selector));
    if (!home) throw new Error(`${this.product.label} home does not exist: ${selector}`);
    return home;
  }

  installTrayApp(appDir) {
    const app = this.installedTrayApp(appDir);
    ensureDir(app.directory);
    const traySource = path.join(this.packageRoot, "codex-multihome-tray.ps1");
    const trayScript = path.join(app.directory, "codex-multihome-tray.ps1");
    fs.copyFileSync(traySource, trayScript);
    const homeportScript = path.join(this.packageRoot, "codex-multihome.js");
    const launcher = [
      "@echo off",
      "setlocal",
      `powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "${trayScript}" -HomeportScript "${homeportScript}" -WorkingDirectory "%CD%" -Channel "${this.channel}"`,
      ""
    ].join("\r\n");
    fs.writeFileSync(app.launcher, launcher);
    return app;
  }

  installedTrayApp(appDir) {
    const appSupportName = this.channel === "dev" ? "CodexMultihomeDev" : "CodexMultihome";
    const directory = path.resolve(appDir || path.join(this.paths.localAppData, appSupportName, "App"));
    return {
      directory,
      launcher: path.join(directory, `${this.channel === "dev" ? "Codex Multihome Dev" : "Codex Multihome"}.cmd`),
      trayScript: path.join(directory, "codex-multihome-tray.ps1")
    };
  }

  printHelp(topic) {
    if (topic) {
      console.log(`Use: ${COMMAND} ${topic} [options]`);
      return;
    }
    console.log(`Codex Multihome for Windows

Usage:
  codex-multihome <command> [options]

Daily commands:
  start        Start the installed Windows tray app
  launch       Open Codex using main, temporary, or named homes
  throwaway    Open a temporary Codex desktop or terminal session
  list         Show homes and recent launched instances
  review       Show temporary homes waiting for cleanup review
  doctor       Diagnose Codex state and launch-environment problems

Home commands:
  clone        Create a managed Codex or Claude home from the selected product's main home
  create       Create a clean-room, temporary, or cloned home
  rename       Rename a managed home
  path         Change, move, or adopt a managed home's CODEX_HOME path
  delete       Move a managed home/profile to Multihome Trash
  cleanup      Move a temporary home/profile to Multihome Trash after review
  promote      Keep a temporary home as a saved managed home

Setup commands:
  install      Install the CLI shim, optionally the Windows tray app
  autostart    Enable, disable, or show scheduled-task login autostart
  uninstall    Remove installed app/autostart entries; extra removals are opt-in

Examples:
  codex-multihome install --with-app
  codex-multihome start
  codex-multihome launch main --target terminal
  codex-multihome launch temp --target desktop
  codex-multihome clone --preset working-setup --name "Plugin Lab"
  codex-multihome configure --show`);
  }
}

function channelFromEnvironment() {
  return environmentValue("CODEX_MULTIHOME_CHANNEL", "HOMEPORT_CHANNEL") === "dev" ? "dev" : "live";
}

function productFromEnvironment() {
  return products[normalizeProduct(environmentValue("CODEX_MULTIHOME_PRODUCT", "HOMEPORT_PRODUCT") || process.env.HOMEPORT_TOOL || "codex")];
}

function normalizeProduct(product) {
  const key = String(product || "codex").toLowerCase();
  if (key === "claude" || key === "claude-code" || key === "claude_code") return "claude";
  return "codex";
}

function makePaths(channel = channelFromEnvironment(), product = productFromEnvironment()) {
  const profile = typeof product === "string" ? products[normalizeProduct(product)] : product;
  const home = os.homedir();
  const appData = process.env.APPDATA || path.join(home, "AppData", "Roaming");
  const localAppData = process.env.LOCALAPPDATA || path.join(home, "AppData", "Local");
  const appSupportName = channel === "dev" ? profile.appSupportDevName : profile.appSupportName;
  const managedHomesName = channel === "dev" ? profile.managedHomesDevName : profile.managedHomesName;
  const appSupport = path.join(appData, appSupportName);
  const mainHome = profile.key === "claude" && process.env.CLAUDE_CONFIG_DIR ? process.env.CLAUDE_CONFIG_DIR : path.join(home, profile.mainHomeName);
  return {
    channel,
    product: profile.key,
    label: profile.label,
    envName: profile.envName,
    cli: profile.cli,
    home,
    appData,
    localAppData,
    mainHome,
    mainHomeName: profile.mainHomeName,
    managedHomes: path.join(home, managedHomesName),
    appSupport,
    profiles: path.join(appSupport, "Profiles"),
    stateFile: path.join(appSupport, "homeport.json"),
    trash: path.join(appSupport, "Trash"),
    normalProfile: profile.normalProfileName ? path.join(appData, profile.normalProfileName) : null,
    desktop: path.join(home, "Desktop")
  };
}

function defaultPreferences() {
  return {
    defaultLaunchTarget: "terminal",
    defaultClonePreset: "working-setup",
    cloneSourceSelector: "main",
    cloneMaterialization: "copy",
    clonePolicies: presetPolicies("working-setup"),
    launchTemporaryByDefault: false,
    onboardEnablesAutostart: true,
    installAppByDefault: false,
    autoUpdateChecksEnabled: true,
    autoInstallUpdates: false,
    updateCheckInterval: "daily"
  };
}

function presetPolicies(preset) {
  if (preset === "empty") return emptyPolicies();
  if (preset === "config-only") {
    return { ...emptyPolicies(), instructions: "copy", config: "copy", skills: "copy", plugins: "copy", prompts: "copy", rules: "copy", profiles: "copy", agents: "copy", commands: "copy", workflows: "copy", outputStyles: "copy" };
  }
  if (preset === "everything") return Object.fromEntries(Object.keys(categories).map((key) => [key, "copy"]));
  return { ...presetPolicies("everything"), sessions: "skip" };
}

function emptyPolicies() {
  return Object.fromEntries(Object.keys(categories).map((key) => [key, "skip"]));
}

function presetForPolicies(policies) {
  const entries = Object.entries(policies);
  if (entries.every(([, policy]) => policy === "skip")) return "empty";
  if (entries.every(([, policy]) => policy !== "skip")) return "everything";
  const configOnly = presetPolicies("config-only");
  if (Object.keys(categories).every((key) => policies[key] === configOnly[key])) return "config-only";
  return "working-setup";
}

function policiesFromArgs(args, preset, base) {
  let policies = { ...(base || presetPolicies(preset)) };
  if (option(args, "--preset")) policies = presetPolicies(preset);
  if (args.includes("--link-safe")) {
    for (const key of linkable) if (policies[key] !== "skip" && key !== "auth") policies[key] = "link";
  }
  if (args.includes("--link-auth") && policies.auth !== "skip") policies.auth = "link";
  applyPolicyList(policies, option(args, "--include"), "copy");
  applyPolicyList(policies, option(args, "--exclude"), "skip");
  applyPolicyList(policies, option(args, "--link"), "link");
  return policies;
}

function hasCopiedPolicy(policies) {
  return Object.values(policies).some((policy) => policy !== "skip");
}

function applyPolicyList(policies, list, policy) {
  if (!list) return;
  for (const raw of list.split(",")) {
    const key = normalizeCategory(raw.trim());
    if (!key) continue;
    if (key === "all") {
      for (const category of Object.keys(policies)) policies[category] = policy === "link" && !linkable.has(category) ? "copy" : policy;
    } else {
      policies[key] = policy === "link" && !linkable.has(key) ? "copy" : policy;
    }
  }
}

function normalizeCategory(token) {
  if (token === "config.toml") return "config";
  if (token === "agents.md" || token === "agent.md" || token === "claude.md" || token === "cloud.md" || token === "instructions" || token === "memory") return "instructions";
  if (token === "browser-support" || token === "chrome") return "browser";
  if (token === "sessions" || token === "logs" || token === "history") return "sessions";
  if (token === "output-styles" || token === "output_styles") return "outputStyles";
  if (token === "everything" || token === "all") return "all";
  return Object.hasOwn(categories, token) ? token : null;
}

function materializeHome(source, destination, policies) {
  if (!fs.existsSync(source)) throw new Error(`Codex home does not exist: ${source}`);
  const names = new Map();
  for (const [category, categoryPaths] of Object.entries(categories)) {
    const policy = policies[category] || "skip";
    if (policy === "skip") continue;
    for (const item of categoryPaths) names.set(item, policy === "link" && linkable.has(category) ? "link" : "copy");
  }
  const copyEverything = Object.values(policies).every((policy) => policy !== "skip");
  if (copyEverything) {
    for (const item of fs.readdirSync(source)) if (!names.has(item)) copyItem(path.join(source, item), path.join(destination, item));
  }
  for (const [item, policy] of names) {
    const from = path.join(source, item);
    if (!fs.existsSync(from)) continue;
    const to = path.join(destination, item);
    if (policy === "link") linkItem(from, to);
    else copyItem(from, to);
  }
}

function linkItem(from, to) {
  fs.rmSync(to, { recursive: true, force: true });
  const stats = fs.statSync(from);
  if (stats.isDirectory()) {
    fs.symlinkSync(fs.realpathSync(from), to, "junction");
    return;
  }
  try {
    fs.symlinkSync(fs.realpathSync(from), to, "file");
  } catch (error) {
    if (process.platform !== "win32" || error.code !== "EPERM") throw error;
    fs.linkSync(fs.realpathSync(from), to);
  }
}

function copyItem(from, to) {
  fs.rmSync(to, { recursive: true, force: true });
  fs.cpSync(from, to, { recursive: true, verbatimSymlinks: true });
}

function moveToTrash(target, trashRoot) {
  if (!fs.existsSync(target)) return;
  const resolvedTarget = path.resolve(target);
  let resolvedTrashRoot = path.resolve(trashRoot);
  if (resolvedTrashRoot === resolvedTarget || resolvedTrashRoot.startsWith(`${resolvedTarget}${path.sep}`)) {
    resolvedTrashRoot = path.join(path.dirname(resolvedTarget), `${path.basename(resolvedTarget)} Trash`);
  }
  ensureDir(resolvedTrashRoot);
  const stamp = new Date().toISOString().replace(/[:.]/g, "-");
  const destination = path.join(resolvedTrashRoot, `${stamp}-${path.basename(target)}`);
  fs.renameSync(target, destination);
}

function cleanupTargets(home, paths, removeCustom = false) {
  const targets = [];
  if (home.homePath && (removeCustom || isPathInside(home.homePath, paths.managedHomes))) targets.push(home.homePath);
  if (home.profilePath && isPathInside(home.profilePath, paths.profiles)) targets.push(home.profilePath);
  return targets;
}

function nameFromPath(value) {
  if (!value) return null;
  return path.basename(path.resolve(value)) || null;
}

function samePath(left, right) {
  if (!left || !right) return false;
  return path.resolve(left).toLowerCase() === path.resolve(right).toLowerCase();
}

function isPathInside(candidate, parent) {
  if (!candidate || !parent) return false;
  const resolvedCandidate = path.resolve(candidate).toLowerCase();
  const resolvedParent = path.resolve(parent).toLowerCase();
  return resolvedCandidate === resolvedParent || resolvedCandidate.startsWith(`${resolvedParent}${path.sep}`);
}

function reconcileInstances(state) {
  const running = state.instances.filter((instance) => instance.status === "running" && instance.pid);
  if (!running.length) return false;
  const liveProcessIDs = runningProcessIDs(running.map((instance) => Number(instance.pid)));
  if (!liveProcessIDs) return false;
  let changed = false;
  for (const instance of running) {
    if (!liveProcessIDs.has(Number(instance.pid))) {
      instance.status = "closed";
      instance.closedAt ||= new Date().toISOString();
      changed = true;
    }
  }
  return changed;
}

function runningProcessIDs(requested) {
  if (environmentValue("CODEX_MULTIHOME_TEST_ASSUME_RUNNING", "HOMEPORT_TEST_ASSUME_RUNNING") === "1") return new Set(requested);
  if (process.platform !== "win32") return new Set(requested);
  const result = spawnSync("tasklist.exe", ["/FO", "CSV", "/NH"], { encoding: "utf8" });
  if (result.error || result.status !== 0) return null;
  const ids = new Set();
  for (const line of result.stdout.split(/\r?\n/)) {
    const match = line.match(/^"[^"]+","(\d+)"/);
    if (match) ids.add(Number(match[1]));
  }
  return ids;
}

function environmentValue(primary, legacy) {
  return process.env[primary] ?? process.env[legacy];
}

function findCodexApp() {
  const override = environmentValue("CODEX_MULTIHOME_CODEX_APP", "HOMEPORT_CODEX_APP");
  if (override && fs.existsSync(override)) return path.resolve(override);
  const paths = makePaths();
  const candidates = [
    findPackagedCodexApp(),
    path.join(paths.localAppData, "Programs", "Codex", "Codex.exe"),
    path.join(paths.localAppData, "Programs", "codex", "Codex.exe"),
    path.join(paths.localAppData, "Codex", "Codex.exe"),
    path.join(paths.localAppData, "Programs", "OpenAI Codex", "Codex.exe"),
    path.join(paths.localAppData, "Programs", "OpenAI", "Codex.exe"),
    path.join(process.env.ProgramFiles || "C:\\Program Files", "Codex", "Codex.exe"),
    path.join(process.env.ProgramFiles || "C:\\Program Files", "OpenAI Codex", "Codex.exe"),
    path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)", "Codex", "Codex.exe")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function findPackagedCodexApp() {
  const result = spawnSync("powershell.exe", [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    "(Get-AppxPackage -Name OpenAI.Codex -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty InstallLocation)"
  ], { encoding: "utf8" });
  if (result.status !== 0) return null;
  const installLocation = result.stdout.split(/\r?\n/).map((line) => line.trim()).find(Boolean);
  if (!installLocation) return null;
  const candidates = [
    path.join(installLocation, "app", "ChatGPT.exe"),
    path.join(installLocation, "app", "Codex.exe")
  ];
  return candidates.find((candidate) => fs.existsSync(candidate)) || null;
}

function findCommand(command) {
  const result = spawnSync("where.exe", [command], { encoding: "utf8" });
  if (result.status === 0) {
    const discovered = result.stdout.split(/\r?\n/).map((line) => line.trim()).find(Boolean);
    if (discovered) return discovered;
  }
  const extensions = command.includes(".") ? [""] : (process.env.PATHEXT || ".COM;.EXE;.BAT;.CMD").split(";");
  for (const directory of (process.env.PATH || "").split(path.delimiter).filter(Boolean)) {
    for (const extension of ["", ...extensions]) {
      const candidate = path.join(directory.replace(/^"|"$/g, ""), `${command}${extension}`);
      if (fs.existsSync(candidate)) return candidate;
    }
  }
  return null;
}

function sessionCount(home) {
  const file = path.join(home, "session_index.jsonl");
  if (!fs.existsSync(file)) return 0;
  return fs.readFileSync(file, "utf8").split(/\r?\n/).filter(Boolean).length;
}

function suspiciousLaunchers(desktop) {
  if (!fs.existsSync(desktop)) return [];
  return fs.readdirSync(desktop)
    .filter((name) => name.endsWith(".cmd") || name.endsWith(".bat") || name.endsWith(".ps1"))
    .map((name) => path.join(desktop, name))
    .filter((file) => fs.readFileSync(file, "utf8").includes("Deckhand\\CodexHome") || fs.readFileSync(file, "utf8").includes("Deckhand/CodexHome"));
}

function readCodexAuthStatus(home) {
  const file = path.join(home, "auth.json");
  if (!fs.existsSync(file)) return { isLoggedIn: false, hasStoredCredentials: false, usageSummary: "Usage unavailable" };
  try {
    const auth = JSON.parse(fs.readFileSync(file, "utf8"));
    const tokens = auth.tokens || {};
    return {
      isLoggedIn: false,
      hasStoredCredentials: Boolean(tokens.access_token || tokens.refresh_token || tokens.api_key),
      mode: auth.auth_mode,
      accountLabel: accountLabel(tokens.id_token) || (tokens.account_id ? `account ${String(tokens.account_id).slice(0, 8)}` : undefined),
      detail: "Stored credentials found in this home",
      usageSummary: "Usage unavailable"
    };
  } catch {
    return { isLoggedIn: false, hasStoredCredentials: false, usageSummary: "Usage unavailable" };
  }
}

function readClaudeAuthStatus(home) {
  const candidates = ["auth.json", ".credentials.json", "oauth_creds.json", "settings.json", "claude.json"];
  const found = candidates.map((name) => path.join(home, name)).find((file) => fs.existsSync(file));
  if (!found) return { isLoggedIn: false, hasStoredCredentials: false, usageSummary: "Usage unavailable" };
  try {
    const raw = fs.readFileSync(found, "utf8");
    const parsed = JSON.parse(raw);
    return {
      isLoggedIn: false,
      hasStoredCredentials: true,
      mode: parsed.auth_mode || parsed.authMode || parsed.oauth ? "stored" : undefined,
      accountLabel: parsed.email || parsed.accountEmail || parsed.account?.email || undefined,
      detail: `Stored Claude data found in ${path.basename(found)}`,
      usageSummary: "Usage unavailable"
    };
  } catch {
    return {
      isLoggedIn: false,
      hasStoredCredentials: true,
      detail: `Stored Claude data found in ${path.basename(found)}`,
      usageSummary: "Usage unavailable"
    };
  }
}

function accountLabel(idToken) {
  if (!idToken) return null;
  const payload = idToken.split(".")[1];
  if (!payload) return null;
  try {
    const claims = JSON.parse(Buffer.from(payload.replace(/-/g, "+").replace(/_/g, "/"), "base64url").toString("utf8"));
    return claims.email || claims.preferred_username || claims.name || claims.sub || null;
  } catch {
    return null;
  }
}

function authStatusLabel(status) {
  if (status.isLoggedIn) return "logged in";
  if (status.hasStoredCredentials) return "stored";
  return "not found";
}

function option(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

function removeOption(args, name) {
  const next = [];
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === name) {
      index += 1;
      continue;
    }
    next.push(args[index]);
  }
  return next;
}

function positionalName(args) {
  const valueOptions = new Set(["--name", "--preset", "--source", "--path", "--kind", "--target", "--workspace", "--channel", "--product", "--tool"]);
  return args.find((arg, index) => !arg.startsWith("--") && !valueOptions.has(args[index - 1]));
}

function slugify(raw) {
  const slug = String(raw).toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  return slug || "home";
}

function uniqueSlug(base, homes) {
  const existing = new Set(homes.map((home) => home.slug));
  if (!existing.has(base)) return base;
  let index = 2;
  while (existing.has(`${base}-${index}`)) index += 1;
  return `${base}-${index}`;
}

function timestampSlug(prefix) {
  return `${prefix}-${new Date().toISOString().slice(0, 19).replace(/[-:T]/g, "").replace(/^(\d{8})(\d{6})$/, "$1-$2")}`;
}

function matchesHome(home, selector) {
  return home.slug === selector || home.name === selector;
}

function materializationForPolicies(policies) {
  if (policies.auth === "link") return "linkSafeCustomizationsAndAuth";
  if (Object.entries(policies).some(([key, policy]) => policy === "link" && key !== "auth")) return "linkSafeCustomizations";
  return "copy";
}

function onOff(value, current) {
  switch (String(value).toLowerCase()) {
    case "on":
    case "yes":
    case "true":
    case "1":
    case "enable":
    case "enabled":
      return true;
    case "off":
    case "no":
    case "false":
    case "0":
    case "disable":
    case "disabled":
      return false;
    default:
      return current;
  }
}

function policySummary(policies) {
  const linked = Object.entries(policies).filter(([, policy]) => policy === "link").map(([key]) => key);
  const copied = Object.entries(policies).filter(([, policy]) => policy === "copy").map(([key]) => key);
  const parts = [];
  if (linked.length) parts.push(`Link ${formatList(linked)}`);
  if (copied.length) parts.push(`Copy ${formatList(copied)}`);
  return parts.length ? parts.join(" | ") : "Empty";
}

function formatList(values) {
  if (values.length === Object.keys(categories).length) return "everything";
  if (values.length > 3) return `${values.length} categories`;
  return values.join(", ");
}

function printCreatedHome(home, envName = "CODEX_HOME") {
  console.log(`Created ${home.name}`);
  console.log(`slug=${home.slug}`);
  console.log(`${envName}=${home.homePath}`);
  console.log(`profile=${home.profilePath || "none"}`);
  if (home.sourceHomePath) {
    console.log(`source=${home.sourceHomePath}`);
    console.log(`materialization=${home.cloneMaterialization || "copy"}`);
    console.log(`policies=${policySummary(home.clonePolicies || {})}`);
  }
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function cmdQuote(value) {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function powerShellSingleQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`;
}

function cryptoRandomUUID() {
  return require("node:crypto").randomUUID();
}

module.exports = {
  HomeportWin,
  main,
  makePaths,
  slugify,
  presetPolicies,
  policySummary
};
