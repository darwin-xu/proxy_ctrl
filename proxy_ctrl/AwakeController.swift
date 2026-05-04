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

    private let powerAssertions: PowerAssertionProviding
    private let defaults: UserDefaults?
    private let persistenceKey: String
    private var assertionToken: PowerAssertionToken?

    init(
        powerAssertions: PowerAssertionProviding? = nil,
        defaults: UserDefaults? = .standard,
        persistenceKey: String = "keepAwakeEnabled",
        restoreSavedState: Bool = true
    ) {
        self.powerAssertions = powerAssertions ?? IOKitPowerAssertionProvider()
        self.defaults = defaults
        self.persistenceKey = persistenceKey
        defaults?.register(defaults: [persistenceKey: false])
        if restoreSavedState, defaults?.bool(forKey: persistenceKey) == true {
            setKeepingAwake(true, persist: false)
        }
    }

    func toggleKeepingAwake() {
        setKeepingAwake(!isKeepingAwake)
    }

    func setKeepingAwake(_ enabled: Bool) {
        setKeepingAwake(enabled, persist: true)
    }

    func releaseForTermination() {
        setKeepingAwake(false, persist: false)
    }

    private func setKeepingAwake(_ enabled: Bool, persist: Bool) {
        if enabled {
            enableKeepingAwake()
        } else {
            disableKeepingAwake()
        }
        if persist {
            defaults?.set(isKeepingAwake, forKey: persistenceKey)
        }
    }

    private func enableKeepingAwake() {
        guard assertionToken == nil else {
            isKeepingAwake = true
            errorMessage = nil
            return
        }

        switch powerAssertions.createKeepAwakeAssertion(reason: "proxy_ctrl Keep Awake") {
        case let .success(token):
            assertionToken = token
            isKeepingAwake = true
            errorMessage = nil
        case let .failure(error):
            assertionToken = nil
            isKeepingAwake = false
            errorMessage = "Failed to keep Mac awake. IOKit returned \(error.code)."
        }
    }

    private func disableKeepingAwake() {
        releaseAssertion()
        isKeepingAwake = false
        errorMessage = nil
    }

    private func releaseAssertion() {
        guard let assertionToken else { return }
        powerAssertions.releaseAssertion(assertionToken)
        self.assertionToken = nil
    }
}
