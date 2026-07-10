import Foundation
import SwiftUI
import HomeportCore

@main
struct CodexMultihomeApp: App {
    @StateObject private var model = HomeportModel()

    var body: some Scene {
        MenuBarExtra {
            HomeportMenuView()
                .environmentObject(model)
                .frame(width: 390)
        } label: {
            MenuBarBadgeIcon(title: model.channel.appName, symbol: model.menuIcon, isDev: model.channel == .dev, showsBadge: model.updateAvailable)
        }
        .menuBarExtraStyle(.window)

        Window("Multihome Console", id: "console") {
            HomeportConsoleView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }

        .commands {
            CommandGroup(replacing: .appTermination) {
                Button("Quit Multihome") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            }
        }
    }
}

struct MenuBarBadgeIcon: View {
    var title: String
    var symbol: String
    var isDev: Bool = false
    var showsBadge: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .overlay(alignment: .topTrailing) {
                    if showsBadge {
                        Circle()
                            .fill(.red)
                            .frame(width: 6, height: 6)
                            .offset(x: 3, y: -3)
                    }
                }
            if isDev {
                Text("DEV")
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(.purple)
            }
        }
        .help(showsBadge ? "\(title) update available" : title)
    }
}

@MainActor
final class HomeportModel: ObservableObject {
    @Published var state = HomeportState()
    @Published var report = DiagnosticReport(globalCodexHome: nil, mainSessionCount: 0, suspiciousLaunchers: [], codexBinaryPath: nil, codexAppExists: false, authStatus: CodexAuthStatus(), notes: [])
    @Published var authStatuses: [UUID: CodexAuthStatus] = [:]
    @Published var brokenLinkedTargets: [UUID: [String]] = [:]
    @Published var status = "Ready"
    @Published var workspacePath = FileManager.default.currentDirectoryPath
    @Published var isCheckingForUpdates = false
    @Published var isInstallingUpdate = false
    @Published var isRunningShimCommand = false
    private var shimOperationCount = 0
    @Published var shimStatus = "Ready"
    @Published var shimProviderStatuses: [ShimLoginProvider: ShimProviderStatus] = [:]
    @Published var shimAppBundleStatus = ShimAppBundleStatus.checking
    @Published var allowForbiddenComputerUseTargets: Bool?

    let service: HomeportService
    private var updateMonitorTask: Task<Void, Never>?
    private var developmentLaunchSaveTask: Task<Void, Never>?
    private var healthRefreshTask: Task<Void, Never>?
    private var healthRefreshGeneration = 0

    var channel: HomeportChannel {
        service.paths.channel
    }

    var menuIcon: String {
        report.globalCodexHome == nil && report.suspiciousLaunchers.isEmpty ? "sailboat" : "exclamationmark.triangle"
    }

    var updateAvailable: Bool {
        state.updater.updateAvailable()
    }

    var pinnedHomes: [CodexHome] {
        state.pinnedHomeIDs.compactMap { id in
            state.homes.first { $0.id == id }
        }
    }

    var activeInstances: [LaunchedInstance] {
        state.instances.filter { $0.status == .running }
    }

    var recentInstances: [LaunchedInstance] {
        Array(state.instances.filter { $0.status != .running }.prefix(6))
    }

    init() {
        self.service = HomeportService()
        refresh()
        startUpdateMonitor()
    }

    func refresh(statusMessage: String? = nil) {
        do {
            var loadedState = try service.loadState()
            if !isValidCloneSourceSelector(loadedState.preferences.cloneSourceSelector, in: loadedState) {
                loadedState.preferences.cloneSourceSelector = "main"
                try service.saveState(loadedState)
            }
            state = loadedState
            allowForbiddenComputerUseTargets = ComputerUseDefaults.readAllowForbiddenTargets()
            workspacePath = state.lastWorkspacePath ?? workspacePath
            status = statusMessage ?? "Ready"
            scheduleHealthRefresh(for: loadedState.homes)
        } catch {
            status = error.localizedDescription
        }
    }

    private func scheduleHealthRefresh(for homes: [CodexHome]) {
        healthRefreshGeneration += 1
        let generation = healthRefreshGeneration
        healthRefreshTask?.cancel()
        let service = service
        healthRefreshTask = Task { [weak self] in
            let result = await Task.detached {
                let report = service.report()
                var statuses = Dictionary(uniqueKeysWithValues: homes.map { home in
                    (home.id, service.authStatus(for: home))
                })
                let brokenLinks = Dictionary(uniqueKeysWithValues: homes.map { home in
                    (home.id, service.brokenLinkedTargets(for: home))
                })
                if let mainHome = homes.first(where: { $0.kind == .main }) {
                    statuses[mainHome.id] = report.authStatus
                }
                return (report, statuses, brokenLinks)
            }.value
            guard !Task.isCancelled, let self, generation == self.healthRefreshGeneration else { return }
            self.report = result.0
            self.authStatuses = result.1
            self.brokenLinkedTargets = result.2
        }
    }

    private func isValidCloneSourceSelector(_ selector: String, in state: HomeportState) -> Bool {
        selector == "main" || state.homes.contains { $0.kind != .main && ($0.slug == selector || $0.name == selector) }
    }

    func authStatus(for home: CodexHome) -> CodexAuthStatus {
        authStatuses[home.id] ?? CodexAuthStatus()
    }

    func authSummary(for home: CodexHome) -> String {
        let status = authStatus(for: home)
        if status.isLoggedIn {
            return [status.modeDisplay, status.accountLabel, status.usageSummary]
                .compactMap { $0 }
                .joined(separator: " • ")
        }
        if status.hasStoredCredentials {
            return [status.modeDisplay, status.accountLabel, "Stored credentials found"]
                .compactMap { $0 }
                .joined(separator: " • ")
        }
        return status.detail ?? "No stored auth in this home"
    }

    /// Returns true when the launch was started. For routing-enabled homes the launch
    /// continues asynchronously (catalog publish, shim wiring) and later failures are
    /// reported through `status`/`shimStatus`, not this return value.
    @discardableResult
    func launch(_ selector: String, target: LaunchTarget) -> Bool {
        let actualSelector = modelSelector(for: selector)
        if let home = resolveHome(selector: actualSelector), routingEnabled(for: home) {
            launchWithRouting(home: home, target: target)
            return true
        }
        return performLaunch(actualSelector, target: target)
    }

