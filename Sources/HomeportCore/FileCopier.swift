import Foundation

private struct CloneItem {
    var name: String
    var policy: ClonePolicy
}

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
        try createHome(destination: destination, source: source, options: .preset(preset), materialization: .copy)
    }

    public func createHome(
        destination: URL,
        source: URL?,
        options: CloneOptions,
        materialization: CloneMaterialization = .copy
    ) throws {
        try createHome(
            destination: destination,
            source: source,
            policies: ClonePolicies(options: options, materialization: materialization),
            copyEverything: options.everything && materialization == .copy
        )
    }

    public func createHome(
        destination: URL,
        source: URL?,
        policies: ClonePolicies
    ) throws {
        try createHome(destination: destination, source: source, policies: policies, copyEverything: false)
    }

    private func createHome(
        destination: URL,
        source: URL?,
        policies: ClonePolicies,
        copyEverything: Bool
    ) throws {
        if fileManager.fileExists(atPath: destination.path) {
            throw HomeportError.homeAlreadyExists(destination.path)
        }

        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        do {
            guard let source, policies != .empty else {
                return
            }

            let items = items(for: policies)
            if copyEverything {
                try materializeEverything(from: source, to: destination)
                return
            }

            if policies.options.everything {
                try materializeEverything(items: items, from: source, to: destination)
                return
            }

            try materializeExisting(items: items, from: source, to: destination)
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
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

    private func items(for policies: ClonePolicies) -> [CloneItem] {
        var items: [CloneItem] = []
        for category in CloneCategory.allCases {
            append(category.paths, policy: policies[category], canLink: category.canLink, to: &items)
        }
        return Dictionary(grouping: items, by: \.name)
            .map { name, grouped in
                grouped.contains(where: { $0.policy == .link }) ? CloneItem(name: name, policy: .link) : CloneItem(name: name, policy: .copy)
            }
            .sorted { $0.name < $1.name }
    }

    private func append(_ names: [String], policy: ClonePolicy, canLink: Bool, to items: inout [CloneItem]) {
        guard policy != .skip else {
            return
        }
        let effectivePolicy: ClonePolicy = policy == .link && canLink ? .link : .copy
        items.append(contentsOf: names.map { CloneItem(name: $0, policy: effectivePolicy) })
    }

    private func materializeExisting(items: [CloneItem], from source: URL, to destination: URL) throws {
        for item in items {
            let sourceURL = source.appendingPathComponent(item.name)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                continue
            }
            let destinationURL = destination.appendingPathComponent(item.name)
            try materializeItem(from: sourceURL, to: destinationURL, policy: item.policy)
        }
    }

    private func materializeEverything(from source: URL, to destination: URL) throws {
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

    private func materializeEverything(items: [CloneItem], from source: URL, to destination: URL) throws {
        guard fileManager.fileExists(atPath: source.path) else {
            throw HomeportError.homeDoesNotExist(source.path)
        }

        let knownNames = Set(items.map(\.name))
        try materializeExisting(items: items, from: source, to: destination)
        let contents = try fileManager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        )
        for item in contents where !knownNames.contains(item.lastPathComponent) {
            try copyItem(from: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
    }

    private func materializeItem(from source: URL, to destination: URL, policy: ClonePolicy) throws {
        if policy == .link {
            try linkItem(from: source, to: destination)
            return
        }
        try copyItem(from: source, to: destination)
    }

    private func linkItem(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try trash(destination)
        }
        try fileManager.createSymbolicLink(at: destination, withDestinationURL: resolvedOneHopSymlink(source))
    }

    private func copyItem(from source: URL, to destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            try trash(destination)
        }
        try copyRecursively(from: source, to: destination)
    }

    /// Copies directories without carrying over live filesystem objects such as
    /// Git's fsmonitor socket. Those objects are process-specific and cannot be
    /// materialized into another CODEX_HOME; regular files, directories, and
    /// symbolic links are retained.
    private func copyRecursively(from source: URL, to destination: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: source.path)
        guard let type = attributes[.type] as? FileAttributeType else {
            return
        }

        switch type {
        case .typeDirectory:
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try fileManager.contentsOfDirectory(
                at: source,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            )
            for child in children {
                try copyRecursively(from: child, to: destination.appendingPathComponent(child.lastPathComponent))
            }
        case .typeSymbolicLink:
            let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
            try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
        case .typeRegular:
            try fileManager.copyItem(at: source, to: destination)
        default:
            // Sockets, FIFOs, device files, and other process-local objects are
            // deliberately omitted from cloned homes.
            return
        }
    }

    private func resolvedOneHopSymlink(_ url: URL) throws -> URL {
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: url.path) else {
            return url
        }
        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination)
        }
        return url
            .deletingLastPathComponent()
            .appendingPathComponent(destination)
            .standardizedFileURL
    }
}
