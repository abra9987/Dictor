import AppKit
import Foundation
import FluidAudio
import CoreGraphics
import QuartzCore

// MARK: - App
//
// Single class that owns the lifecycle and the AppKit menu-bar UI.
// All UI state lives here; subsystems (HotkeyListener, AudioCapture,
// TranscriptionWorker, UpdateCheck, …) hold their own state but
// call back into `DictorApp` for anything that touches the menu.

enum DictationReleaseShortcut: Equatable {
    case standard
    case alternate
}

func shouldPressEnterAfterDictation(
    shortcut: DictationReleaseShortcut,
    primaryBehavior: DictationCompletionBehavior
) -> Bool {
    let behavior = shortcut == .standard ? primaryBehavior : primaryBehavior.opposite
    return behavior.pressesEnter
}

func formattedUsageInteger(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
}

@MainActor
final class DictorApp: NSObject, NSApplicationDelegate, NSWindowDelegate, UpdateWindowDelegate {
    struct CachedInsertionTarget {
        let target: FocusedInsertionTargetFrame
        let windowFrame: NSRect?
        let cachedAt: TimeInterval
    }

    struct LastExternalClick {
        let applicationPID: pid_t
        let point: NSPoint
        let capturedAt: TimeInterval
    }

    var statusItem: NSStatusItem!
    var templateImage: NSImage?
    var recordingImage: NSImage?
    var errorImage: NSImage?
    var recordingStartedAtUptime: TimeInterval?
    var quickPanel: DictorQuickPanel?
    /// Пауза перед показом коротких состояний службы (макет 8c) — та же, что
    /// в подвале окна, чтобы шапка панели и подвал не расходились словами.
    let quickPanelStatusHold = ServiceStatusHold()
    var quickPanelStatusHoldTimer: Timer?
    /// Плавающая капсула (макет 6c). Живёт, только пока включена в настройках.
    let floatingCapsule = FloatingCapsuleController()
    var isDictationPaused = false
    var menuBarGlyphPhase: CGFloat = 0
    var lastMenuBarGlyphUpdateAt: TimeInterval = 0
    var insertedHUDWorkItem: DispatchWorkItem?
    let audio = AudioCapture()
    let hotkey = HotkeyListener()
    let asr = TranscriptionWorker()
    let insertionTargetTracker = FocusedInsertionTargetTracker()
    let settings = Settings.shared

