import AppKit

// MARK: - Quick panel (поповер меню-бара)

extension DictorApp: QuickPanelDelegate {

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Меню действий: отмена записи, разрешения, обновление, окно,
            // диагностика, выход. Настроек здесь больше нет — все они живут
            // в окне, и меню не обязано быть их вторым адресом.
            statusItem.menu = buildMenu()
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        let panel = quickPanel ?? {
            let created = DictorQuickPanel(state: quickPanelState())
            created.quickDelegate = self
            quickPanel = created
            return created
        }()
        panel.toggle(relativeTo: sender, state: quickPanelState())
    }

    /// Состояние службы для панели. Агент — это и есть служба, поэтому здесь
    /// оно известно напрямую, без чтения файла состояния.
    ///
    /// Наружу — состояние, выдержавшее паузу (макет 8c): прогрев длится 0,2 с
    /// и в шапке успевал только мигнуть.
    private func quickPanelServiceStatus() -> ServiceStatusKind {
        let settled = quickPanelStatusHold.settle(rawQuickPanelServiceStatus())
        scheduleQuickPanelStatusWakeup()
        return settled
    }

    /// Пока панель открыта, созревшую паузу некому донести до экрана: шапка
    /// пересобирается по событиям службы, а их в этот момент может не быть.
    private func scheduleQuickPanelStatusWakeup() {
        quickPanelStatusHoldTimer?.invalidate()
        quickPanelStatusHoldTimer = nil
        guard let deadline = quickPanelStatusHold.pendingDeadline,
              quickPanel?.isVisible == true else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        quickPanelStatusHoldTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.quickPanel?.isVisible == true else { return }
                self.quickPanel?.apply(state: self.quickPanelState())
            }
        }
    }

    private func rawQuickPanelServiceStatus() -> ServiceStatusKind {
        if installingUpdateVersion != nil { return .updating }
        if !settings.agentEnabled { return .off }
        if let missing = missingPermissions().first {
            return .needsPermission(name: localizedPermissionTitle(missing,
                                                                   language: settings.interfaceLanguage))
        }
        // Отказ на старте (модель не загрузилась, слушатель хоткея не встал)
        // раньше сюда не доносился: сборщик проваливался в «Служба
        // запускается · обычно 1–3 секунды» — навечно. Состояние .failed из
        // макета 8 с кнопкой «Открыть Настройки» существовало и было
        // недостижимо.
        if let startupFailure {
            return startupFailure.isMissingAudioInput ? .noMicrophone : .failed
        }
        if let verified = verifiedModelFiles, let total = totalModelFiles {
            return .verifying(done: verified, total: total)
        }
        if !isSpeechModelReady {
            if speechModelStartupProgressFraction != nil || downloadedModelFiles != nil {
                return .downloading(fraction: speechModelStartupProgressFraction,
                                    files: downloadedModelFiles,
                                    totalFiles: totalDownloadModelFiles)
            }
            return .starting
        }
        if !isReady { return .warmingUp }
        // Пауза перекрывает только «Готово»: пока служба запускается или
        // сломана, это важнее нарочно выключенного хоткея.
        if isDictationPaused { return .paused }
        return .ready(latencyMilliseconds: medianLatencyMilliseconds,
                      modelUpdate: speechModelUpdateStatus)
    }

    func quickPanelState() -> QuickPanelState {
        let language = settings.interfaceLanguage
        let rawPreference = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = availableAudioInputDevices()
        var microphoneName = audioInputDevice(matching: rawPreference, in: devices)?.name
            ?? localizedText("Системный по умолчанию", "System default", language: language)
        // Выбранное устройство отказало — строка обязана сказать, с чего
        // запись идёт на самом деле, а не повторять галочку из настроек.
        if let failed = audio.inputFallbackDeviceName {
            microphoneName = localizedText("\(failed) отказал — системный",
                                           "\(failed) failed — system default",
                                           language: language)
        }

        let calendar = Calendar.current
        let todayKey = dictationUsageDayKey(for: Date(), calendar: calendar)
        let today = settings.dailyDictationUsage.first(where: { $0.day == todayKey })
        let week = lastSevenCompletedDictationUsage(settings.dailyDictationUsage,
                                                    referenceDate: Date(),
                                                    calendar: calendar)
        let weekBars = dictationUsageBarFractions(
            week.days.map { $0.usage.characterCount } + [today?.characterCount ?? 0])

        return QuickPanelState(
            enabled: !isDictationPaused,
            language: settings.dictationLanguage,
            microphoneName: microphoneName,
            devices: devices,
            // Ровно столько, сколько выбрано в «Недавнее в панели меню-бара»
            // (1/5/10): панель — единственный оставшийся список меню-бара,
            // и настройка управляет именно ею.
            recent: visibleHistory,
            historyKeepingEnabled: settings.recentTranscriptLimit != .off,
            todayCharacters: today?.characterCount ?? 0,
            todayAudioSeconds: today?.audioSeconds ?? 0,
            weekBars: weekBars,
            interfaceLanguage: language
        ,
                               availableUpdateVersion: pendingUpdate?.version,
                               installedVersion: currentBundleVersion(),
                               isCheckingForUpdates: isCheckingForUpdates,
                               serviceStatus: quickPanelServiceStatus())
    }

    func quickPanelDidToggleEnabled(_ enabled: Bool) {
        isDictationPaused = !enabled
        if isDictationPaused {
            setMenuBarState(.paused)
            log("dictation paused from quick panel")
        } else {
            setMenuBarState(isReady ? .idle : .loading)
            log("dictation resumed from quick panel")
        }
        rebuildMenu()
    }

    func quickPanelDidSelectLanguage(_ language: DictationLanguage) {
        settings.dictationLanguage = language
        log("dictation language selected from quick panel: \(language.rawValue)")
        rebuildMenu()
    }

    func quickPanelDidSelectInputDevice(uid: String) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        settings.inputDevice = uid
        log("input device selected from quick panel: \(uid.isEmpty ? "system default" : uid)")
        restartAudioForInputDeviceChange()
        rebuildMenu()
    }

    func quickPanelDidCopyRecent(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func quickPanelDidPasteRecent(text: String) {
        _ = TextInserter.insert(pastedText(from: text, suffix: settings.pasteSuffix))
    }

    func quickPanelOpenSettings() {
        openControlPanelFromAgent(section: "settings")
    }

    func quickPanelOpenHistory() {
        openControlPanelFromAgent(section: "history")
    }

    // MARK: - Окно обновления

    func updateWindowDidChooseInstall(version: String) {
        guard let release = pendingUpdate, release.version == version else { return }
        startUpdate(for: release)
    }

    func updateWindowDidChooseLater(version: String) {
        guard let release = pendingUpdate, release.version == version else { return }
        closeUpdateWindow()
        pauseUpdateReminder(for: release)
    }

    func updateWindowDidChooseSkip(version: String) {
        closeUpdateWindow()
        var skipped = settings.skippedVersions
        if !skipped.contains(version) {
            skipped.append(version)
            settings.skippedVersions = skipped
            log("user skipped v\(version) from the update window")
        }
        pendingUpdate = nil
        rebuildMenu()
    }

    /// «Выйти» в поповере — та кнопка, которой люди действительно выходят:
    /// поповер открывается левым кликом, а меню с «Quit Dictor» — правым,
    /// куда мало кто заходит. Она же и не выходила толком: завершала процесс
    /// службы, оставляя открытое окно жить своей жизнью и не снимая launchd,
    /// так что «Выйти» выглядело как «пропала иконка».
    ///
    /// Теперь это тот же полный выход, что и в меню.
    func quickPanelQuit() {
        quitApplicationCompletely()
    }

    func quickPanelInstallUpdate() {
        guard let release = pendingUpdate else { return }
        presentUpdateWindow(for: release, currentVersion: currentBundleVersion())
    }

    /// Ручная проверка из панели. Обработчик для неё существовал с самого
    /// начала, но не был подключён ни к одному элементу интерфейса: узнать о
    /// новой версии можно было только дождавшись автоматической проверки.
    /// «Открыть Настройки» / «Запустить» / «Перезапустить службу» из шапки
    /// панели — те же действия, что и в подвале окна.
    func quickPanelStatusPrimaryAction() {
        switch quickPanelServiceStatus() {
        case .needsPermission:
            openControlPanelFromAgent(section: "settings")
        case .failed, .versionMismatch:
            // Перезапускать службу из неё самой нельзя: `bootout` ждал бы
            // смерти этого же процесса и повесил бы главный поток. Открываем
            // окно — там перезапуск делает отдельный процесс, и там же видно,
            // чем всё кончилось.
            openControlPanelFromAgent(section: "settings")
        default:
            break
        }
    }

    func quickPanelStatusSecondaryAction() {
        openControlPanelFromAgent(section: "settings")
    }

    func quickPanelCheckForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        refreshQuickPanel()
        manualUpdateCheckTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled, let self, !self.isTerminating else { return }
            self.manualUpdateCheckTask = nil
            self.isCheckingForUpdates = false
            self.recordUpdateCheck(release: try? outcome.get(), source: .manual)
            switch outcome {
            case .success(let release):
                self.handleFetchedRelease(release, source: .manual)
                self.refreshQuickPanel()
                if self.pendingUpdate == nil {
                    self.quickPanel?.flashUpToDate()
                }
            case .failure(let error):
                // Проверка не удалась — и сказать об этом обязательно. Раньше
                // здесь просто не оказывалось обновления, и панель отвечала
                // «у вас последняя версия»: человек, у которого не было сети,
                // получал бодрое подтверждение вместо правды.
                log("manual update check failed: \(error)")
                self.refreshQuickPanel()
                self.showUpdateCheckFailedAlert(error)
            }
        }
    }

    private func refreshQuickPanel() {
        guard let panel = quickPanel, panel.isVisible else { return }
        panel.apply(state: quickPanelState())
    }
}
