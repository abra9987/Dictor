// Кадры анимации капсулы в PNG (--export-hud-animation): движение капсулы
// проверяется по кадрам, а не на глаз.

import AppKit

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
    let transcribingDuration = 1.20
    // Диктовка кончается не распознаванием, а галочкой «Вставлено · N слов».
    // Раньше экспорт обрывался на «Распознаю…»: анимация на витрине показывала
    // капсулу, которая подумала и исчезла, — то есть программу, которая
    // ничего не вставила. Держим чуть дольше настоящего: здесь это читают, а
    // не замечают краем глаза.
    let insertedDuration = max(SD.Anim.insertedHoldSeconds, 1.20)
    let insertedWords = 12
    let emptyTail = 0.50
    let totalDuration = emptyLead
        + RECORDING_HUD_ANIMATE_IN_SECONDS
        + recordingDuration
        + transcribingDuration
        + insertedDuration
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
    view.insertedWordCount = insertedWords
    view.mode = .recording

    var phase: CGFloat = 0
    for frameIndex in 0..<frameCount {
        try autoreleasepool {
            let time = Double(frameIndex) / framesPerSecond
            let revealStart = emptyLead
            let recordingStart = revealStart + RECORDING_HUD_ANIMATE_IN_SECONDS
            let transcribingStart = recordingStart + recordingDuration
            let insertedStart = transcribingStart + transcribingDuration
            let hideStart = insertedStart + insertedDuration
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
            } else if time < insertedStart {
                reveal = 1
                level = 0
                mode = .transcribing
                transcribingElapsed = CGFloat(time - transcribingStart)
            } else if time < hideStart {
                reveal = 1
                level = 0
                mode = .inserted
                transcribingElapsed = nil
            } else if time < tailStart {
                reveal = 1 - CGFloat((time - hideStart) / RECORDING_HUD_ANIMATE_OUT_SECONDS)
                level = 0
                mode = .inserted
                transcribingElapsed = nil
            } else {
                reveal = 0
                level = 0
                mode = .inserted
                transcribingElapsed = nil
            }

            phase += recordingHUDPhaseSpeed(mode: mode, level: level)
                / CGFloat(framesPerSecond)
            view.revealProgress = max(0, min(1, reveal))
            view.mode = mode
            // Таймер записи идёт вместе с кадрами. Без этого он стоял на
            // 0:00 всю анимацию: капсула показывала, что она умеет считать
            // время, и тут же доказывала обратное.
            view.recordingElapsed = min(recordingDuration, max(0, time - recordingStart))
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
