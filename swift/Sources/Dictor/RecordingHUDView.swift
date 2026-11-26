import AppKit

final class RecordingHUDView: NSView {
    // Публичный API сохранён ради exportRecordingHUDAnimationFrames и
    // существующей интеграции; отрисовка полностью новая («линия голоса»).
    var visualScale: CGFloat = RecordingHUDSize.standard.visualScale {
        didSet { if oldValue != visualScale { needsDisplay = true } }
    }

    var hudSize: RecordingHUDSize = .standard {
        didSet { if oldValue != hudSize { needsDisplay = true } }
    }

    var recordingColor: NSColor = SD.C.voiceDark {
        didSet { if !oldValue.isEqual(recordingColor) { needsDisplay = true } }
    }

    var transcribingColor: NSColor = NSColor(hex: 0xA3A09A) {
        didSet { if !oldValue.isEqual(transcribingColor) { needsDisplay = true } }
    }

    var backgroundStyle: RecordingHUDBackgroundStyle = .system {
        didSet { if oldValue != backgroundStyle { needsDisplay = true } }
    }

    var showsCapsuleStroke = true {
        didSet { if oldValue != showsCapsuleStroke { needsDisplay = true } }
    }

    var transcribingElapsedOverride: CGFloat? {
        didSet { needsDisplay = true }
    }

    var revealProgress: CGFloat = 1 {
        didSet { if oldValue != revealProgress { needsDisplay = true } }
    }

    var mode: RecordingHUDMode = .recording {
        didSet {
            if oldValue != mode {
                modeChangedAt = ProcessInfo.processInfo.systemUptime
                if mode == .transcribing { frozenLevels = levelHistory }
                needsDisplay = true
            }
        }
    }
    private var modeChangedAt = ProcessInfo.processInfo.systemUptime

    var level: Float = 0 {
        didSet {
            if mode == .recording {
                levelHistory.append(CGFloat(max(0, min(1, level))))
                if levelHistory.count > 96 { levelHistory.removeFirst(levelHistory.count - 96) }
            }
            if oldValue != level { needsDisplay = true }
        }
    }

    var phase: CGFloat = 0 {
        didSet { if oldValue != phase { needsDisplay = true } }
    }

    /// Секунды записи для mono-таймера. Обновляет таймер уровня.
    var recordingElapsed: TimeInterval = 0 {
        didSet { if Int(oldValue) != Int(recordingElapsed) { needsDisplay = true } }
    }

    var insertedWordCount: Int = 0 {
        didSet { if oldValue != insertedWordCount { needsDisplay = true } }
    }

    var errorMessage: String? {
        didSet { if oldValue != errorMessage { needsDisplay = true } }
    }

    var interfaceLanguage: InterfaceLanguage = .russian {
        didSet { if oldValue != interfaceLanguage { needsDisplay = true } }
    }

    /// Кольцевой буфер RMS-уровней; волна скроллится влево. Тишина
    /// рисует бары высотой 2pt — линия не исчезает никогда.
    private var levelHistory: [CGFloat] = []
    private var frozenLevels: [CGFloat] = []

    func resetWave() {
        levelHistory.removeAll(keepingCapacity: true)
        frozenLevels.removeAll(keepingCapacity: true)
        recordingElapsed = 0
        needsDisplay = true
    }

