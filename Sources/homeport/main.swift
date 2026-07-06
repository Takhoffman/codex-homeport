import Foundation
import HomeportCore

let arguments = Array(CommandLine.arguments.dropFirst())
let cliChannel = HomeportChannel.current()
let service = HomeportService(paths: HomeportPaths(channel: cliChannel))

do {
    try run(arguments)
} catch {
    fputs("homeport: \(error.localizedDescription)\n", stderr)
    exit(1)
}

func run(_ arguments: [String]) throws {
    guard let command = arguments.first else {
        printHelp()
        return
    }

    if command == "--version" || command == "-v" {
        printVersion()
        return
    }

    if command == "help" {
        printHelp(topic: arguments.dropFirst().first)
        return
    }

    if arguments.dropFirst().contains("--help") || arguments.dropFirst().contains("-h") {
        printHelp(topic: command)
        return
    }

    switch command {
    case "doctor":
        try doctor(arguments.dropFirst())
    case "launch":
        try launch(Array(arguments.dropFirst()))
    case "throwaway":
        try throwaway(Array(arguments.dropFirst()))
    case "clone":
        try clone(Array(arguments.dropFirst()))
    case "create":
        try createHome(Array(arguments.dropFirst()))
    case "rename":
        try renameHome(Array(arguments.dropFirst()))
    case "path":
        try changeHomePath(Array(arguments.dropFirst()))
    case "delete":
        try deleteHome(Array(arguments.dropFirst()))
    case "list":
        try list()
    case "cleanup":
        try cleanup(Array(arguments.dropFirst()))
    case "promote":
        try promote(Array(arguments.dropFirst()))
    case "review":
        try review()
    case "repair":
        try repair()
    case "version":
        printVersion()
    case "install":
        try install(Array(arguments.dropFirst()))
    case "update":
        try update(Array(arguments.dropFirst()))
    case "start":
        try start(Array(arguments.dropFirst()))
    case "restart":
        try restart(Array(arguments.dropFirst()))
    case "autostart":
        try autostart(Array(arguments.dropFirst()))
    case "configure":
        try configure(Array(arguments.dropFirst()))
    case "onboard":
        try onboard(Array(arguments.dropFirst()))
    case "uninstall":
        try uninstall(Array(arguments.dropFirst()))
    case "--help", "-h":
        printHelp()
    default:
        throw HomeportError.unsupportedCommand(command)
    }
}

func doctor(_ arguments: ArraySlice<String>) throws {
    let report = service.report()
    print("Codex Multihome Doctor")
    print("Main CODEX_HOME: \(service.paths.mainCodexHome.path)")
    print("Main sessions: \(report.mainSessionCount)")
    print("Codex.app: \(report.codexAppExists ? "found" : "missing")")
    print("codex CLI: \(report.codexBinaryPath ?? "missing")")
    print("Main auth: \(authStatusLabel(report.authStatus))")
    print("Auth mode: \(report.authStatus.mode ?? "unknown")")
    print("Account: \(report.authStatus.accountLabel ?? "unknown")")
    print("Usage: \(report.authStatus.usageSummary ?? "unknown")")
    print("GUI CODEX_HOME: \(report.globalCodexHome ?? "not set")")

    if report.suspiciousLaunchers.isEmpty {
        print("Suspicious launchers: none")
    } else {
        print("Suspicious launchers:")
        for launcher in report.suspiciousLaunchers {
            print("  \(launcher)")
        }
    }

    if !report.notes.isEmpty {
        print("")
        print("Notes:")
        for note in report.notes {
            print("- \(note)")
        }
    }

    if arguments.contains("--repair") {
        try service.clearGlobalCodexHome()
        print("")
        print("Cleared GUI CODEX_HOME.")
    }
}

func launch(_ arguments: [String]) throws {
    let selector = arguments.first ?? "main"
    let state = try service.loadState()
    let target = option(arguments, "--target").flatMap(LaunchTarget.init(rawValue:)) ?? state.preferences.defaultLaunchTarget
    let workspace = option(arguments, "--workspace") ?? state.lastWorkspacePath ?? FileManager.default.currentDirectoryPath
    let terminal = option(arguments, "--terminal").flatMap(TerminalApp.init(rawValue:))
    let instance = try service.launch(selector: selector, target: target, workspace: workspace, terminal: terminal)
    print("Launched \(instance.homeName) as \(instance.target.rawValue).")
    print("CODEX_HOME=\(instance.homePath)")
    if let pid = instance.pid {
        print("pid=\(pid)")
    }
    if instance.cleanupReviewRequired {
        print("Temporary instance will require cleanup review after it closes.")
        print("instance=\(instance.id.uuidString)")
    }
}

func throwaway(_ arguments: [String]) throws {
    var launchArguments = ["temp"]
    launchArguments.append("--target")
    launchArguments.append(option(arguments, "--target") ?? "desktop")
    if let workspace = option(arguments, "--workspace") {
        launchArguments.append(contentsOf: ["--workspace", workspace])
    }
    if let terminal = option(arguments, "--terminal") {
        launchArguments.append(contentsOf: ["--terminal", terminal])
    }
    try launch(launchArguments)
}

func clone(_ arguments: [String]) throws {
    let state = try service.loadState()
    let preset = option(arguments, "--preset").flatMap(ClonePreset.init(rawValue:)) ?? state.preferences.defaultClonePreset
    let hasExplicitPreset = option(arguments, "--preset") != nil
    let basePolicies = hasExplicitPreset ? ClonePolicies.preset(preset) : state.preferences.clonePolicies
    let clonePolicies = clonePolicies(from: arguments, base: basePolicies)
    let sourceSelector = option(arguments, "--source") ?? "main"
    let name = option(arguments, "--name") ?? positionalName(in: arguments) ?? "Multihome Clone"
    let home = try service.clone(
        name: name,
        preset: preset,
        policies: clonePolicies,
        sourceSelector: sourceSelector,
        homePath: option(arguments, "--path")
    )
    printCreatedHome(home)
}

func printCreatedHome(_ home: CodexHome) {
    print("Created \(home.name)")
    print("slug=\(home.slug)")
    print("CODEX_HOME=\(home.homePath)")
    print("profile=\(home.profilePath ?? "none")")
    if let source = home.sourceHomePath {
        print("source=\(source)")
        print("materialization=\(home.cloneMaterialization?.rawValue ?? CloneMaterialization.copy.rawValue)")
        if let policies = home.clonePolicies {
            print("policies=\(policies.summary)")
        }
    }
}

