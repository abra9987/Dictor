import AppKit

// Четыре шага онбординга и страница, которая их держит.
// Каждый шаг — долгоживущий вид с методом `apply(_:)`: он меняет надписи и
// состояния, но никогда не пересобирает иерархию. См. OnboardingPage.swift.

// MARK: - Описание разрешений

struct OnboardingPermissionCopy {
    let name: String
    let why: String
    let symbol: String
}

@MainActor
func onboardingPermissionCopy(_ permission: Permission,
                              language: InterfaceLanguage) -> OnboardingPermissionCopy {
    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }
    switch permission {
    case .microphone:
        return OnboardingPermissionCopy(
            name: t("Микрофон", "Microphone"),
            why: t("Слышать вас, пока клавиша зажата", "To hear you while the key is held"),
            symbol: "mic.fill")
    case .inputMonitoring:
        return OnboardingPermissionCopy(
            name: t("Мониторинг ввода", "Input Monitoring"),
            why: t("Ловить хоткей, пока вы в другой программе",
                   "To catch the hotkey while you are in another app"),
            symbol: "keyboard")
    case .accessibility:
        return OnboardingPermissionCopy(
            name: t("Универсальный доступ", "Accessibility"),
            why: t("Вставлять текст туда, где стоит курсор",
                   "To paste text where the caret is"),
            symbol: "text.cursor")
    }
}

/// Порядок выдачи. Микрофон первым — он единственный показывает системный
/// диалог сразу, остальные два уводят в Системные настройки.
let ONBOARDING_PERMISSION_ORDER: [Permission] = [.microphone, .inputMonitoring, .accessibility]

// MARK: - Базовый шаг

@MainActor
class OnboardingStepView: NSView {
    let language: InterfaceLanguage
    weak var actions: OnboardingPageActions?

    let headStack = NSStackView()
    let bodyStack = NSStackView()
    let footNote = NSTextField(labelWithString: "")
    private let footRow = NSStackView()

    init(language: InterfaceLanguage, actions: OnboardingPageActions?) {
        self.language = language
        self.actions = actions
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        headStack.orientation = .vertical
        headStack.alignment = .leading
        headStack.spacing = 10

        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 14

        footNote.font = .systemFont(ofSize: 12)
        footNote.textColor = SD.C.subtle
        footNote.maximumNumberOfLines = 2
        footNote.lineBreakMode = .byWordWrapping

        footRow.orientation = .horizontal
        footRow.alignment = .centerY
        footRow.spacing = 16
        footRow.translatesAutoresizingMaskIntoConstraints = false

        // Свободная высота достаётся распорке, а не содержимому: иначе
        // NSStackView растягивал поле пробы на пол-панели.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        headStack.setContentHuggingPriority(.required, for: .vertical)
        bodyStack.setContentHuggingPriority(.required, for: .vertical)
        footRow.setContentHuggingPriority(.required, for: .vertical)

        let root = NSStackView(views: [headStack, bodyStack, spacer, footRow])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.setCustomSpacing(32, after: headStack)
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 56),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -56),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 64),
            root.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -40),
            headStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            footRow.widthAnchor.constraint(equalTo: root.widthAnchor),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    /// Шапка: заголовок и подзаголовок ограничены по ширине, чтобы строка
    /// оставалась читаемой и не растягивалась на всю панель.
    func setHead(title: String, subtitle: String) {
        let titleLabel = onboardingTitleLabel(title)
        let subtitleLabel = onboardingSubtitleLabel(subtitle)
        headStack.addArrangedSubview(titleLabel)
        headStack.addArrangedSubview(subtitleLabel)
        NSLayoutConstraint.activate([
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])
    }

    func setFoot(note: String, button: NSView?) {
        footNote.stringValue = note
        footRow.addArrangedSubview(footNote)
        let spacer = NSView()
        footRow.addArrangedSubview(spacer)
        if let button {
            footRow.addArrangedSubview(button)
        }
    }

    func apply(_ snapshot: OnboardingSnapshot) {}
}

// MARK: - Шаг 1. Приветствие

@MainActor
final class OnboardingWelcomeStepView: OnboardingStepView {
    private let keycaps: OnboardingKeycapsView

