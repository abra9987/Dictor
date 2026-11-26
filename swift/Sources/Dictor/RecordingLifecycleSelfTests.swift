// Самотесты жизненного цикла записи: смена маршрута звука, запись от
// нажатия до текста и восстановление после сна.

import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testAudioRouteChangeDecision() throws {
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

    static func testRecordingLifecycle() throws {
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

    static func testPowerStateRecoveryDecision() throws {
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
}
#endif
