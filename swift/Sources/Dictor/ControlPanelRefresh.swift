import AppKit
import ServiceManagement

extension DictorControlPanelApp {
    func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(timeInterval: 0.75,
                                            target: self,
                                            selector: #selector(refreshTimerFired(_:)),
                                            userInfo: nil,
                                            repeats: true)
        refreshTimer?.tolerance = 0.15
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refresh()
    }

    func refresh(force: Bool = false) {
        guard let window else { return }
        // Выделение в тексте диктовки живёт ровно до следующей пересборки
        // вида, а таймер тикает каждые 0.75 с. Пока пользователь держит
        // выделение в активном окне, фон подождёт — иначе копировать кусок
        // невозможно. Ушёл в другое приложение — окно снова живое, иначе
        // забытое выделение заморозило бы счётчики и список навсегда.
        if !force, window.isKeyWindow,
           historyDetailTranscriptView?.hasSelection == true { return }
        _ = settings.refreshFromDisk()
        if onboardingFlow != nil {
            applyOnboarding()
            return
        }
        let fingerprint = renderFingerprint()
        guard force || fingerprint != lastRenderFingerprint else { return }
        lastRenderFingerprint = fingerprint
        // Вид пересобирается целиком, поэтому фокус и каретку поиска
        // приходится снимать до замены и возвращать после.
        let focusState = capturedSearchFocusState(in: window)
        let historyScroll = capturedHistoryScroll()
        // Главное окно по макету 6a: сайдбар + раздел, включая настройки.
        window.title = "Dictor"
        window.contentView = makeMainWindowView()
        restoreSearchFocus(focusState, in: window)
        restoreHistoryScroll(historyScroll, in: window)
    }

    /// Запрос и фильтр вместе определяют, какой список показан.
    private var historyScrollContext: String {
        "\(historyShowsPinnedOnly ? "pinned" : "all")|\(mainHistorySearch)"
    }

    private func capturedHistoryScroll() -> CGFloat? {
        guard mainSection == .history,
              mainHistoryScrollContext == historyScrollContext else { return nil }
        return mainHistoryListView?.verticalOffset
    }

    private func restoreHistoryScroll(_ offset: CGFloat?, in window: NSWindow) {
        mainHistoryScrollContext = historyScrollContext
        guard mainSection == .history, let offset, offset > 0,
              let list = mainHistoryListView else { return }
        // Таблица узнаёт свою высоту только после раскладки: до неё
        // прокручивать некуда.
        window.contentView?.layoutSubtreeIfNeeded()
        list.verticalOffset = offset
    }

    /// Было ли поле поиска в фокусе и где стояла каретка. Раньше фокус
    /// возвращался только при непустом запросе, поэтому стирание последнего
    /// символа выбрасывало из поля, а каретка всегда прыгала в конец.
    private struct SearchFocusState {
        let hadFocus: Bool
        let selectedRange: NSRange?
    }

    private func capturedSearchFocusState(in window: NSWindow) -> SearchFocusState {
        guard let field = mainHistorySearchField,
              let editor = field.currentEditor(),
              window.firstResponder === editor else {
            return SearchFocusState(hadFocus: false, selectedRange: nil)
        }
        return SearchFocusState(hadFocus: true, selectedRange: editor.selectedRange)
    }

    private func restoreSearchFocus(_ state: SearchFocusState, in window: NSWindow) {
        guard state.hadFocus, let field = mainHistorySearchField else { return }
        window.makeFirstResponder(field)
        guard let editor = field.currentEditor() else { return }
        let length = (field.stringValue as NSString).length
        if let range = state.selectedRange,
           range.location + range.length <= length {
            editor.selectedRange = range
        } else {
            editor.selectedRange = NSRange(location: length, length: 0)
        }
    }


    /// Состояние объекта входа, не старше пяти секунд.
    ///
    /// Вопрос к системе — межпроцессный вызов на 80–90 мс, а отпечаток окна
    /// считается каждые 0,75 с на главном потоке: окно каждую секунду
    /// замирало на десятую её часть ради значения, которое меняется раз в
    /// жизни. Снаружи — в Системных настройках — его всё ещё могут
    /// переключить, поэтому ответ не вечный; пять секунд опоздания здесь
    /// не видны.
    func loginItemStatus() -> SMAppService.Status {
        let now = ProcessInfo.processInfo.systemUptime
        if let reading = loginItemStatusReading, now - reading.readAt < 5 {
            return reading.status
        }
        let status = SMAppService.mainApp.status
        loginItemStatusReading = (status, now)
        return status
    }

    private func renderFingerprint() -> String {
        let state = AgentRuntimeStateStore.read()
        let permissions = Permission.allCases.map { Permissions.isGranted($0) ? "1" : "0" }.joined()
        let stateToken: String
        if serviceOperation != nil {
            stateToken = "operation"
        } else {
            let rawStatus = state?.status ?? "none"
            let isHealthyRuntimeState = ["ready", "recording", "transcribing"].contains(rawStatus)
            stateToken = [isHealthyRuntimeState ? "ready" : rawStatus,
                          isHealthyRuntimeState ? "" : state?.detail ?? "",
                          state?.downloadProgressFraction.map { String(format: "%.2f", $0) } ?? "",
                          String(state?.pid ?? 0),
                          state?.speechModelReady == true ? "1" : "0"].joined(separator: "|")
        }
        let historyEntries = settings.recentTranscriptEntries
        let newestHistory = historyEntries.first
        // Состояние службы — уже выдержавшее паузу (8c), а не сырое: иначе
        // созревшая пауза не доживёт до экрана. Отпечаток к этому моменту уже
        // не меняется, и refresh вышел бы на раннем `return`.
        let statusToken: String = "status:\(currentServiceStatus().fingerprint)"
        let parts: [String] = [statusToken,
                language.rawValue,
                "section:\(mainSection.rawValue):\(statsPeriod.rawValue)",
                "history:\(historyEntries.count):" +
                    "\(newestHistory?.createdAt?.timeIntervalSince1970 ?? 0)",
                "search:\(mainHistorySearch)",
                serviceOperation?.rawValue ?? "idle",
                updateStateFingerprint(),
                DictorAgentService.isAgentRunning() ? "running" : "stopped",
                stateToken,
                permissions,
                settings.configuredHotkey.name,
                settings.configuredEnterHotkey.name,
                settings.primaryCompletionBehavior.rawValue,
                settings.alternateCompletionEnabled ? "alternate-on" : "alternate-off",
                settings.triggerMode.rawValue,
                "suffix:\(settings.pasteSuffix.rawValue)",
                settings.recordingHUDRecordingColor.rawValue,
                settings.recordingHUDTranscribingColor.rawValue,
                settings.recordingHUDBackgroundStyle.rawValue,
                settings.recordingHUDSize.rawValue,
                // Настройки, которые меняются и извне окна — из меню-бара и
                // агентом. Без них окно не перерисовывалось, и клик по
                // устаревшему тумблеру перещёлкивал только что сделанное.
                String(settings.enterDelayMilliseconds),
                settings.playFeedbackSounds ? "sounds-on" : "sounds-off",
                settings.muteWhileRecording ? "mute-on" : "mute-off",
                "login-item:\(loginItemStatus().rawValue)",
                settings.checkForUpdates ? "updates-on" : "updates-off",
                settings.removeFillerWords ? "fillers-on" : "fillers-off",
                settings.builtInSpellingsEnabled ? "spellings-on" : "spellings-off",
                settings.latinTermRestorationsEnabled ? "latin-on" : "latin-off",
                settings.phoneticTermMatchingEnabled ? "phonetic-on" : "phonetic-off",
                "script:\(settings.dictationLanguage.rawValue)",
                "input:\(settings.inputDevice)",
                settings.floatingCapsuleEnabled ? "capsule-on" : "capsule-off",
                settings.showRecordingWaveform ? "hud-on" : "hud-off",
                settings.showInDock ? "dock-on" : "dock-off",
                settings.recordingHUDPlacement.rawValue,
                "limit:\(settings.recentTranscriptLimit.rawValue)",
                // Словарь и его файл синхронизации меняются и службой (скан
                // файла, конфликт останавливает синк): без них вкладка
                // показывает вчерашний список и «включённый» синк, которого
                // уже нет.
                "sync:\(settings.transcriptCorrectionsSyncFile)",
                "corr:\(settings.transcriptCorrections.count):" +
                    String(settings.transcriptCorrections
                        .map { "\($0.source)→\($0.replacement)" }
                        .joined(separator: "|").hashValue),
                settings.speechModelProfile.rawValue,
                "micFallback:\(state?.inputFallbackDeviceName ?? "")",
                permissionClickCount.description,
                "repair:\(permissionRepairNotes.count)",
                (AgentRuntimeStateStore.read()?.missingPermissions ?? []).sorted().joined(separator: ",")]
        return parts.joined(separator: "::")
    }

    private func updateStateFingerprint() -> String {
        switch updateState {
        case .notChecked:
            // Подпись этого состояния зависит от тумблера автопроверки —
            // без него в отпечатке строка не перерисуется при переключении.
            return "notChecked:\(settings.checkForUpdates)"
        case .checking:
            return "checking"
        case .upToDate(let version):
            return "current:\(version)"
        case .available(let release):
            return "available:\(release.version)"
        case .preparing(let version, let phase):
            return "preparing:\(version):\(phase)"
        case .failed(let message):
            return "failed:\(message)"
        }
    }
}
