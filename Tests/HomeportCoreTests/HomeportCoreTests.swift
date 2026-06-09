import XCTest
@testable import HomeportCore

final class HomeportCoreTests: XCTestCase {
    func testSlugifyProducesSafeNames() {
        XCTAssertEqual(slugify("My Clean Room!"), "my-clean-room")
        XCTAssertEqual(slugify("   "), "home")
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(shellQuote("/tmp/that's fine"), "'/tmp/that'\\''s fine'")
    }

    func testConfigOnlyCloneCopiesExpectedFiles() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        try FileCopier().createHome(destination: destination, source: source, preset: .configOnly)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session_index.jsonl").path))
    }

    func testWorkingSetupCopiesAuthButNotSessions() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        try FileCopier().createHome(destination: destination, source: source, preset: .workingSetup)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session_index.jsonl").path))
    }

    func testCustomCloneOptionsCopySelectedCategoriesOnly() throws {
        let root = try makeTempRoot()
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("skills"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("plugins"), withIntermediateDirectories: true)
        try "model = \"gpt\"".write(to: source.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try "secret".write(to: source.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        try "history".write(to: source.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let options = CloneOptions(
            config: true,
            auth: false,
            skills: true,
            plugins: true,
            agents: false,
            prompts: false,
            rules: false,
            profiles: false,
            memories: false,
            browserSupport: false,
            sessionsAndLogs: false
        )
        try FileCopier().createHome(destination: destination, source: source, options: options)

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.toml").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("skills").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("plugins").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("auth.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("session_index.jsonl").path))
    }

    func testTerminalCommandUsesPerProcessCodexHome() {
        let home = CodexHome(
            name: "Temp",
            slug: "temp",
            kind: .temporary,
            homePath: "/tmp/home port",
            profilePath: "/tmp/profile"
        )
        let command = Launcher().terminalShellCommand(home: home, workspace: "/tmp/work space")
        XCTAssertEqual(command, "cd '/tmp/work space'; CODEX_HOME='/tmp/home port' codex")
    }

    func testDiagnosticsCountsSessions() throws {
        let root = try makeTempRoot()
        let home = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "a\nb\n".write(to: home.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let diagnostics = Diagnostics(paths: HomeportPaths(homeDirectory: root))
        XCTAssertEqual(diagnostics.sessionCount(in: home), 2)
    }

    func testCannotDeleteMainHome() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))

        let state = try service.loadState()
        let main = try XCTUnwrap(state.homes.first(where: { $0.kind == .main }))

        XCTAssertThrowsError(try service.deleteHome(id: main.id))
    }

    func testRenameManagedHomeUpdatesNameAndSlug() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Old Name")

        try service.renameHome(id: home.id, name: "New Name")

        let state = try service.loadState()
        let renamed = try XCTUnwrap(state.homes.first(where: { $0.id == home.id }))
        XCTAssertEqual(renamed.name, "New Name")
        XCTAssertEqual(renamed.slug, "new-name")
    }

    func testPinningManagedHomePersists() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        let home = try service.createCleanRoom(name: "Pinned Home")

        try service.setHomePinned(id: home.id, pinned: true)
        XCTAssertEqual(try service.loadState().pinnedHomeIDs, [home.id])

        try service.setHomePinned(id: home.id, pinned: false)
        XCTAssertTrue(try service.loadState().pinnedHomeIDs.isEmpty)
    }

    func testPreferencesDecodeOlderStateWithUpdaterDefaults() throws {
        let data = """
        {
          "defaultLaunchTarget": "desktop",
          "defaultClonePreset": "working-setup",
          "cloneOptions": {
            "config": true,
            "auth": true,
            "skills": true,
            "plugins": true,
            "agents": true,
            "prompts": true,
            "rules": true,
            "profiles": true,
            "memories": true,
            "browserSupport": true,
            "sessionsAndLogs": false,
            "everything": false
          },
          "launchTemporaryByDefault": false,
          "onboardEnablesAutostart": true,
          "installAppByDefault": true
        }
        """.data(using: .utf8)!

        let preferences = try JSONDecoder().decode(HomeportPreferences.self, from: data)

        XCTAssertTrue(preferences.autoUpdateChecksEnabled)
        XCTAssertFalse(preferences.autoInstallUpdates)
        XCTAssertEqual(preferences.updateCheckInterval, .daily)
    }

    func testVersionComparisonHandlesSemverLikeStrings() {
        XCTAssertEqual(compareVersions("0.4.0", "0.3.9"), .orderedDescending)
        XCTAssertEqual(compareVersions("v0.3.0", "0.3.0"), .orderedSame)
        XCTAssertEqual(compareVersions("0.3.0", "0.3.1"), .orderedAscending)
    }

    func testUpdaterCheckScheduleUsesSavedInterval() throws {
        let root = try makeTempRoot()
        let service = HomeportService(paths: HomeportPaths(homeDirectory: root))
        var state = try service.loadState()
        let now = Date()
        state.preferences.autoUpdateChecksEnabled = true
        state.preferences.updateCheckInterval = .daily
        state.updater.lastCheckedAt = now.addingTimeInterval(-60 * 60)
        try service.saveState(state)

        XCTAssertFalse(try service.shouldCheckForUpdates(now: now))

        state.updater.lastCheckedAt = now.addingTimeInterval(-60 * 60 * 25)
        try service.saveState(state)

        XCTAssertTrue(try service.shouldCheckForUpdates(now: now))
    }

    func testUpdaterAvailabilityStopsAfterInstallStarts() {
        let available = UpdaterState(latestVersion: "9.9.9")
        XCTAssertTrue(available.updateAvailable(currentVersion: "0.3.0"))

        let installing = UpdaterState(latestVersion: "9.9.9", installStartedAt: Date())
        XCTAssertFalse(installing.updateAvailable(currentVersion: "0.3.0"))
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
