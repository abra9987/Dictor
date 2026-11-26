import AppKit

// MARK: - Карточки размера капсулы (три превью в ряд)

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
        // Подпись переносится. Однострочной она была шире вкладки: рендер
        // «Службы» выходил 858 pt вместо 767, а в окне правый край текста
        // уезжал за карточку.
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.maximumNumberOfLines = 0
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        self.detailLabel = detailLabel

        let textStack = NSStackView(views: [titleLabel, detailLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1

        var views: [NSView] = [textStack, NSView()]
        if let actionTitle, let action {
            trailingReserve = 96
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
    private var detailLabel: NSTextField?
    /// Место под кнопку справа, если она есть: подписи его занимать нельзя.
    private var trailingReserve: CGFloat = 0

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Ширину переноса нельзя задать в init — до первой раскладки ширина
        // карточки нулевая; тот же приём, что у SDRowView.
        guard let detailLabel else { return }
        let available = bounds.width - 24 - trailingReserve
        if available > 80, abs(detailLabel.preferredMaxLayoutWidth - available) > 0.5 {
            detailLabel.preferredMaxLayoutWidth = available
            detailLabel.invalidateIntrinsicContentSize()
        }
    }

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

/// Плитка производительности (макет 6d): подложка listPaper, радиус 9,
/// поля 11×13, значение mono 17/600, подпись 11 с межстрочным 1.4.
@MainActor
final class SDMetricTile: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")

    init(value: String, caption: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9

        valueLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.maximumNumberOfLines = 2
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.preferredMaxLayoutWidth = 140
        // Иначе длинная подпись растягивает плитку по ширине вместо переноса.
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [valueLabel, captionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -13),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor, constant: 11),
        ])

        update(value: value, caption: caption)
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    func update(value: String, caption: String?) {
        valueLabel.stringValue = value
        if let caption {
            captionLabel.stringValue = caption
        }
    }

    private func restyle() {
        layer?.backgroundColor = resolvedCGColor(SD.C.listPaper)
        valueLabel.textColor = SD.C.ink
        captionLabel.textColor = SD.C.graphite
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// Сегментированный переключатель из макета 6d: дорожка rgba(0,0,0,.055)
/// радиусом 8 с полями 3, сегменты 4×13 радиусом 6, выбранный — белая
/// плашка с тенью и ink 600, остальные graphite.
///
/// Не SDPills: у тех выбранный сегмент — тёмная пилюля, и рядом с живым
/// превью капсулы получались две конкурирующие чёрные плашки.
final class SDSegmented: NSView {
    private let values: [String]
    private(set) var selectedValue: String
    var onSelect: ((String) -> Void)?
    private var buttons: [NSButton] = []

    init(titles: [String], values: [String], selected: String) {
        self.values = values
        self.selectedValue = selected
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])

        for (title, value) in zip(titles, values) {
            let button = NSButton(title: title, target: self,
                                  action: #selector(segmentClicked(_:)))
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.identifier = NSUserInterfaceItemIdentifier(value)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 22).isActive = true
            let textWidth = ceil(title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]).width)
            button.widthAnchor.constraint(equalToConstant: max(28, textWidth + 26)).isActive = true
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func segmentClicked(_ sender: NSButton) {
        guard let value = sender.identifier?.rawValue else { return }
        selectedValue = value
        restyle()
        onSelect?(value)
    }

    private func restyle() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.07)
                                       : NSColor.black.withAlphaComponent(0.055)).cgColor
        for button in buttons {
            let selected = button.identifier?.rawValue == selectedValue
            button.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .regular)
            if selected {
                button.layer?.backgroundColor = (dark ? NSColor(hex: 0x3A3835) : .white).cgColor
                button.layer?.shadowColor = NSColor.black.cgColor
                button.layer?.shadowOpacity = dark ? 0.4 : 0.12
                button.layer?.shadowOffset = NSSize(width: 0, height: -1)
                button.layer?.shadowRadius = 1.5
                button.contentTintColor = SD.C.ink
            } else {
                button.layer?.backgroundColor = .clear
                button.layer?.shadowOpacity = 0
                button.contentTintColor = SD.C.graphite
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// Живое превью капсулы для выбранного размера: тёмная пилюля, коралловая
/// волна, mono-таймер. Пропорции берутся у настоящей капсулы, поэтому
/// переключение S/M/L видно сразу — в макете превью нарисованы статикой,
/// но статичная картинка рядом с переключателем ничего не сообщает.
/// Превью капсулы записи — настоящая `RecordingHUDView`, а не её рисунок.
///
/// Рисунком оно и было: пилюля 132×34 фиксированного размера, ширина —
/// выдуманная доля от него (0.66 / 0.84 / 1), заливка и цвет волны —
/// константы. Значит S/M/L меняли картинку на несколько пикселей и никогда
/// не показывали настоящий размер, а свотчи цвета и вовсе не доходили сюда:
/// человек выбирал розовый и видел коралловый. Превью, которое врёт про
/// то, что настраивают прямо под ним, хуже отсутствующего.
final class SDCapsulePreview: NSView {
    private let hud = RecordingHUDView(frame: .zero)
    private var hudWidth: NSLayoutConstraint!
    private var hudHeight: NSLayoutConstraint!
    private var motionTimer: Timer?
    private var phase: CGFloat = 0

    init(size: RecordingHUDSize,
         backgroundStyle: RecordingHUDBackgroundStyle,
         color: NSColor,
         transcribingColor: NSColor,
         language: InterfaceLanguage) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hud.translatesAutoresizingMaskIntoConstraints = false
        hud.mode = .recording
        hud.revealProgress = 1
        hud.recordingElapsed = 7
        hud.interfaceLanguage = language
        hud.recordingColor = color
        hud.transcribingColor = transcribingColor
        hud.backgroundStyle = backgroundStyle
        addSubview(hud)

        hudWidth = hud.widthAnchor.constraint(equalToConstant: size.expandedSize.width)
        hudHeight = hud.heightAnchor.constraint(equalToConstant: size.expandedSize.height)
        NSLayoutConstraint.activate([
            // Высота держится по самой большой капсуле: иначе карточка
            // прыгала бы на 24 pt при каждом переключении S/M/L.
            heightAnchor.constraint(equalToConstant: RecordingHUDSize.large.expandedSize.height),
            hud.centerXAnchor.constraint(equalTo: centerXAnchor),
            hud.centerYAnchor.constraint(equalTo: centerYAnchor),
            hudWidth,
            hudHeight,
        ])
        apply(size: size)
    }

    required init?(coder: NSCoder) { nil }

    func apply(size: RecordingHUDSize) {
        hud.hudSize = size
        hud.visualScale = size.visualScale
        hudWidth.constant = size.expandedSize.width
        hudHeight.constant = size.expandedSize.height
        needsLayout = true
    }

    func apply(color: NSColor) {
        hud.recordingColor = color
    }

    func apply(backgroundStyle: RecordingHUDBackgroundStyle) {
        hud.backgroundStyle = backgroundStyle
    }

    /// Волна живёт, пока превью на экране: неподвижная капсула показывала бы
    /// одну застывшую полоску и снова была бы не тем, что человек увидит.
    /// Таймер привязан к окну — вкладку закрыли, движение кончилось.
    /// Шаг волны: уровень «как в речи» — не шум и не синус, иначе волна
    /// читается либо как помеха, либо как заставка.
    private func advanceWave() {
        phase += 0.16
        hud.phase = phase
        let base = 0.45 + 0.35 * sin(phase * 0.7)
        let flutter = 0.12 * sin(phase * 2.3)
        hud.level = Float(max(0.05, min(1, base + flutter)))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        motionTimer?.invalidate()
        motionTimer = nil
        guard window != nil else { return }
        // Замыкание таймера — Sendable, а вид живёт на главном акторе.
        // Без assumeIsolated это собиралось локально и падало на CI: у
        // строгой проверки конкурентности своё мнение о том, кто чей.
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.advanceWave()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        motionTimer = timer
    }

    // deinit таймер не трогает: он @MainActor-изолирован, а deinit — нет.
    // Гасит его viewDidMoveToWindow(window == nil), то есть уход вкладки с
    // экрана; вкладка пересобирается целиком, так что этот путь и есть
    // обычный конец жизни превью.
}
