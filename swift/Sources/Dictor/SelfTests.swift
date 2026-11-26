import AppKit
import Foundation

#if DEBUG
enum SelfTestFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message): return message
        }
    }
}

enum DictorSelfTest {
    static func run(arguments: [String]) -> Int32? {
        guard arguments.count >= 2, arguments[0] == "--self-test" else { return nil }
        guard arguments.count == 2 else { return fail("usage") }

        switch arguments[1] {
        case "hotkey":
            return runSuite("hotkey", testHotkey)
        case "readiness":
            return runSuite("readiness", testReadiness)
        case "paste":
            return runSuite("paste", testPasteSuffixFormatting)
        case "history":
            return runSuite("history", testRecentTranscriptLimit)
        case "statistics":
            return runSuite("statistics", testDictationUsageStatistics)
        case "corrections":
            return runSuite("corrections", testTranscriptCorrections)
        case "fillers":
            return runSuite("fillers", testFillerWordRemoval)
        case "audio-level":
            return runSuite("audio-level", testAudioLevelMetering)
        case "audio-conversion":
            return runSuite("audio-conversion", testAudioConversion)
        case "audio-input":
            return runSuite("audio-input", testAudioInputDeviceFiltering)
        case "missing-microphone":
            return runSuite("missing-microphone", testMissingMicrophone)
        case "model-status":
            return runSuite("model-status", testSpeechModelStartupStatus)
        case "service-status":
            return runSuite("service-status", testServiceStatusHold)
        case "quit-state":
            return runSuite("quit-state", testQuitLeavesServiceEnabled)
        case "chart-hover":
            return runSuite("chart-hover", testStatsChartHover)
        case "search-clear":
            return runSuite("search-clear", testHistorySearchClearButton)
        case "today-actions":
            return runSuite("today-actions", testTodayRecentRowActions)
        case "floating-capsule":
            return runSuite("floating-capsule", testFloatingCapsuleGeometry)
        case "spellings":
            return runSuite("spellings", testBuiltInSpellings)
        case "latin-terms":
            return runSuite("latin-terms", testLatinTermRestorations)
        case "history-list":
            return runSuite("history-list", testHistoryListVirtualization)
        case "clipboard-paste":
            return runSuite("clipboard-paste", testClipboardPasteTransaction)
        case "clipboard-paste-live":
            return runSuite("clipboard-paste-live", testClipboardPasteLive)
        case "corrections-cost":
            return runSuite("corrections-cost", testTranscriptCorrectionsCost)
        case "audio-route":
            return runSuite("audio-route", testAudioRouteChangeDecision)
        case "recording-lifecycle":
            return runSuite("recording-lifecycle", testRecordingLifecycle)
        case "power-state":
            return runSuite("power-state", testPowerStateRecoveryDecision)
        case "model-integrity":
            return runSuite("model-integrity", testModelIntegrity)
        case "update":
            return runSuite("update", testUpdate)
        case "hostile-env":
            return runSuite("hostile-env", testHostileRegistryEnvDetection)
        case "logging":
            return runSuite("logging", testPrivateLogAppend)
        case "diagnostics":
            return runSuite("diagnostics", testDiagnostics)
        case "insertion-target":
            return runSuite("insertion-target", testInsertionTargetTracking)
        case "insertion-target-live":
            return runSuite("insertion-target-live", testLiveInsertionTargetProbe)
        case "dock-policy":
            return runSuite("dock-policy", testDockActivationPolicy)
        case "settings-reachable":
            return runSuite("settings-reachable", testSettingsReachability)
        case "smart-insertion":
            return runSuite("smart-insertion", testSmartInsertion)
        case "browser-typing":
            return runSuite("browser-typing", testBrowserTyping)
        case "all":
            return runSuite("all", testAll)
        default:
            return fail("unknown")
        }
    }

    private static func runSuite(_ name: String, _ body: () throws -> Void) -> Int32 {
        do {
            try body()
            print("PASS \(name)")
            return EXIT_SUCCESS
        } catch {
            print("FAIL \(name): \(error)")
            return EXIT_FAILURE
        }
    }

    private static func fail(_ message: String) -> Int32 {
        print("FAIL self-test: \(message)")
        return EXIT_FAILURE
    }

    private static func testAll() throws {
        try testHotkey()
        try testReadiness()
        try testPasteSuffixFormatting()
        try testRecentTranscriptLimit()
        try testDictationUsageStatistics()
        try testTranscriptCorrections()
        try testFillerWordRemoval()
        try testAudioLevelMetering()
        try testAudioConversion()
        try testAudioInputDeviceFiltering()
        try testMissingMicrophone()
        try testSpeechModelStartupStatus()
        try testServiceStatusHold()
        try testQuitLeavesServiceEnabled()
        try testStatsChartHover()
        try testHistorySearchClearButton()
        try testHistoryListVirtualization()
        try testTodayRecentRowActions()
        try testFloatingCapsuleGeometry()
        try testBuiltInSpellings()
        try testLatinTermRestorations()
        try testClipboardPasteTransaction()
        try testAudioRouteChangeDecision()
        try testRecordingLifecycle()
        try testPowerStateRecoveryDecision()
        try testModelIntegrity()
        try testUpdate()
        try testHostileRegistryEnvDetection()
        try testPrivateLogAppend()
        try testDiagnostics()
        try testInsertionTargetTracking()
        try testDockActivationPolicy()
        try testSettingsReachability()
        try testSmartInsertion()
        try testBrowserTyping()
        try testForeignLanguageGuard()
        try testDiagnosticAudioSamples()
    }

    /// Значок в Dock: четыре комбинации «тумблер × окно». Служба обязана
    /// прятать свой значок, пока окно живо, — иначе в Dock два значка
    /// одного бандла.
    private static func testDockActivationPolicy() throws {
        try expect(dockActivationPolicy(showInDock: true, panelRunning: false),
                   equals: .regular,
                   "dock icon should appear when enabled and the panel is closed")
        try expect(dockActivationPolicy(showInDock: true, panelRunning: true),
                   equals: .accessory,
                   "the running panel already shows a Dock icon — the agent must hide its own")
        try expect(dockActivationPolicy(showInDock: false, panelRunning: false),
                   equals: .accessory,
                   "dock icon off means accessory")
        try expect(dockActivationPolicy(showInDock: false, panelRunning: true),
                   equals: .accessory,
                   "dock icon off stays accessory regardless of the panel")
    }

    static func expect<T: Equatable>(
        _ actual: T,
        equals expected: T,
        _ message: String
    ) throws {
        guard actual == expected else {
            throw SelfTestFailure.failed("\(message): got \(actual), expected \(expected)")
        }
    }
}

#endif

