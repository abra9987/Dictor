import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

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

    private static func testAudioRouteChangeDecision() throws {
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 1),
            equals: Optional(1 as UInt64),
            "first audio startup failure should retry after one second"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 2),
            equals: Optional(3 as UInt64),
            "second audio startup failure should retry after three seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 3),
            equals: Optional(8 as UInt64),
            "third audio startup failure should retry after eight seconds"
        )
        try expect(
            audioStartupRetryDelaySeconds(afterFailedAttempt: 4),
            equals: UInt64?.none,
            "audio startup should stop retrying after the configured backoff schedule"
        )
        try expect(
            audioRouteChangeAction(isTerminating: true,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .ignore,
            "route changes during termination should be ignored"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: false,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .rebuildMenuOnly,
            "route changes before runtime readiness should only refresh the menu"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: true,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .deferRefresh,
            "route changes during recording should defer the restart"
        )
        try expect(
            audioRouteChangeAction(isTerminating: false,
                                   isRestartingAudioInput: false,
                                   isCoreRuntimeReady: true,
                                   isRecording: false,
                                   isBusy: false,
                                   hasStartupTask: false),
            equals: .restartNow,
            "idle ready route changes should restart audio immediately"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: nil),
            equals: false,
            "configuration changes should not be suppressed without a suppression deadline"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 10, suppressedUntil: 11),
            equals: true,
            "configuration changes before the app-owned deadline should be ignored"
        )
        try expect(
            audioConfigurationChangeIsSuppressed(now: 11, suppressedUntil: 11),
            equals: false,
            "configuration changes at the suppression deadline should be handled normally"
        )
    }

    private static func testRecordingLifecycle() throws {
        // Смена микрофона в окне обязана дойти до службы, но не ценой
        // перезапуска аудиовхода раз в секунду: таймер настроек тикает
        // постоянно, и решение принимается сравнением с прошлым значением.
        try expect(shouldRestartAudioInput(previous: nil, current: "AppleUSB"),
                   equals: false,
                   "the first tick has nothing to compare against and must not restart")
        try expect(shouldRestartAudioInput(previous: "AppleUSB", current: "AppleUSB"),
                   equals: false,
                   "an unchanged device must not restart the input")
        try expect(shouldRestartAudioInput(previous: "AppleUSB", current: "Yeti"),
                   equals: true,
                   "a device picked in the window must reach the service without a restart")
        try expect(shouldRestartAudioInput(previous: "Yeti", current: ""),
                   equals: true,
                   "going back to the system default is a change too")

        try expect(
            recordingReleaseAction(capturedSampleCount: 3_999,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0.2499375),
            "release decision should discard clips under the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 16_000,
                                   minimumClipSeconds: 0.25),
            equals: .transcribe(duration: 0.25),
            "release decision should transcribe clips at the minimum duration"
        )
        try expect(
            recordingReleaseAction(capturedSampleCount: 4_000,
                                   sampleRate: 0,
                                   minimumClipSeconds: 0.25),
            equals: .discardTooShort(duration: 0),
            "release decision should handle invalid sample rates defensively"
        )

        // Автостоп по потолку не вставляет текст — капсула обязана сказать,
        // куда он делся, и не обещать «Историю», когда туда ничего не легло.
        try expect(
            maxDurationStopMessage(outcome: .savedToHistory,
                                   limitMinutes: 20,
                                   language: .russian),
            equals: "Запись остановлена: лимит 20 мин — текст в «Истории»",
            "auto-stop with saved text must point at History"
        )
        try expect(
            maxDurationStopMessage(outcome: .savedToHistory,
                                   limitMinutes: 20,
                                   language: .english),
            equals: "Recording stopped at the 20-minute limit — the text is in History",
            "auto-stop message must localise"
        )
        try expect(
            maxDurationStopMessage(outcome: .emptyTranscription,
                                   limitMinutes: 20,
                                   language: .russian),
            equals: "Запись остановлена: лимит 20 мин",
            "an empty transcription must not promise text in History"
        )
        try expect(
            maxDurationStopMessage(outcome: .failed,
                                   limitMinutes: 20,
                                   language: .russian),
            equals: "Запись остановлена: лимит 20 мин — не получилось распознать",
            "a failed recovery must not promise text in History either"
        )

        let recoveryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictor-recovery-test-\(UUID().uuidString)")
            .appendingPathExtension("sdaudio")
        defer { try? FileManager.default.removeItem(at: recoveryURL) }
        let expectedSamples: [Float] = [-0.75, -0.125, 0, 0.25, 0.875]
        let journal = try PendingDictationJournal(url: recoveryURL)
        journal.append(Array(expectedSamples.prefix(2)))
        journal.append(Array(expectedSamples.dropFirst(2)))
        journal.finish()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation journal should round-trip captured samples"
        )
        let recoveryHandle = try FileHandle(forWritingTo: recoveryURL)
        try recoveryHandle.seekToEnd()
        try recoveryHandle.write(contentsOf: Data([0x7f]))
        try recoveryHandle.close()
        try expect(
            try PendingDictationRecovery.loadSamples(from: recoveryURL),
            equals: expectedSamples,
            "pending dictation recovery should ignore a partial trailing sample after a crash"
        )
        let recoveryAttributes = try FileManager.default.attributesOfItem(atPath: recoveryURL.path)
        guard let recoveryMode = recoveryAttributes[.posixPermissions] as? NSNumber else {
            throw SelfTestFailure.failed("pending dictation journal should expose POSIX permissions")
        }
        try expect(
            recoveryMode.intValue,
            equals: 0o600,
            "pending dictation journal should be private"
        )

        let processed = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Dictor")],
            removeFillerWords: true
        )
        try expect(
            processed,
            equals: DictationTextProcessingResult(text: "Dictor is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 1),
            "dictation text processing should trim, apply corrections, then remove fillers"
        )

        let preservedFillers = processedDictationText(
            rawTranscript: "  Um, parakeet is fast.  ",
            corrections: [TranscriptCorrection(source: "parakeet", replacement: "Dictor")],
            removeFillerWords: false
        )
        try expect(
            preservedFillers,
            equals: DictationTextProcessingResult(text: "Um, Dictor is fast.",
                                                  appliedCorrectionCount: 1,
                                                  removedFillerWordCount: 0),
            "dictation text processing should preserve fillers when the setting is off"
        )

        try testSpeechModelTextRepair()

        let markerText = systemAudioMuteMarkerText(pid: 12345,
                                                   date: Date(timeIntervalSince1970: 0))
        try expect(
            systemAudioMuteMarkerProcessID(from: markerText),
            equals: Optional(pid_t(12345)),
            "system audio mute marker should preserve the owning pid"
        )
        try expect(
            systemAudioMuteMarkerProcessID(from: "created=bad\n"),
            equals: pid_t?.none,
            "system audio mute marker parsing should ignore missing pids"
        )

        let script = systemAudioMuteWatchdogScript()
        for fragment in [
            #"PID="$1""#,
            #"MARKER="$2""#,
            #"/bin/kill -0 "$PID""#,
            "/usr/bin/osascript -e 'set volume without output muted'",
            #"/bin/rm -f "$MARKER""#,
        ] {
            guard script.contains(fragment) else {
                throw SelfTestFailure.failed("system audio mute watchdog script missing fragment: \(fragment)")
            }
        }

        // Mute command outcome: command failure and verified-unmuted
        // are definitive "not muted"; an ambiguous verification after
        // a successful command must be assumed muted so the recovery
        // marker + watchdog stay armed.
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: true),
            equals: .muted,
            "verified mute should report muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: nil),
            equals: .assumedMuted,
            "successful command with failed verification must assume muted"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: true, verifiedMuted: false),
            equals: .failed,
            "verified-unmuted after the command is a definitive failure"
        )
        try expect(
            systemAudioMuteCommandOutcome(commandSucceeded: false, verifiedMuted: true),
            equals: .failed,
            "a failed command is not muted regardless of verification"
        )

        // Probe decision: only a definitive "output is live" while the
        // recording still wants the mute arms recovery and mutes.
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: false),
            equals: .armRecoveryAndMute,
            "live output during an active recording should mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: true, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a user-set mute must not be stomped"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: nil, unmuteAlreadyRequested: false),
            equals: .standDown,
            "a failed probe must not risk stomping an unseen user mute"
        )
        try expect(
            systemAudioMuteProbeDecision(mutedState: false, unmuteAlreadyRequested: true),
            equals: .standDown,
            "a recording that already ended should not mute"
        )

        // Mute completion decision: assumed mutes behave exactly like
        // verified mutes (recovery stays armed); a definitive failure
        // disarms; a release that raced the command unmutes at once.
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "verified mute during recording should hold"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: false),
            equals: .stayMuted,
            "assumed mute must keep recovery armed, not disarm it"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .failed, unmuteAlreadyRequested: false),
            equals: .disarmRecovery,
            "definitive mute failure should disarm marker and watchdog"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .muted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during the mute command should unmute immediately"
        )
        try expect(
            systemAudioMuteCommandDecision(outcome: .assumedMuted, unmuteAlreadyRequested: true),
            equals: .beginUnmute,
            "release during an assumed mute should also unmute immediately"
        )

        // Unmute request routing per lifecycle phase.
        try expect(
            systemAudioUnmuteRequestDecision(phase: .idle),
            equals: .nothingToDo,
            "no lifecycle → nothing to unmute"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .probing),
            equals: .deferUntilCommandSettles,
            "release during the probe defers to the probe completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muting),
            equals: .deferUntilCommandSettles,
            "release during the mute command defers to its completion"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .muted),
            equals: .beginUnmute,
            "release while muted unmutes immediately"
        )
        try expect(
            systemAudioUnmuteRequestDecision(phase: .unmuting),
            equals: .nothingToDo,
            "release while an unmute is in flight should not double-issue"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-mute-marker-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let marker = root.appendingPathComponent("system-audio-muted")
        try writeSystemAudioMuteMarker(to: marker, text: markerText)
        var markerStat = stat()
        guard lstat(marker.path, &markerStat) == 0 else {
            throw SelfTestFailure.failed("system audio mute marker should exist")
        }
        try expect((markerStat.st_mode & S_IFMT) == S_IFREG,
                   equals: true,
                   "system audio mute marker should be a regular file")
        try expect(Int(markerStat.st_mode & mode_t(0o777)),
                   equals: 0o600,
                   "system audio mute marker should be private")
        try expect(
            String(data: try Data(contentsOf: marker), encoding: .utf8),
            equals: markerText,
            "system audio mute marker should contain the expected pid"
        )

        let target = root.appendingPathComponent("target-marker")
        try Data("target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("linked-marker")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            try writeSystemAudioMuteMarker(to: symlink, text: "bad\n")
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "system audio mute marker should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "system audio mute marker should leave symlink targets untouched"
        )
    }

    private static func testPowerStateRecoveryDecision() throws {
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: true,
                                                isCoreRuntimeReady: true,
                                                isReady: true,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: false,
            "sleep during termination should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: false,
                                                audioIsRunning: false),
            equals: false,
            "sleep before runtime startup should not schedule wake recovery"
        )
        try expect(
            shouldResumeRuntimeAfterSystemSleep(isTerminating: false,
                                                isCoreRuntimeReady: false,
                                                isReady: false,
                                                isRecording: true,
                                                audioIsRunning: true),
            equals: true,
            "active recording should schedule wake recovery even if readiness is already down"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: false,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .ignore,
            "wake without a sleep-paused runtime should do nothing"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: true,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during transcription should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: true,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .deferUntilIdle,
            "wake during startup should defer runtime recovery"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: true),
            equals: .startAudioRuntime,
            "wake after a loaded model should restart audio without reloading the model"
        )
        try expect(
            wakeRuntimeRecoveryAction(shouldResumeAfterWake: true,
                                      isTerminating: false,
                                      hasStartupTask: false,
                                      isBusy: false,
                                      isSpeechModelReady: false),
            equals: .startFullStartup,
            "wake without a loaded model should fall back to full startup"
        )
    }

    static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )

        try expect(
            state.transition(for: event(.keyDown, keycode: f7.keycode), hotkey: f7, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "recorded F-key keyDown should suppress and press"
        )
    }

    static func testCustomShortcutMatching() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: 40,
                                    modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown, keycode: 40, flags: commandShift),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "custom shortcut should trigger when its exact modifiers are held"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: 40),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "custom shortcut release should not depend on modifier release order"
        )
        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: .pass,
            "custom shortcut should ignore incomplete modifier combinations"
        )
    }

    /// Cmd+Tab переставал переключать приложения, стоило назначить
    /// диктовку на «Command + правый Option»: перехватчик глотал каждое
    /// событие Command, потому что Command входит в сочетание.
    /// Cmd+C при этом работал и сбивал с толку — обычные сочетания
    /// читают флаг из самого события клавиши, а переключатель приложений
    /// живёт на удержании Command.
    private static func testCompanionModifierReachesTheSystem() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: RIGHT_OPTION_KEYCODE,
                                    modifiers: .maskCommand)
        let unrelatedEnter = hotkeyChoice(forKeycode: 80)
        let command = CGEventFlags.maskCommand.rawValue

        func send(keycode: CGKeyCode, flags: UInt64) -> HotkeyTransitionResult {
            state.transition(for: event(.flagsChanged, keycode: keycode, flags: flags),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnter,
                             triggerMode: .toggle,
                             isRecording: false)
        }

        try expect(
            send(keycode: LEFT_COMMAND_KEYCODE, flags: command),
            equals: .pass,
            "holding Command alone must reach the system, or Cmd+Tab never opens"
        )
        try expect(
            send(keycode: LEFT_COMMAND_KEYCODE, flags: 0),
            equals: .pass,
            "releasing Command must reach the system, or it stays stuck down"
        )

        // Само сочетание при этом продолжает работать.
        _ = send(keycode: LEFT_COMMAND_KEYCODE, flags: command)
        try expect(
            send(keycode: RIGHT_OPTION_KEYCODE,
                 flags: command | CGEventFlags.maskAlternate.rawValue),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "the assigned key still starts dictation and is still swallowed"
        )
        // И отпускание Command после сочетания тоже обязано дойти:
        // иначе система остаётся уверенной, что Command всё ещё зажат.
        _ = send(keycode: RIGHT_OPTION_KEYCODE, flags: command)
        try expect(
            send(keycode: LEFT_COMMAND_KEYCODE, flags: 0).suppress,
            equals: false,
            "the trailing Command release must reach the system too"
        )
    }

    static func testModifierOnlyChordMatching() throws {
        try testCompanionModifierReachesTheSystem()

        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                    modifiers: [.maskAlternate, .maskCommand])
        let unrelatedEnterShortcut = hotkeyChoice(forKeycode: 80)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = alternate | CGEventFlags.maskCommand.rawValue

        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            // Раньше здесь стояло «первый модификатор аккорда
            // зарезервирован» — и это утверждение и было багом: пока
            // сочетание не набрано, модификатор принадлежит системе.
            "a companion modifier on its own belongs to the system, not to us"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "Option+Command should start dictation when configured as the main shortcut"
        )
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            // Аккорд замкнулся на клавише-спутнике, а не на назначенной,
            // поэтому событие уходит системе: диктовка останавливается,
            // но модификатор остаётся её собственностью.
            equals: HotkeyTransitionResult(suppress: false, actions: [.release]),
            "the same modifier chord should stop dictation on its next activation"
        )
    }

    static func testConfigurableEnterShortcut() throws {
        var state = HotkeyTransitionState()
        let standard = hotkeyChoice(forKeycode: 96)
        let enterShortcut = hotkeyChoice(forKeycode: 40,
                                         modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: commandShift),
                             hotkey: standard,
                             enterHotkey: enterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "a user-configured Enter shortcut should use the Enter completion path"
        )
    }

    static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )

        var toggleState = HotkeyTransitionState()
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right Option should start when it is the configured toggle hotkey"
        )
        _ = toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true)
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right Option should stop instead of being swallowed by the Enter chord"
        )
    }

    static func testOptionCommandEnterChordStopsWithEnter() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue

        var state = HotkeyTransitionState()
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "right option opens the enter chord but stays the system's key"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "right option + right command should stop dictation through the alternate release path"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "enter chord should suppress the paired right command release"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: 0),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "the paired right option release goes back to the system, not swallowed"
        )

    }

    static func testEnterShortcutModeSelection() throws {
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insert),
            equals: false,
            "insert mode should make the primary shortcut finish without Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insert),
            equals: true,
            "the alternate shortcut should invert insert mode"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insertAndEnter),
            equals: true,
            "insert-and-Enter mode should make the primary shortcut press Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insertAndEnter),
            equals: false,
            "the alternate shortcut should invert insert-and-Enter mode"
        )

        var state = HotkeyTransitionState()
        let primary = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = hotkeyChoice(forKeycode: 96)
        try expect(
            state.transition(for: event(.keyDown, keycode: alternate.keycode),
                             hotkey: primary,
                             enterHotkey: alternate,
                             alternateCompletionEnabled: false,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "a disabled alternate shortcut should not be intercepted"
        )
    }

    static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    static func testToggleGatedPressDoesNotFlipToggleState() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        // A press the app would reject (e.g. a transcription in
        // flight) must suppress the key but not flip the toggle —
        // otherwise the next press emits a swallowed .release and
        // only the third press records.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.rejectedBusyPress]),
            "gated toggle press should suppress without flipping state but emit rejectedBusyPress for feedback"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "press after a gated press should start immediately"
        )
        // The stop-side press must NOT be gated: once a recording is
        // active (canStartRecording is false by definition), the
        // press still has to stop it.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: true, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "gate must not block the toggle press that stops a recording"
        )
        // Hold mode ignores the gate entirely — handlePress discarding
        // the press leaves no state behind in hold mode.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "hold-mode press should be unaffected by the gate"
        )
    }

    static func testEscapePassesThroughWhenNotRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyDown should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape autorepeat should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyUp should pass through when not recording"
        )
    }

    static func testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.cancel]),
            "Escape keyDown should suppress and cancel while recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "Escape autorepeat from a canceled press should stay suppressed"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "paired Escape keyUp should stay suppressed after cancel"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "later Escape keyUp should pass through once the canceled press is complete"
        )
    }

    static func event(
        _ type: CGEventType,
        keycode: CGKeyCode,
        flags: UInt64 = 0,
        isAutoRepeat: Bool = false
    ) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(
            typeRawValue: type.rawValue,
            keycode: keycode,
            flagsRawValue: flags,
            isAutoRepeat: isAutoRepeat
        )
    }

    /// Плавающая капсула (макет 6c): прилипание к краям и удержание в
    /// пределах экрана. Проверить это мышью нельзя — нужен второй монитор,
    /// терпение и хорошая память на пиксели.
    private static func testFloatingCapsuleGeometry() throws {
        let m = FloatingCapsuleMetrics.self
        // Экран без Дока и строки меню: visibleFrame, а не frame.
        let visible = NSRect(x: 0, y: 60, width: 1440, height: 840)
        let size = NSSize(width: 200 + m.shadowInset * 2, height: 30 + m.shadowInset * 2)

        func window(capsuleAt point: NSPoint) -> NSRect {
            // Из положения капсулы — положение окна: оно шире на поле под тень.
            NSRect(origin: NSPoint(x: point.x - m.shadowInset, y: point.y - m.shadowInset),
                   size: size)
        }

        // Отпущена в семи точках от левого края — прилипает и встаёт на 16.
        let nearLeft = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: NSPoint(x: visible.minX + 7, y: 400)),
            visibleFrame: visible)
        try expect(nearLeft.x + m.shadowInset, equals: visible.minX + m.snapMargin,
                   "a capsule dropped near the left edge should snap to it")

        // Отпущена посреди экрана — остаётся там, где её отпустили.
        let middlePoint = NSPoint(x: 600, y: 400)
        let middle = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: middlePoint), visibleFrame: visible)
        try expect(middle, equals: window(capsuleAt: middlePoint).origin,
                   "a capsule dropped in the open should stay where it was left")

        // Правый край: прилипает правым боком капсулы, а не окна.
        let nearRight = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: NSPoint(x: visible.maxX - 200 - 5, y: 400)),
            visibleFrame: visible)
        try expect(nearRight.x + m.shadowInset + 200,
                   equals: visible.maxX - m.snapMargin,
                   "the capsule's own right edge should land on the margin")

        // Низ экрана: над Доком, а не под ним.
        let nearBottom = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: NSPoint(x: 600, y: visible.minY + 9)),
            visibleFrame: visible)
        try expect(nearBottom.y + m.shadowInset, equals: visible.minY + m.snapMargin,
                   "a capsule near the bottom should sit above the Dock, not under it")

        // Уехавшую за экран возвращаем: монитор мог отключиться или сменить
        // разрешение, и капсула осталась бы недосягаемой.
        let offscreen = FloatingCapsuleMetrics.clampedOrigin(
            NSPoint(x: 5000, y: -3000), windowSize: size, visibleFrame: visible)
        try expect(offscreen.x + m.shadowInset + 200, equals: visible.maxX,
                   "a capsule off the right side should come back to the edge")
        try expect(offscreen.y + m.shadowInset, equals: visible.minY,
                   "a capsule below the screen should come back to the bottom")

        // Состояния растут в одну сторону: покой → наведение → запись.
        try MainActor.assumeIsolated {
            let view = FloatingCapsuleView(frame: .zero)
            view.hotkeyTitle = "⌘ ⌥"
            let idle = view.capsuleWidth(for: .idle)
            let hover = view.capsuleWidth(for: .hover)
            let recording = view.capsuleWidth(for: .recording)
            try expect(idle < hover, equals: true,
                       "hover shows actions and must be wider than rest: \(idle) vs \(hover)")
            // Строго по макету 6c: запись — самое широкое состояние. Раньше
            // здесь стояла дизъюнкция (hover < recording || recording > idle),
            // которая при уже доказанном idle < hover почти не могла упасть.
            try expect(hover < recording, equals: true,
                       "recording is the widest state: \(hover) vs \(recording)")
            try expect(view.geometry.height(for: .idle)
                        < view.geometry.height(for: .recording), equals: true,
                       "the capsule grows from rest to recording, never shrinks")

            // Размер — общий с капсулой у курсора: в записи высоты совпадают
            // число в число, Large — макет 6c как есть, и ширина следует за
            // размером, а не остаётся от прежнего.
            let large = FloatingCapsuleGeometry(size: .large)
            try expect([large.idleHeight, large.hoverHeight, large.recordingHeight],
                       equals: [30, 40, 44],
                       "Large keeps the mockup 6c heights")
            for size in RecordingHUDSize.allCases {
                let geometry = FloatingCapsuleGeometry(size: size)
                try expect(geometry.recordingHeight, equals: size.capsuleHeight,
                           "recording height must match the cursor capsule for \(size.rawValue)")
                try expect(geometry.idleHeight < geometry.hoverHeight
                            && geometry.hoverHeight < geometry.recordingHeight, equals: true,
                           "states must grow rest → hover → recording for \(size.rawValue)")
                for pointSize in [geometry.hotkeyFontSize, geometry.dictateFontSize,
                                  geometry.historyFontSize, geometry.timerFontSize,
                                  geometry.hintFontSize] {
                    try expect(pointSize >= 10, equals: true,
                               "no capsule text may drop below 10 pt for \(size.rawValue)")
                }
            }
            view.geometry = FloatingCapsuleGeometry(size: .compact)
            let compactRecording = view.capsuleWidth(for: .recording)
            try expect(compactRecording < recording, equals: true,
                       "a compact capsule must be narrower than the large one: \(compactRecording) vs \(recording)")
            try expect(view.windowSize(for: .recording).height,
                       equals: RecordingHUDSize.compact.capsuleHeight + FloatingCapsuleMetrics.shadowInset * 2,
                       "the window follows the geometry height")
        }
    }

    /// Список «Истории» создаёт только видимые строки.
    ///
    /// Раньше он строил строку на каждую диктовку: на 1125 записях раскладка
    /// раздела занимала 27 секунд, и столько же — каждый клик и каждая буква
    /// в поиске, потому что окно пересобирается целиком. Заметить это на
    /// превью было нельзя: фикстура превью — четыре записи.
    ///
    /// Тест держит то, что экран снимком не показывает: число созданных строк
    /// не зависит от длины списка, а строка остаётся достижимой для мыши и
    /// умещается в видимую область.
    private static func testHistoryListVirtualization() throws {
        try MainActor.assumeIsolated {
            final class Receiver: NSObject {
                var clickedIndex: Int?
                @objc func clicked(_ sender: SDHistoryResultRow) { clickedIndex = sender.entryIndex }
            }
            let receiver = Receiver()
            let rowCount = 5_000
            var created = 0
            let list = SDHistoryListView(rowCount: rowCount) { position in
                created += 1
                return SDHistoryResultRow(
                    entryIndex: position,
                    meta: "12 слов",
                    time: "10:00",
                    text: "Диктовка номер \(position): достаточно длинный текст, чтобы перенестись на вторую строку",
                    highlight: "",
                    isPinned: false,
                    isSelected: position == 0,
                    target: receiver,
                    action: #selector(Receiver.clicked(_:)))
            }
            let size = NSSize(width: 328, height: 600)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered,
                                  defer: false)
            list.frame = NSRect(origin: .zero, size: size)
            window.contentView = list
            list.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()

            try expect(list.materializedRowCount > 0, equals: true,
                       "the list must show something")
            try expect(list.materializedRowCount < 40, equals: true,
                       "only visible rows may exist as views, got \(list.materializedRowCount) of \(rowCount)")
            try expect(created < 200, equals: true,
                       "row construction must not scale with the list: \(created) rows built for \(rowCount) entries")

            @MainActor
            func firstRow(in view: NSView) -> SDHistoryResultRow? {
                if let row = view as? SDHistoryResultRow { return row }
                for subview in view.subviews {
                    if let found = firstRow(in: subview) { return found }
                }
                return nil
            }
            guard let row = firstRow(in: list) else {
                throw SelfTestFailure.failed("the list shows no row")
            }
            let rowFrame = row.convert(row.bounds, to: list)
            try expect(rowFrame.maxX <= list.contentView.frame.maxX + 0.5, equals: true,
                       "a row must fit the visible width: \(rowFrame.maxX) vs \(list.contentView.frame.maxX)")
            try expect(rowFrame.width > 200, equals: true,
                       "a row must take the column width, got \(rowFrame.width)")

            // Достижимость: точка внутри строки обязана попадать в неё, а не в
            // таблицу, — иначе клик достанется механизму выделения.
            let probe = NSPoint(x: rowFrame.midX, y: rowFrame.midY)
            var hit = list.hitTest(list.superview?.convert(probe, from: list) ?? probe)
            var reachedRow = false
            while let view = hit {
                if view === row { reachedRow = true; break }
                hit = view.superview
            }
            try expect(reachedRow, equals: true, "a click inside a row must land on the row")
            NSApp.sendAction(#selector(Receiver.clicked(_:)), to: receiver, from: row)
            try expect(receiver.clickedIndex, equals: row.entryIndex,
                       "the row must report which entry was clicked")
        }
    }

    /// Крестик очистки поиска по истории.
    ///
    /// Системный крестик NSSearchField в этом окне не работал вовсе: поле без
    /// рамки (`isBordered = false`) кладёт редактор текста на всю свою площадь
    /// и ещё на пару точек за края — замерено. Кнопка при этом честно
    /// рисовалась, но попадание мыши доставалось NSTextView, и нажатий она не
    /// видела ни одного. Нарисованная и мёртвая кнопка хуже отсутствующей,
    /// поэтому крестик теперь свой — и лежит за пределами поля.
    ///
    /// Тест сторожит именно достижимость: кнопка не должна пересекаться с
    /// полем и обязана иметь адресата.
    private static func testHistorySearchClearButton() throws {
        try MainActor.assumeIsolated {
            let panel = DictorControlPanelApp()
            panel.mainSection = .history
            panel.mainHistorySearch = "звонка"
            let view = panel.makeMainWindowView()
            view.frame = NSRect(origin: .zero, size: MAIN_WINDOW_SIZE)
            view.layoutSubtreeIfNeeded()

            @MainActor
            func firstSearchField(in view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                for subview in view.subviews {
                    if let found = firstSearchField(in: subview) { return found }
                }
                return nil
            }

            guard let field = firstSearchField(in: view), let box = field.superview else {
                throw SelfTestFailure.failed("history search field not found")
            }
            guard let clear = box.subviews.compactMap({ $0 as? NSButton }).first else {
                throw SelfTestFailure.failed("clear button is missing while the query is not empty")
            }
            try expect(clear.target != nil && clear.action != nil, equals: true,
                       "the clear button must have somewhere to send the click")
            // Зазор в 4 pt: редактор поля вылезает за его границы примерно на
            // 3,5 pt, и меньший зазор снова спрятал бы кнопку под текст.
            try expect(clear.frame.minX >= field.frame.maxX + 4, equals: true,
                       "the clear button must sit clear of the text editor, " +
                       "button at \(clear.frame.minX), field ends at \(field.frame.maxX)")

            // И обратное: без запроса крестика быть не должно — стирать нечего.
            panel.mainHistorySearch = ""
            let empty = panel.makeMainWindowView()
            empty.frame = NSRect(origin: .zero, size: MAIN_WINDOW_SIZE)
            empty.layoutSubtreeIfNeeded()
            guard let emptyField = firstSearchField(in: empty),
                  let emptyBox = emptyField.superview else {
                throw SelfTestFailure.failed("history search field not found for the empty query")
            }
            try expect(emptyBox.subviews.contains(where: { $0 is NSButton }), equals: false,
                       "an empty query should show no clear button")
        }
    }

    /// Кнопки строки «Сегодня»: копировать и открыть запись целиком.
    ///
    /// Тест действия прошёл бы и на кнопке, до которой нельзя дотянуться —
    /// ровно так однажды и вышло с крестиком в поиске. Поэтому проверяется
    /// достижимость: у строки есть адресат обоих селекторов, значки не
    /// налезают на время, и `hitTest` в центре значка возвращает значок, а не
    /// лежащий поверх текст.
    private static func testTodayRecentRowActions() throws {
        try MainActor.assumeIsolated {
            let panel = DictorControlPanelApp()
            let copySelector = Selector(("todayRecentRowClicked:"))
            let openSelector = Selector(("todayRecentRowOpen:"))
            try expect(panel.responds(to: copySelector), equals: true,
                       "the copy action has no receiver")
            try expect(panel.responds(to: openSelector), equals: true,
                       "the open action has no receiver")

            // Значки живут под наведением мыши; курсора в тесте нет, поэтому
            // включаем тот же режим, которым пользуется экспорт превью.
            SDRecentEntryRowView.previewForcesActionsVisible = true
            defer { SDRecentEntryRowView.previewForcesActionsVisible = false }

            let row = SDRecentEntryRowView(
                transcript: "Привет! По итогам звонка присылаю короткое резюме",
                entryIndex: 0,
                preview: "Привет! По итогам звонка присылаю короткое резюме",
                time: "14:32",
                copyTooltip: "Копировать",
                openTooltip: "Открыть целиком",
                target: panel,
                copyAction: copySelector,
                openAction: openSelector)
            row.frame = NSRect(x: 0, y: 0, width: 700, height: 48)
            row.layoutSubtreeIfNeeded()

            @MainActor
            func icons(in view: NSView) -> [SDRowIconButton] {
                if let button = view as? SDRowIconButton { return [button] }
                return view.subviews.flatMap(icons(in:))
            }
            let buttons = icons(in: row)
            try expect(buttons.count, equals: 2,
                       "the row should offer copy and open, nothing else")

            for button in buttons {
                // Значок без подписи молчит: tooltip здесь — единственное,
                // что объясняет, что случится по нажатию.
                try expect(button.toolTip?.isEmpty == false, equals: true,
                           "an icon button without a tooltip explains nothing")
                // Строка лежит в начале координат, поэтому её собственная
                // система совпадает с той, в которой считает `hitTest`.
                let centre = button.convert(NSPoint(x: button.bounds.midX,
                                                    y: button.bounds.midY),
                                            to: row)
                let hit = row.hitTest(centre)
                let reachable = hit === button || (hit?.isDescendant(of: button) ?? false)
                try expect(reachable, equals: true,
                           "a click in the middle of the icon lands on \(hit.map { "\(type(of: $0))" } ?? "nothing")")
            }

            // Значки не должны наезжать на время: макет 6a кладёт их правее,
            // и пересечение означало бы, что одно из двух не нажать.
            let timeLabel = { () -> NSTextField? in
                @MainActor
                func fields(in view: NSView) -> [NSTextField] {
                    if let field = view as? NSTextField { return [field] }
                    return view.subviews.flatMap(fields(in:))
                }
                return fields(in: row).first { $0.stringValue == "14:32" }
            }()
            guard let timeLabel else {
                throw SelfTestFailure.failed("the row lost its time label")
            }
            for button in buttons {
                let frame = button.convert(button.bounds, to: row)
                try expect(frame.minX >= timeLabel.frame.maxX, equals: true,
                           "an icon overlaps the time: icon at \(frame.minX), "
                           + "time ends at \(timeLabel.frame.maxX)")
                try expect(frame.maxX <= row.bounds.maxX, equals: true,
                           "an icon hangs off the row: \(frame.maxX) > \(row.bounds.maxX)")
            }

            // И последнее звено: действие доходит до эффекта. Кнопка с живым
            // адресатом, которая никуда не переключает, — тот же мёртвый код,
            // только с виду рабочий.
            let settings = Settings.shared
            let savedEntries = settings.recentTranscriptEntries
            defer { settings.recentTranscriptEntries = savedEntries }
            settings.recentTranscriptEntries = [
                TranscriptHistoryEntry(text: "первая диктовка",
                                       transcriptionDurationSeconds: 1,
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                TranscriptHistoryEntry(text: "вторая диктовка",
                                       transcriptionDurationSeconds: 1,
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
            ]
            panel.mainSection = .today
            // Запрос с прошлого раза не должен спрятать выбранную запись.
            panel.mainHistorySearch = "ничего такого в истории нет"
            let secondRow = SDRecentEntryRowView(
                transcript: "вторая диктовка",
                entryIndex: 1,
                preview: "вторая диктовка",
                time: "14:33",
                copyTooltip: "Копировать",
                openTooltip: "Открыть целиком",
                target: panel,
                copyAction: copySelector,
                openAction: openSelector)
            panel.perform(openSelector, with: secondRow)
            try expect(panel.mainSection.rawValue, equals: MainWindowSection.history.rawValue,
                       "opening an entry must switch the window to History")
            try expect(panel.mainHistorySearch, equals: "",
                       "a stale search query would hide the entry that was just opened")
            try expect(panel.historySelectionKey?.contains("вторая диктовка"), equals: true,
                       "History must select the very entry that was clicked, "
                       + "got \(panel.historySelectionKey ?? "nothing")")
        }
    }

    /// Пауза перед показом состояния службы (макет 8c). Проверять её живьём
    /// нечем: прогрев длится 0,2 с, и увидеть, что он не мигнул, можно только
    /// по часам.
    private static func testServiceStatusHold() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        // Первое состояние показывается сразу: пустой подвал хуже мигания.
        let hold = ServiceStatusHold()
        try expect(hold.settle(.ready(latencyMilliseconds: 180), now: at(0)).identity,
                   equals: "ready",
                   "first status should show without waiting")

        // Прогрев на 0,2 с не должен показаться вовсе.
        try expect(hold.settle(.warmingUp, now: at(0.1)).identity, equals: "ready",
                   "a fresh status must wait out the pause")
        try expect(hold.settle(.ready(latencyMilliseconds: 180), now: at(0.3)).identity,
                   equals: "ready",
                   "a status shorter than the pause must never reach the screen")

        // Состояние, которое выдержало паузу, показывается.
        try expect(hold.settle(.verifying(done: 3, total: 21), now: at(1.0)).identity,
                   equals: "ready",
                   "the pause starts when the new status appears")
        try expect(hold.settle(.verifying(done: 5, total: 21), now: at(1.3)).fingerprint,
                   equals: "verifying:5/21",
                   "a status that outlived the pause should be shown with fresh numbers")

        // Числа внутри показанного состояния идут без задержки: задержанный
        // прогресс — это вторая ложь вместо первой.
        try expect(hold.settle(.verifying(done: 9, total: 21), now: at(1.31)).fingerprint,
                   equals: "verifying:9/21",
                   "numbers inside the shown status must pass through immediately")

        // Пока пауза идёт, окно знает, когда её будить.
        let pending = ServiceStatusHold()
        _ = pending.settle(.ready(latencyMilliseconds: nil), now: at(0))
        try expect(pending.pendingDeadline, equals: nil,
                   "a settled status needs no wake-up")
        _ = pending.settle(.failed, now: at(1))
        try expect(pending.pendingDeadline, equals: at(1 + ServiceStatusHold.delay),
                   "a waiting status should ask for a wake-up at the end of the pause")
        _ = pending.settle(.failed, now: at(1.3))
        try expect(pending.pendingDeadline, equals: nil,
                   "a shown status should cancel its wake-up")
    }

    /// Сценарий «вышел → открыл снова»: выход обязан остановить службу
    /// сейчас, но не отключить её насовсем. Регрессия v1.7.0: выход из окна
    /// писал `agentEnabled = false`, флаг переживал перезапуск, и следующее
    /// открытие Dictor поднимало окно без службы — в меню-баре пусто,
    /// диктовка мертва, а диалог выхода обещал «пока вы не откроете Dictor
    /// снова». Тест гоняет реальные дисковые эффекты выхода против живых
    /// Settings и сверяет их с решением панели при следующем старте.
    private static func testQuitLeavesServiceEnabled() throws {
        let settings = Settings.shared
        let saved = settings.agentEnabled
        defer { settings.agentEnabled = saved }

        // Служба была включена, человек вышел целиком.
        settings.agentEnabled = true
        var serviceStopped = false
        DictorControlPanelApp.applyQuitSideEffects(settings: settings,
                                                   stopService: { serviceStopped = true })
        try expect(serviceStopped, equals: true,
                   "quit must stop the running service")
        try expect(settings.agentEnabled, equals: true,
                   "quit must not disable the service for the next launch")
        try expect(DictorControlPanelApp.shouldStartAgentOnLaunch(
                       agentEnabled: settings.agentEnabled,
                       agentAlreadyRunning: false),
                   equals: true,
                   "after quit, reopening Dictor must bring the service back")

        // Служба выключена тумблером — выход не должен её воскрешать.
        settings.agentEnabled = false
        DictorControlPanelApp.applyQuitSideEffects(settings: settings,
                                                   stopService: {})
        try expect(settings.agentEnabled, equals: false,
                   "quit must not re-enable a service the user switched off")
        try expect(DictorControlPanelApp.shouldStartAgentOnLaunch(
                       agentEnabled: settings.agentEnabled,
                       agentAlreadyRunning: false),
                   equals: false,
                   "a switched-off service must stay off after reopening")

        // Служба уже работает — второй запуск не поднимает её повторно.
        try expect(DictorControlPanelApp.shouldStartAgentOnLaunch(
                       agentEnabled: true,
                       agentAlreadyRunning: true),
                   equals: false,
                   "a running service must not be started twice")
    }

    /// Наведение на график. Столбик без подписи оси и без шкалы Y сообщает
    /// ровно одно — «выше соседнего»; число под курсором и есть та шкала.
    /// Тест держит достижимость: за годом столбики уходят в три пикселя, и
    /// колонка обязана ловить курсор целиком, включая зазор и пустоту над
    /// коротким столбиком, — иначе часть чисел не увидеть вовсе.
    private static func testStatsChartHover() throws {
        try MainActor.assumeIsolated {
            let buckets = (0..<30).map { index in
                StatsBucket(label: "день \(index + 1)",
                            words: index == 7 ? 46 : index,
                            previousWords: index % 4,
                            axisLabel: nil)
            }
            let chart = SDComparisonBarChart(buckets: buckets, peakIndex: 7, peakText: "46")
            chart.frame = NSRect(x: 0, y: 0, width: 700, height: 168)
            chart.layoutSubtreeIfNeeded()

            // Каждый столбик достижим мышью хотя бы в одной точке.
            var reachable = Set<Int>()
            for step in 0..<700 {
                if let index = chart.bucketIndex(at: NSPoint(x: CGFloat(step) + 0.5, y: 84)) {
                    reachable.insert(index)
                }
            }
            try expect(reachable.count, equals: buckets.count,
                       "every bucket must be hoverable; \(buckets.count - reachable.count) "
                       + "of \(buckets.count) cannot be pointed at")

            // Соседние столбики различимы: попадание не съезжает на один и
            // тот же индекс по всей ширине.
            try expect(chart.bucketIndex(at: NSPoint(x: 5, y: 84)), equals: 0,
                       "the leftmost pixel must hit the first bucket")
            try expect(chart.bucketIndex(at: NSPoint(x: 695, y: 84)),
                       equals: buckets.count - 1,
                       "the rightmost pixel must hit the last bucket")

            // Пустой столбик тоже отзывается: ноль — это ответ, а не промах.
            let zeroIndex = 0
            let zeroX = (700.0 / CGFloat(buckets.count)) * (CGFloat(zeroIndex) + 0.5)
            try expect(chart.bucketIndex(at: NSPoint(x: zeroX, y: 84)), equals: zeroIndex,
                       "a bucket with zero words must still be hoverable")

            // Подпись под курсором — про этот столбик, а не про пик.
            chart.calloutFormatter = { "\($0.label): \($0.words)" }
            let hoverX = (700.0 / CGFloat(buckets.count)) * 3.5
            let move = NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: hoverX, y: 84), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)!
            chart.mouseMoved(with: move)
            try expect(chart.hoveredIndex, equals: 3,
                       "moving the mouse over the fourth column must select it")
            chart.mouseExited(with: move)
            try expect(chart.hoveredIndex, equals: nil,
                       "leaving the chart must hand the callout back to the peak")
        }
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

