import SwiftUI
import HomeportCore

@main
struct CodexHomeportApp: App {
    @StateObject private var model = HomeportModel()

    var body: some Scene {
        MenuBarExtra("Codex Homeport", systemImage: model.menuIcon) {
            HomeportMenuView()
                .environmentObject(model)
                .frame(width: 340)
        }
        .menuBarExtraStyle(.window)

        Window("Homeport Console", id: "console") {
            HomeportConsoleView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 560)
        }
    }
}

@MainActor
final class HomeportModel: ObservableObject {
    @Published var state = HomeportState()
    @Published var report = DiagnosticReport(globalCodexHome: nil, mainSessionCount: 0, suspiciousLaunchers: [], codexBinaryPath: nil, codexAppExists: false, notes: [])
    @Published var status = "Ready"
    @Published var workspacePath = FileManager.default.currentDirectoryPath

    let service = HomeportService()

    var menuIcon: String {
        report.globalCodexHome == nil && report.suspiciousLaunchers.isEmpty ? "sailboat" : "exclamationmark.triangle"
    }

    var pinnedHomes: [CodexHome] {
        state.pinnedHomeIDs.compactMap { id in
            state.homes.first { $0.id == id }
        }
    }

    var recentInstances: [LaunchedInstance] {
        Array(state.instances.prefix(6))
    }

    init() {
        refresh()
    }

    func refresh(statusMessage: String? = nil) {
        do {
            state = try service.loadState()
            report = service.report()
            workspacePath = state.lastWorkspacePath ?? workspacePath
            status = statusMessage ?? "Ready"
        } catch {
            status = error.localizedDescription
        }
    }

    func launch(_ selector: String, target: LaunchTarget) {
        do {
            let actualSelector = modelSelector(for: selector)
            let instance = try service.launch(selector: actualSelector, target: target, workspace: workspacePath)
            refresh(statusMessage: "Opened \(instance.homeName) in \(target.rawValue)")
        } catch {
            status = error.localizedDescription
        }
    }

    func launchPreferred() {
        let selector = state.preferences.launchTemporaryByDefault ? "temp" : "main"
        launch(selector, target: state.preferences.defaultLaunchTarget)
    }

    func launchRecent(_ instance: LaunchedInstance) {
        let selector = state.homes.first(where: { $0.id == instance.homeID })?.slug ?? instance.homeName
        launch(selector, target: instance.target)
    }