func createHome(_ arguments: [String]) throws {
    let kind = option(arguments, "--kind") ?? arguments.first ?? "clean-room"
    let name = option(arguments, "--name")
    let home: CodexHome
    switch kind {
    case "clean-room", "cleanRoom":
        home = try service.createCleanRoom(name: name, homePath: option(arguments, "--path"))
    case "temporary", "temp":
        home = try service.createTemporary(name: name, homePath: option(arguments, "--path"))
    case "clone":
        let preset = option(arguments, "--preset").flatMap(ClonePreset.init(rawValue:)) ?? .workingSetup
        home = try service.clone(
            name: name ?? "Multihome Clone",
            preset: preset,
            policies: clonePolicies(from: arguments, base: .preset(preset)),
            sourceSelector: option(arguments, "--source") ?? "main",
            homePath: option(arguments, "--path")
        )
    default:
        throw HomeportError.unsupportedCommand("create \(kind)")
    }
    printCreatedHome(home)
}

func renameHome(_ arguments: [String]) throws {
    guard let selector = arguments.first, let name = option(arguments, "--name") else {
        printHelp(topic: "rename")
        return
    }
    let state = try service.loadState()
    guard let home = state.homes.first(where: { $0.slug == selector || $0.name == selector }) else {
        throw HomeportError.homeDoesNotExist(selector)
    }
    let moveFolders = arguments.contains("--move-folders")
    try service.renameHome(id: home.id, name: name, moveFolders: moveFolders)
    print("Renamed \(selector) to \(name)\(moveFolders ? " and moved managed folders" : "").")
}

func changeHomePath(_ arguments: [String]) throws {
    guard let selector = arguments.first, let path = option(arguments, "--path") else {
        printHelp(topic: "path")
        return
    }
    let state = try service.loadState()
    guard let home = state.homes.first(where: { $0.slug == selector || $0.name == selector }) else {
        throw HomeportError.homeDoesNotExist(selector)
    }
    let moveExisting = arguments.contains("--move") || arguments.contains("--move-existing")
    try service.changeHomePath(id: home.id, homePath: path, moveExisting: moveExisting)
    print("Updated \(selector) home path to \(path)\(moveExisting ? " and moved existing files" : "").")
}

func deleteHome(_ arguments: [String]) throws {
    guard let selector = arguments.first else {
        printHelp(topic: "delete")
        return
    }
    let state = try service.loadState()
    guard let home = state.homes.first(where: { $0.slug == selector || $0.name == selector }) else {
        throw HomeportError.homeDoesNotExist(selector)
    }
    let targets = try service.deleteHome(id: home.id)
    print("Moved to Trash:")
    for target in targets {
        print("- \(target.path)")
    }
}

func list() throws {
    let state = try service.loadState()
    print("Homes")
    for home in state.homes {
        let marker = home.isTemporary ? " temporary" : ""
        print("- \(home.slug): \(home.name) [\(home.kind.rawValue)\(marker)]")
        print("  home: \(home.homePath)")
        if let profile = home.profilePath {
            print("  profile: \(profile)")
        }
        if let source = home.sourceHomePath {
            print("  source: \(source)")
            print("  materialization: \(home.cloneMaterialization?.rawValue ?? CloneMaterialization.copy.rawValue)")
            if let policies = home.clonePolicies {
                print("  policies: \(policies.summary)")
            }
        }
    }
    if !state.instances.isEmpty {
        print("")
        print("Instances")
        for instance in state.instances.prefix(20) {
            print("- \(instance.id.uuidString) \(instance.homeName) \(instance.target.rawValue) \(instance.status.rawValue)")
        }
    }
}

func review() throws {
    let state = try service.loadState()
    let pending = state.instances.filter(\.cleanupReviewRequired)
    if pending.isEmpty {
        print("No temporary homes need cleanup review.")
        return
    }
    print("Cleanup Review")
    for instance in pending {
        print("- \(instance.id.uuidString) \(instance.homeName) \(instance.status.rawValue)")
        print("  home: \(instance.homePath)")
        if let profile = instance.profilePath {
            print("  profile: \(profile)")
        }
        print("  actions: homeport cleanup \(instance.id.uuidString) | homeport promote \(instance.id.uuidString)")
    }
}

func cleanup(_ arguments: [String]) throws {
    guard let rawID = arguments.first, let id = UUID(uuidString: rawID) else {
        printHelp(topic: "cleanup")
        return
    }
    let targets = try service.cleanup(instanceID: id)
    print("Cleaned:")
    for target in targets {
        print("- \(target.path)")
    }
}

func promote(_ arguments: [String]) throws {
    guard let rawID = arguments.first, let id = UUID(uuidString: rawID) else {
        printHelp(topic: "promote")
        return
    }
    try service.promote(instanceID: id, name: option(arguments, "--name"))
    print("Promoted \(id.uuidString).")
}

func repair() throws {
    try service.clearGlobalCodexHome()
    print("Cleared GUI CODEX_HOME.")
}

func printVersion() {
    print("Codex Multihome \(AppVersion.version) (\(AppVersion.build))")
}

func install(_ arguments: [String]) throws {
    let repo = try packageRoot(from: option(arguments, "--repo"))
    let installDirectory = URL(fileURLWithPath: option(arguments, "--prefix") ?? "\(NSHomeDirectory())/bin")
    let includeApp = arguments.contains("--with-app")
    let appDirectory = URL(fileURLWithPath: option(arguments, "--app-dir") ?? "\(NSHomeDirectory())/Applications")
    let channel = try channel(from: arguments)

    print("Installing \(channel.appName) \(AppVersion.version) from \(repo.path)")
    try runProcess("swift", ["build", "--package-path", repo.path, "-c", "release", "--product", "homeport"])
    try FileManager.default.createDirectory(at: installDirectory, withIntermediateDirectories: true)

    let builtCLI = repo.appendingPathComponent(".build/release/homeport")
    let installedCLI = installDirectory.appendingPathComponent("homeport")
    if FileManager.default.fileExists(atPath: installedCLI.path) {
        try trash(installedCLI)
    }
    try FileManager.default.copyItem(at: builtCLI, to: installedCLI)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedCLI.path)
    print("Installed CLI: \(installedCLI.path)")

    if includeApp {
        let appPath = try buildAppBundle(repo: repo, channel: channel)
        let installedApp = try installAppBundle(appPath, appDirectory: appDirectory, channel: channel)
        print("Installed app bundle: \(installedApp.path)")
    }
}

