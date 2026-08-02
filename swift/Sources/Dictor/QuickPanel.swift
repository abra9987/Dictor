import AppKit

// Поповер меню-бара по дизайну 1d/1e: статус + тумблер, язык пилюлями,
// микрофон, «Недавнее» (1/5/10 записей — по настройке, hover-действия),
// статистика, футер. Открывается левым кликом по глифу.

@MainActor
protocol QuickPanelDelegate: AnyObject {
    func quickPanelDidToggleEnabled(_ enabled: Bool)
    func quickPanelDidSelectLanguage(_ language: DictationLanguage)
    func quickPanelDidSelectInputDevice(uid: String)
    func quickPanelDidCopyRecent(text: String)
    func quickPanelDidPasteRecent(text: String)
    func quickPanelOpenSettings()
    func quickPanelOpenHistory()
    func quickPanelQuit()
    func quickPanelInstallUpdate()
    func quickPanelCheckForUpdates()
    func quickPanelStatusPrimaryAction()
    func quickPanelStatusSecondaryAction()
}

struct QuickPanelState {
    var enabled: Bool
    var language: DictationLanguage
    var microphoneName: String
    var devices: [AudioInputDevice]
    var recent: [TranscriptHistoryEntry]
    /// История может быть выключена в настройках — тогда пустое «Недавнее»
    /// обязано назвать причину, а не обещать «первая диктовка появится здесь».
    var historyKeepingEnabled: Bool
    var todayCharacters: Int
    var todayAudioSeconds: Double
    var weekBars: [CGFloat]
    var interfaceLanguage: InterfaceLanguage
    /// Версия, которую предлагает канал обновлений, если она есть. Панель —
    /// то, что открывается левым кликом, то есть единственное меню, которое
    /// человек вообще видит; предложение обновиться обязано быть и здесь.
    var availableUpdateVersion: String?
    var installedVersion: String
    var isCheckingForUpdates: Bool
    /// Состояние службы — одно из девяти (макет 8b). Панель показывает его
    /// теми же словами, что и подвал окна.
    var serviceStatus: ServiceStatusKind
}

@MainActor
final class DictorQuickPanel: NSPanel {
    weak var quickDelegate: QuickPanelDelegate?
    private var state: QuickPanelState
    private let contentStack = NSStackView()
    private var waveView: QuickPanelWaveView?
    private var outsideClickMonitor: Any?
    /// Проверка, которая ничего не нашла, обязана это сказать. Иначе нажатие
    /// «Проверить» выглядит как нажатие в пустоту — а именно за этим человек
    /// и нажимал.
    private var showsUpToDate = false
    private var upToDateWorkItem: DispatchWorkItem?

    static let panelWidth: CGFloat = 360

    init(state: QuickPanelState) {
        self.state = state
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        rebuildContent()
    }

    // MARK: - Показ / скрытие

    func toggle(relativeTo button: NSStatusBarButton, state: QuickPanelState) {
        if isVisible {
            close()
        } else {
            show(relativeTo: button, state: state)
        }
    }

