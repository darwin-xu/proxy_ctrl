//
//  ContentView.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var proxy: ProxyManager
    @AppStorage("logFollowLatest") private var followLatest = true

    var body: some View {
        VStack(spacing: 0) {
            if proxy.tunLogLines.isEmpty {
                Text("(no log yet)")
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                SelectableLogTextView(
                    text: proxy.tunLogLines.joined(separator: "\n"),
                    followLatest: followLatest
                )
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
                Toggle("Follow latest", isOn: $followLatest)
                    .toggleStyle(.checkbox)
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

private struct SelectableLogTextView: NSViewRepresentable {
    let text: String
    let followLatest: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }

        if textView.string != text {
            let selectedRange = textView.selectedRange()
            textView.string = text
            textView.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            textView.textColor = .labelColor

            if followLatest {
                scrollToBottom(textView)
            } else {
                textView.setSelectedRange(clamped(selectedRange, in: textView.string))
            }
        } else if followLatest, context.coordinator.lastFollowLatest != followLatest {
            scrollToBottom(textView)
        }

        context.coordinator.lastFollowLatest = followLatest
    }

    private func scrollToBottom(_ textView: NSTextView) {
        let end = (textView.string as NSString).length
        DispatchQueue.main.async {
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    private func clamped(_ range: NSRange, in string: String) -> NSRange {
        let length = (string as NSString).length
        guard range.location <= length else { return NSRange(location: length, length: 0) }
        return NSRange(location: range.location, length: min(range.length, length - range.location))
    }

    final class Coordinator {
        weak var textView: NSTextView?
        var lastFollowLatest = true
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
    @AppStorage("ipinfoBearerToken") private var ipinfoBearerToken = ""
    @State private var showingConfigPicker = false
    @State private var selectedConfigID: UUID? = nil
    @State private var editingConfigID: UUID? = nil
    @State private var editingConfigName = ""
    @State private var pickingConfigID: UUID? = nil
    @State private var settingsSnapshot: SettingsSnapshot? = nil
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
                Section("Connectivity") {
                    LabeledContent("ipinfo Bearer") {
                        SecureField("optional token", text: $ipinfoBearerToken)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 260)
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
        .onAppear {
            captureSettingsSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowDidOpen)) { _ in
            captureSettingsSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowWillCancel)) { _ in
            restoreSettingsSnapshot()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsWindowWillClose)) { _ in
            cancelPendingWindowEdits()
            settingsSnapshot = nil
        }
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

    private func cancelPendingWindowEdits() {
        cancelEditingName()
        pickingConfigID = nil
        showingConfigPicker = false
    }

    private func captureSettingsSnapshot() {
        settingsSnapshot = SettingsSnapshot(
            networkService: networkService,
            httpHost: httpHost,
            httpPort: httpPort,
            socksHost: socksHost,
            socksPort: socksPort,
            ipinfoBearerToken: ipinfoBearerToken,
            tunConfigs: proxy.tunConfigs
        )
    }

    private func restoreSettingsSnapshot() {
        guard let settingsSnapshot else {
            cancelPendingWindowEdits()
            return
        }
        networkService = settingsSnapshot.networkService
        httpHost = settingsSnapshot.httpHost
        httpPort = settingsSnapshot.httpPort
        socksHost = settingsSnapshot.socksHost
        socksPort = settingsSnapshot.socksPort
        ipinfoBearerToken = settingsSnapshot.ipinfoBearerToken
        proxy.tunConfigs = settingsSnapshot.tunConfigs
        proxy.saveTunConfigs()
        cancelPendingWindowEdits()
    }

    private struct SettingsSnapshot {
        let networkService: String
        let httpHost: String
        let httpPort: String
        let socksHost: String
        let socksPort: String
        let ipinfoBearerToken: String
        let tunConfigs: [TunConfig]
    }
}
