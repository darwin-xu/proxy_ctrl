//
//  proxy_ctrlTests.swift
//  proxy_ctrlTests
//
//  Created by Darwin Xu on 2026/4/10.
//

import Testing
import Foundation
import Combine
@testable import proxy_ctrl

@MainActor
private func makeProxyManagerForTesting(
    networkService: String = "Test Network",
    httpHost: String = "203.0.113.10",
    httpPort: String = "18080",
    socksHost: String = "203.0.113.20",
    socksPort: String = "19090",
    tunConfigPath: String? = "",
    singBoxConfigLinkPath: String? = nil,
    singBoxLogPath: String? = nil
) -> ProxyManager {
    let manager = ProxyManager(forTesting: true)
    manager.networkServiceOverride = networkService
    manager.httpHostOverride = httpHost
    manager.httpPortOverride = httpPort
    manager.socksHostOverride = socksHost
    manager.socksPortOverride = socksPort
    manager.tunConfigPathOverride = tunConfigPath
    manager.singBoxConfigLinkPathOverride = singBoxConfigLinkPath
    manager.singBoxLogPathOverride = singBoxLogPath
    return manager
}

private final class FakePowerAssertionProvider: PowerAssertionProviding {
    var createResults: [Result<PowerAssertionToken, PowerAssertionCreationError>] = [.success(42)]
    var createdReasons: [String] = []
    var releasedTokens: [PowerAssertionToken] = []

    func createKeepAwakeAssertion(reason: String) -> Result<PowerAssertionToken, PowerAssertionCreationError> {
        createdReasons.append(reason)
        return createResults.isEmpty ? .success(42) : createResults.removeFirst()
    }

    func releaseAssertion(_ token: PowerAssertionToken) {
        releasedTokens.append(token)
    }
}

