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


enum ControlPanelServiceOperation: String, Sendable {
    case starting
    case restarting
    case stopping
    case applyingSettings
}

enum ControlPanelShortcutKind: Int {
    case dictation = 0
    case alternateCompletion = 1
    case history = 2
}

struct ControlPanelSettingsDraft: Equatable {
    var dictationHotkey: HotkeyChoice
    var alternateCompletionHotkey: HotkeyChoice
    var historyHotkey: HotkeyChoice
    var primaryCompletionBehavior: DictationCompletionBehavior
    var alternateCompletionEnabled: Bool
    var enterDelayMilliseconds: Int
    var recordingColor: RecordingHUDAccentColor
    var transcribingColor: RecordingHUDAccentColor
    var backgroundStyle: RecordingHUDBackgroundStyle
    var hudSize: RecordingHUDSize

    init(settings: Settings) {
        dictationHotkey = settings.configuredHotkey
        alternateCompletionHotkey = settings.configuredEnterHotkey
        historyHotkey = settings.configuredHistoryHotkey
        primaryCompletionBehavior = settings.primaryCompletionBehavior
        alternateCompletionEnabled = settings.alternateCompletionEnabled
        enterDelayMilliseconds = settings.enterDelayMilliseconds
        recordingColor = settings.recordingHUDRecordingColor
        transcribingColor = settings.recordingHUDTranscribingColor
        backgroundStyle = settings.recordingHUDBackgroundStyle
        hudSize = settings.recordingHUDSize
    }
}

func hotkeysConflict(_ lhs: HotkeyChoice, _ rhs: HotkeyChoice) -> Bool {
    lhs.keycode == rhs.keycode && lhs.requiredModifiers == rhs.requiredModifiers
}

func hotkeyIsModifierPrefix(_ prefix: HotkeyChoice,
                                    of shortcut: HotkeyChoice) -> Bool {
    guard prefix.isModifier,
          prefix.requiredModifiers.isEmpty,
          let prefixMask = prefix.modifierFlag else { return false }
    if shortcut.isModifier {
        return shortcut.requiredModifiers.contains(prefixMask)
    }
    return shortcut.requiredModifiers.contains(prefixMask)
}

enum ControlPanelUpdateState: Equatable, Sendable {
    case checking
    case upToDate(String)
    case available(GitHubRelease)
    case preparing(version: String, phase: String)
    case failed(String)
}

