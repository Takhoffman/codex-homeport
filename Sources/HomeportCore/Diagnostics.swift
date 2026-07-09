import Foundation

public struct Diagnostics {
    private let paths: HomeportPaths
    private let fileManager: FileManager

    public init(paths: HomeportPaths = HomeportPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func report() -> DiagnosticReport {
        var notes: [String] = []
        let globalHome = shellOutput(["/bin/launchctl", "getenv", "CODEX_HOME"]).nilIfEmpty
        let codexPath = findCodexCLI()
        let desktopApp = paths.codexDesktopApp
        let appExists = desktopApp != nil
        let sessions = sessionCount(in: paths.mainCodexHome)
        let suspicious = suspiciousLaunchers()
        let authStatus = authStatus(in: paths.mainCodexHome, codexPath: codexPath, includeCLIStatus: true)

        if let globalHome {
            notes.append("GUI CODEX_HOME is set to \(globalHome). Homeport recommends clearing it.")
        }
        if !appExists {
            notes.append("Codex Desktop was not found. Looked for bundle ID \(HomeportPaths.codexDesktopBundleIdentifier) in \(paths.desktopAppSearchDescription).")
        }
        if codexPath == nil {
            notes.append("The codex CLI was not found on PATH.")
        }
        if !suspicious.isEmpty {
            notes.append("Some Desktop launchers reference Deckhand/CodexHome.")
        }

        return DiagnosticReport(
            globalCodexHome: globalHome,
            mainSessionCount: sessions,
            suspiciousLaunchers: suspicious,
            codexBinaryPath: codexPath,
            codexAppExists: appExists,
            codexAppPath: desktopApp?.bundleURL.path,
            codexAppExecutablePath: desktopApp?.executableURL.path,
            authStatus: authStatus,
            notes: notes
        )
    }

    public func sessionCount(in home: URL) -> Int {
        let index = home.appendingPathComponent("session_index.jsonl")
        guard let contents = try? String(contentsOf: index, encoding: .utf8) else {
            return 0
        }
        return contents.split(separator: "\n", omittingEmptySubsequences: true).count
    }

    public func authStatus(in home: URL, includeCLIStatus: Bool = true) -> CodexAuthStatus {
        authStatus(in: home, codexPath: includeCLIStatus ? findCodexCLI() : nil, includeCLIStatus: includeCLIStatus)
    }

    public func clearGlobalCodexHome() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["unsetenv", "CODEX_HOME"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw HomeportError.commandFailed("launchctl unsetenv CODEX_HOME exited with \(process.terminationStatus)")
        }
    }

