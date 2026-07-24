import AppKit

// Поповер меню-бара по дизайну 1d/1e: статус + тумблер, язык пилюлями,
// микрофон, «Недавнее» (3 записи, hover-действия), статистика, футер.
// Открывается левым кликом по глифу; правый клик показывает старое
// NSMenu как сервисный fallback до завершения новой панели настроек.

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
}

struct QuickPanelState {
    var statusTitle: String
    var statusSubtitle: String
    var enabled: Bool
    var isRecording: Bool
    var language: DictationLanguage
    var microphoneName: String
    var devices: [AudioInputDevice]
    var recent: [TranscriptHistoryEntry]
    var todayCharacters: Int
    var todayAudioSeconds: Double
    var weekBars: [CGFloat]
    var interfaceLanguage: InterfaceLanguage
}

@MainActor
final class DictorQuickPanel: NSPanel {
    weak var quickDelegate: QuickPanelDelegate?
    private var state: QuickPanelState
    private let contentStack = NSStackView()
    private var waveView: QuickPanelWaveView?
    private var outsideClickMonitor: Any?

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
        for entry in state.recent.prefix(3) {
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
        stack.addArrangedSubview(footerRow())

        container.addSubview(stack)
        NSLayoutConstraint.activate([
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
        return field
    }

    // MARK: - Ряды

    private func headerRow() -> NSView {
        // Макет: padding 16px 16px 14px, заголовок 13/600 ink + волна,
        // подпись 11 graphite, коралловый тумблер 36×22.
        let row = NSView()
        let title = label(state.statusTitle, size: 13, weight: .semibold, color: SD.C.ink)
        let wave = QuickPanelWaveView()
        wave.isActive = state.enabled
        wave.isHot = state.isRecording
        waveView = wave
        let subtitle = label(state.statusSubtitle, size: 11, color: SD.C.graphite)
        let toggle = SDToggle()
        toggle.isOn = state.enabled
        toggle.onToggle = { [weak self] enabled in
            self?.quickDelegate?.quickPanelDidToggleEnabled(enabled)
        }

        for view in [title, wave, subtitle, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 62),
            toggle.widthAnchor.constraint(equalToConstant: 36),
            toggle.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 16),
            wave.leadingAnchor.constraint(equalTo: title.trailingAnchor, constant: 8),
            wave.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            wave.widthAnchor.constraint(equalToConstant: 26),
            wave.heightAnchor.constraint(equalToConstant: 10),
            subtitle.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -8),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            toggle.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func languageRow() -> NSView {
        // Макет: подпись 12 graphite шириной 72, пилюли как в настройках.
        let row = NSView()
        let caption = label(t("Язык", "Language"), size: 12, color: SD.C.graphite)

        var options: [(String, DictationLanguage)] = [
            ("RU", .russian),
            ("EN", .english),
            (t("Авто", "Auto"), .auto),
        ]
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
        let text = label(t("Пока тихо — первая диктовка появится здесь.",
                           "Quiet so far — your first dictation will show up here."),
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
func exportQuickPanelPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var exported = 0
    for (suffix, appearanceName, language) in
        [("light", NSAppearance.Name.aqua, InterfaceLanguage.russian),
         ("dark", NSAppearance.Name.darkAqua, InterfaceLanguage.russian)] {
        let now = Date()
        let state = QuickPanelState(
            statusTitle: language == .russian ? "Слушаю хоткей" : "Listening for hotkey",
            statusSubtitle: language == .russian
                ? "Всё распознаётся на этом Mac"
                : "Everything is transcribed on this Mac",
            enabled: true,
            isRecording: false,
            language: .russian,
            microphoneName: "MacBook Pro (встроенный)",
            devices: [],
            recent: [
                TranscriptHistoryEntry(
                    text: "Привет! По итогам звонка присылаю короткое резюме и три следующих шага…",
                    transcriptionDurationSeconds: 1.2,
                    createdAt: now.addingTimeInterval(-120)),
                TranscriptHistoryEntry(
                    text: "Давай созвонимся в четверг в три, я закину приглашение",
                    transcriptionDurationSeconds: 0.9,
                    createdAt: now.addingTimeInterval(-9000)),
                TranscriptHistoryEntry(
                    text: "Заголовок: локальная диктовка без облака — обзор Dictor",
                    transcriptionDurationSeconds: 0.8,
                    createdAt: now.addingTimeInterval(-17000)),
            ],
            todayCharacters: 7192,
            todayAudioSeconds: 810,
            weekBars: [0.3, 0.55, 0.4, 0.8, 0.65, 1.0, 0.5],
            interfaceLanguage: language
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
