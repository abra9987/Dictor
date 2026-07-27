import AppKit

// Главное окно (макеты 6a/6b дизайн-проекта в Claude Design).
// Окно 980×664: слева сайдбар 212pt с навигацией и статусом службы,
// справа — раздел. «Сегодня» открывается первым.
//
// Тёмные пары поверхностей выведены (SDTheme.swift): тёрн 6 нарисован
// только в светлой теме, тёмная стоит следующей задачей в макете.

/// Макет 6a: окно 980×664, сайдбар 212, шапка раздела 52.
let MAIN_WINDOW_SIZE = NSSize(width: 980, height: 664)
let MAIN_WINDOW_SIDEBAR_WIDTH: CGFloat = 212
let MAIN_WINDOW_HEADER_HEIGHT: CGFloat = 52

enum MainWindowSection: String, CaseIterable {
    case today
    case history
    case dictionary
    case settings

    func title(_ language: InterfaceLanguage) -> String {
        switch self {
        case .today: return localizedText("Сегодня", "Today", language: language)
        case .history: return localizedText("История", "History", language: language)
        case .dictionary: return localizedText("Словарь", "Dictionary", language: language)
        case .settings: return localizedText("Настройки", "Settings", language: language)
        }
    }

    /// Иконка пункта. У «Сегодня» в макете вместо символа — волна.
    var glyph: String? {
        switch self {
        case .today: return nil
        case .history: return "≡"
        case .dictionary: return "Aa"
        case .settings: return "⚙"
        }
    }
}

// MARK: - Волна-иконка

/// Статичная мини-волна («линия голоса») для пунктов меню и плашек.
/// Макет: cmdWave — бары 1.5pt с зазором 1.5pt, высота 12.
final class SDMiniWaveView: NSView {
    private let values: [CGFloat]
    private let barWidth: CGFloat
    private let gap: CGFloat
    var color: NSColor {
        didSet { needsDisplay = true }
    }

    init(values: [CGFloat],
         color: NSColor,
         barWidth: CGFloat = 1.5,
         gap: CGFloat = 1.5) {
        self.values = values
        self.color = color
        self.barWidth = barWidth
        self.gap = gap
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(values.count) * barWidth + CGFloat(values.count - 1) * gap,
               height: NSView.noIntrinsicMetric)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        color.setFill()
        let midY = bounds.midY
        for (index, value) in values.enumerated() {
            let height = max(barWidth, value * bounds.height)
            let rect = NSRect(x: CGFloat(index) * (barWidth + gap),
                              y: midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect,
                         xRadius: barWidth / 2,
                         yRadius: barWidth / 2).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Сайдбар

/// Пункт навигации. Макет: padding 9×12, радиус 9, иконка 18 + зазор 11,
/// текст 13.5 (выбранный — 600), справа счётчик 11.5.
final class SDSidebarItemView: NSControl {
    let section: MainWindowSection
    private let isSelected: Bool
    private let background = NSView()

    init(section: MainWindowSection,
         title: String,
         count: Int?,
         isSelected: Bool,
         target: AnyObject?,
         action: Selector) {
        self.section = section
        self.isSelected = isSelected
        super.init(frame: .zero)
        self.target = target
        self.action = action

        background.wantsLayer = true
        background.layer?.cornerRadius = 9
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let icon: NSView
        if let glyph = section.glyph {
            let label = NSTextField(labelWithString: glyph)
            label.font = .systemFont(ofSize: 13)
            label.textColor = isSelected ? SD.C.ink : SD.C.graphite
            label.alignment = .center
            icon = label
        } else {
            let wave = SDMiniWaveView(values: [0.3, 0.7, 1, 0.5, 0.8],
                                      color: SD.C.voice)
            icon = wave
        }
        icon.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13.5,
                                      weight: isSelected ? .semibold : .regular)
        titleLabel.textColor = isSelected ? SD.C.ink : SD.C.inkSecondary
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 34),
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 11),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        if let count, count > 0 {
            let countLabel = NSTextField(labelWithString: formattedUsageInteger(count))
            countLabel.font = .systemFont(ofSize: 11.5)
            countLabel.textColor = isSelected ? SD.C.graphite : SD.C.subtle
            countLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(countLabel)
            NSLayoutConstraint.activate([
                countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                countLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor,
                                                    constant: 8),
            ])
        }
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private var isHovered = false {
        didSet { restyle() }
    }

    private func restyle() {
        let fill: NSColor
        if isSelected {
            fill = SD.C.sidebarSelection
        } else if isHovered {
            fill = NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.05)
            }
        } else {
            fill = .clear
        }
        background.layer?.backgroundColor = resolvedCGColor(fill)
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

// MARK: - Мелкие поверхности

