import AppKit

// Плавающая капсула (макет 6c) — та же капсула записи, только всегда под
// рукой. Три состояния одного объекта, а не три окна:
//
//   покой (30)     — маленькая, полупрозрачная, показывает только хоткей;
//   наведение (40) — открываются действия: диктовать, история, меню;
//   запись (44)    — растёт под голос, таймер и «Esc — отменить».
//
// В макете это сказано прямо: «Один и тот же объект меняет размер — не
// появляется новое окно». Поэтому переход между состояниями — анимация
// размера за 180 мс, без всплывающих уведомлений и подмены окна.
//
// Чего здесь нет: пилюли «Чат» из макета. За ней стоят режимы и голосовые
// команды из тёрна 5, то есть LLM, которого в приложении нет. Нарисованная
// кнопка, за которой ничего не происходит, — обещание, которое программа не
// сдержит.

enum FloatingCapsuleState: Equatable {
    case idle
    case hover
    case recording
}

/// Куда капсула отправляет нажатия. Действия живут в агенте: он владеет и
/// записью, и окном, и меню.
@MainActor
protocol FloatingCapsuleDelegate: AnyObject {
    func floatingCapsuleDidRequestDictation()
    func floatingCapsuleDidRequestHistory()
    func floatingCapsuleDidRequestMenu(at point: NSPoint)
}

/// Метрики трёх состояний — числом в число из макета 6c.
/// Геометрия постоянной капсулы по размеру из настроек — тому же, что у
/// капсулы у курсора. Large — макет 6c число в число (30 / 40 / 44 pt).
/// Standard и Compact в состоянии записи повторяют капсулу у курсора
/// (высота 36 / 26, волна, кегль таймера — см. RecordingHUDView), покой и
/// наведение уменьшены в той же пропорции, но шрифт не мельче 10 pt:
/// пилюля в 18 pt с подписью в 7 pt была бы верна арифметически и
/// нечитаема на деле.
///
/// До 1.9.2 размер был один: человек ставил «Compact», капсула у курсора
/// уменьшалась, а постоянная — нет, хотя это одна и та же капсула.
struct FloatingCapsuleGeometry: Equatable {
    let size: RecordingHUDSize

    init(size: RecordingHUDSize) {
        self.size = size
    }

    private func pick(_ compact: CGFloat, _ standard: CGFloat, _ large: CGFloat) -> CGFloat {
        switch size {
        case .compact: return compact
        case .standard: return standard
        case .large: return large
        }
    }

    // Запись — число в число с капсулой у курсора.
    var recordingHeight: CGFloat { size.capsuleHeight }
    var recordingWaveHeight: CGFloat { pick(12, 18, 20) }
    var recordingPadding: CGFloat { pick(10, 14, 16) }
    var recordingGap: CGFloat { pick(8, 10, 12) }
    var timerFontSize: CGFloat { pick(10, 12, 13) }
    var hintFontSize: CGFloat { pick(10, 11, 11.5) }

    // Покой. Compact упирается в 26 pt записи сверху: покой и наведение
    // обязаны остаться ниже, иначе капсула при старте записи сжималась бы.
    var idleHeight: CGFloat { pick(20, 26, 30) }
    var idleWaveHeight: CGFloat { pick(8, 11, 13) }
    var idlePadding: CGFloat { pick(9, 11, 13) }
    var idleGap: CGFloat { pick(7, 8, 9) }
    var hotkeyFontSize: CGFloat { pick(10, 10.5, 11.5) }

    // Наведение.
    var hoverHeight: CGFloat { pick(24, 34, 40) }
    var hoverWaveHeight: CGFloat { pick(10, 12, 14) }
    var hoverLeadingPadding: CGFloat { pick(10, 12, 14) }
    var hoverTrailingPadding: CGFloat { pick(6, 7, 8) }
    var hoverGap: CGFloat { pick(7, 8, 10) }
    var dictateFontSize: CGFloat { pick(10.5, 11.5, 12.5) }
    var historyFontSize: CGFloat { pick(10, 11, 12) }
    var ellipsisFontSize: CGFloat { pick(11, 12, 13) }

    func height(for state: FloatingCapsuleState) -> CGFloat {
        switch state {
        case .idle: return idleHeight
        case .hover: return hoverHeight
        case .recording: return recordingHeight
        }
    }
}

