import SwiftUI
import HomeportCore

@main
struct CodexHomeportApp: App {
    @StateObject private var model = HomeportModel()

    var body: some Scene {
        MenuBarExtra("Codex Homeport", systemImage: model.menuIcon) {
            HomeportMenuView()
                .environmentObject(model)
                .frame(width: 390)
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

    func launchRecent(_ instance: LaunchedInstance, target: LaunchTarget) {
        let selector = state.homes.first(where: { $0.id == instance.homeID })?.slug ?? instance.homeName
        launch(selector, target: target)
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

    func cloneConfigOnly() {
        do {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm"
            _ = try service.clone(
                name: "Config Copy \(formatter.string(from: Date()))",
                preset: .configOnly,
                options: .configOnly
            )
            refresh(statusMessage: "Created config-only home")
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
            next.preferences.defaultClonePreset = clonePreset(for: next.preferences.cloneOptions)
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

enum NewHomeMode: String, CaseIterable, Identifiable {
    case clone
    case cleanRoom
    case temporary
    case configOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clone: "Clone My Setup"
        case .cleanRoom: "Clean Room"
        case .temporary: "Temporary Home"
        case .configOnly: "Config Only"
        }
    }

    var subtitle: String {
        switch self {
        case .clone: "Start from selected parts of your main Codex home"
        case .cleanRoom: "Fresh saved home with no inherited files"
        case .temporary: "Disposable test home with cleanup review"
        case .configOnly: "Settings, skills, and prompts only"
        }
    }

    var symbol: String {
        switch self {
        case .clone: "square.on.square"
        case .cleanRoom: "sparkles"
        case .temporary: "timer"
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
    @State private var newHomeMode: NewHomeMode = .clone
    @State private var newHomeLaunchTarget: LaunchTarget = .desktop
    @State private var showsAddFavoriteSheet = false

    var body: some View {
        VStack(spacing: 0) {
            PhoneMenuHeader(
                title: headerTitle,
                subtitle: headerSubtitle,
                leftTitle: leftActionTitle,
                showsLeftAction: showsLeftAction,
                rightTitle: focusedHome == nil ? nil : (isEditingDetail ? "Done" : "Edit"),
                showsAddAndRefresh: focusedHome == nil,
                leftAction: handleLeftAction,
                rightAction: toggleDetailEdit,
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

            ScrollView {
                Group {
                    if let focusedHome {
                        FocusedHomeView(
                            home: focusedHome,
                            isEditing: isEditingDetail,
                            editedName: $editedName,
                            launch: { target in model.launch(focusedHome.slug, target: target) },
                            setPinned: { pinned in model.setHomePinned(focusedHome, pinned: pinned) },
                            delete: {
                                model.deleteHome(focusedHome)
                                self.focusedHome = nil
                                isEditingDetail = false
                            },
                            saveName: {
                                model.renameHome(focusedHome, name: editedName)
                                self.focusedHome = model.state.homes.first { $0.id == focusedHome.id } ?? focusedHome
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
        }
        .frame(width: 390)
        .onChange(of: selectedTab) { _ in
            isEditingList = false
        }
        .onChange(of: focusedHome?.id) { _ in
            editedName = focusedHome?.name ?? ""
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
                openDetail: openDetail
            )
        case .new:
            NewHomeTab(
                mode: $newHomeMode,
                launchTarget: $newHomeLaunchTarget,
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
            return "‹ \(detailReturnTab.title)"
        }
        return isEditingList ? "Done" : "Edit"
    }

    private func handleLeftAction() {
        if focusedHome != nil {
            focusedHome = nil
            isEditingDetail = false
            selectedTab = detailReturnTab
            return
        }
        if [.favorites, .recents, .homes].contains(selectedTab) {
            isEditingList.toggle()
        }
    }

    private func toggleDetailEdit() {
        isEditingDetail.toggle()
    }

    private func openDetail(_ home: CodexHome) {
        detailReturnTab = selectedTab
        focusedHome = home
        editedName = home.name
        isEditingList = false
        isEditingDetail = false
    }

    private func createNewHome() {
        switch newHomeMode {
        case .clone:
            model.cloneWorkingSetup()
        case .cleanRoom:
            model.cleanRoom()
        case .temporary:
            model.createTemporaryHome()
        case .configOnly:
            model.cloneConfigOnly()
        }
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
                        Text(tab.title == "New Home" ? "New" : tab.title)
                            .font(.caption2.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .foregroundStyle(selectedTab == tab ? .blue : .secondary)
                    .background(selectedTab == tab ? Color.blue.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
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
        if model.pinnedHomes.isEmpty {
            return Array(model.state.homes.prefix(1))
        }
        return model.pinnedHomes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DefaultLaunchCard()
            SectionLabel("Favorites")
            if favoriteHomes.isEmpty {
                EmptyState(title: "No homes yet", subtitle: "Create or pin homes to put them here.")
            } else {
                ForEach(favoriteHomes) { home in
                    HomeListRow(
                        home: home,
                        subtitle: model.isPinned(home) ? "Favorite • \(kindLabel(for: home))" : "Main home • not pinned yet",
                        isEditing: isEditing,
                        openDetail: { openDetail(home) },
                        launch: { target in model.launch(home.slug, target: target) }
                    )
                }
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
                            Image(systemName: icon(for: home))
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

    private func icon(for home: CodexHome) -> String {
        switch home.kind {
        case .main: "house.fill"
        case .clone: "square.on.square"
        case .cleanRoom: "sparkles"
        case .temporary: "timer"
        }
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

struct RecentsTab: View {
    @EnvironmentObject var model: HomeportModel
    var isEditing: Bool
    var openDetail: (CodexHome) -> Void

    var pending: [LaunchedInstance] {
        model.state.instances.filter(\.cleanupReviewRequired)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Recent Opens")
            if model.recentInstances.isEmpty {
                EmptyState(title: "No recents", subtitle: "Launch a home and it will appear here.")
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("All Homes")
            ForEach(model.state.homes) { home in
                HomeListRow(
                    home: home,
                    subtitle: "\(model.isPinned(home) ? "Favorite" : "Not favorite") • \(kindLabel(for: home))",
                    isEditing: isEditing,
                    openDetail: { openDetail(home) },
                    launch: { target in model.launch(home.slug, target: target) }
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
    var create: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Create")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(NewHomeMode.allCases) { candidate in
                    NewHomeModeButton(mode: candidate, isSelected: mode == candidate) {
                        mode = candidate
                        if candidate == .configOnly {
                            model.setDefaultClonePreset(.configOnly)
                        }
                    }
                }
            }
            SectionLabel("Opens In")
            Picker("Opens In", selection: $launchTarget) {
                Text("Desktop App").tag(LaunchTarget.desktop)
                Text("Terminal").tag(LaunchTarget.terminal)
            }
            .pickerStyle(.segmented)
            if mode.showsCloneOptions {
                SectionLabel("Clone Includes")
                CloneIncludeToggles()
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.caption.weight(.semibold))
                    Text(mode.showsCloneOptions ? "Copy options apply to this saved home." : "No copy options needed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Create", action: create)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
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
            SectionLabel("Install")
            InfoCard(title: "Update Homeport", subtitle: "npm install -g codex-homeport@latest")
            HStack {
                Button("Open Console", action: openConsole)
                Spacer()
                Button("Quit", action: quit)
            }
            .buttonStyle(.bordered)
            Button("Reset Defaults") {
                model.resetDefaults()
            }
            .buttonStyle(.bordered)
        }
    }
}

struct FocusedHomeView: View {
    @EnvironmentObject var model: HomeportModel
    var home: CodexHome
    var isEditing: Bool
    @Binding var editedName: String
    var launch: (LaunchTarget) -> Void
    var setPinned: (Bool) -> Void
    var delete: () -> Void
    var saveName: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(spacing: 10) {
                Image(systemName: icon(for: home))
                    .font(.largeTitle)
                    .frame(width: 64, height: 64)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 18))
                Text(home.name)
                    .font(.title2.weight(.bold))
                Text("\(kindLabel(for: home)) • \(model.isPinned(home) ? "Favorite" : "Not favorite")")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LaunchActionPair(launch: launch)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(.background, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))

            SectionLabel("Home")
            InfoCard(title: "Path", subtitle: home.homePath)
            InfoCard(title: "Copy Source", subtitle: home.sourceHomePath ?? (home.kind == .main ? "This is your main Codex home" : "No inherited files"))

            SectionLabel("Manage")
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Favorite", isOn: Binding(
                    get: { model.isPinned(home) },
                    set: { setPinned($0) }
                ))
                if isEditing && home.kind != .main {
                    HStack {
                        TextField("Name", text: $editedName)
                            .textFieldStyle(.roundedBorder)
                        Button("Save", action: saveName)
                            .disabled(editedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editedName == home.name)
                    }
                    Button("Review Delete", role: .destructive, action: delete)
                        .buttonStyle(.bordered)
                } else if home.kind == .main {
                    Text("The main home cannot be deleted.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func icon(for home: CodexHome) -> String {
        switch home.kind {
        case .main: "house.fill"
        case .clone: "square.on.square"
        case .cleanRoom: "sparkles"
        case .temporary: "timer"
        }
    }
}

struct HomeListRow: View {
    var home: CodexHome
    var subtitle: String
    var isEditing: Bool
    var openDetail: () -> Void
    var launch: (LaunchTarget) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 20)
            }
            Button(action: openDetail) {
                HStack(spacing: 10) {
                    Image(systemName: icon(for: home))
                        .frame(width: 24, height: 24)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(home.name)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            LaunchActionPair(launch: launch)
                .opacity(isEditing ? 0.45 : 1)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }

    private func icon(for home: CodexHome) -> String {
        switch home.kind {
        case .main: "house.fill"
        case .clone: "square.on.square"
        case .cleanRoom: "sparkles"
        case .temporary: "timer"
        }
    }
}

struct RecentLaunchRow: View {
    @EnvironmentObject var model: HomeportModel
    var instance: LaunchedInstance
    var isEditing: Bool

    var body: some View {
        HStack(spacing: 8) {
            if isEditing {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 20)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("\(instance.homeName) • \(targetLabel(instance.target))")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(relativeTime(instance.launchedAt)) • \(instance.workspacePath ?? "no workspace")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            LaunchActionPair { target in
                model.launchRecent(instance, target: target)
            }
            .opacity(isEditing ? 0.45 : 1)
        }
        .padding(10)
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
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
            Button("App") {
                launch(.desktop)
            }
            .help("Open in Codex app")
            Button("Term") {
                launch(.terminal)
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
            VStack(alignment: .leading, spacing: 6) {
                Label(mode.title, systemImage: mode.symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(mode.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
            .padding(10)
            .background(isSelected ? Color.blue.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(isSelected ? Color.blue.opacity(0.35) : Color.secondary.opacity(0.15)))
        }
        .buttonStyle(.plain)
    }
}

struct CloneIncludeToggles: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                helperButton("Clone", .workingSetup)
                helperButton("Config", .configOnly)
                helperButton("Empty", .empty)
            }
            CopyGroup(title: "Safe Defaults") {
                toggle("Config", \.config)
                toggle("Skills", \.skills)
                toggle("Plugins", \.plugins)
                toggle("Prompts", \.prompts)
                toggle("Rules", \.rules)
                toggle("Profiles", \.profiles)
            }
            CopyGroup(title: "Identity And Browser", warning: true) {
                toggle("Auth", \.auth)
                toggle("Browser", \.browserSupport)
                toggle("Agents", \.agents)
                toggle("Memories", \.memories)
            }
            CopyGroup(title: "History", warning: true) {
                toggle("Sessions and logs", \.sessionsAndLogs)
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
        _ keyPath: WritableKeyPath<CloneOptions, Bool>
    ) -> some View {
        Toggle(label, isOn: Binding(
            get: { model.state.preferences.cloneOptions[keyPath: keyPath] },
            set: { value in
                model.updateCloneOptions { options in
                    options[keyPath: keyPath] = value
                    if !value {
                        options.everything = false
                    }
                }
            }
        ))
        .font(.caption)
    }
}

struct CopyGroup<Content: View>: View {
    var title: String
    var warning = false
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 4) {
                content
            }
            if warning {
                Text("These may carry account identity, remembered context, or history.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(warning ? Color.orange.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct LaunchHealthBanner: View {
    @EnvironmentObject var model: HomeportModel

    var body: some View {
        if model.report.globalCodexHome != nil || !model.report.suspiciousLaunchers.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Launch environment needs attention", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                Text("Homeport found state that can open the wrong Codex home.")
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
