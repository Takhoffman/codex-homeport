import Foundation

public enum LaunchTarget: String, Codable, CaseIterable, Sendable {
    case desktop
    case terminal
}

public enum HomeKind: String, Codable, CaseIterable, Sendable {
    case main
    case cleanRoom
    case clone
    case temporary
}

public enum ClonePreset: String, Codable, CaseIterable, Sendable {
    case workingSetup = "working-setup"
    case configOnly = "config-only"
    case everything
    case empty

    public var displayName: String {
        switch self {
        case .workingSetup: "Working Setup"
        case .configOnly: "Config Only"
        case .everything: "Everything"
        case .empty: "Empty"
        }
    }
}

public enum CloneMaterialization: String, Codable, CaseIterable, Sendable {
    case copy
    case linkSafeCustomizations
    case linkSafeCustomizationsAndAuth

    public var displayName: String {
        switch self {
        case .copy: "Copy"
        case .linkSafeCustomizations: "Link Safe"
        case .linkSafeCustomizationsAndAuth: "Link Auth"
        }
    }
}

public enum ClonePolicy: String, Codable, CaseIterable, Sendable {
    case skip
    case copy
    case link

    public var displayName: String {
        switch self {
        case .skip: "Skip"
        case .copy: "Copy"
        case .link: "Link"
        }
    }
}

public enum CloneCategoryGroup: String, Codable, CaseIterable, Sendable {
    case safeDefaults
    case identityAndBrowser
    case history

    public var displayName: String {
        switch self {
        case .safeDefaults: "Safe Defaults"
        case .identityAndBrowser: "Identity And Browser"
        case .history: "History"
        }
    }

    public var warningText: String? {
        switch self {
        case .safeDefaults:
            nil
        case .identityAndBrowser:
            "Linked auth and agents edit the source home. Browser state and memories can carry remembered context, so Link is unavailable for them."
        case .history:
            "History can be copied or skipped, but not linked."
        }
    }
}

public enum CloneCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case config
    case skills
    case plugins
    case prompts
    case rules
    case profiles
    case auth
    case agents
    case browserSupport
    case memories
    case sessionsAndLogs

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .config: "Config"
        case .skills: "Skills"
        case .plugins: "Plugins"
        case .prompts: "Prompts"
        case .rules: "Rules"
        case .profiles: "Profiles"
        case .auth: "Auth"
        case .agents: "Agents"
        case .browserSupport: "Browser"
        case .memories: "Memories"
        case .sessionsAndLogs: "Sessions and logs"
        }
    }

    public var summaryLabel: String {
        switch self {
        case .browserSupport: "browser"
        case .sessionsAndLogs: "history"
        default: rawValue
        }
    }

    public var group: CloneCategoryGroup {
        switch self {
        case .config, .skills, .plugins, .prompts, .rules, .profiles:
            .safeDefaults
        case .auth, .agents, .browserSupport, .memories:
            .identityAndBrowser
        case .sessionsAndLogs:
            .history
        }
    }

    public var canLink: Bool {
        switch self {
        case .config, .skills, .plugins, .prompts, .rules, .profiles, .auth, .agents:
            true
        case .browserSupport, .memories, .sessionsAndLogs:
            false
        }
    }

    public var paths: [String] {
        switch self {
        case .config:
            ["config.toml", "AGENTS.md", "keybindings.json", "version.json"]
        case .skills:
            ["skills", "skills-disabled", "skill-backups"]
        case .plugins:
            ["plugins", "vendor_imports"]
        case .prompts:
            ["prompts"]
        case .rules:
            ["rules"]
        case .profiles:
            ["profiles"]
        case .auth:
            ["auth.json"]
        case .agents:
            ["agents"]
        case .browserSupport:
            ["browser", "chrome-cdp-profile", "chrome-native-hosts.json", "chrome-native-hosts-v2.json", "computer-use", "mcp-auth"]
        case .memories:
            ["memories", "memories_1.sqlite", "memories_1.sqlite-shm", "memories_1.sqlite-wal"]
        case .sessionsAndLogs:
            [
                "session_index.jsonl",
                "sessions",
                "archived_sessions",
                "logs_2.sqlite",
                "logs_2.sqlite-shm",
                "logs_2.sqlite-wal",
                "goals_1.sqlite",
                "goals_1.sqlite-shm",
                "goals_1.sqlite-wal",
                "state_5.sqlite",
                "state_5.sqlite-shm",
                "state_5.sqlite-wal",
                "shell_snapshots",
                "attachments"
            ]
        }
    }

    public var pathSummary: String {
        paths.joined(separator: ", ")
    }
}