    override init(language: InterfaceLanguage, actions: OnboardingPageActions?) {
        keycaps = OnboardingKeycapsView(caps: [])
        super.init(language: language, actions: actions)

        let wave = SDMiniWaveView(values: [0.3, 0.6, 1.0, 0.6, 0.3],
                                  color: SD.C.voice,
                                  barWidth: 6,
                                  gap: 5)
        wave.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wave.widthAnchor.constraint(equalToConstant: 50),
            wave.heightAnchor.constraint(equalToConstant: 74),
        ])
        headStack.addArrangedSubview(wave)
        headStack.setCustomSpacing(30, after: wave)

        setHead(title: t("Диктуйте в любое поле ввода", "Dictate into any text field"),
                subtitle: t("Один хоткей — и ваша речь становится текстом там, где стоит курсор. Всё распознаётся на этом Mac, голос никуда не отправляется.",
                            "One hotkey — and your speech becomes text right where the caret is. Everything is transcribed on this Mac; your voice never leaves it."))

        let caption = NSTextField(labelWithString: t("ТАК ЭТО ВЫГЛЯДИТ", "HOW IT LOOKS"))
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = SD.C.subtle
        bodyStack.addArrangedSubview(caption)
        bodyStack.setCustomSpacing(9, after: caption)

        let field = OnboardingCardView()
        let sample = NSTextField(labelWithString:
            t("Привет! Сегодня встречаемся в семь", "Hi! We are meeting at seven today"))
        sample.font = .systemFont(ofSize: 14.5)
        sample.textColor = SD.C.inkSecondary
        sample.translatesAutoresizingMaskIntoConstraints = false
        let caret = PaperBackgroundView()
        caret.fill = SD.C.voice
        caret.cornerRadius = 1
        caret.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(sample)
        field.addSubview(caret)
        NSLayoutConstraint.activate([
            sample.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 20),
            sample.topAnchor.constraint(equalTo: field.topAnchor, constant: 18),
            sample.bottomAnchor.constraint(equalTo: field.bottomAnchor, constant: -18),
            caret.leadingAnchor.constraint(equalTo: sample.trailingAnchor, constant: 3),
            caret.centerYAnchor.constraint(equalTo: sample.centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 2),
            caret.heightAnchor.constraint(equalToConstant: 19),
            caret.trailingAnchor.constraint(lessThanOrEqualTo: field.trailingAnchor, constant: -20),
        ])
        bodyStack.addArrangedSubview(field)
        field.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        bodyStack.setCustomSpacing(22, after: field)

        let hold = NSTextField(labelWithString: t("Удерживайте", "Hold"))
        hold.font = .systemFont(ofSize: 12.5)
        hold.textColor = SD.C.graphite
        let speak = NSTextField(labelWithString: t("и говорите", "and speak"))
        speak.font = .systemFont(ofSize: 12.5)
        speak.textColor = SD.C.graphite
        // Хвостовая распорка: без неё стек разносил «и говорите» к правому краю.
        let hotkeyRow = NSStackView(views: [hold, keycaps, speak, NSView()])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.alignment = .centerY
        hotkeyRow.spacing = 14
        bodyStack.addArrangedSubview(hotkeyRow)
        hotkeyRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        setFoot(note: t("Речь не покидает Mac. Сеть — загрузка модели и проверка обновлений, её можно выключить",
                        "Speech never leaves your Mac. The network is for the model download and the update check — that can be turned off"),
                button: onboardingButton(t("Настроить за минуту", "Set up in a minute"),
                                         target: self,
                                         action: #selector(startTapped)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func startTapped() { actions?.onboardingStartTapped() }

    override func apply(_ snapshot: OnboardingSnapshot) {
        keycaps.rebuild(caps: snapshot.hotkeyCaps)
    }
}

// MARK: - Шаг 2. Разрешения

@MainActor
final class OnboardingPermissionRowView: NSView {
    enum State {
        case granted
        case actionable
        case waiting
    }

    let permission: Permission
    private let card = OnboardingCardView()
    private let chip = NSStackView()
    private let chipLabel = NSTextField(labelWithString: "")
    private let tick = OnboardingTickView()
    private let grantButton: NSButton
    private let waitingLabel = NSTextField(labelWithString: "")
    private weak var actions: OnboardingPageActions?

    init(permission: Permission,
         language: InterfaceLanguage,
         actions: OnboardingPageActions?) {
        self.permission = permission
        self.actions = actions
        let copy = onboardingPermissionCopy(permission, language: language)
        grantButton = NSButton(title: localizedText("Разрешить", "Allow", language: language),
                               target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: copy.symbol, accessibilityDescription: copy.name)
        icon.symbolConfiguration = .init(pointSize: 15, weight: .medium)
        icon.contentTintColor = SD.C.ink
        icon.translatesAutoresizingMaskIntoConstraints = false
        let iconWell = PaperBackgroundView()
        iconWell.fill = SD.C.hintPaper
        iconWell.cornerRadius = 9
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.addSubview(icon)

        let name = NSTextField(labelWithString: copy.name)
        name.font = .systemFont(ofSize: 13.5, weight: .semibold)
        name.textColor = SD.C.ink
        let why = NSTextField(labelWithString: copy.why)
        why.font = .systemFont(ofSize: 12)
        why.textColor = SD.C.graphite
        let text = NSStackView(views: [name, why])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2

        chipLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        chipLabel.textColor = SD.C.positive
        chipLabel.stringValue = localizedText("Выдано", "Granted", language: language)
        chip.orientation = .horizontal
        chip.alignment = .centerY
        chip.spacing = 5
        chip.addArrangedSubview(tick)
        chip.addArrangedSubview(chipLabel)

        grantButton.target = self
        grantButton.action = #selector(grantTapped)
        grantButton.isBordered = false
        grantButton.bezelStyle = .regularSquare
        grantButton.wantsLayer = true
        grantButton.translatesAutoresizingMaskIntoConstraints = false
        grantButton.font = .systemFont(ofSize: 12.5, weight: .semibold)

        waitingLabel.font = .systemFont(ofSize: 12)
        waitingLabel.textColor = SD.C.subtle
        waitingLabel.stringValue = localizedText("Следующим", "Up next", language: language)

        let row = NSStackView(views: [iconWell, text, NSView(), chip, grantButton, waitingLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        addSubview(card)
        card.addSubview(row)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: card.topAnchor, constant: 15),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -15),
            iconWell.widthAnchor.constraint(equalToConstant: 34),
            iconWell.heightAnchor.constraint(equalToConstant: 34),
            icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            grantButton.heightAnchor.constraint(equalToConstant: 30),
            grantButton.widthAnchor.constraint(equalToConstant: 92),
        ])
        restyleButton()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func restyleButton() {
        grantButton.layer?.cornerRadius = 7
        grantButton.layer?.backgroundColor = resolvedCGColor(SD.C.ink)
        grantButton.contentTintColor = SD.C.paper
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyleButton()
    }

    @objc private func grantTapped() { actions?.onboardingGrantTapped(permission) }

    func apply(state: State) {
        chip.isHidden = state != .granted
        grantButton.isHidden = state != .actionable
        waitingLabel.isHidden = state != .waiting
        card.borderColor = state == .actionable ? SD.C.voice : nil
    }
}

