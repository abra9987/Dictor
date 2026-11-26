// Готовность к диктовке: ожидание разрешений, слежение за настройками из
// окна и применение их на лету (хоткеи, капсула).

import Foundation

extension DictorApp {
    // MARK: - Permission readiness

    func enterPermissionBlockedState(missing: [Permission]? = nil, reason: String) {
        let missing = missing ?? missingPermissions()
        guard !missing.isEmpty else {
            completeReadinessIfPossible(reason: reason)
            return
        }

        if isRecording || audio.isRunning {
            recoverActiveRecordingToHistory(reason: "permission lost: \(reason)") { [weak self] _ in
                self?.enterPermissionBlockedState(missing: missing, reason: reason)
            }
            return
        }

        cancelMaxDurationAutoRelease()
        if audio.isEngineStarted {
            stopAudioEngineImmediately()
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isRecording = false
        isBusy = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()

        logPermissionReadinessWait(missing)
        startPermissionReadinessMonitor(reason: reason)
        setMenuBarState(.loading)
        rebuildMenu()
    }

    func missingPermissions() -> [Permission] {
        Permission.allCases.filter { !Permissions.isGranted($0) }
    }

    @discardableResult
    private func logPermissionReadinessWait(_ missing: [Permission]) -> Bool {
        let key = missing.map(\.rawValue).joined(separator: "|")
        guard key != lastPermissionReadinessMissingKey else { return false }
        lastPermissionReadinessMissingKey = key
        log("readiness retry waiting for permissions: \(missing.map(\.rawValue).joined(separator: ", "))")
        return true
    }

    /// Слежение за настройками хоткеев. Панель пишет их в UserDefaults,
    /// агент подхватывает без перезапуска — «Сохранить и перезапустить»
    /// пользователю больше не нужен.
    func startSettingsWatch() {
        guard settingsWatchTimer == nil else { return }
        settingsWatchTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                                  target: self,
                                                  selector: #selector(settingsWatchTimerFired(_:)),
                                                  userInfo: nil,
                                                  repeats: true)
        settingsWatchTimer?.tolerance = 0.3
    }

    @objc private func settingsWatchTimerFired(_ timer: Timer) {
        // Отсчёт тишины для смены модели: пока идёт запись или распознавание,
        // тишины нет. Отметки в начале и в конце диктовки одной не хватает —
        // запись длиннее двух минут с перезапуском аудиовхода в конце
        // оставила бы отметку на самом её начале.
        if isRecording || isBusy {
            lastDictationActivityUptime = ProcessInfo.processInfo.systemUptime
        }
        guard !isRecording, !isBusy, !isTerminating else { return }
        _ = settings.refreshFromDisk()
        applyHotkeySettings(force: false)
        applyFloatingCapsuleSettings()
        applyLiveSettings()
        switchToUpdatedSpeechModelIfIdle()
    }

    /// Настройки, которые окно меняет, а служба обязана подхватить сама.
    ///
    /// Хоткеи и капсула умели это и раньше, а вот микрофон и словарь — нет:
    /// человек выбирал в окне другой микрофон, окно молчало, и диктовка
    /// продолжала писать со старого до перезапуска службы. Со словарём было
    /// зеркально: запись, добавленная из окна, не попадала в файл
    /// синхронизации, потому что писал его только тот, кто правил словарь в
    /// самой службе.
    ///
    /// Сравнение с прошлым значением здесь не оптимизация, а условие
    /// работоспособности: таймер тикает раз в секунду, а перезапуск аудиовхода
    /// стоит дорого.
    private func applyLiveSettings() {
        let device = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldRestartAudioInput(previous: lastSeenInputDevice, current: device) {
            log("input device changed in settings: restarting audio")
            restartAudioForInputDeviceChange()
        }
        lastSeenInputDevice = device

        // Сравнение самого списка: `TranscriptCorrection` равнимая, а разница в
        // числе записей отсекается первой — раз в секунду это ничего не стоит.
        let corrections = settings.transcriptCorrections

        // Файл синхронизации подключает и отключает окно, а цикл
        // синхронизации живёт здесь. Смена пути пересоздаёт цикл с чистым
        // состоянием: отпечаток и базу старого файла нельзя скармливать
        // слиянию с новым. Правка словаря, приехавшая вместе со сменой
        // файла, в старый файл не пишется — источником истины окно уже
        // сделало новый файл, форсированный скан его и прочитает.
        let syncPath = settings.transcriptCorrectionsSyncFile
        if let previousPath = lastSeenCorrectionSyncFilePath, previousPath != syncPath {
            log("correction sync file changed outside the agent: reconnecting")
            lastSeenCorrections = corrections
            correctionSyncFileFingerprint = nil
            correctionSyncBaselineCorrections = []
            startCorrectionSyncIfConfigured()
        }
        lastSeenCorrectionSyncFilePath = syncPath

        if let previous = lastSeenCorrections, previous != corrections {
            log("corrections changed outside the agent: writing the sync file")
            _ = writeCorrectionsToSyncFile(presentErrors: false)
        }
        lastSeenCorrections = corrections

        // История: окно стирает её целиком или удаляет запись, а агент держал
        // копию с момента старта — и на каждой диктовке записывал её поверх
        // стёртого. «Действие необратимо» отменялось первой же диктовкой.
        // Сравниваются сырые байты архива, декодирование — только при
        // реальном внешнем изменении.
        let historyData = settings.recentTranscriptEntriesStoredData
        if historyData != lastSeenHistoryArchiveData {
            lastSeenHistoryArchiveData = historyData
            history = settings.recentTranscriptEntries
            log("history changed outside the agent: reloaded (\(history.count) entries)")
            rebuildMenu()
        }

        // Цикл проверки обновлений стартует один раз при готовности службы, и
        // если тумблер в тот момент был выключен, включение обратно не
        // поднимало его до перезапуска: тумблер «включено», «Приватность»
        // обещает «1 раз в 6 ч», а служба в сеть не ходит. Вызов идемпотентен
        // и дёшев — внутри два guard'а: по настройке и по уже живому циклу.
        startUpdateCheckLoop()

        // Значок в Dock: тумблер меняет окно, запуск и закрытие окна меняют
        // pid-файл — и то и другое служба замечает здесь. Внутри guard по
        // уже стоящей политике, так что тик обходится в чтение pid-файла.
        refreshActivationPolicy()
    }