public enum TerminalApp: String, Codable, CaseIterable, Sendable {
    case terminal
    case iTerm

    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm: "iTerm"
        }
    }
}

public enum UpdateCheckInterval: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly

    public var seconds: TimeInterval {
        switch self {
        case .daily: 60 * 60 * 24
        case .weekly: 60 * 60 * 24 * 7
        }
    }

    public var displayName: String {
        switch self {
        case .daily: "Daily"
        case .weekly: "Weekly"
        }
    }
}

public struct UpdaterState: Codable, Equatable, Sendable {
    public var lastCheckedAt: Date?
    public var latestVersion: String?
    public var dismissedVersion: String?
    public var installStartedAt: Date?
    public var lastError: String?

    public init(
        lastCheckedAt: Date? = nil,
        latestVersion: String? = nil,
        dismissedVersion: String? = nil,
        installStartedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.lastCheckedAt = lastCheckedAt
        self.latestVersion = latestVersion
        self.dismissedVersion = dismissedVersion
        self.installStartedAt = installStartedAt
        self.lastError = lastError
    }

    public func updateAvailable(currentVersion: String = AppVersion.version) -> Bool {
        guard let latestVersion else {
            return false
        }
        guard installStartedAt == nil else {
            return false
        }
        return compareVersions(latestVersion, currentVersion) == .orderedDescending
            && dismissedVersion != latestVersion
    }
}

public struct ModelRoutingConfig: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var providers: [String]
    public var allowAPIKeyPresets: Bool

    public init(
        isEnabled: Bool = true,
        providers: [String] = [],
        allowAPIKeyPresets: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.providers = providers
        self.allowAPIKeyPresets = allowAPIKeyPresets
    }

    enum CodingKeys: String, CodingKey {
        case isEnabled
        case providers
        case allowAPIKeyPresets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.providers = try container.decodeIfPresent([String].self, forKey: .providers) ?? []
        self.allowAPIKeyPresets = try container.decodeIfPresent(Bool.self, forKey: .allowAPIKeyPresets) ?? false
    }
}

public enum InstanceStatus: String, Codable, Sendable {
    case running
    case closed
    case cleaned
    case promoted
    case unknown
}

