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
        let container = NSVisualEffectView()
        container.material = .popover
        container.state = .active
        container.blendingMode = .behindWindow
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true
        container.layer?.borderWidth = 0.5
        container.layer?.borderColor = NSColor.black.withAlphaComponent(0.15).cgColor

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
        for entry in state.recent.prefix(3) {
            stack.addArrangedSubview(recentRow(entry))
        }
        if state.recent.isEmpty {
            stack.addArrangedSubview(emptyRecentRow())
        }
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(statsRow())
        stack.addArrangedSubview(hairline())
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

    private func hairline() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -16),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
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
        let row = NSView()
        let title = label(state.statusTitle, size: 13, weight: .semibold)
        let wave = QuickPanelWaveView()
        wave.isActive = state.enabled
        wave.isHot = state.isRecording
        waveView = wave
        let subtitle = label(state.statusSubtitle, size: 11, color: .secondaryLabelColor)
        let toggle = NSSwitch()
        toggle.state = state.enabled ? .on : .off
        toggle.target = self
        toggle.action = #selector(toggleChanged(_:))

        for view in [title, wave, subtitle, toggle] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 58),
            title.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: row.topAnchor, constant: 14),
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
        let row = NSView()
        let caption = label(t("Язык", "Language"), size: 12, color: .secondaryLabelColor)
        let pills = NSStackView()
        pills.orientation = .horizontal
        pills.spacing = 4

        var options: [(String, DictationLanguage)] = [
            ("RU", .russian),
            ("EN", .english),
            (t("Авто", "Auto"), .auto),
        ]
        if !options.contains(where: { $0.1 == state.language }) {
            options.insert((state.language.rawValue.uppercased(), state.language), at: 0)
        }
        for (name, value) in options {
            pills.addArrangedSubview(pillButton(name,
                                                selected: state.language == value,
                                                action: #selector(languagePillClicked(_:)),
                                                represented: value.rawValue))
        }

        for view in [caption, pills] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 40),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 78),
            pills.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 6),
            pills.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func microphoneRow() -> NSView {
        let row = NSView()
        let caption = label(t("Микрофон", "Microphone"), size: 12, color: .secondaryLabelColor)
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
            row.heightAnchor.constraint(equalToConstant: 36),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 78),
            popup.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 2),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func recentHeader() -> NSView {
        let row = NSView()
        let caption = label(t("НЕДАВНЕЕ", "RECENT"), size: 11, weight: .semibold,
                            color: .tertiaryLabelColor)
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
        let row = QuickPanelHoverRow()
        let text = label(entry.text, size: 12)
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        var metaText = dictatedWordsLabel(words, language: state.interfaceLanguage)
        if let duration = entry.transcriptionDurationSeconds {
            metaText += " · \(String(format: "%.1f", duration)) c"
        }
        let meta = label(metaText, size: 10.5, color: .tertiaryLabelColor)

        let copyButton = NSButton(title: t("Скопировать", "Copy"),
                                  target: self, action: #selector(copyRecentClicked(_:)))
        let pasteButton = NSButton(title: t("Вставить", "Paste"),
                                   target: self, action: #selector(pasteRecentClicked(_:)))
        for button in [copyButton, pasteButton] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }
        copyButton.contentTintColor = .labelColor
        pasteButton.contentTintColor = SD.C.voice
        copyButton.cell?.representedObject = entry.text
        pasteButton.cell?.representedObject = entry.text
        row.hoverViews = [copyButton, pasteButton]

        for view in [text, meta, copyButton, pasteButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 46),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 6),
            meta.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            meta.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            pasteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
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
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.addArrangedSubview(label(value, size: 14, weight: .semibold, mono: true))
        cell.addArrangedSubview(label(caption, size: 10, color: .tertiaryLabelColor))
        return cell
    }

    private func footerRow() -> NSView {
        let row = NSView()
        let settingsButton = NSButton(title: t("Настройки…", "Settings…"),
                                      target: self, action: #selector(settingsClicked))
        let historyButton = NSButton(title: t("История", "History"),
                                     target: self, action: #selector(historyClicked))
        let quitButton = NSButton(title: t("Выйти", "Quit"),
                                  target: self, action: #selector(quitClicked))
        for button in [settingsButton, historyButton, quitButton] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = .labelColor
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
        }
        quitButton.contentTintColor = .secondaryLabelColor
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),
            settingsButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            settingsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            historyButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 14),
            historyButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quitButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            quitButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func pillButton(_ title: String, selected: Bool,
                            action: Selector, represented: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: selected ? .semibold : .medium)
        button.wantsLayer = true
        button.layer?.cornerRadius = 11
        if selected {
            button.layer?.backgroundColor = SD.C.ink.cgColor
            button.contentTintColor = SD.C.paper
        } else {
            button.contentTintColor = .secondaryLabelColor
        }
        button.cell?.representedObject = represented
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        return button
    }

    // MARK: - Действия

    @objc private func toggleChanged(_ sender: NSSwitch) {
        quickDelegate?.quickPanelDidToggleEnabled(sender.state == .on)
    }

    @objc private func languagePillClicked(_ sender: NSButton) {
        guard let raw = sender.cell?.representedObject as? String,
              let language = DictationLanguage(rawValue: raw) else { return }
        quickDelegate?.quickPanelDidSelectLanguage(language)
    }

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
        SD.C.voice.withAlphaComponent(0.55).setFill()
        for (index, value) in values.enumerated() {
            let height = max(2, value * bounds.height)
            let rect = NSRect(x: CGFloat(index) * (barWidth + gap),
                              y: bounds.height - height,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
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