    @discardableResult
    func performLaunch(_ selector: String, target: LaunchTarget, appBundle: URL? = nil) -> Bool {
        do {
            let actualSelector = modelSelector(for: selector)
            let missingLinks = try service.brokenLinkedTargets(selector: actualSelector)
            let instance = try service.launch(selector: actualSelector, target: target, workspace: workspacePath, appBundle: appBundle)
            let warning = missingLinks.isEmpty ? "" : "; linked paths missing: \(missingLinks.joined(separator: ", "))"
            refresh(statusMessage: "Opened \(instance.homeName) in \(target.rawValue)\(warning)")
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    private func resolveHome(selector: String) -> CodexHome? {
        if selector == "main" {
            return state.homes.first { $0.kind == .main }
        }
        if selector == "temp" || selector == "temporary" {
            return nil
        }
        return state.homes.first { $0.slug == selector || $0.name == selector }
    }

    func launchPreferred() {
        let selector = state.preferences.launchTemporaryByDefault ? "temp" : "main"
        launch(selector, target: state.preferences.defaultLaunchTarget)
    }

    func launchRecent(_ instance: LaunchedInstance) {
        let selector = state.homes.first(where: { $0.id == instance.homeID })?.slug ?? instance.homeName
        launch(selector, target: instance.target)
    }

    func launchRecent(_ instance: LaunchedInstance, target: LaunchTarget) {
        let selector = state.homes.first(where: { $0.id == instance.homeID })?.slug ?? instance.homeName
        launch(selector, target: target)
    }

    @discardableResult
    func cloneWorkingSetup(name: String? = nil, homePath: String? = nil) -> CodexHome? {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            let home = try service.clone(
                name: name ?? "Working Setup \(formatter.string(from: Date()))",
                preset: state.preferences.defaultClonePreset,
                policies: state.preferences.clonePolicies,
                sourceSelector: state.preferences.cloneSourceSelector,
                homePath: normalizedOptionalPath(homePath)
            )
            refresh(statusMessage: "Created \(home.name): \(home.clonePolicies?.summary ?? state.preferences.clonePolicies.summary)")
            return home
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func cloneConfigOnly(name: String? = nil, homePath: String? = nil) -> CodexHome? {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            let home = try service.clone(
                name: name ?? "Config Copy \(formatter.string(from: Date()))",
                preset: .configOnly,
                policies: .configOnly,
                sourceSelector: state.preferences.cloneSourceSelector,
                homePath: normalizedOptionalPath(homePath)
            )
            refresh(statusMessage: "Created \(home.name)")
            return home
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func cleanRoom(name: String? = nil, homePath: String? = nil) -> CodexHome? {
        do {
            let home = try service.createCleanRoom(name: name, homePath: normalizedOptionalPath(homePath))
            refresh(statusMessage: "Created \(home.name)")
            return home
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createTemporaryHome(
        name: String? = nil,
        homePath: String? = nil,
        policies: ClonePolicies? = nil,
        sourceSelector: String = "main",
        preset: ClonePreset = .workingSetup
    ) -> CodexHome? {
        do {
            let home = try service.createTemporary(
                name: name,
                homePath: normalizedOptionalPath(homePath),
                policies: policies,
                sourceSelector: sourceSelector,
                preset: preset
            )
            refresh(statusMessage: "Created \(home.name)")
            return home
        } catch {
            status = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func renameHome(_ home: CodexHome, name: String, moveFolders: Bool = false) -> Bool {
        do {
            try service.renameHome(id: home.id, name: name, moveFolders: moveFolders)
            refresh(statusMessage: "Renamed to \(name.trimmingCharacters(in: .whitespacesAndNewlines))")
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func changeHomePath(_ home: CodexHome, homePath: String, moveExisting: Bool = false) -> Bool {
        do {
            try service.changeHomePath(id: home.id, homePath: homePath, moveExisting: moveExisting)
            refresh(statusMessage: "Updated path for \(home.name)")
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func deleteHome(_ home: CodexHome) -> Bool {
        do {
            _ = try service.deleteHome(id: home.id)
            refresh(statusMessage: "Moved \(home.name) to Trash")
            return true
        } catch {
            status = error.localizedDescription
            return false
        }
    }

    func setHomePinned(_ home: CodexHome, pinned: Bool) {
        do {
            try service.setHomePinned(id: home.id, pinned: pinned)
            refresh(statusMessage: pinned ? "Pinned \(home.name)" : "Unpinned \(home.name)")
        } catch {
            status = error.localizedDescription
        }
    }

    func isPinned(_ home: CodexHome) -> Bool {
        state.pinnedHomeIDs.contains(home.id)
    }

    func cleanup(_ instance: LaunchedInstance) {
        do {
            _ = try service.cleanup(instanceID: instance.id)
            refresh(statusMessage: "Cleaned \(instance.homeName)")
        } catch {
            status = error.localizedDescription
        }
    }

    func promote(_ instance: LaunchedInstance) {
        do {
            try service.promote(instanceID: instance.id)
            refresh(statusMessage: "Promoted \(instance.homeName)")
        } catch {
            status = error.localizedDescription
        }
    }

    func repair() {
        do {
            try service.clearGlobalCodexHome()
            refresh(statusMessage: "Cleared GUI CODEX_HOME")
        } catch {
            status = error.localizedDescription
        }
    }

    func setDefaultLaunchTarget(_ target: LaunchTarget) {
        do {
            var next = try service.loadState()
            next.preferences.defaultLaunchTarget = target
            try service.saveState(next)
            refresh(statusMessage: "Saved default launch")
        } catch {
            status = error.localizedDescription
        }
    }

    func setDefaultClonePreset(_ preset: ClonePreset) {
        do {
            var next = try service.loadState()
            let policies = ClonePolicies.preset(preset)
            rememberCurrentClonePolicies(in: &next, beforeSetting: policies)
            next.preferences.defaultClonePreset = preset
            next.preferences.cloneOptions = .preset(preset)
            next.preferences.cloneMaterialization = .copy
            next.preferences.clonePolicies = policies
            try service.saveState(next)
            refresh(statusMessage: "Saved copy preset")
        } catch {
            status = error.localizedDescription
        }
    }

    func setLaunchTemporaryByDefault(_ value: Bool) {
        do {
            var next = try service.loadState()
            next.preferences.launchTemporaryByDefault = value
            try service.saveState(next)
            refresh(statusMessage: "Saved default home")
        } catch {
            status = error.localizedDescription
        }
    }

    func setAllowForbiddenComputerUseTargets(_ value: Bool) {
        do {
            var next = try service.loadState()
            next.preferences.allowForbiddenComputerUseTargetsByDefault = value
            try service.saveState(next)
            try ComputerUseDefaults.setAllowForbiddenTargets(value)
            try ComputerUseDefaults.applyInstallSupport(in: service.paths.mainCodexHome, isEnabled: value)
            refresh(statusMessage: value ? "Enabled Computer Use target access" : "Disabled Computer Use target access")
        } catch {
            status = error.localizedDescription
        }
    }

    func setBrowserUseLocalTestingMode(_ value: Bool) {
        var next = state
        next.preferences.browserUseLocalTestingMode = value
        state = next
        scheduleDevelopmentLaunchSave()
    }

    func setDesktopAppDevFlavor(_ value: Bool) {
        var next = state
        next.preferences.desktopAppDevFlavor = value
        state = next
        scheduleDevelopmentLaunchSave()
    }

    private func scheduleDevelopmentLaunchSave() {
        developmentLaunchSaveTask?.cancel()
        let browserMode = state.preferences.browserUseLocalTestingMode
        let appDevFlavor = state.preferences.desktopAppDevFlavor
        let service = service
        developmentLaunchSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            let errorMessage = await Task.detached {
                do {
                    try service.setDevelopmentLaunchPreferences(
                        browserUseLocalTestingMode: browserMode,
                        desktopAppDevFlavor: appDevFlavor
                    )
                    return nil as String?
                } catch {
                    return error.localizedDescription
                }
            }.value
            guard !Task.isCancelled, let self else { return }
            if let errorMessage {
                self.status = errorMessage
            }
        }
    }

    func setAutoUpdateChecksEnabled(_ value: Bool) {
        do {
            var next = try service.loadState()
            next.preferences.autoUpdateChecksEnabled = value
            if !value {
                next.preferences.autoInstallUpdates = false
            }
            try service.saveState(next)
            refresh(statusMessage: value ? "Enabled update checks" : "Disabled update checks")
        } catch {
            status = error.localizedDescription
        }
    }

    func setAutoInstallUpdates(_ value: Bool) {
        do {
            var next = try service.loadState()
            next.preferences.autoInstallUpdates = value
            if value {
                next.preferences.autoUpdateChecksEnabled = true
            }
            try service.saveState(next)
            refresh(statusMessage: value ? "Enabled automatic installs" : "Disabled automatic installs")
        } catch {
            status = error.localizedDescription
        }
    }

    func setUpdateCheckInterval(_ interval: UpdateCheckInterval) {
        do {
            var next = try service.loadState()
            next.preferences.updateCheckInterval = interval
            try service.saveState(next)
            refresh(statusMessage: "Saved update schedule")
        } catch {
            status = error.localizedDescription
        }
    }

    func checkForUpdates(force: Bool = true) {
        Task {
            await checkForUpdatesIfNeeded(force: force)
        }
    }

    func installUpdate() {
        guard updateAvailable else {
            status = "No Multihome update is available"
            return
        }
        isInstallingUpdate = true
        do {
            let logFile = try service.installAvailableUpdate()
            refresh(statusMessage: "Installing update in background; log: \(logFile.path)")
        } catch {
            status = error.localizedDescription
        }
        isInstallingUpdate = false
    }

    func dismissUpdate() {
        do {
            try service.dismissAvailableUpdate()
            refresh(statusMessage: "Update hidden until the next version")
        } catch {
            status = error.localizedDescription
        }
    }

    func startUpdateMonitor() {
        guard updateMonitorTask == nil else {
            return
        }
        updateMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkForUpdatesIfNeeded(force: false)
                try? await Task.sleep(nanoseconds: 60 * 60 * 1_000_000_000)
            }
        }
    }

    private func checkForUpdatesIfNeeded(force: Bool) async {
        guard state.preferences.autoUpdateChecksEnabled || force else {
            return
        }
        do {
            let shouldCheck = force ? true : try service.shouldCheckForUpdates()
            guard shouldCheck else {
                return
            }
        } catch {
            status = error.localizedDescription
            return
        }

        isCheckingForUpdates = true
        if force {
            status = "Checking for Multihome updates"
        }
        let service = service
        let result = await Task.detached {
            Result { try service.checkForUpdates() }
        }.value

        switch result {
        case .success(let updater):
            let hasUpdate = updater.updateAvailable()
            refresh(statusMessage: hasUpdate ? "Multihome \(updater.latestVersion ?? "") is available" : "Multihome is up to date")
            if hasUpdate && state.preferences.autoInstallUpdates {
                installUpdate()
            }
        case .failure(let error):
            try? service.recordUpdateCheckError(error)
            refresh(statusMessage: error.localizedDescription)
        }
        isCheckingForUpdates = false
    }

    func updateCloneOptions(_ transform: (inout CloneOptions) -> Void) {
        do {
            var next = try service.loadState()
            transform(&next.preferences.cloneOptions)
            next.preferences.defaultClonePreset = clonePreset(for: next.preferences.cloneOptions)
            next.preferences.clonePolicies = ClonePolicies(
                options: next.preferences.cloneOptions,
                materialization: next.preferences.cloneMaterialization
            )
            try service.saveState(next)
            refresh(statusMessage: "Saved copy options")
        } catch {
            status = error.localizedDescription
        }
    }

    func setCloneSourceSelector(_ selector: String) {
        do {
            var next = try service.loadState()
            next.preferences.cloneSourceSelector = selector
            try service.saveState(next)
            refresh(statusMessage: "Saved clone source")
        } catch {
            status = error.localizedDescription
        }
    }

    func setCloneMaterialization(_ materialization: CloneMaterialization) {
        do {
            var next = try service.loadState()
            next.preferences.cloneMaterialization = materialization
            next.preferences.clonePolicies = ClonePolicies(options: next.preferences.cloneOptions, materialization: materialization)
            try service.saveState(next)
            refresh(statusMessage: "Saved clone mode")
        } catch {
            status = error.localizedDescription
        }
    }

    func updateClonePolicies(_ transform: (inout ClonePolicies) -> Void) {
        do {
            var next = try service.loadState()
            transform(&next.preferences.clonePolicies)
            next.preferences.cloneOptions = next.preferences.clonePolicies.options
            next.preferences.cloneMaterialization = next.preferences.clonePolicies.materialization
            next.preferences.defaultClonePreset = clonePreset(for: next.preferences.cloneOptions)
            next.preferences.lastClonePolicies = next.preferences.clonePolicies
            try service.saveState(next)
            refresh(statusMessage: "Saved clone policies")
        } catch {
            status = error.localizedDescription
        }
    }

    func applyClonePolicies(_ policies: ClonePolicies, statusMessage: String = "Saved clone preset") {
        do {
            var next = try service.loadState()
            rememberCurrentClonePolicies(in: &next, beforeSetting: policies)
            next.preferences.clonePolicies = policies
            next.preferences.cloneOptions = policies.options
            next.preferences.cloneMaterialization = policies.materialization
            next.preferences.defaultClonePreset = clonePreset(for: policies.options)
            try service.saveState(next)
            refresh(statusMessage: statusMessage)
        } catch {
            status = error.localizedDescription
        }
    }

    func resetDefaults() {
        do {
            try service.resetPreferences()
            refresh(statusMessage: "Reset preferences")
        } catch {
            status = error.localizedDescription
        }
    }

    // Shim operations can overlap (e.g. a routed launch while a status check runs);
    // a counter keeps isRunningShimCommand true until the last one finishes.
    private func beginShimOperation() {
        shimOperationCount += 1
        isRunningShimCommand = true
    }

    private func endShimOperation() {
        shimOperationCount = max(0, shimOperationCount - 1)
        isRunningShimCommand = shimOperationCount > 0
    }

    func runShim(_ command: CodexShimCommand, home: CodexHome, executablePath: String, settingsPath: String, port: String) {
        let resolvedExecutable = resolveShimExecutable(executablePath)
        var arguments = shimBaseArguments(home: home, settingsPath: settingsPath, port: port)
        arguments.append(command.rawValue)

        beginShimOperation()
        shimStatus = "Running \(command.title) for \(home.name)"
        let commandArguments = arguments
        let commandEnvironment = ProcessInfo.processInfo.environment
        Task {
            let result = await Task.detached { [resolvedExecutable, commandArguments, commandEnvironment] in
                runCommand(executable: resolvedExecutable, arguments: commandArguments, environment: commandEnvironment)
            }.value
            await MainActor.run {
                endShimOperation()
                shimStatus = result.summary(successMessage: "\(command.title) finished")
                refresh(statusMessage: result.succeeded ? "\(command.title) finished for \(home.name)" : result.summary(successMessage: ""))
                refreshShimProviderStatuses(home: home)
            }
        }
    }

    func startAndWireShim(home: CodexHome, executablePath: String, settingsPath: String, port: String, defaultModelSlug: String?, commandEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolvedExecutable = resolveShimExecutable(executablePath)
        let baseArguments = shimBaseArguments(home: home, settingsPath: settingsPath, port: port)

        beginShimOperation()
        shimStatus = "Starting shim for \(home.name)"
        Task {
            let result = await Task.detached { [resolvedExecutable, baseArguments, commandEnvironment] in
                runShimStartWireSequence(
                    executable: resolvedExecutable,
                    baseArguments: baseArguments,
                    defaultModelSlug: defaultModelSlug,
                    environment: commandEnvironment
                )
            }.value
            await MainActor.run {
                endShimOperation()
                shimStatus = result.summary(successMessage: "Shim is wired for \(home.name)")
                refresh(statusMessage: result.succeeded ? "Shim is wired for \(home.name)" : result.summary(successMessage: ""))
                refreshShimProviderStatuses(home: home)
            }
        }
    }

    func launchCodexWithShim(home: CodexHome, target: LaunchTarget, executablePath: String, settingsPath: String, port: String, defaultModelSlug: String?, commandEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolvedExecutable = resolveShimExecutable(executablePath)
        let baseArguments = shimBaseArguments(home: home, settingsPath: settingsPath, port: port)

        beginShimOperation()
        shimStatus = "Starting model shim for \(home.name)"
        status = shimStatus
        Task {
            let result = await Task.detached { [resolvedExecutable, baseArguments, commandEnvironment] in
                runShimStartWireSequence(
                    executable: resolvedExecutable,
                    baseArguments: baseArguments,
                    defaultModelSlug: defaultModelSlug,
                    environment: commandEnvironment
                )
            }.value
            await MainActor.run {
                if result.succeeded {
                    if target == .desktop {
                        shimStatus = "Building Codex Shim app if needed"
                    } else {
                        shimStatus = "Opening \(home.name) in Terminal with shim"
                    }
                    status = shimStatus
                } else {
                    endShimOperation()
                    shimStatus = result.summary(successMessage: "")
                    refresh(statusMessage: shimStatus)
                    refreshShimProviderStatuses(home: home)
                }
            }
            guard result.succeeded else { return }
            let appBundle: URL?
            if target == .desktop {
                let prepare = await Task.detached { [resolvedExecutable, baseArguments, commandEnvironment] in
                    runCommand(
                        executable: resolvedExecutable,
                        arguments: baseArguments + ["prepare-app"],
                        environment: commandEnvironment
                    )
                }.value
                guard prepare.succeeded else {
                    await MainActor.run {
                        endShimOperation()
                        shimStatus = prepare.summary(successMessage: "")
                        refresh(statusMessage: shimStatus)
                        refreshShimProviderStatuses(home: home)
                    }
                    return
                }
                appBundle = defaultShimmableCodexAppBundleURL()
                await MainActor.run {
                    shimStatus = "Verifying Codex Shim app"
                    status = shimStatus
                }
                let appStatus = await Task.detached { [resolvedExecutable, commandEnvironment] in
                    runCommand(executable: resolvedExecutable, arguments: ["app-status", "--json"], environment: commandEnvironment)
                }.value
                await MainActor.run {
                    if appStatus.succeeded,
                       let data = appStatus.output.data(using: .utf8),
                       let status = ShimAppBundleStatus(data: data) {
                        shimAppBundleStatus = status
                    }
                }
            } else {
                appBundle = nil
            }
            await MainActor.run {
                endShimOperation()
                if result.succeeded {
                    shimStatus = target == .desktop
                        ? "Opening \(home.name) in Codex Shim"
                        : "Opening \(home.name) in Terminal with shim"
                    status = shimStatus
                    let launched = performLaunch(home.slug, target: target, appBundle: appBundle)
                    shimStatus = launched
                        ? "Opened \(home.name) in \(target.rawValue) with shim"
                        : "Shim started, but launching \(home.name) failed: \(status)"
                    if launched {
                        status = "Opened \(home.name) in \(target.rawValue) with shim"
                    }
                }
                refreshShimProviderStatuses(home: home)
            }
        }
    }

    func startShimAndOpenPicker(home: CodexHome, executablePath: String, settingsPath: String, port: String, defaultModelSlug: String?, commandEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        let resolvedExecutable = resolveShimExecutable(executablePath)
        let baseArguments = shimBaseArguments(home: home, settingsPath: settingsPath, port: port)

        beginShimOperation()
        shimStatus = "Starting shim before opening picker for \(home.name)"
        Task {
            let result = await Task.detached { [resolvedExecutable, baseArguments, commandEnvironment] in
                runShimStartWireSequence(
                    executable: resolvedExecutable,
                    baseArguments: baseArguments,
                    defaultModelSlug: defaultModelSlug,
                    environment: commandEnvironment
                )
            }.value
            await MainActor.run {
                endShimOperation()
                if result.succeeded {
                    openShimPicker(port: port)
                    refresh(statusMessage: "Shim picker opened for \(home.name)")
                } else {
                    shimStatus = result.summary(successMessage: "")
                    refresh(statusMessage: shimStatus)
                }
                refreshShimProviderStatuses(home: home)
            }
        }
    }

    // MARK: - Per-home model routing

    func modelRouting(for home: CodexHome) -> ModelRoutingConfig? {
        state.homes.first { $0.id == home.id }?.modelRouting
    }

    func routingEnabled(for home: CodexHome) -> Bool {
        modelRouting(for: home)?.isEnabled == true
    }

    func routingProviders(for home: CodexHome) -> Set<ShimLoginProvider> {
        guard let routing = modelRouting(for: home) else {
            return ShimLoginProvider.defaultEnabledSet
        }
        return Set(routing.providers.compactMap(ShimLoginProvider.init(rawValue:)))
    }

    func setRoutingEnabled(_ enabled: Bool, for home: CodexHome) {
        var routing = modelRouting(for: home) ?? ModelRoutingConfig(
            providers: ShimLoginProvider.defaultEnabledSet.map(\.rawValue)
        )
        routing.isEnabled = enabled
        saveModelRouting(routing, for: home, statusMessage: enabled ? "Model routing on for \(home.name)" : "Model routing off for \(home.name)")
        if enabled {
            withRoutingCatalog(for: home) { _, _ in }
            refreshShimProviderStatuses(home: home)
        } else {
            runShim(.disable, home: home, executablePath: state.preferences.shimExecutablePath, settingsPath: "", port: state.preferences.shimPort)
        }
    }

    func setRoutingProvider(_ provider: ShimLoginProvider, enabled: Bool, for home: CodexHome) {
        guard var routing = modelRouting(for: home) else {
            return
        }
        var providers = Set(routing.providers.compactMap(ShimLoginProvider.init(rawValue:)))
        if enabled {
            providers.insert(provider)
        } else {
            providers.remove(provider)
        }
        routing.providers = ShimLoginProvider.allCases.filter(providers.contains).map(\.rawValue)
        saveModelRouting(routing, for: home, statusMessage: nil)
    }

    private func saveModelRouting(_ routing: ModelRoutingConfig, for home: CodexHome, statusMessage: String?) {
        do {
            try service.setModelRouting(id: home.id, routing: routing)
            refresh(statusMessage: statusMessage)
        } catch {
            status = error.localizedDescription
        }
    }

    func launchWithRouting(home: CodexHome, target: LaunchTarget) {
        withRoutingCatalog(for: home) { [weak self] catalog, providers in
            guard let self else { return }
            self.launchCodexWithShim(
                home: home,
                target: target,
                executablePath: self.state.preferences.shimExecutablePath,
                settingsPath: catalog.path,
                port: self.state.preferences.shimPort,
                defaultModelSlug: catalog.defaultModelSlug,
                commandEnvironment: shimCommandEnvironment(enabledProviders: providers)
            )
        }
    }

    func restartRouting(for home: CodexHome) {
        withRoutingCatalog(for: home) { [weak self] catalog, providers in
            guard let self else { return }
            self.startAndWireShim(
                home: home,
                executablePath: self.state.preferences.shimExecutablePath,
                settingsPath: catalog.path,
                port: self.state.preferences.shimPort,
                defaultModelSlug: catalog.defaultModelSlug,
                commandEnvironment: shimCommandEnvironment(enabledProviders: providers)
            )
        }
    }

    func openRoutingPicker(for home: CodexHome) {
        withRoutingCatalog(for: home) { [weak self] catalog, providers in
            guard let self else { return }
            self.startShimAndOpenPicker(
                home: home,
                executablePath: self.state.preferences.shimExecutablePath,
                settingsPath: catalog.path,
                port: self.state.preferences.shimPort,
                defaultModelSlug: catalog.defaultModelSlug,
                commandEnvironment: shimCommandEnvironment(enabledProviders: providers)
            )
        }
    }

    func checkRoutingStatus(for home: CodexHome) {
        runShim(.status, home: home, executablePath: state.preferences.shimExecutablePath, settingsPath: "", port: state.preferences.shimPort)
    }

    /// Builds the provider catalog off the main thread (it shells out to `ollama list`),
    /// then hands the written catalog back on the main actor. If the per-home config
    /// changed while building, the catalog is rebuilt with the fresh settings.
    private func withRoutingCatalog(for home: CodexHome, attempt: Int = 0, then continuation: @escaping ((path: String, defaultModelSlug: String?), Set<ShimLoginProvider>) -> Void) {
        let providers = routingProviders(for: home)
        guard !providers.isEmpty else {
            shimStatus = "Enable at least one provider for \(home.name)"
            status = shimStatus
            return
        }
        beginShimOperation()
        shimStatus = "Publishing model catalog for \(home.name)"
        Task {
            let result = await Task.detached { [home, providers] in
                Result {
                    try buildAndWriteShimCatalog(
                        home: home,
                        enabledProviders: providers,
                        environment: ProcessInfo.processInfo.environment
                    )
                }
            }.value
            await MainActor.run {
                endShimOperation()
                let configChanged = routingProviders(for: home) != providers
                if configChanged, attempt < 3 {
                    withRoutingCatalog(for: home, attempt: attempt + 1, then: continuation)
                    return
                }
                switch result {
                case .success(let catalog):
                    let included = catalog.included.isEmpty ? "no providers" : catalog.included.joined(separator: ", ")
                    shimStatus = "Published \(included) for \(home.name)"
                    continuation((catalog.path, catalog.defaultModelSlug), providers)
                case .failure(let error):
                    shimStatus = "Catalog failed: \(error.localizedDescription)"
                    status = shimStatus
                }
            }
        }
    }

    func setShimExecutablePath(_ path: String) {
        do {
            var next = try service.loadState()
            next.preferences.shimExecutablePath = path.trimmingCharacters(in: .whitespacesAndNewlines)
            try service.saveState(next)
            refresh(statusMessage: "Saved shim executable path")
        } catch {
            status = error.localizedDescription
        }
    }

    func setShimPort(_ port: String) {
        do {
            var next = try service.loadState()
            let trimmed = port.trimmingCharacters(in: .whitespacesAndNewlines)
            next.preferences.shimPort = trimmed.isEmpty ? "8765" : trimmed
            try service.saveState(next)
            refresh(statusMessage: "Saved shim port")
        } catch {
            status = error.localizedDescription
        }
    }

    private func shimBaseArguments(home: CodexHome, settingsPath: String, port: String) -> [String] {
        let trimmedSettings = settingsPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        var arguments: [String] = []
        if !trimmedSettings.isEmpty {
            arguments += ["--settings", expandUserPath(trimmedSettings)]
        }
        arguments += ["--codex-home", home.homePath]
        if !trimmedPort.isEmpty {
            arguments += ["--port", trimmedPort]
        }
        return arguments
    }

    func loginWithProviderCLI(_ provider: ShimLoginProvider, home: CodexHome? = nil) {
        let command = provider.shellCommand(home: home)
        let script = Launcher().terminalAppleScript(command: command, terminal: state.preferredTerminal)
        let environment = ProcessInfo.processInfo.environment
        shimStatus = "Opening \(provider.title) login"
        Task {
            let result = await Task.detached {
                runCommand(executable: "/usr/bin/osascript", arguments: ["-e", script], environment: environment)
            }.value
            if result.succeeded {
                shimStatus = "Opened \(provider.title) login"
                status = "Opened \(provider.title) login"
                refreshShimProviderStatuses(home: home)
            } else {
                shimStatus = result.summary(successMessage: "")
                status = shimStatus
            }
        }
    }

    func refreshShimProviderStatuses(home: CodexHome?) {
        let selectedHome = home
        let codexStatus = selectedHome.map { codexProviderStatus(for: $0) }
            ?? ShimProviderStatus(state: .unknown, detail: "Choose a home first")
        shimProviderStatuses[.codex] = codexStatus

        let environment = ProcessInfo.processInfo.environment
        Task {
            let statuses = await Task.detached { [environment] in
                [
                    ShimLoginProvider.ollama: ollamaProviderStatus(environment: environment),
                    ShimLoginProvider.cursor: cursorProviderStatus(environment: environment)
                ]
            }.value
            await MainActor.run {
                for (provider, status) in statuses {
                    shimProviderStatuses[provider] = status
                }
            }
        }
    }

    func providerStatus(_ provider: ShimLoginProvider, home: CodexHome?) -> ShimProviderStatus {
        if provider == .codex, let home {
            return codexProviderStatus(for: home)
        }
        return shimProviderStatuses[provider] ?? ShimProviderStatus(state: .unknown, detail: "Not checked yet")
    }

    private func codexProviderStatus(for home: CodexHome) -> ShimProviderStatus {
        let status = authStatus(for: home)
        if status.isLoggedIn {
            return ShimProviderStatus(state: .ready, detail: status.accountLabel ?? "Signed in for this home")
        }
        if status.hasStoredCredentials {
            return ShimProviderStatus(state: .warning, detail: status.accountLabel ?? "Stored credentials found")
        }
        return ShimProviderStatus(state: .missing, detail: "No auth in selected home")
    }

    func openShimPicker(port: String) {
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let portValue = trimmedPort.isEmpty ? "8765" : trimmedPort
        guard let url = URL(string: "http://127.0.0.1:\(portValue)/picker") else {
            shimStatus = "Invalid shim picker port"
            return
        }
        NSWorkspace.shared.open(url)
        shimStatus = "Opened shim picker"
    }

    func refreshShimAppBundleStatus(executablePath: String) {
        let resolvedExecutable = resolveShimExecutable(executablePath)
        let environment = ProcessInfo.processInfo.environment
        shimAppBundleStatus = .checking
        Task {
            let result = await Task.detached {
                runCommand(executable: resolvedExecutable, arguments: ["app-status", "--json"], environment: environment)
            }.value
            await MainActor.run {
                if result.succeeded,
                   let data = result.output.data(using: .utf8),
                   let status = ShimAppBundleStatus(data: data) {
                    shimAppBundleStatus = status
                } else {
                    shimAppBundleStatus = ShimAppBundleStatus(error: result.summary(successMessage: ""))
                }
            }
        }
    }

    func rebuildShimAppBundle(executablePath: String) {
        let resolvedExecutable = resolveShimExecutable(executablePath)
        let environment = ProcessInfo.processInfo.environment
        beginShimOperation()
        shimStatus = "Repairing Codex Shim app"
        status = shimStatus
        Task {
            let result = await Task.detached {
                runCommand(executable: resolvedExecutable, arguments: ["prepare-app", "--replace"], environment: environment)
            }.value
            await MainActor.run {
                shimStatus = result.succeeded ? "Verifying Codex Shim app" : result.summary(successMessage: "")
                status = shimStatus
            }
            let statusResult = await Task.detached {
                runCommand(executable: resolvedExecutable, arguments: ["app-status", "--json"], environment: environment)
            }.value
            await MainActor.run {
                endShimOperation()
                shimStatus = result.summary(successMessage: "Repaired Codex Shim app")
                if statusResult.succeeded,
                   let data = statusResult.output.data(using: .utf8),
                   let status = ShimAppBundleStatus(data: data) {
                    shimAppBundleStatus = status
                } else {
                    shimAppBundleStatus = ShimAppBundleStatus(error: statusResult.summary(successMessage: ""))
                }
            }
        }
    }

    func defaultShimExecutablePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return resolveShimExecutablePath(
            overridePath: "",
            bundledPath: bundledShimExecutablePath(),
            externalCandidates: [
            "\(home)/.local/bin/codex-shim",
            "/opt/homebrew/bin/codex-shim",
            "/usr/local/bin/codex-shim"
            ]
        )
    }

    private func resolveShimExecutable(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return resolveShimExecutablePath(
            overridePath: path,
            bundledPath: bundledShimExecutablePath(),
            externalCandidates: [
                "\(home)/.local/bin/codex-shim",
                "/opt/homebrew/bin/codex-shim",
                "/usr/local/bin/codex-shim"
            ]
        )
    }

    private func bundledShimExecutablePath() -> String? {
        Bundle.module.resourceURL?
            .appendingPathComponent("codex-shim", isDirectory: true)
            .appendingPathComponent("run-codex-shim")
            .path
    }

    private func modelSelector(for selector: String) -> String {
        selector == "preferred" ? (state.preferences.launchTemporaryByDefault ? "temp" : "main") : selector
    }

    private func normalizedOptionalPath(_ value: String?) -> String? {
        guard let value else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func clonePreset(for options: CloneOptions) -> ClonePreset {
        if options == .empty {
            return .empty
        }
        if options.everything {
            return .everything
        }
        if options == .configOnly {
            return .configOnly
        }
        return .workingSetup
    }

    private func rememberCurrentClonePolicies(in state: inout HomeportState, beforeSetting policies: ClonePolicies) {
        guard state.preferences.clonePolicies != policies else {
            return
        }
        state.preferences.lastClonePolicies = state.preferences.clonePolicies
    }
}

enum CodexShimCommand: String, CaseIterable, Identifiable {
    case enable
    case restart
    case status
    case disable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enable: "Enable Shim"
        case .restart: "Restart Shim"
        case .status: "Check Shim"
        case .disable: "Disable Shim"
        }
    }

    var symbol: String {
        switch self {
        case .enable: "bolt.fill"
        case .restart: "arrow.clockwise"
        case .status: "waveform.path.ecg"
        case .disable: "stop.circle"
        }
    }
}

enum ShimLoginProvider: String, CaseIterable, Identifiable, Hashable {
    case codex
    case ollama
    case cursor

    var id: String { rawValue }

    static var defaultEnabledSet: Set<ShimLoginProvider> {
        Set(allCases)
    }

    var title: String {
        switch self {
        case .codex: "Codex"
        case .ollama: "Ollama"
        case .cursor: "Cursor"
        }
    }

    var symbol: String {
        switch self {
        case .codex: "key.fill"
        case .ollama: "cloud.fill"
        case .cursor: "cursorarrow.click.2"
        }
    }

    var detail: String {
        switch self {
        case .codex: "Scoped to selected CODEX_HOME"
        case .ollama: "Uses Ollama Cloud sign-in"
        case .cursor: "Uses cursor-agent session"
        }
    }

    func shellCommand(home: CodexHome?) -> String {
        switch self {
        case .codex:
            let homePath = home?.homePath ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
            return "CODEX_HOME=\(shellQuote(homePath)) codex login"
        case .ollama:
            return "ollama signin"
        case .cursor:
            return "cursor-agent login"
        }
    }
}

enum ShimProviderState {
    case ready
    case warning
    case missing
    case unknown

    var label: String {
        switch self {
        case .ready: "Signed in"
        case .warning: "Check"
        case .missing: "Needs login"
        case .unknown: "Unknown"
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .missing: "key.slash"
        case .unknown: "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .ready: .blue
        case .warning: .orange
        case .missing: .secondary
        case .unknown: .secondary
        }
    }
}

struct ShimProviderStatus {
    var state: ShimProviderState
    var detail: String
}

struct ShimAppBundleStatus {
    var sourcePath: String
    var destinationPath: String
    var sourceExists: Bool
    var destinationExists: Bool
    var sourceVersion: String
    var destinationVersion: String
    var sourceHash: String
    var destinationHash: String
    var patched: Bool
    var stale: Bool
    var browserBridgeReady: Bool
    var destinationBundleIdentifier: String
    var preparedAt: String?
    var error: String?
    var isChecking: Bool

    static let checking = ShimAppBundleStatus(
        sourcePath: HomeportPaths().codexAppBundle.path,
        destinationPath: defaultShimmableCodexAppBundleURL().path,
        sourceExists: false,
        destinationExists: false,
        sourceVersion: "checking",
        destinationVersion: "checking",
        sourceHash: "",
        destinationHash: "",
        patched: false,
        stale: true,
        browserBridgeReady: false,
        destinationBundleIdentifier: "",
        preparedAt: nil,
        error: nil,
        isChecking: true
    )

    init(error: String) {
        self = .checking
        self.sourceVersion = "unknown"
        self.destinationVersion = "unknown"
        self.error = error
        self.isChecking = false
    }

    init(
        sourcePath: String,
        destinationPath: String,
        sourceExists: Bool,
        destinationExists: Bool,
        sourceVersion: String,
        destinationVersion: String,
        sourceHash: String,
        destinationHash: String,
        patched: Bool,
        stale: Bool,
        browserBridgeReady: Bool,
        destinationBundleIdentifier: String,
        preparedAt: String?,
        error: String?,
        isChecking: Bool
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.sourceExists = sourceExists
        self.destinationExists = destinationExists
        self.sourceVersion = sourceVersion
        self.destinationVersion = destinationVersion
        self.sourceHash = sourceHash
        self.destinationHash = destinationHash
        self.patched = patched
        self.stale = stale
        self.browserBridgeReady = browserBridgeReady
        self.destinationBundleIdentifier = destinationBundleIdentifier
        self.preparedAt = preparedAt
        self.error = error
        self.isChecking = isChecking
    }

    init?(data: Data) {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            return nil
        }
        let source = json["source"] as? [String: Any]
        let destination = json["destination"] as? [String: Any]
        let metadata = json["metadata"] as? [String: Any]
        self.init(
            sourcePath: json["source_path"] as? String ?? source?["path"] as? String ?? HomeportPaths().codexAppBundle.path,
            destinationPath: json["destination_path"] as? String ?? destination?["path"] as? String ?? defaultShimmableCodexAppBundleURL().path,
            sourceExists: json["source_exists"] as? Bool ?? false,
            destinationExists: json["destination_exists"] as? Bool ?? false,
            sourceVersion: Self.versionText(source),
            destinationVersion: Self.versionText(destination),
            sourceHash: Self.shortHash(source?["app_asar_sha256"]),
            destinationHash: Self.shortHash(destination?["app_asar_sha256"]),
            patched: json["patched"] as? Bool ?? false,
            stale: json["stale"] as? Bool ?? true,
            browserBridgeReady: true,
            destinationBundleIdentifier: Self.bundleIdentifier(destination),
            preparedAt: metadata?["prepared_at"] as? String,
            error: nil,
            isChecking: false
        )
    }

    var stateTitle: String {
        if isChecking { return "Checking shimmable app" }
        if error != nil { return "Could not inspect shimmable app" }
        if !destinationExists { return "Codex Shim app is not built" }
        if stale { return "Codex Shim app needs rebuild" }
        if !patched { return "Codex Shim app is unpatched" }
        return "Codex Shim app is ready"
    }

    var stateDetail: String {
        if isChecking { return "Inspecting copied app and Browser launch mode." }
        if error != nil { return "Use Repair Shim App to rebuild the copied app and refresh diagnostics." }
        if !destinationExists { return "First routed App launch will build this automatically." }
        if stale { return "Repair Shim App will rebuild from the current Codex app." }
        if !patched { return "The copied app is missing codex-shim's ASAR patch." }
        return "Homeport opens the copy in Browser-compatible dev mode so in-app Browser sockets do not require copied-app peer signing."
    }

    var stateSymbol: String {
        if isChecking { return "hourglass" }
        if error != nil { return "exclamationmark.triangle.fill" }
        if !destinationExists || stale || !patched { return "wrench.and.screwdriver.fill" }
        return "checkmark.seal.fill"
    }

    var stateColor: Color {
        if isChecking { return .blue }
        if error != nil || stale || !patched { return .orange }
        if !destinationExists { return .secondary }
        return .blue
    }

    private static func versionText(_ signature: [String: Any]?) -> String {
        guard let info = signature?["info"] as? [String: Any] else {
            return "missing"
        }
        let short = (info["CFBundleShortVersionString"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let build = (info["CFBundleVersion"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !short.isEmpty && !build.isEmpty {
            return "\(short) (\(build))"
        }
        return short.isEmpty ? (build.isEmpty ? "unknown" : build) : short
    }

    private static func shortHash(_ value: Any?) -> String {
        String((value as? String ?? "").prefix(12))
    }

    private static func bundleIdentifier(_ signature: [String: Any]?) -> String {
        guard let info = signature?["info"] as? [String: Any] else {
            return ""
        }
        return (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct ShimCatalogPlan {
    var payload: [String: Any]
    var defaultModelSlug: String?
    var included: [String]
    var skipped: [String]
}

struct CommandResult {
    var exitCode: Int32
    /// stdout only — safe for JSON parsing even when the command logs to stderr.
    var output: String
    var errorOutput: String = ""

    var succeeded: Bool {
        exitCode == 0
    }

    var combinedOutput: String {
        [output, errorOutput]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    func summary(successMessage: String) -> String {
        let trimmed = combinedOutput
        if succeeded {
            return trimmed.isEmpty ? successMessage : trimmed
        }
        return trimmed.isEmpty ? "Command failed with exit code \(exitCode)" : trimmed
    }
}

func shimCatalogSettingsURL(for home: CodexHome) -> URL {
    URL(fileURLWithPath: home.homePath, isDirectory: true)
        .appendingPathComponent(".codex-shim", isDirectory: true)
        .appendingPathComponent("providers-models.json")
}

/// Shells out to `ollama list` while building the plan — never call on the main thread.
func buildAndWriteShimCatalog(
    home: CodexHome,
    enabledProviders: Set<ShimLoginProvider>,
    environment: [String: String]
) throws -> (path: String, defaultModelSlug: String?, included: [String]) {
    let settingsURL = shimCatalogSettingsURL(for: home)
    try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let plan = buildShimCatalogPlan(
        enabledProviders: enabledProviders,
        environment: environment
    )
    let data = try JSONSerialization.data(withJSONObject: plan.payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: settingsURL, options: .atomic)
    return (settingsURL.path, plan.defaultModelSlug, plan.included)
}

func defaultShimmableCodexAppBundleURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Applications", isDirectory: true)
        .appendingPathComponent("Codex Shim.app", isDirectory: true)
}

func buildShimCatalogPlan(enabledProviders: Set<ShimLoginProvider>, environment: [String: String]) -> ShimCatalogPlan {
    var models: [[String: Any]] = []
    var included: [String] = []
    var skipped: [String] = []

    if enabledProviders.contains(.codex) {
        included.append("ChatGPT/Codex")
    } else {
        skipped.append("ChatGPT/Codex disabled")
    }

    if enabledProviders.contains(.ollama) {
        let ollamaModels = uniqueModels(ollamaCloudModels(environment: environment) + ollamaInstalledLocalModels(environment: environment))
        if ollamaModels.isEmpty {
            skipped.append("Ollama has no listed models")
        } else {
            models.append(contentsOf: ollamaModels.map(ollamaModelPayload))
            included.append("Ollama (\(ollamaModels.count))")
        }
    } else {
        skipped.append("Ollama disabled")
    }

    if enabledProviders.contains(.cursor) {
        included.append("Cursor")
    } else {
        skipped.append("Cursor disabled")
    }

    let defaultSlug = models.first?["slug"] as? String
        ?? (enabledProviders.contains(.codex) ? "gpt-5.5" : nil)
        ?? (enabledProviders.contains(.cursor) ? "composer-2-5" : nil)

    return ShimCatalogPlan(
        payload: [
            "models": models,
            "notes": [
                "Provider toggles are scoped to this Codex home.",
                "ChatGPT/Codex and Cursor are discovered by codex-shim from supported login state.",
                "Included: \(included.joined(separator: ", "))",
                "Skipped: \(skipped.joined(separator: ", "))"
            ]
        ],
        defaultModelSlug: defaultSlug,
        included: included,
        skipped: skipped
    )
}

func shimCommandEnvironment(enabledProviders: Set<ShimLoginProvider>) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    if enabledProviders.contains(.codex) {
        environment.removeValue(forKey: "CODEX_SHIM_DISABLE_CHATGPT")
    } else {
        environment["CODEX_SHIM_DISABLE_CHATGPT"] = "1"
    }
    if enabledProviders.contains(.cursor) {
        environment.removeValue(forKey: "CODEX_SHIM_DISABLE_CURSOR")
    } else {
        environment["CODEX_SHIM_DISABLE_CURSOR"] = "1"
    }
    return environment
}

// Written on one queue, read after DispatchGroup.wait establishes happens-before.
private final class PipeDrain: @unchecked Sendable {
    var data = Data()
}

func runCommand(executable: String, arguments: [String], environment: [String: String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    let outputPipe = Pipe()
    let errorPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = errorPipe
    do {
        try process.run()
        // Drain both pipes before waiting: output beyond the pipe buffer deadlocks waitUntilExit.
        let errorDrain = PipeDrain()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorDrain.data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let error = String(data: errorDrain.data, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, output: output, errorOutput: error)
    } catch {
        return CommandResult(exitCode: 127, output: error.localizedDescription)
    }
}

func runShimStartWireSequence(executable: String, baseArguments: [String], defaultModelSlug: String?, environment: [String: String]) -> CommandResult {
    let restart = runCommand(executable: executable, arguments: baseArguments + [CodexShimCommand.restart.rawValue], environment: environment)
    if !restart.succeeded {
        return restart
    }
    let enable = runCommand(executable: executable, arguments: baseArguments + [CodexShimCommand.enable.rawValue], environment: environment)
    guard enable.succeeded else {
        return CommandResult(exitCode: enable.exitCode, output: [restart.combinedOutput, enable.combinedOutput].joined(separator: "\n"))
    }
    let trimmedSlug = defaultModelSlug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmedSlug.isEmpty else {
        return CommandResult(exitCode: enable.exitCode, output: [restart.combinedOutput, enable.combinedOutput].joined(separator: "\n"))
    }
    let select = runCommand(executable: executable, arguments: baseArguments + ["model", "use", trimmedSlug], environment: environment)
    return CommandResult(exitCode: select.exitCode, output: [restart.combinedOutput, enable.combinedOutput, select.combinedOutput].joined(separator: "\n"))
}

func expandUserPath(_ path: String) -> String {
    if path == "~" {
        return FileManager.default.homeDirectoryForCurrentUser.path
    }
    if path.hasPrefix("~/") {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(String(path.dropFirst(2)))
            .path
    }
    return path
}

func ollamaProviderStatus(environment: [String: String]) -> ShimProviderStatus {
    guard let executable = findExecutable("ollama", extraPaths: []) else {
        return ShimProviderStatus(state: .missing, detail: "Ollama CLI not found")
    }
    let result = runCommand(executable: executable, arguments: ["list"], environment: environment)
    guard result.succeeded else {
        return ShimProviderStatus(state: .warning, detail: "Ollama is installed; sign-in/list check failed")
    }
    let cloudCount = ollamaCloudModels(environment: environment).count
    if cloudCount > 0 {
        return ShimProviderStatus(state: .ready, detail: "\(cloudCount) Ollama Cloud routes available")
    }
    return ShimProviderStatus(state: .warning, detail: "Ollama works; no cloud model visible")
}

func ollamaModelPayload(_ model: String) -> [String: Any] {
    [
        "slug": slug(from: "ollama-\(model)"),
        "model": model,
        "display_name": "Ollama \(ollamaDisplayName(for: model))",
        "provider": "generic-chat-completion-api",
        "base_url": "http://127.0.0.1:11434/v1",
        "api_key": "ollama",
        "reasoning_levels": ["low", "medium", "high", "xhigh"],
        "default_reasoning_level": "medium"
    ]
}

func ollamaCloudModels(environment: [String: String]) -> [String] {
    uniqueModels(knownOllamaCloudModels + ollamaListedModels(
        matching: { isOllamaCloudModel($0) && !isOllamaEmbeddingModel($0) },
        environment: environment
    ))
}

func ollamaInstalledLocalModels(environment: [String: String]) -> [String] {
    let models = ollamaListedModels(
        matching: { !isOllamaCloudModel($0) && !isOllamaEmbeddingModel($0) },
        environment: environment
    )
    return uniqueModels(models)
}

func ollamaListedModels(matching predicate: (String) -> Bool, environment: [String: String]) -> [String] {
    guard let executable = findExecutable("ollama", extraPaths: []) else {
        return []
    }
    let result = runCommand(executable: executable, arguments: ["list"], environment: environment)
    guard result.succeeded else {
        return []
    }
    var models: [String] = []
    for line in result.output.split(separator: "\n").dropFirst() {
        guard let name = line.split(separator: " ").first.map(String.init), predicate(name) else {
            continue
        }
        models.append(name)
    }
    return models
}

let knownOllamaCloudModels = [
    "glm-5.2:cloud",
    "kimi-k2.7-code:cloud",
    "nemotron-3-ultra:cloud",
    "minimax-m3:cloud",
    "deepseek-v4-flash:cloud",
    "deepseek-v4-pro:cloud",
    "glm-5.1:cloud",
    "kimi-k2.6:cloud",
    "minimax-m2.7:cloud",
    "gemma4:cloud",
    "nemotron-3-super:cloud",
    "qwen3.5:cloud",
    "minimax-m2.5:cloud",
    "glm-5:cloud",
    "kimi-k2.5:cloud",
    "glm-4.7:cloud",
    "gemini-3-flash-preview:cloud",
    "devstral-2:123b-cloud",
    "devstral-small-2:24b-cloud",
    "gpt-oss:120b-cloud"
]

func isOllamaCloudModel(_ model: String) -> Bool {
    model.contains(":cloud") || model.hasSuffix("-cloud")
}

func isOllamaEmbeddingModel(_ model: String) -> Bool {
    model.lowercased().contains("embed")
}

func uniqueModels(_ models: [String]) -> [String] {
    var seen = Set<String>()
    return models.filter { seen.insert($0).inserted }
}

func ollamaDisplayName(for model: String) -> String {
    let trimmed = model
        .replacingOccurrences(of: ":cloud", with: "")
        .replacingOccurrences(of: "-cloud", with: "")
    return trimmed
        .split(separator: "-")
        .map { word in
            let text = String(word)
            let uppercased = text.uppercased()
            if ["GLM", "GPT", "OSS", "KIMI", "QWEN"].contains(uppercased) || text.allSatisfy({ $0.isNumber }) {
                return uppercased
            }
            if text.count <= 2 {
                return uppercased
            }
            return text.prefix(1).uppercased() + text.dropFirst()
        }
        .joined(separator: " ")
}

func cursorProviderStatus(environment: [String: String]) -> ShimProviderStatus {
    guard let executable = findExecutable("cursor-agent", extraPaths: []) else {
        return ShimProviderStatus(state: .missing, detail: "cursor-agent not found")
    }
    let result = runCommand(executable: executable, arguments: ["status"], environment: environment)
    guard result.succeeded else {
        return ShimProviderStatus(state: .warning, detail: "cursor-agent found; status failed")
    }
    let lowercasedOutput = result.output.lowercased()
    if lowercasedOutput.contains("logged in") || lowercasedOutput.contains("authenticated") {
        return ShimProviderStatus(state: .ready, detail: "cursor-agent is authenticated")
    }
    let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    return ShimProviderStatus(state: .warning, detail: detail.isEmpty ? "cursor-agent status unknown" : detail)
}

func findExecutable(_ name: String, extraPaths: [String]) -> String? {
    let environmentPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
    let paths = (extraPaths + environmentPath.split(separator: ":").map(String.init) + ["/usr/local/bin", "/opt/homebrew/bin"])
    for path in paths {
        let candidate = URL(fileURLWithPath: path).appendingPathComponent(name).path
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

func slug(from value: String) -> String {
    let lowered = value.lowercased()
    var result = ""
    var lastWasDash = false
    for scalar in lowered.unicodeScalars {
        if CharacterSet.alphanumerics.contains(scalar) {
            result.unicodeScalars.append(scalar)
            lastWasDash = false
        } else if !lastWasDash {
            result.append("-")
            lastWasDash = true
        }
    }
    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "model" : trimmed
}

enum MenuTab: String, CaseIterable, Identifiable {
    case favorites
    case recents
    case homes
    case new
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .favorites: "Favorites"
        case .recents: "Recents"
        case .homes: "Homes"
        case .new: "New Home"
        case .settings: "Settings"
        }
    }

    var subtitle: String {
        switch self {
        case .favorites: "Fast launch your usual homes"
        case .recents: "Recent opens and temporary cleanup"
        case .homes: "Browse, favorite, and launch homes"
        case .new: "Choose the kind of home first"
        case .settings: "Defaults, diagnostics, and installer state"
        }
    }

    var symbol: String {
        switch self {
        case .favorites: "star.fill"
        case .recents: "clock"
        case .homes: "square.grid.2x2.fill"
        case .new: "plus"
        case .settings: "gearshape.fill"
        }
    }
}

enum NewHomeMode: String, CaseIterable, Identifiable, Sendable {
    case clone
    case cleanRoom
    case configOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clone: "Clone My Setup"
        case .cleanRoom: "Clean Room"
        case .configOnly: "Config Only"
        }
    }

    var subtitle: String {
        switch self {
        case .clone: "Start from selected parts of your main Codex home"
        case .cleanRoom: "Fresh saved home with no inherited files"
        case .configOnly: "Settings, skills, and prompts only"
        }
    }

    var symbol: String {
        switch self {
        case .clone: "square.on.square"
        case .cleanRoom: "sparkles"
        case .configOnly: "slider.horizontal.3"
        }
    }

    var showsCloneOptions: Bool {
        self == .clone || self == .configOnly
    }
}

struct HomeportMenuView: View {
    @EnvironmentObject var model: HomeportModel
    @Environment(\.openWindow) private var openWindow
    @State private var selectedTab: MenuTab = .favorites
    @State private var isEditingList = false
    @State private var focusedHome: CodexHome?
    @State private var detailReturnTab: MenuTab = .favorites
    @State private var isEditingDetail = false
    @State private var editedName = ""
    @State private var editedHomePath = ""
    @State private var moveFoldersOnRename = false
    @State private var moveHomePathOnEdit = false
    @State private var newHomeMode: NewHomeMode = .clone
    @State private var newHomeLaunchTarget: LaunchTarget = .desktop
    @State private var newHomeName = ""
    @State private var newHomeNameEdited = false
    @State private var newHomePath = ""
    @State private var newHomePathEdited = false
    @State private var createsTemporaryHome = false
    @State private var isCreatingHome = false
    @State private var showsAddFavoriteSheet = false
    @State private var pendingDeleteHome: CodexHome?

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                PhoneMenuHeader(
                    title: headerTitle,
                    subtitle: headerSubtitle,
                    leftTitle: leftActionTitle,
                    showsLeftAction: showsLeftAction,
                    rightTitle: focusedHome == nil ? nil : (isEditingDetail ? "Done" : "Edit"),
                    showsAddAndRefresh: focusedHome == nil,
                    leftAction: handleLeftAction,
                    rightAction: handleDetailRightAction,
                    addAction: {
                        if selectedTab == .favorites {
                            showsAddFavoriteSheet = true
                            isEditingList = false
                            return
                        }
                        focusedHome = nil
                        selectedTab = .new
                        isEditingList = false
                    },
                    refreshAction: { model.refresh() }
                )

                if focusedHome == nil && model.updateAvailable {
                    UpdateAvailableBanner(
                        openSettings: {
                            selectedTab = .settings
                            isEditingList = false
                        },
                        dismiss: { model.dismissUpdate() }
                    )
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }

                if model.status != "Ready" {
                    StatusBanner(message: model.status)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                if focusedHome == nil {
                    LaunchModeStrip()
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                }

                ScrollView {
                    Group {
                        if let focusedHome {
                            FocusedHomeView(
                                home: focusedHome,
                                isEditing: isEditingDetail,
                                editedName: $editedName,
                                editedHomePath: $editedHomePath,
                                moveFoldersOnRename: $moveFoldersOnRename,
                                moveHomePathOnEdit: $moveHomePathOnEdit,
                                launch: { target in model.launch(focusedHome.slug, target: target) },
                                setPinned: { pinned in
                                    model.setHomePinned(focusedHome, pinned: pinned)
                                    self.focusedHome = model.state.homes.first { $0.id == focusedHome.id } ?? focusedHome
                                },
                                delete: {
                                    requestDelete(focusedHome)
                                }
                            )
                        } else {
                            tabContent
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                }
                .frame(minHeight: 360, maxHeight: 560)

                if focusedHome == nil {
                    PhoneTabBar(selectedTab: $selectedTab) {
                        isEditingList = false
                    }
                }

                Divider()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Multihome", systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .frame(width: 390)
            .blur(radius: pendingDeleteHome == nil ? 0 : 1.5)
            .disabled(pendingDeleteHome != nil)

            if let pendingDeleteHome {
                DeleteHomeConfirmation(
                    home: pendingDeleteHome,
                    confirm: { confirmDeleteHome(pendingDeleteHome) },
                    cancel: { self.pendingDeleteHome = nil }
                )
                .padding(24)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.16), value: pendingDeleteHome?.id)
        .onChange(of: selectedTab) { _ in
            isEditingList = false
        }
        .onChange(of: focusedHome?.id) { _ in
            editedName = focusedHome?.name ?? ""
            editedHomePath = focusedHome?.homePath ?? ""
            moveFoldersOnRename = false
            moveHomePathOnEdit = false
        }
        .sheet(isPresented: $showsAddFavoriteSheet) {
            AddFavoriteSheet()
                .environmentObject(model)
        }
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .favorites:
            FavoritesTab(
                isEditing: isEditingList,
                openDetail: openDetail,
                openConsole: { openWindow(id: "console") }
            )
        case .recents:
            RecentsTab(
                isEditing: isEditingList,
                openDetail: openDetail
            )
        case .homes:
            HomesTab(
                isEditing: isEditingList,
                openDetail: openDetail,
                requestDelete: requestDelete
            )
        case .new:
            NewHomeTab(
                mode: $newHomeMode,
                launchTarget: $newHomeLaunchTarget,
                customName: $newHomeName,
                customNameEdited: $newHomeNameEdited,
                customPath: $newHomePath,
                customPathEdited: $newHomePathEdited,
                createsTemporaryHome: $createsTemporaryHome,
                isCreating: isCreatingHome,
                suggestedName: suggestedNewHomeName(for: newHomeMode),
                suggestedPath: suggestedNewHomePath(for: newHomeMode),
                create: createNewHome
            )
        case .settings:
            SettingsTab(
                openConsole: { openWindow(id: "console") },
                quit: { NSApplication.shared.terminate(nil) }
            )
        }
    }

    private var headerTitle: String {
        focusedHome?.name ?? selectedTab.title
    }

    private var headerSubtitle: String {
        focusedHome.map(kindLabel(for:)) ?? selectedTab.subtitle
    }

    private var showsLeftAction: Bool {
        focusedHome != nil || [.favorites, .recents, .homes].contains(selectedTab)
    }

    private var leftActionTitle: String {
        if focusedHome != nil {
            if isEditingDetail {
                return "Cancel"
            }
            return "‹ \(detailReturnTab.title)"
        }
        return isEditingList ? "Done" : "Edit"
    }

    private func handleLeftAction() {
        if focusedHome != nil {
            if isEditingDetail {
                cancelDetailEdit()
                return
            }
            focusedHome = nil
            isEditingDetail = false
            selectedTab = detailReturnTab
            return
        }
        if [.favorites, .recents, .homes].contains(selectedTab) {
            isEditingList.toggle()
        }
    }

    private func handleDetailRightAction() {
        if isEditingDetail {
            saveDetailEdits()
            return
        }
        editedName = focusedHome?.name ?? ""
        editedHomePath = focusedHome?.homePath ?? ""
        moveFoldersOnRename = false
        moveHomePathOnEdit = false
        isEditingDetail = true
    }

    private func cancelDetailEdit() {
        editedName = focusedHome?.name ?? ""
        editedHomePath = focusedHome?.homePath ?? ""
        moveFoldersOnRename = false
        moveHomePathOnEdit = false
        isEditingDetail = false
    }

    private func saveDetailEdits() {
        guard let focusedHome else {
            isEditingDetail = false
            return
        }
        let trimmedName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            model.status = "Home name cannot be empty."
            return
        }
        let trimmedPath = editedHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else {
            model.status = "Home path cannot be empty."
            return
        }
        let pathChanged = trimmedPath != focusedHome.homePath
        let nameChanged = trimmedName != focusedHome.name || moveFoldersOnRename
        let hasChanges = nameChanged || pathChanged
        guard hasChanges else {
            isEditingDetail = false
            return
        }
        if nameChanged, !model.renameHome(focusedHome, name: trimmedName, moveFolders: moveFoldersOnRename) {
            return
        }
        var refreshedHome = model.state.homes.first { $0.id == focusedHome.id } ?? focusedHome
        if pathChanged, !model.changeHomePath(refreshedHome, homePath: trimmedPath, moveExisting: moveHomePathOnEdit) {
            return
        }
        refreshedHome = model.state.homes.first { $0.id == focusedHome.id } ?? refreshedHome
        self.focusedHome = refreshedHome
        editedName = refreshedHome.name
        editedHomePath = refreshedHome.homePath
        moveFoldersOnRename = false
        moveHomePathOnEdit = false
        isEditingDetail = false
    }

    private func openDetail(_ home: CodexHome) {
        detailReturnTab = selectedTab
        focusedHome = home
        editedName = home.name
        editedHomePath = home.homePath
        moveFoldersOnRename = false
        moveHomePathOnEdit = false
        isEditingList = false
        isEditingDetail = false
    }

    private func createNewHome() {
        guard !isCreatingHome else { return }
        let suggestedName = suggestedNewHomeName(for: newHomeMode)
        let pathBackedName = suggestedHomeName(fromHomePath: newHomePath)
        let name = newHomeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = name.isEmpty ? (pathBackedName ?? suggestedName) : name
        let mode = newHomeMode
        let temporary = createsTemporaryHome
        let target = newHomeLaunchTarget
        let preferences = model.state.preferences
        let service = model.service
        let trimmedPath = newHomePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let homePath = trimmedPath.isEmpty ? nil : trimmedPath
        isCreatingHome = true
        model.status = "Creating \(resolvedName)…"
        Task {
            let result: Result<CodexHome, Error> = await Task.detached {
                do {
                    let home: CodexHome
                    switch mode {
                    case .clone:
                        home = temporary
                            ? try service.createTemporary(name: resolvedName, homePath: homePath, policies: preferences.clonePolicies, sourceSelector: preferences.cloneSourceSelector, preset: preferences.defaultClonePreset)
                            : try service.clone(name: resolvedName, preset: preferences.defaultClonePreset, policies: preferences.clonePolicies, sourceSelector: preferences.cloneSourceSelector, homePath: homePath)
                    case .cleanRoom:
                        home = temporary
                            ? try service.createTemporary(name: resolvedName, homePath: homePath)
                            : try service.createCleanRoom(name: resolvedName, homePath: homePath)
                    case .configOnly:
                        home = temporary
                            ? try service.createTemporary(name: resolvedName, homePath: homePath, policies: .configOnly, sourceSelector: preferences.cloneSourceSelector, preset: .configOnly)
                            : try service.clone(name: resolvedName, preset: .configOnly, policies: .configOnly, sourceSelector: preferences.cloneSourceSelector, homePath: homePath)
                    }
                    return .success(home)
                } catch {
                    return .failure(error)
                }
            }.value
            isCreatingHome = false
            guard case let .success(createdHome) = result else {
                if case let .failure(error) = result { model.status = error.localizedDescription }
                return
            }
            model.refresh(statusMessage: "Created \(createdHome.name)")
            finishCreatingHome(createdHome, launchTarget: target)
        }
    }

    private func finishCreatingHome(_ createdHome: CodexHome, launchTarget: LaunchTarget) {
        let didLaunch = model.launch(createdHome.slug, target: launchTarget)
        let launchFailure = model.status
        let refreshedHome = model.state.homes.first { $0.id == createdHome.id } ?? createdHome
        detailReturnTab = .homes
        selectedTab = .homes
        focusedHome = refreshedHome
        editedName = refreshedHome.name
        editedHomePath = refreshedHome.homePath
        moveFoldersOnRename = false
        moveHomePathOnEdit = false
        newHomeName = ""
        newHomeNameEdited = false
        newHomePath = ""
        newHomePathEdited = false
        createsTemporaryHome = false
        isEditingList = false
        isEditingDetail = false
        model.status = didLaunch
            ? "Created and opened \(refreshedHome.name)"
            : "Created \(refreshedHome.name), but open failed: \(launchFailure)"
    }

    private func suggestedNewHomeName(for mode: NewHomeMode) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d HH:mm"
        switch mode {
        case .clone:
            return "Working Setup \(formatter.string(from: Date()))"
        case .cleanRoom:
            return "Clean Room"
        case .configOnly:
            return "Config Copy \(formatter.string(from: Date()))"
        }
    }

    private func suggestedNewHomePath(for mode: NewHomeMode) -> String {
        let slug = uniqueNewHomeSlug(base: slugify(suggestedNewHomeName(for: mode)))
        return model.service.paths.managedHomesDirectory
            .appendingPathComponent(slug, isDirectory: true)
            .path
    }

    private func uniqueNewHomeSlug(base: String) -> String {
        let existing = Set(model.state.homes.map(\.slug))
        guard existing.contains(base) else {
            return base
        }
        var index = 2
        while existing.contains("\(base)-\(index)") {
            index += 1
        }
        return "\(base)-\(index)"
    }

    private func requestDelete(_ home: CodexHome) {
        guard home.kind != .main else {
            model.status = "The main ~/.codex home cannot be deleted."
            return
        }
        pendingDeleteHome = home
    }

    private func confirmDeleteHome(_ home: CodexHome) {
        pendingDeleteHome = nil
        model.status = "Deleting \(home.name)…"
        let service = model.service
        Task {
            let result: Result<Void, Error> = await Task.detached {
                Result { _ = try service.deleteHome(id: home.id) }
            }.value
            switch result {
            case .success:
                model.refresh(statusMessage: "Deleted \(home.name)")
                if focusedHome?.id == home.id {
                    focusedHome = nil
                    isEditingDetail = false
                    selectedTab = detailReturnTab
                }
            case let .failure(error):
                model.status = error.localizedDescription
            }
        }
    }
}

struct DeleteHomeConfirmation: View {
    var home: CodexHome
    var confirm: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Move \(home.name) to Trash?")
                .font(.headline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text("This removes the managed home and profile from Multihome and moves their files to Trash.")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(role: .destructive, action: confirm) {
                    Text("Move to Trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)

                Button(action: cancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.quaternary)
        }
        .shadow(color: .black.opacity(0.18), radius: 24, y: 12)
    }
}

struct StatusBanner: View {
    var message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            Text(message)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.22)))
    }

    private var tint: Color {
        isError ? .red : .blue
    }

    private var symbol: String {
        isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
    }

    private var isError: Bool {
        let lowercasedMessage = message.lowercased()
        return lowercasedMessage.contains("error")
            || lowercasedMessage.contains("cannot")
            || lowercasedMessage.contains("failed")
            || lowercasedMessage.contains("missing")
            || lowercasedMessage.contains("not found")
    }
}

struct UpdateAvailableBanner: View {
    @EnvironmentObject var model: HomeportModel
    var openSettings: () -> Void
    var dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text("Update available")
                    .font(.caption.weight(.semibold))
                Text(versionText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Details") {
                openSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Button("Later", action: dismiss)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.blue.opacity(0.24)))
    }

    private var versionText: String {
        if let latestVersion = model.state.updater.latestVersion {
            return "Multihome \(latestVersion) is available"
        }
        return "A newer Multihome is available"
    }
}

struct PhoneMenuHeader: View {
    var title: String
    var subtitle: String
    var leftTitle: String
    var showsLeftAction: Bool
    var rightTitle: String?
    var showsAddAndRefresh: Bool
    var leftAction: () -> Void
    var rightAction: () -> Void
    var addAction: () -> Void
    var refreshAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(leftTitle, action: leftAction)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.blue)
                    .opacity(showsLeftAction ? 1 : 0)
                    .disabled(!showsLeftAction)
                Spacer()
                if let rightTitle {
                    Button(rightTitle, action: rightAction)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.blue)
                } else if showsAddAndRefresh {
                    Button(action: addAction) {
                        Image(systemName: "plus")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button(action: refreshAction) {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }
}

struct PhoneTabBar: View {
    @EnvironmentObject var model: HomeportModel
    @Binding var selectedTab: MenuTab
    var onSelect: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(MenuTab.allCases) { tab in
                Button {
                    selectedTab = tab
                    onSelect()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .overlay(alignment: .topTrailing) {
                                if tab == .settings && model.updateAvailable {
                                    Circle()
                                        .fill(.red)
                                        .frame(width: 6, height: 6)
                                        .offset(x: 5, y: -2)
                                }
                            }
                        Text(tab.title == "New Home" ? "New" : tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(selectedTab == tab ? .blue : .secondary)
                    .background(selectedTab == tab ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct FavoritesTab: View {
    @EnvironmentObject var model: HomeportModel
    var isEditing: Bool
    var openDetail: (CodexHome) -> Void
    var openConsole: () -> Void

    var favoriteHomes: [CodexHome] {
        model.pinnedHomes
    }

    var fallbackMainHome: CodexHome? {
        guard favoriteHomes.isEmpty else {
            return nil
        }
        return model.state.homes.first { $0.kind == .main }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DefaultLaunchCard()
            SectionLabel("Favorites")
            if !favoriteHomes.isEmpty {
                ForEach(favoriteHomes) { home in
                    HomeListRow(
                        home: home,
                        subtitle: "Favorite • \(kindLabel(for: home))",
                        isEditing: isEditing,
                        openDetail: { openDetail(home) },
                        launch: { target in model.launch(home.slug, target: target) },
                        editAction: { model.setHomePinned(home, pinned: false) },
                        editActionHelp: "Remove from Favorites"
                    )
                }
            } else if let fallbackMainHome {
                HomeListRow(
                    home: fallbackMainHome,
                    subtitle: "Default main home • not a favorite yet",
                    isEditing: isEditing,
                    openDetail: { openDetail(fallbackMainHome) },
                    launch: { target in model.launch(fallbackMainHome.slug, target: target) }
                )
            } else {
                EmptyState(title: "No favorites yet", subtitle: "Create or pin homes to put them here.")
            }
            if let recent = model.recentInstances.first {
                SectionLabel("Recent")
                RecentLaunchRow(instance: recent, isEditing: isEditing)
            }
            LaunchHealthBanner()
            Button("Open Console", action: openConsole)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
    }
}

private extension CodexAuthStatus {
    var modeDisplay: String? {
        guard let mode, !mode.isEmpty else {
            return nil
        }
        switch mode {
        case "chatgpt":
            return "ChatGPT"
        case "api-key":
            return "API key"
        default:
            return mode
        }
    }
}

struct AddFavoriteSheet: View {
    @EnvironmentObject var model: HomeportModel
    @Environment(\.dismiss) private var dismiss

    private var unpinnedHomes: [CodexHome] {
        model.state.homes.filter { !model.isPinned($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add Favorite")
                        .font(.title3.weight(.bold))
                    Text("Pick a home to pin on Favorites.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }

            if unpinnedHomes.isEmpty {
                EmptyState(title: "All homes are favorites", subtitle: "Create another home to add a new favorite.")
            } else {
                ForEach(unpinnedHomes) { home in
                    Button {
                        model.setHomePinned(home, pinned: true)
                        dismiss()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: homeKindIcon(for: home))
                                .frame(width: 24, height: 24)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(home.name)
                                    .font(.caption.weight(.semibold))
                                Text(kindLabel(for: home))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "star")
                                .foregroundStyle(.secondary)
                        }
                        .padding(10)
                        .background(.background, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }

}

struct DefaultLaunchCard: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default Launch")
                        .font(.headline.weight(.semibold))
                    Text("\(defaultHomeName) home • choose where it opens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LaunchActionPair { target in
                    let selector = model.state.preferences.launchTemporaryByDefault ? "temp" : "main"
                    model.launch(selector, target: target)
                }
            }
        }
        .padding(14)
        .background(Color.blue.opacity(0.14), in: RoundedRectangle(cornerRadius: 14))
    }

    private var defaultHomeName: String {
        model.state.preferences.launchTemporaryByDefault ? "Temporary" : "Main"
    }
}

struct LaunchModeStrip: View {
    @EnvironmentObject var model: HomeportModel

    private var browserDevBinding: Binding<Bool> {
        Binding(
            get: { model.state.preferences.browserUseLocalTestingMode },
            set: { model.setBrowserUseLocalTestingMode($0) }
        )
    }

    private var appDevBinding: Binding<Bool> {
        Binding(
            get: { model.state.preferences.desktopAppDevFlavor },
            set: { model.setDesktopAppDevFlavor($0) }
        )
    }

    private var isUsingDevMode: Bool {
        model.state.preferences.browserUseLocalTestingMode || model.state.preferences.desktopAppDevFlavor
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isUsingDevMode ? "hammer.fill" : "shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isUsingDevMode ? .orange : .secondary)
                .frame(width: 20, height: 20)
                .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))

            Text("Dev launch:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Toggle("Browser", isOn: browserDevBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Allow local browser testing with BROWSER_USE_SECURITY_MODE=disabled-for-local-testing")
                .fixedSize()

            Toggle("App", isOn: appDevBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Launch Codex Desktop with BUILD_FLAVOR=dev")
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            isUsingDevMode ? Color.orange.opacity(0.10) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isUsingDevMode ? Color.orange.opacity(0.22) : Color.secondary.opacity(0.12))
        )
    }
}

struct RecentsTab: View {
    @EnvironmentObject var model: HomeportModel
    var isEditing: Bool
    var openDetail: (CodexHome) -> Void

    var pending: [LaunchedInstance] {
        model.state.instances.filter(\.cleanupReviewRequired)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !model.activeInstances.isEmpty {
                SectionLabel("Open Now")
                ForEach(model.activeInstances) { instance in
                    RecentLaunchRow(instance: instance, isEditing: isEditing, showsStatus: true)
                }
            }
            SectionLabel("Recent Opens")
            if model.recentInstances.isEmpty && model.activeInstances.isEmpty {
                EmptyState(title: "No recents", subtitle: "Launch a home and it will appear here.")
            } else if model.recentInstances.isEmpty {
                Text("Closed launches will appear here after you open more homes.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.recentInstances) { instance in
                    RecentLaunchRow(instance: instance, isEditing: isEditing)
                }
            }
            if !pending.isEmpty {
                SectionLabel("Cleanup Review")
                ForEach(pending) { instance in
                    CleanupReviewRow(instance: instance)
                }
            }
        }
    }
}

struct HomesTab: View {
    @EnvironmentObject var model: HomeportModel
    var isEditing: Bool
    var openDetail: (CodexHome) -> Void
    var requestDelete: (CodexHome) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("All Homes")
            ForEach(model.state.homes) { home in
                HomeListRow(
                    home: home,
                    subtitle: "\(model.isPinned(home) ? "Favorite" : "Not favorite") • \(kindLabel(for: home))",
                    isEditing: isEditing,
                    openDetail: { openDetail(home) },
                    launch: { target in model.launch(home.slug, target: target) },
                    editAction: home.kind == .main ? nil : { requestDelete(home) },
                    editActionHelp: home.kind == .main ? "Main home cannot be deleted" : "Review Delete"
                )
            }
            Text("Tap a row for details. App and Term are always one-tap launch actions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

struct NewHomeTab: View {
    @EnvironmentObject var model: HomeportModel
    @Binding var mode: NewHomeMode
    @Binding var launchTarget: LaunchTarget
    @Binding var customName: String
    @Binding var customNameEdited: Bool
    @Binding var customPath: String
    @Binding var customPathEdited: Bool
    @Binding var createsTemporaryHome: Bool
    var isCreating: Bool
    var suggestedName: String
    var suggestedPath: String
    var create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Temporary home", isOn: $createsTemporaryHome)
            Text("Mark this home for cleanup review after its Codex session closes. Its setup still follows the option selected below.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            SectionLabel("Create")
            VStack(spacing: 0) {
                ForEach(NewHomeMode.allCases) { candidate in
                    NewHomeModeButton(mode: candidate, isSelected: mode == candidate) {
                        mode = candidate
                        if candidate == .configOnly {
                            model.setDefaultClonePreset(.configOnly)
                        }
                    }
                    if candidate != NewHomeMode.allCases.last {
                        Divider()
                            .padding(.leading, 40)
                    }
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.13)))
            SectionLabel("Opens In")
            Picker("Opens In", selection: $launchTarget) {
                Text("Desktop App").tag(LaunchTarget.desktop)
                Text("Terminal").tag(LaunchTarget.terminal)
            }
            .pickerStyle(.segmented)
            SectionLabel("Name")
            TextField("Home name", text: Binding(
                get: { customName.isEmpty && !customNameEdited ? activeSuggestedName : customName },
                set: { value in
                    customName = value
                    customNameEdited = true
                }
            ))
                .textFieldStyle(.roundedBorder)
            SectionLabel("Path")
            TextField("CODEX_HOME path", text: Binding(
                get: { customPath.isEmpty && !customPathEdited ? suggestedPath : customPath },
                set: { value in
                    customPath = value
                    customPathEdited = true
                    if !customNameEdited {
                        customName = suggestedHomeName(fromHomePath: value) ?? suggestedName
                    }
                }
            ))
                .textFieldStyle(.roundedBorder)
            if mode.showsCloneOptions {
                SectionLabel("Clone Source")
                CloneSourceControls()
                SectionLabel("Clone Policies")
                ClonePolicyTable()
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.caption.weight(.semibold))
                    Text(mode.showsCloneOptions ? model.state.preferences.clonePolicies.summary : "Starts empty.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: create) {
                    HStack(spacing: 6) {
                        if isCreating { ProgressView().controlSize(.small) }
                        Text(isCreating ? "Creating…" : "Create")
                    }
                }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreating)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .onAppear {
            if customPath.isEmpty {
                customPath = suggestedPath
                customPathEdited = false
            }
            if customName.isEmpty {
                customName = activeSuggestedName
                customNameEdited = false
            }
        }
        .onChange(of: suggestedPath) { nextPath in
            if !customPathEdited {
                customPath = nextPath
            }
        }
        .onChange(of: suggestedName) { nextName in
            if !customNameEdited && !customPathEdited {
                customName = nextName
            }
        }
    }

    private var activeSuggestedName: String {
        if customPathEdited {
            return suggestedHomeName(fromHomePath: customPath) ?? suggestedName
        }
        return suggestedName
    }
}

struct CloneSourceControls: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: Binding(
                get: { model.state.preferences.cloneSourceSelector },
                set: { model.setCloneSourceSelector($0) }
            )) {
                Text("Main").tag("main")
                ForEach(model.state.homes.filter { $0.kind != .main }) { home in
                    Text(home.name).tag(home.slug)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ShimAppBundleCard: View {
    var status: ShimAppBundleStatus
    var isRunning: Bool
    var refreshAction: () -> Void
    var rebuildAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: status.stateSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(status.stateColor)
                    .frame(width: 24, height: 24)
                    .background(status.stateColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.stateTitle)
                        .font(.caption.weight(.semibold))
                    Text(status.stateDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: refreshAction) {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 28, height: 26)
                }
                .buttonStyle(.plain)
                .help("Refresh shimmable app status")
                .disabled(isRunning || status.isChecking)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ShimAppBundleRow(
                    title: "Source Codex",
                    path: status.sourcePath,
                    version: status.sourceVersion,
                    hash: status.sourceHash,
                    exists: status.sourceExists
                )
                ShimAppBundleRow(
                    title: "Shim Copy",
                    path: status.destinationPath,
                    version: status.destinationVersion,
                    hash: status.destinationHash,
                    exists: status.destinationExists
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Label(status.patched ? "ASAR patch matched" : "ASAR patch missing", systemImage: status.patched ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.patched ? .blue : .orange)
                    Label(status.stale ? "Rebuild needed" : "Current", systemImage: status.stale ? "arrow.triangle.2.circlepath" : "checkmark.circle.fill")
                        .foregroundStyle(status.stale ? .orange : .blue)
                }
                Label("Browser launch mode", systemImage: "network")
                    .foregroundStyle(.blue)
            }
            .font(.caption2.weight(.semibold))
            .lineLimit(1)

            Text("The copied app is launched as dev flavor with in-app Browser features enabled, avoiding copied-bundle peer signing.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            if let preparedAt = status.preparedAt {
                Text("Prepared \(preparedAt)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let error = status.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(4)
                    .textSelection(.enabled)
            }

            Button(action: rebuildAction) {
                Label("Repair Shim App", systemImage: "wrench.and.screwdriver")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Rebuild the copied app and refresh shim diagnostics")
            .disabled(isRunning)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(status.stateColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(status.stateColor.opacity(0.18)))
    }
}

struct ShimAppBundleRow: View {
    var title: String
    var path: String
    var version: String
    var hash: String
    var exists: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(exists ? version : "missing")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if !hash.isEmpty {
                    Text(hash)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            Text(path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

struct ProviderLoginRow: View {
    var provider: ShimLoginProvider
    var status: ShimProviderStatus
    var terminalName: String
    @Binding var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: provider.symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? status.state.color : .secondary)
                .frame(width: 24, height: 24)
                .background((isEnabled ? status.state.color : Color.secondary).opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(provider.title)
                        .font(.caption.weight(.semibold))
                    Label(isEnabled ? status.state.label : "Disabled", systemImage: isEnabled ? status.state.symbol : "pause.circle")
                        .labelStyle(.titleAndIcon)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isEnabled ? status.state.color : .secondary)
                        .lineLimit(1)
                }
                Text(isEnabled ? status.detail : "Not used by generated shim config")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            Toggle("", isOn: $isEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help(isEnabled ? "Disable \(provider.title) for shim" : "Enable \(provider.title) for shim")
            Button(action: action) {
                Label("Login", systemImage: "terminal")
                    .labelStyle(.iconOnly)
                    .font(.caption.weight(.semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open \(provider.title) login in \(terminalName)")
        }
        .padding(9)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.15)))
    }
}

struct SettingsTab: View {
    @EnvironmentObject var model: HomeportModel
    var openConsole: () -> Void
    var quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LaunchHealthBanner()
            SectionLabel("Defaults")
            Picker("Open main in", selection: Binding(
                get: { model.state.preferences.defaultLaunchTarget },
                set: { model.setDefaultLaunchTarget($0) }
            )) {
                Text("Desktop App").tag(LaunchTarget.desktop)
                Text("Terminal").tag(LaunchTarget.terminal)
            }
            .pickerStyle(.segmented)
            Toggle("Prefer temporary launches", isOn: Binding(
                get: { model.state.preferences.launchTemporaryByDefault },
                set: { model.setLaunchTemporaryByDefault($0) }
            ))
            Toggle("Install app by default", isOn: .constant(model.state.preferences.installAppByDefault))
                .disabled(true)
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Allow full Computer Use targets", isOn: Binding(
                    get: { model.allowForbiddenComputerUseTargets ?? model.state.preferences.allowForbiddenComputerUseTargetsByDefault },
                    set: { model.setAllowForbiddenComputerUseTargets($0) }
                ))
                Text(computerUseTargetsDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Browser local testing mode", isOn: Binding(
                    get: { model.state.preferences.browserUseLocalTestingMode },
                    set: { model.setBrowserUseLocalTestingMode($0) }
                ))
                Text("Launches Codex with BROWSER_USE_SECURITY_MODE=disabled-for-local-testing for local browser automation testing.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Desktop app dev flavor", isOn: Binding(
                    get: { model.state.preferences.desktopAppDevFlavor },
                    set: { model.setDesktopAppDevFlavor($0) }
                ))
                Text("Launches Codex Desktop with BUILD_FLAVOR=dev to expose app developer and debug UI.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            SectionLabel("Model Routing")
            ShimSetupCard()
            SectionLabel("Install")
            AutoUpdaterCard()
            InfoCard(title: "Version", subtitle: "\(AppVersion.version) (\(AppVersion.build)) • \(model.channel.rawValue)")
            HStack {
                Button("Open Console", action: openConsole)
                Spacer()
                Button("Quit Multihome", action: quit)
            }
            .buttonStyle(.bordered)
            Button("Reset Defaults") {
                model.resetDefaults()
            }
            .buttonStyle(.bordered)
        }
    }

    private var computerUseTargetsDetail: String {
        switch model.allowForbiddenComputerUseTargets {
        case .some(true):
            return "macOS global default is enabled for Apple Computer Use target access."
        case .some(false):
            return "macOS global default is disabled. Some app-control targets may stay unavailable."
        case .none:
            return "macOS global default is unset. Onboarding enables it unless configured off."
        }
    }
}

struct ShimSetupCard: View {
    @EnvironmentObject var model: HomeportModel
    @State private var executablePath = ""
    @State private var port = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Machine-wide setup for per-home model routing. Turn routing on per home from that home's detail page.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            ShimAppBundleCard(
                status: model.shimAppBundleStatus,
                isRunning: model.isRunningShimCommand,
                refreshAction: {
                    model.refreshShimAppBundleStatus(executablePath: model.state.preferences.shimExecutablePath)
                },
                rebuildAction: {
                    model.rebuildShimAppBundle(executablePath: model.state.preferences.shimExecutablePath)
                }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Shim executable override")
                    .font(.caption.weight(.semibold))
                TextField(model.defaultShimExecutablePath(), text: $executablePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { model.setShimExecutablePath(executablePath) }
                HStack(spacing: 8) {
                    Text("Port")
                        .font(.caption.weight(.semibold))
                    TextField("8765", text: $port)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .frame(width: 92)
                        .onSubmit { model.setShimPort(port) }
                    Spacer()
                    Button("Save") {
                        model.setShimExecutablePath(executablePath)
                        model.setShimPort(port)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Text("Leave blank to use Multihome’s bundled shim. Set a path only to override it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            executablePath = model.state.preferences.shimExecutablePath
            port = model.state.preferences.shimPort
            model.refreshShimAppBundleStatus(executablePath: model.state.preferences.shimExecutablePath)
        }
    }
}

struct AutoUpdaterCard: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: model.updateAvailable ? "arrow.down.circle.fill" : "arrow.triangle.2.circlepath")
                    .foregroundStyle(model.updateAvailable ? .blue : .primary)
                    .frame(width: 26, height: 26)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.caption.weight(.semibold))
                    Text(statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.updateAvailable {
                    VStack(spacing: 6) {
                        Button(model.isInstallingUpdate ? "Updating" : "Update") {
                            model.installUpdate()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isInstallingUpdate)
                        Button("Later") {
                            model.dismissUpdate()
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }
                } else {
                    Button(model.isCheckingForUpdates ? "Checking" : "Check Now") {
                        model.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isCheckingForUpdates)
                }
            }

            if let lastError = model.state.updater.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            Toggle("Check for updates", isOn: Binding(
                get: { model.state.preferences.autoUpdateChecksEnabled },
                set: { model.setAutoUpdateChecksEnabled($0) }
            ))

            Picker("Schedule", selection: Binding(
                get: { model.state.preferences.updateCheckInterval },
                set: { model.setUpdateCheckInterval($0) }
            )) {
                ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
                    Text(interval.displayName).tag(interval)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!model.state.preferences.autoUpdateChecksEnabled)

            Toggle("Install updates automatically", isOn: Binding(
                get: { model.state.preferences.autoInstallUpdates },
                set: { model.setAutoInstallUpdates($0) }
            ))
            .disabled(!model.state.preferences.autoUpdateChecksEnabled)

            Text("Manual path: npm install -g codex-multihome@latest && homeport update --with-app")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(model.updateAvailable ? Color.blue.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.updateAvailable ? Color.blue.opacity(0.28) : Color.secondary.opacity(0.15)))
    }

    private var headline: String {
        if let latestVersion = model.state.updater.latestVersion, model.updateAvailable {
            return "Multihome \(latestVersion) is available"
        }
        return "Auto Updater"
    }

    private var statusText: String {
        if model.updateAvailable {
            return "Install from npm when you choose"
        }
        if model.state.preferences.autoInstallUpdates {
            return "\(model.state.preferences.updateCheckInterval.displayName) checks, automatic install"
        }
        if model.state.preferences.autoUpdateChecksEnabled {
            return "\(model.state.preferences.updateCheckInterval.displayName) checks, notify before install"
        }
        return "Manual updates only"
    }
}

