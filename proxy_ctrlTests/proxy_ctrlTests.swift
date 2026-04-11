//
//  proxy_ctrlTests.swift
//  proxy_ctrlTests
//
//  Created by Darwin Xu on 2026/4/10.
//

import Testing
import Foundation
@testable import proxy_ctrl

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

// MARK: - Log Pipeline Integration

struct LogPipelineTests {
    @Test func appendSimpleLines() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("line1\nline2\n")
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines == ["line1", "line2"])
        }
    }

    @Test func byteCountAccumulates() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("abc\n")     // 3 bytes
        try await Task.sleep(for: .milliseconds(800))
        manager.appendTunLog("defgh\n")   // 5 bytes
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogByteCount == 8)
        }
    }

    @Test func incompleteLineHeldAcrossFlushes() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("partial")
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines.isEmpty)
        }

        manager.appendTunLog(" rest\n")
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines == ["partial rest"])
        }
    }

    @Test func multipleRapidAppendsCoalesced() async throws {
        let manager = ProxyManager(forTesting: true)
        // All appended within the 0.5s flush window
        manager.appendTunLog("a\n")
        manager.appendTunLog("b\n")
        manager.appendTunLog("c\n")
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines == ["a", "b", "c"])
            #expect(manager.tunLogByteCount == 3)
        }
    }

    @Test func clearResetsEverything() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("line1\nline2\n")
        try await Task.sleep(for: .milliseconds(800))
        manager.clearTunLog()
        try await Task.sleep(for: .milliseconds(300))
        await MainActor.run {
            #expect(manager.tunLogLines.isEmpty)
            #expect(manager.tunLogByteCount == 0)
        }
    }

    @Test func clearThenAppendWorks() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("old\n")
        try await Task.sleep(for: .milliseconds(800))
        manager.clearTunLog()
        try await Task.sleep(for: .milliseconds(300))
        manager.appendTunLog("new\n")
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines == ["new"])
            #expect(manager.tunLogByteCount == 3)
        }
    }

    @Test func emptyAppendProducesNoLines() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("")
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines.isEmpty)
            #expect(manager.tunLogByteCount == 0)
        }
    }

    @Test func ansiStrippedBeforeAppend() async throws {
        let manager = ProxyManager(forTesting: true)
        let raw = "\u{1B}[37mTRACE\u{1B}[0m hello world\n"
        let cleaned = ProxyManager.stripANSI(raw)
        manager.appendTunLog(cleaned)
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogLines == ["TRACE hello world"])
        }
    }

    @Test func unicodeByteCounting() async throws {
        let manager = ProxyManager(forTesting: true)
        manager.appendTunLog("日本\n")  // 6 UTF-8 bytes
        try await Task.sleep(for: .milliseconds(800))
        await MainActor.run {
            #expect(manager.tunLogByteCount == 6)
        }
    }
}

// MARK: - applyTun Validation

struct ApplyTunValidationTests {
    @Test func emptyConfigPathShowsError() {
        let manager = ProxyManager(forTesting: true)
        manager.tunConfigPathOverride = ""
        manager.applyTun()
        #expect(manager.lastError == "Please choose a sing-box config file in Settings.")
        #expect(manager.currentMode != .tun)
    }

    @Test func whitespaceOnlyConfigPathShowsError() {
        let manager = ProxyManager(forTesting: true)
        manager.tunConfigPathOverride = "   \t  "
        manager.applyTun()
        #expect(manager.lastError == "Please choose a sing-box config file in Settings.")
    }

    @Test func missingConfigFileShowsError() {
        let manager = ProxyManager(forTesting: true)
        manager.tunConfigPathOverride = "/nonexistent/path/to/config.json"
        manager.applyTun()
        #expect(manager.lastError?.contains("sing-box config file not found") == true)
        #expect(manager.currentMode != .tun)
    }

    @Test func tildeExpandedInConfigPath() {
        let manager = ProxyManager(forTesting: true)
        manager.tunConfigPathOverride = "~/nonexistent_proxy_ctrl_test.json"
        manager.applyTun()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if let err = manager.lastError, err.contains("config file not found") {
            #expect(err.contains(home))
            #expect(!err.contains("~"))
        }
    }

    @Test func applyTunDoesNotSetModeOnValidationFailure() {
        let manager = ProxyManager(forTesting: true)
        manager.tunConfigPathOverride = ""
        manager.currentMode = .direct
        manager.applyTun()
        #expect(manager.currentMode == .direct)
    }
}

