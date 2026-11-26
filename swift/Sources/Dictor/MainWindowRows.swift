import AppKit

// MARK: - Строка «Последние диктовки»

/// Строка списка на «Сегодня»: цветной значок 22×22, текст в одну строку,
/// время и две кнопки-значка, которые проявляются по наведению (макет 6a):
/// скопировать и открыть запись целиком в «Истории». Двойной клик по строке
/// делает то же, что «открыть».
final class SDRecentEntryRowView: NSControl {
    let transcript: String
    /// Индекс в `settings.recentTranscriptEntries` — по нему «История»
    /// находит ту же запись. Образец рядом: `SDHistoryResultRow`.
    let entryIndex: Int
    private let actions = NSStackView()
    private let copyButton: SDRowIconButton
    private let openAction: Selector
    private var isHovered = false {
        didSet { updateHoverState() }
    }

    /// Показывать кнопки, не дожидаясь мыши. Нужно только экспорту превью:
    /// снимок делается без курсора, и иначе иконок на нём не увидеть.
    static var previewForcesActionsVisible = false

    init(transcript: String,
         entryIndex: Int,
         preview: String,
         time: String,
         copyTooltip: String,
         openTooltip: String,
         target: AnyObject?,
         copyAction: Selector,
         openAction: Selector) {
        self.transcript = transcript
        self.entryIndex = entryIndex
        self.openAction = openAction
        copyButton = SDRowIconButton(symbolName: "doc.on.doc", tooltip: copyTooltip)
        super.init(frame: .zero)
        self.target = target
        self.action = copyAction
        wantsLayer = true

        // В макете здесь иконка приложения, в котором диктовали. Источник
        // диктовки пока не сохраняется, поэтому значок нейтральный —
        // «линия голоса», а не выдуманный цвет чужого приложения.
        let badge = NSView()
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6
        badge.layer?.backgroundColor = resolvedCGColor(
            NSColor(name: nil) { appearance in
                (appearance.isDark ? NSColor(hex: 0xFF6B47) : NSColor(hex: 0xE8502F))
                    .withAlphaComponent(0.13)
            })
        badge.translatesAutoresizingMaskIntoConstraints = false
        let badgeWave = SDMiniWaveView(values: [0.35, 0.8, 0.5],
                                       color: SD.C.voice,
                                       barWidth: 1.5,
                                       gap: 1.5)
        badgeWave.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(badgeWave)
        NSLayoutConstraint.activate([
            badgeWave.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            badgeWave.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badgeWave.widthAnchor.constraint(equalToConstant: 7.5),
            badgeWave.heightAnchor.constraint(equalToConstant: 11),
        ])

        let text = NSTextField(labelWithString: preview)
        text.font = .systemFont(ofSize: 13)
        text.textColor = SD.C.ink
        text.lineBreakMode = .byTruncatingTail
        text.maximumNumberOfLines = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.translatesAutoresizingMaskIntoConstraints = false

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .systemFont(ofSize: 11.5)
        timeLabel.textColor = SD.C.subtle
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        timeLabel.translatesAutoresizingMaskIntoConstraints = false

        let openButton = SDRowIconButton(symbolName: "arrow.up.forward.square",
                                         tooltip: openTooltip)
        copyButton.onClick = { [weak self] in
            guard let self else { return }
            self.sendRowAction(copyAction)
            self.copyButton.flashSymbol("checkmark")
        }
        openButton.onClick = { [weak self] in self?.sendRowAction(openAction) }

        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 6
        actions.setViews([copyButton, openButton], in: .leading)
        actions.alphaValue = SDRecentEntryRowView.previewForcesActionsVisible ? 1 : 0
        actions.translatesAutoresizingMaskIntoConstraints = false

        for view in [badge, text, timeLabel, actions] {
            addSubview(view)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 48),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 14),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -14),
            timeLabel.trailingAnchor.constraint(equalTo: actions.leadingAnchor, constant: -14),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Кнопки шлют действие от имени строки, а не от своего: получателю
    /// нужен `SDRecentEntryRowView` — в нём и текст, и индекс записи.
    private func sendRowAction(_ selector: Selector) {
        guard let target else { return }
        NSApp.sendAction(selector, to: target, from: self)
    }

    private func restyle() {
        layer?.backgroundColor = resolvedCGColor(
            isHovered
                ? NSColor(name: nil) { appearance in
                    (appearance.isDark ? NSColor(hex: 0xFF6B47) : NSColor(hex: 0xE8502F))
                        .withAlphaComponent(0.045)
                }
                : .clear)
    }

    private func updateHoverState() {
        actions.alphaValue =
            (isHovered || SDRecentEntryRowView.previewForcesActionsVisible) ? 1 : 0
        restyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        // Двойной клик открывает запись целиком — то же, что кнопка со
        // стрелкой. Одиночный, как и прежде, копирует.
        if event.clickCount >= 2 {
            sendRowAction(openAction)
            return
        }
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

// MARK: - Кнопка второго плана

/// Кнопка с контуром в шапке детального просмотра (макет 6b):
/// высота 30, радиус 8, рамка rgba(0,0,0,.13).
final class SDSecondaryButton: NSControl {
    private let background = NSView()
    private let titleLabel: NSTextField
    private var revertWorkItem: DispatchWorkItem?
    private var isHovered = false {
        didSet { restyle() }
    }

    init(title: String, target: AnyObject?, action: Selector) {
        let label = NSTextField(labelWithString: title)
        titleLabel = label
        super.init(frame: .zero)
        self.target = target
        self.action = action

        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 1
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = SD.C.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    /// То же подтверждение на месте надписи, что и у главной кнопки, и по той
    /// же причине: результат нажатия — запись в словаре или строка в буфере —
    /// человеку не виден, а молчание читается как поломка. Окно при этом не
    /// пересобирается, иначе подтверждение стёрло бы выделение в тексте рядом.
    func flashTitle(_ text: String, revertingTo original: String,
                    after seconds: TimeInterval = 1.4) {
        revertWorkItem?.cancel()
        titleLabel.stringValue = text
        let revert = DispatchWorkItem { [weak self] in
            self?.titleLabel.stringValue = original
        }
        revertWorkItem = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: revert)
    }

    private func restyle() {
        background.layer?.borderColor = resolvedCGColor(
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.13)
            })
        background.layer?.backgroundColor = resolvedCGColor(
            isHovered
                ? NSColor(name: nil) { appearance in
                    appearance.isDark
                        ? NSColor.white.withAlphaComponent(0.06)
                        : NSColor.black.withAlphaComponent(0.04)
                }
                : .clear)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

// MARK: - Строка результата поиска (макет 6b)

/// Карточка в средней колонке «Истории»: значок, мета, две строки текста
/// с подсветкой совпадения. Выбранная — белая, с коралловым кольцом.
final class SDHistoryResultRow: NSControl {
    let entryIndex: Int
    private let isSelected: Bool
    private var isHovered = false {
        didSet { restyle() }
    }
    private let body = NSTextField(labelWithString: "")
    private var widthConstraint: NSLayoutConstraint?

    /// Ширина, в которую строка обязана уложиться. Таблица меряет высоту
    /// строки за один проход, а переносу текста для этого нужна ширина
    /// заранее: без неё текст считается одной длинной строкой, и строка
    /// выходит ниже и шире, чем должна.
    var layoutWidth: CGFloat = 0 {
        didSet {
            guard layoutWidth > 0 else { return }
            body.preferredMaxLayoutWidth = layoutWidth - 24
            if let widthConstraint {
                widthConstraint.constant = layoutWidth
            } else {
                widthConstraint = widthAnchor.constraint(equalToConstant: layoutWidth)
                widthConstraint?.isActive = true
            }
        }
    }

    init(entryIndex: Int,
         meta: String,
         time: String,
         text: String,
         highlight: String,
         isPinned: Bool,
         isSelected: Bool,
         target: AnyObject?,
         action: Selector) {
        self.entryIndex = entryIndex
        self.isSelected = isSelected
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 9

        let badge: NSView
        if isPinned {
            let pin = NSTextField(labelWithString: "⚑")
            pin.font = .systemFont(ofSize: 11)
            pin.textColor = SD.C.voice
            pin.alignment = .center
            badge = pin
        } else {
            badge = SDMiniWaveView(values: [0.35, 0.8, 0.5],
                                   color: SD.C.subtle,
                                   barWidth: 1.5,
                                   gap: 1.5)
        }
        badge.translatesAutoresizingMaskIntoConstraints = false

        let metaLabel = NSTextField(labelWithString: meta)
        metaLabel.font = .systemFont(ofSize: 11)
        metaLabel.textColor = SD.C.subtle
        metaLabel.lineBreakMode = .byTruncatingTail

        let timeLabel = NSTextField(labelWithString: time)
        timeLabel.font = .systemFont(ofSize: 11)
        timeLabel.textColor = SD.C.subtle
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let head = NSStackView(views: [badge, metaLabel, NSView(), timeLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8
        head.translatesAutoresizingMaskIntoConstraints = false

        body.attributedStringValue = SDHistoryResultRow.highlighted(
            text: text,
            query: highlight,
            color: isSelected ? SD.C.ink : SD.C.inkSecondary)
        body.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = 2
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(head)
        addSubview(body)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 15),
            badge.heightAnchor.constraint(equalToConstant: 12),
            head.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            head.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            head.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            body.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            body.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            body.topAnchor.constraint(equalTo: head.bottomAnchor, constant: 6),
            body.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Совпадение подсвечивается плашкой rgba(232,80,47,.18), как в макете.
    private static func highlighted(text: String,
                                    query: String,
                                    color: NSColor) -> NSAttributedString {
        let attributed = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12.5),
                .foregroundColor: color,
            ])
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }
        var searchRange = NSRange(location: 0, length: (text as NSString).length)
        while searchRange.length > 0 {
            let found = (text as NSString).range(of: trimmed,
                                                 options: [.caseInsensitive],
                                                 range: searchRange)
            guard found.location != NSNotFound else { break }
            attributed.addAttribute(.backgroundColor,
                                    value: SD.C.voice.withAlphaComponent(0.18),
                                    range: found)
            let next = found.location + found.length
            searchRange = NSRange(location: next,
                                  length: max(0, (text as NSString).length - next))
        }
        return attributed
    }

    private func restyle() {
        if isSelected {
            layer?.backgroundColor = resolvedCGColor(SD.C.cardFill)
            layer?.borderWidth = 1
            layer?.borderColor = resolvedCGColor(SD.C.voice.withAlphaComponent(0.28))
        } else {
            layer?.borderWidth = 0
            layer?.backgroundColor = resolvedCGColor(
                isHovered
                    ? NSColor(name: nil) { appearance in
                        appearance.isDark
                            ? NSColor.white.withAlphaComponent(0.05)
                            : NSColor.black.withAlphaComponent(0.04)
                    }
                    : .clear)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
