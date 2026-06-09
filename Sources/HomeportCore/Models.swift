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
    public var createdAt: Date
    public var isTemporary: Bool
    public var promotedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        kind: HomeKind,
        homePath: String,
        profilePath: String?,
        sourceHomePath: String? = nil,
        clonePreset: ClonePreset? = nil,
        createdAt: Date = Date(),
        isTemporary: Bool = false,
        promotedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.kind = kind
        self.homePath = homePath
        self.profilePath = profilePath
        self.sourceHomePath = sourceHomePath
        self.clonePreset = clonePreset
        self.createdAt = createdAt
        self.isTemporary = isTemporary
        self.promotedAt = promotedAt
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
    public var launchTemporaryByDefault: Bool
    public var onboardEnablesAutostart: Bool
    public var installAppByDefault: Bool
    public var autoUpdateChecksEnabled: Bool
    public var autoInstallUpdates: Bool
    public var updateCheckInterval: UpdateCheckInterval

    public init(
        defaultLaunchTarget: LaunchTarget = .desktop,
        defaultClonePreset: ClonePreset = .workingSetup,
        cloneOptions: CloneOptions = CloneOptions.workingSetup,
        launchTemporaryByDefault: Bool = false,
        onboardEnablesAutostart: Bool = true,
        installAppByDefault: Bool = true,
        autoUpdateChecksEnabled: Bool = true,
        autoInstallUpdates: Bool = false,
        updateCheckInterval: UpdateCheckInterval = .daily
    ) {
        self.defaultLaunchTarget = defaultLaunchTarget
        self.defaultClonePreset = defaultClonePreset
        self.cloneOptions = cloneOptions
        self.launchTemporaryByDefault = launchTemporaryByDefault
        self.onboardEnablesAutostart = onboardEnablesAutostart
        self.installAppByDefault = installAppByDefault
        self.autoUpdateChecksEnabled = autoUpdateChecksEnabled
        self.autoInstallUpdates = autoInstallUpdates
        self.updateCheckInterval = updateCheckInterval
    }

    enum CodingKeys: String, CodingKey {
        case defaultLaunchTarget
        case defaultClonePreset
        case cloneOptions
        case launchTemporaryByDefault
        case onboardEnablesAutostart
        case installAppByDefault
        case autoUpdateChecksEnabled
        case autoInstallUpdates
        case updateCheckInterval
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.defaultLaunchTarget = try container.decodeIfPresent(LaunchTarget.self, forKey: .defaultLaunchTarget) ?? .desktop
        self.defaultClonePreset = try container.decodeIfPresent(ClonePreset.self, forKey: .defaultClonePreset) ?? .workingSetup
        self.cloneOptions = try container.decodeIfPresent(CloneOptions.self, forKey: .cloneOptions) ?? .workingSetup
        self.launchTemporaryByDefault = try container.decodeIfPresent(Bool.self, forKey: .launchTemporaryByDefault) ?? false
        self.onboardEnablesAutostart = try container.decodeIfPresent(Bool.self, forKey: .onboardEnablesAutostart) ?? true
        self.installAppByDefault = try container.decodeIfPresent(Bool.self, forKey: .installAppByDefault) ?? true
        self.autoUpdateChecksEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoUpdateChecksEnabled) ?? true
        self.autoInstallUpdates = try container.decodeIfPresent(Bool.self, forKey: .autoInstallUpdates) ?? false
        self.updateCheckInterval = try container.decodeIfPresent(UpdateCheckInterval.self, forKey: .updateCheckInterval) ?? .daily
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
    public var notes: [String]

    public init(
        globalCodexHome: String?,
        mainSessionCount: Int,
        suspiciousLaunchers: [String],
        codexBinaryPath: String?,
        codexAppExists: Bool,
        notes: [String]
    ) {
        self.globalCodexHome = globalCodexHome
        self.mainSessionCount = mainSessionCount
        self.suspiciousLaunchers = suspiciousLaunchers
        self.codexBinaryPath = codexBinaryPath
        self.codexAppExists = codexAppExists
        self.notes = notes
    }
}
