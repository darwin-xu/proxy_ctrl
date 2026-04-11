//
//  ContentView.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import SwiftUI
import UniformTypeIdentifiers
import Combine

// MARK: - Menu

struct ProxyMenuView: View {
    @EnvironmentObject var proxy: ProxyManager

    var body: some View {
        Toggle("http", isOn: Binding(
            get: { proxy.currentMode == .http },
            set: { if $0 { proxy.applyHTTP() } }
        ))
        Toggle("socks", isOn: Binding(
            get: { proxy.currentMode == .socks },
            set: { if $0 { proxy.applySOCKS() } }
        ))
        Toggle("tun", isOn: Binding(
            get: { proxy.currentMode == .tun },
            set: { on in if on { proxy.applyTun() } else { proxy.applyDirect() } }
        ))
        Toggle("direct", isOn: Binding(
            get: { proxy.currentMode == .direct },
            set: { if $0 { proxy.applyDirect() } }
        ))

        if let err = proxy.lastError {
            Divider()
            Text("⚠️ \(err)")
                .foregroundColor(.red)
        }

        Divider()

        Button("Settings…") {
            // Small delay lets the status menu finish dismissing before
            // the panel appears, avoiding a visual overlap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                SettingsWindowController.shared.showSettings()
            }
        }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var proxy: ProxyManager
    @State private var memoryMB: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            if proxy.tunLogLines.isEmpty {
                Text("(no log yet)")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(
                                Array(proxy.tunLogLines.enumerated()), id: \.offset
                            ) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        Color.clear.frame(height: 0).id("bottom")
                    }
                    .onChange(of: proxy.tunLogLines.count) {
                        reader.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
            Divider()
            HStack {
                Text(String(format: "%.1f MB", memoryMB))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading)
                Text("·").foregroundColor(.secondary)
                Text("\(proxy.tunLogLines.count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Clear") { proxy.clearTunLog() }
                    .padding()
            }
        }
        .frame(width: 640, height: 420)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            memoryMB = Self.currentMemoryMB()
        }
        .onAppear { memoryMB = Self.currentMemoryMB() }
    }

    static func currentMemoryMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.resident_size) / 1_048_576
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage("networkService") private var networkService = "Wi-Fi"
    @AppStorage("httpHost")       private var httpHost       = "192.168.2.223"
    @AppStorage("httpPort")       private var httpPort       = "8899"
    @AppStorage("socksHost")      private var socksHost      = "192.168.2.201"
    @AppStorage("socksPort")      private var socksPort      = "7788"
    @AppStorage("tunConfigPath")  private var tunConfigPath  = ""
    @State private var showingConfigPicker = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Network") {
                    LabeledContent("Service") {
                        TextField("e.g. Wi-Fi", text: $networkService)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }
                }
                Section("HTTP/HTTPS Proxy") {
                    LabeledContent("Host") {
                        TextField("host", text: $httpHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }
                    LabeledContent("Port") {
                        TextField("port", text: $httpPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                    }
                }
                Section("SOCKS Proxy") {
                    LabeledContent("Host") {
                        TextField("host", text: $socksHost)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 200)
                    }
                    LabeledContent("Port") {
                        TextField("port", text: $socksPort)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 80)
                    }
                }
                Section("sing-box") {
                    HStack(spacing: 8) {
                        TextField("", text: $tunConfigPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Browse…") {
                            showingConfigPicker = true
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(.vertical)
            .fileImporter(
                isPresented: $showingConfigPicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                if case let .success(urls) = result, let url = urls.first {
                    tunConfigPath = url.path
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("View Log…") {
                    LogWindowController.shared.showLog()
                }
                .padding()
            }
        }
        .frame(width: 540)
    }
}
