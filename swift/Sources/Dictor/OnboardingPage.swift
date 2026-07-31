import AppKit

// Онбординг занимает главное окно целиком: слева рейка с четырьмя шагами,
// справа панель активного шага.
//
// Почему не как раньше. Плавающая карточка 356×420 пересобиралась целиком
// по таймеру: снимок состояния включал долю загрузки модели, а значит во
// время скачивания `contentView` менялся примерно раз в тик. На шаге пробы
// это уносило поле ввода вместе с фокусом и набранным текстом.
//
// Здесь виды шагов создаются один раз и живут до конца онбординга. Обновление
// — это `apply(snapshot:)`, который меняет надписи, ширину полоски и состояние
// строк, но не трогает иерархию. Поле ввода не пересоздаётся никогда.

@MainActor
protocol OnboardingPageActions: AnyObject {
    func onboardingStartTapped()
    func onboardingGrantTapped(_ permission: Permission)
    func onboardingSkipTapped()
    func onboardingFinishTapped()
}

// MARK: - Страница целиком

@MainActor
final class OnboardingPageView: NSView {
    private let language: InterfaceLanguage
    private weak var actions: OnboardingPageActions?

    private var rows: [OnboardingRailRow] = []
    private let railHint = NSTextField(wrappingLabelWithString: "")
    private let panelHost = NSView()
    private var stepViews: [OnboardingStep: OnboardingStepView] = [:]
    private var installedStep: OnboardingStep?

    init(language: InterfaceLanguage, actions: OnboardingPageActions?) {
        self.language = language
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let rail = makeRail()
        rail.translatesAutoresizingMaskIntoConstraints = false

        let panel = PaperBackgroundView()
        panel.fill = SD.C.onboardingPaper
        panel.translatesAutoresizingMaskIntoConstraints = false
        panelHost.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(panelHost)

        addSubview(rail)
        addSubview(panel)
        NSLayoutConstraint.activate([
            rail.leadingAnchor.constraint(equalTo: leadingAnchor),
            rail.topAnchor.constraint(equalTo: topAnchor),
            rail.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.widthAnchor.constraint(equalToConstant: 300),
            panel.leadingAnchor.constraint(equalTo: rail.trailingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panelHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            panelHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            panelHost.topAnchor.constraint(equalTo: panel.topAnchor),
            panelHost.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    private func makeRail() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.sidebarPaper

        let wave = SDMiniWaveView(values: [0.32, 0.6, 0.92, 0.6, 0.32],
                                  color: SD.C.voice,
                                  barWidth: 3,
                                  gap: 2.5)
        wave.translatesAutoresizingMaskIntoConstraints = false
        let name = NSTextField(labelWithString: "Dictor")
        name.font = .systemFont(ofSize: 15, weight: .semibold)
        name.textColor = SD.C.ink
        let brand = NSStackView(views: [wave, name])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 10

        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 2
        steps.translatesAutoresizingMaskIntoConstraints = false
        for (index, step) in OnboardingStep.allCases.enumerated() {
            let row = OnboardingRailRow(index: index, title: railTitle(step))
            rows.append(row)
            steps.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: steps.widthAnchor).isActive = true
        }

        railHint.font = .systemFont(ofSize: 11.5)
        railHint.textColor = SD.C.subtle
        railHint.stringValue = t("Шаги переключаются сами, как только macOS выдаёт разрешение или модель дочитывается.",
                                 "Steps advance by themselves as macOS grants a permission or the model finishes downloading.")

        let divider = SDHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let skip = NSButton(title: t("Пропустить настройку", "Skip setup"),
                            target: self,
                            action: #selector(skipTapped))
        skip.isBordered = false
        skip.bezelStyle = .inline
        skip.contentTintColor = SD.C.graphite
        skip.font = .systemFont(ofSize: 12.5)
        skip.translatesAutoresizingMaskIntoConstraints = false

        let spacer = NSView()
        // Первые 52pt — под кнопки окна: сайдбар уходит под тайтлбар.
        let top = NSView()
        top.translatesAutoresizingMaskIntoConstraints = false
        top.heightAnchor.constraint(equalToConstant: 52).isActive = true

        let stack = NSStackView(views: [top, brand, steps, spacer, divider, railHint, skip])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(26, after: brand)
        stack.setCustomSpacing(12, after: divider)
        stack.setCustomSpacing(12, after: railHint)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
            steps.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            railHint.widthAnchor.constraint(equalTo: stack.widthAnchor),
            wave.widthAnchor.constraint(equalToConstant: 26),
            wave.heightAnchor.constraint(equalToConstant: 22),
        ])
        return root
    }

    private func railTitle(_ step: OnboardingStep) -> String {
        switch step {
        case .welcome: return t("Знакомство", "Welcome")
        case .permissions: return t("Разрешения macOS", "macOS permissions")
        case .model: return t("Модель распознавания", "Speech model")
        case .practice: return t("Первая диктовка", "First dictation")
        }
    }

    private func railNote(_ step: OnboardingStep,
                          state: OnboardingRailRow.State,
                          snapshot: OnboardingSnapshot) -> String {
        if state == .done {
            switch step {
            case .welcome: return t("готово", "done")
            case .permissions: return t("все три выданы", "all three granted")
            case .model: return t("загружена", "downloaded")
            case .practice: return t("получилось", "it works")
            }
        }
        switch step {
        case .welcome:
            return t("меньше минуты", "under a minute")
        case .permissions:
            let missing = Permission.allCases.count - snapshot.granted.count
            if state == .todo || missing == Permission.allCases.count {
                return t("три штуки", "three of them")
            }
            return missing == 1
                ? t("осталось одно", "one to go")
                : t("осталось \(missing)", "\(missing) to go")
        case .model:
            guard state == .current, let fraction = snapshot.downloadFraction else {
                return t("~460 МБ", "~460 MB")
            }
            return "\(Int((fraction * 100).rounded()))%"
        case .practice:
            return t("проверим вместе", "let us check together")
        }
    }

    @objc private func skipTapped() { actions?.onboardingSkipTapped() }

    /// Единственная точка обновления. Иерархия не пересобирается: меняются
    /// надписи в рейке и содержимое активного шага.
    func apply(step: OnboardingStep, snapshot: OnboardingSnapshot) {
        for (index, railStep) in OnboardingStep.allCases.enumerated() {
            let state: OnboardingRailRow.State
            if railStep == step {
                state = .current
            } else if railStep.rawValue < step.rawValue {
                state = .done
            } else {
                state = .todo
            }
            rows[index].apply(state: state,
                              note: railNote(railStep, state: state, snapshot: snapshot))
        }

        let view = stepView(for: step)
        if installedStep != step {
            installedStep = step
            for subview in panelHost.subviews { subview.removeFromSuperview() }
            panelHost.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: panelHost.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: panelHost.trailingAnchor),
                view.topAnchor.constraint(equalTo: panelHost.topAnchor),
                view.bottomAnchor.constraint(equalTo: panelHost.bottomAnchor),
            ])
            if let practice = view as? OnboardingPracticeStepView {
                DispatchQueue.main.async { practice.focusField() }
            }
        }
        view.apply(snapshot)
    }

    private func stepView(for step: OnboardingStep) -> OnboardingStepView {
        if let existing = stepViews[step] { return existing }
        let view: OnboardingStepView
        switch step {
        case .welcome:
            view = OnboardingWelcomeStepView(language: language, actions: actions)
        case .permissions:
            view = OnboardingPermissionsStepView(language: language, actions: actions)
        case .model:
            view = OnboardingModelStepView(language: language, actions: actions)
        case .practice:
            view = OnboardingPracticeStepView(language: language, actions: actions)
        }
        stepViews[step] = view
        return view
    }
}

