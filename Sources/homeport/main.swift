import Foundation
import HomeportCore

let service = HomeportService()
let arguments = Array(CommandLine.arguments.dropFirst())

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
    print("Codex Homeport Doctor")
    print("Main CODEX_HOME: \(service.paths.mainCodexHome.path)")
    print("Main sessions: \(report.mainSessionCount)")
    print("Codex.app: \(report.codexAppExists ? "found" : "missing")")
    print("codex CLI: \(report.codexBinaryPath ?? "missing")")
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
    let cloneOptions = cloneOptions(from: arguments, base: state.preferences.cloneOptions)
    let name = option(arguments, "--name") ?? arguments.first(where: { !$0.hasPrefix("--") }) ?? "Homeport Clone"
    let home = try service.clone(name: name, preset: preset, options: cloneOptions)
    print("Created \(home.name)")
    print("slug=\(home.slug)")
    print("CODEX_HOME=\(home.homePath)")
    print("profile=\(home.profilePath ?? "none")")
}

func createHome(_ arguments: [String]) throws {
    let kind = option(arguments, "--kind") ?? arguments.first ?? "clean-room"
    let name = option(arguments, "--name")
    let home: CodexHome
    switch kind {
    case "clean-room", "cleanRoom":
        home = try service.createCleanRoom(name: name)
    case "temporary", "temp":
        home = try service.createTemporary(name: name)
    case "clone":
        let preset = option(arguments, "--preset").flatMap(ClonePreset.init(rawValue:)) ?? .workingSetup
        home = try service.clone(name: name ?? "Homeport Clone", preset: preset, options: cloneOptions(from: arguments, base: .preset(preset)))
    default:
        throw HomeportError.unsupportedCommand("create \(kind)")
    }
    print("Created \(home.name)")
    print("slug=\(home.slug)")
    print("CODEX_HOME=\(home.homePath)")
    print("profile=\(home.profilePath ?? "none")")
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
    try service.renameHome(id: home.id, name: name)
    print("Renamed \(selector) to \(name).")
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
    print("Codex Homeport \(AppVersion.version) (\(AppVersion.build))")
}

func install(_ arguments: [String]) throws {
    let repo = try packageRoot(from: option(arguments, "--repo"))
    let installDirectory = URL(fileURLWithPath: option(arguments, "--prefix") ?? "\(NSHomeDirectory())/bin")
    let includeApp = arguments.contains("--with-app")
    let appDirectory = URL(fileURLWithPath: option(arguments, "--app-dir") ?? "\(NSHomeDirectory())/Applications")

    print("Installing Codex Homeport \(AppVersion.version) from \(repo.path)")
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
        let appPath = try buildAppBundle(repo: repo)
        let installedApp = try installAppBundle(appPath, appDirectory: appDirectory)
        print("Installed app bundle: \(installedApp.path)")
    }
}