    override var isFlipped: Bool { true }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawCapsule()
    }

    // MARK: - Метрики раскладки

    private var capsuleHeight: CGFloat { hudSize.capsuleHeight }

    private var waveSize: NSSize {
        switch hudSize {
        case .compact: return NSSize(width: 24, height: 12)
        case .standard: return NSSize(width: 34, height: 18)
        case .large: return NSSize(width: 40, height: 20)
        }
    }

    private var timerFontSize: CGFloat {
        switch hudSize {
        case .compact: return 10
        case .standard: return 12
        case .large: return 13
        }
    }

    private var labelFontSize: CGFloat {
        switch hudSize {
        case .compact: return 10.5
        case .standard: return 12
        case .large: return 13
        }
    }

    private var captionFontSize: CGFloat {
        switch hudSize {
        case .compact: return 10
        case .standard: return 11
        case .large: return 11.5
        }
    }

    private var showsEscHint: Bool { hudSize != .compact }

    // MARK: - Отрисовка

    private func drawCapsule() {
        let reveal = max(0, min(1, revealProgress))
        guard reveal > 0.001 else { return }

        // Появление: scale 0.85→1 + opacity (spring имитируется
        // overshoot-кривой); Reduce Motion — чистый crossfade.
        let capsuleAlpha = smootherstep(0, 0.5, reveal)
        let contentAlpha = smootherstep(0.3, 0.9, reveal)
        let scale: CGFloat
        if reduceMotion {
            scale = 1
        } else {
            let settle = smootherstep(0, 1, reveal)
            let overshoot = sin(settle * .pi) * 0.045
            scale = 0.85 + (0.15 * settle) + overshoot
        }

        let content = contentLayout()
        let width = min(bounds.width - 8, content.totalWidth) * scale
        let height = capsuleHeight * scale
        let capsuleRect = NSRect(x: bounds.midX - width / 2,
                                 y: bounds.midY - height / 2,
                                 width: width,
                                 height: height)
        let capsule = NSBezierPath(roundedRect: capsuleRect,
                                   xRadius: height / 2,
                                   yRadius: height / 2)

        // Тени под капсулой нет намеренно. Она отделяла капсулу от чужих
        // окон под ней, но капсула висит поверх всего экрана и отделена уже
        // тем, что непрозрачна: 24 pt размытия читались не как глубина, а как
        // грязь под объектом. Отделение держит обводка ниже.
        capsuleFill().withAlphaComponent(capsuleFillAlpha() * capsuleAlpha).setFill()
        capsule.fill()

        if showsCapsuleStroke {
            // Обводка идёт по стилю капсулы, а не всегда белая: у светлой
            // капсулы белая линия на светлом фоне — это отсутствие линии, и
            // без тени её край растворялся бы вовсе.
            let stroke = shouldUseLightBackground()
                ? NSColor.black.withAlphaComponent(0.12 * capsuleAlpha)
                : NSColor.white.withAlphaComponent(0.08 * capsuleAlpha)
            stroke.setStroke()
            capsule.lineWidth = 1
            capsule.stroke()
        }

        guard contentAlpha > 0.001 else { return }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        capsule.addClip()
        NSGraphicsContext.current?.cgContext.setAlpha(contentAlpha)

        drawContent(content, in: capsuleRect)

        if mode == .transcribing {
            drawTranscribingProgress(in: capsuleRect, alpha: contentAlpha)
        }
    }

    private struct ContentLayout {
        var wave: Bool = false
        var check: Bool = false
        var primaryText: NSAttributedString?
        var secondaryText: NSAttributedString?
        var totalWidth: CGFloat = 0
    }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: interfaceLanguage)
    }

    private func contentLayout() -> ContentLayout {
        var layout = ContentLayout()
        let padding: CGFloat = hudSize == .compact ? 10 : 14
        let gap: CGFloat = hudSize == .compact ? 8 : 10
        var width = padding

        switch mode {
        case .recording:
            layout.wave = true
            width += waveSize.width + gap
            layout.primaryText = attributed(timerText(),
                                            font: SD.timerFont(size: timerFontSize),
                                            color: SD.C.capsuleText)
            width += ceil(measuredSize(layout.primaryText).width)
            if showsEscHint {
                layout.secondaryText = attributed(t("Esc — отменить", "Esc to cancel"),
                                                  font: SD.captionFont(size: captionFontSize),
                                                  color: SD.C.capsuleSecondaryText)
                width += gap + 1 + gap + ceil(measuredSize(layout.secondaryText).width)
            }
        case .transcribing:
            layout.wave = true
            width += waveSize.width + gap
            layout.primaryText = attributed(t("Распознаю…", "Transcribing…"),
                                            font: SD.labelFont(size: labelFontSize),
                                            color: SD.C.capsuleText)
            width += ceil(measuredSize(layout.primaryText).width)
        case .inserted:
            layout.check = true
            width += checkDiameter + 8
            let words = dictatedWordsLabel(insertedWordCount, language: interfaceLanguage)
            layout.primaryText = attributed(t("Вставлено · \(words)", "Inserted · \(words)"),
                                            font: SD.labelFont(size: labelFontSize),
                                            color: SD.C.capsuleText)
            width += ceil(measuredSize(layout.primaryText).width)
        case .error:
            layout.wave = true
            width += waveSize.width + gap
            let message = errorMessage ?? t("Не получилось распознать", "Dictation failed")
            layout.primaryText = attributed(message,
                                            font: SD.labelFont(size: labelFontSize),
                                            color: accentColor())
            width += ceil(measuredSize(layout.primaryText).width)
        }
        width += padding
        layout.totalWidth = width
        return layout
    }

    private var checkDiameter: CGFloat { hudSize == .compact ? 13 : 16 }

    private func drawContent(_ layout: ContentLayout, in capsuleRect: NSRect) {
        let padding: CGFloat = hudSize == .compact ? 10 : 14
        let gap: CGFloat = hudSize == .compact ? 8 : 10
        var x = capsuleRect.minX + padding

        if layout.wave {
            let waveRect = NSRect(x: x,
                                  y: capsuleRect.midY - waveSize.height / 2,
                                  width: waveSize.width,
                                  height: waveSize.height)
            drawWave(in: waveRect)
            x += waveSize.width + gap
        }

        if layout.check {
            let rect = NSRect(x: x,
                              y: capsuleRect.midY - checkDiameter / 2,
                              width: checkDiameter,
                              height: checkDiameter)
            drawCheckmark(in: rect)
            x += checkDiameter + 8
        }

        if let primary = layout.primaryText {
            let size = measuredSize(primary)
            drawText(primary, at: NSPoint(x: x, y: capsuleRect.midY - size.height / 2))
            x += ceil(size.width)
        }

        if let secondary = layout.secondaryText {
            x += gap
            let divider = NSRect(x: x,
                                 y: capsuleRect.midY - 7,
                                 width: 1,
                                 height: 14)
            SD.C.capsuleDivider.setFill()
            divider.fill()
            x += 1 + gap
            let size = measuredSize(secondary)
            drawText(secondary, at: NSPoint(x: x, y: capsuleRect.midY - size.height / 2))
        }
    }

    // Бар-волна из истории RMS. recording — живая, error — плоская
    // линия («звук ушёл»), transcribing — замороженный кадр с
    // мерцанием слева направо (каскад 90 мс на бар).
    private func drawWave(in rect: NSRect) {
        let barWidth = SD.Metrics.waveBarWidth
        let barGap = SD.Metrics.waveBarGap
        let barCount = max(1, Int(rect.width / (barWidth + barGap)))

        let source: [CGFloat]
        let color: NSColor
        switch mode {
        case .transcribing:
            source = frozenLevels
            color = transcribingColor
        case .error:
            source = []
            color = accentColor()
        default:
            source = levelHistory
            color = accentColor()
        }

        let age = transcribingElapsedOverride
            ?? CGFloat(max(0, ProcessInfo.processInfo.systemUptime - modeChangedAt))

        if reduceMotion, mode == .recording {
            // Reduce Motion: статичная линия + индикатор-точка.
            drawFlatLine(in: rect, color: color, barCount: barCount,
                         barWidth: barWidth, barGap: barGap)
            let dot = NSRect(x: rect.maxX - 4, y: rect.midY - 2, width: 4, height: 4)
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return
        }

        for index in 0..<barCount {
            let sourceIndex = source.count - barCount + index
            let value = sourceIndex >= 0 && sourceIndex < source.count ? source[sourceIndex] : 0
            let shaped = pow(max(0, min(1, value)), 0.82)
            let height = max(SD.Metrics.waveSilenceHeight, shaped * rect.height)
            let barRect = NSRect(x: rect.minX + CGFloat(index) * (barWidth + barGap),
                                 y: rect.midY - height / 2,
                                 width: barWidth,
                                 height: height)
            var alpha: CGFloat = 1
            if mode == .transcribing, !reduceMotion {
                // Мерцание: opacity 0.25↔1 бежит слева направо.
                let cycle = CGFloat(SD.Anim.shimmerCycleSeconds)
                let cascade = CGFloat(SD.Anim.shimmerCascadePerBar)
                let t = (age - CGFloat(index) * cascade)
                    .truncatingRemainder(dividingBy: cycle) / cycle
                alpha = 0.25 + 0.75 * (0.5 + 0.5 * sin(t * 2 * .pi - .pi / 2))
            }
            color.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: barRect,
                         xRadius: barWidth / 2,
                         yRadius: barWidth / 2).fill()
        }
    }

    private func drawFlatLine(in rect: NSRect, color: NSColor, barCount: Int,
                              barWidth: CGFloat, barGap: CGFloat) {
        color.setFill()
        for index in 0..<barCount {
            let barRect = NSRect(x: rect.minX + CGFloat(index) * (barWidth + barGap),
                                 y: rect.midY - SD.Metrics.waveSilenceHeight / 2,
                                 width: barWidth,
                                 height: SD.Metrics.waveSilenceHeight)
            NSBezierPath(roundedRect: barRect,
                         xRadius: barWidth / 2,
                         yRadius: barWidth / 2).fill()
        }
    }

    /// 2pt-прогресс у нижней кромки капсулы при распознавании.
    /// Реального прогресса у ASR нет — ease-out к 92%, добегает при скрытии.
    private func drawTranscribingProgress(in capsuleRect: NSRect, alpha: CGFloat) {
        let age = transcribingElapsedOverride
            ?? CGFloat(max(0, ProcessInfo.processInfo.systemUptime - modeChangedAt))
        let progress = min(0.92, 1 - exp(-age / 0.9))
        let rect = NSRect(x: capsuleRect.minX,
                          y: capsuleRect.maxY - 2,
                          width: capsuleRect.width * progress,
                          height: 2)
        accentColor().withAlphaComponent(alpha).setFill()
        rect.fill()
    }

    private func drawCheckmark(in rect: NSRect) {
        accentColor().setFill()
        NSBezierPath(ovalIn: rect).fill()
        let path = NSBezierPath()
        path.lineWidth = max(1.5, rect.width * 0.11)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: rect.minX + rect.width * 0.28,
                              y: rect.minY + rect.height * 0.52))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.44,
                              y: rect.minY + rect.height * 0.68))
        path.line(to: NSPoint(x: rect.minX + rect.width * 0.73,
                              y: rect.minY + rect.height * 0.34))
        NSColor(hex: 0x1C1B19).setStroke()
        path.stroke()
    }

    // MARK: - Вспомогательное

    private func timerText() -> String {
        let total = max(0, Int(recordingElapsed))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// CoreText отверг текст капсулы: один раз в лог, дальше капсула рисуется
    /// системным шрифтом. Страховка поверх пробы `SD.timerFont`: та ловит
    /// шрифт до отрисовки, эта — исключение внутри неё, если оно всё же
    /// случилось. Без неё исключение доходит до `abort()` и служба умирает
    /// посреди записи (macOS 26.3.1, 2026-09-10).
    private var textLayoutFallbackActive = false

    private func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        let resolved = textLayoutFallbackActive
            ? NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
            : font
        return NSAttributedString(string: text, attributes: [.font: resolved, .foregroundColor: color])
    }

    private func measuredSize(_ text: NSAttributedString?) -> NSSize {
        guard let text else { return .zero }
        var size = NSSize.zero
        do {
            try withObjCExceptionsAsErrors { size = text.size() }
        } catch {
            noteTextLayoutFailure(error, in: text)
            // Оценка вместо вёрстки: ширина по числу знаков, высота по кеглю.
            let pointSize = attributedFont(of: text)?.pointSize ?? 12
            size = NSSize(width: CGFloat(text.length) * pointSize * 0.62,
                          height: pointSize * 1.25)
        }
        return size
    }

    private func drawText(_ text: NSAttributedString, at point: NSPoint) {
        do {
            try withObjCExceptionsAsErrors { text.draw(at: point) }
        } catch {
            noteTextLayoutFailure(error, in: text)
        }
    }

    private func attributedFont(of text: NSAttributedString) -> NSFont? {
        guard text.length > 0 else { return nil }
        return text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
    }

    private func noteTextLayoutFailure(_ error: Error, in text: NSAttributedString) {
        guard !textLayoutFallbackActive else { return }
        textLayoutFallbackActive = true
        let font = attributedFont(of: text).map(SD.describe) ?? "unknown font"
        log("capsule text layout failed: \(error.localizedDescription); \(font); switching to the system font")
        needsDisplay = true
    }

    private func accentColor() -> NSColor {
        // На тёмной капсуле светлый коралл читается лучше тёмного.
        if recordingColor.isEqual(SD.C.voiceLight) || recordingColor.isEqual(SD.C.voiceDark) {
            return shouldUseLightBackground() ? SD.C.voiceLight : SD.C.voiceDark
        }
        return recordingColor
    }

    private func capsuleFill() -> NSColor {
        shouldUseLightBackground() ? SD.C.capsuleLight : SD.C.capsuleDark
    }

    private func capsuleFillAlpha() -> CGFloat {
        shouldUseLightBackground() ? 0.96 : 0.94
    }

    private func smootherstep(_ edge0: CGFloat, _ edge1: CGFloat, _ value: CGFloat) -> CGFloat {
        guard edge0 != edge1 else { return value >= edge1 ? 1 : 0 }
        let t = max(0, min(1, (value - edge0) / (edge1 - edge0)))
        return t * t * t * (t * ((t * 6) - 15) + 10)
    }

    private func shouldUseLightBackground() -> Bool {
        switch backgroundStyle {
        case .light:
            return true
        case .dark:
            return false
        case .system:
            // Дизайн: капсула остаётся тёмной и в светлой системной теме
            // («Как в системе» = тёмная в light). Светлую даёт только
            // явный выбор пользователя.
            return false
        }
    }

}
