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
    public var preferredTerminal: TerminalApp
    public var lastWorkspacePath: String?
    public var preferences: HomeportPreferences

    public init(
        version: Int = 1,
        homes: [CodexHome] = [],
        instances: [LaunchedInstance] = [],
        preferredTerminal: TerminalApp = .terminal,
        lastWorkspacePath: String? = nil,
        preferences: HomeportPreferences = HomeportPreferences()
    ) {
        self.version = version
        self.homes = homes
        self.instances = instances
        self.preferredTerminal = preferredTerminal
        self.lastWorkspacePath = lastWorkspacePath
        self.preferences = preferences
    }

    enum CodingKeys: String, CodingKey {
        case version
        case homes
        case instances
        case preferredTerminal
        case lastWorkspacePath
        case preferences
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        self.homes = try container.decodeIfPresent([CodexHome].self, forKey: .homes) ?? []
        self.instances = try container.decodeIfPresent([LaunchedInstance].self, forKey: .instances) ?? []
        self.preferredTerminal = try container.decodeIfPresent(TerminalApp.self, forKey: .preferredTerminal) ?? .terminal
        self.lastWorkspacePath = try container.decodeIfPresent(String.self, forKey: .lastWorkspacePath)
        self.preferences = try container.decodeIfPresent(HomeportPreferences.self, forKey: .preferences) ?? HomeportPreferences()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(homes, forKey: .homes)
        try container.encode(instances, forKey: .instances)
        try container.encode(preferredTerminal, forKey: .preferredTerminal)
        try container.encodeIfPresent(lastWorkspacePath, forKey: .lastWorkspacePath)
        try container.encode(preferences, forKey: .preferences)
    }
}

public struct HomeportPreferences: Codable, Equatable, Sendable {
    public var defaultLaunchTarget: LaunchTarget
    public var defaultClonePreset: ClonePreset
    public var launchTemporaryByDefault: Bool
    public var onboardEnablesAutostart: Bool
    public var installAppByDefault: Bool

    public init(
        defaultLaunchTarget: LaunchTarget = .desktop,
        defaultClonePreset: ClonePreset = .workingSetup,
        launchTemporaryByDefault: Bool = false,
        onboardEnablesAutostart: Bool = true,
        installAppByDefault: Bool = true
    ) {
        self.defaultLaunchTarget = defaultLaunchTarget
        self.defaultClonePreset = defaultClonePreset
        self.launchTemporaryByDefault = launchTemporaryByDefault
        self.onboardEnablesAutostart = onboardEnablesAutostart
        self.installAppByDefault = installAppByDefault
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