enum FloatingCapsuleMetrics {
    /// Запас вокруг капсулы внутри окна: тень рисуется своей, а не системной,
    /// иначе её радиус и смещение из макета задать нечем.
    static let shadowInset: CGFloat = 26
    /// Переход между состояниями — 180 мс из макета.
    static let transitionSeconds: TimeInterval = 0.18
    /// Ближе этого к краю экрана капсула прилипает…
    static let snapDistance: CGFloat = 48
    /// …и встаёт на таком отступе от него.
    static let snapMargin: CGFloat = 16

    /// Держим капсулу в пределах видимой области экрана. Упираться в край
    /// должна сама капсула, а не прозрачное поле под тень вокруг неё, —
    /// иначе она встаёт с зазором в 26 pt и выглядит криво поставленной.
    static func clampedOrigin(_ origin: NSPoint,
                              windowSize: NSSize,
                              visibleFrame: NSRect) -> NSPoint {
        let minX = visibleFrame.minX - shadowInset
        let maxX = visibleFrame.maxX - windowSize.width + shadowInset
        let minY = visibleFrame.minY - shadowInset
        let maxY = visibleFrame.maxY - windowSize.height + shadowInset
        return NSPoint(x: min(max(origin.x, minX), max(minX, maxX)),
                       y: min(max(origin.y, minY), max(minY, maxY)))
    }

    /// Прилипание к краям: капсула, отпущенная рядом с краем, встаёт ровно
    /// вдоль него. Иначе она навсегда остаётся «почти у края».
    static func snappedOrigin(windowFrame: NSRect, visibleFrame: NSRect) -> NSPoint {
        let capsule = windowFrame.insetBy(dx: shadowInset, dy: shadowInset)
        var origin = windowFrame.origin
        if abs(capsule.minX - visibleFrame.minX) < snapDistance {
            origin.x = visibleFrame.minX + snapMargin - shadowInset
        } else if abs(visibleFrame.maxX - capsule.maxX) < snapDistance {
            origin.x = visibleFrame.maxX - snapMargin - capsule.width - shadowInset
        }
        if abs(capsule.minY - visibleFrame.minY) < snapDistance {
            origin.y = visibleFrame.minY + snapMargin - shadowInset
        } else if abs(visibleFrame.maxY - capsule.maxY) < snapDistance {
            origin.y = visibleFrame.maxY - snapMargin - capsule.height - shadowInset
        }
        return clampedOrigin(origin, windowSize: windowFrame.size, visibleFrame: visibleFrame)
    }
}

/// Рисованная капсула. Всё внутри — свои прямоугольники, потому что от
/// состояния меняются и высота, и набор элементов; стек-вью на такой переход
/// отвечает скачками раскладки.
final class FloatingCapsuleView: NSView {
    weak var delegate: FloatingCapsuleDelegate?

    var state: FloatingCapsuleState = .idle {
        didSet { if state != oldValue { needsDisplay = true } }
    }
    /// Подпись хоткея в покое: «⌘ ⌥» — то, что человек и нажимает.
    var hotkeyTitle = "" { didSet { needsDisplay = true } }
    var language: InterfaceLanguage = .russian { didSet { needsDisplay = true } }
    /// Уровень звука 0…1 и фаза дыхания волны — как у капсулы записи.
    var level: Float = 0 { didSet { if state == .recording { needsDisplay = true } } }
    var phase: CGFloat = 0 { didSet { if state == .recording { needsDisplay = true } } }
    var elapsedSeconds: Int = 0 { didSet { if state == .recording { needsDisplay = true } } }

    /// Прямоугольники действий, посчитанные при отрисовке: клик проверяется
    /// по ним же, поэтому нарисованное и нажимаемое не могут разъехаться.
    private var dictateRect: NSRect = .zero
    private var historyRect: NSRect = .zero
    private var menuRect: NSRect = .zero

    private var trackingArea: NSTrackingArea?

    // MARK: - Геометрия

    /// Ширина капсулы для состояния — считается по содержимому, как в макете
    /// («width: max-content»).
    /// Размер — из той же настройки, что у капсулы у курсора. По умолчанию
    /// Large: это макет 6c как есть, и таким его видят экспорт и тесты, пока
    /// контроллер не подставит выбранное человеком.
    var geometry = FloatingCapsuleGeometry(size: .large) {
        didSet { if geometry != oldValue { needsDisplay = true } }
    }

