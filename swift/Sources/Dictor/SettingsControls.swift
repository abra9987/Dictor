import AppKit

/// Кнопка-таб окна настроек. Активная — пилюля rgba(0,0,0,.08) /
/// rgba(255,255,255,.1), текст ink 600; неактивная — graphite 400.
/// Restyle на смене темы, иначе слой остаётся с цветом старой appearance.
final class SDTabButton: NSButton {
    var isActiveTab = false {
        didSet { restyle() }
    }

    /// Точка у ярлыка — новость, а не состояние: её ставит доступное
    /// обновление. Состояние («разрешение отозвано») зовёт человека подвалом
    /// сайдбара и баннером, где он в него и упирается; точка бережётся для
    /// того, чего он иначе не заметит вовсе.
    var showsBadge = false {
        didSet {
            guard showsBadge != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    static let badgeSize: CGFloat = 6
    static let badgeGap: CGFloat = 6

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard showsBadge else { return }
        // Заголовок кнопка центрирует сама, поэтому точку ставим от его
        // правого края, а не от края кнопки: иначе при разной длине названий
        // она гуляла бы то вплотную к тексту, то далеко от него.
        let titleWidth = title.size(withAttributes: [.font: font ?? .systemFont(ofSize: 12.5)]).width
        let size = SDTabButton.badgeSize
        let rect = NSRect(x: bounds.midX + titleWidth / 2 + SDTabButton.badgeGap,
                          y: bounds.midY - size / 2,
                          width: size, height: size)
        SD.C.voice.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    /// Активная вкладка приподнята над полосой: белая карточка с мягкой
    /// тенью (в тёмной теме — светлее фона полосы). Прежняя заливка
    /// «чуть темнее фона» читалась как нажатая, а не как выбранная.
    static let activeFill = NSColor(name: nil) { appearance in
        appearance.isDark
            ? NSColor(hex: 0x403D39)
            : NSColor.white
    }

    func restyle() {
        wantsLayer = true
        layer?.cornerRadius = 7
        font = .systemFont(ofSize: 12.5, weight: isActiveTab ? .semibold : .medium)
        if isActiveTab {
            layer?.backgroundColor = resolvedCGColor(SDTabButton.activeFill)
            contentTintColor = SD.C.ink
            layer?.shadowColor = NSColor.black.cgColor
            layer?.shadowOpacity = effectiveAppearance.isDark ? 0.28 : 0.10
            layer?.shadowOffset = CGSize(width: 0, height: -1)
            layer?.shadowRadius = 1.5
        } else {
            layer?.backgroundColor = .clear
            contentTintColor = SD.C.graphite
            layer?.shadowOpacity = 0
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

    /// Красимся при создании, а не только при смене темы. Раньше `restyle()`
    /// звали лишь из `viewDidChangeEffectiveAppearance`, и только что созданная
    /// кнопка до первой смены темы выглядела системной — то есть не такой, как
    /// в макете.
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func restyle() {
        wantsLayer = true
        layer?.cornerRadius = 8
        font = .systemFont(ofSize: 12, weight: .semibold)
        layer?.backgroundColor = resolvedCGColor(SD.C.voice)
        contentTintColor = SD.C.onVoice
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
        // Блёклый тумблер обязан быть и мёртвым: поповер выключает его на
        // время установки обновления (isEnabled = false, alpha 0.45), а
        // NSControl сам за этим в mouseDown не следит.
        guard isEnabled else { return }
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
