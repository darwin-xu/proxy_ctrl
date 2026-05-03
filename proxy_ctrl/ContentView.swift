//
//  ContentView.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import SwiftUI
import UniformTypeIdentifiers

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
        Menu("tun") {
            if proxy.tunConfigs.isEmpty {
                Text("No configs — add one in Settings")
            } else {
                ForEach(proxy.tunConfigs) { config in
                    Toggle(config.name, isOn: Binding(
                        get: { proxy.currentMode == .tun && proxy.activeTunConfig?.id == config.id },
                        set: { on in
                            if on { proxy.applyTun(config: config) }
                            else  { proxy.applyDirect() }
                        }
                    ))
                }
            }
        }
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
                            ForEach(0..<proxy.tunLogLines.count, id: \.self) { index in
                                Text(proxy.tunLogLines[index])
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        .textSelection(.enabled)
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
                Text(String(format: "%.1f MB", Double(proxy.tunLogByteCount) / 1_048_576))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.leading)
                Text("·").foregroundColor(.secondary)
                Text("\(proxy.tunLogLines.count) lines")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        proxy.tunLogLines.joined(separator: "\n"),
                        forType: .string
                    )
                }
                Button("Clear") { proxy.clearTunLog() }
                    .padding()
            }
        }
        .frame(width: 640, height: 420)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject private var proxy: ProxyManager
    @AppStorage("networkService") private var networkService = "Wi-Fi"
    @AppStorage("httpHost")       private var httpHost       = "192.168.2.223"
    @AppStorage("httpPort")       private var httpPort       = "8899"
    @AppStorage("socksHost")      private var socksHost      = "192.168.2.201"
    @AppStorage("socksPort")      private var socksPort      = "7788"
    @State private var showingConfigPicker = false
    @State private var selectedConfigID: UUID? = nil
    @State private var pickingConfigIndex: Int? = nil

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
                Section("sing-box Configs") {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(proxy.tunConfigs.indices, id: \.self) { i in
                                HStack(spacing: 8) {
                                    TextField("", text: Binding(
                                        get: { proxy.tunConfigs[i].name },
                                        set: {
                                            proxy.tunConfigs[i].name = $0
                                            proxy.saveTunConfigs()
                                        }
                                    ))
                                    .frame(width: 120)
                                    .textFieldStyle(.plain)
                                    Text(proxy.tunConfigs[i].path)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Button("…") {
                                        pickingConfigIndex = i
                                        showingConfigPicker = true
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(
                                    selectedConfigID == proxy.tunConfigs[i].id
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.clear
                                )
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedConfigID = proxy.tunConfigs[i].id
                                }
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 34, maxHeight: 170)
                    .border(Color(nsColor: .separatorColor), width: 0.5)
                    HStack(spacing: 4) {
                        Button {
                            pickingConfigIndex = nil
                            showingConfigPicker = true
                        } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        Button {
                            if let id = selectedConfigID {
                                proxy.removeTunConfig(id: id)
                                selectedConfigID = nil
                            }
                        } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless)
                        .disabled(selectedConfigID == nil)
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
                    if let idx = pickingConfigIndex {
                        proxy.tunConfigs[idx].path = url.path
                        proxy.saveTunConfigs()
                    } else {
                        let name = url.deletingPathExtension().lastPathComponent
                        proxy.addTunConfig(name: name, path: url.path)
                    }
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
        .fixedSize(horizontal: false, vertical: true)
    }
}
