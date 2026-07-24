import AppKit

// Дизайн-токены редизайна («линия голоса»). Источник: Claude Design,
// Dictor Redesign.dc.html, секция 3a (SDTheme.swift) и 1a (палитра).
// Светлая/тёмная пары резолвятся через NSColor(name:dynamicProvider:),
// чтобы капсула и глиф следовали системной теме без ручных пересчётов.

enum SD {
    enum C {
        /// Акцент = запись. Продукт и его главное действие делят один цвет.
        static let voice = adaptive(light: 0xE8502F, dark: 0xFF6B47)
        static let ink = adaptive(light: 0x1C1B19, dark: 0xF2F1EE)
        static let graphite = adaptive(light: 0x6E6B66, dark: 0xA3A09A)
        static let paper = adaptive(light: 0xF5F4F1, dark: 0x1E1D1B)
        /// Фон окна настроек по макету 2c/4b: #F5F4F1 / #262523.
        static let settingsPaper = adaptive(light: 0xF5F4F1, dark: 0x262523)
        /// Фон поповера по макету 1d/1e: rgba(248,247,244,.97) / rgba(38,37,35,.97).
        static let popoverPaper = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor(hex: 0x262523, alpha: 0.97)
                : NSColor(hex: 0xF8F7F4, alpha: 0.97)
        }
        /// Приглушённые подписи под заголовком строки. В макете пара
        /// инвертирована относительно graphite: светлая #A3A09A, тёмная #6E6B66.
        static let subtle = adaptive(light: 0xA3A09A, dark: 0x6E6B66)
        /// Выбранная пилюля: «чернильная» в светлой теме, «бумажная» в тёмной.
        static let pillSelectedFill = adaptive(light: 0x1C1B19, dark: 0xF2F1EE)
        static let pillSelectedText = adaptive(light: 0xF5F4F1, dark: 0x1C1B19)
        static let hairline = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.08)
                : NSColor.black.withAlphaComponent(0.07)
        }
        /// Разделители строк настроек чуть светлее hairline: .06 / .07.
        static let rowHairline = NSColor(name: nil) { appearance in
            appearance.isDark
                ? NSColor.white.withAlphaComponent(0.07)
                : NSColor.black.withAlphaComponent(0.06)
        }
        /// Заливка капсулы в тёмном исполнении (дефолт дизайна).
        static let capsuleDark = NSColor(calibratedRed: 28 / 255,
                                         green: 27 / 255,
                                         blue: 25 / 255,
                                         alpha: 0.94)
        static let capsuleLight = NSColor(calibratedWhite: 0.97, alpha: 0.96)
        /// Текст на тёмной капсуле.
        static let capsuleText = NSColor(hex: 0xF2F1EE)
        static let capsuleSecondaryText = NSColor(hex: 0xA3A09A)
        static let capsuleDivider = NSColor.white.withAlphaComponent(0.16)
        static let voiceLight = NSColor(hex: 0xE8502F)
        static let voiceDark = NSColor(hex: 0xFF6B47)

        private static func adaptive(light: Int, dark: Int) -> NSColor {
            NSColor(name: nil) { appearance in
                appearance.isDark ? NSColor(hex: dark) : NSColor(hex: light)
            }
        }
    }

    enum Metrics {
        /// Волна в капсуле: бар 2pt, зазор 2pt, тишина = бар 2pt высотой.
        static let waveBarWidth: CGFloat = 2
        static let waveBarGap: CGFloat = 2
        static let waveSilenceHeight: CGFloat = 2
        static let capsuleShadowRadius: CGFloat = 24
        static let capsuleShadowAlpha: CGFloat = 0.28
        static let capsuleShadowOffsetY: CGFloat = 8
    }

    enum Anim {
        /// hold перед растворением капсулы «Вставлено».
        static let insertedHoldSeconds: TimeInterval = 0.9
        /// Каскад мерцания баров при распознавании, сек на бар.
        static let shimmerCascadePerBar: TimeInterval = 0.09
        static let shimmerCycleSeconds: TimeInterval = 1.1
    }

    static func timerFont(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
    }

    static func captionFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size)
    }

    static func labelFont(size: CGFloat) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: .medium)
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

