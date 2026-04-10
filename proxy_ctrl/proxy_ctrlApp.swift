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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Settings window
// SwiftUI's Window scene cannot be shown from an .accessory-policy app
// (causes "task name port right" errors). Use NSWindowController instead
// and temporarily switch to .regular while the window is visible.

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
        win.setContentSize(NSSize(width: 420, height: 480))
        win.center()
        super.init(window: win)
        win.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    func showSettings() {
        NSApp.setActivationPolicy(.regular)
        // Defer until the next runloop cycle so the policy change takes effect
        // before the window system tries to present the window.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if !(window?.isVisible ?? false) { window?.center() }
            showWindow(nil)
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Restore menu-bar-only mode once settings window is dismissed
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