func update(_ arguments: [String]) throws {
    let repo = try packageRoot(from: option(arguments, "--repo"))
    let skipPull = arguments.contains("--no-pull")
    let appPath = try installedAppPath(arguments)
    let channel = try channel(from: arguments)
    let shouldInstallApp = arguments.contains("--with-app") || FileManager.default.fileExists(atPath: appPath.path)
    let shouldRestart = shouldInstallApp && !arguments.contains("--no-restart") && isHomeportAppRunning(channel: channel)

    if !skipPull, FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) {
        print("Updating source repo: \(repo.path)")
        try runProcess("git", ["-C", repo.path, "pull", "--ff-only"])
    } else if skipPull {
        print("Skipping git pull.")
    } else {
        print("No git repo found; skipping git pull.")
    }

    var installArguments = arguments.filter { $0 != "--no-pull" && $0 != "--no-restart" }
    if shouldInstallApp && !installArguments.contains("--with-app") {
        installArguments.append("--with-app")
    }
    try install(installArguments)

    if shouldRestart {
        try restart(arguments)
    }
}

func buildAppBundle(repo: URL, channel: HomeportChannel) throws -> URL {
    let app = repo.appendingPathComponent("dist/\(channel.appBundleName)")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

    try runProcess("swift", ["build", "--package-path", repo.path, "-c", "release", "--product", "CodexMultihomeApp"])
    let builtApp = repo.appendingPathComponent(".build/release/CodexMultihomeApp")
    let executable = macOS.appendingPathComponent(channel.appName)
    if FileManager.default.fileExists(atPath: executable.path) {
        try trash(executable)
    }
    try FileManager.default.copyItem(at: builtApp, to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>\(xmlEscape(channel.appName))</string>
      <key>CFBundleIdentifier</key>
      <string>\(channel.bundleIdentifier)</string>
      <key>CFBundleName</key>
      <string>\(xmlEscape(channel.appName))</string>
      <key>CFBundleDisplayName</key>
      <string>\(xmlEscape(channel.appName))</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>CFBundleShortVersionString</key>
      <string>\(AppVersion.version)</string>
      <key>CFBundleVersion</key>
      <string>\(AppVersion.build)</string>
      <key>LSMinimumSystemVersion</key>
      <string>13.0</string>
      <key>LSUIElement</key>
      <true/>
      <key>HomeportChannel</key>
      <string>\(channel.rawValue)</string>
    </dict>
    </plist>
    """
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    return app
}

func installAppBundle(_ builtApp: URL, appDirectory: URL, channel: HomeportChannel) throws -> URL {
    try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
    let installedApp = appDirectory.appendingPathComponent(channel.appBundleName)
    if FileManager.default.fileExists(atPath: installedApp.path) {
        try trash(installedApp)
    }
    try FileManager.default.copyItem(at: builtApp, to: installedApp)
    return installedApp
}

func start(_ arguments: [String]) throws {
    let appPath = try installedAppPath(arguments)
    let channel = try channel(from: arguments)
    guard FileManager.default.fileExists(atPath: appPath.path) else {
        throw HomeportError.commandFailed("\(channel.appBundleName) was not found at \(appPath.path). Run homeport install --with-app first.")
    }
    try runProcess("open", [appPath.path])
    print("Started \(channel.appName): \(appPath.path)")
}

func restart(_ arguments: [String]) throws {
    let channel = try channel(from: arguments)
    try runProcess("pkill", ["-f", "\(channel.appBundleName)/Contents/MacOS/\(channel.appName)"], allowFailure: true)
    Thread.sleep(forTimeInterval: 0.5)
    try start(arguments)
}

func autostart(_ arguments: [String]) throws {
    let action = arguments.first ?? "status"
    switch action {
    case "enable", "on":
        let appPath = try installedAppPath(arguments)
        let channel = try channel(from: arguments)
        guard FileManager.default.fileExists(atPath: appPath.path) else {
            throw HomeportError.commandFailed("\(channel.appBundleName) was not found at \(appPath.path). Run homeport install --with-app first.")
        }
        try writeLaunchAgent(appPath: appPath, channel: channel)
        try runProcess("launchctl", ["unload", launchAgentPlist(channel: channel).path], allowFailure: true)
        try runProcess("launchctl", ["load", launchAgentPlist(channel: channel).path])
        print("Autostart enabled.")
    case "disable", "off":
        let channel = try channel(from: arguments)
        try runProcess("launchctl", ["unload", launchAgentPlist(channel: channel).path], allowFailure: true)
        if FileManager.default.fileExists(atPath: launchAgentPlist(channel: channel).path) {
            try trash(launchAgentPlist(channel: channel))
        }
        print("Autostart disabled.")
    case "status":
        let channel = try channel(from: arguments)
        let plistURL = launchAgentPlist(channel: channel)
        if FileManager.default.fileExists(atPath: plistURL.path) {
            print("Autostart (\(channel.rawValue)): enabled")
        } else {
            print("Autostart (\(channel.rawValue)): disabled")
        }
        print("plist: \(plistURL.path)")
    default:
        throw HomeportError.unsupportedCommand("autostart \(action)")
    }
}

func configure(_ arguments: [String]) throws {
    let selectedChannel = try channel(from: arguments)
    if arguments.contains("--reset") {
        try service.resetPreferences()
        print("Reset Multihome preferences to defaults.")
        return
    }

    if let terminal = option(arguments, "--terminal").flatMap(TerminalApp.init(rawValue:)) {
        var state = try service.loadState()
        state.preferredTerminal = terminal
        try service.saveState(state)
        print("Preferred terminal: \(terminal.rawValue)")
    }

    if let workspace = option(arguments, "--workspace") {
        var state = try service.loadState()
        state.lastWorkspacePath = workspace
        try service.saveState(state)
        print("Default workspace: \(workspace)")
    }

    if let target = option(arguments, "--launch-target").flatMap(LaunchTarget.init(rawValue:)) {
        var state = try service.loadState()
        state.preferences.defaultLaunchTarget = target
        try service.saveState(state)
        print("Default launch target: \(target.rawValue)")
    }

    if let preset = option(arguments, "--clone-preset").flatMap(ClonePreset.init(rawValue:)) {
        var state = try service.loadState()
        state.preferences.defaultClonePreset = preset
        state.preferences.cloneOptions = .preset(preset)
        state.preferences.cloneMaterialization = .copy
        state.preferences.clonePolicies = .preset(preset)
        try service.saveState(state)
        print("Default clone preset: \(preset.rawValue)")
    }

    if let include = option(arguments, "--clone-include") {
        var state = try service.loadState()
        state.preferences.cloneOptions = applyCloneList(include, to: state.preferences.cloneOptions, value: true)
        state.preferences.clonePolicies = applyClonePolicyList(include, to: state.preferences.clonePolicies, policy: .copy)
        try service.saveState(state)
        print("Updated clone includes: \(include)")
    }

    if let exclude = option(arguments, "--clone-exclude") {
        var state = try service.loadState()
        state.preferences.cloneOptions = applyCloneList(exclude, to: state.preferences.cloneOptions, value: false)
        state.preferences.clonePolicies = applyClonePolicyList(exclude, to: state.preferences.clonePolicies, policy: .skip)
        try service.saveState(state)
        print("Updated clone excludes: \(exclude)")
    }

    if let temporary = option(arguments, "--temporary") {
        var state = try service.loadState()
        state.preferences.launchTemporaryByDefault = boolValue(temporary)
        try service.saveState(state)
        print("Launch temporary by default: \(state.preferences.launchTemporaryByDefault)")
    }

    if let installApp = option(arguments, "--install-app") {
        var state = try service.loadState()
        state.preferences.installAppByDefault = boolValue(installApp)
        try service.saveState(state)
        print("Install app by default: \(state.preferences.installAppByDefault)")
    }

    if let updateChecks = option(arguments, "--update-checks") {
        var state = try service.loadState()
        state.preferences.autoUpdateChecksEnabled = try strictBoolValue(updateChecks, optionName: "--update-checks")
        if !state.preferences.autoUpdateChecksEnabled {
            state.preferences.autoInstallUpdates = false
        }
        try service.saveState(state)
        print("Update checks enabled: \(state.preferences.autoUpdateChecksEnabled)")
    }

    if let updateInterval = option(arguments, "--update-interval") {
        guard let interval = UpdateCheckInterval(rawValue: updateInterval) else {
            throw HomeportError.commandFailed("Unknown --update-interval value: \(updateInterval)")
        }
        var state = try service.loadState()
        state.preferences.updateCheckInterval = interval
        try service.saveState(state)
        print("Update interval: \(interval.rawValue)")
    }

    if let autoInstallUpdates = option(arguments, "--auto-install-updates") {
        var state = try service.loadState()
        state.preferences.autoInstallUpdates = try strictBoolValue(autoInstallUpdates, optionName: "--auto-install-updates")
        if state.preferences.autoInstallUpdates {
            state.preferences.autoUpdateChecksEnabled = true
        }
        try service.saveState(state)
        print("Auto-install updates: \(state.preferences.autoInstallUpdates)")
    }

    if let autostartValue = option(arguments, "--autostart") {
        switch autostartValue {
        case "on", "enable", "true", "yes":
            try autostart(["enable"] + arguments)
        case "off", "disable", "false", "no":
            try autostart(["disable"])
        case "status":
            try autostart(["status"])
        default:
            throw HomeportError.commandFailed("Unknown --autostart value: \(autostartValue)")
        }
    }

    if arguments.isEmpty || arguments.contains("--show") {
        let state = try service.loadState()
        print("Preferred terminal: \(state.preferredTerminal.rawValue)")
        print("Default workspace: \(state.lastWorkspacePath ?? FileManager.default.currentDirectoryPath)")
        print("Default launch target: \(state.preferences.defaultLaunchTarget.rawValue)")
        print("Default clone preset: \(state.preferences.defaultClonePreset.rawValue)")
        print("Clone includes: \(cloneOptionSummary(state.preferences.cloneOptions))")
        print("Launch temporary by default: \(state.preferences.launchTemporaryByDefault)")
        print("Install app by default: \(state.preferences.installAppByDefault)")
        print("Update checks enabled: \(state.preferences.autoUpdateChecksEnabled)")
        print("Update interval: \(state.preferences.updateCheckInterval.rawValue)")
        print("Auto-install updates: \(state.preferences.autoInstallUpdates)")
        try autostart(["status", "--channel", selectedChannel.rawValue])
    }
}

func onboard(_ arguments: [String]) throws {
    let repo = try packageRoot(from: option(arguments, "--repo"))
    let prefix = option(arguments, "--prefix") ?? "\(NSHomeDirectory())/bin"
    let appDir = option(arguments, "--app-dir") ?? "\(NSHomeDirectory())/Applications"
    let terminal = option(arguments, "--terminal") ?? "terminal"
    let workspace = option(arguments, "--workspace") ?? FileManager.default.currentDirectoryPath
    let channel = try channel(from: arguments)

    let channelArguments = ["--channel", channel.rawValue]
    try install(["--repo", repo.path, "--prefix", prefix, "--with-app", "--app-dir", appDir] + channelArguments)
    try configure(["--terminal", terminal, "--workspace", workspace, "--autostart", "on", "--app-dir", appDir] + channelArguments)
    try start(["--app-dir", appDir] + channelArguments)
    print("Onboarding complete.")
}

func uninstall(_ arguments: [String]) throws {
    let appPath = try installedAppPath(arguments)
    let removeCLI = arguments.contains("--remove-cli")
    let removeState = arguments.contains("--remove-state")
    let removeManagedHomes = arguments.contains("--remove-managed-homes")
    let cliPath = URL(fileURLWithPath: option(arguments, "--cli") ?? "\(NSHomeDirectory())/bin/homeport")

    try autostart(["disable", "--channel", try channel(from: arguments).rawValue])

    if FileManager.default.fileExists(atPath: appPath.path) {
        try trash(appPath)
        print("Moved app to Trash: \(appPath.path)")
    } else {
        print("App not found: \(appPath.path)")
    }

    if removeState {
        let stateRoot = service.paths.appSupportDirectory
        if FileManager.default.fileExists(atPath: stateRoot.path) {
            try trash(stateRoot)
            print("Moved Multihome state to Trash: \(stateRoot.path)")
        }
    } else {
        print("Kept Multihome state: \(service.paths.appSupportDirectory.path)")
    }

    if removeManagedHomes {
        let homesRoot = service.paths.managedHomesDirectory
        if FileManager.default.fileExists(atPath: homesRoot.path) {
            try trash(homesRoot)
            print("Moved managed Codex homes to Trash: \(homesRoot.path)")
        }
    } else {
        print("Kept managed Codex homes: \(service.paths.managedHomesDirectory.path)")
    }

    if removeCLI {
        if FileManager.default.fileExists(atPath: cliPath.path) {
            try trash(cliPath)
            print("Moved CLI to Trash: \(cliPath.path)")
        } else {
            print("CLI not found: \(cliPath.path)")
        }
    } else {
        print("Kept CLI: \(cliPath.path)")
    }

    print("Uninstall complete.")
}

func trash(_ url: URL) throws {
    var resultingURL: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &resultingURL)
}

func installedAppPath(_ arguments: [String]) throws -> URL {
    let appDirectory = URL(fileURLWithPath: option(arguments, "--app-dir") ?? "\(NSHomeDirectory())/Applications")
    return appDirectory.appendingPathComponent(try channel(from: arguments).appBundleName)
}

func isHomeportAppRunning(channel: HomeportChannel = cliChannel) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pgrep", "-f", "\(channel.appBundleName)/Contents/MacOS/\(channel.appName)"]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

func launchAgentPlist(channel: HomeportChannel = cliChannel) -> URL {
    URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/\(channel.bundleIdentifier).plist")
}

func writeLaunchAgent(appPath: URL, channel: HomeportChannel) throws {
    let plistURL = launchAgentPlist(channel: channel)
    let executable = appPath.appendingPathComponent("Contents/MacOS/\(channel.appName)")
    try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>\(channel.bundleIdentifier)</string>
      <key>ProgramArguments</key>
      <array>
        <string>/usr/bin/env</string>
        <string>HOMEPORT_CHANNEL=\(channel.rawValue)</string>
        <string>\(xmlEscape(executable.path))</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
    </dict>
    </plist>
    """
    try plist.write(to: plistURL, atomically: true, encoding: .utf8)
}

func packageRoot(from explicitPath: String?) throws -> URL {
    if let explicitPath {
        let root = URL(fileURLWithPath: explicitPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
            throw HomeportError.commandFailed("No Package.swift found at \(root.path)")
        }
        return root
    }

    var current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL
    while true {
        if FileManager.default.fileExists(atPath: current.appendingPathComponent("Package.swift").path) {
            return current
        }
        let parent = current.deletingLastPathComponent()
        if parent.path == current.path {
            break
        }
        current = parent
    }

    let fallbackRoots = [
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/CodexMultihome/Source"),
        URL(fileURLWithPath: "\(NSHomeDirectory())/github.com/Takhoffman/codex-multihome")
    ]
    for fallback in fallbackRoots where FileManager.default.fileExists(atPath: fallback.appendingPathComponent("Package.swift").path) {
        return fallback
    }

    throw HomeportError.commandFailed("Run this from the Codex Multihome repo or pass --repo PATH.")
}

func xmlEscape(_ raw: String) -> String {
    raw
        .replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

func runProcess(_ executable: String, _ arguments: [String], allowFailure: Bool = false) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [executable] + arguments
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 && !allowFailure {
        throw HomeportError.commandFailed("\(executable) \(arguments.joined(separator: " ")) exited with \(process.terminationStatus)")
    }
}

func channel(from arguments: [String]) throws -> HomeportChannel {
    if let value = option(arguments, "--channel") {
        guard let channel = HomeportChannel(rawValue: value) else {
            throw HomeportError.commandFailed("Unknown --channel value: \(value)")
        }
        return channel
    }
    return HomeportChannel.current()
}

func option(_ arguments: [String], _ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
}

func authStatusLabel(_ status: CodexAuthStatus) -> String {
    if status.isLoggedIn {
        return "logged in"
    }
    if status.hasStoredCredentials {
        return "stored"
    }
    return "not found"
}

func cloneMaterialization(from arguments: [String]) -> CloneMaterialization {
    if arguments.contains("--link-auth") {
        return .linkSafeCustomizationsAndAuth
    }
    if arguments.contains("--link-safe") || arguments.contains("--link") {
        return .linkSafeCustomizations
    }
    return .copy
}

func positionalName(in arguments: [String]) -> String? {
    let optionsWithValues: Set<String> = [
        "--preset",
        "--include",
        "--exclude",
        "--link",
        "--name",
        "--path",
        "--source"
    ]
    var skipNext = false
    for argument in arguments {
        if skipNext {
            skipNext = false
            continue
        }
        if optionsWithValues.contains(argument) {
            skipNext = true
            continue
        }
        if argument.hasPrefix("--") {
            continue
        }
        return argument
    }
    return nil
}

func boolValue(_ value: String) -> Bool {
    ["1", "true", "yes", "on", "enable", "enabled"].contains(value.lowercased())
}

func strictBoolValue(_ value: String, optionName: String) throws -> Bool {
    switch value.lowercased() {
    case "1", "true", "yes", "on", "enable", "enabled":
        return true
    case "0", "false", "no", "off", "disable", "disabled":
        return false
    default:
        throw HomeportError.commandFailed("Unknown \(optionName) value: \(value)")
    }
}

func cloneOptions(from arguments: [String], base: CloneOptions) -> CloneOptions {
    var options = base
    if let include = option(arguments, "--include") {
        options = applyCloneList(include, to: options, value: true)
    }
    if let exclude = option(arguments, "--exclude") {
        options = applyCloneList(exclude, to: options, value: false)
    }
    return options
}

func clonePolicies(from arguments: [String], base: ClonePolicies) -> ClonePolicies {
    var policies = base
    if let include = option(arguments, "--include") {
        policies = applyClonePolicyList(include, to: policies, policy: .copy)
    }
    if let exclude = option(arguments, "--exclude") {
        policies = applyClonePolicyList(exclude, to: policies, policy: .skip)
    }
    if arguments.contains("--link-safe") {
        policies = linkSafePolicies(policies)
    }
    if arguments.contains("--link-auth") {
        policies = linkSafePolicies(policies)
        policies.auth = .link
    }
    if let link = option(arguments, "--link") {
        policies = applyClonePolicyList(link, to: policies, policy: .link)
    }
    return policies
}

func applyClonePolicyList(_ list: String, to policies: ClonePolicies, policy: ClonePolicy) -> ClonePolicies {
    var next = policies
    for rawToken in list.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }) {
        applyClonePolicyToken(rawToken, policy: policy, to: &next)
    }
    return next
}