public struct CodexHome: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var kind: HomeKind
    public var homePath: String
    public var profilePath: String?
    public var sourceHomePath: String?
    public var clonePreset: ClonePreset?
    public var cloneMaterialization: CloneMaterialization?
    public var clonePolicies: ClonePolicies?
    public var createdAt: Date
    public var isTemporary: Bool
    public var promotedAt: Date?
    public var modelRouting: ModelRoutingConfig?

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        kind: HomeKind,
        homePath: String,
        profilePath: String?,
        sourceHomePath: String? = nil,
        clonePreset: ClonePreset? = nil,
        cloneMaterialization: CloneMaterialization? = nil,
        clonePolicies: ClonePolicies? = nil,
        createdAt: Date = Date(),
        isTemporary: Bool = false,
        promotedAt: Date? = nil,
        modelRouting: ModelRoutingConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.kind = kind
        self.homePath = homePath
        self.profilePath = profilePath
        self.sourceHomePath = sourceHomePath
        self.clonePreset = clonePreset
        self.cloneMaterialization = cloneMaterialization
        self.clonePolicies = clonePolicies
        self.createdAt = createdAt
        self.isTemporary = isTemporary
        self.promotedAt = promotedAt
        self.modelRouting = modelRouting
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case slug
        case kind
        case homePath
        case profilePath
        case sourceHomePath
        case clonePreset
        case cloneMaterialization
        case clonePolicies
        case createdAt
        case isTemporary
        case promotedAt
        case modelRouting
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.slug = try container.decode(String.self, forKey: .slug)
        self.kind = try container.decode(HomeKind.self, forKey: .kind)
        self.homePath = try container.decode(String.self, forKey: .homePath)
        self.profilePath = try container.decodeIfPresent(String.self, forKey: .profilePath)
        self.sourceHomePath = try container.decodeIfPresent(String.self, forKey: .sourceHomePath)
        self.clonePreset = try container.decodeIfPresent(ClonePreset.self, forKey: .clonePreset)
        self.cloneMaterialization = try container.decodeIfPresent(CloneMaterialization.self, forKey: .cloneMaterialization)
        self.clonePolicies = try container.decodeIfPresent(ClonePolicies.self, forKey: .clonePolicies)
            ?? Self.policiesFromLegacyMetadata(
                preset: clonePreset,
                materialization: cloneMaterialization,
                hasSource: sourceHomePath != nil
            )
        self.createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        self.isTemporary = try container.decodeIfPresent(Bool.self, forKey: .isTemporary) ?? false
        self.promotedAt = try container.decodeIfPresent(Date.self, forKey: .promotedAt)
        self.modelRouting = try container.decodeIfPresent(ModelRoutingConfig.self, forKey: .modelRouting)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(slug, forKey: .slug)
        try container.encode(kind, forKey: .kind)
        try container.encode(homePath, forKey: .homePath)
        try container.encodeIfPresent(profilePath, forKey: .profilePath)
        try container.encodeIfPresent(sourceHomePath, forKey: .sourceHomePath)
        try container.encodeIfPresent(clonePreset, forKey: .clonePreset)
        try container.encodeIfPresent(cloneMaterialization, forKey: .cloneMaterialization)
        try container.encodeIfPresent(clonePolicies, forKey: .clonePolicies)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(isTemporary, forKey: .isTemporary)
        try container.encodeIfPresent(promotedAt, forKey: .promotedAt)
        try container.encodeIfPresent(modelRouting, forKey: .modelRouting)
    }

    private static func policiesFromLegacyMetadata(
        preset: ClonePreset?,
        materialization: CloneMaterialization?,
        hasSource: Bool
    ) -> ClonePolicies? {
        guard hasSource || preset != nil || materialization != nil else {
            return nil
        }
        return ClonePolicies(
            options: .preset(preset ?? .workingSetup),
            materialization: materialization ?? .copy
        )
    }
}

public struct LaunchedInstance: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var homeID: UUID
    public var homeName: String
    public var homePath: String
    public var profilePath: String?
    public var target: LaunchTarget
    public var pid: Int32?
    public var workspacePath: String?
    public var terminalApp: TerminalApp?
    public var launchedAt: Date
    public var closedAt: Date?
    public var status: InstanceStatus
    public var cleanupReviewRequired: Bool

    public init(
        id: UUID = UUID(),
        homeID: UUID,
        homeName: String,
        homePath: String,
        profilePath: String?,
        target: LaunchTarget,
        pid: Int32?,
        workspacePath: String?,
        terminalApp: TerminalApp?,
        launchedAt: Date = Date(),
        closedAt: Date? = nil,
        status: InstanceStatus = .running,
        cleanupReviewRequired: Bool = false
    ) {
        self.id = id
        self.homeID = homeID
        self.homeName = homeName
        self.homePath = homePath
        self.profilePath = profilePath
        self.target = target
        self.pid = pid
        self.workspacePath = workspacePath
        self.terminalApp = terminalApp
        self.launchedAt = launchedAt
        self.closedAt = closedAt
        self.status = status
        self.cleanupReviewRequired = cleanupReviewRequired
    }
}

