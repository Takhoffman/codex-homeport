import Foundation
import Darwin

public final class HomeportService: @unchecked Sendable {
    public let paths: HomeportPaths
    private let store: HomeportStore
    private let copier: FileCopier
    private let launcher: Launcher
    private let diagnostics: Diagnostics
    private let fileManager: FileManager

    public init(paths: HomeportPaths = HomeportPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        self.store = HomeportStore(paths: paths, fileManager: fileManager)
        self.copier = FileCopier(fileManager: fileManager)
        self.launcher = Launcher(paths: paths, fileManager: fileManager)
        self.diagnostics = Diagnostics(paths: paths, fileManager: fileManager)
    }

    public func loadState() throws -> HomeportState {
        var state = try store.load()
        reconcileInstances(in: &state)
        try store.save(state)
        return state
    }

    public func saveState(_ state: HomeportState) throws {
        try store.save(state)
    }

    public func resetPreferences() throws {
        var state = try store.load()
        state.preferences = HomeportPreferences()
        state.preferredTerminal = .terminal
        state.lastWorkspacePath = nil
        try store.save(state)
    }

    public func createCleanRoom(name: String? = nil) throws -> CodexHome {
        let slug = uniqueSlug(base: slugify(name ?? timestampSlug(prefix: "clean-room")))
        return try createManagedHome(name: name ?? "Clean Room", slug: slug, kind: .cleanRoom, preset: .empty, temporary: false)
    }

    public func createTemporary(name: String? = nil) throws -> CodexHome {
        let slug = uniqueSlug(base: slugify(name ?? timestampSlug(prefix: "temp")))
        return try createManagedHome(name: name ?? "Temporary", slug: slug, kind: .temporary, preset: .empty, temporary: true)
    }

    public func clone(name: String, preset: ClonePreset) throws -> CodexHome {
        let slug = uniqueSlug(base: slugify(name))
        return try createManagedHome(name: name, slug: slug, kind: .clone, preset: preset, temporary: false)
    }

    public func renameHome(id: UUID, name: String) throws {
        var state = try store.load()
        guard let index = state.homes.firstIndex(where: { $0.id == id }) else {
            throw HomeportError.homeDoesNotExist(id.uuidString)
        }
        guard state.homes[index].kind != .main else {
            throw HomeportError.commandFailed("The main ~/.codex home cannot be renamed.")
        }
        state.homes[index].name = name
        state.homes[index].slug = uniqueSlug(base: slugify(name), existing: state.homes.enumerated().compactMap { $0.offset == index ? nil : $0.element.slug })
        try store.save(state)
    }

    public func setHomePinned(id: UUID, pinned: Bool) throws {
        var state = try store.load()
        guard state.homes.contains(where: { $0.id == id }) else {
            throw HomeportError.homeDoesNotExist(id.uuidString)
        }
        state.pinnedHomeIDs.removeAll { $0 == id }
        if pinned {
            state.pinnedHomeIDs.insert(id, at: 0)
        }
        try store.save(state)
    }

    public func deleteHome(id: UUID) throws -> [URL] {
        var state = try store.load()
        guard let index = state.homes.firstIndex(where: { $0.id == id }) else {
            throw HomeportError.homeDoesNotExist(id.uuidString)
        }
        let home = state.homes[index]
        guard home.kind != .main else {
            throw HomeportError.commandFailed("The main ~/.codex home cannot be deleted.")
        }
        let targets = copier.cleanupTargets(for: home)
        try copier.cleanup(paths: targets)
        state.homes.remove(at: index)
        state.pinnedHomeIDs.removeAll { $0 == id }
        for instanceIndex in state.instances.indices where state.instances[instanceIndex].homeID == id {
            state.instances[instanceIndex].status = .cleaned
            state.instances[instanceIndex].cleanupReviewRequired = false
        }
        try store.save(state)
        return targets
    }

    public func launch(
        selector: String,
        target: LaunchTarget,
        workspace: String? = nil,
        terminal: TerminalApp? = nil
    ) throws -> LaunchedInstance {
        var state = try store.load()
        reconcileInstances(in: &state)
        let home: CodexHome
        if selector == "temp" || selector == "temporary" {
            home = try createTemporary()
            state = try store.load()
        } else {
            home = try resolveHome(selector: selector, in: state)
        }
        let selectedTerminal = terminal ?? state.preferredTerminal
        let pid = try launcher.launch(home: home, target: target, workspace: workspace, terminal: selectedTerminal)
        let instance = LaunchedInstance(
            homeID: home.id,
            homeName: home.name,
            homePath: home.homePath,
            profilePath: home.profilePath,
            target: target,
            pid: pid,
            workspacePath: workspace,
            terminalApp: target == .terminal ? selectedTerminal : nil,
            cleanupReviewRequired: home.isTemporary
        )
        state.instances.insert(instance, at: 0)
        state.lastWorkspacePath = workspace ?? state.lastWorkspacePath
        try store.save(state)
        return instance
    }