private func makeAwakeDefaults() -> (String, UserDefaults) {
    let suiteName = "proxy_ctrl.awake.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (suiteName, defaults)
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("proxy_ctrl_tests_\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func successfulCommandResult() -> CommandResult {
    CommandResult(exitCode: 0, output: "", errorOutput: "")
}

// MARK: - ProxyMode

struct ProxyModeTests {
    @Test func rawValues() {
        #expect(ProxyMode.http.rawValue == "http")
        #expect(ProxyMode.socks.rawValue == "socks")
        #expect(ProxyMode.tun.rawValue == "tun")
        #expect(ProxyMode.direct.rawValue == "direct")
    }

    @Test func initFromRawValue() {
        #expect(ProxyMode(rawValue: "http") == .http)
        #expect(ProxyMode(rawValue: "socks") == .socks)
        #expect(ProxyMode(rawValue: "tun") == .tun)
        #expect(ProxyMode(rawValue: "direct") == .direct)
        #expect(ProxyMode(rawValue: "invalid") == nil)
        #expect(ProxyMode(rawValue: "") == nil)
    }
}

// MARK: - Awake Controller

@MainActor
struct AwakeControllerTests {
    @Test func enablingCreatesAssertionAndPersistsState() {
        let (suiteName, defaults) = makeAwakeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let powerAssertions = FakePowerAssertionProvider()
        let controller = AwakeController(
            powerAssertions: powerAssertions,
            defaults: defaults,
            restoreSavedState: false
        )

        controller.setKeepingAwake(true)

        #expect(controller.isKeepingAwake)
        #expect(controller.errorMessage == nil)
        #expect(powerAssertions.createdReasons == ["proxy_ctrl Keep Awake"])
        #expect(defaults.bool(forKey: AwakeController.defaultsKey))
    }

    @Test func enablingTwiceDoesNotCreateDuplicateAssertion() {
        let powerAssertions = FakePowerAssertionProvider()
        let controller = AwakeController(
            powerAssertions: powerAssertions,
            defaults: nil,
            restoreSavedState: false
        )

        controller.setKeepingAwake(true)
        controller.setKeepingAwake(true)

        #expect(controller.isKeepingAwake)
        #expect(powerAssertions.createdReasons.count == 1)
    }

    @Test func disablingReleasesAssertionAndPersistsState() {
        let (suiteName, defaults) = makeAwakeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let powerAssertions = FakePowerAssertionProvider()
        let controller = AwakeController(
            powerAssertions: powerAssertions,
            defaults: defaults,
            restoreSavedState: false
        )

        controller.setKeepingAwake(true)
        controller.setKeepingAwake(false)

        #expect(!controller.isKeepingAwake)
        #expect(controller.errorMessage == nil)
        #expect(powerAssertions.releasedTokens == [42])
        #expect(!defaults.bool(forKey: AwakeController.defaultsKey))
    }

    @Test func failedAssertionLeavesControllerDisabled() {
        let (suiteName, defaults) = makeAwakeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let powerAssertions = FakePowerAssertionProvider()
        powerAssertions.createResults = [.failure(PowerAssertionCreationError(code: -1))]
        let controller = AwakeController(
            powerAssertions: powerAssertions,
            defaults: defaults,
            restoreSavedState: false
        )

        controller.setKeepingAwake(true)

        #expect(!controller.isKeepingAwake)
        #expect(controller.errorMessage != nil)
        #expect(powerAssertions.releasedTokens.isEmpty)
        #expect(!defaults.bool(forKey: AwakeController.defaultsKey))
    }

    @Test func terminationReleaseKeepsSavedPreference() {
        let (suiteName, defaults) = makeAwakeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let powerAssertions = FakePowerAssertionProvider()
        let controller = AwakeController(
            powerAssertions: powerAssertions,
            defaults: defaults,
            restoreSavedState: false
        )

        controller.setKeepingAwake(true)
        controller.releaseForTermination()

        #expect(!controller.isKeepingAwake)
        #expect(powerAssertions.releasedTokens == [42])
        #expect(defaults.bool(forKey: AwakeController.defaultsKey))
    }

    @Test func durationParsingRequiresPositiveHHMM() {
        #expect(AwakeController.parseDuration("01:30") == 5_400)
        #expect(AwakeController.parseDuration("1:05") == 3_900)
        #expect(AwakeController.parseDuration("00:00") == nil)
        #expect(AwakeController.parseDuration("00:60") == nil)
        #expect(AwakeController.parseDuration("abc") == nil)
    }

    @Test func clockTimeParsingUsesTomorrowForPastTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 5,
            day: 5,
            hour: 18,
            minute: 30
        )))

        let future = try #require(AwakeController.targetDate(forClockTime: "19:10", now: now, calendar: calendar))
        let tomorrow = try #require(AwakeController.targetDate(forClockTime: "17:10", now: now, calendar: calendar))

        #expect(calendar.component(.day, from: future) == 5)
        #expect(calendar.component(.hour, from: future) == 19)
        #expect(calendar.component(.minute, from: future) == 10)
        #expect(calendar.component(.day, from: tomorrow) == 6)
        #expect(calendar.component(.hour, from: tomorrow) == 17)
        #expect(calendar.component(.minute, from: tomorrow) == 10)
    }

    @Test func timedKeepAwakeUsesExpirationAndDoesNotPersist() throws {
        let (suiteName, defaults) = makeAwakeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let powerAssertions = FakePowerAssertionProvider()
        let now = try #require(Calendar.current.date(from: DateComponents(
            year: 2026,
            month: 5,
            day: 5,
            hour: 10,
            minute: 0
        )))
        let controller = AwakeController(
            powerAssertions: powerAssertions,
            defaults: defaults,
            restoreSavedState: false,
            nowProvider: { now }
        )

        controller.keepAwake(for: 90 * 60)

        #expect(controller.isKeepingAwake)
        #expect(controller.remainingTimeText() == "01:30")
        #expect(!defaults.bool(forKey: AwakeController.defaultsKey))
        if case .duration = controller.mode {
            #expect(true)
        } else {
            Issue.record("Expected duration keep-awake mode.")
        }
    }
}

// MARK: - ANSI Stripping

struct ANSIStrippingTests {
    @Test func stripsSingleColorCode() {
        let input = "\u{1B}[37mTRACE\u{1B}[0m[0000] hello"
        #expect(ProxyManager.stripANSI(input) == "TRACE[0000] hello")
    }