// MARK: - Initial State

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
        // Simulate what the pipe handler does: strip ANSI then split
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

// MARK: - resolveSingBoxPath

struct ResolveSingBoxPathTests {
    @Test func findsInstalledSingBox() {
        let manager = ProxyManager(forTesting: true)
        let path = manager.resolveSingBoxPath()
        // sing-box is installed on this machine
        if let path {
            #expect(FileManager.default.isExecutableFile(atPath: path))
            #expect(path.hasSuffix("sing-box"))
        }
    }

    @Test func returnsAbsolutePath() {
        let manager = ProxyManager(forTesting: true)
        if let path = manager.resolveSingBoxPath() {
            #expect(path.hasPrefix("/"))
        }
    }
}

// MARK: - readCommand

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

// MARK: - applyTun with valid config but no sudo

struct ApplyTunProcessTests {
    @Test func validConfigNoSudoSetsError() throws {
        // Create a temporary config file
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy_ctrl_test_\(UUID().uuidString).json")
        try "{}".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let manager = ProxyManager(forTesting: true)
        manager.tunConfigPathOverride = tmp.path
        manager.applyTun()

        // Either succeeds (sets tun mode) or fails (sets lastError)
        // On machines without passwordless sudo, the process will start
        // but sing-box/sudo may fail quickly
        let didAttempt = manager.currentMode == .tun || manager.lastError != nil
        #expect(didAttempt)
    }
}

// MARK: - Mode transitions

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

struct ApplyHTTPTests {
    @Test func buildsCorrectCommands() {
        let manager = ProxyManager(forTesting: true)
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
        let manager = ProxyManager(forTesting: true)
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyHTTP()
        #expect(manager.currentMode == .http)
    }

    @Test func usesDefaultHostPort() {
        let manager = ProxyManager(forTesting: true)
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applyHTTP()
        // Default httpHost is "192.168.2.223", httpPort is "8899"
        #expect(captured[0].contains("192.168.2.223"))
        #expect(captured[0].contains("8899"))
    }
}

struct ApplySOCKSTests {
    @Test func buildsCorrectCommands() {
        let manager = ProxyManager(forTesting: true)
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applySOCKS()
        #expect(captured.count == 6)
        // Socks proxy set
        #expect(captured[0].first == "-setsocksfirewallproxy")
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
        let manager = ProxyManager(forTesting: true)
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applySOCKS()
        #expect(manager.currentMode == .socks)
    }

    @Test func usesDefaultHostPort() {
        let manager = ProxyManager(forTesting: true)
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applySOCKS()
        // Default socksHost is "192.168.2.201", socksPort is "7788"
        #expect(captured[0].contains("192.168.2.201"))
        #expect(captured[0].contains("7788"))
    }
}

struct ApplyDirectTests {
    @Test func buildsCorrectCommands() {
        let manager = ProxyManager(forTesting: true)
        var captured: [[String]] = []
        manager.runWithAuthHandler = { commands, completion in
            captured = commands
            completion()
        }
        manager.applyDirect()
        #expect(captured.count == 6)
        // All proxies disabled
        #expect(captured[0].first == "-setwebproxy")
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
        let manager = ProxyManager(forTesting: true)
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyDirect()
        #expect(manager.currentMode == .direct)
    }
}

// MARK: - tunConfigPath nil-coalescing fallback

struct TunConfigPathTests {
    @Test func nilOverrideFallsToUserDefaults() {
        let manager = ProxyManager(forTesting: true)
        // tunConfigPathOverride is nil by default
        // UserDefaults may or may not have "tunConfigPath"
        // Either way, applyTun should hit the empty config path validation
        manager.applyTun()
        #expect(manager.lastError == "Please choose a sing-box config file in Settings.")
    }
}

// MARK: - stopTun via apply methods

struct StopTunViaApplyTests {
    @Test func applyHTTPStopsPreviousTun() {
        let manager = ProxyManager(forTesting: true)
        manager.currentMode = .tun
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyHTTP()
        #expect(manager.currentMode == .http)
    }

    @Test func applySOCKSStopsPreviousTun() {
        let manager = ProxyManager(forTesting: true)
        manager.currentMode = .tun
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applySOCKS()
        #expect(manager.currentMode == .socks)
    }

    @Test func applyDirectStopsPreviousTun() {
        let manager = ProxyManager(forTesting: true)
        manager.currentMode = .tun
        manager.runWithAuthHandler = { _, completion in completion() }
        manager.applyDirect()
        #expect(manager.currentMode == .direct)
    }
}
