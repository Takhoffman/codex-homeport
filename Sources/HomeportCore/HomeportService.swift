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
        try clone(name: name, preset: preset, options: .preset(preset))
    }

    public func clone(name: String, preset: ClonePreset, options: CloneOptions) throws -> CodexHome {
        try clone(name: name, preset: preset, options: options, sourceSelector: "main", materialization: .copy)
    }

    public func clone(
        name: String,
        preset: ClonePreset,
        options: CloneOptions,
        sourceSelector: String,
        materialization: CloneMaterialization
    ) throws -> CodexHome {
        try clone(
            name: name,
            preset: preset,
            policies: ClonePolicies(options: options, materialization: materialization),
            sourceSelector: sourceSelector
        )
    }

    public func clone(
        name: String,
        preset: ClonePreset,
        policies: ClonePolicies,
        sourceSelector: String
    ) throws -> CodexHome {
        let slug = uniqueSlug(base: slugify(name))
        let sourceURL = preset == .empty ? nil : try cloneSourceURL(selector: sourceSelector)
        return try createManagedHome(
            name: name,
            slug: slug,
            kind: .clone,
            preset: preset,
            policies: policies,
            sourceURL: sourceURL,
            temporary: false
        )
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

    public func authStatus(for home: CodexHome, verifyWithCLI: Bool = false) -> CodexAuthStatus {
        diagnostics.authStatus(
            in: URL(fileURLWithPath: home.homePath, isDirectory: true),
            includeCLIStatus: verifyWithCLI
        )
    }

    public func brokenLinkedTargets(for home: CodexHome) -> [String] {
        let homeURL = URL(fileURLWithPath: home.homePath, isDirectory: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return contents.compactMap { item in
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: item.path) else {
                return nil
            }
            let targetURL: URL
            if target.hasPrefix("/") {
                targetURL = URL(fileURLWithPath: target)
            } else {
                targetURL = item.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL
            }
            return fileManager.fileExists(atPath: targetURL.path) ? nil : item.lastPathComponent
        }.sorted()
    }

    public func brokenLinkedTargets(selector: String) throws -> [String] {
        let state = try store.load()
        let home = try resolveHome(selector: selector, in: state)
        return brokenLinkedTargets(for: home)
    }

    public func clearGlobalCodexHome() throws {
        try diagnostics.clearGlobalCodexHome()
    }

    public func shouldCheckForUpdates(now: Date = Date()) throws -> Bool {
        let state = try store.load()
        guard state.preferences.autoUpdateChecksEnabled else {
            return false
        }
        guard let lastCheckedAt = state.updater.lastCheckedAt else {
            return true
        }
        return now.timeIntervalSince(lastCheckedAt) >= state.preferences.updateCheckInterval.seconds
    }

    public func checkForUpdates(now: Date = Date()) throws -> UpdaterState {
        let latestVersion = try latestPublishedVersion()
        var state = try store.load()
        state.updater.lastCheckedAt = now
        state.updater.latestVersion = latestVersion
        state.updater.lastError = nil
        if compareVersions(latestVersion, AppVersion.version) != .orderedDescending {
            state.updater.dismissedVersion = nil
            state.updater.installStartedAt = nil
        }
        try store.save(state)
        return state.updater
    }

    public func recordUpdateCheckError(_ error: Error, now: Date = Date()) throws {
        var state = try store.load()
        state.updater.lastCheckedAt = now
        state.updater.lastError = error.localizedDescription
        try store.save(state)
    }

    public func dismissAvailableUpdate() throws {
        var state = try store.load()
        state.updater.dismissedVersion = state.updater.latestVersion
        try store.save(state)
    }

    public func installAvailableUpdate(now: Date = Date()) throws -> URL {
        var state = try store.load()
        guard state.updater.updateAvailable() else {
            throw HomeportError.commandFailed("No Homeport update is available.")
        }
        state.updater.installStartedAt = now
        state.updater.lastError = nil
        try store.save(state)
        try launchDetachedUpdater()
        return paths.updateLogFile
    }

    private func createManagedHome(
        name: String,
        slug: String,
        kind: HomeKind,
        preset: ClonePreset,
        options: CloneOptions? = nil,
        policies explicitPolicies: ClonePolicies? = nil,
        sourceURL explicitSourceURL: URL? = nil,
        materialization: CloneMaterialization = .copy,
        temporary: Bool
    ) throws -> CodexHome {
        try fileManager.createDirectory(at: paths.managedHomesDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.profilesDirectory, withIntermediateDirectories: true)

        let homeURL = paths.managedHomesDirectory.appendingPathComponent(slug, isDirectory: true)
        let profileURL = paths.profilesDirectory.appendingPathComponent(slug, isDirectory: true)
        let sourceURL = preset == .empty ? nil : explicitSourceURL ?? paths.mainCodexHome
        let policies = explicitPolicies ?? ClonePolicies(options: options ?? .preset(preset), materialization: materialization)
        do {
            try copier.createHome(
                destination: homeURL,
                source: sourceURL,
                policies: policies
            )
            try fileManager.createDirectory(at: profileURL, withIntermediateDirectories: true)

            let home = CodexHome(
                name: name,
                slug: slug,
                kind: kind,
                homePath: homeURL.path,
                profilePath: profileURL.path,
                sourceHomePath: sourceURL?.path,
                clonePreset: preset,
                cloneMaterialization: sourceURL == nil ? nil : policies.materialization,
                clonePolicies: sourceURL == nil ? nil : policies,
                isTemporary: temporary
            )

            var state = try store.load()
            state.homes.append(home)
            try store.save(state)
            return home
        } catch {
            try? fileManager.removeItem(at: homeURL)
            try? fileManager.removeItem(at: profileURL)
            throw error
        }
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

    private func cloneSourceURL(selector: String) throws -> URL {
        if selector == "main" {
            return paths.mainCodexHome
        }
        let state = try store.load()
        guard let home = state.homes.first(where: { $0.slug == selector || $0.name == selector }) else {
            throw HomeportError.homeDoesNotExist(selector)
        }
        return URL(fileURLWithPath: home.homePath, isDirectory: true)
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

    private func latestPublishedVersion() throws -> String {
        let output = try runProcessCapturingOutput(
            "zsh",
            [
                "-lc",
                "export PATH=\"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH\"; npm view codex-homeport version --silent"
            ],
            timeout: 30
        )
        let version = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw HomeportError.commandFailed("npm did not return a codex-homeport version.")
        }
        return version
    }

    private func runProcessCapturingOutput(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> String {
        let process = Process()
        let output = Pipe()
        let errorOutput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.standardOutput = output
        process.standardError = errorOutput
        try process.run()

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw HomeportError.commandFailed("\(executable) timed out after \(Int(timeout)) seconds")
        }

        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorOutput.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw HomeportError.commandFailed(message?.isEmpty == false ? message! : "\(executable) exited with \(process.terminationStatus)")
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }

    private func launchDetachedUpdater() throws {
        try fileManager.createDirectory(at: paths.appSupportDirectory, withIntermediateDirectories: true)
        let command = """
        set -e
        export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
        npm install -g codex-homeport@latest
        package_root="$(npm root -g)/codex-homeport"
        test -f "$package_root/Package.swift"
        homeport update --with-app --no-restart --repo "$package_root" --channel \(paths.channel.rawValue)
        """
        let shellCommand = "nohup /bin/zsh -lc \(shellQuote(command)) >> \(shellQuote(paths.updateLogFile.path)) 2>&1 &"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", shellCommand]
        try process.run()
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