    private func suspiciousLaunchers() -> [String] {
        guard let items = try? fileManager.contentsOfDirectory(
            at: paths.desktopDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        return items
            .filter { $0.pathExtension == "command" || $0.pathExtension == "sh" }
            .compactMap { url in
                guard
                    let text = try? String(contentsOf: url, encoding: .utf8),
                    text.contains("Deckhand/CodexHome")
                else {
                    return nil
                }
                return url.path
            }
            .sorted()
    }

    private func findCodexCLI() -> String? {
        if let path = shellOutput(["/usr/bin/which", "codex"]).nilIfEmpty {
            return path
        }
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/bin/codex",
            "\(NSHomeDirectory())/.local/bin/codex"
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func authStatus(in home: URL, codexPath: String?, includeCLIStatus: Bool) -> CodexAuthStatus {
        let metadata = authMetadata(in: home)
        let cliStatus = includeCLIStatus ? codexPath.map {
            shellOutput(
                [$0, "login", "status"],
                timeout: 5,
                environment: codexHomeEnvironment(home)
            )
        }?.nilIfEmpty
            : nil
        let mode = metadata.mode ?? mode(fromLoginStatus: cliStatus)
        let detail = cliStatus ?? (metadata.hasStoredCredentials ? "Stored credentials found in this home" : nil)
        let cliLoggedIn = isLoggedInStatus(cliStatus)
        let isLoggedIn = cliLoggedIn ?? false
        let usageSummary = includeCLIStatus && isLoggedIn
            ? appServerUsageSummary(codexPath: codexPath, home: home)
            : nil

        return CodexAuthStatus(
            isLoggedIn: isLoggedIn,
            hasStoredCredentials: metadata.hasStoredCredentials,
            mode: mode,
            accountLabel: metadata.accountLabel,
            detail: detail,
            usageSummary: usageSummary ?? "Usage unavailable"
        )
    }

    private func appServerUsageSummary(codexPath: String?, home: URL) -> String? {
        guard let codexPath else {
            return nil
        }
        let messages: [[String: Any]] = [
            [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "homeport",
                        "version": AppVersion.version
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            ],
            [
                "jsonrpc": "2.0",
                "id": 2,
                "method": "account/rateLimits/read"
            ],
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "account/usage/read"
            ]
        ]
        let input = messages.compactMap(jsonLine).joined(separator: "\n") + "\n"
        let output = appServerOutput(codexPath: codexPath, input: input, home: home, timeout: 10)
        return usageSummary(fromAppServerOutput: output)
    }

    private func appServerOutput(codexPath: String, input: String, home: URL, timeout: TimeInterval) -> String {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = Pipe()
        let outputData = LockedData()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = ["app-server", "--stdio"]
        process.environment = codexHomeEnvironment(home)
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        do {
            outputPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else {
                    return
                }
                outputData.append(data)
            }
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                let output = outputData.string()
                if output.contains("\"id\":2") && output.contains("\"id\":3") {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            let output = outputData.string().trimmingCharacters(in: .whitespacesAndNewlines)
            if !output.isEmpty {
                return output
            }
            return String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func usageSummary(fromAppServerOutput output: String) -> String? {
        var rateLimits: [String: Any]?
        var tokenUsage: [String: Any]?
        for line in output.split(separator: "\n") {
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = object["id"] as? Int,
                let result = object["result"] as? [String: Any]
            else {
                continue
            }
            if id == 2 {
                rateLimits = result
            } else if id == 3 {
                tokenUsage = result
            }
        }

        var parts: [String] = []
        if let rateLimitSummary = rateLimitSummary(from: rateLimits) {
            parts.append(rateLimitSummary)
        }
        if let tokenSummary = tokenUsageSummary(from: tokenUsage) {
            parts.append(tokenSummary)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }

    private func rateLimitSummary(from response: [String: Any]?) -> String? {
        let snapshot = (response?["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
            ?? response?["rateLimits"] as? [String: Any]
        guard let snapshot else {
            return nil
        }

        var parts: [String] = []
        if let plan = snapshot["planType"] as? String {
            parts.append(planDisplayName(plan))
        }
        if let primary = snapshot["primary"] as? [String: Any],
           let used = numberValue(primary["usedPercent"]) {
            parts.append("\(formatPercent(used)) / \(windowLabel(primary))")
        }
        if let secondary = snapshot["secondary"] as? [String: Any],
           let used = numberValue(secondary["usedPercent"]) {
            parts.append("\(formatPercent(used)) / \(windowLabel(secondary))")
        }
        if let credits = snapshot["credits"] as? [String: Any],
           let balance = credits["balance"] as? String,
           !balance.isEmpty {
            parts.append("\(balance) credits")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func tokenUsageSummary(from response: [String: Any]?) -> String? {
        guard let summary = response?["summary"] as? [String: Any] else {
            return nil
        }
        var parts: [String] = []
        if let lifetime = integerValue(summary["lifetimeTokens"]) {
            parts.append("\(formatInteger(lifetime)) lifetime tokens")
        }
        if let peak = integerValue(summary["peakDailyTokens"]) {
            parts.append("\(formatInteger(peak)) peak daily")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func windowLabel(_ window: [String: Any]) -> String {
        guard let minutes = numberValue(window["windowDurationMins"]) else {
            return "window"
        }
        if minutes >= 60 * 24 {
            let days = Int((minutes / (60 * 24)).rounded())
            return "\(days)d"
        }
        if minutes >= 60 {
            let hours = Int((minutes / 60).rounded())
            return "\(hours)h"
        }
        return "\(Int(minutes.rounded()))m"
    }

    private func planDisplayName(_ plan: String) -> String {
        switch plan {
        case "pro": "Pro"
        case "plus": "Plus"
        case "team": "Team"
        case "business": "Business"
        case "enterprise": "Enterprise"
        case "edu": "Edu"
        default: plan
        }
    }

    private func formatPercent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func formatInteger(_ value: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func numberValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }
        if let value = value as? Int {
            return Double(value)
        }
        if let value = value as? String {
            return Double(value)
        }
        return nil
    }

    private func integerValue(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }

    private func jsonLine(_ object: [String: Any]) -> String? {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object),
            let line = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return line
    }

    private func authMetadata(in home: URL) -> (hasStoredCredentials: Bool, mode: String?, accountLabel: String?) {
        let authFile = home.appendingPathComponent("auth.json")
        guard
            let data = try? Data(contentsOf: authFile),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return (false, nil, nil)
        }

        let mode = object["auth_mode"] as? String
        let tokens = object["tokens"] as? [String: Any]
        let accountID = tokens?["account_id"] as? String
        let idToken = tokens?["id_token"] as? String
        let accountLabel = accountLabel(idToken: idToken) ?? shortAccountLabel(accountID)
        let hasStoredCredentials = tokens?["access_token"] is String
            || tokens?["refresh_token"] is String
            || tokens?["api_key"] is String

        return (hasStoredCredentials, mode, accountLabel)
    }

    private func accountLabel(idToken: String?) -> String? {
        guard
            let payload = idToken?.split(separator: ".").dropFirst().first,
            let data = base64URLDecode(String(payload)),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        for key in ["email", "preferred_username", "name", "sub"] {
            if let value = claims[key] as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func base64URLDecode(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }

    private func shortAccountLabel(_ accountID: String?) -> String? {
        guard let accountID, !accountID.isEmpty else {
            return nil
        }
        return "account \(accountID.prefix(8))"
    }

    private func mode(fromLoginStatus status: String?) -> String? {
        guard let status else {
            return nil
        }
        let marker = "using "
        guard let range = status.range(of: marker, options: [.caseInsensitive]) else {
            return nil
        }
        return String(status[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func isLoggedInStatus(_ status: String?) -> Bool? {
        guard let status else {
            return nil
        }
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("logged in") {
            return true
        }
        if normalized.hasPrefix("not logged in") {
            return false
        }
        return nil
    }

    private func codexHomeEnvironment(_ home: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for key in ["OPENAI_API_KEY", "CODEX_ACCESS_TOKEN"] {
            environment.removeValue(forKey: key)
        }
        environment["CODEX_HOME"] = home.path
        return environment
    }

    private func shellOutput(
        _ arguments: [String],
        input: String? = nil,
        timeout: TimeInterval = 5,
        environment: [String: String]? = nil
    ) -> String {
        guard let executable = arguments.first else {
            return ""
        }
        let process = Process()
        let pipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        if let environment {
            process.environment = environment
        }
        process.standardOutput = pipe
        process.standardError = errorPipe
        if let inputPipe {
            process.standardInput = inputPipe
        }
        do {
            try process.run()
            if let input, let inputPipe {
                inputPipe.fileHandleForWriting.write(Data(input.utf8))
                try? inputPipe.fileHandleForWriting.close()
            }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return ""
            }
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !output.isEmpty {
                return output
            }
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ nextData: Data) {
        lock.lock()
        data.append(nextData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let currentData = data
        lock.unlock()
        return String(data: currentData, encoding: .utf8) ?? ""
    }
}
