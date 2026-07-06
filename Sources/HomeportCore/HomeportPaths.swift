import Foundation

public enum HomeportChannel: String, Codable, CaseIterable, Sendable {
    case live
    case dev

    public var appName: String {
        switch self {
        case .live: "Codex Multihome"
        case .dev: "Codex Multihome Dev"
        }
    }

    public var appBundleName: String {
        "\(appName).app"
    }

    public var bundleIdentifier: String {
        switch self {
        case .live: "com.takhoffman.codex-multihome"
        case .dev: "com.takhoffman.codex-multihome.dev"
        }
    }

    public var appSupportName: String {
        switch self {
        case .live: "CodexMultihome"
        case .dev: "CodexMultihomeDev"
        }
    }

    public var legacyAppSupportName: String {
        switch self {
        case .live: "CodexHomeport"
        case .dev: "CodexHomeportDev"
        }
    }

    public var managedHomesName: String {
        switch self {
        case .live: ".codex-homes"
        case .dev: ".codex-homes-dev"
        }
    }

    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> HomeportChannel {
        if let raw = environment["HOMEPORT_CHANNEL"], let channel = HomeportChannel(rawValue: raw) {
            return channel
        }
        if let raw = bundle.object(forInfoDictionaryKey: "HomeportChannel") as? String,
           let channel = HomeportChannel(rawValue: raw) {
            return channel
        }
        return .live
    }
}

public struct HomeportPaths: Sendable {
    public let homeDirectory: URL
    public let channel: HomeportChannel

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        channel: HomeportChannel = .current()
    ) {
        self.homeDirectory = homeDirectory
        self.channel = channel
    }

    public var mainCodexHome: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public var managedHomesDirectory: URL {
        homeDirectory.appendingPathComponent(channel.managedHomesName, isDirectory: true)
    }

    public var appSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(channel.appSupportName, isDirectory: true)
    }

    public var legacyAppSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(channel.legacyAppSupportName, isDirectory: true)
    }

    public var legacyStateFile: URL {
        legacyAppSupportDirectory.appendingPathComponent("homeport.json")
    }

    public var profilesDirectory: URL {
        appSupportDirectory.appendingPathComponent("Profiles", isDirectory: true)
    }

    public var stateFile: URL {
        appSupportDirectory.appendingPathComponent("homeport.json")
    }

    public var updateLogFile: URL {
        appSupportDirectory.appendingPathComponent("update.log")
    }

    public var codexAppBundle: URL {
        URL(fileURLWithPath: "/Applications/Codex.app", isDirectory: true)
    }

    public var codexAppExecutable: URL {
        codexAppBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("Codex")
    }

    public var normalCodexProfile: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Codex", isDirectory: true)
    }

    public var desktopDirectory: URL {
        homeDirectory.appendingPathComponent("Desktop", isDirectory: true)
    }
}

public enum HomeportError: LocalizedError, Equatable {
    case homeDoesNotExist(String)
    case homeAlreadyExists(String)
    case invalidName(String)
    case unsupportedCommand(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .homeDoesNotExist(let path):
            "Codex home does not exist: \(path)"
        case .homeAlreadyExists(let path):
            "Codex home already exists: \(path)"
        case .invalidName(let name):
            "Invalid name: \(name)"
        case .unsupportedCommand(let command):
            "Unsupported command: \(command)"
        case .commandFailed(let message):
            message
        }
    }
}

public func slugify(_ raw: String) -> String {
    let lowered = raw.lowercased()
    var result = ""
    var lastWasDash = false

    for scalar in lowered.unicodeScalars {
        let isAllowed = CharacterSet.alphanumerics.contains(scalar)
        if isAllowed {
            result.unicodeScalars.append(scalar)
            lastWasDash = false
        } else if !lastWasDash {
            result.append("-")
            lastWasDash = true
        }
    }

    let trimmed = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return trimmed.isEmpty ? "home" : trimmed
}

public func suggestedHomeName(fromHomePath path: String) -> String? {
    let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return nil
    }
    let expandedPath = NSString(string: trimmed).expandingTildeInPath
    let lastComponent = URL(fileURLWithPath: expandedPath, isDirectory: true).standardizedFileURL.lastPathComponent
    return lastComponent.isEmpty ? nil : lastComponent
}

public func timestampSlug(prefix: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(prefix)-\(formatter.string(from: date))"
}