struct FocusedHomeView: View {
    @EnvironmentObject var model: HomeportModel
    var home: CodexHome
    var isEditing: Bool
    @Binding var editedName: String
    @Binding var editedHomePath: String
    @Binding var moveFoldersOnRename: Bool
    @Binding var moveHomePathOnEdit: Bool
    var launch: (LaunchTarget) -> Void
    var setPinned: (Bool) -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HomeDetailHero(
                home: home,
                isPinned: model.isPinned(home),
                isEditing: isEditing,
                editedName: $editedName,
                moveFoldersOnRename: $moveFoldersOnRename,
                authSummary: model.authSummary(for: home),
                icon: homeKindIcon(for: home),
                launch: launch
            )

            SectionLabel("Home")
            VStack(spacing: 6) {
                if isEditing && home.kind != .main {
                    EditableDetailInfoRow(symbol: "folder", title: "Path", text: $editedHomePath)
                } else {
                    DetailInfoRow(symbol: "folder", title: "Path", subtitle: home.homePath)
                }
                DetailInfoRow(symbol: "key.fill", title: "Auth", subtitle: model.authSummary(for: home))
                DetailInfoRow(symbol: "arrow.triangle.branch", title: "Clone Source", subtitle: home.sourceHomePath ?? (home.kind == .main ? "This is your main Codex home" : "No inherited files"))
                if let policies = home.clonePolicies {
                    DetailInfoRow(symbol: "slider.horizontal.3", title: "Clone Policies", subtitle: policies.summary)
                } else if let materialization = home.cloneMaterialization {
                    DetailInfoRow(symbol: "doc.on.doc", title: "Clone Mode", subtitle: materialization.displayName)
                }
                let missingLinks = model.brokenLinkedTargets[home.id] ?? []
                if !missingLinks.isEmpty {
                    DetailInfoRow(symbol: "link.badge.plus", title: "Linked Paths Missing", subtitle: missingLinks.joined(separator: ", "), tint: .orange)
                }
            }

