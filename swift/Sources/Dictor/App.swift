import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - App
//
// Single class that owns the lifecycle and the AppKit menu-bar UI.
// All UI state lives here; subsystems (HotkeyListener, AudioCapture,
// TranscriptionWorker, UpdateCheck, …) hold their own state but
// call back into `DictorApp` for anything that touches the menu.

enum DictationReleaseShortcut: Equatable {
    case standard
    case alternate
}

func shouldPressEnterAfterDictation(
    shortcut: DictationReleaseShortcut,
    primaryBehavior: DictationCompletionBehavior
) -> Bool {
    let behavior = shortcut == .standard ? primaryBehavior : primaryBehavior.opposite
    return behavior.pressesEnter
}

@MainActor
final class CorrectionShareCleanupDelegate: NSObject, @preconcurrency NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    private let cleanup: (String) -> Void

    init(cleanup: @escaping (String) -> Void) {
        self.cleanup = cleanup
    }

    private func runCleanup(reason: String) {
        cleanup(reason)
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              delegateFor sharingService: NSSharingService) -> NSSharingServiceDelegate? {
        self
    }

    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker,
                              didChoose service: NSSharingService?) {
        if service == nil {
            runCleanup(reason: "dismissed")
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        runCleanup(reason: "shared")
    }

    func sharingService(_ sharingService: NSSharingService,
                        didFailToShareItems items: [Any],
                        error: Error) {
        runCleanup(reason: "share failed")
    }
}

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

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext.current?.cgContext {
            context.setShadow(offset: CGSize(width: 0, height: -SD.Metrics.capsuleShadowOffsetY),
                              blur: SD.Metrics.capsuleShadowRadius,
                              color: NSColor.black
                                  .withAlphaComponent(SD.Metrics.capsuleShadowAlpha * capsuleAlpha)
                                  .cgColor)
        }
        capsuleFill().withAlphaComponent(capsuleFillAlpha() * capsuleAlpha).setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()

        if showsCapsuleStroke {
            NSColor.white.withAlphaComponent(0.08 * capsuleAlpha).setStroke()
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
            width += ceil(layout.primaryText?.size().width ?? 0)
            if showsEscHint {
                layout.secondaryText = attributed(t("Esc — отменить", "Esc to cancel"),
                                                  font: SD.captionFont(size: captionFontSize),
                                                  color: SD.C.capsuleSecondaryText)
                width += gap + 1 + gap + ceil(layout.secondaryText?.size().width ?? 0)
            }
        case .transcribing:
            layout.wave = true
            width += waveSize.width + gap
            layout.primaryText = attributed(t("Распознаю…", "Transcribing…"),
                                            font: SD.labelFont(size: labelFontSize),
                                            color: SD.C.capsuleText)
            width += ceil(layout.primaryText?.size().width ?? 0)
        case .inserted:
            layout.check = true
            width += checkDiameter + 8
            let words = dictatedWordsLabel(insertedWordCount, language: interfaceLanguage)
            layout.primaryText = attributed(t("Вставлено · \(words)", "Inserted · \(words)"),
                                            font: SD.labelFont(size: labelFontSize),
                                            color: SD.C.capsuleText)
            width += ceil(layout.primaryText?.size().width ?? 0)
        case .error:
            layout.wave = true
            width += waveSize.width + gap
            let message = errorMessage ?? t("Не получилось распознать", "Dictation failed")
            layout.primaryText = attributed(message,
                                            font: SD.labelFont(size: labelFontSize),
                                            color: accentColor())
            width += ceil(layout.primaryText?.size().width ?? 0)
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
            let size = primary.size()
            primary.draw(at: NSPoint(x: x, y: capsuleRect.midY - size.height / 2))
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
            let size = secondary.size()
            secondary.draw(at: NSPoint(x: x, y: capsuleRect.midY - size.height / 2))
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

    private func attributed(_ text: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
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


let RECORDING_HUD_EXPORT_ARGUMENT = "--export-hud-animation"

@MainActor
/// Язык — параметром, а не из настроек: кадры для витрины проекта нужны на
/// английском, и снимать их, переключая язык живого приложения, значило бы
/// трогать чужие настройки ради картинки.
func exportRecordingHUDAnimationFrames(to directory: URL,
                                       language: InterfaceLanguage = Settings.shared.interfaceLanguage) throws {
    let fileManager = FileManager.default
    if fileManager.fileExists(atPath: directory.path) {
        try fileManager.removeItem(at: directory)
    }
    try fileManager.createDirectory(at: directory,
                                    withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])

    let hudSize = Settings.shared.recordingHUDSize
    let pointSize = hudSize.expandedSize
    let pixelScale: CGFloat = 4
    let pixelWidth = Int((pointSize.width * pixelScale).rounded())
    let pixelHeight = Int((pointSize.height * pixelScale).rounded())
    let framesPerSecond = 120.0
    let emptyLead = 0.35
    let recordingDuration = 6.20
    let transcribingDuration = 2.40
    let emptyTail = 0.50
    let totalDuration = emptyLead
        + RECORDING_HUD_ANIMATE_IN_SECONDS
        + recordingDuration
        + transcribingDuration
        + RECORDING_HUD_ANIMATE_OUT_SECONDS
        + emptyTail
    let frameCount = Int((totalDuration * framesPerSecond).rounded())

    let view = RecordingHUDView(frame: NSRect(origin: .zero, size: pointSize))
    view.interfaceLanguage = language
    view.visualScale = hudSize.visualScale
    let settings = Settings.shared
    view.recordingColor = settings.recordingHUDRecordingColor.nsColor
    view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
    view.backgroundStyle = .dark
    view.showsCapsuleStroke = false
    view.mode = .recording

    var phase: CGFloat = 0
    for frameIndex in 0..<frameCount {
        try autoreleasepool {
            let time = Double(frameIndex) / framesPerSecond
            let revealStart = emptyLead
            let recordingStart = revealStart + RECORDING_HUD_ANIMATE_IN_SECONDS
            let transcribingStart = recordingStart + recordingDuration
            let hideStart = transcribingStart + transcribingDuration
            let tailStart = hideStart + RECORDING_HUD_ANIMATE_OUT_SECONDS

            let reveal: CGFloat
            let level: Float
            let mode: RecordingHUDMode
            let transcribingElapsed: CGFloat?
            if time < revealStart {
                reveal = 0
                level = 0
                mode = .recording
                transcribingElapsed = nil
            } else if time < recordingStart {
                reveal = CGFloat((time - revealStart) / RECORDING_HUD_ANIMATE_IN_SECONDS)
                level = 0
                mode = .recording
                transcribingElapsed = nil
            } else if time < transcribingStart {
                reveal = 1
                let voiceTime = time - recordingStart
                let syllables = pow(max(0, sin((voiceTime * 8.7) + 0.35)), 0.58)
                let phrasing = 0.58 + (0.42 * ((sin((voiceTime * 2.15) - 0.7) + 1) / 2))
                let detail = 0.78 + (0.22 * ((sin((voiceTime * 13.4) + 1.8) + 1) / 2))
                level = Float(min(0.94, 0.10 + (0.78 * syllables * phrasing * detail)))
                mode = .recording
                transcribingElapsed = nil
            } else if time < hideStart {
                reveal = 1
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else if time < tailStart {
                reveal = 1 - CGFloat((time - hideStart) / RECORDING_HUD_ANIMATE_OUT_SECONDS)
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else {
                reveal = 0
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            }

            phase += recordingHUDPhaseSpeed(mode: mode, level: level)
                / CGFloat(framesPerSecond)
            view.revealProgress = max(0, min(1, reveal))
            view.mode = mode
            view.transcribingElapsedOverride = transcribingElapsed
            view.level = level
            view.phase = phase

            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                                                pixelsWide: pixelWidth,
                                                pixelsHigh: pixelHeight,
                                                bitsPerSample: 8,
                                                samplesPerPixel: 4,
                                                hasAlpha: true,
                                                isPlanar: false,
                                                colorSpaceName: .deviceRGB,
                                                bytesPerRow: 0,
                                                bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                throw NSError(domain: "DictorHUDExport", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not create an RGBA frame."])
            }
            bitmap.size = pointSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.clear(NSRect(origin: .zero, size: pointSize))
            context.cgContext.scaleBy(x: pixelScale, y: pixelScale)
            view.displayIgnoringOpacity(view.bounds, in: context)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()

            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw NSError(domain: "DictorHUDExport", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Could not encode a PNG frame."])
            }
            let name = String(format: "frame-%05d.png", frameIndex)
            try png.write(to: directory.appendingPathComponent(name), options: .atomic)
        }
    }

    print("HUD_EXPORT frames=\(frameCount) fps=120 size=\(pixelWidth)x\(pixelHeight) duration=\(String(format: "%.3f", totalDuration))")
}

struct UpdateProgressLaunch {
    let statePath: String
    let logPath: String
    let targetVersion: String
    let cleanupAppPath: String

    init?(arguments: [String]) {
        guard arguments.count >= 5,
              arguments[0] == UPDATE_PROGRESS_ARGUMENT,
              !arguments[1].isEmpty,
              !arguments[2].isEmpty,
              !arguments[3].isEmpty,
              !arguments[4].isEmpty else {
            return nil
        }

        statePath = arguments[1]
        logPath = arguments[2]
        targetVersion = arguments[3]
        cleanupAppPath = arguments[4]
    }
}

struct UpdateProgressState {
    let phase: String
    let message: String

    static func read(from path: String) -> UpdateProgressState? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .newlines)
        let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return UpdateProgressState(phase: String(parts[0]), message: String(parts[1]))
    }
}

func isSafeUpdateProgressCleanupPath(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let tempPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .standardizedFileURL
        .path
    let tempPrefix = tempPath.hasSuffix("/") ? tempPath : "\(tempPath)/"
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return url.path.hasPrefix(tempPrefix)
        && url.pathExtension == "app"
        && url.lastPathComponent.hasPrefix(UPDATE_PROGRESS_APP_PREFIX)
}

@MainActor
final class UpdateProgressAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let launch: UpdateProgressLaunch
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var closeWorkItem: DispatchWorkItem?
    private var lastPhase = ""
    private var lastMessage = ""

    private var messageLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var openReleaseButton: NSButton!
    private var closeButton: NSButton!

    init(launch: UpdateProgressLaunch) {
        self.launch = launch
    }

    private var language: InterfaceLanguage { Settings.shared.interfaceLanguage }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        pollState()
        pollTimer = Timer.scheduledTimer(timeInterval: 0.5,
                                         target: self,
                                         selector: #selector(updateProgressTimerFired(_:)),
                                         userInfo: nil,
                                         repeats: true)
        pollTimer?.tolerance = 0.15
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        closeWorkItem?.cancel()
        scheduleCopiedAppCleanup()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 184),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = t("Обновление Dictor", "Updating Dictor")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = updateProgressLabel(t("Обновление Dictor до v\(launch.targetVersion)",
                                          "Updating Dictor to v\(launch.targetVersion)"),
                                        font: .systemFont(ofSize: 18, weight: .semibold))
        messageLabel = updateProgressLabel(t("Запускаю обновление…", "Starting update…"),
                                           font: .systemFont(ofSize: 13, weight: .medium))
        detailLabel = updateProgressLabel(t("Dictor автоматически откроется после установки.",
                                             "Dictor will reopen automatically when the update finishes."),
                                          font: .systemFont(ofSize: 12),
                                          color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 390

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.usesThreadedAnimation = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.startAnimation(nil)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let openLog = NSButton(title: t("Открыть журнал", "Open Log"),
                               target: self,
                               action: #selector(openUpdateLogClicked(_:)))
        openLog.bezelStyle = .rounded

        openReleaseButton = NSButton(title: t("Открыть страницу релиза", "Open Release Page"),
                                     target: self,
                                     action: #selector(openReleasePageClicked(_:)))
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.isHidden = true

        closeButton = NSButton(title: t("Закрыть", "Close"),
                               target: self,
                               action: #selector(closeUpdateProgressClicked(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.isHidden = true

        buttonRow.addArrangedSubview(openLog)
        buttonRow.addArrangedSubview(openReleaseButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(closeButton)
        buttonRow.setHuggingPriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(title)
        root.addArrangedSubview(messageLabel)
        root.addArrangedSubview(progress)
        root.addArrangedSubview(detailLabel)
        root.addArrangedSubview(buttonRow)

        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: -(root.edgeInsets.left + root.edgeInsets.right)).isActive = true
        }

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 430),
            progress.heightAnchor.constraint(equalToConstant: 14),
        ])

        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateProgressLabel(_ text: String,
                                     font: NSFont,
                                     color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    @objc private func updateProgressTimerFired(_ timer: Timer) {
        pollState()
    }

    private func pollState() {
        let state = UpdateProgressState.read(from: launch.statePath)
            ?? UpdateProgressState(phase: "starting",
                                   message: t("Запускаю обновление…", "Starting update…"))
        guard state.phase != lastPhase || state.message != lastMessage else { return }

        lastPhase = state.phase
        lastMessage = state.message
        messageLabel.stringValue = state.message

        switch state.phase {
        case "failed":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Предыдущая версия сохранена. Подробности доступны в журнале.",
                                        "The previous version was preserved. Open the log for details.")
            openReleaseButton.isHidden = false
            closeButton.isHidden = false
            NSApp.activate(ignoringOtherApps: true)
        case "complete":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Обновлённое приложение открывается. Это окно скоро закроется.",
                                        "The updated app is opening. This window will close shortly.")
            closeButton.isHidden = false
            scheduleClose(after: 4)
        case "installing":
            detailLabel.stringValue = t("Старая версия закрыта, новая устанавливается. Приложение откроется автоматически.",
                                        "The old version has closed while the new one is installed. It will reopen automatically.")
        case "relaunching":
            detailLabel.stringValue = t("Запускаю новую версию Dictor.",
                                        "Opening the new version of Dictor.")
            scheduleClose(after: 0.5)
        default:
            detailLabel.stringValue = t("Dictor автоматически откроется после установки.",
                                        "Dictor will reopen automatically when the update finishes.")
        }
    }

    private func scheduleClose(after delay: TimeInterval) {
        guard closeWorkItem == nil else { return }
        let item = DispatchWorkItem { NSApp.terminate(nil) }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleCopiedAppCleanup() {
        guard isSafeUpdateProgressCleanupPath(launch.cleanupAppPath) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 2; /bin/rm -rf \"$1\"", "cleanup", launch.cleanupAppPath]
        proc.environment = systemToolProcessEnvironment()
        try? proc.run()
    }

    @objc private func openUpdateLogClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(fileURLWithPath: launch.logPath))
    }

    @objc private func openReleasePageClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(UPDATE_CHANNEL_PAGE)
    }

    @objc private func closeUpdateProgressClicked(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}

func formattedUsageInteger(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "ru_RU")
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    return formatter.string(from: NSNumber(value: max(0, value))) ?? String(max(0, value))
}

@MainActor
final class DictorApp: NSObject, NSApplicationDelegate, NSWindowDelegate, UpdateWindowDelegate {
    private struct CachedInsertionTarget {
        let target: FocusedInsertionTargetFrame
        let windowFrame: NSRect?
        let cachedAt: TimeInterval
    }

    private struct LastExternalClick {
        let applicationPID: pid_t
        let point: NSPoint
        let capturedAt: TimeInterval
    }

    private var statusItem: NSStatusItem!
    private var templateImage: NSImage?
    private var recordingImage: NSImage?
    private var errorImage: NSImage?
    private var recordingStartedAtUptime: TimeInterval?
    private var quickPanel: DictorQuickPanel?
    /// Пауза перед показом коротких состояний службы (макет 8c) — та же, что
    /// в подвале окна, чтобы шапка панели и подвал не расходились словами.
    private let quickPanelStatusHold = ServiceStatusHold()
    private var quickPanelStatusHoldTimer: Timer?
    /// Плавающая капсула (макет 6c). Живёт, только пока включена в настройках.
    private let floatingCapsule = FloatingCapsuleController()
    private var isDictationPaused = false
    private var menuBarGlyphPhase: CGFloat = 0
    private var lastMenuBarGlyphUpdateAt: TimeInterval = 0
    private var insertedHUDWorkItem: DispatchWorkItem?
    private let audio = AudioCapture()
    private let hotkey = HotkeyListener()
    private let asr = TranscriptionWorker()
    private let insertionTargetTracker = FocusedInsertionTargetTracker()
    private let settings = Settings.shared

    private var isRecording = false
    private var isBusy = false
    private var isReady = false
    private var isCoreRuntimeReady = false
    private var isSpeechModelReady = false
    private var isTerminating = false
    private var isResettingSpeechModelCache = false
    private var isSwitchingSpeechModel = false
    private var fallbackSpeechModelProfileAfterStartupFailure: SpeechModelProfile?
    private var startupTask: Task<Void, Never>?
    private var updateCheckLoopTask: Task<Void, Never>?
    private var manualUpdateCheckTask: Task<Void, Never>?
    private var startupStatusTitle = "Loading speech model…"
    private var speechModelStartupProgressFraction: Double?
    /// «Проверено N файлов модели из M» — то, чем занята служба первые
    /// секунды после запуска. Раньше это время выглядело как «Остановлена».
    private var verifiedModelFiles: Int?
    private var totalModelFiles: Int?
    private var lastDownloadPhase: DownloadUtils.DownloadPhase?
    private var startupFailure: StartupFailure?
    private var didTouchAudioEngine = false
    private var permissionReadinessTimer: Timer?
    private var lastPermissionReadinessMissingKey: String?
    /// Recording-time system-audio mute state machine. Main-actor
    /// only; transitions are driven by muteIfNeededForRecording /
    /// unmuteIfWeMuted and the SystemAudio.*Async completions. The
    /// pure decision logic lives in systemAudioMuteProbeDecision /
    /// systemAudioMuteCommandDecision / systemAudioUnmuteRequestDecision.
    private var systemAudioMutePhase: SystemAudioMutePhase = .idle
    /// Set when the recording ends while the probe or mute command is
    /// still in flight; the in-flight completion honours it.
    private var systemAudioUnmuteRequested = false
    private var maxDurationWorkItem: DispatchWorkItem?
    private var audioIdleStopWorkItem: DispatchWorkItem?
    private var isRestartingAudioInput = false
    private var pendingAudioRouteRefresh = false
    private var audioConfigurationChangeSuppressedUntil: TimeInterval?
    private var workspacePowerObservers: [NSObjectProtocol] = []
    private var hotkeyPausedForExternalCapture = false
    private var hotkeyCaptureFailsafeTimer: Timer?
    private var hotkeyRecorder: HotkeyRecorderController?
    private var shouldResumeRuntimeAfterWake = false
    private var didLogDeferredWakeRecovery = false
    private var setupChecklistWindow: NSWindow?
    private var setupChecklistRefreshTimer: Timer?
    private var hotkeyTestSucceeded = false
    private var recordingLevelTimer: Timer?
    private var recordingVisualLevel: Float = 0
    private var recordingHUDPhase: CGFloat = 0
    private var lastRecordingLevelSequence: UInt64 = 0
    private var staleRecordingLevelTicks = 0
    private var recordingHUDPanel: NSPanel?
    private var recordingHUDView: RecordingHUDView?
    private var recordingHUDTranscribingStartedAt: TimeInterval?
    private var recordingHUDAnimationToken = 0
    private var recordingHUDDisplayLink: CADisplayLink?
    private var lastRecordingHUDMotionAt: TimeInterval?
    private var lastRecordingHUDTargetRefreshAt: TimeInterval?
    private var recordingHUDRevealStartedAt: TimeInterval?
    private var recordingHUDRevealFrom: CGFloat = 0
    private var recordingHUDRevealTo: CGFloat = 1
    private var recordingHUDRevealDuration: TimeInterval = RECORDING_HUD_ANIMATE_IN_SECONDS
    private var recordingHUDRevealCompletion: (() -> Void)?
    private var recordingHUDRetargetWorkItem: DispatchWorkItem?
    private var recordingHUDInsertionTargetFrame: NSRect?
    private var recordingHUDInsertionTargetVisualFrame: NSRect?
    private var recordingHUDFallbackWindowFrame: NSRect?
    private var recordingHUDTargetStabilizer = RecordingHUDTargetStabilizer()
    private var recordingHUDTargetQueryInFlight = false
    private var recordingHUDTargetSessionToken = 0
    private var recordingHUDWaitingForInitialTarget = false
    private var insertionTargetCache: [pid_t: CachedInsertionTarget] = [:]
    private var globalMouseDownMonitor: Any?
    private var lastExternalClick: LastExternalClick?
    private var errorFlashWorkItem: DispatchWorkItem?
    private var systemAudioMuteWatchdog: Process?

    /// Local transcript archive, newest first. UI applies the user's visible limit.
    private var history: [TranscriptHistoryEntry] = []

    private var visibleHistory: [TranscriptHistoryEntry] {
        limitedRecentTranscriptEntries(history, limit: settings.recentTranscriptLimit)
    }

    /// In-session click counter per permission. Click #2 onwards
    /// resets the matching TCC entry before re-requesting — belt
    /// and braces for stuck DENIED entries macOS occasionally caches.
    private var permClickCount: [Permission: Int] = [:]

    /// Latest release detected by the periodic check. nil = no update,
    /// or user has skipped it.
    private var pendingUpdate: DictorRelease?
    private var isCheckingForUpdates = false
    /// Установка, запущенная из «Update now…». Держим задачу, чтобы второй
    /// клик не начал вторую загрузку, и версию — чтобы меню показывало, что
    /// идёт работа, а не молчало на десятках мегабайт скачивания.
    private var updateInstallTask: Task<Void, Never>?
    private var installingUpdateVersion: String?
    private var updateAvailableWindow: UpdateAvailableWindow?
    private var reminderPausedUpdateVersion: String?
    private var reminderPausedUntil: Date?

    private struct CorrectionImportSummary {
        let total: Int
        let newCount: Int
        let updatedCount: Int
        let unchangedCount: Int
    }

    private enum CorrectionImportChoice {
        case merge
        case replace
    }

    private var correctionSyncTimer: Timer?
    /// Хоткеи агент раньше читал только при старте, поэтому их смена
    /// требовала перезапуска службы. Таймер подхватывает их на лету.
    private var settingsWatchTimer: Timer?
    /// Что служба видела в настройках в прошлый тик. Нужны, чтобы отличать
    /// «человек поменял в окне» от «ничего не изменилось»: без сравнения
    /// перезапуск аудиовхода случался бы раз в секунду.
    private var lastSeenInputDevice: String?
    private var lastSeenCorrections: [TranscriptCorrection]?
    /// Байты архива истории, какими агент видел их в последний раз. Обновляется
    /// и собственными записями (persistHistoryArchive), и наблюдателем — чтобы
    /// «изменилось снаружи» не срабатывало на самих себя.
    private var lastSeenHistoryArchiveData: Data?
    private var lastAppliedHotkeySignature = ""
    private var correctionSyncFileFingerprint: CorrectionSyncFileFingerprint?
    private var correctionSyncBaselineCorrections: [TranscriptCorrection] = []
    private var isApplyingCorrectionSyncFile = false
    /// Serial queue for the periodic sync-file scan (validate + hash
    /// + read). The UI recommends putting the sync file in iCloud
    /// Drive, where open(2) on a dataless file can block for seconds
    /// while the content downloads — far too long for the main
    /// thread, which also services the session-wide hotkey event tap.
    /// `correctionSyncScanInFlight` (main-actor) guarantees scans
    /// never overlap; results hop back to the main actor, where the
    /// existing merge/apply logic runs unchanged.
    private static let correctionSyncScanQueue = DispatchQueue(label: "DictorCorrectionSyncScan",
                                                               qos: .utility)
    private var correctionSyncScanInFlight = false
    /// Scan request that arrived while a scan was in flight; re-issued
    /// (with the strongest flags seen) when the in-flight scan lands.
    private var pendingCorrectionSyncScan: (force: Bool, presentErrors: Bool)?
    private var correctionSharePicker: NSSharingServicePicker?
    private var correctionShareCleanupDelegate: CorrectionShareCleanupDelegate?
    private var pendingSharedCorrectionsURL: URL?

    // MARK: - Lifecycle