    private var hotkeyFont: NSFont { .systemFont(ofSize: geometry.hotkeyFontSize) }
    private var dictateFont: NSFont { .systemFont(ofSize: geometry.dictateFontSize, weight: .medium) }
    private var historyFont: NSFont { .systemFont(ofSize: geometry.historyFontSize) }
    private var ellipsisFont: NSFont { .systemFont(ofSize: geometry.ellipsisFontSize) }
    private var hintFont: NSFont { .systemFont(ofSize: geometry.hintFontSize) }
    private var timerFont: NSFont { SD.timerFont(size: geometry.timerFontSize) }

    func capsuleWidth(for state: FloatingCapsuleState) -> CGFloat {
        let g = geometry
        switch state {
        case .idle:
            let wave = waveWidth(bars: 5, height: g.idleWaveHeight)
            let text = measure(hotkeyTitle, font: hotkeyFont)
            return g.idlePadding * 2 + wave + g.idleGap + text
        case .hover:
            let wave = waveWidth(bars: 5, height: g.hoverWaveHeight)
            let dictate = measure(dictateTitle, font: dictateFont)
            let history = measure(historyTitle, font: historyFont)
            let ellipsis = measure("⋯", font: ellipsisFont)
            return g.hoverLeadingPadding + wave + g.hoverGap + dictate + g.hoverGap
                + 1 + g.hoverGap + history + g.hoverGap + ellipsis + 6 + g.hoverTrailingPadding
        case .recording:
            let wave = waveWidth(bars: 7, height: g.recordingWaveHeight)
            let timer = measure(timerText, font: timerFont)
            let hint = measure(cancelHint, font: hintFont)
            return g.recordingPadding * 2 + wave + g.recordingGap + timer
                + g.recordingGap + 1 + g.recordingGap + hint
        }
    }

    func windowSize(for state: FloatingCapsuleState) -> NSSize {
        let inset = FloatingCapsuleMetrics.shadowInset * 2
        return NSSize(width: capsuleWidth(for: state) + inset,
                      height: geometry.height(for: state) + inset)
    }

    private var dictateTitle: String { localizedText("Диктовать", "Dictate", language: language) }
    private var historyTitle: String { localizedText("История", "History", language: language) }
    private var cancelHint: String {
        localizedText("Esc — отменить", "Esc to cancel", language: language)
    }
    private var timerText: String {
        String(format: "%d:%02d", elapsedSeconds / 60, elapsedSeconds % 60)
    }

    /// CoreText отверг текст капсулы: один раз в лог, дальше — системный
    /// шрифт. Та же страховка, что у RecordingHUDView: необработанное
    /// исключение из вёрстки роняло службу посреди записи (macOS 26.3.1).
    private var textLayoutFallbackActive = false

    private func resolvedFont(_ font: NSFont) -> NSFont {
        textLayoutFallbackActive
            ? NSFont.systemFont(ofSize: font.pointSize, weight: .medium)
            : font
    }

    private func noteTextLayoutFailure(_ error: Error, font: NSFont) {
        guard !textLayoutFallbackActive else { return }
        textLayoutFallbackActive = true
        log("floating capsule text layout failed: \(error.localizedDescription); \(SD.describe(font)); switching to the system font")
        needsDisplay = true
    }

    private func measure(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        var width: CGFloat = 0
        do {
            try withObjCExceptionsAsErrors {
                width = (text as NSString).size(withAttributes: [.font: resolvedFont(font)]).width
            }
        } catch {
            noteTextLayoutFailure(error, font: font)
            width = CGFloat(text.count) * font.pointSize * 0.62
        }
        return ceil(width)
    }

    private func waveWidth(bars: Int, height: CGFloat) -> CGFloat {
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2
        return CGFloat(bars) * barWidth + CGFloat(bars - 1) * gap
    }

    /// Прямоугольник самой капсулы внутри окна — окно шире на тень.
    private var capsuleRect: NSRect {
        bounds.insetBy(dx: FloatingCapsuleMetrics.shadowInset,
                       dy: FloatingCapsuleMetrics.shadowInset)
    }

    // MARK: - Отрисовка