    @Test func noOpOnCleanText() {
        let input = "INFO[0000] network: updated default interface en0"
        #expect(ProxyManager.stripANSI(input) == input)
    }

    @Test func stripsMultipleColorCodes() {
        let input = "\u{1B}[36mINFO\u{1B}[0m[0000] \u{1B}[1;32mnetwork\u{1B}[0m started"
        #expect(ProxyManager.stripANSI(input) == "INFO[0000] network started")
    }

    @Test func emptyString() {
        #expect(ProxyManager.stripANSI("") == "")
    }

    @Test func onlyEscapeCodes() {
        let input = "\u{1B}[0m\u{1B}[37m\u{1B}[1;33m"
        #expect(ProxyManager.stripANSI(input) == "")
    }

    @Test func preservesBracketsThatAreNotANSI() {
        let input = "array[0] value[123]"
        #expect(ProxyManager.stripANSI(input) == input)
    }

    @Test func stripsResetCode() {
        let input = "before\u{1B}[0mafter"
        #expect(ProxyManager.stripANSI(input) == "beforeafter")
    }

    @Test func multiLineWithCodes() {
        let input = "\u{1B}[37mTRACE\u{1B}[0m line1\n\u{1B}[36mINFO\u{1B}[0m line2\n"
        #expect(ProxyManager.stripANSI(input) == "TRACE line1\nINFO line2\n")
    }

    @Test func stripsBoldAndColorCombined() {
        let input = "\u{1B}[1;31mERROR\u{1B}[0m: something failed"
        #expect(ProxyManager.stripANSI(input) == "ERROR: something failed")
    }
}

// MARK: - Line Splitting

struct LineSplittingTests {
    @Test func singleLineWithNewline() {
        let result = ProxyManager.splitLines("hello\n")
        #expect(result.lines == ["hello"])
        #expect(result.remainder == "")
    }

    @Test func multipleLines() {
        let result = ProxyManager.splitLines("line1\nline2\nline3\n")
        #expect(result.lines == ["line1", "line2", "line3"])
        #expect(result.remainder == "")
    }

    @Test func incompleteLastLine() {
        let result = ProxyManager.splitLines("line1\npartial")
        #expect(result.lines == ["line1"])
        #expect(result.remainder == "partial")
    }

    @Test func onlyPartialLine() {
        let result = ProxyManager.splitLines("partial")
        #expect(result.lines == [])
        #expect(result.remainder == "partial")
    }

    @Test func emptyText() {
        let result = ProxyManager.splitLines("")
        #expect(result.lines == [])
        #expect(result.remainder == "")
    }

    @Test func onlyNewlines() {
        let result = ProxyManager.splitLines("\n\n\n")
        #expect(result.lines == ["", "", ""])
        #expect(result.remainder == "")
    }

    @Test func singleNewline() {
        let result = ProxyManager.splitLines("\n")
        #expect(result.lines == [""])
        #expect(result.remainder == "")
    }

    @Test func trailingNewlineProducesNoRemainder() {
        let result = ProxyManager.splitLines("a\nb\n")
        #expect(result.lines == ["a", "b"])
        #expect(result.remainder == "")
    }

    @Test func noNewlineAtAll() {
        let result = ProxyManager.splitLines("no newline here")
        #expect(result.lines == [])
        #expect(result.remainder == "no newline here")
    }

    @Test func unicodeContent() {
        let result = ProxyManager.splitLines("日本語\n中文\nEmoji 🎉\n")
        #expect(result.lines == ["日本語", "中文", "Emoji 🎉"])
        #expect(result.remainder == "")
    }

    @Test func emptyLinesBetweenContent() {
        let result = ProxyManager.splitLines("a\n\n\nb\n")
        #expect(result.lines == ["a", "", "", "b"])
        #expect(result.remainder == "")
    }
}

// MARK: - sing-box log file

@MainActor
struct SingBoxLogFileTests {
    @Test func reloadReadsSingBoxLogFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("sing-box.log")
        try "\u{1B}[36mINFO\u{1B}[0m started\nlast line".write(
            to: logURL,
            atomically: true,
            encoding: .utf8
        )

