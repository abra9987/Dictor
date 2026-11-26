// Путь одной диктовки: нажатие хоткея начинает запись, отпускание ведёт её
// через распознавание и правку текста до вставки; отмена и спасение записи
// в историю, если до вставки не дошло.

import AppKit

extension DictorApp {
    // MARK: - Recording loop

    func handlePress() {
        lastDictationActivityUptime = ProcessInfo.processInfo.systemUptime
        guard !isDictationPaused else { return }
        guard isReady, !isRecording, !isBusy, !isTerminating else {
            // Audible cue when the previous transcription is still in
            // flight — without it the press vanishes silently and the
            // user thinks the hotkey broke. Only fires for the busy
            // case; model-loading and termination have their own UI.
            if isBusy, settings.playFeedbackSounds {
                Sounds.playError()
            }
            return
        }
        let missing = missingPermissions()
        guard missing.isEmpty else {
            enterPermissionBlockedState(missing: missing, reason: "hotkey press")
            return
        }
        let initialInsertionContext = insertionTargetQueryContext()
        if let initialInsertionContext {
            ElectronAccessibility.enableIfNeeded(pid: initialInsertionContext.applicationPID,
                                                 bundleIdentifier: initialInsertionContext.bundleIdentifier)
            BrowserTyping.wakeAccessibilityIfNeeded(pid: initialInsertionContext.applicationPID,
                                                    bundleIdentifier: initialInsertionContext.bundleIdentifier)
        }
        cancelAudioIdleStop()
        var recoveryJournal: PendingDictationJournal?
        do {
            recoveryJournal = try PendingDictationRecovery.createJournal()
            didTouchAudioEngine = true
            if !audio.isEngineStarted {
                suppressAudioConfigurationChangesFromAppEngineUpdate()
            }
            try audio.startRecording(inputDevicePreference: settings.inputDevice,
                                     recoveryJournal: recoveryJournal)
        } catch {
            recoveryJournal?.finish()
            PendingDictationRecovery.remove(recoveryJournal?.url)
            stopAudioEngineImmediately()
            log("recording start failed: \(error.localizedDescription)")
            // Служба готова, а микрофон пропал уже после запуска: наушники
            // убрали в кейс. Один звук ошибки причину не называл.
            if availableAudioInputDevices().isEmpty {
                log("recording start failed: no input devices on this Mac")
                signalDictationFailure(message: noMicrophoneDictationMessage(language: settings.interfaceLanguage))
            } else {
                signalDictationFailure()
            }
            return
        }
        isRecording = true
        if setupChecklistWindow?.isVisible == true {
            hotkeyTestSucceeded = true
            updateSetupChecklist()
        }
        startRecordingLevelMeter(initialContext: initialInsertionContext)
        if settings.playFeedbackSounds {
            Sounds.playStart()
        }
        muteIfNeededForRecording()
        log("press: recording")

        scheduleMaxDurationAutoRelease()
        rebuildMenu()
    }