    override func draw(_ dirtyRect: NSRect) {
        let rect = capsuleRect
        guard rect.width > 0, rect.height > 0 else { return }
        let radius = rect.height / 2

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(shadowAlpha)
        shadow.shadowBlurRadius = shadowBlur
        shadow.shadowOffset = NSSize(width: 0, height: -shadowOffset)
        shadow.set()
        backgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()

        dictateRect = .zero
        historyRect = .zero
        menuRect = .zero

        switch state {
        case .idle: drawIdle(in: rect)
        case .hover: drawHover(in: rect)
        case .recording: drawRecording(in: rect)
        }
    }

    /// Фон: полупрозрачный в покое, почти плотный под действиями и записью.
    private var backgroundColor: NSColor {
        switch state {
        case .idle: return NSColor(hex: 0x1C1B19, alpha: 0.5)
        case .hover: return NSColor(hex: 0x1C1B19, alpha: 0.94)
        case .recording: return NSColor(hex: 0x1C1B19, alpha: 0.96)
        }
    }

    private var shadowAlpha: CGFloat {
        switch state {
        case .idle: return 0.16
        case .hover: return 0.26
        case .recording: return 0.30
        }
    }

    private var shadowBlur: CGFloat {
        switch state {
        case .idle: return 18
        case .hover: return 30
        case .recording: return 34
        }
    }

    private var shadowOffset: CGFloat {
        switch state {
        case .idle: return 6
        case .hover: return 12
        case .recording: return 14
        }
    }

    private func drawIdle(in rect: NSRect) {
        let g = geometry
        var x = rect.minX + g.idlePadding
        x += drawWave(at: x, in: rect, bars: 5, height: g.idleWaveHeight,
                      color: NSColor(hex: 0xF2F1EE, alpha: 0.55), live: false)
        x += g.idleGap
        draw(hotkeyTitle, at: x, in: rect,
             font: hotkeyFont,
             color: NSColor(hex: 0xF2F1EE, alpha: 0.75))
    }

    private func drawHover(in rect: NSRect) {
        let g = geometry
        var x = rect.minX + g.hoverLeadingPadding
        x += drawWave(at: x, in: rect, bars: 5, height: g.hoverWaveHeight,
                      color: SD.C.voiceDark, live: false)
        x += g.hoverGap

        let dictateWidth = draw(dictateTitle, at: x, in: rect, font: dictateFont,
                                color: NSColor(hex: 0xF2F1EE))
        dictateRect = NSRect(x: rect.minX, y: rect.minY,
                             width: x + dictateWidth - rect.minX + g.hoverGap / 2,
                             height: rect.height)
        x += dictateWidth + g.hoverGap

        drawDivider(at: x, in: rect)
        x += 1 + g.hoverGap

        let historyWidth = draw(historyTitle, at: x, in: rect, font: historyFont,
                                color: NSColor(hex: 0xA3A09A))
        historyRect = NSRect(x: x - g.hoverGap / 2, y: rect.minY,
                             width: historyWidth + g.hoverGap, height: rect.height)
        x += historyWidth + g.hoverGap

        let ellipsisWidth = draw("⋯", at: x, in: rect, font: ellipsisFont,
                                 color: NSColor(hex: 0xA3A09A))
        menuRect = NSRect(x: x - g.hoverGap / 2, y: rect.minY,
                          width: ellipsisWidth + g.hoverGap + 6, height: rect.height)
    }

    private func drawRecording(in rect: NSRect) {
        let g = geometry
        var x = rect.minX + g.recordingPadding
        x += drawWave(at: x, in: rect, bars: 7, height: g.recordingWaveHeight,
                      color: SD.C.voiceDark, live: true)
        x += g.recordingGap
        x += draw(timerText, at: x, in: rect, font: timerFont,
                  color: NSColor(hex: 0xF2F1EE))
        x += g.recordingGap
        drawDivider(at: x, in: rect)
        x += 1 + g.recordingGap
        draw(cancelHint, at: x, in: rect, font: hintFont,
             color: NSColor(hex: 0xA3A09A))
    }

