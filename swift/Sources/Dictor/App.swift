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
    private struct CachedInsertionTarget {
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
    private var recordingStartedAtUptime: TimeInterval?
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
    private let insertionTargetTracker = FocusedInsertionTargetTracker()
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
    private var systemAudioMutePhase: SystemAudioMutePhase = .idle
    /// Set when the recording ends while the probe or mute command is
    /// still in flight; the in-flight completion honours it.
    private var systemAudioUnmuteRequested = false
    private var maxDurationWorkItem: DispatchWorkItem?
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
    private var recordingVisualLevel: Float = 0
    private var recordingHUDPhase: CGFloat = 0
    private var lastRecordingLevelSequence: UInt64 = 0
    private var staleRecordingLevelTicks = 0
    private var recordingHUDPanel: NSPanel?
    private var recordingHUDView: RecordingHUDView?
    private var recordingHUDTranscribingStartedAt: TimeInterval?
    private var recordingHUDAnimationToken = 0
    private var recordingHUDDisplayLink: CADisplayLink?
    private var lastRecordingHUDMotionAt: TimeInterval?
    private var lastRecordingHUDTargetRefreshAt: TimeInterval?
    private var recordingHUDRevealStartedAt: TimeInterval?
    private var recordingHUDRevealFrom: CGFloat = 0
    private var recordingHUDRevealTo: CGFloat = 1
    private var recordingHUDRevealDuration: TimeInterval = RECORDING_HUD_ANIMATE_IN_SECONDS
    private var recordingHUDRevealCompletion: (() -> Void)?
    private var recordingHUDRetargetWorkItem: DispatchWorkItem?
    private var recordingHUDInsertionTargetFrame: NSRect?
    private var recordingHUDInsertionTargetVisualFrame: NSRect?
    private var recordingHUDFallbackWindowFrame: NSRect?
    private var recordingHUDTargetStabilizer = RecordingHUDTargetStabilizer()
    private var recordingHUDTargetQueryInFlight = false
    private var recordingHUDTargetSessionToken = 0
    private var recordingHUDWaitingForInitialTarget = false
    private var insertionTargetCache: [pid_t: CachedInsertionTarget] = [:]
    var globalMouseDownMonitor: Any?
    var lastExternalClick: LastExternalClick?
    private var errorFlashWorkItem: DispatchWorkItem?
    private var systemAudioMuteWatchdog: Process?

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

    private func startRecordingLevelMeter(initialContext: InsertionTargetQueryContext?) {
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

    private var recordingHUDExpandedSize: NSSize {
        settings.recordingHUDSize.expandedSize
    }

    private func showRecordingHUD(mode: RecordingHUDMode,
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

    private func showTranscribingHUD() {
        guard settings.showRecordingWaveform else { return }
        recordingHUDTranscribingStartedAt = ProcessInfo.processInfo.systemUptime
        if recordingHUDPanel?.isVisible == true {
            updateRecordingHUD(mode: .transcribing, level: 0)
        } else {
            showRecordingHUD(mode: .transcribing, level: 0)
        }
        startRecordingHUDMotion()
    }

    private func hideRecordingHUD() {
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

    private func startRecordingHUDMotion() {
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
    private func showInsertedHUD(wordCount: Int) {
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

    private func recordingHUDFrame(size: NSSize) -> NSRect {
        switch settings.recordingHUDPlacement {
        case .bottomCenter:
            return recordingHUDFrameAtScreenCenter(size: size, atBottom: true)
        case .topCenter:
            return recordingHUDFrameAtScreenCenter(size: size, atBottom: false)
        case .followsInput:
            break
        }
        if let targetFrame = recordingHUDInsertionTargetVisualFrame ?? recordingHUDInsertionTargetFrame {
            return recordingHUDFrameAboveTarget(targetFrame, size: size)
        }
        if let fallbackWindow = recordingHUDFallbackWindowFrame {
            return recordingHUDFrameInsideFallbackWindow(fallbackWindow, size: size)
        }
        let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - (size.width / 2)
        let y = visible.maxY - size.height - 96
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// По центру того экрана, где сейчас курсор — на нём же пользователь
    /// и печатает. 96 pt от края повторяют отступ, с которым капсула
    /// висит сверху, когда поле ввода не нашлось.
    private func recordingHUDFrameAtScreenCenter(size: NSSize, atBottom: Bool) -> NSRect {
        let visible = screenFor(point: NSEvent.mouseLocation).visibleFrame
        return NSRect(x: visible.midX - (size.width / 2),
                      y: atBottom ? visible.minY + 96 : visible.maxY - size.height - 96,
                      width: size.width,
                      height: size.height)
    }

    private func recordingHUDFrameInsideFallbackWindow(_ windowFrame: NSRect,
                                                       size: NSSize) -> NSRect {
        let screen = screenFor(point: NSPoint(x: windowFrame.midX, y: windowFrame.midY))
        let visible = screen.visibleFrame
        let contentInset = min(180, max(28, windowFrame.width * 0.15))
        let preferredX = windowFrame.minX + contentInset
        let preferredY = windowFrame.minY + min(96, max(44, windowFrame.height * 0.14))
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let y = min(max(preferredY, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func recordingHUDFrameAboveTarget(_ targetFrame: NSRect, size: NSSize) -> NSRect {
        let center = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        let visible = screenFor(point: center).visibleFrame
        let gap: CGFloat = 12
        let preferredX = targetFrame.minX + 6
        let preferredY = targetFrame.maxY + gap + 8
        let fallbackY = targetFrame.minY - gap - size.height
        let y = preferredY + size.height <= visible.maxY - 8
            ? preferredY
            : fallbackY
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let clampedY = min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: x, y: clampedY, width: size.width, height: size.height)
    }

    private func startRecordingHUDRevealAnimation(from: CGFloat,
                                                  to: CGFloat,
                                                  duration: TimeInterval,
                                                  completion: (() -> Void)? = nil) {
        recordingHUDRevealFrom = max(0, min(1, from))
        recordingHUDRevealTo = max(0, min(1, to))
        let distance = abs(recordingHUDRevealTo - recordingHUDRevealFrom)
        recordingHUDRevealDuration = max(1.0 / Double(RECORDING_HUD_DISPLAY_LINK_MAX_FPS),
                                         duration * Double(distance))
        recordingHUDRevealCompletion = completion
        recordingHUDView?.revealProgress = recordingHUDRevealFrom
        recordingHUDRevealStartedAt = ProcessInfo.processInfo.systemUptime
        startRecordingHUDMotion()
    }

    private func stopRecordingHUDRevealAnimation(finish: Bool) {
        recordingHUDRevealStartedAt = nil
        let finalProgress = recordingHUDRevealTo
        let completion = recordingHUDRevealCompletion
        recordingHUDRevealCompletion = nil
        if finish {
            recordingHUDView?.revealProgress = finalProgress
            completion?()
        }
    }

    private func advanceRecordingHUDRevealAnimation(at now: TimeInterval) {
        guard let startedAt = recordingHUDRevealStartedAt,
              let view = recordingHUDView else {
            return
        }
        let elapsed = now - startedAt
        let progress = min(1, max(0, elapsed / recordingHUDRevealDuration))
        // The view gives each visual layer its own quintic curve. Keep this
        // master timeline linear so those curves do not get double-eased.
        view.revealProgress = recordingHUDRevealFrom
            + ((recordingHUDRevealTo - recordingHUDRevealFrom) * CGFloat(progress))
        if progress >= 1 {
            stopRecordingHUDRevealAnimation(finish: true)
        }
    }

    private func insertionTargetQueryContext() -> InsertionTargetQueryContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let referenceMaxY = screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        let clickPoint: NSPoint?
        if let lastExternalClick,
           lastExternalClick.applicationPID == app.processIdentifier,
           now - lastExternalClick.capturedAt <= RECORDING_HUD_TARGET_CACHE_MAX_AGE {
            clickPoint = lastExternalClick.point
        } else {
            clickPoint = nil
        }
        return InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: referenceMaxY,
            lastClickPoint: clickPoint
        )
    }

    private func requestRecordingHUDTarget(context: InsertionTargetQueryContext? = nil,
                                           isInitial: Bool = false) {
        guard isRecording, !recordingHUDTargetQueryInFlight else { return }
        guard let context = context ?? insertionTargetQueryContext() else {
            if isInitial {
                recordingHUDWaitingForInitialTarget = false
                if settings.showRecordingWaveform {
                    showRecordingHUD(mode: .recording, level: recordingVisualLevel)
                }
            }
            return
        }

        recordingHUDTargetQueryInFlight = true
        let sessionToken = recordingHUDTargetSessionToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.insertionTargetTracker.query(context: context)
            guard self.recordingHUDTargetSessionToken == sessionToken,
                  self.isRecording else {
                return
            }
            self.recordingHUDTargetQueryInFlight = false
            self.handleRecordingHUDTargetResult(result, isInitial: isInitial)
        }
    }

    private func handleRecordingHUDTargetResult(_ result: FocusedInsertionTargetQueryResult,
                                                isInitial: Bool) {
        lastRecordingHUDTargetRefreshAt = ProcessInfo.processInfo.systemUptime
        if let focusedWindowFrame = result.focusedWindowFrame {
            recordingHUDFallbackWindowFrame = focusedWindowFrame
        }

        let liveTarget = result.target.flatMap {
            shouldUseRecordingHUDInsertionTarget($0) ? $0 : nil
        }
        let observedTarget = liveTarget ?? cachedInsertionTarget(for: result)
        let decision = recordingHUDTargetStabilizer.observe(observedTarget)
        switch decision {
        case .none:
            break
        case .update(let target):
            applyRecordingHUDTarget(target,
                                    queryResult: result,
                                    animateSwitch: false,
                                    updateCache: liveTarget != nil)
        case .switchTarget(let target):
            applyRecordingHUDTarget(target,
                                    queryResult: result,
                                    animateSwitch: recordingHUDPanel?.isVisible == true,
                                    updateCache: liveTarget != nil)
        }

        if isInitial {
            recordingHUDWaitingForInitialTarget = false
            if let liveTarget {
                log("text insertion target captured at recording start: \(liveTarget.resolutionKind), frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            } else if observedTarget != nil {
                log("text insertion target restored from recent cache, frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            } else {
                log("text insertion target unavailable at recording start, frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            }
            if settings.showRecordingWaveform {
                showRecordingHUD(mode: .recording, level: recordingVisualLevel)
            }
        } else if liveTarget != nil,
                  case .switchTarget(let target) = decision {
            log("text insertion target switched during recording: \(target.resolutionKind), frontmost: \(result.applicationName) (\(result.bundleIdentifier))")
        }
    }

    private func applyRecordingHUDTarget(_ target: FocusedInsertionTargetFrame,
                                         queryResult: FocusedInsertionTargetQueryResult,
                                         animateSwitch: Bool,
                                         updateCache: Bool) {
        let previousTargetFrame = recordingHUDInsertionTargetVisualFrame
            ?? recordingHUDInsertionTargetFrame
        recordingHUDInsertionTargetFrame = target.frame
        recordingHUDInsertionTargetVisualFrame = target.visualFrame
        if updateCache {
            insertionTargetCache[target.identity.applicationPID] = CachedInsertionTarget(
                target: target,
                windowFrame: queryResult.focusedWindowFrame,
                cachedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        if animateSwitch {
            animateRecordingHUDRetargetIfNeeded(from: previousTargetFrame,
                                                to: target.visualFrame)
        }
    }

    private func cachedInsertionTarget(for result: FocusedInsertionTargetQueryResult) -> FocusedInsertionTargetFrame? {
        guard let cached = insertionTargetCache[result.applicationPID],
              ProcessInfo.processInfo.systemUptime - cached.cachedAt <= RECORDING_HUD_TARGET_CACHE_MAX_AGE else {
            insertionTargetCache[result.applicationPID] = nil
            return nil
        }
        if result.focusedWindowToken != 0,
           cached.target.identity.windowToken != 0,
           result.focusedWindowToken != cached.target.identity.windowToken {
            return nil
        }

        var frame = cached.target.frame
        var visualFrame = cached.target.visualFrame
        if let oldWindow = cached.windowFrame,
           let newWindow = result.focusedWindowFrame {
            let dx = newWindow.minX - oldWindow.minX
            let dy = newWindow.minY - oldWindow.minY
            frame = frame.offsetBy(dx: dx, dy: dy)
            visualFrame = visualFrame.offsetBy(dx: dx, dy: dy)
            guard newWindow.insetBy(dx: -80, dy: -80).intersects(visualFrame) else {
                return nil
            }
        }
        return FocusedInsertionTargetFrame(
            frame: frame,
            visualFrame: visualFrame,
            resolutionKind: "\(cached.target.resolutionKind) cache",
            identity: cached.target.identity
        )
    }

    private func stopRecordingHUDTargetTracking(clearTarget: Bool) {
        recordingHUDTargetSessionToken &+= 1
        recordingHUDTargetQueryInFlight = false
        recordingHUDWaitingForInitialTarget = false
        lastRecordingHUDTargetRefreshAt = nil
        if clearTarget {
            recordingHUDTargetStabilizer.reset(initialApplicationPID: nil)
            recordingHUDFallbackWindowFrame = nil
        }
    }

    private func refreshRecordingHUDInsertionTargetIfNeeded(at now: TimeInterval) {
        guard isRecording else { return }
        if let last = lastRecordingHUDTargetRefreshAt,
           now - last < RECORDING_HUD_TARGET_REFRESH_INTERVAL {
            return
        }
        lastRecordingHUDTargetRefreshAt = now
        requestRecordingHUDTarget()
    }

    private func shouldUseRecordingHUDInsertionTarget(_ target: FocusedInsertionTargetFrame) -> Bool {
        let frame = target.visualFrame
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let visible = screenFor(point: NSPoint(x: frame.midX, y: frame.midY)).visibleFrame
        if frame.width > visible.width * 0.92,
           frame.height > visible.height * 0.55 {
            return false
        }
        if frame.height > visible.height * 0.82 {
            return false
        }
        return true
    }

    private func moveRecordingHUDTowardInsertionTarget(deltaTime: TimeInterval) -> Bool {
        guard let panel = recordingHUDPanel,
              panel.isVisible,
              recordingHUDView?.revealProgress == 1 else {
            return false
        }

        let target = recordingHUDFrame(size: recordingHUDExpandedSize)
        guard recordingHUDRetargetWorkItem == nil else {
            return true
        }

        let current = panel.frame
        let deltaX = target.midX - current.midX
        let deltaY = target.midY - current.midY
        if abs(deltaX) < 0.35, abs(deltaY) < 0.35 {
            if !NSEqualRects(current, target) {
                panel.setFrame(target, display: false)
            }
            return true
        }

        let response = 1 - CGFloat(exp(-Double(RECORDING_HUD_TARGET_FOLLOW_RESPONSE) * deltaTime))
        let nextCenter = NSPoint(x: current.midX + (deltaX * response),
                                 y: current.midY + (deltaY * response))
        let size = recordingHUDExpandedSize
        let next = NSRect(x: nextCenter.x - (size.width / 2),
                          y: nextCenter.y - (size.height / 2),
                          width: size.width,
                          height: size.height)
        panel.setFrame(clampedRecordingHUDFrame(next), display: false)
        return true
    }

    private func animateRecordingHUDRetargetIfNeeded(from previousTargetFrame: NSRect?,
                                                     to newTargetFrame: NSRect) {
        guard isRecording else { return }
        guard let panel = recordingHUDPanel,
              panel.isVisible,
              recordingHUDView?.mode == .recording else {
            return
        }

        let target = recordingHUDFrameAboveTarget(newTargetFrame,
                                                  size: recordingHUDExpandedSize)
        let distance = hypot(target.midX - panel.frame.midX,
                             target.midY - panel.frame.midY)
        guard distance > 8 else {
            if distance > 1 {
                panel.setFrame(target, display: false)
            }
            return
        }
        if let previousTargetFrame,
           hypot(previousTargetFrame.midX - newTargetFrame.midX,
                 previousTargetFrame.midY - newTargetFrame.midY) < 3,
           abs(previousTargetFrame.width - newTargetFrame.width) < 3,
           abs(previousTargetFrame.height - newTargetFrame.height) < 3 {
            return
        }

        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        recordingHUDAnimationToken += 1
        let token = recordingHUDAnimationToken
        stopRecordingHUDRevealAnimation(finish: false)

        startRecordingHUDRevealAnimation(from: recordingHUDView?.revealProgress ?? 1,
                                         to: 0,
                                         duration: RECORDING_HUD_ANIMATE_OUT_SECONDS) { [weak self, weak panel] in
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.recordingHUDRetargetWorkItem = nil
                guard self.recordingHUDAnimationToken == token else { return }
                panel.setFrame(target, display: false)
                self.recordingHUDView?.revealProgress = 0
                panel.alphaValue = 1
                panel.contentView?.displayIfNeeded()
                panel.displayIfNeeded()
                panel.orderFrontRegardless()
                self.startRecordingHUDRevealAnimation(from: 0,
                                                      to: 1,
                                                      duration: RECORDING_HUD_ANIMATE_IN_SECONDS)
            }
            self?.recordingHUDRetargetWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }

    private func screenFor(point: NSPoint) -> NSScreen {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return screen
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return screen
        }
        preconditionFailure("NSScreen.screens unexpectedly empty")
    }

    private func clampedRecordingHUDFrame(_ frame: NSRect) -> NSRect {
        let screen = screenFor(point: NSPoint(x: frame.midX, y: frame.midY))
        let visible = screen.visibleFrame
        let x = min(max(frame.minX, visible.minX + 12), visible.maxX - frame.width - 12)
        let y = min(max(frame.minY, visible.minY + 12), visible.maxY - frame.height - 12)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func finishBusyHUD() {
        if let startedAt = recordingHUDTranscribingStartedAt {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let remaining = RECORDING_HUD_TRANSCRIBING_MIN_VISIBLE_SECONDS - elapsed
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self,
                          !self.isRecording,
                          !self.isBusy,
                          self.recordingHUDTranscribingStartedAt == startedAt else { return }
                    self.recordingHUDTranscribingStartedAt = nil
                    self.hideRecordingHUD()
                }
                return
            }
        }
        recordingHUDTranscribingStartedAt = nil
        hideRecordingHUD()
    }

    // Visible + audible cue that a press produced no pasted text — the
    // transcription threw, or the paste itself failed. Without it the menu
    // bar just slips back to idle and the user can't tell their speech was
    // dropped from "pasted somewhere I wasn't looking."
    //
    // The error sound honours playFeedbackSounds — the HUD flash
    // (added below) already solves the original "invisible error"
    // problem for users who run silent. Gating the sound avoids
    // unexpected noise during meetings or screen recordings.
    private func signalDictationFailure(message: String? = nil,
                                        holdSeconds: TimeInterval = DICTATION_ERROR_FLASH_SECONDS) {
        if settings.playFeedbackSounds {
            Sounds.playError()
        }
        flashErrorFeedback(message: message, holdSeconds: holdSeconds)
    }

    /// Через restoreTimeout после «Вставлено» выяснилось, что за текстом никто
    /// не пришёл: ⌘V не дошёл (Secure Input, зависшее окно, перехваченное
    /// сочетание). Текст цел — в «Истории» и, как правило, в буфере — и об
    /// этом надо сказать вслух.
    private func signalPasteNeverRead(keptInClipboard: Bool) {
        guard !isTerminating else { return }
        guard !isRecording, !isBusy else {
            // Человек уже диктует снова — вспышка и звук сейчас помешают
            // записи. След остаётся в логе транзакции.
            log("paste-never-read signal suppressed: a new dictation is in progress")
            return
        }
        let language = settings.interfaceLanguage
        let message = keptInClipboard
            ? localizedText("Текст не вставился — он в буфере и в «Истории»",
                            "The text never pasted — it's in the clipboard and History",
                            language: language)
            : localizedText("Текст не вставился — он в «Истории»",
                            "The text never pasted — it's in History",
                            language: language)
        signalDictationFailure(message: message,
                               holdSeconds: PASTE_NEVER_READ_FLASH_SECONDS)
    }

    /// Flashes both the menu-bar icon (error tint) and the recording
    /// HUD (static yellow capsule with exclamation mark) for
    /// DICTATION_ERROR_FLASH_SECONDS. A single work item owns both
    /// channels so they always expire together.
    private func flashErrorFeedback(message: String? = nil,
                                    holdSeconds: TimeInterval = DICTATION_ERROR_FLASH_SECONDS) {
        errorFlashWorkItem?.cancel()
        // Invalidate any pending delayed hide from finishBusyHUD() —
        // without this the transcribing cleanup closure fires shortly
        // after and hides the error capsule prematurely.
        recordingHUDTranscribingStartedAt = nil
        setMenuBarState(.error)
        if settings.showRecordingWaveform {
            showRecordingHUD(mode: .error, level: 0)
            // После показа: до него view может ещё не существовать. nil
            // возвращает капсуле общий текст «Не получилось распознать» —
            // сообщение прошлой вспышки не должно пережить её саму.
            recordingHUDView?.errorMessage = message
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.errorFlashWorkItem = nil
            // Only clear if nothing else has claimed the icon meanwhile — a
            // new recording, an in-flight transcription, a real (non-transient)
            // error state, or termination all own it and must not be stomped.
            guard self.isReady, !self.isRecording, !self.isBusy, !self.isTerminating else { return }
            self.setMenuBarState(.idle)
            self.hideRecordingHUD()
            self.rebuildMenu()
        }
        errorFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
    }

    // MARK: - Recording loop

    private func handlePress() {
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

    private func handleRelease(shortcut: DictationReleaseShortcut = .standard,
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
    private func cancelRecordingForTermination() {
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

    // Trade-off: the mute is asynchronous relative to recording
    // start. Audio capture is armed immediately when the engine opens
    // on press, while the probe + mute land a few milliseconds later,
    // so a sliver of system audio can bleed into the start of the clip.
    // That beats the alternative — the old synchronous AppleScript
    // calls ran behind the session-wide event tap on the main run
    // loop, stalling every keystroke system-wide (and risking macOS
    // disabling the tap after a >1 s stall).
    private func muteIfNeededForRecording() {
        guard settings.muteWhileRecording else { return }
        guard systemAudioMutePhase == .idle else {
            // A previous recording's lifecycle is still settling
            // (rapid press cycles). Skipping the mute for this
            // recording is safe in the never-stuck sense, but the
            // cost is not always "a few ms": if the previous probe is
            // still in flight when this press lands, it stands down
            // to .idle and THIS recording runs unmuted for its whole
            // duration. Accepted: it needs a press/release/press
            // faster than one AppleScript round-trip, and the
            // alternative (queueing nested mute lifecycles) is far
            // more complex than the failure it prevents.
            log("output mute skipped: previous mute lifecycle still settling")
            return
        }
        systemAudioMutePhase = .probing
        systemAudioUnmuteRequested = false
        // Only mute if we wouldn't be stomping a user-set mute.
        SystemAudio.mutedStateAsync { [weak self] mutedState in
            self?.continueMuteAfterProbe(mutedState: mutedState)
        }
    }

    private func continueMuteAfterProbe(mutedState: Bool?) {
        guard systemAudioMutePhase == .probing else {
            log("output mute probe completion ignored: unexpected phase")
            return
        }
        switch systemAudioMuteProbeDecision(mutedState: mutedState,
                                            unmuteAlreadyRequested: systemAudioUnmuteRequested) {
        case .standDown:
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            return
        case .armRecoveryAndMute:
            break
        }

        // Crash-recovery invariant: the marker + watchdog must exist
        // BEFORE the mute command can execute, so a crash at any
        // point after the mute leaves a recovery path. Both are armed
        // here on the main actor; the mute is only enqueued after
        // they exist, and SystemAudio's serial queue preserves that
        // order.
        do {
            try writeSystemAudioMuteMarker()
            try startSystemAudioMuteWatchdog()
        } catch {
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            log("output mute skipped: recovery watchdog unavailable (\(error.localizedDescription))")
            return
        }
        systemAudioMutePhase = .muting
        SystemAudio.muteAsync { [weak self] outcome in
            self?.finishMuteCommand(outcome: outcome)
        }
    }

    private func finishMuteCommand(outcome: SystemAudioMuteCommandOutcome) {
        guard systemAudioMutePhase == .muting else {
            log("output mute completion ignored: unexpected phase")
            return
        }
        switch systemAudioMuteCommandDecision(outcome: outcome,
                                              unmuteAlreadyRequested: systemAudioUnmuteRequested) {
        case .disarmRecovery:
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            log("output mute failed")
        case .stayMuted:
            systemAudioMutePhase = .muted
            log(outcome == .assumedMuted
                ? "output muted (verification failed; assuming muted, recovery stays armed)"
                : "output muted")
        case .beginUnmute:
            // The recording ended while the mute command ran.
            systemAudioUnmuteRequested = false
            beginSystemAudioUnmute()
        }
    }

    func unmuteIfWeMuted() {
        switch systemAudioUnmuteRequestDecision(phase: systemAudioMutePhase) {
        case .nothingToDo:
            return
        case .deferUntilCommandSettles:
            systemAudioUnmuteRequested = true
        case .beginUnmute:
            beginSystemAudioUnmute()
        }
    }

    private func beginSystemAudioUnmute() {
        systemAudioMutePhase = .unmuting
        SystemAudio.unmuteAsync { [weak self] unmuted in
            self?.finishUnmuteCommand(unmuted: unmuted)
        }
    }

    private func finishUnmuteCommand(unmuted: Bool) {
        guard systemAudioMutePhase == .unmuting else {
            log("output unmute completion ignored: unexpected phase")
            return
        }
        if unmuted {
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            log("output unmuted")
        } else {
            // Stay "muted": the marker + watchdog remain armed, the
            // next recording's release retries the unmute, and the
            // watchdog recovers if we exit first.
            systemAudioMutePhase = .muted
            log("output unmute failed; crash-recovery marker left in place")
        }
    }

    private func startSystemAudioMuteWatchdog() throws {
        stopSystemAudioMuteWatchdog()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            systemAudioMuteWatchdogScript(),
            "dictor-audio-watchdog",
            "\(getpid())",
            systemAudioMuteMarkerURL().path,
        ]
        proc.environment = systemToolProcessEnvironment()
        try proc.run()
        systemAudioMuteWatchdog = proc
    }

    private func stopSystemAudioMuteWatchdog() {
        guard let proc = systemAudioMuteWatchdog else { return }
        if proc.isRunning {
            proc.terminate()
        }
        systemAudioMuteWatchdog = nil
    }

    // Uses the synchronous SystemAudio calls deliberately: this runs
    // once from applicationDidFinishLaunching, before the event tap
    // exists, so a main-thread AppleScript round-trip cannot stall
    // keystrokes here.
    private func recoverStaleSystemAudioMuteIfNeeded() {
        let marker = systemAudioMuteMarkerURL()
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let pid = systemAudioMuteMarkerProcessID(from: text),
           pid != getpid(),
           Darwin.kill(pid, 0) == 0 {
            log("output mute recovery deferred: marker belongs to active process \(pid)")
            return
        }

        if SystemAudio.isMuted() {
            if SystemAudio.unmute() {
                log("output unmuted after interrupted recording")
            } else {
                log("output unmute after interrupted recording failed")
            }
        } else {
            log("stale output mute marker removed")
        }
        removeSystemAudioMuteMarker(at: marker)
    }

    private func scheduleMaxDurationAutoRelease() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            // Не handleRelease(): автостоп срабатывает без человека — чаще
            // всего это забытая toggle-запись, и вставка вылила бы
            // расшифровку комнаты туда, где остался курсор. Текст уходит
            // только в «Историю», а капсула объясняет, где его искать.
            log("max recording duration reached, stopping without insertion")
            self.recoverActiveRecordingToHistory(reason: "max recording duration") { [weak self] outcome in
                self?.signalMaxDurationStop(outcome)
            }
        }
        maxDurationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MAX_RECORDING_SECONDS, execute: work)
    }

    private func signalMaxDurationStop(_ outcome: DictationRecoveryOutcome) {
        guard !isTerminating else { return }
        let message = maxDurationStopMessage(outcome: outcome,
                                             limitMinutes: Int(MAX_RECORDING_SECONDS) / 60,
                                             language: settings.interfaceLanguage)
        if outcome == .failed {
            // Звук ошибки уже сыграл внутри recoverActiveRecordingToHistory —
            // здесь только уточняется текст капсулы, без второго сигнала.
            flashErrorFeedback(message: message,
                               holdSeconds: PASTE_NEVER_READ_FLASH_SECONDS)
        } else {
            signalDictationFailure(message: message,
                                   holdSeconds: PASTE_NEVER_READ_FLASH_SECONDS)
        }
    }

    func cancelMaxDurationAutoRelease() {
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
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
