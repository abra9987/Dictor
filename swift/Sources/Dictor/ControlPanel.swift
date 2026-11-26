import AppKit
import Foundation
import CoreGraphics
import ServiceManagement


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
    var refreshTimer: Timer?
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
    var onboardingFlow: OnboardingFlow?
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
    var mainHistoryScrollContext = ""
    /// Состояние объекта входа и момент, когда его спрашивали.
    var loginItemStatusReading: (status: SMAppService.Status, readAt: TimeInterval)?
    weak var historyDetailTranscriptView: SDSelectableTranscriptView?
    /// Раздел главного окна (макет 6a): «Сегодня» открывается первым.
    var mainSection: MainWindowSection = .today
    /// Выбранная запись в «Истории» и фильтр «Закреплённые» (макет 6b).
    /// Не private: самотест `today-actions` проверяет, что переход из
    /// «Сегодня» выбирает именно ту запись, по которой щёлкнули.
    var historySelectionKey: String?
    var pendingSettingsApply: DispatchWorkItem?
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
    func applyOnboarding() {
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
