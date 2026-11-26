import FluidAudio
import Foundation

extension DictorApp {
    func startStartup(reason: String) {
        guard startupTask == nil else {
            log("startup ignored (\(reason)): already in progress")
            rebuildMenu()
            return
        }

        prepareForStartupAttempt()
        let speechModelProfile = settings.speechModelProfile

        // Load ASR FIRST, then audio + hotkey. Reversing this order
        // makes the first-launch CoreML compile of the ANE Encoder
        // hang. The bench under experiments/swift-bench/ never opens
        // an audio session so it doesn't see this.
        startupTask = Task { @MainActor in
            var stage = StartupFailureStage.speechModel
            defer {
                startupTask = nil
                rebuildMenu()
                recoverRuntimeAfterWakeIfNeeded(reason: "startup finished after wake")
            }

            do {
                let throttler = ProgressThrottler()
                let loadedSpeechModel = try await asr.load(
                    profile: speechModelProfile,
                    progressHandler: { [weak self] progress in
                        let title = speechModelStartupStatusTitle(progress)
                        let fraction = speechModelStartupProgressValue(progress)
                        guard throttler.shouldDispatch(title, fraction) else { return }
                        Task { @MainActor in
                            self?.updateSpeechModelStartupProgress(progress)
                        }
                    },
                    verificationProgress: { [weak self] verified, total in
                        Task { @MainActor in
                            self?.updateModelVerificationProgress(verified: verified, total: total)
                        }
                    })
                guard !Task.isCancelled, !isTerminating else { return }
                noteLoadedSpeechModel(loadedSpeechModel)

                do {
                    let warmUpTiming = try await asr.warmUp()
                    log("ASR: CoreML warm-up completed in \(millisecondsLabel(warmUpTiming.totalSeconds))")
                } catch {
                    // Model loading succeeded, so a failed best-effort warm-up
                    // must not make the dictation service unavailable.
                    log("ASR: CoreML warm-up skipped: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, !isTerminating else { return }

                fallbackSpeechModelProfileAfterStartupFailure = nil
                isSpeechModelReady = true
                speechModelStartupProgressFraction = nil

                await recoverPendingDictationsAfterStartup()
                guard !Task.isCancelled, !isTerminating else { return }

                stage = .audioInput
                startupStatusTitle = "Starting audio input…"
                rebuildMenu()

                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Starting audio input…")
                guard !Task.isCancelled, !isTerminating else { return }

                isCoreRuntimeReady = true
                startupFailure = nil
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !Task.isCancelled, !isTerminating else { return }
                recordStartupFailure(stage: stage, error: error, reason: reason)
            }
        }
    }

    private func recoverPendingDictationsAfterStartup() async {
        let pendingURLs = PendingDictationRecovery.pendingURLs()
        guard !pendingURLs.isEmpty else { return }

        settings.refreshFromDisk()
        startupStatusTitle = "Recovering interrupted dictation…"
        rebuildMenu()
        log("pending dictation recovery: \(pendingURLs.count) recording(s) found")

        for url in pendingURLs {
            guard !Task.isCancelled, !isTerminating else { return }
            do {
                let samples = try PendingDictationRecovery.loadSamples(from: url)
                guard !samples.isEmpty else {
                    PendingDictationRecovery.remove(url)
                    continue
                }
                let duration = Double(samples.count) / SAMPLE_RATE
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: samples,
                    language: settings.dictationLanguage,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
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
                }
                PendingDictationRecovery.remove(url)
                log("pending dictation recovered: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
            } catch {
                log("pending dictation recovery deferred: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Обновление модели без простоя

    /// Запоминает, на какой модели поднялась служба. Если это модель прошлой
    /// версии — запускает фоновую загрузку текущей.
    private func noteLoadedSpeechModel(_ loaded: LoadedSpeechModel) {
        switch loaded {
        case .current:
            if isRunningOnPreviousSpeechModel {
                log("ASR: the service moved from \(SpeechModelPackage.previous.profile.shortName) to \(SpeechModelPackage.current.profile.shortName)")
            }
            isRunningOnPreviousSpeechModel = false
            cancelSpeechModelUpdate()
        case .previous:
            isRunningOnPreviousSpeechModel = true
            // Отсчёт тишины начинается заново: служба только что поднялась,
            // и перезапускать её сразу же ради новой модели незачем.
            lastDictationActivityUptime = ProcessInfo.processInfo.systemUptime
            startSpeechModelUpdateIfNeeded()
        case .previousAfterCurrentFailed:
            // Текущая модель скачана, цела и не запустилась. Качать её снова
            // незачем, а человек должен увидеть, на чём работает диктовка.
            isRunningOnPreviousSpeechModel = true
            cancelSpeechModelUpdate()
            speechModelUpdatePhase = .failedToLoad
        }
    }

    func cancelSpeechModelUpdate() {
        speechModelUpdateGeneration += 1
        speechModelUpdateTask?.cancel()
        speechModelUpdateTask = nil
        speechModelUpdateRetryWorkItem?.cancel()
        speechModelUpdateRetryWorkItem = nil
        speechModelUpdatePhase = nil
        speechModelUpdateFraction = nil
        speechModelUpdateFailedAttempts = 0
    }

    private func startSpeechModelUpdateIfNeeded() {
        guard isRunningOnPreviousSpeechModel,
              speechModelUpdateTask == nil,
              speechModelUpdatePhase != .waitingForIdle,
              speechModelUpdatePhase != .failedToLoad,
              !isTerminating else { return }
        speechModelUpdateRetryWorkItem?.cancel()
        speechModelUpdateRetryWorkItem = nil
        speechModelUpdateGeneration += 1
        let generation = speechModelUpdateGeneration
        speechModelUpdatePhase = .downloading
        speechModelUpdateFraction = nil
        log("ASR: downloading \(SpeechModelPackage.current.profile.shortName) in the background; dictation stays on \(SpeechModelPackage.previous.profile.shortName)")

        let throttler = ProgressThrottler()
        // Вне главного потока и с низким приоритетом: сверка сумм — это
        // чтение 630 МБ с диска, и ни капсуле, ни распознаванию оно мешать не
        // должно.
        speechModelUpdateTask = Task.detached(priority: .utility) { [weak self] in
            var failure: Error?
            do {
                try await SpeechModelUpdater.fetchCurrentModel(progressHandler: { [weak self] progress in
                    let fraction = speechModelStartupProgressValue(progress)
                    guard throttler.shouldDispatch("", fraction) else { return }
                    Task { @MainActor in
                        self?.updateSpeechModelUpdateProgress(fraction, generation: generation)
                    }
                })
            } catch {
                failure = error
            }
            await self?.finishSpeechModelUpdate(failure: failure, generation: generation)
        }
        rebuildMenu()
    }

    private func updateSpeechModelUpdateProgress(_ fraction: Double?, generation: Int) {
        guard generation == speechModelUpdateGeneration,
              speechModelUpdatePhase == .downloading,
              let fraction,
              fraction != speechModelUpdateFraction,
              !isTerminating else { return }
        speechModelUpdateFraction = fraction
        rebuildMenu()
    }

    private func finishSpeechModelUpdate(failure: Error?, generation: Int) {
        guard generation == speechModelUpdateGeneration, !isTerminating else { return }
        speechModelUpdateTask = nil
        speechModelUpdateFraction = nil
        let name = SpeechModelPackage.current.profile.shortName

        if let failure {
            speechModelUpdateFailedAttempts += 1
            let delay = SpeechModelUpdater.retryDelay(
                afterFailedAttempt: speechModelUpdateFailedAttempts,
                failure: failure)
            speechModelUpdatePhase = .retrying
            log("ASR: background download of \(name) failed (attempt \(speechModelUpdateFailedAttempts)); next attempt in \(Int(delay / 60)) min: \(failure.localizedDescription)")
            let work = DispatchWorkItem { [weak self] in
                self?.startSpeechModelUpdateIfNeeded()
            }
            speechModelUpdateRetryWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            speechModelUpdateFailedAttempts = 0
            speechModelUpdatePhase = .waitingForIdle
            log("ASR: \(name) is downloaded and verified; the service will move to it when dictation is idle")
        }
        rebuildMenu()
    }

    /// Переход на скачанную модель. Зовётся раз в секунду наблюдателем
    /// настроек; сам переход — обычный перезапуск службы, тот же путь, что
    /// после обновления приложения.
    func switchToUpdatedSpeechModelIfIdle() {
        // Служба, приостановленная на время сна, тоже занята: запуск посреди
        // сна сбросил бы отметку «поднять после пробуждения», и неудача с
        // микрофоном оставила бы её лежать.
        let occupied = isRecording || isBusy || startupTask != nil
            || isRestartingAudioInput || isSwitchingSpeechModel
            || isResettingSpeechModelCache || installingUpdateVersion != nil
            || shouldResumeRuntimeAfterWake || isTerminating
        guard SpeechModelUpdater.switchIsDue(
            updateIsReady: speechModelUpdatePhase == .waitingForIdle,
            serviceIsOccupied: occupied,
            secondsSinceLastDictation: ProcessInfo.processInfo.systemUptime
                - lastDictationActivityUptime) else { return }
        speechModelUpdatePhase = nil
        log("ASR: dictation is idle — restarting the service on \(SpeechModelPackage.current.profile.shortName)")
        startStartup(reason: "speech model update")
    }

    /// Что сказать окну и панели про модель, пока работает прежняя.
    var speechModelUpdateStatus: SpeechModelUpdateStatus? {
        guard isRunningOnPreviousSpeechModel, let phase = speechModelUpdatePhase else { return nil }
        return SpeechModelUpdateStatus(
            previousModelName: SpeechModelPackage.previous.profile.shortName,
            phase: phase,
            fraction: speechModelUpdateFraction)
    }

    func prepareForStartupAttempt() {
        cancelMaxDurationAutoRelease()

        if isRecording || audio.isRunning {
            let captured = audio.endRecording()
            if captured.recoveryURL != nil {
                log("startup restart: active dictation preserved for recovery")
            }
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isSpeechModelReady = false
        isRecording = false
        isBusy = false
        pendingAudioRouteRefresh = false
        shouldResumeRuntimeAfterWake = false
        didLogDeferredWakeRecovery = false
        startupFailure = nil
        startupStatusTitle = "Loading speech model…"
        speechModelStartupProgressFraction = nil

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            stopAudioEngineImmediately()
        }

        setMenuBarState(.loading)
        rebuildMenu()
    }

    private func updateModelVerificationProgress(verified: Int, total: Int) {
        guard !isTerminating else { return }
        verifiedModelFiles = verified
        totalModelFiles = total
        if verified >= total {
            // Проверка кончилась — число больше не актуально, дальше грузится
            // сама модель.
            verifiedModelFiles = nil
            totalModelFiles = nil
        }
        publishAgentState()
    }

    private func updateSpeechModelStartupProgress(_ progress: DownloadProgress) {
        guard startupTask != nil, !isTerminating else { return }
        let next = speechModelStartupStatusTitle(progress)
        let nextProgressFraction = speechModelStartupProgressValue(progress)
        guard next != startupStatusTitle
            || nextProgressFraction != speechModelStartupProgressFraction else { return }
        startupStatusTitle = next
        speechModelStartupProgressFraction = nextProgressFraction
        lastDownloadPhase = progress.phase
        publishAgentState()
        rebuildMenu()
    }

    func recordStartupFailure(stage: StartupFailureStage, error: Error, reason: String) {
        if stage == .speechModel,
           let fallback = fallbackSpeechModelProfileAfterStartupFailure,
           fallback != settings.speechModelProfile,
           !isTerminating {
            let failedProfile = settings.speechModelProfile
            fallbackSpeechModelProfileAfterStartupFailure = nil
            settings.speechModelProfile = fallback
            isSwitchingSpeechModel = true
            isCoreRuntimeReady = false
            isSpeechModelReady = false
            isReady = false
            isRecording = false
            isBusy = false
            startupFailure = nil
            startupStatusTitle = "Falling back to \(fallback.shortName)…"
            speechModelStartupProgressFraction = nil
            setMenuBarState(.loading)
            log("ASR: \(failedProfile.shortName) failed to load during switch; falling back to \(fallback.shortName): \(startupFailureLogDetail(stage: stage, error: error))")
            rebuildMenu()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTerminating else { return }
                Task { @MainActor in
                    await self.asr.unload()
                    self.isSwitchingSpeechModel = false
                    self.startStartup(reason: "speech model fallback")
                }
            }
            return
        }

        fallbackSpeechModelProfileAfterStartupFailure = nil
        isCoreRuntimeReady = false
        if stage == .speechModel {
            isSpeechModelReady = false
        }
        isReady = false
        isRecording = false
        isBusy = false
        speechModelStartupProgressFraction = nil
        stopRecordingLevelMeter()

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            stopAudioEngineImmediately()
        }

        let isMissingInput = isMissingAudioInputFailure(stage: stage,
                                                        inputDevices: availableAudioInputDevices())
        let detail = isMissingInput
            ? NO_MICROPHONE_FAILURE_DETAIL
            : startupFailureDetail(stage: stage, error: error)
        startupFailure = StartupFailure(stage: stage, detail: detail,
                                        isMissingAudioInput: isMissingInput)
        log("startup failed (\(reason), \(stage)): \(startupFailureLogDetail(stage: stage, error: error))")
        setMenuBarState(.error)
        if !missingPermissions().isEmpty {
            startPermissionReadinessMonitor(reason: reason)
        }
        rebuildMenu()
    }

    func startAudioInputWithRetries(reason: String,
                                            initialStatusTitle: String) async throws {
        let totalAttempts = AUDIO_START_RETRY_DELAYS_SECONDS.count + 1
        var lastError: Error?

        for attempt in 1...totalAttempts {
            try Task.checkCancellation()
            guard !isTerminating else { throw CancellationError() }

            startupStatusTitle = attempt == 1
                ? initialStatusTitle
                : "Starting audio input… (\(attempt)/\(totalAttempts))"
            rebuildMenu()

            do {
                didTouchAudioEngine = true
                suppressAudioConfigurationChangesFromAppEngineUpdate()
                try audio.startEngine(inputDevicePreference: settings.inputDevice)
                stopAudioEngineImmediately()
                return
            } catch {
                lastError = error
                stopAudioEngineImmediately()
                log("audio startup attempt \(attempt)/\(totalAttempts) failed (\(reason)): \(singleLineLogDetail(audioStartupErrorDescription(error)))")

                // Без единого входа повторять нечего: CoreAudio не передумает,
                // пока человек не подключит микрофон, а это подхватит
                // слушатель устройств.
                guard shouldRetryAudioStartup(inputDevices: availableAudioInputDevices()) else {
                    log("audio startup: no input devices on this Mac; not retrying until one appears")
                    throw error
                }

                guard let delay = audioStartupRetryDelaySeconds(afterFailedAttempt: attempt) else {
                    throw error
                }

                startupStatusTitle = audioStartupRetryStatusTitle(nextAttempt: attempt + 1,
                                                                  totalAttempts: totalAttempts,
                                                                  delaySeconds: delay)
                rebuildMenu()
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }

        if let lastError {
            throw lastError
        }
    }
}
