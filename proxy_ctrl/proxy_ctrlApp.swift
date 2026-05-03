//
//  proxy_ctrlApp.swift
//  proxy_ctrl
//
//  Created by Darwin Xu on 2026/4/10.
//

import AppKit
import Combine
import SwiftUI

@main
struct proxy_ctrlApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
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
    private var statusMenuController: ProxyStatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installStderrFilter()
        statusMenuController = ProxyStatusMenuController(proxy: .shared)
        statusMenuController?.install()
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

final class ProxyStatusMenuController: NSObject {
    private let proxy: ProxyManager
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables = Set<AnyCancellable>()

    init(proxy: ProxyManager) {
        self.proxy = proxy
        super.init()
    }

    func install() {
        updateStatusButton()
        rebuildMenu()
        proxy.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.updateStatusButton()
                    self?.rebuildMenu()
                }
            }
            .store(in: &cancellables)
    }

    private func updateStatusButton() {
        guard let button = statusItem.button else { return }
        let symbolName = proxy.currentMode == .direct ? "network" : "network.badge.shield.half.filled"
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Proxy") {
            image.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.title = ""
        } else {
            button.image = nil
            button.title = "Proxy"
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(proxyItem(title: "http", mode: .http, action: #selector(selectHTTP(_:))))
        menu.addItem(proxyItem(title: "socks", mode: .socks, action: #selector(selectSOCKS(_:))))
        menu.addItem(tunMenuItem())
        menu.addItem(proxyItem(title: "direct", mode: .direct, action: #selector(selectDirect(_:))))

        if let error = proxy.lastError {
            menu.addItem(.separator())
            menu.addItem(errorItem(message: error))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ""
        ).configured(target: self))

        statusItem.menu = menu
    }

    private func proxyItem(title: String, mode: ProxyMode, action: Selector) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
            .configured(target: self, state: proxy.currentMode == mode ? .on : .off)
    }

    private func tunMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "tun", action: nil, keyEquivalent: "")
        item.state = proxy.currentMode == .tun ? .on : .off

        let submenu = NSMenu(title: "tun")
        submenu.autoenablesItems = false
        if proxy.tunConfigs.isEmpty {
            let empty = NSMenuItem(title: "No configs - add one in Settings", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for config in proxy.tunConfigs {
                let configItem = NSMenuItem(
                    title: config.name,
                    action: #selector(selectTunConfig(_:)),
                    keyEquivalent: ""
                )
                configItem.target = self
                configItem.representedObject = config.id.uuidString
                configItem.state = proxy.currentMode == .tun && proxy.activeTunConfig?.id == config.id ? .on : .off
                submenu.addItem(configItem)
            }
        }
        item.submenu = submenu
        return item
    }

    private func errorItem(message: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(
            string: "⚠️ \(message)",
            attributes: [.foregroundColor: NSColor.systemRed]
        )
        item.isEnabled = false
        return item
    }

    @objc private func selectHTTP(_ sender: NSMenuItem) {
        proxy.applyHTTP()
    }

    @objc private func selectSOCKS(_ sender: NSMenuItem) {
        proxy.applySOCKS()
    }

    @objc private func selectDirect(_ sender: NSMenuItem) {
        proxy.applyDirect()
    }

    @objc private func selectTunConfig(_ sender: NSMenuItem) {
        guard
            let idString = sender.representedObject as? String,
            let id = UUID(uuidString: idString),
            let config = proxy.tunConfigs.first(where: { $0.id == id })
        else { return }
        proxy.applyTun(config: config)
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SettingsWindowController.shared.showSettings()
        }
    }
}

private extension NSMenuItem {
    func configured(target: AnyObject, state: NSControl.StateValue = .off) -> NSMenuItem {
        self.target = target
        self.state = state
        return self
    }
}

// MARK: - Settings window
// SwiftUI's Window scene cannot be shown from an .accessory-policy app.
// Use NSWindowController + temporary .regular policy instead.

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()
    private let hosting: NSHostingController<AnyView>
    private var sizeObserver: NSKeyValueObservation?

    private init() {
        hosting = NSHostingController(
            rootView: AnyView(SettingsView().environmentObject(ProxyManager.shared))
        )
        let win = NSPanel(
            contentRect: .zero,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "Settings"
        win.contentViewController = hosting
        win.setContentSize(NSSize(width: 560, height: 100))
        win.center()
        win.hidesOnDeactivate = false
        win.collectionBehavior = [.moveToActiveSpace]
        super.init(window: win)
        win.delegate = self
        sizeObserver = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] ctrl, _ in
            let size = ctrl.preferredContentSize
            guard size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async { self?.window?.setContentSize(size) }
        }
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