            SectionLabel("Model Routing")
            ModelRoutingPanel(home: home)

            SectionLabel("Manage")
            HomeManagePanel(
                home: home,
                isEditing: isEditing,
                isPinned: model.isPinned(home),
                moveFoldersOnRename: $moveFoldersOnRename,
                moveHomePathOnEdit: $moveHomePathOnEdit,
                setPinned: setPinned,
                delete: delete
            )
        }
    }
}

struct HomeDetailHero: View {
    var home: CodexHome
    var isPinned: Bool
    var isEditing: Bool
    @Binding var editedName: String
    @Binding var moveFoldersOnRename: Bool
    var authSummary: String
    var icon: String
    var launch: (LaunchTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 48, height: 48)
                    .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if isEditing && home.kind != .main {
                            TextField("Home name", text: $editedName)
                                .font(.title3.weight(.bold))
                                .textFieldStyle(.roundedBorder)
                                .frame(minWidth: 120)
                        } else {
                            Text(home.name)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)
                        }
                        if isPinned {
                            Image(systemName: "star.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.yellow)
                        }
                    }
                    Text("\(kindLabel(for: home)) • \(isPinned ? "Favorite" : "Not favorite")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        HomeTags(home: home)
                        HomeAuthTag(home: home)
                    }
                }
                Spacer(minLength: 0)
            }

            Text(authSummary)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            HStack {
                LaunchActionPair(launch: launch)
                Spacer()
                Text(home.slug)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(12)
        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.blue.opacity(0.18)))
    }
}