    @discardableResult
    private func draw(_ text: String, at x: CGFloat, in rect: NSRect,
                      font: NSFont, color: NSColor) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [NSAttributedString.Key: Any] = [.font: resolvedFont(font),
                                                         .foregroundColor: color]
        var width: CGFloat = 0
        do {
            try withObjCExceptionsAsErrors {
                let size = (text as NSString).size(withAttributes: attributes)
                let origin = NSPoint(x: x, y: rect.midY - size.height / 2)
                (text as NSString).draw(at: origin, withAttributes: attributes)
                width = size.width
            }
        } catch {
            noteTextLayoutFailure(error, font: font)
            width = CGFloat(text.count) * font.pointSize * 0.62
        }
        return ceil(width)
    }

    private func drawDivider(at x: CGFloat, in rect: NSRect) {
        NSColor(hex: 0xFFFFFF, alpha: 0.16).setFill()
        NSBezierPath(rect: NSRect(x: x, y: rect.midY - 8, width: 1, height: 16)).fill()
    }

    /// Волна. В покое и под действиями — застывший глиф, при записи дышит по
    /// уровню звука: та же волна, что в капсуле записи, чтобы человек узнавал
    /// один и тот же объект.
    @discardableResult
    private func drawWave(at x: CGFloat, in rect: NSRect, bars: Int,
                          height: CGFloat, color: NSColor, live: Bool) -> CGFloat {
        let barWidth: CGFloat = 2
        let gap: CGFloat = 2
        color.setFill()
        for index in 0..<bars {
            let ratio: CGFloat
            if live {
                let wave = sin(phase * 2 + CGFloat(index) * 0.9)
                let loudness = CGFloat(max(0, min(1, level)))
                ratio = 0.28 + 0.72 * loudness * (0.55 + 0.45 * (wave + 1) / 2)
            } else {
                // Застывший глиф: средний столбик выше, края ниже — тот же
                // рисунок, что у иконки в строке меню.
                let distance = abs(CGFloat(index) - CGFloat(bars - 1) / 2)
                ratio = max(0.3, 1 - distance * 0.3)
            }
            let barHeight = max(2, height * ratio)
            let barRect = NSRect(x: x + CGFloat(index) * (barWidth + gap),
                                 y: rect.midY - barHeight / 2,
                                 width: barWidth, height: barHeight)
            NSBezierPath(roundedRect: barRect, xRadius: 1, yRadius: 1).fill()
        }
        return waveWidth(bars: bars, height: height)
    }

    // MARK: - Мышь

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // Следим только за самой капсулой: окно шире на тень, и наведение на
        // пустой угол не должно раскрывать действия.
        let area = NSTrackingArea(rect: capsuleRect,
                                  options: [.mouseEnteredAndExited, .activeAlways],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    var onHoverChange: ((Bool) -> Void)?
    var onDragMoved: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onAction: ((FloatingCapsuleAction) -> Void)?

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }

    private var dragStart: NSPoint?
    private var didDrag = false

    override func mouseDown(with event: NSEvent) {
        dragStart = event.locationInWindow
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart, let window else { return }
        didDrag = true
        // Тащим за любую точку капсулы: положение окна = где сейчас курсор
        // минус то, за какое место его взяли.
        let cursor = NSEvent.mouseLocation
        window.setFrameOrigin(NSPoint(x: cursor.x - dragStart.x, y: cursor.y - dragStart.y))
        onDragMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil }
        if didDrag {
            onDragEnded?()
            return
        }
        // Нажатие без перетаскивания — это нажатие.
        if let action = action(at: convert(event.locationInWindow, from: nil)) {
            onAction?(action)
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        guard state == .hover else { return }
        for rect in [dictateRect, historyRect, menuRect] where !rect.isEmpty {
            addCursorRect(rect, cursor: .pointingHand)
        }
    }

    /// Клик в прозрачный угол окна не должен ни таскать капсулу, ни нажимать:
    /// для системы этого места как будто нет.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let radius = capsuleRect.height / 2
        let path = NSBezierPath(roundedRect: capsuleRect, xRadius: radius, yRadius: radius)
        return path.contains(local) ? self : nil
    }

    func action(at point: NSPoint) -> FloatingCapsuleAction? {
        guard state == .hover else { return nil }
        if menuRect.contains(point) { return .menu }
        if historyRect.contains(point) { return .history }
        if dictateRect.contains(point) { return .dictate }
        return nil
    }
}

enum FloatingCapsuleAction {
    case dictate
    case history
    case menu
}