@MainActor
final class OnboardingTickView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 17),
            heightAnchor.constraint(equalToConstant: 17),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        SD.C.positive.setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let size = ("✓" as NSString).size(withAttributes: attributes)
        ("✓" as NSString).draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attributes)
    }
}

@MainActor
final class OnboardingPermissionsStepView: OnboardingStepView {
    private var rows: [OnboardingPermissionRowView] = []

    override init(language: InterfaceLanguage, actions: OnboardingPageActions?) {
        super.init(language: language, actions: actions)

        setHead(title: t("Три разрешения macOS", "Three macOS permissions"),
                subtitle: t("Каждое — по одной причине. Выдаются по очереди: окно системных настроек откроется само, там нужно щёлкнуть тумблер.",
                            "Each one for a single reason. Granted in order: System Settings opens by itself, you flip the switch there."))

        bodyStack.spacing = 10
        for permission in ONBOARDING_PERMISSION_ORDER {
            let row = OnboardingPermissionRowView(permission: permission,
                                                  language: language,
                                                  actions: actions)
            rows.append(row)
            bodyStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true
        }

        setFoot(note: t("Разрешения проверяются каждые несколько секунд — возвращаться сюда не нужно",
                        "Permissions are re-checked every few seconds — no need to come back here"),
                button: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func apply(_ snapshot: OnboardingSnapshot) {
        // Активна ровно одна строка — первая невыданная по порядку. Так
        // человек не мечется между тремя тумблерами сразу.
        let firstMissing = ONBOARDING_PERMISSION_ORDER.first { !snapshot.granted.contains($0) }
        for row in rows {
            if snapshot.granted.contains(row.permission) {
                row.apply(state: .granted)
            } else if row.permission == firstMissing {
                row.apply(state: .actionable)
            } else {
                row.apply(state: .waiting)
            }
        }
    }
}

// MARK: - Шаг 3. Модель

@MainActor
final class OnboardingModelStepView: OnboardingStepView {
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let bar = OnboardingProgressBarView()
    private let stateLabel = NSTextField(labelWithString: "")

    override init(language: InterfaceLanguage, actions: OnboardingPageActions?) {
        super.init(language: language, actions: actions)

        setHead(title: t("Скачиваем модель распознавания", "Downloading the speech model"),
                subtitle: t("Распознавание — целиком на вашем Mac: в самолёте, в поезде, без сети. Дальше Dictor выходит в интернет только спросить номер новой версии, и эту проверку можно выключить.",
                            "Transcription runs entirely on your Mac — on a plane, on a train, offline. From here Dictor only goes online to ask for the latest version number, and that check can be turned off."))

        let card = OnboardingCardView()
        card.cornerRadius = 14

        let name = NSTextField(labelWithString:
            t("Parakeet TDT v3 · русский и английский", "Parakeet TDT v3 · Russian and English"))
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.textColor = SD.C.ink

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 20, weight: .semibold)
        percentLabel.textColor = SD.C.voice

        let top = NSStackView(views: [name, NSView(), percentLabel])
        top.orientation = .horizontal
        top.alignment = .lastBaseline
        top.translatesAutoresizingMaskIntoConstraints = false

        let size = NSTextField(labelWithString: t("~460 МБ · один раз", "~460 MB · once"))
        size.font = .systemFont(ofSize: 12)
        size.textColor = SD.C.subtle
        stateLabel.font = .systemFont(ofSize: 12)
        stateLabel.textColor = SD.C.subtle
        let foot = NSStackView(views: [size, NSView(), stateLabel])
        foot.orientation = .horizontal
        foot.translatesAutoresizingMaskIntoConstraints = false

        bar.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(top)
        card.addSubview(bar)
        card.addSubview(foot)
        NSLayoutConstraint.activate([
            top.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            top.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            top.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            bar.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            bar.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14),
            bar.heightAnchor.constraint(equalToConstant: 7),
            foot.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            foot.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            foot.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 11),
            foot.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
        ])
        bodyStack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        let aside = PaperBackgroundView()
        aside.fill = SD.C.hintPaper
        aside.cornerRadius = 11
        aside.translatesAutoresizingMaskIntoConstraints = false
        let asideText = NSTextField(wrappingLabelWithString:
            t("Модель ложится в Application Support и остаётся там навсегда. Обновления приложения её не перекачивают.",
              "The model goes into Application Support and stays there. App updates do not re-download it."))
        asideText.font = .systemFont(ofSize: 12.5)
        asideText.textColor = SD.C.graphite
        asideText.translatesAutoresizingMaskIntoConstraints = false
        aside.addSubview(asideText)
        NSLayoutConstraint.activate([
            asideText.leadingAnchor.constraint(equalTo: aside.leadingAnchor, constant: 16),
            asideText.trailingAnchor.constraint(equalTo: aside.trailingAnchor, constant: -16),
            asideText.topAnchor.constraint(equalTo: aside.topAnchor, constant: 14),
            asideText.bottomAnchor.constraint(equalTo: aside.bottomAnchor, constant: -14),
        ])
        bodyStack.addArrangedSubview(aside)
        aside.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        setFoot(note: t("Окно можно закрыть — глиф в меню-баре покажет прогресс",
                        "You can close this window — the menu bar glyph shows progress"),
                button: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func apply(_ snapshot: OnboardingSnapshot) {
        let fraction = snapshot.modelReady ? 1 : (snapshot.downloadFraction ?? 0)
        percentLabel.stringValue = "\(Int((fraction * 100).rounded()))%"
        bar.fraction = CGFloat(fraction)
        if snapshot.modelReady {
            stateLabel.stringValue = t("готово", "done")
        } else if snapshot.downloadFraction == nil {
            stateLabel.stringValue = t("ждём службу…", "waiting for the service…")
        } else {
            stateLabel.stringValue = t("качается…", "downloading…")
        }
    }
}

@MainActor
final class OnboardingProgressBarView: NSView {
    var fraction: CGFloat = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        SD.C.hintPaper.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        let clamped = max(0, min(1, fraction))
        guard clamped > 0 else { return }
        let width = max(bounds.height, bounds.width * clamped)
        SD.C.voice.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: width, height: bounds.height),
                     xRadius: radius,
                     yRadius: radius).fill()
    }
}