func applyClonePolicyToken(_ token: String, policy: ClonePolicy, to policies: inout ClonePolicies) {
    let safePolicy: ClonePolicy = policy == .link && !clonePolicyTokenCanLink(token) ? .copy : policy
    switch token {
    case "config", "config.toml": policies.config = safePolicy
    case "auth": policies.auth = safePolicy
    case "skills": policies.skills = safePolicy
    case "plugins": policies.plugins = safePolicy
    case "agents": policies.agents = safePolicy
    case "prompts": policies.prompts = safePolicy
    case "rules": policies.rules = safePolicy
    case "profiles": policies.profiles = safePolicy
    case "memories": policies.memories = safePolicy
    case "browser", "chrome", "browser-support": policies.browserSupport = safePolicy
    case "sessions", "logs", "history": policies.sessionsAndLogs = safePolicy
    case "everything", "all":
        policies = policy == .skip ? .empty : (policy == .link ? linkAllLinkablePolicies(.full) : .full)
    default:
        return
    }
}

func clonePolicyTokenCanLink(_ token: String) -> Bool {
    switch token {
    case "config", "config.toml", "auth", "skills", "plugins", "agents", "prompts", "rules", "profiles", "everything", "all":
        return true
    default:
        return false
    }
}

func linkSafePolicies(_ policies: ClonePolicies) -> ClonePolicies {
    var next = policies
    if next.config != .skip { next.config = .link }
    if next.skills != .skip { next.skills = .link }
    if next.plugins != .skip { next.plugins = .link }
    if next.agents != .skip { next.agents = .link }
    if next.prompts != .skip { next.prompts = .link }
    if next.rules != .skip { next.rules = .link }
    if next.profiles != .skip { next.profiles = .link }
    return next
}

