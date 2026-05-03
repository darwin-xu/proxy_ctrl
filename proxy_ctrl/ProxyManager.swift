//
//  ProxyManager.swift
//  proxy_ctrl
//

import Combine
import Foundation

enum ProxyMode: String {
    case http, socks, tun, direct
}

struct TunConfig: Identifiable, Codable {
    var id: UUID
    var name: String
    var path: String
    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var currentMode: ProxyMode = .direct
    @Published var lastError: String? = nil
    @Published var tunLogLines: [String] = []
    @Published var tunLogByteCount: Int = 0

    /// Overrides for testing; when non-nil, used instead of UserDefaults.
    var networkServiceOverride: String?
    var httpHostOverride: String?
    var httpPortOverride: String?
    var socksHostOverride: String?
    var socksPortOverride: String?
    var tunConfigPathOverride: String?  // retained for testing only
    @Published var tunConfigs: [TunConfig] = []
    @Published var activeTunConfig: TunConfig? = nil

    /// Hook for testing; when non-nil, called instead of spawning real processes.
    var runWithAuthHandler: ((_ commands: [[String]], _ completion: @escaping () -> Void) -> Void)?

    private var tunProcess: Process?
    private var tunOutputPipe: Pipe?
    private var tunErrorPipe: Pipe?
    private let tunLogQueue = DispatchQueue(label: "proxy_ctrl.tunLog")
    private var pendingChunks: [String] = []
    private var incompleteLine = ""
    private var isFlushScheduled = false

    // MARK: - Pure helpers (testable)

    static func stripANSI(_ str: String) -> String {
        str.replacingOccurrences(of: "\\e\\[[0-9;]*m", with: "", options: .regularExpression)
    }

    static func splitLines(_ text: String) -> (lines: [String], remainder: String) {
        guard !text.isEmpty else { return ([], "") }
        let segments = text.components(separatedBy: "\n")
        let lines = Array(segments.dropLast())
        let remainder = text.hasSuffix("\n") ? "" : (segments.last ?? "")
        return (lines, remainder)
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
        refreshCurrentMode()
    }

    /// Testing-only initializer that skips side effects.
    init(forTesting: Bool) {
        _ = forTesting
    }

    // MARK: - Proxy actions (each batches into a single auth prompt)

    func applyHTTP() {
        stopTun()
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
        runWithAuth(cmds) { self.currentMode = .http }
    }

    func applySOCKS() {
        stopTun()
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
        runWithAuth(cmds) { self.currentMode = .socks }
    }

    func applyDirect() {
        stopTun()
        let svc = networkService
        let cmds: [[String]] = [
            ["-setwebproxy",                svc, "", "0"],
            ["-setsecurewebproxy",          svc, "", "0"],
            ["-setsocksfirewallproxy",      svc, "", "0"],
            ["-setwebproxystate",           svc, "off"],
            ["-setsecurewebproxystate",     svc, "off"],
            ["-setsocksfirewallproxystate", svc, "off"],
        ]
        runWithAuth(cmds) { self.currentMode = .direct }
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
        stopTun()
        resetTunLog()
        let configPath = NSString(string: rawPath).expandingTildeInPath
        guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Please choose a sing-box config file in Settings."
            return
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            lastError = "sing-box config file not found: \(configPath)"
            return
        }
        guard let singBoxPath = resolveSingBoxPath() else {
            lastError = "sing-box not found. Checked common install paths and /usr/bin/which."
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", singBoxPath, "run", "-c", configPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe
        tunOutputPipe = outPipe
        tunErrorPipe = errPipe

        let append: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let str = String(data: data, encoding: .utf8) else { return }
            let clean = ProxyManager.stripANSI(str)
            self?.appendTunLog(clean)
        }
        outPipe.fileHandleForReading.readabilityHandler = { append($0) }
        errPipe.fileHandleForReading.readabilityHandler = { append($0) }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.currentMode == .tun { self.currentMode = .direct }
                self.cleanupTunProcess()
            }
        }

        do {
            try proc.run()
            tunProcess = proc
            activeTunConfig = activeConfig
            currentMode = .tun
        } catch {
            lastError = "Failed to start tun: \(error.localizedDescription)"
        }
    }

    func clearTunLog() {
        resetTunLog()
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

    private func stopTun() {
        if let proc = tunProcess {
            let sudoPID = proc.processIdentifier
            // sudo -n without a TTY does not forward signals to its child, so
            // sing-box must be killed directly by finding its PID via pgrep.
            let pgrep = Process()
            pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pgrep.arguments = ["-P", "\(sudoPID)"]
            let pipe = Pipe()
            pgrep.standardOutput = pipe
            if (try? pgrep.run()) != nil {
                pgrep.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8),
                   let childPID = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    let kill = Process()
                    kill.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                    kill.arguments = ["-n", "kill", "\(childPID)"]
                    try? kill.run()
                    kill.waitUntilExit()
                }
            }
            proc.terminate()
        }
        cleanupTunProcess()
    }

    private func cleanupTunProcess() {
        tunOutputPipe?.fileHandleForReading.readabilityHandler = nil
        tunErrorPipe?.fileHandleForReading.readabilityHandler = nil
        tunOutputPipe = nil
        tunErrorPipe = nil
        tunProcess = nil
        activeTunConfig = nil
    }

    private func resetTunLog() {
        tunLogQueue.async { [weak self] in
            guard let self else { return }
            self.pendingChunks = []
            self.incompleteLine = ""
            self.isFlushScheduled = false
            DispatchQueue.main.async { [weak self] in
                self?.tunLogLines = []
                self?.tunLogByteCount = 0
            }
        }
    }

    func appendTunLog(_ text: String) {
        tunLogQueue.async { [weak self] in
            guard let self else { return }
            self.pendingChunks.append(text)

            guard !self.isFlushScheduled else { return }
            self.isFlushScheduled = true
            self.tunLogQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.isFlushScheduled = false
                self.flushPendingLog()
            }
        }
    }

    private func flushPendingLog() {
        let joined = pendingChunks.joined()
        pendingChunks = []
        let text = incompleteLine + joined
        incompleteLine = ""
        guard !text.isEmpty else { return }

        let (newLines, remainder) = Self.splitLines(text)
        incompleteLine = remainder

        guard !newLines.isEmpty else { return }
        let addedBytes = newLines.reduce(0) { $0 + $1.utf8.count }
        DispatchQueue.main.async { [weak self] in
            self?.tunLogLines.append(contentsOf: newLines)
            self?.tunLogByteCount += addedBytes
        }
    }

    // MARK: - State detection

    func refreshCurrentMode() {
        let svc = networkService
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let httpOut  = self.readCommand(["-getwebproxy",          svc])
            let socksOut = self.readCommand(["-getsocksfirewallproxy", svc])
            DispatchQueue.main.async {
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

    /// Resolve sing-box by absolute path so sudo does not depend on PATH.
    func resolveSingBoxPath() -> String? {
        let candidates = [
            "/opt/homebrew/bin/sing-box",
            "/usr/local/bin/sing-box",
            "/usr/bin/sing-box",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }

        let found = readCommand(at: "/usr/bin/which", args: ["sing-box"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !found.isEmpty, FileManager.default.isExecutableFile(atPath: found) {
            return found
        }
        return nil
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
