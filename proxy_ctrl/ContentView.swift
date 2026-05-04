//
//  ContentView.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @ObservedObject private var awakeController = AwakeController.shared
    @AppStorage("networkService") private var networkService = "Wi-Fi"
    @AppStorage("httpHost")       private var httpHost       = "192.168.2.223"
    @AppStorage("httpPort")       private var httpPort       = "8899"
    @AppStorage("socksHost")      private var socksHost      = "192.168.2.201"
    @AppStorage("socksPort")      private var socksPort      = "7788"
    @State private var showingConfigPicker = false
    @State private var selectedConfigID: UUID? = nil
    @State private var editingConfigID: UUID? = nil
    @State private var editingConfigName = ""
    @State private var pickingConfigID: UUID? = nil
    @FocusState private var focusedConfigID: UUID?
    private let configNameColumnWidth: CGFloat = 120
    private let configActionColumnWidth: CGFloat = 20
    private let configListRowHeight: CGFloat = 28

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
                Section("Power") {
                    Toggle("Keep Awake", isOn: Binding(
                        get: { awakeController.isKeepingAwake },
                        set: { awakeController.setKeepingAwake($0) }
                    ))
                    if let error = awakeController.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
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
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("Name")
                                    .frame(width: configNameColumnWidth, alignment: .leading)
                                Text("Configuration File")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(width: configActionColumnWidth)
                            }
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: configListRowHeight)
                            Divider()
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 0) {
                                    ForEach(proxy.tunConfigs) { config in
                                        configRow(config)
                                        if config.id != proxy.tunConfigs.last?.id {
                                            Divider()
                                        }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 34, maxHeight: 170)
                        .border(Color(nsColor: .separatorColor), width: 0.5)
                        HStack(spacing: 4) {
                            Button {
                                pickingConfigID = nil
                                showingConfigPicker = true
                            } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            Button {
                                removeSelectedConfig()
                            } label: { Image(systemName: "minus") }
                            .buttonStyle(.borderless)
                            .disabled(selectedConfigID == nil || editingConfigID != nil)
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
                    if let id = pickingConfigID,
                       let idx = proxy.tunConfigs.firstIndex(where: { $0.id == id }) {
                        proxy.tunConfigs[idx].path = url.path
                        proxy.saveTunConfigs()
                    } else {
                        let name = url.deletingPathExtension().lastPathComponent
                        proxy.addTunConfig(name: name, path: url.path)
                    }
                }
                pickingConfigID = nil
            }

            Divider()

            HStack {
                Spacer()
                Button("View Log…") {
                    commitEditingName()
                    LogWindowController.shared.showLog()
                }
                .padding()
            }
        }
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func configRow(_ config: TunConfig) -> some View {
        HStack(spacing: 8) {
            configNameCell(config)
            Text(config.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    selectConfig(id: config.id)
                }
            Button("…") {
                selectConfig(id: config.id)
                pickingConfigID = config.id
                showingConfigPicker = true
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 8)
        .frame(height: configListRowHeight)
        .background(
            selectedConfigID == config.id
                ? Color.accentColor.opacity(0.2)
                : Color.clear
        )
    }

    @ViewBuilder
    private func configNameCell(_ config: TunConfig) -> some View {
        if editingConfigID == config.id {
            TextField("", text: $editingConfigName)
                .textFieldStyle(.plain)
                .focused($focusedConfigID, equals: config.id)
                .frame(width: configNameColumnWidth, height: configListRowHeight, alignment: .leading)
                .onSubmit {
                    commitEditingName()
                }
                .onExitCommand {
                    cancelEditingName()
                }
        } else {
            Text(config.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: configNameColumnWidth, height: configListRowHeight, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture {
                    beginEditingNameIfSelected(id: config.id)
                }
        }
    }

    private func selectConfig(id: UUID) {
        if editingConfigID != nil {
            commitEditingName()
        }
        selectedConfigID = id
    }

    private func beginEditingNameIfSelected(id: UUID) {
        guard selectedConfigID == id else {
            selectConfig(id: id)
            return
        }
        editingConfigName = proxy.tunConfigs.first(where: { $0.id == id })?.name ?? ""
        editingConfigID = id
        selectedConfigID = nil
        DispatchQueue.main.async {
            focusedConfigID = id
            selectFocusedTextFieldContents()
        }
    }

    private func commitEditingName() {
        guard let id = editingConfigID else { return }
        if let idx = proxy.tunConfigs.firstIndex(where: { $0.id == id }) {
            proxy.tunConfigs[idx].name = editingConfigName
            proxy.saveTunConfigs()
        }
        editingConfigID = nil
        editingConfigName = ""
        focusedConfigID = nil
    }

    private func cancelEditingName() {
        editingConfigID = nil
        editingConfigName = ""
        focusedConfigID = nil
    }

    private func removeSelectedConfig() {
        guard let id = selectedConfigID, editingConfigID == nil else { return }
        if pickingConfigID == id {
            pickingConfigID = nil
        }
        proxy.removeTunConfig(id: id)
        selectedConfigID = nil
    }

    private func selectFocusedTextFieldContents(attempt: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
                return
            }
            if attempt < 5 {
                selectFocusedTextFieldContents(attempt: attempt + 1)
            }
        }
    }
}
