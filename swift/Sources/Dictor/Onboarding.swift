import AppKit

// Онбординг по макету 2d: одна плавающая карточка, четыре шага.
// 1 приветствие → 2 права macOS (номера шагов, выдаются по очереди)
// → 3 загрузка модели с прогрессом → 4 «попробуйте прямо здесь».
// Шаги переключаются сами по реальному состоянию: права выданы →
// модель готова → первая диктовка попала в историю.

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case model
    case practice
}

/// Снимок мира для рендера шага. В приложении собирается из
/// Permissions/AgentRuntimeStateStore/Settings; в превью — задаётся руками.
struct OnboardingSnapshot {
    var granted: Set<Permission>
    var modelReady: Bool
    var downloadFraction: Double?
    var hotkeyCaps: [String]
    var dictatedText: String?
    var practiceDone: Bool
    var language: InterfaceLanguage
}

@MainActor
final class OnboardingWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class OnboardingController {
    static let cardWidth: CGFloat = 356

    private(set) var step: OnboardingStep = .welcome
    private var window: OnboardingWindow?
    private var timer: Timer?
    private let settings = Settings.shared
    private var historyBaseline = 0
    private var practiceField: NSTextView?
    private var lastSnapshotKey = ""
    var onFinished: (() -> Void)?

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: settings.interfaceLanguage)
    }

    // MARK: - Жизненный цикл

    func showIfNeeded(force: Bool = false) {
        guard force || !settings.onboardingCompleted else { return }
        let snapshot = currentSnapshot()
        if !force && snapshot.granted.count == Permission.allCases.count
            && snapshot.modelReady
            && !settings.recentTranscriptEntries.isEmpty {
            // Всё уже настроено (обновление с прошлой версии) — не мешаем.
            settings.onboardingCompleted = true
            return
        }
        historyBaseline = settings.recentTranscriptEntries.count
        step = force ? .welcome : firstIncompleteStep(snapshot)
        presentWindow()
        startTimer()
    }

    func close(markCompleted: Bool) {
        timer?.invalidate()
        timer = nil
        if markCompleted {
            settings.onboardingCompleted = true
        }
        window?.close()
        window = nil
        onFinished?()
    }

    private func firstIncompleteStep(_ snapshot: OnboardingSnapshot) -> OnboardingStep {
        if snapshot.granted.count < Permission.allCases.count { return .welcome }
        if !snapshot.modelReady { return .model }
        return .practice
    }

    private func presentWindow() {
        if window == nil {
            let window = OnboardingWindow(
                contentRect: NSRect(x: 0, y: 0, width: Self.cardWidth, height: 420),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            self.window = window
        }
        renderCurrentStep()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        _ = settings.refreshFromDisk()
        let snapshot = currentSnapshot()

        // Автопереходы по реальному состоянию.
        switch step {
        case .permissions:
            if snapshot.granted.count == Permission.allCases.count {
                step = snapshot.modelReady ? .practice : .model
            }
        case .model:
            if snapshot.modelReady { step = .practice }
        case .practice:
            if snapshot.practiceDone {
                renderCurrentStep()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                    self?.close(markCompleted: true)
                }
                timer?.invalidate()
                timer = nil
                return
            }
        case .welcome:
            break
        }

        let key = snapshotKey(snapshot)
        if key != lastSnapshotKey {
            lastSnapshotKey = key
            renderCurrentStep()
        }
    }

    private func snapshotKey(_ snapshot: OnboardingSnapshot) -> String {
        [String(step.rawValue),
         snapshot.granted.map(\.rawValue).sorted().joined(separator: ","),
         snapshot.modelReady ? "1" : "0",
         snapshot.downloadFraction.map { String(format: "%.2f", $0) } ?? "-",
         snapshot.practiceDone ? "1" : "0"].joined(separator: "|")
    }

    private func currentSnapshot() -> OnboardingSnapshot {
        let runtime = AgentRuntimeStateStore.read()
        let entries = settings.recentTranscriptEntries
        let practiced = entries.count > historyBaseline
        var dictated: String?
        if practiced, let latest = entries.first {
            dictated = latest.text
        }
        return OnboardingSnapshot(
            granted: Set(Permission.allCases.filter { Permissions.isGranted($0) }),
            modelReady: runtime?.speechModelReady ?? false,
            downloadFraction: runtime?.downloadProgressFraction,
            hotkeyCaps: keycapLabels(for: settings.configuredHotkey,
                                     language: settings.interfaceLanguage),
            dictatedText: dictated,
            practiceDone: practiced,
            language: settings.interfaceLanguage
        )
    }

    // MARK: - Рендер

    private func renderCurrentStep() {
        guard let window else { return }
        let snapshot = currentSnapshot()
        let card = OnboardingCardBuilder(language: settings.interfaceLanguage)
        let view = card.makeCard(step: step, snapshot: snapshot, controller: self)
        window.contentView = view
        let height = OnboardingCardBuilder.fittingHeight(for: view)
        let topY = window.frame.maxY
        window.setContentSize(NSSize(width: Self.cardWidth, height: height))
        var frame = window.frame
        frame.origin.y = topY - frame.height
        window.setFrame(frame, display: true)
        practiceField = card.practiceField
    }

    // MARK: - Действия шагов

    @objc func startClicked(_ sender: NSButton) {
        let snapshot = currentSnapshot()
        step = snapshot.granted.count < Permission.allCases.count
            ? .permissions
            : (snapshot.modelReady ? .practice : .model)
        renderCurrentStep()
    }

    @objc func grantClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        Permissions.request(Permission.allCases[sender.tag])
    }

    @objc func skipClicked(_ sender: NSButton) {
        close(markCompleted: true)
    }
}

