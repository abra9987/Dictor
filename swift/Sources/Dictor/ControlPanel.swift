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
    var permissionClickCount: [Permission: Int] = [:]
    var settingsDraft: ControlPanelSettingsDraft?
    var settingsTab = SETTINGS_TABS[0].id
    var hotkeyRecorder: HotkeyRecorderController?
    private var onboardingFlow: OnboardingFlow?
    var onboardingPage: OnboardingPageView?
    /// Отчёт последней починки разрешений. Пусто — показываем план.
    var permissionRepairNotes: [String] = []
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
    var loginItemStatusReading: (status: SMAppService.Status, readAt: TimeInterval)?
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

    func compactCard() -> NSView {
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

    func panelSymbol(_ name: String,
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

    func pin(_ view: NSView,
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

    func permissionDetail(_ permission: Permission) -> String {
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

    func localizedBackgroundName(_ style: RecordingHUDBackgroundStyle) -> String {
        guard language == .russian else { return style.displayName }
        switch style {
        case .system: return "Как в системе"
        case .dark: return "Тёмный"
        case .light: return "Светлый"
        }
    }

    @objc func recordDictationShortcutClicked(_ sender: NSButton) {
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
    func scheduleSettingsApply(after delay: TimeInterval) {
        pendingSettingsApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applySettingsDraft()
        }
        pendingSettingsApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func settingsValidationMessage(_ draft: ControlPanelSettingsDraft) -> String? {
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
