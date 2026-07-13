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
        browserUseLocalTestingMode: Bool = false,
        desktopAppDevFlavor: Bool = false,
        proxyURL: String? = nil,
        proxyCACertificatePath: String? = nil
    ) throws -> Int32? {
        switch target {
        case .desktop:
            return try launchDesktop(
                home: home,
                appBundle: appBundle,
                browserUseLocalTestingMode: browserUseLocalTestingMode,
                desktopAppDevFlavor: desktopAppDevFlavor,
                proxyURL: proxyURL,
                proxyCACertificatePath: proxyCACertificatePath
            )
        case .terminal:
            return try launchTerminal(
                home: home,
                workspace: workspace,
                terminal: terminal,
                browserUseLocalTestingMode: browserUseLocalTestingMode,
                proxyURL: proxyURL,
                proxyCACertificatePath: proxyCACertificatePath
            )
        }
    }

    private func launchDesktop(
        home: CodexHome,
        appBundle: URL?,
        browserUseLocalTestingMode: Bool,
        desktopAppDevFlavor: Bool,
        proxyURL: String?,
        proxyCACertificatePath: String?
    ) throws -> Int32? {
        let homeURL = URL(fileURLWithPath: home.homePath)
        guard fileManager.fileExists(atPath: homeURL.path) else {
            throw HomeportError.homeDoesNotExist(homeURL.path)
        }
        let bundle = appBundle ?? paths.codexDesktopApp?.bundleURL
        guard let bundle else {
            throw HomeportError.commandFailed(
                "Codex Desktop was not found. Looked for bundle ID \(HomeportPaths.codexDesktopBundleIdentifier) in \(paths.desktopAppSearchDescription)."
            )
        }
        guard fileManager.fileExists(atPath: bundle.path) else {
            throw HomeportError.commandFailed("Codex Desktop app bundle does not exist at \(bundle.path).")
        }

        if let profilePath = home.profilePath {
            try fileManager.createDirectory(at: URL(fileURLWithPath: profilePath), withIntermediateDirectories: true)
        }

        var arguments: [String] = []
        if let profilePath = home.profilePath {
            arguments = ["--user-data-dir=\(profilePath)"]
        }
        if let proxyURL { arguments.append("--proxy-server=\(proxyURL)") }
        if appBundle != nil, let profilePath = home.profilePath {
            let shimProfilePath = "\(profilePath)-shim"
            try fileManager.createDirectory(at: URL(fileURLWithPath: shimProfilePath), withIntermediateDirectories: true)
            try hydrateBundledBrowserPluginsForShim(
                from: paths.mainCodexHome,
                to: homeURL,
                fileManager: fileManager
            )
            try enableBundledBrowserPluginsForShim(in: homeURL)
            try patchCachedBrowserSkillForStatelessIAB(in: homeURL, fileManager: fileManager)
            try ComputerUseDefaults.applyInstallSupport(in: homeURL, isEnabled: true, fileManager: fileManager)
            // Reuse the live shim session instead of killing it. Restarting Codex while a
            // Computer Use permission card is pending leaves a persisted "Awaiting approval"
            // badge whose in-memory approval request no longer exists.
            if let existingPID = findCodexProcess(bundlePath: bundle.path, profilePath: shimProfilePath) {
                NSRunningApplication(processIdentifier: existingPID)?.activate(
                    options: [.activateAllWindows, .activateIgnoringOtherApps]
                )
                return existingPID
            }
            terminateCodexProcesses(usingProfilePath: shimProfilePath)
            return try launchCustomDesktopBundle(
                bundle: bundle,
                home: home,
                profilePath: shimProfilePath,
                browserUseLocalTestingMode: browserUseLocalTestingMode,
                proxyURL: proxyURL,
                proxyCACertificatePath: proxyCACertificatePath
            )
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.homePath
        applyBrowserUseLocalTestingMode(browserUseLocalTestingMode, to: &environment)
        applyDesktopAppDevFlavor(desktopAppDevFlavor, to: &environment)
        applyProxy(proxyURL: proxyURL, caCertificatePath: proxyCACertificatePath, to: &environment)

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
        browserUseLocalTestingMode: Bool,
        proxyURL: String?,
        proxyCACertificatePath: String?
    ) throws -> Int32? {
        var arguments = ["-n", "-F", bundle.path, "--env", "CODEX_HOME=\(home.homePath)"]
        arguments += shimBrowserCompatibleDesktopEnvironmentArguments(environment: ProcessInfo.processInfo.environment)
        if browserUseLocalTestingMode {
            arguments += ["--env", "BROWSER_USE_SECURITY_MODE=disabled-for-local-testing"]
        }
        if let proxyURL {
            arguments += ["--env", "HTTPS_PROXY=\(proxyURL)", "--env", "HTTP_PROXY=\(proxyURL)"]
        }
        if let proxyCACertificatePath, !proxyCACertificatePath.isEmpty {
            arguments += ["--env", "SSL_CERT_FILE=\(proxyCACertificatePath)", "--env", "NODE_EXTRA_CA_CERTS=\(proxyCACertificatePath)"]
        }
        arguments += ["--args", "--user-data-dir=\(profilePath)"]
        if let proxyURL { arguments.append("--proxy-server=\(proxyURL)") }

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
        return existingCustomDesktopProcessPID(
            processListing: output,
            bundlePath: bundlePath,
            profilePath: profilePath
        )
    }

    func existingCustomDesktopProcessPID(
        processListing: String,
        bundlePath: String,
        profilePath: String
    ) -> Int32? {
        for line in processListing.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            guard let pid = Int32(trimmed[..<space]) else { continue }
            let args = trimmed[space...]
            // The renamed shim bundle currently retains ChatGPT as CFBundleExecutable.
            // Match the bundle's main executable directory instead of assuming "Codex".
            guard args.contains("\(bundlePath)/Contents/MacOS/") else { continue }
            guard args.contains("--user-data-dir=\(profilePath)") else { continue }
            return pid
        }
        return nil
    }

    private func launchTerminal(
        home: CodexHome,
        workspace: String?,
        terminal: TerminalApp,
        browserUseLocalTestingMode: Bool,
        proxyURL: String?,
        proxyCACertificatePath: String?
    ) throws -> Int32? {
        let command = terminalShellCommand(
            home: home,
            workspace: workspace,
            browserUseLocalTestingMode: browserUseLocalTestingMode,
            proxyURL: proxyURL,
            proxyCACertificatePath: proxyCACertificatePath
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
        browserUseLocalTestingMode: Bool = false,
        proxyURL: String? = nil,
        proxyCACertificatePath: String? = nil
    ) -> String {
        let workspacePath = workspace?.isEmpty == false ? workspace! : fileManager.currentDirectoryPath
        let browserMode = browserUseLocalTestingMode
            ? " BROWSER_USE_SECURITY_MODE=disabled-for-local-testing"
            : ""
        let proxyEnvironment = proxyShellEnvironment(proxyURL: proxyURL, caCertificatePath: proxyCACertificatePath)
        return """
        cd \(shellQuote(workspacePath)); CODEX_HOME=\(shellQuote(home.homePath))\(browserMode)\(proxyEnvironment) codex
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

func applyProxy(proxyURL: String?, caCertificatePath: String?, to environment: inout [String: String]) {
    guard let proxyURL, !proxyURL.isEmpty else { return }
    environment["HTTPS_PROXY"] = proxyURL
    environment["HTTP_PROXY"] = proxyURL
    environment["https_proxy"] = proxyURL
    environment["http_proxy"] = proxyURL
    environment["NO_PROXY"] = mergedNoProxy(environment["NO_PROXY"])
    environment["no_proxy"] = mergedNoProxy(environment["no_proxy"])
    if let path = caCertificatePath, !path.isEmpty {
        environment["SSL_CERT_FILE"] = path
        environment["NODE_EXTRA_CA_CERTS"] = path
    }
}

private func mergedNoProxy(_ existing: String?) -> String {
    var entries = (existing ?? "").split(separator: ",").map(String.init)
    for host in ["127.0.0.1", "localhost", "::1"] where !entries.contains(host) {
        entries.append(host)
    }
    return entries.joined(separator: ",")
}

func proxyShellEnvironment(proxyURL: String?, caCertificatePath: String?) -> String {
    guard let proxyURL, !proxyURL.isEmpty else { return "" }
    var result = " HTTPS_PROXY=\(shellQuote(proxyURL)) HTTP_PROXY=\(shellQuote(proxyURL)) https_proxy=\(shellQuote(proxyURL)) http_proxy=\(shellQuote(proxyURL))"
    result += " NO_PROXY='127.0.0.1,localhost,::1' no_proxy='127.0.0.1,localhost,::1'"
    if let path = caCertificatePath, !path.isEmpty {
        result += " SSL_CERT_FILE=\(shellQuote(path)) NODE_EXTRA_CA_CERTS=\(shellQuote(path))"
    }
    return result
}

func applyBrowserUseLocalTestingMode(_ isEnabled: Bool, to environment: inout [String: String]) {
    if isEnabled {
        environment["BROWSER_USE_SECURITY_MODE"] = "disabled-for-local-testing"
    } else {
        environment.removeValue(forKey: "BROWSER_USE_SECURITY_MODE")
    }
}

func applyDesktopAppDevFlavor(_ isEnabled: Bool, to environment: inout [String: String]) {
    if isEnabled {
        environment["BUILD_FLAVOR"] = "dev"
    } else {
        environment.removeValue(forKey: "BUILD_FLAVOR")
    }
}

public func setBrowserUseLocalTestingModeInConfig(in homeURL: URL, isEnabled: Bool, fileManager: FileManager = .default) throws {
    let configURL = homeURL.appendingPathComponent("config.toml")
    let existing = fileManager.fileExists(atPath: configURL.path)
        ? try String(contentsOf: configURL, encoding: .utf8)
        : ""
    let next = updateNodeReplEnv(
        in: existing,
        key: "BROWSER_USE_SECURITY_MODE",
        value: isEnabled ? "disabled-for-local-testing" : nil
    )
    guard next != existing else { return }
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    try next.write(to: configURL, atomically: true, encoding: .utf8)
}

func updateNodeReplEnv(in toml: String, key: String, value: String?) -> String {
    var lines = toml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    let hadTrailingNewline = toml.hasSuffix("\n")
    let tableHeader = "[mcp_servers.node_repl.env]"
    let assignmentPrefix = "\(key) "
    let assignment = value.map { "\(key) = \"\($0)\"" }

    guard let tableIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == tableHeader }) else {
        guard let assignment else { return toml }
        let block = toml.isEmpty || hadTrailingNewline
            ? "\(tableHeader)\n\(assignment)\n"
            : "\n\(tableHeader)\n\(assignment)\n"
        return toml + block
    }

    let tableEnd = lines[(tableIndex + 1)...].firstIndex { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    } ?? lines.endIndex

    if let keyIndex = lines[(tableIndex + 1)..<tableEnd].firstIndex(where: { line in
        line.trimmingCharacters(in: .whitespaces).hasPrefix(assignmentPrefix)
    }) {
        if let assignment {
            lines[keyIndex] = assignment
        } else {
            lines.remove(at: keyIndex)
        }
    } else if let assignment {
        lines.insert(assignment, at: tableIndex + 1)
    }

    var result = lines.joined(separator: "\n")
    if hadTrailingNewline || !result.isEmpty {
        result += "\n"
    }
    return result
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
let shimBundledBrowserPluginNames = ["browser", "chrome", "computer-use"]

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

func hydrateBundledBrowserPluginsForShim(
    from sourceHomeURL: URL,
    to destinationHomeURL: URL,
    fileManager: FileManager = .default
) throws {
    let sourceRoot = sourceHomeURL.appendingPathComponent("plugins/cache/openai-bundled", isDirectory: true)
    guard fileManager.fileExists(atPath: sourceRoot.path) else { return }

    let destinationRoot = destinationHomeURL.appendingPathComponent("plugins/cache/openai-bundled", isDirectory: true)
    try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

    for pluginName in shimBundledBrowserPluginNames {
        let sourcePlugin = sourceRoot.appendingPathComponent(pluginName, isDirectory: true)
        guard fileManager.fileExists(atPath: sourcePlugin.path) else { continue }

        let destinationPlugin = destinationRoot.appendingPathComponent(pluginName, isDirectory: true)
        try fileManager.createDirectory(at: destinationPlugin, withIntermediateDirectories: true)
        let versions = try fileManager.contentsOfDirectory(
            at: sourcePlugin,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        for version in versions {
            let destinationVersion = destinationPlugin.appendingPathComponent(version.lastPathComponent)
            guard !fileManager.fileExists(atPath: destinationVersion.path) else { continue }
            try fileManager.copyItem(at: version, to: destinationVersion)
        }
    }

    let sourceMarketplace = sourceHomeURL
        .appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled", isDirectory: true)
    guard fileManager.fileExists(atPath: sourceMarketplace.path) else { return }
    let destinationMarketplace = destinationHomeURL
        .appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled", isDirectory: true)
    try fileManager.createDirectory(
        at: destinationMarketplace.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    if fileManager.fileExists(atPath: destinationMarketplace.path) {
        try fileManager.removeItem(at: destinationMarketplace)
    }
    try fileManager.copyItem(at: sourceMarketplace, to: destinationMarketplace)
}

func enableBundledBrowserPluginsForShim(in homeURL: URL, fileManager: FileManager = .default) throws {
    let configURL = homeURL.appendingPathComponent("config.toml")
    let marketplaceSource = homeURL
        .appendingPathComponent(".tmp/bundled-marketplaces/openai-bundled", isDirectory: true)
        .path
    let pluginBlock = """

\(shimBundledBrowserPluginsBegin)
[plugins."browser@openai-bundled"]
enabled = true

[plugins."chrome@openai-bundled"]
enabled = true

[plugins."computer-use@openai-bundled"]
enabled = true

[marketplaces.openai-bundled]
source_type = "local"
source = "\(marketplaceSource)"
\(shimBundledBrowserPluginsEnd)
"""

    let existing = fileManager.fileExists(atPath: configURL.path)
        ? try String(contentsOf: configURL, encoding: .utf8)
        : ""
    var cleaned = removeLines(
        [shimBundledBrowserPluginsBegin, shimBundledBrowserPluginsEnd],
        from: existing
    )
    for tableName in [
        "plugins.\"browser@openai-bundled\"",
        "plugins.\"chrome@openai-bundled\"",
        "plugins.\"computer-use@openai-bundled\"",
        "marketplaces.openai-bundled"
    ] {
        cleaned = removeTOMLTable(named: tableName, from: cleaned)
    }
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    let next = cleaned.isEmpty ? pluginBlock.trimmingCharacters(in: .newlines) + "\n" : cleaned + "\n" + pluginBlock + "\n"
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    try next.write(to: configURL, atomically: true, encoding: .utf8)
}

func removeLines(_ removedLines: Set<String>, from text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
        .filter { !removedLines.contains($0.trimmingCharacters(in: .whitespaces)) }
        .joined(separator: "\n")
}

func removeTOMLTable(named tableName: String, from text: String) -> String {
    let header = "[\(tableName)]"
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var result: [String] = []
    var skipping = false
    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed == header {
            skipping = true
            continue
        }
        if skipping, trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
            skipping = false
        }
        if !skipping {
            result.append(line)
        }
    }
    return result.joined(separator: "\n")
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