    public func markClosed(instanceID: UUID) throws {
        var state = try store.load()
        guard let index = state.instances.firstIndex(where: { $0.id == instanceID }) else {
            return
        }
        state.instances[index].status = .closed
        state.instances[index].closedAt = Date()
        try store.save(state)
    }

    public func cleanup(instanceID: UUID) throws -> [URL] {
        var state = try store.load()
        guard let instanceIndex = state.instances.firstIndex(where: { $0.id == instanceID }) else {
            return []
        }
        let instance = state.instances[instanceIndex]
        guard let homeIndex = state.homes.firstIndex(where: { $0.id == instance.homeID }) else {
            return []
        }
        let home = state.homes[homeIndex]
        let targets = copier.cleanupTargets(for: home)
        try copier.cleanup(paths: targets)
        state.instances[instanceIndex].status = .cleaned
        state.instances[instanceIndex].cleanupReviewRequired = false
        state.homes.remove(at: homeIndex)
        try store.save(state)
        return targets
    }

    public func promote(instanceID: UUID, name: String? = nil) throws {
        var state = try store.load()
        guard let instanceIndex = state.instances.firstIndex(where: { $0.id == instanceID }) else {
            return
        }
        let instance = state.instances[instanceIndex]
        guard let homeIndex = state.homes.firstIndex(where: { $0.id == instance.homeID }) else {
            return
        }
        if let name {
            state.homes[homeIndex].name = name
            state.homes[homeIndex].slug = uniqueSlug(base: slugify(name), existing: state.homes.map(\.slug))
        }
        state.homes[homeIndex].isTemporary = false
        state.homes[homeIndex].kind = .clone
        state.homes[homeIndex].promotedAt = Date()
        state.instances[instanceIndex].status = .promoted
        state.instances[instanceIndex].cleanupReviewRequired = false
        try store.save(state)
    }

    public func report() -> DiagnosticReport {
        diagnostics.report()
    }

    public func clearGlobalCodexHome() throws {
        try diagnostics.clearGlobalCodexHome()
    }

    private func createManagedHome(
        name: String,
        slug: String,
        kind: HomeKind,
        preset: ClonePreset,
        temporary: Bool
    ) throws -> CodexHome {
        try fileManager.createDirectory(at: paths.managedHomesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.profilesDirectory, withIntermediateDirectories: true)

        let homeURL = paths.managedHomesDirectory.appendingPathComponent(slug, isDirectory: true)
        let profileURL = paths.profilesDirectory.appendingPathComponent(slug, isDirectory: true)
        let sourceURL = preset == .empty ? nil : paths.mainCodexHome
        try copier.createHome(destination: homeURL, source: sourceURL, preset: preset)
        try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)

        let home = CodexHome(
            name: name,
            slug: slug,
            kind: kind,
            homePath: homeURL.path,
            profilePath: profileURL.path,
            sourceHomePath: sourceURL?.path,
            clonePreset: preset,
            isTemporary: temporary
        )

        var state = try store.load()
        state.homes.append(home)
        try store.save(state)
        return home
    }

    private func resolveHome(selector: String, in state: HomeportState) throws -> CodexHome {
        if selector == "main" {
            return state.homes.first(where: { $0.kind == .main }) ?? store.mainHome()
        }
        if let home = state.homes.first(where: { $0.slug == selector || $0.name == selector }) {
            return home
        }
        throw HomeportError.homeDoesNotExist(selector)
    }

    private func reconcileInstances(in state: inout HomeportState) {
        for index in state.instances.indices {
            guard
                state.instances[index].status == .running,
                let pid = state.instances[index].pid,
                !processIsRunning(pid)
            else {
                continue
            }
            state.instances[index].status = .closed
            state.instances[index].closedAt = state.instances[index].closedAt ?? Date()
        }
    }

    private func processIsRunning(_ pid: Int32) -> Bool {
        if pid <= 0 {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func uniqueSlug(base: String) -> String {
        (try? store.load().homes.map(\.slug)).map { uniqueSlug(base: base, existing: $0) } ?? base
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
