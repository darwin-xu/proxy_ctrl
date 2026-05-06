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
        statusMenuController = ProxyStatusMenuController(proxy: .shared, awakeController: .shared)
        statusMenuController?.install()
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationWillTerminate(_ notification: Notification) {
        AwakeController.shared.releaseForTermination()
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
    private let awakeController: AwakeController
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var cancellables = Set<AnyCancellable>()
    private var activeTimeDialog: TimeSelectionWindowController?

    init(proxy: ProxyManager, awakeController: AwakeController) {
        self.proxy = proxy
        self.awakeController = awakeController
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
        awakeController.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
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

        menu.addItem(proxyItem(
            title: "http",
            mode: .http,
            action: #selector(selectHTTP(_:)),
            symbolNames: ["arrow.triangle.branch", "globe"]
        ))
        menu.addItem(proxyItem(
            title: "socks",
            mode: .socks,
            action: #selector(selectSOCKS(_:)),
            symbolNames: ["poweroutlet.type.a", "cable.connector.horizontal", "powerplug", "network"]
        ))
        menu.addItem(tunMenuItem())
        menu.addItem(proxyItem(
            title: "direct",
            mode: .direct,
            action: #selector(selectDirect(_:)),
            symbolNames: ["arrow.right"]
        ))

        if let error = proxy.lastError {
            menu.addItem(.separator())
            menu.addItem(errorItem(message: error))
        }

        menu.addItem(.separator())
        menu.addItem(keepAwakeItem())
        if let error = awakeController.errorMessage {
            menu.addItem(errorItem(message: error))
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings(_:)),
            keyEquivalent: ""
        ).configured(target: self, symbolNames: ["gearshape"]))

        statusItem.menu = menu
    }

    private func proxyItem(
        title: String,
        mode: ProxyMode,
        action: Selector,
        symbolNames: [String]
    ) -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: "")
            .configured(
                target: self,
                state: proxy.currentMode == mode ? .on : .off,
                symbolNames: symbolNames
            )
    }

    private func keepAwakeItem() -> NSMenuItem {
        if awakeController.isKeepingAwake {
            return NSMenuItem(
                title: awakeController.keepAwakeMenuTitle,
                action: #selector(stopKeepAwake(_:)),
                keyEquivalent: ""
            ).configured(
                target: self,
                state: .on,
                symbolNames: ["lightbulb.max", "lightbulb.fill"]
            )
        }

        let item = NSMenuItem(title: awakeController.keepAwakeMenuTitle, action: nil, keyEquivalent: "")
        item.state = awakeController.isKeepingAwake ? .on : .off
        item.setSymbolImage(named: ["lightbulb"])

        let submenu = NSMenu(title: "Keep Awake")
        submenu.autoenablesItems = false
        submenu.addItem(NSMenuItem(
            title: "Always",
            action: #selector(selectKeepAwakeAlways(_:)),
            keyEquivalent: ""
        ).configured(
            target: self,
            state: awakeController.mode == .always ? .on : .off,
            symbolNames: ["infinity"]
        ))
        submenu.addItem(NSMenuItem(
            title: "For Duration...",
            action: #selector(selectKeepAwakeDuration(_:)),
            keyEquivalent: ""
        ).configured(
            target: self,
            state: isKeepAwakeDurationSelected ? .on : .off,
            symbolNames: ["timer"]
        ))
        submenu.addItem(NSMenuItem(
            title: "Until Time...",
            action: #selector(selectKeepAwakeUntil(_:)),
            keyEquivalent: ""
        ).configured(
            target: self,
            state: isKeepAwakeUntilSelected ? .on : .off,
            symbolNames: ["clock"]
        ))
        item.submenu = submenu
        return item
    }

    private var isKeepAwakeDurationSelected: Bool {
        if case .duration = awakeController.mode { return true }
        return false
    }

    private var isKeepAwakeUntilSelected: Bool {
        if case .until = awakeController.mode { return true }
        return false
    }

    private func tunMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "tun", action: nil, keyEquivalent: "")
        item.state = proxy.currentMode == .tun ? .on : .off
        item.setSymbolImage(named: ["tram.fill.tunnel", "pipe.and.drop", "network.badge.shield.half.filled", "network"])

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
                configItem.setSymbolImage(named: ["doc.text"])
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

    @objc private func selectKeepAwakeAlways(_ sender: NSMenuItem) {
        closeActiveTimeDialog()
        awakeController.startAlways()
    }

    @objc private func selectKeepAwakeDuration(_ sender: NSMenuItem) {
        promptForDuration()
    }

    @objc private func selectKeepAwakeUntil(_ sender: NSMenuItem) {
        promptForUntilTime()
    }

    @objc private func stopKeepAwake(_ sender: NSMenuItem) {
        closeActiveTimeDialog()
        awakeController.stopKeepingAwake()
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            SettingsWindowController.shared.showSettings()
        }
    }

    private func promptForDuration() {
        let totalMinutes = Self.savedDurationMinutes
        showTimeSelectionDialog(
            kind: .duration,
            title: "Keep Awake Duration",
            message: "Set a relative time.",
            initialHour: totalMinutes / 60,
            initialMinute: totalMinutes % 60,
            hourRange: 0...99
        ) { [weak self] hour, minute in
            guard let self else { return }
            let totalMinutes = hour * 60 + minute
            guard totalMinutes > 0 else {
                self.showInvalidTimeAlert("Choose a duration greater than 00:00.")
                return
            }
            Self.savedDurationMinutes = totalMinutes
            self.awakeController.keepAwake(for: TimeInterval(totalMinutes * 60))
        }
    }

    private func promptForUntilTime() {
        let clockMinutes = Self.savedUntilClockMinutes
        showTimeSelectionDialog(
            kind: .until,
            title: "Keep Awake Until",
            message: "Set a clock time. Past times use tomorrow.",
            initialHour: clockMinutes / 60,
            initialMinute: clockMinutes % 60,
            hourRange: 0...23
        ) { [weak self] hour, minute in
            guard let self else { return }
            let value = String(format: "%02d:%02d", hour, minute)
            guard let date = AwakeController.targetDate(forClockTime: value, now: Date()) else {
                self.showInvalidTimeAlert("Choose a valid 24-hour time.")
                return
            }
            Self.savedUntilClockMinutes = hour * 60 + minute
            self.awakeController.keepAwake(until: date)
        }
    }

    private func showTimeSelectionDialog(
        kind: TimeSelectionDialogKind,
        title: String,
        message: String,
        initialHour: Int,
        initialMinute: Int,
        hourRange: ClosedRange<Int>,
        completion: @escaping (Int, Int) -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if let activeTimeDialog = self.activeTimeDialog {
                if activeTimeDialog.kind == kind {
                    activeTimeDialog.bringToFront()
                    return
                }
                activeTimeDialog.closeForReplacement()
            }

            let controller = TimeSelectionWindowController(
                kind: kind,
                title: title,
                message: message,
                initialHour: initialHour,
                initialMinute: initialMinute,
                hourRange: hourRange,
                previousActivationPolicy: NSApp.activationPolicy(),
                completion: completion
            )
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller, self.activeTimeDialog === controller else { return }
                self.activeTimeDialog = nil
            }
            self.activeTimeDialog = controller
            controller.show()
        }
    }

    private func closeActiveTimeDialog() {
        activeTimeDialog?.close()
        activeTimeDialog = nil
    }

    private func showInvalidTimeAlert(_ message: String) {
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Invalid Time"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        prepareAlertWindow(alert)
        alert.runModal()

        if previousPolicy != .regular {
            NSApp.setActivationPolicy(previousPolicy)
        }
    }

    private func prepareAlertWindow(_ alert: NSAlert, initialFirstResponder: NSView? = nil) {
        let window = alert.window
        window.level = .floating
        window.collectionBehavior.insert(.canJoinAllSpaces)
        window.collectionBehavior.insert(.transient)
        if let initialFirstResponder {
            window.initialFirstResponder = initialFirstResponder
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private static let durationMinutesKey = "keepAwakeLastDurationMinutes"
    private static let untilClockMinutesKey = "keepAwakeLastUntilClockMinutes"

    private static var savedDurationMinutes: Int {
        get {
            let value = UserDefaults.standard.object(forKey: durationMinutesKey) as? Int ?? 60
            return min(max(value, 1), 99 * 60 + 59)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 1), 99 * 60 + 59), forKey: durationMinutesKey)
        }
    }

    private static var savedUntilClockMinutes: Int {
        get {
            if let value = UserDefaults.standard.object(forKey: untilClockMinutesKey) as? Int {
                return min(max(value, 0), 23 * 60 + 59)
            }

            let defaultDate = Date().addingTimeInterval(3600)
            let components = Calendar.current.dateComponents([.hour, .minute], from: defaultDate)
            return (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0), 23 * 60 + 59), forKey: untilClockMinutesKey)
        }
    }
}

