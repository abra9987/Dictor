// Меню иконки в строке меню: состояние службы для окна и поповера, пункты
// меню, политика активации (Dock), сброс кэша модели и «О программе».

import AppKit

extension DictorApp {
    // MARK: - Menu

    func rebuildMenu() {
        publishAgentState()
        if quickPanel?.isVisible == true {
            quickPanel?.apply(state: quickPanelState())
        }
    }

    func publishAgentState(status explicitStatus: String? = nil,
                                   detail explicitDetail: String? = nil) {
        let statusDetail = agentStateStatusDetail()
        let missing = missingPermissions().map(\.rawValue)
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: explicitStatus ?? statusDetail.status,
                              detail: explicitDetail ?? statusDetail.detail,
                              updatedAt: Date().timeIntervalSince1970,
                              pid: getpid(),
                              isReady: isReady,
                              isRecording: isRecording,
                              isTranscribing: isBusy,
                              speechModelReady: isSpeechModelReady,
                              missingPermissions: missing,
                              hotkeyName: hotkey.hotkey.name,
                              triggerMode: settings.triggerMode.rawValue,
                              downloadProgressFraction: speechModelStartupProgressFraction,
                              verifiedModelFiles: verifiedModelFiles,
                              totalModelFiles: totalModelFiles,
                              downloadedModelFiles: downloadedModelFiles,
                              totalDownloadModelFiles: totalDownloadModelFiles,
                              medianLatencyMilliseconds: medianLatencyMilliseconds,
                              isUpdating: installingUpdateVersion != nil,
                              appVersion: currentBundleVersion(),
                              inputFallbackDeviceName: audio.inputFallbackDeviceName,
                              previousSpeechModelName: speechModelUpdateStatus?.previousModelName,
                              speechModelUpdatePhase: speechModelUpdateStatus?.phase.rawValue,
                              speechModelUpdateFraction: speechModelUpdateStatus?.fraction,
                              failureReason: startupFailure?.isMissingAudioInput == true
                                  ? AGENT_FAILURE_REASON_NO_MICROPHONE
                                  : nil)
        )
    }

    /// Сколько файлов модели уже скачано. Байты FluidAudio не отдаёт — только
    /// число файлов и долю, поэтому «412 МБ из 600 МБ» из макета показать
    /// нечем, а придумывать объём нельзя.
    var downloadedModelFiles: Int? {
        guard case .downloading(let completed, _)? = lastDownloadPhase else { return nil }
        return completed
    }

    var totalDownloadModelFiles: Int? {
        guard case .downloading(_, let total)? = lastDownloadPhase else { return nil }
        return total
    }

    /// Медиана времени распознавания последних тридцати диктовок. Это же число
    /// показывает плитка в «Продвинутых» — считаем один раз здесь.
    var medianLatencyMilliseconds: Int? {
        guard let seconds = medianRecognitionSeconds(entries: settings.recentTranscriptEntries),
              seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    private func agentStateStatusDetail() -> (status: String, detail: String) {
        if isRecording {
            return ("recording", "Recording dictation.")
        }
        if isBusy {
            return ("transcribing", "Transcribing your last recording.")
        }
        // Пауза раньше жила только в памяти службы: окно и панель показывали
        // «Готово» с зелёной точкой, пока хоткей нарочно молчал (аудит №11).
        if isDictationPaused {
            return ("paused", "Dictation is paused from the quick panel.")
        }
        if isReady {
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            return ("ready", "\(verb) \(hotkey.hotkey.name) to dictate.")
        }
        if let failure = startupFailure {
            return ("error", failure.detail)
        }
        let missing = missingPermissions()
        if !missing.isEmpty {
            return ("needs_permissions", "Grant \(missing.map(\.rawValue).joined(separator: ", ")) to finish setup.")
        }
        if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            return ("starting", startupStatusTitle)
        }
        if isCoreRuntimeReady {
            return ("starting", "Starting hotkey listener.")
        }
        return ("starting", "Starting dictation service.")
    }

    /// Язык служебного меню. Само меню — только действия: все настройки
    /// живут в окне, и меню больше не обязано быть их вторым, англоязычным
    /// адресом. Протокольные строки (startupStatusTitle, failure.*,
    /// diagnosticsText) не переводятся — окно парсит английские префиксы.
    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: settings.interfaceLanguage)
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status row.
        let statusTitle = menuStatusTitle()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if let failure = startupFailure {
            status.toolTip = failure.detail
        }
        menu.addItem(status)
        if shouldShowSpeechModelProgressRow {
            menu.addItem(buildSpeechModelProgressItem())
        }

        menu.addItem(.separator())

        if isRecording {
            let cancel = NSMenuItem(title: t("Отменить запись", "Cancel Recording"),
                                    action: #selector(cancelRecordingClicked(_:)),
                                    keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(.separator())
        }

        if let failure = startupFailure {
            let retry = NSMenuItem(title: failure.retryTitle,
                                   action: #selector(retryStartupClicked(_:)),
                                   keyEquivalent: "")
            retry.target = self
            retry.toolTip = failure.detail
            retry.isEnabled = startupTask == nil
            menu.addItem(retry)
            menu.addItem(.separator())
        }

        // Update submenu (lazy — only present when an update exists).
        if let release = pendingUpdate, !settings.skippedVersions.contains(release.version) {
            menu.addItem(buildUpdateItem(for: release))
            menu.addItem(.separator())
        }

        // Permission rows — visible only while something is missing.
        var addedPermRow = false
        for p in Permission.allCases where !Permissions.isGranted(p) {
            menu.addItem(buildPermissionItem(p))
            addedPermRow = true
        }
        if addedPermRow { menu.addItem(.separator()) }

        // History: keep one-click access to the last transcript; the
        // full list lives in the quick panel and the History window.
        if let newest = visibleHistory.first {
            let inline = NSMenuItem(title: t("Копировать последнюю диктовку",
                                             "Copy Last Transcript"),
                                    action: #selector(historyClicked(_:)),
                                    keyEquivalent: "")
            inline.target = self
            inline.representedObject = newest.text
            inline.toolTip = newest.text
            menu.addItem(inline)
            menu.addItem(.separator())
        }

        let history = NSMenuItem(title: t("История…", "History…"),
                                 action: #selector(openHistoryFromMenu(_:)),
                                 keyEquivalent: "")
        history.target = self
        menu.addItem(history)

        let settingsItem = NSMenuItem(title: t("Настройки…", "Settings…"),
                                      action: #selector(openSettingsFromMenu(_:)),
                                      keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(buildSupportItem())
        menu.addItem(.separator())

        // Route through our own selector rather than `NSApp.terminate(_:)`
        // directly. macOS auto-decorates items whose action is the
        // system terminate: selector with a destructive-action glyph
        // (visible in the state-column slot), which is the *only* item
        // in the menu that gets such an indicator — every other row
        // sits flush against the left edge. The wrapper produces the
        // identical behaviour with no auto-glyph.
        let quit = NSMenuItem(title: t("Выйти из Dictor", "Quit Dictor"),
                              action: #selector(quitClicked(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    @objc private func openHistoryFromMenu(_ sender: NSMenuItem) {
        openControlPanelFromAgent(section: "history")
    }

    @objc private func openSettingsFromMenu(_ sender: NSMenuItem) {
        openControlPanelFromAgent(section: "settings")
    }

    private func buildSupportItem() -> NSMenuItem {
        let parent = NSMenuItem(title: t("Поддержка", "Support"),
                                action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let setup = NSMenuItem(title: t("Чек-лист настройки…", "Setup Checklist…"),
                               action: #selector(showSetupChecklistClicked(_:)),
                               keyEquivalent: "")
        setup.target = self
        sub.addItem(setup)

        sub.addItem(.separator())

        let about = NSMenuItem(title: t("О Dictor", "About Dictor"),
                               action: #selector(showAboutClicked(_:)),
                               keyEquivalent: "")
        about.target = self
        sub.addItem(about)

        sub.addItem(.separator())

        let diagnostics = NSMenuItem(title: t("Копировать диагностику", "Copy Diagnostics"),
                                     action: #selector(copyDiagnosticsClicked(_:)),
                                     keyEquivalent: "")
        diagnostics.target = self
        sub.addItem(diagnostics)

        let saveDiagnostics = NSMenuItem(title: t("Сохранить диагностику…", "Save Diagnostics…"),
                                         action: #selector(saveDiagnosticsClicked(_:)),
                                         keyEquivalent: "")
        saveDiagnostics.target = self
        sub.addItem(saveDiagnostics)

        let reportProblem = NSMenuItem(title: t("Сообщить о проблеме…", "Report a Problem…"),
                                       action: #selector(reportProblemClicked(_:)),
                                       keyEquivalent: "")
        reportProblem.target = self
        sub.addItem(reportProblem)

        let resetModel = NSMenuItem(title: isResettingSpeechModelCache
                                        ? t("Сбрасываю кэш модели речи…", "Resetting Speech Model Cache…")
                                        : t("Сбросить кэш модели речи…", "Reset Speech Model Cache…"),
                                    action: #selector(resetSpeechModelCacheClicked(_:)),
                                    keyEquivalent: "")
        resetModel.target = self
        resetModel.isEnabled = !isRecording
            && !isBusy
            && !isTerminating
            && startupTask == nil
            && !isResettingSpeechModelCache
            && !isSwitchingSpeechModel
        resetModel.toolTip = t("Удалить кэш модели речи и скачать свежую проверенную копию.",
                               "Delete the speech model cache and download a fresh verified copy.")
        sub.addItem(resetModel)

        parent.submenu = sub
        return parent
    }

    private var shouldShowSpeechModelProgressRow: Bool {
        startupFailure == nil
            && ((startupTask != nil && !isSpeechModelReady)
                || isSwitchingSpeechModel
                || isResettingSpeechModelCache)
    }

    private func buildSpeechModelProgressItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let progress = NSProgressIndicator(frame: NSRect(x: 14, y: 7, width: 232, height: 10))
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.usesThreadedAnimation = true
        progress.toolTip = startupStatusTitle

        if let speechModelStartupProgressFraction {
            progress.isIndeterminate = false
            progress.doubleValue = speechModelStartupProgressFraction
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }

        view.addSubview(progress)
        item.view = view
        return item
    }

    func menuStatusTitle() -> String {
        if isRecording {
            return t("Идёт запись…", "Recording…")
        }
        if isBusy {
            return t("Распознаю…", "Transcribing…")
        }
        if isDictationPaused {
            return t("Диктовка на паузе", "Dictation is paused")
        }
        if isReady {
            let hk = hotkey.hotkey.name
            return settings.triggerMode == .hold
                ? t("Удерживайте \(hk) для диктовки", "Hold \(hk) to dictate")
                : t("Нажмите \(hk) для диктовки", "Press \(hk) to dictate")
        }
        // failure.statusTitle и startupStatusTitle — протокольные строки,
        // их парсит окно; в меню они показываются как есть, по-английски.
        if let failure = startupFailure {
            return failure.statusTitle
        }
        if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            return startupStatusTitle
        }
        if !missingPermissions().isEmpty {
            return t("Выдайте разрешения, чтобы закончить настройку",
                     "Grant permissions to finish setup")
        }
        if isCoreRuntimeReady {
            return t("Запускаю слушатель хоткея…", "Starting hotkey listener…")
        }
        return t("Dictor не готов", "Dictor is not ready")
    }

    @objc private func retryStartupClicked(_ sender: NSMenuItem) {
        startStartup(reason: "manual retry")
    }

    func showAppForModal() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Значок в Dock принадлежит службе — и только пока окно не запущено:
    /// окно всегда `.regular`, и два значка одного бандла выглядят как два
    /// приложения. Клик по значку открывает окно через
    /// `applicationShouldHandleReopen`, окно пишет свой pid, и следующий тик
    /// наблюдателя прячет значок службы.
    func refreshActivationPolicy() {
        let desired = dockActivationPolicy(
            showInDock: settings.showInDock,
            panelRunning: DictorControlPanelRegistry.isPanelRunning())
        guard NSApp.activationPolicy() != desired else { return }
        if desired == .regular {
            // Приложению в `.regular` нужна строка меню — иначе рядом с
            // логотипом Apple остаётся пустое место.
            NSApp.mainMenu = agentMainMenu()
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        }
    }

    private func agentMainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let about = NSMenuItem(title: t("О Dictor", "About Dictor"),
                               action: #selector(showAboutClicked(_:)),
                               keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: t("Выйти из Dictor", "Quit Dictor"),
                              action: #selector(quitClicked(_:)),
                              keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        return main
    }

    @objc private func resetSpeechModelCacheClicked(_ sender: NSMenuItem) {
        guard !isRecording,
              !isBusy,
              startupTask == nil,
              !isResettingSpeechModelCache,
              !isSwitchingSpeechModel,
              !isTerminating else { return }

        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Speech Model Cache?"
        let profile = settings.speechModelProfile
        alert.informativeText = profile.cacheResetDetail
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isResettingSpeechModelCache = true
        // Фоновая загрузка пишет в тот самый каталог, который сейчас удалят.
        cancelSpeechModelUpdate()
        prepareForStartupAttempt()
        startupStatusTitle = "Resetting speech model cache…"
        log("ASR: \(profile.shortName) cache reset started")
        rebuildMenu()

        Task { @MainActor in
            await asr.unload()
            let cacheDir = speechModelCacheDirectory(for: profile)
            do {
                let didRemoveCache = try await removeSpeechModelCacheDirectory(cacheDir)
                if didRemoveCache {
                    log("ASR: removed \(profile.shortName) cache \(privacySafeLogPath(cacheDir))")
                } else {
                    log("ASR: \(profile.shortName) cache reset requested; cache was already absent")
                }
                isResettingSpeechModelCache = false
                startStartup(reason: "speech model cache reset")
            } catch {
                isResettingSpeechModelCache = false
                log("ASR: speech model cache reset failed: \(error)")
                showSpeechModelCacheResetError(error)
                startStartup(reason: "speech model cache reset recovery")
            }
        }
    }

    private func showSpeechModelCacheResetError(_ error: Error) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Speech model cache couldn't be reset"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - About dialog

    @objc private func showAboutClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Dictor \(currentBundleVersion())"
        alert.informativeText = """
            Lightweight push-to-talk dictation for Apple Silicon Macs.

            Hotkey:  \(hotkey.hotkey.name)
            Mode:    \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)
            Model:   \(settings.speechModelProfile.aboutModelText)

            Local-only dictation. No cloud transcription, no telemetry.
            Network: model download, optional update check and install.
            Permissions: microphone audio, paste-at-cursor, push-to-talk hotkey.

            Open source, based on Dictor by Richard Courtman.
            \(UPDATE_CHANNEL_PAGE.host ?? "") · MIT licensed
            """
        // Use our app icon instead of NSAlert's default exclamation
        // mark. .icns lives in Contents/Resources/Dictor.icns;
        // NSImage(named:) on Bundle.main resolves it by filename
        // sans extension.
        if let icon = NSImage(named: "Dictor") {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Download Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UPDATE_CHANNEL_PAGE)
        }
    }
}
