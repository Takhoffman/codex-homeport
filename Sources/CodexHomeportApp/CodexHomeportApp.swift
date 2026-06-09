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

    init() {
        refresh()
    }

    func refresh() {
        do {
            state = try service.loadState()
            report = service.report()
            workspacePath = state.lastWorkspacePath ?? workspacePath
            status = "Ready"
        } catch {
            status = error.localizedDescription
        }
    }

    func launch(_ selector: String, target: LaunchTarget) {
        do {
            let actualSelector = modelSelector(for: selector)
            let instance = try service.launch(selector: actualSelector, target: target, workspace: workspacePath)
            status = "Launched \(instance.homeName) as \(target.rawValue)"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func launchPreferred() {
        let selector = state.preferences.launchTemporaryByDefault ? "temp" : "main"
        launch(selector, target: state.preferences.defaultLaunchTarget)
    }

    func cloneWorkingSetup() {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            _ = try service.clone(name: "Working Setup \(formatter.string(from: Date()))", preset: state.preferences.defaultClonePreset)
            status = "Cloned working setup"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func cleanRoom() {
        do {
            _ = try service.createCleanRoom()
            status = "Created clean room"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func createTemporaryHome() {
        do {
            _ = try service.createTemporary()
            status = "Created temporary home"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func renameHome(_ home: CodexHome, name: String) {
        do {
            try service.renameHome(id: home.id, name: name)
            status = "Renamed \(home.name)"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func deleteHome(_ home: CodexHome) {
        do {
            _ = try service.deleteHome(id: home.id)
            status = "Moved \(home.name) to Trash"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func cleanup(_ instance: LaunchedInstance) {
        do {
            _ = try service.cleanup(instanceID: instance.id)
            status = "Cleaned \(instance.homeName)"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func promote(_ instance: LaunchedInstance) {
        do {
            try service.promote(instanceID: instance.id)
            status = "Promoted \(instance.homeName)"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func repair() {
        do {
            try service.clearGlobalCodexHome()
            status = "Cleared GUI CODEX_HOME"
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func setDefaultLaunchTarget(_ target: LaunchTarget) {
        do {
            var next = try service.loadState()
            next.preferences.defaultLaunchTarget = target
            try service.saveState(next)
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func setDefaultClonePreset(_ preset: ClonePreset) {
        do {
            var next = try service.loadState()
            next.preferences.defaultClonePreset = preset
            try service.saveState(next)
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func setLaunchTemporaryByDefault(_ value: Bool) {
        do {
            var next = try service.loadState()
            next.preferences.launchTemporaryByDefault = value
            try service.saveState(next)
            refresh()
        } catch {
            status = error.localizedDescription
        }
    }

    func resetDefaults() {
        do {
            try service.resetPreferences()
            status = "Reset preferences"
            refresh()
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

            VStack(spacing: 8) {
                LaunchTile(title: "Launch Preferred", subtitle: preferredSubtitle, symbol: "play.circle") {
                    model.launchPreferred()
                }
                LaunchTile(title: "Main Desktop", subtitle: "~/.codex in Codex.app", symbol: "macwindow") {
                    model.launch("main", target: .desktop)
                }
                LaunchTile(title: "Main Terminal", subtitle: "codex with ~/.codex", symbol: "terminal") {
                    model.launch("main", target: .terminal)
                }
                LaunchTile(title: "Throwaway App", subtitle: "Temporary Codex.app, cleanup review", symbol: "timer") {
                    model.launch("temp", target: .desktop)
                }
                LaunchTile(title: "Temporary Terminal", subtitle: "Throwaway home, cleanup review", symbol: "sparkles") {
                    model.launch("temp", target: .terminal)
                }
            }

            Divider()

            QuickOptions()

            Divider()

            HStack {
                Button("Clone My Setup") {
                    model.cloneWorkingSetup()
                }
                Button("Clean Room") {
                    model.cleanRoom()
                }
                Button("Temp Home") {
                    model.createTemporaryHome()
                }
            }

            if model.report.globalCodexHome != nil || !model.report.suspiciousLaunchers.isEmpty {
                DiagnosticBanner()
            }

            HStack {
                Button("Console") {
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

    private var preferredSubtitle: String {
        let home = model.state.preferences.launchTemporaryByDefault ? "temporary" : "main"
        return "\(home), \(model.state.preferences.defaultLaunchTarget.rawValue)"
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
        VStack(alignment: .leading, spacing: 10) {
            Text("Remembered Options")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Default", selection: Binding(
                get: { model.state.preferences.defaultLaunchTarget },
                set: { model.setDefaultLaunchTarget($0) }
            )) {
                Text("Desktop").tag(LaunchTarget.desktop)
                Text("Terminal").tag(LaunchTarget.terminal)
            }
            .pickerStyle(.segmented)

            Toggle("Prefer temporary launches", isOn: Binding(
                get: { model.state.preferences.launchTemporaryByDefault },
                set: { model.setLaunchTemporaryByDefault($0) }
            ))

            Picker("Clone", selection: Binding(
                get: { model.state.preferences.defaultClonePreset },
                set: { model.setDefaultClonePreset($0) }
            )) {
                ForEach(ClonePreset.allCases, id: \.self) { preset in
                    Text(preset.displayName).tag(preset)
                }
            }

            Button("Reset Options") {
                model.resetDefaults()
            }
        }
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
                    HomeGrid()
                    CleanupReview()
                    DiagnosticsPanel()
                }
                .padding(24)
            }
        }
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