func update(_ arguments: [String]) throws {
    let repo = try packageRoot(from: option(arguments, "--repo"))
    let skipPull = arguments.contains("--no-pull")
    let appPath = installedAppPath(arguments)
    let shouldInstallApp = arguments.contains("--with-app") || FileManager.default.fileExists(atPath: appPath.path)
    let shouldRestart = shouldInstallApp && !arguments.contains("--no-restart") && isHomeportAppRunning()

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

func buildAppBundle(repo: URL) throws -> URL {
    let app = repo.appendingPathComponent("dist/Codex Homeport.app")
    let macOS = app.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)

    try runProcess("swift", ["build", "--package-path", repo.path, "-c", "release", "--product", "CodexHomeportApp"])
    let builtApp = repo.appendingPathComponent(".build/release/CodexHomeportApp")
    let executable = macOS.appendingPathComponent("Codex Homeport")
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
      <string>Codex Homeport</string>
      <key>CFBundleIdentifier</key>
      <string>com.takhoffman.codex-homeport</string>
      <key>CFBundleName</key>
      <string>Codex Homeport</string>
      <key>CFBundleDisplayName</key>
      <string>Codex Homeport</string>
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
    </dict>
    </plist>
    """
    try plist.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
    return app
}

func installAppBundle(_ builtApp: URL, appDirectory: URL) throws -> URL {
    try FileManager.default.createDirectory(at: appDirectory, withIntermediateDirectories: true)
    let installedApp = appDirectory.appendingPathComponent("Codex Homeport.app")
    if FileManager.default.fileExists(atPath: installedApp.path) {
        try trash(installedApp)
    }
    try FileManager.default.copyItem(at: builtApp, to: installedApp)
    return installedApp
}

func start(_ arguments: [String]) throws {
    let appPath = installedAppPath(arguments)
    guard FileManager.default.fileExists(atPath: appPath.path) else {
        throw HomeportError.commandFailed("Codex Homeport.app was not found at \(appPath.path). Run homeport install --with-app first.")
    }
    try runProcess("open", [appPath.path])
    print("Started Codex Homeport: \(appPath.path)")
}

func restart(_ arguments: [String]) throws {
    try runProcess("pkill", ["-f", "Codex Homeport.app/Contents/MacOS/Codex Homeport"], allowFailure: true)
    Thread.sleep(forTimeInterval: 0.5)
    try start(arguments)
}

func autostart(_ arguments: [String]) throws {
    let action = arguments.first ?? "status"
    switch action {
    case "enable", "on":
        let appPath = installedAppPath(arguments)
        guard FileManager.default.fileExists(atPath: appPath.path) else {
            throw HomeportError.commandFailed("Codex Homeport.app was not found at \(appPath.path). Run homeport install --with-app first.")
        }
        try writeLaunchAgent(appPath: appPath)
        try runProcess("launchctl", ["unload", launchAgentPlist().path], allowFailure: true)
        try runProcess("launchctl", ["load", launchAgentPlist().path])
        print("Autostart enabled.")
    case "disable", "off":
        try runProcess("launchctl", ["unload", launchAgentPlist().path], allowFailure: true)
        if FileManager.default.fileExists(atPath: launchAgentPlist().path) {
            try trash(launchAgentPlist())
        }
        print("Autostart disabled.")
    case "status":
        if FileManager.default.fileExists(atPath: launchAgentPlist().path) {
            print("Autostart: enabled")
            print("plist: \(launchAgentPlist().path)")
        } else {
            print("Autostart: disabled")
        }
    default:
        throw HomeportError.unsupportedCommand("autostart \(action)")
    }
}

func configure(_ arguments: [String]) throws {
    if arguments.contains("--reset") {
        try service.resetPreferences()
        print("Reset Homeport preferences to defaults.")
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
        try service.saveState(state)
        print("Default clone preset: \(preset.rawValue)")
    }

    if let include = option(arguments, "--clone-include") {
        var state = try service.loadState()
        state.preferences.cloneOptions = applyCloneList(include, to: state.preferences.cloneOptions, value: true)
        try service.saveState(state)
        print("Updated clone includes: \(include)")
    }

    if let exclude = option(arguments, "--clone-exclude") {
        var state = try service.loadState()
        state.preferences.cloneOptions = applyCloneList(exclude, to: state.preferences.cloneOptions, value: false)
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
        try autostart(["status"])
    }
}

func onboard(_ arguments: [String]) throws {
    let repo = try packageRoot(from: option(arguments, "--repo"))
    let prefix = option(arguments, "--prefix") ?? "\(NSHomeDirectory())/bin"
    let appDir = option(arguments, "--app-dir") ?? "\(NSHomeDirectory())/Applications"
    let terminal = option(arguments, "--terminal") ?? "terminal"
    let workspace = option(arguments, "--workspace") ?? FileManager.default.currentDirectoryPath

    try install(["--repo", repo.path, "--prefix", prefix, "--with-app", "--app-dir", appDir])
    try configure(["--terminal", terminal, "--workspace", workspace, "--autostart", "on", "--app-dir", appDir])
    try start(["--app-dir", appDir])
    print("Onboarding complete.")
}

func uninstall(_ arguments: [String]) throws {
    let appPath = installedAppPath(arguments)
    let removeCLI = arguments.contains("--remove-cli")
    let removeState = arguments.contains("--remove-state")
    let removeManagedHomes = arguments.contains("--remove-managed-homes")
    let cliPath = URL(fileURLWithPath: option(arguments, "--cli") ?? "\(NSHomeDirectory())/bin/homeport")

    try autostart(["disable"])

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
            print("Moved Homeport state to Trash: \(stateRoot.path)")
        }
    } else {
        print("Kept Homeport state: \(service.paths.appSupportDirectory.path)")
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

func installedAppPath(_ arguments: [String]) -> URL {
    let appDirectory = URL(fileURLWithPath: option(arguments, "--app-dir") ?? "\(NSHomeDirectory())/Applications")
    return appDirectory.appendingPathComponent("Codex Homeport.app")
}

func isHomeportAppRunning() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["pgrep", "-f", "Codex Homeport.app/Contents/MacOS/Codex Homeport"]
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

func launchAgentPlist() -> URL {
    URL(fileURLWithPath: "\(NSHomeDirectory())/Library/LaunchAgents/com.takhoffman.codex-homeport.plist")
}

func writeLaunchAgent(appPath: URL) throws {
    let plistURL = launchAgentPlist()
    try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>com.takhoffman.codex-homeport</string>
      <key>ProgramArguments</key>
      <array>
        <string>/usr/bin/open</string>
        <string>\(xmlEscape(appPath.path))</string>
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
        URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/CodexHomeport/Source"),
        URL(fileURLWithPath: "\(NSHomeDirectory())/github.com/Takhoffman/codex-homeport")
    ]
    for fallback in fallbackRoots where FileManager.default.fileExists(atPath: fallback.appendingPathComponent("Package.swift").path) {
        return fallback
    }

    throw HomeportError.commandFailed("Run this from the Codex Homeport repo or pass --repo PATH.")
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

func option(_ arguments: [String], _ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
        return nil
    }
    return arguments[index + 1]
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
Codex Homeport

Safely launch and manage multiple Codex homes without leaking global CODEX_HOME
state. Homeport can open Codex.app, start terminal Codex sessions, clone your
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
  version      Show installed Homeport version
  start        Open the installed menu bar app
  restart      Quit and reopen the installed menu bar app
  configure    Change terminal, workspace, or autostart preferences
  autostart    Enable, disable, or show LaunchAgent status
  uninstall    Remove the app/autostart entry; extra removals are opt-in

Home commands:
  clone        Create a managed Codex home from ~/.codex
  create       Create a clean-room, temporary, or cloned home
  rename       Rename a managed home
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
  homeport delete scratch-lab
  homeport clone --preset working-setup --name "Plugin Lab"
  homeport review
  homeport doctor --repair

Paths:
  Main Codex home:        ~/.codex
  Managed homes:          ~/.codex-homes/<slug>
  Homeport state:         ~/Library/Application Support/CodexHomeport/homeport.json
  Installed app default:  ~/Applications/Codex Homeport.app
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
  Homeport sets CODEX_HOME only for the launched process. It does not call
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

Create a named managed Codex home under ~/.codex-homes.

Usage:
  homeport clone --preset working-setup|config-only|everything|empty --name NAME [--include LIST] [--exclude LIST]

Presets:
  working-setup   Config, auth, skills, plugins, MCP-related files; no sessions/logs.
  config-only     Config and customization only; no auth.
  everything      Full copy of ~/.codex.
  empty           Empty managed home.

Examples:
  homeport clone --preset working-setup --name "Plugin Lab"
  homeport clone --preset config-only --name "No Auth Test"
  homeport clone --preset empty --name "Blank Slate"
  homeport clone --name "Skills Only" --include skills,plugins --exclude auth,memories,browser

Clone categories:
  config, auth, skills, plugins, agents, prompts, rules, profiles, memories,
  browser, sessions, everything, all
""" }