func linkAllLinkablePolicies(_ policies: ClonePolicies) -> ClonePolicies {
    var next = linkSafePolicies(policies)
    if next.auth != .skip { next.auth = .link }
    return next
}

func applyCloneList(_ list: String, to options: CloneOptions, value: Bool) -> CloneOptions {
    var next = options
    for rawToken in list.split(separator: ",").map({ String($0).trimmingCharacters(in: .whitespacesAndNewlines) }) {
        switch rawToken {
        case "config", "config.toml": next.config = value
        case "auth": next.auth = value
        case "skills": next.skills = value
        case "plugins": next.plugins = value
        case "agents": next.agents = value
        case "prompts": next.prompts = value
        case "rules": next.rules = value
        case "profiles": next.profiles = value
        case "memories": next.memories = value
        case "browser", "chrome", "browser-support": next.browserSupport = value
        case "sessions", "logs", "history": next.sessionsAndLogs = value
        case "everything": next.everything = value
        case "all":
            next = value ? .full : .empty
        default:
            continue
        }
    }
    if next.everything && !value {
        next.everything = false
    }
    return next
}

func cloneOptionSummary(_ options: CloneOptions) -> String {
    if options.everything {
        return "everything"
    }
    var parts: [String] = []
    if options.config { parts.append("config") }
    if options.auth { parts.append("auth") }
    if options.skills { parts.append("skills") }
    if options.plugins { parts.append("plugins") }
    if options.agents { parts.append("agents") }
    if options.prompts { parts.append("prompts") }
    if options.rules { parts.append("rules") }
    if options.profiles { parts.append("profiles") }
    if options.memories { parts.append("memories") }
    if options.browserSupport { parts.append("browser") }
    if options.sessionsAndLogs { parts.append("sessions") }
    return parts.isEmpty ? "nothing" : parts.joined(separator: ",")
}

