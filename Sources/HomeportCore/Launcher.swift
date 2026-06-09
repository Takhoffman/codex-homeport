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
        terminal: TerminalApp
    ) throws -> Int32? {
        switch target {
        case .desktop:
            return try launchDesktop(home: home)
        case .terminal:
            return try launchTerminal(home: home, workspace: workspace, terminal: terminal)
        }
    }

    private func launchDesktop(home: CodexHome) throws -> Int32 {
        let homeURL = URL(fileURLWithPath: home.homePath)
        guard fileManager.fileExists(atPath: homeURL.path) else {
            throw HomeportError.homeDoesNotExist(homeURL.path)
        }

        if let profilePath = home.profilePath {
            try fileManager.createDirectory(at: URL(fileURLWithPath: profilePath), withIntermediateDirectories: true)
        }

        let process = Process()
        process.executableURL = paths.codexAppExecutable
        if let profilePath = home.profilePath {
            process.arguments = ["--user-data-dir=\(profilePath)"]
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.homePath
        process.environment = environment
        try process.run()
        return process.processIdentifier
    }

    private func launchTerminal(
        home: CodexHome,
        workspace: String?,
        terminal: TerminalApp
    ) throws -> Int32? {
        let command = terminalShellCommand(home: home, workspace: workspace)
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

    public func terminalShellCommand(home: CodexHome, workspace: String?) -> String {
        let workspacePath = workspace?.isEmpty == false ? workspace! : fileManager.currentDirectoryPath
        return """
        cd \(shellQuote(workspacePath)); CODEX_HOME=\(shellQuote(home.homePath)) codex
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

public func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