struct DetailInfoRow: View {
    var symbol: String
    var title: String
    var subtitle: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct EditableDetailInfoRow: View {
    var symbol: String
    var title: String
    @Binding var text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                TextField(title, text: $text)
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct ModelRoutingPanel: View {
    @EnvironmentObject var model: HomeportModel
    var home: CodexHome
    @State private var catalogSummary = "Checking available models…"

    private var isEnabled: Bool {
        model.routingEnabled(for: home)
    }

    private var providers: Set<ShimLoginProvider> {
        model.routingProviders(for: home)
    }

    private var catalogKey: String {
        let providerKey = providers.map(\.rawValue).sorted().joined(separator: ",")
        return "\(isEnabled)|\(providerKey)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { isEnabled },
                set: { model.setRoutingEnabled($0, for: home) }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isEnabled ? .indigo : .secondary)
                        .frame(width: 24, height: 24)
                        .background((isEnabled ? Color.indigo : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Route models through shim")
                            .font(.caption.weight(.semibold))
                        Text(isEnabled ? "App and Term launches wire the shim first" : "Launches use this home's normal models")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(model.isRunningShimCommand)

            if isEnabled {
                Divider()

                VStack(spacing: 6) {
                    ForEach(ShimLoginProvider.allCases) { provider in
                        ProviderLoginRow(
                            provider: provider,
                            status: model.providerStatus(provider, home: home),
                            terminalName: model.state.preferredTerminal.displayName,
                            isEnabled: Binding(
                                get: { providers.contains(provider) },
                                set: { model.setRoutingProvider(provider, enabled: $0, for: home) }
                            )
                        ) {
                            model.loginWithProviderCLI(provider, home: home)
                        }
                        .disabled(model.isRunningShimCommand)
                    }
                }

                Text(catalogSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack(spacing: 8) {
                    Button {
                        model.openRoutingPicker(for: home)
                    } label: {
                        Label("Model Picker", systemImage: "slider.horizontal.3")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        model.restartRouting(for: home)
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Restart and rewire the shim for this home")
                    Button {
                        model.checkRoutingStatus(for: home)
                    } label: {
                        Label("Status", systemImage: "waveform.path.ecg")
                    }
                    .buttonStyle(.bordered)
                    .help("Read the running shim daemon state")
                }
                .controlSize(.small)
                .disabled(model.isRunningShimCommand)

                if model.isRunningShimCommand || model.shimStatus != "Ready" {
                    Text(model.shimStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .onAppear {
            if isEnabled {
                model.refreshShimProviderStatuses(home: home)
            }
        }
        .task(id: catalogKey) {
            guard isEnabled else { return }
            catalogSummary = "Checking available models…"
            let key = catalogKey
            let enabledProviders = providers
            let summary = await Task.detached {
                Self.summaryText(for: buildShimCatalogPlan(
                    enabledProviders: enabledProviders,
                    environment: ProcessInfo.processInfo.environment
                ))
            }.value
            // The detached work outlives .task cancellation; drop results for superseded configs.
            guard !Task.isCancelled, key == catalogKey else { return }
            catalogSummary = summary
        }
    }

    private nonisolated static func summaryText(for plan: ShimCatalogPlan) -> String {
        if plan.included.isEmpty {
            return "Enable at least one provider to publish models."
        }
        var text = "Publishes \(plan.included.joined(separator: " + "))"
        if !plan.skipped.isEmpty {
            text += " • Skipped: \(plan.skipped.joined(separator: ", "))"
        }
        return text
    }
}

struct HomeManagePanel: View {
    var home: CodexHome
    var isEditing: Bool
    var isPinned: Bool
    @Binding var moveFoldersOnRename: Bool
    @Binding var moveHomePathOnEdit: Bool
    var setPinned: (Bool) -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { isPinned },
                set: { setPinned($0) }
            )) {
                HStack(spacing: 10) {
                    Image(systemName: isPinned ? "star.fill" : "star")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isPinned ? .yellow : .secondary)
                        .frame(width: 24, height: 24)
                        .background((isPinned ? Color.yellow : Color.secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Favorite")
                            .font(.caption.weight(.semibold))
                        Text(isPinned ? "Shown in the Favorites list" : "Pin this home for faster launch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .toggleStyle(.switch)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isEditing && home.kind != .main {
                Toggle(isOn: $moveFoldersOnRename) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Move folders to match name")
                            .font(.caption.weight(.semibold))
                        Text("Renames the managed home and app profile folders.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .toggleStyle(.switch)
                Toggle(isOn: $moveHomePathOnEdit) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Move existing home to path")
                            .font(.caption.weight(.semibold))
                        Text("Off means the new path must already contain a Codex home.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .toggleStyle(.switch)
                Button("Review Delete", role: .destructive, action: delete)
                    .buttonStyle(.bordered)
            } else {
                Text(home.kind == .main ? "The main home cannot be renamed or deleted." : "Use Edit to rename or review deletion.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct HomeListRow: View {
    var home: CodexHome
    var subtitle: String
    var isEditing: Bool
    var openDetail: () -> Void
    var launch: (LaunchTarget) -> Void
    var editAction: (() -> Void)? = nil
    var editActionHelp: String = "Edit"

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                if let editAction {
                    Button(action: editAction) {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.red)
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(.plain)
                    .help(editActionHelp)
                } else {
                    Image(systemName: "lock.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .help(editActionHelp)
                }
            }
            Button(action: openDetail) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(home.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        HomePillStrip(home: home)
                    }
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open details for \(home.name)")
            LaunchActionPair(launch: launch)
                .opacity(isEditing ? 0.45 : 1)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

struct TagChip: View {
    var label: String
    var symbol: String
    var color: Color
    var compact = false
    var backgroundOpacity: Double = 0.12

    var body: some View {
        Group {
            if compact {
                Label(label, systemImage: symbol)
                    .labelStyle(.iconOnly)
            } else {
                Label(label, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(color)
        .lineLimit(1)
        .fixedSize()
        .padding(.horizontal, compact ? 4 : 5)
        .padding(.vertical, 2)
        .background(color.opacity(backgroundOpacity), in: RoundedRectangle(cornerRadius: 5))
        .help(label)
    }
}

struct HomeKindTag: View {
    var home: CodexHome

    var body: some View {
        TagChip(
            label: kindLabel(for: home),
            symbol: homeKindIcon(for: home),
            color: .secondary,
            backgroundOpacity: 0.08
        )
        .help("Home type: \(kindLabel(for: home))")
    }
}

struct HomePillStrip: View {
    @EnvironmentObject var model: HomeportModel
    var home: CodexHome
    var showsOpenStatus = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                HomeKindTag(home: home)
                HomeTags(home: home)
                HomeAuthTag(home: home)
                if showsOpenStatus {
                    TagChip(label: "Open", symbol: "circle.fill", color: .green)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 22)
        .help("Home details. Scroll horizontally to see additional labels.")
    }
}

struct HomeTags: View {
    var home: CodexHome
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags, id: \.label) { tag in
                TagChip(label: tag.label, symbol: tag.symbol, color: tag.color)
            }
        }
    }

    private var tags: [(label: String, symbol: String, color: Color)] {
        var tags: [(label: String, symbol: String, color: Color)] = []
        if home.modelRouting?.isEnabled == true {
            tags.append(("Routed", "point.3.connected.trianglepath.dotted", .indigo))
        }
        if let policies = home.clonePolicies {
            if policies.linkedCategoryCount > 0 {
                tags.append(("\(policies.linkedCategoryCount) linked", "link", policies.auth == .link ? .orange : .blue))
            }
            if policies.copiedCategoryCount > 0 && policies.linkedCategoryCount > 0 {
                tags.append(("\(policies.copiedCategoryCount) copied", "doc.on.doc", .secondary))
            }
            return tags
        }
        switch home.cloneMaterialization {
        case .linkSafeCustomizations:
            tags.append(("Linked", "link", .blue))
        case .linkSafeCustomizationsAndAuth:
            tags.append(("Auth linked", "key.fill", .orange))
        case .copy, nil:
            break
        }
        return tags
    }
}

struct HomeAuthTag: View {
    @EnvironmentObject var model: HomeportModel
    var home: CodexHome
    var body: some View {
        TagChip(
            label: display.label,
            symbol: display.symbol,
            color: display.color,
            backgroundOpacity: display.backgroundOpacity
        )
        .help("Sign-in status: \(display.label)")
    }

    private var display: (label: String, symbol: String, color: Color, backgroundOpacity: Double) {
        let status = model.authStatus(for: home)
        if status.isLoggedIn {
            return (status.accountLabel ?? "Logged in", "checkmark.seal.fill", .blue, 0.12)
        }
        if status.hasStoredCredentials {
            return (status.accountLabel ?? "Stored auth", "key.fill", .secondary, 0.10)
        }
        return ("No auth", "key.slash", .secondary, 0.06)
    }
}

struct RecentLaunchRow: View {
    @EnvironmentObject var model: HomeportModel
    var instance: LaunchedInstance
    var isEditing: Bool
    var showsStatus: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(instance.homeName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let home = resolvedHome {
                        HomePillStrip(home: home, showsOpenStatus: showsStatus)
                    } else if showsStatus {
                        TagChip(label: "Open", symbol: "circle.fill", color: .green)
                    }
                }
                Text("\(targetLabel(instance.target)) • \(relativeTime(instance.launchedAt)) • \(instance.workspacePath ?? "no workspace")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help("Recent launch for \(instance.homeName)")
            LaunchActionPair { target in
                model.launchRecent(instance, target: target)
            }
            .opacity(isEditing ? 0.45 : 1)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private var resolvedHome: CodexHome? {
        model.state.homes.first { $0.id == instance.homeID }
    }
}

struct CleanupReviewRow: View {
    @EnvironmentObject var model: HomeportModel
    var instance: LaunchedInstance

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(instance.homeName)
                        .font(.caption.weight(.semibold))
                    Text("Disposable home • review before moving to Trash")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                LaunchActionPair { target in
                    model.launchRecent(instance, target: target)
                }
            }
            HStack {
                Button("Promote") {
                    model.promote(instance)
                }
                Button("Review Delete", role: .destructive) {
                    model.cleanup(instance)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct LaunchActionPair: View {
    var launch: (LaunchTarget) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                launch(.desktop)
            } label: {
                Label("App", systemImage: "macwindow")
                    .labelStyle(.titleAndIcon)
            }
            .help("Open in Codex app")
            Button {
                launch(.terminal)
            } label: {
                Label("Term", systemImage: "terminal")
                    .labelStyle(.titleAndIcon)
            }
            .help("Open in Terminal")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct NewHomeModeButton: View {
    var mode: NewHomeMode
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: mode.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isSelected ? .blue : .secondary)
                    .frame(width: 20, height: 20)
                    .background(isSelected ? Color.blue.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(mode.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ClonePolicyTable: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ClonePolicyPresetGrid()
            ForEach(CloneCategoryGroup.allCases, id: \.rawValue) { group in
                PolicyGroup(title: group.displayName, warningText: group.warningText) {
                    ForEach(categories(in: group)) { category in
                        policyRow(category)
                    }
                }
            }
        }
    }

    private func categories(in group: CloneCategoryGroup) -> [CloneCategory] {
        CloneCategory.allCases.filter { $0.group == group }
    }

    private func policyRow(_ category: CloneCategory) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(category.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(category.pathSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                policyButton(.skip, category)
                policyButton(.copy, category)
                policyButton(.link, category)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.18)))
        }
        .frame(maxWidth: .infinity, minHeight: 38)
    }

    private func policyButton(
        _ policy: ClonePolicy,
        _ category: CloneCategory
    ) -> some View {
        let selected = model.state.preferences.clonePolicies[category] == policy
        let disabled = policy == .link && !category.canLink
        return Button(policy.displayName) {
            model.updateClonePolicies { policies in
                policies[category] = policy
            }
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(disabled ? Color.secondary.opacity(0.5) : (selected ? Color.white : Color.primary))
        .frame(width: 42, height: 24)
        .background(selected ? Color.blue : Color.clear)
        .disabled(disabled)
        .help(disabled ? "Link is not available for this category" : policy.displayName)
    }
}

struct ClonePolicyPresetGrid: View {
    @EnvironmentObject var model: HomeportModel

    private let columns = [
        GridItem(.adaptive(minimum: 78), spacing: 6)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            if let last = model.state.preferences.lastClonePolicies {
                presetButton("Last", symbol: "clock.arrow.circlepath", policies: last)
            } else {
                disabledPresetButton("Last", symbol: "clock.arrow.circlepath")
            }
            presetButton("Working", symbol: "doc.on.doc", policies: .workingSetup)
            presetButton("Config", symbol: "gearshape", policies: .configOnly)
            presetButton(
                "Link Safe",
                symbol: "link",
                policies: ClonePolicies(options: .workingSetup, materialization: .linkSafeCustomizations)
            )
            presetButton(
                "Link Auth",
                symbol: "key",
                policies: ClonePolicies(options: .workingSetup, materialization: .linkSafeCustomizationsAndAuth)
            )
            presetButton("Everything", symbol: "archivebox", policies: .full)
            presetButton("Empty", symbol: "nosign", policies: .empty)
        }
    }

    private func presetButton(_ label: String, symbol: String, policies: ClonePolicies) -> some View {
        let selected = model.state.preferences.clonePolicies == policies
        return Button {
            model.applyClonePolicies(policies, statusMessage: "Saved \(label) preset")
        } label: {
            Label(label, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(selected ? .blue : nil)
    }

    private func disabledPresetButton(_ label: String, symbol: String) -> some View {
        Label(label, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 7)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            .opacity(0.6)
            .help("No previous custom policy yet")
    }
}

struct PolicyGroup<Content: View>: View {
    var title: String
    var warningText: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                content
            }
            if let warningText {
                Text(warningText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(warningText == nil ? Color.secondary.opacity(0.08) : Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LaunchHealthBanner: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        if model.report.globalCodexHome != nil || !model.report.suspiciousLaunchers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Launch environment needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                Text("Multihome found state that can open the wrong Codex home.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("Repair Launch Environment") {
                    model.repair()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(10)
            .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
        } else {
            InfoCard(title: "Launch health appears good", subtitle: "No global CODEX_HOME or stale launcher was detected.")
        }
    }
}

struct InfoCard: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct EmptyState: View {
    var title: String
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct SectionLabel: View {
    var title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

private func kindLabel(for home: CodexHome) -> String {
    switch home.kind {
    case .main: "Normal home"
    case .clone: "Copied home"
    case .cleanRoom: "Clean room"
    case .temporary: "Temporary home"
    }
}

private func homeKindIcon(for home: CodexHome) -> String {
    switch home.kind {
    case .main: "house.fill"
    case .clone: "square.on.square"
    case .cleanRoom: "sparkles"
    case .temporary: "timer"
    }
}

private func targetLabel(_ target: LaunchTarget) -> String {
    target == .desktop ? "Desktop App" : "Terminal"
}

private func relativeTime(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

struct HomeportConsoleView: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        NavigationSplitView {
            List {
                Section("Homes") {
                    ForEach(model.state.homes) { home in
                        VStack(alignment: .leading) {
                            Text(home.name)
                            Text(home.slug)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Multihome")
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    ConsoleHeader()
                    ConsoleCopySettings()
                    PinnedConsoleSection()
                    RecentConsoleSection()
                    HomeGrid()
                    CleanupReview()
                    DiagnosticsPanel()
                }
                .padding(24)
            }
        }
    }
}

struct ConsoleCopySettings: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Copy Settings")
                .font(.title2.weight(.semibold))
            Text("These options control what “Make a saved copy of my current setup” includes.")
                .foregroundStyle(.secondary)
            Picker("Copy preset", selection: Binding(
                get: { model.state.preferences.defaultClonePreset },
                set: { model.setDefaultClonePreset($0) }
            )) {
                ForEach(ClonePreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }
            .frame(maxWidth: 360)
            ClonePolicyTable()
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ConsoleHeader: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Multihome Console")
                .font(.largeTitle.weight(.bold))
            Text("Launch, clone, inspect, and clean up Codex homes without leaking global environment state.")
                .foregroundStyle(.secondary)
            TextField("Workspace path", text: $model.workspacePath)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 640)
        }
    }
}

struct HomeGrid: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
            ForEach(model.state.homes) { home in
                HomeCard(home: home)
            }
        }
    }
}

struct HomeCard: View {
    @EnvironmentObject var model: HomeportModel
    @State private var editedName: String = ""
    @State private var editedPath: String = ""
    @State private var moveFoldersOnRename = false
    @State private var moveHomePathOnSave = false

    var home: CodexHome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(home.name, systemImage: homeKindIcon(for: home))
                    .font(.headline)
                Spacer()
                Button {
                    model.setHomePinned(home, pinned: !model.isPinned(home))
                } label: {
                    Image(systemName: model.isPinned(home) ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                Text(home.kind.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            if home.kind != .main {
                HStack {
                    TextField("Name", text: $editedName)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        saveEdits()
                        moveFoldersOnRename = false
                        moveHomePathOnSave = false
                    }
                    .disabled(saveDisabled)
                }
                Toggle("Move folders to match name", isOn: $moveFoldersOnRename)
                TextField("CODEX_HOME path", text: $editedPath)
                    .textFieldStyle(.roundedBorder)
                Toggle("Move existing home to path", isOn: $moveHomePathOnSave)
            }

            Text(home.homePath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack {
                Button("Desktop") {
                    model.launch(home.slug, target: .desktop)
                }
                Button("Terminal") {
                    model.launch(home.slug, target: .terminal)
                }
                if home.kind != .main {
                    Spacer()
                    Button("Trash", role: .destructive) {
                        model.deleteHome(home)
                    }
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.quaternary)
        )
        .onAppear {
            editedName = home.name
            editedPath = home.homePath
            moveFoldersOnRename = false
            moveHomePathOnSave = false
        }
        .onChange(of: home.name) { newName in
            editedName = newName
            editedPath = home.homePath
            moveFoldersOnRename = false
            moveHomePathOnSave = false
        }
    }

    private var saveDisabled: Bool {
        let trimmedPath = editedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || trimmedPath.isEmpty
            || (editedName == home.name && !moveFoldersOnRename && trimmedPath == home.homePath)
    }

    private func saveEdits() {
        let trimmedPath = editedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let nameChanged = editedName != home.name || moveFoldersOnRename
        if nameChanged {
            model.renameHome(home, name: editedName, moveFolders: moveFoldersOnRename)
        }
        let refreshedHome = model.state.homes.first { $0.id == home.id } ?? home
        if trimmedPath != home.homePath {
            model.changeHomePath(refreshedHome, homePath: trimmedPath, moveExisting: moveHomePathOnSave)
        }
    }
}

struct PinnedConsoleSection: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        if !model.pinnedHomes.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Pinned")
                    .font(.title2.weight(.semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(model.pinnedHomes) { home in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(home.name, systemImage: "pin.fill")
                                    .font(.headline)
                                Text(home.slug)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                HStack {
                                    Button("Desktop") {
                                        model.launch(home.slug, target: .desktop)
                                    }
                                    Button("Terminal") {
                                        model.launch(home.slug, target: .terminal)
                                    }
                                }
                            }
                            .frame(width: 240, alignment: .leading)
                            .padding(12)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
    }
}

struct RecentConsoleSection: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        if !model.activeInstances.isEmpty || !model.recentInstances.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Instances")
                    .font(.title2.weight(.semibold))
                VStack(spacing: 8) {
                    ForEach(model.activeInstances) { instance in
                        ConsoleInstanceRow(instance: instance, isActive: true)
                    }
                    ForEach(model.recentInstances) { instance in
                        ConsoleInstanceRow(instance: instance, isActive: false)
                    }
                }
            }
        }
    }
}

struct ConsoleInstanceRow: View {
    @EnvironmentObject var model: HomeportModel
    var instance: LaunchedInstance
    var isActive: Bool

    var body: some View {
        HStack {
            Image(systemName: instance.target == .desktop ? "macwindow" : "terminal")
            VStack(alignment: .leading) {
                HStack(spacing: 6) {
                    Text(instance.homeName)
                        .font(.headline)
                    if isActive {
                        Text("Open")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Text("\(instance.target.rawValue) • \(instance.workspacePath ?? "no workspace")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Launch") {
                model.launchRecent(instance)
            }
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

struct CleanupReview: View {
    @EnvironmentObject var model: HomeportModel

    var pending: [LaunchedInstance] {
        model.state.instances.filter(\.cleanupReviewRequired)
    }

    var body: some View {
        if !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cleanup Review")
                    .font(.title2.weight(.semibold))
                ForEach(pending) { instance in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(instance.homeName)
                                .font(.headline)
                            Text(instance.homePath)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Promote") {
                            model.promote(instance)
                        }
                        Button("Delete") {
                            model.cleanup(instance)
                        }
                    }
                    .padding(12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

struct DiagnosticsPanel: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Diagnostics")
                .font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("GUI CODEX_HOME").foregroundStyle(.secondary)
                    Text(model.report.globalCodexHome ?? "not set")
                }
                GridRow {
                    Text("Main sessions").foregroundStyle(.secondary)
                    Text("\(model.report.mainSessionCount)")
                }
                GridRow {
                    Text("Codex Desktop").foregroundStyle(.secondary)
                    Text(model.report.codexAppPath ?? "missing")
                }
                GridRow {
                    Text("codex CLI").foregroundStyle(.secondary)
                    Text(model.report.codexBinaryPath ?? "missing")
                }
                GridRow {
                    Text("Main auth").foregroundStyle(.secondary)
                    Text(model.report.authStatus.statusDisplay)
                }
                GridRow {
                    Text("Auth mode").foregroundStyle(.secondary)
                    Text(model.report.authStatus.modeDisplay ?? "unknown")
                }
                GridRow {
                    Text("Account").foregroundStyle(.secondary)
                    Text(model.report.authStatus.accountLabel ?? "unknown")
                }
                GridRow {
                    Text("Usage").foregroundStyle(.secondary)
                    Text(model.report.authStatus.usageSummary ?? "unknown")
                }
            }
            if !model.report.suspiciousLaunchers.isEmpty {
                Text("Suspicious launchers")
                    .font(.headline)
                ForEach(model.report.suspiciousLaunchers, id: \.self) { launcher in
                    Text(launcher)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }
}

private extension CodexAuthStatus {
    var statusDisplay: String {
        if isLoggedIn {
            return "logged in"
        }
        if hasStoredCredentials {
            return "stored"
        }
        return "not found"
    }
}