extension NSView {
    /// `.cgColor` динамического NSColor резолвится под appearance,
    /// актуальную В МОМЕНТ обращения, а не под тему вью — из-за этого
    /// слои красились «светлыми» цветами в тёмной теме. Всегда
    /// резолвим под effectiveAppearance.
    func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1) {
        self.init(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

// MARK: - Глиф меню-бара «линия голоса»

// Пять баров 2×(3…16)pt. Всегда template (монохром, система сама
// красит под светлую/тёмную панель) — кроме error, где к линии
// добавляется коралловая точка и template невозможен.

enum VoiceLineGlyph {
    static let pointSize = NSSize(width: 20, height: 18)
    private static let barWidth: CGFloat = 2
    private static let barGap: CGFloat = 1.6
    private static let maxBarHeight: CGFloat = 15

    static let idleBars: [CGFloat] = [0.12, 0.12, 0.4, 0.12, 0.12]
    static let busyBars: [CGFloat] = [0.5, 0.5, 0.5, 0.5, 0.5]
    static let flatBars: [CGFloat] = [0.12, 0.12, 0.12, 0.12, 0.12]
    /// Пауза: линия с разрывом в центре.
    static let pausedBars: [CGFloat] = [0.12, 0.12, 0, 0.12, 0.12]

    /// Живые бары записи: амплитуда от реального RMS + бегущая фаза,
    /// детерминированно от (level, phase) — обновление ~8 fps.
    static func recordingBars(level: CGFloat, phase: CGFloat) -> [CGFloat] {
        let clamped = max(0, min(1, level))
        let audio = pow(clamped, 0.82)
        return (0..<5).map { index in
            let i = CGFloat(index)
            let centered = 1 - abs(i - 2) / 2.4
            let travel = (sin(phase * 1.9 - i * 1.1) + 1) / 2
            let motion = 0.14 + audio * (0.25 + 0.75 * centered) * (0.5 + 0.5 * travel)
            return max(0.1, min(1, motion))
        }
    }

    static func image(bars: [CGFloat]) -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { _ in
            draw(bars: bars, color: .black)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Error: монохромная плоская линия + коралловая точка справа
    /// сверху. Линия рисуется labelColor, чтобы адаптироваться к теме
    /// панели в момент отрисовки.
    static func errorImage() -> NSImage {
        let image = NSImage(size: pointSize, flipped: false) { _ in
            draw(bars: flatBars, color: .labelColor)
            let dot = NSRect(x: pointSize.width - 5.5,
                             y: pointSize.height - 6,
                             width: 4.5,
                             height: 4.5)
            SD.C.voice.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func draw(bars: [CGFloat], color: NSColor) {
        let totalWidth = CGFloat(bars.count) * barWidth
            + CGFloat(bars.count - 1) * barGap
        let startX = (pointSize.width - totalWidth) / 2
        let midY = pointSize.height / 2
        color.setFill()
        for (index, value) in bars.enumerated() {
            let height = max(2.6, value * maxBarHeight)
            let rect = NSRect(x: startX + CGFloat(index) * (barWidth + barGap),
                              y: midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect,
                         xRadius: barWidth / 2,
                         yRadius: barWidth / 2).fill()
        }
    }
}

/// Русская форма «N слов» для капсулы-подтверждения.
func dictatedWordsLabel(_ count: Int, language: InterfaceLanguage) -> String {
    guard language == .russian else {
        return count == 1 ? "1 word" : "\(count) words"
    }
    let mod100 = count % 100
    let mod10 = count % 10
    let noun: String
    if (11...14).contains(mod100) {
        noun = "слов"
    } else if mod10 == 1 {
        noun = "слово"
    } else if (2...4).contains(mod10) {
        noun = "слова"
    } else {
        noun = "слов"
    }
    return "\(count) \(noun)"
}

// MARK: - Поверхность «бумага»

/// Непрозрачный фон окон по дизайну: paper #F5F4F1 / #1E1D1B.
/// Обычный draw()-вью, чтобы цвет следовал за сменой темы без слоёв.
final class PaperBackgroundView: NSView {
    var cornerRadius: CGFloat = 0 {
        didSet { needsDisplay = true }
    }
    /// Каждая поверхность в макете имеет свой оттенок бумаги
    /// (настройки #262523, поповер #2B2A27 в тёмной теме).
    var fill: NSColor = SD.C.paper {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds,
                                xRadius: cornerRadius,
                                yRadius: cornerRadius)
        fill.setFill()
        path.fill()
        if cornerRadius > 0 {
            SD.C.hairline.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension SD {
    /// Заголовок окна 22/700 c тонким трекингом — «Заголовок окна» из
    /// типографической шкалы дизайна.
    static func windowTitleLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        label.textColor = SD.C.ink
        return label
    }
}