private enum TimeSelectionDialogKind: Equatable {
    case duration
    case until
}

private final class TimeSelectionWindowController: NSWindowController, NSWindowDelegate {
    private static let frameOriginKey = "keepAwakeTimeDialogOrigin"

    let kind: TimeSelectionDialogKind
    var onClose: (() -> Void)?

    private let timeSelectionView: TimeSelectionView
    private let completion: (Int, Int) -> Void
    private let previousActivationPolicy: NSApplication.ActivationPolicy
    private var restoresActivationPolicyOnClose = true
    private var isRestoringWindowFrame = false

    init(
        kind: TimeSelectionDialogKind,
        title: String,
        message: String,
        initialHour: Int,
        initialMinute: Int,
        hourRange: ClosedRange<Int>,
        previousActivationPolicy: NSApplication.ActivationPolicy,
        completion: @escaping (Int, Int) -> Void
    ) {
        self.kind = kind
        self.timeSelectionView = TimeSelectionView(
            initialHour: initialHour,
            initialMinute: initialMinute,
            hourRange: hourRange
        )
        self.completion = completion
        self.previousActivationPolicy = previousActivationPolicy

        let panel = TimeSelectionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient]

        super.init(window: panel)

        shouldCascadeWindows = false
        panel.delegate = self
        configureContent(message: message)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        NSApp.setActivationPolicy(.regular)
        restoreWindowFrame()
        bringToFront()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.restoreWindowFrame()
            self.bringToFront()
        }
    }

    func bringToFront() {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.level = .modalPanel
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        window.makeFirstResponder(timeSelectionView)
    }

    func closeForReplacement() {
        restoresActivationPolicyOnClose = false
        close()
    }

    func windowDidMove(_ notification: Notification) {
        guard !isRestoringWindowFrame else { return }
        saveWindowPosition()
    }

    func windowWillClose(_ notification: Notification) {
        saveWindowPosition()
        onClose?()
        if restoresActivationPolicyOnClose, previousActivationPolicy != .regular {
            NSApp.setActivationPolicy(previousActivationPolicy)
        }
    }

    private func configureContent(message: String) {
        guard let window else { return }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let messageLabel = NSTextField(wrappingLabelWithString: message)
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        timeSelectionView.translatesAutoresizingMaskIntoConstraints = false

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        let okButton = NSButton(title: "OK", target: self, action: #selector(confirm(_:)))
        okButton.bezelStyle = .rounded
        okButton.keyEquivalent = "\r"
        okButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [cancelButton, okButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(messageLabel)
        contentView.addSubview(timeSelectionView)
        contentView.addSubview(buttonRow)
        window.contentView = contentView
        window.defaultButtonCell = okButton.cell as? NSButtonCell
        window.initialFirstResponder = timeSelectionView

        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 22),
            messageLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            messageLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),

            timeSelectionView.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            timeSelectionView.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 14),

            buttonRow.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -22),
            buttonRow.topAnchor.constraint(equalTo: timeSelectionView.bottomAnchor, constant: 16),
            buttonRow.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18)
        ])
    }

    @objc private func confirm(_ sender: Any?) {
        let hour = timeSelectionView.hour
        let minute = timeSelectionView.minute
        close()
        completion(hour, minute)
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    private func restoreWindowFrame() {
        guard let window else { return }
        guard let origin = Self.savedOrigin(for: Self.frameOriginKey) else {
            window.center()
            return
        }

        isRestoringWindowFrame = true
        window.setFrameOrigin(Self.constrainedOrigin(origin, for: window.frame.size))
        isRestoringWindowFrame = false
    }

    private func saveWindowPosition() {
        guard let window else { return }
        let origin = window.frame.origin
        UserDefaults.standard.set(
            ["x": Double(origin.x), "y": Double(origin.y)],
            forKey: Self.frameOriginKey
        )
    }

    private static func savedOrigin(for key: String) -> NSPoint? {
        guard
            let dictionary = UserDefaults.standard.dictionary(forKey: key),
            let x = dictionary["x"] as? Double,
            let y = dictionary["y"] as? Double
        else { return nil }
        return NSPoint(x: x, y: y)
    }

    private static func constrainedOrigin(_ origin: NSPoint, for size: NSSize) -> NSPoint {
        let candidateFrame = NSRect(origin: origin, size: size)
        if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(candidateFrame) }) {
            return origin
        }

        guard let visibleFrame = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            return origin
        }
        let maxX = max(visibleFrame.minX, visibleFrame.maxX - size.width)
        let maxY = max(visibleFrame.minY, visibleFrame.maxY - size.height)
        return NSPoint(
            x: min(max(origin.x, visibleFrame.minX), maxX),
            y: min(max(origin.y, visibleFrame.minY), maxY)
        )
    }
}