/// Точка состояния службы в подвале сайдбара (7pt, макет 6a).
final class SDStatusDotView: NSView {
    var color: NSColor = SD.C.positive {
        didSet { needsDisplay = true }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: 0, y: bounds.midY - 3.5, width: 7, height: 7)).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Белая карточка-контейнер: радиус 12, рамка rgba(0,0,0,.07).
final class SDCardBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        restyle()
    }

    convenience init() {
        self.init(frame: .zero)
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

/// Пилюля-пометка источника слова в словаре (макет 5d).
final class SDBadgeLabel: NSView {
    init(text: String, accent: Bool = false) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 7

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = accent ? SD.C.voice : SD.C.graphite
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.accent = accent
        restyle()
    }

    private var accent = false

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        let fill = NSColor(name: nil) { [accent] appearance in
            if accent {
                return (appearance.isDark ? NSColor(hex: 0xFF6B47) : NSColor(hex: 0xE8502F))
                    .withAlphaComponent(0.12)
            }
            return appearance.isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.06)
        }
        layer?.backgroundColor = resolvedCGColor(fill)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

// MARK: - Карточка показателя

/// Карточка «Слов сегодня» / «Сэкономлено» / «Дней подряд».
/// Макет: белая, рамка rgba(0,0,0,.07), радиус 12, padding 16×18.
final class SDStatCardView: NSView {
    private let border = CAShapeLayer()

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