public struct HomeportState: Codable, Equatable, Sendable {
    public var version: Int
    public var homes: [CodexHome]
    public var instances: [LaunchedInstance]
    public var pinnedHomeIDs: [UUID]
    public var preferredTerminal: TerminalApp
    public var lastWorkspacePath: String?
    public var preferences: HomeportPreferences
    public var updater: UpdaterState

    public init(
        version: Int = 1,
        homes: [CodexHome] = [],
        instances: [LaunchedInstance] = [],
        pinnedHomeIDs: [UUID] = [],
        preferredTerminal: TerminalApp = .terminal,
        lastWorkspacePath: String? = nil,
        preferences: HomeportPreferences = HomeportPreferences(),
        updater: UpdaterState = UpdaterState()
    ) {
        self.version = version
        self.homes = homes
        self.instances = instances
        self.pinnedHomeIDs = pinnedHomeIDs
        self.preferredTerminal = preferredTerminal
        self.lastWorkspacePath = lastWorkspacePath
        self.preferences = preferences
        self.updater = updater
    }

    enum CodingKeys: String, CodingKey {
        case version
        case homes
        case instances
        case pinnedHomeIDs
        case preferredTerminal
        case lastWorkspacePath
        case preferences
        case updater
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.homes = try container.decodeIfPresent([CodexHome].self, forKey: .homes) ?? []
        self.instances = try container.decodeIfPresent([LaunchedInstance].self, forKey: .instances) ?? []
        self.pinnedHomeIDs = try container.decodeIfPresent([UUID].self, forKey: .pinnedHomeIDs) ?? []
        self.preferredTerminal = try container.decodeIfPresent(TerminalApp.self, forKey: .preferredTerminal) ?? .terminal
        self.lastWorkspacePath = try container.decodeIfPresent(String.self, forKey: .lastWorkspacePath)
        self.preferences = try container.decodeIfPresent(HomeportPreferences.self, forKey: .preferences) ?? HomeportPreferences()
        self.updater = try container.decodeIfPresent(UpdaterState.self, forKey: .updater) ?? UpdaterState()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(homes, forKey: .homes)
        try container.encode(instances, forKey: .instances)
        try container.encode(pinnedHomeIDs, forKey: .pinnedHomeIDs)
        try container.encode(preferredTerminal, forKey: .preferredTerminal)
        try container.encodeIfPresent(lastWorkspacePath, forKey: .lastWorkspacePath)
        try container.encode(preferences, forKey: .preferences)
        try container.encode(updater, forKey: .updater)
    }
}

public struct HomeportPreferences: Codable, Equatable, Sendable {
    public var defaultLaunchTarget: LaunchTarget
    public var defaultClonePreset: ClonePreset
    public var cloneOptions: CloneOptions
    public var cloneSourceSelector: String
    public var cloneMaterialization: CloneMaterialization
    public var clonePolicies: ClonePolicies
    public var lastClonePolicies: ClonePolicies?
    public var launchTemporaryByDefault: Bool
    public var onboardEnablesAutostart: Bool
    public var installAppByDefault: Bool
    public var allowForbiddenComputerUseTargetsByDefault: Bool
    public var autoUpdateChecksEnabled: Bool
    public var autoInstallUpdates: Bool
    public var updateCheckInterval: UpdateCheckInterval
    public var shimExecutablePath: String
    public var shimPort: String

