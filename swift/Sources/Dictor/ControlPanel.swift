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
}

struct ControlPanelSettingsDraft: Equatable {
    var dictationHotkey: HotkeyChoice
    var alternateCompletionHotkey: HotkeyChoice
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
    return shortcut.requiredModifiers.contains(prefixMask)
}

enum ControlPanelUpdateState: Equatable, Sendable {
    /// Проверка не выполнялась: автопроверка выключена или окно только что
    /// открылось. Не путать с `.checking` — тут в сеть никто не ходил.
    case notChecked
    case checking
    case upToDate(String)
    case available(DictorRelease)
    case preparing(version: String, phase: String)
    case failed(String)
}

@MainActor
final class DictorControlPanelApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow?
    private var refreshTimer: Timer?
    private var serviceOperation: ControlPanelServiceOperation?
    private var updateTask: Task<Void, Never>?
    /// Состояние, навязанное экспортом превью, — в живом окне всегда nil.
    /// Не private: витрина снимается debug-бинарём, у которого нет бандла, и
    /// подвал честно докладывал «Установлена версия 0.0.0, служба ещё работает
    /// на 1.2.0». Для снимков состояние задаётся явно.
    var previewStatusOverride: ServiceStatusKind?
    /// Пауза перед показом коротких состояний службы (макет 8c).
    private let statusHold = ServiceStatusHold()
    private var statusHoldTimer: Timer?
    private var updateState: ControlPanelUpdateState = .notChecked
    private var lastRenderFingerprint = ""
    private let settings = Settings.shared
    private var permissionClickCount: [Permission: Int] = [:]
    private var settingsDraft: ControlPanelSettingsDraft?
    var settingsTab = "general"
    private var hotkeyRecorder: HotkeyRecorderController?
    private var onboardingFlow: OnboardingFlow?
    private var onboardingPage: OnboardingPageView?
    /// Отчёт последней починки разрешений. Пусто — показываем план.
    private var permissionRepairNotes: [String] = []
    /// Запрос поиска по истории. Не private: экспорт превью снимает историю с
    /// набранным запросом — только там видны подсветка совпадений и крестик
    /// очистки.
    var mainHistorySearch = ""
    private weak var mainHistorySearchField: NSSearchField?
    private weak var historyDetailTranscriptView: SDSelectableTranscriptView?
    /// Раздел главного окна (макет 6a): «Сегодня» открывается первым.
    var mainSection: MainWindowSection = .today
    /// Выбранная запись в «Истории» и фильтр «Закреплённые» (макет 6b).
    /// Не private: самотест `today-actions` проверяет, что переход из
    /// «Сегодня» выбирает именно ту запись, по которой щёлкнули.
    var historySelectionKey: String?
    private var pendingSettingsApply: DispatchWorkItem?
    /// Выбранный период в «Статистике» (макет 7a).
    var statsPeriod: StatsPeriod = .month
    /// Что сказать после записи сочетания — иначе тишина читается как «не сработало».
    private var hotkeyNotice: String?
    private var historyShowsPinnedOnly = false

    private var language: InterfaceLanguage { settings.interfaceLanguage }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if DictorControlPanelRegistry.activateExistingPanelIfPresent() {
            NSApp.terminate(nil)
            return
        }
        DictorControlPanelRegistry.claimCurrentPanel()
        guard offerToMoveIntoApplicationsIfNeeded() else {
            NSApp.terminate(nil)
            return
        }
        installMainMenu()
        // Раздел, запрошенный поповером (макет 6a: «История» и «Настройки»
        // ведут в окно, а не открывают отдельные окна).
        if let index = CommandLine.arguments.firstIndex(of: CONTROL_PANEL_SECTION_ARGUMENT),
           CommandLine.arguments.indices.contains(index + 1),
           let requested = MainWindowSection(rawValue: CommandLine.arguments[index + 1]) {
            mainSection = requested
            if requested == .settings {
                settingsDraft = ControlPanelSettingsDraft(settings: settings)
            }
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(openSectionRequested(_:)),
            name: CONTROL_PANEL_SECTION_NOTIFICATION,
            object: nil)
        // «Выйти» в меню-баре закрывает и это окно: Dictor — одно приложение,
        // хоть и два процесса.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(quitRequestedByAgent(_:)),
            name: CONTROL_PANEL_QUIT_NOTIFICATION,
            object: nil)
        showWindow()
        startRefreshTimer()
        // Автопроверка при открытии окна уважает тумблер: вкладка
        // «Приватность» обещает «0 сетевых запросов — обновления отключены»,
        // и до этого guard'а само открытие окна делало обещание ложью.
        // Ручная кнопка «Проверить» работает независимо от тумблера — как и
        // ручная проверка из поповера службы.
        if settings.checkForUpdates {
            checkForUpdates()
        }
        if settings.agentEnabled && !DictorAgentService.isAgentRunning() {
            beginServiceOperation(.starting)
        }
        startOnboardingIfNeeded(force: CommandLine.arguments.contains("--onboarding"))
    }

    // MARK: - Онбординг

    private func startOnboardingIfNeeded(force: Bool) {
        guard let flow = OnboardingFlow.makeIfNeeded(force: force) else { return }
        onboardingFlow = flow
        onboardingPage = OnboardingPageView(language: language, actions: self)
        window?.contentView = makeMainWindowView()
        applyOnboarding()
    }

    /// Обновление онбординга минует общую пересборку окна. В `refresh()` вид
    /// заменяется целиком по отпечатку, куда входит и доля загрузки модели —
    /// на шаге пробы это уносило бы поле ввода вместе с фокусом раз в тик.
    private func applyOnboarding() {
        guard let flow = onboardingFlow, let page = onboardingPage else { return }
        let snapshot = flow.currentSnapshot()
        flow.advance(with: snapshot)
        page.apply(step: flow.step, snapshot: snapshot)
    }

    private func finishOnboarding() {
        guard onboardingFlow != nil else { return }
        settings.onboardingCompleted = true
        onboardingFlow = nil
        onboardingPage = nil
        lastRenderFingerprint = ""
        refresh(force: true)
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
        if closingWindow === window {
            hotkeyRecorder?.cancel()
            hotkeyRecorder = nil
            NSApp.terminate(nil)
        }
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    /// Возвращает false, если запускаться отсюда нельзя и приложение должно
    /// закрыться: либо мы уже открыли установленную копию, либо пользователь
    /// отказался переносить.
    private func offerToMoveIntoApplicationsIfNeeded() -> Bool {
        guard InstallLocation.isEphemeral() else { return true }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Перенести Dictor в «Программы»?",
                              "Move Dictor to Applications?")
        alert.informativeText = t(
            """
            Сейчас Dictor открыт из временного места — прямо с образа или из \
            папки загрузок. Оттуда он работать не будет: macOS подменяет такой \
            копии путь, разрешения на микрофон и мониторинг ввода к ней не \
            привязываются, а служба диктовки сломается, как только образ будет \
            извлечён.
            """,
            """
            Dictor is running from a temporary location — straight off the disk \
            image or out of your downloads folder. It cannot work from there: \
            macOS gives such a copy a throwaway path, microphone and input \
            monitoring permissions will not stick to it, and dictation breaks as \
            soon as the image is ejected.
            """)
        alert.addButton(withTitle: t("Перенести и открыть", "Move and Open"))
        alert.addButton(withTitle: t("Выйти", "Quit"))

        guard alert.runModal() == .alertFirstButtonReturn else {
            log("install location: user declined the move from \(InstallLocation.current.path)")
            return false
        }

        do {
            try InstallLocation.moveToApplicationsAndRelaunch()
            log("install location: moved into Applications and relaunched")
            return false
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .critical
            failure.messageText = t("Не удалось перенести Dictor",
                                    "Could not move Dictor")
            failure.informativeText = t(
                "Перетащи Dictor.app в «Программы» вручную и открой уже оттуда.\n\n\(error.localizedDescription)",
                "Drag Dictor.app into Applications yourself, then open it from there.\n\n\(error.localizedDescription)")
            failure.addButton(withTitle: "OK")
            failure.runModal()
            return false
        }
    }

    /// Без этого меню ⌘C в окне только пищит. Приложение живёт в меню-баре
    /// (LSUIElement), окно поднимает политику до .regular — и остаётся без
    /// NSApp.mainMenu, а стандартные ⌘C/⌘V/⌘A ходят через пункты меню
    /// «Правки»: их keyEquivalent и рассылает copy: по цепочке отклика.
    /// Нет пунктов — некому рассылать, и текст не забрать ни из истории,
    /// ни из поля поиска, ни из словаря.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: t("Скрыть Dictor", "Hide Dictor"),
                        action: #selector(NSApplication.hide(_:)),
                        keyEquivalent: "h")
        appMenu.addItem(.separator())
        // Закрывает окно, а не диктовку: служба живёт отдельным процессом
        // и продолжает слушать хоткей.
        appMenu.addItem(withTitle: t("Закрыть окно", "Close Window"),
                        action: #selector(NSWindow.performClose(_:)),
                        keyEquivalent: "w")
        appMenu.addItem(.separator())
        // ⌘Q не делал ничего: пункта «Выйти» в меню не было, а без пункта
        // сочетание некому обработать. Выход здесь — полный: и окно, и
        // служба, потому что «выйти из приложения» не означает «оставить
        // половину работать».
        let quit = appMenu.addItem(withTitle: t("Выйти из Dictor", "Quit Dictor"),
                                   action: #selector(quitEverythingClicked(_:)),
                                   keyEquivalent: "q")
        quit.target = self
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: t("Правка", "Edit"))
        editMenu.addItem(withTitle: t("Отменить", "Undo"),
                         action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: t("Повторить", "Redo"),
                                    action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: t("Вырезать", "Cut"),
                         action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: t("Копировать", "Copy"),
                         action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: t("Вставить", "Paste"),
                         action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: t("Выбрать все", "Select All"),
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
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
        // Главное окно по макету 6a: сайдбар + раздел, включая настройки.
        window.title = "Dictor"
        window.contentView = makeMainWindowView()
        restoreSearchFocus(focusState, in: window)
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
        // Состояние службы — уже выдержавшее паузу (8c), а не сырое: иначе
        // созревшая пауза не доживёт до экрана. Отпечаток к этому моменту уже
        // не меняется, и refresh вышел бы на раннем `return`.
        let statusToken: String = "status:\(currentServiceStatus().fingerprint)"
        let parts: [String] = [statusToken,
                language.rawValue,
                "section:\(mainSection.rawValue):\(statsPeriod.rawValue)",
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
                settings.primaryCompletionBehavior.rawValue,
                settings.alternateCompletionEnabled ? "alternate-on" : "alternate-off",
                settings.triggerMode.rawValue,
                settings.recordingHUDRecordingColor.rawValue,
                settings.recordingHUDTranscribingColor.rawValue,
                settings.recordingHUDBackgroundStyle.rawValue,
                settings.recordingHUDSize.rawValue,
                // Настройки, которые меняются и извне окна — из меню-бара и
                // агентом. Без них окно не перерисовывалось, и клик по
                // устаревшему тумблеру перещёлкивал только что сделанное.
                String(settings.enterDelayMilliseconds),
                settings.playFeedbackSounds ? "sounds-on" : "sounds-off",
                settings.checkForUpdates ? "updates-on" : "updates-off",
                settings.removeFillerWords ? "fillers-on" : "fillers-off",
                settings.builtInSpellingsEnabled ? "spellings-on" : "spellings-off",
                settings.latinTermRestorationsEnabled ? "latin-on" : "latin-off",
                "script:\(settings.dictationLanguage.rawValue)",
                "input:\(settings.inputDevice)",
                settings.floatingCapsuleEnabled ? "capsule-on" : "capsule-off",
                settings.recordingHUDPlacement.rawValue,
                "limit:\(settings.recentTranscriptLimit.rawValue)",
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
        case "advanced":
            addAdvancedTabRows(to: root)
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
                    ("advanced", t("Продвинутые", "Advanced")),
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
        hotkeyNotice = nil
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

        let scriptOptions = dictationScriptOptions(interfaceLanguage: language)
        let langPills = SDPills(options: scriptOptions.map {
            .init(title: $0.title, value: $0.language.rawValue)
        }, selected: settings.dictationLanguage.rawValue)
        langPills.onSelect = { [weak self] raw in
            guard let language = DictationLanguage(rawValue: raw) else { return }
            self?.settings.dictationLanguage = language
        }
        root.addArrangedSubview(SDRowView(
            title: t("Алфавит вывода", "Output script"),
            subtitle: t("Авто — смешанная речь. Кириллица — английские слова "
                        + "запишутся по-русски",
                        "Auto handles mixed speech. Cyrillic makes English words "
                        + "come out in Russian letters"),
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
        // Служба сообщает, если выбранное устройство отказало и запись идёт
        // с системного входа: без этого выбранное имя в попапе — молчаливая
        // ложь о том, откуда берётся звук.
        let microphoneSubtitle: String
        if let failed = AgentRuntimeStateStore.read()?.inputFallbackDeviceName {
            microphoneSubtitle = t("\(failed) отказал — запись идёт с системного входа",
                                   "\(failed) failed — recording from the system default input")
        } else {
            microphoneSubtitle = t("Если пропадёт — вернёмся к встроенному",
                                   "Falls back to the built-in mic if it disappears")
        }
        root.addArrangedSubview(SDRowView(
            title: t("Микрофон", "Microphone"),
            subtitle: microphoneSubtitle,
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
                                        range: 0...ENTER_DELAY_MAX_MILLISECONDS,
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
            control: soundsToggle
        ))

        // Выключить автопроверку было можно и раньше — но только через меню по
        // правому клику на иконке в строке меню. Первый же человек со стороны
        // попросил «чтобы проверку обновлений можно было убрать»: настройка,
        // которую нельзя найти там, где её ищут, всё равно что отсутствует.
        let updatesToggle = SDToggle()
        updatesToggle.isOn = settings.checkForUpdates
        updatesToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            self.settings.checkForUpdates = enabled
            log("update checks \(enabled ? "enabled" : "disabled") from settings")
            self.refresh(force: true)
        }
        root.addArrangedSubview(SDRowView(
            title: t("Проверять обновления", "Check for updates"),
            subtitle: t("Раз в 6 часов приложение спрашивает номер последней версии. "
                        + "Выключите — и оно само в сеть не ходит.",
                        "Every 6 hours the app asks for the latest version number. "
                        + "Turn it off and it stops going online on its own."),
            control: updatesToggle
        ))

        root.addArrangedSubview(versionRow())
    }

    /// Версия и проверка обновлений. Ни того, ни другого в интерфейсе не было:
    /// номер версии человек мог узнать только из «О программе» в меню-баре, а
    /// проверить обновления вручную — никак, оставалось ждать автоматической
    /// проверки раз в шесть часов. Для приложения, которое обновляет себя само
    /// и не лежит в App Store, это две вещи, которые спрашивают первыми.
    private func versionRow() -> NSView {
        let version = monoValueLabel("v\(currentBundleVersion())")
        let button: NSButton
        let subtitle: String

        switch updateState {
        case .notChecked:
            subtitle = settings.checkForUpdates
                ? t("Проверка ещё не выполнялась", "No check has run yet")
                : t("Автопроверка выключена", "Automatic checks are off")
            button = panelButton(t("Проверить", "Check"),
                                 action: #selector(updateRowButtonClicked(_:)))
        case .checking:
            subtitle = t("Проверяю обновления…", "Checking for updates…")
            button = panelButton(t("Проверить", "Check"),
                                 action: #selector(updateRowButtonClicked(_:)),
                                 enabled: false)
        case .upToDate:
            subtitle = t("Установлена последняя версия", "This is the latest version")
            button = panelButton(t("Проверить", "Check"),
                                 action: #selector(updateRowButtonClicked(_:)))
        case .available(let release):
            subtitle = t("Доступна версия \(release.version) — скачается, проверится и установится",
                         "Version \(release.version) is available — it downloads, verifies and installs")
            button = panelButton(t("Обновить", "Update"),
                                 action: #selector(updateRowButtonClicked(_:)))
        case .preparing(let target, let phase):
            subtitle = "\(t("Обновляю до", "Updating to")) \(target): \(phase)"
            button = panelButton(t("Обновить", "Update"),
                                 action: #selector(updateRowButtonClicked(_:)),
                                 enabled: false)
        case .failed(let message):
            subtitle = message
            button = panelButton(t("Повторить", "Retry"),
                                 action: #selector(updateRowButtonClicked(_:)))
        }
        button.controlSize = .small

        let control = NSStackView(views: [version, button])
        control.orientation = .horizontal
        control.alignment = .centerY
        control.spacing = 10

        return SDRowView(title: t("Версия", "Version"),
                         subtitle: subtitle,
                         control: control,
                         hairline: false)
    }

    @objc private func updateRowButtonClicked(_ sender: NSButton) {
        switch updateState {
        case .available(let release):
            beginInAppUpdate(for: release)
        case .checking, .preparing:
            return
        case .notChecked, .upToDate, .failed:
            checkForUpdates()
        }
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
            title: t("Альтернативное завершение", "Alternative finish"),
            subtitle: t("Завершает диктовку противоположным действием",
                        "Finishes dictation with the opposite action"),
            control: hotkeyControl(shortcut: draft.alternateCompletionHotkey, kind: .alternateCompletion)
        ))
        // Кнопки «Сохранить» в макете нет: записанное сочетание применяется
        // само, служба перезапускается следом.
        if let notice = hotkeyNotice {
            let noticeLabel = panelLabel(notice, size: 11.5, weight: .medium, color: SD.C.voice)
            noticeLabel.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
                - MAIN_WINDOW_SIDEBAR_WIDTH - 100
            root.setCustomSpacing(12, after: root.arrangedSubviews.last ?? noticeLabel)
            root.addArrangedSubview(noticeLabel)
        }
        let hint = panelLabel(
            t("Клик по «Изменить» — поле слушает клавиши. Esc отменяет. Новое сочетание начинает работать через секунду, перезапускать ничего не нужно.",
              "Click “Change” and press the new combo. Esc cancels. It starts working a second later — nothing needs restarting."),
            size: 11, color: SD.C.graphite)
        hint.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 100
        root.setCustomSpacing(14, after: root.arrangedSubviews.last ?? hint)
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
                detail = t("~460 МБ · русский, английский и ещё 16 языков · Neural Engine",
                           "~460 MB · Russian, English and 16 more · Neural Engine")
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
                t("…и ещё \(corrections.count - 8). Полный список — в разделе «Словарь».",
                  "…and \(corrections.count - 8) more. Full list in the Dictionary section."),
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
        _ = presentCorrectionDialog(heard: "")
        refresh(force: true)
    }

    /// Диалог новой автозамены. `heard` подставляется в первое поле, когда
    /// слово пришло из выделения в «Истории»: человек уже показал его пальцем,
    /// просить набрать заново незачем.
    ///
    /// Возвращает добавленную запись или nil, если человек отменил, оставил
    /// поле пустым или такая замена уже есть. Вызывающий сам решает, как
    /// подтвердить — в «Словаре» новая строка видна сразу, а в «Истории»
    /// подтверждать надо на кнопке.
    @discardableResult
    private func presentCorrectionDialog(heard: String) -> TranscriptCorrection? {
        let alert = NSAlert()
        alert.messageText = t("Новая автозамена", "New correction")
        alert.informativeText = t(
            "Что слышит модель — и что должно быть в тексте. Слово находится "
            + "целиком и в любом регистре, а подставляется ровно так, как "
            + "написано справа. Одна запись чинит одну форму слова: для падежей "
            + "добавьте отдельные записи.",
            "What the model hears — and what the text should say. The word is "
            + "matched whole and in any case, and is replaced exactly as written "
            + "on the right. One entry fixes one form of a word: add separate "
            + "entries for other forms.")
        let sourceField = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24))
        sourceField.placeholderString = t("слышится («супер диктант»)", "heard (“super dictate”)")
        sourceField.stringValue = heard
        let replacementField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        replacementField.placeholderString = t("должно быть (Dictor)", "should be (Dictor)")
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 60))
        holder.addSubview(sourceField)
        holder.addSubview(replacementField)
        alert.accessoryView = holder
        alert.addButton(withTitle: t("Добавить", "Add"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        // Курсор туда, где человеку есть что печатать: услышанное уже стоит.
        alert.window.initialFirstResponder = heard.isEmpty ? sourceField : replacementField
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let source = sourceField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else { return nil }

        let existing = settings.transcriptCorrections
        // `normalizedTranscriptCorrections` схлопнет дубликат молча, и человек
        // решит, что добавление не сработало. Говорим прямо.
        if let clash = existing.first(where: { $0.source.lowercased() == source.lowercased() }) {
            guard confirmCorrectionOverwrite(source: source,
                                             from: clash.replacement,
                                             to: replacement) else { return nil }
        }
        let entry = TranscriptCorrection(source: source, replacement: replacement)
        settings.transcriptCorrections = normalizedTranscriptCorrections(existing + [entry])
        // Содержимое пары в лог не пишется: хвост лога дословно попадает в
        // отчёт диагностики, который обещает «text-correction contents are
        // not included», — и человек прикладывает его к публичным issue.
        log("dictionary: correction added (\(source.count) chars → \(replacement.count) chars)")
        return entry
    }

    private func confirmCorrectionOverwrite(source: String, from: String, to: String) -> Bool {
        guard from != to else { return false }
        let alert = NSAlert()
        alert.messageText = t("«\(source)» уже есть в словаре", "«\(source)» is already in the dictionary")
        alert.informativeText = t("Сейчас заменяется на «\(from)». Заменить на «\(to)»?",
                                  "It is currently replaced with «\(from)». Change it to «\(to)»?")
        alert.addButton(withTitle: t("Заменить", "Replace"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// «В словарь» из «Истории» — из кнопки в шапке или из контекстного меню
    /// текста. Без выделения открывает пустой диалог: кнопка, которая молчит
    /// в ответ на нажатие, читается как сломанная.
    @objc private func addHistorySelectionToDictionary(_ sender: Any?) {
        let heard = (historyDetailTranscriptView?.selectedText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let added = presentCorrectionDialog(heard: heard)
        guard let added else { return }
        if let button = sender as? SDSecondaryButton {
            button.flashTitle(t("Добавлено", "Added"),
                              revertingTo: t("В словарь", "To dictionary"))
        } else {
            // Из контекстного меню подтверждать негде — кнопки под рукой нет.
            let done = NSAlert()
            done.messageText = t("Добавлено в словарь", "Added to the dictionary")
            done.informativeText = t("«\(added.source)» → «\(added.replacement)». "
                                     + "Замена сработает в следующих диктовках.",
                                     "«\(added.source)» → «\(added.replacement)». "
                                     + "It will apply to the next dictations.")
            done.addButton(withTitle: "OK")
            done.runModal()
        }
        // Окно намеренно не пересобирается: «История» от новой записи в
        // словаре не меняется, а пересборка заменила бы кнопку вместе с
        // подтверждением, которое на ней только что появилось. Словарь
        // перечитает настройки, когда человек туда перейдёт.
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
        // «Интернет нужен один раз» перестало быть правдой, когда включился
        // канал обновлений: раз в 6 часов приложение спрашивает версию.
        // Строка ниже говорит, сколько это запросов и за чем именно.
        let sub = panelLabel(
            t("Запись, распознавание и история живут локально. В сеть Dictor выходит за моделью и за обновлениями.",
              "Recording, transcription and history live locally. Dictor goes online for the model and for updates."),
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

        // Значение было зашито как «0 — обновления отключены». Пока проверка
        // стояла за мёртвым `return`, это была правда; в 1.1.0 канал включён,
        // и строка стала бы враньём ровно в той вкладке, где человек решает,
        // насколько приложению верить. Считаем по настройке.
        root.addArrangedSubview(SDRowView(
            title: t("Сетевые запросы", "Network requests"),
            control: monoValueLabel(settings.checkForUpdates
                ? t("1 раз в 6 ч — проверка обновлений",
                    "once every 6 h — update check")
                : t("0 — обновления отключены", "0 — updates disabled")),
            verticalPadding: 12
        ))

        // Раньше здесь стоял один переключатель «Выкл / 1 / 5 / 10» с
        // подписью «Хранить историю», и он врал: цифры никогда не были
        // объёмом хранилища — архив держит до 10 000 диктовок, а 1/5/10
        // ограничивают только список в меню-баре. Во вкладке про
        // приватность это худший из возможных обманов, поэтому теперь
        // две отдельные строки, каждая про своё.
        let historyToggle = SDToggle()
        historyToggle.isOn = settings.recentTranscriptLimit != .off
        historyToggle.onToggle = { [weak self] isOn in
            guard let self else { return }
            self.settings.recentTranscriptLimit = isOn ? self.settings.preferredRecentTranscriptLimit : .off
            self.refresh(force: true)
        }
        root.addArrangedSubview(SDRowView(
            title: t("Хранить историю", "Keep history"),
            subtitle: t("Локально, до \(groupedNumberLabel(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES, language: .russian)) диктовок. Выключить — стереть и больше не записывать",
                        "Locally, up to \(groupedNumberLabel(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES, language: .english)) dictations. Switching off erases them and stops recording"),
            control: historyToggle,
            verticalPadding: 12
        ))

        if settings.recentTranscriptLimit != .off {
            let menuLimits: [RecentTranscriptLimit] = [.last1, .last5, .last10]
            let limitPills = SDPills(options: menuLimits.map {
                .init(title: $0.rawValue, value: $0.rawValue)
            }, selected: settings.recentTranscriptLimit.rawValue)
            limitPills.onSelect = { [weak self] raw in
                guard let limit = RecentTranscriptLimit(rawValue: raw) else { return }
                self?.settings.recentTranscriptLimit = limit
            }
            root.addArrangedSubview(SDRowView(
                title: t("Показывать в меню-баре", "Show in the menu bar"),
                subtitle: t("Сколько последних диктовок в меню. Окно «История» показывает все",
                            "How many recent dictations the menu lists. The History window shows all of them"),
                control: limitPills,
                verticalPadding: 12
            ))
        }

        // Макет: значение здесь обычным шрифтом 12/500, не mono.
        // «Удаляется сразу» без оговорок было полуправдой: на время обработки
        // на диске живёт страховочный журнал, и при сбое он сознательно
        // остаётся — чтобы следующий запуск вернул диктовку в историю.
        let audioRow = SDRowView(
            title: t("Аудио после распознавания", "Audio after transcription"),
            subtitle: t("На время обработки на диске живёт страховочный журнал; при сбое он остаётся, чтобы вернуть диктовку в историю",
                        "A crash-recovery journal lives on disk while a dictation is handled; after a failure it stays so the dictation can be recovered"),
            control: panelLabel(t("Удаляется после вставки", "Deleted once the text exists"),
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

    @objc private func revealModelFilesFromPanel(_ sender: NSButton) {
        NSWorkspace.shared.activateFileViewerSelecting([speechModelCacheBaseDirectory()])
    }

    @objc private func eraseHistoryFromPanel(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Стереть всю историю диктовок?", "Erase all dictation history?")
        alert.informativeText = t("Действие необратимо: сотрутся и закреплённые. Модель и настройки не затрагиваются.",
                                  "This cannot be undone; pinned dictations are erased too. The model and settings stay intact.")
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        alert.addButton(withTitle: t("Стереть", "Erase"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        settings.recentTranscriptEntries = []
        // Пины — полные тексты диктовок в том же plist; «стереть всю
        // историю», оставив их, было бы обратимым ровно наполовину.
        settings.pinnedTranscripts = []
        refresh(force: true)
    }

    // MARK: - Главное окно: история (макет 2b/4a)

    // MARK: - Каркас главного окна (макет 6a)

    /// Сайдбар 212pt + раздел. Сайдбар уходит под тайтлбар, первые 52pt
    /// оставлены под кнопки окна.
    func makeMainWindowView() -> NSView {
        // Онбординг занимает окно целиком: ни сайдбара, ни разделов, пока
        // человек не дошёл до конца или не нажал «Пропустить».
        if let onboardingPage { return onboardingPage }

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
        case .stats:
            content = makeStatsSectionView()
        case .dictionary:
            content = makeDictionarySectionView()
        case .settings:
            content = makeSettingsSectionView()
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
                                         isSelected: section == mainSection,
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

    /// Текущее состояние службы — одно из девяти (макет 8). Раньше их было
    /// два, «готово» и «остановлена», и между ними прятались проверка модели,
    /// её загрузка, прогрев и обновление приложения. После обновления это было
    /// особенно плохо: служба поднимается заново, а подвал утверждал, что она
    /// остановлена, — человек не знал, ждать или чинить.
    ///
    /// Наружу отдаётся не сырое состояние, а выдержавшее паузу (макет 8c):
    /// прогрев и быстрая проверка файлов иначе успевают только мигнуть.
    func currentServiceStatus() -> ServiceStatusKind {
        if let previewStatusOverride { return previewStatusOverride }
        let settled = statusHold.settle(rawServiceStatus())
        scheduleStatusHoldWakeup()
        return settled
    }

    /// Будильник на конец паузы. Без него созревшее состояние ждало бы
    /// очередного тика таймера обновления — до 0,75 с сверх задержки.
    private func scheduleStatusHoldWakeup() {
        statusHoldTimer?.invalidate()
        statusHoldTimer = nil
        guard let deadline = statusHold.pendingDeadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        statusHoldTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func rawServiceStatus() -> ServiceStatusKind {
        let state = AgentRuntimeStateStore.read()
        let running = DictorAgentService.isAgentRunning()

        if state?.isUpdating == true { return .updating }
        if let operation = serviceOperation, operation != .stopping { return .starting }
        if !settings.agentEnabled && !running { return .off }
        if !running { return .failed }

        if let missing = state?.missingPermissions, let first = missing.first,
           let permission = Permission(rawValue: first) {
            return .needsPermission(name: permissionTitle(permission))
        }

        // Служба может работать из бандла прошлой версии — так бывает, когда
        // человек ставит обновление вручную поверх работающего приложения.
        if let running = state?.appVersion, running != currentBundleVersion() {
            return .versionMismatch(running: running, installed: currentBundleVersion())
        }

        switch state?.status {
        case "ready":
            return .ready(latencyMilliseconds: state?.medianLatencyMilliseconds)
        case "error":
            return .failed
        default:
            if let verified = state?.verifiedModelFiles, let total = state?.totalModelFiles {
                return .verifying(done: verified, total: total)
            }
            if state?.speechModelReady == false,
               state?.downloadProgressFraction != nil || state?.downloadedModelFiles != nil {
                return .downloading(fraction: state?.downloadProgressFraction,
                                    files: state?.downloadedModelFiles,
                                    totalFiles: state?.totalDownloadModelFiles)
            }
            if state?.speechModelReady == true { return .warmingUp }
            return .starting
        }
    }

    /// Низ сайдбара по макету 8a. Маркер 7×7 в 16 px от края, заголовок 11,5,
    /// вторая строка 11 — и то, и другое всегда на одном месте: меняется
    /// только форма маркера, движение и высота подвала.
    private func makeSidebarStatusView() -> NSView {
        let kind = currentServiceStatus()
        let view = serviceStatusPresentation(kind, language: language)

        let marker = ServiceStatusMarkerView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .ready: marker.shape = .dot(SD.C.positive)
        case .versionMismatch: marker.shape = .hollowSquare
        case .off: marker.shape = .hollowRing
        case .needsPermission: marker.shape = .hollowSquare
        case .failed: marker.shape = .filledSquare(SD.C.danger)
        default: marker.shape = .wave(slow: kind.waveIsSlow)
        }

        let titleLabel = panelLabel(view.title,
                                    size: 11.5,
                                    weight: view.wantsAttention ? .semibold : .regular,
                                    color: view.wantsAttention
                                        ? SD.C.ink
                                        : (kind == .off ? SD.C.subtle : SD.C.inkSecondary))
        titleLabel.lineBreakMode = .byTruncatingTail

        let head = NSStackView(views: [marker, titleLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        let detail = panelLabel(view.subtitle, size: 11,
                                color: kind == .off ? SD.C.hintText : SD.C.subtle)
        // Две строки и перенос по словам: «Parakeet · локально · отклик 180 мс»
        // в 188 px одной строкой не помещается, а многоточие вместо числа —
        // ровно та подпись, ради которой строка и нужна.
        detail.maximumNumberOfLines = 2
        detail.preferredMaxLayoutWidth = 188

        let hairline = SDHairlineView()
        let column = NSStackView(views: [hairline, head, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 14, right: 16)
        column.setCustomSpacing(14, after: hairline)
        column.translatesAutoresizingMaskIntoConstraints = false

        // Прогресс: засечки по числу файлов модели либо сплошная полоса
        // загрузки. И то, и другое — под второй строкой, с отступом 7.
        if let ticks = view.ticks {
            let ticksView = ServiceStatusTicksView()
            ticksView.done = ticks.done
            ticksView.total = ticks.total
            ticksView.translatesAutoresizingMaskIntoConstraints = false
            ticksView.heightAnchor.constraint(equalToConstant: 5).isActive = true
            column.addArrangedSubview(ticksView)
            column.setCustomSpacing(7, after: detail)
            ticksView.widthAnchor.constraint(equalToConstant: 188).isActive = true
        } else if let fraction = view.progressFraction {
            let bar = ServiceStatusProgressView()
            bar.fraction = fraction
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
            column.addArrangedSubview(bar)
            column.setCustomSpacing(7, after: detail)
            bar.widthAnchor.constraint(equalToConstant: 188).isActive = true
        }

        // Кнопка есть только там, где нужен человек, — она и есть сигнал.
        if let primary = view.primaryAction {
            let button = SDSolidButton(title: primary,
                                       target: self,
                                       action: #selector(serviceStatusPrimaryClicked(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            if let secondary = view.secondaryAction {
                let quiet = SDSecondaryButton(title: secondary,
                                              target: self,
                                              action: #selector(serviceStatusSecondaryClicked(_:)))
                quiet.translatesAutoresizingMaskIntoConstraints = false
                quiet.heightAnchor.constraint(equalToConstant: 24).isActive = true
                let row = NSStackView(views: [button, quiet])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                row.distribution = .fill
                // Главная кнопка занимает остаток строки, тихая — по тексту.
                // Без этого «Запустить» сжималась до многоточия.
                quiet.setContentHuggingPriority(.required, for: .horizontal)
                quiet.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.translatesAutoresizingMaskIntoConstraints = false
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 188).isActive = true
            } else {
                column.addArrangedSubview(button)
                button.widthAnchor.constraint(equalToConstant: 188).isActive = true
            }
            column.setCustomSpacing(8, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])
        }

        let container = ServiceStatusFooterView()
        // Подложка лёгким тревожным цветом — только у отказа. У «нужен доступ»
        // подложки нет: это ожидание действия, а не поломка.
        container.fill = kind == .failed ? SD.C.dangerWash : .clear
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

    /// Точка входа для рендера: собирает подвал для заданного состояния,
    /// не спрашивая живую службу.
    func serviceStatusFooterPreview(for kind: ServiceStatusKind,
                                    language: InterfaceLanguage) -> NSView {
        previewStatusOverride = kind
        defer { previewStatusOverride = nil }
        return makeSidebarStatusView()
    }

    @objc private func serviceStatusPrimaryClicked(_ sender: Any?) {
        switch currentServiceStatus() {
        case .needsPermission:
            mainSection = .settings
            settingsTab = "advanced"
            settingsDraft = ControlPanelSettingsDraft(settings: settings)
            refresh(force: true)
        case .failed:
            settings.agentEnabled = true
            _ = settings.refreshFromDisk()
            beginServiceOperation(.starting)
        case .versionMismatch:
            beginServiceOperation(.restarting)
        default:
            break
        }
    }

    @objc private func serviceStatusSecondaryClicked(_ sender: Any?) {
        mainSection = .settings
        settingsTab = "advanced"
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        refresh(force: true)
    }

    /// Поповер попросил открыть раздел в уже запущенном окне.
    @objc private func openSectionRequested(_ notification: Notification) {
        guard let raw = notification.object as? String,
              let section = MainWindowSection(rawValue: raw) else { return }
        if section == .settings {
            settingsDraft = ControlPanelSettingsDraft(settings: settings)
        }
        mainSection = section
        hotkeyNotice = nil
        refresh(force: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Служба уходит и уводит окно за собой. Останавливать её отсюда не надо —
    /// она уже сняла себя сама, а повторный bootout из второго процесса только
    /// гонялся бы за уже мёртвым джобом.
    @objc private func quitRequestedByAgent(_ notification: Notification) {
        log("control panel: quitting because the menu-bar app is quitting")
        NSApp.terminate(nil)
    }

    /// ⌘Q и «Выйти из Dictor» в меню окна. Раньше выход из окна оставлял
    /// службу работать: иконка в меню-баре, живой хоткей и процесс, который
    /// человек только что попросил закрыть. Спрашиваем, потому что диктовка
    /// перестанет работать до следующего запуска, и потому что рядом есть
    /// «Закрыть окно» — ровно для случая «уберите с глаз, но не выключайте».
    @objc private func quitEverythingClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Выйти из Dictor?", "Quit Dictor?")
        alert.informativeText = t(
            "Диктовка по \(settings.configuredHotkey.name) перестанет работать, пока вы не "
            + "откроете Dictor снова. Чтобы убрать окно и оставить диктовку — "
            + "«Закрыть окно» (⌘W).",
            "Dictation on \(settings.configuredHotkey.name) will stop until you open Dictor "
            + "again. To hide the window and keep dictation running, use Close "
            + "Window (⌘W).")
        alert.addButton(withTitle: t("Оставить работать", "Keep Running"))
        alert.addButton(withTitle: t("Выйти", "Quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        log("control panel: quitting the app and the dictation service")
        // Здесь ждать можно: это окно, а не агент. Дедлок ловил только сам
        // агент, который своим bootout ждал собственной смерти.
        DictorAgentService.stop()
        settings.agentEnabled = false
        NSApp.terminate(nil)
    }

    @objc private func sidebarItemClicked(_ sender: SDSidebarItemView) {
        guard sender.section != mainSection else { return }
        if sender.section == .settings {
            settingsDraft = ControlPanelSettingsDraft(settings: settings)
        } else {
            hotkeyRecorder?.cancel()
            hotkeyRecorder = nil
            settingsDraft = nil
        }
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

        if entryCount >= 3, !dismissed.contains("history-section") {
            return TodayHint(
                identifier: "history-section",
                text: t("Каждая диктовка остаётся в истории — её можно найти и скопировать целиком или по кусочку.",
                        "Every dictation stays in History — find it there and copy all of it or just a piece."),
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

    /// Из «Сегодня» — в «Историю», на ту же самую запись. В строке текст
    /// обрезан одной строкой, и длинную диктовку прочесть больше негде.
    @objc private func todayRecentRowOpen(_ sender: SDRecentEntryRowView) {
        let entries = settings.recentTranscriptEntries
        guard entries.indices.contains(sender.entryIndex) else { return }
        // Поиск в «Истории» мог остаться набранным с прошлого раза — с ним
        // выбранная запись не попадёт в список и выбор будет не виден.
        mainHistorySearch = ""
        historySelectionKey = historyEntryKey(entries[sender.entryIndex])
        mainSection = .history
        refresh(force: true)
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

    // MARK: - Раздел «Статистика» (макеты 7a/7b/7c)

    private func makeStatsSectionView() -> NSView {
        let summary = StatsCalculator.summary(period: statsPeriod,
                                              usage: settings.dailyDictationUsage,
                                              entries: settings.recentTranscriptEntries,
                                              language: language)
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        // Шапка: заголовок, переключатель периодов, подпись периода и экспорт.
        let periodPills = SDPills(options: StatsPeriod.allCases.map {
            .init(title: $0.title(language), value: $0.rawValue)
        }, selected: statsPeriod.rawValue)
        periodPills.onSelect = { [weak self] raw in
            guard let period = StatsPeriod(rawValue: raw) else { return }
            self?.statsPeriod = period
            self?.refresh(force: true)
        }
        let periodLabel = panelLabel(summary.periodTitle, size: 12.5, color: SD.C.inkSecondary)
        let export = NSButton(title: t("Экспорт CSV", "Export CSV"),
                              target: self,
                              action: #selector(exportStatsCSVClicked(_:)))
        export.isBordered = false
        export.font = .systemFont(ofSize: 12.5)
        export.contentTintColor = SD.C.voice
        let headerRight = NSStackView(views: [periodLabel, export])
        headerRight.orientation = .horizontal
        headerRight.alignment = .centerY
        headerRight.spacing = 12

        let header = NSView()
        let headerTitle = panelLabel(MainWindowSection.stats.title(language),
                                     size: 14, weight: .semibold, color: SD.C.ink)
        for view in [headerTitle, periodPills, headerRight] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let headerHairline = SDHairlineView()
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerHairline)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            periodPills.leadingAnchor.constraint(equalTo: headerTitle.trailingAnchor, constant: 12),
            periodPills.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerRight.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            headerRight.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerRight.leadingAnchor.constraint(greaterThanOrEqualTo: periodPills.trailingAnchor,
                                                 constant: 12),
            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false

        let cards = statsHeadlineCards(summary)
        column.addArrangedSubview(cards)
        column.setCustomSpacing(18, after: cards)

        let chart = statsChartCard(summary)
        column.addArrangedSubview(chart)
        column.setCustomSpacing(16, after: chart)

        let habitAndHours = NSStackView(views: [statsHabitCard(summary),
                                                statsHoursCard(summary)])
        habitAndHours.orientation = .horizontal
        habitAndHours.distribution = .fillEqually
        habitAndHours.alignment = .top
        habitAndHours.spacing = 12
        column.addArrangedSubview(habitAndHours)

        // Годовой разрез (7c) показываем там, где он уместен.
        if statsPeriod == .year || statsPeriod == .all {
            column.setCustomSpacing(16, after: habitAndHours)
            let year = statsYearCard(summary)
            column.addArrangedSubview(year)
            year.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }

        for view in [cards, chart, habitAndHours] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }

        let documentView = SDFlippedView()
        documentView.addSubview(column)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: documentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Четыре показателя вверху. «Правок %» из макета нет — учёта правок
    /// после вставки движок не ведёт, поэтому вместо выдуманного числа
    /// показываем количество диктовок.
    private func statsHeadlineCards(_ summary: StatsSummary) -> NSView {
        let wordsCard = SDStatCardView(
            caption: t("Слов за период", "Words this period"),
            value: formattedUsageInteger(summary.words),
            delta: summary.deltaPercent.map {
                SDStatCardView.Delta(text: $0 >= 0 ? "+\($0)%" : "\($0)%",
                                     isPositive: $0 >= 0)
            },
            footnote: summary.previousWords > 0
                ? t("было \(formattedUsageInteger(summary.previousWords))",
                    "was \(formattedUsageInteger(summary.previousWords))")
                : t("не с чем сравнить", "nothing to compare with"))

        let savedValue = String(format: "%.1f", summary.savedHours)
            .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
        let savedCard = SDStatCardView(
            caption: t("Сэкономлено", "Time saved"),
            value: savedValue,
            unit: t("ч", "h"),
            footnote: summary.workingDays >= 0.1
                ? t("≈ \(String(format: "%.1f", summary.workingDays).replacingOccurrences(of: ".", with: ",")) рабочих дня",
                    "≈ \(String(format: "%.1f", summary.workingDays)) working days")
                : t("считаем от 40 слов/мин на клавиатуре",
                    "assuming 40 wpm typing"))

        let speedCard = SDStatCardView(
            caption: t("Скорость речи", "Speech rate"),
            value: summary.speechWordsPerMinute > 0 ? "\(summary.speechWordsPerMinute)" : "—",
            unit: t("сл/мин", "wpm"),
            footnote: t("на клавиатуре считаем 40", "keyboard assumed at 40"))

        let countCard = SDStatCardView(
            caption: t("Диктовок", "Dictations"),
            value: formattedUsageInteger(summary.dictationCount),
            footnote: summary.averageDictationSeconds > 0
                ? t("в среднем \(statsDurationText(summary.averageDictationSeconds))",
                    "\(statsDurationText(summary.averageDictationSeconds)) on average")
                : t("пока нет данных", "no data yet"))

        let row = NSStackView(views: [wordsCard, savedCard, speedCard, countCard])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false
        // 16 + подпись 13 + 8 + число 36 + 10 + сноска 14 + 16 (макет 7a).
        row.heightAnchor.constraint(equalToConstant: 116).isActive = true
        return row
    }

    private func statsChartCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(statsChartTitle(), size: 12.5, weight: .semibold, color: SD.C.ink)
        var peakText: String?
        if let index = summary.peakBucketIndex, summary.buckets[index].words > 0 {
            peakText = formattedUsageInteger(summary.buckets[index].words)
        }
        let subtitle = panelLabel(
            peakText.map { t("пик — \($0) слов", "peak — \($0) words") }
                ?? t("пока пусто", "no data yet"),
            size: 11.5, color: SD.C.subtle)

        let legendCurrent = statsLegendItem(color: SD.C.voice,
                                            text: t("сейчас", "current"))
        let legendPrevious = statsLegendItem(
            color: NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.14)
                    : NSColor.black.withAlphaComponent(0.1)
            },
            text: t("прошлый период", "previous"))
        let legend = NSStackView(views: [legendCurrent, legendPrevious])
        legend.orientation = .horizontal
        legend.spacing = 12

        let head = NSStackView(views: [title, subtitle, NSView(), legend])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10

        let chart = SDComparisonBarChart(buckets: summary.buckets,
                                         peakIndex: summary.peakBucketIndex,
                                         peakText: peakText)
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 168).isActive = true

        let column = NSStackView(views: [head, chart])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [head, chart] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        return card
    }

    private func statsLegendItem(color: NSColor, text: String) -> NSView {
        let swatch = SDLegendSwatch(color: color)
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let label = panelLabel(text, size: 11, color: SD.C.graphite)
        let row = NSStackView(views: [swatch, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        return row
    }

    private func statsChartTitle() -> String {
        switch statsPeriod {
        case .week: return t("Слов по дням", "Words by day")
        case .month: return t("Слов по дням", "Words by day")
        case .quarter: return t("Слов по неделям", "Words by week")
        case .year, .all: return t("Слов по месяцам", "Words by month")
        }
    }

    private func statsHabitCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(t("Привычка", "Habit"), size: 12.5, weight: .semibold, color: SD.C.ink)
        let streakText: String
        if summary.currentStreak > 0 {
            streakText = t("\(summary.currentStreak) дней подряд · лучший результат \(summary.bestStreak)",
                           "\(summary.currentStreak)-day streak · best \(summary.bestStreak)")
        } else {
            streakText = t("серии пока нет", "no streak yet")
        }
        let subtitle = panelLabel(streakText, size: 11.5, color: SD.C.subtle)
        let head = NSStackView(views: [title, subtitle])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10

        let heatmap = SDHabitHeatmapView(days: summary.habit)
        heatmap.translatesAutoresizingMaskIntoConstraints = false
        heatmap.heightAnchor.constraint(equalToConstant: 7 * 14 - 3).isActive = true

        let note = panelLabel(
            t("Каждый квадрат — день, насыщенность — сколько слов. Выходные обычно пустые, и это нормально.",
              "Each square is a day; the darker it is, the more words. Empty weekends are fine."),
            size: 11.5, color: SD.C.graphite)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 320

        let column = NSStackView(views: [head, heatmap, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 15, right: 17)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [head, heatmap, note] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -34).isActive = true
        }
        return card
    }

    private func statsHoursCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(t("Когда диктуете", "When you dictate"),
                               size: 12.5, weight: .semibold, color: SD.C.ink)
        let histogram = SDHourHistogramView(values: summary.hourly)
        histogram.translatesAutoresizingMaskIntoConstraints = false
        histogram.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let peakHour = summary.hourly.enumerated().max(by: { $0.element < $1.element })
        let noteText: String
        if summary.hourlySampleCount == 0 {
            noteText = t("Считается по времени записей истории — за этот период их пока нет.",
                         "Built from history timestamps — none in this period yet.")
        } else if let peakHour, peakHour.element > 0 {
            noteText = t("Больше всего — около \(peakHour.offset):00. По \(summary.hourlySampleCount) записям истории.",
                         "Busiest around \(peakHour.offset):00, from \(summary.hourlySampleCount) history entries.")
        } else {
            noteText = t("Пока недостаточно записей.", "Not enough entries yet.")
        }
        let note = panelLabel(noteText, size: 11.5, color: SD.C.graphite)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 320

        let column = NSStackView(views: [title, histogram, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 15, right: 17)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [title, histogram, note] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -34).isActive = true
        }
        return card
    }

    /// Год по кварталам и честный итог (макет 7c).
    private func statsYearCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(t("По кварталам", "By quarter"),
                               size: 12.5, weight: .semibold, color: SD.C.ink)
        var sinceText = ""
        if let first = summary.firstDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
            formatter.dateFormat = "d MMMM"
            sinceText = t("данные с \(formatter.string(from: first))",
                          "data since \(formatter.string(from: first))")
        }
        let since = panelLabel(sinceText, size: 11.5, color: SD.C.subtle)
        let head = NSStackView(views: [title, NSView(), since])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10

        let bars = SDQuarterBarsView(quarters: summary.quarters, language: language)
        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.heightAnchor.constraint(equalToConstant: 4 * 26 + 3 * 10).isActive = true

        let totalWords = summary.quarters.reduce(0) { $0 + $1.words }
        let totalHours = summary.quarters.reduce(0.0) { $0 + $1.savedHours }
        let conclusion = panelLabel(statsYearConclusion(words: totalWords, hours: totalHours),
                                    size: 15, color: SD.C.ink)
        conclusion.lineBreakMode = .byWordWrapping
        conclusion.maximumNumberOfLines = 3
        conclusion.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 120

        let reset = SDSecondaryButton(title: t("Сбросить статистику", "Reset statistics"),
                                      target: self,
                                      action: #selector(resetStatsClicked(_:)))
        let actions = NSStackView(views: [reset, NSView()])
        actions.orientation = .horizontal
        actions.spacing = 10

        let tone = panelLabel(
            t("Ни одна цифра не считается «нормой» и ни за что не ругает. Упал график — приложение молчит.",
              "No number here is a target, and nothing scolds you. If the chart dips, the app stays quiet."),
            size: 11.5, color: SD.C.graphite)
        tone.lineBreakMode = .byWordWrapping
        tone.maximumNumberOfLines = 3
        tone.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 120

        let column = NSStackView(views: [head, bars, conclusion, actions, tone])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 16, right: 17)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [head, bars, conclusion, tone] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -34).isActive = true
        }
        return card
    }

    private func statsYearConclusion(words: Int, hours: Double) -> String {
        guard words > 0 else {
            return t("Пока считать нечего — данные появятся после первых диктовок.",
                     "Nothing to sum up yet — numbers appear after your first dictations.")
        }
        let hoursText = String(format: "%.1f", hours)
            .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
        return t("\(formattedUsageInteger(words)) слов голосом — это \(hoursText) часа, которые не ушли на клавиатуру.",
                 "\(formattedUsageInteger(words)) words by voice — \(hoursText) hours that never went to the keyboard.")
    }

    private func statsDurationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func exportStatsCSVClicked(_ sender: NSButton) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dictor-stats.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "day,dictations,characters,words,audio_seconds,asr_seconds\n"
        for day in settings.dailyDictationUsage.sorted(by: { $0.day < $1.day }) {
            let words = approximateWordCount(characters: day.characterCount)
            csv += "\(day.day),\(day.dictationCount),\(day.characterCount),\(words),"
            csv += String(format: "%.1f,%.1f\n", day.audioSeconds, day.asrSeconds)
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(title: t("Не удалось сохранить файл", "Could not save the file"),
                      detail: error.localizedDescription)
        }
    }

    @objc private func resetStatsClicked(_ sender: NSControl) {
        let alert = NSAlert()
        alert.messageText = t("Сбросить статистику?", "Reset statistics?")
        alert.informativeText = t(
            "Посуточные счётчики будут удалены навсегда. История диктовок останется на месте.",
            "The daily counters are deleted for good. Your dictation history stays.")
        alert.addButton(withTitle: t("Сбросить", "Reset"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.dailyDictationUsage = []
        refresh(force: true)
    }

    // MARK: - Раздел «Настройки» (макет 2c/4b/6d внутри окна 6a)

    /// Настройки — такой же раздел окна, как «Сегодня» и «История».
    /// Отдельного окна больше нет: в макете 6a это пункт сайдбара.
    private func makeSettingsSectionView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper
        let header = makeSectionHeader(title: MainWindowSection.settings.title(language),
                                       accessory: nil)

        let content = makeSettingsContentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let paneWidth = MAIN_WINDOW_SIZE.width - MAIN_WINDOW_SIDEBAR_WIDTH - 1
        let contentHeight = Self.settingsContentHeight(for: content, width: paneWidth)

        let documentView = SDFlippedView()
        documentView.addSubview(content)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.heightAnchor.constraint(equalToConstant: contentHeight),
            documentView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
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

        // Встроенные наборы правят текст молча, поэтому о них надо сказать
        // вслух — и дать выключить. Обе карточки устроены одинаково.
        func toggleCard(title: String,
                        subtitle: String,
                        isOn: Bool,
                        onToggle: @escaping (Bool) -> Void) -> NSView {
            let toggle = SDToggle()
            toggle.isOn = isOn
            toggle.onToggle = onToggle
            let cardBackground = SDCardBackgroundView()
            let row = SDRowView(title: title,
                                subtitle: subtitle,
                                control: toggle,
                                hairline: false)
            row.translatesAutoresizingMaskIntoConstraints = false
            cardBackground.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: cardBackground.leadingAnchor,
                                             constant: 16),
                row.trailingAnchor.constraint(equalTo: cardBackground.trailingAnchor,
                                              constant: -16),
                row.topAnchor.constraint(equalTo: cardBackground.topAnchor, constant: 4),
                row.bottomAnchor.constraint(equalTo: cardBackground.bottomAnchor,
                                            constant: -4),
            ])
            return cardBackground
        }

        let spellingsCard = toggleCard(
            title: t("Написание названий", "Name spelling"),
            subtitle: t("\(BuiltInSpellings.count) технических названий пишутся правильно: "
                        + "postgres → PostgreSQL, sql → SQL, macos → macOS",
                        "\(BuiltInSpellings.count) technical names come out spelled properly: "
                        + "postgres → PostgreSQL, sql → SQL, macos → macOS"),
            isOn: settings.builtInSpellingsEnabled,
            onToggle: { [weak self] enabled in
                self?.settings.builtInSpellingsEnabled = enabled
            })

        // Второй набор меняет алфавит, а не форму записи, — и это заметнее.
        // Пример в подписи именно поэтому: человек должен увидеть, что
        // произойдёт с его текстом, до того как это произойдёт.
        let restorationsCard = toggleCard(
            title: t("Названия латиницей", "Names in Latin script"),
            subtitle: t("\(LatinTermRestorations.count) названий, услышанных по-русски, "
                        + "возвращаются к своему написанию: гитхаб → GitHub, "
                        + "постгрес → PostgreSQL",
                        "\(LatinTermRestorations.count) names heard in Russian go back to "
                        + "their own spelling: гитхаб → GitHub, постгрес → PostgreSQL"),
            isOn: settings.latinTermRestorationsEnabled,
            onToggle: { [weak self] enabled in
                self?.settings.latinTermRestorationsEnabled = enabled
            })

        let column = NSStackView(views: [card, spellingsCard, restorationsCard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
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
        spellingsCard.widthAnchor.constraint(equalTo: column.widthAnchor,
                                             constant: -56).isActive = true
        restorationsCard.widthAnchor.constraint(equalTo: column.widthAnchor,
                                                constant: -56).isActive = true
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
                    entryIndex: index,
                    preview: entry.text.replacingOccurrences(of: "\n", with: " "),
                    time: recentEntryTimeText(entry),
                    copyTooltip: t("Копировать", "Copy"),
                    openTooltip: t("Открыть целиком в «Истории»", "Open in full in History"),
                    target: self,
                    copyAction: #selector(todayRecentRowClicked(_:)),
                    openAction: #selector(todayRecentRowOpen(_:)))
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
        // Системный крестик очистки тоже убираем — и вот почему. Поле без
        // рамки (isBordered = false) кладёт редактор текста на всю свою
        // площадь: замерено — редактор −2,5…361,5 при кнопке на 334…356.
        // Крестик рисуется, но попадание мыши достаётся NSTextView, и кнопка
        // не получает ни одного нажатия. Нарисованная и не работающая кнопка
        // хуже её отсутствия, поэтому крестик у нас свой.
        (search.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(magnifier)
        searchBox.addSubview(search)
        NSLayoutConstraint.activate([
            searchBox.heightAnchor.constraint(equalToConstant: 30),
            magnifier.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 11),
            magnifier.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 8),
            search.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
        ])

        // Крестик появляется только когда есть что стирать.
        if mainHistorySearch.isEmpty {
            search.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor,
                                             constant: -10).isActive = true
        } else {
            let clear = NSButton(title: "×",
                                 target: self,
                                 action: #selector(clearMainHistorySearch(_:)))
            clear.isBordered = false
            clear.font = .systemFont(ofSize: 15)
            clear.contentTintColor = SD.C.subtle
            clear.setButtonType(.momentaryChange)
            clear.toolTip = t("Очистить поиск", "Clear search")
            clear.translatesAutoresizingMaskIntoConstraints = false
            searchBox.addSubview(clear)
            NSLayoutConstraint.activate([
                clear.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -6),
                clear.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
                clear.widthAnchor.constraint(equalToConstant: 22),
                clear.heightAnchor.constraint(equalToConstant: 22),
                // −8, а не −4: раскладка считает поле по alignment rect, а он
                // уже настоящего кадра, и редактор текста вылезает за границы
                // поля на пару точек. Впритык кнопка снова оказалась бы под
                // текстом.
                search.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            ])
        }

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
        // Словарь чинит то, что модель услышала не так, а видно это здесь —
        // в собственной расшифровке. Кнопка работает и без выделения (откроет
        // пустой диалог), поэтому её состояние не зависит от того, что сейчас
        // выделено: окно во время выделения намеренно не пересобирается.
        let dictionaryButton = SDSecondaryButton(
            title: t("В словарь", "To dictionary"),
            target: self,
            action: #selector(addHistorySelectionToDictionary(_:)))
        let deleteButton = SDSecondaryButton(title: t("Удалить", "Delete"),
                                             target: self,
                                             action: #selector(deleteSelectedHistoryEntry(_:)))
        deleteButton.tag = index

        let actions = NSStackView(views: [copyButton, pinButton, dictionaryButton,
                                          NSView(), deleteButton])
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

        // Полный текст: 16/1.6, выделяемый — его забирают мышью, по слову
        // и по строке, а не только целиком кнопкой «Копировать».
        let body = SDSelectableTranscriptView(text: entry.text,
                                              font: .systemFont(ofSize: 16),
                                              color: SD.C.ink,
                                              lineHeightMultiple: 1.6)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setDictionaryItem(title: t("В словарь…", "Add to Dictionary…"),
                               target: self,
                               action: #selector(addHistorySelectionToDictionary(_:)))
        historyDetailTranscriptView = body

        metaRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(metaRow)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            metaRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            metaRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
            metaRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            body.topAnchor.constraint(equalTo: metaRow.bottomAnchor, constant: 14),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
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
        guard let (_, entry) = selectedHistoryEntry(among: filteredMainHistory()) else {
            log("history copy from window: nothing selected")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        log("history entry copied from window (\(entry.text.count) chars)")
        (sender as? SDPrimaryActionButton)?.flashTitle(
            t("Скопировано", "Copied"),
            revertingTo: t("Копировать", "Copy"))
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

    @objc private func clearMainHistorySearch(_ sender: NSButton) {
        mainHistorySearch = ""
        mainHistorySearchField?.stringValue = ""
        refresh(force: true)
    }

    private func deleteMainHistoryEntry(at index: Int) {
        var entries = settings.recentTranscriptEntries
        guard entries.indices.contains(index) else { return }
        let removed = entries.remove(at: index)
        settings.recentTranscriptEntries = entries
        // Явное удаление сильнее закрепления: без снятия пина его текст
        // оставался в plist невидимкой — фильтр «Закреплённые» ищет пины
        // только среди записей архива.
        if !entries.contains(where: { $0.text == removed.text }) {
            settings.pinnedTranscripts = settings.pinnedTranscripts.filter { $0 != removed.text }
        }
        if historySelectionKey == historyEntryKey(removed) {
            historySelectionKey = nil
        }
        refresh(force: true)
    }

    private func addLookTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        // Плавающая капсула (макет 6c). Выключена по умолчанию: это объект
        // поверх чужих окон, и появляться он должен по приглашению.
        let capsuleToggle = SDToggle()
        capsuleToggle.isOn = settings.floatingCapsuleEnabled
        capsuleToggle.onToggle = { [weak self] enabled in
            self?.settings.floatingCapsuleEnabled = enabled
        }
        root.addArrangedSubview(SDRowView(
            title: t("Плавающая капсула", "Floating capsule"),
            subtitle: t("Всегда под рукой: перетаскивается, прилипает к краям и помнит место",
                        "Always at hand: drag it, it sticks to the edges and remembers its place"),
            control: capsuleToggle
        ))

        // Размер капсулы переехал в «Продвинутые» — там он стоит рядом с
        // положением и живым превью, как в макете 6d. Два места для одной
        // настройки неизбежно начинают расходиться.
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





    // MARK: - Вкладка «Продвинутые» (макет 6d)
    //
    // Из макета сюда сознательно не перенесены четыре элемента, под
    // которыми нет ни данных, ни поведения:
    //
    // • «В покое» (прозрачность) и «Прятать капсулу» — управляют
    //   капсулой, которой между диктовками не существует. Обе строки
    //   требуют постоянной плавающей капсулы из макета 6c.
    // • «Перетащите капсулу мышью» — то же самое: тащить нечего.
    // • «Предлагать слова в словарь» — такой функции в приложении нет,
    //   тумблер включал бы пустоту.
    //
    // «Системные уведомления» и «Держать модель в памяти» остались, но
    // как факты, а не тумблеры: уведомлений приложение не шлёт вообще,
    // а модель и так никогда не выгружается, кроме смены модели. Тумблер,
    // который ничего не переключает, врёт убедительнее отсутствующего.
    private func addAdvancedTabRows(to root: NSStackView) {
        addPermissionsSection(to: root)
        root.addArrangedSubview(advancedSectionHeader(t("Капсула", "Capsule")))

        // Размер — с живым превью справа: переключение S/M/L видно сразу,
        // не открывая диктовку.
        let preview = SDCapsulePreview(size: settings.recordingHUDSize)
        let sizes: [RecordingHUDSize] = [.compact, .standard, .large]
        let sizeSegmented = SDSegmented(titles: ["S", "M", "L"],
                                        values: sizes.map(\.rawValue),
                                        selected: settings.recordingHUDSize.rawValue)
        sizeSegmented.onSelect = { [weak self, weak preview] raw in
            guard let size = RecordingHUDSize(rawValue: raw) else { return }
            self?.settings.recordingHUDSize = size
            preview?.setSize(size)
        }
        root.addArrangedSubview(advancedCapsuleRow(title: t("Размер", "Size"),
                                                   control: sizeSegmented,
                                                   trailing: preview))

        let placement = NSPopUpButton()
        placement.isBordered = false
        placement.font = .systemFont(ofSize: 12.5)
        placement.contentTintColor = SD.C.ink
        let placements: [(RecordingHUDPlacement, String)] = [
            (.followsInput, t("У поля ввода", "At the text field")),
            (.bottomCenter, t("Снизу по центру", "Bottom center")),
            (.topCenter, t("Сверху по центру", "Top center")),
        ]
        for (value, title) in placements {
            placement.addItem(withTitle: title)
            placement.lastItem?.identifier = NSUserInterfaceItemIdentifier(value.rawValue)
        }
        placement.selectItem(at: placements.firstIndex { $0.0 == settings.recordingHUDPlacement } ?? 0)
        placement.target = self
        placement.action = #selector(capsulePlacementChanged(_:))
        // Макет предлагал ещё и «перетащите капсулу мышью». Тащить нечего:
        // между диктовками капсулы не существует, это макет 6c. Вместо
        // выдуманной подсказки — правда о запасном варианте.
        let placementHint = panelLabel(t("Если поле ввода не найдено — сверху по центру",
                                         "If no text field is found — top center"),
                                       size: 11.5, color: SD.C.subtle)
        root.addArrangedSubview(advancedCapsuleRow(title: t("Положение", "Position"),
                                                   control: placement,
                                                   trailing: placementHint))

        root.addArrangedSubview(advancedSectionHeader(t("Тишина", "Silence")))
        let silenceNote = panelLabel(
            t("По умолчанию приложение молчит: ни баннеров, ни звуков. Всё, что нужно сказать, показывает сама капсула.",
              "The app stays quiet by default: no banners, no sounds. Anything worth saying, the capsule says itself."),
            size: 11.5, color: SD.C.graphite)
        silenceNote.maximumNumberOfLines = 2
        silenceNote.preferredMaxLayoutWidth = 470
        let noteRow = NSStackView(views: [silenceNote])
        noteRow.orientation = .vertical
        noteRow.alignment = .leading
        noteRow.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        root.addArrangedSubview(noteRow)

        root.addArrangedSubview(SDRowView(
            title: t("Системные уведомления", "System notifications"),
            control: panelLabel(t("Не отправляются", "Never sent"), size: 12, weight: .medium),
            verticalPadding: 12
        ))

        // Тумблер звуков живёт во вкладке «Основное» и только там. Здесь стоял
        // второй, для той же настройки: два места неизбежно начинают
        // расходиться — сначала подписью, потом поведением.

        root.addArrangedSubview(advancedSectionHeader(t("Производительность", "Performance")))
        root.addArrangedSubview(performanceTilesRow())

        root.addArrangedSubview(SDRowView(
            title: t("Модель в памяти", "Model in memory"),
            subtitle: t("Выгружается только при смене модели — первая диктовка без задержки",
                        "Unloaded only when the model changes — the first dictation has no warm-up"),
            control: panelLabel(t("Всегда", "Always"), size: 12, weight: .medium),
            hairline: false,
            verticalPadding: 12
        ))
    }

    @objc private func capsulePlacementChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.identifier?.rawValue,
              let placement = RecordingHUDPlacement(rawValue: raw) else { return }
        settings.recordingHUDPlacement = placement
    }

    /// Строка секции «Капсула» из макета: подпись фиксированной ширины 96,
    /// сразу за ней контрол, а всё остальное прижато вправо.
    private func advancedCapsuleRow(title: String,
                                    control: NSView,
                                    trailing: NSView) -> NSView {
        let row = NSView()
        let label = panelLabel(title, size: 12.5)
        label.textColor = SD.C.ink
        for view in [label, control, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        let hairline = SDHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hairline)

        let squeeze = row.heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow
        NSLayoutConstraint.activate([
            squeeze,
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 96),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: control.trailingAnchor,
                                              constant: 16),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor, constant: 10),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: trailing.bottomAnchor, constant: 10),
            hairline.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    /// Разрешения и их починка. Живут в «Продвинутых», потому что сюда идут
    /// именно тогда, когда что-то не работает.
    private func addPermissionsSection(to root: NSStackView) {
        let report = PermissionsDoctor.report()
        root.addArrangedSubview(advancedSectionHeader(t("Разрешения macOS", "macOS permissions")))

        for (index, row) in report.rows.enumerated() {
            let copy = onboardingPermissionCopy(row.permission, language: language)
            let state = panelLabel(PermissionsDoctor.explain(row.diagnosis, language: language),
                                   size: 12,
                                   color: row.diagnosis == .granted ? SD.C.positive : SD.C.graphite)
            let trailing: NSView
            if row.diagnosis == .missing {
                let button = NSButton(title: t("Разрешить", "Allow"),
                                      target: self,
                                      action: #selector(permissionGrantClicked(_:)))
                button.tag = index
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 12)
                trailing = button
            } else {
                trailing = NSView()
            }
            root.addArrangedSubview(advancedCapsuleRow(title: copy.name,
                                                       control: state,
                                                       trailing: trailing))
        }

        let fix = NSButton(title: t("Проверить и починить", "Check and repair"),
                           target: self,
                           action: #selector(permissionRepairClicked(_:)))
        fix.bezelStyle = .rounded
        fix.font = .systemFont(ofSize: 12, weight: .semibold)
        root.addArrangedSubview(advancedCapsuleRow(
            title: t("Диагностика", "Diagnostics"),
            control: fix,
            trailing: NSView()))

        // Что кнопка сделает — показываем заранее, а после нажатия заменяем
        // на отчёт о том, что сделано.
        let lines = permissionRepairNotes.isEmpty
            ? PermissionsDoctor.repairPlan(report, language: language)
            : permissionRepairNotes
        for (index, line) in lines.enumerated() {
            // Запуск не из «Программ» — не совет, а причина, по которой всё
            // остальное бесполезно. Он всегда первый и выделен цветом.
            let isBlocker = index == 0 && !report.isInstalledInApplications
            root.addArrangedSubview(permissionsNoteRow(line,
                                                       color: isBlocker ? SD.C.voice : SD.C.subtle))
        }
    }

    private func permissionsNoteRow(_ text: String, color: NSColor) -> NSView {
        let label = panelLabel("• " + text, size: 11.5, color: color)
        // Без уступки по сжатию строка вылезала за правый край окна. Точки
        // разрыва внутри пути расставляет PermissionsDoctor.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let wrapper = NSStackView(views: [label])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)
        label.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        return wrapper
    }

    @objc private func permissionGrantClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        Permissions.request(Permission.allCases[sender.tag])
        refresh(force: true)
    }

    @objc private func permissionRepairClicked(_ sender: NSButton) {
        let report = PermissionsDoctor.report()
        var notes: [String] = []
        let bundleID = Bundle.main.bundleIdentifier ?? "com.raul.dictor"

        if report.needsAgentRestart {
            notes.append(t("Служба перезапущена — теперь она перечитает разрешения.",
                           "The service was restarted — it will re-read permissions now."))
            beginServiceOperation(.restarting)
        }

        let missing = report.rows.filter { $0.diagnosis == .missing }.map(\.permission)
        for permission in missing {
            let name = onboardingPermissionCopy(permission, language: language).name
            notes.append(t("Запись macOS для «\(name)» сброшена, запрос отправлен заново.",
                           "The macOS record for “\(name)” was reset and requested again."))
            TCC.reset(permission, bundleID: bundleID) { [weak self] in
                Permissions.request(permission)
                self?.refresh(force: true)
            }
        }

        if notes.isEmpty {
            notes.append(t("Чинить нечего: все разрешения выданы и служба их видит.",
                           "Nothing to repair: every permission is granted and the service sees it."))
        }
        if !report.isInstalledInApplications {
            notes.append(t("Это не лечится отсюда: перенесите Dictor в «Программы» и выдайте разрешения заново.",
                           "This cannot be fixed from here: move Dictor to Applications and grant the permissions again."))
        }
        log("permissions repair: \(notes.count) action(s)")
        permissionRepairNotes = notes
        refresh(force: true)
    }

    private func advancedSectionHeader(_ title: String) -> NSView {
        let label = historySectionLabel(title)
        let wrapper = NSStackView(views: [label])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        // Макет: секция отбита сверху заметно сильнее, чем строки между
        // собой — 20px против 13px внутри строки.
        wrapper.edgeInsets = NSEdgeInsets(top: 20, left: 0, bottom: 4, right: 0)
        return wrapper
    }

    private func performanceTilesRow() -> NSView {
        let entries = settings.recentTranscriptEntries
        let recognition = medianRecognitionSeconds(entries: entries)
        let agentPID = AgentRuntimeStateStore.read()?.pid ?? 0
        let sample = processResourceSample(pid: agentPID)

        let recognitionTile = SDMetricTile(
            value: recognition.map { recognitionDurationLabel($0, language: language) } ?? "—",
            caption: recognition == nil
                ? t("распознайте что-нибудь, и здесь появится цифра",
                    "dictate something and a number shows up here")
                : t("от отпускания клавиши до текста, медиана",
                    "from key release to text, median")
        )
        let memoryTile = SDMetricTile(
            value: sample.map { memoryFootprintLabel($0.physicalFootprintBytes, language: language) } ?? "—",
            caption: sample == nil
                ? t("служба не запущена", "the service is not running")
                : t("памяти у службы", "memory used by the service")
        )
        // Процессорное время имеет смысл только как разница двух замеров,
        // поэтому плитка сначала честно пустая и заполняется через секунду.
        let cpuTile = SDMetricTile(value: "…", caption: t("CPU, пока молчите", "CPU while you are silent"))
        if let sample, agentPID > 0 {
            scheduleCPUTileUpdate(tile: cpuTile, baseline: sample, pid: agentPID)
        } else {
            cpuTile.update(value: "—", caption: t("служба не запущена", "the service is not running"))
        }

        let row = NSStackView(views: [recognitionTile, memoryTile, cpuTile])
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -14),
        ])
        return wrapper
    }

    private func scheduleCPUTileUpdate(tile: SDMetricTile,
                                       baseline: ProcessResourceSample,
                                       pid: Int32) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak tile] _ in
            MainActor.assumeIsolated {
                // weak tile: вкладка пересобирается на каждом refresh, и
                // к моменту выстрела эта плитка может быть уже не на экране.
                guard let tile, tile.window != nil else { return }
                guard let later = processResourceSample(pid: pid) else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                guard let percent = cpuLoadPercent(from: baseline,
                                                   to: later,
                                                   elapsedSeconds: elapsed) else { return }
                tile.update(value: percent < 0.5 ? "0%" : String(format: "%.0f%%", percent),
                            caption: nil)
            }
        }
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

    /// Установка из окна. Путь тот же, что у «Update now…» в меню-баре, —
    /// `launchPreparedDictorUpdate`; отличается только тем, что ход работы
    /// видно прямо в строке настроек, а не в пункте меню.
    private func beginInAppUpdate(for release: DictorRelease) {
        guard updateTask == nil else { return }
        let version = release.version
        updateState = .preparing(
            version: version,
            phase: t("получаю манифест…", "fetching the manifest…"))
        refresh(force: true)
        updateTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await DictorUpdateInstaller.fetchManifest(
                    expectedVersion: version)
                guard !Task.isCancelled else { return }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("скачиваю и проверяю SHA-256…",
                                  "downloading and verifying SHA-256…"))
                self.refresh(force: true)
                let prepared = try await DictorUpdateInstaller.prepare(manifest: manifest)
                guard !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: prepared.workDirectory)
                    return
                }
                self.updateState = .preparing(
                    version: version,
                    phase: self.t("архив проверен, ставлю…",
                                  "archive verified, installing…"))
                self.refresh(force: true)
                // Скрипт ждёт смерти этого процесса, чтобы подменить бандл.
                // Уходим с дороги сразу после запуска.
                try launchPreparedDictorUpdate(prepared, language: self.language)
                self.updateTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
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

    private func localizedUpdateFailure(_ failure: UpdateCheckFailure) -> String {
        guard language == .russian else { return manualUpdateCheckFailureText(failure) }
        switch failure {
        case .network:
            return "Не удалось связаться с сервером обновлений. Проверьте интернет и повторите попытку."
        case .httpStatus(let code):
            return "Сервер обновлений вернул ошибку HTTP \(code). Повторите попытку позже."
        case .unexpectedResponse:
            return "Сервер обновлений вернул ответ, который Dictor не смог проверить."
        }
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

    private func permissionTitle(_ permission: Permission) -> String {
        localizedPermissionTitle(permission, language: language)
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

    private func localizedBackgroundName(_ style: RecordingHUDBackgroundStyle) -> String {
        guard language == .russian else { return style.displayName }
        switch style {
        case .system: return "Как в системе"
        case .dark: return "Тёмный"
        case .light: return "Светлый"
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

    @objc private func recordDictationShortcutClicked(_ sender: NSButton) {
        guard serviceOperation == nil,
              let kind = ControlPanelShortcutKind(rawValue: sender.tag) else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present(relativeTo: window)
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
            }
            self.settingsDraft = draft
            // Если записали ровно то, что уже стояло, менять нечего —
            // но молчать об этом нельзя.
            let unchanged = draft == ControlPanelSettingsDraft(settings: self.settings)
            self.hotkeyNotice = unchanged
                ? self.t("Это сочетание уже стояло — \(selected.name). Ничего не изменилось.",
                         "That combination was already set — \(selected.name). Nothing changed.")
                : self.t("Новое сочетание: \(selected.name).",
                         "New combination: \(selected.name).")
            self.refreshSettingsWindow()
            // Записанное сочетание применяется сразу: агент подхватывает
            // хоткей только при старте, поэтому служба перезапускается сама.
            if !unchanged {
                self.scheduleSettingsApply(after: 0.15)
            }
        }
        hotkeyRecorder = recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak recorder] in
            guard self?.hotkeyRecorder === recorder else { return }
            recorder?.present(relativeTo: self?.window)
        }
    }

    /// Настройки применяются сами — кнопки «Сохранить» в макете нет.
    /// Хоткей агент читает только при старте, поэтому применение тянет за
    /// собой перезапуск службы; задержка нужна, чтобы щелчки по степперу
    /// не перезапускали её на каждый клик.
    private func scheduleSettingsApply(after delay: TimeInterval) {
        pendingSettingsApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applySettingsDraft()
        }
        pendingSettingsApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func settingsValidationMessage(_ draft: ControlPanelSettingsDraft) -> String? {
        let shortcuts = draft.alternateCompletionEnabled
            ? [draft.dictationHotkey, draft.alternateCompletionHotkey]
            : [draft.dictationHotkey]
        for firstIndex in shortcuts.indices {
            for secondIndex in shortcuts.indices where secondIndex > firstIndex {
                let first = shortcuts[firstIndex]
                let second = shortcuts[secondIndex]
                if hotkeysConflict(first, second) {
                    return t("Сочетания для диктовки и завершения должны отличаться.",
                             "Dictation and finish shortcuts must be different.")
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

    private func applySettingsDraft() {
        pendingSettingsApply = nil
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil,
              draft != ControlPanelSettingsDraft(settings: settings) else { return }
        applySettings(draft)
    }

    private func applySettings(_ draft: ControlPanelSettingsDraft) {
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.enterDelayMilliseconds = draft.enterDelayMilliseconds
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDTranscribingColor = draft.transcribingColor
        settings.recordingHUDBackgroundStyle = draft.backgroundStyle
        settings.recordingHUDSize = draft.hudSize
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        // Служба перечитывает хоткеи сама раз в секунду, так что перезапуск
        // нужен только когда её вообще нет. И только если человек её не
        // останавливал: остановленная тумблером служба не должна воскресать
        // от записи хоткея — новое сочетание она прочтёт при запуске.
        if settings.agentEnabled, !DictorAgentService.isAgentRunning() {
            beginServiceOperation(.starting)
        } else {
            refresh(force: true)
        }
    }

    private func refreshSettingsWindow() {
        refresh(force: true)
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
    for tab in ["general", "hotkeys", "model", "dict", "look", "advanced", "privacy"] {
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
func exportHistoryPanelPreviews(to directory: URL,
                                language: InterfaceLanguage? = nil) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let settings = Settings.shared
    // Превью подменяет историю и статистику сэмплами. Раньше подмена была
    // безвозвратной: запуск ключа у установленного .app стирал реальные
    // диктовки пользователя. Снимаем состояние и возвращаем его на выходе.
    let savedEntries = settings.recentTranscriptEntries
    let savedUsage = settings.dailyDictationUsage
    // Язык — тем же приёмом, что история: подменяем и возвращаем. Нужен для
    // англоязычных снимков в витрине проекта; настройка общая с работающим
    // приложением, поэтому возврат обязателен даже при исключении.
    let savedLanguage = settings.interfaceLanguage
    if let language { settings.interfaceLanguage = language }
    // Закрытые подсказки — тем же приёмом. Иначе «Сегодня» снимается без
    // плашки подсказки у всякого, кто хоть раз её закрыл, и проверить эмаль
    // (макет 8d) рендером нечем.
    let savedDismissedHints = settings.dismissedHints
    settings.dismissedHints = []
    // Словарь — тоже сэмплами: у чистой копии он пуст, и «Словарь» снимался
    // пустым экраном «Пока пусто», хотя показывать надо, как раздел работает.
    let savedCorrections = settings.transcriptCorrections
    settings.transcriptCorrections = settings.interfaceLanguage == .english
        ? [TranscriptCorrection(source: "kubernetis", replacement: "Kubernetes"),
           TranscriptCorrection(source: "postgres ql", replacement: "PostgreSQL"),
           TranscriptCorrection(source: "raoul", replacement: "Raul"),
           TranscriptCorrection(source: "dictor app", replacement: "Dictor")]
        : [TranscriptCorrection(source: "кубернетис", replacement: "Kubernetes"),
           TranscriptCorrection(source: "постгрес", replacement: "PostgreSQL"),
           TranscriptCorrection(source: "раул", replacement: "Раул"),
           TranscriptCorrection(source: "диктор", replacement: "Dictor")]
    // Кнопки строки «Сегодня» проявляются по наведению, а снимок делается
    // без курсора — иначе иконки не проверить рендером вовсе.
    SDRecentEntryRowView.previewForcesActionsVisible = true
    defer {
        settings.interfaceLanguage = savedLanguage
        settings.recentTranscriptEntries = savedEntries
        settings.dailyDictationUsage = savedUsage
        settings.dismissedHints = savedDismissedHints
        settings.transcriptCorrections = savedCorrections
        SDRecentEntryRowView.previewForcesActionsVisible = false
    }
    // Сэмплы на языке интерфейса: английские снимки с русскими диктовками
    // внутри выглядят как незаконченный перевод.
    let sampleTexts = settings.interfaceLanguage == .english
        ? ["Hey! Sending a short recap of the call and the three next steps — take a look before Friday",
           "Let's talk Thursday at three, I'll send the invite",
           "Headline: local dictation with no cloud — a look at Dictor",
           "We cut the beta scope down to the dictionary and the modes"]
        : ["Привет! По итогам звонка присылаю короткое резюме и три следующих шага, посмотри до пятницы",
           "Давай созвонимся в четверг в три, я закину приглашение",
           "Заголовок: локальная диктовка без облака — обзор Dictor",
           "Собираем бету в пятницу, режем скоуп до словаря и режимов"]
    settings.recentTranscriptEntries = [
        TranscriptHistoryEntry(text: sampleTexts[0],
                               transcriptionDurationSeconds: 1.2,
                               createdAt: now.addingTimeInterval(-3600)),
        TranscriptHistoryEntry(text: sampleTexts[1],
                               transcriptionDurationSeconds: 0.7,
                               createdAt: now.addingTimeInterval(-9000)),
        TranscriptHistoryEntry(text: sampleTexts[2],
                               transcriptionDurationSeconds: 0.6,
                               createdAt: now.addingTimeInterval(-16000)),
        TranscriptHistoryEntry(text: sampleTexts[3],
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
    // Витрина показывает рабочее состояние службы. Без этого подвал сообщал бы
    // о расхождении версий — правду про запуск из /tmp, но не про программу.
    panel.previewStatusOverride = .ready(latencyMilliseconds: 180)
    let size = MAIN_WINDOW_SIZE
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.colorSpace = .sRGB
    var exported = 0
    // Каждый раздел окна (макет 6a/6b) в обеих темах.
    for section in [MainWindowSection.today, .history, .stats, .dictionary, .settings] {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                         ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearanceName)
            panel.mainSection = section
            // «Статистику» снимаем ещё и в годовом периоде — там живёт
            // блок по кварталам с итогом (макет 7c).
            panel.statsPeriod = section == .stats ? .month : .month
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
    // История с набранным запросом. Без неё не проверить ни подсветку
    // совпадений, ни крестик очистки: пустое поле не показывает ни того,
    // ни другого.
    panel.mainSection = .history
    panel.mainHistorySearch = settings.interfaceLanguage == .english ? "call" : "звонка"
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeMainWindowView()
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for history-search-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for history-search-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("history-search-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }
    panel.mainHistorySearch = ""

    // Годовой разрез статистики (макет 7c). Окно превью выше рабочего,
    // чтобы карточка кварталов попала в кадр целиком, а не под прокрутку.
    panel.mainSection = .stats
    panel.statsPeriod = .year
    let tallSize = NSSize(width: size.width, height: 1180)
    window.setContentSize(tallSize)
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeMainWindowView()
        view.frame = NSRect(origin: .zero, size: tallSize)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for stats-year-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for stats-year-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("stats-year-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }
    window.contentView = nil
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("HISTORY_PREVIEW exported \(exported) files to \(directory.path)")
}

// MARK: - Действия онбординга

extension DictorControlPanelApp: OnboardingPageActions {
    func onboardingStartTapped() {
        guard let flow = onboardingFlow else { return }
        flow.start(with: flow.currentSnapshot())
        applyOnboarding()
    }

    func onboardingGrantTapped(_ permission: Permission) {
        Permissions.request(permission)
        applyOnboarding()
    }

    func onboardingSkipTapped() {
        log("onboarding: skipped by user")
        finishOnboarding()
    }

    func onboardingFinishTapped() {
        log("onboarding: finished by user")
        finishOnboarding()
    }
}