    func cloneWorkingSetup() {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            _ = try service.clone(
                name: "Working Setup \(formatter.string(from: Date()))",
                preset: state.preferences.defaultClonePreset,
                options: state.preferences.cloneOptions
            )
            refresh(statusMessage: "Created copied home")
        } catch {
            status = error.localizedDescription
        }
    }

    func cleanRoom() {
        do {
            _ = try service.createCleanRoom()
            refresh(statusMessage: "Created fresh home")
        } catch {
            status = error.localizedDescription
        }
    }

    func createTemporaryHome() {
        do {
            _ = try service.createTemporary()
            refresh(statusMessage: "Created temporary home")
        } catch {
            status = error.localizedDescription
        }
    }

    func renameHome(_ home: CodexHome, name: String) {
        do {
            try service.renameHome(id: home.id, name: name)
            refresh(statusMessage: "Renamed \(home.name)")
        } catch {
            status = error.localizedDescription
        }
    }

    func deleteHome(_ home: CodexHome) {
        do {
            _ = try service.deleteHome(id: home.id)
            refresh(statusMessage: "Moved \(home.name) to Trash")
        } catch {
            status = error.localizedDescription
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
            next.preferences.defaultClonePreset = preset
            next.preferences.cloneOptions = .preset(preset)
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

    func updateCloneOptions(_ transform: (inout CloneOptions) -> Void) {
        do {
            var next = try service.loadState()
            transform(&next.preferences.cloneOptions)
            try service.saveState(next)
            refresh(statusMessage: "Saved copy options")
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

    private func modelSelector(for selector: String) -> String {
        selector == "preferred" ? (state.preferences.launchTemporaryByDefault ? "temp" : "main") : selector
    }
}

struct HomeportMenuView: View {
    @EnvironmentObject var model: HomeportModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex Homeport")
                        .font(.headline)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }

            FormSection(
                title: "1. Open Codex Now",
                help: "Use your remembered defaults, or pick the other common launch."
            ) {
                PrimaryLaunchButton(
                    title: primaryTitle,
                    subtitle: primarySubtitle,
                    symbol: primarySymbol
                ) {
                    model.launchPreferred()
                }

                VStack(spacing: 6) {
                    PlainActionButton(title: alternateTargetTitle, subtitle: alternateTargetSubtitle, symbol: alternateTargetSymbol) {
                        model.launch("main", target: alternateTarget)
                    }
                    PlainActionButton(title: "Open a temporary Codex app", subtitle: "Uses a disposable home; you can review cleanup later", symbol: "timer") {
                        model.launch("temp", target: .desktop)
                    }
                }
            }

            RecentMenuSection()

            HomeLaunchSection()

            Divider()

            FormSection(
                title: "2. Defaults",
                help: "Change what the blue button does."
            ) {
                QuickOptions()
            }

            Divider()

            FormSection(
                title: "3. Make a New Home",
                help: "New homes appear in Your Homes above."
            ) {
                CreateHomeSection()
            }

            if model.report.globalCodexHome != nil || !model.report.suspiciousLaunchers.isEmpty {
                DiagnosticBanner()
            }

            HStack {
                Button("Open Console") {
                    openWindow(id: "console")
                }
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(16)
    }

    private var primaryTitle: String {
        let home = model.state.preferences.launchTemporaryByDefault ? "Temporary" : "Main"
        let surface = model.state.preferences.defaultLaunchTarget == .desktop ? "Codex" : "Terminal"
        return "Open \(home) in \(surface)"
    }

    private var primarySubtitle: String {
        let home = model.state.preferences.launchTemporaryByDefault ? "temporary" : "main"
        let target = model.state.preferences.defaultLaunchTarget == .desktop ? "desktop app" : "terminal"
        return "\(home) home • \(target)"
    }

    private var primarySymbol: String {
        model.state.preferences.defaultLaunchTarget == .desktop ? "play.circle.fill" : "terminal.fill"
    }

    private var alternateTarget: LaunchTarget {
        model.state.preferences.defaultLaunchTarget == .desktop ? .terminal : .desktop
    }

    private var alternateTargetTitle: String {
        alternateTarget == .desktop ? "Open Main in the desktop app" : "Open Main in Terminal"
    }

    private var alternateTargetSubtitle: String {
        alternateTarget == .desktop ? "Same main home, but in Codex.app" : "Same main home, but in a terminal window"
    }

    private var alternateTargetSymbol: String {
        alternateTarget == .desktop ? "macwindow" : "terminal"
    }
}

struct FormSection<Content: View>: View {
    var title: String
    var help: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(help)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

struct PinnedMenuSection: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        if !model.pinnedHomes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pinned")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.pinnedHomes.prefix(3)) { home in
                    CompactLaunchRow(
                        title: home.name,
                        subtitle: home.slug,
                        symbol: "pin.fill",
                        target: model.state.preferences.defaultLaunchTarget
                    ) {
                        model.launch(home.slug, target: model.state.preferences.defaultLaunchTarget)
                    }
                }
            }
        }
    }
}

