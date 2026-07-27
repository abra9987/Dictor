import AppKit

// Контролы окна настроек — построены с нуля по макету 2c/4b
// («Настройки Dictor», тёмная/светлая бумага). Никаких системных
// NSPopUpButton/NSSwitch: пилюли, тумблер и кейкапы рисуются сами,
// чтобы совпадать с дизайном в обеих темах.

// MARK: - Строка настройки (title + subtitle слева, контрол справа)

final class SDRowView: NSView {
    private let hairline: Bool

    // Макет: padding 13px 0, разделитель rgba .06/.07 снизу,
    // заголовок 13px ink, подпись 11px subtle с отступом 1px.
    init(title: String,
         subtitle: String? = nil,
         control: NSView,
         hairline: Bool = true,
         verticalPadding: CGFloat = 13) {
        self.hairline = hairline
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13)
        titleLabel.textColor = SD.C.ink

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleLabel)
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: 11)
            subtitleLabel.textColor = SD.C.subtle
            textStack.addArrangedSubview(subtitleLabel)
        }

        for view in [textStack, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Высота строки = 2×padding + самый высокий элемент; без
        // low-priority «сжатия» неравенства дают неоднозначную высоту,
        // и стек растягивает строку произвольно.
        let squeeze = heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow
        NSLayoutConstraint.activate([
            squeeze,
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor,
                                           constant: verticalPadding),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor,
                                         constant: verticalPadding),
            bottomAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor,
                                    constant: verticalPadding),
            bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor,
                                    constant: verticalPadding),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard hairline else { return }
        SD.C.rowHairline.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }
}

/// Кнопка-таб окна настроек. Активная — пилюля rgba(0,0,0,.08) /
/// rgba(255,255,255,.1), текст ink 600; неактивная — graphite 400.
/// Restyle на смене темы, иначе слой остаётся с цветом старой appearance.
final class SDTabButton: NSButton {
    var isActiveTab = false {
        didSet { restyle() }
    }