    func show(relativeTo button: NSStatusBarButton, state: QuickPanelState) {
        apply(state: state)
        layoutIfNeeded()
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - frame.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - frame.width - 8)
        let y = buttonFrame.minY - frame.height - 6
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
        waveView?.startAnimating()
        installOutsideClickMonitor()
    }

    override func close() {
        waveView?.stopAnimating()
        removeOutsideClickMonitor()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    func apply(state: QuickPanelState) {
        self.state = state
        rebuildContent()
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: state.interfaceLanguage)
    }

    // MARK: - Сборка контента

    private func rebuildContent() {
        let container = PaperBackgroundView()
        container.fill = SD.C.popoverPaper
        container.cornerRadius = 12
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        contentStack.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(headerRow())
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(languageRow())
        stack.addArrangedSubview(microphoneRow())
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(recentHeader())
        // Макет: блок записей с полем 4px 6px 6px, ряды со скруглением 8.
        let recentBlock = NSStackView()
        recentBlock.orientation = .vertical
        recentBlock.alignment = .leading
        recentBlock.spacing = 0
        recentBlock.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 6, right: 6)
        // Сколько записей показывать, решает настройка «Недавнее в панели
        // меню-бара» (1/5/10): список приходит уже обрезанным по ней. Жёсткий
        // prefix(3) делал пилюли 1/5/10 враньём — они управляли только
        // подменю старого меню.
        for entry in state.recent {
            let row = recentRow(entry)
            recentBlock.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentBlock.widthAnchor,
                                       constant: -12).isActive = true
        }
        if state.recent.isEmpty {
            recentBlock.addArrangedSubview(emptyRecentRow())
        }
        stack.addArrangedSubview(recentBlock)
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(statsRow())
        stack.addArrangedSubview(hairline(inset: 0))
        stack.addArrangedSubview(updateRow())
        stack.addArrangedSubview(footerRow())

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            // Жёсткая ширина: без неё длинная запись в «Недавнем»
            // продавливает fitting-ширину, и окно разъезжается на весь экран.
            stack.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        contentView = container
        let height = stack.fittingSize.height
        setContentSize(NSSize(width: Self.panelWidth, height: height))
    }

    private func hairline(inset: CGFloat = 16) -> NSView {
        let line = SDHairlineView()
        line.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -inset),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrapper
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        // Текст обязан обрезаться, а не распирать панель.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // MARK: - Ряды

    /// Шапка панели по макету 8b. Маркер 8×8, заголовок 14/600, подпись 12,
    /// тумблер 36×22 — всё на одном месте во всех девяти состояниях; меняются
    /// форма маркера, тексты, высота и наличие кнопок.
    ///
    /// Раньше здесь всегда стояла волна: она шла и когда служба готова, и
    /// когда лежит. Движение — обещание работы, и обещать его в состоянии
    /// покоя значит врать; теперь в «Готово» стоит зелёная точка, а волна
    /// появляется ровно тогда, когда что-то действительно происходит.
    private func headerRow() -> NSView {
        let kind = state.serviceStatus
        let view = serviceStatusPresentation(kind, language: state.interfaceLanguage)

        let row = NSView()
        let marker = ServiceStatusMarkerView()
        marker.markerSize = 8
        switch kind {
        case .ready: marker.shape = .dot(SD.C.positive)
        // Пауза, как и «выключено», — намеренный покой: кольцо, без движения.
        case .off, .paused: marker.shape = .hollowRing
        case .needsPermission, .versionMismatch: marker.shape = .hollowSquare
        case .failed: marker.shape = .filledSquare(SD.C.danger)
        default: marker.shape = .wave(slow: kind.waveIsSlow)
        }

        let title = label(view.title, size: 14, weight: .semibold,
                          color: kind == .off ? SD.C.graphite : SD.C.ink)
        let subtitle = label(view.subtitle, size: 12,
                             color: kind == .off ? SD.C.hintText : SD.C.graphite)
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = Self.panelWidth - 32 - 36 - 12

        let toggle = SDToggle()
        toggle.isOn = state.enabled
        // Во время обновления тумблер не нажимается: служба и так сейчас
        // сменится, а нажатие в этот момент только запутает.
        toggle.isEnabled = kind != .updating
        toggle.alphaValue = kind == .updating ? 0.45 : 1
        toggle.onToggle = { [weak self] enabled in
            self?.quickDelegate?.quickPanelDidToggleEnabled(enabled)
        }

        let head = NSStackView(views: [marker, title])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        let textColumn = NSStackView(views: [head, subtitle])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 3

        for sub in [textColumn, toggle] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            toggle.widthAnchor.constraint(equalToConstant: 36),
            toggle.heightAnchor.constraint(equalToConstant: 22),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            textColumn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            textColumn.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor,
                                                 constant: -12),
            textColumn.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
        ])

        // Прогресс и кнопки — только там, где они есть по макету.
        var lastAnchor: NSView = textColumn
        if let ticks = view.ticks {
            let ticksView = ServiceStatusTicksView()
            ticksView.done = ticks.done
            ticksView.total = ticks.total
            ticksView.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(ticksView)
            NSLayoutConstraint.activate([
                ticksView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                ticksView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                ticksView.topAnchor.constraint(equalTo: textColumn.bottomAnchor, constant: 8),
                ticksView.heightAnchor.constraint(equalToConstant: 5),
            ])
            lastAnchor = ticksView
        } else if let fraction = view.progressFraction {
            let bar = ServiceStatusProgressView()
            bar.fraction = fraction
            bar.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                bar.topAnchor.constraint(equalTo: textColumn.bottomAnchor, constant: 8),
                bar.heightAnchor.constraint(equalToConstant: 5),
            ])
            lastAnchor = bar
        }

        if let primary = view.primaryAction {
            let buttons = NSStackView()
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8
            buttons.translatesAutoresizingMaskIntoConstraints = false

            let main = NSButton(title: primary, target: self,
                                action: #selector(statusPrimaryClicked))
            main.isBordered = false
            main.wantsLayer = true
            main.layer?.cornerRadius = 8
            main.layer?.backgroundColor = main.resolvedCGColor(SD.C.voice)
            main.contentTintColor = .white
            main.font = .systemFont(ofSize: 12, weight: .semibold)
            main.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons.addArrangedSubview(main)

            if let secondary = view.secondaryAction {
                let quiet = NSButton(title: secondary, target: self,
                                     action: #selector(statusSecondaryClicked))
                quiet.isBordered = false
                quiet.font = .systemFont(ofSize: 12, weight: .medium)
                quiet.contentTintColor = SD.C.inkSecondary
                quiet.heightAnchor.constraint(equalToConstant: 28).isActive = true
                buttons.addArrangedSubview(quiet)
            }
            buttons.addArrangedSubview(NSView())

            row.addSubview(buttons)
            NSLayoutConstraint.activate([
                buttons.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                buttons.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                buttons.topAnchor.constraint(equalTo: lastAnchor.bottomAnchor, constant: 10),
            ])
            lastAnchor = buttons
        }

        row.bottomAnchor.constraint(equalTo: lastAnchor.bottomAnchor, constant: 12).isActive = true

        // Отказ подсвечен той же лёгкой подложкой, что и в подвале окна.
        if kind == .failed {
            let wash = ServiceStatusFooterView()
            wash.fill = SD.C.dangerWash
            wash.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(wash, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                wash.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                wash.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                wash.topAnchor.constraint(equalTo: row.topAnchor),
                wash.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
        }
        return row
    }

    @objc private func statusPrimaryClicked() {
        close()
        quickDelegate?.quickPanelStatusPrimaryAction()
    }

    @objc private func statusSecondaryClicked() {
        close()
        quickDelegate?.quickPanelStatusSecondaryAction()
    }

    /// Предложение обновиться. Подложка голосового цвета, потому что это
    /// единственная строка панели, которая появляется не всегда, и её
    /// незаметность означала бы, что обновления снова нет.
    private func updateRow() -> NSView {
        let row = PaperBackgroundView()
        let caption: NSTextField
        let button: NSButton

        if let version = state.availableUpdateVersion {
            // Единственная строка панели, которая появляется не всегда, —
            // и потому единственная, которой позволено быть цветной. Заливка
            // разбавленная: на плотном оранжевом надпись кнопки тонет, а это
            // ровно та кнопка, ради которой строка и нужна.
            row.fill = NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(hex: 0xFF6B47).withAlphaComponent(0.16)
                    : NSColor(hex: 0xE8502F).withAlphaComponent(0.10)
            }
            caption = label(t("Доступна версия \(version)", "Version \(version) is available"),
                            size: 12.5, weight: .medium, color: SD.C.ink)
            button = NSButton(title: t("Обновить", "Update"),
                              target: self, action: #selector(installUpdateClicked))
            button.contentTintColor = SD.C.voice
        } else if showsUpToDate {
            row.fill = .clear
            caption = label(t("Установлена последняя версия — \(state.installedVersion)",
                              "You are on the latest version — \(state.installedVersion)"),
                            size: 12, color: SD.C.graphite)
            button = NSButton(title: "", target: nil, action: nil)
            button.isHidden = true
        } else if state.isCheckingForUpdates {
            row.fill = .clear
            caption = label(t("Проверяю обновления…", "Checking for updates…"),
                            size: 12, color: SD.C.graphite)
            button = NSButton(title: "", target: nil, action: nil)
            button.isHidden = true
        } else {
            row.fill = .clear
            caption = label(t("Версия \(state.installedVersion)",
                              "Version \(state.installedVersion)"),
                            size: 12, color: SD.C.graphite)
            button = NSButton(title: t("Проверить", "Check"),
                              target: self, action: #selector(checkUpdatesClicked))
            button.contentTintColor = SD.C.ink
        }
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        for view in [caption, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),
            row.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func installUpdateClicked() {
        close()
        quickDelegate?.quickPanelInstallUpdate()
    }

    @objc private func checkUpdatesClicked() {
        quickDelegate?.quickPanelCheckForUpdates()
    }

    func flashUpToDate() {
        upToDateWorkItem?.cancel()
        showsUpToDate = true
        rebuildContent()
        let revert = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showsUpToDate = false
            self.rebuildContent()
        }
        upToDateWorkItem = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: revert)
    }

    private func languageRow() -> NSView {
        // Макет: подпись 12 graphite шириной 72, пилюли как в настройках.
        let row = NSView()
        let caption = label(t("Алфавит", "Script"), size: 12, color: SD.C.graphite)

        // Те же три варианта, что в окне, — только подписи короче: панель
        // узкая, а «Кириллица» целиком в неё не влезает.
        var options: [(String, DictationLanguage)] =
            dictationScriptOptions(interfaceLanguage: state.interfaceLanguage)
                .map { ($0.shortTitle, $0.language) }
        if !options.contains(where: { $0.1 == state.language }) {
            options.insert((state.language.rawValue.uppercased(), state.language), at: 0)
        }
        let pills = SDPills(options: options.map { .init(title: $0.0, value: $0.1.rawValue) },
                            selected: state.language.rawValue)
        pills.onSelect = { [weak self] raw in
            guard let language = DictationLanguage(rawValue: raw) else { return }
            self?.quickDelegate?.quickPanelDidSelectLanguage(language)
        }

        for view in [caption, pills] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 72),
            pills.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 10),
            pills.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func microphoneRow() -> NSView {
        let row = NSView()
        let caption = label(t("Микрофон", "Microphone"), size: 12, color: SD.C.graphite)
        let popup = NSPopUpButton()
        popup.isBordered = false
        popup.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        popup.addItem(withTitle: t("Системный по умолчанию", "System default"))
        popup.lastItem?.representedObject = ""
        for device in state.devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.uid
        }
        if let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == state.microphoneUID(popupTitles: popup.itemArray)
        }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(microphoneChanged(_:))

        for view in [caption, popup] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 72),
            popup.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 6),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func recentHeader() -> NSView {
        // Макет: капс 11/600 с трекингом .05em цвета subtle,
        // справа «История» 11/500 акцентом.
        let row = NSView()
        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = NSAttributedString(
            string: t("НЕДАВНЕЕ", "RECENT"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: SD.C.subtle,
                .kern: 0.55,
            ]
        )
        let historyButton = NSButton(title: t("История", "History"),
                                     target: self,
                                     action: #selector(historyClicked))
        historyButton.isBordered = false
        historyButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        historyButton.contentTintColor = SD.C.voice

        for view in [caption, historyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            historyButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            historyButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
        ])
        return row
    }

    private func recentRow(_ entry: TranscriptHistoryEntry) -> NSView {
        // Макет: ряд padding 7px 10px, радиус 8; текст 12 ink,
        // мета 10.5 subtle «14:02 · 34 слова»; hover-действия
        // «Скопировать» ink / «Вставить снова» акцент.
        let row = QuickPanelHoverRow()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        let text = label(entry.text, size: 12, color: SD.C.ink)
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        var parts: [String] = []
        if let createdAt = entry.createdAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: state.interfaceLanguage == .russian
                                          ? "ru_RU" : "en_US")
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            parts.append(formatter.string(from: createdAt))
        }
        parts.append(dictatedWordsLabel(words, language: state.interfaceLanguage))
        let meta = label(parts.joined(separator: " · "), size: 10.5, color: SD.C.subtle)

        let copyButton = NSButton(title: t("Скопировать", "Copy"),
                                  target: self, action: #selector(copyRecentClicked(_:)))
        let pasteButton = NSButton(title: t("Вставить снова", "Paste again"),
                                   target: self, action: #selector(pasteRecentClicked(_:)))
        for button in [copyButton, pasteButton] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }
        copyButton.contentTintColor = SD.C.ink
        pasteButton.contentTintColor = SD.C.voice
        copyButton.cell?.representedObject = entry.text
        pasteButton.cell?.representedObject = entry.text
        row.hoverViews = [copyButton, pasteButton]

        for view in [text, meta, copyButton, pasteButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            meta.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            meta.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            pasteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            pasteButton.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
        ])
        return row
    }

    private func emptyRecentRow() -> NSView {
        let row = NSView()
        let text = label(state.historyKeepingEnabled
                            ? t("Пока тихо — первая диктовка появится здесь.",
                                "Quiet so far — your first dictation will show up here.")
                            : t("История выключена: Настройки → Приватность.",
                                "History is off: Settings → Privacy."),
                         size: 11.5, color: .secondaryLabelColor)
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func statsRow() -> NSView {
        let row = NSView()
        // Слова оцениваются по символам (в хранилище только characterCount).
        let words = approximateWordCount(characters: state.todayCharacters)
        let minutes = state.todayAudioSeconds / 60
        let wpm = minutes > 0.05 ? Int((Double(words) / minutes).rounded()) : 0
        // Экономия ≈ время печати (40 слов/мин) минус время речи.
        let savedMinutes = max(0, Double(words) / 40 - minutes)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.addArrangedSubview(statCell(value: formattedUsageInteger(words),
                                          caption: t("слов сегодня", "words today")))
        stack.addArrangedSubview(statCell(value: wpm > 0 ? "\(wpm)" : "—",
                                          caption: t("WPM средний", "avg WPM")))
        stack.addArrangedSubview(statCell(value: savedMinutes >= 1
                                              ? "≈\(Int(savedMinutes.rounded())) \(t("мин", "min"))"
                                              : "—",
                                          caption: t("сэкономлено", "saved")))
        let bars = QuickPanelStatBars(values: state.weekBars)

        for view in [stack, bars] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 54),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bars.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 10),
            bars.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            bars.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bars.widthAnchor.constraint(equalToConstant: 40),
            bars.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    private func statCell(value: String, caption: String) -> NSView {
        // Макет: значение mono 600 15 ink, подпись 10 subtle.
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.addArrangedSubview(label(value, size: 15, weight: .semibold,
                                      color: SD.C.ink, mono: true))
        cell.addArrangedSubview(label(caption, size: 10, color: SD.C.subtle))
        return cell
    }

    private func footerRow() -> NSView {
        // Макет: padding 9px 16px, лёгкая подложка (.02 чёрного / .03 белого),
        // «Выйти» — 12/400 graphite.
        let row = QuickPanelFooterView()
        let settingsButton = NSButton(title: t("Настройки…", "Settings…"),
                                      target: self, action: #selector(settingsClicked))
        let historyButton = NSButton(title: t("История", "History"),
                                     target: self, action: #selector(historyClicked))
        let quitButton = NSButton(title: t("Выйти", "Quit"),
                                  target: self, action: #selector(quitClicked))
        for button in [settingsButton, historyButton] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = SD.C.ink
        }
        quitButton.isBordered = false
        quitButton.font = NSFont.systemFont(ofSize: 12)
        quitButton.contentTintColor = SD.C.graphite
        for button in [settingsButton, historyButton, quitButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            settingsButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            settingsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            historyButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 14),
            historyButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quitButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            quitButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    // MARK: - Действия

    @objc private func microphoneChanged(_ sender: NSPopUpButton) {
        let uid = (sender.selectedItem?.representedObject as? String) ?? ""
        quickDelegate?.quickPanelDidSelectInputDevice(uid: uid)
    }

    @objc private func copyRecentClicked(_ sender: NSButton) {
        guard let text = sender.cell?.representedObject as? String else { return }
        quickDelegate?.quickPanelDidCopyRecent(text: text)
    }

    @objc private func pasteRecentClicked(_ sender: NSButton) {
        guard let text = sender.cell?.representedObject as? String else { return }
        close()
        quickDelegate?.quickPanelDidPasteRecent(text: text)
    }

    @objc private func settingsClicked() {
        close()
        quickDelegate?.quickPanelOpenSettings()
    }

    @objc private func historyClicked() {
        close()
        quickDelegate?.quickPanelOpenHistory()
    }

    @objc private func quitClicked() {
        close()
        quickDelegate?.quickPanelQuit()
    }
}

private extension QuickPanelState {
    func microphoneUID(popupTitles: [NSMenuItem]) -> String {
        devices.first(where: { $0.name == microphoneName })?.uid ?? ""
    }
}

/// Оценка числа слов по символам: в хранилище статистики только
/// characterCount. 5.8 символа на слово — среднее для русского с
/// пробелами; для честности везде показывается как оценка.
func approximateWordCount(characters: Int) -> Int {
    max(0, Int((Double(characters) / 5.8).rounded()))
}

// MARK: - Живая мини-волна статуса

final class QuickPanelWaveView: NSView {
    var isActive = true
    var isHot = false
    private var timer: Timer?
    private var phase: CGFloat = 0

    func startAnimating() {
        stopAnimating()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            needsDisplay = true
            return
        }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.phase += 0.45
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let barCount = 6
        let barWidth: CGFloat = 1.5
        let gap: CGFloat = 1.5
        let color = isActive ? SD.C.voice : NSColor.tertiaryLabelColor
        color.setFill()
        for index in 0..<barCount {
            let i = CGFloat(index)
            let motion: CGFloat
            if isActive {
                let travel = (sin(phase - i * 0.9) + 1) / 2
                motion = (isHot ? 0.45 : 0.2) + (isHot ? 0.55 : 0.35) * travel
            } else {
                motion = 0.18
            }
            let height = max(2, motion * bounds.height)
            let rect = NSRect(x: CGFloat(index) * (barWidth + gap),
                              y: bounds.midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

// MARK: - Мини-бары недельной статистики

final class QuickPanelStatBars: NSView {
    private let values: [CGFloat]

    init(values: [CGFloat]) {
        self.values = values
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        SD.C.voice.withAlphaComponent(0.6).setFill()
        for (index, value) in values.enumerated() {
            let height = max(2, value * bounds.height)
            // Бары растут от нижней кромки (align-items:end в макете).
            let rect = NSRect(x: CGFloat(index) * (barWidth + gap),
                              y: 0,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// MARK: - Подложка футера поповера

final class QuickPanelFooterView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        (effectiveAppearance.isDark
            ? NSColor.white.withAlphaComponent(0.03)
            : NSColor.black.withAlphaComponent(0.02)).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Превью поповера (для визуальной сверки с макетом 1d/1e)

@MainActor
/// Язык — параметром, как у экспорта окна: витрина проекта двуязычная, и
/// английская страница с русской панелью выглядит как незаконченный перевод.
func exportQuickPanelPreviews(to directory: URL,
                              language: InterfaceLanguage = .russian) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var exported = 0
    // Строка обновления живёт в двух видах — «версия и кнопка проверки» и
    // «доступна новая версия». Снимаем оба: цветная строка появляется редко,
    // и увидеть её иначе можно только дождавшись релиза.
    for (base, appearanceName) in
        [("light", NSAppearance.Name.aqua),
         ("dark", NSAppearance.Name.darkAqua)] {
      for (variant, offered) in [("", String?.none), ("-update", .some("1.1.3"))] {
        let suffix = base + variant
        let now = Date()
        let state = QuickPanelState(
            enabled: true,
            language: .russian,
            microphoneName: language == .english
                ? "MacBook Pro (built-in)"
                : "MacBook Pro (встроенный)",
            devices: [],
            recent: (language == .english
                ? ["Hey! Sending a short recap of the call and the three next steps…",
                   "Let's talk Thursday at three, I'll send the invite",
                   "Headline: local dictation with no cloud — a look at Dictor"]
                : ["Привет! По итогам звонка присылаю короткое резюме и три следующих шага…",
                   "Давай созвонимся в четверг в три, я закину приглашение",
                   "Заголовок: локальная диктовка без облака — обзор Dictor"])
                .enumerated().map { index, text in
                    TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: [1.2, 0.9, 0.8][index],
                        createdAt: now.addingTimeInterval([-120, -9000, -17000][index]))
                },
            historyKeepingEnabled: true,
            todayCharacters: 7192,
            todayAudioSeconds: 810,
            weekBars: [0.3, 0.55, 0.4, 0.8, 0.65, 1.0, 0.5],
            interfaceLanguage: language,
            availableUpdateVersion: offered,
            // Своя версия, а не зашитая: на витрине она была вечной 1.1.2.
            // Снимать поповер поэтому нужно собранным приложением
            // (`dist/Dictor.app/Contents/MacOS/Dictor`), а не debug-бинарём:
            // у того нет бандла, и версия выйдет 0.0.0.
            installedVersion: currentBundleVersion(),
            isCheckingForUpdates: false,
            serviceStatus: .ready(latencyMilliseconds: 180)
        )
        let panel = DictorQuickPanel(state: state)
        panel.appearance = NSAppearance(named: appearanceName)
        panel.apply(state: state)
        guard let view = panel.contentView else {
            throw SettingsPreviewExportError(message: "no popover content view")
        }
        view.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for popover-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for popover-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("popover-\(suffix).png"),
                      options: .atomic)
        exported += 1
      }
    }
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("POPOVER_PREVIEW exported \(exported) files to \(directory.path)")
}

// MARK: - Строка с hover-действиями

final class QuickPanelHoverRow: NSView {
    var hoverViews: [NSView] = [] {
        didSet { hoverViews.forEach { $0.isHidden = true } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        hoverViews.forEach { $0.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        hoverViews.forEach { $0.isHidden = true }
    }
}
