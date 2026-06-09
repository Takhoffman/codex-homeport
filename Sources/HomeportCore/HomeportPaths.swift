import Foundation

public struct HomeportPaths: Sendable {
    public let homeDirectory: URL

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.homeDirectory = homeDirectory
    }

    public var mainCodexHome: URL {
        homeDirectory.appendingPathComponent(".codex", isDirectory: true)
    }

    public var managedHomesDirectory: URL {
        homeDirectory.appendingPathComponent(".codex-homes", isDirectory: true)
    }

    public var appSupportDirectory: URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("CodexHomeport", isDirectory: true)
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

    public var codexAppExecutable: URL {
        URL(fileURLWithPath: "/Applications/Codex.app/Contents/MacOS/Codex")
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

public func timestampSlug(prefix: String, date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return "\(prefix)-\(formatter.string(from: date))"
}