    func handleRelease(shortcut: DictationReleaseShortcut = .standard,
                               hotkeyDetectedAt: TimeInterval? = nil) {
        guard isRecording, !isTerminating else { return }
        let releaseReceivedAt = ProcessInfo.processInfo.systemUptime
        let hotkeyDispatchSeconds = hotkeyDetectedAt.map { max(0, releaseReceivedAt - $0) }
        let settingsRefreshStartedAt = ProcessInfo.processInfo.systemUptime
        settings.refreshFromDisk()
        let settingsRefreshedAt = ProcessInfo.processInfo.systemUptime
        let shouldPressEnterAfterInsertion = shouldPressEnterAfterDictation(
            shortcut: shortcut,
            primaryBehavior: settings.primaryCompletionBehavior
        )
        let releasePermissionCheckStartedAt = ProcessInfo.processInfo.systemUptime
        let missing = missingPermissions()
        let releasePermissionCheckCompletedAt = ProcessInfo.processInfo.systemUptime
        guard missing.isEmpty else {
            recoverActiveRecordingToHistory(reason: "permission lost on release") { [weak self] _ in
                self?.enterPermissionBlockedState(missing: missing, reason: "hotkey release")
            }
            return
        }

        isRecording = false
        stopRecordingLevelMeter(hideHUD: false)
        cancelMaxDurationAutoRelease()
        unmuteIfWeMuted()

        let audioFinalizeStartedAt = ProcessInfo.processInfo.systemUptime
        let captured = audio.endRecording()
        let audioFinalizedAt = ProcessInfo.processInfo.systemUptime
        let samples = captured.samples
        let dur: Double
        switch recordingReleaseAction(capturedSampleCount: samples.count) {
        case .discardTooShort(let duration):
            dur = duration
            log("release: clip too short (\(String(format: "%.2f", dur)) s), discarding")
            PendingDictationRecovery.remove(captured.recoveryURL)
            hideRecordingHUD()
            let recordedWallSeconds = recordingStartedAtUptime.map { releaseReceivedAt - $0 } ?? 0
            if recordedWallSeconds >= CAPTURE_FAILURE_MIN_RECORDING_SECONDS {
                // Человек держал запись секунды, а звука не набралось и на
                // клип: захват молчал. Раньше это выглядело ровно как
                // случайное касание хоткея — ни звука, ни вспышки, ни
                // записи в истории, только строка в логе.
                log("recording ran \(String(format: "%.1f", recordedWallSeconds)) s but captured \(String(format: "%.2f", dur)) s — capture failed silently")
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            if !runDeferredAudioRouteRefreshIfNeeded() {
                scheduleAudioIdleStop(reason: "short clip")
            }
            return
        case .transcribe(let duration):
            dur = duration
        }
        isBusy = true

        // Start CoreML before AppKit/menu work. The UI still transitions
        // immediately, but its disk/menu updates now overlap inference.
        let asrRequestedAt = ProcessInfo.processInfo.systemUptime
        let transcriptionWorker = asr
        let language = settings.dictationLanguage
        let transcriptionTask = Task.detached(priority: .userInitiated) {
            let transcription = try await transcriptionWorker.transcribe(
                samples: samples,
                language: language,
                requestedAt: asrRequestedAt
            )
            return CompletedTranscriptionWorkerResult(
                transcription: transcription,
                completedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        // Что стоит перед курсором, читается, пока модель распознаёт: поле на
        // отпускании клавиши то же, в которое уйдёт текст, а время чтения
        // целиком прячется за распознаванием.
        let insertionContextTask = makeInsertionContextTask()

        let transcribingUIStartedAt = ProcessInfo.processInfo.systemUptime
        setMenuBarState(.busy)
        showTranscribingHUD()
        rebuildMenu()
        let transcribingUICompletedAt = ProcessInfo.processInfo.systemUptime
        log("release: \(String(format: "%.2f", dur)) s captured, transcribing")

        let taskEnqueuedAt = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            let taskStartedAt = ProcessInfo.processInfo.systemUptime
            var dictationFailed = false
            var insertedWordsForHUD: Int?
            do {
                let completed = try await transcriptionTask.value
                let transcription = completed.transcription
                let asrTiming = transcription.timing(
                    totalSeconds: completed.completedAt - asrRequestedAt
                )
                if !isTerminating {
                    let postprocessingStartedAt = ProcessInfo.processInfo.systemUptime
                    let processed = processedDictationText(rawTranscript: transcription.text,
                                                           corrections: settings.dictationTranscriptCorrections,
                                                           removeFillerWords: settings.removeFillerWords,
                                                           language: settings.dictationLanguage,
                                                           lexicon: settings.dictationTermLexicon)
                    let postprocessingCompletedAt = ProcessInfo.processInfo.systemUptime
                    if processed.appliedCorrectionCount > 0 {
                        log("transcript corrections applied: \(processed.appliedCorrectionCount)")
                    }
                    if processed.removedFillerWordCount > 0 {
                        log("filler words removed: \(processed.removedFillerWordCount)")
                    }
                    var cleaned = processed.text
                    // Умная вставка правит текст до записи в «Историю»: там
                    // обязано лежать ровно то, что ушло в поле. Пробел перед
                    // текстом — клей, как и хвост, и в историю не идёт.
                    var insertionLeadingSpace = false
                    if !cleaned.isEmpty, let insertionContextTask {
                        if let reading = await InsertionContextReader.value(
                            of: insertionContextTask,
                            within: InsertionContextReader.insertionWaitSeconds) {
                            let corrections = settings.dictationTranscriptCorrections
                            let adjusted = SmartInsertion.adjust(
                                cleaned,
                                context: reading.context,
                                lexicons: .system,
                                protectedWords: { SmartInsertion.protectedWords(in: corrections) },
                                sentWithEnter: shouldPressEnterAfterInsertion)
                            cleaned = adjusted.text
                            insertionLeadingSpace = adjusted.leadingSpace
                            log("smart insertion: \(adjusted.summary); \(reading.diagnostic)")
                        } else {
                            log("smart insertion: skipped, the field did not answer in time")
                        }
                    }
                    log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", asrTiming.totalSeconds)) s → \(cleaned.count) chars")
                    DiagnosticAudioSamples.saveIfEnabled(
                        samples: samples, audioSeconds: dur, inputChannels: audio.inputChannelCount,
                        language: settings.dictationLanguage, rawText: transcription.text,
                        processedText: processed.text, insertedText: cleaned)
                    if !cleaned.isEmpty {
                        let historyStartedAt = ProcessInfo.processInfo.systemUptime
                        addToHistory(
                            cleaned,
                            transcriptionDurationSeconds: asrTiming.totalSeconds,
                            asrTiming: asrTiming,
                            rebuildMenuAfterPersisting: false
                        )
                        recordDictationUsage(text: cleaned,
                                             audioSeconds: dur,
                                             asrSeconds: asrTiming.totalSeconds)
                        let historyCompletedAt = ProcessInfo.processInfo.systemUptime

                        let journalCleanupStartedAt = ProcessInfo.processInfo.systemUptime
                        PendingDictationRecovery.remove(captured.recoveryURL)
                        let journalCleanupCompletedAt = ProcessInfo.processInfo.systemUptime

                        let permissionRecheckStartedAt = ProcessInfo.processInfo.systemUptime
                        let missing = missingPermissions()
                        let permissionRecheckCompletedAt = ProcessInfo.processInfo.systemUptime
                        guard missing.isEmpty else {
                            isBusy = false
                            finishBusyHUD()
                            enterPermissionBlockedState(missing: missing, reason: "paste")
                            return
                        }

                        let insertionStartedAt = ProcessInfo.processInfo.systemUptime
                        let inserted = TextInserter.insert(
                            pastedText(from: cleaned,
                                       suffix: settings.pasteSuffix,
                                       leadingSpace: insertionLeadingSpace)
                        )
                        let insertionCompletedAt = ProcessInfo.processInfo.systemUptime
                        var enterDelaySeconds: Double?
                        if inserted {
                            insertedWordsForHUD = cleaned
                                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                                .count
                            if shouldPressEnterAfterInsertion {
                                let enterDelayStartedAt = ProcessInfo.processInfo.systemUptime
                                let enterDelayNanoseconds = UInt64(settings.enterDelayMilliseconds) * 1_000_000
                                if enterDelayNanoseconds > 0 {
                                    try? await Task.sleep(nanoseconds: enterDelayNanoseconds)
                                }
                                // Enter не жмётся вслепую: при вставке через
                                // буфер получатель обязан прийти за текстом.
                                // Не пришёл и за льготную секунду — ⌘V не
                                // дошёл, и Enter отправил бы поле, в которое
                                // ничего не вставилось.
                                let pasteConfirmed: Bool
                                if TextInserter.lastSuccessfulStrategy == .clipboardPaste {
                                    pasteConfirmed = await ClipboardPasteInserter.waitUntilPasteRead(
                                        timeout: ENTER_AFTER_PASTE_READ_GRACE_SECONDS)
                                } else {
                                    pasteConfirmed = true
                                }
                                if !pasteConfirmed {
                                    log("return skipped: paste was never read within the grace period")
                                } else if KeyboardShortcutPoster.postReturn() {
                                    log("return posted after dictation")
                                } else {
                                    log("return event creation failed")
                                }
                                enterDelaySeconds = ProcessInfo.processInfo.systemUptime - enterDelayStartedAt
                            }
                            if settings.playFeedbackSounds {
                                Sounds.playDone()
                            }
                        } else {
                            log("text insertion failed")
                            dictationFailed = true
                        }

                        log(DictationLatencyMetrics(
                            audioSeconds: dur,
                            hotkeyDispatchSeconds: hotkeyDispatchSeconds,
                            releasePreparationSeconds: audioFinalizeStartedAt - releaseReceivedAt,
                            settingsRefreshSeconds: settingsRefreshedAt - settingsRefreshStartedAt,
                            releasePermissionCheckSeconds: releasePermissionCheckCompletedAt - releasePermissionCheckStartedAt,
                            audioFinalizeSeconds: audioFinalizedAt - audioFinalizeStartedAt,
                            audioDetachSeconds: captured.detachSeconds,
                            journalFlushSeconds: captured.journalFlushSeconds,
                            audioFlattenSeconds: captured.flattenSeconds,
                            transcribingUISeconds: transcribingUICompletedAt - transcribingUIStartedAt,
                            taskQueueSeconds: taskStartedAt - taskEnqueuedAt,
                            releaseToASRSeconds: asrRequestedAt - releaseReceivedAt,
                            asrTiming: asrTiming,
                            postprocessingSeconds: postprocessingCompletedAt - postprocessingStartedAt,
                            historyPersistenceSeconds: historyCompletedAt - historyStartedAt,
                            journalCleanupSeconds: journalCleanupCompletedAt - journalCleanupStartedAt,
                            permissionRecheckSeconds: permissionRecheckCompletedAt - permissionRecheckStartedAt,
                            insertionDispatchSeconds: insertionCompletedAt - insertionStartedAt,
                            releaseToPasteDispatchSeconds: insertionCompletedAt - releaseReceivedAt,
                            enterDelaySeconds: enterDelaySeconds,
                            pasteSucceeded: inserted
                        ).logLine)
                    } else {
                        PendingDictationRecovery.remove(captured.recoveryURL)
                        // Запись нормальной длины, а распознавание вернуло
                        // пустоту — раньше это выглядело как «ничего не
                        // произошло»: ни текста, ни звука, ни записи в
                        // истории. Пустой результат — тоже отказ.
                        log("transcription returned empty text for \(String(format: "%.2f", dur)) s of audio")
                        dictationFailed = true
                    }
                }
            } catch {
                log("transcribe failed: \(error)")
                dictationFailed = true
            }
            isBusy = false
            if let words = insertedWordsForHUD, !dictationFailed, !isTerminating {
                showInsertedHUD(wordCount: words)
            } else {
                finishBusyHUD()
            }
            if dictationFailed && !isTerminating {
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            let didRestartAudio = runDeferredAudioRouteRefreshIfNeeded()
            recoverRuntimeAfterWakeIfNeeded(reason: "transcription finished after wake")
            if !didRestartAudio {
                scheduleAudioIdleStop(reason: "recording finished")
            }
        }
    }

    /// Запускает чтение текста перед курсором — или не запускает, если умная
    /// вставка выключена. Читает не главный поток: программа, которая не
    /// отвечает на запросы универсального доступа, не должна останавливать
    /// ни капсулу, ни перехват клавиш.
    private func makeInsertionContextTask() -> Task<(context: InsertionContext, diagnostic: String), Never>? {
        guard settings.smartInsertionEnabled,
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let applicationPID = app.processIdentifier
        let bundleIdentifier = app.bundleIdentifier ?? ""
        return Task.detached(priority: .userInitiated) {
            let reading = InsertionContextReader.read(frontmostPID: applicationPID,
                                                      frontmostBundleIdentifier: bundleIdentifier)
            return (InsertionContext(bundleIdentifier: reading.bundleIdentifier,
                                     textBeforeCaret: reading.textBeforeCaret),
                    reading.diagnostic)
        }
    }

    func recoverActiveRecordingToHistory(reason: String,
                                                 runDeferredRefresh: Bool = true,
                                                 completion: ((DictationRecoveryOutcome) -> Void)? = nil) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            completion?(.noAudio)
            return
        }

        cancelMaxDurationAutoRelease()
        let captured = audio.endRecording()
        let duration = Double(captured.samples.count) / SAMPLE_RATE
        isRecording = false
        stopRecordingLevelMeter(hideHUD: false)
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        guard !captured.samples.isEmpty else {
            PendingDictationRecovery.remove(captured.recoveryURL)
            hideRecordingHUD()
            setMenuBarState(.idle)
            rebuildMenu()
            log("recording ended without audio (\(reason))")
            completion?(.noAudio)
            return
        }

        isBusy = true
        setMenuBarState(.busy)
        showTranscribingHUD()
        rebuildMenu()
        log("recording ended nonstandard (\(reason)); recovering \(String(format: "%.2f", duration)) s to history")

        Task { @MainActor in
            var outcome = DictationRecoveryOutcome.failed
            do {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: captured.samples,
                    language: settings.dictationLanguage,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                if !isTerminating {
                    let processed = processedDictationText(rawTranscript: transcription.text,
                                                           corrections: settings.dictationTranscriptCorrections,
                                                           removeFillerWords: settings.removeFillerWords,
                                                           language: settings.dictationLanguage,
                                                           lexicon: settings.dictationTermLexicon)
                    if !processed.text.isEmpty {
                        addToHistory(
                            processed.text,
                            transcriptionDurationSeconds: timing.totalSeconds,
                            asrTiming: timing
                        )
                        recordDictationUsage(text: processed.text,
                                             audioSeconds: duration,
                                             asrSeconds: timing.totalSeconds)
                        outcome = .savedToHistory
                    } else {
                        outcome = .emptyTranscription
                    }
                    PendingDictationRecovery.remove(captured.recoveryURL)
                    log("recovered dictation: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
                }
            } catch {
                log("dictation recovery failed; audio retained for next launch: \(error.localizedDescription)")
            }

            guard !isTerminating else { return }
            isBusy = false
            finishBusyHUD()
            if outcome == .failed {
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            completion?(outcome)
            let didRestartAudio = runDeferredRefresh
                ? runDeferredAudioRouteRefreshIfNeeded()
                : false
            recoverRuntimeAfterWakeIfNeeded(reason: "dictation recovery finished after wake")
            if !didRestartAudio {
                scheduleAudioIdleStop(reason: reason)
            }
        }
    }

    func cancelActiveRecording(reason: String, runDeferredRefresh: Bool = true) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            return
        }

        recoverActiveRecordingToHistory(reason: reason,
                                        runDeferredRefresh: runDeferredRefresh)
    }

    // Termination cannot await transcription, so it only flushes the
    // recovery journal. The next launch transcribes it into history.
    func cancelRecordingForTermination() {
        cancelMaxDurationAutoRelease()
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.stop()

        let hadActiveRecording = isRecording || audio.isRunning
        let hadMute = systemAudioMutePhase != .idle
        if hadActiveRecording {
            let captured = audio.endRecording()
            if captured.recoveryURL != nil {
                log("terminate: active dictation preserved for next-launch recovery")
            }
        }
        stopRecordingLevelMeter()
        stopAudioEngineImmediately()
        isRecording = false
        isBusy = false
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        if hadActiveRecording || hadMute {
            log("terminate: active recording finalized")
        }
    }
}