private final class TimeSelectionPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

private final class TimeSelectionView: NSView {
    private enum SelectedComponent {
        case hour
        case minute
    }

    private let hourStepper = NSStepper()
    private let minuteStepper = NSStepper()
    private let hourValue = NSTextField(labelWithString: "")
    private let minuteValue = NSTextField(labelWithString: "")
    private let hourRange: ClosedRange<Int>
    private var selectedComponent: SelectedComponent = .hour {
        didSet {
            resetTypedDigits()
            updateValues()
        }
    }
    private var typedDigits = ""
    private var typedDigitsResetWorkItem: DispatchWorkItem?

    var hour: Int { hourStepper.integerValue }
    var minute: Int { minuteStepper.integerValue }

    init(initialHour: Int, initialMinute: Int, hourRange: ClosedRange<Int>) {
        self.hourRange = hourRange
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 86))
        focusRingType = .default
        buildView(initialHour: initialHour, initialMinute: initialMinute, hourRange: hourRange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        updateValues()
        return true
    }

    override func resignFirstResponder() -> Bool {
        resetTypedDigits()
        updateValues()
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76:
            window?.defaultButtonCell?.performClick(nil)
        case 48:
            selectedComponent = event.modifierFlags.contains(.shift) ? .hour : .minute
        case 123:
            selectedComponent = .hour
        case 124:
            selectedComponent = .minute
        case 125:
            adjustSelectedComponent(by: -1)
        case 126:
            adjustSelectedComponent(by: 1)
        default:
            guard
                let character = event.charactersIgnoringModifiers?.first,
                character.isNumber,
                let digit = character.wholeNumberValue
            else {
                super.keyDown(with: event)
                return
            }
            handleDigitInput(digit)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        selectedComponent = location.x < bounds.midX ? .hour : .minute

        if event.scrollingDeltaY > 0 {
            adjustSelectedComponent(by: 1)
        } else if event.scrollingDeltaY < 0 {
            adjustSelectedComponent(by: -1)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func buildView(initialHour: Int, initialMinute: Int, hourRange: ClosedRange<Int>) {
        hourStepper.minValue = Double(hourRange.lowerBound)
        hourStepper.maxValue = Double(hourRange.upperBound)
        hourStepper.integerValue = min(max(initialHour, hourRange.lowerBound), hourRange.upperBound)
        hourStepper.increment = 1
        hourStepper.target = self
        hourStepper.action = #selector(valueChanged(_:))

        minuteStepper.minValue = 0
        minuteStepper.maxValue = 59
        minuteStepper.integerValue = min(max(initialMinute, 0), 59)
        minuteStepper.increment = 1
        minuteStepper.target = self
        minuteStepper.action = #selector(valueChanged(_:))

        let colon = NSTextField(labelWithString: ":")
        colon.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        colon.alignment = .center
        colon.translatesAutoresizingMaskIntoConstraints = false

        let hourLabel = componentLabel(title: "hours", component: .hour)
        let minuteLabel = componentLabel(title: "minutes", component: .minute)

        let hourRow = timeValueRow(valueField: hourValue, stepper: hourStepper, component: .hour)
        let minuteRow = timeValueRow(valueField: minuteValue, stepper: minuteStepper, component: .minute)
        addSubview(hourLabel)
        addSubview(minuteLabel)
        addSubview(hourRow)
        addSubview(colon)
        addSubview(minuteRow)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 260),
            heightAnchor.constraint(equalToConstant: 86),

            hourRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            hourRow.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 12),
            hourRow.widthAnchor.constraint(equalToConstant: 100),
            hourRow.heightAnchor.constraint(equalToConstant: 42),

            colon.leadingAnchor.constraint(equalTo: hourRow.trailingAnchor, constant: 10),
            colon.centerYAnchor.constraint(equalTo: hourRow.centerYAnchor),
            colon.widthAnchor.constraint(equalToConstant: 12),
            colon.heightAnchor.constraint(equalToConstant: 38),

            minuteRow.leadingAnchor.constraint(equalTo: colon.trailingAnchor, constant: 10),
            minuteRow.centerYAnchor.constraint(equalTo: hourRow.centerYAnchor),
            minuteRow.widthAnchor.constraint(equalToConstant: 100),
            minuteRow.heightAnchor.constraint(equalToConstant: 42),

            hourLabel.centerXAnchor.constraint(equalTo: hourRow.centerXAnchor),
            hourLabel.bottomAnchor.constraint(equalTo: hourRow.topAnchor, constant: -4),
            hourLabel.widthAnchor.constraint(equalToConstant: 94),
            minuteLabel.centerXAnchor.constraint(equalTo: minuteRow.centerXAnchor),
            minuteLabel.bottomAnchor.constraint(equalTo: minuteRow.topAnchor, constant: -4),
            minuteLabel.widthAnchor.constraint(equalToConstant: 94)
        ])

        updateValues()
    }

    private func componentLabel(title: String, component: SelectedComponent) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.identifier = NSUserInterfaceItemIdentifier(component == .hour ? "hour" : "minute")
        label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectComponent(_:))))
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private func timeValueRow(
        valueField: NSTextField,
        stepper: NSStepper,
        component: SelectedComponent
    ) -> NSView {
        valueField.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
        valueField.alignment = .center
        valueField.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueField.translatesAutoresizingMaskIntoConstraints = false
        stepper.translatesAutoresizingMaskIntoConstraints = false

        let row = NSView()
        row.addSubview(valueField)
        row.addSubview(stepper)
        row.identifier = NSUserInterfaceItemIdentifier(component == .hour ? "hour" : "minute")
        row.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(selectComponent(_:))))
        row.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            valueField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            valueField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            valueField.widthAnchor.constraint(equalToConstant: 54),
            valueField.heightAnchor.constraint(equalToConstant: 38),

            stepper.leadingAnchor.constraint(equalTo: valueField.trailingAnchor, constant: 6),
            stepper.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            stepper.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }

    @objc private func valueChanged(_ sender: NSStepper) {
        selectedComponent = sender == hourStepper ? .hour : .minute
        window?.makeFirstResponder(self)
        updateValues()
    }

    @objc private func selectComponent(_ recognizer: NSClickGestureRecognizer) {
        guard let identifier = recognizer.view?.identifier?.rawValue else { return }
        selectedComponent = identifier == "hour" ? .hour : .minute
        window?.makeFirstResponder(self)
    }

    private func adjustSelectedComponent(by value: Int) {
        resetTypedDigits()
        switch selectedComponent {
        case .hour:
            hourStepper.integerValue = clamped(hour + value, in: hourRange)
        case .minute:
            minuteStepper.integerValue = clamped(minute + value, in: 0...59)
        }
        updateValues()
    }

    private func handleDigitInput(_ digit: Int) {
        typedDigits.append(String(digit))
        let maxLength = maximumValueForSelectedComponent() > 9 ? 2 : 1
        if typedDigits.count > maxLength {
            typedDigits = String(digit)
        }

        let value = Int(typedDigits) ?? digit
        setSelectedComponentValue(value)

        if typedDigits.count >= maxLength {
            if selectedComponent == .hour {
                selectedComponent = .minute
            }
            resetTypedDigits()
        } else {
            scheduleTypedDigitsReset()
        }
        updateValues()
    }

    private func setSelectedComponentValue(_ value: Int) {
        switch selectedComponent {
        case .hour:
            hourStepper.integerValue = clamped(value, in: hourRange)
        case .minute:
            minuteStepper.integerValue = clamped(value, in: 0...59)
        }
    }

    private func maximumValueForSelectedComponent() -> Int {
        switch selectedComponent {
        case .hour:
            hourRange.upperBound
        case .minute:
            59
        }
    }

    private func scheduleTypedDigitsReset() {
        typedDigitsResetWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.typedDigits = ""
        }
        typedDigitsResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: workItem)
    }

    private func resetTypedDigits() {
        typedDigitsResetWorkItem?.cancel()
        typedDigitsResetWorkItem = nil
        typedDigits = ""
    }

    private func clamped(_ value: Int, in range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func updateValues() {
        hourValue.stringValue = String(format: "%02d", hour)
        minuteValue.stringValue = String(format: "%02d", minute)
        hourValue.textColor = selectedComponent == .hour ? .controlAccentColor : .labelColor
        minuteValue.textColor = selectedComponent == .minute ? .controlAccentColor : .labelColor
    }
}

private extension NSMenuItem {
    func configured(
        target: AnyObject,
        state: NSControl.StateValue = .off,
        symbolNames: [String] = []
    ) -> NSMenuItem {
        self.target = target
        self.state = state
        setSymbolImage(named: symbolNames)
        return self
    }

    func setSymbolImage(named symbolNames: [String]) {
        for symbolName in symbolNames {
            if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
                image.isTemplate = true
                self.image = image
                return
            }
        }
        image = nil
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
        let win = SettingsPanel(
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
        sizeObserver = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, change in
            guard let size = change.newValue, size.width > 0, size.height > 0 else { return }
            DispatchQueue.main.async {
                self?.applyPreferredContentSize(size)
            }
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

    private func applyPreferredContentSize(_ size: NSSize) {
        guard let window else { return }
        let current = window.contentView?.bounds.size ?? .zero
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5 else {
            return
        }
        window.setContentSize(size)
    }
}

final class SettingsPanel: NSPanel {
    override func cancelOperation(_ sender: Any?) {
        // Escape should not close the Settings window. Inline editors handle
        // their own Escape behavior before the command reaches the panel.
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
        win.title = "sing-box Log"
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
        ProxyManager.shared.reloadTunLogFromFile()
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
