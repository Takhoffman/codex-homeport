import Foundation

public final class HomeportStore: @unchecked Sendable {
    public static let mainHomeID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private let paths: HomeportPaths
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(paths: HomeportPaths = HomeportPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() throws -> HomeportState {
        try migrateLegacyStateIfNeeded()
        guard fileManager.fileExists(atPath: paths.stateFile.path) else {
            return HomeportState(homes: [mainHome()])
        }

        let data = try Data(contentsOf: paths.stateFile)
        var state = try decoder.decode(HomeportState.self, from: data)
        if !state.homes.contains(where: { $0.kind == .main }) {
            state.homes.insert(mainHome(), at: 0)
        }
        try mergeLegacyStateIfNeeded(into: &state)
        return state
    }

    public func save(_ state: HomeportState) throws {
        try fileManager.createDirectory(at: paths.appSupportDirectory, withIntermediateDirectories: true)
        let data = try encoder.encode(state)
        try data.write(to: paths.stateFile, options: [.atomic])
    }

    public func mainHome() -> CodexHome {
        CodexHome(
            id: Self.mainHomeID,
            name: "Main",
            slug: "main",
            kind: .main,
            homePath: paths.mainCodexHome.path,
            profilePath: paths.normalCodexProfile.path,
            sourceHomePath: nil,
            clonePreset: nil,
            isTemporary: false
        )
    }

    private func migrateLegacyStateIfNeeded() throws {
        guard !fileManager.fileExists(atPath: paths.stateFile.path),
              fileManager.fileExists(atPath: paths.legacyStateFile.path),
              paths.appSupportDirectory.path != paths.legacyAppSupportDirectory.path
        else {
            return
        }

        try fileManager.createDirectory(at: paths.appSupportDirectory.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: paths.appSupportDirectory.path) {
            try fileManager.copyItem(at: paths.legacyStateFile, to: paths.stateFile)
            return
        }
        try fileManager.moveItem(at: paths.legacyAppSupportDirectory, to: paths.appSupportDirectory)
    }

    private func mergeLegacyStateIfNeeded(into state: inout HomeportState) throws {
        guard fileManager.fileExists(atPath: paths.legacyStateFile.path),
              paths.appSupportDirectory.path != paths.legacyAppSupportDirectory.path
        else {
            return
        }

        let data = try Data(contentsOf: paths.legacyStateFile)
        let legacyState = try decoder.decode(HomeportState.self, from: data)
        var importedHomeIDs: [UUID: UUID] = [:]

        for legacyHome in legacyState.homes where legacyHome.kind != .main {
            if state.homes.contains(where: { $0.id == legacyHome.id }) {
                importedHomeIDs[legacyHome.id] = legacyHome.id
                continue
            }
            if let existingHome = state.homes.first(where: { $0.homePath == legacyHome.homePath }) {
                importedHomeIDs[legacyHome.id] = existingHome.id
                continue
            }

            var importedHome = legacyHome
            importedHome.slug = uniqueSlug(
                base: importedHome.slug,
                existing: state.homes.map(\.slug)
            )
            state.homes.append(importedHome)
            importedHomeIDs[legacyHome.id] = importedHome.id
        }

        let knownInstanceIDs = Set(state.instances.map(\.id))
        for legacyInstance in legacyState.instances where !knownInstanceIDs.contains(legacyInstance.id) {
            var importedInstance = legacyInstance
            if let importedHomeID = importedHomeIDs[legacyInstance.homeID] {
                importedInstance.homeID = importedHomeID
            }
            guard state.homes.contains(where: { $0.id == importedInstance.homeID }) else {
                continue
            }
            state.instances.append(importedInstance)
        }

        for pinnedID in legacyState.pinnedHomeIDs {
            guard let importedID = importedHomeIDs[pinnedID],
                  !state.pinnedHomeIDs.contains(importedID)
            else {
                continue
            }
            state.pinnedHomeIDs.append(importedID)
        }

        state.instances.sort { $0.launchedAt > $1.launchedAt }
    }

    private func uniqueSlug(base: String, existing: [String]) -> String {
        if !existing.contains(base) {
            return base
        }
        var index = 2
        while existing.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }
}