    public init(
        defaultLaunchTarget: LaunchTarget = .desktop,
        defaultClonePreset: ClonePreset = .workingSetup,
        cloneOptions: CloneOptions = CloneOptions.workingSetup,
        cloneSourceSelector: String = "main",
        cloneMaterialization: CloneMaterialization = .copy,
        clonePolicies: ClonePolicies? = nil,
        lastClonePolicies: ClonePolicies? = nil,
        launchTemporaryByDefault: Bool = false,
        onboardEnablesAutostart: Bool = true,
        installAppByDefault: Bool = true,
        allowForbiddenComputerUseTargetsByDefault: Bool = true,
        autoUpdateChecksEnabled: Bool = true,
        autoInstallUpdates: Bool = false,
        updateCheckInterval: UpdateCheckInterval = .daily,
        shimExecutablePath: String = "",
        shimPort: String = "8765"
    ) {
        self.defaultLaunchTarget = defaultLaunchTarget
        self.defaultClonePreset = defaultClonePreset
        self.cloneOptions = cloneOptions
        self.cloneSourceSelector = cloneSourceSelector
        self.cloneMaterialization = cloneMaterialization
        self.clonePolicies = clonePolicies ?? ClonePolicies(options: cloneOptions, materialization: cloneMaterialization)
        self.lastClonePolicies = lastClonePolicies
        self.launchTemporaryByDefault = launchTemporaryByDefault
        self.onboardEnablesAutostart = onboardEnablesAutostart
        self.installAppByDefault = installAppByDefault
        self.allowForbiddenComputerUseTargetsByDefault = allowForbiddenComputerUseTargetsByDefault
        self.autoUpdateChecksEnabled = autoUpdateChecksEnabled
        self.autoInstallUpdates = autoInstallUpdates
        self.updateCheckInterval = updateCheckInterval
        self.shimExecutablePath = shimExecutablePath
        self.shimPort = shimPort
    }

    enum CodingKeys: String, CodingKey {
        case defaultLaunchTarget
        case defaultClonePreset
        case cloneOptions
        case cloneSourceSelector
        case cloneMaterialization
        case clonePolicies
        case lastClonePolicies
        case launchTemporaryByDefault
        case onboardEnablesAutostart
        case installAppByDefault
        case allowForbiddenComputerUseTargetsByDefault
        case autoUpdateChecksEnabled
        case autoInstallUpdates
        case updateCheckInterval
        case shimExecutablePath
        case shimPort
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultLaunchTarget = try container.decodeIfPresent(LaunchTarget.self, forKey: .defaultLaunchTarget) ?? .desktop
        self.defaultClonePreset = try container.decodeIfPresent(ClonePreset.self, forKey: .defaultClonePreset) ?? .workingSetup
        self.cloneOptions = try container.decodeIfPresent(CloneOptions.self, forKey: .cloneOptions) ?? .workingSetup
        self.cloneSourceSelector = try container.decodeIfPresent(String.self, forKey: .cloneSourceSelector) ?? "main"
        self.cloneMaterialization = try container.decodeIfPresent(CloneMaterialization.self, forKey: .cloneMaterialization) ?? .copy
        self.clonePolicies = try container.decodeIfPresent(ClonePolicies.self, forKey: .clonePolicies)
            ?? ClonePolicies(options: self.cloneOptions, materialization: self.cloneMaterialization)
        self.lastClonePolicies = try container.decodeIfPresent(ClonePolicies.self, forKey: .lastClonePolicies)
        self.launchTemporaryByDefault = try container.decodeIfPresent(Bool.self, forKey: .launchTemporaryByDefault) ?? false
        self.onboardEnablesAutostart = try container.decodeIfPresent(Bool.self, forKey: .onboardEnablesAutostart) ?? true
        self.installAppByDefault = try container.decodeIfPresent(Bool.self, forKey: .installAppByDefault) ?? true
        self.allowForbiddenComputerUseTargetsByDefault = try container.decodeIfPresent(Bool.self, forKey: .allowForbiddenComputerUseTargetsByDefault) ?? true
        self.autoUpdateChecksEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateChecksEnabled) ?? true
        self.autoInstallUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? false
        self.updateCheckInterval = try container.decodeIfPresent(UpdateCheckInterval.self, forKey: .updateCheckInterval) ?? .daily
        self.shimExecutablePath = try container.decodeIfPresent(String.self, forKey: .shimExecutablePath) ?? ""
        self.shimPort = try container.decodeIfPresent(String.self, forKey: .shimPort) ?? "8765"
    }
}

