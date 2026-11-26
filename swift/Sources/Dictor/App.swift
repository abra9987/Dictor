import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

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
    private var templateImage: NSImage?
    private var recordingImage: NSImage?
    private var errorImage: NSImage?
    var recordingStartedAtUptime: TimeInterval?
    var quickPanel: DictorQuickPanel?
    /// Пауза перед показом коротких состояний службы (макет 8c) — та же, что
    /// в подвале окна, чтобы шапка панели и подвал не расходились словами.
    let quickPanelStatusHold = ServiceStatusHold()
    var quickPanelStatusHoldTimer: Timer?
    /// Плавающая капсула (макет 6c). Живёт, только пока включена в настройках.
    let floatingCapsule = FloatingCapsuleController()
    var isDictationPaused = false
    private var menuBarGlyphPhase: CGFloat = 0
    private var lastMenuBarGlyphUpdateAt: TimeInterval = 0
    private var insertedHUDWorkItem: DispatchWorkItem?
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
    private var recordingLevelTimer: Timer?
    var recordingVisualLevel: Float = 0
    private var recordingHUDPhase: CGFloat = 0
    private var lastRecordingLevelSequence: UInt64 = 0
    private var staleRecordingLevelTicks = 0
    var recordingHUDPanel: NSPanel?
    var recordingHUDView: RecordingHUDView?
    var recordingHUDTranscribingStartedAt: TimeInterval?
    var recordingHUDAnimationToken = 0
    private var recordingHUDDisplayLink: CADisplayLink?
    private var lastRecordingHUDMotionAt: TimeInterval?
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

    // MARK: - Menu bar appearance
    //
    // Same silhouette across all states; only colour shifts. The
    // template image is used for idle/loading/busy so it auto-adapts to
    // light/dark menu bar. For recording/error we swap to pre-rendered,
    // non-template images: NSStatusItem.button silently drops
    // contentTintColor on template images in some macOS configurations,
    // so baking the colour into the image is the only reliable way to
    // guarantee the recording state actually reads.

    private func configureStatusItemImage() {
        guard let button = statusItem.button else { return }
        // Глиф «линия голоса» рисуется кодом (VoiceLineGlyph) — PNG из
        // Resources больше не нужен. Idle/busy — template (система сама
        // красит под светлую/тёмную панель), error — линия + коралловая
        // точка. Recording анимируется в recordingLevelTimerFired.
        let image = VoiceLineGlyph.image(bars: VoiceLineGlyph.idleBars)
        templateImage = image
        recordingImage = VoiceLineGlyph.image(
            bars: VoiceLineGlyph.recordingBars(level: 0, phase: 0)
        )
        errorImage = VoiceLineGlyph.errorImage()
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Dictor"
    }

    private func revealMenuBarIcon() {
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.isHidden = false
        statusItem.button?.toolTip = "Dictor"
    }

    func setMenuBarState(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .loading:
            // Subtle dim while the model compiles. nil contentTintColor
            // = system default (black/white per theme); .tertiary gives
            // a "this is here but not yet active" feel.
            button.image = templateImage
            button.contentTintColor = .tertiaryLabelColor
        case .idle:
            // Default tint — macOS auto-handles light/dark menu bar.
            button.image = templateImage
            button.contentTintColor = nil
        case .recording:
            button.image = recordingImage ?? templateImage
            button.contentTintColor = nil
        case .busy:
            // Ровные полубары — «замерли, распознаём». Transcribe обычно
            // короткий, поэтому без анимации.
            button.image = VoiceLineGlyph.image(bars: VoiceLineGlyph.busyBars)
            button.contentTintColor = nil
        case .error:
            button.image = errorImage ?? templateImage
            button.contentTintColor = nil
        case .paused:
            button.image = VoiceLineGlyph.image(bars: VoiceLineGlyph.pausedBars)
            button.contentTintColor = .tertiaryLabelColor
        }
    }

    func startRecordingLevelMeter(initialContext: InsertionTargetQueryContext?) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        recordingHUDPhase = 0
        recordingHUDInsertionTargetFrame = nil
        recordingHUDInsertionTargetVisualFrame = nil
        recordingHUDFallbackWindowFrame = nil
        recordingHUDTranscribingStartedAt = nil
        lastRecordingHUDTargetRefreshAt = nil
        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        recordingHUDTargetSessionToken &+= 1
        recordingHUDTargetQueryInFlight = false
        recordingHUDWaitingForInitialTarget = settings.showRecordingWaveform
        recordingHUDTargetStabilizer.reset(initialApplicationPID: initialContext?.applicationPID)
        recordingStartedAtUptime = ProcessInfo.processInfo.systemUptime
        menuBarGlyphPhase = 0
        lastMenuBarGlyphUpdateAt = 0
        recordingHUDView?.resetWave()
        setMenuBarState(.recording)
        // Капсула переходит в состояние записи тем же движением, что и растёт:
        // человек видит, что это она, а не новое окно.
        floatingCapsule.setRecording(true)
        let timer = Timer(timeInterval: 1.0 / 24.0,
                          target: self,
                          selector: #selector(recordingLevelTimerFired(_:)),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 1.0 / 48.0
        RunLoop.main.add(timer, forMode: .common)
        recordingLevelTimer = timer

        if let initialContext {
            requestRecordingHUDTarget(context: initialContext, isInitial: true)
        } else {
            recordingHUDWaitingForInitialTarget = false
            log("text insertion target unavailable at recording start: frontmost application unavailable")
            if settings.showRecordingWaveform {
                showRecordingHUD(mode: .recording, level: 0)
            }
        }
    }

    func stopRecordingLevelMeter(resetImage: Bool = true, hideHUD: Bool = true) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        if !isRecording {
            stopRecordingHUDTargetTracking(clearTarget: false)
        }
        if hideHUD {
            recordingHUDPhase = 0
            hideRecordingHUD()
        }
        // Капсула возвращается к покою (или к действиям, если курсор всё ещё
        // на ней) при любом конце записи — в том числе когда HUD остаётся ради
        // «распознаю…»: своего состояния распознавания у капсулы нет, и под
        // if hideHUD она навсегда застревала в «идёт запись».
        floatingCapsule.setRecording(false)
        if resetImage, isRecording {
            setMenuBarState(.recording)
        }
    }

    @objc private func recordingLevelTimerFired(_ timer: Timer) {
        guard isRecording else {
            stopRecordingLevelMeter()
            return
        }
        let snapshot = audio.latestRecordingLevelSnapshot()
        if snapshot.sequence == lastRecordingLevelSequence {
            staleRecordingLevelTicks += 1
        } else {
            lastRecordingLevelSequence = snapshot.sequence
            staleRecordingLevelTicks = 0
        }
        let unsuppressedLevel = staleRecordingLevelTicks > 8 ? 0 : snapshot.level
        let rawLevel = visibleRecordingLevel(rawLevel: unsuppressedLevel)
        let attack: Float = rawLevel > recordingVisualLevel ? 0.65 : 0.28
        recordingVisualLevel += (rawLevel - recordingVisualLevel) * attack
        let now = ProcessInfo.processInfo.systemUptime
        if let startedAt = recordingStartedAtUptime {
            recordingHUDView?.recordingElapsed = now - startedAt
        }
        // Живой глиф в меню-баре: бары от реального RMS, 8 fps.
        if now - lastMenuBarGlyphUpdateAt >= 0.12 {
            lastMenuBarGlyphUpdateAt = now
            menuBarGlyphPhase += 0.9
            let bars = VoiceLineGlyph.recordingBars(level: CGFloat(recordingVisualLevel),
                                                    phase: menuBarGlyphPhase)
            let image = VoiceLineGlyph.image(bars: bars)
            recordingImage = image
            statusItem.button?.image = image
        }
        // Плавающая капсула сама растёт под голос — это тот же объект, а не
        // второе окно (макет 6c). Пока она на экране, отдельный HUD не нужен.
        if floatingCapsule.isVisible {
            floatingCapsule.update(level: recordingVisualLevel,
                                   phase: CGFloat(menuBarGlyphPhase),
                                   elapsedSeconds: Int(now - (recordingStartedAtUptime ?? now)))
        }
        refreshRecordingHUDInsertionTargetIfNeeded(at: now)
        if settings.showRecordingWaveform {
            guard !recordingHUDWaitingForInitialTarget else { return }
            if recordingHUDPanel?.isVisible == true {
                updateRecordingHUD(mode: .recording, level: recordingVisualLevel)
            } else {
                showRecordingHUD(mode: .recording, level: recordingVisualLevel)
            }
        } else {
            hideRecordingHUD()
        }
    }

    var recordingHUDExpandedSize: NSSize {
        settings.recordingHUDSize.expandedSize
    }

    func showRecordingHUD(mode: RecordingHUDMode,
                                  level: Float) {
        guard settings.showRecordingWaveform else { return }
        // «Один и тот же объект меняет размер — не появляется новое окно»
        // (макет 6c): при включённой капсуле запись показывается в ней.
        guard !floatingCapsule.isVisible else { return }
        let panel = recordingHUDPanel ?? makeRecordingHUDPanel()
        recordingHUDPanel = panel
        let shouldAnimate = !panel.isVisible
        if let view = recordingHUDView {
            configureRecordingHUDView(view)
            view.mode = mode
            view.level = level
            view.phase = recordingHUDPhase
        }
        if shouldAnimate {
            animateRecordingHUDIn(panel)
        } else {
            recordingHUDAnimationToken += 1
            stopRecordingHUDRevealAnimation(finish: true)
            panel.alphaValue = 1
            recordingHUDView?.revealProgress = 1
            panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize), display: true)
            panel.orderFrontRegardless()
        }
        startRecordingHUDMotion()
    }

    private func updateRecordingHUD(mode: RecordingHUDMode,
                                    level: Float) {
        if let view = recordingHUDView {
            configureRecordingHUDView(view)
            view.mode = mode
            view.level = level
            view.phase = recordingHUDPhase
        }
    }

    func showTranscribingHUD() {
        guard settings.showRecordingWaveform else { return }
        recordingHUDTranscribingStartedAt = ProcessInfo.processInfo.systemUptime
        if recordingHUDPanel?.isVisible == true {
            updateRecordingHUD(mode: .transcribing, level: 0)
        } else {
            showRecordingHUD(mode: .transcribing, level: 0)
        }
        startRecordingHUDMotion()
    }

    func hideRecordingHUD() {
        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        guard let panel = recordingHUDPanel else {
            stopRecordingHUDMotion()
            recordingHUDInsertionTargetFrame = nil
            recordingHUDInsertionTargetVisualFrame = nil
            recordingHUDFallbackWindowFrame = nil
            lastRecordingHUDTargetRefreshAt = nil
            stopRecordingHUDTargetTracking(clearTarget: true)
            return
        }
        recordingHUDAnimationToken += 1
        stopRecordingHUDRevealAnimation(finish: false)
        guard panel.isVisible else {
            stopRecordingHUDMotion()
            panel.alphaValue = 1
            panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize), display: false)
            recordingHUDView?.mode = .recording
            recordingHUDView?.level = 0
            recordingHUDView?.phase = 0
            recordingHUDView?.revealProgress = 1
            recordingHUDInsertionTargetFrame = nil
            recordingHUDInsertionTargetVisualFrame = nil
            recordingHUDFallbackWindowFrame = nil
            lastRecordingHUDTargetRefreshAt = nil
            stopRecordingHUDTargetTracking(clearTarget: true)
            return
        }

        let token = recordingHUDAnimationToken
        panel.alphaValue = 1
        panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize),
                       display: false)
        startRecordingHUDRevealAnimation(from: recordingHUDView?.revealProgress ?? 1,
                                         to: 0,
                                         duration: RECORDING_HUD_ANIMATE_OUT_SECONDS) { [weak panel, weak self] in
            guard let self, let panel else { return }
            guard self.recordingHUDAnimationToken == token else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(self.recordingHUDFrame(size: self.recordingHUDExpandedSize),
                           display: false)
            self.recordingHUDView?.mode = .recording
            self.recordingHUDView?.level = 0
            self.recordingHUDView?.phase = 0
            self.recordingHUDView?.revealProgress = 1
            self.recordingHUDInsertionTargetFrame = nil
            self.recordingHUDInsertionTargetVisualFrame = nil
            self.recordingHUDFallbackWindowFrame = nil
            self.lastRecordingHUDTargetRefreshAt = nil
            self.stopRecordingHUDTargetTracking(clearTarget: true)
            self.stopRecordingHUDMotion()
        }
    }

    func startRecordingHUDMotion() {
        guard recordingHUDDisplayLink == nil,
              let view = recordingHUDView else {
            return
        }
        lastRecordingHUDMotionAt = ProcessInfo.processInfo.systemUptime
        let displayLink = view.displayLink(target: self,
                                           selector: #selector(recordingHUDDisplayLinkFired(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: RECORDING_HUD_DISPLAY_LINK_MIN_FPS,
            maximum: RECORDING_HUD_DISPLAY_LINK_MAX_FPS,
            preferred: RECORDING_HUD_DISPLAY_LINK_MAX_FPS
        )
        displayLink.add(to: .main, forMode: .common)
        recordingHUDDisplayLink = displayLink
    }

    private func stopRecordingHUDMotion() {
        recordingHUDDisplayLink?.invalidate()
        recordingHUDDisplayLink = nil
        lastRecordingHUDMotionAt = nil
    }

    @objc private func recordingHUDDisplayLinkFired(_ displayLink: CADisplayLink) {
        let hudIsVisible = recordingHUDPanel?.isVisible == true
        guard hudIsVisible || recordingHUDRevealStartedAt != nil else {
            stopRecordingHUDMotion()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastRecordingHUDMotionAt ?? now
        let dt = max(0.001, min(0.05, now - previous))
        lastRecordingHUDMotionAt = now

        advanceRecordingHUDRevealAnimation(at: now)
        let mode = recordingHUDView?.mode
            ?? ((isBusy && !isRecording) ? .transcribing : .recording)
        let speed = recordingHUDPhaseSpeed(mode: mode, level: recordingVisualLevel)
        recordingHUDPhase += CGFloat(dt) * speed
        recordingHUDView?.phase = recordingHUDPhase
        _ = moveRecordingHUDTowardInsertionTarget(deltaTime: dt)
        recordingHUDView?.displayIfNeeded()
    }

    private func makeRecordingHUDPanel() -> NSPanel {
        let size = recordingHUDExpandedSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        let view = RecordingHUDView(frame: NSRect(origin: .zero, size: size))
        configureRecordingHUDView(view)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        recordingHUDView = view
        return panel
    }

    private func configureRecordingHUDView(_ view: RecordingHUDView) {
        view.visualScale = settings.recordingHUDSize.visualScale
        view.hudSize = settings.recordingHUDSize
        view.recordingColor = settings.recordingHUDRecordingColor.nsColor
        view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
        view.backgroundStyle = settings.recordingHUDBackgroundStyle
        view.interfaceLanguage = settings.interfaceLanguage
    }

    /// Капсула-подтверждение: галочка + «Вставлено · N слов», hold
    /// 0.9 с, затем растворение. Показывается только если HUD включён.
    func showInsertedHUD(wordCount: Int) {
        guard settings.showRecordingWaveform else { return }
        insertedHUDWorkItem?.cancel()
        recordingHUDTranscribingStartedAt = nil
        recordingHUDView?.insertedWordCount = wordCount
        if recordingHUDPanel?.isVisible == true {
            updateRecordingHUD(mode: .inserted, level: 0)
        } else {
            showRecordingHUD(mode: .inserted, level: 0)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.insertedHUDWorkItem = nil
            guard !self.isRecording, !self.isBusy else { return }
            self.hideRecordingHUD()
        }
        insertedHUDWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SD.Anim.insertedHoldSeconds,
                                      execute: work)
    }

    private func animateRecordingHUDIn(_ panel: NSPanel) {
        recordingHUDAnimationToken += 1
        stopRecordingHUDRevealAnimation(finish: false)
        let finalFrame = recordingHUDFrame(size: recordingHUDExpandedSize)
        recordingHUDView?.revealProgress = 0
        panel.alphaValue = 1
        panel.setFrame(finalFrame, display: true)
        panel.contentView?.displayIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        startRecordingHUDRevealAnimation(from: 0,
                                         to: 1,
                                         duration: RECORDING_HUD_ANIMATE_IN_SECONDS)
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