    var isRecording = false
    var isBusy = false
    var isReady = false
    var isCoreRuntimeReady = false
    var isSpeechModelReady = false
    var isTerminating = false
    var isResettingSpeechModelCache = false
    var isSwitchingSpeechModel = false
    /// Служба распознаёт на модели прошлой версии: текущей на диске ещё нет,
    /// она скачивается в фоне (см. SpeechModelUpdate.swift).
    var isRunningOnPreviousSpeechModel = false
    var speechModelUpdateTask: Task<Void, Never>?
    /// Номер запуска фоновой загрузки. Отменённая задача доживает до своего
    /// завершения и не должна тронуть состояние, которое уже принадлежит
    /// следующей.
    var speechModelUpdateGeneration = 0
    var speechModelUpdatePhase: SpeechModelUpdateStatus.Phase?
    var speechModelUpdateFraction: Double?
    var speechModelUpdateFailedAttempts = 0
    var speechModelUpdateRetryWorkItem: DispatchWorkItem?
    /// Когда закончилась последняя диктовка. Переход на скачанную модель
    /// ждёт тишины, и отсчитывается она отсюда.
    var lastDictationActivityUptime = ProcessInfo.processInfo.systemUptime
    var fallbackSpeechModelProfileAfterStartupFailure: SpeechModelProfile?
    var startupTask: Task<Void, Never>?
    var updateCheckLoopTask: Task<Void, Never>?
    var manualUpdateCheckTask: Task<Void, Never>?
    var startupStatusTitle = "Loading speech model…"
    var speechModelStartupProgressFraction: Double?
    /// «Проверено N файлов модели из M» — то, чем занята служба первые
    /// секунды после запуска. Раньше это время выглядело как «Остановлена».
    var verifiedModelFiles: Int?
    var totalModelFiles: Int?
    var lastDownloadPhase: DownloadPhase?
    var startupFailure: StartupFailure?
    var didTouchAudioEngine = false
    var permissionReadinessTimer: Timer?
    var lastPermissionReadinessMissingKey: String?
    /// Recording-time system-audio mute state machine. Main-actor
    /// only; transitions are driven by muteIfNeededForRecording /
    /// unmuteIfWeMuted and the SystemAudio.*Async completions. The
    /// pure decision logic lives in systemAudioMuteProbeDecision /
    /// systemAudioMuteCommandDecision / systemAudioUnmuteRequestDecision.
    var systemAudioMutePhase: SystemAudioMutePhase = .idle
    /// Set when the recording ends while the probe or mute command is
    /// still in flight; the in-flight completion honours it.
    var systemAudioUnmuteRequested = false
    var maxDurationWorkItem: DispatchWorkItem?
    var audioIdleStopWorkItem: DispatchWorkItem?
    var isRestartingAudioInput = false
    var pendingAudioRouteRefresh = false
    var audioConfigurationChangeSuppressedUntil: TimeInterval?
    var workspacePowerObservers: [NSObjectProtocol] = []
    var audioInputDeviceWatcher: AudioInputDeviceWatcher?
    var hotkeyPausedForExternalCapture = false
    var hotkeyCaptureFailsafeTimer: Timer?
    var shouldResumeRuntimeAfterWake = false
    var didLogDeferredWakeRecovery = false
    var setupChecklistWindow: NSWindow?
    var setupChecklistRefreshTimer: Timer?
    var hotkeyTestSucceeded = false
    var recordingLevelTimer: Timer?
    var recordingVisualLevel: Float = 0
    var recordingHUDPhase: CGFloat = 0
    var lastRecordingLevelSequence: UInt64 = 0
    var staleRecordingLevelTicks = 0
    var recordingHUDPanel: NSPanel?
    var recordingHUDView: RecordingHUDView?
    var recordingHUDTranscribingStartedAt: TimeInterval?
    var recordingHUDAnimationToken = 0
    var recordingHUDDisplayLink: CADisplayLink?
    var lastRecordingHUDMotionAt: TimeInterval?
    var lastRecordingHUDTargetRefreshAt: TimeInterval?
    var recordingHUDRevealStartedAt: TimeInterval?
    var recordingHUDRevealFrom: CGFloat = 0
    var recordingHUDRevealTo: CGFloat = 1
    var recordingHUDRevealDuration: TimeInterval = RECORDING_HUD_ANIMATE_IN_SECONDS
    var recordingHUDRevealCompletion: (() -> Void)?
    var recordingHUDRetargetWorkItem: DispatchWorkItem?
    var recordingHUDInsertionTargetFrame: NSRect?
    var recordingHUDInsertionTargetVisualFrame: NSRect?
    var recordingHUDFallbackWindowFrame: NSRect?
    var recordingHUDTargetStabilizer = RecordingHUDTargetStabilizer()
    var recordingHUDTargetQueryInFlight = false
    var recordingHUDTargetSessionToken = 0
    var recordingHUDWaitingForInitialTarget = false
    var insertionTargetCache: [pid_t: CachedInsertionTarget] = [:]
    var globalMouseDownMonitor: Any?
    var lastExternalClick: LastExternalClick?
    var errorFlashWorkItem: DispatchWorkItem?
    var systemAudioMuteWatchdog: Process?

    /// Local transcript archive, newest first. UI applies the user's visible limit.
    var history: [TranscriptHistoryEntry] = []

    var visibleHistory: [TranscriptHistoryEntry] {
        limitedRecentTranscriptEntries(history, limit: settings.recentTranscriptLimit)
    }

    /// In-session click counter per permission. Click #2 onwards
    /// resets the matching TCC entry before re-requesting — belt
    /// and braces for stuck DENIED entries macOS occasionally caches.
    var permClickCount: [Permission: Int] = [:]

    /// Latest release detected by the periodic check. nil = no update,
    /// or user has skipped it.
    var pendingUpdate: DictorRelease?
    var isCheckingForUpdates = false
    /// Установка, запущенная из «Update now…». Держим задачу, чтобы второй
    /// клик не начал вторую загрузку, и версию — чтобы меню показывало, что
    /// идёт работа, а не молчало на десятках мегабайт скачивания.
    var updateInstallTask: Task<Void, Never>?
    var installingUpdateVersion: String?
    var updateAvailableWindow: UpdateAvailableWindow?
    var reminderPausedUpdateVersion: String?
    var reminderPausedUntil: Date?

