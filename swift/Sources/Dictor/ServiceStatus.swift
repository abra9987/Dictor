import AppKit

// Состояние службы диктовки — то, что человек читает, пока приложение ещё не
// готово (макет 8, тёрн «Статус службы»).
//
// До этого состояний было два: «Готово к диктовке» и «Служба остановлена».
// Между ними умещались проверка двадцати одного файла модели, её загрузка при
// первой установке, прогрев и обновление приложения — и всё это выглядело
// одинаково: как будто сломалось. Хуже всего было после обновления, когда
// служба поднимается заново: человек видел «Остановлена» и не знал, ждать ему
// или чинить.
//
// Макет разводит девять состояний по трём признакам:
//   идёт работа (2–5)  — маркер-волна, движение, ни одной кнопки;
//   нужен человек (7–8) — квадрат, ничего не движется, есть кнопка;
//   выключено (9)      — пустое кольцо, приглушённый серый, кнопки нет.
// Кнопка есть только там, где требуется человек: она и есть сигнал.

enum ServiceStatusKind: Equatable {
    /// 1 · Готово. Единственное состояние без движения — потому что ничего и
    /// не происходит, и это хорошая новость.
    case ready(latencyMilliseconds: Int?)
    /// 2 · Служба запускается.
    case starting
    /// 3 · Проверка файлов модели.
    case verifying(done: Int, total: Int)
    /// 4 · Скачивание модели. Доля есть, объём в мегабайтах — нет: FluidAudio
    /// отдаёт только число файлов, а выдуманные мегабайты хуже их отсутствия.
    case downloading(fraction: Double?, files: Int?, totalFiles: Int?)
    /// 5 · Прогрев. Визуально то же, что 2 — 0,2 с человек не читает.
    case warmingUp
    /// 6 · Обновление приложения. Та же волна, но в 1,8 раза медленнее.
    case updating
    /// 7 · Нет разрешений.
    case needsPermission(name: String)
    /// 8 · Ошибка.
    case failed
    /// 9 · Выключена намеренно. Не поломка, поэтому ни кнопки, ни движения.
    case off

    /// Признак «идёт работа»: маркер-волна и запрет на кнопки.
    var isBusy: Bool {
        switch self {
        case .starting, .verifying, .downloading, .warmingUp, .updating: return true
        case .ready, .needsPermission, .failed, .off: return false
        }
    }

    /// Обновление живёт в своём ритме: 1,62 с против 0,9 с у остальных.
    /// «Это не ваша спешка» — так в макете.
    var waveIsSlow: Bool { self == .updating }
}

/// Что показывать в подвале сайдбара: две строки, необязательный прогресс и
/// необязательные кнопки. Собирается один раз, чтобы окно и панель говорили
/// одними словами.
struct ServiceStatusPresentation {
    let title: String
    let subtitle: String
    /// Доля 0…1 для сплошной полосы, nil — полосы нет.
    var progressFraction: Double?
    /// «Засечки»: сколько из скольких. Макет рисует 21 засечку по числу файлов
    /// модели — доля в процентах здесь понятнее не делает.
    var ticks: (done: Int, total: Int)?
    var primaryAction: String?
    var secondaryAction: String?
    /// Заголовок жирный и максимально контрастный только там, где нужен
    /// человек: вес — это сигнал, а не украшение.
    var wantsAttention: Bool = false
}

