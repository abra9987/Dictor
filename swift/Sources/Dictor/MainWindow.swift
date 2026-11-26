import AppKit

// Главное окно (макеты 6a/6b дизайн-проекта).
// Окно 980×664: слева сайдбар 212pt с навигацией и статусом службы,
// справа — раздел. «Сегодня» открывается первым.
//
// Тёмные пары поверхностей выведены (SDTheme.swift): тёрн 6 нарисован
// только в светлой теме, тёмная стоит следующей задачей в макете.

/// Макеты 6a/7a: окно 980×720, сайдбар 212, шапка раздела 52.
let MAIN_WINDOW_SIZE = NSSize(width: 980, height: 720)
let MAIN_WINDOW_SIDEBAR_WIDTH: CGFloat = 212
let MAIN_WINDOW_HEADER_HEIGHT: CGFloat = 52

enum MainWindowSection: String, CaseIterable {
    case today
    case history
    case stats
    case dictionary
    case settings

    func title(_ language: InterfaceLanguage) -> String {
        switch self {
        case .today: return localizedText("Сегодня", "Today", language: language)
        case .history: return localizedText("История", "History", language: language)
        case .stats: return localizedText("Статистика", "Statistics", language: language)
        case .dictionary: return localizedText("Словарь", "Dictionary", language: language)
        case .settings: return localizedText("Настройки", "Settings", language: language)
        }
    }

    /// Иконка пункта. У «Сегодня» в макете вместо символа — волна.
    ///
    /// SF Symbols, а не текстовые глифы (≡, ▨, Aa, ⚙): у случайных символов
    /// Юникода метрики свои у каждого — знак сидит в своей коробке то выше,
    /// то ниже, и центрируется коробка, а не сам знак. В ряду это читалось
    /// как «иконки не напротив текста», и размер у них гулял. У символов
    /// метрики общие и заданы под шрифт рядом.
    var symbolName: String? {
        switch self {
        case .today: return nil
        case .history: return "clock.arrow.circlepath"
        case .stats: return "chart.bar.fill"
        case .dictionary: return "character.book.closed.fill"
        case .settings: return "gearshape.fill"
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
        if let symbolName = section.symbolName {
            let view = NSImageView()
            // Кегль символа берётся от подписи рядом (13.5): SF Symbols
            // размечены под шрифт, и заданный так знак совпадает с текстом
            // и по росту, и по весу. Прежние 13 pt в поле высотой 14
            // обрезали знак и делали его мельче подписи.
            view.image = NSImage(systemSymbolName: symbolName,
                                 accessibilityDescription: title)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(
                    pointSize: 13.5,
                    weight: isSelected ? .semibold : .regular))
            view.contentTintColor = isSelected ? SD.C.ink : SD.C.graphite
            view.imageScaling = .scaleNone
            icon = view
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
            icon.heightAnchor.constraint(equalToConstant: 18),
            // Иконка равняется по подписи, а не по строке: у строки высота
            // 34 pt, и центр у неё свой — совпадение с текстом получалось
            // случайно и держалось только пока текст ровно посередине.
            icon.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
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

// MARK: - Брендовая эмаль

/// Три размытых цветных пятна, очень медленно плавающих под текстом подсказки
/// (макет 8d). Смысл — в скорости: периоды 20, 27 и 34 секунды взаимно не
/// кратны, поэтому рисунок не повторяется заметно, а движение видно, только
/// если задержать взгляд на несколько секунд. Это фон, а не индикатор.
///
/// В макете отдельно оговорено, чего здесь быть не должно: ни three.js, ни
/// WebGL — «это два-три размытых пятна», и WebGL-контекст в приложении,
/// которое обязано быть незаметным, стоил бы десятков мегабайт памяти и
/// постоянной работы GPU. Здесь три `CAGradientLayer` типа `.radial` и
/// `CABasicAnimation` на `transform`: композитные свойства, ноль перерисовки.
final class SDEnamelView: NSView {
    /// Пятно в долях собственного размера. Координаты — как в CSS, сверху
    /// вниз; при переносе в слой ось Y переворачивается.
    private struct Blob {
        let color: NSColor
        /// Центр эллипса: `at 24% 46%` в градиенте.
        let center: CGPoint
        /// Радиусы эллипса: `52% 66%` — доли ширины и высоты слоя.
        let radius: CGSize
        let blur: CGFloat
        /// Одна сторона хода. `alternate` в CSS = `autoreverses` здесь,
        /// поэтому полный цикл вдвое длиннее.
        let duration: CFTimeInterval
        let fromOffset: CGPoint
        let fromScale: CGFloat
        let toOffset: CGPoint
        let toScale: CGFloat
    }

    /// Значения перенесены из макета числом в число.
    private static let blobs: [Blob] = [
        Blob(color: SD.C.enamelAccent,
             center: CGPoint(x: 0.24, y: 0.46), radius: CGSize(width: 0.52, height: 0.66),
             blur: 16, duration: 20,
             fromOffset: CGPoint(x: -0.16, y: -0.14), fromScale: 1.08,
             toOffset: CGPoint(x: 0.18, y: 0.12), toScale: 1.40),
        Blob(color: SD.C.enamelGreen,
             center: CGPoint(x: 0.74, y: 0.58), radius: CGSize(width: 0.46, height: 0.58),
             blur: 18, duration: 27,
             fromOffset: CGPoint(x: 0.20, y: 0.13), fromScale: 1.32,
             toOffset: CGPoint(x: -0.17, y: -0.12), toScale: 1.0),
        // Третий слой идёт тем же ходом, но с другого конца
        // (`alternate-reverse`): иначе он повторял бы движение второго.
        Blob(color: SD.C.enamelWarm,
             center: CGPoint(x: 0.54, y: 0.24), radius: CGSize(width: 0.40, height: 0.52),
             blur: 20, duration: 34,
             fromOffset: CGPoint(x: -0.17, y: -0.12), fromScale: 1.0,
             toOffset: CGPoint(x: 0.20, y: 0.13), toScale: 1.32),
    ]

    private var blobLayers: [CAGradientLayer] = []
    private var occlusionObserver: NSObjectProtocol?
    private var lastLaidOutSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        build()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Слои живут в собственных координатах слоя-хозяина, а он вдвое
        // больше плашки: пятну нужно место, чтобы уезжать за край, а не
        // упираться в него.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in blobLayers { layer.frame = bounds }
        CATransaction.commit()
        // Смещения в макете заданы долями собственного размера, поэтому до
        // первой раскладки считать их не из чего: при нулевых bounds пятно
        // осталось бы в центре плашки во всю силу цвета — вместо периферии,
        // которая только и должна быть видна.
        guard bounds.size != lastLaidOutSize else { return }
        lastLaidOutSize = bounds.size
        applyMotion()
    }

    private func build() {
        blobLayers.forEach { $0.removeFromSuperlayer() }
        blobLayers = []
        for blob in Self.blobs {
            let gradient = CAGradientLayer()
            gradient.type = .radial
            // Цвет резолвим через тему вида: динамический NSColor отдал бы
            // `.cgColor` под тему приложения, и в тёмной эмаль вышла бы светлой.
            let color = resolvedCGColor(blob.color)
            gradient.colors = [color, color.copy(alpha: 0) ?? color]
            // `transparent 70%` из макета: к 70 % радиуса цвет сходит на нет.
            gradient.locations = [0, 0.7]
            gradient.startPoint = CGPoint(x: blob.center.x, y: 1 - blob.center.y)
            gradient.endPoint = CGPoint(x: blob.center.x + blob.radius.width,
                                        y: 1 - blob.center.y + blob.radius.height)
            gradient.frame = bounds
            if let filter = CIFilter(name: "CIGaussianBlur",
                                     parameters: [kCIInputRadiusKey: blob.blur]) {
                gradient.filters = [filter]
            }
            layer?.addSublayer(gradient)
            blobLayers.append(gradient)
        }
        applyMotion()
    }

    private func transform(offset: CGPoint, scale: CGFloat) -> CATransform3D {
        // Проценты — от собственного размера слоя, как в CSS. Ось Y
        // перевёрнута: в слое положительное смещение идёт вверх.
        let translated = CATransform3DMakeTranslation(offset.x * bounds.width,
                                                      -offset.y * bounds.height,
                                                      0)
        return CATransform3DScale(translated, scale, scale, 1)
    }

    private func applyMotion() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Пока вида нет на экране или окно закрыто чужими, двигать нечего:
        // считать кадры в невидимой плашке — плата без покупки.
        let visible = window != nil && (window?.occlusionState.contains(.visible) ?? false)
        for (index, layer) in blobLayers.enumerated() {
            let blob = Self.blobs[index]
            layer.removeAnimation(forKey: "enamel")
            guard !reduceMotion, visible else {
                // Reduce Motion оставляет слои на месте: эмаль просто
                // перестаёт быть живой — так в макете и написано.
                layer.transform = transform(offset: blob.fromOffset, scale: blob.fromScale)
                continue
            }
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: transform(offset: blob.fromOffset,
                                                                   scale: blob.fromScale))
            animation.toValue = NSValue(caTransform3D: transform(offset: blob.toOffset,
                                                                 scale: blob.toScale))
            animation.duration = blob.duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0.05, 0.55, 0.95)
            layer.add(animation, forKey: "enamel")
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
            self.occlusionObserver = nil
        }
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.applyMotion() }
                }
        }
        applyMotion()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        build()
    }
}