func printHelp(topic: String? = nil) {
    guard let topic else {
        print(generalHelp())
        return
    }

    switch topic {
    case "doctor": print(doctorHelp())
    case "launch": print(launchHelp())
    case "throwaway": print(throwawayHelp())
    case "clone": print(cloneHelp())
    case "create": print(createHelp())
    case "rename": print(renameHelp())
    case "path": print(pathHelp())
    case "delete": print(deleteHelp())
    case "list": print(listHelp())
    case "review": print(reviewHelp())
    case "cleanup": print(cleanupHelp())
    case "promote": print(promoteHelp())
    case "repair": print(repairHelp())
    case "version": print(versionHelp())
    case "install": print(installHelp())
    case "update": print(updateHelp())
    case "start": print(startHelp())
    case "restart": print(restartHelp())
    case "autostart": print(autostartHelp())
    case "configure": print(configureHelp())
    case "onboard": print(onboardHelp())
    case "uninstall": print(uninstallHelp())
    default:
        print("Unknown help topic: \(topic)\n")
        print(generalHelp())
    }
}

func generalHelp() -> String { """
Codex Multihome

Safely launch and manage multiple Codex homes without leaking global CODEX_HOME
state. Multihome can open Codex.app, start terminal Codex sessions, clone your
setup, create temporary homes, and clean up temporary state after review.

Usage:
  homeport <command> [options]
  homeport help <command>
  homeport <command> --help

Daily commands:
  launch       Open Codex using main, temporary, or named homes
  throwaway    Open a temporary Codex app or terminal session
  list         Show homes and recent launched instances
  review       Show temporary homes waiting for cleanup review
  doctor       Diagnose Codex state and launch-environment problems

Setup commands:
  onboard      Install CLI/app, configure defaults, enable autostart, start app
  install      Build and install the CLI, optionally the menu bar app
  update       Pull latest source, reinstall, and restart the app when needed
  version      Show installed Multihome version
  start        Open the installed menu bar app
  restart      Quit and reopen the installed menu bar app
  configure    Change terminal, workspace, or autostart preferences
  autostart    Enable, disable, or show LaunchAgent status
  uninstall    Remove the app/autostart entry; extra removals are opt-in

Home commands:
  clone        Create a managed Codex home from ~/.codex
  create       Create a clean-room, temporary, or cloned home
  rename       Rename a managed home
  path         Change a managed home's CODEX_HOME path
  delete       Move a managed home/profile to Trash
  cleanup      Move a temporary home/profile to Trash after review
  promote      Keep a temporary home as a saved managed home
  repair       Clear GUI-level CODEX_HOME override

Examples:
  homeport onboard
  homeport launch main --target desktop
  homeport launch temp --target terminal
  homeport throwaway
  homeport create --kind clean-room --name "Blank Slate"
  homeport rename blank-slate --name "Scratch Lab"
  homeport path scratch-lab --path ~/codex-homes/scratch-lab --move
  homeport delete scratch-lab
  homeport clone --preset working-setup --name "Plugin Lab"
  homeport review
  homeport doctor --repair

Paths:
  Main Codex home:        ~/.codex
  Managed homes:          ~/.codex-homes/<slug>
  Multihome state:         ~/Library/Application Support/CodexMultihome/homeport.json
  Installed app default:  ~/Applications/Codex Multihome.app
  Installed CLI default:  ~/bin/homeport
""" }