struct RecentMenuSection: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        if let instance = model.recentInstances.first {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last Opened")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                CompactLaunchRow(
                    title: instance.homeName,
                    subtitle: "\(instance.target.rawValue) • \(relativeTime(instance.launchedAt))",
                    symbol: instance.target == .desktop ? "macwindow" : "terminal",
                    target: instance.target
                ) {
                    model.launchRecent(instance)
                }
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct HomeLaunchSection: View {
    @EnvironmentObject var model: HomeportModel

    private var managedHomes: [CodexHome] {
        model.state.homes.filter { $0.kind != .main }
    }

    var body: some View {
        if !managedHomes.isEmpty {
            FormSection(
                title: "Your Homes",
                help: "Press a row to open one of the homes you created."
            ) {
                VStack(spacing: 6) {
                    ForEach(managedHomes.prefix(4)) { home in
                        HomeLaunchRow(home: home)
                    }
                    if managedHomes.count > 4 {
                        Text("Open Console to see all \(managedHomes.count) created homes.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct HomeLaunchRow: View {
    @EnvironmentObject var model: HomeportModel

    var home: CodexHome

    private var defaultTarget: LaunchTarget {
        model.state.preferences.defaultLaunchTarget
    }

    private var otherTarget: LaunchTarget {
        defaultTarget == .desktop ? .terminal : .desktop
    }

    var body: some View {
        HStack(spacing: 6) {
            Button {
                model.launch(home.slug, target: defaultTarget)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: icon(for: home))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(home.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text("\(kindLabel(for: home)) • opens in \(defaultTargetLabel)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button {
                model.launch(home.slug, target: otherTarget)
            } label: {
                Image(systemName: otherTarget == .desktop ? "macwindow" : "terminal")
                    .frame(width: 20)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open \(home.name) in \(otherTargetLabel)")
        }
    }

    private var defaultTargetLabel: String {
        defaultTarget == .desktop ? "Codex.app" : "Terminal"
    }

    private var otherTargetLabel: String {
        otherTarget == .desktop ? "Codex.app" : "Terminal"
    }

    private func kindLabel(for home: CodexHome) -> String {
        switch home.kind {
        case .main: "Main home"
        case .clone: "Copied home"
        case .cleanRoom: "Fresh home"
        case .temporary: "Temporary home"
        }
    }

    private func icon(for home: CodexHome) -> String {
        switch home.kind {
        case .main: "house"
        case .clone: "square.on.square"
        case .cleanRoom: "sparkles"
        case .temporary: "timer"
        }
    }
}

struct CompactLaunchRow: View {
    var title: String
    var subtitle: String
    var symbol: String
    var target: LaunchTarget
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(target.rawValue)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct PrimaryLaunchButton: View {
    var title: String
    var subtitle: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "return")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

struct SecondaryLaunchButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct PlainActionButton: View {
    var title: String
    var subtitle: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(2)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

struct CreateHomeSection: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CreateHomeButton(
                title: "Make a saved copy of my current setup",
                subtitle: "Uses the copy preset selected above",
                symbol: "square.on.square"
            ) {
                model.cloneWorkingSetup()
            }

            CreateHomeButton(
                title: "Make a saved empty home",
                subtitle: "Starts fresh and stays in your list",
                symbol: "sparkles"
            ) {
                model.cleanRoom()
            }

            CreateHomeButton(
                title: "Make a temporary test home",
                subtitle: "Starts fresh and is meant to be cleaned up later",
                symbol: "timer"
            ) {
                model.createTemporaryHome()
            }
        }
    }
}

struct CreateHomeButton: View {
    var title: String
    var subtitle: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("\(title): \(subtitle)")
    }
}

struct LaunchTile: View {
    var title: String
    var subtitle: String
    var symbol: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward")
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct DiagnosticBanner: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Launch environment needs attention", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
            Text("Homeport found a global CODEX_HOME or an older Desktop launcher that can open the wrong Codex state.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Repair Launch Environment") {
                model.repair()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct QuickOptions: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

            Picker("Copy preset", selection: Binding(
                get: { model.state.preferences.defaultClonePreset },
                set: { model.setDefaultClonePreset($0) }
            )) {
                ForEach(ClonePreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }

            HStack {
                Text("Detailed copy checkboxes are in Console.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    model.resetDefaults()
                }
            }
        }
    }
}

struct CloneIncludeToggles: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checked items will be copied into a saved copy:")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                helperButton("Working", .workingSetup)
                helperButton("Config", .configOnly)
                helperButton("All", .allIncluded)
                helperButton("None", .empty)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                toggle("config", \.config)
                toggle("auth", \.auth)
                toggle("skills", \.skills)
                toggle("plugins", \.plugins)
                toggle("agents", \.agents)
                toggle("prompts", \.prompts)
                toggle("rules", \.rules)
                toggle("profiles", \.profiles)
                toggle("memories", \.memories)
                toggle("browser", \.browserSupport)
                toggle("sessions", \.sessionsAndLogs)
                toggle("everything", \.everything, expandsAll: true)
            }
        }
    }

    private func helperButton(_ label: String, _ options: CloneOptions) -> some View {
        Button(label) {
            model.updateCloneOptions { current in
                current = options
            }
        }
        .font(.caption)
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func toggle(
        _ label: String,
        _ keyPath: WritableKeyPath<CloneOptions, Bool>,
        expandsAll: Bool = false
    ) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.state.preferences.cloneOptions[keyPath: keyPath] },
            set: { value in
                model.updateCloneOptions { options in
                    if expandsAll, value {
                        options = .allIncluded
                    } else {
                        options[keyPath: keyPath] = value
                    }
                }
            }
        ))
        .font(.caption)
    }
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
            .navigationTitle("Homeport")
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
            CloneIncludeToggles()
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ConsoleHeader: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Homeport Console")
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

    var home: CodexHome

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(home.name, systemImage: icon(for: home))
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
                        model.renameHome(home, name: editedName)
                    }
                    .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedName == home.name)
                }
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
        }
        .onChange(of: home.name) { newName in
            editedName = newName
        }
    }

    private func icon(for home: CodexHome) -> String {
        switch home.kind {
        case .main: "house"
        case .cleanRoom: "sparkle.magnifyingglass"
        case .clone: "square.on.square"
        case .temporary: "timer"
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
        if !model.recentInstances.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Recents")
                    .font(.title2.weight(.semibold))
                VStack(spacing: 8) {
                    ForEach(model.recentInstances) { instance in
                        HStack {
                            Image(systemName: instance.target == .desktop ? "macwindow" : "terminal")
                            VStack(alignment: .leading) {
                                Text(instance.homeName)
                                    .font(.headline)
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
            }
        }
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
                    Text("Codex.app").foregroundStyle(.secondary)
                    Text(model.report.codexAppExists ? "found" : "missing")
                }
                GridRow {
                    Text("codex CLI").foregroundStyle(.secondary)
                    Text(model.report.codexBinaryPath ?? "missing")
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
