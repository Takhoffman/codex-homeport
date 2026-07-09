import AppKit
import Foundation

public struct Launcher {
    private let paths: HomeportPaths
    private let fileManager: FileManager

    public init(paths: HomeportPaths = HomeportPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func launch(
        home: CodexHome,
        target: LaunchTarget,
        workspace: String?,
        terminal: TerminalApp,
        appBundle: URL? = nil,
        browserUseLocalTestingMode: Bool = false
    ) throws -> Int32? {
        switch target {
        case .desktop:
            return try launchDesktop(
                home: home,
                appBundle: appBundle,
                browserUseLocalTestingMode: browserUseLocalTestingMode
            )
        case .terminal:
            return try launchTerminal(
                home: home,
                workspace: workspace,
                terminal: terminal,
                browserUseLocalTestingMode: browserUseLocalTestingMode
            )
        }
    }

    private func launchDesktop(home: CodexHome, appBundle: URL?, browserUseLocalTestingMode: Bool) throws -> Int32? {
        let homeURL = URL(fileURLWithPath: home.homePath)
        guard fileManager.fileExists(atPath: homeURL.path) else {
            throw HomeportError.homeDoesNotExist(homeURL.path)
        }
        let bundle = appBundle ?? paths.codexAppBundle
        guard fileManager.fileExists(atPath: bundle.path) else {
            throw HomeportError.commandFailed("Codex app bundle does not exist at \(bundle.path).")
        }

        if let profilePath = home.profilePath {
            try fileManager.createDirectory(at: URL(fileURLWithPath: profilePath), withIntermediateDirectories: true)
        }

        var arguments: [String] = []
        if let profilePath = home.profilePath {
            arguments = ["--user-data-dir=\(profilePath)"]
        }
        if appBundle != nil, let profilePath = home.profilePath {
            let shimProfilePath = "\(profilePath)-shim"
            try fileManager.createDirectory(at: URL(fileURLWithPath: shimProfilePath), withIntermediateDirectories: true)
            try enableBundledBrowserPluginsForShim(in: homeURL)
            try patchCachedBrowserSkillForStatelessIAB(in: homeURL, fileManager: fileManager)
            terminateCodexProcesses(usingProfilePath: shimProfilePath)
            return try launchCustomDesktopBundle(
                bundle: bundle,
                home: home,
                profilePath: shimProfilePath,
                browserUseLocalTestingMode: browserUseLocalTestingMode
            )
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.homePath
        applyBrowserUseLocalTestingMode(browserUseLocalTestingMode, to: &environment)

        let app = try NSWorkspace.shared.launchApplication(
            at: bundle,
            options: [.newInstance, .async],
            configuration: [
                .arguments: arguments,
                .environment: environment
            ]
        )
        app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        return app.processIdentifier
    }

    private func launchCustomDesktopBundle(
        bundle: URL,
        home: CodexHome,
        profilePath: String,
        browserUseLocalTestingMode: Bool
    ) throws -> Int32? {
        var arguments = ["-n", "-F", bundle.path, "--env", "CODEX_HOME=\(home.homePath)"]
        arguments += shimBrowserCompatibleDesktopEnvironmentArguments(environment: ProcessInfo.processInfo.environment)
        if browserUseLocalTestingMode {
            arguments += ["--env", "BROWSER_USE_SECURITY_MODE=disabled-for-local-testing"]
        }
        arguments += ["--args", "--user-data-dir=\(profilePath)"]

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw HomeportError.commandFailed("Custom Codex app launch failed with exit code \(process.terminationStatus).")
        }

        for _ in 0..<20 {
            if let pid = findCodexProcess(bundlePath: bundle.path, profilePath: profilePath) {
                return pid
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        throw HomeportError.commandFailed("Custom Codex app launch did not produce a running process from \(bundle.path).")
    }

    private func terminateCodexProcesses(usingProfilePath profilePath: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return
        }

        // Drain before waiting: ps output can exceed the pipe buffer, which deadlocks waitUntilExit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return }
        let ownPID = Int32(ProcessInfo.processInfo.processIdentifier)
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            guard pid != ownPID else { continue }
            let args = trimmed[space...]
            guard args.contains("--user-data-dir=\(profilePath)") else { continue }
            guard args.contains("/Contents/MacOS/Codex") || args.contains("/Helpers/Codex ") else { continue }
            kill(pid, SIGTERM)
        }
        Thread.sleep(forTimeInterval: 0.4)
    }

    private func findCodexProcess(bundlePath: String, profilePath: String) -> Int32? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain before waiting: ps output can exceed the pipe buffer, which deadlocks waitUntilExit.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return nil }
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            let args = trimmed[space...]
            guard args.contains("\(bundlePath)/Contents/MacOS/Codex") else { continue }
            guard args.contains("--user-data-dir=\(profilePath)") else { continue }
            return pid
        }
        return nil
    }

    private func launchTerminal(
        home: CodexHome,
        workspace: String?,
        terminal: TerminalApp,
        browserUseLocalTestingMode: Bool
    ) throws -> Int32? {
        let command = terminalShellCommand(
            home: home,
            workspace: workspace,
            browserUseLocalTestingMode: browserUseLocalTestingMode
        )
        let script = terminalAppleScript(command: command, terminal: terminal)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw HomeportError.commandFailed("Terminal launch failed with exit code \(process.terminationStatus).")
        }
        return nil
    }

    public func terminalShellCommand(
        home: CodexHome,
        workspace: String?,
        browserUseLocalTestingMode: Bool = false
    ) -> String {
        let workspacePath = workspace?.isEmpty == false ? workspace! : fileManager.currentDirectoryPath
        let browserMode = browserUseLocalTestingMode
            ? " BROWSER_USE_SECURITY_MODE=disabled-for-local-testing"
            : ""
        return """
        cd \(shellQuote(workspacePath)); CODEX_HOME=\(shellQuote(home.homePath))\(browserMode) codex
        """
    }

    public func terminalAppleScript(command: String, terminal: TerminalApp) -> String {
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        switch terminal {
        case .terminal:
            return """
            tell application "Terminal"
              activate
              do script "\(escaped)"
            end tell
            """
        case .iTerm:
            return """
            tell application "iTerm"
              activate
              create window with default profile
              tell current session of current window
                write text "\(escaped)"
              end tell
            end tell
            """
        }
    }
}

