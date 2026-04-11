//
//  ProxyManager.swift
//  proxy_ctrl
//

import Combine
import Foundation

enum ProxyMode: String {
    case http, socks, tun, direct
}

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var currentMode: ProxyMode = .direct
    @Published var lastError: String? = nil
    @Published var tunLog: String = ""

    private var tunProcess: Process?

    private var networkService: String {
        UserDefaults.standard.string(forKey: "networkService") ?? "Wi-Fi"
    }
    private var httpHost: String {
        UserDefaults.standard.string(forKey: "httpHost") ?? "192.168.2.223"
    }
    private var httpPort: String {
        UserDefaults.standard.string(forKey: "httpPort") ?? "8899"
    }
    private var socksHost: String {
        UserDefaults.standard.string(forKey: "socksHost") ?? "192.168.2.201"
    }
    private var socksPort: String {
        UserDefaults.standard.string(forKey: "socksPort") ?? "7788"
    }
    private var tunConfigPath: String {
        UserDefaults.standard.string(forKey: "tunConfigPath") ?? ""
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            "networkService": "Wi-Fi",
            "httpHost": "192.168.2.223",
            "httpPort": "8899",
            "socksHost": "192.168.2.201",
            "socksPort": "7788",
            "tunConfigPath": "",
        ])
        refreshCurrentMode()
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
        stopTun()
        tunLog = ""
        guard let singBoxPath = resolveSingBoxPath() else {
            lastError = "sing-box not found. Checked common install paths and /usr/bin/which."
            return
        }
        let configPath = NSString(string: tunConfigPath).expandingTildeInPath
        guard !configPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "Please choose a sing-box config file in Settings."
            return
        }
        guard FileManager.default.fileExists(atPath: configPath) else {
            lastError = "sing-box config file not found: \(configPath)"
            return
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        proc.arguments = ["-n", singBoxPath, "run", "-c", configPath]
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError  = errPipe

        let append: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let str = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.tunLog += str }
        }
        outPipe.fileHandleForReading.readabilityHandler = { append($0) }
        errPipe.fileHandleForReading.readabilityHandler = { append($0) }

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.currentMode == .tun { self.currentMode = .direct }
            }
        }

        do {
            try proc.run()
            tunProcess = proc
            currentMode = .tun
        } catch {
            lastError = "Failed to start tun: \(error.localizedDescription)"
        }
    }

    private func stopTun() {
        tunProcess?.terminate()
        tunProcess = nil
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
    private func resolveSingBoxPath() -> String? {
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

    private func readCommand(at executablePath: String, args: [String]) -> String {
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