func serviceStatusPresentation(_ kind: ServiceStatusKind,
                               language: InterfaceLanguage) -> ServiceStatusPresentation {
    func t(_ ru: String, _ en: String) -> String { localizedText(ru, en, language: language) }

    switch kind {
    case .ready(let latency):
        // Вторая строка называет модель и — если есть, что назвать — реальную
        // медиану отклика. Пока диктовок не было, числа нет и его не выдумываем.
        let detail = latency.map {
            t("Parakeet · локально · отклик \($0) мс",
              "Parakeet · on-device · \($0) ms latency")
        } ?? t("Parakeet · локально", "Parakeet · on-device")
        return .init(title: t("Готово к диктовке", "Ready to dictate"), subtitle: detail)

    case .starting:
        return .init(title: t("Служба запускается", "Starting the service"),
                     subtitle: t("обычно 1–3 секунды", "usually 1–3 seconds"))

    case .verifying(let done, let total):
        return .init(title: t("Проверяю файлы модели", "Checking model files"),
                     subtitle: t("\(done) из \(total) файлов", "\(done) of \(total) files"),
                     ticks: (done, total))

    case .downloading(let fraction, let files, let totalFiles):
        let percent = fraction.map { "\(Int(($0 * 100).rounded())) %" }
        let filesText: String? = {
            guard let files, let totalFiles, totalFiles > 0 else { return nil }
            return t("файл \(files) из \(totalFiles) · один раз",
                     "file \(files) of \(totalFiles) · one time")
        }()
        return .init(title: t("Скачиваю модель", "Downloading the model"),
                     subtitle: filesText ?? percent
                        ?? t("только при первой установке", "first install only"),
                     progressFraction: fraction)

    case .warmingUp:
        return .init(title: t("Служба запускается", "Starting the service"),
                     subtitle: t("поднимаю модель в память", "loading the model into memory"))

    case .updating:
        return .init(title: t("Обновляю приложение", "Updating the app"),
                     subtitle: t("диктовка вернётся сама", "dictation comes back on its own"))

    case .needsPermission(let name):
        return .init(title: t("Нужен доступ: \(name)", "Access needed: \(name)"),
                     subtitle: t("Диктовка ждёт разрешения", "Dictation is waiting for it"),
                     primaryAction: t("Открыть Настройки", "Open Settings"),
                     wantsAttention: true)

    case .failed:
        return .init(title: t("Служба не запустилась", "The service didn’t start"),
                     subtitle: t("Диктовка сейчас не работает", "Dictation is not working now"),
                     primaryAction: t("Запустить", "Start"),
                     secondaryAction: t("Подробнее", "Details"),
                     wantsAttention: true)

    case .off:
        return .init(title: t("Диктовка выключена", "Dictation is off"),
                     subtitle: t("включите тумблером в меню", "turn it on from the menu"))
    }
}

// MARK: - Маркер состояния

/// Маркер слева от заголовка: 7×7 в 16 px от края, всегда на одном месте.
/// Меняется только форма и движение — поэтому переключение состояний не
/// «дёргает» сайдбар.
final class ServiceStatusMarkerView: NSView {
    enum Shape: Equatable {
        case dot(NSColor)          // 1 · готово: залитый круг
        case wave(slow: Bool)      // 2–6 · идёт работа: пять столбиков
        case hollowSquare          // 7 · нужен человек: пустой квадрат
        case filledSquare(NSColor) // 8 · встало: залитый
        case hollowRing            // 9 · выключено: пустое кольцо
    }

    var shape: Shape = .dot(SD.C.positive) {
        didSet { if shape != oldValue { rebuild() } }
    }

    private var bars: [NSView] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        rebuild()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        // Волне нужно 5 столбиков по 2 px с зазором 1,5 — 17,5 в ширину и 11 в
        // высоту. Остальные формы — ровно 7×7 из макета: если дать им высоту
        // волны, круг и квадрат растянутся в овал и прямоугольник.
        if case .wave = shape { return NSSize(width: 17.5, height: 11) }
        return NSSize(width: 7, height: 7)
    }

    private func rebuild() {
        bars.forEach { $0.removeFromSuperview() }
        bars = []
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        layer?.backgroundColor = nil
        layer?.borderWidth = 0
        layer?.cornerRadius = 0
        invalidateIntrinsicContentSize()

        switch shape {
        case .dot(let color):
            layer?.cornerRadius = 3.5
            layer?.backgroundColor = resolvedCGColor(color)
        case .hollowSquare:
            layer?.cornerRadius = 1.5
            layer?.borderWidth = 1.5
            layer?.borderColor = resolvedCGColor(SD.C.ink)
        case .filledSquare(let color):
            layer?.cornerRadius = 1.5
            layer?.backgroundColor = resolvedCGColor(color)
        case .hollowRing:
            layer?.cornerRadius = 3.5
            layer?.borderWidth = 1.5
            layer?.borderColor = resolvedCGColor(SD.C.subtle)
        case .wave(let slow):
            buildWave(slow: slow)
        }
    }

    /// Пять столбиков, дышащих на месте: scaleY 0,3 → 1 за 0,9 с (или 1,62 с
    /// для обновления), ease-in-out, alternate, сдвиг по столбикам 0,08 с.
    /// По горизонтали ничего не едет — волна дышит, а не бежит.
    private func buildWave(slow: Bool) {
        let duration = slow ? 1.62 : 0.9
        let step = slow ? 0.14 : 0.08
        for index in 0..<5 {
            let bar = NSView()
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 1
            bar.layer?.backgroundColor = resolvedCGColor(SD.C.voice)
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.widthAnchor.constraint(equalToConstant: 2),
                bar.heightAnchor.constraint(equalToConstant: 11),
                bar.centerYAnchor.constraint(equalTo: centerYAnchor),
                bar.leadingAnchor.constraint(equalTo: leadingAnchor,
                                             constant: CGFloat(index) * 3.5),
            ])
            bars.append(bar)

            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                // Reduce Motion: волна замирает в среднем кадре — остаются
                // цвет и текст, которых достаточно.
                bar.layer?.transform = CATransform3DMakeScale(1, 0.65, 1)
                continue
            }
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = 0.3
            animation.toValue = 1.0
            animation.duration = duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.timeOffset = Double(index) * step
            bar.layer?.add(animation, forKey: "wave")
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }
}

