// История диктовок на стороне агента и команды меню вокруг неё: копирование,
// выход, диагностика и отчёт о проблеме, а также текст диагностики.

import AppKit
import ServiceManagement

extension DictorApp {
    // MARK: - History

    func importDictationUsageFromLogIfNeeded() {
        guard !settings.didImportDictationUsageLog else { return }
        defer { settings.didImportDictationUsageLog = true }
        guard settings.dailyDictationUsage.isEmpty else { return }

        let url = Logger.shared.fileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return
        }
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let imported = importedDailyDictationUsage(from: text,
                                                   fileCreatedAt: createdAt,
                                                   calendar: .current)
        guard !imported.isEmpty else { return }
        settings.dailyDictationUsage = imported
        let total = imported.reduce(0) { $0 + $1.dictationCount }
        log("usage statistics imported from local log (\(total) dictations across \(imported.count) days)")
    }

    func recordDictationUsage(text: String,
                                      audioSeconds: Double,
                                      asrSeconds: Double,
                                      at date: Date = Date()) {
        settings.dailyDictationUsage = addingDictationUsageSample(
            to: settings.dailyDictationUsage,
            at: date,
            characterCount: text.count,
            audioSeconds: audioSeconds,
            asrSeconds: asrSeconds,
            calendar: .current
        )
    }

    func addToHistory(_ text: String,
                              transcriptionDurationSeconds: Double?,
                              asrTiming: ASRTimingBreakdown? = nil,
                              rebuildMenuAfterPersisting: Bool = true) {
        guard settings.recentTranscriptLimit != .off else { return }
        let entry = TranscriptHistoryEntry(
            text: text,
            transcriptionDurationSeconds: transcriptionDurationSeconds,
            asrTiming: asrTiming,
            createdAt: Date()
        )
        // Архив перечитывается с диска прямо перед записью: пока шла запись и
        // распознавание, секундный наблюдатель настроек стоит (guard
        // !isRecording, !isBusy), и копия агента могла устареть — окно могло
        // успеть стереть историю или удалить запись.
        settings.refreshFromDisk()
        let onDisk = settings.recentTranscriptEntries
        let next = limitedTranscriptHistoryArchive([entry] + onDisk,
                                                   pinned: Set(settings.pinnedTranscripts))
        guard next != onDisk else { return }
        persistHistoryArchive(next)
        if rebuildMenuAfterPersisting {
            rebuildMenu()
        }
    }

    /// Единственная точка, где агент пишет архив истории. Обновляет и кэш, и
    /// отпечаток байтов — иначе наблюдатель настроек примет собственную запись
    /// за внешнюю и перечитает архив впустую.
    private func persistHistoryArchive(_ entries: [TranscriptHistoryEntry]) {
        history = entries
        settings.recentTranscriptEntries = entries
        lastSeenHistoryArchiveData = settings.recentTranscriptEntriesStoredData
    }

    @objc func historyClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        copyHistoryText(s)
    }

    private func copyHistoryText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("history copied to clipboard (\(text.count) chars)")
    }

    @objc func quitClicked(_ sender: NSMenuItem) {
        quitApplicationCompletely()
    }

    /// Единственный выход из Dictor, куда бы на него ни нажали: «Выйти» в
    /// поповере, «Quit Dictor» в служебном меню, ⌘Q в окне. Все три обязаны
    /// делать одно и то же, иначе «выйти» означает разное в зависимости от
    /// того, откуда вышли, — а человек видит одно приложение.
    func quitApplicationCompletely() {
        guard confirmStopDictation() else { return }
        // Окно — отдельный процесс, и раньше выход его не касался: иконка из
        // меню-бара исчезала, а приложение оставалось на экране и в Dock.
        DistributedNotificationCenter.default().postNotificationName(
            CONTROL_PANEL_QUIT_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        // Снять службу обязательно: у тех, кто ставил прошлую версию, в plist
        // остался KeepAlive: true, и без bootout launchd поднял бы агента
        // обратно — выход выглядел бы как «приложение не закрывается».
        log("quit: stopping the service and closing the window")
        DictorAgentService.stopForQuit()
        NSApp.terminate(self)
    }

    private func confirmStopDictation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop Dictor?"
        alert.informativeText = "The \(hotkey.hotkey.name) dictation shortcut will stop until you open Dictor again. Use Close to hide windows while keeping dictation running."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop Dictation")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc func cancelRecordingClicked(_ sender: NSMenuItem) {
        cancelActiveRecording(reason: "menu")
    }

    @objc func copyDiagnosticsClicked(_ sender: NSMenuItem) {
        copyDiagnosticsToClipboard()
    }

    private func copyDiagnosticsToClipboard() {
        let text = diagnosticsText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("diagnostics copied to clipboard")
    }

    @objc func saveDiagnosticsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics"
        panel.message = "Save a privacy-safe diagnostics report for a GitHub issue."
        panel.prompt = "Save"
        panel.nameFieldStringValue = "Dictor Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            log("diagnostics saved to \(privacySafeLogPath(url))")
        } catch {
            showDiagnosticsSaveError(error)
        }
    }

    private func showDiagnosticsSaveError(_ error: Error) {
        log("diagnostics save failed: \(error.localizedDescription)")
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Diagnostics couldn't be saved"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func reportProblemClicked(_ sender: NSMenuItem) {
        showAppForModal()
        ProblemReport.share(diagnostics: diagnosticsText(),
                            anchor: statusItem.button,
                            language: settings.interfaceLanguage)
    }

    private func diagnosticsText() -> String {
        let generated = ISO8601DateFormatter().string(from: Date())
        let bundlePath = Bundle.main.bundlePath
        let installKind: String
        if bundlePath == "/Applications/Dictor.app" {
            installKind = "Applications app"
        } else if bundlePath == "/tmp/Dictor-dev.app" {
            installKind = "signed dev app"
        } else {
            installKind = "other"
        }

        let devices = availableAudioInputDevices()
        let savedInput = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedInput = audioInputDevice(matching: savedInput, in: devices)
        let inputLabel: String
        if savedInput.isEmpty || isDefaultAggregateAudioInputPreference(savedInput) {
            inputLabel = "System default"
        } else if let selectedInput {
            inputLabel = "\(selectedInput.name) (available)"
        } else {
            inputLabel = "Saved device unavailable"
        }

        let startupText: String
        if let failure = startupFailure {
            startupText = "\(failure.statusTitle): \(failure.detail)"
        } else if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            startupText = startupStatusTitle
        } else {
            startupText = isCoreRuntimeReady ? "Runtime ready" : "Runtime not ready"
        }

        let permissionLines = Permission.allCases
            .map { "\($0.rawValue): \(Permissions.isGranted($0) ? "granted" : "missing")" }
        let availableInputLines = devices.isEmpty
            ? ["Available inputs: none reported"]
            : ["Available inputs (\(devices.count)):"] + devices.map { "  \($0.name)" }
        let pendingUpdateText = pendingUpdate.map { "v\($0.version)" } ?? "none"
        let lastUpdateCheckText = updateCheckDiagnosticText(
            checkedAt: settings.lastUpdateCheckAt,
            source: settings.lastUpdateCheckSource,
            result: settings.lastUpdateCheckResult,
            releaseVersion: settings.lastUpdateCheckVersion
        )
        let updateReminderText: String
        if let version = reminderPausedUpdateVersion,
           let until = reminderPausedUntil,
           Date() < until {
            updateReminderText = "v\(version) until \(ISO8601DateFormatter().string(from: until))"
        } else {
            updateReminderText = "none"
        }
        let memoryLines: [String]
        if let memory = currentAppMemoryUsage() {
            memoryLines = [
                "Resident: \(formattedByteCount(memory.residentBytes))",
                "Physical footprint: \(formattedByteCount(memory.physicalFootprintBytes))",
            ]
        } else {
            memoryLines = []
        }
        let launchAtLoginText: String
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginText = "enabled"
        case .requiresApproval:
            launchAtLoginText = "requires approval"
        case .notRegistered:
            launchAtLoginText = "disabled"
        case .notFound:
            launchAtLoginText = "not found"
        @unknown default:
            launchAtLoginText = "unknown"
        }

        let speechModelProfile = settings.speechModelProfile
        let languageSettingText = DICTATION_LANGUAGE_DISPLAY[settings.dictationLanguage]
            ?? settings.dictationLanguage.rawValue

        let logLines: [String]
        do {
            logLines = try recentDiagnosticLogLines()
        } catch {
            logLines = ["Unavailable: \(error.localizedDescription)"]
        }

        let snapshot = DiagnosticsReportSnapshot(
            generated: generated,
            appVersion: currentBundleVersion(),
            appBuild: currentBundleBuild(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: privacySafeBundlePath(bundlePath),
            installKind: installKind,
            status: menuStatusTitle(),
            startup: startupText,
            speechModelReady: isSpeechModelReady,
            coreRuntimeReady: isCoreRuntimeReady,
            readyForDictation: isReady,
            recordingActive: isRecording,
            transcribing: isBusy,
            memoryLines: memoryLines,
            permissionLines: permissionLines,
            settingLines: [
                "Hotkey: \(hotkey.hotkey.name)",
                "Trigger mode: \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)",
                "Speech model: \(speechModelProfile.displayName)",
                "Running on the previous model: \(speechModelUpdateStatus.map { "\($0.previousModelName), update \($0.phase.rawValue)" } ?? "no")",
                "Language: \(languageSettingText)",
                "Paste behavior: \(PASTE_SUFFIX_DISPLAY[settings.pasteSuffix] ?? settings.pasteSuffix.rawValue)",
                "Smart insertion: \(settings.smartInsertionEnabled)",
                "Remove filler words: \(settings.removeFillerWords)",
                "Recent transcripts: \(RECENT_TRANSCRIPT_LIMIT_DISPLAY[settings.recentTranscriptLimit] ?? settings.recentTranscriptLimit.rawValue) (\(visibleHistory.count) visible, \(history.count) archived)",
                "Text corrections: \(settings.transcriptCorrections.count) configured",
                "Text correction sync: \(settings.transcriptCorrectionsSyncFile.isEmpty ? "off" : "configured")",
                "Text insertion: \(TextInserter.defaultStrategyDescription)",
                "Recording waveform: \(settings.showRecordingWaveform)",
                "Mute while recording: \(settings.muteWhileRecording)",
                "Feedback sounds: \(settings.playFeedbackSounds)",
                "Show in Dock: \(settings.showInDock)",
                "Launch at Login: \(launchAtLoginText)",
                "Capsule fonts: \(SD.fontFallbackNotes.isEmpty ? "as designed" : SD.fontFallbackNotes.joined(separator: " | "))",
            ],
            updateLines: [
                "Update notifications: \(settings.checkForUpdates)",
                "Last update check: \(lastUpdateCheckText)",
                "Manual update check active: \(isCheckingForUpdates)",
                "Pending update: \(pendingUpdateText)",
                "Reminder paused: \(updateReminderText)",
                "Update helper log: \((UPDATE_HELPER_LOG_PATH as NSString).abbreviatingWithTildeInPath)",
            ],
            microphoneLines: ["Selected: \(inputLabel)"] + availableInputLines,
            logPath: (Logger.shared.fileURL.path as NSString).abbreviatingWithTildeInPath,
            recentLogLines: logLines,
            crashReportLines: crashReportSummaryLines(
                fileNames: dictorCrashReportURLs().map(\.lastPathComponent))
        )
        return diagnosticsReportText(from: snapshot)
    }
}