        let manager = makeProxyManagerForTesting(singBoxLogPath: logURL.path)
        manager.reloadTunLogFromFile()

        #expect(manager.tunLogLines == ["INFO started", "last line"])
        #expect(manager.tunLogByteCount == "INFO startedlast line".utf8.count)
    }

    @Test func reloadMissingSingBoxLogFileClearsDisplayedLog() {
        let manager = makeProxyManagerForTesting(singBoxLogPath: "/nonexistent/sing-box.log")
        manager.tunLogLines = ["old"]
        manager.tunLogByteCount = 3

        manager.reloadTunLogFromFile()

        #expect(manager.tunLogLines.isEmpty)
        #expect(manager.tunLogByteCount == 0)
    }

    @Test func reloadUnchangedSingBoxLogDoesNotRepublish() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = directory.appendingPathComponent("sing-box.log")
        try "started\n".write(to: logURL, atomically: true, encoding: .utf8)

        let manager = makeProxyManagerForTesting(singBoxLogPath: logURL.path)
        var publishCount = 0
        let cancellable = manager.objectWillChange.sink {
            publishCount += 1
        }
        defer { cancellable.cancel() }

        manager.reloadTunLogFromFile()
        let publishCountAfterInitialLoad = publishCount
        manager.reloadTunLogFromFile()

        #expect(publishCountAfterInitialLoad > 0)
        #expect(publishCount == publishCountAfterInitialLoad)
    }

    @Test func clearResetsDisplayedLog() {
        let manager = ProxyManager(forTesting: true)
        manager.tunLogLines = ["line"]
        manager.tunLogByteCount = 4

        manager.clearTunLog()

        #expect(manager.tunLogLines.isEmpty)
        #expect(manager.tunLogByteCount == 0)
    }
}

// MARK: - applyTun Validation

@MainActor
struct ApplyTunValidationTests {
    @Test func emptyConfigPathShowsError() {
        let manager = makeProxyManagerForTesting(tunConfigPath: "")
        manager.applyTun()
        #expect(manager.lastError == "Please choose a sing-box config file in Settings.")
        #expect(manager.currentMode != .tun)
    }

    @Test func whitespaceOnlyConfigPathShowsError() {
        let manager = makeProxyManagerForTesting(tunConfigPath: "   \t  ")
        manager.applyTun()
        #expect(manager.lastError == "Please choose a sing-box config file in Settings.")
    }

    @Test func missingConfigFileShowsError() {
        let manager = makeProxyManagerForTesting(tunConfigPath: "/nonexistent/path/to/config.json")
        manager.applyTun()
        #expect(manager.lastError?.contains("sing-box config file not found") == true)
        #expect(manager.currentMode != .tun)
    }

    @Test func tildeExpandedInConfigPath() {
        let manager = makeProxyManagerForTesting(tunConfigPath: "~/nonexistent_proxy_ctrl_test.json")
        manager.applyTun()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let err = manager.lastError, err.contains("config file not found") {
            #expect(err.contains(home))
            #expect(!err.contains("~"))
        }
    }

    @Test func applyTunDoesNotSetModeOnValidationFailure() {
        let manager = makeProxyManagerForTesting(tunConfigPath: "")
        manager.currentMode = .direct
        manager.applyTun()
        #expect(manager.currentMode == .direct)
    }
}

// MARK: - applyTun via launchctl service

