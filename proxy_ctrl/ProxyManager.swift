//
//  ProxyManager.swift
//  proxy_ctrl
//

import Combine
import Foundation

enum ProxyMode: String {
    case http, socks, tun, direct
}

struct TunConfig: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var path: String
    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

struct CommandResult: Equatable {
    let exitCode: Int32
    let output: String
    let errorOutput: String

    var succeeded: Bool {
        exitCode == 0
    }

    var failureMessage: String {
        let message = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { return message }

        let output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !output.isEmpty { return output }

        return "Command exited with status \(exitCode)."
    }
}

private struct IPInfoResponse: Decodable {
    let city: String?
}

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var currentMode: ProxyMode = .direct
    @Published var lastError: String? = nil
    @Published var tunLogLines: [String] = []
    @Published var tunLogByteCount: Int = 0
    @Published var connectivityCity: String = "unknown"

    /// Overrides for testing; when non-nil, used instead of UserDefaults.
    var networkServiceOverride: String?
    var httpHostOverride: String?
    var httpPortOverride: String?
    var socksHostOverride: String?
    var socksPortOverride: String?
    var tunConfigPathOverride: String?  // retained for testing only
    var sudoPathOverride: String?
    var launchctlPathOverride: String?
    var curlPathOverride: String?
    var singBoxServiceLabelOverride: String?
    var singBoxConfigLinkPathOverride: String?
    var singBoxLogPathOverride: String?
    @Published var tunConfigs: [TunConfig] = []
    @Published var activeTunConfig: TunConfig? = nil

    /// Hook for testing; when non-nil, called instead of spawning real processes.
    var runWithAuthHandler: ((_ commands: [[String]], _ completion: @escaping () -> Void) -> Void)?
    var privilegedCommandHandler: ((_ arguments: [String]) -> CommandResult)?
    var readCommandHandler: ((_ executablePath: String, _ args: [String]) -> String)?
    var connectivityCommandHandler: (() -> CommandResult)?
    private var tunLogSignature: LogFileSignature?
    private var connectivityTimer: Timer?
    private var isRefreshingConnectivity = false

    // MARK: - Pure helpers (testable)

    nonisolated static func stripANSI(_ str: String) -> String {
        str.replacingOccurrences(of: "\\e\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    nonisolated static func splitLines(_ text: String) -> (lines: [String], remainder: String) {
        guard !text.isEmpty else { return ([], "") }
        let segments = text.components(separatedBy: "\n")
        let lines = Array(segments.dropLast())
        let remainder = text.hasSuffix("\n") ? "" : (segments.last ?? "")
        return (lines, remainder)
    }

    nonisolated static func readLogFile(at path: String, maxBytes: UInt64) throws -> String {
        let url = URL(fileURLWithPath: path)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        if size > maxBytes {
            try handle.seek(toOffset: size - maxBytes)
        }
        let data = try handle.readToEnd() ?? Data()
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    nonisolated static func launchctlOutputIndicatesRunning(_ output: String) -> Bool {
        output.range(
            of: #"(?m)^\s*state\s*=\s*running\s*$"#,
            options: .regularExpression
        ) != nil ||
        output.range(
            of: #"(?m)^\s*(pid|\"PID\")\s*=\s*[1-9][0-9]*\s*;?\s*$"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func normalizedConfigPath(_ path: String, relativeTo basePath: String? = nil) -> String {
        var expanded = NSString(string: path).expandingTildeInPath
        if !expanded.hasPrefix("/"), let basePath {
            expanded = URL(fileURLWithPath: basePath).appendingPathComponent(expanded).path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    nonisolated static func parseConnectivityCity(from output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(IPInfoResponse.self, from: data),
              let city = response.city?.trimmingCharacters(in: .whitespacesAndNewlines),
              !city.isEmpty else {
            return nil
        }
        return city
    }

    private struct LogFileSignature: Equatable {
        let path: String
        let maxBytes: UInt64
        let size: UInt64
        let modificationDate: Date?
    }

    private var networkService: String {
        networkServiceOverride ?? (UserDefaults.standard.string(forKey: "networkService") ?? "Wi-Fi")
    }
    private var httpHost: String {
        httpHostOverride ?? (UserDefaults.standard.string(forKey: "httpHost") ?? "192.168.2.223")
    }
    private var httpPort: String {
        httpPortOverride ?? (UserDefaults.standard.string(forKey: "httpPort") ?? "8899")
    }
    private var socksHost: String {
        socksHostOverride ?? (UserDefaults.standard.string(forKey: "socksHost") ?? "192.168.2.201")
    }
    private var socksPort: String {
        socksPortOverride ?? (UserDefaults.standard.string(forKey: "socksPort") ?? "7788")
    }
    private var singBoxServiceLabel: String {
        singBoxServiceLabelOverride ?? "io.sing-box"
    }
    private var launchctlPath: String {
        launchctlPathOverride ?? "/bin/launchctl"
    }
    private var curlPath: String {
        curlPathOverride ?? "/usr/bin/curl"
    }
    private var singBoxConfigLinkPath: String {
        singBoxConfigLinkPathOverride ?? "/Users/darwin/projects/scripts/sing-box/config.json"
    }
    private var singBoxLogPath: String {
        singBoxLogPathOverride ?? "/var/log/sing-box.log"
    }
    private var sudoPath: String {
        sudoPathOverride ?? "/usr/bin/sudo"
    }
    private init() {
        UserDefaults.standard.register(defaults: [
            "networkService": "Wi-Fi",
            "httpHost": "192.168.2.223",
            "httpPort": "8899",
            "socksHost": "192.168.2.201",
            "socksPort": "7788",
        ])
        if let data = UserDefaults.standard.data(forKey: "tunConfigs"),
           let saved = try? JSONDecoder().decode([TunConfig].self, from: data) {
            tunConfigs = saved
        }
    }

    /// Testing-only initializer that skips side effects.
    init(forTesting: Bool) {
        _ = forTesting
    }

    // MARK: - Proxy actions (each batches into a single auth prompt)

    func applyHTTP() {
        let stopError = stopTun()
        let svc = networkService
        let webHost = httpHost
        let webPort = httpPort
        let cmds: [[String]] = [
            ["-setwebproxy",                svc, webHost, webPort],
            ["-setsecurewebproxy",          svc, webHost, webPort],
            ["-setwebproxystate",         svc, "on"],
            ["-setsecurewebproxystate",   svc, "on"],
            ["-setsocksfirewallproxy",      svc, "", "0"],
            ["-setsocksfirewallproxystate", svc, "off"],
        ]
        runWithAuth(cmds) {
            self.currentMode = .http
            if self.lastError == nil {
                self.lastError = stopError
            }
        }
    }

    func applySOCKS() {
        let stopError = stopTun()
        let svc = networkService
        let host = socksHost
        let port = socksPort
        let cmds: [[String]] = [
            ["-setsocksfirewallproxy",      svc, host, port],
            ["-setsocksfirewallproxystate", svc, "on"],
            ["-setwebproxy",                svc, "", "0"],
            ["-setsecurewebproxy",          svc, "", "0"],
            ["-setwebproxystate",           svc, "off"],
            ["-setsecurewebproxystate",     svc, "off"],
        ]
        runWithAuth(cmds) {
            self.currentMode = .socks
            if self.lastError == nil {
                self.lastError = stopError
            }
        }
    }

    func applyDirect() {
        let stopError = stopTun()
        let svc = networkService
        let cmds: [[String]] = [
            ["-setwebproxy",                svc, "", "0"],
            ["-setsecurewebproxy",          svc, "", "0"],
            ["-setsocksfirewallproxy",      svc, "", "0"],
            ["-setwebproxystate",           svc, "off"],
            ["-setsecurewebproxystate",     svc, "off"],
            ["-setsocksfirewallproxystate", svc, "off"],
        ]
        runWithAuth(cmds) {
            self.currentMode = .direct
            if self.lastError == nil {
                self.lastError = stopError
            }
        }
    }

    func applyTun() {
        // No-arg variant used in tests via tunConfigPathOverride.
        guard let path = tunConfigPathOverride else {
            lastError = "Please choose a sing-box config file in Settings."
            return
        }
        startTun(rawPath: path)
    }

    func applyTun(config: TunConfig) {
        startTun(rawPath: config.path, activeConfig: config)
    }

    private func startTun(rawPath: String, activeConfig: TunConfig? = nil) {
        let configPath = NSString(string: rawPath).expandingTildeInPath
        guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Please choose a sing-box config file in Settings."
            return
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            lastError = "sing-box config file not found: \(configPath)"
            return
        }

        do {
            try updateSingBoxConfigLink(to: configPath)
        } catch {
            lastError = error.localizedDescription
            return
        }

        _ = stopTun(force: true)
        clearTunLog()
        let result = runLaunchctl("start")
        if result.succeeded {
            activeTunConfig = activeConfig
            currentMode = .tun
            lastError = nil
        } else {
            activeTunConfig = nil
            currentMode = .direct
            lastError = "Failed to start sing-box service: \(result.failureMessage)"
        }
    }

    func clearTunLog() {
        tunLogSignature = nil
        setTunLog(lines: [], byteCount: 0)
    }

    func reloadTunLogFromFile(maxBytes: UInt64 = 1_048_576) {
        let path = singBoxLogPath
        guard
            FileManager.default.fileExists(atPath: path),
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        else {
            tunLogSignature = nil
            setTunLog(lines: [], byteCount: 0)
            return
        }

        let signature = LogFileSignature(
            path: path,
            maxBytes: maxBytes,
            size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
            modificationDate: attributes[.modificationDate] as? Date
        )
        guard signature != tunLogSignature else { return }

        do {
            let text = try Self.readLogFile(at: path, maxBytes: maxBytes)
            let clean = Self.stripANSI(text)
            let split = Self.splitLines(clean)
            let lines = split.remainder.isEmpty ? split.lines : split.lines + [split.remainder]
            tunLogSignature = signature
            setTunLog(lines: lines, byteCount: lines.reduce(0) { $0 + $1.utf8.count })
        } catch {
            tunLogSignature = nil
            setTunLog(lines: ["Failed to read sing-box log: \(error.localizedDescription)"], byteCount: 0)
        }
    }

    private func setTunLog(lines: [String], byteCount: Int) {
        if tunLogLines != lines {
            tunLogLines = lines
        }
        if tunLogByteCount != byteCount {
            tunLogByteCount = byteCount
        }
    }

    func addTunConfig(name: String, path: String) {
        tunConfigs.append(TunConfig(name: name, path: path))
        saveTunConfigs()
    }

    func removeTunConfig(id: UUID) {
        tunConfigs.removeAll { $0.id == id }
        saveTunConfigs()
    }

    func saveTunConfigs() {
        if let data = try? JSONEncoder().encode(tunConfigs) {
            UserDefaults.standard.set(data, forKey: "tunConfigs")
        }
    }

    private func updateSingBoxConfigLink(to configPath: String) throws {
        let fileManager = FileManager.default
        let linkPath = singBoxConfigLinkPath
        let linkURL = URL(fileURLWithPath: linkPath)
        let parentURL = linkURL.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parentURL.path) else {
            throw NSError(
                domain: "proxy_ctrl.sing-box",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "sing-box config link directory not found: \(parentURL.path)"]
            )
        }

        let tempPath = linkPath + ".proxy_ctrl.\(UUID().uuidString).tmp"
        defer { try? fileManager.removeItem(atPath: tempPath) }

        try fileManager.createSymbolicLink(atPath: tempPath, withDestinationPath: configPath)

        if (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) != nil {
            try fileManager.removeItem(atPath: linkPath)
        } else if fileManager.fileExists(atPath: linkPath) {
            throw NSError(
                domain: "proxy_ctrl.sing-box",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Refusing to replace non-symlink sing-box config: \(linkPath)"]
            )
        }

        try fileManager.moveItem(atPath: tempPath, toPath: linkPath)
    }

    @discardableResult
    private func stopTun(force: Bool = false) -> String? {
        guard force || currentMode == .tun || activeTunConfig != nil else { return nil }

        let result = runLaunchctl("stop")
        activeTunConfig = nil
        if currentMode == .tun {
            currentMode = .direct
        }

        guard !result.succeeded else { return nil }
        return "Failed to stop sing-box service: \(result.failureMessage)"
    }

    // MARK: - State detection

    func startConnectivityUpdates(interval: TimeInterval = 180) {
        connectivityTimer?.invalidate()
        refreshConnectivity()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshConnectivity()
        }
        timer.tolerance = min(30, max(1, interval * 0.1))
        connectivityTimer = timer
    }

    func stopConnectivityUpdates() {
        connectivityTimer?.invalidate()
        connectivityTimer = nil
    }

    func refreshConnectivity() {
        guard !isRefreshingConnectivity else { return }
        isRefreshingConnectivity = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let city = self.fetchConnectivityCity()
            DispatchQueue.main.async {
                self.connectivityCity = city
                self.isRefreshingConnectivity = false
            }
        }
    }

    func refreshCurrentMode() {
        let svc = networkService
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if self.isSingBoxServiceRunning() {
                let activeConfig = self.activeTunConfigFromConfigLink()
                DispatchQueue.main.async {
                    self.activeTunConfig = activeConfig
                    self.currentMode = .tun
                }
                return
            }

            let httpOut  = self.readCommand(["-getwebproxy",          svc])
            let socksOut = self.readCommand(["-getsocksfirewallproxy", svc])
            DispatchQueue.main.async {
                self.activeTunConfig = nil
                if httpOut.contains("Enabled: Yes") {
                    self.currentMode = .http
                } else if socksOut.contains("Enabled: Yes") {
                    self.currentMode = .socks
                } else {
                    self.currentMode = .direct
                }
            }
        }
    }

    // MARK: - Execution helpers

    private func fetchConnectivityCity() -> String {
        let result: CommandResult
        if let handler = connectivityCommandHandler {
            result = handler()
        } else {
            result = runCurl(["-fsS", "--max-time", "10", "https://ipinfo.io/"])
        }

        guard result.succeeded,
              let city = Self.parseConnectivityCity(from: result.output) else {
            return "unknown"
        }
        return city
    }

    private func runCurl(_ arguments: [String]) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: curlPath)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return CommandResult(
                exitCode: 127,
                output: "",
                errorOutput: "exec failed: \(error.localizedDescription)"
            )
        }

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: proc.terminationStatus, output: output, errorOutput: errorOutput)
    }

    private func runLaunchctl(_ action: String) -> CommandResult {
        runPrivilegedCommand([launchctlPath, action, singBoxServiceLabel])
    }

    private func isSingBoxServiceRunning() -> Bool {
        let printResult = runPrivilegedCommand([launchctlPath, "print", "system/\(singBoxServiceLabel)"])
        if printResult.succeeded {
            return Self.launchctlOutputIndicatesRunning(printResult.output)
        }

        let listResult = runPrivilegedCommand([launchctlPath, "list", singBoxServiceLabel])
        guard listResult.succeeded else { return false }
        return Self.launchctlOutputIndicatesRunning(listResult.output)
    }

    private func activeTunConfigFromConfigLink() -> TunConfig? {
        let linkPath = singBoxConfigLinkPath
        guard let linkedPath = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) else {
            return nil
        }

        let linkDirectory = URL(fileURLWithPath: linkPath).deletingLastPathComponent().path
        let normalizedLinkedPath = Self.normalizedConfigPath(linkedPath, relativeTo: linkDirectory)
        return tunConfigs.first {
            Self.normalizedConfigPath($0.path) == normalizedLinkedPath
        }
    }

    private func runPrivilegedCommand(_ arguments: [String]) -> CommandResult {
        if let handler = privilegedCommandHandler {
            return handler(arguments)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: sudoPath)
        proc.arguments = ["-n"] + arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return CommandResult(
                exitCode: 127,
                output: "",
                errorOutput: "exec failed: \(error.localizedDescription)"
            )
        }

        let output = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errorOutput = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return CommandResult(exitCode: proc.terminationStatus, output: output, errorOutput: errorOutput)
    }

    /// Run multiple networksetup commands directly.
    private func runWithAuth(_ commands: [[String]], completion: @escaping () -> Void) {
        if let handler = runWithAuthHandler {
            handler(commands, completion)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            var errors: [String] = []
            for args in commands {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                proc.arguments = args
                proc.standardOutput = Pipe()
                let errPipe = Pipe()
                proc.standardError = errPipe
                do {
                    try proc.run()
                    proc.waitUntilExit()
                    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if let msg = String(data: errData, encoding: .utf8),
                       !msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        errors.append(msg.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                } catch {
                    errors.append("exec failed: \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                self.lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
                completion()
            }
        }
    }

    /// Read networksetup output (no auth needed for reads).
    private func readCommand(_ args: [String]) -> String {
        readCommand(at: "/usr/sbin/networksetup", args: args)
    }

    func readCommand(at executablePath: String, args: [String]) -> String {
        if let handler = readCommandHandler {
            return handler(executablePath, args)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executablePath)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return ""
        }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }


}