public struct ClonePolicies: Codable, Equatable, Sendable {
    public var config: ClonePolicy
    public var auth: ClonePolicy
    public var skills: ClonePolicy
    public var plugins: ClonePolicy
    public var agents: ClonePolicy
    public var prompts: ClonePolicy
    public var rules: ClonePolicy
    public var profiles: ClonePolicy
    public var memories: ClonePolicy
    public var browserSupport: ClonePolicy
    public var sessionsAndLogs: ClonePolicy

    public init(
        config: ClonePolicy = .copy,
        auth: ClonePolicy = .copy,
        skills: ClonePolicy = .copy,
        plugins: ClonePolicy = .copy,
        agents: ClonePolicy = .copy,
        prompts: ClonePolicy = .copy,
        rules: ClonePolicy = .copy,
        profiles: ClonePolicy = .copy,
        memories: ClonePolicy = .copy,
        browserSupport: ClonePolicy = .copy,
        sessionsAndLogs: ClonePolicy = .skip
    ) {
        self.config = config
        self.auth = auth
        self.skills = skills
        self.plugins = plugins
        self.agents = agents
        self.prompts = prompts
        self.rules = rules
        self.profiles = profiles
        self.memories = memories
        self.browserSupport = browserSupport
        self.sessionsAndLogs = sessionsAndLogs
    }

    public init(options: CloneOptions, materialization: CloneMaterialization) {
        let safeLink = materialization == .linkSafeCustomizations || materialization == .linkSafeCustomizationsAndAuth
        let authLink = materialization == .linkSafeCustomizationsAndAuth
        self.init(
            config: Self.policy(included: options.config, linked: safeLink),
            auth: Self.policy(included: options.auth, linked: authLink),
            skills: Self.policy(included: options.skills, linked: safeLink),
            plugins: Self.policy(included: options.plugins, linked: safeLink),
            agents: Self.policy(included: options.agents, linked: safeLink),
            prompts: Self.policy(included: options.prompts, linked: safeLink),
            rules: Self.policy(included: options.rules, linked: safeLink),
            profiles: Self.policy(included: options.profiles, linked: safeLink),
            memories: Self.policy(included: options.memories, linked: false),
            browserSupport: Self.policy(included: options.browserSupport, linked: false),
            sessionsAndLogs: Self.policy(included: options.sessionsAndLogs, linked: false)
        )
    }

    public static let empty = ClonePolicies(
        config: .skip,
        auth: .skip,
        skills: .skip,
        plugins: .skip,
        agents: .skip,
        prompts: .skip,
        rules: .skip,
        profiles: .skip,
        memories: .skip,
        browserSupport: .skip,
        sessionsAndLogs: .skip
    )

    public static let configOnly = ClonePolicies(options: .configOnly, materialization: .copy)
    public static let workingSetup = ClonePolicies(options: .workingSetup, materialization: .copy)
    public static let full = ClonePolicies(options: .full, materialization: .copy)

    public static func preset(_ preset: ClonePreset) -> ClonePolicies {
        switch preset {
        case .empty: .empty
        case .configOnly: .configOnly
        case .workingSetup: .workingSetup
        case .everything: .full
        }
    }

    public var options: CloneOptions {
        CloneOptions(
            config: config != .skip,
            auth: auth != .skip,
            skills: skills != .skip,
            plugins: plugins != .skip,
            agents: agents != .skip,
            prompts: prompts != .skip,
            rules: rules != .skip,
            profiles: profiles != .skip,
            memories: memories != .skip,
            browserSupport: browserSupport != .skip,
            sessionsAndLogs: sessionsAndLogs != .skip,
            everything: allIncluded
        )
    }