func applyBrowserUseLocalTestingMode(_ isEnabled: Bool, to environment: inout [String: String]) {
    if isEnabled {
        environment["BROWSER_USE_SECURITY_MODE"] = "disabled-for-local-testing"
    } else {
        environment.removeValue(forKey: "BROWSER_USE_SECURITY_MODE")
    }
}

func shimBrowserCompatibleDesktopEnvironmentArguments(environment: [String: String]) -> [String] {
    let browserFeatureOverrides = #"{"browserPane":true,"inAppBrowserUse":true,"inAppBrowserUseAllowed":true,"multiBrowserTabs":true}"#
    var arguments = [
        "--env", "BUILD_FLAVOR=dev",
        "--env", "CODEX_ELECTRON_DESKTOP_FEATURE_OVERRIDES=\(browserFeatureOverrides)"
    ]
    for key in ["NO_PROXY", "no_proxy"] {
        if let value = environment[key], !value.isEmpty {
            arguments += ["--env", "\(key)=\(value)"]
        }
    }
    return arguments
}

let statelessIABWorkflowMarker = "## Stateless In-App Browser Calls"
let statelessIABWorkflowEndMarker = "<!-- codex-multihome-stateless-iab-end -->"
let shimBundledBrowserPluginsBegin = "# >>> codex-multihome shim bundled browser plugins >>>"
let shimBundledBrowserPluginsEnd = "# <<< codex-multihome shim bundled browser plugins <<<"