    var correctionSyncTimer: Timer?
    /// Хоткеи агент раньше читал только при старте, поэтому их смена
    /// требовала перезапуска службы. Таймер подхватывает их на лету.
    var settingsWatchTimer: Timer?
    /// Что служба видела в настройках в прошлый тик. Нужны, чтобы отличать
    /// «человек поменял в окне» от «ничего не изменилось»: без сравнения
    /// перезапуск аудиовхода случался бы раз в секунду.
    var lastSeenInputDevice: String?
    var lastSeenCorrections: [TranscriptCorrection]?
    var lastSeenCorrectionSyncFilePath: String?
    /// Байты архива истории, какими агент видел их в последний раз. Обновляется
    /// и собственными записями (persistHistoryArchive), и наблюдателем — чтобы
    /// «изменилось снаружи» не срабатывало на самих себя.
    var lastSeenHistoryArchiveData: Data?
    var lastAppliedHotkeySignature = ""
    var correctionSyncFileFingerprint: CorrectionSyncFileFingerprint?
    var correctionSyncBaselineCorrections: [TranscriptCorrection] = []
    var isApplyingCorrectionSyncFile = false
    /// Serial queue for the periodic sync-file scan (validate + hash
    /// + read). The UI recommends putting the sync file in iCloud
    /// Drive, where open(2) on a dataless file can block for seconds
    /// while the content downloads — far too long for the main
    /// thread, which also services the session-wide hotkey event tap.
    /// `correctionSyncScanInFlight` (main-actor) guarantees scans
    /// never overlap; results hop back to the main actor, where the
    /// existing merge/apply logic runs unchanged.
    static let correctionSyncScanQueue = DispatchQueue(label: "DictorCorrectionSyncScan",
                                                               qos: .utility)
    var correctionSyncScanInFlight = false
    /// Scan request that arrived while a scan was in flight; re-issued
    /// (with the strongest flags seen) when the in-flight scan lands.
    var pendingCorrectionSyncScan: (force: Bool, presentErrors: Bool)?

    // MARK: - Lifecycle