    public var materialization: CloneMaterialization {
        if auth == .link {
            return .linkSafeCustomizationsAndAuth
        }
        if [config, skills, plugins, agents, prompts, rules, profiles].contains(.link) {
            return .linkSafeCustomizations
        }
        return .copy
    }

    public var summary: String {
        let linked = labeledCategories(for: .link)
        let copied = labeledCategories(for: .copy)
        let skipped = labeledCategories(for: .skip)
        var parts: [String] = []
        if !linked.isEmpty {
            parts.append("Link \(Self.format(linked))")
        }
        if !copied.isEmpty {
            parts.append("Copy \(Self.format(copied))")
        }
        if copied.isEmpty && linked.isEmpty {
            parts.append("Empty")
        } else if !skipped.isEmpty && skipped.count <= 3 {
            parts.append("Skip \(Self.format(skipped))")
        }
        return parts.joined(separator: " • ")
    }

    public var linkedCategoryCount: Int {
        labeledCategories(for: .link).count
    }

    public var copiedCategoryCount: Int {
        labeledCategories(for: .copy).count
    }

    public var skippedCategoryCount: Int {
        labeledCategories(for: .skip).count
    }

    public subscript(category: CloneCategory) -> ClonePolicy {
        get {
            switch category {
            case .config: config
            case .skills: skills
            case .plugins: plugins
            case .prompts: prompts
            case .rules: rules
            case .profiles: profiles
            case .auth: auth
            case .agents: agents
            case .browserSupport: browserSupport
            case .memories: memories
            case .sessionsAndLogs: sessionsAndLogs
            }
        }
        set {
            switch category {
            case .config: config = newValue
            case .skills: skills = newValue
            case .plugins: plugins = newValue
            case .prompts: prompts = newValue
            case .rules: rules = newValue
            case .profiles: profiles = newValue
            case .auth: auth = newValue
            case .agents: agents = newValue
            case .browserSupport: browserSupport = newValue
            case .memories: memories = newValue
            case .sessionsAndLogs: sessionsAndLogs = newValue
            }
        }
    }

    private var allIncluded: Bool {
        config != .skip
            && auth != .skip
            && skills != .skip
            && plugins != .skip
            && agents != .skip
            && prompts != .skip
            && rules != .skip
            && profiles != .skip
            && memories != .skip
            && browserSupport != .skip
            && sessionsAndLogs != .skip
    }

    private static func policy(included: Bool, linked: Bool) -> ClonePolicy {
        guard included else {
            return .skip
        }
        return linked ? .link : .copy
    }

    private func labeledCategories(for policy: ClonePolicy) -> [String] {
        CloneCategory.allCases.compactMap { self[$0] == policy ? $0.summaryLabel : nil }
    }

    private static func format(_ labels: [String]) -> String {
        if labels.count == 11 {
            return "everything"
        }
        if labels.count > 3 {
            return "\(labels.count) categories"
        }
        return labels.joined(separator: ", ")
    }
}

public struct CloneOptions: Codable, Equatable, Sendable {
    public var config: Bool
    public var auth: Bool
    public var skills: Bool
    public var plugins: Bool
    public var agents: Bool
    public var prompts: Bool
    public var rules: Bool
    public var profiles: Bool
    public var memories: Bool
    public var browserSupport: Bool
    public var sessionsAndLogs: Bool
    public var everything: Bool

    public init(
        config: Bool = true,
        auth: Bool = true,
        skills: Bool = true,
        plugins: Bool = true,
        agents: Bool = true,
        prompts: Bool = true,
        rules: Bool = true,
        profiles: Bool = true,
        memories: Bool = true,
        browserSupport: Bool = true,
        sessionsAndLogs: Bool = false,
        everything: Bool = false
    ) {
        self.config = config
        self.auth = auth
        self.skills = skills
        self.plugins = plugins
        self.agents = agents
        self.prompts = prompts
        self.rules = rules
        self.profiles = profiles
        self.memories = memories
        self.browserSupport = browserSupport
        self.sessionsAndLogs = sessionsAndLogs
        self.everything = everything
    }

