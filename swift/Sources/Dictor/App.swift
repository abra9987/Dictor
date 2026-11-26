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
    private var setupChecklistWindow: NSWindow?
    private var setupChecklistRefreshTimer: Timer?
    private var hotkeyTestSucceeded = false
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

    private var correctionSyncTimer: Timer?
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
    private var isApplyingCorrectionSyncFile = false
    /// Serial queue for the periodic sync-file scan (validate + hash
    /// + read). The UI recommends putting the sync file in iCloud
    /// Drive, where open(2) on a dataless file can block for seconds
    /// while the content downloads — far too long for the main
    /// thread, which also services the session-wide hotkey event tap.
    /// `correctionSyncScanInFlight` (main-actor) guarantees scans
    /// never overlap; results hop back to the main actor, where the
    /// existing merge/apply logic runs unchanged.
    private static let correctionSyncScanQueue = DispatchQueue(label: "DictorCorrectionSyncScan",
                                                               qos: .utility)
    private var correctionSyncScanInFlight = false
    /// Scan request that arrived while a scan was in flight; re-issued
    /// (with the strongest flags seen) when the in-flight scan lands.
    private var pendingCorrectionSyncScan: (force: Bool, presentErrors: Bool)?

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

    /// Двойной клик по файлу `.dictor-corrections` в Finder. Полный
    /// словарный UI живёт в окне, но файл LaunchServices приносит агенту —
    /// поэтому здесь остаётся маленький локализованный диалог поверх той же
    /// логики слияния, что и в окне.
    private func importCorrectionsFromOpenedFile(_ url: URL) -> Bool {
        showAppForModal()
        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            let normalized = normalizedTranscriptCorrections(imported.corrections)
            guard !normalized.isEmpty else {
                showCorrectionTransferError(
                    title: t("В файле нет автозамен", "No Text Corrections Found"),
                    message: t("В файле «\(url.lastPathComponent)» нет ни одной автозамены.",
                               "\(url.lastPathComponent) does not contain any corrections to import."))
                return false
            }
            let summary = correctionImportSummary(existing: settings.transcriptCorrections,
                                                  imported: normalized)
            let countText = correctionImportCountText(sourceName: url.lastPathComponent,
                                                      originalCount: imported.originalCount,
                                                      keptCount: summary.total,
                                                      language: settings.interfaceLanguage)
            let capWarning = correctionImportMergeCapWarningText(
                existingCount: settings.transcriptCorrections.count,
                newCount: summary.newCount,
                language: settings.interfaceLanguage)
            let alert = NSAlert()
            alert.messageText = t("Импортировать автозамены?", "Import Text Corrections?")
            alert.informativeText = t("""
                \(countText)

                Новых: \(summary.newCount) · обновят существующие: \(summary.updatedCount) · уже совпадают: \(summary.unchangedCount).

                «Объединить» сохранит записи этого Mac, которых нет в файле. «Заменить все» сделает словарь точной копией файла.\(capWarning.map { "\n\n" + $0 } ?? "")
                """, """
                \(countText)

                \(summary.newCount) new, \(summary.updatedCount) will update existing corrections, \(summary.unchangedCount) already match.

                Merge keeps local corrections that are not in the file. Replace All makes this Mac match the file exactly.\(capWarning.map { "\n\n" + $0 } ?? "")
                """)
            alert.addButton(withTitle: t("Объединить", "Merge"))
            alert.addButton(withTitle: t("Заменить все", "Replace All"))
            alert.addButton(withTitle: t("Отмена", "Cancel"))
            let mode: CorrectionImportChoice
            switch alert.runModal() {
            case .alertFirstButtonReturn: mode = .merge
            case .alertSecondButtonReturn: mode = .replace
            default: return false
            }
            let next = transcriptCorrections(afterApplying: normalized,
                                             to: settings.transcriptCorrections,
                                             mode: mode)
            updateTranscriptCorrections(next)
            log("correction import read \(normalized.count) corrections from an opened file")
            return true
        } catch {
            showCorrectionTransferError(title: t("Импорт не удался", "Import Failed"),
                                        error: error)
            return false
        }
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

    // MARK: - History

    private func importDictationUsageFromLogIfNeeded() {
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

    @objc private func historyClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        copyHistoryText(s)
    }

    private func copyHistoryText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("history copied to clipboard (\(text.count) chars)")
    }

    @objc private func quitClicked(_ sender: NSMenuItem) {
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

    @objc private func cancelRecordingClicked(_ sender: NSMenuItem) {
        cancelActiveRecording(reason: "menu")
    }

    @objc private func copyDiagnosticsClicked(_ sender: NSMenuItem) {
        copyDiagnosticsToClipboard()
    }

    private func copyDiagnosticsToClipboard() {
        let text = diagnosticsText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("diagnostics copied to clipboard")
    }

    @objc private func saveDiagnosticsClicked(_ sender: NSMenuItem) {
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

    @objc private func reportProblemClicked(_ sender: NSMenuItem) {
        showAppForModal()
        ProblemReport.share(diagnostics: diagnosticsText(),
                            anchor: statusItem.button,
                            language: settings.interfaceLanguage)
    }

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

    private func menuStatusTitle() -> String {
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

    @objc private func retryStartupClicked(_ sender: NSMenuItem) {
        startStartup(reason: "manual retry")
    }

    // MARK: - Setup checklist

    @objc private func showSetupChecklistClicked(_ sender: NSMenuItem) {
        showSetupChecklist()
    }

    private func showSetupChecklist() {
        NSApp.setActivationPolicy(.regular)
        showAppForModal()
        if let window = setupChecklistWindow {
            updateSetupChecklist()
            window.makeKeyAndOrderFront(nil)
            startSetupChecklistRefreshTimer()
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Set Up Dictor"
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupChecklistWindow = window

        updateSetupChecklist()
        window.center()
        window.makeKeyAndOrderFront(nil)
        startSetupChecklistRefreshTimer()
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

    private func startSetupChecklistRefreshTimer() {
        guard setupChecklistRefreshTimer == nil else { return }
        setupChecklistRefreshTimer = Timer.scheduledTimer(timeInterval: 1,
                                                          target: self,
                                                          selector: #selector(setupChecklistTimerFired(_:)),
                                                          userInfo: nil,
                                                          repeats: true)
        setupChecklistRefreshTimer?.tolerance = 0.25
    }

    private func stopSetupChecklistRefreshTimer() {
        setupChecklistRefreshTimer?.invalidate()
        setupChecklistRefreshTimer = nil
    }

    @objc private func setupChecklistTimerFired(_ timer: Timer) {
        guard setupChecklistWindow?.isVisible == true else {
            stopSetupChecklistRefreshTimer()
            return
        }
        updateSetupChecklist()
    }

    private func updateSetupChecklist() {
        guard let window = setupChecklistWindow else { return }
        window.contentView = makeSetupChecklistView()
        rebuildMenu()
    }

    private func makeSetupChecklistView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        // NSStackView on macOS uses NSLayoutConstraint.Attribute for
        // alignment and has no `.fill` case (UIKit-only). With
        // `.leading` every child hugged its own content, so the
        // right-edge Status / Grant column drifted between rows and
        // the NSBox separators — which have no intrinsic width —
        // collapsed to zero. After assembly we explicitly constrain
        // each arranged subview to the inner content width so
        // everything lines up at the same right edge.
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = setupLabel("Set Up Dictor", font: .systemFont(ofSize: 22, weight: .semibold))
        let subtitle = setupLabel("Finish these checks before dictating. Dictor keeps this setup local to your Mac.",
                                  font: .systemFont(ofSize: 13),
                                  color: .secondaryLabelColor)
        subtitle.preferredMaxLayoutWidth = 476
        root.addArrangedSubview(title)
        root.addArrangedSubview(subtitle)
        root.addArrangedSubview(setupSeparator())

        root.addArrangedSubview(makeSpeechModelSetupRow())
        root.addArrangedSubview(makeAudioInputSetupRow())

        for permission in Permission.allCases {
            root.addArrangedSubview(makePermissionSetupRow(permission))
        }

        root.addArrangedSubview(makeHotkeySetupRow())

        if !setupChecklistIsComplete {
            let tip = setupLabel("Tip: If clicking 'Grant' doesn't open a prompt or show Dictor in System Settings, click 'Try Again' — Dictor will reset its macOS privacy permission entry and re-request, which clears stuck macOS state.",
                                 font: .systemFont(ofSize: 11),
                                 color: .secondaryLabelColor)
            tip.preferredMaxLayoutWidth = 476
            root.addArrangedSubview(tip)
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let summary = setupLabel(setupChecklistSummary(),
                                 font: .systemFont(ofSize: 12),
                                 color: .secondaryLabelColor)
        let close = NSButton(title: setupChecklistIsComplete ? "Done" : "Close",
                             target: self,
                             action: #selector(closeSetupChecklistClicked(_:)))
        close.bezelStyle = .rounded

        footer.addArrangedSubview(summary)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(close)
        footer.setHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(setupSeparator())
        root.addArrangedSubview(footer)

        // Force every arranged subview to fill the inner content width
        // (root width minus left + right insets). Without this the row
        // NSStackViews hug their content and the right-aligned Status /
        // Grant column drifts between rows; the NSBox separators have
        // no intrinsic width and collapse entirely.
        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        return container
    }

    private var setupChecklistIsComplete: Bool {
        isSpeechModelReady
            && isReady
            && missingPermissions().isEmpty
    }

    private func setupChecklistSummary() -> String {
        setupChecklistIsComplete
            ? "Setup is complete. Use Dictor from the Dock or shortcuts."
            : "You can close this window; the menu will keep tracking setup."
    }

    private func makeSpeechModelSetupRow() -> NSView {
        // Строка называет модель, которая загружена на самом деле: пока
        // текущая скачивается, это модель прошлой версии.
        let state = speechModelSetupRowState(profile: isRunningOnPreviousSpeechModel
                                                ? SpeechModelPackage.previous.profile
                                                : settings.speechModelProfile,
                                             isSpeechModelReady: isSpeechModelReady,
                                             isStartupInProgress: startupTask != nil || isSwitchingSpeechModel,
                                             startupStatusTitle: startupStatusTitle,
                                             failure: startupFailure)

        return makeSetupChecklistRow(title: "Speech model",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func makeAudioInputSetupRow() -> NSView {
        let state = audioInputSetupRowState(isSpeechModelReady: isSpeechModelReady,
                                            isCoreRuntimeReady: isCoreRuntimeReady,
                                            isStartupInProgress: startupTask != nil || isRestartingAudioInput,
                                            startupStatusTitle: startupStatusTitle,
                                            failure: startupFailure)
        return makeSetupChecklistRow(title: "Audio input",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func makePermissionSetupRow(_ permission: Permission) -> NSView {
        let granted = Permissions.isGranted(permission)
        let clicks = permClickCount[permission] ?? 0
        return makeSetupChecklistRow(title: permission.rawValue,
                                     detail: setupDetail(for: permission),
                                     status: granted ? "Granted" : "Missing",
                                     buttonTitle: granted ? nil : (clicks >= 1 ? "Try Again" : "Grant"),
                                     action: granted ? nil : #selector(grantSetupPermissionClicked(_:)),
                                     tag: Permission.allCases.firstIndex(of: permission) ?? -1)
    }

    private func makeHotkeySetupRow() -> NSView {
        let state = hotkeySetupRowState(isReady: isReady,
                                        hotkeyTestSucceeded: hotkeyTestSucceeded,
                                        triggerMode: settings.triggerMode,
                                        hotkeyName: hotkey.hotkey.name,
                                        failure: startupFailure)

        return makeSetupChecklistRow(title: "Hotkey",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func setupDetail(for permission: Permission) -> String {
        switch permission {
        case .microphone:
            return "Captures your voice while dictating. Click 'Grant', then click 'OK' in the macOS prompt."
        case .accessibility:
            return "Pastes the transcript at your cursor. Click 'Grant' to open System Settings → Privacy & Security → Accessibility, then enable the toggle next to 'Dictor'."
        case .inputMonitoring:
            return "Lets Dictor detect the dictation hotkey. Click 'Grant' to open System Settings → Privacy & Security → Input Monitoring, then enable the toggle next to 'Dictor'."
        }
    }

    private func makeSetupChecklistRow(title: String,
                                       detail: String,
                                       status: String,
                                       buttonTitle: String? = nil,
                                       action: Selector? = nil,
                                       tag: Int = 0) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        textStack.addArrangedSubview(setupLabel(title, font: .systemFont(ofSize: 13, weight: .semibold)))
        
        let detailLabel = setupLabel(detail, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = (buttonTitle != nil) ? 310 : 380
        textStack.addArrangedSubview(detailLabel)

        let statusLabel = setupLabel(status,
                                     font: .systemFont(ofSize: 12, weight: .medium),
                                     color: setupStatusColor(status))
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(statusLabel)

        if let buttonTitle, let action {
            let button = NSButton(title: buttonTitle, target: self, action: action)
            button.bezelStyle = .rounded
            button.tag = tag
            button.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }

        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func setupLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func setupStatusColor(_ status: String) -> NSColor {
        switch status {
        case "Granted", "Ready", "Detected", "Set":
            return .systemGreen
        case "Missing", "Needs retry", "Required":
            return .systemOrange
        default:
            return .secondaryLabelColor
        }
    }

    private func setupSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func closeSetupChecklistClicked(_ sender: NSButton) {
        setupChecklistWindow?.close()
    }

    @objc private func retryStartupFromSetupClicked(_ sender: NSButton) {
        startStartup(reason: "setup checklist retry")
    }

    @objc private func grantSetupPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        requestPermissionFromMenu(Permission.allCases[sender.tag])
    }

    // MARK: - Permission row + click-twice-to-reset

    private func buildPermissionItem(_ p: Permission) -> NSMenuItem {
        let clicks = permClickCount[p] ?? 0
        let name = localizedPermissionTitle(p, language: settings.interfaceLanguage)
        let title: String
        if clicks >= 1 {
            // First click already happened; permission still denied,
            // so signal explicitly that a second click will reset
            // any stuck TCC state and re-request.
            title = t("⚠ Разрешить «\(name)» (ещё раз — сбросит зависшее состояние)…",
                      "⚠ Grant \(name) (try again — will reset stuck state)…")
        } else {
            title = t("⚠ Разрешить «\(name)»…", "⚠ Grant \(name) permission…")
        }
        let item = NSMenuItem(title: title,
                              action: #selector(grantPermissionClicked(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = p.rawValue
        return item
    }

    @objc private func grantPermissionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = Permission(rawValue: raw) else { return }
        requestPermissionFromMenu(p)
    }

    private func requestPermissionFromMenu(_ p: Permission) {
        if Permissions.isGranted(p) {
            permClickCount[p] = nil
            log("perm click ignored: \(p.rawValue) already granted")
            completeReadinessIfPossible(reason: "permission already granted")
            return
        }

        let clicks = (permClickCount[p] ?? 0) + 1
        permClickCount[p] = clicks
        log("perm click #\(clicks): \(p.rawValue)")

        if clicks >= 2 {
            // Click #2+: scrub TCC before re-requesting. The most
            // common cause of "I clicked Grant but nothing happened"
            // is a stuck TCC entry that survived an upgrade. The
            // re-request happens in the reset's completion — issuing
            // it before tccutil finished would race the scrub it
            // depends on.
            log("  resetting TCC for \(p.rawValue) before retry")
            TCC.reset(p, bundleID: Bundle.main.bundleIdentifier ?? "com.raul.dictor") { [weak self] in
                guard let self, !self.isTerminating else { return }
                Permissions.request(p)
                self.startPermissionReadinessMonitor(reason: "permission grant")
                self.updateSetupChecklist()
                self.rebuildMenu()
            }
            rebuildMenu()
            return
        }
        Permissions.request(p)
        startPermissionReadinessMonitor(reason: "permission grant")
        updateSetupChecklist()
        rebuildMenu()
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

    private func updateTranscriptCorrections(_ corrections: [TranscriptCorrection],
                                             writeToSync: Bool = true) {
        if let error = settings.storeTranscriptCorrections(normalizedTranscriptCorrections(corrections)) {
            // The previous value is still in place. Surface the failed
            // save like export/sync-write failures do — silently
            // dropping the user's edit looked like data loss.
            showCorrectionTransferError(title: "Saving Corrections Failed", error: error)
            rebuildMenu()
            return
        }
        if writeToSync, !isApplyingCorrectionSyncFile {
            writeCorrectionsToSyncFile(presentErrors: false)
        }
        rebuildMenu()
    }

    private func correctionSyncFileURL() -> URL? {
        let path = settings.transcriptCorrectionsSyncFile
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Все записи пути синхронизации из самой службы идут здесь: наблюдатель
    /// настроек сверяет путь с прошлым тиком, и собственную запись он должен
    /// увидеть уже «своей», иначе примет её за внешнюю и перезапустит цикл.
    private func setCorrectionSyncFilePath(_ path: String) {
        settings.transcriptCorrectionsSyncFile = path
        lastSeenCorrectionSyncFilePath = settings.transcriptCorrectionsSyncFile
    }

    func startCorrectionSyncIfConfigured() {
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        guard correctionSyncFileURL() != nil else {
            correctionSyncFileFingerprint = nil
            correctionSyncBaselineCorrections = []
            return
        }

        scheduleCorrectionSyncScan(force: true, presentErrors: false)
        // The timer always starts; if the initial async scan rejects
        // the path it stops the sync (and this timer) from its
        // main-actor completion.
        correctionSyncTimer = Timer.scheduledTimer(timeInterval: 4,
                                                   target: self,
                                                   selector: #selector(correctionSyncTimerFired(_:)),
                                                   userInfo: nil,
                                                   repeats: true)
        correctionSyncTimer?.tolerance = 1
    }

    @objc private func correctionSyncTimerFired(_ timer: Timer) {
        scheduleCorrectionSyncScan(force: false, presentErrors: false)
    }

    /// What a background sync-file scan found. Built off the main
    /// thread, applied on the main actor — so it must be Sendable and
    /// carry everything the apply step needs.
    private enum CorrectionSyncScanOutcome: Sendable {
        case rejectedPath(TranscriptCorrectionsSyncPathError)
        case fingerprintUnavailable
        case unchanged
        case loaded(corrections: [TranscriptCorrection], fingerprint: CorrectionSyncFileFingerprint)
        case readFailed(logDescription: String, alertMessage: String)
    }

    /// Runs on `correctionSyncScanQueue` (hence `nonisolated`). Pure
    /// with respect to app state: everything it needs arrives as
    /// parameters and the result goes back as a value.
    private nonisolated static func performCorrectionSyncScan(url: URL,
                                                  lastFingerprint: CorrectionSyncFileFingerprint?,
                                                  force: Bool) -> CorrectionSyncScanOutcome {
        do {
            try validateCorrectionSyncPath(url)
        } catch let error as TranscriptCorrectionsSyncPathError {
            return .rejectedPath(error)
        } catch {
            // validateCorrectionSyncPath only throws
            // TranscriptCorrectionsSyncPathError today; keep the
            // catch-all defensive rather than crashing the scan.
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
        guard let fingerprint = correctionSyncFingerprint(for: url) else {
            return .fingerprintUnavailable
        }
        guard force || fingerprint != lastFingerprint else { return .unchanged }
        do {
            let corrections = try TranscriptCorrectionsTransfer.read(from: url)
            return .loaded(corrections: corrections, fingerprint: fingerprint)
        } catch {
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
    }

    private func scheduleCorrectionSyncScan(force: Bool, presentErrors: Bool) {
        guard let url = correctionSyncFileURL() else { return }
        // Never let scans overlap — a dataless iCloud file can block
        // one scan for many timer periods. Requests that arrive while
        // a scan is in flight are coalesced (strongest flags win) and
        // re-issued when it completes, so a user's explicit
        // "Sync Corrections Now" is never silently dropped behind a
        // stalled timer scan.
        guard !correctionSyncScanInFlight else {
            let pending = pendingCorrectionSyncScan
            pendingCorrectionSyncScan = (force: (pending?.force ?? false) || force,
                                         presentErrors: (pending?.presentErrors ?? false) || presentErrors)
            return
        }
        correctionSyncScanInFlight = true
        let lastFingerprint = correctionSyncFileFingerprint
        Self.correctionSyncScanQueue.async { [weak self] in
            let outcome = Self.performCorrectionSyncScan(url: url,
                                                         lastFingerprint: lastFingerprint,
                                                         force: force)
            Task { @MainActor in
                guard let self else { return }
                self.correctionSyncScanInFlight = false
                self.applyCorrectionSyncScanOutcome(outcome,
                                                    scannedURL: url,
                                                    scanStartFingerprint: lastFingerprint,
                                                    force: force,
                                                    presentErrors: presentErrors)
                if let pending = self.pendingCorrectionSyncScan {
                    self.pendingCorrectionSyncScan = nil
                    self.scheduleCorrectionSyncScan(force: pending.force,
                                                    presentErrors: pending.presentErrors)
                }
            }
        }
    }

    private func applyCorrectionSyncScanOutcome(_ outcome: CorrectionSyncScanOutcome,
                                                scannedURL: URL,
                                                scanStartFingerprint: CorrectionSyncFileFingerprint?,
                                                force: Bool,
                                                presentErrors: Bool) {
        // The sync file may have been disconnected or repointed while
        // the scan ran; results for a stale path must not touch
        // current state.
        guard let url = correctionSyncFileURL(), url == scannedURL else { return }

        switch outcome {
        case .rejectedPath(let error):
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
        case .fingerprintUnavailable:
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed",
                                            message: "Dictor could not find the selected sync file.")
            }
        case .unchanged:
            break
        case .loaded(let corrections, let fingerprint):
            // If a local edit wrote the sync file (moving the
            // fingerprint) while the scan ran, this outcome holds
            // pre-edit content; applying it would roll the edit back
            // and rewind the baseline. Drop it — a forced scan is
            // re-issued so a "Sync Now" still completes against the
            // post-edit file.
            guard correctionSyncFileFingerprint == scanStartFingerprint else {
                if force {
                    scheduleCorrectionSyncScan(force: true, presentErrors: presentErrors)
                }
                return
            }
            // Non-forced scans only apply genuinely new content
            // (forced scans deliberately re-apply even an unchanged
            // file — that is what "Sync Now" promises).
            guard force || fingerprint != correctionSyncFileFingerprint else { return }
            isApplyingCorrectionSyncFile = true
            updateTranscriptCorrections(corrections, writeToSync: false)
            isApplyingCorrectionSyncFile = false
            correctionSyncFileFingerprint = fingerprint
            correctionSyncBaselineCorrections = normalizedTranscriptCorrections(corrections)
            log("correction sync read \(corrections.count) corrections")
        case .readFailed(let logDescription, let alertMessage):
            log("correction sync read failed: \(logDescription)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", message: alertMessage)
            }
        }
    }

    @discardableResult
    func writeCorrectionsToSyncFile(presentErrors: Bool) -> Bool {
        guard let url = correctionSyncFileURL() else { return true }
        do {
            try validateCorrectionSyncPath(url)
        } catch {
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
            return false
        }
        do {
            var correctionsToWrite = normalizedTranscriptCorrections(settings.transcriptCorrections)
            if let knownFingerprint = correctionSyncFileFingerprint,
               let currentFingerprint = correctionSyncFingerprint(for: url),
               currentFingerprint != knownFingerprint {
                let remoteCorrections = try TranscriptCorrectionsTransfer.read(from: url)
                let merge = mergedTranscriptCorrectionsForSync(
                    base: correctionSyncBaselineCorrections,
                    local: correctionsToWrite,
                    remote: remoteCorrections
                )
                if !merge.conflictingSources.isEmpty {
                    stopCorrectionSyncAfterConflict(conflictingSources: merge.conflictingSources)
                    log("correction sync stopped after \(merge.conflictingSources.count) conflicting corrections")
                    return false
                }
                // Normalize (cap) the merge result BEFORE it fans out:
                // file, settings, and baseline must all hold the same
                // list. A raw over-cap merge result stored as baseline
                // made capped-out entries look like local deletions on
                // the next merge, silently removing them from the file.
                correctionsToWrite = normalizedTranscriptCorrections(merge.corrections)
                if let storeError = settings.storeTranscriptCorrections(correctionsToWrite) {
                    throw storeError
                }
            }

            let writtenData = try TranscriptCorrectionsTransfer.write(correctionsToWrite, to: url)
            // Fingerprint the exact bytes written, not a re-read of the
            // file: a sync provider replacing the file in the re-read
            // window would have its change fingerprinted as ours and
            // swallowed until the next local edit.
            correctionSyncFileFingerprint = correctionSyncFingerprint(forWrittenData: writtenData, at: url)
            correctionSyncBaselineCorrections = correctionsToWrite
            log("correction sync wrote \(correctionsToWrite.count) corrections")
            return true
        } catch {
            log("correction sync write failed: \(error)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return false
        }
    }

    private func handleCorrectionSyncRejectedPath(_ error: Error, presentErrors: Bool) {
        log("correction sync rejected path: \(error)")
        guard shouldStopCorrectionSync(afterPathValidationError: error) else {
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return
        }

        stopCorrectionSyncAfterRejectedPath(error: error, presentErrors: presentErrors)
    }

    private func stopCorrectionSyncAfterConflict(conflictingSources: [String]) {
        setCorrectionSyncFilePath("")
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()

        let exampleCount = min(conflictingSources.count, 3)
        let examples = conflictingSources.prefix(exampleCount).joined(separator: "\n")
        let remaining = conflictingSources.count - exampleCount
        let remainingText = remaining > 0 ? "\n…and \(remaining) more." : ""
        showAppForModal()
        showCorrectionTransferError(
            title: "Text Correction Sync Conflict",
            message: """
            The sync file changed before this Mac wrote its latest text correction edits. Dictor kept the corrections on this Mac and stopped syncing so it would not overwrite the file.

            Reconnect the sync file after importing or resolving the conflicting correction\(conflictingSources.count == 1 ? "" : "s"):
            \(examples)\(remainingText)
            """
        )
    }

    private func stopCorrectionSyncAfterRejectedPath(error: Error, presentErrors: Bool) {
        setCorrectionSyncFilePath("")
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        log("correction sync stopped after rejected path")
        rebuildMenu()

        if presentErrors {
            showCorrectionTransferError(
                title: "Text Correction Sync Stopped",
                message: """
                Dictor stopped syncing because the selected corrections file is no longer safe to use.

                \(error.localizedDescription)
                """
            )
        }
    }

    private func showCorrectionTransferError(title: String, error: Error) {
        showCorrectionTransferError(title: title, message: error.localizedDescription)
    }

    private func showCorrectionTransferError(title: String, message: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
