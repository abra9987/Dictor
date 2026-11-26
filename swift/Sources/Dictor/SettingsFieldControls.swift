import AppKit

// MARK: - Mono-степпер («120 ms»)

final class SDStepperRow: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private var value: Int
    private let step: Int
    private let range: ClosedRange<Int>
    private let suffix: String
    var onChange: ((Int) -> Void)?
    /// Выключённый степпер приглушён И не принимает нажатий. Приглушить, но
    /// оставить рабочим — значит показать значение, которое человек меняет,
    /// а оно ни на что не влияет; это хуже, чем не показывать вовсе.
    var isEnabled = true {
        didSet {
            alphaValue = isEnabled ? 1 : 0.55
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isEnabled ? super.hitTest(point) : nil
    }

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

/// Документ скролла с системой координат сверху вниз — иначе короткий
/// список прижимается к нижней кромке NSScrollView.
final class SDFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Капс-заголовок группы настроек. Он делает работу подвкладки: называет
/// тему, под которой лежат строки, и позволяет держать навигацию плоской.
@MainActor
func settingsGroupHeaderLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.attributedStringValue = NSAttributedString(
        string: text.uppercased(),
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: SD.C.subtle,
            .kern: 0.6,
        ])
    return label
}

/// Статистика за 30 дней в шапке истории: слова, WPM, экономия, бары
/// по дням (макет 2b: mono 17/600 + подписи 10.5 + бары справа).
@MainActor

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