@MainActor
struct ApplyTunServiceTests {
    @Test func applyTunLinksConfigAndStartsService() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let configDirectory = directory.appendingPathComponent("sing-box", isDirectory: true)
        try FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        let linkURL = configDirectory.appendingPathComponent("config.json")
        let configURL = directory.appendingPathComponent("selected.json")
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)

        var commands: [[String]] = []
        let manager = makeProxyManagerForTesting(singBoxConfigLinkPath: linkURL.path)
        manager.privilegedCommandHandler = { arguments in
            commands.append(arguments)
            return successfulCommandResult()
        }
        let config = TunConfig(name: "selected", path: configURL.path)

        manager.applyTun(config: config)

        #expect(commands == [
            ["/bin/launchctl", "stop", "io.sing-box"],
            ["/bin/launchctl", "start", "io.sing-box"],
        ])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) == configURL.path)
        #expect(manager.currentMode == .tun)
        #expect(manager.activeTunConfig?.id == config.id)
        #expect(manager.lastError == nil)
    }

    @Test func switchingTunConfigsRelinksAndRestartsService() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let serviceDirectory = directory.appendingPathComponent("sing-box", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true)
        let linkURL = serviceDirectory.appendingPathComponent("config.json")
        let firstConfigURL = directory.appendingPathComponent("first.json")
        let secondConfigURL = directory.appendingPathComponent("second.json")
        try "{}".write(to: firstConfigURL, atomically: true, encoding: .utf8)
        try "{}".write(to: secondConfigURL, atomically: true, encoding: .utf8)

        var commands: [[String]] = []
        let manager = makeProxyManagerForTesting(singBoxConfigLinkPath: linkURL.path)
        manager.privilegedCommandHandler = { arguments in
            commands.append(arguments)
            return successfulCommandResult()
        }
        let firstConfig = TunConfig(name: "first", path: firstConfigURL.path)
        let secondConfig = TunConfig(name: "second", path: secondConfigURL.path)

        manager.applyTun(config: firstConfig)
        manager.applyTun(config: secondConfig)

        #expect(commands == [
            ["/bin/launchctl", "stop", "io.sing-box"],
            ["/bin/launchctl", "start", "io.sing-box"],
            ["/bin/launchctl", "stop", "io.sing-box"],
            ["/bin/launchctl", "start", "io.sing-box"],
        ])
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path) == secondConfigURL.path)
        #expect(manager.currentMode == .tun)
        #expect(manager.activeTunConfig?.id == secondConfig.id)
    }

    @Test func startFailureDoesNotEnterTunMode() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let serviceDirectory = directory.appendingPathComponent("sing-box", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true)
        let linkURL = serviceDirectory.appendingPathComponent("config.json")
        let configURL = directory.appendingPathComponent("selected.json")
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)

        let manager = makeProxyManagerForTesting(singBoxConfigLinkPath: linkURL.path)
        manager.privilegedCommandHandler = { arguments in
            if arguments.contains("start") {
                return CommandResult(exitCode: 1, output: "", errorOutput: "launch failed")
            }
            return successfulCommandResult()
        }

        manager.applyTun(config: TunConfig(name: "selected", path: configURL.path))

        #expect(manager.currentMode == .direct)
        #expect(manager.activeTunConfig == nil)
        #expect(manager.lastError == "Failed to start sing-box service: launch failed")
    }

    @Test func nonSymlinkConfigPathIsNotReplaced() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let serviceDirectory = directory.appendingPathComponent("sing-box", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceDirectory, withIntermediateDirectories: true)
        let linkURL = serviceDirectory.appendingPathComponent("config.json")
        let configURL = directory.appendingPathComponent("selected.json")
        try "existing".write(to: linkURL, atomically: true, encoding: .utf8)
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)

        var commands: [[String]] = []
        let manager = makeProxyManagerForTesting(singBoxConfigLinkPath: linkURL.path)
        manager.privilegedCommandHandler = { arguments in
            commands.append(arguments)
            return successfulCommandResult()
        }

        manager.applyTun(config: TunConfig(name: "selected", path: configURL.path))

        #expect(commands.isEmpty)
        #expect(manager.currentMode == .direct)
        #expect(manager.lastError?.contains("Refusing to replace non-symlink sing-box config") == true)
        #expect((try String(contentsOf: linkURL, encoding: .utf8)) == "existing")
    }
}

// MARK: - startup sing-box status

struct LaunchctlStatusParsingTests {
    @Test func detectsRunningPrintOutput() {
        let output = """
        system/io.sing-box = {
            state = running
            pid = 123
        }
        """
        #expect(ProxyManager.launchctlOutputIndicatesRunning(output))
    }

    @Test func detectsRunningListOutput() {
        let output = """
        {
            "Label" = "io.sing-box";
            "PID" = 123;
        };
        """
        #expect(ProxyManager.launchctlOutputIndicatesRunning(output))
    }

