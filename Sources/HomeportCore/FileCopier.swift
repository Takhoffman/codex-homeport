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
        if fileManager.fileExists(atPath: destination.path) {
            throw HomeportError.homeAlreadyExists(destination.path)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        guard let source, preset != .empty else {
            return
        }

        switch preset {
        case .empty:
            return
        case .configOnly:
            try copyExisting(names: configOnlyNames, from: source, to: destination)
        case .workingSetup:
            try copyExisting(names: workingSetupNames, from: source, to: destination)
        case .everything:
            try copyEverything(from: source, to: destination)
        }
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