    init(title: String, shortcut: String?, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action

        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .white

        let row = NSStackView(views: [titleLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        if let shortcut, !shortcut.isEmpty {
            let shortcutLabel = NSTextField(labelWithString: shortcut)
            shortcutLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            shortcutLabel.textColor = NSColor.white.withAlphaComponent(0.72)
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

// MARK: - Строка «Последние диктовки»

/// Строка списка на «Сегодня»: цветной значок 22×22, текст в одну строку,
/// время и кнопка «Копировать», которая проявляется по наведению (макет 6a).
final class SDRecentEntryRowView: NSControl {
    let transcript: String
    private let copyBadge = NSView()
    private var isHovered = false {
        didSet { updateHoverState() }
    }

    init(transcript: String,
         preview: String,
         time: String,
         copyTitle: String,
         target: AnyObject?,
         action: Selector) {
        self.transcript = transcript
        super.init(frame: .zero)
        self.target = target
        self.action = action
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

        let copyLabel = NSTextField(labelWithString: copyTitle)
        copyLabel.font = .systemFont(ofSize: 11.5, weight: .semibold)
        copyLabel.textColor = SD.C.ink
        copyLabel.translatesAutoresizingMaskIntoConstraints = false
        copyBadge.wantsLayer = true
        copyBadge.layer?.cornerRadius = 6
        copyBadge.layer?.borderWidth = 1
        copyBadge.alphaValue = 0
        copyBadge.translatesAutoresizingMaskIntoConstraints = false
        copyBadge.addSubview(copyLabel)

        for view in [badge, text, timeLabel, copyBadge] {
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
            timeLabel.trailingAnchor.constraint(equalTo: copyBadge.leadingAnchor, constant: -14),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyBadge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            copyBadge.centerYAnchor.constraint(equalTo: centerYAnchor),
            copyBadge.heightAnchor.constraint(equalToConstant: 22),
            copyLabel.leadingAnchor.constraint(equalTo: copyBadge.leadingAnchor, constant: 11),
            copyLabel.trailingAnchor.constraint(equalTo: copyBadge.trailingAnchor, constant: -11),
            copyLabel.centerYAnchor.constraint(equalTo: copyBadge.centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        layer?.backgroundColor = resolvedCGColor(
            isHovered
                ? NSColor(name: nil) { appearance in
                    (appearance.isDark ? NSColor(hex: 0xFF6B47) : NSColor(hex: 0xE8502F))
                        .withAlphaComponent(0.045)
                }
                : .clear)
        copyBadge.layer?.borderColor = resolvedCGColor(
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.18)
                    : NSColor.black.withAlphaComponent(0.13)
            })
    }

    private func updateHoverState() {
        copyBadge.alphaValue = isHovered ? 1 : 0
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
        guard let action, let target else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}

// MARK: - Кнопка второго плана

/// Кнопка с контуром в шапке детального просмотра (макет 6b):
/// высота 30, радиус 8, рамка rgba(0,0,0,.13).
final class SDSecondaryButton: NSControl {
    private let background = NSView()
    private var isHovered = false {
        didSet { restyle() }
    }

    init(title: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        self.target = target
        self.action = action

        background.wantsLayer = true
        background.layer?.cornerRadius = 8
        background.layer?.borderWidth = 1
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let label = NSTextField(labelWithString: title)
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

        let body = NSTextField(labelWithString: "")
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

// MARK: - Плашка подсказки

/// Одна подсказка внизу «Сегодня». Правило из макета 6e: одна на экране,
/// закрыли — больше не возвращается.
final class SDHintBannerView: NSView {
    init(text: String,
         actionTitle: String?,
         target: AnyObject?,
         action: Selector?,
         dismissAction: Selector?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12

        let wave = SDMiniWaveView(values: [0.09, 0.09, 0.09, 0.3, 0.09, 0.09, 0.09],
                                  color: SD.C.subtle,
                                  barWidth: 2,
                                  gap: 2)
        wave.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = SD.C.inkSecondary
        label.isSelectable = false
        label.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [wave, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 13
        row.translatesAutoresizingMaskIntoConstraints = false

        if let actionTitle, let action {
            let button = NSButton(title: actionTitle, target: target, action: action)
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.contentTintColor = SD.C.voice
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }
        if let dismissAction {
            let close = NSButton(title: "×", target: target, action: dismissAction)
            close.isBordered = false
            close.font = .systemFont(ofSize: 14)
            close.contentTintColor = SD.C.subtle
            close.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(close)
        }

        addSubview(row)
        NSLayoutConstraint.activate([
            wave.widthAnchor.constraint(equalToConstant: 26),
            wave.heightAnchor.constraint(equalToConstant: 14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -13),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        layer?.backgroundColor = resolvedCGColor(SD.C.hintPaper)
        layer?.borderWidth = 1
        layer?.borderColor = resolvedCGColor(
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.06)
                    : NSColor.black.withAlphaComponent(0.05)
            })
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

// MARK: - Сводка «Сегодня»

/// Числа для экрана «Сегодня», посчитанные из локальной статистики.
struct TodaySummary {
    let words: Int
    let deltaPercent: Int?
    let dayBars: [CGFloat]
    let savedMinutesToday: Int
    let savedHoursMonth: Double
    let streakDays: Int
    let streakIntensities: [CGFloat]
    let todayActive: Bool

    static func make(usage: [DailyDictationUsage],
                     calendar: Calendar = .current,
                     now: Date = Date()) -> TodaySummary {
        func characters(daysAgo: Int) -> Int {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return 0 }
            let key = dictationUsageDayKey(for: day, calendar: calendar)
            return usage.first(where: { $0.day == key })?.characterCount ?? 0
        }
        func audioSeconds(daysAgo: Int) -> Double {
            guard let day = calendar.date(byAdding: .day, value: -daysAgo, to: now) else { return 0 }
            let key = dictationUsageDayKey(for: day, calendar: calendar)
            return usage.first(where: { $0.day == key })?.audioSeconds ?? 0
        }

        let todayCharacters = characters(daysAgo: 0)
        let words = approximateWordCount(characters: todayCharacters)
        let yesterdayWords = approximateWordCount(characters: characters(daysAgo: 1))
        let delta: Int?
        if yesterdayWords > 0 {
            delta = Int((Double(words - yesterdayWords) / Double(yesterdayWords) * 100).rounded())
        } else {
            delta = nil
        }

        // Спарклайн: последние 7 дней, самый свежий — справа (макет: 7 баров).
        let weekCharacters = (0..<7).map { characters(daysAgo: 6 - $0) }
        let peak = max(1, weekCharacters.max() ?? 1)
        let dayBars = weekCharacters.map { CGFloat($0) / CGFloat(peak) }

        // «Сэкономлено» считаем как в поповере: 40 слов/мин на клавиатуре
        // минус реально потраченное время речи.
        let savedToday = max(0, Double(words) / 40 - audioSeconds(daysAgo: 0) / 60)
        var monthWords = 0
        var monthAudio: Double = 0
        for offset in 0..<30 {
            monthWords += approximateWordCount(characters: characters(daysAgo: offset))
            monthAudio += audioSeconds(daysAgo: offset)
        }
        let savedMonth = max(0, Double(monthWords) / 40 - monthAudio / 60)

        // Стрик: подряд идущие дни с диктовками, считая от сегодня (или,
        // если сегодня ещё молчали, от вчера — день не должен «обнуляться»
        // до первой диктовки).
        let todayActive = todayCharacters > 0
        var streak = 0
        var cursor = todayActive ? 0 : 1
        while characters(daysAgo: cursor) > 0 && cursor < 400 {
            streak += 1
            cursor += 1
        }
        let streakIntensities = (0..<7).map { index -> CGFloat in
            let value = characters(daysAgo: 6 - index)
            guard value > 0 else { return 0 }
            return 0.3 + 0.7 * CGFloat(value) / CGFloat(peak)
        }

        return TodaySummary(words: words,
                            deltaPercent: delta,
                            dayBars: dayBars,
                            savedMinutesToday: Int(savedToday.rounded()),
                            savedHoursMonth: savedMonth / 60,
                            streakDays: streak,
                            streakIntensities: streakIntensities,
                            todayActive: todayActive)
    }
}
