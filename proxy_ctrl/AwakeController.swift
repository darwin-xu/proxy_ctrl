//
//  AwakeController.swift
//  proxy_ctrl
//

import Combine
import Foundation
import IOKit.pwr_mgt

typealias PowerAssertionToken = UInt32

struct PowerAssertionCreationError: Error, Equatable {
    let code: Int32
}

protocol PowerAssertionProviding {
    func createKeepAwakeAssertion(reason: String) -> Result<PowerAssertionToken, PowerAssertionCreationError>
    func releaseAssertion(_ token: PowerAssertionToken)
}

enum KeepAwakeMode: Equatable {
    case off
    case always
    case duration(until: Date)
    case until(Date)

    var expirationDate: Date? {
        switch self {
        case .off, .always:
            nil
        case let .duration(until), let .until(until):
            until
        }
    }
}

struct IOKitPowerAssertionProvider: PowerAssertionProviding {
    func createKeepAwakeAssertion(reason: String) -> Result<PowerAssertionToken, PowerAssertionCreationError> {
        var assertionID = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            return .failure(PowerAssertionCreationError(code: Int32(result)))
        }
        return .success(assertionID)
    }

    func releaseAssertion(_ token: PowerAssertionToken) {
        guard token != PowerAssertionToken(kIOPMNullAssertionID) else { return }
        IOPMAssertionRelease(IOPMAssertionID(token))
    }
}

@MainActor
final class AwakeController: ObservableObject {
    static let shared = AwakeController()
    static let defaultsKey = "keepAwakeEnabled"

    @Published private(set) var isKeepingAwake = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var mode: KeepAwakeMode = .off

    private let powerAssertions: PowerAssertionProviding
    private let defaults: UserDefaults?
    private let persistenceKey: String
    private let nowProvider: () -> Date
    private var assertionToken: PowerAssertionToken?
    private var expirationTimer: Timer?
    private var menuRefreshTimer: Timer?

    init(
        powerAssertions: PowerAssertionProviding? = nil,
        defaults: UserDefaults? = .standard,
        persistenceKey: String = "keepAwakeEnabled",
        restoreSavedState: Bool = true,
        nowProvider: @escaping () -> Date = Date.init
    ) {
        self.powerAssertions = powerAssertions ?? IOKitPowerAssertionProvider()
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        self.nowProvider = nowProvider
        defaults?.register(defaults: [persistenceKey: false])
        if restoreSavedState, defaults?.bool(forKey: persistenceKey) == true {
            startAlways(persist: false)
        }
    }

    func toggleKeepingAwake() {
        if isKeepingAwake {
            stopKeepingAwake()
        } else {
            startAlways()
        }
    }

    func setKeepingAwake(_ enabled: Bool) {
        if enabled {
            startAlways()
        } else {
            stopKeepingAwake()
        }
    }

    func startAlways() {
        startAlways(persist: true)
    }

    func keepAwake(for duration: TimeInterval) {
        guard duration > 0 else { return }
        startTimed(mode: .duration(until: nowProvider().addingTimeInterval(duration)))
    }

    func keepAwake(until date: Date) {
        startTimed(mode: .until(date))
    }

    func stopKeepingAwake() {
        stopKeepingAwake(persist: true)
    }

    func releaseForTermination() {
        stopKeepingAwake(persist: false)
    }

    var keepAwakeMenuTitle: String {
        switch mode {
        case .off:
            "Keep Awake"
        case .always:
            "Keep Awake (Always)"
        case .duration, .until:
            if let remaining = remainingTimeText() {
                "Keep Awake (\(remaining))"
            } else {
                "Keep Awake"
            }
        }
    }

    func remainingTimeText() -> String? {
        guard let expirationDate = mode.expirationDate else { return nil }
        return Self.formatRemainingTime(seconds: expirationDate.timeIntervalSince(nowProvider()))
    }

    nonisolated static func parseDuration(_ input: String) -> TimeInterval? {
        let parts = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hours = Int(parts[0]),
              let minutes = Int(parts[1]),
              hours >= 0,
              minutes >= 0,
              minutes < 60 else {
            return nil
        }

        let totalMinutes = hours * 60 + minutes
        return totalMinutes > 0 ? TimeInterval(totalMinutes * 60) : nil
    }

    nonisolated static func targetDate(forClockTime input: String, now: Date, calendar: Calendar = .current) -> Date? {
        let parts = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let hour = Int(parts[0]),
              let minute = Int(parts[1]),
              (0..<24).contains(hour),
              (0..<60).contains(minute) else {
            return nil
        }

        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = minute
        components.second = 0
        components.nanosecond = 0
        guard let candidate = calendar.date(from: components) else { return nil }

        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate)
    }

    nonisolated static func formatRemainingTime(seconds: TimeInterval) -> String {
        let totalMinutes = max(0, Int(ceil(seconds / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return String(format: "%02d:%02d", hours, minutes)
    }

    private func startAlways(persist: Bool) {
        cancelTimers()
        guard enableKeepingAwake() else {
            mode = .off
            if persist {
                defaults?.set(false, forKey: persistenceKey)
            }
            return
        }
        mode = .always
        if persist {
            defaults?.set(true, forKey: persistenceKey)
        }
    }

    private func startTimed(mode: KeepAwakeMode) {
        guard mode.expirationDate != nil else { return }
        cancelTimers()
        guard enableKeepingAwake() else {
            self.mode = .off
            defaults?.set(false, forKey: persistenceKey)
            return
        }
        self.mode = mode
        defaults?.set(false, forKey: persistenceKey)
        scheduleTimers()
    }

    @discardableResult
    private func enableKeepingAwake() -> Bool {
        guard assertionToken == nil else {
            isKeepingAwake = true
            errorMessage = nil
            return true
        }

        switch powerAssertions.createKeepAwakeAssertion(reason: "proxy_ctrl Keep Awake") {
        case let .success(token):
            assertionToken = token
            isKeepingAwake = true
            errorMessage = nil
            return true
        case let .failure(error):
            assertionToken = nil
            isKeepingAwake = false
            errorMessage = "Failed to keep Mac awake. IOKit returned \(error.code)."
            return false
        }
    }

    private func stopKeepingAwake(persist: Bool) {
        cancelTimers()
        releaseAssertion()
        isKeepingAwake = false
        mode = .off
        errorMessage = nil
        if persist {
            defaults?.set(false, forKey: persistenceKey)
        }
    }

    private func releaseAssertion() {
        guard let assertionToken else { return }
        powerAssertions.releaseAssertion(assertionToken)
        self.assertionToken = nil
    }

    private func scheduleTimers() {
        guard let expirationDate = mode.expirationDate else { return }
        let remainingSeconds = max(0, expirationDate.timeIntervalSince(nowProvider()))
        expirationTimer = Timer.scheduledTimer(withTimeInterval: remainingSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimerTick()
            }
        }

        menuRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimerTick()
            }
        }
        menuRefreshTimer?.tolerance = 2
    }

    private func handleTimerTick() {
        if let expirationDate = mode.expirationDate, expirationDate <= nowProvider() {
            stopKeepingAwake(persist: false)
            return
        }
        objectWillChange.send()
    }

    private func cancelTimers() {
        expirationTimer?.invalidate()
        menuRefreshTimer?.invalidate()
        expirationTimer = nil
        menuRefreshTimer = nil
    }
}
