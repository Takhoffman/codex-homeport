import Foundation

public let computerUseAllowForbiddenTargetsKey = "ComputerUseAllowForbiddenTargets"

public enum ComputerUseDefaults {
    public static func readAllowForbiddenTargets() -> Bool? {
        let result = runDefaults(["read", "-g", computerUseAllowForbiddenTargetsKey])
        guard result.status == 0 else { return nil }
        switch result.output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes":
            return true
        case "0", "false", "no":
            return false
        default:
            return nil
        }
    }

    public static func setAllowForbiddenTargets(_ isEnabled: Bool) throws {
        let result = runDefaults(["write", "-g", computerUseAllowForbiddenTargetsKey, "-bool", isEnabled ? "YES" : "NO"])
        guard result.status == 0 else {
            throw HomeportError.commandFailed("Could not update \(computerUseAllowForbiddenTargetsKey): \(result.output)")
        }
    }

    public static func applyInstallSupport(in homeURL: URL, isEnabled: Bool, fileManager: FileManager = .default) throws {
        try setBundledComputerUsePluginForDefaultInstall(in: homeURL, isEnabled: isEnabled, fileManager: fileManager)
        try patchCachedComputerUseSkillForForbiddenTargets(in: homeURL, fileManager: fileManager)
    }

    private static func runDefaults(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (1, error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}

let computerUseDefaultInstallBegin = "# >>> codex-multihome computer use defaults >>>"
let computerUseDefaultInstallEnd = "# <<< codex-multihome computer use defaults <<<"
let forbiddenComputerUseTargetsMarker = "## Forbidden Computer Use Targets"
let forbiddenComputerUseTargetsEndMarker = "<!-- codex-multihome-forbidden-computer-use-targets-end -->"

let forbiddenComputerUseTargetsInstructions = """

## Forbidden Computer Use Targets

Codex Multihome can enable Apple's global `ComputerUseAllowForbiddenTargets` default during setup. If a requested app-control target appears unavailable even though Accessibility and Screen Recording permissions are granted, check the machine default with:

```sh
defaults read -g ComputerUseAllowForbiddenTargets
```

When the user asks to enable full Computer Use target access, set it with:

```sh
defaults write -g ComputerUseAllowForbiddenTargets -bool YES
```
\(forbiddenComputerUseTargetsEndMarker)
"""

func setBundledComputerUsePluginForDefaultInstall(in homeURL: URL, isEnabled: Bool, fileManager: FileManager = .default) throws {
    let configURL = homeURL.appendingPathComponent("config.toml")
    let existing = fileManager.fileExists(atPath: configURL.path)
        ? try String(contentsOf: configURL, encoding: .utf8)
        : ""
    let cleaned = removeMarkedBlock(
        from: existing,
        begin: computerUseDefaultInstallBegin,
        end: computerUseDefaultInstallEnd
    ).trimmingCharacters(in: .whitespacesAndNewlines)

    guard isEnabled else {
        if cleaned != existing.trimmingCharacters(in: .whitespacesAndNewlines) {
            try cleaned.appending(cleaned.isEmpty ? "" : "\n").write(to: configURL, atomically: true, encoding: .utf8)
        }
        return
    }

    let pluginTable = #"[plugins."computer-use@openai-bundled"]"#
    guard !cleaned.contains(pluginTable) else { return }

    let pluginBlock = """

\(computerUseDefaultInstallBegin)
\(pluginTable)
enabled = true
\(computerUseDefaultInstallEnd)
"""
    let next = cleaned.isEmpty ? pluginBlock.trimmingCharacters(in: .newlines) + "\n" : cleaned + "\n" + pluginBlock + "\n"
    try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
    try next.write(to: configURL, atomically: true, encoding: .utf8)
}

func patchCachedComputerUseSkillForForbiddenTargets(in homeURL: URL, fileManager: FileManager = .default) throws {
    let pluginsURL = homeURL.appendingPathComponent("plugins/cache", isDirectory: true)
    guard fileManager.fileExists(atPath: pluginsURL.path) else { return }

    let enumerator = fileManager.enumerator(
        at: pluginsURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
    )
    while let skillURL = enumerator?.nextObject() as? URL {
        guard skillURL.lastPathComponent == "SKILL.md" else { continue }
        guard skillURL.path.contains("/computer-use/") && skillURL.path.contains("/skills/computer-use/") else { continue }
        let values = try skillURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let text = try String(contentsOf: skillURL, encoding: .utf8)
        let cleaned = removeForbiddenComputerUseTargetsInstructions(from: text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let next = cleaned + forbiddenComputerUseTargetsInstructions
        guard next != text else { continue }
        try next.write(to: skillURL, atomically: true, encoding: .utf8)
    }
}

func removeForbiddenComputerUseTargetsInstructions(from text: String) -> String {
    guard let beginRange = text.range(of: forbiddenComputerUseTargetsMarker) else { return text }
    if let endRange = text[beginRange.upperBound...].range(of: forbiddenComputerUseTargetsEndMarker) {
        var remaining = text
        remaining.removeSubrange(beginRange.lowerBound..<endRange.upperBound)
        return remaining
    }
    return String(text[..<beginRange.lowerBound])
}
