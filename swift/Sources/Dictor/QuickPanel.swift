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
    var state: QuickPanelState
    private let contentStack = NSStackView()
    private var waveView: QuickPanelWaveView?
    private var outsideClickMonitor: Any?
    /// Проверка, которая ничего не нашла, обязана это сказать. Иначе нажатие
    /// «Проверить» выглядит как нажатие в пустоту — а именно за этим человек
    /// и нажимал.
    var showsUpToDate = false
    var upToDateWorkItem: DispatchWorkItem?
    private var copyResetWorkItem: DispatchWorkItem?

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

    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: state.interfaceLanguage)
    }

    // MARK: - Сборка контента

    func rebuildContent() {
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

    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
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
        confirmCopy(on: sender)
    }

    /// Копирование — единственное действие панели, которое ничего не меняет
    /// на экране: окно остаётся открытым, текст уходит в буфер молча, и
    /// человеку неоткуда узнать, сработало ли. Кнопка отвечает за себя сама.
    private func confirmCopy(on button: NSButton) {
        copyResetWorkItem?.cancel()
        let originalTitle = t("Скопировать", "Copy")
        button.title = t("Скопировано", "Copied")
        button.contentTintColor = SD.C.positive
        let reset = DispatchWorkItem { [weak button] in
            guard let button else { return }
            button.title = originalTitle
            button.contentTintColor = SD.C.ink
        }
        copyResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
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