func createHelp() -> String { """
homeport create

Create a managed Codex home.

Usage:
  homeport create --kind clean-room|temporary|clone [--name NAME] [--preset PRESET]

Examples:
  homeport create --kind clean-room --name "Blank Slate"
  homeport create --kind temporary --name "Throwaway UI"
  homeport create --kind clone --preset config-only --name "Config Lab"
""" }

func renameHelp() -> String { """
homeport rename

Rename a managed home. The main ~/.codex home cannot be renamed.

Usage:
  homeport rename SLUG --name NAME

Examples:
  homeport rename config-lab --name "Config Lab 2"
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

Build and install Homeport from a source checkout.

Usage:
  homeport install [--prefix PATH] [--with-app] [--app-dir PATH] [--repo PATH]

Options:
  --prefix PATH     CLI install directory. Default: ~/bin
  --with-app        Also build and install the menu bar app.
  --app-dir PATH    App install directory. Default: ~/Applications
  --repo PATH       Source repo path. Usually auto-detected.

Examples:
  homeport install
  homeport install --with-app
  homeport install --prefix ~/.local/bin --with-app --app-dir /Applications
""" }

func updateHelp() -> String { """
homeport update

Fast-forward the source repo, reinstall Homeport, and restart the menu bar app
when it is already installed and running.

Usage:
  homeport update [--prefix PATH] [--with-app] [--app-dir PATH] [--repo PATH] [--no-pull]

Options:
  --with-app      Install the menu bar app. This is automatic when the app exists.
  --no-pull       Skip git pull and rebuild from the current checkout.
  --no-restart    Reinstall without restarting a running menu bar app.

Examples:
  homeport update
  homeport update --with-app
  homeport update --no-pull --with-app
""" }