/// Рендер трёх состояний капсулы. Живьём два из них видно только под мышью
/// и во время диктовки, а сверять с макетом надо все.
@MainActor
func exportFloatingCapsulePreviews(to directory: URL,
                                   language: InterfaceLanguage = .russian,
                                   size: RecordingHUDSize = .large) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let states: [(String, FloatingCapsuleState)] = [
        ("1-idle", .idle), ("2-hover", .hover), ("3-recording", .recording),
    ]
    var exported = 0
    for (name, state) in states {
        let view = FloatingCapsuleView(frame: .zero)
        view.language = language
        view.geometry = FloatingCapsuleGeometry(size: size)
        view.hotkeyTitle = language == .english ? "⌘ ⌥" : "⌘ ⌥"
        view.state = state
        view.level = 0.72
        view.phase = 1.1
        view.elapsedSeconds = 14
        view.frame = NSRect(origin: .zero, size: view.windowSize(for: state))

        // Капсула прозрачная и тёмная: на прозрачном фоне её не разглядеть,
        // поэтому подкладываем светлую бумагу — как окно под ней.
        let host = PaperBackgroundView(frame: view.frame)
        host.fill = SD.C.paper
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { continue }
        // Large — имена как прежде: на них ссылаются документация и гифка.
        let prefix = size == .large ? "capsule-" : "capsule-\(size.rawValue)-"
        try png.write(to: directory.appendingPathComponent("\(prefix)\(name).png"))
        exported += 1
    }
    print("FLOATING_CAPSULE_PREVIEW exported \(exported) files to \(directory.path)")
}

/// Окно капсулы и всё, что делает её «всегда под рукой»: перетаскивание,
/// прилипание к краям и память места — своя для каждого монитора.
@MainActor
final class FloatingCapsuleController {
    weak var delegate: FloatingCapsuleDelegate?

    private var panel: NSPanel?
    private var view: FloatingCapsuleView?
    private(set) var state: FloatingCapsuleState = .idle
    private var isHovered = false
    /// Размер — общий с капсулой у курсора: одна настройка, одна геометрия.
    private var size: RecordingHUDSize = .standard
    private let settings = Settings.shared

    func applySize(_ newSize: RecordingHUDSize) {
        guard newSize != size else { return }
        size = newSize
        guard let view else { return }
        view.geometry = FloatingCapsuleGeometry(size: newSize)
        applyState(state, animated: false)
        clampIntoScreen()
    }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Показ и скрытие