// MARK: - Плашка подсказки

/// Одна подсказка внизу «Сегодня». Правило из макета 6e: одна на экране,
/// закрыли — больше не возвращается. Под текстом — брендовая эмаль (макет 8d):
/// подсказка единственное место в окне, где ей есть место. В подвале сайдбара
/// и в шапке панели её быть не должно — там движется индикатор состояния, и
/// движущихся элементов должно остаться ровно один.
final class SDHintBannerView: NSView {
    init(text: String,
         actionTitle: String?,
         target: AnyObject?,
         action: Selector?,
         dismissAction: Selector?) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        // Эмаль уезжает за край плашки — без обрезки пятна вылезли бы на
        // бумагу раздела.
        layer?.masksToBounds = true

        let enamel = SDEnamelView()
        enamel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(enamel)

        let wave = SDMiniWaveView(values: [0.09, 0.09, 0.09, 0.3, 0.09, 0.09, 0.09],
                                  color: SD.C.subtle,
                                  barWidth: 2,
                                  gap: 2)
        wave.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = SD.C.enamelInk
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
            // Акцентная ссылка поверх акцентного пятна перестала бы читаться —
            // поэтому на шаг темнее в светлой теме и на шаг светлее в тёмной.
            button.contentTintColor = SD.C.enamelVoice
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }
        if let dismissAction {
            let close = NSButton(title: "×", target: target, action: dismissAction)
            close.isBordered = false
            close.font = .systemFont(ofSize: 14)
            close.contentTintColor = SD.C.enamelSubtle
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
            // Слой эмали вдвое больше плашки и центрирован по ней — это
            // `inset: -50 %` из макета: пятну нужно куда уезжать.
            enamel.centerXAnchor.constraint(equalTo: centerXAnchor),
            enamel.centerYAnchor.constraint(equalTo: centerYAnchor),
            enamel.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 2),
            enamel.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 2),
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
        let dayBars = dictationUsageBarFractions(weekCharacters)

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
