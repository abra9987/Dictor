import AppKit

extension DictorApp {
    func installHotkeyCaptureObservers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self,
                           selector: #selector(externalHotkeyCaptureDidBegin(_:)),
                           name: HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(externalHotkeyCaptureDidEnd(_:)),
                           name: HOTKEY_CAPTURE_END_NOTIFICATION,
                           object: nil)
    }

    func removeHotkeyCaptureObservers() {
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = nil
        let center = DistributedNotificationCenter.default()
        center.removeObserver(self, name: HOTKEY_CAPTURE_BEGIN_NOTIFICATION, object: nil)
        center.removeObserver(self, name: HOTKEY_CAPTURE_END_NOTIFICATION, object: nil)
    }

    @objc private func externalHotkeyCaptureDidBegin(_ notification: Notification) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        hotkey.stop()
        hotkeyPausedForExternalCapture = true
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = Timer.scheduledTimer(
            withTimeInterval: HOTKEY_CAPTURE_FAILSAFE_SECONDS,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeHotkeyAfterExternalCapture(reason: "failsafe")
            }
        }
        log("HotkeyListener: paused for control-panel shortcut capture")
    }

    @objc private func externalHotkeyCaptureDidEnd(_ notification: Notification) {
        resumeHotkeyAfterExternalCapture(reason: "control panel finished")
    }

    private func resumeHotkeyAfterExternalCapture(reason: String) {
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = nil
        guard hotkeyPausedForExternalCapture, !isTerminating else { return }
        hotkeyPausedForExternalCapture = false
        guard isReady else {
            log("HotkeyListener: shortcut capture ended while service was not ready")
            return
        }
        guard hotkey.start() else {
            isReady = false
            recordStartupFailure(
                stage: .hotkeyListener,
                error: NSError(
                    domain: "Dictor",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "The hotkey listener could not resume after shortcut capture."]
                ),
                reason: "external shortcut capture"
            )
            return
        }
        log("HotkeyListener: resumed after shortcut capture (\(reason))")
    }

    /// Сбой «нет микрофона» лечится подключением, а не кнопкой: как только в
    /// системе появился вход, служба запускается сама.
    func installAudioInputDeviceWatcher() {
        audioInputDeviceWatcher?.stop()
        let watcher = AudioInputDeviceWatcher { [weak self] in
            Task { @MainActor in
                self?.handleAudioInputDevicesChanged()
            }
        }
        watcher.start()
        audioInputDeviceWatcher = watcher
    }

    private func handleAudioInputDevicesChanged() {
        let devices = availableAudioInputDevices()
        let failureIsMissingInput = startupFailure?.isMissingAudioInput == true
        guard shouldRestartAfterInputDevicesChanged(
            failureIsMissingInput: failureIsMissingInput,
            hasStartupTask: startupTask != nil || isRestartingAudioInput,
            isTerminating: isTerminating,
            inputDevices: devices) else { return }
        log("audio input devices changed: \(devices.count) input(s) now available; restarting after the no-microphone failure")
        startStartup(reason: "microphone connected")
    }

    func installWorkspacePowerObservers() {
        removeWorkspacePowerObservers()
        let center = NSWorkspace.shared.notificationCenter
        workspacePowerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemWillSleep()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemDidWake()
                }
            },
        ]
    }

    func installGlobalMouseMonitor() {
        removeGlobalMouseMonitor()
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            let capturedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isTerminating,
                      let app = NSWorkspace.shared.frontmostApplication else {
                    return
                }
                self.lastExternalClick = LastExternalClick(
                    applicationPID: app.processIdentifier,
                    point: point,
                    capturedAt: capturedAt
                )
            }
        }
    }

    func removeGlobalMouseMonitor() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        lastExternalClick = nil
    }

    func removeWorkspacePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspacePowerObservers {
            center.removeObserver(observer)
        }
        workspacePowerObservers.removeAll()
    }

    // MARK: - Sleep/wake runtime recovery

    private func handleSystemWillSleep() {
        guard !isTerminating else { return }

        if shouldResumeRuntimeAfterSystemSleep(isTerminating: isTerminating,
                                               isCoreRuntimeReady: isCoreRuntimeReady,
                                               isReady: isReady,
                                               isRecording: isRecording,
                                               audioIsRunning: audio.isRunning) {
            shouldResumeRuntimeAfterWake = true
            didLogDeferredWakeRecovery = false
        }

        if isRecording || audio.isRunning {
            cancelActiveRecording(reason: "system sleep", runDeferredRefresh: false)
        }

        guard isCoreRuntimeReady || isReady else {
            rebuildMenu()
            return
        }

        pauseAudioRuntimeForSystemSleep()
    }

    private func handleSystemDidWake() {
        guard !isTerminating else { return }
        guard shouldResumeRuntimeAfterWake else { return }
        log("system wake detected")
        recoverRuntimeAfterWakeIfNeeded(reason: "system wake")
    }

    private func pauseAudioRuntimeForSystemSleep() {
        cancelMaxDurationAutoRelease()
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        pendingAudioRouteRefresh = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        stopAudioEngineImmediately()

        startupFailure = nil
        startupStatusTitle = "Waiting for system wake…"
        setMenuBarState(isBusy ? .busy : .loading)
        log("system sleep: audio runtime paused")
        rebuildMenu()
    }

    func recoverRuntimeAfterWakeIfNeeded(reason: String) {
        switch wakeRuntimeRecoveryAction(shouldResumeAfterWake: shouldResumeRuntimeAfterWake,
                                         isTerminating: isTerminating,
                                         hasStartupTask: startupTask != nil,
                                         isBusy: isBusy,
                                         isSpeechModelReady: isSpeechModelReady) {
        case .ignore:
            return
        case .deferUntilIdle:
            if !didLogDeferredWakeRecovery {
                didLogDeferredWakeRecovery = true
                log("system wake recovery deferred until idle")
            }
            rebuildMenu()
        case .startAudioRuntime:
            shouldResumeRuntimeAfterWake = false
            didLogDeferredWakeRecovery = false
            startAudioRuntimeAfterWake(reason: reason)
        case .startFullStartup:
            shouldResumeRuntimeAfterWake = false
            didLogDeferredWakeRecovery = false
            startStartup(reason: reason)
        }
    }

    private func startAudioRuntimeAfterWake(reason: String) {
        guard !isRestartingAudioInput else {
            return
        }
        guard startupTask == nil, !isBusy, !isTerminating else {
            shouldResumeRuntimeAfterWake = true
            recoverRuntimeAfterWakeIfNeeded(reason: reason)
            return
        }

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        startupFailure = nil
        startupStatusTitle = "Restarting audio input…"
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        stopAudioEngineImmediately()
        setMenuBarState(.loading)
        rebuildMenu()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Restarting audio input…")
                guard !isTerminating else { return }
                isCoreRuntimeReady = true
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !isTerminating else { return }
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
    }

    // MARK: - Settings submenu

    func restartAudioForInputDeviceChange() {
        restartAudioInput(reason: "input device change")
    }

    func suppressAudioConfigurationChangesFromAppEngineUpdate() {
        let suppressedUntil = Date().timeIntervalSinceReferenceDate
            + AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS
        audioConfigurationChangeSuppressedUntil = max(audioConfigurationChangeSuppressedUntil ?? 0,
                                                      suppressedUntil)
    }

    private func shouldIgnoreAppOwnedAudioConfigurationChange() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if audioConfigurationChangeIsSuppressed(now: now,
                                                suppressedUntil: audioConfigurationChangeSuppressedUntil) {
            return true
        }
        if let suppressedUntil = audioConfigurationChangeSuppressedUntil,
           now >= suppressedUntil {
            audioConfigurationChangeSuppressedUntil = nil
        }
        return false
    }

    func cancelAudioIdleStop() {
        audioIdleStopWorkItem?.cancel()
        audioIdleStopWorkItem = nil
    }

    func scheduleAudioIdleStop(reason: String) {
        // Сюда приходит каждая закончившаяся запись, чем бы она ни кончилась:
        // удобная точка, чтобы запомнить, когда человек диктовал в последний раз.
        lastDictationActivityUptime = ProcessInfo.processInfo.systemUptime
        cancelAudioIdleStop()
        guard audio.isEngineStarted, !isRecording, !isBusy, !isTerminating else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.closeIdleAudioInputIfNeeded(reason: reason)
        }
        audioIdleStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AUDIO_IDLE_STOP_DELAY_SECONDS, execute: work)
    }

    func stopAudioEngineImmediately() {
        cancelAudioIdleStop()
        if audio.isEngineStarted {
            suppressAudioConfigurationChangesFromAppEngineUpdate()
        }
        audio.stopEngine()
    }

    private func closeIdleAudioInputIfNeeded(reason: String) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        let wasEngineStarted = audio.isEngineStarted
        stopAudioEngineImmediately()
        if wasEngineStarted {
            log("AudioCapture: idle audio input closed (\(reason))")
        }
    }

    func handleAudioConfigurationChange() {
        if shouldIgnoreAppOwnedAudioConfigurationChange() {
            log("AudioCapture: app-owned audio configuration change ignored")
            return
        }

        switch audioRouteChangeAction(isTerminating: isTerminating,
                                      isRestartingAudioInput: isRestartingAudioInput,
                                      isCoreRuntimeReady: isCoreRuntimeReady,
                                      isRecording: isRecording,
                                      isBusy: isBusy,
                                      hasStartupTask: startupTask != nil) {
        case .ignore:
            return
        case .rebuildMenuOnly:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
        case .deferRefresh:
            log("AudioCapture: audio configuration changed")
            pendingAudioRouteRefresh = true
            log("AudioCapture: audio route refresh deferred")
            rebuildMenu()
        case .restartNow:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
            restartAudioInput(reason: "audio configuration change")
        }
    }

    @discardableResult
    func runDeferredAudioRouteRefreshIfNeeded() -> Bool {
        guard pendingAudioRouteRefresh,
              !isRecording, !isBusy, startupTask == nil, isCoreRuntimeReady, !isTerminating else { return false }
        pendingAudioRouteRefresh = false
        restartAudioInput(reason: "deferred audio configuration change")
        return true
    }

    private func restartAudioInput(reason: String) {
        guard !isRestartingAudioInput else { return }
        guard isCoreRuntimeReady else {
            rebuildMenu()
            return
        }

        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        isReady = false
        isRecording = false
        isBusy = false
        hotkey.stop()
        setMenuBarState(.loading)
        rebuildMenu()
        stopAudioEngineImmediately()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Restarting audio input…")
                isCoreRuntimeReady = true
                completeReadinessIfPossible(reason: reason)
            } catch {
                isCoreRuntimeReady = false
                isReady = false
                isRecording = false
                isBusy = false
                hotkey.stop()
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
    }
}