    private func completeReadinessIfPossible(reason: String) {
        let missing = (isReady || isCoreRuntimeReady) ? missingPermissions() : []
        switch readinessTransition(isReady: isReady,
                                   isCoreRuntimeReady: isCoreRuntimeReady,
                                   missingPermissions: missing) {
        case .rebuildMenuOnly:
            if isReady {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
            }
            rebuildMenu()
            return
        case .blockForPermissions(let missing):
            enterPermissionBlockedState(missing: missing, reason: reason)
            return
        case .startHotkeyListener:
            break
        }

        hotkey.onPress = { [weak self] in self?.handlePress() }
        hotkey.onRelease = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .standard, hotkeyDetectedAt: detectedAt)
        }
        hotkey.onReleaseAlternate = { [weak self] detectedAt in
            self?.handleRelease(shortcut: .alternate, hotkeyDetectedAt: detectedAt)
        }
        hotkey.onCancel = { [weak self] in self?.cancelActiveRecording(reason: "escape") }
        hotkey.onRejectedBusyPress = { [weak self] in
            guard let self, self.isBusy, self.settings.playFeedbackSounds else { return }
            Sounds.playError()
        }
        hotkey.isRecordingActive = { [weak self] in self?.isRecording == true }
        // Mirrors the first guard in handlePress — if this returns
        // false the press would be silently discarded, so toggle mode
        // must not flip state for it. The missing-permissions case is
        // deliberately NOT part of the gate: that press gives feedback
        // (enterPermissionBlockedState), which also resets the toggle.
        hotkey.canStartRecording = { [weak self] in
            guard let self else { return false }
            return self.isReady && !self.isRecording && !self.isBusy && !self.isTerminating
        }
        let hotkeyReady = hotkeyPausedForExternalCapture || hotkey.start()
        if hotkeyPausedForExternalCapture {
            log("HotkeyListener: startup completed while shortcut capture remains active")
        }
        guard hotkeyReady else {
            isReady = false
            isRecording = false
            isBusy = false
            hotkey.onPress = nil
            hotkey.onRelease = nil
            hotkey.onReleaseAlternate = nil
            hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
            hotkey.isRecordingActive = nil
            hotkey.canStartRecording = nil
            hotkey.resetToggleState()
            hotkey.stop()
            log("readiness failed (\(reason)): hotkey listener unavailable")
            setMenuBarState(.error)
            if missingPermissions().isEmpty {
                startupFailure = StartupFailure(stage: .hotkeyListener,
                                                detail: "The keyboard event tap could not be started.")
            } else {
                startPermissionReadinessMonitor(reason: reason)
            }
            rebuildMenu()
            return
        }

        isReady = true
        startupStatusTitle = "Ready"
        startupFailure = nil
        stopPermissionReadinessMonitor()
        setMenuBarState(.idle)
        refreshActivationPolicy()

        rebuildMenu()
        startUpdateCheckLoop()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if settings.normalizeSpeechModelProfileForCurrentBuild() {
            log("ASR: reset unsupported saved speech model selection to \(settings.speechModelProfile.shortName)")
        }

        DictorAgentService.refreshInstalledPlistIfNeeded()
        recoverStaleTCCAfterUpgrade()
        _ = previousExitNoticeAction(previousRunWasActive: settings.hasActiveRunMarker)
        recoverStaleSystemAudioMuteIfNeeded()
        settings.hasActiveRunMarker = true
        restoreUpdateReminderPause()
        history = settings.recentTranscriptEntries
        lastSeenHistoryArchiveData = settings.recentTranscriptEntriesStoredData
        importDictationUsageFromLogIfNeeded()

        // «Вставлено» показывается оптимистично: в момент ⌘V правды ещё нет,
        // а задерживать успех нельзя — сигнал чтения буфера надёжен только в
        // отрицательную сторону (менеджер буфера обмена читает всё подряд).
        // Правда приходит со страховкой транзакции: за текстом никто не
        // пришёл — значит, вставки точно не было, и молчать нельзя.
        ClipboardPasteInserter.onPasteNeverRead = { [weak self] keptInClipboard in
            self?.signalPasteNeverRead(keptInClipboard: keptInClipboard)
        }

        refreshActivationPolicy()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusItemImage()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        revealMenuBarIcon()
        setMenuBarState(.loading)
        startCorrectionSyncIfConfigured()
        rebuildMenu()
        applyFloatingCapsuleSettings()

        audio.onConfigurationChange = { [weak self] in
            Task { @MainActor in
                self?.handleAudioConfigurationChange()
            }
        }
        installWorkspacePowerObservers()
        installGlobalMouseMonitor()
        installHotkeyCaptureObservers()

        // Configure hotkey listener up front so it picks up the user's
        // saved choice the moment the tap goes live.
        applyHotkeySettings(force: true)
        startStartup(reason: "launch")
        startSettingsWatch()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openControlPanelFromAgent()
        return true
    }

    private func openControlPanelFromAgent(section: String? = nil) {
        if DictorControlPanelRegistry.activateExistingPanelIfPresent() {
            log("control panel activated from agent")
            if let section {
                // Окно уже открыто — просим его переключить раздел.
                DistributedNotificationCenter.default().postNotificationName(
                    CONTROL_PANEL_SECTION_NOTIFICATION,
                    object: section,
                    userInfo: nil,
                    deliverImmediately: true)
            }
            return
        }
        guard let executablePath = Bundle.main.executablePath else {
            log("control panel open failed: missing executable path")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = section.map { [CONTROL_PANEL_SECTION_ARGUMENT, $0] } ?? []
        process.environment = systemToolProcessEnvironment()
        do {
            try process.run()
            log("control panel opened from agent")
        } catch {
            log("control panel open failed: \(error.localizedDescription)")
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        guard !isTerminating else { return }
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        hotkeyRecorder?.cancel()
        hotkeyRecorder = nil
        publishAgentState(status: "stopping", detail: "Dictation service is stopping.")
        settings.hasActiveRunMarker = false
        startupTask?.cancel()
        startupTask = nil
        updateCheckLoopTask?.cancel()
        updateCheckLoopTask = nil
        manualUpdateCheckTask?.cancel()
        manualUpdateCheckTask = nil
        stopPermissionReadinessMonitor()
        stopSetupChecklistRefreshTimer()
        removeWorkspacePowerObservers()
        removeGlobalMouseMonitor()
        removeHotkeyCaptureObservers()
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        cleanupPendingSharedCorrections(reason: "terminate")
        audio.onConfigurationChange = nil
        cancelRecordingForTermination()
        // If the mute lifecycle is mid-flight or still holding the
        // mute, the watchdog must outlive us: the async unmute
        // requested by cancelRecordingForTermination may not run
        // before the process exits, and the watchdog unmutes + clears
        // the marker once our pid disappears.
        if systemAudioMutePhase == .idle {
            stopSystemAudioMuteWatchdog()
        }
    }

    private func installHotkeyCaptureObservers() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self,
                           selector: #selector(externalHotkeyCaptureDidBegin(_:)),
                           name: HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
                           object: nil)
        center.addObserver(self,
                           selector: #selector(externalHotkeyCaptureDidEnd(_:)),
                           name: HOTKEY_CAPTURE_END_NOTIFICATION,
                           object: nil)
    }

    private func removeHotkeyCaptureObservers() {
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = nil
        let center = DistributedNotificationCenter.default()
        center.removeObserver(self, name: HOTKEY_CAPTURE_BEGIN_NOTIFICATION, object: nil)
        center.removeObserver(self, name: HOTKEY_CAPTURE_END_NOTIFICATION, object: nil)
    }

    @objc private func externalHotkeyCaptureDidBegin(_ notification: Notification) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        hotkey.stop()
        hotkeyPausedForExternalCapture = true
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = Timer.scheduledTimer(
            withTimeInterval: HOTKEY_CAPTURE_FAILSAFE_SECONDS,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.resumeHotkeyAfterExternalCapture(reason: "failsafe")
            }
        }
        log("HotkeyListener: paused for control-panel shortcut capture")
    }

    @objc private func externalHotkeyCaptureDidEnd(_ notification: Notification) {
        resumeHotkeyAfterExternalCapture(reason: "control panel finished")
    }

    private func resumeHotkeyAfterExternalCapture(reason: String) {
        hotkeyCaptureFailsafeTimer?.invalidate()
        hotkeyCaptureFailsafeTimer = nil
        guard hotkeyPausedForExternalCapture, !isTerminating else { return }
        hotkeyPausedForExternalCapture = false
        guard isReady else {
            log("HotkeyListener: shortcut capture ended while service was not ready")
            return
        }
        guard hotkey.start() else {
            isReady = false
            recordStartupFailure(
                stage: .hotkeyListener,
                error: NSError(
                    domain: "Dictor",
                    code: -6,
                    userInfo: [NSLocalizedDescriptionKey: "The hotkey listener could not resume after shortcut capture."]
                ),
                reason: "external shortcut capture"
            )
            return
        }
        log("HotkeyListener: resumed after shortcut capture (\(reason))")
    }

    private func installWorkspacePowerObservers() {
        removeWorkspacePowerObservers()
        let center = NSWorkspace.shared.notificationCenter
        workspacePowerObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemWillSleep()
                }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification,
                               object: nil,
                               queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.handleSystemDidWake()
                }
            },
        ]
    }

    private func installGlobalMouseMonitor() {
        removeGlobalMouseMonitor()
        globalMouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            let point = NSEvent.mouseLocation
            let capturedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor [weak self] in
                guard let self,
                      !self.isTerminating,
                      let app = NSWorkspace.shared.frontmostApplication else {
                    return
                }
                self.lastExternalClick = LastExternalClick(
                    applicationPID: app.processIdentifier,
                    point: point,
                    capturedAt: capturedAt
                )
            }
        }
    }

    private func removeGlobalMouseMonitor() {
        if let globalMouseDownMonitor {
            NSEvent.removeMonitor(globalMouseDownMonitor)
            self.globalMouseDownMonitor = nil
        }
        lastExternalClick = nil
    }

    private func removeWorkspacePowerObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in workspacePowerObservers {
            center.removeObserver(observer)
        }
        workspacePowerObservers.removeAll()
    }

    private func cleanupPendingSharedCorrections(reason: String) {
        correctionSharePicker = nil
        correctionShareCleanupDelegate = nil

        guard let url = pendingSharedCorrectionsURL else { return }
        pendingSharedCorrectionsURL = nil

        let folder = url.deletingLastPathComponent().standardizedFileURL
        let tempRoot = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let normalizedTempRoot = tempRoot.hasSuffix("/") ? tempRoot : "\(tempRoot)/"

        guard url.lastPathComponent == CORRECTIONS_FILE_NAME,
              folder.lastPathComponent.hasPrefix("Dictor-"),
              folder.path.hasPrefix(normalizedTempRoot)
        else {
            log("correction share cleanup skipped (\(reason)): unexpected temp file")
            return
        }

        do {
            try FileManager.default.removeItem(at: folder)
            log("correction share cleanup completed (\(reason))")
        } catch {
            log("correction share cleanup failed (\(reason))")
        }
    }

    private func startStartup(reason: String) {
        guard startupTask == nil else {
            log("startup ignored (\(reason)): already in progress")
            rebuildMenu()
            return
        }

        prepareForStartupAttempt()
        let speechModelProfile = settings.speechModelProfile

        // Load ASR FIRST, then audio + hotkey. Reversing this order
        // makes the first-launch CoreML compile of the ANE Encoder
        // hang. The bench under experiments/swift-bench/ never opens
        // an audio session so it doesn't see this.
        startupTask = Task { @MainActor in
            var stage = StartupFailureStage.speechModel
            defer {
                startupTask = nil
                rebuildMenu()
                recoverRuntimeAfterWakeIfNeeded(reason: "startup finished after wake")
            }

            do {
                let throttler = ProgressThrottler()
                try await asr.load(
                    profile: speechModelProfile,
                    progressHandler: { [weak self] progress in
                        let title = speechModelStartupStatusTitle(progress)
                        let fraction = speechModelStartupProgressValue(progress)
                        guard throttler.shouldDispatch(title, fraction) else { return }
                        Task { @MainActor in
                            self?.updateSpeechModelStartupProgress(progress)
                        }
                    },
                    verificationProgress: { [weak self] verified, total in
                        Task { @MainActor in
                            self?.updateModelVerificationProgress(verified: verified, total: total)
                        }
                    })
                guard !Task.isCancelled, !isTerminating else { return }

                do {
                    let warmUpTiming = try await asr.warmUp()
                    log("ASR: CoreML warm-up completed in \(millisecondsLabel(warmUpTiming.totalSeconds))")
                } catch {
                    // Model loading succeeded, so a failed best-effort warm-up
                    // must not make the dictation service unavailable.
                    log("ASR: CoreML warm-up skipped: \(error.localizedDescription)")
                }
                guard !Task.isCancelled, !isTerminating else { return }

                fallbackSpeechModelProfileAfterStartupFailure = nil
                isSpeechModelReady = true
                speechModelStartupProgressFraction = nil

                await recoverPendingDictationsAfterStartup()
                guard !Task.isCancelled, !isTerminating else { return }

                stage = .audioInput
                startupStatusTitle = "Starting audio input…"
                rebuildMenu()

                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Starting audio input…")
                guard !Task.isCancelled, !isTerminating else { return }

                isCoreRuntimeReady = true
                startupFailure = nil
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !Task.isCancelled, !isTerminating else { return }
                recordStartupFailure(stage: stage, error: error, reason: reason)
            }
        }
    }

    private func recoverPendingDictationsAfterStartup() async {
        let pendingURLs = PendingDictationRecovery.pendingURLs()
        guard !pendingURLs.isEmpty else { return }

        settings.refreshFromDisk()
        startupStatusTitle = "Recovering interrupted dictation…"
        rebuildMenu()
        log("pending dictation recovery: \(pendingURLs.count) recording(s) found")

        for url in pendingURLs {
            guard !Task.isCancelled, !isTerminating else { return }
            do {
                let samples = try PendingDictationRecovery.loadSamples(from: url)
                guard !samples.isEmpty else {
                    PendingDictationRecovery.remove(url)
                    continue
                }
                let duration = Double(samples.count) / SAMPLE_RATE
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: samples,
                    language: settings.dictationLanguage.fluidLanguage,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                let processed = processedDictationText(rawTranscript: transcription.text,
                                                       corrections: settings.dictationTranscriptCorrections,
                                                       removeFillerWords: settings.removeFillerWords,
                                                       language: settings.dictationLanguage)
                if !processed.text.isEmpty {
                    addToHistory(
                        processed.text,
                        transcriptionDurationSeconds: timing.totalSeconds,
                        asrTiming: timing
                    )
                    recordDictationUsage(text: processed.text,
                                         audioSeconds: duration,
                                         asrSeconds: timing.totalSeconds)
                }
                PendingDictationRecovery.remove(url)
                log("pending dictation recovered: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
            } catch {
                log("pending dictation recovery deferred: \(error.localizedDescription)")
            }
        }
    }

    private func prepareForStartupAttempt() {
        cancelMaxDurationAutoRelease()

        if isRecording || audio.isRunning {
            let captured = audio.endRecording()
            if captured.recoveryURL != nil {
                log("startup restart: active dictation preserved for recovery")
            }
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isSpeechModelReady = false
        isRecording = false
        isBusy = false
        pendingAudioRouteRefresh = false
        shouldResumeRuntimeAfterWake = false
        didLogDeferredWakeRecovery = false
        startupFailure = nil
        startupStatusTitle = "Loading speech model…"
        speechModelStartupProgressFraction = nil

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            stopAudioEngineImmediately()
        }

        setMenuBarState(.loading)
        rebuildMenu()
    }

    private func updateModelVerificationProgress(verified: Int, total: Int) {
        guard !isTerminating else { return }
        verifiedModelFiles = verified
        totalModelFiles = total
        if verified >= total {
            // Проверка кончилась — число больше не актуально, дальше грузится
            // сама модель.
            verifiedModelFiles = nil
            totalModelFiles = nil
        }
        publishAgentState()
    }

    private func updateSpeechModelStartupProgress(_ progress: DownloadUtils.DownloadProgress) {
        guard startupTask != nil, !isTerminating else { return }
        let next = speechModelStartupStatusTitle(progress)
        let nextProgressFraction = speechModelStartupProgressValue(progress)
        guard next != startupStatusTitle
            || nextProgressFraction != speechModelStartupProgressFraction else { return }
        startupStatusTitle = next
        speechModelStartupProgressFraction = nextProgressFraction
        lastDownloadPhase = progress.phase
        publishAgentState()
        rebuildMenu()
    }

    private func recordStartupFailure(stage: StartupFailureStage, error: Error, reason: String) {
        if stage == .speechModel,
           let fallback = fallbackSpeechModelProfileAfterStartupFailure,
           fallback != settings.speechModelProfile,
           !isTerminating {
            let failedProfile = settings.speechModelProfile
            fallbackSpeechModelProfileAfterStartupFailure = nil
            settings.speechModelProfile = fallback
            isSwitchingSpeechModel = true
            isCoreRuntimeReady = false
            isSpeechModelReady = false
            isReady = false
            isRecording = false
            isBusy = false
            startupFailure = nil
            startupStatusTitle = "Falling back to \(fallback.shortName)…"
            speechModelStartupProgressFraction = nil
            setMenuBarState(.loading)
            log("ASR: \(failedProfile.shortName) failed to load during switch; falling back to \(fallback.shortName): \(startupFailureLogDetail(stage: stage, error: error))")
            rebuildMenu()
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isTerminating else { return }
                Task { @MainActor in
                    await self.asr.unload()
                    self.isSwitchingSpeechModel = false
                    self.startStartup(reason: "speech model fallback")
                }
            }
            return
        }

        fallbackSpeechModelProfileAfterStartupFailure = nil
        isCoreRuntimeReady = false
        if stage == .speechModel {
            isSpeechModelReady = false
        }
        isReady = false
        isRecording = false
        isBusy = false
        speechModelStartupProgressFraction = nil
        stopRecordingLevelMeter()

        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        if didTouchAudioEngine {
            stopAudioEngineImmediately()
        }

        let detail = startupFailureDetail(stage: stage, error: error)
        startupFailure = StartupFailure(stage: stage, detail: detail)
        log("startup failed (\(reason), \(stage)): \(startupFailureLogDetail(stage: stage, error: error))")
        setMenuBarState(.error)
        if !missingPermissions().isEmpty {
            startPermissionReadinessMonitor(reason: reason)
        }
        rebuildMenu()
    }

    private func startAudioInputWithRetries(reason: String,
                                            initialStatusTitle: String) async throws {
        let totalAttempts = AUDIO_START_RETRY_DELAYS_SECONDS.count + 1
        var lastError: Error?

        for attempt in 1...totalAttempts {
            try Task.checkCancellation()
            guard !isTerminating else { throw CancellationError() }

            startupStatusTitle = attempt == 1
                ? initialStatusTitle
                : "Starting audio input… (\(attempt)/\(totalAttempts))"
            rebuildMenu()

            do {
                didTouchAudioEngine = true
                suppressAudioConfigurationChangesFromAppEngineUpdate()
                try audio.startEngine(inputDevicePreference: settings.inputDevice)
                stopAudioEngineImmediately()
                return
            } catch {
                lastError = error
                stopAudioEngineImmediately()
                log("audio startup attempt \(attempt)/\(totalAttempts) failed (\(reason)): \(singleLineLogDetail(audioStartupErrorDescription(error)))")

                guard let delay = audioStartupRetryDelaySeconds(afterFailedAttempt: attempt) else {
                    throw error
                }

                startupStatusTitle = audioStartupRetryStatusTitle(nextAttempt: attempt + 1,
                                                                  totalAttempts: totalAttempts,
                                                                  delaySeconds: delay)
                rebuildMenu()
                try await Task.sleep(nanoseconds: delay * 1_000_000_000)
            }
        }

        if let lastError {
            throw lastError
        }
    }

    // MARK: - Sleep/wake runtime recovery

    private func handleSystemWillSleep() {
        guard !isTerminating else { return }

        if shouldResumeRuntimeAfterSystemSleep(isTerminating: isTerminating,
                                               isCoreRuntimeReady: isCoreRuntimeReady,
                                               isReady: isReady,
                                               isRecording: isRecording,
                                               audioIsRunning: audio.isRunning) {
            shouldResumeRuntimeAfterWake = true
            didLogDeferredWakeRecovery = false
        }

        if isRecording || audio.isRunning {
            cancelActiveRecording(reason: "system sleep", runDeferredRefresh: false)
        }

        guard isCoreRuntimeReady || isReady else {
            rebuildMenu()
            return
        }

        pauseAudioRuntimeForSystemSleep()
    }

    private func handleSystemDidWake() {
        guard !isTerminating else { return }
        guard shouldResumeRuntimeAfterWake else { return }
        log("system wake detected")
        recoverRuntimeAfterWakeIfNeeded(reason: "system wake")
    }

    private func pauseAudioRuntimeForSystemSleep() {
        cancelMaxDurationAutoRelease()
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        pendingAudioRouteRefresh = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        stopAudioEngineImmediately()

        startupFailure = nil
        startupStatusTitle = "Waiting for system wake…"
        setMenuBarState(isBusy ? .busy : .loading)
        log("system sleep: audio runtime paused")
        rebuildMenu()
    }

    private func recoverRuntimeAfterWakeIfNeeded(reason: String) {
        switch wakeRuntimeRecoveryAction(shouldResumeAfterWake: shouldResumeRuntimeAfterWake,
                                         isTerminating: isTerminating,
                                         hasStartupTask: startupTask != nil,
                                         isBusy: isBusy,
                                         isSpeechModelReady: isSpeechModelReady) {
        case .ignore:
            return
        case .deferUntilIdle:
            if !didLogDeferredWakeRecovery {
                didLogDeferredWakeRecovery = true
                log("system wake recovery deferred until idle")
            }
            rebuildMenu()
        case .startAudioRuntime:
            shouldResumeRuntimeAfterWake = false
            didLogDeferredWakeRecovery = false
            startAudioRuntimeAfterWake(reason: reason)
        case .startFullStartup:
            shouldResumeRuntimeAfterWake = false
            didLogDeferredWakeRecovery = false
            startStartup(reason: reason)
        }
    }

    private func startAudioRuntimeAfterWake(reason: String) {
        guard !isRestartingAudioInput else {
            return
        }
        guard startupTask == nil, !isBusy, !isTerminating else {
            shouldResumeRuntimeAfterWake = true
            recoverRuntimeAfterWakeIfNeeded(reason: reason)
            return
        }

        isReady = false
        isCoreRuntimeReady = false
        isRecording = false
        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        startupFailure = nil
        startupStatusTitle = "Restarting audio input…"
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()
        stopAudioEngineImmediately()
        setMenuBarState(.loading)
        rebuildMenu()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Restarting audio input…")
                guard !isTerminating else { return }
                isCoreRuntimeReady = true
                startupStatusTitle = "Finishing setup…"
                completeReadinessIfPossible(reason: reason)
            } catch {
                guard !isTerminating else { return }
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
    }

    // MARK: - Permission readiness

    private func enterPermissionBlockedState(missing: [Permission]? = nil, reason: String) {
        let missing = missing ?? missingPermissions()
        guard !missing.isEmpty else {
            completeReadinessIfPossible(reason: reason)
            return
        }

        if isRecording || audio.isRunning {
            recoverActiveRecordingToHistory(reason: "permission lost: \(reason)") { [weak self] in
                self?.enterPermissionBlockedState(missing: missing, reason: reason)
            }
            return
        }

        cancelMaxDurationAutoRelease()
        if audio.isEngineStarted {
            stopAudioEngineImmediately()
        }
        stopRecordingLevelMeter()
        unmuteIfWeMuted()

        isReady = false
        isRecording = false
        isBusy = false
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.resetToggleState()
        hotkey.stop()

        logPermissionReadinessWait(missing)
        startPermissionReadinessMonitor(reason: reason)
        setMenuBarState(.loading)
        rebuildMenu()
    }

    private func missingPermissions() -> [Permission] {
        Permission.allCases.filter { !Permissions.isGranted($0) }
    }

    @discardableResult
    private func logPermissionReadinessWait(_ missing: [Permission]) -> Bool {
        let key = missing.map(\.rawValue).joined(separator: "|")
        guard key != lastPermissionReadinessMissingKey else { return false }
        lastPermissionReadinessMissingKey = key
        log("readiness retry waiting for permissions: \(missing.map(\.rawValue).joined(separator: ", "))")
        return true
    }

    /// Слежение за настройками хоткеев. Панель пишет их в UserDefaults,
    /// агент подхватывает без перезапуска — «Сохранить и перезапустить»
    /// пользователю больше не нужен.
    private func startSettingsWatch() {
        guard settingsWatchTimer == nil else { return }
        settingsWatchTimer = Timer.scheduledTimer(timeInterval: 1.0,
                                                  target: self,
                                                  selector: #selector(settingsWatchTimerFired(_:)),
                                                  userInfo: nil,
                                                  repeats: true)
        settingsWatchTimer?.tolerance = 0.3
    }

    @objc private func settingsWatchTimerFired(_ timer: Timer) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        _ = settings.refreshFromDisk()
        applyHotkeySettings(force: false)
        applyFloatingCapsuleSettings()
        applyLiveSettings()
    }

    /// Настройки, которые окно меняет, а служба обязана подхватить сама.
    ///
    /// Хоткеи и капсула умели это и раньше, а вот микрофон и словарь — нет:
    /// человек выбирал в окне другой микрофон, окно молчало, и диктовка
    /// продолжала писать со старого до перезапуска службы. Со словарём было
    /// зеркально: запись, добавленная из окна, не попадала в файл
    /// синхронизации, потому что писал его только тот, кто правил словарь в
    /// самой службе.
    ///
    /// Сравнение с прошлым значением здесь не оптимизация, а условие
    /// работоспособности: таймер тикает раз в секунду, а перезапуск аудиовхода
    /// стоит дорого.
    private func applyLiveSettings() {
        let device = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        if shouldRestartAudioInput(previous: lastSeenInputDevice, current: device) {
            log("input device changed in settings: restarting audio")
            restartAudioForInputDeviceChange()
        }
        lastSeenInputDevice = device

        // Сравнение самого списка: `TranscriptCorrection` равнимая, а разница в
        // числе записей отсекается первой — раз в секунду это ничего не стоит.
        let corrections = settings.transcriptCorrections
        if let previous = lastSeenCorrections, previous != corrections {
            log("corrections changed outside the agent: writing the sync file")
            _ = writeCorrectionsToSyncFile(presentErrors: false)
        }
        lastSeenCorrections = corrections

        // История: окно стирает её целиком или удаляет запись, а агент держал
        // копию с момента старта — и на каждой диктовке записывал её поверх
        // стёртого. «Действие необратимо» отменялось первой же диктовкой.
        // Сравниваются сырые байты архива, декодирование — только при
        // реальном внешнем изменении.
        let historyData = settings.recentTranscriptEntriesStoredData
        if historyData != lastSeenHistoryArchiveData {
            lastSeenHistoryArchiveData = historyData
            history = settings.recentTranscriptEntries
            log("history changed outside the agent: reloaded (\(history.count) entries)")
            rebuildMenu()
        }

        // Цикл проверки обновлений стартует один раз при готовности службы, и
        // если тумблер в тот момент был выключен, включение обратно не
        // поднимало его до перезапуска: тумблер «включено», «Приватность»
        // обещает «1 раз в 6 ч», а служба в сеть не ходит. Вызов идемпотентен
        // и дёшев — внутри два guard'а: по настройке и по уже живому циклу.
        startUpdateCheckLoop()
    }

    // MARK: - Плавающая капсула (макет 6c)

    /// Капсулу включают и выключают из настроек, как и хоткеи, — без
    /// перезапуска службы.
    func applyFloatingCapsuleSettings() {
        guard settings.floatingCapsuleEnabled else {
            if floatingCapsule.isVisible { floatingCapsule.close() }
            return
        }
        floatingCapsule.delegate = self
        let title = capsuleHotkeyTitle()
        if floatingCapsule.isVisible {
            floatingCapsule.updateHotkey(title, language: settings.interfaceLanguage)
        } else {
            floatingCapsule.show(hotkeyTitle: title, language: settings.interfaceLanguage)
        }
    }

    /// В покое капсула показывает ровно то, что человек нажимает.
    private func capsuleHotkeyTitle() -> String {
        keycapLabels(for: settings.configuredHotkey, language: settings.interfaceLanguage)
            .joined(separator: " ")
    }

    private func hotkeySignature() -> String {
        [settings.configuredHotkey.name,
         settings.configuredEnterHotkey.name,
         settings.alternateCompletionEnabled ? "1" : "0",
         settings.triggerMode.rawValue].joined(separator: "|")
    }

    private func applyHotkeySettings(force: Bool) {
        let signature = hotkeySignature()
        guard force || signature != lastAppliedHotkeySignature else { return }
        lastAppliedHotkeySignature = signature
        hotkey.setHotkey(settings.configuredHotkey)
        hotkey.setEnterHotkey(settings.configuredEnterHotkey)
        hotkey.setAlternateCompletionEnabled(settings.alternateCompletionEnabled)
        hotkey.setTriggerMode(settings.triggerMode)
        if !force {
            log("hotkeys reloaded without restart → \(settings.configuredHotkey.name)")
            rebuildMenu()
            publishAgentState()
        }
    }

    private func startPermissionReadinessMonitor(reason: String) {
        guard permissionReadinessTimer == nil else { return }
        log("permission readiness monitor started (\(reason))")
        permissionReadinessTimer = Timer.scheduledTimer(timeInterval: 2,
                                                        target: self,
                                                        selector: #selector(permissionReadinessTimerFired(_:)),
                                                        userInfo: nil,
                                                        repeats: true)
        permissionReadinessTimer?.tolerance = 0.5
    }

    private func stopPermissionReadinessMonitor() {
        guard permissionReadinessTimer != nil else { return }
        permissionReadinessTimer?.invalidate()
        permissionReadinessTimer = nil
        lastPermissionReadinessMissingKey = nil
        log("permission readiness monitor stopped")
    }

    @objc private func permissionReadinessTimerFired(_ timer: Timer) {
        guard isCoreRuntimeReady else {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            if logPermissionReadinessWait(missing) {
                rebuildMenu()
            }
            return
        }

        if isReady {
            let missing = missingPermissions()
            guard !missing.isEmpty else {
                permClickCount.removeAll()
                stopPermissionReadinessMonitor()
                rebuildMenu()
                return
            }
            enterPermissionBlockedState(missing: missing, reason: "permission monitor")
            return
        }

        completeReadinessIfPossible(reason: "permission monitor")
    }

    // MARK: - File imports

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var didImport = false
        for filename in filenames {
            let url = URL(fileURLWithPath: filename)
            if importCorrectionsFromUserSelectedFile(url) {
                didImport = true
            }
        }
        sender.reply(toOpenOrPrint: didImport ? .success : .failure)
    }

    // MARK: - Menu bar appearance
    //
    // Same silhouette across all states; only colour shifts. The
    // template image is used for idle/loading/busy so it auto-adapts to
    // light/dark menu bar. For recording/error we swap to pre-rendered,
    // non-template images: NSStatusItem.button silently drops
    // contentTintColor on template images in some macOS configurations,
    // so baking the colour into the image is the only reliable way to
    // guarantee the recording state actually reads.

    private func configureStatusItemImage() {
        guard let button = statusItem.button else { return }
        // Глиф «линия голоса» рисуется кодом (VoiceLineGlyph) — PNG из
        // Resources больше не нужен. Idle/busy — template (система сама
        // красит под светлую/тёмную панель), error — линия + коралловая
        // точка. Recording анимируется в recordingLevelTimerFired.
        let image = VoiceLineGlyph.image(bars: VoiceLineGlyph.idleBars)
        templateImage = image
        recordingImage = VoiceLineGlyph.image(
            bars: VoiceLineGlyph.recordingBars(level: 0, phase: 0)
        )
        errorImage = VoiceLineGlyph.errorImage()
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Dictor"
    }

    private func revealMenuBarIcon() {
        statusItem.length = NSStatusItem.squareLength
        statusItem.button?.isHidden = false
        statusItem.button?.toolTip = "Dictor"
    }

    private func setMenuBarState(_ state: MenuBarState) {
        guard let button = statusItem.button else { return }
        switch state {
        case .loading:
            // Subtle dim while the model compiles. nil contentTintColor
            // = system default (black/white per theme); .tertiary gives
            // a "this is here but not yet active" feel.
            button.image = templateImage
            button.contentTintColor = .tertiaryLabelColor
        case .idle:
            // Default tint — macOS auto-handles light/dark menu bar.
            button.image = templateImage
            button.contentTintColor = nil
        case .recording:
            button.image = recordingImage ?? templateImage
            button.contentTintColor = nil
        case .busy:
            // Ровные полубары — «замерли, распознаём». Transcribe обычно
            // короткий, поэтому без анимации.
            button.image = VoiceLineGlyph.image(bars: VoiceLineGlyph.busyBars)
            button.contentTintColor = nil
        case .error:
            button.image = errorImage ?? templateImage
            button.contentTintColor = nil
        case .paused:
            button.image = VoiceLineGlyph.image(bars: VoiceLineGlyph.pausedBars)
            button.contentTintColor = .tertiaryLabelColor
        }
    }

    private func startRecordingLevelMeter(initialContext: InsertionTargetQueryContext?) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        recordingHUDPhase = 0
        recordingHUDInsertionTargetFrame = nil
        recordingHUDInsertionTargetVisualFrame = nil
        recordingHUDFallbackWindowFrame = nil
        recordingHUDTranscribingStartedAt = nil
        lastRecordingHUDTargetRefreshAt = nil
        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        recordingHUDTargetSessionToken &+= 1
        recordingHUDTargetQueryInFlight = false
        recordingHUDWaitingForInitialTarget = settings.showRecordingWaveform
        recordingHUDTargetStabilizer.reset(initialApplicationPID: initialContext?.applicationPID)
        recordingStartedAtUptime = ProcessInfo.processInfo.systemUptime
        menuBarGlyphPhase = 0
        lastMenuBarGlyphUpdateAt = 0
        recordingHUDView?.resetWave()
        setMenuBarState(.recording)
        // Капсула переходит в состояние записи тем же движением, что и растёт:
        // человек видит, что это она, а не новое окно.
        floatingCapsule.setRecording(true)
        let timer = Timer(timeInterval: 1.0 / 24.0,
                          target: self,
                          selector: #selector(recordingLevelTimerFired(_:)),
                          userInfo: nil,
                          repeats: true)
        timer.tolerance = 1.0 / 48.0
        RunLoop.main.add(timer, forMode: .common)
        recordingLevelTimer = timer

        if let initialContext {
            requestRecordingHUDTarget(context: initialContext, isInitial: true)
        } else {
            recordingHUDWaitingForInitialTarget = false
            log("text insertion target unavailable at recording start: frontmost application unavailable")
            if settings.showRecordingWaveform {
                showRecordingHUD(mode: .recording, level: 0)
            }
        }
    }

    private func stopRecordingLevelMeter(resetImage: Bool = true, hideHUD: Bool = true) {
        recordingLevelTimer?.invalidate()
        recordingLevelTimer = nil
        recordingVisualLevel = 0
        lastRecordingLevelSequence = 0
        staleRecordingLevelTicks = 0
        if !isRecording {
            stopRecordingHUDTargetTracking(clearTarget: false)
        }
        if hideHUD {
            recordingHUDPhase = 0
            hideRecordingHUD()
        }
        // Капсула возвращается к покою (или к действиям, если курсор всё ещё
        // на ней) при любом конце записи — в том числе когда HUD остаётся ради
        // «распознаю…»: своего состояния распознавания у капсулы нет, и под
        // if hideHUD она навсегда застревала в «идёт запись».
        floatingCapsule.setRecording(false)
        if resetImage, isRecording {
            setMenuBarState(.recording)
        }
    }

    @objc private func recordingLevelTimerFired(_ timer: Timer) {
        guard isRecording else {
            stopRecordingLevelMeter()
            return
        }
        let snapshot = audio.latestRecordingLevelSnapshot()
        if snapshot.sequence == lastRecordingLevelSequence {
            staleRecordingLevelTicks += 1
        } else {
            lastRecordingLevelSequence = snapshot.sequence
            staleRecordingLevelTicks = 0
        }
        let unsuppressedLevel = staleRecordingLevelTicks > 8 ? 0 : snapshot.level
        let rawLevel = visibleRecordingLevel(rawLevel: unsuppressedLevel)
        let attack: Float = rawLevel > recordingVisualLevel ? 0.65 : 0.28
        recordingVisualLevel += (rawLevel - recordingVisualLevel) * attack
        let now = ProcessInfo.processInfo.systemUptime
        if let startedAt = recordingStartedAtUptime {
            recordingHUDView?.recordingElapsed = now - startedAt
        }
        // Живой глиф в меню-баре: бары от реального RMS, 8 fps.
        if now - lastMenuBarGlyphUpdateAt >= 0.12 {
            lastMenuBarGlyphUpdateAt = now
            menuBarGlyphPhase += 0.9
            let bars = VoiceLineGlyph.recordingBars(level: CGFloat(recordingVisualLevel),
                                                    phase: menuBarGlyphPhase)
            let image = VoiceLineGlyph.image(bars: bars)
            recordingImage = image
            statusItem.button?.image = image
        }
        // Плавающая капсула сама растёт под голос — это тот же объект, а не
        // второе окно (макет 6c). Пока она на экране, отдельный HUD не нужен.
        if floatingCapsule.isVisible {
            floatingCapsule.update(level: recordingVisualLevel,
                                   phase: CGFloat(menuBarGlyphPhase),
                                   elapsedSeconds: Int(now - (recordingStartedAtUptime ?? now)))
        }
        refreshRecordingHUDInsertionTargetIfNeeded(at: now)
        if settings.showRecordingWaveform {
            guard !recordingHUDWaitingForInitialTarget else { return }
            if recordingHUDPanel?.isVisible == true {
                updateRecordingHUD(mode: .recording, level: recordingVisualLevel)
            } else {
                showRecordingHUD(mode: .recording, level: recordingVisualLevel)
            }
        } else {
            hideRecordingHUD()
        }
    }

    private var recordingHUDExpandedSize: NSSize {
        settings.recordingHUDSize.expandedSize
    }

    private func showRecordingHUD(mode: RecordingHUDMode,
                                  level: Float) {
        guard settings.showRecordingWaveform else { return }
        // «Один и тот же объект меняет размер — не появляется новое окно»
        // (макет 6c): при включённой капсуле запись показывается в ней.
        guard !floatingCapsule.isVisible else { return }
        let panel = recordingHUDPanel ?? makeRecordingHUDPanel()
        recordingHUDPanel = panel
        let shouldAnimate = !panel.isVisible
        if let view = recordingHUDView {
            configureRecordingHUDView(view)
            view.mode = mode
            view.level = level
            view.phase = recordingHUDPhase
        }
        if shouldAnimate {
            animateRecordingHUDIn(panel)
        } else {
            recordingHUDAnimationToken += 1
            stopRecordingHUDRevealAnimation(finish: true)
            panel.alphaValue = 1
            recordingHUDView?.revealProgress = 1
            panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize), display: true)
            panel.orderFrontRegardless()
        }
        startRecordingHUDMotion()
    }

    private func updateRecordingHUD(mode: RecordingHUDMode,
                                    level: Float) {
        if let view = recordingHUDView {
            configureRecordingHUDView(view)
            view.mode = mode
            view.level = level
            view.phase = recordingHUDPhase
        }
    }

    private func showTranscribingHUD() {
        guard settings.showRecordingWaveform else { return }
        recordingHUDTranscribingStartedAt = ProcessInfo.processInfo.systemUptime
        if recordingHUDPanel?.isVisible == true {
            updateRecordingHUD(mode: .transcribing, level: 0)
        } else {
            showRecordingHUD(mode: .transcribing, level: 0)
        }
        startRecordingHUDMotion()
    }

    private func hideRecordingHUD() {
        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        guard let panel = recordingHUDPanel else {
            stopRecordingHUDMotion()
            recordingHUDInsertionTargetFrame = nil
            recordingHUDInsertionTargetVisualFrame = nil
            recordingHUDFallbackWindowFrame = nil
            lastRecordingHUDTargetRefreshAt = nil
            stopRecordingHUDTargetTracking(clearTarget: true)
            return
        }
        recordingHUDAnimationToken += 1
        stopRecordingHUDRevealAnimation(finish: false)
        guard panel.isVisible else {
            stopRecordingHUDMotion()
            panel.alphaValue = 1
            panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize), display: false)
            recordingHUDView?.mode = .recording
            recordingHUDView?.level = 0
            recordingHUDView?.phase = 0
            recordingHUDView?.revealProgress = 1
            recordingHUDInsertionTargetFrame = nil
            recordingHUDInsertionTargetVisualFrame = nil
            recordingHUDFallbackWindowFrame = nil
            lastRecordingHUDTargetRefreshAt = nil
            stopRecordingHUDTargetTracking(clearTarget: true)
            return
        }

        let token = recordingHUDAnimationToken
        panel.alphaValue = 1
        panel.setFrame(recordingHUDFrame(size: recordingHUDExpandedSize),
                       display: false)
        startRecordingHUDRevealAnimation(from: recordingHUDView?.revealProgress ?? 1,
                                         to: 0,
                                         duration: RECORDING_HUD_ANIMATE_OUT_SECONDS) { [weak panel, weak self] in
            guard let self, let panel else { return }
            guard self.recordingHUDAnimationToken == token else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
            panel.setFrame(self.recordingHUDFrame(size: self.recordingHUDExpandedSize),
                           display: false)
            self.recordingHUDView?.mode = .recording
            self.recordingHUDView?.level = 0
            self.recordingHUDView?.phase = 0
            self.recordingHUDView?.revealProgress = 1
            self.recordingHUDInsertionTargetFrame = nil
            self.recordingHUDInsertionTargetVisualFrame = nil
            self.recordingHUDFallbackWindowFrame = nil
            self.lastRecordingHUDTargetRefreshAt = nil
            self.stopRecordingHUDTargetTracking(clearTarget: true)
            self.stopRecordingHUDMotion()
        }
    }

    private func startRecordingHUDMotion() {
        guard recordingHUDDisplayLink == nil,
              let view = recordingHUDView else {
            return
        }
        lastRecordingHUDMotionAt = ProcessInfo.processInfo.systemUptime
        let displayLink = view.displayLink(target: self,
                                           selector: #selector(recordingHUDDisplayLinkFired(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: RECORDING_HUD_DISPLAY_LINK_MIN_FPS,
            maximum: RECORDING_HUD_DISPLAY_LINK_MAX_FPS,
            preferred: RECORDING_HUD_DISPLAY_LINK_MAX_FPS
        )
        displayLink.add(to: .main, forMode: .common)
        recordingHUDDisplayLink = displayLink
    }

    private func stopRecordingHUDMotion() {
        recordingHUDDisplayLink?.invalidate()
        recordingHUDDisplayLink = nil
        lastRecordingHUDMotionAt = nil
    }

    @objc private func recordingHUDDisplayLinkFired(_ displayLink: CADisplayLink) {
        let hudIsVisible = recordingHUDPanel?.isVisible == true
        guard hudIsVisible || recordingHUDRevealStartedAt != nil else {
            stopRecordingHUDMotion()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let previous = lastRecordingHUDMotionAt ?? now
        let dt = max(0.001, min(0.05, now - previous))
        lastRecordingHUDMotionAt = now

        advanceRecordingHUDRevealAnimation(at: now)
        let mode = recordingHUDView?.mode
            ?? ((isBusy && !isRecording) ? .transcribing : .recording)
        let speed = recordingHUDPhaseSpeed(mode: mode, level: recordingVisualLevel)
        recordingHUDPhase += CGFloat(dt) * speed
        recordingHUDView?.phase = recordingHUDPhase
        _ = moveRecordingHUDTowardInsertionTarget(deltaTime: dt)
        recordingHUDView?.displayIfNeeded()
    }

    private func makeRecordingHUDPanel() -> NSPanel {
        let size = recordingHUDExpandedSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        let view = RecordingHUDView(frame: NSRect(origin: .zero, size: size))
        configureRecordingHUDView(view)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        recordingHUDView = view
        return panel
    }

    private func configureRecordingHUDView(_ view: RecordingHUDView) {
        view.visualScale = settings.recordingHUDSize.visualScale
        view.hudSize = settings.recordingHUDSize
        view.recordingColor = settings.recordingHUDRecordingColor.nsColor
        view.transcribingColor = settings.recordingHUDTranscribingColor.nsColor
        view.backgroundStyle = settings.recordingHUDBackgroundStyle
        view.interfaceLanguage = settings.interfaceLanguage
    }

    /// Капсула-подтверждение: галочка + «Вставлено · N слов», hold
    /// 0.9 с, затем растворение. Показывается только если HUD включён.
    private func showInsertedHUD(wordCount: Int) {
        guard settings.showRecordingWaveform else { return }
        insertedHUDWorkItem?.cancel()
        recordingHUDTranscribingStartedAt = nil
        recordingHUDView?.insertedWordCount = wordCount
        if recordingHUDPanel?.isVisible == true {
            updateRecordingHUD(mode: .inserted, level: 0)
        } else {
            showRecordingHUD(mode: .inserted, level: 0)
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.insertedHUDWorkItem = nil
            guard !self.isRecording, !self.isBusy else { return }
            self.hideRecordingHUD()
        }
        insertedHUDWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + SD.Anim.insertedHoldSeconds,
                                      execute: work)
    }

    private func animateRecordingHUDIn(_ panel: NSPanel) {
        recordingHUDAnimationToken += 1
        stopRecordingHUDRevealAnimation(finish: false)
        let finalFrame = recordingHUDFrame(size: recordingHUDExpandedSize)
        recordingHUDView?.revealProgress = 0
        panel.alphaValue = 1
        panel.setFrame(finalFrame, display: true)
        panel.contentView?.displayIfNeeded()
        panel.displayIfNeeded()
        panel.orderFrontRegardless()
        startRecordingHUDRevealAnimation(from: 0,
                                         to: 1,
                                         duration: RECORDING_HUD_ANIMATE_IN_SECONDS)
    }

    private func recordingHUDFrame(size: NSSize) -> NSRect {
        switch settings.recordingHUDPlacement {
        case .bottomCenter:
            return recordingHUDFrameAtScreenCenter(size: size, atBottom: true)
        case .topCenter:
            return recordingHUDFrameAtScreenCenter(size: size, atBottom: false)
        case .followsInput:
            break
        }
        if let targetFrame = recordingHUDInsertionTargetVisualFrame ?? recordingHUDInsertionTargetFrame {
            return recordingHUDFrameAboveTarget(targetFrame, size: size)
        }
        if let fallbackWindow = recordingHUDFallbackWindowFrame {
            return recordingHUDFrameInsideFallbackWindow(fallbackWindow, size: size)
        }
        let visible = NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = visible.midX - (size.width / 2)
        let y = visible.maxY - size.height - 96
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    /// По центру того экрана, где сейчас курсор — на нём же пользователь
    /// и печатает. 96 pt от края повторяют отступ, с которым капсула
    /// висит сверху, когда поле ввода не нашлось.
    private func recordingHUDFrameAtScreenCenter(size: NSSize, atBottom: Bool) -> NSRect {
        let visible = screenFor(point: NSEvent.mouseLocation).visibleFrame
        return NSRect(x: visible.midX - (size.width / 2),
                      y: atBottom ? visible.minY + 96 : visible.maxY - size.height - 96,
                      width: size.width,
                      height: size.height)
    }

    private func recordingHUDFrameInsideFallbackWindow(_ windowFrame: NSRect,
                                                       size: NSSize) -> NSRect {
        let screen = screenFor(point: NSPoint(x: windowFrame.midX, y: windowFrame.midY))
        let visible = screen.visibleFrame
        let contentInset = min(180, max(28, windowFrame.width * 0.15))
        let preferredX = windowFrame.minX + contentInset
        let preferredY = windowFrame.minY + min(96, max(44, windowFrame.height * 0.14))
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let y = min(max(preferredY, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    private func recordingHUDFrameAboveTarget(_ targetFrame: NSRect, size: NSSize) -> NSRect {
        let center = NSPoint(x: targetFrame.midX, y: targetFrame.midY)
        let visible = screenFor(point: center).visibleFrame
        let gap: CGFloat = 12
        let preferredX = targetFrame.minX + 6
        let preferredY = targetFrame.maxY + gap + 8
        let fallbackY = targetFrame.minY - gap - size.height
        let y = preferredY + size.height <= visible.maxY - 8
            ? preferredY
            : fallbackY
        let x = min(max(preferredX, visible.minX + 12), visible.maxX - size.width - 12)
        let clampedY = min(max(y, visible.minY + 12), visible.maxY - size.height - 12)
        return NSRect(x: x, y: clampedY, width: size.width, height: size.height)
    }

    private func startRecordingHUDRevealAnimation(from: CGFloat,
                                                  to: CGFloat,
                                                  duration: TimeInterval,
                                                  completion: (() -> Void)? = nil) {
        recordingHUDRevealFrom = max(0, min(1, from))
        recordingHUDRevealTo = max(0, min(1, to))
        let distance = abs(recordingHUDRevealTo - recordingHUDRevealFrom)
        recordingHUDRevealDuration = max(1.0 / Double(RECORDING_HUD_DISPLAY_LINK_MAX_FPS),
                                         duration * Double(distance))
        recordingHUDRevealCompletion = completion
        recordingHUDView?.revealProgress = recordingHUDRevealFrom
        recordingHUDRevealStartedAt = ProcessInfo.processInfo.systemUptime
        startRecordingHUDMotion()
    }

    private func stopRecordingHUDRevealAnimation(finish: Bool) {
        recordingHUDRevealStartedAt = nil
        let finalProgress = recordingHUDRevealTo
        let completion = recordingHUDRevealCompletion
        recordingHUDRevealCompletion = nil
        if finish {
            recordingHUDView?.revealProgress = finalProgress
            completion?()
        }
    }

    private func advanceRecordingHUDRevealAnimation(at now: TimeInterval) {
        guard let startedAt = recordingHUDRevealStartedAt,
              let view = recordingHUDView else {
            return
        }
        let elapsed = now - startedAt
        let progress = min(1, max(0, elapsed / recordingHUDRevealDuration))
        // The view gives each visual layer its own quintic curve. Keep this
        // master timeline linear so those curves do not get double-eased.
        view.revealProgress = recordingHUDRevealFrom
            + ((recordingHUDRevealTo - recordingHUDRevealFrom) * CGFloat(progress))
        if progress >= 1 {
            stopRecordingHUDRevealAnimation(finish: true)
        }
    }

    private func insertionTargetQueryContext() -> InsertionTargetQueryContext? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let referenceMaxY = screens.first?.frame.maxY
            ?? NSScreen.main?.frame.maxY
            ?? 0
        let now = ProcessInfo.processInfo.systemUptime
        let clickPoint: NSPoint?
        if let lastExternalClick,
           lastExternalClick.applicationPID == app.processIdentifier,
           now - lastExternalClick.capturedAt <= RECORDING_HUD_TARGET_CACHE_MAX_AGE {
            clickPoint = lastExternalClick.point
        } else {
            clickPoint = nil
        }
        return InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: referenceMaxY,
            lastClickPoint: clickPoint
        )
    }

    private func requestRecordingHUDTarget(context: InsertionTargetQueryContext? = nil,
                                           isInitial: Bool = false) {
        guard isRecording, !recordingHUDTargetQueryInFlight else { return }
        guard let context = context ?? insertionTargetQueryContext() else {
            if isInitial {
                recordingHUDWaitingForInitialTarget = false
                if settings.showRecordingWaveform {
                    showRecordingHUD(mode: .recording, level: recordingVisualLevel)
                }
            }
            return
        }

        recordingHUDTargetQueryInFlight = true
        let sessionToken = recordingHUDTargetSessionToken
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await self.insertionTargetTracker.query(context: context)
            guard self.recordingHUDTargetSessionToken == sessionToken,
                  self.isRecording else {
                return
            }
            self.recordingHUDTargetQueryInFlight = false
            self.handleRecordingHUDTargetResult(result, isInitial: isInitial)
        }
    }

    private func handleRecordingHUDTargetResult(_ result: FocusedInsertionTargetQueryResult,
                                                isInitial: Bool) {
        lastRecordingHUDTargetRefreshAt = ProcessInfo.processInfo.systemUptime
        if let focusedWindowFrame = result.focusedWindowFrame {
            recordingHUDFallbackWindowFrame = focusedWindowFrame
        }

        let liveTarget = result.target.flatMap {
            shouldUseRecordingHUDInsertionTarget($0) ? $0 : nil
        }
        let observedTarget = liveTarget ?? cachedInsertionTarget(for: result)
        let decision = recordingHUDTargetStabilizer.observe(observedTarget)
        switch decision {
        case .none:
            break
        case .update(let target):
            applyRecordingHUDTarget(target,
                                    queryResult: result,
                                    animateSwitch: false,
                                    updateCache: liveTarget != nil)
        case .switchTarget(let target):
            applyRecordingHUDTarget(target,
                                    queryResult: result,
                                    animateSwitch: recordingHUDPanel?.isVisible == true,
                                    updateCache: liveTarget != nil)
        }

        if isInitial {
            recordingHUDWaitingForInitialTarget = false
            if let liveTarget {
                log("text insertion target captured at recording start: \(liveTarget.resolutionKind), frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            } else if observedTarget != nil {
                log("text insertion target restored from recent cache, frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            } else {
                log("text insertion target unavailable at recording start, frontmost: \(result.applicationName) (\(result.bundleIdentifier)); \(result.diagnostic)")
            }
            if settings.showRecordingWaveform {
                showRecordingHUD(mode: .recording, level: recordingVisualLevel)
            }
        } else if liveTarget != nil,
                  case .switchTarget(let target) = decision {
            log("text insertion target switched during recording: \(target.resolutionKind), frontmost: \(result.applicationName) (\(result.bundleIdentifier))")
        }
    }

    private func applyRecordingHUDTarget(_ target: FocusedInsertionTargetFrame,
                                         queryResult: FocusedInsertionTargetQueryResult,
                                         animateSwitch: Bool,
                                         updateCache: Bool) {
        let previousTargetFrame = recordingHUDInsertionTargetVisualFrame
            ?? recordingHUDInsertionTargetFrame
        recordingHUDInsertionTargetFrame = target.frame
        recordingHUDInsertionTargetVisualFrame = target.visualFrame
        if updateCache {
            insertionTargetCache[target.identity.applicationPID] = CachedInsertionTarget(
                target: target,
                windowFrame: queryResult.focusedWindowFrame,
                cachedAt: ProcessInfo.processInfo.systemUptime
            )
        }
        if animateSwitch {
            animateRecordingHUDRetargetIfNeeded(from: previousTargetFrame,
                                                to: target.visualFrame)
        }
    }

    private func cachedInsertionTarget(for result: FocusedInsertionTargetQueryResult) -> FocusedInsertionTargetFrame? {
        guard let cached = insertionTargetCache[result.applicationPID],
              ProcessInfo.processInfo.systemUptime - cached.cachedAt <= RECORDING_HUD_TARGET_CACHE_MAX_AGE else {
            insertionTargetCache[result.applicationPID] = nil
            return nil
        }
        if result.focusedWindowToken != 0,
           cached.target.identity.windowToken != 0,
           result.focusedWindowToken != cached.target.identity.windowToken {
            return nil
        }

        var frame = cached.target.frame
        var visualFrame = cached.target.visualFrame
        if let oldWindow = cached.windowFrame,
           let newWindow = result.focusedWindowFrame {
            let dx = newWindow.minX - oldWindow.minX
            let dy = newWindow.minY - oldWindow.minY
            frame = frame.offsetBy(dx: dx, dy: dy)
            visualFrame = visualFrame.offsetBy(dx: dx, dy: dy)
            guard newWindow.insetBy(dx: -80, dy: -80).intersects(visualFrame) else {
                return nil
            }
        }
        return FocusedInsertionTargetFrame(
            frame: frame,
            visualFrame: visualFrame,
            resolutionKind: "\(cached.target.resolutionKind) cache",
            identity: cached.target.identity
        )
    }

    private func stopRecordingHUDTargetTracking(clearTarget: Bool) {
        recordingHUDTargetSessionToken &+= 1
        recordingHUDTargetQueryInFlight = false
        recordingHUDWaitingForInitialTarget = false
        lastRecordingHUDTargetRefreshAt = nil
        if clearTarget {
            recordingHUDTargetStabilizer.reset(initialApplicationPID: nil)
            recordingHUDFallbackWindowFrame = nil
        }
    }

    private func refreshRecordingHUDInsertionTargetIfNeeded(at now: TimeInterval) {
        guard isRecording else { return }
        if let last = lastRecordingHUDTargetRefreshAt,
           now - last < RECORDING_HUD_TARGET_REFRESH_INTERVAL {
            return
        }
        lastRecordingHUDTargetRefreshAt = now
        requestRecordingHUDTarget()
    }

    private func shouldUseRecordingHUDInsertionTarget(_ target: FocusedInsertionTargetFrame) -> Bool {
        let frame = target.visualFrame
        guard frame.minX.isFinite,
              frame.minY.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 0,
              frame.height > 0 else {
            return false
        }

        let visible = screenFor(point: NSPoint(x: frame.midX, y: frame.midY)).visibleFrame
        if frame.width > visible.width * 0.92,
           frame.height > visible.height * 0.55 {
            return false
        }
        if frame.height > visible.height * 0.82 {
            return false
        }
        return true
    }

    private func moveRecordingHUDTowardInsertionTarget(deltaTime: TimeInterval) -> Bool {
        guard let panel = recordingHUDPanel,
              panel.isVisible,
              recordingHUDView?.revealProgress == 1 else {
            return false
        }

        let target = recordingHUDFrame(size: recordingHUDExpandedSize)
        guard recordingHUDRetargetWorkItem == nil else {
            return true
        }

        let current = panel.frame
        let deltaX = target.midX - current.midX
        let deltaY = target.midY - current.midY
        if abs(deltaX) < 0.35, abs(deltaY) < 0.35 {
            if !NSEqualRects(current, target) {
                panel.setFrame(target, display: false)
            }
            return true
        }

        let response = 1 - CGFloat(exp(-Double(RECORDING_HUD_TARGET_FOLLOW_RESPONSE) * deltaTime))
        let nextCenter = NSPoint(x: current.midX + (deltaX * response),
                                 y: current.midY + (deltaY * response))
        let size = recordingHUDExpandedSize
        let next = NSRect(x: nextCenter.x - (size.width / 2),
                          y: nextCenter.y - (size.height / 2),
                          width: size.width,
                          height: size.height)
        panel.setFrame(clampedRecordingHUDFrame(next), display: false)
        return true
    }

    private func animateRecordingHUDRetargetIfNeeded(from previousTargetFrame: NSRect?,
                                                     to newTargetFrame: NSRect) {
        guard isRecording else { return }
        guard let panel = recordingHUDPanel,
              panel.isVisible,
              recordingHUDView?.mode == .recording else {
            return
        }

        let target = recordingHUDFrameAboveTarget(newTargetFrame,
                                                  size: recordingHUDExpandedSize)
        let distance = hypot(target.midX - panel.frame.midX,
                             target.midY - panel.frame.midY)
        guard distance > 8 else {
            if distance > 1 {
                panel.setFrame(target, display: false)
            }
            return
        }
        if let previousTargetFrame,
           hypot(previousTargetFrame.midX - newTargetFrame.midX,
                 previousTargetFrame.midY - newTargetFrame.midY) < 3,
           abs(previousTargetFrame.width - newTargetFrame.width) < 3,
           abs(previousTargetFrame.height - newTargetFrame.height) < 3 {
            return
        }

        recordingHUDRetargetWorkItem?.cancel()
        recordingHUDRetargetWorkItem = nil
        recordingHUDAnimationToken += 1
        let token = recordingHUDAnimationToken
        stopRecordingHUDRevealAnimation(finish: false)

        startRecordingHUDRevealAnimation(from: recordingHUDView?.revealProgress ?? 1,
                                         to: 0,
                                         duration: RECORDING_HUD_ANIMATE_OUT_SECONDS) { [weak self, weak panel] in
            let work = DispatchWorkItem { [weak self, weak panel] in
                guard let self, let panel else { return }
                self.recordingHUDRetargetWorkItem = nil
                guard self.recordingHUDAnimationToken == token else { return }
                panel.setFrame(target, display: false)
                self.recordingHUDView?.revealProgress = 0
                panel.alphaValue = 1
                panel.contentView?.displayIfNeeded()
                panel.displayIfNeeded()
                panel.orderFrontRegardless()
                self.startRecordingHUDRevealAnimation(from: 0,
                                                      to: 1,
                                                      duration: RECORDING_HUD_ANIMATE_IN_SECONDS)
            }
            self?.recordingHUDRetargetWorkItem = work
            DispatchQueue.main.async(execute: work)
        }
    }

    private func screenFor(point: NSPoint) -> NSScreen {
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
            return screen
        }
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            return screen
        }
        preconditionFailure("NSScreen.screens unexpectedly empty")
    }

    private func clampedRecordingHUDFrame(_ frame: NSRect) -> NSRect {
        let screen = screenFor(point: NSPoint(x: frame.midX, y: frame.midY))
        let visible = screen.visibleFrame
        let x = min(max(frame.minX, visible.minX + 12), visible.maxX - frame.width - 12)
        let y = min(max(frame.minY, visible.minY + 12), visible.maxY - frame.height - 12)
        return NSRect(x: x, y: y, width: frame.width, height: frame.height)
    }

    private func finishBusyHUD() {
        if let startedAt = recordingHUDTranscribingStartedAt {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            let remaining = RECORDING_HUD_TRANSCRIBING_MIN_VISIBLE_SECONDS - elapsed
            if remaining > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    guard let self,
                          !self.isRecording,
                          !self.isBusy,
                          self.recordingHUDTranscribingStartedAt == startedAt else { return }
                    self.recordingHUDTranscribingStartedAt = nil
                    self.hideRecordingHUD()
                }
                return
            }
        }
        recordingHUDTranscribingStartedAt = nil
        hideRecordingHUD()
    }

    // Visible + audible cue that a press produced no pasted text — the
    // transcription threw, or the paste itself failed. Without it the menu
    // bar just slips back to idle and the user can't tell their speech was
    // dropped from "pasted somewhere I wasn't looking."
    //
    // The error sound honours playFeedbackSounds — the HUD flash
    // (added below) already solves the original "invisible error"
    // problem for users who run silent. Gating the sound avoids
    // unexpected noise during meetings or screen recordings.
    private func signalDictationFailure(message: String? = nil,
                                        holdSeconds: TimeInterval = DICTATION_ERROR_FLASH_SECONDS) {
        if settings.playFeedbackSounds {
            Sounds.playError()
        }
        flashErrorFeedback(message: message, holdSeconds: holdSeconds)
    }

    /// Через restoreTimeout после «Вставлено» выяснилось, что за текстом никто
    /// не пришёл: ⌘V не дошёл (Secure Input, зависшее окно, перехваченное
    /// сочетание). Текст цел — в «Истории» и, как правило, в буфере — и об
    /// этом надо сказать вслух.
    private func signalPasteNeverRead(keptInClipboard: Bool) {
        guard !isTerminating else { return }
        guard !isRecording, !isBusy else {
            // Человек уже диктует снова — вспышка и звук сейчас помешают
            // записи. След остаётся в логе транзакции.
            log("paste-never-read signal suppressed: a new dictation is in progress")
            return
        }
        let language = settings.interfaceLanguage
        let message = keptInClipboard
            ? localizedText("Текст не вставился — он в буфере и в «Истории»",
                            "The text never pasted — it's in the clipboard and History",
                            language: language)
            : localizedText("Текст не вставился — он в «Истории»",
                            "The text never pasted — it's in History",
                            language: language)
        signalDictationFailure(message: message,
                               holdSeconds: PASTE_NEVER_READ_FLASH_SECONDS)
    }

    /// Flashes both the menu-bar icon (error tint) and the recording
    /// HUD (static yellow capsule with exclamation mark) for
    /// DICTATION_ERROR_FLASH_SECONDS. A single work item owns both
    /// channels so they always expire together.
    private func flashErrorFeedback(message: String? = nil,
                                    holdSeconds: TimeInterval = DICTATION_ERROR_FLASH_SECONDS) {
        errorFlashWorkItem?.cancel()
        // Invalidate any pending delayed hide from finishBusyHUD() —
        // without this the transcribing cleanup closure fires shortly
        // after and hides the error capsule prematurely.
        recordingHUDTranscribingStartedAt = nil
        setMenuBarState(.error)
        if settings.showRecordingWaveform {
            showRecordingHUD(mode: .error, level: 0)
            // После показа: до него view может ещё не существовать. nil
            // возвращает капсуле общий текст «Не получилось распознать» —
            // сообщение прошлой вспышки не должно пережить её саму.
            recordingHUDView?.errorMessage = message
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.errorFlashWorkItem = nil
            // Only clear if nothing else has claimed the icon meanwhile — a
            // new recording, an in-flight transcription, a real (non-transient)
            // error state, or termination all own it and must not be stomped.
            guard self.isReady, !self.isRecording, !self.isBusy, !self.isTerminating else { return }
            self.setMenuBarState(.idle)
            self.hideRecordingHUD()
            self.rebuildMenu()
        }
        errorFlashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdSeconds, execute: work)
    }

    // MARK: - Recording loop

    private func handlePress() {
        guard !isDictationPaused else { return }
        guard isReady, !isRecording, !isBusy, !isTerminating else {
            // Audible cue when the previous transcription is still in
            // flight — without it the press vanishes silently and the
            // user thinks the hotkey broke. Only fires for the busy
            // case; model-loading and termination have their own UI.
            if isBusy, settings.playFeedbackSounds {
                Sounds.playError()
            }
            return
        }
        let missing = missingPermissions()
        guard missing.isEmpty else {
            enterPermissionBlockedState(missing: missing, reason: "hotkey press")
            return
        }
        let initialInsertionContext = insertionTargetQueryContext()
        cancelAudioIdleStop()
        var recoveryJournal: PendingDictationJournal?
        do {
            recoveryJournal = try PendingDictationRecovery.createJournal()
            didTouchAudioEngine = true
            if !audio.isEngineStarted {
                suppressAudioConfigurationChangesFromAppEngineUpdate()
            }
            try audio.startRecording(inputDevicePreference: settings.inputDevice,
                                     recoveryJournal: recoveryJournal)
        } catch {
            recoveryJournal?.finish()
            PendingDictationRecovery.remove(recoveryJournal?.url)
            stopAudioEngineImmediately()
            log("recording start failed: \(error.localizedDescription)")
            signalDictationFailure()
            return
        }
        isRecording = true
        if setupChecklistWindow?.isVisible == true {
            hotkeyTestSucceeded = true
            updateSetupChecklist()
        }
        startRecordingLevelMeter(initialContext: initialInsertionContext)
        if settings.playFeedbackSounds {
            Sounds.playStart()
        }
        muteIfNeededForRecording()
        log("press: recording")

        scheduleMaxDurationAutoRelease()
        rebuildMenu()
    }

    private func handleRelease(shortcut: DictationReleaseShortcut = .standard,
                               hotkeyDetectedAt: TimeInterval? = nil) {
        guard isRecording, !isTerminating else { return }
        let releaseReceivedAt = ProcessInfo.processInfo.systemUptime
        let hotkeyDispatchSeconds = hotkeyDetectedAt.map { max(0, releaseReceivedAt - $0) }
        let settingsRefreshStartedAt = ProcessInfo.processInfo.systemUptime
        settings.refreshFromDisk()
        let settingsRefreshedAt = ProcessInfo.processInfo.systemUptime
        let shouldPressEnterAfterInsertion = shouldPressEnterAfterDictation(
            shortcut: shortcut,
            primaryBehavior: settings.primaryCompletionBehavior
        )
        let releasePermissionCheckStartedAt = ProcessInfo.processInfo.systemUptime
        let missing = missingPermissions()
        let releasePermissionCheckCompletedAt = ProcessInfo.processInfo.systemUptime
        guard missing.isEmpty else {
            recoverActiveRecordingToHistory(reason: "permission lost on release") { [weak self] in
                self?.enterPermissionBlockedState(missing: missing, reason: "hotkey release")
            }
            return
        }

        isRecording = false
        stopRecordingLevelMeter(hideHUD: false)
        cancelMaxDurationAutoRelease()
        unmuteIfWeMuted()

        let audioFinalizeStartedAt = ProcessInfo.processInfo.systemUptime
        let captured = audio.endRecording()
        let audioFinalizedAt = ProcessInfo.processInfo.systemUptime
        let samples = captured.samples
        let dur: Double
        switch recordingReleaseAction(capturedSampleCount: samples.count) {
        case .discardTooShort(let duration):
            dur = duration
            log("release: clip too short (\(String(format: "%.2f", dur)) s), discarding")
            PendingDictationRecovery.remove(captured.recoveryURL)
            hideRecordingHUD()
            let recordedWallSeconds = recordingStartedAtUptime.map { releaseReceivedAt - $0 } ?? 0
            if recordedWallSeconds >= CAPTURE_FAILURE_MIN_RECORDING_SECONDS {
                // Человек держал запись секунды, а звука не набралось и на
                // клип: захват молчал. Раньше это выглядело ровно как
                // случайное касание хоткея — ни звука, ни вспышки, ни
                // записи в истории, только строка в логе.
                log("recording ran \(String(format: "%.1f", recordedWallSeconds)) s but captured \(String(format: "%.2f", dur)) s — capture failed silently")
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            if !runDeferredAudioRouteRefreshIfNeeded() {
                scheduleAudioIdleStop(reason: "short clip")
            }
            return
        case .transcribe(let duration):
            dur = duration
        }
        isBusy = true

        // Start CoreML before AppKit/menu work. The UI still transitions
        // immediately, but its disk/menu updates now overlap inference.
        let asrRequestedAt = ProcessInfo.processInfo.systemUptime
        let transcriptionWorker = asr
        let language = settings.dictationLanguage.fluidLanguage
        let transcriptionTask = Task.detached(priority: .userInitiated) {
            let transcription = try await transcriptionWorker.transcribe(
                samples: samples,
                language: language,
                requestedAt: asrRequestedAt
            )
            return CompletedTranscriptionWorkerResult(
                transcription: transcription,
                completedAt: ProcessInfo.processInfo.systemUptime
            )
        }

        let transcribingUIStartedAt = ProcessInfo.processInfo.systemUptime
        setMenuBarState(.busy)
        showTranscribingHUD()
        rebuildMenu()
        let transcribingUICompletedAt = ProcessInfo.processInfo.systemUptime
        log("release: \(String(format: "%.2f", dur)) s captured, transcribing")

        let taskEnqueuedAt = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            let taskStartedAt = ProcessInfo.processInfo.systemUptime
            var dictationFailed = false
            var insertedWordsForHUD: Int?
            do {
                let completed = try await transcriptionTask.value
                let transcription = completed.transcription
                let asrTiming = transcription.timing(
                    totalSeconds: completed.completedAt - asrRequestedAt
                )
                if !isTerminating {
                    let postprocessingStartedAt = ProcessInfo.processInfo.systemUptime
                    let processed = processedDictationText(rawTranscript: transcription.text,
                                                           corrections: settings.dictationTranscriptCorrections,
                                                           removeFillerWords: settings.removeFillerWords,
                                                           language: settings.dictationLanguage)
                    let postprocessingCompletedAt = ProcessInfo.processInfo.systemUptime
                    if processed.appliedCorrectionCount > 0 {
                        log("transcript corrections applied: \(processed.appliedCorrectionCount)")
                    }
                    if processed.removedFillerWordCount > 0 {
                        log("filler words removed: \(processed.removedFillerWordCount)")
                    }
                    let cleaned = processed.text
                    log("\(String(format: "%.2f", dur)) s audio → \(String(format: "%.2f", asrTiming.totalSeconds)) s → \(cleaned.count) chars")
                    if !cleaned.isEmpty {
                        let historyStartedAt = ProcessInfo.processInfo.systemUptime
                        addToHistory(
                            cleaned,
                            transcriptionDurationSeconds: asrTiming.totalSeconds,
                            asrTiming: asrTiming,
                            rebuildMenuAfterPersisting: false
                        )
                        recordDictationUsage(text: cleaned,
                                             audioSeconds: dur,
                                             asrSeconds: asrTiming.totalSeconds)
                        let historyCompletedAt = ProcessInfo.processInfo.systemUptime

                        let journalCleanupStartedAt = ProcessInfo.processInfo.systemUptime
                        PendingDictationRecovery.remove(captured.recoveryURL)
                        let journalCleanupCompletedAt = ProcessInfo.processInfo.systemUptime

                        let permissionRecheckStartedAt = ProcessInfo.processInfo.systemUptime
                        let missing = missingPermissions()
                        let permissionRecheckCompletedAt = ProcessInfo.processInfo.systemUptime
                        guard missing.isEmpty else {
                            isBusy = false
                            finishBusyHUD()
                            enterPermissionBlockedState(missing: missing, reason: "paste")
                            return
                        }

                        let insertionStartedAt = ProcessInfo.processInfo.systemUptime
                        let inserted = TextInserter.insert(
                            pastedText(from: cleaned, suffix: settings.pasteSuffix)
                        )
                        let insertionCompletedAt = ProcessInfo.processInfo.systemUptime
                        var enterDelaySeconds: Double?
                        if inserted {
                            insertedWordsForHUD = cleaned
                                .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
                                .count
                            if shouldPressEnterAfterInsertion {
                                let enterDelayStartedAt = ProcessInfo.processInfo.systemUptime
                                let enterDelayNanoseconds = UInt64(settings.enterDelayMilliseconds) * 1_000_000
                                if enterDelayNanoseconds > 0 {
                                    try? await Task.sleep(nanoseconds: enterDelayNanoseconds)
                                }
                                // Enter не жмётся вслепую: при вставке через
                                // буфер получатель обязан прийти за текстом.
                                // Не пришёл и за льготную секунду — ⌘V не
                                // дошёл, и Enter отправил бы поле, в которое
                                // ничего не вставилось.
                                let pasteConfirmed: Bool
                                if TextInserter.lastSuccessfulStrategy == .clipboardPaste {
                                    pasteConfirmed = await ClipboardPasteInserter.waitUntilPasteRead(
                                        timeout: ENTER_AFTER_PASTE_READ_GRACE_SECONDS)
                                } else {
                                    pasteConfirmed = true
                                }
                                if !pasteConfirmed {
                                    log("return skipped: paste was never read within the grace period")
                                } else if KeyboardShortcutPoster.postReturn() {
                                    log("return posted after dictation")
                                } else {
                                    log("return event creation failed")
                                }
                                enterDelaySeconds = ProcessInfo.processInfo.systemUptime - enterDelayStartedAt
                            }
                            if settings.playFeedbackSounds {
                                Sounds.playDone()
                            }
                        } else {
                            log("text insertion failed")
                            dictationFailed = true
                        }

                        log(DictationLatencyMetrics(
                            audioSeconds: dur,
                            hotkeyDispatchSeconds: hotkeyDispatchSeconds,
                            releasePreparationSeconds: audioFinalizeStartedAt - releaseReceivedAt,
                            settingsRefreshSeconds: settingsRefreshedAt - settingsRefreshStartedAt,
                            releasePermissionCheckSeconds: releasePermissionCheckCompletedAt - releasePermissionCheckStartedAt,
                            audioFinalizeSeconds: audioFinalizedAt - audioFinalizeStartedAt,
                            audioDetachSeconds: captured.detachSeconds,
                            journalFlushSeconds: captured.journalFlushSeconds,
                            audioFlattenSeconds: captured.flattenSeconds,
                            transcribingUISeconds: transcribingUICompletedAt - transcribingUIStartedAt,
                            taskQueueSeconds: taskStartedAt - taskEnqueuedAt,
                            releaseToASRSeconds: asrRequestedAt - releaseReceivedAt,
                            asrTiming: asrTiming,
                            postprocessingSeconds: postprocessingCompletedAt - postprocessingStartedAt,
                            historyPersistenceSeconds: historyCompletedAt - historyStartedAt,
                            journalCleanupSeconds: journalCleanupCompletedAt - journalCleanupStartedAt,
                            permissionRecheckSeconds: permissionRecheckCompletedAt - permissionRecheckStartedAt,
                            insertionDispatchSeconds: insertionCompletedAt - insertionStartedAt,
                            releaseToPasteDispatchSeconds: insertionCompletedAt - releaseReceivedAt,
                            enterDelaySeconds: enterDelaySeconds,
                            pasteSucceeded: inserted
                        ).logLine)
                    } else {
                        PendingDictationRecovery.remove(captured.recoveryURL)
                        // Запись нормальной длины, а распознавание вернуло
                        // пустоту — раньше это выглядело как «ничего не
                        // произошло»: ни текста, ни звука, ни записи в
                        // истории. Пустой результат — тоже отказ.
                        log("transcription returned empty text for \(String(format: "%.2f", dur)) s of audio")
                        dictationFailed = true
                    }
                }
            } catch {
                log("transcribe failed: \(error)")
                dictationFailed = true
            }
            isBusy = false
            if let words = insertedWordsForHUD, !dictationFailed, !isTerminating {
                showInsertedHUD(wordCount: words)
            } else {
                finishBusyHUD()
            }
            if dictationFailed && !isTerminating {
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            let didRestartAudio = runDeferredAudioRouteRefreshIfNeeded()
            recoverRuntimeAfterWakeIfNeeded(reason: "transcription finished after wake")
            if !didRestartAudio {
                scheduleAudioIdleStop(reason: "recording finished")
            }
        }
    }

    private func recoverActiveRecordingToHistory(reason: String,
                                                 runDeferredRefresh: Bool = true,
                                                 completion: (() -> Void)? = nil) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            completion?()
            return
        }

        cancelMaxDurationAutoRelease()
        let captured = audio.endRecording()
        let duration = Double(captured.samples.count) / SAMPLE_RATE
        isRecording = false
        stopRecordingLevelMeter(hideHUD: false)
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        guard !captured.samples.isEmpty else {
            PendingDictationRecovery.remove(captured.recoveryURL)
            hideRecordingHUD()
            setMenuBarState(.idle)
            rebuildMenu()
            log("recording ended without audio (\(reason))")
            completion?()
            return
        }

        isBusy = true
        setMenuBarState(.busy)
        showTranscribingHUD()
        rebuildMenu()
        log("recording ended nonstandard (\(reason)); recovering \(String(format: "%.2f", duration)) s to history")

        Task { @MainActor in
            var recoveryFailed = false
            do {
                let requestedAt = ProcessInfo.processInfo.systemUptime
                let transcription = try await asr.transcribe(
                    samples: captured.samples,
                    language: settings.dictationLanguage.fluidLanguage,
                    requestedAt: requestedAt
                )
                let completedAt = ProcessInfo.processInfo.systemUptime
                let timing = transcription.timing(totalSeconds: completedAt - requestedAt)
                if !isTerminating {
                    let processed = processedDictationText(rawTranscript: transcription.text,
                                                           corrections: settings.dictationTranscriptCorrections,
                                                           removeFillerWords: settings.removeFillerWords,
                                                           language: settings.dictationLanguage)
                    if !processed.text.isEmpty {
                        addToHistory(
                            processed.text,
                            transcriptionDurationSeconds: timing.totalSeconds,
                            asrTiming: timing
                        )
                        recordDictationUsage(text: processed.text,
                                             audioSeconds: duration,
                                             asrSeconds: timing.totalSeconds)
                    }
                    PendingDictationRecovery.remove(captured.recoveryURL)
                    log("recovered dictation: \(String(format: "%.2f", duration)) s audio → \(String(format: "%.2f", timing.totalSeconds)) s → \(processed.text.count) chars in history")
                }
            } catch {
                recoveryFailed = true
                log("dictation recovery failed; audio retained for next launch: \(error.localizedDescription)")
            }

            guard !isTerminating else { return }
            isBusy = false
            finishBusyHUD()
            if recoveryFailed {
                signalDictationFailure()
            } else {
                setMenuBarState(.idle)
            }
            rebuildMenu()
            completion?()
            let didRestartAudio = runDeferredRefresh
                ? runDeferredAudioRouteRefreshIfNeeded()
                : false
            recoverRuntimeAfterWakeIfNeeded(reason: "dictation recovery finished after wake")
            if !didRestartAudio {
                scheduleAudioIdleStop(reason: reason)
            }
        }
    }

    private func cancelActiveRecording(reason: String, runDeferredRefresh: Bool = true) {
        guard isRecording || audio.isRunning else {
            hotkey.resetToggleState()
            return
        }

        recoverActiveRecordingToHistory(reason: reason,
                                        runDeferredRefresh: runDeferredRefresh)
    }

    // Termination cannot await transcription, so it only flushes the
    // recovery journal. The next launch transcribes it into history.
    private func cancelRecordingForTermination() {
        cancelMaxDurationAutoRelease()
        hotkey.onPress = nil
        hotkey.onRelease = nil
        hotkey.onReleaseAlternate = nil
        hotkey.onCancel = nil
        hotkey.onRejectedBusyPress = nil
        hotkey.isRecordingActive = nil
        hotkey.canStartRecording = nil
        hotkey.stop()

        let hadActiveRecording = isRecording || audio.isRunning
        let hadMute = systemAudioMutePhase != .idle
        if hadActiveRecording {
            let captured = audio.endRecording()
            if captured.recoveryURL != nil {
                log("terminate: active dictation preserved for next-launch recovery")
            }
        }
        stopRecordingLevelMeter()
        stopAudioEngineImmediately()
        isRecording = false
        isBusy = false
        hotkey.resetToggleState()
        unmuteIfWeMuted()

        if hadActiveRecording || hadMute {
            log("terminate: active recording finalized")
        }
    }

    // Trade-off: the mute is asynchronous relative to recording
    // start. Audio capture is armed immediately when the engine opens
    // on press, while the probe + mute land a few milliseconds later,
    // so a sliver of system audio can bleed into the start of the clip.
    // That beats the alternative — the old synchronous AppleScript
    // calls ran behind the session-wide event tap on the main run
    // loop, stalling every keystroke system-wide (and risking macOS
    // disabling the tap after a >1 s stall).
    private func muteIfNeededForRecording() {
        guard settings.muteWhileRecording else { return }
        guard systemAudioMutePhase == .idle else {
            // A previous recording's lifecycle is still settling
            // (rapid press cycles). Skipping the mute for this
            // recording is safe in the never-stuck sense, but the
            // cost is not always "a few ms": if the previous probe is
            // still in flight when this press lands, it stands down
            // to .idle and THIS recording runs unmuted for its whole
            // duration. Accepted: it needs a press/release/press
            // faster than one AppleScript round-trip, and the
            // alternative (queueing nested mute lifecycles) is far
            // more complex than the failure it prevents.
            log("output mute skipped: previous mute lifecycle still settling")
            return
        }
        systemAudioMutePhase = .probing
        systemAudioUnmuteRequested = false
        // Only mute if we wouldn't be stomping a user-set mute.
        SystemAudio.mutedStateAsync { [weak self] mutedState in
            self?.continueMuteAfterProbe(mutedState: mutedState)
        }
    }

    private func continueMuteAfterProbe(mutedState: Bool?) {
        guard systemAudioMutePhase == .probing else {
            log("output mute probe completion ignored: unexpected phase")
            return
        }
        switch systemAudioMuteProbeDecision(mutedState: mutedState,
                                            unmuteAlreadyRequested: systemAudioUnmuteRequested) {
        case .standDown:
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            return
        case .armRecoveryAndMute:
            break
        }

        // Crash-recovery invariant: the marker + watchdog must exist
        // BEFORE the mute command can execute, so a crash at any
        // point after the mute leaves a recovery path. Both are armed
        // here on the main actor; the mute is only enqueued after
        // they exist, and SystemAudio's serial queue preserves that
        // order.
        do {
            try writeSystemAudioMuteMarker()
            try startSystemAudioMuteWatchdog()
        } catch {
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            log("output mute skipped: recovery watchdog unavailable (\(error.localizedDescription))")
            return
        }
        systemAudioMutePhase = .muting
        SystemAudio.muteAsync { [weak self] outcome in
            self?.finishMuteCommand(outcome: outcome)
        }
    }

    private func finishMuteCommand(outcome: SystemAudioMuteCommandOutcome) {
        guard systemAudioMutePhase == .muting else {
            log("output mute completion ignored: unexpected phase")
            return
        }
        switch systemAudioMuteCommandDecision(outcome: outcome,
                                              unmuteAlreadyRequested: systemAudioUnmuteRequested) {
        case .disarmRecovery:
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            log("output mute failed")
        case .stayMuted:
            systemAudioMutePhase = .muted
            log(outcome == .assumedMuted
                ? "output muted (verification failed; assuming muted, recovery stays armed)"
                : "output muted")
        case .beginUnmute:
            // The recording ended while the mute command ran.
            systemAudioUnmuteRequested = false
            beginSystemAudioUnmute()
        }
    }

    private func unmuteIfWeMuted() {
        switch systemAudioUnmuteRequestDecision(phase: systemAudioMutePhase) {
        case .nothingToDo:
            return
        case .deferUntilCommandSettles:
            systemAudioUnmuteRequested = true
        case .beginUnmute:
            beginSystemAudioUnmute()
        }
    }

    private func beginSystemAudioUnmute() {
        systemAudioMutePhase = .unmuting
        SystemAudio.unmuteAsync { [weak self] unmuted in
            self?.finishUnmuteCommand(unmuted: unmuted)
        }
    }

    private func finishUnmuteCommand(unmuted: Bool) {
        guard systemAudioMutePhase == .unmuting else {
            log("output unmute completion ignored: unexpected phase")
            return
        }
        if unmuted {
            systemAudioMutePhase = .idle
            systemAudioUnmuteRequested = false
            removeSystemAudioMuteMarker()
            stopSystemAudioMuteWatchdog()
            log("output unmuted")
        } else {
            // Stay "muted": the marker + watchdog remain armed, the
            // next recording's release retries the unmute, and the
            // watchdog recovers if we exit first.
            systemAudioMutePhase = .muted
            log("output unmute failed; crash-recovery marker left in place")
        }
    }

    private func startSystemAudioMuteWatchdog() throws {
        stopSystemAudioMuteWatchdog()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = [
            "-c",
            systemAudioMuteWatchdogScript(),
            "dictor-audio-watchdog",
            "\(getpid())",
            systemAudioMuteMarkerURL().path,
        ]
        proc.environment = systemToolProcessEnvironment()
        try proc.run()
        systemAudioMuteWatchdog = proc
    }

    private func stopSystemAudioMuteWatchdog() {
        guard let proc = systemAudioMuteWatchdog else { return }
        if proc.isRunning {
            proc.terminate()
        }
        systemAudioMuteWatchdog = nil
    }

    // Uses the synchronous SystemAudio calls deliberately: this runs
    // once from applicationDidFinishLaunching, before the event tap
    // exists, so a main-thread AppleScript round-trip cannot stall
    // keystrokes here.
    private func recoverStaleSystemAudioMuteIfNeeded() {
        let marker = systemAudioMuteMarkerURL()
        guard FileManager.default.fileExists(atPath: marker.path) else { return }

        if let text = try? String(contentsOf: marker, encoding: .utf8),
           let pid = systemAudioMuteMarkerProcessID(from: text),
           pid != getpid(),
           Darwin.kill(pid, 0) == 0 {
            log("output mute recovery deferred: marker belongs to active process \(pid)")
            return
        }

        if SystemAudio.isMuted() {
            if SystemAudio.unmute() {
                log("output unmuted after interrupted recording")
            } else {
                log("output unmute after interrupted recording failed")
            }
        } else {
            log("stale output mute marker removed")
        }
        removeSystemAudioMuteMarker(at: marker)
    }

    private func scheduleMaxDurationAutoRelease() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isRecording else { return }
            log("max recording duration reached, releasing")
            self.hotkey.resetToggleState()
            self.handleRelease()
        }
        maxDurationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + MAX_RECORDING_SECONDS, execute: work)
    }

    private func cancelMaxDurationAutoRelease() {
        maxDurationWorkItem?.cancel()
        maxDurationWorkItem = nil
    }

    // MARK: - History

    private func importDictationUsageFromLogIfNeeded() {
        guard !settings.didImportDictationUsageLog else { return }
        defer { settings.didImportDictationUsageLog = true }
        guard settings.dailyDictationUsage.isEmpty else { return }

        let url = Logger.shared.fileURL
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              !text.isEmpty else {
            return
        }
        let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let imported = importedDailyDictationUsage(from: text,
                                                   fileCreatedAt: createdAt,
                                                   calendar: .current)
        guard !imported.isEmpty else { return }
        settings.dailyDictationUsage = imported
        let total = imported.reduce(0) { $0 + $1.dictationCount }
        log("usage statistics imported from local log (\(total) dictations across \(imported.count) days)")
    }

    private func recordDictationUsage(text: String,
                                      audioSeconds: Double,
                                      asrSeconds: Double,
                                      at date: Date = Date()) {
        settings.dailyDictationUsage = addingDictationUsageSample(
            to: settings.dailyDictationUsage,
            at: date,
            characterCount: text.count,
            audioSeconds: audioSeconds,
            asrSeconds: asrSeconds,
            calendar: .current
        )
    }

    private func addToHistory(_ text: String,
                              transcriptionDurationSeconds: Double?,
                              asrTiming: ASRTimingBreakdown? = nil,
                              rebuildMenuAfterPersisting: Bool = true) {
        guard settings.recentTranscriptLimit != .off else { return }
        let entry = TranscriptHistoryEntry(
            text: text,
            transcriptionDurationSeconds: transcriptionDurationSeconds,
            asrTiming: asrTiming,
            createdAt: Date()
        )
        // Архив перечитывается с диска прямо перед записью: пока шла запись и
        // распознавание, секундный наблюдатель настроек стоит (guard
        // !isRecording, !isBusy), и копия агента могла устареть — окно могло
        // успеть стереть историю или удалить запись.
        settings.refreshFromDisk()
        let onDisk = settings.recentTranscriptEntries
        let next = limitedTranscriptHistoryArchive([entry] + onDisk)
        guard next != onDisk else { return }
        persistHistoryArchive(next)
        if rebuildMenuAfterPersisting {
            rebuildMenu()
        }
    }

    /// Единственная точка, где агент пишет архив истории. Обновляет и кэш, и
    /// отпечаток байтов — иначе наблюдатель настроек примет собственную запись
    /// за внешнюю и перечитает архив впустую.
    private func persistHistoryArchive(_ entries: [TranscriptHistoryEntry]) {
        history = entries
        settings.recentTranscriptEntries = entries
        lastSeenHistoryArchiveData = settings.recentTranscriptEntriesStoredData
    }

    private func applyRecentTranscriptLimit() {
        guard settings.recentTranscriptLimit == .off, !history.isEmpty else { return }
        let removed = history.count
        persistHistoryArchive([])
        log("recent transcript history disabled and cleared (\(removed) entries)")
    }

    /// 60-char preview with ellipsis. Newlines collapsed so a multi-
    /// line transcript still renders as one menu row.
    private func previewLine(for text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 60 ? String(flat.prefix(60)) + "…" : flat
    }

    @objc private func historyClicked(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        copyHistoryText(s)
    }

    private func copyHistoryText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("history copied to clipboard (\(text.count) chars)")
    }

    @objc private func clearHistoryClicked(_ sender: NSMenuItem) {
        guard !history.isEmpty else { return }
        let count = history.count
        persistHistoryArchive([])
        log("history cleared (\(count) entries)")
        rebuildMenu()
    }

    @objc private func quitClicked(_ sender: NSMenuItem) {
        quitApplicationCompletely()
    }

    /// Единственный выход из Dictor, куда бы на него ни нажали: «Выйти» в
    /// поповере, «Quit Dictor» в служебном меню, ⌘Q в окне. Все три обязаны
    /// делать одно и то же, иначе «выйти» означает разное в зависимости от
    /// того, откуда вышли, — а человек видит одно приложение.
    private func quitApplicationCompletely() {
        guard confirmStopDictation() else { return }
        // Окно — отдельный процесс, и раньше выход его не касался: иконка из
        // меню-бара исчезала, а приложение оставалось на экране и в Dock.
        DistributedNotificationCenter.default().postNotificationName(
            CONTROL_PANEL_QUIT_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true)
        // Снять службу обязательно: у тех, кто ставил прошлую версию, в plist
        // остался KeepAlive: true, и без bootout launchd поднял бы агента
        // обратно — выход выглядел бы как «приложение не закрывается».
        log("quit: stopping the service and closing the window")
        DictorAgentService.stopForQuit()
        NSApp.terminate(self)
    }

    private func confirmStopDictation() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop Dictor?"
        alert.informativeText = "The \(hotkey.hotkey.name) dictation shortcut will stop until you open Dictor again. Use Close to hide windows while keeping dictation running."
        alert.addButton(withTitle: "Keep Running")
        alert.addButton(withTitle: "Stop Dictation")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @objc private func cancelRecordingClicked(_ sender: NSMenuItem) {
        cancelActiveRecording(reason: "menu")
    }

    @objc private func copyDiagnosticsClicked(_ sender: NSMenuItem) {
        copyDiagnosticsToClipboard()
    }

    private func copyDiagnosticsToClipboard() {
        let text = diagnosticsText()
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
        log("diagnostics copied to clipboard")
    }

    @objc private func saveDiagnosticsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Save Diagnostics"
        panel.message = "Save a privacy-safe diagnostics report for a GitHub issue."
        panel.prompt = "Save"
        panel.nameFieldStringValue = "Dictor Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnosticsText().write(to: url, atomically: true, encoding: .utf8)
            log("diagnostics saved to \(privacySafeLogPath(url))")
        } catch {
            showDiagnosticsSaveError(error)
        }
    }

    private func showDiagnosticsSaveError(_ error: Error) {
        log("diagnostics save failed: \(error.localizedDescription)")
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Diagnostics couldn't be saved"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - Menu

    private func rebuildMenu() {
        publishAgentState()
        if quickPanel?.isVisible == true {
            quickPanel?.apply(state: quickPanelState())
        }
    }

    private func publishAgentState(status explicitStatus: String? = nil,
                                   detail explicitDetail: String? = nil) {
        let statusDetail = agentStateStatusDetail()
        let missing = missingPermissions().map(\.rawValue)
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: explicitStatus ?? statusDetail.status,
                              detail: explicitDetail ?? statusDetail.detail,
                              updatedAt: Date().timeIntervalSince1970,
                              pid: getpid(),
                              isReady: isReady,
                              isRecording: isRecording,
                              isTranscribing: isBusy,
                              speechModelReady: isSpeechModelReady,
                              missingPermissions: missing,
                              hotkeyName: hotkey.hotkey.name,
                              triggerMode: settings.triggerMode.rawValue,
                              downloadProgressFraction: speechModelStartupProgressFraction,
                              verifiedModelFiles: verifiedModelFiles,
                              totalModelFiles: totalModelFiles,
                              downloadedModelFiles: downloadedModelFiles,
                              totalDownloadModelFiles: totalDownloadModelFiles,
                              medianLatencyMilliseconds: medianLatencyMilliseconds,
                              isUpdating: installingUpdateVersion != nil,
                              appVersion: currentBundleVersion())
        )
    }

    /// Сколько файлов модели уже скачано. Байты FluidAudio не отдаёт — только
    /// число файлов и долю, поэтому «412 МБ из 600 МБ» из макета показать
    /// нечем, а придумывать объём нельзя.
    private var downloadedModelFiles: Int? {
        guard case .downloading(let completed, _)? = lastDownloadPhase else { return nil }
        return completed
    }

    private var totalDownloadModelFiles: Int? {
        guard case .downloading(_, let total)? = lastDownloadPhase else { return nil }
        return total
    }

    /// Медиана времени распознавания последних тридцати диктовок. Это же число
    /// показывает плитка в «Продвинутых» — считаем один раз здесь.
    private var medianLatencyMilliseconds: Int? {
        guard let seconds = medianRecognitionSeconds(entries: settings.recentTranscriptEntries),
              seconds > 0 else { return nil }
        return Int((seconds * 1000).rounded())
    }

    private func agentStateStatusDetail() -> (status: String, detail: String) {
        if isRecording {
            return ("recording", "Recording dictation.")
        }
        if isBusy {
            return ("transcribing", "Transcribing your last recording.")
        }
        if isReady {
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            return ("ready", "\(verb) \(hotkey.hotkey.name) to dictate.")
        }
        if let failure = startupFailure {
            return ("error", failure.detail)
        }
        let missing = missingPermissions()
        if !missing.isEmpty {
            return ("needs_permissions", "Grant \(missing.map(\.rawValue).joined(separator: ", ")) to finish setup.")
        }
        if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            return ("starting", startupStatusTitle)
        }
        if isCoreRuntimeReady {
            return ("starting", "Starting hotkey listener.")
        }
        return ("starting", "Starting dictation service.")
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        // Status row.
        let statusTitle = menuStatusTitle()
        let status = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        status.isEnabled = false
        if let failure = startupFailure {
            status.toolTip = failure.detail
        }
        menu.addItem(status)
        if shouldShowSpeechModelProgressRow {
            menu.addItem(buildSpeechModelProgressItem())
        }

        menu.addItem(.separator())

        if isRecording {
            let cancel = NSMenuItem(title: "Cancel Recording",
                                    action: #selector(cancelRecordingClicked(_:)),
                                    keyEquivalent: "")
            cancel.target = self
            menu.addItem(cancel)
            menu.addItem(.separator())
        }

        if let failure = startupFailure {
            let retry = NSMenuItem(title: failure.retryTitle,
                                   action: #selector(retryStartupClicked(_:)),
                                   keyEquivalent: "")
            retry.target = self
            retry.toolTip = failure.detail
            retry.isEnabled = startupTask == nil
            menu.addItem(retry)
            menu.addItem(.separator())
        }

        // Update submenu (lazy — only present when an update exists).
        if let release = pendingUpdate, !settings.skippedVersions.contains(release.version) {
            menu.addItem(buildUpdateItem(for: release))
            menu.addItem(.separator())
        }

        // Permission rows — visible only while something is missing.
        var addedPermRow = false
        for p in Permission.allCases where !Permissions.isGranted(p) {
            menu.addItem(buildPermissionItem(p))
            addedPermRow = true
        }
        if addedPermRow { menu.addItem(.separator()) }

        // History: keep one-click access to the last transcript, but
        // hide transcript preview text inside the submenu so the menu
        // stays stable even after long dictations.
        if let newest = visibleHistory.first {
            let inline = NSMenuItem(title: "Copy Last Transcript",
                                    action: #selector(historyClicked(_:)),
                                    keyEquivalent: "")
            inline.target = self
            inline.representedObject = newest.text
            inline.toolTip = newest.text
            menu.addItem(inline)

            menu.addItem(buildRecentTranscriptsItem())

            menu.addItem(.separator())
        }

        // Settings submenu.
        menu.addItem(buildSettingsItem())
        menu.addItem(buildSupportItem())
        menu.addItem(.separator())

        // Route through our own selector rather than `NSApp.terminate(_:)`
        // directly. macOS auto-decorates items whose action is the
        // system terminate: selector with a destructive-action glyph
        // (visible in the state-column slot), which is the *only* item
        // in the menu that gets such an indicator — every other row
        // sits flush against the left edge. The wrapper produces the
        // identical behaviour with no auto-glyph.
        let quit = NSMenuItem(title: "Quit Dictor",
                              action: #selector(quitClicked(_:)),
                              keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func buildRecentTranscriptsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        for entry in visibleHistory {
            let item = NSMenuItem(title: previewLine(for: entry.text),
                                  action: #selector(historyClicked(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = entry.text
            sub.addItem(item)
        }

        sub.addItem(.separator())

        let clear = NSMenuItem(title: "Clear Recent Transcripts",
                               action: #selector(clearHistoryClicked(_:)),
                               keyEquivalent: "")
        clear.target = self
        sub.addItem(clear)

        parent.submenu = sub
        return parent
    }

    private func buildSupportItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Support", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let setup = NSMenuItem(title: "Setup Checklist…",
                               action: #selector(showSetupChecklistClicked(_:)),
                               keyEquivalent: "")
        setup.target = self
        sub.addItem(setup)

        sub.addItem(.separator())

        let about = NSMenuItem(title: "About Dictor",
                               action: #selector(showAboutClicked(_:)),
                               keyEquivalent: "")
        about.target = self
        sub.addItem(about)

        sub.addItem(.separator())

        let diagnostics = NSMenuItem(title: "Copy Diagnostics",
                                     action: #selector(copyDiagnosticsClicked(_:)),
                                     keyEquivalent: "")
        diagnostics.target = self
        sub.addItem(diagnostics)

        let saveDiagnostics = NSMenuItem(title: "Save Diagnostics…",
                                         action: #selector(saveDiagnosticsClicked(_:)),
                                         keyEquivalent: "")
        saveDiagnostics.target = self
        sub.addItem(saveDiagnostics)

        let resetModel = NSMenuItem(title: isResettingSpeechModelCache ? "Resetting Speech Model Cache…" : "Reset Speech Model Cache…",
                                    action: #selector(resetSpeechModelCacheClicked(_:)),
                                    keyEquivalent: "")
        resetModel.target = self
        resetModel.isEnabled = !isRecording
            && !isBusy
            && !isTerminating
            && startupTask == nil
            && !isResettingSpeechModelCache
            && !isSwitchingSpeechModel
        resetModel.toolTip = "Delete the speech model cache and download a fresh verified copy."
        sub.addItem(resetModel)

        parent.submenu = sub
        return parent
    }

    private var shouldShowSpeechModelProgressRow: Bool {
        startupFailure == nil
            && ((startupTask != nil && !isSpeechModelReady)
                || isSwitchingSpeechModel
                || isResettingSpeechModelCache)
    }

    private func buildSpeechModelProgressItem() -> NSMenuItem {
        let item = NSMenuItem()
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        let progress = NSProgressIndicator(frame: NSRect(x: 14, y: 7, width: 232, height: 10))
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.usesThreadedAnimation = true
        progress.toolTip = startupStatusTitle

        if let speechModelStartupProgressFraction {
            progress.isIndeterminate = false
            progress.doubleValue = speechModelStartupProgressFraction
        } else {
            progress.isIndeterminate = true
            progress.startAnimation(nil)
        }

        view.addSubview(progress)
        item.view = view
        return item
    }

    private func menuStatusTitle() -> String {
        if isRecording {
            return "Recording..."
        }
        if isBusy {
            return "Transcribing..."
        }
        if isReady {
            let hk = hotkey.hotkey.name
            let verb = settings.triggerMode == .hold ? "Hold" : "Press"
            return "\(verb) \(hk) to dictate"
        }
        if let failure = startupFailure {
            return failure.statusTitle
        }
        if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            return startupStatusTitle
        }
        if !missingPermissions().isEmpty {
            return "Grant permissions to finish setup"
        }
        if isCoreRuntimeReady {
            return "Starting hotkey listener…"
        }
        return "Dictor is not ready"
    }

    private func diagnosticsText() -> String {
        let generated = ISO8601DateFormatter().string(from: Date())
        let bundlePath = Bundle.main.bundlePath
        let installKind: String
        if bundlePath == "/Applications/Dictor.app" {
            installKind = "Applications app"
        } else if bundlePath == "/tmp/Dictor-dev.app" {
            installKind = "signed dev app"
        } else {
            installKind = "other"
        }

        let devices = availableAudioInputDevices()
        let savedInput = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedInput = audioInputDevice(matching: savedInput, in: devices)
        let inputLabel: String
        if savedInput.isEmpty || isDefaultAggregateAudioInputPreference(savedInput) {
            inputLabel = "System default"
        } else if let selectedInput {
            inputLabel = "\(selectedInput.name) (available)"
        } else {
            inputLabel = "Saved device unavailable"
        }

        let startupText: String
        if let failure = startupFailure {
            startupText = "\(failure.statusTitle): \(failure.detail)"
        } else if startupTask != nil || isRestartingAudioInput || isSwitchingSpeechModel {
            startupText = startupStatusTitle
        } else {
            startupText = isCoreRuntimeReady ? "Runtime ready" : "Runtime not ready"
        }

        let permissionLines = Permission.allCases
            .map { "\($0.rawValue): \(Permissions.isGranted($0) ? "granted" : "missing")" }
        let availableInputLines = devices.isEmpty
            ? ["Available inputs: none reported"]
            : ["Available inputs (\(devices.count)):"] + devices.map { "  \($0.name)" }
        let pendingUpdateText = pendingUpdate.map { "v\($0.version)" } ?? "none"
        let lastUpdateCheckText = updateCheckDiagnosticText(
            checkedAt: settings.lastUpdateCheckAt,
            source: settings.lastUpdateCheckSource,
            result: settings.lastUpdateCheckResult,
            releaseVersion: settings.lastUpdateCheckVersion
        )
        let updateReminderText: String
        if let version = reminderPausedUpdateVersion,
           let until = reminderPausedUntil,
           Date() < until {
            updateReminderText = "v\(version) until \(ISO8601DateFormatter().string(from: until))"
        } else {
            updateReminderText = "none"
        }
        let memoryLines: [String]
        if let memory = currentAppMemoryUsage() {
            memoryLines = [
                "Resident: \(formattedByteCount(memory.residentBytes))",
                "Physical footprint: \(formattedByteCount(memory.physicalFootprintBytes))",
            ]
        } else {
            memoryLines = []
        }
        let launchAtLoginText: String
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginText = "enabled"
        case .requiresApproval:
            launchAtLoginText = "requires approval"
        case .notRegistered:
            launchAtLoginText = "disabled"
        case .notFound:
            launchAtLoginText = "not found"
        @unknown default:
            launchAtLoginText = "unknown"
        }

        let speechModelProfile = settings.speechModelProfile
        let languageSettingText = DICTATION_LANGUAGE_DISPLAY[settings.dictationLanguage]
            ?? settings.dictationLanguage.rawValue

        let logLines: [String]
        do {
            logLines = try recentDiagnosticLogLines()
        } catch {
            logLines = ["Unavailable: \(error.localizedDescription)"]
        }

        let snapshot = DiagnosticsReportSnapshot(
            generated: generated,
            appVersion: currentBundleVersion(),
            appBuild: currentBundleBuild(),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            bundleID: Bundle.main.bundleIdentifier ?? "unknown",
            bundlePath: privacySafeBundlePath(bundlePath),
            installKind: installKind,
            status: menuStatusTitle(),
            startup: startupText,
            speechModelReady: isSpeechModelReady,
            coreRuntimeReady: isCoreRuntimeReady,
            readyForDictation: isReady,
            recordingActive: isRecording,
            transcribing: isBusy,
            memoryLines: memoryLines,
            permissionLines: permissionLines,
            settingLines: [
                "Hotkey: \(hotkey.hotkey.name)",
                "Trigger mode: \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)",
                "Speech model: \(speechModelProfile.displayName)",
                "Language: \(languageSettingText)",
                "Paste behavior: \(PASTE_SUFFIX_DISPLAY[settings.pasteSuffix] ?? settings.pasteSuffix.rawValue)",
                "Remove filler words: \(settings.removeFillerWords)",
                "Recent transcripts: \(RECENT_TRANSCRIPT_LIMIT_DISPLAY[settings.recentTranscriptLimit] ?? settings.recentTranscriptLimit.rawValue) (\(visibleHistory.count) visible, \(history.count) archived)",
                "Text corrections: \(settings.transcriptCorrections.count) configured",
                "Text correction sync: \(settings.transcriptCorrectionsSyncFile.isEmpty ? "off" : "configured")",
                "Text insertion: \(TextInserter.defaultStrategyDescription)",
                "Recording waveform: \(settings.showRecordingWaveform)",
                "Mute while recording: \(settings.muteWhileRecording)",
                "Feedback sounds: \(settings.playFeedbackSounds)",
                "Show in Dock: \(settings.showInDock)",
                "Launch at Login: \(launchAtLoginText)",
            ],
            updateLines: [
                "Update notifications: \(settings.checkForUpdates)",
                "Last update check: \(lastUpdateCheckText)",
                "Manual update check active: \(isCheckingForUpdates)",
                "Pending update: \(pendingUpdateText)",
                "Reminder paused: \(updateReminderText)",
                "Update helper log: \((UPDATE_HELPER_LOG_PATH as NSString).abbreviatingWithTildeInPath)",
            ],
            microphoneLines: ["Selected: \(inputLabel)"] + availableInputLines,
            logPath: (Logger.shared.fileURL.path as NSString).abbreviatingWithTildeInPath,
            recentLogLines: logLines
        )
        return diagnosticsReportText(from: snapshot)
    }

    @objc private func retryStartupClicked(_ sender: NSMenuItem) {
        startStartup(reason: "manual retry")
    }

    // MARK: - Setup checklist

    @objc private func showSetupChecklistClicked(_ sender: NSMenuItem) {
        showSetupChecklist()
    }

    private func showSetupChecklist() {
        NSApp.setActivationPolicy(.regular)
        showAppForModal()
        if let window = setupChecklistWindow {
            updateSetupChecklist()
            window.makeKeyAndOrderFront(nil)
            startSetupChecklistRefreshTimer()
            return
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "Set Up Dictor"
        window.isReleasedWhenClosed = false
        window.delegate = self
        setupChecklistWindow = window

        updateSetupChecklist()
        window.center()
        window.makeKeyAndOrderFront(nil)
        startSetupChecklistRefreshTimer()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        // Системный крестик — тоже способ закрыть окно обновления. Без
        // обнуления ссылки guard в presentUpdateWindow навсегда съедал
        // следующие показы: кнопка «Обновить» в поповере молчала, и даже
        // автоматическая проверка через 6 часов упиралась в тот же guard.
        if window === updateAvailableWindow {
            updateAvailableWindow = nil
            refreshActivationPolicy()
            return
        }
        guard window === setupChecklistWindow else { return }
        stopSetupChecklistRefreshTimer()
        refreshActivationPolicy()
    }

    private func startSetupChecklistRefreshTimer() {
        guard setupChecklistRefreshTimer == nil else { return }
        setupChecklistRefreshTimer = Timer.scheduledTimer(timeInterval: 1,
                                                          target: self,
                                                          selector: #selector(setupChecklistTimerFired(_:)),
                                                          userInfo: nil,
                                                          repeats: true)
        setupChecklistRefreshTimer?.tolerance = 0.25
    }

    private func stopSetupChecklistRefreshTimer() {
        setupChecklistRefreshTimer?.invalidate()
        setupChecklistRefreshTimer = nil
    }

    @objc private func setupChecklistTimerFired(_ timer: Timer) {
        guard setupChecklistWindow?.isVisible == true else {
            stopSetupChecklistRefreshTimer()
            return
        }
        updateSetupChecklist()
    }

    private func updateSetupChecklist() {
        guard let window = setupChecklistWindow else { return }
        window.contentView = makeSetupChecklistView()
        rebuildMenu()
    }

    private func makeSetupChecklistView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        // NSStackView on macOS uses NSLayoutConstraint.Attribute for
        // alignment and has no `.fill` case (UIKit-only). With
        // `.leading` every child hugged its own content, so the
        // right-edge Status / Grant column drifted between rows and
        // the NSBox separators — which have no intrinsic width —
        // collapsed to zero. After assembly we explicitly constrain
        // each arranged subview to the inner content width so
        // everything lines up at the same right edge.
        root.alignment = .leading
        root.spacing = 14
        root.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 18, right: 22)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = setupLabel("Set Up Dictor", font: .systemFont(ofSize: 22, weight: .semibold))
        let subtitle = setupLabel("Finish these checks before dictating. Dictor keeps this setup local to your Mac.",
                                  font: .systemFont(ofSize: 13),
                                  color: .secondaryLabelColor)
        subtitle.preferredMaxLayoutWidth = 476
        root.addArrangedSubview(title)
        root.addArrangedSubview(subtitle)
        root.addArrangedSubview(setupSeparator())

        root.addArrangedSubview(makeSpeechModelSetupRow())
        root.addArrangedSubview(makeAudioInputSetupRow())

        for permission in Permission.allCases {
            root.addArrangedSubview(makePermissionSetupRow(permission))
        }

        root.addArrangedSubview(makeHotkeySetupRow())

        if !setupChecklistIsComplete {
            let tip = setupLabel("Tip: If clicking 'Grant' doesn't open a prompt or show Dictor in System Settings, click 'Try Again' — Dictor will reset its macOS privacy permission entry and re-request, which clears stuck macOS state.",
                                 font: .systemFont(ofSize: 11),
                                 color: .secondaryLabelColor)
            tip.preferredMaxLayoutWidth = 476
            root.addArrangedSubview(tip)
        }

        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        let summary = setupLabel(setupChecklistSummary(),
                                 font: .systemFont(ofSize: 12),
                                 color: .secondaryLabelColor)
        let close = NSButton(title: setupChecklistIsComplete ? "Done" : "Close",
                             target: self,
                             action: #selector(closeSetupChecklistClicked(_:)))
        close.bezelStyle = .rounded

        footer.addArrangedSubview(summary)
        footer.addArrangedSubview(NSView())
        footer.addArrangedSubview(close)
        footer.setHuggingPriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(setupSeparator())
        root.addArrangedSubview(footer)

        // Force every arranged subview to fill the inner content width
        // (root width minus left + right insets). Without this the row
        // NSStackViews hug their content and the right-aligned Status /
        // Grant column drifts between rows; the NSBox separators have
        // no intrinsic width and collapse entirely.
        let innerWidthInset = -(root.edgeInsets.left + root.edgeInsets.right)
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: innerWidthInset).isActive = true
        }

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 520),
        ])
        return container
    }

    private var setupChecklistIsComplete: Bool {
        isSpeechModelReady
            && isReady
            && missingPermissions().isEmpty
    }

    private func setupChecklistSummary() -> String {
        setupChecklistIsComplete
            ? "Setup is complete. Use Dictor from the Dock or shortcuts."
            : "You can close this window; the menu will keep tracking setup."
    }

    private func makeSpeechModelSetupRow() -> NSView {
        let state = speechModelSetupRowState(profile: settings.speechModelProfile,
                                             isSpeechModelReady: isSpeechModelReady,
                                             isStartupInProgress: startupTask != nil || isSwitchingSpeechModel,
                                             startupStatusTitle: startupStatusTitle,
                                             failure: startupFailure)

        return makeSetupChecklistRow(title: "Speech model",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func makeAudioInputSetupRow() -> NSView {
        let state = audioInputSetupRowState(isSpeechModelReady: isSpeechModelReady,
                                            isCoreRuntimeReady: isCoreRuntimeReady,
                                            isStartupInProgress: startupTask != nil || isRestartingAudioInput,
                                            startupStatusTitle: startupStatusTitle,
                                            failure: startupFailure)
        return makeSetupChecklistRow(title: "Audio input",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func makePermissionSetupRow(_ permission: Permission) -> NSView {
        let granted = Permissions.isGranted(permission)
        let clicks = permClickCount[permission] ?? 0
        return makeSetupChecklistRow(title: permission.rawValue,
                                     detail: setupDetail(for: permission),
                                     status: granted ? "Granted" : "Missing",
                                     buttonTitle: granted ? nil : (clicks >= 1 ? "Try Again" : "Grant"),
                                     action: granted ? nil : #selector(grantSetupPermissionClicked(_:)),
                                     tag: Permission.allCases.firstIndex(of: permission) ?? -1)
    }

    private func makeHotkeySetupRow() -> NSView {
        let state = hotkeySetupRowState(isReady: isReady,
                                        hotkeyTestSucceeded: hotkeyTestSucceeded,
                                        triggerMode: settings.triggerMode,
                                        hotkeyName: hotkey.hotkey.name,
                                        failure: startupFailure)

        return makeSetupChecklistRow(title: "Hotkey",
                                     detail: state.detail,
                                     status: state.status,
                                     buttonTitle: state.buttonTitle,
                                     action: state.buttonTitle == nil ? nil : #selector(retryStartupFromSetupClicked(_:)))
    }

    private func setupDetail(for permission: Permission) -> String {
        switch permission {
        case .microphone:
            return "Captures your voice while dictating. Click 'Grant', then click 'OK' in the macOS prompt."
        case .accessibility:
            return "Pastes the transcript at your cursor. Click 'Grant' to open System Settings → Privacy & Security → Accessibility, then enable the toggle next to 'Dictor'."
        case .inputMonitoring:
            return "Lets Dictor detect the dictation hotkey. Click 'Grant' to open System Settings → Privacy & Security → Input Monitoring, then enable the toggle next to 'Dictor'."
        }
    }

    private func makeSetupChecklistRow(title: String,
                                       detail: String,
                                       status: String,
                                       buttonTitle: String? = nil,
                                       action: Selector? = nil,
                                       tag: Int = 0) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        row.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2

        textStack.addArrangedSubview(setupLabel(title, font: .systemFont(ofSize: 13, weight: .semibold)))
        
        let detailLabel = setupLabel(detail, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = (buttonTitle != nil) ? 310 : 380
        textStack.addArrangedSubview(detailLabel)

        let statusLabel = setupLabel(status,
                                     font: .systemFont(ofSize: 12, weight: .medium),
                                     color: setupStatusColor(status))
        statusLabel.alignment = .right
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(statusLabel)

        if let buttonTitle, let action {
            let button = NSButton(title: buttonTitle, target: self, action: action)
            button.bezelStyle = .rounded
            button.tag = tag
            button.setContentHuggingPriority(.required, for: .horizontal)
            row.addArrangedSubview(button)
        }

        row.setHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func setupLabel(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    private func setupStatusColor(_ status: String) -> NSColor {
        switch status {
        case "Granted", "Ready", "Detected", "Set":
            return .systemGreen
        case "Missing", "Needs retry", "Required":
            return .systemOrange
        default:
            return .secondaryLabelColor
        }
    }

    private func setupSeparator() -> NSBox {
        let separator = NSBox()
        separator.boxType = .separator
        return separator
    }

    @objc private func closeSetupChecklistClicked(_ sender: NSButton) {
        setupChecklistWindow?.close()
    }

    @objc private func retryStartupFromSetupClicked(_ sender: NSButton) {
        startStartup(reason: "setup checklist retry")
    }

    @objc private func grantSetupPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        requestPermissionFromMenu(Permission.allCases[sender.tag])
    }

    // MARK: - Permission row + click-twice-to-reset

    private func buildPermissionItem(_ p: Permission) -> NSMenuItem {
        let clicks = permClickCount[p] ?? 0
        let title: String
        if clicks >= 1 {
            // First click already happened; permission still denied,
            // so signal explicitly that a second click will reset
            // any stuck TCC state and re-request.
            title = "⚠ Grant \(p.rawValue) (try again — will reset stuck state)…"
        } else {
            title = "⚠ Grant \(p.rawValue) permission…"
        }
        let item = NSMenuItem(title: title,
                              action: #selector(grantPermissionClicked(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = p.rawValue
        return item
    }

    @objc private func grantPermissionClicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let p = Permission(rawValue: raw) else { return }
        requestPermissionFromMenu(p)
    }

    private func requestPermissionFromMenu(_ p: Permission) {
        if Permissions.isGranted(p) {
            permClickCount[p] = nil
            log("perm click ignored: \(p.rawValue) already granted")
            completeReadinessIfPossible(reason: "permission already granted")
            return
        }

        let clicks = (permClickCount[p] ?? 0) + 1
        permClickCount[p] = clicks
        log("perm click #\(clicks): \(p.rawValue)")

        if clicks >= 2 {
            // Click #2+: scrub TCC before re-requesting. The most
            // common cause of "I clicked Grant but nothing happened"
            // is a stuck TCC entry that survived an upgrade. The
            // re-request happens in the reset's completion — issuing
            // it before tccutil finished would race the scrub it
            // depends on.
            log("  resetting TCC for \(p.rawValue) before retry")
            TCC.reset(p, bundleID: Bundle.main.bundleIdentifier ?? "com.raul.dictor") { [weak self] in
                guard let self, !self.isTerminating else { return }
                Permissions.request(p)
                self.startPermissionReadinessMonitor(reason: "permission grant")
                self.updateSetupChecklist()
                self.rebuildMenu()
            }
            rebuildMenu()
            return
        }
        Permissions.request(p)
        startPermissionReadinessMonitor(reason: "permission grant")
        updateSetupChecklist()
        rebuildMenu()
    }

    // MARK: - Settings submenu

    private func buildSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(buildDictationSettingsItem())
        sub.addItem(buildTextSettingsItem())
        sub.addItem(buildBehaviorSettingsItem())

        parent.submenu = sub
        return parent
    }

    private func buildDictationSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Dictation", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(buildHotkeySettingsItem())
        sub.addItem(buildTriggerSettingsItem())
        sub.addItem(buildDictationLanguageSettingsItem())
        sub.addItem(buildInputDeviceItem())

        parent.submenu = sub
        return parent
    }

    private func buildTextSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Text", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        sub.addItem(buildPasteSuffixSettingsItem())
        sub.addItem(buildRecentTranscriptLimitSettingsItem())
        sub.addItem(buildCorrectionsItem())

        let filler = NSMenuItem(title: "Remove filler words (um, uh, ah, er, hmm)",
                                action: #selector(toggleRemoveFillerWords(_:)),
                                keyEquivalent: "")
        filler.target = self
        filler.state = settings.removeFillerWords ? .on : .off
        sub.addItem(filler)

        parent.submenu = sub
        return parent
    }

    private func buildBehaviorSettingsItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Behavior", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let waveform = NSMenuItem(title: "Show recording waveform",
                                  action: #selector(toggleRecordingWaveform(_:)),
                                  keyEquivalent: "")
        waveform.target = self
        waveform.state = settings.showRecordingWaveform ? .on : .off
        sub.addItem(waveform)

        let mute = NSMenuItem(title: "Mute system audio while recording",
                              action: #selector(toggleMute(_:)),
                              keyEquivalent: "")
        mute.target = self
        mute.state = settings.muteWhileRecording ? .on : .off
        sub.addItem(mute)

        let sounds = NSMenuItem(title: "Play feedback sounds",
                                action: #selector(toggleFeedbackSounds(_:)),
                                keyEquivalent: "")
        sounds.target = self
        sounds.state = settings.playFeedbackSounds ? .on : .off
        sub.addItem(sounds)

        let launchAtLogin = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin(_:)),
                                       keyEquivalent: "")
        launchAtLogin.target = self
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLogin.state = .on
        case .requiresApproval:
            launchAtLogin.state = .mixed
            launchAtLogin.toolTip = "Approve Dictor in System Settings → General → Login Items."
        default:
            launchAtLogin.state = .off
        }
        sub.addItem(launchAtLogin)

        let dock = NSMenuItem(title: "Show Dictor in Dock",
                              action: #selector(toggleDock(_:)),
                              keyEquivalent: "")
        dock.target = self
        dock.state = settings.showInDock ? .on : .off
        sub.addItem(dock)

        parent.submenu = sub
        return parent
    }

    private func buildHotkeySettingsItem() -> NSMenuItem {
        let hkParent = NSMenuItem(title: "Hotkey", action: nil, keyEquivalent: "")
        let hkSub = NSMenu()
        hkSub.autoenablesItems = false
        let current = hotkey.hotkey

        if !HOTKEY_CHOICES.contains(current) {
            let currentItem = NSMenuItem(title: current.name,
                                         action: nil,
                                         keyEquivalent: "")
            currentItem.state = .on
            currentItem.toolTip = "Recorded custom hotkey"
            hkSub.addItem(currentItem)
            hkSub.addItem(.separator())
        }

        for choice in HOTKEY_CHOICES {
            let item = NSMenuItem(title: choice.name,
                                  action: #selector(selectHotkey(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (choice == current) ? .on : .off
            item.representedObject = Int(choice.keycode)
            hkSub.addItem(item)
        }

        hkSub.addItem(.separator())

        let record = NSMenuItem(title: "Record Hotkey…",
                                action: #selector(recordHotkeyClicked(_:)),
                                keyEquivalent: "")
        record.target = self
        record.isEnabled = !isRecording && !isBusy && !isTerminating
        hkSub.addItem(record)

        let reset = NSMenuItem(title: "Reset Hotkey to Default",
                               action: #selector(resetHotkeyClicked(_:)),
                               keyEquivalent: "")
        reset.target = self
        reset.isEnabled = current != hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
            && !isRecording
            && !isBusy
            && !isTerminating
        reset.toolTip = "Use Right Command for dictation."
        hkSub.addItem(reset)

        hkParent.submenu = hkSub
        return hkParent
    }

    private func buildTriggerSettingsItem() -> NSMenuItem {
        let tmParent = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        let tmSub = NSMenu()
        tmSub.autoenablesItems = false
        for mode in [TriggerMode.hold, .toggle] {
            let item = NSMenuItem(title: TRIGGER_DISPLAY[mode] ?? mode.rawValue,
                                  action: #selector(selectTriggerMode(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (mode == settings.triggerMode) ? .on : .off
            item.representedObject = mode.rawValue
            tmSub.addItem(item)
        }
        tmParent.submenu = tmSub
        return tmParent
    }

    private func buildDictationLanguageSettingsItem() -> NSMenuItem {
        // Пункт называется по тому, что делает: подсказка языка — это фильтр
        // по алфавиту внутри декодера, а не выбор словаря.
        let langParent = NSMenuItem(title: "Output Script", action: nil, keyEquivalent: "")
        let langSub = NSMenu()
        langSub.autoenablesItems = false
        for lang in DictationLanguage.allCases {
            let item = NSMenuItem(title: DICTATION_LANGUAGE_DISPLAY[lang] ?? lang.rawValue,
                                  action: #selector(selectDictationLanguage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (lang == settings.dictationLanguage) ? .on : .off
            item.representedObject = lang.rawValue
            langSub.addItem(item)
            // Auto-detect is the right default for almost everyone; only
            // pin a specific language if you see wrong-script bleed-through
            // (e.g. Cyrillic letters in Polish output).
            if lang == .auto {
                langSub.addItem(.separator())
            }
        }
        langParent.submenu = langSub
        return langParent
    }

    private func buildPasteSuffixSettingsItem() -> NSMenuItem {
        let pasteParent = NSMenuItem(title: "After Pasting", action: nil, keyEquivalent: "")
        let pasteSub = NSMenu()
        pasteSub.autoenablesItems = false
        for suffix in [PasteSuffix.appendSpace, .none, .appendNewline] {
            let item = NSMenuItem(title: PASTE_SUFFIX_DISPLAY[suffix] ?? suffix.rawValue,
                                  action: #selector(selectPasteSuffix(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (suffix == settings.pasteSuffix) ? .on : .off
            item.representedObject = suffix.rawValue
            pasteSub.addItem(item)
        }
        pasteParent.submenu = pasteSub
        return pasteParent
    }

    private func buildRecentTranscriptLimitSettingsItem() -> NSMenuItem {
        let recentParent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let recentSub = NSMenu()
        recentSub.autoenablesItems = false
        for limit in RecentTranscriptLimit.allCases {
            let item = NSMenuItem(title: RECENT_TRANSCRIPT_LIMIT_DISPLAY[limit] ?? limit.rawValue,
                                  action: #selector(selectRecentTranscriptLimit(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.state = (limit == settings.recentTranscriptLimit) ? .on : .off
            item.representedObject = limit.rawValue
            recentSub.addItem(item)
        }
        recentParent.submenu = recentSub
        return recentParent
    }

    private func buildInputDeviceItem() -> NSMenuItem {
        let devices = availableAudioInputDevices()
        let rawSavedPreference = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedPreference = isDefaultAggregateAudioInputPreference(rawSavedPreference) ? "" : rawSavedPreference
        let selectedDevice = audioInputDevice(matching: savedPreference, in: devices)
        let canSwitch = !isRecording && !isBusy && !isTerminating
        let parent = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        if !savedPreference.isEmpty && selectedDevice == nil {
            parent.toolTip = savedPreference
        }

        let sub = NSMenu()
        sub.autoenablesItems = false

        let system = NSMenuItem(title: "System default",
                                action: #selector(selectInputDevice(_:)),
                                keyEquivalent: "")
        system.target = self
        system.representedObject = ""
        system.state = (savedPreference.isEmpty || selectedDevice == nil) ? .on : .off
        system.isEnabled = canSwitch
        sub.addItem(system)

        if !savedPreference.isEmpty && selectedDevice == nil {
            let unavailable = NSMenuItem(title: "Unavailable: \(savedPreference)",
                                         action: nil,
                                         keyEquivalent: "")
            unavailable.isEnabled = false
            sub.addItem(unavailable)
        }

        if !devices.isEmpty {
            sub.addItem(.separator())
        }

        for device in devices {
            let item = NSMenuItem(title: device.name,
                                  action: #selector(selectInputDevice(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.toolTip = device.uid
            item.state = (selectedDevice?.uid == device.uid) ? .on : .off
            item.isEnabled = canSwitch
            sub.addItem(item)
        }

        parent.submenu = sub
        return parent
    }

    @objc private func selectInputDevice(_ sender: NSMenuItem) {
        guard !isRecording, !isBusy, !isTerminating,
              let preference = sender.representedObject as? String else { return }

        settings.inputDevice = preference
        let label = preference.isEmpty
            ? "system default"
            : (audioInputDevice(matching: preference)?.name ?? preference)
        log("input device selected: \(label)")
        restartAudioForInputDeviceChange()
    }

    private func restartAudioForInputDeviceChange() {
        restartAudioInput(reason: "input device change")
    }

    private func suppressAudioConfigurationChangesFromAppEngineUpdate() {
        let suppressedUntil = Date().timeIntervalSinceReferenceDate
            + AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS
        audioConfigurationChangeSuppressedUntil = max(audioConfigurationChangeSuppressedUntil ?? 0,
                                                      suppressedUntil)
    }

    private func shouldIgnoreAppOwnedAudioConfigurationChange() -> Bool {
        let now = Date().timeIntervalSinceReferenceDate
        if audioConfigurationChangeIsSuppressed(now: now,
                                                suppressedUntil: audioConfigurationChangeSuppressedUntil) {
            return true
        }
        if let suppressedUntil = audioConfigurationChangeSuppressedUntil,
           now >= suppressedUntil {
            audioConfigurationChangeSuppressedUntil = nil
        }
        return false
    }

    private func cancelAudioIdleStop() {
        audioIdleStopWorkItem?.cancel()
        audioIdleStopWorkItem = nil
    }

    private func scheduleAudioIdleStop(reason: String) {
        cancelAudioIdleStop()
        guard audio.isEngineStarted, !isRecording, !isBusy, !isTerminating else { return }

        let work = DispatchWorkItem { [weak self] in
            self?.closeIdleAudioInputIfNeeded(reason: reason)
        }
        audioIdleStopWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AUDIO_IDLE_STOP_DELAY_SECONDS, execute: work)
    }

    private func stopAudioEngineImmediately() {
        cancelAudioIdleStop()
        if audio.isEngineStarted {
            suppressAudioConfigurationChangesFromAppEngineUpdate()
        }
        audio.stopEngine()
    }

    private func closeIdleAudioInputIfNeeded(reason: String) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        let wasEngineStarted = audio.isEngineStarted
        stopAudioEngineImmediately()
        if wasEngineStarted {
            log("AudioCapture: idle audio input closed (\(reason))")
        }
    }

    private func handleAudioConfigurationChange() {
        if shouldIgnoreAppOwnedAudioConfigurationChange() {
            log("AudioCapture: app-owned audio configuration change ignored")
            return
        }

        switch audioRouteChangeAction(isTerminating: isTerminating,
                                      isRestartingAudioInput: isRestartingAudioInput,
                                      isCoreRuntimeReady: isCoreRuntimeReady,
                                      isRecording: isRecording,
                                      isBusy: isBusy,
                                      hasStartupTask: startupTask != nil) {
        case .ignore:
            return
        case .rebuildMenuOnly:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
        case .deferRefresh:
            log("AudioCapture: audio configuration changed")
            pendingAudioRouteRefresh = true
            log("AudioCapture: audio route refresh deferred")
            rebuildMenu()
        case .restartNow:
            log("AudioCapture: audio configuration changed")
            rebuildMenu()
            restartAudioInput(reason: "audio configuration change")
        }
    }

    @discardableResult
    private func runDeferredAudioRouteRefreshIfNeeded() -> Bool {
        guard pendingAudioRouteRefresh,
              !isRecording, !isBusy, startupTask == nil, isCoreRuntimeReady, !isTerminating else { return false }
        pendingAudioRouteRefresh = false
        restartAudioInput(reason: "deferred audio configuration change")
        return true
    }

    private func restartAudioInput(reason: String) {
        guard !isRestartingAudioInput else { return }
        guard isCoreRuntimeReady else {
            rebuildMenu()
            return
        }

        pendingAudioRouteRefresh = false
        isRestartingAudioInput = true
        isReady = false
        isRecording = false
        isBusy = false
        hotkey.stop()
        setMenuBarState(.loading)
        rebuildMenu()
        stopAudioEngineImmediately()

        Task { @MainActor in
            defer { isRestartingAudioInput = false }
            do {
                try await startAudioInputWithRetries(reason: reason,
                                                     initialStatusTitle: "Restarting audio input…")
                isCoreRuntimeReady = true
                completeReadinessIfPossible(reason: reason)
            } catch {
                isCoreRuntimeReady = false
                isReady = false
                isRecording = false
                isBusy = false
                hotkey.stop()
                recordStartupFailure(stage: .audioInput, error: error, reason: reason)
            }
        }
    }

    private func buildCorrectionsItem() -> NSMenuItem {
        let corrections = settings.transcriptCorrections
        let title = corrections.isEmpty ? "Text Corrections" : "Text Corrections (\(corrections.count))"
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let add = NSMenuItem(title: "Add Correction…",
                             action: #selector(addCorrectionClicked(_:)),
                             keyEquivalent: "")
        add.target = self
        sub.addItem(add)

        let addFromLast = NSMenuItem(title: "Add Correction from Last Transcript…",
                                     action: #selector(addCorrectionFromLastTranscriptClicked(_:)),
                                     keyEquivalent: "")
        addFromLast.target = self
        addFromLast.isEnabled = visibleHistory.first != nil
        if let newest = visibleHistory.first {
            addFromLast.toolTip = previewLine(for: newest.text)
        }
        sub.addItem(addFromLast)

        sub.addItem(.separator())

        let importItem = NSMenuItem(title: "Import Corrections…",
                                    action: #selector(importCorrectionsClicked(_:)),
                                    keyEquivalent: "")
        importItem.target = self
        sub.addItem(importItem)

        let exportItem = NSMenuItem(title: "Export Corrections…",
                                    action: #selector(exportCorrectionsClicked(_:)),
                                    keyEquivalent: "")
        exportItem.target = self
        exportItem.isEnabled = !corrections.isEmpty
        sub.addItem(exportItem)

        let shareItem = NSMenuItem(title: "Share Corrections…",
                                   action: #selector(shareCorrectionsClicked(_:)),
                                   keyEquivalent: "")
        shareItem.target = self
        shareItem.isEnabled = !corrections.isEmpty
        sub.addItem(shareItem)

        sub.addItem(.separator())

        if let syncURL = correctionSyncFileURL() {
            let syncLabel = NSMenuItem(title: "Syncing: \(syncURL.lastPathComponent)",
                                       action: nil,
                                       keyEquivalent: "")
            syncLabel.isEnabled = false
            syncLabel.toolTip = syncURL.path
            sub.addItem(syncLabel)

            let syncNow = NSMenuItem(title: "Sync Now",
                                     action: #selector(syncCorrectionsNowClicked(_:)),
                                     keyEquivalent: "")
            syncNow.target = self
            sub.addItem(syncNow)

            let stopSync = NSMenuItem(title: "Stop Syncing…",
                                      action: #selector(stopSyncingCorrectionsClicked(_:)),
                                      keyEquivalent: "")
            stopSync.target = self
            sub.addItem(stopSync)
        } else {
            let startSync = NSMenuItem(title: "Set Up Sync…",
                                       action: #selector(setUpCorrectionsSyncClicked(_:)),
                                       keyEquivalent: "")
            startSync.target = self
            sub.addItem(startSync)
        }

        sub.addItem(.separator())

        if corrections.isEmpty {
            let empty = NSMenuItem(title: "No corrections", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
            parent.submenu = sub
            return parent
        }

        for (index, correction) in corrections.enumerated() {
            let item = NSMenuItem(title: correctionMenuTitle(correction),
                                  action: nil,
                                  keyEquivalent: "")
            let itemSub = NSMenu()
            itemSub.autoenablesItems = false

            let edit = NSMenuItem(title: "Edit…",
                                  action: #selector(editCorrectionClicked(_:)),
                                  keyEquivalent: "")
            edit.target = self
            edit.representedObject = index
            itemSub.addItem(edit)

            let delete = NSMenuItem(title: "Delete",
                                    action: #selector(deleteCorrectionClicked(_:)),
                                    keyEquivalent: "")
            delete.target = self
            delete.representedObject = index
            itemSub.addItem(delete)

            item.submenu = itemSub
            sub.addItem(item)
        }

        sub.addItem(.separator())

        let removeAll = NSMenuItem(title: "Remove All Corrections…",
                                   action: #selector(removeAllCorrectionsClicked(_:)),
                                   keyEquivalent: "")
        removeAll.target = self
        sub.addItem(removeAll)

        parent.submenu = sub
        return parent
    }

    private func correctionMenuTitle(_ correction: TranscriptCorrection) -> String {
        "\(clippedCorrectionText(correction.source)) → \(clippedCorrectionText(correction.replacement))"
    }

    private func clippedCorrectionText(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        return flat.count > 32 ? String(flat.prefix(32)) + "…" : flat
    }

    @objc private func addCorrectionClicked(_ sender: NSMenuItem) {
        guard let correction = showCorrectionEditor(existing: nil) else { return }
        saveCorrection(correction)
    }

    @objc private func addCorrectionFromLastTranscriptClicked(_ sender: NSMenuItem) {
        guard let newest = visibleHistory.first else { return }
        let prefill = correctionSourcePrefill(from: newest.text)
        guard !prefill.isEmpty else { return }
        guard let correction = showCorrectionEditor(existing: nil, prefillSource: prefill) else { return }
        saveCorrection(correction)
    }

    @objc private func editCorrectionClicked(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        let corrections = settings.transcriptCorrections
        guard corrections.indices.contains(index) else { return }
        guard let correction = showCorrectionEditor(existing: corrections[index]) else { return }
        saveCorrection(correction, replacing: index)
    }

    @objc private func deleteCorrectionClicked(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        var corrections = settings.transcriptCorrections
        guard corrections.indices.contains(index) else { return }
        corrections.remove(at: index)
        updateTranscriptCorrections(corrections)
    }

    @objc private func removeAllCorrectionsClicked(_ sender: NSMenuItem) {
        guard !settings.transcriptCorrections.isEmpty else { return }
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove All Text Corrections?"
        alert.informativeText = "This removes every saved text correction from this Mac."
        alert.addButton(withTitle: "Remove All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        updateTranscriptCorrections([])
    }

    @objc private func importCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSOpenPanel()
        panel.title = "Import Text Corrections"
        panel.message = "Choose a Dictor corrections file to import."
        panel.prompt = "Import"
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = importCorrectionsFromUserSelectedFile(url)
    }

    @objc private func exportCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Export Text Corrections"
        panel.message = "Save a file you can AirDrop, store in iCloud Drive, or import on another Mac."
        panel.prompt = "Export"
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            log("correction export wrote \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Export Failed", error: error)
        }
    }

    @objc private func shareCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        do {
            cleanupPendingSharedCorrections(reason: "new share")

            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("Dictor-\(UUID().uuidString)", isDirectory: true)
            let url = folder.appendingPathComponent(CORRECTIONS_FILE_NAME)
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            pendingSharedCorrectionsURL = url

            let picker = NSSharingServicePicker(items: [url])
            let cleanupDelegate = CorrectionShareCleanupDelegate { [weak self] reason in
                self?.cleanupPendingSharedCorrections(reason: reason)
            }
            picker.delegate = cleanupDelegate
            correctionSharePicker = picker
            correctionShareCleanupDelegate = cleanupDelegate
            if let button = statusItem.button {
                picker.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            } else {
                cleanupPendingSharedCorrections(reason: "missing status button")
            }
            log("correction share prepared \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Share Failed", error: error)
        }
    }

    @objc private func setUpCorrectionsSyncClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Set Up Text Correction Sync"
        alert.informativeText = """
            Dictor can keep corrections in one local file. Put that file in iCloud Drive, Dropbox, Syncthing, or another synced folder to keep multiple Macs aligned without a Dictor account.

            Dictor only reads and writes the file you choose.
            """
        alert.addButton(withTitle: "Create Sync File")
        alert.addButton(withTitle: "Use Existing File")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            createCorrectionsSyncFile()
        case .alertSecondButtonReturn:
            useExistingCorrectionsSyncFile()
        default:
            return
        }
    }

    @objc private func syncCorrectionsNowClicked(_ sender: NSMenuItem) {
        guard correctionSyncFileURL() != nil else { return }
        scheduleCorrectionSyncScan(force: true, presentErrors: true)
    }

    @objc private func stopSyncingCorrectionsClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Stop Syncing Text Corrections?"
        alert.informativeText = "Dictor will keep the corrections already on this Mac. The sync file will not be deleted."
        alert.addButton(withTitle: "Stop Syncing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()
    }

    private func showAppForModal() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var shouldShowDockIcon: Bool {
        false
    }

    private func refreshActivationPolicy() {
        if shouldShowDockIcon {
            NSApp.setActivationPolicy(.regular)
        } else {
            NSApp.setActivationPolicy(.accessory)
            NSApp.hide(nil)
        }
    }

    @discardableResult
    private func importCorrectionsFromUserSelectedFile(_ url: URL) -> Bool {
        showAppForModal()
        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            guard let choice = chooseCorrectionImportMode(imported: imported.corrections,
                                                          originalCount: imported.originalCount,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: false) else {
                return false
            }
            let next = corrections(afterApplying: imported.corrections, mode: choice)
            updateTranscriptCorrections(next)
            log("correction import read \(imported.corrections.count) corrections")
            return true
        } catch {
            showCorrectionTransferError(title: "Import Failed", error: error)
            return false
        }
    }

    private func createCorrectionsSyncFile() {
        showAppForModal()
        let panel = NSSavePanel()
        panel.title = "Create Text Correction Sync File"
        panel.message = "Choose where Dictor should keep the sync file. A folder synced by iCloud Drive or another provider works best."
        panel.prompt = "Create"
        panel.nameFieldStringValue = CORRECTIONS_FILE_NAME
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try TranscriptCorrectionsTransfer.write(settings.transcriptCorrections, to: url)
            settings.transcriptCorrectionsSyncFile = url.path
            startCorrectionSyncIfConfigured()
            log("correction sync created file with \(settings.transcriptCorrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Sync Setup Failed", error: error)
        }
    }

    private func useExistingCorrectionsSyncFile() {
        showAppForModal()
        let panel = NSOpenPanel()
        panel.title = "Choose Text Correction Sync File"
        panel.message = "Choose an existing Dictor corrections file."
        panel.prompt = "Use File"
        panel.allowedContentTypes = [TranscriptCorrectionsTransfer.contentType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            guard let choice = chooseCorrectionImportMode(imported: imported.corrections,
                                                          originalCount: imported.originalCount,
                                                          sourceName: url.lastPathComponent,
                                                          allowsEmptyReplace: true) else {
                return
            }
            let next = corrections(afterApplying: imported.corrections, mode: choice)
            settings.transcriptCorrectionsSyncFile = url.path
            updateTranscriptCorrections(next, writeToSync: false)
            if choice == .merge {
                guard writeCorrectionsToSyncFile(presentErrors: true) else {
                    settings.transcriptCorrectionsSyncFile = ""
                    rebuildMenu()
                    return
                }
            } else {
                correctionSyncFileFingerprint = correctionSyncFingerprint(for: url)
                correctionSyncBaselineCorrections = normalizedTranscriptCorrections(next)
            }
            startCorrectionSyncIfConfigured()
            log("correction sync linked file with \(imported.corrections.count) corrections")
        } catch {
            showCorrectionTransferError(title: "Sync Setup Failed", error: error)
        }
    }

    private func chooseCorrectionImportMode(imported: [TranscriptCorrection],
                                            originalCount: Int,
                                            sourceName: String,
                                            allowsEmptyReplace: Bool) -> CorrectionImportChoice? {
        let imported = normalizedTranscriptCorrections(imported)
        showAppForModal()
        if imported.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No Text Corrections Found"
            alert.informativeText = allowsEmptyReplace
                ? "\(sourceName) does not contain any corrections. You can still use it as an empty sync file."
                : "\(sourceName) does not contain any corrections to import."
            alert.addButton(withTitle: allowsEmptyReplace ? "Use Empty File" : "OK")
            if allowsEmptyReplace { alert.addButton(withTitle: "Cancel") }
            let response = alert.runModal()
            return allowsEmptyReplace && response == .alertFirstButtonReturn ? .replace : nil
        }

        let summary = correctionImportSummary(for: imported)
        let countText = correctionImportCountText(sourceName: sourceName,
                                                  originalCount: originalCount,
                                                  keptCount: summary.total)
        let mergeCapWarning = correctionImportMergeCapWarningText(
            existingCount: settings.transcriptCorrections.count,
            newCount: summary.newCount
        )
        let alert = NSAlert()
        alert.messageText = "Import Text Corrections?"
        alert.informativeText = """
            \(countText)

            \(summary.newCount) new, \(summary.updatedCount) will update existing corrections, \(summary.unchangedCount) already match.

            Merge keeps local corrections that are not in the file. Replace All makes this Mac match the file exactly.\(mergeCapWarning.map { "\n\n" + $0 } ?? "")
            """
        alert.addButton(withTitle: "Merge")
        alert.addButton(withTitle: "Replace All")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .merge
        case .alertSecondButtonReturn:
            return .replace
        default:
            return nil
        }
    }

    private func correctionImportSummary(for imported: [TranscriptCorrection]) -> CorrectionImportSummary {
        let existingBySource = Dictionary(uniqueKeysWithValues: settings.transcriptCorrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })

        var newCount = 0
        var updatedCount = 0
        var unchangedCount = 0

        for correction in imported {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            guard let existing = existingBySource[key] else {
                newCount += 1
                continue
            }
            if existing == correction {
                unchangedCount += 1
            } else {
                updatedCount += 1
            }
        }

        return CorrectionImportSummary(
            total: imported.count,
            newCount: newCount,
            updatedCount: updatedCount,
            unchangedCount: unchangedCount
        )
    }

    private func corrections(afterApplying imported: [TranscriptCorrection],
                             mode: CorrectionImportChoice) -> [TranscriptCorrection] {
        let imported = normalizedTranscriptCorrections(imported)
        switch mode {
        case .replace:
            return imported
        case .merge:
            var merged = settings.transcriptCorrections
            var indexBySource = Dictionary(uniqueKeysWithValues: merged.enumerated().map {
                (normalizedTranscriptCorrectionSource($0.element.source), $0.offset)
            })

            for correction in imported {
                let key = normalizedTranscriptCorrectionSource(correction.source)
                if let index = indexBySource[key] {
                    merged[index] = correction
                } else {
                    indexBySource[key] = merged.count
                    merged.append(correction)
                }
            }
            return merged
        }
    }

    private func updateTranscriptCorrections(_ corrections: [TranscriptCorrection],
                                             writeToSync: Bool = true) {
        if let error = settings.storeTranscriptCorrections(normalizedTranscriptCorrections(corrections)) {
            // The previous value is still in place. Surface the failed
            // save like export/sync-write failures do — silently
            // dropping the user's edit looked like data loss.
            showCorrectionTransferError(title: "Saving Corrections Failed", error: error)
            rebuildMenu()
            return
        }
        if writeToSync, !isApplyingCorrectionSyncFile {
            writeCorrectionsToSyncFile(presentErrors: false)
        }
        rebuildMenu()
    }

    private func correctionSyncFileURL() -> URL? {
        let path = settings.transcriptCorrectionsSyncFile
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func startCorrectionSyncIfConfigured() {
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        guard correctionSyncFileURL() != nil else {
            correctionSyncFileFingerprint = nil
            correctionSyncBaselineCorrections = []
            return
        }

        scheduleCorrectionSyncScan(force: true, presentErrors: false)
        // The timer always starts; if the initial async scan rejects
        // the path it stops the sync (and this timer) from its
        // main-actor completion.
        correctionSyncTimer = Timer.scheduledTimer(timeInterval: 4,
                                                   target: self,
                                                   selector: #selector(correctionSyncTimerFired(_:)),
                                                   userInfo: nil,
                                                   repeats: true)
        correctionSyncTimer?.tolerance = 1
    }

    @objc private func correctionSyncTimerFired(_ timer: Timer) {
        scheduleCorrectionSyncScan(force: false, presentErrors: false)
    }

    /// What a background sync-file scan found. Built off the main
    /// thread, applied on the main actor — so it must be Sendable and
    /// carry everything the apply step needs.
    private enum CorrectionSyncScanOutcome: Sendable {
        case rejectedPath(TranscriptCorrectionsSyncPathError)
        case fingerprintUnavailable
        case unchanged
        case loaded(corrections: [TranscriptCorrection], fingerprint: CorrectionSyncFileFingerprint)
        case readFailed(logDescription: String, alertMessage: String)
    }

    /// Runs on `correctionSyncScanQueue` (hence `nonisolated`). Pure
    /// with respect to app state: everything it needs arrives as
    /// parameters and the result goes back as a value.
    private nonisolated static func performCorrectionSyncScan(url: URL,
                                                  lastFingerprint: CorrectionSyncFileFingerprint?,
                                                  force: Bool) -> CorrectionSyncScanOutcome {
        do {
            try validateCorrectionSyncPath(url)
        } catch let error as TranscriptCorrectionsSyncPathError {
            return .rejectedPath(error)
        } catch {
            // validateCorrectionSyncPath only throws
            // TranscriptCorrectionsSyncPathError today; keep the
            // catch-all defensive rather than crashing the scan.
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
        guard let fingerprint = correctionSyncFingerprint(for: url) else {
            return .fingerprintUnavailable
        }
        guard force || fingerprint != lastFingerprint else { return .unchanged }
        do {
            let corrections = try TranscriptCorrectionsTransfer.read(from: url)
            return .loaded(corrections: corrections, fingerprint: fingerprint)
        } catch {
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
    }

    private func scheduleCorrectionSyncScan(force: Bool, presentErrors: Bool) {
        guard let url = correctionSyncFileURL() else { return }
        // Never let scans overlap — a dataless iCloud file can block
        // one scan for many timer periods. Requests that arrive while
        // a scan is in flight are coalesced (strongest flags win) and
        // re-issued when it completes, so a user's explicit
        // "Sync Corrections Now" is never silently dropped behind a
        // stalled timer scan.
        guard !correctionSyncScanInFlight else {
            let pending = pendingCorrectionSyncScan
            pendingCorrectionSyncScan = (force: (pending?.force ?? false) || force,
                                         presentErrors: (pending?.presentErrors ?? false) || presentErrors)
            return
        }
        correctionSyncScanInFlight = true
        let lastFingerprint = correctionSyncFileFingerprint
        Self.correctionSyncScanQueue.async { [weak self] in
            let outcome = Self.performCorrectionSyncScan(url: url,
                                                         lastFingerprint: lastFingerprint,
                                                         force: force)
            Task { @MainActor in
                guard let self else { return }
                self.correctionSyncScanInFlight = false
                self.applyCorrectionSyncScanOutcome(outcome,
                                                    scannedURL: url,
                                                    scanStartFingerprint: lastFingerprint,
                                                    force: force,
                                                    presentErrors: presentErrors)
                if let pending = self.pendingCorrectionSyncScan {
                    self.pendingCorrectionSyncScan = nil
                    self.scheduleCorrectionSyncScan(force: pending.force,
                                                    presentErrors: pending.presentErrors)
                }
            }
        }
    }

    private func applyCorrectionSyncScanOutcome(_ outcome: CorrectionSyncScanOutcome,
                                                scannedURL: URL,
                                                scanStartFingerprint: CorrectionSyncFileFingerprint?,
                                                force: Bool,
                                                presentErrors: Bool) {
        // The sync file may have been disconnected or repointed while
        // the scan ran; results for a stale path must not touch
        // current state.
        guard let url = correctionSyncFileURL(), url == scannedURL else { return }

        switch outcome {
        case .rejectedPath(let error):
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
        case .fingerprintUnavailable:
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed",
                                            message: "Dictor could not find the selected sync file.")
            }
        case .unchanged:
            break
        case .loaded(let corrections, let fingerprint):
            // If a local edit wrote the sync file (moving the
            // fingerprint) while the scan ran, this outcome holds
            // pre-edit content; applying it would roll the edit back
            // and rewind the baseline. Drop it — a forced scan is
            // re-issued so a "Sync Now" still completes against the
            // post-edit file.
            guard correctionSyncFileFingerprint == scanStartFingerprint else {
                if force {
                    scheduleCorrectionSyncScan(force: true, presentErrors: presentErrors)
                }
                return
            }
            // Non-forced scans only apply genuinely new content
            // (forced scans deliberately re-apply even an unchanged
            // file — that is what "Sync Now" promises).
            guard force || fingerprint != correctionSyncFileFingerprint else { return }
            isApplyingCorrectionSyncFile = true
            updateTranscriptCorrections(corrections, writeToSync: false)
            isApplyingCorrectionSyncFile = false
            correctionSyncFileFingerprint = fingerprint
            correctionSyncBaselineCorrections = normalizedTranscriptCorrections(corrections)
            log("correction sync read \(corrections.count) corrections")
        case .readFailed(let logDescription, let alertMessage):
            log("correction sync read failed: \(logDescription)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", message: alertMessage)
            }
        }
    }

    @discardableResult
    private func writeCorrectionsToSyncFile(presentErrors: Bool) -> Bool {
        guard let url = correctionSyncFileURL() else { return true }
        do {
            try validateCorrectionSyncPath(url)
        } catch {
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
            return false
        }
        do {
            var correctionsToWrite = normalizedTranscriptCorrections(settings.transcriptCorrections)
            if let knownFingerprint = correctionSyncFileFingerprint,
               let currentFingerprint = correctionSyncFingerprint(for: url),
               currentFingerprint != knownFingerprint {
                let remoteCorrections = try TranscriptCorrectionsTransfer.read(from: url)
                let merge = mergedTranscriptCorrectionsForSync(
                    base: correctionSyncBaselineCorrections,
                    local: correctionsToWrite,
                    remote: remoteCorrections
                )
                if !merge.conflictingSources.isEmpty {
                    stopCorrectionSyncAfterConflict(conflictingSources: merge.conflictingSources)
                    log("correction sync stopped after \(merge.conflictingSources.count) conflicting corrections")
                    return false
                }
                // Normalize (cap) the merge result BEFORE it fans out:
                // file, settings, and baseline must all hold the same
                // list. A raw over-cap merge result stored as baseline
                // made capped-out entries look like local deletions on
                // the next merge, silently removing them from the file.
                correctionsToWrite = normalizedTranscriptCorrections(merge.corrections)
                if let storeError = settings.storeTranscriptCorrections(correctionsToWrite) {
                    throw storeError
                }
            }

            let writtenData = try TranscriptCorrectionsTransfer.write(correctionsToWrite, to: url)
            // Fingerprint the exact bytes written, not a re-read of the
            // file: a sync provider replacing the file in the re-read
            // window would have its change fingerprinted as ours and
            // swallowed until the next local edit.
            correctionSyncFileFingerprint = correctionSyncFingerprint(forWrittenData: writtenData, at: url)
            correctionSyncBaselineCorrections = correctionsToWrite
            log("correction sync wrote \(correctionsToWrite.count) corrections")
            return true
        } catch {
            log("correction sync write failed: \(error)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return false
        }
    }

    private func handleCorrectionSyncRejectedPath(_ error: Error, presentErrors: Bool) {
        log("correction sync rejected path: \(error)")
        guard shouldStopCorrectionSync(afterPathValidationError: error) else {
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return
        }

        stopCorrectionSyncAfterRejectedPath(error: error, presentErrors: presentErrors)
    }

    private func stopCorrectionSyncAfterConflict(conflictingSources: [String]) {
        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()

        let exampleCount = min(conflictingSources.count, 3)
        let examples = conflictingSources.prefix(exampleCount).joined(separator: "\n")
        let remaining = conflictingSources.count - exampleCount
        let remainingText = remaining > 0 ? "\n…and \(remaining) more." : ""
        showAppForModal()
        showCorrectionTransferError(
            title: "Text Correction Sync Conflict",
            message: """
            The sync file changed before this Mac wrote its latest text correction edits. Dictor kept the corrections on this Mac and stopped syncing so it would not overwrite the file.

            Reconnect the sync file after importing or resolving the conflicting correction\(conflictingSources.count == 1 ? "" : "s"):
            \(examples)\(remainingText)
            """
        )
    }

    private func stopCorrectionSyncAfterRejectedPath(error: Error, presentErrors: Bool) {
        settings.transcriptCorrectionsSyncFile = ""
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        log("correction sync stopped after rejected path")
        rebuildMenu()

        if presentErrors {
            showCorrectionTransferError(
                title: "Text Correction Sync Stopped",
                message: """
                Dictor stopped syncing because the selected corrections file is no longer safe to use.

                \(error.localizedDescription)
                """
            )
        }
    }

    private func showCorrectionTransferError(title: String, error: Error) {
        showCorrectionTransferError(title: title, message: error.localizedDescription)
    }

    private func showCorrectionTransferError(title: String, message: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func showCorrectionEditor(existing: TranscriptCorrection?,
                                      prefillSource: String = "") -> TranscriptCorrection? {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Text Correction" : "Edit Text Correction"
        alert.informativeText = "Add the incorrect text Dictor typed, then the text it should paste instead."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let viewWidth: CGFloat = 520
        let labelHeight: CGFloat = 18
        let fieldHeight: CGFloat = 76
        let viewHeight: CGFloat = (labelHeight * 2) + (fieldHeight * 2) + 24
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight))

        let sourceLabel = NSTextField(labelWithString: "Typed")
        sourceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        sourceLabel.frame = NSRect(x: 0, y: viewHeight - labelHeight, width: viewWidth, height: labelHeight)

        let sourceEditor = correctionTextEditor(
            frame: NSRect(x: 0, y: viewHeight - labelHeight - fieldHeight, width: viewWidth, height: fieldHeight),
            text: existing?.source ?? prefillSource.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let replacementLabel = NSTextField(labelWithString: "Paste")
        replacementLabel.font = .systemFont(ofSize: 12, weight: .medium)
        replacementLabel.frame = NSRect(x: 0, y: fieldHeight + 6, width: viewWidth, height: labelHeight)

        let replacementEditor = correctionTextEditor(
            frame: NSRect(x: 0, y: 0, width: viewWidth, height: fieldHeight),
            text: existing?.replacement ?? ""
        )

        accessory.addSubview(sourceLabel)
        accessory.addSubview(sourceEditor.scrollView)
        accessory.addSubview(replacementLabel)
        accessory.addSubview(replacementEditor.scrollView)
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = sourceEditor.textView

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let source = sourceEditor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = replacementEditor.textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty, !replacement.isEmpty else {
            showCorrectionValidationError()
            return nil
        }

        return TranscriptCorrection(source: source, replacement: replacement)
    }

    private func correctionTextEditor(frame: NSRect, text: String) -> (scrollView: NSScrollView, textView: NSTextView) {
        let scroll = NSScrollView(frame: frame)
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: frame.width, height: frame.height))
        textView.font = .systemFont(ofSize: 13)
        textView.string = text
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 6, height: 5)
        textView.minSize = NSSize(width: 0, height: frame.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: frame.width,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        return (scroll, textView)
    }

    private func showCorrectionValidationError() {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Correction Not Saved"
        alert.informativeText = "Both fields need text."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func saveCorrection(_ correction: TranscriptCorrection, replacing index: Int? = nil) {
        var corrections = settings.transcriptCorrections
        let key = normalizedTranscriptCorrectionSource(correction.source)

        if let index, corrections.indices.contains(index) {
            corrections[index] = correction
            var keepIndex = index
            for i in corrections.indices.reversed() {
                guard i != keepIndex, normalizedTranscriptCorrectionSource(corrections[i].source) == key else { continue }
                corrections.remove(at: i)
                if i < keepIndex { keepIndex -= 1 }
            }
        } else if let duplicate = corrections.firstIndex(where: { normalizedTranscriptCorrectionSource($0.source) == key }) {
            corrections[duplicate] = correction
        } else {
            corrections.append(correction)
        }

        updateTranscriptCorrections(corrections)
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let kc = sender.representedObject as? Int else { return }
        _ = applyHotkeyChoice(hotkeyChoice(forKeycode: CGKeyCode(kc)))
    }

    @objc private func recordHotkeyClicked(_ sender: NSMenuItem) {
        showHotkeyRecorder()
    }

    @objc private func resetHotkeyClicked(_ sender: NSMenuItem) {
        if applyHotkeyChoice(hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)) {
            log("HotkeyListener: reset hotkey to default")
        }
    }

    private func applyHotkeyChoice(_ choice: HotkeyChoice) -> Bool {
        let previous = hotkey.hotkey

        guard let recordable = recordableHotkeyChoice(forKeycode: choice.keycode,
                                                      modifiers: choice.requiredModifiers) else {
            if case .rejected(let message) = hotkeyPreferenceUpdateResult(
                requested: choice,
                previous: previous,
                persisted: previous
            ) {
                showHotkeyRecordError(message)
            }
            return false
        }

        settings.setConfiguredHotkey(recordable)
        hotkey.setHotkey(recordable)
        hotkeyTestSucceeded = false

        switch hotkeyPreferenceUpdateResult(
            requested: recordable,
            previous: previous,
            persisted: settings.configuredHotkey
        ) {
        case .saved:
            rebuildMenu()
            updateSetupChecklist()
            return true
        case .rejected(let message):
            showHotkeyRecordError(message)
            return false
        case .rolledBack(let previous, let message):
            settings.setConfiguredHotkey(previous)
            hotkey.setHotkey(previous)
            showHotkeyRecordError(message)
            rebuildMenu()
            return false
        }
    }

    private func showHotkeyRecorder() {
        guard !isRecording, !isBusy, !isTerminating else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present()
            return
        }
        showAppForModal()

        let shouldRestoreHotkeyTap = isReady
        if shouldRestoreHotkeyTap {
            hotkey.stop()
        }

        let recorder = HotkeyRecorderController(language: settings.interfaceLanguage) { [weak self] selected in
            guard let self else { return }
            self.hotkeyRecorder = nil
            let restartSucceeded: Bool
            if shouldRestoreHotkeyTap && !self.isTerminating {
                restartSucceeded = self.hotkey.start()
            } else {
                restartSucceeded = false
            }
            switch hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: shouldRestoreHotkeyTap,
                isTerminating: self.isTerminating,
                restartSucceeded: restartSucceeded
            ) {
            case .none, .restoredListener:
                break
            case .recordFailure:
                self.recordStartupFailure(
                    stage: .hotkeyListener,
                    error: NSError(
                        domain: "Dictor",
                        code: -5,
                        userInfo: [
                            NSLocalizedDescriptionKey: "The hotkey listener could not restart after recording a hotkey."
                        ]
                    ),
                    reason: "hotkey recorder"
                )
            }
            guard let selected else { return }
            if self.applyHotkeyChoice(selected) {
                log("HotkeyListener: recorded hotkey → \(selected.name)")
            }
        }
        hotkeyRecorder = recorder
        recorder.present()
    }

    private func showHotkeyRecordError(_ message: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Hotkey Not Changed"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func selectTriggerMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = TriggerMode(rawValue: raw) else { return }
        settings.triggerMode = m
        hotkey.setTriggerMode(m)
        rebuildMenu()
    }

    @objc private func selectPasteSuffix(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let suffix = PasteSuffix(rawValue: raw) else { return }
        settings.pasteSuffix = suffix
        rebuildMenu()
    }

    @objc private func selectDictationLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let lang = DictationLanguage(rawValue: raw) else { return }
        settings.dictationLanguage = lang
        rebuildMenu()
    }

    @objc private func selectRecentTranscriptLimit(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let limit = RecentTranscriptLimit(rawValue: raw) else { return }
        settings.recentTranscriptLimit = limit
        applyRecentTranscriptLimit()
        rebuildMenu()
    }

    @objc private func toggleRecordingWaveform(_ sender: NSMenuItem) {
        settings.showRecordingWaveform.toggle()
        sender.state = settings.showRecordingWaveform ? .on : .off
        if settings.showRecordingWaveform, isRecording {
            showRecordingHUD(mode: .recording, level: recordingVisualLevel)
        } else {
            hideRecordingHUD()
        }
    }

    @objc private func toggleMute(_ sender: NSMenuItem) {
        settings.muteWhileRecording.toggle()
        sender.state = settings.muteWhileRecording ? .on : .off
    }

    @objc private func toggleRemoveFillerWords(_ sender: NSMenuItem) {
        settings.removeFillerWords.toggle()
        sender.state = settings.removeFillerWords ? .on : .off
    }

    @objc private func toggleFeedbackSounds(_ sender: NSMenuItem) {
        settings.playFeedbackSounds.toggle()
        sender.state = settings.playFeedbackSounds ? .on : .off
    }

    @objc private func toggleDock(_ sender: NSMenuItem) {
        settings.showInDock.toggle()
        sender.state = settings.showInDock ? .on : .off
        refreshActivationPolicy()
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
                log("launch at login disabled")
            default:
                try SMAppService.mainApp.register()
                log("launch at login enabled")
            }
        } catch {
            showLaunchAtLoginError(error)
        }
        rebuildMenu()
    }

    private func showLaunchAtLoginError(_ error: Error) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Launch at Login couldn't be changed"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc private func resetSpeechModelCacheClicked(_ sender: NSMenuItem) {
        guard !isRecording,
              !isBusy,
              startupTask == nil,
              !isResettingSpeechModelCache,
              !isSwitchingSpeechModel,
              !isTerminating else { return }

        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset Speech Model Cache?"
        let profile = settings.speechModelProfile
        alert.informativeText = profile.cacheResetDetail
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        isResettingSpeechModelCache = true
        prepareForStartupAttempt()
        startupStatusTitle = "Resetting speech model cache…"
        log("ASR: \(profile.shortName) cache reset started")
        rebuildMenu()

        Task { @MainActor in
            await asr.unload()
            let cacheDir = speechModelCacheDirectory(for: profile)
            do {
                let didRemoveCache = try await removeSpeechModelCacheDirectory(cacheDir)
                if didRemoveCache {
                    log("ASR: removed \(profile.shortName) cache \(privacySafeLogPath(cacheDir))")
                } else {
                    log("ASR: \(profile.shortName) cache reset requested; cache was already absent")
                }
                isResettingSpeechModelCache = false
                startStartup(reason: "speech model cache reset")
            } catch {
                isResettingSpeechModelCache = false
                log("ASR: speech model cache reset failed: \(error)")
                showSpeechModelCacheResetError(error)
                startStartup(reason: "speech model cache reset recovery")
            }
        }
    }

    private func showSpeechModelCacheResetError(_ error: Error) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Speech model cache couldn't be reset"
        alert.informativeText = "\(error)"
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - About dialog

    @objc private func showAboutClicked(_ sender: NSMenuItem) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Dictor \(currentBundleVersion())"
        alert.informativeText = """
            Lightweight push-to-talk dictation for Apple Silicon Macs.

            Hotkey:  \(hotkey.hotkey.name)
            Mode:    \(TRIGGER_DISPLAY[settings.triggerMode] ?? settings.triggerMode.rawValue)
            Model:   \(settings.speechModelProfile.aboutModelText)

            Local-only dictation. No cloud transcription, no telemetry.
            Network: model download, optional update check and install.
            Permissions: microphone audio, paste-at-cursor, push-to-talk hotkey.

            Open source, based on Dictor by Richard Courtman.
            \(UPDATE_CHANNEL_PAGE.host ?? "") · MIT licensed
            """
        // Use our app icon instead of NSAlert's default exclamation
        // mark. .icns lives in Contents/Resources/Dictor.icns;
        // NSImage(named:) on Bundle.main resolves it by filename
        // sans extension.
        if let icon = NSImage(named: "Dictor") {
            alert.icon = icon
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Download Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UPDATE_CHANNEL_PAGE)
        }
    }

    // MARK: - Update flow

    private func startUpdateCheckLoop() {
        // Цикл был отключён, пока обновления вели на апстрим-репозиторий.
        // Теперь канал свой (UPDATE_MANIFEST_URL), а ставится только сборка,
        // подписанная нашим сертификатом (UPDATE_SIGNING_CERT_SHA1).
        guard settings.checkForUpdates else { return }
        guard updateCheckLoopTask == nil else { return }
        updateCheckLoopTask = Task.detached { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_FIRST_DELAY_SECONDS * 1_000_000_000))
            while !Task.isCancelled {
                await self?.tickUpdateCheck()
                try? await Task.sleep(nanoseconds: UInt64(UPDATE_CHECK_INTERVAL_SECONDS * 1_000_000_000))
            }
        }
    }

    /// Silent update check: failures are recorded in diagnostics but
    /// never alerted. Manual checks take a different path
    /// (`quickPanelCheckForUpdates`) and record `.manual` themselves.
    private func tickUpdateCheck(source: UpdateCheckSource = .automatic) async {
        guard settings.checkForUpdates else { return }
        let outcome = await UpdateCheck.fetchLatest()
        await MainActor.run {
            self.recordUpdateCheck(release: try? outcome.get(), source: source)
            guard let release = try? outcome.get() else { return }
            self.handleFetchedRelease(release, source: source)
        }
    }

    private func recordUpdateCheck(release: DictorRelease?, source: UpdateCheckSource) {
        let skippedVersions = source == .manual ? [] : settings.skippedVersions
        let result = updateCheckResult(
            for: release,
            currentVersion: currentBundleVersion(),
            skippedVersions: skippedVersions
        )
        settings.lastUpdateCheckAt = Date()
        settings.lastUpdateCheckSource = source
        settings.lastUpdateCheckResult = result
        settings.lastUpdateCheckVersion = release?.version ?? ""

        let versionText = release.map { " v\($0.version)" } ?? ""
        log("update check \(source.rawValue): \(result.rawValue)\(versionText)")
    }

    private func handleFetchedRelease(_ release: DictorRelease,
                                      source: UpdateCheckSource = .automatic) {
        let current = currentBundleVersion()
        guard isNewer(release.version, than: current) else { return }
        // Пропуск версии и пауза «Позже» глушат только автоматические
        // проверки. Ручную человек запускает сам — и «Установлена последняя
        // версия» при живом обновлении была ложью, а снять пропуск было
        // просто негде.
        if source != .manual {
            if settings.skippedVersions.contains(release.version) {
                log("update available (v\(release.version)) but user skipped — staying quiet")
                return
            }
            let now = Date()
            if shouldSuppressUpdateForReminder(version: release.version,
                                               reminderVersion: reminderPausedUpdateVersion,
                                               reminderUntil: reminderPausedUntil,
                                               now: now) {
                if let reminderPausedUntil {
                    log("update available (v\(release.version)) but reminder is paused until \(ISO8601DateFormatter().string(from: reminderPausedUntil))")
                }
                return
            }
            // Same version → the pause expired and the update is re-shown.
            // Newer version → it supersedes the paused one, so the stale
            // pause must not linger in diagnostics alongside the new
            // pending update. (An ACTIVE pause for this exact version
            // already returned above.)
            if shouldClearUpdateReminderPause(fetchedVersion: release.version,
                                              pausedVersion: reminderPausedUpdateVersion) {
                clearUpdateReminderPause()
            }
        }
        log("update available: \(current) → v\(release.version)")
        pendingUpdate = release
        rebuildMenu()
        if source == .manual, let existing = updateAvailableWindow {
            // Окно уже показано (и, возможно, закопано под чужими) — ручная
            // проверка обязана его поднять, а не промолчать об уже известном.
            showAppForModal()
            existing.makeKeyAndOrderFront(nil)
        } else {
            presentUpdateWindow(for: release, currentVersion: current)
        }
    }

    /// Окно с предложением обновиться. Пункт в меню-баре для этого не годился:
    /// меню открывается правым кликом по иконке в строке состояния, а до этого
    /// не додумывается почти никто — предложение обновиться существовало
    /// примерно нигде.
    private func presentUpdateWindow(for release: DictorRelease, currentVersion: String) {
        guard updateAvailableWindow == nil else { return }
        let window = UpdateAvailableWindow(release: release,
                                           currentVersion: currentVersion,
                                           language: settings.interfaceLanguage)
        window.updateDelegate = self
        // Крестик обязан чистить ссылку так же, как «Позже» и «Пропустить»
        // (windowWillClose), — окно .closable, и человек им пользуется.
        window.delegate = self
        updateAvailableWindow = window
        window.center()
        showAppForModal()
        window.makeKeyAndOrderFront(nil)
        log("update window shown for v\(release.version)")
    }

    private func closeUpdateWindow() {
        updateAvailableWindow?.close()
        updateAvailableWindow = nil
    }


    private func buildUpdateItem(for release: DictorRelease) -> NSMenuItem {
        // Пока идёт скачивание, меню — единственное место, где видно, что
        // нажатие вообще что-то сделало: окно прогресса появляется только
        // после проверки архива, а до неё десятки мегабайт.
        if let installing = installingUpdateVersion {
            let busy = NSMenuItem(title: "Installing Dictor v\(installing)…",
                                  action: nil, keyEquivalent: "")
            busy.isEnabled = false
            return busy
        }

        let parent = NSMenuItem(title: "Update to v\(release.version)",
                                action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.autoenablesItems = false

        let whatsNew = NSMenuItem(title: "What's new…",
                                  action: #selector(whatsNewClicked(_:)),
                                  keyEquivalent: "")
        whatsNew.target = self
        sub.addItem(whatsNew)

        let updateNow = NSMenuItem(title: "Update now…",
                                   action: #selector(updateNowClicked(_:)),
                                   keyEquivalent: "")
        updateNow.target = self
        sub.addItem(updateNow)

        let remindLater = NSMenuItem(title: "Remind me in 24 hours",
                                     action: #selector(remindMeLaterClicked(_:)),
                                     keyEquivalent: "")
        remindLater.target = self
        sub.addItem(remindLater)

        let skip = NSMenuItem(title: "Skip v\(release.version)",
                              action: #selector(skipVersionClicked(_:)),
                              keyEquivalent: "")
        skip.target = self
        sub.addItem(skip)

        parent.submenu = sub
        return parent
    }

    private func showReleaseNotes(for release: DictorRelease) {
        showAppForModal()
        let alert = NSAlert()
        alert.messageText = "Dictor v\(release.version)"
        var body = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { body = "(No release notes available for this version.)" }
        else if body.count > 1500 { body = String(body.prefix(1500)) + "\n\n…" }
        alert.informativeText = body
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Open in Browser")
        let response = alert.runModal()
        if response == .alertSecondButtonReturn,
           let url = URL(string: release.htmlURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func whatsNewClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        showReleaseNotes(for: release)
    }

    @objc private func updateNowClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        startUpdate(for: release)
    }

    @objc private func remindMeLaterClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        pauseUpdateReminder(for: release)
    }

    @objc private func skipVersionClicked(_ sender: NSMenuItem) {
        guard let release = pendingUpdate else { return }
        var skipped = settings.skippedVersions
        if !skipped.contains(release.version) {
            skipped.append(release.version)
            settings.skippedVersions = skipped
            log("user skipped v\(release.version); suppressing until a newer release")
        }
        pendingUpdate = nil
        clearUpdateReminderPause()
        rebuildMenu()
    }

    private func pauseUpdateReminder(for release: DictorRelease) {
        setUpdateReminderPause(version: release.version,
                               until: Date().addingTimeInterval(UPDATE_REMIND_LATER_SECONDS))
        pendingUpdate = nil
        if let reminderPausedUntil {
            log("user chose remind later for v\(release.version); paused until \(ISO8601DateFormatter().string(from: reminderPausedUntil))")
        }
        rebuildMenu()
    }

    // MARK: "Remind me later" pause state
    //
    // The in-memory fields drive menu/diagnostics decisions; the
    // Settings copies survive relaunches. The pause used to be
    // memory-only, so quitting inside the 24 h window re-prompted the
    // user ~30 s after the next launch. These two helpers are the ONLY
    // write paths so memory and defaults can never disagree.

    private func setUpdateReminderPause(version: String, until: Date) {
        reminderPausedUpdateVersion = version
        reminderPausedUntil = until
        settings.updateReminderPausedVersion = version
        settings.updateReminderPausedUntil = until
    }

    private func clearUpdateReminderPause() {
        reminderPausedUpdateVersion = nil
        reminderPausedUntil = nil
        settings.updateReminderPausedVersion = nil
        settings.updateReminderPausedUntil = nil
    }

    /// Restores a persisted pause at launch. Either half missing or
    /// corrupt (the validated Settings accessors degrade those to nil)
    /// means no pause: clear the leftover half rather than carrying
    /// incoherent state.
    private func restoreUpdateReminderPause() {
        guard let version = settings.updateReminderPausedVersion,
              let until = settings.updateReminderPausedUntil else {
            clearUpdateReminderPause()
            return
        }
        reminderPausedUpdateVersion = version
        reminderPausedUntil = until
    }

    private func showUpdateCheckFailedAlert(_ failure: UpdateCheckFailure) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates"
        alert.informativeText = manualUpdateCheckFailureText(failure)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// «Update now…» — единственная кнопка, ради которой писался апдейтер.
    /// До 1.1.0 она не устанавливала ничего: показывала совет выполнить в
    /// Терминале установочный скрипт из апстримового репозитория, которого в
    /// проекте давно нет. Заметно это не было, потому что цикл проверки стоял
    /// за мёртвым `return` и до кнопки нельзя было добраться.
    ///
    /// Теперь она делает то, что обещает: манифест → архив → SHA-256 →
    /// проверка подписи нашим сертификатом → подмена бандла с перезапуском.
    /// Загрузка идёт в фоне, а меню всё это время показывает, что происходит:
    /// молчание в ответ на нажатие читается как поломка.
    private func startUpdate(for release: DictorRelease) {
        guard updateInstallTask == nil else { return }
        let version = release.version
        log("update: installing v\(version)")
        installingUpdateVersion = version
        rebuildMenu()
        updateAvailableWindow?.showProgress(
            localizedText("Скачиваю и проверяю архив…",
                          "Downloading and verifying the archive…",
                          language: settings.interfaceLanguage))
        updateInstallTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let manifest = try await DictorUpdateInstaller.fetchManifest(
                    expectedVersion: version)
                let prepared = try await DictorUpdateInstaller.prepare(manifest: manifest)
                // Скрипт ждёт смерти этого процесса, чтобы заменить бандл, и
                // сам снимает службу. Уходим с дороги сразу после запуска.
                try launchPreparedDictorUpdate(prepared, language: self.settings.interfaceLanguage)
                log("update: helper started, quitting for v\(version)")
                self.updateInstallTask = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    NSApp.terminate(nil)
                }
            } catch {
                self.updateInstallTask = nil
                self.installingUpdateVersion = nil
                self.rebuildMenu()
                let detail = (error as? DictorUpdateInstallerError)?
                    .message(language: self.settings.interfaceLanguage)
                    ?? error.localizedDescription
                if let window = self.updateAvailableWindow {
                    window.showFailure(detail)
                } else {
                    self.showUpdateCouldNotStart(version: version, detail: detail)
                }
            }
        }
    }

    private func showUpdateCouldNotStart(version: String, detail: String) {
        log("update: install of v\(version) failed: \(detail)")
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Dictor v\(version) was not installed"
        alert.informativeText = """
        \(detail)

        The version you have is untouched. You can try again later, or \
        download the new version yourself from \(UPDATE_CHANNEL_PAGE.absoluteString)
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Download Page")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(UPDATE_CHANNEL_PAGE)
        }
    }


    // MARK: - TCC stale-state recovery on upgrade

    private func recoverStaleTCCAfterUpgrade() {
        let last = settings.lastSeenVersion
        let current = currentBundleVersion()
        guard !last.isEmpty else {
            // First-ever launch — just record the version. No state
            // to recover.
            settings.lastSeenVersion = current
            return
        }
        guard last != current else { return }
        log("upgrade detected: \(last) → \(current); checking for stale TCC state")
        let bundleID = Bundle.main.bundleIdentifier ?? "com.raul.dictor"
        for p in Permission.allCases {
            if Permissions.isGranted(p) { continue }
            // Fire-and-forget on TCC's serial queue: these resets are
            // best-effort scrubbing of stale DENIED entries, nothing
            // at launch depends on their completion, and the user's
            // first Grant click has its own reset-and-retry path.
            TCC.reset(p, bundleID: bundleID)
        }
        settings.lastSeenVersion = current
    }
}



// MARK: - Quick panel (поповер меню-бара)

extension DictorApp: QuickPanelDelegate {

    @objc func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // Сервисное меню: модель, словарь, диагностика — до переезда
            // всего в новую панель настроек.
            statusItem.menu = buildMenu()
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        let panel = quickPanel ?? {
            let created = DictorQuickPanel(state: quickPanelState())
            created.quickDelegate = self
            quickPanel = created
            return created
        }()
        panel.toggle(relativeTo: sender, state: quickPanelState())
    }

    /// Состояние службы для панели. Агент — это и есть служба, поэтому здесь
    /// оно известно напрямую, без чтения файла состояния.
    ///
    /// Наружу — состояние, выдержавшее паузу (макет 8c): прогрев длится 0,2 с
    /// и в шапке успевал только мигнуть.
    private func quickPanelServiceStatus() -> ServiceStatusKind {
        let settled = quickPanelStatusHold.settle(rawQuickPanelServiceStatus())
        scheduleQuickPanelStatusWakeup()
        return settled
    }

    /// Пока панель открыта, созревшую паузу некому донести до экрана: шапка
    /// пересобирается по событиям службы, а их в этот момент может не быть.
    private func scheduleQuickPanelStatusWakeup() {
        quickPanelStatusHoldTimer?.invalidate()
        quickPanelStatusHoldTimer = nil
        guard let deadline = quickPanelStatusHold.pendingDeadline,
              quickPanel?.isVisible == true else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        quickPanelStatusHoldTimer = Timer.scheduledTimer(withTimeInterval: delay,
                                                         repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.quickPanel?.isVisible == true else { return }
                self.quickPanel?.apply(state: self.quickPanelState())
            }
        }
    }

    private func rawQuickPanelServiceStatus() -> ServiceStatusKind {
        if installingUpdateVersion != nil { return .updating }
        if !settings.agentEnabled { return .off }
        if let missing = missingPermissions().first {
            return .needsPermission(name: missing.rawValue)
        }
        // Отказ на старте (модель не загрузилась, слушатель хоткея не встал)
        // раньше сюда не доносился: сборщик проваливался в «Служба
        // запускается · обычно 1–3 секунды» — навечно. Состояние .failed из
        // макета 8 с кнопкой «Открыть Настройки» существовало и было
        // недостижимо.
        if startupFailure != nil { return .failed }
        if let verified = verifiedModelFiles, let total = totalModelFiles {
            return .verifying(done: verified, total: total)
        }
        if !isSpeechModelReady {
            if speechModelStartupProgressFraction != nil || downloadedModelFiles != nil {
                return .downloading(fraction: speechModelStartupProgressFraction,
                                    files: downloadedModelFiles,
                                    totalFiles: totalDownloadModelFiles)
            }
            return .starting
        }
        if !isReady { return .warmingUp }
        return .ready(latencyMilliseconds: medianLatencyMilliseconds)
    }

    func quickPanelState() -> QuickPanelState {
        let language = settings.interfaceLanguage
        let title: String
        let subtitle: String
        if isDictationPaused {
            title = localizedText("Диктовка на паузе", "Dictation paused", language: language)
            subtitle = localizedText("Включите тумблер, чтобы вернуть хоткей",
                                     "Turn the switch on to restore the hotkey",
                                     language: language)
        } else if isRecording {
            title = localizedText("Записываю", "Recording", language: language)
            subtitle = localizedText("Говорите — всё остаётся на этом Mac",
                                     "Speak — everything stays on this Mac",
                                     language: language)
        } else if isReady {
            let hotkeyName = localizedHotkeyName(hotkey.hotkey, language: language)
            title = localizedText("Слушаю \(hotkeyName)", "Listening for \(hotkeyName)",
                                  language: language)
            subtitle = localizedText("Всё распознаётся на этом Mac",
                                     "Everything is transcribed on this Mac",
                                     language: language)
        } else {
            title = startupStatusTitle
            subtitle = localizedText("Служба ещё запускается", "The service is still starting",
                                     language: language)
        }

        let rawPreference = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = availableAudioInputDevices()
        let microphoneName = audioInputDevice(matching: rawPreference, in: devices)?.name
            ?? localizedText("Системный по умолчанию", "System default", language: language)

        let calendar = Calendar.current
        let todayKey = dictationUsageDayKey(for: Date(), calendar: calendar)
        let today = settings.dailyDictationUsage.first(where: { $0.day == todayKey })
        let week = lastSevenCompletedDictationUsage(settings.dailyDictationUsage,
                                                    referenceDate: Date(),
                                                    calendar: calendar)
        let maxCharacters = max(1, week.days.map { $0.usage.characterCount }.max() ?? 1)
        var weekBars = week.days.map { CGFloat($0.usage.characterCount) / CGFloat(maxCharacters) }
        weekBars.append(CGFloat(today?.characterCount ?? 0) / CGFloat(maxCharacters))

        return QuickPanelState(
            statusTitle: title,
            statusSubtitle: subtitle,
            enabled: !isDictationPaused,
            isRecording: isRecording,
            language: settings.dictationLanguage,
            microphoneName: microphoneName,
            devices: devices,
            recent: Array(settings.recentTranscriptEntries.prefix(3)),
            todayCharacters: today?.characterCount ?? 0,
            todayAudioSeconds: today?.audioSeconds ?? 0,
            weekBars: weekBars,
            interfaceLanguage: language
        ,
                               availableUpdateVersion: pendingUpdate?.version,
                               installedVersion: currentBundleVersion(),
                               isCheckingForUpdates: isCheckingForUpdates,
                               serviceStatus: quickPanelServiceStatus())
    }

    func quickPanelDidToggleEnabled(_ enabled: Bool) {
        isDictationPaused = !enabled
        if isDictationPaused {
            setMenuBarState(.paused)
            log("dictation paused from quick panel")
        } else {
            setMenuBarState(isReady ? .idle : .loading)
            log("dictation resumed from quick panel")
        }
        rebuildMenu()
    }

    func quickPanelDidSelectLanguage(_ language: DictationLanguage) {
        settings.dictationLanguage = language
        log("dictation language selected from quick panel: \(language.rawValue)")
        rebuildMenu()
    }

    func quickPanelDidSelectInputDevice(uid: String) {
        guard !isRecording, !isBusy, !isTerminating else { return }
        settings.inputDevice = uid
        log("input device selected from quick panel: \(uid.isEmpty ? "system default" : uid)")
        restartAudioForInputDeviceChange()
        rebuildMenu()
    }

    func quickPanelDidCopyRecent(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func quickPanelDidPasteRecent(text: String) {
        _ = TextInserter.insert(pastedText(from: text, suffix: settings.pasteSuffix))
    }

    func quickPanelOpenSettings() {
        openControlPanelFromAgent(section: "settings")
    }

    func quickPanelOpenHistory() {
        openControlPanelFromAgent(section: "history")
    }

    // MARK: - Окно обновления

    func updateWindowDidChooseInstall(version: String) {
        guard let release = pendingUpdate, release.version == version else { return }
        startUpdate(for: release)
    }

    func updateWindowDidChooseLater(version: String) {
        guard let release = pendingUpdate, release.version == version else { return }
        closeUpdateWindow()
        pauseUpdateReminder(for: release)
    }

    func updateWindowDidChooseSkip(version: String) {
        closeUpdateWindow()
        var skipped = settings.skippedVersions
        if !skipped.contains(version) {
            skipped.append(version)
            settings.skippedVersions = skipped
            log("user skipped v\(version) from the update window")
        }
        pendingUpdate = nil
        rebuildMenu()
    }

    /// «Выйти» в поповере — та кнопка, которой люди действительно выходят:
    /// поповер открывается левым кликом, а меню с «Quit Dictor» — правым,
    /// куда мало кто заходит. Она же и не выходила толком: завершала процесс
    /// службы, оставляя открытое окно жить своей жизнью и не снимая launchd,
    /// так что «Выйти» выглядело как «пропала иконка».
    ///
    /// Теперь это тот же полный выход, что и в меню.
    func quickPanelQuit() {
        quitApplicationCompletely()
    }

    func quickPanelInstallUpdate() {
        guard let release = pendingUpdate else { return }
        presentUpdateWindow(for: release, currentVersion: currentBundleVersion())
    }

    /// Ручная проверка из панели. Обработчик для неё существовал с самого
    /// начала, но не был подключён ни к одному элементу интерфейса: узнать о
    /// новой версии можно было только дождавшись автоматической проверки.
    /// «Открыть Настройки» / «Запустить» / «Перезапустить службу» из шапки
    /// панели — те же действия, что и в подвале окна.
    func quickPanelStatusPrimaryAction() {
        switch quickPanelServiceStatus() {
        case .needsPermission:
            openControlPanelFromAgent(section: "settings")
        case .failed, .versionMismatch:
            // Перезапускать службу из неё самой нельзя: `bootout` ждал бы
            // смерти этого же процесса и повесил бы главный поток. Открываем
            // окно — там перезапуск делает отдельный процесс, и там же видно,
            // чем всё кончилось.
            openControlPanelFromAgent(section: "settings")
        default:
            break
        }
    }

    func quickPanelStatusSecondaryAction() {
        openControlPanelFromAgent(section: "settings")
    }

    func quickPanelCheckForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        refreshQuickPanel()
        manualUpdateCheckTask = Task { [weak self] in
            let outcome = await UpdateCheck.fetchLatest()
            guard !Task.isCancelled, let self, !self.isTerminating else { return }
            self.manualUpdateCheckTask = nil
            self.isCheckingForUpdates = false
            self.recordUpdateCheck(release: try? outcome.get(), source: .manual)
            switch outcome {
            case .success(let release):
                self.handleFetchedRelease(release, source: .manual)
                self.refreshQuickPanel()
                if self.pendingUpdate == nil {
                    self.quickPanel?.flashUpToDate()
                }
            case .failure(let error):
                // Проверка не удалась — и сказать об этом обязательно. Раньше
                // здесь просто не оказывалось обновления, и панель отвечала
                // «у вас последняя версия»: человек, у которого не было сети,
                // получал бодрое подтверждение вместо правды.
                log("manual update check failed: \(error)")
                self.refreshQuickPanel()
                self.showUpdateCheckFailedAlert(error)
            }
        }
    }

    private func refreshQuickPanel() {
        guard let panel = quickPanel, panel.isVisible else { return }
        panel.apply(state: quickPanelState())
    }
}

// MARK: - Плавающая капсула

extension DictorApp: FloatingCapsuleDelegate {
    /// Кнопка «Диктовать» — переключатель, независимо от того, как настроен
    /// хоткей: удерживать мышь на кнопке всю диктовку никто не станет.
    func floatingCapsuleDidRequestDictation() {
        if isRecording {
            handleRelease()
        } else {
            handlePress()
        }
    }

    func floatingCapsuleDidRequestHistory() {
        openControlPanelFromAgent(section: MainWindowSection.history.rawValue)
    }

    func floatingCapsuleDidRequestMenu(at point: NSPoint) {
        // То же меню, что по правому клику на иконке в строке меню: второго
        // набора команд у приложения быть не должно.
        buildMenu().popUp(positioning: nil, at: point, in: nil)
    }
}