// MARK: - Строка рейки

@MainActor
final class OnboardingRailRow: NSView {
    enum State {
        case done
        case current
        case todo
    }

    private let badge = OnboardingBadgeView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let noteLabel = NSTextField(labelWithString: "")
    private let highlight = PaperBackgroundView()

    init(index: Int, title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        badge.number = index + 1

        highlight.cornerRadius = 9
        highlight.fill = .clear
        highlight.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
        titleLabel.maximumNumberOfLines = 2
        titleLabel.lineBreakMode = .byWordWrapping

        noteLabel.font = .systemFont(ofSize: 11.5)
        noteLabel.textColor = SD.C.subtle
        noteLabel.maximumNumberOfLines = 1

        let text = NSStackView(views: [titleLabel, noteLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        let row = NSStackView(views: [badge, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(highlight)
        addSubview(row)
        NSLayoutConstraint.activate([
            highlight.leadingAnchor.constraint(equalTo: leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: trailingAnchor),
            highlight.topAnchor.constraint(equalTo: topAnchor),
            highlight.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func apply(state: State, note: String) {
        noteLabel.stringValue = note
        switch state {
        case .done:
            badge.state = .done
            titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
            titleLabel.textColor = SD.C.ink
            noteLabel.textColor = SD.C.positive
            highlight.fill = .clear
        case .current:
            badge.state = .current
            titleLabel.font = .systemFont(ofSize: 13.5, weight: .semibold)
            titleLabel.textColor = SD.C.ink
            noteLabel.textColor = SD.C.subtle
            highlight.fill = SD.C.sidebarSelection
        case .todo:
            badge.state = .todo
            titleLabel.font = .systemFont(ofSize: 13.5, weight: .medium)
            titleLabel.textColor = SD.C.graphite
            noteLabel.textColor = SD.C.subtle
            highlight.fill = .clear
        }
    }
}

@MainActor
final class OnboardingBadgeView: NSView {
    enum State { case done, current, todo }

    var number = 1 { didSet { needsDisplay = true } }
    var state: State = .todo { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 22),
            heightAnchor.constraint(equalToConstant: 22),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75))
        let label: String
        let labelColor: NSColor

        switch state {
        case .done:
            SD.C.positive.setFill()
            circle.fill()
            label = "✓"
            labelColor = .white
        case .current:
            SD.C.ink.setFill()
            circle.fill()
            label = String(number)
            labelColor = SD.C.paper
        case .todo:
            SD.C.subtle.setStroke()
            circle.lineWidth = 1.5
            circle.stroke()
            label = String(number)
            labelColor = SD.C.subtle
        }

        let font = NSFont.systemFont(ofSize: state == .done ? 10 : 11, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: labelColor,
        ]
        let size = (label as NSString).size(withAttributes: attributes)
        (label as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}

// MARK: - Общие мелочи панели

@MainActor
func onboardingTitleLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.attributedStringValue = NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: 28, weight: .bold),
        .foregroundColor: SD.C.ink,
        .kern: -0.56,
    ])
    label.maximumNumberOfLines = 2
    label.lineBreakMode = .byWordWrapping
    return label
}

@MainActor
func onboardingSubtitleLabel(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 14)
    label.textColor = SD.C.graphite
    label.isSelectable = false
    label.drawsBackground = false
    return label
}

/// Тёмная кнопка из макета. `SDSolidButton` красится фирменным оранжевым,
/// а главное действие онбординга по макету чернильное.
@MainActor
final class OnboardingPrimaryButton: NSButton {
    var isGhost = false { didSet { restyle() } }