    public static let empty = CloneOptions(
        config: false,
        auth: false,
        skills: false,
        plugins: false,
        agents: false,
        prompts: false,
        rules: false,
        profiles: false,
        memories: false,
        browserSupport: false,
        sessionsAndLogs: false,
        everything: false
    )

    public static let configOnly = CloneOptions(
        config: true,
        auth: false,
        skills: true,
        plugins: true,
        agents: false,
        prompts: true,
        rules: true,
        profiles: true,
        memories: false,
        browserSupport: false,
        sessionsAndLogs: false,
        everything: false
    )

    public static let workingSetup = CloneOptions()

    public static let full = CloneOptions(
        config: true,
        auth: true,
        skills: true,
        plugins: true,
        agents: true,
        prompts: true,
        rules: true,
        profiles: true,
        memories: true,
        browserSupport: true,
        sessionsAndLogs: true,
        everything: true
    )

    public static let allIncluded = CloneOptions(
        config: true,
        auth: true,
        skills: true,
        plugins: true,
        agents: true,
        prompts: true,
        rules: true,
        profiles: true,
        memories: true,
        browserSupport: true,
        sessionsAndLogs: true,
        everything: true
    )

    public static func preset(_ preset: ClonePreset) -> CloneOptions {
        switch preset {
        case .empty: .empty
        case .configOnly: .configOnly
        case .workingSetup: .workingSetup
        case .everything: .full
        }
    }
}

public func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
    let left = versionComponents(lhs)
    let right = versionComponents(rhs)
    let count = max(left.count, right.count)

    for index in 0..<count {
        let leftValue = index < left.count ? left[index] : 0
        let rightValue = index < right.count ? right[index] : 0
        if leftValue > rightValue {
            return .orderedDescending
        }
        if leftValue < rightValue {
            return .orderedAscending
        }
    }

    return .orderedSame
}

private func versionComponents(_ version: String) -> [Int] {
    version
        .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
        .split(separator: ".")
        .map { part in
            let digits = part.prefix { $0.isNumber }
            return Int(digits) ?? 0
        }
}

public struct DiagnosticReport: Equatable, Sendable {
    public var globalCodexHome: String?
    public var mainSessionCount: Int
    public var suspiciousLaunchers: [String]
    public var codexBinaryPath: String?
    public var codexAppExists: Bool
    public var authStatus: CodexAuthStatus
    public var notes: [String]

    public init(
        globalCodexHome: String?,
        mainSessionCount: Int,
        suspiciousLaunchers: [String],
        codexBinaryPath: String?,
        codexAppExists: Bool,
        authStatus: CodexAuthStatus = CodexAuthStatus(),
        notes: [String]
    ) {
        self.globalCodexHome = globalCodexHome
        self.mainSessionCount = mainSessionCount
        self.suspiciousLaunchers = suspiciousLaunchers
        self.codexBinaryPath = codexBinaryPath
        self.codexAppExists = codexAppExists
        self.authStatus = authStatus
        self.notes = notes
    }
}

public struct CodexAuthStatus: Equatable, Sendable {
    public var isLoggedIn: Bool
    public var hasStoredCredentials: Bool
    public var mode: String?
    public var accountLabel: String?
    public var detail: String?
    public var usageSummary: String?

    public init(
        isLoggedIn: Bool = false,
        hasStoredCredentials: Bool = false,
        mode: String? = nil,
        accountLabel: String? = nil,
        detail: String? = nil,
        usageSummary: String? = nil
    ) {
        self.isLoggedIn = isLoggedIn
        self.hasStoredCredentials = hasStoredCredentials
        self.mode = mode
        self.accountLabel = accountLabel
        self.detail = detail
        self.usageSummary = usageSummary
    }
}