    static let activeFill = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor.white.withAlphaComponent(0.1)
            : NSColor.black.withAlphaComponent(0.08)
    }

    func restyle() {
        wantsLayer = true
        layer?.cornerRadius = 7
        font = .systemFont(ofSize: 12, weight: isActiveTab ? .semibold : .regular)
        if isActiveTab {
            layer?.backgroundColor = resolvedCGColor(SDTabButton.activeFill)
            contentTintColor = SD.C.ink
        } else {
            layer?.backgroundColor = .clear
            contentTintColor = SD.C.graphite
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// Заливная коралловая кнопка действия (primary в языке дизайна).
final class SDSolidButton: NSButton {
    override var isEnabled: Bool {
        didSet { restyle() }
    }

    func restyle() {
        wantsLayer = true
        layer?.cornerRadius = 8
        font = .systemFont(ofSize: 12, weight: .semibold)
        layer?.backgroundColor = resolvedCGColor(SD.C.voice)
        contentTintColor = NSColor.white
        alphaValue = isEnabled ? 1 : 0.4
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// Однопиксельная линия цвета hairline (граница под табами).
final class SDHairlineView: NSView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        SD.C.hairline.setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Коралловый тумблер 36×22 (как в макете)

final class SDToggle: NSControl {
    var isOn = false {
        didSet { needsDisplay = true }
    }
    var onToggle: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let track = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        if isOn {
            SD.C.voice.setFill()
        } else {
            // Макет: off-трек rgba(0,0,0,.14) / rgba(255,255,255,.16).
            (dark ? NSColor.white.withAlphaComponent(0.16)
                  : NSColor.black.withAlphaComponent(0.14)).setFill()
        }
        track.fill()
        let knobX = isOn ? bounds.maxX - 20 : bounds.minX + 2
        let knob = NSRect(x: knobX, y: bounds.minY + 2, width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(dark ? 0.3 : 0.2)
        shadow.set()
        NSColor.white.setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        isOn.toggle()
        onToggle?(isOn)
    }
}

// MARK: - Пилюли-сегменты (RU / EN / Авто, Ничего / Нажать Enter…)

final class SDPills: NSView {
    struct Option {
        let title: String
        let value: String
    }

    private let options: [Option]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?
    private var buttons: [NSButton] = []

    init(options: [Option], selected: String) {
        self.options = options
        self.selectedValue = selected
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Макет: padding 4px 12px, радиус 999, шрифт 12 (выбранная — 600).
        for option in options {
            let button = NSButton(title: option.title, target: self,
                                  action: #selector(pillClicked(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 11.5
            button.identifier = NSUserInterfaceItemIdentifier(option.value)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 23).isActive = true
            let textWidth = ceil(option.title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]).width)
            button.widthAnchor.constraint(equalToConstant: textWidth + 24).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        for button in buttons {
            let selected = button.identifier?.rawValue == selectedValue
            button.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            if selected {
                button.layer?.backgroundColor = resolvedCGColor(SD.C.pillSelectedFill)
                button.contentTintColor = SD.C.pillSelectedText
            } else {
                button.layer?.backgroundColor = .clear
                button.contentTintColor = SD.C.graphite
            }
        }
    }

    @objc private func pillClicked(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        selectedValue = value
        restyle()
        onSelect?(value)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

// MARK: - Кейкап хоткея (белая «клавиша» с тенью)

final class SDKeycaps: NSView {
    init(keys: [String]) {
        super.init(frame: .zero)
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        // Макет: mono 600 12px, padding 5px 9px, радиус 7.
        for key in keys {
            let cap = NSTextField(labelWithString: key)
            cap.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            cap.textColor = SD.C.ink
            cap.alignment = .center
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 7
            cap.layer?.borderWidth = 1
            cap.translatesAutoresizingMaskIntoConstraints = false
            cap.heightAnchor.constraint(equalToConstant: 25).isActive = true
            let textWidth = ceil(key.size(withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
            ]).width)
            cap.widthAnchor.constraint(equalToConstant: max(25, textWidth + 18)).isActive = true
            capViews.append(cap)
            stack.addArrangedSubview(cap)
        }
        restyle()
    }

    private var capViews: [NSTextField] = []

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        let dark = effectiveAppearance.isDark
        for cap in capViews {
            cap.layer?.backgroundColor = dark
                ? NSColor.white.withAlphaComponent(0.09).cgColor
                : NSColor.white.cgColor
            cap.layer?.borderColor = dark
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.black.withAlphaComponent(0.12).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// Раскладывает HotkeyChoice в подписи кейкапов: модификаторы
/// символами + имя клавиши («⌘ прав.», «⇧⌘», «L»).
func keycapLabels(for choice: HotkeyChoice, language: InterfaceLanguage) -> [String] {
    var labels: [String] = []
    let flags = choice.requiredModifiers
    if flags.contains(.maskControl) { labels.append("⌃") }
    if flags.contains(.maskAlternate) { labels.append("⌥") }
    if flags.contains(.maskShift) { labels.append("⇧") }
    if flags.contains(.maskCommand) { labels.append("⌘") }
    if choice.isModifier {
        let side: String
        // Not choice.name — that is the whole chord ("Command + Right
        // Option"), and scanning it for a modifier word finds the
        // *required* modifier before the key itself, so «Command +
        // правый Option» drew itself as «⌘ прав.». The keycode names
        // exactly one physical key, so ask it rather than parse prose.
        let lower = (MODIFIER_HOTKEY_CHOICES.first { $0.keycode == choice.keycode }?.name
            ?? choice.name.components(separatedBy: " + ").last
            ?? choice.name).lowercased()
        if lower.contains("right") {
            side = language == .russian ? " прав." : " R"
        } else if lower.contains("left") {
            side = language == .russian ? " лев." : " L"
        } else {
            side = ""
        }
        let symbol: String
        if lower.contains("command") { symbol = "⌘" }
        else if lower.contains("option") { symbol = "⌥" }
        else if lower.contains("shift") { symbol = "⇧" }
        else if lower.contains("control") { symbol = "⌃" }
        else { symbol = choice.name }
        labels.append(symbol + side)
    } else {
        labels.append(hotkeyKeyName(for: choice.keycode))
    }
    return labels
}

// MARK: - Mono-степпер («120 ms»)

final class SDStepperRow: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private var value: Int
    private let step: Int
    private let range: ClosedRange<Int>
    private let suffix: String
    var onChange: ((Int) -> Void)?

    init(value: Int, step: Int, range: ClosedRange<Int>, suffix: String) {
        self.value = value
        self.step = step
        self.range = range
        self.suffix = suffix
        super.init(frame: .zero)
        valueLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        valueLabel.textColor = SD.C.ink
        let arrows = SDStepperArrows()
        arrows.onStep = { [weak self] delta in
            guard let self else { return }
            let next = max(self.range.lowerBound,
                           min(self.range.upperBound, self.value + delta * self.step))
            guard next != self.value else { return }
            self.value = next
            self.refreshLabel()
            self.onChange?(next)
        }
        refreshLabel()
        let stack = NSStackView(views: [valueLabel, arrows])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func refreshLabel() {
        valueLabel.stringValue = "\(value) \(suffix)"
    }
}

/// Пара крошечных кнопок ▲▼ 18×11 из макета — вместо системного NSStepper.
final class SDStepperArrows: NSView {
    var onStep: ((Int) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 23) }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let fill = dark ? NSColor.white.withAlphaComponent(0.09)
                        : NSColor.black.withAlphaComponent(0.07)
        let up = NSRect(x: 0, y: bounds.midY + 0.5, width: 18, height: 11)
        let down = NSRect(x: 0, y: bounds.midY - 11.5, width: 18, height: 11)
        fill.setFill()
        NSBezierPath(roundedRect: up, xRadius: 3, yRadius: 3).fill()
        NSBezierPath(roundedRect: down, xRadius: 3, yRadius: 3).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 7),
            .foregroundColor: SD.C.graphite,
        ]
        for (glyph, rect) in [("▲", up), ("▼", down)] {
            let size = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: rect.midX - size.width / 2,
                                   y: rect.midY - size.height / 2),
                       withAttributes: attrs)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onStep?(point.y >= bounds.midY ? 1 : -1)
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Кнопка-«поле» (микрофон и прочие выпадающие значения)

final class SDFieldButton: NSView {
    private let button: NSPopUpButton

    init(popup: NSPopUpButton) {
        self.button = popup
        super.init(frame: .zero)
        // Макет: font 12, padding 5px 10px, радиус 7,
        // фон rgba(0,0,0,.05) / rgba(255,255,255,.07).
        wantsLayer = true
        layer?.cornerRadius = 7
        popup.isBordered = false
        popup.font = .systemFont(ofSize: 12)
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 27),
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        layer?.backgroundColor = effectiveAppearance.isDark
            ? NSColor.white.withAlphaComponent(0.07).cgColor
            : NSColor.black.withAlphaComponent(0.05).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

// MARK: - Общие куски окна истории (макет 2b/4a)
// Используются и главным окном панели, и оверлеем агента.

/// «15:42 · 34 слова · 1,2 с» — мета строки истории.
func historyEntryMetaText(_ entry: TranscriptHistoryEntry,
                          language: InterfaceLanguage) -> String {
    var parts: [String] = []
    if let createdAt = entry.createdAt {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        parts.append(formatter.string(from: createdAt))
    }
    let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
    parts.append(dictatedWordsLabel(words, language: language))
    if let duration = entry.transcriptionDurationSeconds {
        parts.append(String(format: "%.1f %@", duration,
                            localizedText("с", "s", language: language)))
    }
    return parts.joined(separator: " · ")
}

/// Заголовок группы по дню: Сегодня / Вчера / «21 июля» / Ранее.
func historyDayHeaderText(for date: Date?, language: InterfaceLanguage) -> String {
    guard let date else { return localizedText("Ранее", "Earlier", language: language) }
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return localizedText("Сегодня", "Today", language: language) }
    if calendar.isDateInYesterday(date) { return localizedText("Вчера", "Yesterday", language: language) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
    formatter.dateFormat = "d MMMM"
    return formatter.string(from: date)
}

/// Документ скролла с системой координат сверху вниз — иначе короткий
/// список прижимается к нижней кромке NSScrollView.
final class SDFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Капс-заголовок секции («СЕГОДНЯ»), 11/600 с трекингом .05em.
@MainActor
func historySectionLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.attributedStringValue = NSAttributedString(
        string: text.uppercased(),
        attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: SD.C.subtle,
            .kern: 0.55,
        ])
    return label
}

/// Статистика за 30 дней в шапке истории: слова, WPM, экономия, бары
/// по дням (макет 2b: mono 17/600 + подписи 10.5 + бары справа).
@MainActor
func historyMonthStatsRowView(usage: [DailyDictationUsage],
                              language: InterfaceLanguage) -> NSView {
    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }
    let calendar = Calendar.current
    let now = Date()
    var characters = 0
    var audioSeconds: Double = 0
    var dayCharacters: [Int] = []
    for offset in stride(from: 29, through: 0, by: -1) {
        guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
        let key = dictationUsageDayKey(for: day, calendar: calendar)
        let entry = usage.first(where: { $0.day == key })
        characters += entry?.characterCount ?? 0
        audioSeconds += entry?.audioSeconds ?? 0
        dayCharacters.append(entry?.characterCount ?? 0)
    }
    let words = approximateWordCount(characters: characters)
    let minutes = audioSeconds / 60
    let wpm = minutes > 0.05 ? Int((Double(words) / minutes).rounded()) : 0
    let savedMinutes = max(0, Double(words) / 40 - minutes)
    let savedText: String
    if savedMinutes >= 90 {
        savedText = "≈" + String(format: "%.1f", savedMinutes / 60)
            .replacingOccurrences(of: ".", with: ",") + " " + t("ч", "h")
    } else if savedMinutes >= 1 {
        savedText = "≈\(Int(savedMinutes.rounded())) " + t("мин", "min")
    } else {
        savedText = "—"
    }

    func cell(_ value: String, _ caption: String) -> NSView {
        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        valueLabel.textColor = SD.C.ink
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 10.5)
        captionLabel.textColor = SD.C.subtle
        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    let cells = NSStackView(views: [
        cell(formattedUsageInteger(words), t("слов за месяц", "words this month")),
        cell(wpm > 0 ? "\(wpm)" : "—", t("WPM средний", "avg WPM")),
        cell(savedText, t("сэкономлено", "saved")),
    ])
    cells.orientation = .horizontal
    cells.distribution = .fillEqually
    cells.spacing = 8

    let maxCharacters = max(1, dayCharacters.max() ?? 1)
    let bars = QuickPanelStatBars(values: dayCharacters.suffix(14).map {
        CGFloat($0) / CGFloat(maxCharacters)
    })
    bars.translatesAutoresizingMaskIntoConstraints = false
    bars.widthAnchor.constraint(equalToConstant: 14 * 5 - 2).isActive = true
    bars.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let row = NSStackView(views: [cells, bars])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.edgeInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)
    cells.widthAnchor.constraint(equalTo: row.widthAnchor, constant: -120).isActive = true
    return row
}

