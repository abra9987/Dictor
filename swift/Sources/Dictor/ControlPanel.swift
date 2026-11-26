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
    var backgroundStyle: RecordingHUDBackgroundStyle
    var hudSize: RecordingHUDSize

    init(settings: Settings) {
        dictationHotkey = settings.configuredHotkey
        alternateCompletionHotkey = settings.configuredEnterHotkey
        primaryCompletionBehavior = settings.primaryCompletionBehavior
        alternateCompletionEnabled = settings.alternateCompletionEnabled
        enterDelayMilliseconds = settings.enterDelayMilliseconds
        recordingColor = settings.recordingHUDRecordingColor
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
    var window: NSWindow?
    private var refreshTimer: Timer?
    var serviceOperation: ControlPanelServiceOperation?
    var updateTask: Task<Void, Never>?
    /// Состояние, навязанное экспортом превью, — в живом окне всегда nil.
    /// Не private: витрина снимается debug-бинарём, у которого нет бандла, и
    /// подвал честно докладывал «Установлена версия 0.0.0, служба ещё работает
    /// на 1.2.0». Для снимков состояние задаётся явно.
    var previewStatusOverride: ServiceStatusKind?
    /// Для рендера вкладки «Служба» в состоянии «работает прежняя модель»:
    /// в обычной жизни оно длится минуты после обновления, и поймать его на
    /// живой службе нечем.
    var previewModelUpdateOverride: SpeechModelUpdateStatus?
    /// Пауза перед показом коротких состояний службы (макет 8c).
    let statusHold = ServiceStatusHold()
    var statusHoldTimer: Timer?
    /// Не private ради экспорта превью: «доступно обновление» — состояние
    /// с собственным видом (точка на ярлыке вкладки), и увидеть его надо
    /// картинкой, а не рассуждением.
    var updateState: ControlPanelUpdateState = .notChecked
    var lastRenderFingerprint = ""
    let settings = Settings.shared
    private var permissionClickCount: [Permission: Int] = [:]
    var settingsDraft: ControlPanelSettingsDraft?
    var settingsTab = SETTINGS_TABS[0].id
    var hotkeyRecorder: HotkeyRecorderController?
    private var onboardingFlow: OnboardingFlow?
    var onboardingPage: OnboardingPageView?
    /// Отчёт последней починки разрешений. Пусто — показываем план.
    private var permissionRepairNotes: [String] = []
    /// Запрос поиска по истории. Не private: экспорт превью снимает историю с
    /// набранным запросом — только там видны подсветка совпадений и крестик
    /// очистки.
    var mainHistorySearch = ""
    weak var mainHistorySearchField: NSSearchField?
    /// Список «Истории» текущего вида — чтобы пересборка окна не сбрасывала
    /// прокрутку: клик по сотой строке возвращал человека к первой.
    weak var mainHistoryListView: SDHistoryListView?
    /// К какому списку относится запомненная прокрутка. Другой запрос или
    /// другой фильтр — это другой список, и место в нём начинается сверху.
    private var mainHistoryScrollContext = ""
    /// Состояние объекта входа и момент, когда его спрашивали.
    private var loginItemStatusReading: (status: SMAppService.Status, readAt: TimeInterval)?
    weak var historyDetailTranscriptView: SDSelectableTranscriptView?
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
    var hotkeyNotice: String?
    var historyShowsPinnedOnly = false

    var language: InterfaceLanguage { settings.interfaceLanguage }

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
        if Self.shouldStartAgentOnLaunch(
            agentEnabled: settings.agentEnabled,
            agentAlreadyRunning: DictorAgentService.isAgentRunning()) {
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

    func t(_ russian: String, _ english: String) -> String {
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
    private func loginItemStatus() -> SMAppService.Status {
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


    func makeSettingsContentView() -> NSView {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        // Таб-бар лежит на своей полосе во всю ширину, поэтому боковых
        // отступов у корня нет: их держит стек содержимого.
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsTabBar())

        // Содержимое вкладки — стопка групп, а не строк: между группами
        // 18 pt, внутри группы строки лежат вплотную под общей крышей.
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false
        switch settingsTab {
        case "text":
            addTextTabRows(to: content, draft: draft)
        case "look":
            addLookTabRows(to: content, draft: draft)
        case "privacy":
            addPrivacyTabRows(to: content)
        case "app":
            addAppTabRows(to: content)
        case "service":
            addServiceTabRows(to: content)
        default:
            addDictationTabRows(to: content, draft: draft)
        }
        root.addArrangedSubview(content)

        let background = PaperBackgroundView()
        background.fill = SD.C.settingsPaper
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        let contentInset = -(content.edgeInsets.left + content.edgeInsets.right)
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: contentInset).isActive = true
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
        // Переносимая подпись узнаёт свою ширину в layout() — из фрейма
        // контрола, а не из констрейнтов. Пока у контейнера нет фрейма,
        // фреймы детей нулевые, перенос не случается, и высота считается по
        // однострочной подписи: вторая строка потом налезала на разделитель.
        // Поэтому сначала даём заведомо просторный фрейм, раскладываемся —
        // и только потом меряем. Крутим до устойчивой высоты: перенос одной
        // строки может сдвинуть соседнюю.
        let probeHeight = MAIN_WINDOW_SIZE.height * 3
        view.frame = NSRect(x: 0, y: 0, width: width, height: probeHeight)
        // Проходов именно несколько, и выйти по «высота не изменилась» нельзя:
        // перенос проявляется только на третьем. Первый даёт строке фрейм,
        // второй в layout() выставляет ширину переноса, и лишь третий видит
        // двухстрочную подпись. Ранний выход по совпадению первых двух
        // замеров возвращал высоту на строку меньше — и стек, у которого
        // строка сжимаема, съедал у неё нижний отступ: подпись налезала на
        // разделитель.
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            _ = root.fittingSize
        }
        view.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize.height
        widthPin.isActive = false
        return max(404, ceil(fitting))
    }

    // MARK: - Вкладки настроек (дизайн 2c, адаптировано)

    private func settingsTabBar() -> NSView {
        // Полоса вкладок — своя поверхность с линией снизу: пять вкладок
        // прижаты к левому краю, как строки под ними, а не парят по центру.
        let wrapper = PaperBackgroundView()
        wrapper.fill = SD.C.listPaper
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 2
        // Макет: таб 27 pt высотой, padding 0 11px, радиус 7, шрифт 12.5;
        // активный — 600 ink на белой карточке с мягкой тенью, неактивный —
        // 500 graphite без подложки. Отступ 11, а не 13: шесть вкладок
        // должны уместиться в 767 pt и по-русски, и по-английски.
        let updateAvailable: Bool
        if case .available = updateState { updateAvailable = true } else { updateAvailable = false }
        for tab in SETTINGS_TABS {
            let (id, title) = (tab.id, tab.title(language))
            let button = SDTabButton(title: title, target: self,
                                     action: #selector(settingsTabClicked(_:)))
            button.isBordered = false
            button.isActiveTab = settingsTab == id
            // Обновление — единственная новость, которую человек иначе не
            // заметит: версия лежит внутри вкладки, а не на виду.
            button.showsBadge = id == "app" && updateAvailable
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true
            let textWidth = ceil(title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            ]).width)
            let badgeWidth = button.showsBadge
                ? SDTabButton.badgeSize + SDTabButton.badgeGap
                : 0
            button.widthAnchor.constraint(equalToConstant: textWidth + 22 + badgeWidth)
                .isActive = true
            bar.addArrangedSubview(button)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        let hairline = SDHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(bar)
        wrapper.addSubview(hairline)
        NSLayoutConstraint.activate([
            // Ровно та же высота, что у верхней полосы сайдбара: вкладки —
            // первое, что есть в панели, и встают вровень с кнопками окна.
            wrapper.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                          constant: -16),
            bar.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrapper
    }

    @objc private func settingsTabClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        hotkeyNotice = nil
        settingsTab = id
        refresh(force: true)
    }

    // MARK: Вкладка «Диктовка» — всё, что происходит до текста

    private func addDictationTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        let missingPermissions = Permission.allCases.filter { !Permissions.isGranted($0) }
        if !missingPermissions.isEmpty {
            root.addArrangedSubview(compactPermissionsCard())
        }

        var startRows: [NSView] = [
            SDRowView(
                title: t("Начать и остановить диктовку", "Start and stop dictation"),
                subtitle: t("Работает в любом приложении, пока служба включена",
                            "Works in any app while the service is running"),
                control: hotkeyControl(shortcut: draft.dictationHotkey, kind: .dictation),
                style: .card
            ),
        ]

        // Режим клавиши жил только в старом меню («Trigger») — по-английски и
        // не там, где настраивают саму клавишу.
        let triggerPills = SDPills(options: [
            .init(title: t("Удерживать", "Hold"), value: TriggerMode.hold.rawValue),
            .init(title: t("Переключать", "Toggle"), value: TriggerMode.toggle.rawValue),
        ], selected: settings.triggerMode.rawValue)
        triggerPills.onSelect = { [weak self] raw in
            guard let mode = TriggerMode(rawValue: raw) else { return }
            self?.settings.triggerMode = mode
        }
        startRows.append(SDRowView(
            title: t("Режим клавиши", "Key behavior"),
            subtitle: t("Удерживать — запись, пока клавиша зажата. Переключать — "
                        + "нажатие включает, следующее выключает",
                        "Hold records while the key is down. Toggle starts on one "
                        + "press and stops on the next"),
            control: triggerPills,
            style: .card
        ))

        // Тумблер существовал только как ключ в настройках: выключить
        // альтернативное завершение из интерфейса было нельзя вовсе.
        let altToggle = SDToggle()
        altToggle.isOn = draft.alternateCompletionEnabled
        altToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            var draft = self.settingsDraft ?? ControlPanelSettingsDraft(settings: self.settings)
            draft.alternateCompletionEnabled = enabled
            self.settingsDraft = draft
            self.hotkeyNotice = self.settingsValidationMessage(draft)
            self.scheduleSettingsApply(after: 0.15)
            self.refresh(force: true)
        }
        startRows.append(SDRowView(
            title: t("Отдельное сочетание для завершения", "Separate finish shortcut"),
            subtitle: t("Второе сочетание завершает диктовку противоположным действием",
                        "A second shortcut finishes dictation with the opposite action"),
            control: altToggle,
            style: .card
        ))
        // Сочетание — условие тумблера над ним, а не самостоятельная строка:
        // вложенность видна отступом, и объяснять её словами не приходится.
        if draft.alternateCompletionEnabled {
            startRows.append(SDRowView(
                title: t("Сочетание завершения", "Finish shortcut"),
                control: hotkeyControl(shortcut: draft.alternateCompletionHotkey,
                                       kind: .alternateCompletion),
                style: .cardNested
            ))
        }
        root.addArrangedSubview(settingsGroup(t("Как начать", "How it starts"), rows: startRows))

        var inputRows: [NSView] = []

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
            microphoneSubtitle = t("Если этот пропадёт — вернёмся ко встроенному",
                                   "Falls back to the built-in mic if this one disappears")
        }
        inputRows.append(SDRowView(
            title: t("Микрофон", "Microphone"),
            subtitle: microphoneSubtitle,
            control: SDFieldButton(popup: microphonePopup),
            style: .card
        ))

        // Полный список языков раньше жил только в меню по правому клику.
        // Подписи ведут с алфавита: настройка ограничивает алфавит вывода,
        // и «Кириллица» для английской речи означает «инглиш по-русски».
        let languagePopup = NSPopUpButton()
        for option in dictationLanguageMenuOrder() {
            if option == dictationLanguageMenuOrder().dropFirst(3).first {
                languagePopup.menu?.addItem(.separator())
            }
            languagePopup.addItem(withTitle: dictationLanguageMenuTitle(
                option, interfaceLanguage: language))
            languagePopup.lastItem?.representedObject = option.rawValue
        }
        if let index = languagePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == settings.dictationLanguage.rawValue
        }) {
            languagePopup.selectItem(at: index)
        }
        languagePopup.target = self
        languagePopup.action = #selector(selectDictationLanguageFromPanel(_:))
        inputRows.append(SDRowView(
            title: t("Алфавит вывода", "Output script"),
            subtitle: t("Авто — смешанная речь. Кириллица — английские слова "
                        + "запишутся по-русски",
                        "Auto handles mixed speech. Cyrillic makes English words "
                        + "come out in Russian letters"),
            control: SDFieldButton(popup: languagePopup),
            style: .card
        ))

        // Глушение жило только в старом меню («Mute system audio…»).
        let muteToggle = SDToggle()
        muteToggle.isOn = settings.muteWhileRecording
        muteToggle.onToggle = { [weak self] enabled in
            self?.settings.muteWhileRecording = enabled
        }
        inputRows.append(SDRowView(
            title: t("Глушить звук во время записи", "Mute audio while recording"),
            subtitle: t("Музыка и уведомления приглушаются, чтобы не попасть в диктовку",
                        "Music and alerts are ducked so they don't leak into the dictation"),
            control: muteToggle,
            style: .card
        ))

        let soundsToggle = SDToggle()
        soundsToggle.isOn = settings.playFeedbackSounds
        soundsToggle.onToggle = { [weak self] enabled in
            self?.settings.playFeedbackSounds = enabled
        }
        inputRows.append(SDRowView(
            title: t("Звуки диктовки", "Dictation sounds"),
            subtitle: t("Сигналы начала, конца и ошибки",
                        "Cues for start, finish and errors"),
            control: soundsToggle,
            style: .card
        ))
        root.addArrangedSubview(settingsGroup(t("Чем слушаем", "What listens"),
                                              rows: inputRows))

        if let notice = hotkeyNotice {
            let noticeLabel = panelLabel(notice, size: 11.5, weight: .medium, color: SD.C.voice)
            noticeLabel.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
                - MAIN_WINDOW_SIDEBAR_WIDTH - 100
            root.addArrangedSubview(noticeLabel)
        }
        root.addArrangedSubview(settingsFootnote(
            t("Микрофон и алфавит вывода продублированы в панели меню-бара. Это осознанный дубль: их меняют в момент диктовки, а не в момент настройки.",
              "The microphone and the output script are also in the menu-bar panel. That duplicate is deliberate: they get changed while dictating, not while configuring.")))
    }

    /// Сноска под группами: точка-маркер и приглушённый текст. Место для
    /// правды, которая не является настройкой, — например про осознанный
    /// дубль в другом месте интерфейса.
    private func settingsFootnote(_ text: String) -> NSView {
        let dot = PaperBackgroundView()
        dot.fill = SD.C.subtle
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = panelLabel(text, size: 11.5, color: SD.C.subtle)
        label.preferredMaxLayoutWidth = 600
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(dot)
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            dot.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 5),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    @objc private func selectMicrophoneFromPanel(_ sender: NSPopUpButton) {
        settings.inputDevice = (sender.selectedItem?.representedObject as? String) ?? ""
    }

    @objc private func selectDictationLanguageFromPanel(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let chosen = DictationLanguage(rawValue: raw) else { return }
        settings.dictationLanguage = chosen
    }

    // MARK: Вкладка «Текст» — в каком виде придёт сказанное

    private func addTextTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        var insertedRows: [NSView] = []

        let completionPills = SDPills(options: [
            .init(title: t("Ничего", "Nothing"), value: DictationCompletionBehavior.insert.rawValue),
            .init(title: t("Нажать Enter", "Press Enter"),
                  value: DictationCompletionBehavior.insertAndEnter.rawValue),
        ], selected: settings.primaryCompletionBehavior.rawValue)
        completionPills.onSelect = { [weak self] raw in
            guard let self, let behavior = DictationCompletionBehavior(rawValue: raw) else { return }
            self.settings.primaryCompletionBehavior = behavior
            // Черновик обязан узнать о прямой записи: иначе следующая запись
            // хоткея применит черновик со вчерашним значением поверх только
            // что сделанного выбора.
            self.settingsDraft?.primaryCompletionBehavior = behavior
            // Задержка ниже приглушается и оживает вместе с выбором —
            // перерисовываем, иначе строка врёт про своё состояние.
            self.refresh(force: true)
        }
        insertedRows.append(SDRowView(
            title: t("После вставки текста", "After inserting text"),
            subtitle: t("Enter отправляет сообщение в мессенджерах и почте",
                        "Enter sends the message in chat apps and mail"),
            control: completionPills,
            style: .card
        ))

        let delayStepper = SDStepperRow(value: settings.enterDelayMilliseconds,
                                        step: 20,
                                        range: 0...ENTER_DELAY_MAX_MILLISECONDS,
                                        suffix: "ms")
        delayStepper.onChange = { [weak self] value in
            self?.settings.enterDelayMilliseconds = value
            self?.settingsDraft?.enterDelayMilliseconds = value
        }
        // Задержка осмысленна только рядом с Enter. Раньше она стояла в
        // полную силу всегда — настройка, которая ни на что не влияет, но
        // выглядит рабочей, читается как поломка.
        let enterChosen = settings.primaryCompletionBehavior == .insertAndEnter
        let delayRow = SDRowView(
            title: t("Задержка перед Enter", "Delay before Enter"),
            subtitle: enterChosen
                ? t("Пауза между вставкой и подтверждением",
                    "Pause between inserting and confirming")
                : t("Заработает, когда выбрано «Нажать Enter»",
                    "Takes effect once “Press Enter” is chosen"),
            control: delayStepper,
            style: .card
        )
        delayStepper.isEnabled = enterChosen
        delayRow.alphaValue = enterChosen ? 1 : 0.55
        insertedRows.append(delayRow)

        // «After Pasting» из старого меню: что дописать после вставленного
        // текста. Пробел стоит по умолчанию, чтобы следующая диктовка не
        // приклеивалась к предыдущей.
        let suffixPills = SDPills(options: [
            .init(title: t("Пробел", "Space"), value: PasteSuffix.appendSpace.rawValue),
            .init(title: t("Ничего", "Nothing"), value: PasteSuffix.none.rawValue),
            .init(title: t("Новая строка", "New line"), value: PasteSuffix.appendNewline.rawValue),
        ], selected: settings.pasteSuffix.rawValue)
        suffixPills.onSelect = { [weak self] raw in
            guard let suffix = PasteSuffix(rawValue: raw) else { return }
            self?.settings.pasteSuffix = suffix
        }
        insertedRows.append(SDRowView(
            title: t("После текста добавлять", "Append after the text"),
            subtitle: t("Чтобы следующая диктовка не склеилась с этой",
                        "So the next dictation doesn't run into this one"),
            control: suffixPills,
            style: .card
        ))

        // Выключатель обязателен: правило само меняет сказанное, и человек,
        // которому оно мешает в его программе, должен убрать его одним
        // движением, а не терпеть до следующей версии.
        let smartToggle = SDToggle()
        smartToggle.isOn = settings.smartInsertionEnabled
        smartToggle.onToggle = { [weak self] enabled in
            self?.settings.smartInsertionEnabled = enabled
        }
        insertedRows.append(SDRowView(
            title: t("Умная вставка", "Smart insertion"),
            subtitle: t("Продолжение фразы — со строчной и через пробел, "
                        + "реплика в мессенджере — без точки",
                        "A continued sentence starts lowercase after a space, "
                        + "a chat message drops its period"),
            control: smartToggle,
            style: .card
        ))
        root.addArrangedSubview(settingsGroup(t("Когда текст вставлен", "Once the text is in"),
                                              rows: insertedRows))

        addTextCleanupGroup(to: root)
        addTextDictionaryGroup(to: root)
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

    /// «Чистится само» — встроенные правки, которые применяются без участия
    /// человека. Раньше жили вкладкой «Словарь» вперемешку со своим списком
    /// замен; это тоже вид текста, а не работа со словарём.
    private func addTextCleanupGroup(to root: NSStackView) {
        let fillerToggle = SDToggle()
        fillerToggle.isOn = settings.removeFillerWords
        fillerToggle.onToggle = { [weak self] enabled in
            self?.settings.removeFillerWords = enabled
        }
        let fillerRow = SDRowView(
            title: t("Убирать слова-паразиты", "Remove filler words"),
            subtitle: t("«Эээ», «ммм» и подобное исчезают из текста",
                        "“Uh”, “um” and similar vanish from the text"),
            control: fillerToggle,
            style: .card
        )

        // Тумблеры встроенных наборов живут здесь и только здесь: карточки-
        // дубли в разделе «Словарь» сняты. Два места для одной настройки
        // неизбежно расходятся — сначала подписью, потом поведением.
        let spellingsToggle = SDToggle()
        spellingsToggle.isOn = settings.builtInSpellingsEnabled
        spellingsToggle.onToggle = { [weak self] enabled in
            self?.settings.builtInSpellingsEnabled = enabled
        }
        let spellingsRow = SDRowView(
            title: t("Написание названий", "Name spelling"),
            subtitle: t("\(BuiltInSpellings.count) названий: postgres → PostgreSQL · sql → SQL · macos → macOS",
                        "\(BuiltInSpellings.count) names: postgres → PostgreSQL · sql → SQL · macos → macOS"),
            control: spellingsToggle,
            style: .card
        )

        let latinToggle = SDToggle()
        latinToggle.isOn = settings.latinTermRestorationsEnabled
        latinToggle.onToggle = { [weak self] enabled in
            self?.settings.latinTermRestorationsEnabled = enabled
        }
        let latinRow = SDRowView(
            title: t("Названия латиницей", "Names in Latin script"),
            subtitle: t("\(LatinTermRestorations.count) названий: гитхаб → GitHub · постгрес → PostgreSQL",
                        "\(LatinTermRestorations.count) names: гитхаб → GitHub · постгрес → PostgreSQL"),
            control: latinToggle,
            style: .card
        )

        root.addArrangedSubview(settingsGroup(t("Чистится само", "Cleaned up automatically"),
                                              rows: [fillerRow, spellingsRow, latinRow]))
    }

    /// «Свой словарь» — настройки списка замен и явная дверь в сам список.
    /// Список остался разделом окна: с ним работают долго, как с историей,
    /// и строкой настроек он не притворяется.
    private func addTextDictionaryGroup(to root: NSStackView) {
        let count = settings.transcriptCorrections.count
        let openButton = panelButton(t("Открыть словарь", "Open dictionary"),
                                     action: #selector(openDictionarySectionFromPanel(_:)))
        let listRow = SDRowView(
            title: t("Список автозамен", "Correction list"),
            subtitle: count == 0
                ? t("Пока пусто — сам список живёт в разделе «Словарь»",
                    "Empty so far — the list itself lives in the Dictionary section")
                : t("\(count) \(pluralizeRU(count, "своя замена", "свои замены", "своих замен")) · сам список живёт в разделе «Словарь»",
                    "\(count) own \(count == 1 ? "replacement" : "replacements") · the list itself lives in the Dictionary section"),
            control: openButton,
            style: .card
        )

        // Синхронизация и перенос жили только в старом меню по правому клику —
        // то есть их не существовало ни для кого, кто в это меню не заглядывал.
        let syncPath = settings.transcriptCorrectionsSyncFile
        let syncRow: SDRowView
        if syncPath.isEmpty {
            syncRow = SDRowView(
                title: t("Синхронизация файлом", "Sync through a file"),
                subtitle: t("Файл в iCloud Drive или Dropbox держит словарь общим "
                            + "для нескольких Mac",
                            "A file in iCloud Drive or Dropbox keeps the dictionary "
                            + "shared between Macs"),
                control: panelButton(t("Настроить…", "Set up…"),
                                     action: #selector(setUpDictionarySyncFromPanel(_:))),
                style: .card
            )
        } else {
            syncRow = SDRowView(
                title: t("Синхронизация файлом", "Sync through a file"),
                subtitle: (syncPath as NSString).abbreviatingWithTildeInPath,
                control: panelButton(t("Отключить…", "Disconnect…"),
                                     action: #selector(stopDictionarySyncFromPanel(_:))),
                style: .card
            )
        }

        let transferButtons = NSStackView(views: [
            panelButton(t("Импорт…", "Import…"),
                        action: #selector(importDictionaryFromPanel(_:))),
            panelButton(t("Экспорт…", "Export…"),
                        action: #selector(exportDictionaryFromPanel(_:))),
        ])
        transferButtons.orientation = .horizontal
        transferButtons.spacing = 8
        let transferRow = SDRowView(
            title: t("Перенос словаря", "Move the dictionary"),
            subtitle: t("Файлом — на другой Mac или в резерв",
                        "As a file — to another Mac or to a backup"),
            control: transferButtons,
            style: .card
        )

        // Встроенные наборы названий собраны по диктовкам одного человека.
        // Чужой словарь — готовый список слов, на которых модель ошибается у
        // других, и узнать о них больше неоткуда: приложение о себе молчит.
        let shareRow = SDRowView(
            title: t("Поделиться словарём", "Share the dictionary"),
            subtitle: count == 0
                ? t("Пока нечем — словарь пуст",
                    "Nothing to share yet — the dictionary is empty")
                : t("Откроет письмо автору с файлом словаря: так встроенный набор "
                    + "пополняется словами, на которых модель ошибается. "
                    + "Ничего не уходит без вашего «Отправить»",
                    "Opens an email to the author with the dictionary file: that is how "
                    + "the built-in set learns the words the model gets wrong. "
                    + "Nothing leaves until you press Send"),
            control: panelButton(t("Открыть письмо…", "Open email…"),
                                 action: #selector(shareDictionaryFromPanel(_:)),
                                 enabled: count > 0),
            style: .card
        )

        root.addArrangedSubview(settingsGroup(t("Свой словарь", "Your dictionary"),
                                              rows: [listRow, syncRow, transferRow, shareRow]))
    }

    @objc private func shareDictionaryFromPanel(_ sender: NSButton) {
        DictionaryShare.share(corrections: settings.transcriptCorrections,
                              anchor: sender,
                              language: settings.interfaceLanguage)
    }

    @objc private func openDictionarySectionFromPanel(_ sender: NSButton) {
        mainSection = .dictionary
        refresh(force: true)
    }

    /// Диплинк во вкладку «Служба» — из «Приложения», из подвала сайдбара и
    /// из баннера «текст не вставился». Состояние прячется за кликом, поэтому
    /// каждое место, где человек упирается в неработающую диктовку, обязано
    /// вести прямо сюда, а не «в настройки, там разберётесь».
    func openServiceTab() {
        mainSection = .settings
        settingsTab = "service"
        hotkeyNotice = nil
        refresh(force: true)
    }

    @objc private func openServiceSectionFromPanel(_ sender: NSButton) {
        openServiceTab()
    }

    @objc private func reportProblemFromPanel(_ sender: NSButton) {
        ProblemReport.share(diagnostics: panelDiagnosticsText(),
                            anchor: sender,
                            language: settings.interfaceLanguage)
    }

    /// Окно — отдельный процесс, полного отчёта службы у него нет. Зато есть
    /// то, что служба публикует на диск, и настройки, которые к сбою
    /// относятся чаще всего: капсула, режим клавиши, приглушение.
    private func panelDiagnosticsText() -> String {
        var lines = [
            "Dictor diagnostics (control panel)",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "App version: \(currentBundleVersion()) (\(currentBundleBuild()))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "Service:",
        ]
        if let state = AgentRuntimeStateStore.read() {
            lines += [
                "- Status: \(state.status) — \(state.detail)",
                "- Ready: \(state.isReady), recording: \(state.isRecording), transcribing: \(state.isTranscribing)",
                "- Speech model ready: \(state.speechModelReady)",
                "- Missing permissions: \(state.missingPermissions.isEmpty ? "none" : state.missingPermissions.joined(separator: ", "))",
                "- Hotkey: \(state.hotkeyName), trigger: \(state.triggerMode)",
            ]
            if let reason = state.failureReason {
                lines.append("- Failure reason: \(reason)")
            }
        } else {
            lines.append("- State file unavailable (service not running?)")
        }
        lines.append(inputDevicesDiagnosticsLine(availableAudioInputDevices()))
        lines += [
            "",
            "Settings:",
            "- Capsule size: \(settings.recordingHUDSize.rawValue)",
            "- Show capsule: \(settings.showRecordingWaveform)",
            "- Trigger mode: \(settings.triggerMode.rawValue)",
            "- Mute while recording: \(settings.muteWhileRecording)",
            "- Interface language: \(settings.interfaceLanguage.rawValue)",
            "",
            "Crash reports (~/Library/Logs/DiagnosticReports):",
        ]
        let crashLines = crashReportSummaryLines(
            fileNames: dictorCrashReportURLs().map(\.lastPathComponent))
        lines += crashLines.isEmpty ? ["- None found"] : crashLines.map { "- \($0)" }
        lines.append("")
        lines.append("Privacy: transcript text and text-correction contents are not included.")
        return lines.joined(separator: "\n")
    }

    /// Автозапуск диктовки. Включение поднимает службу сразу — ждать входа в
    /// систему, чтобы проверить, что тумблер сработал, никто не станет.
    /// Выключение только снимает автозапуск: живую службу не трогаем, иначе
    /// строка под заголовком «При входе в систему» делала бы вторую вещь
    /// молча — ту самую путаницу, ради которой её и разделили.
    private func setDictationAutostart(_ enabled: Bool) {
        settings.agentEnabled = enabled
        _ = settings.refreshFromDisk()
        if enabled {
            beginServiceOperation(.starting)
        } else {
            DictorAgentService.disableAutostart()
            refresh(force: true)
        }
    }

    // MARK: Вкладка «Приложение» — про сам продукт, а не про диктовку

    private func addAppTabRows(to root: NSStackView) {
        // Язык интерфейса включался только через defaults write — английский
        // интерфейс существовал целиком и был недостижим.
        let interfacePills = SDPills(options: [
            .init(title: "Русский", value: InterfaceLanguage.russian.rawValue),
            .init(title: "English", value: InterfaceLanguage.english.rawValue),
        ], selected: settings.interfaceLanguage.rawValue)
        interfacePills.onSelect = { [weak self] raw in
            guard let self, let chosen = InterfaceLanguage(rawValue: raw) else { return }
            self.settings.interfaceLanguage = chosen
            self.refresh(force: true)
        }
        root.addArrangedSubview(settingsGroup(nil, rows: [SDRowView(
            title: t("Язык интерфейса", "Interface language"),
            subtitle: t("Языки диктовки от этого не зависят — они в «Диктовке»",
                        "Dictation languages are separate — they live in Dictation"),
            control: interfacePills,
            style: .card
        )]))

        // Две разные вещи, которые носили одну подпись: автозапуск службы и
        // логин-айтем окна (аудит №16). Тумблер службы значил вдобавок третье
        // — «включена сейчас»; это состояние, и оно уехало в панель меню-бара.
        let autostartToggle = SDToggle()
        autostartToggle.isOn = settings.agentEnabled
        autostartToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            self.setDictationAutostart(enabled)
        }
        let autostartRow = SDRowView(
            title: t("Запускать диктовку в фоне", "Start dictation in the background"),
            subtitle: t("Служба поднимается вместе с системой и слушает хоткей — без окон",
                        "The service comes up with the system and listens for the hotkey — no windows"),
            control: autostartToggle,
            style: .card
        )

        let loginItemStatus = loginItemStatus()
        let loginToggle = SDToggle()
        loginToggle.isOn = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        loginToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    log("panel login item enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    log("panel login item disabled")
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = self.t("Не удалось изменить объект входа",
                                           "Login item couldn't be changed")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            // Только что изменённое обязано быть видно сразу, а не через
            // срок годности прошлого ответа.
            self.loginItemStatusReading = nil
            self.refresh(force: true)
        }
        let loginSubtitle = loginItemStatus == .requiresApproval
            ? t("Ждёт одобрения: Системные настройки → Основные → Объекты входа",
                "Waiting for approval: System Settings → General → Login Items")
            : t("Только окно. Диктовка работает и без него",
                "The window only. Dictation works without it")
        let loginRow = SDRowView(
            title: t("Открывать это окно", "Open this window"),
            subtitle: loginSubtitle,
            control: loginToggle,
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("При входе в систему", "At login"),
                                              rows: [autostartRow, loginRow]))
        root.addArrangedSubview(settingsFootnote(
            t("Здесь только автозапуск. Приостановить диктовку прямо сейчас — тумблером в панели меню-бара: служба остаётся на месте, хоткей молчит.",
              "Autostart only. To pause dictation right now use the toggle in the menu-bar panel: the service stays, the hotkey goes quiet.")))

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
        let updatesRow = SDRowView(
            title: t("Проверять обновления", "Check for updates"),
            subtitle: t("Раз в 6 часов приложение спрашивает номер последней версии. "
                        + "Это единственный сетевой запрос — он же виден в «Приватности»",
                        "Every 6 hours the app asks for the latest version number. "
                        + "It is the only network request — Privacy shows the same one"),
            control: updatesToggle,
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("Обновления", "Updates"),
                                              rows: [updatesRow, versionRow()]))

        // Состояние службы вкладкой не является: переключать там нечего.
        // Дверь оставляем здесь, где человек ищет «а где всё остальное».
        // Кнопка «пожаловаться» живёт рядом с диагностикой: человек, у
        // которого что-то сломалось, ищет её именно здесь, а не в меню-баре.
        root.addArrangedSubview(settingsGroup(nil, rows: [SDRowView(
            title: t("Разрешения, модель, измерения и диагностика",
                     "Permissions, model, measurements and diagnostics"),
            subtitle: t("Это состояние, а не настройки — они в разделе «Служба»",
                        "That is state, not preferences — it lives in the Service section"),
            control: panelButton(t("Открыть «Службу»", "Open Service"),
                                 action: #selector(openServiceSectionFromPanel(_:))),
            style: .card
        ), SDRowView(
            title: t("Сообщить о проблеме", "Report a problem"),
            subtitle: t("Соберёт журнал и отчёты о сбоях в архив и откроет письмо. "
                        + "Ничего не уходит без вашего «Отправить»",
                        "Packs the log and crash reports into an archive and opens an email. "
                        + "Nothing leaves until you press Send"),
            control: panelButton(t("Собрать архив…", "Build archive…"),
                                 action: #selector(reportProblemFromPanel(_:))),
            style: .card
        )]))
    }



    // MARK: Вкладка «Приватность» — что уходит с этого Mac

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
            t("Речь распознаётся моделью на этом компьютере. Ни звук, ни расшифровка никуда не отправляются.",
              "Speech is transcribed by a model on this computer. Neither the audio nor the transcript is sent anywhere."),
            size: 12, color: SD.C.graphite)
        sub.maximumNumberOfLines = 2
        sub.alignment = .center
        sub.preferredMaxLayoutWidth = 420
        let showcase = NSStackView(views: [wave, headline, sub])
        showcase.orientation = .vertical
        showcase.alignment = .centerX
        showcase.spacing = 8
        showcase.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 4, right: 0)
        root.addArrangedSubview(showcase)

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
        // Подпись обещала «стереть» — а выключение только останавливает
        // запись новых текстов; стирает кнопка ниже. И «больше не
        // записывать» неточно в другую сторону: обезличенные счётчики
        // статистики считаются в любом случае.
        var diskRows: [NSView] = [SDRowView(
            title: t("Хранить историю диктовок", "Keep dictation history"),
            subtitle: t("Локально, до \(groupedNumberLabel(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES, language: .russian)) записей. Выключение останавливает запись текстов; счётчики статистики считаются в любом случае",
                        "Locally, up to \(groupedNumberLabel(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES, language: .english)) entries. Switching off stops recording texts; statistics counters keep running either way"),
            control: historyToggle,
            style: .card
        )]

        if settings.recentTranscriptLimit != .off {
            let menuLimits: [RecentTranscriptLimit] = [.last1, .last5, .last10]
            let limitPills = SDPills(options: menuLimits.map {
                .init(title: $0.rawValue, value: $0.rawValue)
            }, selected: settings.recentTranscriptLimit.rawValue)
            limitPills.onSelect = { [weak self] raw in
                guard let limit = RecentTranscriptLimit(rawValue: raw) else { return }
                self?.settings.recentTranscriptLimit = limit
            }
            diskRows.append(SDRowView(
                title: t("Недавнее в панели меню-бара", "Recent list in the menu-bar panel"),
                subtitle: t("Длина списка по клику на иконку. Окно «История» показывает все",
                            "How long the list is when you click the icon. The History window shows all of them"),
                control: limitPills,
                style: .card
            ))
        }

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
        let actions = NSStackView(views: [showModels, wipeHistory])
        actions.orientation = .horizontal
        actions.spacing = 16
        diskRows.append(SDRowView(title: t("Файлы на диске", "Files on disk"),
                                  control: actions,
                                  style: .card))

        root.addArrangedSubview(settingsGroup(t("Что хранится на диске", "What is kept on disk"),
                                              rows: diskRows))

        // Факты — не переключатели. Раньше они стояли строками вперемешку с
        // тумблерами и выглядели одинаково; здесь у них своя приглушённая
        // карточка без правого столбца управления, и видно, что это ответы.
        // Значение сетевых запросов было зашито как «0 — обновления
        // отключены»: пока проверка стояла за мёртвым `return`, это была
        // правда, а с включённым каналом стало бы враньём ровно в той
        // вкладке, где человек решает, насколько приложению верить.
        let networkFact = privacyFactRow(
            title: t("Сетевые запросы", "Network requests"),
            subtitle: settings.checkForUpdates
                ? t("Единственный. Отключается в «Приложение» → Обновления",
                    "The only one. Switched off in App → Updates")
                : t("Автопроверка выключена — приложение само в сеть не ходит",
                    "Automatic checks are off — the app does not go online on its own"),
            value: settings.checkForUpdates
                ? t("1 раз в 6 ч", "once every 6 h")
                : t("нет", "none"))
        // Записи для диагностики включаются только вручную, но факт обязан
        // сказать правду и тогда.
        let keptSamples = DiagnosticAudioSamples.keptCount()
        let audioFact = privacyFactRow(
            title: t("Аудио после распознавания", "Audio after transcription"),
            subtitle: keptSamples > 0
                ? t("Включены записи для диагностики: последние \(keptSamples) лежат в Application Support/Dictor/AudioSamples",
                    "Diagnostic recordings are on: the latest \(keptSamples) are kept in Application Support/Dictor/AudioSamples")
                : t("На время обработки на диске живёт страховочный журнал. При сбое он остаётся, чтобы вернуть диктовку в историю",
                        "A crash-recovery journal lives on disk while a dictation is handled. After a failure it stays so the dictation can be recovered"),
            value: keptSamples > 0 ? t("хранятся", "kept") : t("удаляется", "deleted"))
        let notificationsFact = privacyFactRow(
            title: t("Системные уведомления", "System notifications"),
            subtitle: t("Приложение не показывает баннеров — ни разу, ни при ошибке",
                        "The app shows no banners — not once, not even on failure"),
            value: t("не отправляются", "never sent"))

        // Умная вставка заглядывает в чужое поле — это надо сказать там, где
        // человек решает, насколько приложению верить, а не только в файле
        // PRIVACY.md. Число знаков берётся из кода: разойтись они не могут.
        let caretFact = privacyFactRow(
            title: t("Текст перед курсором", "Text before the cursor"),
            subtitle: settings.smartInsertionEnabled
                ? t("Умная вставка смотрит на последние \(InsertionContextReader.tailUTF16Length) знаков перед курсором, чтобы понять, продолжается ли фраза. Они не сохраняются и не пишутся в журнал; поля с паролем не читаются",
                    "Smart insertion looks at the last \(InsertionContextReader.tailUTF16Length) characters before the cursor to tell whether a sentence continues. They are neither stored nor logged; password fields are not read")
                : t("Умная вставка выключена — содержимое полей приложение не читает",
                    "Smart insertion is off — the app does not read what is in the field"),
            value: settings.smartInsertionEnabled
                ? t("только в памяти", "in memory only")
                : t("не читается", "not read"))

        let factsCard = SDFactCard(rows: [networkFact, audioFact, caretFact, notificationsFact])
        let factsGroup = NSStackView(views: [
            serviceGroupHeader(t("Факты, а не переключатели", "Facts, not switches")),
            factsCard,
        ])
        factsGroup.orientation = .vertical
        factsGroup.alignment = .leading
        factsGroup.spacing = 7
        for view in factsGroup.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: factsGroup.widthAnchor).isActive = true
        }
        root.addArrangedSubview(factsGroup)
    }

    /// Строка-факт: слева вопрос, справа ответ. Контрола нет намеренно —
    /// это утверждение о поведении программы, а не то, что можно изменить.
    private func privacyFactRow(title: String, subtitle: String, value: String) -> NSView {
        SDRowView(title: title,
                  subtitle: subtitle,
                  control: panelLabel(value, size: 12, weight: .medium, color: SD.C.graphite),
                  style: .card)
    }

    func monoValueLabel(_ text: String) -> NSTextField {
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

    // MARK: - Раздел «Настройки» (макет 2c/4b/6d внутри окна 6a)

    /// Настройки — такой же раздел окна, как «Сегодня» и «История».
    /// Отдельного окна больше нет: в макете 6a это пункт сайдбара.
    /// Шапки с названием раздела здесь нет намеренно. Слово «Настройки» уже
    /// подсвечено в сайдбаре в тридцати пунктах левее, а содержимое называет
    /// полоса вкладок — заголовок между ними был чистым повтором и съедал
    /// 52 pt высоты у вкладок, которые и так длиннее экрана. У остальных
    /// разделов шапка остаётся: у «Словаря» она несёт кнопку «Добавить», а
    /// «Службе», «Истории» и «Статистике» больше нечем назвать экран.
    func makeSettingsSectionView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

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
        // Окно с fullSizeContentView: скролл сам добавил бы сверху отступ
        // высотой с тайтлбар, чтобы содержимое не уезжало под кнопки окна.
        // Кнопки лежат над сайдбаром, а не над этой панелью, так что отступ
        // здесь — просто пустая полоса над первой строкой.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Шапка раздела: заголовок 14/600 слева, произвольный контрол справа,
    /// hairline снизу (макет 6a/6b).
    func makeSectionHeader(title: String, accessory: NSView?) -> NSView {
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

    // MARK: Вкладка «Вид» — что видно на экране

    private func addLookTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        // Главный шов старой раскладки: капсула записи была разорвана между
        // «Внешним видом» (тумблер, фон, цвет) и «Продвинутыми» (размер,
        // положение). Пять настроек одного объекта теперь стоят вместе, под
        // одним превью, и видно, что меняется.
        let preview = SDCapsulePreview(
            size: settings.recordingHUDSize,
            backgroundStyle: settings.recordingHUDBackgroundStyle,
            color: settings.recordingHUDRecordingColor.nsColor,
            transcribingColor: settings.recordingHUDTranscribingColor.nsColor,
            language: language)
        preview.translatesAutoresizingMaskIntoConstraints = false

        let hudToggle = SDToggle()
        hudToggle.isOn = settings.showRecordingWaveform
        hudToggle.onToggle = { [weak self] enabled in
            self?.settings.showRecordingWaveform = enabled
        }
        let showRow = SDRowView(
            title: t("Показывать капсулу", "Show the capsule"),
            subtitle: t("Волна и таймер рядом с курсором, пока идёт диктовка",
                        "Wave and timer beside the cursor while dictation runs"),
            control: hudToggle,
            style: .card
        )

        let sizes: [RecordingHUDSize] = [.compact, .standard, .large]
        let sizeSegmented = SDSegmented(titles: ["S", "M", "L"],
                                        values: sizes.map(\.rawValue),
                                        selected: settings.recordingHUDSize.rawValue)
        sizeSegmented.onSelect = { [weak self, weak preview] raw in
            guard let size = RecordingHUDSize(rawValue: raw) else { return }
            self?.settings.recordingHUDSize = size
            self?.settingsDraft?.hudSize = size
            preview?.apply(size: size)
        }
        let sizeRow = SDRowView(title: t("Размер", "Size"),
                                control: sizeSegmented,
                                style: .card)

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
        let placementRow = SDRowView(
            title: t("Положение", "Position"),
            subtitle: t("Если поле ввода не найдено — сверху по центру",
                        "If no text field is found — top center"),
            control: SDFieldButton(popup: placement),
            style: .card
        )

        let backgroundPills = SDPills(options: RecordingHUDBackgroundStyle.allCases.map {
            .init(title: localizedBackgroundName($0), value: $0.rawValue)
        }, selected: settings.recordingHUDBackgroundStyle.rawValue)
        backgroundPills.onSelect = { [weak self, weak preview] raw in
            guard let style = RecordingHUDBackgroundStyle(rawValue: raw) else { return }
            self?.settings.recordingHUDBackgroundStyle = style
            self?.settingsDraft?.backgroundStyle = style
            preview?.apply(backgroundStyle: style)
        }
        let backgroundRow = SDRowView(title: t("Фон", "Background"),
                                      control: backgroundPills,
                                      style: .card)

        // Макет: кружки-свотчи 22px вместо пилюль с названиями.
        let swatches = SDColorSwatches(
            swatches: RecordingHUDAccentColor.allCases.map {
                .init(value: $0.rawValue, color: $0.nsColor)
            },
            selected: settings.recordingHUDRecordingColor.rawValue
        )
        swatches.onSelect = { [weak self, weak preview] raw in
            guard let color = RecordingHUDAccentColor(rawValue: raw) else { return }
            self?.settings.recordingHUDRecordingColor = color
            self?.settingsDraft?.recordingColor = color
            preview?.apply(color: color.nsColor)
        }
        let colorRow = SDRowView(
            title: t("Цвет волны", "Wave color"),
            // «Он же цвет приложения» тут стояло из макета и было неправдой:
            // акцент интерфейса — константа и за этой настройкой не следует.
            // Правдой это делать нельзя как есть: в палитре белый и серый,
            // подобранные под тёмную капсулу, — акцентом всего окна белый
            // сделал бы невидимыми «Стереть историю…» и точку обновления.
            subtitle: t("Волна в капсуле выше. Цвет фазы распознавания задаётся только через defaults write",
                        "The wave in the capsule above. The transcribing phase color is set through defaults write only"),
            control: swatches,
            style: .card
        )

        // Превью стоит над карточкой: оно показывает то, что настраивают
        // строки под ним, — а не одну из них.
        let previewStage = NSStackView(views: [preview])
        previewStage.orientation = .vertical
        previewStage.alignment = .centerX
        previewStage.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)

        let capsuleGroup = NSStackView(views: [
            serviceGroupHeader(t("Капсула записи", "Recording capsule")),
            previewStage,
            SDSettingsGroupCard(rows: [showRow, sizeRow, placementRow,
                                       backgroundRow, colorRow]),
        ])
        capsuleGroup.orientation = .vertical
        capsuleGroup.alignment = .leading
        capsuleGroup.spacing = 7
        for view in capsuleGroup.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: capsuleGroup.widthAnchor).isActive = true
        }
        root.addArrangedSubview(capsuleGroup)

        // Плавающая капсула отделена в свою группу именно потому, что
        // настройки капсулы записи на неё не действуют: соседство в одной
        // карточке обещало бы обратное (аудит №6).
        let capsuleToggle = SDToggle()
        capsuleToggle.isOn = settings.floatingCapsuleEnabled
        capsuleToggle.onToggle = { [weak self] enabled in
            self?.settings.floatingCapsuleEnabled = enabled
        }
        let floatingRow = SDRowView(
            title: t("Постоянная капсула", "Permanent capsule"),
            subtitle: t("Всегда на экране: перетаскивается, прилипает к краям, помнит "
                        + "место, при записи растёт сама. Размер — тот же, что выбран выше",
                        "Always on screen: drag it, it sticks to the edges, remembers "
                        + "its place and grows while recording. Size follows the choice above"),
            control: capsuleToggle,
            style: .card
        )

        // Настройка существовала всегда, но shouldShowDockIcon жёстко
        // возвращал false — пункт старого меню переключал её впустую.
        // Значок принадлежит службе и показывается, пока это окно закрыто.
        let dockToggle = SDToggle()
        dockToggle.isOn = settings.showInDock
        dockToggle.onToggle = { [weak self] enabled in
            self?.settings.showInDock = enabled
        }
        let dockRow = SDRowView(
            title: t("Значок в Dock", "Dock icon"),
            subtitle: t("Клик по значку открывает это окно. Иконка в меню-баре остаётся всегда",
                        "Clicking it opens this window. The menu-bar icon always stays"),
            control: dockToggle,
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("На рабочем столе", "On the desktop"),
                                              rows: [floatingRow, dockRow]))
    }

    // MARK: - Раздел «Служба» — состояние, а не настройки

    /// Разрешения, модель, измерения и обслуживание. Ни одного переключателя
    /// предпочтений: всё здесь — ответ на вопрос «что там со службой», и
    /// приходят сюда из подвала сайдбара или из «Приложения».
    // MARK: Вкладка «Служба» — работает ли всё это сейчас

    /// Разрешения, модель, измерения и обслуживание. Ни одного переключателя:
    /// строка вкладок обещает предпочтения, и обещание снимается словами —
    /// подписью сверху, а не заголовком раздела. Отдельным разделом сайдбара
    /// это жило ровно один релиз: сайдбар — про данные (Сегодня, История,
    /// Статистика, Словарь), а состояние службы данными не является.
    private func addServiceTabRows(to root: NSStackView) {
        let caption = panelLabel(
            t("Состояние диктовки на этом Mac. Здесь нечего настраивать — только увидеть и починить.",
              "How dictation is doing on this Mac. Nothing to configure here — only to see and to fix."),
            size: 11.5, color: SD.C.subtle)
        caption.preferredMaxLayoutWidth = 640
        root.addArrangedSubview(caption)

        addServicePermissionsGroup(to: root)
        addServiceModelGroup(to: root)
        addServiceMeasurementsGroup(to: root)
        addServiceMaintenanceGroup(to: root)
    }

    private func addServicePermissionsGroup(to root: NSStackView) {
        let report = PermissionsDoctor.report()
        var rows: [NSView] = []
        for (index, row) in report.rows.enumerated() {
            let copy = onboardingPermissionCopy(row.permission, language: language)
            let control: NSView
            if row.diagnosis == .missing {
                let button = NSButton(title: t("Разрешить", "Allow"),
                                      target: self,
                                      action: #selector(permissionGrantClicked(_:)))
                button.tag = index
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 12)
                control = button
            } else {
                control = panelLabel(PermissionsDoctor.explain(row.diagnosis, language: language),
                                     size: 12, weight: .medium,
                                     color: row.diagnosis == .granted ? SD.C.positive : SD.C.graphite)
            }
            let dot = SDStatusDot(shape: row.diagnosis == .granted ? .round : .square,
                                  color: row.diagnosis == .granted ? SD.C.positive : SD.C.danger)
            rows.append(SDRowView(title: copy.name,
                                  subtitle: copy.why,
                                  control: control,
                                  style: .card,
                                  leading: dot))
        }

        let fix = NSButton(title: t("Проверить и починить", "Check and repair"),
                           target: self,
                           action: #selector(permissionRepairClicked(_:)))
        fix.bezelStyle = .rounded
        fix.font = .systemFont(ofSize: 12, weight: .semibold)
        rows.append(SDRowView(
            title: t("Разрешение выдано, а не работает", "Granted but not working"),
            subtitle: t("Частая причина — вторая копия приложения или устаревшая "
                        + "запись системы после смены подписи",
                        "Usually a second copy of the app or a stale system record "
                        + "after the signature changed"),
            control: fix,
            style: .card
        ))
        root.addArrangedSubview(settingsGroup(t("Разрешения macOS", "macOS permissions"),
                                              rows: rows))

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

    private func addServiceModelGroup(to root: NSStackView) {
        let profile = SpeechModelProfile.productionDefault
        // Карточка называет ту модель, которая распознаёт на самом деле. После
        // обновления приложения это может быть модель прошлой версии — пока
        // новая скачивается, — и «используется» рядом с именем новой было бы
        // неправдой.
        let modelUpdate = previewModelUpdateOverride
            ?? AgentRuntimeStateStore.read()?.speechModelUpdate
        let cardTitle: String
        let cardDetail: String
        if let modelUpdate {
            cardTitle = modelUpdate.previousModelName + " · "
                + t("используется, пока не готова новая", "in use until the new one is ready")
            cardDetail = speechModelUpdateDetail(modelUpdate, newModelName: profile.shortName)
        } else {
            cardTitle = profile.shortName + " · " + t("используется", "in use")
            cardDetail = t("~630 МБ · русский, английский и ещё 16 языков · Neural Engine. "
                           + "Работает целиком на этом Mac; скачивается с huggingface.co при установке.",
                           "~630 MB · Russian, English and 16 more · Neural Engine. "
                           + "Runs entirely on this Mac; downloads from huggingface.co at setup.")
        }
        let card = SDModelCard(
            title: cardTitle,
            detail: cardDetail,
            active: true,
            actionTitle: nil,
            target: nil,
            action: nil,
            identifier: profile.rawValue
        )
        card.translatesAutoresizingMaskIntoConstraints = false

        let memoryRow = SDRowView(
            title: t("Модель в памяти", "Model in memory"),
            subtitle: t("Выгружается только при смене модели — первая диктовка без задержки",
                        "Unloaded only when the model changes — the first dictation has no warm-up"),
            control: panelLabel(t("всегда", "always"), size: 12, weight: .medium),
            style: .card
        )

        let wrapper = NSStackView(views: [card, settingsGroup(nil, rows: [memoryRow])])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 10
        for view in wrapper.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        }

        let group = NSStackView(views: [
            serviceGroupHeader(t("Модель", "Model")),
            wrapper,
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        for view in group.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        root.addArrangedSubview(group)
    }

    /// Одна строка: подпись карточки модели не переносится.
    private func speechModelUpdateDetail(_ update: SpeechModelUpdateStatus,
                                         newModelName: String) -> String {
        switch update.phase {
        case .downloading:
            let percent = update.fraction.map { " — \(Int(($0 * 100).rounded()))\u{00A0}%" } ?? ""
            return t("\(newModelName) (~630 МБ) скачивается\(percent). Диктовка работает; "
                     + "служба перейдёт на новую модель сама, в паузе.",
                     "\(newModelName) (~630 MB) is downloading\(percent). Dictation works; "
                     + "the service moves to the new model on its own, when idle.")
        case .waitingForIdle:
            return t("\(newModelName) скачана и проверена. Служба перейдёт на неё сама, "
                     + "когда вы пару минут не диктуете.",
                     "\(newModelName) is downloaded and verified. The service moves to it "
                     + "on its own once you stop dictating for a couple of minutes.")
        case .retrying:
            // Причину не называем: это может быть сеть, место на диске или
            // файлы, которые не сошлись с проверкой, — подробности в журнале.
            return t("\(newModelName) (~630 МБ) пока не скачалась. "
                     + "Диктовка работает; загрузка повторится сама.",
                     "\(newModelName) (~630 MB) hasn’t downloaded yet. "
                     + "Dictation works; the download retries on its own.")
        case .failedToLoad:
            return t("\(newModelName) скачана, но на этом Mac не запустилась. "
                     + "Диктовка работает на прежней модели; подробности — в журнале.",
                     "\(newModelName) is downloaded but failed to start on this Mac. "
                     + "Dictation runs on the previous model; the log has the details.")
        }
    }

    private func addServiceMeasurementsGroup(to root: NSStackView) {
        let tiles = performanceTilesRow()
        tiles.translatesAutoresizingMaskIntoConstraints = false
        let group = NSStackView(views: [
            serviceGroupHeader(t("Измерения", "Measurements")),
            tiles,
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        for view in group.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        root.addArrangedSubview(group)
    }

    private func addServiceMaintenanceGroup(to root: NSStackView) {
        // Подсказки «Сегодня» закрываются навсегда — правило макета 6e.
        // Раньше «навсегда» было буквальным: dismissedHints нигде не
        // сбрасывался, и вернуть подсказки не мог никто (аудит, мелочь №15).
        let dismissed = settings.dismissedHints.count
        let hintsRow = SDRowView(
            title: t("Закрытые подсказки", "Dismissed hints"),
            subtitle: dismissed > 0
                ? t("\(dismissed) \(pluralizeRU(dismissed, "подсказка скрыта", "подсказки скрыты", "подсказок скрыто")) на экране «Сегодня»",
                    "\(dismissed) \(dismissed == 1 ? "hint is" : "hints are") hidden on the Today screen")
                : t("Закрытых нет", "Nothing is dismissed"),
            control: panelButton(t("Вернуть", "Restore"),
                                 action: #selector(restoreDismissedHintsFromPanel(_:)),
                                 enabled: dismissed > 0),
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("Обслуживание", "Maintenance"),
                                              rows: [hintsRow]))
    }

    /// Заголовок группы раздела «Служба» — тот же, что у групп настроек:
    /// раздел читается как продолжение вкладок, а не как чужой экран.
    private func serviceGroupHeader(_ title: String) -> NSView {
        let header = settingsGroupHeaderLabel(title)
        let wrapper = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            header.topAnchor.constraint(equalTo: wrapper.topAnchor),
            header.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    @objc private func restoreDismissedHintsFromPanel(_ sender: NSButton) {
        settings.dismissedHints = []
        refresh(force: true)
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
        let row = SDAdvancedRowView(rowTitle: title, control: control)
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

    func panelLabel(_ text: String,
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

    func panelButton(_ title: String,
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

    func permissionTitle(_ permission: Permission) -> String {
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

    func beginServiceOperation(_ operation: ControlPanelServiceOperation) {
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

    func showError(title: String, detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: t("ОК", "OK"))
        alert.runModal()
    }
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