func doctorHelp() -> String { """
homeport doctor

Diagnose the current Codex launch environment.

Usage:
  homeport doctor [--repair]

Options:
  --repair    Also clear GUI-level CODEX_HOME with launchctl unsetenv.

Checks:
  - Main ~/.codex session index count
  - Codex.app executable presence
  - codex CLI presence on PATH
  - GUI CODEX_HOME override
  - Desktop launchers that still reference Deckhand/CodexHome

Examples:
  homeport doctor
  homeport doctor --repair
""" }

func launchHelp() -> String { """
homeport launch

Launch Codex with an explicit per-process CODEX_HOME.

Usage:
  homeport launch [main|temp|SLUG] --target desktop|terminal [options]

Options:
  --target desktop|terminal     Launch Codex.app or a terminal Codex session.
  --workspace PATH              Working directory for terminal launches.
  --terminal terminal|iTerm     Terminal app to use for terminal launches.

Selectors:
  main      Your normal ~/.codex home.
  temp      Create a temporary home and mark it for cleanup review.
  SLUG      Launch a managed home shown by homeport list.

Examples:
  homeport launch main --target desktop
  homeport launch main --target terminal --workspace ~/github.com/project
  homeport launch temp --target terminal
  homeport launch plugin-lab --target desktop

Safety:
  Multihome sets CODEX_HOME only for the launched process. It does not call
  launchctl setenv CODEX_HOME.
""" }

func throwawayHelp() -> String { """
homeport throwaway

Open a temporary Codex instance. By default this launches the desktop app with a
new throwaway CODEX_HOME and app profile. The temporary home is registered for
cleanup review so you can delete or promote it later.

Usage:
  homeport throwaway [--target desktop|terminal] [--workspace PATH] [--terminal terminal|iTerm]

Examples:
  homeport throwaway
  homeport throwaway --target terminal
  homeport review
""" }

func cloneHelp() -> String { """
homeport clone

Create a named managed Codex home. By default homes live under ~/.codex-homes;
pass --path to choose a different CODEX_HOME destination.

Usage:
  homeport clone --preset working-setup|config-only|everything|empty --name NAME [--path PATH] [--source main|SLUG] [--include LIST] [--exclude LIST] [--link LIST|--link-safe|--link-auth]

Presets:
  working-setup   Config, auth, skills, plugins, MCP-related files; no sessions/logs.
  config-only     Config and customization only; no auth.
  everything      Full copy of ~/.codex.
  empty           Empty managed home.

Examples:
  homeport clone --preset working-setup --name "Plugin Lab"
  homeport clone --preset working-setup --name "Plugin Lab" --path ~/codex-homes/plugin-lab
  homeport clone --preset config-only --name "No Auth Test"
  homeport clone --preset empty --name "Blank Slate"
  homeport clone --name "Skills Only" --include skills,plugins --exclude auth,memories,browser
  homeport clone --name "Shared Skills" --source main --link-safe --include skills,plugins
  homeport clone --name "Shared Auth" --source main --link-auth --include config,auth
  homeport clone --name "Linked Config" --source main --include config,auth --link config
  homeport clone --name "From Template" --source template-home --link-safe

Clone categories:
  config, auth, skills, plugins, agents, prompts, rules, profiles, memories,
  browser, sessions, everything, all

Linking:
  --link-safe symlinks safe customization categories only: config, skills,
  plugins, agents, prompts, rules, and profiles. --link-auth also symlinks
  selected auth.json. --link LIST symlinks specific linkable categories.
  Browser state, memories, and sessions/logs are always copied or excluded.
""" }

func createHelp() -> String { """
homeport create

Create a managed Codex home.

Usage:
  homeport create --kind clean-room|temporary|clone [--name NAME] [--path PATH] [--preset PRESET] [--source main|SLUG] [--include LIST] [--exclude LIST] [--link LIST|--link-safe|--link-auth]

Examples:
  homeport create --kind clean-room --name "Blank Slate"
  homeport create --kind clean-room --name "Blank Slate" --path ~/codex-homes/blank-slate
  homeport create --kind temporary --name "Throwaway UI"
  homeport create --kind clone --preset config-only --name "Config Lab"
  homeport create --kind clone --preset working-setup --name "Shared Auth" --link-auth
""" }

func renameHelp() -> String { """
homeport rename

Rename a managed home. The main ~/.codex home cannot be renamed. By default,
only the display name and selector slug change; pass --move-folders to also
rename the managed CODEX_HOME folder and matching app profile folder.

Usage:
  homeport rename SLUG --name NAME [--move-folders]

Examples:
  homeport rename config-lab --name "Config Lab 2"
  homeport rename old-lab --name "New Lab" --move-folders
""" }

func pathHelp() -> String { """
homeport path

Change a saved home's CODEX_HOME path. The main ~/.codex home cannot be changed.
By default, the new path must already be an existing directory. Pass --move to
move the current home folder to a new path.

Usage:
  homeport path SLUG --path PATH [--move]

Examples:
  homeport path config-lab --path ~/codex-homes/config-lab
  homeport path config-lab --path ~/codex-homes/config-lab-2 --move
""" }

func deleteHelp() -> String { """
homeport delete

Move a managed home and matching app profile to Trash. The main ~/.codex home
cannot be deleted.

Usage:
  homeport delete SLUG

Examples:
  homeport list
  homeport delete config-lab
""" }

func listHelp() -> String { """
homeport list

Show registered homes and recent launch instances.

Usage:
  homeport list

Examples:
  homeport list
""" }

func reviewHelp() -> String { """
homeport review

Show temporary homes that are waiting for cleanup review.

Usage:
  homeport review

Next steps:
  homeport cleanup INSTANCE_UUID
  homeport promote INSTANCE_UUID --name "Saved Home"
""" }

func cleanupHelp() -> String { """
homeport cleanup

Move a temporary managed home and its matching app profile to Trash after review.

Usage:
  homeport cleanup INSTANCE_UUID

Examples:
  homeport review
  homeport cleanup 00000000-0000-0000-0000-000000000000

Safety:
  Cleanup targets the temporary home/profile recorded for that instance. It never
  removes your main ~/.codex home.
""" }