    func show(hotkeyTitle: String, language: InterfaceLanguage) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        view?.hotkeyTitle = hotkeyTitle
        view?.language = language
        applyState(state, animated: false)
        if !panel.isVisible {
            let origin = restoredOrigin(for: panel)
            panel.setFrameOrigin(origin)
            panel.orderFrontRegardless()
            let remembered = storedOrigin() != nil
            log("floating capsule shown at \(Int(origin.x)),\(Int(origin.y)) "
                + (remembered ? "(remembered)" : "(default corner)"))
        }
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
        view = nil
        state = .idle
        isHovered = false
    }

    private func makePanel() -> NSPanel {
        let view = FloatingCapsuleView(frame: NSRect(origin: .zero,
                                                     size: NSSize(width: 200, height: 82)))
        view.geometry = FloatingCapsuleGeometry(size: size)
        let panel = NSPanel(contentRect: view.frame,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Тень рисуется внутри окна: у системной не задать ни радиус, ни
        // смещение, а в макете они разные для каждого состояния.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // Панель не активирующая: нажатие «Диктовать» не должно уводить фокус
        // из чужого поля ввода — иначе текст будет некуда вставлять.
        panel.becomesKeyOnlyIfNeeded = true

        view.onHoverChange = { [weak self] hovered in
            guard let self else { return }
            self.isHovered = hovered
            guard self.state != .recording else { return }
            self.applyState(hovered ? .hover : .idle, animated: true)
        }
        view.onDragMoved = { [weak self] in self?.clampIntoScreen() }
        view.onDragEnded = { [weak self] in
            self?.snapToEdges()
            self?.storeOrigin()
        }
        view.onAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .dictate: self.delegate?.floatingCapsuleDidRequestDictation()
            case .history: self.delegate?.floatingCapsuleDidRequestHistory()
            case .menu:
                let frame = self.panel?.frame ?? .zero
                self.delegate?.floatingCapsuleDidRequestMenu(
                    at: NSPoint(x: frame.maxX - FloatingCapsuleMetrics.shadowInset,
                                y: frame.minY + FloatingCapsuleMetrics.shadowInset))
            }
        }
        self.view = view
        return panel
    }

    // MARK: - Состояния

    func setRecording(_ recording: Bool) {
        if recording {
            applyState(.recording, animated: true)
        } else {
            applyState(isHovered ? .hover : .idle, animated: true)
        }
    }

    func update(level: Float, phase: CGFloat, elapsedSeconds: Int) {
        view?.level = level
        view?.phase = phase
        view?.elapsedSeconds = elapsedSeconds
    }

    func updateHotkey(_ title: String, language: InterfaceLanguage) {
        guard view?.hotkeyTitle != title || view?.language != language else { return }
        view?.hotkeyTitle = title
        view?.language = language
        applyState(state, animated: false)
    }

    /// Смена состояния — это смена размера одного окна. Якорь — центр
    /// капсулы: так она растёт «из себя», а не съезжает углом.
    private func applyState(_ newState: FloatingCapsuleState, animated: Bool) {
        guard let panel, let view else { return }
        state = newState
        view.state = newState
        let size = view.windowSize(for: newState)
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        let frame = NSRect(x: center.x - size.width / 2,
                           y: center.y - size.height / 2,
                           width: size.width, height: size.height)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = FloatingCapsuleMetrics.transitionSeconds
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        view.needsDisplay = true
        panel.invalidateCursorRects(for: view)
        clampIntoScreen()
    }

    // MARK: - Место на экране

    private func screenKey(for screen: NSScreen) -> String {
        let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number.map { "display-\($0.intValue)" } ?? "display-main"
    }

    private func currentScreen() -> NSScreen? {
        guard let panel else { return NSScreen.main }
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
    }

    /// Место, где капсула стояла в прошлый раз на этом мониторе. Незнакомый
    /// монитор получает угол по умолчанию — правый нижний, подальше от Дока
    /// внизу по центру.
    private func restoredOrigin(for panel: NSPanel) -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return .zero }
        let visible = screen.visibleFrame
        if let stored = storedOrigin() {
            return FloatingCapsuleMetrics.clampedOrigin(stored,
                                                        windowSize: panel.frame.size,
                                                        visibleFrame: visible)
        }
        let inset = FloatingCapsuleMetrics.shadowInset
        return NSPoint(x: visible.maxX - panel.frame.width + inset
                        - FloatingCapsuleMetrics.snapMargin,
                       y: visible.minY - inset + FloatingCapsuleMetrics.snapMargin + 40)
    }

    /// Запомненное место на текущем мониторе, если оно есть.
    private func storedOrigin() -> NSPoint? {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return nil }
        return settings.floatingCapsulePositions[screenKey(for: screen)]
    }

    private func storeOrigin() {
        guard let panel, let screen = currentScreen() else { return }
        var positions = settings.floatingCapsulePositions
        positions[screenKey(for: screen)] = panel.frame.origin
        settings.floatingCapsulePositions = positions
        log("floating capsule parked at \(Int(panel.frame.origin.x)),"
            + "\(Int(panel.frame.origin.y)) on \(screenKey(for: screen))")
    }

    private func clampIntoScreen() {
        guard let panel, let screen = currentScreen() else { return }
        let origin = FloatingCapsuleMetrics.clampedOrigin(panel.frame.origin,
                                                          windowSize: panel.frame.size,
                                                          visibleFrame: screen.visibleFrame)
        if origin != panel.frame.origin { panel.setFrameOrigin(origin) }
    }

    /// Прилипание: капсула, отпущенная у края, встаёт ровно вдоль него.
    /// Иначе она навсегда остаётся «почти у края» и выглядит забытой.
    private func snapToEdges() {
        guard let panel, let screen = currentScreen() else { return }
        let origin = FloatingCapsuleMetrics.snappedOrigin(windowFrame: panel.frame,
                                                          visibleFrame: screen.visibleFrame)
        guard origin != panel.frame.origin else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FloatingCapsuleMetrics.transitionSeconds
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
        }
    }
}
