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
        let appExists = fileManager.isExecutableFile(atPath: paths.codexAppExecutable.path)
        let sessions = sessionCount(in: paths.mainCodexHome)
        let suspicious = suspiciousLaunchers()

        if let globalHome {
            notes.append("GUI CODEX_HOME is set to \(globalHome). Homeport recommends clearing it.")
        }
        if !appExists {
            notes.append("Codex.app executable was not found at \(paths.codexAppExecutable.path).")
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

    private func shellOutput(_ arguments: [String]) -> String {
        guard let executable = arguments.first else {
            return ""
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(arguments.dropFirst())
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
