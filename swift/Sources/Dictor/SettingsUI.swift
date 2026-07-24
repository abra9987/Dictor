import AppKit

// Контролы окна настроек — построены с нуля по макету 2c/4b
// («Настройки Dictor», тёмная/светлая бумага). Никаких системных
// NSPopUpButton/NSSwitch: пилюли, тумблер и кейкапы рисуются сами,
// чтобы совпадать с дизайном в обеих темах.

// MARK: - Строка настройки (title + subtitle слева, контрол справа)

final class SDRowView: NSView {
    private let hairline: Bool

    init(title: String, subtitle: String? = nil, control: NSView, hairline: Bool = true) {
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
            subtitleLabel.textColor = SD.C.graphite
            textStack.addArrangedSubview(subtitleLabel)
        }

        for view in [textStack, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: trailingAnchor),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard hairline else { return }
        SD.C.hairline.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }
}

// MARK: - Коралловый тумблер 36×22 (как в макете)

final class SDToggle: NSControl {
    var isOn = false {
        didSet { needsDisplay = true }
    }
    var onToggle: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize { NSSize(width: 36, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11)
        if isOn {
            SD.C.voice.setFill()
        } else {
            SD.C.ink.withAlphaComponent(0.14).setFill()
        }
        track.fill()
        let knobX = isOn ? bounds.maxX - 20 : bounds.minX + 2
        let knob = NSRect(x: knobX, y: bounds.minY + 2, width: 18, height: 18)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 2
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.2)
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
        for option in options {
            let button = NSButton(title: option.title, target: self,
                                  action: #selector(pillClicked(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 12
            button.identifier = NSUserInterfaceItemIdentifier(option.value)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        for button in buttons {
            let selected = button.identifier?.rawValue == selectedValue
            button.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .medium)
            if selected {
                // В мокапе выбранная пилюля — контрастная «чернильная»
                // в светлой теме и «бумажная» в тёмной.
                button.layer?.backgroundColor = SD.C.ink.cgColor
                button.contentTintColor = SD.C.paper
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
        for key in keys {
            let cap = NSTextField(labelWithString: key)
            cap.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
            cap.textColor = SD.C.ink
            cap.alignment = .center
            cap.wantsLayer = true
            cap.layer?.cornerRadius = 7
            cap.layer?.borderWidth = 1
            cap.translatesAutoresizingMaskIntoConstraints = false
            cap.heightAnchor.constraint(equalToConstant: 26).isActive = true
            cap.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
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
                ? NSColor.white.withAlphaComponent(0.1).cgColor
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
        let lower = choice.name.lowercased()
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
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.increment = Double(step)
        stepper.integerValue = value
        stepper.target = self
        stepper.action = #selector(stepperChanged(_:))
        refreshLabel()
        let stack = NSStackView(views: [valueLabel, stepper])
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

    @objc private func stepperChanged(_ sender: NSStepper) {
        value = sender.integerValue
        refreshLabel()
        onChange?(value)
    }
}

// MARK: - Кнопка-«поле» (микрофон и прочие выпадающие значения)

final class SDFieldButton: NSView {
    private let button: NSPopUpButton

    init(popup: NSPopUpButton) {
        self.button = popup
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        popup.isBordered = false
        popup.font = .systemFont(ofSize: 12, weight: .medium)
        popup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(popup)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            popup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        layer?.backgroundColor = effectiveAppearance.isDark
            ? NSColor.white.withAlphaComponent(0.08).cgColor
            : NSColor.black.withAlphaComponent(0.05).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
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
        detailLabel.textColor = SD.C.graphite

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        var views: [NSView] = [textStack, NSView()]
        if let actionTitle, let action {
            let button = NSButton(title: actionTitle, target: target, action: action)
            button.isBordered = false
            button.font = .systemFont(ofSize: 11, weight: .semibold)
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
        NSLayoutConstraint.activate([
            heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private var active = false

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        if active {
            layer?.borderColor = SD.C.voice.cgColor
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