// MARK: - Сборка карточки (общая для приложения и превью)

@MainActor
final class OnboardingCardBuilder {
    private let language: InterfaceLanguage
    private(set) var practiceField: NSTextView?

    init(language: InterfaceLanguage) {
        self.language = language
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    static func fittingHeight(for card: NSView) -> CGFloat {
        guard let stack = card.subviews.first as? NSStackView else { return 420 }
        let pin = stack.widthAnchor.constraint(
            equalToConstant: OnboardingController.cardWidth)
        pin.isActive = true
        stack.layoutSubtreeIfNeeded()
        let height = stack.fittingSize.height
        pin.isActive = false
        return ceil(height)
    }

    func makeCard(step: OnboardingStep,
                  snapshot: OnboardingSnapshot,
                  controller: OnboardingController?) -> NSView {
        // Макет: карточка #F8F7F4, радиус 12, padding 26px 26px 22px.
        let card = PaperBackgroundView()
        card.fill = SD.C.onboardingPaper
        card.cornerRadius = 12
        card.wantsLayer = true
        card.layer?.cornerRadius = 12
        card.layer?.masksToBounds = true

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 22, right: 26)
        stack.translatesAutoresizingMaskIntoConstraints = false

        switch step {
        case .welcome:
            buildWelcome(into: stack, controller: controller)
        case .permissions:
            buildPermissions(into: stack, snapshot: snapshot, controller: controller)
        case .model:
            buildModel(into: stack, snapshot: snapshot, controller: controller)
        case .practice:
            buildPractice(into: stack, snapshot: snapshot, controller: controller)
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: OnboardingController.cardWidth),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        let contentWidth = OnboardingController.cardWidth - 52
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalToConstant: contentWidth).isActive = true
        }
        return card
    }

    // MARK: Шаг 1 — приветствие

    private func buildWelcome(into stack: NSStackView, controller: OnboardingController?) {
        let icon = OnboardingIconView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        let iconRow = NSStackView(views: [icon, NSView()])
        iconRow.orientation = .horizontal
        stack.addArrangedSubview(iconRow)
        stack.setCustomSpacing(16, after: iconRow)

        // Макет: 19/700 с трекингом -.01em.
        let title = NSTextField(labelWithString: "")
        title.attributedStringValue = NSAttributedString(
            string: t("Диктуйте в любое поле ввода", "Dictate into any text field"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 19, weight: .bold),
                .foregroundColor: SD.C.ink,
                .kern: -0.19,
            ])
        title.maximumNumberOfLines = 0
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(6, after: title)

        let body = onboardingBody(
            t("Один хоткей — и ваша речь становится текстом там, где стоит курсор. Всё распознаётся на этом Mac, голос никуда не отправляется.",
              "One hotkey — and your speech becomes text right where the caret is. Everything is transcribed on this Mac; your voice never leaves it."),
            size: 12.5)
        stack.addArrangedSubview(body)
        stack.setCustomSpacing(20, after: body)

        let button = SDSolidButton(title: t("Настроить за минуту", "Set up in a minute"),
                                   target: controller,
                                   action: #selector(OnboardingController.startClicked(_:)))
        button.isBordered = false
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        let width = ceil(button.title.size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold)
        ]).width)
        button.widthAnchor.constraint(equalToConstant: width + 36).isActive = true
        button.restyle()
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(footerRow(dots: dotsView(active: 0), trailing: button))
    }

    // MARK: Шаг 2 — права

    private func buildPermissions(into stack: NSStackView,
                                  snapshot: OnboardingSnapshot,
                                  controller: OnboardingController?) {
        addTitle(t("Три разрешения macOS", "Three macOS permissions"), to: stack)
        addSubtitle(t("Каждое — по одной причине. Выдаются по очереди.",
                      "Each for a single reason. Granted one by one."), to: stack, after: 14)

        let names: [Permission: (String, String)] = [
            .microphone: (t("Микрофон", "Microphone"),
                          t("Слышать вашу речь", "To hear your speech")),
            .accessibility: (t("Универсальный доступ", "Accessibility"),
                             t("Вставлять текст в активное поле", "To insert text into the active field")),
            .inputMonitoring: (t("Мониторинг ввода", "Input Monitoring"),
                               t("Ловить хоткей в любом приложении", "To catch the hotkey in any app")),
        ]
        // Активный шаг — первый невыданный; всё после него приглушено.
        let firstMissing = Permission.allCases.firstIndex { !snapshot.granted.contains($0) }
        for (index, permission) in Permission.allCases.enumerated() {
            let granted = snapshot.granted.contains(permission)
            let isActive = index == firstMissing
            let row = permissionRow(index: index,
                                    title: names[permission]?.0 ?? permission.rawValue,
                                    detail: names[permission]?.1 ?? "",
                                    granted: granted,
                                    active: isActive,
                                    hairline: index < Permission.allCases.count - 1,
                                    controller: controller)
            if !granted && !isActive {
                row.alphaValue = 0.45
            }
            stack.addArrangedSubview(row)
        }

        let note = onboardingBody(
            t("Кнопка открывает нужную панель Системных настроек сразу на месте — без поиска по списку.",
              "The button opens the exact System Settings pane — no digging through lists."),
            size: 11)
        note.alignment = .left
        let spacer = NSView()
        stack.addArrangedSubview(spacer)
        stack.setCustomSpacing(14, after: spacer)
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(14, after: note)
        stack.addArrangedSubview(footerRow(dots: dotsView(active: 1), trailing: nil))
    }

    private func permissionRow(index: Int,
                               title: String,
                               detail: String,
                               granted: Bool,
                               active: Bool,
                               hairline: Bool,
                               controller: OnboardingController?) -> NSView {
        let badge = OnboardingStepBadge(number: index + 1, granted: granted, active: active)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 22).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = SD.C.ink
        let detailLabel = NSTextField(labelWithString: detail)
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = SD.C.subtle
        let text = NSStackView(views: [titleLabel, detailLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1

        var views: [NSView] = [badge, text, NSView()]
        if granted {
            let done = NSTextField(labelWithString: t("Выдано", "Granted"))
            done.font = .systemFont(ofSize: 11, weight: .semibold)
            done.textColor = NSColor(hex: 0x4CA35A)
            views.append(done)
        } else if active {
            let grant = SDSolidButton(title: t("Выдать…", "Grant…"),
                                      target: controller,
                                      action: #selector(OnboardingController.grantClicked(_:)))
            grant.isBordered = false
            grant.tag = index
            grant.translatesAutoresizingMaskIntoConstraints = false
            grant.heightAnchor.constraint(equalToConstant: 24).isActive = true
            let width = ceil(grant.title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
            ]).width)
            grant.widthAnchor.constraint(equalToConstant: width + 18).isActive = true
            grant.restyle()
            grant.layer?.cornerRadius = 7
            grant.font = .systemFont(ofSize: 12, weight: .semibold)
            views.append(grant)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        if hairline {
            let wrapper = NSStackView(views: [row, SDHairlineView()])
            wrapper.orientation = .vertical
            wrapper.alignment = .leading
            wrapper.spacing = 0
            row.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
            return wrapper
        }
        return row
    }

    // MARK: Шаг 3 — модель

    private func buildModel(into stack: NSStackView,
                            snapshot: OnboardingSnapshot,
                            controller: OnboardingController?) {
        addTitle(t("Скачиваем модель распознавания", "Downloading the speech model"), to: stack)
        addSubtitle(t("Единственный раз, когда нужен интернет.",
                      "The only time the internet is needed."), to: stack, after: 16)

        let fraction = snapshot.modelReady ? 1 : (snapshot.downloadFraction ?? 0)
        let card = OnboardingProgressCard(
            title: "Parakeet TDT v3 · RU + EN",
            percent: Int((fraction * 100).rounded()),
            fraction: CGFloat(fraction),
            leftNote: t("~460 МБ · один раз", "~460 MB · once"),
            rightNote: snapshot.modelReady
                ? t("готово", "done")
                : (snapshot.downloadFraction == nil
                    ? t("ждём службу…", "waiting for the service…")
                    : t("качается…", "downloading…"))
        )
        stack.addArrangedSubview(card)
        stack.setCustomSpacing(12, after: card)

        let note = onboardingBody(
            t("Пока качается — можно закрыть это окно. Позовём, когда всё будет готово: глиф в меню-баре покажет прогресс.",
              "You can close this window while it downloads. We'll let you know — the menu bar glyph shows progress."),
            size: 11.5)
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(20, after: note)

        let hint = NSTextField(labelWithString: t("Дальше — после загрузки", "Next — after the download"))
        hint.font = .systemFont(ofSize: 12)
        hint.textColor = SD.C.subtle
        stack.addArrangedSubview(footerRow(dots: dotsView(active: 2), trailing: hint))
    }

    // MARK: Шаг 4 — попробуйте прямо здесь

    private func buildPractice(into stack: NSStackView,
                               snapshot: OnboardingSnapshot,
                               controller: OnboardingController?) {
        addTitle(t("Попробуйте прямо здесь", "Try it right here"), to: stack)

        // Подзаголовок с кейкапами хоткея.
        let sub = NSStackView()
        sub.orientation = .horizontal
        sub.alignment = .centerY
        sub.spacing = 5
        let hold = NSTextField(labelWithString: t("Зажмите", "Hold"))
        hold.font = .systemFont(ofSize: 12)
        hold.textColor = SD.C.graphite
        sub.addArrangedSubview(hold)
        for (index, cap) in snapshot.hotkeyCaps.enumerated() {
            if index > 0 {
                let plus = NSTextField(labelWithString: "+")
                plus.font = .systemFont(ofSize: 12)
                plus.textColor = SD.C.graphite
                sub.addArrangedSubview(plus)
            }
            let capLabel = NSTextField(labelWithString: cap)
            capLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
            capLabel.textColor = SD.C.ink
            sub.addArrangedSubview(capLabel)
        }
        let say = NSTextField(labelWithString: t("и скажите пару слов.", "and say a few words."))
        say.font = .systemFont(ofSize: 12)
        say.textColor = SD.C.graphite
        sub.addArrangedSubview(say)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(16, after: sub)

        let field = OnboardingPracticeField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        if let text = snapshot.dictatedText {
            field.textView.string = text
        }
        practiceField = field.textView
        stack.addArrangedSubview(field)
        stack.setCustomSpacing(16, after: field)

        let note = onboardingBody(
            snapshot.practiceDone
                ? t("Готово. Так это работает везде — в любом приложении, где есть курсор.",
                    "Done. That's how it works everywhere — in any app with a caret.")
                : t("Слова появятся в поле после отпускания хоткея. Сработало — этот шаг закроется сам.",
                    "Words appear in the field once you release the hotkey. When it works, this step closes itself."),
            size: 11.5)
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(20, after: note)

        let skip = NSButton(title: t("Пропустить — я разберусь", "Skip — I'll figure it out"),
                            target: controller,
                            action: #selector(OnboardingController.skipClicked(_:)))
        skip.isBordered = false
        skip.font = .systemFont(ofSize: 12)
        skip.contentTintColor = SD.C.subtle
        stack.addArrangedSubview(footerRow(dots: dotsView(active: 3), trailing: skip))
    }

    // MARK: Общие куски

    private func addTitle(_ text: String, to stack: NSStackView) {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 16, weight: .bold)
        title.textColor = SD.C.ink
        title.maximumNumberOfLines = 0
        stack.addArrangedSubview(title)
        stack.setCustomSpacing(4, after: title)
    }

    private func addSubtitle(_ text: String, to stack: NSStackView, after: CGFloat) {
        let sub = onboardingBody(text, size: 12)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(after, after: sub)
    }

    private func onboardingBody(_ text: String, size: CGFloat) -> NSTextField {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = 1.25
        let label = NSTextField(labelWithString: "")
        label.attributedStringValue = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: size),
                .foregroundColor: SD.C.graphite,
                .paragraphStyle: paragraph,
            ])
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private func dotsView(active: Int) -> NSView {
        let dots = OnboardingDotsView(count: OnboardingStep.allCases.count, active: active)
        dots.translatesAutoresizingMaskIntoConstraints = false
        dots.widthAnchor.constraint(equalToConstant: 6 * 4 + 5 * 3).isActive = true
        dots.heightAnchor.constraint(equalToConstant: 6).isActive = true
        return dots
    }

    private func footerRow(dots: NSView, trailing: NSView?) -> NSView {
        var views: [NSView] = [dots, NSView()]
        if let trailing {
            views.append(trailing)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)
        return row
    }
}

