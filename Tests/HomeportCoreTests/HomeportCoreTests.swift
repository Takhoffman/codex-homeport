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

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
