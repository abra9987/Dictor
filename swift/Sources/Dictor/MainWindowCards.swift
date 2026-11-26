import AppKit

// MARK: - Карточка показателя

/// Карточка «Слов сегодня» / «Сэкономлено» / «Дней подряд».
/// Макет: белая, рамка rgba(0,0,0,.07), радиус 12, padding 16×18.
final class SDStatCardView: NSView {
    struct Delta {
        let text: String
        let isPositive: Bool
    }

    init(caption: String,
         value: String,
         unit: String? = nil,
         delta: Delta? = nil,
         footnote: String? = nil,
         accessory: NSView? = nil) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12

        let captionLabel = NSTextField(labelWithString: caption.uppercased())
        captionLabel.attributedStringValue = NSAttributedString(
            string: caption.uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: SD.C.subtle,
                .kern: 0.55,
            ])

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .systemFont(ofSize: 30, weight: .semibold)
        valueLabel.textColor = SD.C.ink

        let valueRow = NSStackView(views: [valueLabel])
        valueRow.orientation = .horizontal
        valueRow.alignment = .lastBaseline
        valueRow.spacing = unit == nil ? 8 : 4
        if let unit {
            let unitLabel = NSTextField(labelWithString: unit)
            unitLabel.font = .systemFont(ofSize: 14, weight: .medium)
            unitLabel.textColor = SD.C.graphite
            valueRow.addArrangedSubview(unitLabel)
        }
        if let delta {
            let deltaLabel = NSTextField(labelWithString: delta.text)
            deltaLabel.font = .systemFont(ofSize: 12, weight: .semibold)
            // Рост — зелёным, падение — приглушённым: «минус» зелёным
            // читается как успех.
            deltaLabel.textColor = delta.isPositive ? SD.C.positive : SD.C.subtle
            valueRow.addArrangedSubview(deltaLabel)
        }

        let column = NSStackView(views: [captionLabel, valueRow])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.setCustomSpacing(8, after: captionLabel)

        if let accessory {
            column.addArrangedSubview(accessory)
            column.setCustomSpacing(10, after: valueRow)
        } else if let footnote {
            let footnoteLabel = NSTextField(labelWithString: footnote)
            footnoteLabel.font = .systemFont(ofSize: 11.5)
            footnoteLabel.textColor = SD.C.subtle
            footnoteLabel.lineBreakMode = .byTruncatingTail
            column.addArrangedSubview(footnoteLabel)
            column.setCustomSpacing(10, after: valueRow)
        }

        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            column.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            column.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            column.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        layer?.backgroundColor = resolvedCGColor(SD.C.cardFill)
        layer?.borderWidth = 1
        layer?.borderColor = resolvedCGColor(SD.C.cardBorder)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// Полоска «дней подряд»: 7 квадратов 9×9, радиус 3, насыщенность растёт;
/// сегодняшний — сплошной коралл с кольцом (макет 6a).
final class SDStreakDotsView: NSView {
    private let intensities: [CGFloat]
    private let todayActive: Bool

    init(intensities: [CGFloat], todayActive: Bool) {
        self.intensities = intensities
        self.todayActive = todayActive
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(intensities.count) * 9 + CGFloat(max(0, intensities.count - 1)) * 5,
               height: 15)
    }

    override func draw(_ dirtyRect: NSRect) {
        let side: CGFloat = 9
        let gap: CGFloat = 5
        let midY = bounds.midY
        for (index, intensity) in intensities.enumerated() {
            let x = CGFloat(index) * (side + gap)
            let rect = NSRect(x: x, y: midY - side / 2, width: side, height: side)
            let isToday = index == intensities.count - 1
            if isToday && todayActive {
                SD.C.voice.withAlphaComponent(0.16).setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3),
                             xRadius: 6, yRadius: 6).fill()
                SD.C.voice.setFill()
            } else {
                SD.C.voice.withAlphaComponent(max(0.18, intensity)).setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Кнопка «Диктовать»

/// Коралловая кнопка в шапке раздела: высота 30, радиус 8,
/// подпись 12.5/600 + моно-хоткей rgba(255,255,255,.72).
final class SDPrimaryActionButton: NSControl {
    private let background = NSView()
    private let titleLabel: NSTextField
    private var revertWorkItem: DispatchWorkItem?

    init(title: String, shortcut: String?, target: AnyObject?, action: Selector) {
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        self.target = target
        self.action = action

        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = SD.C.onVoice

        let row = NSStackView(views: [titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        if let shortcut, !shortcut.isEmpty {
            let shortcutLabel = NSTextField(labelWithString: shortcut)
            shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            shortcutLabel.textColor = SD.C.onVoice.withAlphaComponent(0.72)
            row.addArrangedSubview(shortcutLabel)
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Кнопка, которая молча кладёт текст в буфер, читается как сломанная:
    /// буфер не видно. Подтверждение живёт на самой кнопке и возвращается
    /// к обычной надписи само — окно при этом не пересобирается, иначе
    /// подтверждение стёрло бы выделение в тексте рядом.
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
        background.layer?.backgroundColor = resolvedCGColor(SD.C.voice)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func mouseDown(with event: NSEvent) {
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

// MARK: - Кнопка-значок в строке списка

/// Квадрат 22×22 с символом внутри: рамка, как у прежнего бейджа
/// «Копировать», но места занимает столько, что рядом помещается вторая.
/// Значок без подписи молчит, поэтому tooltip здесь обязателен, а не «по
/// возможности».
final class SDRowIconButton: NSView {
    private let icon = NSImageView()
    private let symbolName: String
    private var revertWorkItem: DispatchWorkItem?
    private var isHovered = false {
        didSet { restyle() }
    }
    var onClick: (() -> Void)?

    init(symbolName: String, tooltip: String) {
        self.symbolName = symbolName
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        toolTip = tooltip
        setAccessibilityLabel(tooltip)

        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 12),
            icon.heightAnchor.constraint(equalToConstant: 12),
        ])
        showSymbol(symbolName)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    /// Ответ на нажатие: значок на секунду становится галочкой. Без этого
    /// копирование выглядит как ничего не произошедшее.
    func flashSymbol(_ name: String, revertingAfter seconds: TimeInterval = 1.2) {
        revertWorkItem?.cancel()
        showSymbol(name)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showSymbol(self.symbolName)
        }
        revertWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func showSymbol(_ name: String) {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: toolTip)
        icon.image = symbol?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        icon.contentTintColor = SD.C.ink
    }

    private func restyle() {
        layer?.borderColor = resolvedCGColor(
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(self.isHovered ? 0.34 : 0.18)
                    : NSColor.black.withAlphaComponent(self.isHovered ? 0.26 : 0.13)
            })
        layer?.backgroundColor = resolvedCGColor(
            isHovered
                ? NSColor(name: nil) { appearance in
                    appearance.isDark
                        ? NSColor.white.withAlphaComponent(0.08)
                        : NSColor.black.withAlphaComponent(0.05)
                }
                : .clear)
        icon.contentTintColor = SD.C.ink
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
    override func mouseDown(with event: NSEvent) { onClick?() }
}
