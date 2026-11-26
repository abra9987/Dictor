import AppKit
import QuartzCore

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
