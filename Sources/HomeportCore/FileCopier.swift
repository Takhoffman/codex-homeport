import Foundation

public struct FileCopier {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func createHome(
        destination: URL,
        source: URL?,
        preset: ClonePreset
    ) throws {
        try createHome(destination: destination, source: source, options: .preset(preset))
    }

    public func createHome(
        destination: URL,
        source: URL?,
        options: CloneOptions
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw HomeportError.homeAlreadyExists(destination.path)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let source, options != .empty else {
            return
        }

        if options.everything {
            try copyEverything(from: source, to: destination)
            return
        }

        try copyExisting(names: names(for: options), from: source, to: destination)
    }

    public func cleanup(paths: [URL]) throws {
        for path in paths where fileManager.fileExists(atPath: path.path) {
            try trash(path)
        }
    }

    public func trash(_ path: URL) throws {
        var resultingURL: NSURL?
        try fileManager.trashItem(at: path, resultingItemURL: &resultingURL)
    }

    public func cleanupTargets(for home: CodexHome) -> [URL] {
        var targets = [URL(fileURLWithPath: home.homePath)]
        if let profilePath = home.profilePath {
            targets.append(URL(fileURLWithPath: profilePath))
        }
        return targets
    }

    private var configOnlyNames: [String] {
        [
            "config.toml",
            "AGENTS.md",
            "agents",
            "plugins",
            "skills",
            "skills-disabled",
            "profiles",
            "rules",
            "prompts",
            "mcp-auth"
        ]
    }

    private var workingSetupNames: [String] {
        configOnlyNames + [
            "auth.json",
            "chrome-native-hosts.json",
            "chrome-native-hosts-v2.json",
            "keybindings.json",
            "memories",
            "memories_1.sqlite",
            "memories_1.sqlite-shm",
            "memories_1.sqlite-wal",
            "version.json"
        ]
    }

    private func names(for options: CloneOptions) -> [String] {
        var names: [String] = []
        if options.config {
            names.append(contentsOf: ["config.toml", "AGENTS.md", "keybindings.json", "version.json"])
        }
        if options.auth {
            names.append("auth.json")
        }
        if options.skills {
            names.append(contentsOf: ["skills", "skills-disabled", "skill-backups"])
        }
        if options.plugins {
            names.append(contentsOf: ["plugins", "vendor_imports"])
        }
        if options.agents {
            names.append("agents")
        }
        if options.prompts {
            names.append("prompts")
        }
        if options.rules {
            names.append("rules")
        }
        if options.profiles {
            names.append("profiles")
        }
        if options.memories {
            names.append(contentsOf: ["memories", "memories_1.sqlite", "memories_1.sqlite-shm", "memories_1.sqlite-wal"])
        }
        if options.browserSupport {
            names.append(contentsOf: [
                "browser",
                "chrome-cdp-profile",
                "chrome-native-hosts.json",
                "chrome-native-hosts-v2.json",
                "computer-use",
                "mcp-auth"
            ])
        }
        if options.sessionsAndLogs {
            names.append(contentsOf: [
                "session_index.jsonl",
                "sessions",
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
            ])
        }
        return Array(Set(names)).sorted()
    }

    private func copyExisting(names: [String], from source: URL, to destination: URL) throws {
        for name in names {
            let sourceURL = source.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            let destinationURL = destination.appendingPathComponent(name)
            try copyItem(from: sourceURL, to: destinationURL)
        }
    }

    private func copyEverything(from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw HomeportError.homeDoesNotExist(source.path)
        }

        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        for item in contents {
            try copyItem(from: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    private func copyItem(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try trash(destination)
        }
        try fileManager.copyItem(at: source, to: destination)
    }
}