    func restyle() {
        wantsLayer = true
        layer?.cornerRadius = 8
        font = .systemFont(ofSize: 13.5, weight: .semibold)
        if isGhost {
            layer?.backgroundColor = NSColor.clear.cgColor
            layer?.borderWidth = 1
            layer?.borderColor = resolvedCGColor(SD.C.cardBorder)
            contentTintColor = SD.C.graphite
        } else {
            layer?.borderWidth = 0
            layer?.backgroundColor = resolvedCGColor(SD.C.ink)
            contentTintColor = SD.C.paper
        }
        alphaValue = isEnabled ? 1 : 0.4
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

@MainActor
func onboardingButton(_ title: String,
                      target: AnyObject?,
                      action: Selector,
                      ghost: Bool = false) -> OnboardingPrimaryButton {
    let button = OnboardingPrimaryButton(title: title, target: target, action: action)
    button.isBordered = false
    button.bezelStyle = .regularSquare
    button.translatesAutoresizingMaskIntoConstraints = false
    button.isGhost = ghost
    button.restyle()
    let width = ceil(title.size(withAttributes: [
        .font: NSFont.systemFont(ofSize: 13.5, weight: .semibold)
    ]).width)
    NSLayoutConstraint.activate([
        button.heightAnchor.constraint(equalToConstant: 38),
        button.widthAnchor.constraint(equalToConstant: width + 40),
    ])
    return button
}

/// Клавиши хоткея как на макете: светлая накладка с утолщённым низом.
@MainActor
final class OnboardingKeycapsView: NSStackView {
    init(caps: [String]) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        rebuild(caps: caps)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func rebuild(caps: [String]) {
        for view in arrangedSubviews { view.removeFromSuperview() }
        for (index, cap) in caps.enumerated() {
            if index > 0 {
                let plus = NSTextField(labelWithString: "+")
                plus.font = .systemFont(ofSize: 12)
                plus.textColor = SD.C.subtle
                addArrangedSubview(plus)
            }
            addArrangedSubview(OnboardingKeycapView(text: cap))
        }
    }
}

@MainActor
final class OnboardingKeycapView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        label.stringValue = text
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = SD.C.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func restyle() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = resolvedCGColor(SD.C.cardFill)
        layer?.borderWidth = 1
        layer?.borderColor = resolvedCGColor(SD.C.cardBorder)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
        label.textColor = SD.C.ink
    }
}

/// Белая карточка с рамкой. Не `PaperBackgroundView`: там рамка жёстко
/// hairline, а активной строке разрешений нужна фирменная обводка.
@MainActor
final class OnboardingCardView: NSView {
    var cornerRadius: CGFloat = 12 { didSet { needsDisplay = true } }
    var borderColor: NSColor? { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: cornerRadius,
                                yRadius: cornerRadius)
        SD.C.cardFill.setFill()
        path.fill()
        (borderColor ?? SD.C.cardBorder).setStroke()
        path.lineWidth = borderColor == nil ? 1 : 1.5
        path.stroke()
    }
}