// MARK: - Шаг 4. Проба

@MainActor
final class OnboardingPracticeStepView: OnboardingStepView {
    private let keycaps: OnboardingKeycapsView
    private let field = OnboardingPracticeFieldView()
    private let successRow = NSStackView()
    private let successLabel = NSTextField(labelWithString: "")
    private let finishButton: OnboardingPrimaryButton

    override init(language: InterfaceLanguage, actions: OnboardingPageActions?) {
        keycaps = OnboardingKeycapsView(caps: [])
        finishButton = OnboardingPrimaryButton(
            title: localizedText("Начать пользоваться", "Start using Dictor", language: language),
            target: nil, action: nil)
        super.init(language: language, actions: actions)

        setHead(title: t("Попробуйте прямо здесь", "Try it right here"),
                subtitle: t("Зажмите хоткей, скажите что-нибудь и отпустите. Текст появится в поле ниже.",
                            "Hold the hotkey, say something, release. The text lands in the field below."))

        let hint = NSTextField(labelWithString: t("удерживайте и говорите", "hold and speak"))
        hint.font = .systemFont(ofSize: 12.5)
        hint.textColor = SD.C.graphite
        let hotkeyRow = NSStackView(views: [keycaps, hint, NSView()])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.alignment = .centerY
        hotkeyRow.spacing = 14
        bodyStack.addArrangedSubview(hotkeyRow)
        hotkeyRow.widthAnchor.constraint(equalTo: bodyStack.widthAnchor).isActive = true

        bodyStack.addArrangedSubview(field)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalTo: bodyStack.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 108),
        ])

        successLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        successLabel.textColor = SD.C.positive
        successRow.orientation = .horizontal
        successRow.alignment = .centerY
        successRow.spacing = 9
        successRow.addArrangedSubview(OnboardingTickView())
        successRow.addArrangedSubview(successLabel)
        successRow.isHidden = true
        bodyStack.addArrangedSubview(successRow)

        finishButton.target = self
        finishButton.action = #selector(finishTapped)
        finishButton.isBordered = false
        finishButton.bezelStyle = .regularSquare
        finishButton.translatesAutoresizingMaskIntoConstraints = false
        finishButton.restyle()
        NSLayoutConstraint.activate([
            finishButton.heightAnchor.constraint(equalToConstant: 38),
            finishButton.widthAnchor.constraint(equalToConstant: 200),
        ])

        setFoot(note: t("Хоткей можно поменять в настройках в любой момент",
                        "You can change the hotkey in settings at any time"),
                button: finishButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func finishTapped() { actions?.onboardingFinishTapped() }

    /// Поле должно быть первым откликающимся, иначе вставка уйдёт мимо.
    func focusField() {
        window?.makeFirstResponder(field.textView)
    }

    override func apply(_ snapshot: OnboardingSnapshot) {
        keycaps.rebuild(caps: snapshot.hotkeyCaps)
        field.setSuccess(snapshot.practiceDone)
        successRow.isHidden = !snapshot.practiceDone
        if snapshot.practiceDone {
            successLabel.stringValue = t("Готово — текст попал в историю",
                                         "Done — the text is in your history")
        }
    }
}

/// Поле для пробной диктовки. Рамка и заливка рисуются вручную: у
/// `NSScrollView` свой слой, и заданные ему `layer.backgroundColor` с
/// `borderColor` до окна не доживали — поле выходило невидимым.
@MainActor
final class OnboardingPracticeFieldView: NSView {
    let textView = NSTextView()
    private let scroll = NSScrollView()
    private var isSuccess = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder

        textView.isEditable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = SD.C.ink
        textView.insertionPointColor = SD.C.voice
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scroll.documentView = textView

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setSuccess(_ success: Bool) {
        guard success != isSuccess else { return }
        isSuccess = success
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75),
                                xRadius: 12,
                                yRadius: 12)
        SD.C.cardFill.setFill()
        path.fill()
        (isSuccess ? SD.C.positive : SD.C.cardBorder).setStroke()
        path.lineWidth = isSuccess ? 1.5 : 1
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        textView.textColor = SD.C.ink
        needsDisplay = true
    }
}