let statelessIABWorkflowInstructions = """

## Stateless In-App Browser Calls

Some Codex Desktop shim sessions do not preserve JavaScript globals between Browser calls. Do not rely on `browser` or `tab` bindings from an earlier JavaScript call. For every in-app browser operation after the first documentation read, reconnect to the Browser backend and reacquire or create the active tab inside the same JavaScript call that performs the action.

Use this complete pattern when the user asks to open and screenshot a page such as Reddit:

```js
if (globalThis.agent?.browsers == null) {
  const { setupBrowserRuntime } = await import("<plugin root>/scripts/browser-client.mjs");
  await setupBrowserRuntime({ globals: globalThis });
}
const browser = await agent.browsers.get("iab");
await (await browser.capabilities.get("visibility")).set(true);
const tabs = await browser.tabs.list();
const existing = tabs.find((tab) => tab.url === "https://www.reddit.com/" || tab.url === "https://reddit.com/");
const tab = existing == null ? await browser.tabs.new() : await browser.tabs.get(existing.id);
await tab.goto("https://www.reddit.com/");
await nodeRepl.emitImage(await tab.screenshot());
nodeRepl.write(`Opened: ${await tab.url()}`);
```

Call the visibility capability before creating, claiming, or navigating tabs when the user asks to open, show, attach, or watch a page in the in-app browser. This is separate from screenshots: screenshots can succeed for a background or live-detached tab even when the Browser pane is not visible to the user.

Use the same reconnect-and-reacquire shape for clicks, content reads, verification, and screenshots. If `browser.tabs.get(existing.id)` is unavailable for a user-opened tab, call `browser.user.openTabs()`, choose the matching tab by visible URL/title, and claim it with `browser.user.claimTab(tab)` before acting.
\(statelessIABWorkflowEndMarker)
"""

func patchCachedBrowserSkillForStatelessIAB(in homeURL: URL, fileManager: FileManager = .default) throws {
    let pluginsURL = homeURL.appendingPathComponent("plugins/cache", isDirectory: true)
    guard fileManager.fileExists(atPath: pluginsURL.path) else { return }

    let enumerator = fileManager.enumerator(
        at: pluginsURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while let skillURL = enumerator?.nextObject() as? URL {
        guard skillURL.lastPathComponent == "SKILL.md" else { continue }
        guard skillURL.path.contains("/browser/") && skillURL.path.contains("/skills/control-in-app-browser/") else { continue }
        let values = try skillURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let text = try String(contentsOf: skillURL, encoding: .utf8)
        let cleaned = removeStatelessIABWorkflowInstructions(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = cleaned + statelessIABWorkflowInstructions
        guard next != text else { continue }
        try next.write(to: skillURL, atomically: true, encoding: .utf8)
    }
}

func removeStatelessIABWorkflowInstructions(from text: String) -> String {
    guard let beginRange = text.range(of: statelessIABWorkflowMarker) else { return text }
    if let endRange = text[beginRange.upperBound...].range(of: statelessIABWorkflowEndMarker) {
        var remaining = text
        remaining.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
        return remaining
    }
    return String(text[..<beginRange.lowerBound])
}

func enableBundledBrowserPluginsForShim(in homeURL: URL, fileManager: FileManager = .default) throws {
    let configURL = homeURL.appendingPathComponent("config.toml")
    let pluginBlock = """

\(shimBundledBrowserPluginsBegin)
[plugins."browser@openai-bundled"]
enabled = true

[plugins."chrome@openai-bundled"]
enabled = true

[plugins."computer-use@openai-bundled"]
enabled = true
\(shimBundledBrowserPluginsEnd)
"""

    let existing = fileManager.fileExists(atPath: configURL.path)
        ? try String(contentsOf: configURL, encoding: .utf8)
        : ""
    let cleaned = removeMarkedBlock(
        from: existing,
        begin: shimBundledBrowserPluginsBegin,
        end: shimBundledBrowserPluginsEnd
    ).trimmingCharacters(in: .whitespacesAndNewlines)
    let next = cleaned.isEmpty ? pluginBlock.trimmingCharacters(in: .newlines) + "\n" : cleaned + "\n" + pluginBlock + "\n"
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    try next.write(to: configURL, atomically: true, encoding: .utf8)
}

func removeMarkedBlock(from text: String, begin: String, end: String) -> String {
    var remaining = text
    while let beginRange = remaining.range(of: begin),
          let endRange = remaining[beginRange.upperBound...].range(of: end) {
        remaining.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
    }
    return remaining
}

public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