// MARK: - Свотчи цвета волны (кружки 22px, выбранный — с кольцом)

final class SDColorSwatches: NSControl {
    struct Swatch {
        let value: String
        let color: NSColor
    }

    private let swatches: [Swatch]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?

    private let diameter: CGFloat = 22
    private let gap: CGFloat = 6

    init(swatches: [Swatch], selected: String) {
        self.swatches = swatches
        self.selectedValue = selected
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(swatches.count) * diameter
                   + CGFloat(max(0, swatches.count - 1)) * gap,
               height: diameter + 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Макет: выбранный кружок — box-shadow 0 0 0 2px «бумага»,
        // 0 0 0 3.5px цвет (кольцо с просветом).
        for (index, swatch) in swatches.enumerated() {
            let rect = circleRect(index)
            if swatch.value == selectedValue {
                swatch.color.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -3.5, dy: -3.5)).fill()
                SD.C.settingsPaper.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: -2, dy: -2)).fill()
            }
            swatch.color.setFill()
            NSBezierPath(ovalIn: rect).fill()
            // Светлые цвета (белый) без канта сливаются с бумагой.
            SD.C.ink.withAlphaComponent(0.12).setStroke()
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            ring.lineWidth = 1
            ring.stroke()
        }
    }

    private func circleRect(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * (diameter + gap),
               y: (bounds.height - diameter) / 2,
               width: diameter,
               height: diameter)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        for (index, swatch) in swatches.enumerated()
        where circleRect(index).insetBy(dx: -3, dy: -3).contains(point) {
            selectedValue = swatch.value
            needsDisplay = true
            onSelect?(swatch.value)
            return
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Карточки размера капсулы (три превью в ряд)

final class SDCapsuleSizeCard: NSControl {
    private let title: String
    private let kind: String
    private(set) var isSelected: Bool
    var onSelect: ((String) -> Void)?

    init(title: String, kind: String, selected: Bool) {
        self.title = title
        self.kind = kind
        self.isSelected = selected
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 78).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    func setSelected(_ selected: Bool) {
        isSelected = selected
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        // Карточка: radius 9, фон #fff / rgba(255,255,255,.05),
        // кольцо 1px rgba(0,0,0,.08)|rgba(255,255,255,.1), у выбранной 1.5px акцент.
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1),
                                xRadius: 9, yRadius: 9)
        (dark ? NSColor.white.withAlphaComponent(0.05) : NSColor.white).setFill()
        card.fill()
        if isSelected {
            SD.C.voice.setStroke()
            card.lineWidth = 1.5
        } else {
            (dark ? NSColor.white.withAlphaComponent(0.1)
                  : NSColor.black.withAlphaComponent(0.08)).setStroke()
            card.lineWidth = 1
        }
        card.stroke()

        // Мини-превью капсулы: чёрная пилюля с коралловым баром.
        let capsuleHeight: CGFloat = kind == "compact" ? 14 : 18
        let capsuleWidth: CGFloat = kind == "compact" ? 30 : (kind == "standard" ? 44 : 54)
        let capsuleRect = NSRect(x: bounds.midX - capsuleWidth / 2,
                                 y: bounds.midY + 2,
                                 width: capsuleWidth,
                                 height: kind == "large" ? 24 : capsuleHeight)
        (dark ? NSColor(hex: 0x111111) : NSColor(hex: 0x1C1B19)).setFill()
        NSBezierPath(roundedRect: capsuleRect,
                     xRadius: kind == "large" ? 8 : capsuleRect.height / 2,
                     yRadius: kind == "large" ? 8 : capsuleRect.height / 2).fill()
        let barY = kind == "large" ? capsuleRect.midY + 3 : capsuleRect.midY
        SD.C.voiceDark.setFill()
        NSBezierPath(roundedRect: NSRect(x: capsuleRect.minX + 8, y: barY - 3,
                                         width: kind == "compact" ? 14 : 18, height: 6),
                     xRadius: 3, yRadius: 3).fill()
        if kind != "compact" {
            NSColor(hex: 0xA3A09A).setFill()
            NSBezierPath(roundedRect: NSRect(x: capsuleRect.minX + 30, y: barY - 1.5,
                                             width: 12, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
        if kind == "large" {
            NSColor.white.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: NSRect(x: capsuleRect.minX + 8,
                                             y: capsuleRect.minY + 4,
                                             width: 34, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }

        // Подпись: 11px, выбранная — 600 ink, остальные graphite.
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: isSelected ? .semibold : .regular),
            .foregroundColor: isSelected ? SD.C.ink : SD.C.graphite,
        ]
        let size = title.size(withAttributes: attrs)
        title.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                               y: bounds.minY + 10),
                   withAttributes: attrs)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(kind)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Карточка модели (вкладка «Модель»)

final class SDModelCard: NSView {
    init(title: String, detail: String, active: Bool, actionTitle: String?,
         target: AnyObject?, action: Selector?, identifier: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        if active {
            layer?.borderWidth = 1.5
        }
        self.active = active
        restyle()

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: active ? .semibold : .regular)
        titleLabel.textColor = SD.C.ink
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = SD.C.subtle

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        var views: [NSView] = [textStack, NSView()]
        if let actionTitle, let action {
            let button = NSButton(title: actionTitle, target: target, action: action)
            button.isBordered = false
            // Макет: «✓ Активна» 11px 600 акцент, «Выбрать» 11px 400 graphite.
            button.font = .systemFont(ofSize: 11, weight: active ? .semibold : .regular)
            button.contentTintColor = active ? SD.C.voice : SD.C.graphite
            button.identifier = NSUserInterfaceItemIdentifier(identifier)
            views.append(button)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let squeeze = heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow
        NSLayoutConstraint.activate([
            squeeze,
            heightAnchor.constraint(greaterThanOrEqualToConstant: 55),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 12),
        ])
    }

    private var active = false

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        if active {
            layer?.borderColor = resolvedCGColor(SD.C.voice)
            layer?.backgroundColor = effectiveAppearance.isDark
                ? NSColor.white.withAlphaComponent(0.05).cgColor
                : NSColor.white.cgColor
        } else {
            layer?.backgroundColor = .clear
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}