func versionHelp() -> String { """
homeport version

Show the installed Codex Homeport version.

Usage:
  homeport version
  homeport --version
""" }

func startHelp() -> String { """
homeport start

Open the installed Codex Homeport menu bar app.

Usage:
  homeport start [--app-dir PATH]

Examples:
  homeport start
  homeport start --app-dir ~/Applications
""" }

func restartHelp() -> String { """
homeport restart

Quit any running Codex Homeport menu bar process and reopen the installed app.
Use this after reinstalling so macOS does not keep an older menu bar build alive.

Usage:
  homeport restart [--app-dir PATH]

Examples:
  homeport restart
  homeport restart --app-dir ~/Applications
""" }

func autostartHelp() -> String { """
homeport autostart

Manage the user LaunchAgent that opens Codex Homeport at login.

Usage:
  homeport autostart enable [--app-dir PATH]
  homeport autostart disable
  homeport autostart status

Files:
  ~/Library/LaunchAgents/com.takhoffman.codex-homeport.plist

Examples:
  homeport autostart enable
  homeport autostart status
  homeport autostart disable
""" }

func configureHelp() -> String { """
homeport configure

Change Homeport preferences without reinstalling.

Usage:
  homeport configure [options]

Options:
  --terminal terminal|iTerm             Preferred terminal for terminal launches.
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
  --reset                               Reset Homeport preferences to defaults.
  --show                                Print current configuration.

Examples:
  homeport configure --show
  homeport configure --terminal iTerm
  homeport configure --workspace ~/github.com/Takhoffman/codex-homeport
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
  homeport onboard --terminal iTerm --workspace ~/github.com/Takhoffman/codex-homeport
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
  --remove-state              Remove Homeport app state.
  --remove-managed-homes      Remove ~/.codex-homes.

Examples:
  homeport uninstall
  homeport uninstall --remove-cli --remove-state
  homeport uninstall --remove-managed-homes

Safety:
  Homeport never removes your main ~/.codex home. Managed homes are only removed
  when you pass --remove-managed-homes.
""" }
