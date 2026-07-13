import Foundation
import Darwin

public struct MitmProxyStatus: Sendable {
    public let isRunning: Bool
    public let pid: Int32?
    public let executablePath: String?
    public let logPath: String
    public let caCertificatePath: String
    public let flowArchivePath: String
    public let proxyURL: String
    public let webURL: String
    public let webToken: String?
}

public struct MitmProxyManager {
    private let paths: HomeportPaths
    private let fileManager: FileManager

    public init(paths: HomeportPaths = HomeportPaths(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    private var directory: URL { paths.appSupportDirectory.appendingPathComponent("mitmproxy", isDirectory: true) }
    private func sessionDirectory(_ homeID: UUID?) -> URL {
        guard let homeID else { return directory.appendingPathComponent("shared", isDirectory: true) }
        return directory.appendingPathComponent("homes/\(homeID.uuidString.lowercased())", isDirectory: true)
    }
    private func pidFile(_ homeID: UUID?) -> URL { sessionDirectory(homeID).appendingPathComponent("mitmweb.pid") }
    public func logFile(_ homeID: UUID?) -> URL { sessionDirectory(homeID).appendingPathComponent("mitmweb.log") }
    public var caCertificate: URL { directory.appendingPathComponent("mitmproxy-ca-cert.pem") }
    public func flowArchive(_ homeID: UUID?) -> URL { sessionDirectory(homeID).appendingPathComponent("flows.mitm") }

    public func ports(for homeID: UUID?) -> (proxy: Int, web: Int) {
        guard let homeID else { return (8080, 8081) }
        let bytes = withUnsafeBytes(of: homeID.uuid) { Array($0) }
        let hash = bytes.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 }
        let slot = Int(hash % 4000)
        return (18000 + slot, 23000 + slot)
    }

    public func status(homeID: UUID? = nil) -> MitmProxyStatus {
        let ports = ports(for: homeID)
        let pid = storedPID(homeID)
        let running = pid.map(processIsManaged) ?? false
        let token = webToken(homeID)
        return MitmProxyStatus(
            isRunning: running,
            pid: running ? pid : nil,
            executablePath: bundledExecutable()?.path,
            logPath: logFile(homeID).path,
            caCertificatePath: caCertificate.path,
            flowArchivePath: flowArchive(homeID).path,
            proxyURL: "http://127.0.0.1:\(ports.proxy)",
            webURL: token.map { "http://127.0.0.1:\(ports.web)/?token=\($0)" }
                ?? "http://127.0.0.1:\(ports.web)",
            webToken: token
        )
    }

    @discardableResult
    public func start(homeID: UUID? = nil) throws -> MitmProxyStatus {
        let current = status(homeID: homeID)
        if current.isRunning { return current }
        let ports = ports(for: homeID)
        guard let executable = bundledExecutable() else {
            throw HomeportError.commandFailed("Bundled mitmproxy runtime is missing. Run scripts/prepare-mitmproxy-runtime.sh before building the app.")
        }
        let session = sessionDirectory(homeID)
        try fileManager.createDirectory(at: session, withIntermediateDirectories: true)
        let token = try createWebToken(homeID)
        let logURL = logFile(homeID)
        if !fileManager.fileExists(atPath: logURL.path) { fileManager.createFile(atPath: logURL.path, contents: nil) }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        process.environment = environment
        process.arguments = [
            "--listen-host", "127.0.0.1",
            "--listen-port", String(ports.proxy),
            "--web-host", "127.0.0.1",
            "--web-port", String(ports.web),
            "--set", "web_open_browser=false",
            "--set", "web_password=\(token)",
            "--set", "confdir=\(directory.path)",
            "--save-stream-file", flowArchive(homeID).path
        ]
        process.standardOutput = log
        process.standardError = log
        try process.run()
        try String(process.processIdentifier).write(to: pidFile(homeID), atomically: true, encoding: .utf8)

        for _ in 0..<30 {
            if !process.isRunning {
                throw HomeportError.commandFailed("Bundled mitmweb exited during startup. See \(logURL.path).")
            }
            if fileManager.fileExists(atPath: caCertificate.path) {
                return status(homeID: homeID)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return status(homeID: homeID)
    }

    public func stop(homeID: UUID? = nil) throws {
        guard let pid = storedPID(homeID), processIsManaged(pid) else {
            try? fileManager.removeItem(at: pidFile(homeID))
            return
        }
        guard kill(pid, SIGTERM) == 0 else {
            throw HomeportError.commandFailed("Could not stop bundled mitmweb process \(pid).")
        }
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { break }
            Thread.sleep(forTimeInterval: 0.1)
        }
        try? fileManager.removeItem(at: pidFile(homeID))
    }

    private func storedPID(_ homeID: UUID?) -> Int32? {
        guard let text = try? String(contentsOf: pidFile(homeID), encoding: .utf8) else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func tokenFile(_ homeID: UUID?) -> URL {
        sessionDirectory(homeID).appendingPathComponent("web-token")
    }

    private func webToken(_ homeID: UUID?) -> String? {
        guard let value = try? String(contentsOf: tokenFile(homeID), encoding: .utf8) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func createWebToken(_ homeID: UUID?) throws -> String {
        if let existing = webToken(homeID) { return existing }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let file = tokenFile(homeID)
        try token.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }

    private func processIsManaged(_ pid: Int32) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let command = String(data: data, encoding: .utf8) else { return false }
        return command.contains("mitmproxy.app/Contents/MacOS/mitmweb")
    }

    private func bundledExecutable() -> URL? {
        if let override = ProcessInfo.processInfo.environment["HOMEPORT_MITMPROXY_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let relative = "mitmproxy-runtime/\(architecture)/mitmproxy.app/Contents/MacOS/mitmweb"
        let installedResources = paths.homeDirectory
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(paths.channel.appBundleName, isDirectory: true)
                .appendingPathComponent("Contents/Resources", isDirectory: true)
        let resourceBundle = "CodexMultihome_CodexMultihomeApp.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(relative),
            Bundle.main.resourceURL?.appendingPathComponent(resourceBundle).appendingPathComponent(relative),
            installedResources.appendingPathComponent(relative),
            installedResources.appendingPathComponent(resourceBundle).appendingPathComponent(relative)
        ].compactMap { $0 }
        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