// MARK: - Иконка приветствия (тёмный скруглённый квадрат + волна)

final class OnboardingIconView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        let gradient = NSGradient(starting: NSColor(hex: 0x2B2A27),
                                  ending: NSColor(hex: 0x1C1B19))
        gradient?.draw(in: path, angle: -90)
        // Волна из пяти баров, как VoiceLineGlyph, но крупнее и коралловая.
        let bars: [CGFloat] = [0.35, 0.65, 1.0, 0.55, 0.4]
        let barWidth: CGFloat = 3.5
        let gap: CGFloat = 3
        let maxHeight: CGFloat = 24
        let totalWidth = CGFloat(bars.count) * barWidth + CGFloat(bars.count - 1) * gap
        let startX = (bounds.width - totalWidth) / 2
        SD.C.voiceDark.setFill()
        for (index, value) in bars.enumerated() {
            let height = max(4, value * maxHeight)
            let rect = NSRect(x: startX + CGFloat(index) * (barWidth + gap),
                              y: bounds.midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

// MARK: - Кружок шага прав (✓ / номер)

final class OnboardingStepBadge: NSView {
    private let number: Int
    private let granted: Bool
    private let active: Bool

    init(number: Int, granted: Bool, active: Bool) {
        self.number = number
        self.granted = granted
        self.active = active
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let circle = NSBezierPath(ovalIn: bounds)
        let text: String
        let textColor: NSColor
        let font: NSFont
        if granted {
            NSColor(hex: 0x4CA35A).setFill()
            circle.fill()
            text = "✓"
            textColor = .white
            font = .systemFont(ofSize: 11, weight: .semibold)
        } else if active {
            SD.C.voice.withAlphaComponent(0.12).setFill()
            circle.fill()
            text = "\(number)"
            textColor = SD.C.voice
            font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        } else {
            (dark ? NSColor.white.withAlphaComponent(0.1)
                  : NSColor.black.withAlphaComponent(0.08)).setFill()
            circle.fill()
            text = "\(number)"
            textColor = SD.C.graphite
            font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor]
        let size = text.size(withAttributes: attrs)
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2,
                              y: bounds.midY - size.height / 2),
                  withAttributes: attrs)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Точки прогресса онбординга

final class OnboardingDotsView: NSView {
    private let count: Int
    private let active: Int

    init(count: Int, active: Int) {
        self.count = count
        self.active = active
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        for index in 0..<count {
            let rect = NSRect(x: CGFloat(index) * 11, y: bounds.midY - 3, width: 6, height: 6)
            if index == active {
                SD.C.ink.setFill()
            } else {
                (dark ? NSColor.white.withAlphaComponent(0.2)
                      : NSColor.black.withAlphaComponent(0.15)).setFill()
            }
            NSBezierPath(ovalIn: rect).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Карточка прогресса модели

final class OnboardingProgressCard: NSView {
    private let fraction: CGFloat

    init(title: String, percent: Int, fraction: CGFloat,
         leftNote: String, rightNote: String) {
        self.fraction = max(0, min(1, fraction))
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = SD.C.ink
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let percentLabel = NSTextField(labelWithString: "\(percent)%")
        percentLabel.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        percentLabel.textColor = SD.C.voice
        let top = NSStackView(views: [titleLabel, NSView(), percentLabel])
        top.orientation = .horizontal
        top.alignment = .firstBaseline

        let bar = OnboardingProgressBar(fraction: self.fraction)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let left = NSTextField(labelWithString: leftNote)
        let right = NSTextField(labelWithString: rightNote)
        for label in [left, right] {
            label.font = .systemFont(ofSize: 10.5)
            label.textColor = SD.C.subtle
        }
        let bottom = NSStackView(views: [left, NSView(), right])
        bottom.orientation = .horizontal

        let stack = NSStackView(views: [top, bar, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setCustomSpacing(10, after: top)
        stack.setCustomSpacing(7, after: bar)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        for view in [top, bar, bottom] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = dark
            ? NSColor.white.withAlphaComponent(0.05).cgColor
            : NSColor.white.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = dark
            ? NSColor.white.withAlphaComponent(0.1).cgColor
            : NSColor.black.withAlphaComponent(0.07).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

final class OnboardingProgressBar: NSView {
    private let fraction: CGFloat

    init(fraction: CGFloat) {
        self.fraction = fraction
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.isDark
        let track = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        (dark ? NSColor.white.withAlphaComponent(0.1)
              : NSColor.black.withAlphaComponent(0.07)).setFill()
        track.fill()
        guard fraction > 0 else { return }
        let fillRect = NSRect(x: 0, y: 0,
                              width: max(4, bounds.width * fraction),
                              height: bounds.height)
        SD.C.voice.setFill()
        NSBezierPath(roundedRect: fillRect, xRadius: 2, yRadius: 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Поле для тренировочной диктовки

final class OnboardingPracticeField: NSView {
    let textView = NSTextView()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8

        textView.font = .systemFont(ofSize: 13)
        textView.textColor = SD.C.ink
        textView.backgroundColor = .clear
        textView.insertionPointColor = SD.C.voiceLight
        textView.isRichText = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        restyle()
    }

    required init?(coder: NSCoder) { nil }

    private func restyle() {
        let dark = effectiveAppearance.isDark
        layer?.backgroundColor = dark
            ? NSColor.white.withAlphaComponent(0.06).cgColor
            : NSColor.white.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = dark
            ? NSColor.white.withAlphaComponent(0.12).cgColor
            : NSColor.black.withAlphaComponent(0.1).cgColor
        textView.insertionPointColor = dark ? SD.C.voiceDark : SD.C.voiceLight
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

// MARK: - Превью онбординга (для визуальной сверки с макетом 2d)

@MainActor
func exportOnboardingPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.colorSpace = .sRGB
    var exported = 0
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        for step in OnboardingStep.allCases {
            let snapshot = OnboardingSnapshot(
                granted: step == .permissions ? [.microphone] : Set(Permission.allCases),
                modelReady: step.rawValue > OnboardingStep.model.rawValue,
                downloadFraction: step == .model ? 0.62 : nil,
                hotkeyCaps: ["⌘", "⌥ прав."],
                dictatedText: step == .practice ? "Привет, это моя первая диктовка" : nil,
                practiceDone: false,
                language: .russian
            )
            let builder = OnboardingCardBuilder(language: .russian)
            let card = builder.makeCard(step: step, snapshot: snapshot, controller: nil)
            let height = OnboardingCardBuilder.fittingHeight(for: card)
            window.setContentSize(NSSize(width: OnboardingController.cardWidth,
                                         height: height))
            card.frame = NSRect(x: 0, y: 0,
                                width: OnboardingController.cardWidth, height: height)
            window.contentView = card
            card.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else {
                throw SettingsPreviewExportError(message: "no bitmap rep for onboarding")
            }
            card.cacheDisplay(in: card.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SettingsPreviewExportError(message: "PNG encode failed for onboarding")
            }
            try png.write(
                to: directory.appendingPathComponent("onboarding-\(step.rawValue + 1)-\(suffix).png"),
                options: .atomic)
            exported += 1
        }
    }
    window.contentView = nil
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("ONBOARDING_PREVIEW exported \(exported) files to \(directory.path)")
}
