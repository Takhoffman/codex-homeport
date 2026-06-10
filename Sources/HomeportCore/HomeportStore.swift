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
}