    // MARK: - Плавающая капсула (макет 6c)

    /// Капсулу включают и выключают из настроек, как и хоткеи, — без
    /// перезапуска службы.
    func applyFloatingCapsuleSettings() {
        guard settings.floatingCapsuleEnabled else {
            if floatingCapsule.isVisible { floatingCapsule.close() }
            return
        }
        floatingCapsule.delegate = self
        floatingCapsule.applySize(settings.recordingHUDSize)
        let title = capsuleHotkeyTitle()
        if floatingCapsule.isVisible {
            floatingCapsule.updateHotkey(title, language: settings.interfaceLanguage)
        } else {
            floatingCapsule.show(hotkeyTitle: title, language: settings.interfaceLanguage)
        }
    }

    /// В покое капсула показывает ровно то, что человек нажимает.
    private func capsuleHotkeyTitle() -> String {
        keycapLabels(for: settings.configuredHotkey, language: settings.interfaceLanguage)
            .joined(separator: " ")
    }

    private func hotkeySignature() -> String {
        [settings.configuredHotkey.name,
         settings.configuredEnterHotkey.name,
         settings.alternateCompletionEnabled ? "1" : "0",
         settings.triggerMode.rawValue].joined(separator: "|")
    }

    func applyHotkeySettings(force: Bool) {
        let signature = hotkeySignature()
        guard force || signature != lastAppliedHotkeySignature else { return }
        lastAppliedHotkeySignature = signature
        hotkey.setHotkey(settings.configuredHotkey)
        hotkey.setEnterHotkey(settings.configuredEnterHotkey)
        hotkey.setAlternateCompletionEnabled(settings.alternateCompletionEnabled)
        hotkey.setTriggerMode(settings.triggerMode)
        if !force {
            log("hotkeys reloaded without restart → \(settings.configuredHotkey.name)")
            rebuildMenu()
            publishAgentState()
        }
    }

    func startPermissionReadinessMonitor(reason: String) {
        guard permissionReadinessTimer == nil else { return }
        log("permission readiness monitor started (\(reason))")
        permissionReadinessTimer = Timer.scheduledTimer(timeInterval: 2,
                                                        target: self,
                                                        selector: #selector(permissionReadinessTimerFired(_:)),
                                                        userInfo: nil,
                                                        repeats: true)
        permissionReadinessTimer?.tolerance = 0.5
    }

    func stopPermissionReadinessMonitor() {
        guard permissionReadinessTimer != nil else { return }
        permissionReadinessTimer?.invalidate()
        permissionReadinessTimer = nil
        lastPermissionReadinessMissingKey = nil
        log("permission readiness monitor stopped")
    }

    @objc private func permissionReadinessTimerFired(_ timer: Timer) {
        guard isCoreRuntimeReady else {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            if logPermissionReadinessWait(missing) {
                rebuildMenu()
            }
            return
        }

        if isReady {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            enterPermissionBlockedState(missing: missing, reason: "permission monitor")
            return
        }

        completeReadinessIfPossible(reason: "permission monitor")
    }
}