    @Test func ignoresStoppedOutput() {
        #expect(!ProxyManager.launchctlOutputIndicatesRunning("state = waiting\n"))
        #expect(!ProxyManager.launchctlOutputIndicatesRunning(#""LastExitStatus" = 0;"#))
    }
}

@MainActor
struct StartupSingBoxStatusTests {
    @Test func runningServiceWithKnownConfigLinkShowsTunConfig() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let linkURL = directory.appendingPathComponent("config.json")
        let configURL = directory.appendingPathComponent("saved.json")
        try "{}".write(to: configURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: "saved.json")

        let config = TunConfig(name: "saved", path: configURL.path)
        let manager = makeProxyManagerForTesting(singBoxConfigLinkPath: linkURL.path)
        manager.tunConfigs = [config]
        manager.privilegedCommandHandler = { _ in
            CommandResult(exitCode: 0, output: "state = running\npid = 123\n", errorOutput: "")
        }
        manager.readCommandHandler = { _, _ in "" }

        manager.refreshCurrentMode()
        try await Task.sleep(for: .milliseconds(250))

        #expect(manager.currentMode == .tun)
        #expect(manager.activeTunConfig?.id == config.id)
    }

    @Test func runningServiceWithUnknownConfigStillShowsTunChecked() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let linkURL = directory.appendingPathComponent("missing-config.json")

        let manager = makeProxyManagerForTesting(singBoxConfigLinkPath: linkURL.path)
        manager.tunConfigs = [
            TunConfig(name: "saved", path: directory.appendingPathComponent("saved.json").path)
        ]
        manager.privilegedCommandHandler = { _ in
            CommandResult(exitCode: 0, output: "state = running\npid = 123\n", errorOutput: "")
        }
        manager.readCommandHandler = { _, _ in "Enabled: Yes\n" }

        manager.refreshCurrentMode()
        try await Task.sleep(for: .milliseconds(250))

        #expect(manager.currentMode == .tun)
        #expect(manager.activeTunConfig == nil)
    }

    @Test func stoppedServiceFallsBackToNetworksetupStatus() async throws {
        let manager = makeProxyManagerForTesting()
        manager.activeTunConfig = TunConfig(name: "old", path: "/old.json")
        manager.privilegedCommandHandler = { _ in
            CommandResult(exitCode: 0, output: "state = waiting\n", errorOutput: "")
        }
        manager.readCommandHandler = { _, args in
            args.first == "-getwebproxy" ? "Enabled: Yes\n" : "Enabled: No\n"
        }

        manager.refreshCurrentMode()
        try await Task.sleep(for: .milliseconds(250))

        #expect(manager.currentMode == .http)
        #expect(manager.activeTunConfig == nil)
    }
}

// MARK: - Initial State

@MainActor
struct InitialStateTests {
    @Test func testingInitDefaultState() {
        let manager = ProxyManager(forTesting: true)
        #expect(manager.currentMode == .direct)
        #expect(manager.lastError == nil)
        #expect(manager.tunLogLines.isEmpty)
        #expect(manager.tunLogByteCount == 0)
    }
}

// MARK: - splitLines + stripANSI combined

struct CombinedProcessingTests {
    @Test func fullPipelineSimulation() {
        // Simulate the log-file display path: strip ANSI then split.
        let raw = "\u{1B}[37mTRACE\u{1B}[0m[0000] init\n\u{1B}[36mINFO\u{1B}[0m[0000] ready\n"
        let cleaned = ProxyManager.stripANSI(raw)
        let (lines, remainder) = ProxyManager.splitLines(cleaned)
        #expect(lines == ["TRACE[0000] init", "INFO[0000] ready"])
        #expect(remainder == "")
    }

    @Test func partialAnsiLine() {
        let chunk1 = "\u{1B}[37mTRACE\u{1B}[0m partial"
        let cleaned1 = ProxyManager.stripANSI(chunk1)
        let (lines1, rem1) = ProxyManager.splitLines(cleaned1)
        #expect(lines1 == [])
        #expect(rem1 == "TRACE partial")

        let chunk2 = " continued\n"
        let cleaned2 = ProxyManager.stripANSI(chunk2)
        let combined = rem1 + cleaned2
        let (lines2, rem2) = ProxyManager.splitLines(combined)
        #expect(lines2 == ["TRACE partial continued"])
        #expect(rem2 == "")
    }

