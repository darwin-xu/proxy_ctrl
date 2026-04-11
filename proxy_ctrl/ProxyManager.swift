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

    private init() {
        UserDefaults.standard.register(defaults: [
            "networkService": "Wi-Fi",
            "httpHost": "192.168.2.223",
            "httpPort": "8899",
            "socksHost": "192.168.2.201",
            "socksPort": "7788",
        ])
        refreshCurrentMode()
    }

    // MARK: - Proxy actions (each batches into a single auth prompt)

    func applyHTTP() {
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
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
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