func promoteHelp() -> String { """
homeport promote

Keep a temporary home as a saved managed home.

Usage:
  homeport promote INSTANCE_UUID [--name NAME]

Examples:
  homeport promote 00000000-0000-0000-0000-000000000000
  homeport promote 00000000-0000-0000-0000-000000000000 --name "Good Experiment"
""" }

func repairHelp() -> String { """
homeport repair

Clear a GUI-level CODEX_HOME override.

Usage:
  homeport repair

Equivalent:
  launchctl unsetenv CODEX_HOME

This is useful after an old launcher poisoned future GUI Codex launches.
""" }

func installHelp() -> String { """
homeport install

Build and install Multihome from a source checkout.

Usage:
  homeport install [--prefix PATH] [--with-app] [--app-dir PATH] [--repo PATH] [--channel live|dev]

Options:
  --prefix PATH     CLI install directory. Default: ~/bin
  --with-app        Also build and install the menu bar app.
  --app-dir PATH    App install directory. Default: ~/Applications
  --repo PATH       Source repo path. Usually auto-detected.
  --channel live|dev
                   App/state channel. Default: live.

Examples:
  homeport install
  homeport install --with-app
  homeport install --with-app --channel dev
  homeport install --prefix ~/.local/bin --with-app --app-dir /Applications
""" }

func updateHelp() -> String { """
homeport update

Fast-forward the source repo, reinstall Multihome, and restart the menu bar app
when it is already installed and running.

Usage:
  homeport update [--prefix PATH] [--with-app] [--app-dir PATH] [--repo PATH] [--channel live|dev] [--no-pull]

Options:
  --with-app      Install the menu bar app. This is automatic when the app exists.
  --channel live|dev
                  App/state channel. Default: live.
  --no-pull       Skip git pull and rebuild from the current checkout.
  --no-restart    Reinstall without restarting a running menu bar app.

Examples:
  homeport update
  homeport update --with-app
  homeport update --with-app --channel dev
  homeport update --no-pull --with-app
""" }

func versionHelp() -> String { """
homeport version

Show the installed Codex Multihome version.

Usage:
  homeport version
  homeport --version
""" }

func startHelp() -> String { """
homeport start

Open the installed Codex Multihome menu bar app.

Usage:
  homeport start [--app-dir PATH] [--channel live|dev]

Examples:
  homeport start
  homeport start --channel dev
  homeport start --app-dir ~/Applications
""" }

func restartHelp() -> String { """
homeport restart

Quit any running Codex Multihome menu bar process and reopen the installed app.
Use this after reinstalling so macOS does not keep an older menu bar build alive.

Usage:
  homeport restart [--app-dir PATH] [--channel live|dev]

Examples:
  homeport restart
  homeport restart --channel dev
  homeport restart --app-dir ~/Applications
""" }

func autostartHelp() -> String { """
homeport autostart

Manage the user LaunchAgent that opens Codex Multihome at login.

Usage:
  homeport autostart enable [--app-dir PATH] [--channel live|dev]
  homeport autostart disable [--channel live|dev]
  homeport autostart status [--channel live|dev]

Files:
  ~/Library/LaunchAgents/com.takhoffman.codex-multihome.plist
  ~/Library/LaunchAgents/com.takhoffman.codex-multihome.dev.plist

Examples:
  homeport autostart enable
  homeport autostart enable --channel dev
  homeport autostart status
  homeport autostart disable
""" }

func configureHelp() -> String { """
homeport configure

Change Multihome preferences without reinstalling.

Usage:
  homeport configure [options]

Options:
  --terminal terminal|iTerm             Preferred terminal for terminal launches.
  --channel live|dev                    State/app channel. Default: live.
  --workspace PATH                      Default workspace path.
  --launch-target desktop|terminal      Default launch target.
  --clone-preset PRESET                 Default clone preset.
  --clone-include LIST                  Remember clone categories to include.
  --clone-exclude LIST                  Remember clone categories to exclude.
  --temporary on|off                    Prefer temporary launch mode in UI.
  --install-app on|off                  Default whether onboarding installs app.
  --update-checks on|off                Enable proactive npm update checks.
  --update-interval daily|weekly        How often the app checks for updates.
  --auto-install-updates on|off         Install available updates without prompting.
  --autostart on|off|status             Manage login autostart.
  --reset                               Reset Multihome preferences to defaults.
  --show                                Print current configuration.

Examples:
  homeport configure --show
  homeport configure --channel dev --show
  homeport configure --terminal iTerm
  homeport configure --workspace ~/github.com/Takhoffman/codex-multihome
  homeport configure --launch-target terminal
  homeport configure --clone-preset config-only
  homeport configure --clone-include config,skills,plugins
  homeport configure --clone-exclude auth,sessions
  homeport configure --update-checks on --update-interval weekly
  homeport configure --auto-install-updates off
  homeport configure --reset
  homeport configure --autostart on
""" }

func onboardHelp() -> String { """
homeport onboard

Friendly first-run setup: install CLI, install app, save preferences, enable
autostart, and start the menu bar app.

Usage:
  homeport onboard [--prefix PATH] [--app-dir PATH] [--terminal terminal|iTerm] [--workspace PATH] [--repo PATH]

Defaults:
  --prefix ~/bin
  --app-dir ~/Applications
  --terminal terminal
  --workspace current directory

Examples:
  homeport onboard
  homeport onboard --terminal iTerm --workspace ~/github.com/Takhoffman/codex-multihome
""" }

func uninstallHelp() -> String { """
homeport uninstall

Remove the installed app and autostart entry. More complete removal is opt-in.

Usage:
  homeport uninstall [options]

Options:
  --app-dir PATH              App install directory. Default: ~/Applications
  --remove-cli                Also remove the installed CLI.
  --cli PATH                  CLI path to remove. Default: ~/bin/homeport
  --remove-state              Remove Multihome app state.
  --remove-managed-homes      Remove the channel managed homes directory.
  --channel live|dev          App/state channel. Default: live.

Examples:
  homeport uninstall
  homeport uninstall --remove-cli --remove-state
  homeport uninstall --remove-managed-homes
  homeport uninstall --channel dev --remove-state

Safety:
  Multihome never removes your main ~/.codex home. Managed homes are only removed
  when you pass --remove-managed-homes.
""" }