    @Test func realWorldSingBoxOutput() {
        let raw = """
        \u{1B}[37mTRACE\u{1B}[0m[0000] initialize networkmanager
        \u{1B}[36mINFO\u{1B}[0m[0000] network: updated default interface en0, index 14
        \u{1B}[37mTRACE\u{1B}[0m[0000] initialize networkmanager completed (0.00s)

        """
        let cleaned = ProxyManager.stripANSI(raw)
        let (lines, remainder) = ProxyManager.splitLines(cleaned)
        #expect(lines.count == 3)
        #expect(lines[0].contains("TRACE"))
        #expect(lines[0].contains("initialize networkmanager"))
        #expect(lines[1].contains("INFO"))
        #expect(lines[1].contains("network: updated"))
        #expect(lines[2].contains("completed"))
        #expect(remainder == "")
    }
}

// MARK: - readCommand

@MainActor
struct ReadCommandTests {
    @Test func validCommand() {
        let manager = ProxyManager(forTesting: true)
        let output = manager.readCommand(at: "/bin/echo", args: ["hello"])
        #expect(output.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }

    @Test func invalidExecutableReturnsEmpty() {
        let manager = ProxyManager(forTesting: true)
        let output = manager.readCommand(at: "/nonexistent/binary", args: [])
        #expect(output == "")
    }

    @Test func commandWithMultipleArgs() {
        let manager = ProxyManager(forTesting: true)
        let output = manager.readCommand(at: "/bin/echo", args: ["-n", "test"])
        #expect(output == "test")
    }
}

// MARK: - Mode transitions

@MainActor
struct ModeTransitionTests {
    @Test func initialModeIsDirect() {
        let manager = ProxyManager(forTesting: true)
        #expect(manager.currentMode == .direct)
    }

    @Test func settingModePublishes() {
        let manager = ProxyManager(forTesting: true)
        manager.currentMode = .http
        #expect(manager.currentMode == .http)
        manager.currentMode = .socks
        #expect(manager.currentMode == .socks)
        manager.currentMode = .tun
        #expect(manager.currentMode == .tun)
        manager.currentMode = .direct
        #expect(manager.currentMode == .direct)
    }

    @Test func lastErrorCanBeSetAndCleared() {
        let manager = ProxyManager(forTesting: true)
        #expect(manager.lastError == nil)
        manager.lastError = "test error"
        #expect(manager.lastError == "test error")
        manager.lastError = nil
        #expect(manager.lastError == nil)
    }
}

// MARK: - applyHTTP / applySOCKS / applyDirect via runWithAuthHandler

@MainActor
struct ApplyHTTPTests {
    @Test func buildsCorrectCommands() {
        let manager = makeProxyManagerForTesting()
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applyHTTP()
        #expect(captured.count == 6)
        // Check web proxy set
        #expect(captured[0].first == "-setwebproxy")
        #expect(captured[1].first == "-setsecurewebproxy")
        #expect(captured[0].contains("Test Network"))
        #expect(captured[0].contains("203.0.113.10"))
        #expect(captured[0].contains("18080"))
        #expect(captured[2].first == "-setwebproxystate")
        #expect(captured[2].last == "on")
        #expect(captured[3].first == "-setsecurewebproxystate")
        #expect(captured[3].last == "on")
        // Socks turned off
        #expect(captured[4].first == "-setsocksfirewallproxy")
        #expect(captured[5].first == "-setsocksfirewallproxystate")
        #expect(captured[5].last == "off")
    }

    @Test func setsHTTPMode() {
        let manager = makeProxyManagerForTesting()
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyHTTP()
        #expect(manager.currentMode == .http)
    }

