//
//  proxy_ctrlApp.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import SwiftUI

@main
struct proxy_ctrlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var proxy = ProxyManager.shared

    var body: some Scene {
        MenuBarExtra {
            ProxyMenuView()
                .environmentObject(proxy)
        } label: {
            Image(systemName: proxy.currentMode == .direct ? "network" : "network.badge.shield.half.filled")
        }
        .menuBarExtraStyle(.menu)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    SettingsWindowController.shared.showSettings()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var stderrPipe: Pipe?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStderrFilter()
        NSApp.setActivationPolicy(.accessory)
    }

    /// Redirect stderr through a pipe and drop lines containing known
    /// benign Apple-framework warnings that cannot be avoided at the API level.
    private func installStderrFilter() {
        let original = dup(STDERR_FILENO)
        guard original >= 0 else { return }

        let pipe = Pipe()
        self.stderrPipe = pipe          // prevent deallocation
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }

            if let str = String(data: data, encoding: .utf8),
               str.contains("task name port right") ||
               str.contains("ViewBridge to RemoteViewService") {
                return   // suppress
            }

            data.withUnsafeBytes { buf in
                if let base = buf.baseAddress {
                    write(original, base, data.count)
                }
            }
        }
    }
}

// MARK: - Settings window
// SwiftUI's Window scene cannot be shown from an .accessory-policy app.
// Use NSWindowController + temporary .regular policy instead.

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private init() {
        let hosting = NSHostingController(rootView: SettingsView())
        let win = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 560, height: 620))
        win.center()
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.moveToActiveSpace]
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.center()
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - Log window

final class LogWindowController: NSWindowController, NSWindowDelegate {
    static let shared = LogWindowController()

    private init() {
        let hosting = NSHostingController(
            rootView: LogView().environmentObject(ProxyManager.shared)
        )
        let win = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Tun Log"
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 640, height: 420))
        win.center()
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.moveToActiveSpace]
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func showLog() {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window?.center()
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