/// Полоса засечек для проверки файлов: 21 деление, из них закрашено столько,
/// сколько файлов проверено. Проценты здесь ничего не добавляют — «17 из 21»
/// человек понимает сразу.
final class ServiceStatusTicksView: NSView {
    var done: Int = 0 { didSet { needsDisplay = true } }
    var total: Int = 21 { didSet { needsDisplay = true } }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        guard total > 0 else { return }
        let gap: CGFloat = 2.95
        let width = (bounds.width - gap * CGFloat(total - 1)) / CGFloat(total)
        guard width > 0 else { return }
        for index in 0..<total {
            let x = CGFloat(index) * (width + gap)
            let filled = index < done
            (filled ? SD.C.voice : SD.C.hairline).setFill()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: width, height: bounds.height)).fill()
        }
    }
}

/// Сплошная полоса загрузки. Растёт только вперёд: полоса, которая может
/// отступить, читается как ошибка.
final class ServiceStatusProgressView: NSView {
    private var shown: Double = 0
    var fraction: Double = 0 {
        didSet {
            shown = max(shown, min(max(fraction, 0), 1))
            needsDisplay = true
        }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 5) }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        SD.C.hairline.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        guard shown > 0 else { return }
        SD.C.voice.setFill()
        let filled = NSRect(x: 0, y: 0, width: bounds.width * CGFloat(shown), height: bounds.height)
        NSBezierPath(roundedRect: filled, xRadius: radius, yRadius: radius).fill()
    }
}

/// Подложка подвала. Заливка нужна ровно одному состоянию — отказу, — но
/// рисовать её приходится своим слоем: обычный NSView отдаёт `layer` без
/// разрешения перекрашиваться под сменой темы.
final class ServiceStatusFooterView: NSView {
    var fill: NSColor = .clear {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard fill != .clear else { return }
        fill.setFill()
        dirtyRect.fill()
    }
}

/// Рендер всех девяти состояний подвала — иначе проверить их нечем: семь из
/// девяти в обычной жизни либо не наступают, либо длятся полсекунды.
@MainActor
func exportServiceStatusPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let kinds: [(String, ServiceStatusKind)] = [
        ("1-ready", .ready(latencyMilliseconds: 180)),
        ("2-starting", .starting),
        ("3-verifying", .verifying(done: 17, total: 21)),
        ("4-downloading", .downloading(fraction: 0.69, files: 12, totalFiles: 21)),
        ("5-warmup", .warmingUp),
        ("6-updating", .updating),
        ("7-permission", .needsPermission(name: "Микрофон")),
        ("8-failed", .failed),
        ("9-off", .off),
    ]

    var exported = 0
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        for (name, kind) in kinds {
            let panel = DictorControlPanelApp()
            let view = panel.serviceStatusFooterPreview(for: kind, language: .russian)
            // Ширина сайдбара из макета — 220. Фон обязателен: подвал сам по
            // себе прозрачный, и без бумаги сайдбара тёмная тема снималась бы
            // светлым текстом на белом.
            let host = PaperBackgroundView(frame: NSRect(x: 0, y: 0, width: 220, height: 110))
            host.appearance = NSAppearance(named: appearanceName)
            host.fill = SD.C.sidebarPaper
            view.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
                view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            ])
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: directory.appendingPathComponent("status-\(name)-\(suffix).png"))
            exported += 1
        }
    }
    log("service status previews exported: \(exported) → \(directory.path)")
}