    @Test func usesOverrideHostPort() {
        let manager = makeProxyManagerForTesting()
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applyHTTP()
        #expect(captured[0].contains("203.0.113.10"))
        #expect(captured[0].contains("18080"))
    }
}

@MainActor
struct ApplySOCKSTests {
    @Test func buildsCorrectCommands() {
        let manager = makeProxyManagerForTesting()
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applySOCKS()
        #expect(captured.count == 6)
        // Socks proxy set
        #expect(captured[0].first == "-setsocksfirewallproxy")
        #expect(captured[0].contains("Test Network"))
        #expect(captured[0].contains("203.0.113.20"))
        #expect(captured[0].contains("19090"))
        #expect(captured[1].first == "-setsocksfirewallproxystate")
        #expect(captured[1].last == "on")
        // Web proxy turned off
        #expect(captured[2].first == "-setwebproxy")
        #expect(captured[3].first == "-setsecurewebproxy")
        #expect(captured[4].first == "-setwebproxystate")
        #expect(captured[4].last == "off")
        #expect(captured[5].first == "-setsecurewebproxystate")
        #expect(captured[5].last == "off")
    }

    @Test func setsSOCKSMode() {
        let manager = makeProxyManagerForTesting()
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applySOCKS()
        #expect(manager.currentMode == .socks)
    }

    @Test func usesOverrideHostPort() {
        let manager = makeProxyManagerForTesting()
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applySOCKS()
        #expect(captured[0].contains("203.0.113.20"))
        #expect(captured[0].contains("19090"))
    }
}

@MainActor
struct ApplyDirectTests {
    @Test func buildsCorrectCommands() {
        let manager = makeProxyManagerForTesting()
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applyDirect()
        #expect(captured.count == 6)
        // All proxies disabled
        #expect(captured[0].first == "-setwebproxy")
        #expect(captured[0].contains("Test Network"))
        #expect(captured[1].first == "-setsecurewebproxy")
        #expect(captured[2].first == "-setsocksfirewallproxy")
        #expect(captured[3].first == "-setwebproxystate")
        #expect(captured[3].last == "off")
        #expect(captured[4].first == "-setsecurewebproxystate")
        #expect(captured[4].last == "off")
        #expect(captured[5].first == "-setsocksfirewallproxystate")
        #expect(captured[5].last == "off")
    }

    @Test func setsDirectMode() {
        let manager = makeProxyManagerForTesting()
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyDirect()
        #expect(manager.currentMode == .direct)
    }
}

// MARK: - tunConfigPath override

@MainActor
struct TunConfigPathTests {
    @Test func emptyOverrideShowsValidationError() {
        let manager = makeProxyManagerForTesting(tunConfigPath: "")
        manager.applyTun()
        #expect(manager.lastError == "Please choose a sing-box config file in Settings.")
    }
}

// MARK: - stopTun via apply methods

@MainActor
struct StopTunViaApplyTests {
    @Test func applyHTTPStopsPreviousTun() {
        let manager = makeProxyManagerForTesting()
        var serviceCommands: [[String]] = []
        manager.currentMode = .tun
        manager.privilegedCommandHandler = { arguments in
            serviceCommands.append(arguments)
            return successfulCommandResult()
        }
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyHTTP()
        #expect(serviceCommands == [["/bin/launchctl", "stop", "io.sing-box"]])
        #expect(manager.currentMode == .http)
    }

    @Test func applySOCKSStopsPreviousTun() {
        let manager = makeProxyManagerForTesting()
        var serviceCommands: [[String]] = []
        manager.currentMode = .tun
        manager.privilegedCommandHandler = { arguments in
            serviceCommands.append(arguments)
            return successfulCommandResult()
        }
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applySOCKS()
        #expect(serviceCommands == [["/bin/launchctl", "stop", "io.sing-box"]])
        #expect(manager.currentMode == .socks)
    }

    @Test func applyDirectStopsPreviousTun() {
        let manager = makeProxyManagerForTesting()
        var serviceCommands: [[String]] = []
        manager.currentMode = .tun
        manager.privilegedCommandHandler = { arguments in
            serviceCommands.append(arguments)
            return successfulCommandResult()
        }
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyDirect()
        #expect(serviceCommands == [["/bin/launchctl", "stop", "io.sing-box"]])
        #expect(manager.currentMode == .direct)
    }
}