@MainActor
final class DictorControlPanelApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var refreshTimer: Timer?
    private var serviceOperation: ControlPanelServiceOperation?
    private var updateTask: Task<Void, Never>?
    private var updateState: ControlPanelUpdateState = .checking
    private var lastRenderFingerprint = ""
    private let settings = Settings.shared
    private var permissionClickCount: [Permission: Int] = [:]
    private var settingsDraft: ControlPanelSettingsDraft?
    var settingsTab = "general"
    private var hotkeyRecorder: HotkeyRecorderController?
    private let onboarding = OnboardingController()
    private var mainHistorySearch = ""
    private weak var mainHistorySearchField: NSSearchField?
    /// Раздел главного окна (макет 6a): «Сегодня» открывается первым.
    var mainSection: MainWindowSection = .today
    /// Выбранная запись в «Истории» и фильтр «Закреплённые» (макет 6b).
    private var historySelectionKey: String?
    private var historyShowsPinnedOnly = false

    private var language: InterfaceLanguage { settings.interfaceLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if DictorControlPanelRegistry.activateExistingPanelIfPresent() {
            NSApp.terminate(nil)
            return
        }
        DictorControlPanelRegistry.claimCurrentPanel()
        showWindow()
        startRefreshTimer()
        checkForUpdates()
        if settings.agentEnabled && !DictorAgentService.isAgentRunning() {
            beginServiceOperation(.starting)
        }
        onboarding.showIfNeeded(
            force: CommandLine.arguments.contains("--onboarding"))
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyRecorder?.cancel()
        hotkeyRecorder = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        updateTask?.cancel()
        updateTask = nil
        DictorControlPanelRegistry.clearCurrentPanel()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow === settingsWindow {
            hotkeyRecorder?.cancel()
            hotkeyRecorder = nil
            settingsWindow = nil
            settingsDraft = nil
            return
        }
        if closingWindow === window {
            settingsWindow?.orderOut(nil)
            settingsWindow = nil
            NSApp.terminate(nil)
        }
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    private func showWindow() {
        if let window {
            refresh(force: true)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Макет 6a: окно 980×664, сайдбар уходит под тайтлбар, поэтому
        // контент занимает всю высоту, а кнопки окна лежат поверх сайдбара.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0,
                                                  width: MAIN_WINDOW_SIZE.width,
                                                  height: MAIN_WINDOW_SIZE.height),
                              styleMask: [.titled, .closable, .miniaturizable,
                                          .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "Dictor"
        window.contentMinSize = MAIN_WINDOW_SIZE
        window.contentMaxSize = MAIN_WINDOW_SIZE
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = SD.C.sidebarPaper
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        refresh(force: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRefreshTimer() {
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

    private func refresh(force: Bool = false) {
        guard let window else { return }
        _ = settings.refreshFromDisk()
        let fingerprint = renderFingerprint()
        guard force || fingerprint != lastRenderFingerprint else { return }
        lastRenderFingerprint = fingerprint
        // Вид пересобирается целиком, поэтому фокус и каретку поиска
        // приходится снимать до замены и возвращать после.
        let focusState = capturedSearchFocusState(in: window)
        // Главное окно по макету 6a: сайдбар + раздел. Настройки живут
        // в отдельном окне settingsWindow (макет 2c/4b/6d).
        window.title = "Dictor"
        window.contentView = makeMainWindowView()
        restoreSearchFocus(focusState, in: window)
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.title = t("Настройки Dictor", "Dictor Settings")
            settingsWindow.contentView = makeSettingsContentView()
            if let contentView = settingsWindow.contentView {
                resizeSettingsWindowToFit(settingsWindow, contentView: contentView)
            }
        }
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
        let newestHistory = settings.recentTranscriptEntries.first
        return [language.rawValue,
                "section:\(mainSection.rawValue)",
                "history:\(settings.recentTranscriptEntries.count):" +
                    "\(newestHistory?.createdAt?.timeIntervalSince1970 ?? 0)",
                "search:\(mainHistorySearch)",
                serviceOperation?.rawValue ?? "idle",
                updateStateFingerprint(),
                DictorAgentService.isAgentRunning() ? "running" : "stopped",
                stateToken,
                permissions,
                settings.configuredHotkey.name,
                settings.configuredEnterHotkey.name,
                settings.configuredHistoryHotkey.name,
                settings.primaryCompletionBehavior.rawValue,
                settings.alternateCompletionEnabled ? "alternate-on" : "alternate-off",
                settings.triggerMode.rawValue,
                settings.recordingHUDRecordingColor.rawValue,
                settings.recordingHUDTranscribingColor.rawValue,
                settings.recordingHUDBackgroundStyle.rawValue,
                settings.recordingHUDSize.rawValue,
                permissionClickCount.description].joined(separator: "::")
    }

    private func updateStateFingerprint() -> String {
        switch updateState {
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


    func makeSettingsContentView() -> NSView {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        // Макет: контент padding 6px 24px 20px, вертикальные отступы
        // живут внутри строк (13px), между строками — только hairline.
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsTabBar())
        let tabsHairline = SDHairlineView()
        root.addArrangedSubview(tabsHairline)
        root.setCustomSpacing(6, after: tabsHairline)
        switch settingsTab {
        case "hotkeys":
            addHotkeyTabRows(to: root, draft: draft)
        case "model":
            addModelTabRows(to: root)
        case "dict":
            addDictTabRows(to: root)
        case "look":
            addLookTabRows(to: root, draft: draft)
        case "privacy":
            addPrivacyTabRows(to: root)
        default:
            addGeneralTabRows(to: root, draft: draft)
        }

        let background = PaperBackgroundView()
        background.fill = SD.C.settingsPaper
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }
        return background
    }

    /// Высота окна под контент вкладки, как в макете (min-height 330 у
    /// контентной зоны). Меньше не сжимаем, чтобы окно не «прыгало».
    static func settingsContentHeight(for view: NSView, width: CGFloat = 620) -> CGFloat {
        guard let root = view.subviews.first as? NSStackView else { return 404 }
        // Фиксируем ширину, чтобы fittingSize мерил высоту при реальной
        // ширине окна (многострочные подписи).
        let widthPin = root.widthAnchor.constraint(equalToConstant: width)
        widthPin.isActive = true
        root.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize.height
        widthPin.isActive = false
        return max(404, ceil(fitting))
    }

    private func resizeSettingsWindowToFit(_ window: NSWindow, contentView: NSView) {
        let height = Self.settingsContentHeight(for: contentView)
        let size = NSSize(width: 620, height: height)
        guard window.contentView?.frame.size.height != height else { return }
        let topY = window.frame.maxY
        window.contentMinSize = size
        window.contentMaxSize = size
        window.setContentSize(size)
        var frame = window.frame
        frame.origin.y = topY - frame.height
        window.setFrame(frame, display: true)
    }

    // MARK: - Вкладки настроек (дизайн 2c, адаптировано)

    private func settingsTabBar() -> NSView {
        let wrapper = NSView()
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 2
        let tabs = [("general", t("Основное", "General")),
                    ("hotkeys", t("Хоткеи", "Hotkeys")),
                    ("model", t("Модель", "Model")),
                    ("dict", t("Словарь", "Dictionary")),
                    ("look", t("Внешний вид", "Appearance")),
                    ("privacy", t("Приватность", "Privacy"))]
        // Макет: таб padding 5px 12px, радиус 7, шрифт 12; активный —
        // 600, ink, пилюля rgba(0,0,0,.08)/rgba(255,255,255,.1);
        // неактивный — 400 graphite. Ряд: padding 10px 0.
        for (id, title) in tabs {
            let button = SDTabButton(title: title, target: self,
                                     action: #selector(settingsTabClicked(_:)))
            button.isBordered = false
            button.isActiveTab = settingsTab == id
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true
            let textWidth = ceil(title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]).width)
            button.widthAnchor.constraint(equalToConstant: textWidth + 24).isActive = true
            bar.addArrangedSubview(button)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(bar)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 47),
            bar.centerXAnchor.constraint(equalTo: wrapper.centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
        ])
        return wrapper
    }

    @objc private func settingsTabClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        settingsTab = id
        refresh(force: true)
    }

    private func addGeneralTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        let missingPermissions = Permission.allCases.filter { !Permissions.isGranted($0) }
        if !missingPermissions.isEmpty {
            root.addArrangedSubview(compactPermissionsCard())
        }

        let running = DictorAgentService.isAgentRunning()
        let serviceToggle = SDToggle()
        serviceToggle.isOn = running && settings.agentEnabled
        serviceToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            if enabled {
                self.startAgentClicked(NSButton())
            } else {
                self.stopAgentClicked(NSButton())
                self.refresh(force: true)
            }
        }
        root.addArrangedSubview(SDRowView(
            title: t("Запускать при входе в систему", "Launch at login"),
            subtitle: t("Служба стартует тихо, без окон", "The service starts silently, no windows"),
            control: serviceToggle
        ))

        let langPills = SDPills(options: [
            .init(title: "RU", value: DictationLanguage.russian.rawValue),
            .init(title: "EN", value: DictationLanguage.english.rawValue),
            .init(title: t("Авто", "Auto"), value: DictationLanguage.auto.rawValue),
        ], selected: settings.dictationLanguage.rawValue)
        langPills.onSelect = { [weak self] raw in
            guard let language = DictationLanguage(rawValue: raw) else { return }
            self?.settings.dictationLanguage = language
        }
        root.addArrangedSubview(SDRowView(
            title: t("Язык распознавания", "Dictation language"),
            control: langPills
        ))

        let microphonePopup = NSPopUpButton()
        microphonePopup.addItem(withTitle: t("Системный по умолчанию", "System default"))
        microphonePopup.lastItem?.representedObject = ""
        let devices = availableAudioInputDevices()
        let saved = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        for device in devices {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.uid
        }
        if let index = microphonePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == saved
        }) {
            microphonePopup.selectItem(at: index)
        }
        microphonePopup.target = self
        microphonePopup.action = #selector(selectMicrophoneFromPanel(_:))
        root.addArrangedSubview(SDRowView(
            title: t("Микрофон", "Microphone"),
            subtitle: t("Если пропадёт — вернёмся к встроенному",
                        "Falls back to the built-in mic if it disappears"),
            control: SDFieldButton(popup: microphonePopup)
        ))

        let completionPills = SDPills(options: [
            .init(title: t("Ничего", "Nothing"), value: DictationCompletionBehavior.insert.rawValue),
            .init(title: t("Нажать Enter", "Press Enter"),
                  value: DictationCompletionBehavior.insertAndEnter.rawValue),
        ], selected: settings.primaryCompletionBehavior.rawValue)
        completionPills.onSelect = { [weak self] raw in
            guard let behavior = DictationCompletionBehavior(rawValue: raw) else { return }
            self?.settings.primaryCompletionBehavior = behavior
        }
        root.addArrangedSubview(SDRowView(
            title: t("После вставки текста", "After inserting text"),
            control: completionPills
        ))

        let delayStepper = SDStepperRow(value: settings.enterDelayMilliseconds,
                                        step: 20,
                                        range: 0...2000,
                                        suffix: "ms")
        delayStepper.onChange = { [weak self] value in
            self?.settings.enterDelayMilliseconds = value
        }
        root.addArrangedSubview(SDRowView(
            title: t("Задержка перед Enter", "Delay before Enter"),
            subtitle: t("Пауза между вставкой и подтверждением",
                        "Pause between inserting and confirming"),
            control: delayStepper
        ))

        let soundsToggle = SDToggle()
        soundsToggle.isOn = settings.playFeedbackSounds
        soundsToggle.onToggle = { [weak self] enabled in
            self?.settings.playFeedbackSounds = enabled
        }
        root.addArrangedSubview(SDRowView(
            title: t("Звуки", "Sounds"),
            subtitle: t("Сигналы начала, конца и ошибки диктовки",
                        "Cues for start, finish and errors"),
            control: soundsToggle,
            hairline: false
        ))
    }

    @objc private func selectMicrophoneFromPanel(_ sender: NSPopUpButton) {
        settings.inputDevice = (sender.selectedItem?.representedObject as? String) ?? ""
    }

    private func addHotkeyTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        root.addArrangedSubview(SDRowView(
            title: t("Начать / остановить диктовку", "Start / stop dictation"),
            control: hotkeyControl(shortcut: draft.dictationHotkey, kind: .dictation)
        ))
        root.addArrangedSubview(SDRowView(
            title: t("Открыть историю", "Open history"),
            control: hotkeyControl(shortcut: draft.historyHotkey, kind: .history)
        ))
        root.addArrangedSubview(SDRowView(
            title: t("Альтернативное завершение", "Alternative finish"),
            subtitle: t("Завершает диктовку противоположным действием",
                        "Finishes dictation with the opposite action"),
            control: hotkeyControl(shortcut: draft.alternateCompletionHotkey, kind: .alternateCompletion)
        ))
        let actions = settingsActionsRow(draft: draft)
        root.addArrangedSubview(actions)
        root.setCustomSpacing(14, after: actions)
        let hint = panelLabel(t("Клик по «Изменить» — поле слушает клавиши. Esc отменяет.",
                                "Click “Change” and press the new combo. Esc cancels."),
                              size: 11, color: SD.C.graphite)
        root.addArrangedSubview(hint)
    }

    private func hotkeyControl(shortcut: HotkeyChoice, kind: ControlPanelShortcutKind) -> NSView {
        let caps = SDKeycaps(keys: keycapLabels(for: shortcut, language: language))
        let change = NSButton(title: t("Изменить", "Change"),
                              target: self,
                              action: #selector(recordDictationShortcutClicked(_:)))
        change.isBordered = false
        change.font = .systemFont(ofSize: 11)
        change.contentTintColor = SD.C.graphite
        change.tag = kind.rawValue
        let stack = NSStackView(views: [caps, change])
        stack.orientation = .horizontal
        stack.spacing = 11
        return stack
    }

    private func addModelTabRows(to root: NSStackView) {
        let active = settings.speechModelProfile
        for profile in SpeechModelProfile.allCases {
            let isActive = profile == active
            let detail: String
            switch profile {
            case .multilingualV3:
                detail = t("~460 МБ · русский, английский и ещё 17 языков · Neural Engine",
                           "~460 MB · Russian, English and 17 more · Neural Engine")
            default:
                detail = t("Устаревший профиль, только английский",
                           "Deprecated profile, English only")
            }
            let card = SDModelCard(
                title: profile.shortName + (isActive ? " · " + t("используется", "in use") : ""),
                detail: detail,
                active: isActive,
                actionTitle: isActive ? "✓ " + t("Активна", "Active") : t("Выбрать", "Select"),
                target: self,
                action: isActive ? nil : #selector(selectSpeechModelFromPanel(_:)),
                identifier: profile.rawValue
            )
            root.addArrangedSubview(card)
        }
        if let lastCard = root.arrangedSubviews.last {
            root.setCustomSpacing(12, after: lastCard)
        }
        let note = panelLabel(t("Смена модели перезапустит службу; новая модель докачается сама.",
                                "Switching restarts the service; the model downloads itself."),
                              size: 11, color: SD.C.graphite)
        root.addArrangedSubview(note)
    }

    @objc private func selectSpeechModelFromPanel(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let profile = SpeechModelProfile(rawValue: raw) else { return }
        settings.speechModelProfile = profile
        restartAgentClicked(NSButton())
        refresh(force: true)
    }

    private func addDictTabRows(to root: NSStackView) {
        let addButton = NSButton(title: "+ " + t("Добавить", "Add"),
                                 target: self,
                                 action: #selector(addCorrectionFromPanel(_:)))
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 12, weight: .semibold)
        addButton.contentTintColor = SD.C.voice
        let headerRow = NSStackView(views: [
            panelLabel(t("Автозамены после распознавания", "Corrections applied after transcription"),
                       size: 12, color: SD.C.graphite),
            NSView(),
            addButton,
        ])
        headerRow.orientation = .horizontal
        headerRow.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 10, right: 0)
        root.addArrangedSubview(headerRow)

        let corrections = settings.transcriptCorrections
        if corrections.isEmpty {
            root.addArrangedSubview(panelLabel(
                t("Пока пусто. Добавьте термины, которые модель слышит неправильно.",
                  "Empty so far. Add terms the model keeps mishearing."),
                size: 12, color: SD.C.graphite))
        }
        // Макет: строка словаря — padding 10px 0, слово 13px ink слева,
        // приглушённая аннотация 11px справа, hairline снизу.
        for (index, correction) in corrections.prefix(8).enumerated() {
            let annotation = panelLabel("«\(correction.source)»", size: 11, color: SD.C.subtle)
            let remove = NSButton(title: "✕", target: self,
                                  action: #selector(removeCorrectionFromPanel(_:)))
            remove.isBordered = false
            remove.font = .systemFont(ofSize: 11)
            remove.contentTintColor = SD.C.graphite
            remove.tag = index
            let right = NSStackView(views: [annotation, remove])
            right.orientation = .horizontal
            right.spacing = 10
            root.addArrangedSubview(SDRowView(
                title: correction.replacement,
                control: right,
                verticalPadding: 10
            ))
        }
        if corrections.count > 8 {
            root.addArrangedSubview(panelLabel(
                t("…и ещё \(corrections.count - 8). Полный список — в сервисном меню.",
                  "…and \(corrections.count - 8) more. Full list in the service menu."),
                size: 11, color: SD.C.subtle))
        }

        let fillerToggle = SDToggle()
        fillerToggle.isOn = settings.removeFillerWords
        fillerToggle.onToggle = { [weak self] enabled in
            self?.settings.removeFillerWords = enabled
        }
        root.addArrangedSubview(SDRowView(
            title: t("Убирать слова-паразиты", "Remove filler words"),
            subtitle: t("«Эээ», «ммм» и подобное исчезают из текста",
                        "“Uh”, “um” and similar vanish from the text"),
            control: fillerToggle,
            hairline: false
        ))
    }

    @objc private func addCorrectionFromPanel(_ sender: NSButton) {
        let alert = NSAlert()
        alert.messageText = t("Новая автозамена", "New correction")
        alert.informativeText = t("Что слышит модель — и что должно быть в тексте.",
                                  "What the model hears — and what the text should say.")
        let sourceField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        sourceField.placeholderString = t("слышится («супер диктант»)", "heard (“super dictate”)")
        let replacementField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        replacementField.placeholderString = t("должно быть (Dictor)", "should be (Dictor)")
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        holder.addSubview(sourceField)
        holder.addSubview(replacementField)
        alert.accessoryView = holder
        alert.addButton(withTitle: t("Добавить", "Add"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else { return }
        let next = normalizedTranscriptCorrections(
            settings.transcriptCorrections + [TranscriptCorrection(source: source,
                                                                   replacement: replacement)]
        )
        settings.transcriptCorrections = next
        refresh(force: true)
    }

    @objc private func removeCorrectionFromPanel(_ sender: NSButton) {
        var corrections = settings.transcriptCorrections
        guard corrections.indices.contains(sender.tag) else { return }
        corrections.remove(at: sender.tag)
        settings.transcriptCorrections = corrections
        refresh(force: true)
    }

    private func addPrivacyTabRows(to root: NSStackView) {
        // Витрина: волна + главное обещание продукта.
        let wave = QuickPanelWaveView()
        wave.isActive = true
        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.widthAnchor.constraint(equalToConstant: 60).isActive = true
        wave.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let headline = panelLabel(t("Ваш голос не покидает этот Mac",
                                    "Your voice never leaves this Mac"),
                                  size: 15, weight: .bold)
        let sub = panelLabel(
            t("Запись, распознавание и история живут локально. Интернет нужен один раз — скачать модель.",
              "Recording, transcription and history live locally. The internet is needed once — to download the model."),
            size: 12, color: SD.C.graphite)
        sub.maximumNumberOfLines = 2
        sub.alignment = .center
        sub.preferredMaxLayoutWidth = 380
        let showcase = NSStackView(views: [wave, headline, sub])
        showcase.orientation = .vertical
        showcase.alignment = .centerX
        showcase.spacing = 8
        // Макет: витрина padding 22px 0 18px + hairline снизу.
        showcase.edgeInsets = NSEdgeInsets(top: 22, left: 0, bottom: 18, right: 0)
        root.addArrangedSubview(showcase)
        showcase.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -48).isActive = true
        root.addArrangedSubview(SDHairlineView())

        root.addArrangedSubview(SDRowView(
            title: t("Сетевые запросы", "Network requests"),
            control: monoValueLabel(t("0 — обновления отключены", "0 — updates disabled")),
            verticalPadding: 12
        ))

        let limitPills = SDPills(options: RecentTranscriptLimit.allCases.map {
            .init(title: localizedTranscriptLimitName($0), value: $0.rawValue)
        }, selected: settings.recentTranscriptLimit.rawValue)
        limitPills.onSelect = { [weak self] raw in
            guard let limit = RecentTranscriptLimit(rawValue: raw) else { return }
            self?.settings.recentTranscriptLimit = limit
        }
        root.addArrangedSubview(SDRowView(
            title: t("Хранить историю", "Keep history"),
            subtitle: t("Локальный список последних диктовок", "A local list of recent dictations"),
            control: limitPills,
            verticalPadding: 12
        ))

        // Макет: значение здесь обычным шрифтом 12/500, не mono.
        let audioRow = SDRowView(
            title: t("Аудио после распознавания", "Audio after transcription"),
            control: panelLabel(t("Удаляется сразу", "Deleted immediately"),
                                size: 12, weight: .medium),
            verticalPadding: 12
        )
        root.addArrangedSubview(audioRow)
        root.setCustomSpacing(14, after: audioRow)

        let showModels = NSButton(title: t("Показать файлы моделей…", "Show model files…"),
                                  target: self, action: #selector(revealModelFilesFromPanel(_:)))
        let wipeHistory = NSButton(title: t("Стереть историю…", "Erase history…"),
                                   target: self, action: #selector(eraseHistoryFromPanel(_:)))
        for button in [showModels, wipeHistory] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        showModels.contentTintColor = SD.C.ink
        wipeHistory.contentTintColor = SD.C.voice
        let actions = NSStackView(views: [showModels, wipeHistory, NSView()])
        actions.orientation = .horizontal
        actions.spacing = 16
        root.addArrangedSubview(actions)
    }

    private func monoValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = SD.C.ink
        return label
    }

    private func localizedTranscriptLimitName(_ limit: RecentTranscriptLimit) -> String {
        switch limit {
        case .off: return t("Выкл", "Off")
        case .last1: return "1"
        case .last5: return "5"
        case .last10: return "10"
        }
    }

    @objc private func revealModelFilesFromPanel(_ sender: NSButton) {
        NSWorkspace.shared.activateFileViewerSelecting([speechModelCacheBaseDirectory()])
    }

    @objc private func eraseHistoryFromPanel(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Стереть всю историю диктовок?", "Erase all dictation history?")
        alert.informativeText = t("Действие необратимо. Модель и настройки не затрагиваются.",
                                  "This cannot be undone. The model and settings stay intact.")
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        alert.addButton(withTitle: t("Стереть", "Erase"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        settings.recentTranscriptEntries = []
        refresh(force: true)
    }

    // MARK: - Главное окно: история (макет 2b/4a)

    func makeMainHistoryViewForPreview() -> NSView {
        makeMainHistoryView()
    }

    // MARK: - Каркас главного окна (макет 6a)

    /// Сайдбар 212pt + раздел. Сайдбар уходит под тайтлбар, первые 52pt
    /// оставлены под кнопки окна.
    func makeMainWindowView() -> NSView {
        let sidebar = makeSidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let divider = SDHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content: NSView
        switch mainSection {
        case .today:
            content = makeTodayView()
        case .history:
            content = makeMainHistoryView()
        case .dictionary:
            content = makeDictionarySectionView()
        case .settings:
            // «Настройки» открываются отдельным окном (макет 2c/4b/6d),
            // а раздел остаётся на «Сегодня».
            content = makeTodayView()
        }
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper
        root.addSubview(sidebar)
        root.addSubview(divider)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: MAIN_WINDOW_SIDEBAR_WIDTH),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Сайдбар: пустые 52pt под кнопки окна, навигация, статус службы внизу.
    private func makeSidebarView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.sidebarPaper

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 3
        nav.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        nav.translatesAutoresizingMaskIntoConstraints = false

        let historyCount = settings.recentTranscriptEntries.count
        let dictionaryCount = settings.transcriptCorrections.count
        for section in MainWindowSection.allCases {
            let count: Int?
            switch section {
            case .history: count = historyCount
            case .dictionary: count = dictionaryCount
            default: count = nil
            }
            let item = SDSidebarItemView(section: section,
                                         title: section.title(language),
                                         count: count,
                                         isSelected: section == mainSection
                                             && section != .settings,
                                         target: self,
                                         action: #selector(sidebarItemClicked(_:)))
            item.translatesAutoresizingMaskIntoConstraints = false
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -24).isActive = true
        }

        let status = makeSidebarStatusView()
        status.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(nav)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nav.topAnchor.constraint(equalTo: root.topAnchor,
                                     constant: MAIN_WINDOW_HEADER_HEIGHT),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.topAnchor.constraint(greaterThanOrEqualTo: nav.bottomAnchor),
        ])
        return root
    }

    /// Низ сайдбара: зелёная точка + состояние службы, второй строкой — модель.
    private func makeSidebarStatusView() -> NSView {
        let state = AgentRuntimeStateStore.read()
        let running = DictorAgentService.isAgentRunning()
        let ready = running && state?.status == "ready"

        let dot = SDStatusDotView()
        dot.color = ready ? SD.C.positive : (running ? SD.C.voice : SD.C.subtle)
        dot.translatesAutoresizingMaskIntoConstraints = false

        let title: String
        if !running {
            title = t("Служба остановлена", "Service stopped")
        } else if ready {
            title = t("Готово к диктовке", "Ready to dictate")
        } else {
            title = state?.detail ?? t("Запускается…", "Starting…")
        }
        let titleLabel = panelLabel(title, size: 11.5, color: SD.C.inkSecondary)
        titleLabel.lineBreakMode = .byTruncatingTail

        let head = NSStackView(views: [dot, titleLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        let detail = panelLabel(
            t("Parakeet · локально", "Parakeet · on-device"),
            size: 11, color: SD.C.subtle)
        detail.lineBreakMode = .byTruncatingTail

        let hairline = SDHairlineView()
        let column = NSStackView(views: [hairline, head, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 14, right: 16)
        column.setCustomSpacing(14, after: hairline)
        column.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hairline.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return container
    }

    @objc private func sidebarItemClicked(_ sender: SDSidebarItemView) {
        if sender.section == .settings {
            openSettingsWindow()
            return
        }
        guard sender.section != mainSection else { return }
        mainSection = sender.section
        refresh(force: true)
    }

    // MARK: - Подсказки «Сегодня» (правило макета 6e)

    struct TodayHint {
        let identifier: String
        let text: String
        let actionTitle: String?
        let action: Selector?
    }

    /// Одна подсказка за раз и только когда есть настоящий повод.
    /// Закрытые лежат в `settings.dismissedHints` и не возвращаются.
    private func todayHint() -> TodayHint? {
        let dismissed = Set(settings.dismissedHints)
        let entryCount = settings.recentTranscriptEntries.count

        if entryCount >= 3, !dismissed.contains("history-hotkey") {
            let caps = inlineShortcutText(
                keycapLabels(for: settings.configuredHistoryHotkey, language: language))
            return TodayHint(
                identifier: "history-hotkey",
                text: t("Историю можно открыть поверх любого приложения — \(caps). Не нужно возвращаться в это окно.",
                        "History opens on top of any app — \(caps). No need to come back to this window."),
                actionTitle: t("Показать", "Show"),
                action: #selector(showHistorySectionClicked(_:)))
        }

        if entryCount >= 5, !settings.removeFillerWords,
           !dismissed.contains("filler-removal") {
            return TodayHint(
                identifier: "filler-removal",
                text: t("«Эээ» и «ммм» пока попадают в текст. Включите очистку — они исчезнут ещё до вставки.",
                        "Filler words still land in your text. Turn cleanup on and they go before the paste."),
                actionTitle: t("Включить", "Turn on"),
                action: #selector(enableFillerRemovalFromHint(_:)))
        }
        return nil
    }

    @objc private func dismissTodayHint(_ sender: NSButton) {
        guard let hint = todayHint() else { return }
        settings.dismissedHints.append(hint.identifier)
        refresh(force: true)
    }

    @objc private func enableFillerRemovalFromHint(_ sender: NSButton) {
        settings.removeFillerWords = true
        settings.dismissedHints.append("filler-removal")
        refresh(force: true)
    }

    @objc private func showHistorySectionClicked(_ sender: NSButton) {
        mainSection = .history
        refresh(force: true)
    }

    /// Кнопка «Диктовать» — само действие делает хоткей в агенте, поэтому
    /// окно лишь напоминает, какую комбинацию зажать.
    @objc private func todayDictateHintClicked(_ sender: NSControl) {
        let caps = keycapLabels(for: settings.configuredHotkey, language: language)
            .joined(separator: " + ")
        let alert = NSAlert()
        alert.messageText = t("Диктовка запускается с клавиатуры",
                              "Dictation starts from the keyboard")
        alert.informativeText = t(
            "Поставьте курсор в любое поле ввода и зажмите \(caps). Текст появится там, где стоит курсор.",
            "Put the cursor in any text field and hold \(caps). The text lands where your cursor is.")
        alert.addButton(withTitle: t("Понятно", "Got it"))
        alert.runModal()
    }

    @objc private func todayRecentRowClicked(_ sender: SDRecentEntryRowView) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sender.transcript, forType: .string)
    }

    // MARK: - Раздел «Сегодня» (макет 6a)

    private func makeTodayView() -> NSView {
        let summary = TodaySummary.make(usage: settings.dailyDictationUsage)
        let entries = settings.recentTranscriptEntries

        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        // Шапка раздела: заголовок + кнопка «Диктовать» с хоткеем.
        let header = NSView()
        let headerTitle = panelLabel(MainWindowSection.today.title(language),
                                     size: 14, weight: .semibold)
        let caps = keycapLabels(for: settings.configuredHotkey, language: language)
        let dictateButton = SDPrimaryActionButton(
            title: t("Диктовать", "Dictate"),
            shortcut: caps.joined(separator: " "),
            target: self,
            action: #selector(todayDictateHintClicked(_:)))
        for view in [headerTitle, dictateButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let headerHairline = SDHairlineView()
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerHairline)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dictateButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -28),
            dictateButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        // Приветствие.
        let greeting = panelLabel(t("С возвращением", "Welcome back"),
                                  size: 22, weight: .semibold)
        let subtitle = panelLabel(todayGreetingSubtitle(summary),
                                  size: 13.5, color: SD.C.graphite)
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 56

        // Три карточки показателей.
        let sparkline = QuickPanelStatBars(values: summary.dayBars)
        sparkline.translatesAutoresizingMaskIntoConstraints = false
        sparkline.widthAnchor.constraint(equalToConstant: 7 * 5 - 2).isActive = true
        sparkline.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let wordsCard = SDStatCardView(
            caption: t("Слов сегодня", "Words today"),
            value: formattedUsageInteger(summary.words),
            delta: summary.deltaPercent.map {
                SDStatCardView.Delta(text: $0 >= 0 ? "+\($0)%" : "\($0)%",
                                     isPositive: $0 >= 0)
            },
            accessory: sparkline)

        let savedCard = SDStatCardView(
            caption: t("Сэкономлено", "Time saved"),
            value: "\(summary.savedMinutesToday)",
            unit: t("мин", "min"),
            footnote: todaySavedMonthText(summary))

        let streakDots = SDStreakDotsView(intensities: summary.streakIntensities,
                                          todayActive: summary.todayActive)
        streakDots.translatesAutoresizingMaskIntoConstraints = false
        streakDots.heightAnchor.constraint(equalToConstant: 15).isActive = true
        let streakCard = SDStatCardView(
            caption: t("Дней подряд", "Day streak"),
            value: "\(summary.streakDays)",
            accessory: streakDots)

        let cards = NSStackView(views: [wordsCard, savedCard, streakCard])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false
        // 16 + подпись 13 + 8 + число 36 + 10 + спарклайн 22 + 16 (макет 6a).
        cards.heightAnchor.constraint(equalToConstant: 121).isActive = true

        // «Последние диктовки».
        let recentTitle = panelLabel(t("Последние диктовки", "Recent dictations"),
                                     size: 13, weight: .semibold)
        let allHistory = NSButton(title: t("Вся история", "All history"),
                                  target: self,
                                  action: #selector(showHistorySectionClicked(_:)))
        allHistory.isBordered = false
        allHistory.font = .systemFont(ofSize: 12)
        allHistory.contentTintColor = SD.C.voice
        let recentHeader = NSStackView(views: [recentTitle, allHistory])
        recentHeader.orientation = .horizontal
        recentHeader.alignment = .firstBaseline
        recentHeader.spacing = 10

        let recentCard = makeTodayRecentCard(entries: Array(entries.prefix(3)))

        let column = NSStackView(views: [greeting, subtitle, cards,
                                         recentHeader, recentCard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 24, right: 28)
        column.setCustomSpacing(5, after: greeting)
        column.setCustomSpacing(20, after: subtitle)
        column.setCustomSpacing(24, after: cards)
        column.setCustomSpacing(11, after: recentHeader)

        if let hint = todayHint() {
            let banner = SDHintBannerView(text: hint.text,
                                          actionTitle: hint.actionTitle,
                                          target: self,
                                          action: hint.action,
                                          dismissAction: #selector(dismissTodayHint(_:)))
            column.addArrangedSubview(banner)
            column.setCustomSpacing(18, after: recentCard)
        }

        column.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        for view in [cards, recentHeader, recentCard] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor,
                                        constant: -56).isActive = true
        }
        if let banner = column.arrangedSubviews.last as? SDHintBannerView {
            banner.widthAnchor.constraint(equalTo: column.widthAnchor,
                                          constant: -56).isActive = true
        }
        return root
    }

    // MARK: - Раздел «Словарь»

    /// Словарь в окне (макет 5d). Пометки источника пока нет — провенанс
    /// автозамен не сохраняется, поэтому все записи показаны как ручные.
    private func makeDictionarySectionView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        let addButton = NSButton(title: t("Добавить слово", "Add word"),
                                 target: self,
                                 action: #selector(addCorrectionFromPanel(_:)))
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 12, weight: .semibold)
        addButton.contentTintColor = SD.C.voice
        let header = makeSectionHeader(title: MainWindowSection.dictionary.title(language),
                                       accessory: addButton)

        let corrections = settings.transcriptCorrections
        let card = SDCardBackgroundView()
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false

        if corrections.isEmpty {
            let empty = panelLabel(
                t("Пока пусто. Добавьте термины, которые модель слышит неправильно.",
                  "Empty so far. Add terms the model keeps mishearing."),
                size: 12.5, color: SD.C.graphite)
            let wrapper = NSStackView(views: [empty])
            wrapper.orientation = .vertical
            wrapper.edgeInsets = NSEdgeInsets(top: 22, left: 16, bottom: 22, right: 16)
            list.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        } else {
            for (index, correction) in corrections.enumerated() {
                if index > 0 {
                    let hairline = SDHairlineView()
                    list.addArrangedSubview(hairline)
                    hairline.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                }
                let word = panelLabel(correction.replacement, size: 12.5, color: SD.C.ink)
                let badge = SDBadgeLabel(text: t("вручную", "manual"))
                let heard = panelLabel(t("слышится как «\(correction.source)»",
                                         "heard as “\(correction.source)”"),
                                       size: 11, color: SD.C.subtle)
                let remove = NSButton(title: "✕", target: self,
                                      action: #selector(removeCorrectionFromPanel(_:)))
                remove.isBordered = false
                remove.font = .systemFont(ofSize: 11)
                remove.contentTintColor = SD.C.subtle
                remove.tag = index

                let row = NSStackView(views: [word, badge, heard, NSView(), remove])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 10
                row.edgeInsets = NSEdgeInsets(top: 10, left: 13, bottom: 10, right: 13)
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
        }

        card.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            list.topAnchor.constraint(equalTo: card.topAnchor),
            list.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let column = NSStackView(views: [card])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 24, right: 28)
        column.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        card.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -56).isActive = true
        return root
    }

    /// Шапка раздела: заголовок 14/600 слева, произвольный контрол справа,
    /// hairline снизу (макет 6a/6b).
    private func makeSectionHeader(title: String, accessory: NSView?) -> NSView {
        let header = NSView()
        let titleLabel = panelLabel(title, size: 14, weight: .semibold, color: SD.C.ink)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(titleLabel)
        let hairline = SDHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(hairline)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            titleLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        if let accessory {
            accessory.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(accessory)
            NSLayoutConstraint.activate([
                accessory.trailingAnchor.constraint(equalTo: header.trailingAnchor,
                                                    constant: -28),
                accessory.centerYAnchor.constraint(equalTo: header.centerYAnchor),
                accessory.leadingAnchor.constraint(greaterThanOrEqualTo:
                                                    titleLabel.trailingAnchor, constant: 12),
            ])
        }
        return header
    }

    /// Карточка со списком последних диктовок (или пустое состояние 5f).
    private func makeTodayRecentCard(entries: [TranscriptHistoryEntry]) -> NSView {
        let card = SDCardBackgroundView()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        if entries.isEmpty {
            let empty = makeTodayEmptyState()
            column.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        } else {
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    let hairline = SDHairlineView()
                    column.addArrangedSubview(hairline)
                    hairline.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                }
                let row = SDRecentEntryRowView(
                    transcript: entry.text,
                    preview: entry.text.replacingOccurrences(of: "\n", with: " "),
                    time: recentEntryTimeText(entry),
                    copyTitle: t("Копировать", "Copy"),
                    target: self,
                    action: #selector(todayRecentRowClicked(_:)))
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Пустое состояние по макету 5f: волна, заголовок, что нажать.
    private func makeTodayEmptyState() -> NSView {
        let wave = SDMiniWaveView(values: [0.09, 0.09, 0.09, 0.3, 0.09, 0.09, 0.09],
                                  color: SD.C.subtle,
                                  barWidth: 2,
                                  gap: 2)
        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.widthAnchor.constraint(equalToConstant: 26).isActive = true
        wave.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let title = panelLabel(t("Здесь появятся ваши диктовки",
                                 "Your dictations will show up here"),
                               size: 13, weight: .semibold)
        let caps = keycapLabels(for: settings.configuredHotkey, language: language)
            .joined(separator: " + ")
        let hint = panelLabel(
            t("Откройте любое поле ввода, зажмите \(caps) и скажите пару слов.",
              "Open any text field, hold \(caps) and say a few words."),
            size: 11.5, color: SD.C.graphite)
        hint.alignment = .center
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 300

        let column = NSStackView(views: [wave, title, hint])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 22, right: 20)
        column.setCustomSpacing(10, after: wave)
        column.setCustomSpacing(4, after: title)
        return column
    }

    private func todayGreetingSubtitle(_ summary: TodaySummary) -> String {
        guard summary.words > 0 else {
            return t("Сегодня вы ещё не диктовали. Зажмите хоткей в любом поле ввода — текст появится там, где стоит курсор.",
                     "No dictations today yet. Hold the hotkey in any text field and the text lands where your cursor is.")
        }
        let words = formattedUsageInteger(summary.words)
        if summary.savedMinutesToday >= 1 {
            let minutes = dictationMinutesLabel(summary.savedMinutesToday, language: language)
            return t("За сегодня вы наговорили \(words) слов. Это примерно \(minutes), которые не ушли на клавиатуру.",
                     "You dictated \(words) words today — about \(minutes) that never went to the keyboard.")
        }
        return t("За сегодня вы наговорили \(words) слов.",
                 "You dictated \(words) words today.")
    }

    private func todaySavedMonthText(_ summary: TodaySummary) -> String {
        guard summary.savedHoursMonth >= 0.1 else {
            return t("за месяц пока немного", "not much this month yet")
        }
        let hours = String(format: "%.1f", summary.savedHoursMonth)
            .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
        return t("\(hours) часа за месяц", "\(hours) hours this month")
    }

    private func recentEntryTimeText(_ entry: TranscriptHistoryEntry) -> String {
        guard let createdAt = entry.createdAt else {
            return t("ранее", "earlier")
        }
        let elapsed = Date().timeIntervalSince(createdAt)
        if elapsed < 60 {
            return t("только что", "just now")
        }
        if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return t("\(minutes) мин назад", "\(minutes) min ago")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: createdAt)
    }

    // MARK: - Раздел «История» (макет 6b)

    /// Три колонки: сайдбар (снаружи), список результатов 328pt и
    /// детальный просмотр. Аудио и «как было сказано» из макета не
    /// показываем — запись удаляется сразу, сырой текст не сохраняется.
    private func makeMainHistoryView() -> NSView {
        let entries = filteredMainHistory()
        let selected = selectedHistoryEntry(among: entries)

        let list = makeHistoryListColumn(entries: entries, selected: selected)
        list.translatesAutoresizingMaskIntoConstraints = false
        let divider = SDHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        let detail = makeHistoryDetailPane(selected: selected)
        detail.translatesAutoresizingMaskIntoConstraints = false

        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper
        root.addSubview(list)
        root.addSubview(divider)
        root.addSubview(detail)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            list.widthAnchor.constraint(equalToConstant: 328),
            divider.leadingAnchor.constraint(equalTo: list.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Средняя колонка: поиск, фильтры, счётчик совпадений, список.
    private func makeHistoryListColumn(entries: [(Int, TranscriptHistoryEntry)],
                                       selected: (Int, TranscriptHistoryEntry)?) -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.listPaper

        // Поиск: белое поле 30pt, радиус 8, рамка rgba(0,0,0,.1).
        let searchBox = SDCardBackgroundView()
        searchBox.layer?.cornerRadius = 8
        let magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass",
                                  accessibilityDescription: nil)
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11,
                                                                    weight: .regular)
        magnifier.contentTintColor = SD.C.subtle
        let search = NSSearchField()
        search.placeholderString = t("Искать в истории…", "Search history…")
        search.font = .systemFont(ofSize: 12.5)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.target = self
        search.action = #selector(mainHistorySearchChanged(_:))
        search.stringValue = mainHistorySearch
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        mainHistorySearchField = search
        // Системная лупа-кнопка не нужна: значок нарисован слева по макету.
        (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(magnifier)
        searchBox.addSubview(search)
        NSLayoutConstraint.activate([
            searchBox.heightAnchor.constraint(equalToConstant: 30),
            magnifier.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 11),
            magnifier.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -10),
            search.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
        ])

        // Фильтры. Пилюль по приложениям из макета нет: источник диктовки
        // не сохраняется, поэтому остаются «Все» и «Закреплённые».
        let filters = SDPills(options: [
            .init(title: t("Все", "All"), value: "all"),
            .init(title: t("Закреплённые", "Pinned"), value: "pinned"),
        ], selected: historyShowsPinnedOnly ? "pinned" : "all")
        filters.onSelect = { [weak self] value in
            self?.historyShowsPinnedOnly = value == "pinned"
            self?.refresh(force: true)
        }

        let header = NSStackView(views: [searchBox, filters])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 9
        header.edgeInsets = NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        searchBox.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: "")
        countLabel.attributedStringValue = NSAttributedString(
            string: historyMatchesCaption(count: entries.count).uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: SD.C.subtle,
                .kern: 0.5,
            ])
        let countRow = NSStackView(views: [countLabel])
        countRow.orientation = .vertical
        countRow.alignment = .leading
        countRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 6, right: 14)

        let listStack = NSStackView()
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 3
        listStack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 12, right: 8)
        listStack.translatesAutoresizingMaskIntoConstraints = false

        if entries.isEmpty {
            let empty = panelLabel(
                mainHistorySearch.isEmpty
                    ? t("Пока пусто", "Nothing here yet")
                    : t("Ничего не нашлось", "No matches"),
                size: 12.5, color: SD.C.graphite)
            let wrapper = NSStackView(views: [empty])
            wrapper.orientation = .vertical
            wrapper.alignment = .centerX
            wrapper.edgeInsets = NSEdgeInsets(top: 28, left: 12, bottom: 28, right: 12)
            listStack.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: listStack.widthAnchor,
                                           constant: -16).isActive = true
        }
        let pinned = Set(settings.pinnedTranscripts)
        for (index, entry) in entries {
            let row = SDHistoryResultRow(
                entryIndex: index,
                meta: historyRowMetaText(entry),
                time: recentEntryTimeText(entry),
                text: entry.text.replacingOccurrences(of: "\n", with: " "),
                highlight: mainHistorySearch,
                isPinned: pinned.contains(entry.text),
                isSelected: index == selected?.0,
                target: self,
                action: #selector(historyResultRowClicked(_:)))
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor,
                                       constant: -16).isActive = true
        }

        let documentView = SDFlippedView()
        documentView.addSubview(listStack)
        NSLayoutConstraint.activate([
            listStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        let headerHairline = SDHairlineView()
        let column = NSStackView(views: [header, headerHairline, countRow, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor,
                                        constant: MAIN_WINDOW_HEADER_HEIGHT - 11),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return root
    }

    /// Правая колонка: действия сверху, мета и полный текст диктовки.
    private func makeHistoryDetailPane(selected: (Int, TranscriptHistoryEntry)?) -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        guard let (index, entry) = selected else {
            let empty = makeTodayEmptyState()
            empty.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                empty.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            ])
            return root
        }

        let isPinned = settings.pinnedTranscripts.contains(entry.text)
        let copyButton = SDPrimaryActionButton(title: t("Копировать", "Copy"),
                                               shortcut: "⌘C",
                                               target: self,
                                               action: #selector(copySelectedHistoryEntry(_:)))
        let pinButton = SDSecondaryButton(
            title: isPinned ? t("Открепить", "Unpin") : t("Закрепить", "Pin"),
            target: self,
            action: #selector(togglePinSelectedHistoryEntry(_:)))
        let deleteButton = SDSecondaryButton(title: t("Удалить", "Delete"),
                                             target: self,
                                             action: #selector(deleteSelectedHistoryEntry(_:)))
        deleteButton.tag = index

        let actions = NSStackView(views: [copyButton, pinButton, NSView(), deleteButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        actions.translatesAutoresizingMaskIntoConstraints = false
        let headerHairline = SDHairlineView()
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.addSubview(actions)
        header.addSubview(headerHairline)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            actions.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        let badge = SDMiniWaveView(values: [0.35, 0.8, 0.5, 0.6],
                                   color: SD.C.subtle,
                                   barWidth: 1.5,
                                   gap: 1.5)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 10.5).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let meta = panelLabel(historyDetailMetaText(entry), size: 12, color: SD.C.graphite)
        let metaRow = NSStackView(views: [badge, meta])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 9

        // Полный текст: 16/1.6, выделяемый — его забирают мышью.
        let body = NSTextField(wrappingLabelWithString: entry.text)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.6
        body.attributedStringValue = NSAttributedString(
            string: entry.text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 16),
                .foregroundColor: SD.C.ink,
                .paragraphStyle: paragraph,
            ])
        body.isSelectable = true
        body.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 328 - 44

        let column = NSStackView(views: [metaRow, body])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 22, left: 22, bottom: 22, right: 22)
        column.setCustomSpacing(14, after: metaRow)
        column.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(header)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        return root
    }

    private func historyMatchesCaption(count: Int) -> String {
        guard !mainHistorySearch.trimmingCharacters(in: .whitespaces).isEmpty else {
            return historyShowsPinnedOnly
                ? t("Закреплённые", "Pinned")
                : t("Все диктовки", "All dictations")
        }
        if language == .russian {
            let mod100 = count % 100
            let mod10 = count % 10
            let noun: String
            if (11...14).contains(mod100) {
                noun = "совпадений"
            } else if mod10 == 1 {
                noun = "совпадение"
            } else if (2...4).contains(mod10) {
                noun = "совпадения"
            } else {
                noun = "совпадений"
            }
            return "\(count) \(noun)"
        }
        return count == 1 ? "1 match" : "\(count) matches"
    }

    /// Мета строки списка: длительность распознавания и число слов.
    private func historyRowMetaText(_ entry: TranscriptHistoryEntry) -> String {
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        return dictatedWordsLabel(words, language: language)
    }

    private func historyDetailMetaText(_ entry: TranscriptHistoryEntry) -> String {
        var parts: [String] = []
        if let createdAt = entry.createdAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
            formatter.dateFormat = language == .russian ? "d MMMM, HH:mm" : "MMMM d, h:mm a"
            parts.append(formatter.string(from: createdAt))
        } else {
            parts.append(t("время не сохранилось", "time not recorded"))
        }
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        parts.append(dictatedWordsLabel(words, language: language))
        if let duration = entry.transcriptionDurationSeconds {
            parts.append(String(format: "%.1f %@", duration,
                                localizedText("с", "s", language: language)))
        }
        return parts.joined(separator: " · ")
    }

    /// Ключ выбора переживает пересборку вида и сдвиг индексов.
    private func historyEntryKey(_ entry: TranscriptHistoryEntry) -> String {
        "\(entry.createdAt?.timeIntervalSince1970 ?? 0)|\(entry.text.prefix(64))"
    }

    private func selectedHistoryEntry(among entries: [(Int, TranscriptHistoryEntry)])
        -> (Int, TranscriptHistoryEntry)? {
        if let key = historySelectionKey,
           let match = entries.first(where: { historyEntryKey($0.1) == key }) {
            return match
        }
        return entries.first
    }

    @objc private func historyResultRowClicked(_ sender: SDHistoryResultRow) {
        let entries = settings.recentTranscriptEntries
        guard entries.indices.contains(sender.entryIndex) else { return }
        historySelectionKey = historyEntryKey(entries[sender.entryIndex])
        refresh(force: true)
    }

    @objc private func copySelectedHistoryEntry(_ sender: NSControl) {
        guard let (_, entry) = selectedHistoryEntry(among: filteredMainHistory()) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
    }

    @objc private func togglePinSelectedHistoryEntry(_ sender: NSControl) {
        guard let (_, entry) = selectedHistoryEntry(among: filteredMainHistory()) else { return }
        var pinned = settings.pinnedTranscripts
        if let existing = pinned.firstIndex(of: entry.text) {
            pinned.remove(at: existing)
        } else {
            pinned.insert(entry.text, at: 0)
        }
        settings.pinnedTranscripts = pinned
        refresh(force: true)
    }

    @objc private func deleteSelectedHistoryEntry(_ sender: NSControl) {
        deleteMainHistoryEntry(at: sender.tag)
    }

    private func filteredMainHistory() -> [(Int, TranscriptHistoryEntry)] {
        let query = mainHistorySearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var indexed = Array(settings.recentTranscriptEntries.enumerated())
        if historyShowsPinnedOnly {
            let pinned = Set(settings.pinnedTranscripts)
            indexed = indexed.filter { pinned.contains($0.1.text) }
        }
        guard !query.isEmpty else { return indexed }
        return indexed.filter { $0.1.text.lowercased().contains(query) }
    }

    @objc private func mainHistorySearchChanged(_ sender: NSSearchField) {
        mainHistorySearch = sender.stringValue
        refresh(force: true)
    }

    private func deleteMainHistoryEntry(at index: Int) {
        var entries = settings.recentTranscriptEntries
        guard entries.indices.contains(index) else { return }
        let removed = entries.remove(at: index)
        settings.recentTranscriptEntries = entries
        if historySelectionKey == historyEntryKey(removed) {
            historySelectionKey = nil
        }
        refresh(force: true)
    }

    private func addLookTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        // Макет: секция «Размер капсулы» — заголовок 13px + три карточки
        // с мини-превью (padding 14px 0 10px, hairline снизу).
        let sizeTitle = panelLabel(t("Размер капсулы", "Capsule size"), size: 13)
        sizeTitle.textColor = SD.C.ink
        let sizeNames: [(RecordingHUDSize, String)] = [
            (.compact, t("Компактный", "Compact")),
            (.standard, t("Обычный", "Standard")),
            (.large, t("Крупный", "Large")),
        ]
        var sizeCards: [SDCapsuleSizeCard] = []
        for (size, name) in sizeNames {
            let card = SDCapsuleSizeCard(title: name,
                                         kind: size.rawValue,
                                         selected: settings.recordingHUDSize == size)
            card.onSelect = { [weak self] raw in
                guard let self, let size = RecordingHUDSize(rawValue: raw) else { return }
                self.settings.recordingHUDSize = size
                for other in sizeCards {
                    other.setSelected(false)
                }
                card.setSelected(true)
            }
            sizeCards.append(card)
        }
        let cardsRow = NSStackView(views: sizeCards)
        cardsRow.orientation = .horizontal
        cardsRow.spacing = 10
        cardsRow.distribution = .fillEqually
        let sizeSection = NSStackView(views: [sizeTitle, cardsRow])
        sizeSection.orientation = .vertical
        sizeSection.alignment = .leading
        sizeSection.spacing = 10
        sizeSection.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 10, right: 0)
        cardsRow.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(sizeSection)
        cardsRow.widthAnchor.constraint(equalTo: sizeSection.widthAnchor).isActive = true
        root.addArrangedSubview(SDHairlineView())

        let backgroundPills = SDPills(options: RecordingHUDBackgroundStyle.allCases.map {
            .init(title: localizedBackgroundName($0), value: $0.rawValue)
        }, selected: settings.recordingHUDBackgroundStyle.rawValue)
        backgroundPills.onSelect = { [weak self] raw in
            guard let style = RecordingHUDBackgroundStyle(rawValue: raw) else { return }
            self?.settings.recordingHUDBackgroundStyle = style
        }
        root.addArrangedSubview(SDRowView(
            title: t("Фон капсулы", "Capsule background"),
            control: backgroundPills
        ))

        // Макет: кружки-свотчи 22px вместо пилюль с названиями.
        let swatches = SDColorSwatches(
            swatches: RecordingHUDAccentColor.allCases.map {
                .init(value: $0.rawValue, color: $0.nsColor)
            },
            selected: settings.recordingHUDRecordingColor.rawValue
        )
        swatches.onSelect = { [weak self] raw in
            guard let color = RecordingHUDAccentColor(rawValue: raw) else { return }
            self?.settings.recordingHUDRecordingColor = color
        }
        root.addArrangedSubview(SDRowView(
            title: t("Цвет волны", "Wave color"),
            subtitle: t("Один цвет для записи и бренда", "One color for recording and brand"),
            control: swatches,
            hairline: false
        ))
    }





    private func compactPermissionsCard() -> NSView {
        let missing = Permission.allCases.filter { !Permissions.isGranted($0) }
        let card = compactCard()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let color: NSColor = missing.isEmpty ? .systemGreen : .systemOrange
        header.addArrangedSubview(panelSymbol(missing.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                              color: color,
                                              description: t("Разрешения macOS", "macOS permissions"),
                                              pointSize: 15))
        header.addArrangedSubview(panelLabel(t("Разрешения macOS", "macOS permissions"),
                                             size: 12.5,
                                             weight: .semibold))
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(panelLabel(
            missing.isEmpty ? t("Все выданы", "All granted")
                            : t("Нужно: \(missing.count)", "Missing: \(missing.count)"),
            size: 11.5,
            weight: .medium,
            color: color
        ))
        content.addArrangedSubview(header)

        if missing.isEmpty {
            let ready = panelLabel(
                t("Микрофон, вставка текста и глобальный хоткей доступны.",
                  "Microphone, text insertion, and the global shortcut are available."),
                size: 11,
                color: .secondaryLabelColor
            )
            ready.toolTip = t("Dictor получил все три необходимых разрешения macOS.",
                              "Dictor has all three required macOS permissions.")
            content.addArrangedSubview(ready)
        } else {
            for permission in missing {
                content.addArrangedSubview(compactPermissionRow(permission))
            }
        }
        pin(content, inside: card, horizontal: 13, vertical: 10)
        return card
    }

    private func compactPermissionRow(_ permission: Permission) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let title = panelLabel(permissionTitle(permission), size: 11.5, weight: .medium)
        title.toolTip = permissionDetail(permission)
        let buttonTitle = (permissionClickCount[permission] ?? 0) >= 1
            ? t("Повторить", "Try Again") : t("Разрешить", "Grant")
        let button = panelButton(buttonTitle,
                                 action: #selector(grantPermissionClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: t("Открыть системное разрешение: \(permissionTitle(permission))",
                                            "Open the system permission: \(permissionTitle(permission))"))
        button.controlSize = .small
        button.tag = Permission.allCases.firstIndex(of: permission) ?? -1
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(button)
        return row
    }


    private func compactUpdatePresentation() -> (symbol: String,
                                                   color: NSColor,
                                                   title: String,
                                                   detail: String,
                                                   buttonTitle: String?,
                                                   action: Selector?,
                                                   buttonEnabled: Bool,
                                                   buttonToolTip: String?) {
        switch updateState {
        case .checking:
            return ("arrow.triangle.2.circlepath", .systemBlue,
                    t("Проверяю обновления", "Checking for updates"),
                    t("Установлена v\(currentBundleVersion())", "Installed v\(currentBundleVersion())"),
                    nil, nil, false, nil)
        case .upToDate:
            return ("checkmark.circle.fill", .systemGreen,
                    t("Dictor актуален", "Dictor is up to date"),
                    t("Установлена последняя версия v\(currentBundleVersion())",
                      "Latest version v\(currentBundleVersion()) is installed"),
                    t("Проверить", "Check"), #selector(updateButtonClicked(_:)), true,
                    t("Проверить GitHub Releases ещё раз", "Check GitHub Releases again"))
        case .available(let release):
            return ("arrow.down.circle.fill", .systemBlue,
                    t("Доступна версия v\(release.version)", "Version v\(release.version) is available"),
                    t("Скачается, проверится и установится автоматически",
                      "Downloads, verifies, and installs automatically"),
                    t("Обновить", "Update"), #selector(updateButtonClicked(_:)), serviceOperation == nil,
                    t("Обновить Dictor до v\(release.version) одной кнопкой",
                      "Update Dictor to v\(release.version) with one click"))
        case .preparing(let version, let phase):
            return ("arrow.down.circle", .systemBlue,
                    t("Обновляю до v\(version)", "Updating to v\(version)"),
                    phase, nil, nil, false, nil)
        case .failed(let message):
            return ("exclamationmark.triangle.fill", .systemRed,
                    t("Обновление не проверено", "Update check failed"),
                    message,
                    t("Повторить", "Retry"), #selector(updateButtonClicked(_:)), true,
                    t("Повторить проверку обновлений", "Retry the update check"))
        }
    }


    private func operationTitle(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting: return t("Запускаю службу диктовки", "Starting dictation service")
        case .restarting: return t("Перезапускаю фоновую службу", "Restarting background service")
        case .stopping: return t("Останавливаю фоновую службу", "Stopping background service")
        case .applyingSettings: return t("Применяю настройки и перезапускаю службу",
                                         "Applying settings and restarting service")
        }
    }

    private func operationDetail(_ operation: ControlPanelServiceOperation) -> String {
        switch operation {
        case .starting:
            return t("Подключаю глобальный хоткей и локальную модель.\nОбычно 1–3 секунды; при первой загрузке дольше.",
                     "Enabling the global shortcut and local model.\nUsually 1–3 seconds; the first download takes longer.")
        case .restarting, .applyingSettings:
            return t("Диктовка временно недоступна. Панель не зависла — новый воркер уже запускается.",
                     "Dictation is temporarily unavailable. The panel is responsive while the new worker starts.")
        case .stopping:
            return t("Хоткей перестанет работать, но настройки и история сохранятся.",
                     "The shortcut will stop; settings and history remain saved.")
        }
    }

    private func servicePresentation(running: Bool,
                                     state: AgentRuntimeState?) -> (status: String, detail: String, color: NSColor) {
        if let operation = serviceOperation {
            return (operationTitle(operation), operationDetail(operation), .systemBlue)
        }
        if running, let state {
            if ["ready", "recording", "transcribing"].contains(state.status) {
                return (t("Работает", "Running"),
                        t("Фоновая служба включена.", "The background service is running."),
                        .systemGreen)
            }
            return (displayStatus(state.status), localizedServiceDetail(state), colorForStatus(state.status))
        }
        if running {
            return (t("Запускается", "Starting"),
                    t("Фоновый процесс запущен и готовит модель.", "The background process is preparing the model."),
                    .systemOrange)
        }
        return (settings.agentEnabled ? t("Остановлена", "Stopped") : t("Выключена", "Off"),
                t("Хоткей не работает, пока служба не запущена.",
                  "The shortcut is unavailable until the service starts."),
                settings.agentEnabled ? .systemRed : .secondaryLabelColor)
    }

    private func checkForUpdates() {
        updateTask?.cancel()
        updateState = .checking
        refresh(force: true)
        updateTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled, let self else { return }
            self.updateTask = nil
            switch outcome {
            case .success(let release):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckVersion = release.version
                if isNewer(release.version, than: currentBundleVersion()) {
                    self.settings.lastUpdateCheckResult = .available
                    self.updateState = .available(release)
                } else {
                    self.settings.lastUpdateCheckResult = .upToDate
                    self.updateState = .upToDate(currentBundleVersion())
                }
            case .failure(let failure):
                self.settings.lastUpdateCheckAt = Date()
                self.settings.lastUpdateCheckSource = .manual
                self.settings.lastUpdateCheckResult = .failed
                self.updateState = .failed(self.localizedUpdateFailure(failure))
            }
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
        }
    }

    private func localizedUpdateFailure(_ failure: UpdateCheckFailure) -> String {
        guard language == .russian else { return manualUpdateCheckFailureText(failure) }
        switch failure {
        case .network:
            return "Не удалось связаться с GitHub. Проверьте интернет и повторите попытку."
        case .httpStatus(403):
            return "GitHub временно ограничил проверку обновлений. Повторите через несколько минут."
        case .httpStatus(let code):
            return "GitHub вернул ошибку HTTP \(code). Повторите попытку позже."
        case .unexpectedResponse:
            return "GitHub вернул ответ, который Dictor не смог проверить."
        }
    }

    private func beginInAppUpdate(for release: GitHubRelease) {
        guard updateTask == nil else { return }
        let version = release.version
        updateState = .preparing(
            version: version,
            phase: t("Получаю защищённый манифест обновления…",
                     "Fetching the verified update manifest…")
        )
        refresh(force: true)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await DictorUpdateInstaller.fetchManifest(
                    expectedVersion: version
                )
                guard !Task.isCancelled else { return }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("Скачиваю архив и проверяю SHA-256…",
                                  "Downloading the archive and verifying SHA-256…")
                )
                self.refresh(force: true)
                let prepared = try await DictorUpdateInstaller.prepare(manifest: manifest)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.workDirectory)
                    return
                }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("Архив проверен. Запускаю установку…",
                                  "The archive is verified. Starting installation…")
                )
                self.refresh(force: true)
                try self.launchPreparedUpdate(prepared)
            } catch {
                self.updateTask = nil
                let message = (error as? DictorUpdateInstallerError)?
                    .message(language: self.language) ?? error.localizedDescription
                self.updateState = .failed(message)
                self.lastRenderFingerprint = ""
                self.refresh(force: true)
            }
        }
    }

    private func launchPreparedUpdate(_ prepared: PreparedDictorUpdate) throws {
        let statePath = try createPrivateUpdateProgressStateFile()
        let helperLog = try openPrivateUpdateHelperLog()
        let appURL = Bundle.main.bundleURL
        let backupURL = appURL.deletingLastPathComponent()
            .appendingPathComponent(".Dictor-update-backup-\(UUID().uuidString).app",
                                    isDirectory: true)
        let script = superDictateDirectUpdateHelperScript(
            pid: getpid(),
            targetVersion: prepared.version,
            statePath: statePath,
            stagedAppPath: prepared.stagedAppURL.path,
            workDirectory: prepared.workDirectory.path,
            backupAppPath: backupURL.path,
            appPath: appURL.path,
            language: language
        )
        let helperPath = try writePrivateUpdateHelperScript(script)

        let progressAppPath: String
        do {
            progressAppPath = try launchUpdateProgressApp(
                statePath: statePath,
                logPath: helperLog.path,
                targetVersion: prepared.version
            )
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            helperLog.handle.closeFile()
            throw error
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [helperPath]
        process.environment = systemToolProcessEnvironment()
        process.standardOutput = helperLog.handle
        process.standardError = helperLog.handle
        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(atPath: helperPath)
            try? FileManager.default.removeItem(atPath: statePath)
            try? FileManager.default.removeItem(at: prepared.workDirectory)
            try? FileManager.default.removeItem(atPath: progressAppPath)
            helperLog.handle.closeFile()
            throw error
        }

        updateTask = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NSApp.terminate(nil)
        }
    }

    private func launchUpdateProgressApp(statePath: String,
                                         logPath: String,
                                         targetVersion: String) throws -> String {
        let sourceAppURL = Bundle.main.bundleURL
        guard sourceAppURL.pathExtension == "app",
              let executableName = Bundle.main.executableURL?.lastPathComponent else {
            throw posixError(EINVAL)
        }
        let progressAppURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).app",
                                    isDirectory: true)
        try FileManager.default.copyItem(at: sourceAppURL, to: progressAppURL)
        let executableURL = progressAppURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(executableName)
        let process = Process()
        process.executableURL = executableURL
        process.arguments = [
            UPDATE_PROGRESS_ARGUMENT,
            statePath,
            logPath,
            targetVersion,
            progressAppURL.path,
        ]
        process.environment = systemToolProcessEnvironment()
        do {
            try process.run()
            return progressAppURL.path
        } catch {
            try? FileManager.default.removeItem(at: progressAppURL)
            throw error
        }
    }

    private func statusRow(title: String,
                           detail: String,
                           status: String,
                           statusColor: NSColor,
                           buttonTitle: String? = nil,
                           action: Selector? = nil,
                           tag: Int = 0,
                           buttonEnabled: Bool = true,
                           toolTip: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        let detailLabel = panelLabel(detail, size: 12, color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 440
        text.addArrangedSubview(detailLabel)

        let statusLabel = panelLabel(status, size: 12, weight: .medium, color: statusColor)
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(statusLabel)
        if let buttonTitle, let action {
            let button = panelButton(buttonTitle,
                                     action: action,
                                     enabled: buttonEnabled,
                                     toolTip: toolTip)
            button.tag = tag
            row.addArrangedSubview(button)
        }
        return row
    }

    private func hotkeyRow(title: String,
                           shortcut: HotkeyChoice,
                           kind: ControlPanelShortcutKind,
                           toolTip: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        row.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        row.addArrangedSubview(NSView())
        let button = panelButton(localizedHotkeyName(shortcut, language: language),
                                 action: #selector(recordDictationShortcutClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: toolTip)
        button.tag = kind.rawValue
        button.controlSize = .regular
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true
        row.addArrangedSubview(button)
        return row
    }

    private func primaryCompletionBehaviorRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(t("Повторное нажатие", "Press again"),
                                           size: 13,
                                           weight: .semibold))
        text.addArrangedSubview(panelLabel(
            t("Что сделать после вставки распознанного текста.",
              "What to do after inserting the transcribed text."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let control = NSSegmentedControl(
            labels: [t("Вставить", "Insert"), t("Вставить + Enter", "Insert + Enter")],
            trackingMode: .selectOne,
            target: self,
            action: #selector(selectPrimaryCompletionBehavior(_:))
        )
        control.selectedSegment = draft.primaryCompletionBehavior == .insert ? 0 : 1
        control.isEnabled = serviceOperation == nil
        control.toolTip = t("Выберите действие при повторном нажатии основного хоткея.",
                            "Choose what the main shortcut does when pressed again.")
        control.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(control)
        return row
    }

    private func alternateCompletionRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        let behavior = draft.primaryCompletionBehavior.opposite
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(
            behavior == .insert
                ? t("Завершить без Enter", "Finish without Enter")
                : t("Завершить + Enter", "Finish + Enter"),
            size: 13,
            weight: .semibold
        ))
        text.addArrangedSubview(panelLabel(
            t("Дополнительный хоткей работает только во время записи.",
              "The alternative shortcut only works while recording."),
            size: 12,
            color: .secondaryLabelColor
        ))

        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(toggleAlternateCompletion(_:))
        toggle.state = draft.alternateCompletionEnabled ? .on : .off
        toggle.isEnabled = serviceOperation == nil
        toggle.toolTip = t("Включить дополнительный способ завершения записи.",
                           "Enable the alternative way to finish recording.")
        toggle.setContentHuggingPriority(.required, for: .horizontal)

        let button = panelButton(
            localizedHotkeyName(draft.alternateCompletionHotkey, language: language),
            action: #selector(recordDictationShortcutClicked(_:)),
            enabled: draft.alternateCompletionEnabled && serviceOperation == nil,
            toolTip: t("Изменить дополнительный хоткей завершения.",
                       "Change the alternative finish shortcut.")
        )
        button.tag = ControlPanelShortcutKind.alternateCompletion.rawValue
        button.controlSize = .regular
        button.widthAnchor.constraint(equalToConstant: 200).isActive = true

        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(toggle)
        row.addArrangedSubview(button)
        return row
    }

    private static let enterDelayOptions: [(title: String, value: String)] = [
        ("0 ms", "0"),
        ("50 ms", "50"),
        ("80 ms", "80"),
        ("120 ms", "120"),
        ("200 ms", "200"),
        ("300 ms", "300"),
    ]

    private func enterDelayRow(_ draft: ControlPanelSettingsDraft) -> NSView {
        popupRow(
            title: t("Задержка Enter", "Enter delay"),
            detail: t("Пауза между вставкой текста и нажатием Enter.",
                      "Pause between inserting text and pressing Enter."),
            selectedValue: String(draft.enterDelayMilliseconds),
            options: Self.enterDelayOptions,
            action: #selector(selectEnterDelay(_:)),
            toolTip: t("Некоторым приложениям (Electron, VM) нужна пауза после вставки. Уменьшите для быстрых приложений.",
                       "Some apps (Electron, VMs) need a pause after paste. Lower for fast native apps.")
        )
    }

    private func popupRow(title: String,
                          detail: String,
                          selectedValue: String,
                          options: [(title: String, value: String)],
                          action: Selector,
                          toolTip: String? = nil) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14

        let text = NSStackView()
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.addArrangedSubview(panelLabel(title, size: 13, weight: .semibold))
        text.addArrangedSubview(panelLabel(detail, size: 12, color: .secondaryLabelColor))

        let popup = NSPopUpButton()
        popup.target = self
        popup.action = action
        popup.toolTip = toolTip
        for option in options {
            popup.addItem(withTitle: option.title)
            popup.lastItem?.representedObject = option.value
        }
        if let item = popup.itemArray.first(where: { $0.representedObject as? String == selectedValue }) {
            popup.select(item)
        }
        popup.setContentHuggingPriority(.required, for: .horizontal)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(popup)
        return row
    }

    private func settingsActionsRow(draft: ControlPanelSettingsDraft) -> NSView {
        let persisted = ControlPanelSettingsDraft(settings: settings)
        let hasChanges = draft != persisted
        let validation = settingsValidationMessage(draft)
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let message = panelLabel(
            validation ?? (hasChanges
                ? t("Есть несохранённые изменения", "You have unsaved changes")
                : t("Все изменения сохранены", "All changes are saved")),
            size: 11,
            color: validation == nil ? SD.C.graphite : SD.C.voice
        )
        message.toolTip = validation
        row.addArrangedSubview(message)
        row.addArrangedSubview(NSView())

        let discard = NSButton(title: t("Отменить", "Discard"),
                               target: self,
                               action: #selector(discardSettingsClicked(_:)))
        discard.isBordered = false
        discard.font = .systemFont(ofSize: 12, weight: .medium)
        discard.contentTintColor = SD.C.graphite
        discard.isEnabled = hasChanges && serviceOperation == nil
        discard.alphaValue = discard.isEnabled ? 1 : 0.4
        row.addArrangedSubview(discard)

        let save = SDSolidButton(title: t("Сохранить и перезапустить", "Save & Restart"),
                                 target: self,
                                 action: #selector(saveSettingsClicked(_:)))
        save.isBordered = false
        save.isEnabled = hasChanges && validation == nil && serviceOperation == nil
        save.toolTip = t("Сохранить настройки и перезапустить фоновую службу.",
                         "Save settings and restart the background service.")
        save.keyEquivalent = "\r"
        save.translatesAutoresizingMaskIntoConstraints = false
        save.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let saveWidth = ceil(save.title.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
        ]).width)
        save.widthAnchor.constraint(equalToConstant: saveWidth + 28).isActive = true
        save.restyle()
        row.addArrangedSubview(save)
        row.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        return row
    }

    private func settingsValidationMessage(_ draft: ControlPanelSettingsDraft) -> String? {
        let shortcuts = draft.alternateCompletionEnabled
            ? [draft.dictationHotkey, draft.alternateCompletionHotkey, draft.historyHotkey]
            : [draft.dictationHotkey, draft.historyHotkey]
        for firstIndex in shortcuts.indices {
            for secondIndex in shortcuts.indices where secondIndex > firstIndex {
                let first = shortcuts[firstIndex]
                let second = shortcuts[secondIndex]
                if hotkeysConflict(first, second) {
                    return t("Сочетания для диктовки, завершения и истории должны отличаться.",
                             "Dictation, finish, and history shortcuts must be different.")
                }
                if hotkeyIsModifierPrefix(first, of: second)
                    || hotkeyIsModifierPrefix(second, of: first) {
                    return t("Одна активная комбинация не должна быть частью другой.",
                             "One active shortcut cannot be a prefix of another.")
                }
            }
        }
        return nil
    }

    private func privacyInfoView() -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.shield.fill",
                                              accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        row.addArrangedSubview(icon)
        let label = panelLabel(
            t("Аудио и распознавание остаются на Mac. Интернет нужен только для первой загрузки модели и обновлений.",
              "Audio and transcription stay on this Mac. Internet is only used for the first model download and updates."),
            size: 11.5,
            color: .secondaryLabelColor
        )
        label.preferredMaxLayoutWidth = 600
        row.addArrangedSubview(label)
        return row
    }

    private func panelLabel(_ text: String,
                            size: CGFloat,
                            weight: NSFont.Weight = .regular,
                            color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func panelButton(_ title: String,
                             action: Selector,
                             enabled: Bool = true,
                             toolTip: String? = nil) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func compactIconButton(symbol: String,
                                   accessibilityTitle: String,
                                   toolTip: String,
                                   action: Selector,
                                   enabled: Bool = true) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol,
                                             accessibilityDescription: accessibilityTitle) ?? NSImage(),
                              target: self,
                              action: action)
        button.bezelStyle = .texturedRounded
        button.controlSize = .small
        button.isEnabled = enabled
        button.toolTip = toolTip
        button.setAccessibilityLabel(accessibilityTitle)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 30),
            button.heightAnchor.constraint(equalToConstant: 26),
        ])
        return button
    }

    private func compactCard() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.70).cgColor
        card.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.42).cgColor
        card.layer?.borderWidth = 1
        card.setContentHuggingPriority(.required, for: .vertical)
        card.setContentCompressionResistancePriority(.required, for: .vertical)
        return card
    }

    private func panelSymbol(_ name: String,
                             color: NSColor,
                             description: String?,
                             pointSize: CGFloat) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description) ?? NSImage()
        let view = NSImageView(image: image)
        view.contentTintColor = color
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    private func pin(_ view: NSView,
                     inside container: NSView,
                     horizontal: CGFloat,
                     vertical: CGFloat) {
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: horizontal),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -horizontal),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
        ])
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func triggerModeText() -> String {
        switch settings.triggerMode {
        case .hold: return t("Удерживать", "Press and hold")
        case .toggle: return t("Нажать для старта и ещё раз для остановки", "Press to start, press again to stop")
        }
    }

    private func localizedCompletionBehavior(_ behavior: DictationCompletionBehavior) -> String {
        switch behavior {
        case .insert:
            return t("Вставить", "Insert")
        case .insertAndEnter:
            return t("Вставить + Enter", "Insert + Enter")
        }
    }

    private func displayStatus(_ raw: String) -> String {
        switch raw {
        case "ready": return t("Работает", "Running")
        case "recording", "transcribing": return t("Работает", "Running")
        case "starting": return t("Запускается", "Starting")
        case "needs_permissions": return t("Нужен доступ", "Needs Access")
        case "error": return t("Ошибка", "Error")
        case "stopping": return t("Останавливается", "Stopping")
        case "stopped": return t("Остановлена", "Stopped")
        default: return raw.capitalized
        }
    }

    private func localizedServiceDetail(_ state: AgentRuntimeState) -> String {
        switch state.status {
        case "ready", "recording", "transcribing":
            return t("Фоновая служба готова к диктовке.",
                     "The background service is ready for dictation.")
        case "starting":
            if state.detail.hasPrefix("Downloading speech model") {
                if let percentRange = state.detail.range(of: "\\d+%", options: .regularExpression) {
                    let percent = state.detail[percentRange]
                    return t("Скачиваю языковую модель… \(percent)", "Downloading speech model… \(percent)")
                }
                return t("Скачиваю языковую модель…", "Downloading speech model…")
            } else if state.detail.hasPrefix("Checking speech model") {
                return t("Проверяю список файлов модели…", "Checking speech model files…")
            } else if state.detail.hasPrefix("Preparing speech model") {
                return t("Подготавливаю модель…", "Preparing speech model…")
            } else if state.detail.hasPrefix("Loading cached speech model") {
                return t("Загружаю модель из кэша…", "Loading cached speech model…")
            } else if state.detail.hasPrefix("Loading speech model") {
                return t("Загружаю языковую модель…", "Loading speech model…")
            }
            return t("Запускаю службу диктовки…", "Starting dictation service…")
        case "needs_permissions": return t("Выдайте недостающие разрешения ниже.", "Grant the missing permissions below.")
        case "stopped": return t("Фоновая служба остановлена.", "The background service is stopped.")
        case "error": return t("Служба сообщила об ошибке: \(state.detail)", "Service error: \(state.detail)")
        default: return state.detail
        }
    }

    private func colorForStatus(_ raw: String) -> NSColor {
        switch raw {
        case "ready", "recording", "transcribing": return .systemGreen
        case "starting", "needs_permissions", "stopping": return .systemOrange
        case "error", "stopped": return .systemRed
        default: return .secondaryLabelColor
        }
    }

    private func permissionTitle(_ permission: Permission) -> String {
        switch permission {
        case .microphone: return t("Микрофон", "Microphone")
        case .accessibility: return t("Универсальный доступ", "Accessibility")
        case .inputMonitoring: return t("Мониторинг ввода", "Input Monitoring")
        }
    }

    private func permissionDetail(_ permission: Permission) -> String {
        switch permission {
        case .microphone:
            return t("Запись голоса только во время активной диктовки.",
                     "Lets the service hear your voice while dictation is active.")
        case .accessibility:
            return t("Поиск активного поля и вставка готового текста.",
                     "Lets the service find the active field and insert text.")
        case .inputMonitoring:
            return t("Глобальное распознавание выбранного сочетания клавиш.",
                     "Lets the service detect your shortcut globally.")
        }
    }

    private func localizedColorName(_ color: RecordingHUDAccentColor) -> String {
        guard language == .russian else { return color.displayName }
        switch color {
        case .coral: return "Коралловый"
        case .graphite: return "Графитовый"
        case .red: return "Красный"
        case .orange: return "Оранжевый"
        case .pink: return "Розовый"
        case .purple: return "Фиолетовый"
        case .blue: return "Синий"
        case .cyan: return "Голубой"
        case .green: return "Зелёный"
        case .white: return "Белый"
        }
    }

    private func localizedBackgroundName(_ style: RecordingHUDBackgroundStyle) -> String {
        guard language == .russian else { return style.displayName }
        switch style {
        case .system: return "Как в системе"
        case .dark: return "Тёмный"
        case .light: return "Светлый"
        }
    }

    private func localizedHUDSizeName(_ size: RecordingHUDSize) -> String {
        guard language == .russian else { return size.displayName }
        switch size {
        case .compact: return "Компактная"
        case .standard: return "Обычная"
        case .large: return "Крупная"
        }
    }

    private func beginServiceOperation(_ operation: ControlPanelServiceOperation) {
        guard serviceOperation == nil else { return }
        serviceOperation = operation
        lastRenderFingerprint = ""
        refresh(force: true)
        let operationStartedAt = Date().timeIntervalSince1970

        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    switch operation {
                    case .starting:
                        try DictorAgentService.installAndStart()
                    case .restarting, .applyingSettings:
                        try DictorAgentService.restart()
                    case .stopping:
                        DictorAgentService.stop()
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if failure == nil {
                await self.waitForServiceResult(operation: operation, startedAt: operationStartedAt)
            }
            self.serviceOperation = nil
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
            if let failure {
                self.showError(
                    title: self.t("Не удалось изменить состояние службы", "Service operation failed"),
                    detail: failure
                )
            }
        }
    }

    private func waitForServiceResult(operation: ControlPanelServiceOperation,
                                      startedAt: TimeInterval) async {
        for _ in 0..<80 {
            let state = AgentRuntimeStateStore.read()
            if operation == .stopping {
                if state?.status == "stopped" { return }
            } else if let state,
                      state.updatedAt >= startedAt,
                      ["ready", "error", "needs_permissions"].contains(state.status) {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    @objc private func updateButtonClicked(_ sender: NSButton) {
        switch updateState {
        case .available(let release):
            beginInAppUpdate(for: release)
        case .checking, .preparing:
            return
        case .upToDate, .failed:
            checkForUpdates()
        }
    }

    @objc private func startAgentClicked(_ sender: NSButton) {
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        beginServiceOperation(.starting)
    }

    @objc private func restartAgentClicked(_ sender: NSButton) {
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        beginServiceOperation(.restarting)
    }

    @objc private func stopAgentClicked(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Остановить службу диктовки?", "Stop Dictation Service?")
        alert.informativeText = t("Хоткей перестанет работать, но история, модель и настройки сохранятся.",
                                  "The shortcut will stop, but history, model, and settings remain saved.")
        alert.addButton(withTitle: t("Оставить включённой", "Keep Running"))
        alert.addButton(withTitle: t("Остановить", "Stop Service"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        settings.agentEnabled = false
        _ = settings.refreshFromDisk()
        beginServiceOperation(.stopping)
    }

    @objc private func openSettingsClicked(_ sender: NSButton) {
        openSettingsWindow()
    }

    func openSettingsWindow() {
        if let settingsWindow {
            settingsWindow.contentView = makeSettingsContentView()
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        settingsDraft = ControlPanelSettingsDraft(settings: settings)

        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = t("Настройки Dictor", "Dictor Settings")
        settingsWindow.titlebarAppearsTransparent = true
        settingsWindow.backgroundColor = SD.C.settingsPaper
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.delegate = self
        settingsWindow.contentView = makeSettingsContentView()
        if let contentView = settingsWindow.contentView {
            resizeSettingsWindowToFit(settingsWindow, contentView: contentView)
        }
        if let mainWindow = window, let visibleFrame = mainWindow.screen?.visibleFrame {
            let mainFrame = mainWindow.frame
            let preferredRight = mainFrame.maxX + 14
            let preferredLeft = mainFrame.minX - settingsWindow.frame.width - 14
            let x = preferredRight + settingsWindow.frame.width <= visibleFrame.maxX
                ? preferredRight
                : max(visibleFrame.minX, preferredLeft)
            let y = min(max(visibleFrame.minY,
                            mainFrame.maxY - settingsWindow.frame.height),
                        visibleFrame.maxY - settingsWindow.frame.height)
            settingsWindow.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            settingsWindow.center()
        }
        self.settingsWindow = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func recordDictationShortcutClicked(_ sender: NSButton) {
        guard serviceOperation == nil,
              let kind = ControlPanelShortcutKind(rawValue: sender.tag) else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present(relativeTo: settingsWindow)
            return
        }
        let state = AgentRuntimeStateStore.read()
        if state?.isRecording == true || state?.isTranscribing == true {
            showError(
                title: t("Сначала завершите диктовку", "Finish Dictation First"),
                detail: t("Сочетание нельзя менять во время записи или распознавания.",
                          "Shortcuts cannot be changed while recording or transcribing.")
            )
            return
        }
        if DictorAgentService.isAgentRunning(), state?.isReady != true {
            showError(
                title: t("Служба ещё запускается", "Service Is Still Starting"),
                detail: t("Дождитесь статуса «Работает» и попробуйте изменить сочетание ещё раз.",
                          "Wait for the Running status, then try changing the shortcut again.")
            )
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let recorderTitle: String
        switch kind {
        case .dictation:
            recorderTitle = t("Новое сочетание для диктовки", "New Dictation Shortcut")
        case .alternateCompletion:
            recorderTitle = t("Дополнительное сочетание завершения", "Alternative Finish Shortcut")
        case .history:
            recorderTitle = t("Новое сочетание для истории", "New History Shortcut")
        }
        let recorder = HotkeyRecorderController(language: language,
                                                titleOverride: recorderTitle) { [weak self] selected in
            DistributedNotificationCenter.default().postNotificationName(
                HOTKEY_CAPTURE_END_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            guard let self else { return }
            self.hotkeyRecorder = nil
            guard let selected else { return }
            var draft = self.settingsDraft ?? ControlPanelSettingsDraft(settings: self.settings)
            switch kind {
            case .dictation: draft.dictationHotkey = selected
            case .alternateCompletion: draft.alternateCompletionHotkey = selected
            case .history: draft.historyHotkey = selected
            }
            self.settingsDraft = draft
            self.refreshSettingsWindow()
        }
        hotkeyRecorder = recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak recorder] in
            guard self?.hotkeyRecorder === recorder else { return }
            recorder?.present(relativeTo: self?.settingsWindow)
        }
    }

    @objc private func selectInterfaceLanguage(_ sender: NSSegmentedControl) {
        settings.interfaceLanguage = sender.selectedSegment == 1 ? .english : .russian
        _ = settings.refreshFromDisk()
        lastRenderFingerprint = ""
        refresh(force: true)
    }

    @objc private func selectPrimaryCompletionBehavior(_ sender: NSSegmentedControl) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.primaryCompletionBehavior = sender.selectedSegment == 1 ? .insertAndEnter : .insert
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func toggleAlternateCompletion(_ sender: NSSwitch) {
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.alternateCompletionEnabled = sender.state == .on
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDRecordingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.recordingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDTranscribingColor(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let color = RecordingHUDAccentColor(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.transcribingColor = color
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDBackgroundStyle(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let style = RecordingHUDBackgroundStyle(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.backgroundStyle = style
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectEnterDelay(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let ms = Int(raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.enterDelayMilliseconds = ms
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func selectRecordingHUDSize(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let size = RecordingHUDSize(rawValue: raw) else { return }
        var draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        draft.hudSize = size
        settingsDraft = draft
        refreshSettingsWindow()
    }

    @objc private func discardSettingsClicked(_ sender: NSButton) {
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        refreshSettingsWindow()
    }

    @objc private func saveSettingsClicked(_ sender: NSButton) {
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil else { return }
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.setConfiguredHistoryHotkey(draft.historyHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.enterDelayMilliseconds = draft.enterDelayMilliseconds
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDTranscribingColor = draft.transcribingColor
        settings.recordingHUDBackgroundStyle = draft.backgroundStyle
        settings.recordingHUDSize = draft.hudSize
        settings.agentEnabled = true
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        beginServiceOperation(.applyingSettings)
    }

    private func refreshSettingsWindow() {
        guard let settingsWindow else { return }
        settingsWindow.contentView = makeSettingsContentView()
    }

    @objc private func grantPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        let permission = Permission.allCases[sender.tag]
        if Permissions.isGranted(permission) {
            permissionClickCount[permission] = nil
            refresh(force: true)
            return
        }

        let clicks = (permissionClickCount[permission] ?? 0) + 1
        permissionClickCount[permission] = clicks
        if clicks >= 2 {
            TCC.reset(permission, bundleID: Bundle.main.bundleIdentifier ?? SETTINGS_SUITE) { [weak self] in
                guard let self else { return }
                Permissions.request(permission)
                self.refresh(force: true)
            }
        } else {
            Permissions.request(permission)
        }
        refresh(force: true)
    }

    private func showError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: t("ОК", "OK"))
        alert.runModal()
    }
}


// MARK: - Превью настроек (для визуальной сверки с макетом)

struct SettingsPreviewExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
func exportSettingsPanelPreviews(to directory: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let panel = DictorControlPanelApp()
    let size = NSSize(width: 620, height: 560)
    // Вне NSWindow layer-backed view не проходит через window server и
    // bitmapImageRepForCachingDisplay возвращает пустой битмап — поэтому
    // рендерим в офскрин-окне.
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.colorSpace = .sRGB
    var exported = 0
    for tab in ["general", "hotkeys", "model", "dict", "look", "privacy"] {
        panel.settingsTab = tab
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                         ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearanceName)
            let view = panel.makeSettingsContentView()
            let height = DictorControlPanelApp.settingsContentHeight(for: view)
            window.setContentSize(NSSize(width: size.width, height: height))
            view.frame = NSRect(origin: .zero,
                                size: NSSize(width: size.width, height: height))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw SettingsPreviewExportError(message: "no bitmap rep for \(tab)-\(suffix)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SettingsPreviewExportError(message: "PNG encode failed for \(tab)-\(suffix)")
            }
            let url = directory.appendingPathComponent("settings-\(tab)-\(suffix).png")
            try png.write(to: url, options: .atomic)
            exported += 1
        }
    }
    window.contentView = nil
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("SETTINGS_PREVIEW exported \(exported) files to \(directory.path)")
}

/// Превью главного окна истории. Сеет сэмпл-данные в defaults ТЕКУЩЕГО
/// процесса (CLI-домен, не приложение) и рендерит светлый/тёмный вариант.
@MainActor
func exportHistoryPanelPreviews(to directory: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let settings = Settings.shared
    // Превью подменяет историю и статистику сэмплами. Раньше подмена была
    // безвозвратной: запуск ключа у установленного .app стирал реальные
    // диктовки пользователя. Снимаем состояние и возвращаем его на выходе.
    let savedEntries = settings.recentTranscriptEntries
    let savedUsage = settings.dailyDictationUsage
    defer {
        settings.recentTranscriptEntries = savedEntries
        settings.dailyDictationUsage = savedUsage
    }
    settings.recentTranscriptEntries = [
        TranscriptHistoryEntry(text: "Привет! По итогам звонка присылаю короткое резюме и три следующих шага, посмотри до пятницы",
                               transcriptionDurationSeconds: 1.2,
                               createdAt: now.addingTimeInterval(-3600)),
        TranscriptHistoryEntry(text: "Давай созвонимся в четверг в три, я закину приглашение",
                               transcriptionDurationSeconds: 0.7,
                               createdAt: now.addingTimeInterval(-9000)),
        TranscriptHistoryEntry(text: "Заголовок: локальная диктовка без облака — обзор Dictor",
                               transcriptionDurationSeconds: 0.6,
                               createdAt: now.addingTimeInterval(-16000)),
        TranscriptHistoryEntry(text: "Собираем бету в пятницу, режем скоуп до словаря и режимов",
                               transcriptionDurationSeconds: 0.9,
                               createdAt: now.addingTimeInterval(-100_000)),
    ]
    var usage: [DailyDictationUsage] = []
    let calendar = Calendar.current
    for offset in 0..<30 {
        guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
        let key = dictationUsageDayKey(for: day, calendar: calendar)
        usage.append(DailyDictationUsage(day: key,
                                         dictationCount: 8,
                                         characterCount: 2500 + (offset * 137) % 2200,
                                         audioSeconds: 400,
                                         asrSeconds: 10))
    }
    settings.dailyDictationUsage = usage

    let panel = DictorControlPanelApp()
    let size = MAIN_WINDOW_SIZE
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.colorSpace = .sRGB
    var exported = 0
    // Каждый раздел окна (макет 6a/6b) в обеих темах.
    for section in [MainWindowSection.today, .history, .dictionary] {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                         ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearanceName)
            panel.mainSection = section
            let name = "\(section.rawValue)-\(suffix)"
            let view = panel.makeMainWindowView()
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw SettingsPreviewExportError(message: "no bitmap rep for \(name)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SettingsPreviewExportError(message: "PNG encode failed for \(name)")
            }
            try png.write(to: directory.appendingPathComponent("\(name).png"),
                          options: .atomic)
            exported += 1
        }
    }
    window.contentView = nil
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("HISTORY_PREVIEW exported \(exported) files to \(directory.path)")
}