    func completeReadinessIfPossible(reason: String) {
        let missing = (isReady || isCoreRuntimeReady) ? missingPermissions() : []
        switch readinessTransition(isReady: isReady,
                                   isCoreRuntimeReady: isCoreRuntimeReady,
                                   missingPermissions: missing) {
        case .rebuildMenuOnly:
            if isReady {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
            }
            rebuildMenu()
            return
        case .blockForPermissions(let missing):
            enterPermissionBlockedState(missing: missing, reason: reason)
            return
        case .startHotkeyListener:
            break
        }

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .standard, hotkeyDetectedAt: detectedAt)
        }
        hotkey.onReleaseAlternate = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .alternate, hotkeyDetectedAt: detectedAt)
        }
        hotkey.onCancel = { [weak self] in self?.cancelActiveRecording(reason: "escape") }
        hotkey.onRejectedBusyPress = { [weak self] in
            guard let self, self.isBusy, self.settings.playFeedbackSounds else { return }
            Sounds.playError()
        }
        hotkey.isRecordingActive = { [weak self] in self?.isRecording == true }
        // Mirrors the first guard in handlePress — if this returns
        // false the press would be silently discarded, so toggle mode
        // must not flip state for it. The missing-permissions case is
        // deliberately NOT part of the gate: that press gives feedback
        // (enterPermissionBlockedState), which also resets the toggle.
        hotkey.canStartRecording = { [weak self] in
            guard let self else { return false }
            return self.isReady && !self.isRecording && !self.isBusy && !self.isTerminating
        }
        let hotkeyReady = hotkeyPausedForExternalCapture || hotkey.start()
        if hotkeyPausedForExternalCapture {
            log("HotkeyListener: startup completed while shortcut capture remains active")
        }
        guard hotkeyReady else {
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
            log("readiness failed (\(reason)): hotkey listener unavailable")
            setMenuBarState(.error)
            if missingPermissions().isEmpty {
                startupFailure = StartupFailure(stage: .hotkeyListener,
                                                detail: "The keyboard event tap could not be started.")
            } else {
                startPermissionReadinessMonitor(reason: reason)
            }
            rebuildMenu()
            return
        }

        isReady = true
        startupStatusTitle = "Ready"
        startupFailure = nil
        stopPermissionReadinessMonitor()
        setMenuBarState(.idle)
        refreshActivationPolicy()

        rebuildMenu()
        startUpdateCheckLoop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.normalizeSpeechModelProfileForCurrentBuild() {
            log("ASR: reset unsupported saved speech model selection to \(settings.speechModelProfile.shortName)")
        }

        DictorAgentService.refreshInstalledPlistIfNeeded()
        recoverStaleTCCAfterUpgrade()
        _ = previousExitNoticeAction(previousRunWasActive: settings.hasActiveRunMarker)
        recoverStaleSystemAudioMuteIfNeeded()
        settings.hasActiveRunMarker = true
        restoreUpdateReminderPause()
        history = settings.recentTranscriptEntries
        lastSeenHistoryArchiveData = settings.recentTranscriptEntriesStoredData
        importDictationUsageFromLogIfNeeded()

        // «Вставлено» показывается оптимистично: в момент ⌘V правды ещё нет,
        // а задерживать успех нельзя — сигнал чтения буфера надёжен только в
        // отрицательную сторону (менеджер буфера обмена читает всё подряд).
        // Правда приходит со страховкой транзакции: за текстом никто не
        // пришёл — значит, вставки точно не было, и молчать нельзя.
        ClipboardPasteInserter.onPasteNeverRead = { [weak self] keptInClipboard in
            self?.signalPasteNeverRead(keptInClipboard: keptInClipboard)
        }

        refreshActivationPolicy()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemImage()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        revealMenuBarIcon()
        setMenuBarState(.loading)
        startCorrectionSyncIfConfigured()
        rebuildMenu()
        applyFloatingCapsuleSettings()

        audio.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.handleAudioConfigurationChange()
            }
        }
        installWorkspacePowerObservers()
        installAudioInputDeviceWatcher()
        installGlobalMouseMonitor()
        installHotkeyCaptureObservers()

        // Configure hotkey listener up front so it picks up the user's
        // saved choice the moment the tap goes live.
        applyHotkeySettings(force: true)
        startStartup(reason: "launch")
        startSettingsWatch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openControlPanelFromAgent()
        return true
    }

    func openControlPanelFromAgent(section: String? = nil) {
        if DictorControlPanelRegistry.activateExistingPanelIfPresent() {
            log("control panel activated from agent")
            if let section {
                // Окно уже открыто — просим его переключить раздел.
                DistributedNotificationCenter.default().postNotificationName(
                    CONTROL_PANEL_SECTION_NOTIFICATION,
                    object: section,
                    userInfo: nil,
                    deliverImmediately: true)
            }
            return
        }
        guard let executablePath = Bundle.main.executablePath else {
            log("control panel open failed: missing executable path")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = section.map { [CONTROL_PANEL_SECTION_ARGUMENT, $0] } ?? []
        process.environment = systemToolProcessEnvironment()
        do {
            try process.run()
            log("control panel opened from agent")
        } catch {
            log("control panel open failed: \(error.localizedDescription)")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        publishAgentState(status: "stopping", detail: "Dictation service is stopping.")
        settings.hasActiveRunMarker = false
        startupTask?.cancel()
        startupTask = nil
        cancelSpeechModelUpdate()
        updateCheckLoopTask?.cancel()
        updateCheckLoopTask = nil
        manualUpdateCheckTask?.cancel()
        manualUpdateCheckTask = nil
        stopPermissionReadinessMonitor()
        stopSetupChecklistRefreshTimer()
        removeWorkspacePowerObservers()
        audioInputDeviceWatcher?.stop()
        audioInputDeviceWatcher = nil
        removeGlobalMouseMonitor()
        removeHotkeyCaptureObservers()
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        audio.onConfigurationChange = nil
        cancelRecordingForTermination()
        // If the mute lifecycle is mid-flight or still holding the
        // mute, the watchdog must outlive us: the async unmute
        // requested by cancelRecordingForTermination may not run
        // before the process exits, and the watchdog unmutes + clears
        // the marker once our pid disappears.
        if systemAudioMutePhase == .idle {
            stopSystemAudioMuteWatchdog()
        }
    }

    // MARK: - File imports

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var didImport = false
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if importCorrectionsFromOpenedFile(url) {
                didImport = true
            }
        }
        sender.reply(toOpenOrPrint: didImport ? .success : .failure)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Системный крестик — тоже способ закрыть окно обновления. Без
        // обнуления ссылки guard в presentUpdateWindow навсегда съедал
        // следующие показы: кнопка «Обновить» в поповере молчала, и даже
        // автоматическая проверка через 6 часов упиралась в тот же guard.
        if window === updateAvailableWindow {
            updateAvailableWindow = nil
            refreshActivationPolicy()
            return
        }
        guard window === setupChecklistWindow else { return }
        stopSetupChecklistRefreshTimer()
        refreshActivationPolicy()
    }
}

// MARK: - Плавающая капсула

extension DictorApp: FloatingCapsuleDelegate {
    /// Кнопка «Диктовать» — переключатель, независимо от того, как настроен
    /// хоткей: удерживать мышь на кнопке всю диктовку никто не станет.
    func floatingCapsuleDidRequestDictation() {
        if isRecording {
            handleRelease()
        } else {
            handlePress()
        }
    }

    func floatingCapsuleDidRequestHistory() {
        openControlPanelFromAgent(section: MainWindowSection.history.rawValue)
    }

    func floatingCapsuleDidRequestMenu(at point: NSPoint) {
        // То же меню, что по правому клику на иконке в строке меню: второго
        // набора команд у приложения быть не должно.
        buildMenu().popUp(positioning: nil, at: point, in: nil)
    }
}
