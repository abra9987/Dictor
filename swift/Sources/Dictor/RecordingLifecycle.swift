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

// MARK: - Recording lifecycle decisions

enum RecordingReleaseAction: Equatable {
    case discardTooShort(duration: Double)
    case transcribe(duration: Double)
}

func recordingReleaseAction(capturedSampleCount: Int,
                                    sampleRate: Double = SAMPLE_RATE,
                                    minimumClipSeconds: Double = MIN_CLIP_SECONDS) -> RecordingReleaseAction {
    let duration = sampleRate > 0 ? Double(max(0, capturedSampleCount)) / sampleRate : 0
    return duration < minimumClipSeconds
        ? .discardTooShort(duration: duration)
        : .transcribe(duration: duration)
}

struct DictationTextProcessingResult: Equatable {
    let text: String
    let appliedCorrectionCount: Int
    let removedFillerWordCount: Int
}

func processedDictationText(rawTranscript: String,
                                    corrections: [TranscriptCorrection],
                                    removeFillerWords: Bool,
                                    language: DictationLanguage = .auto) -> DictationTextProcessingResult {
    let trimmed = rawTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let repaired = SpeechModelTextRepair.apply(to: trimmed, language: language)
    let corrected = TranscriptCorrector.apply(to: repaired, corrections: corrections)

    guard removeFillerWords else {
        return DictationTextProcessingResult(text: corrected.text,
                                             appliedCorrectionCount: corrected.appliedCount,
                                             removedFillerWordCount: 0)
    }

    let stripped = FillerWordRemover.apply(to: corrected.text)
    return DictationTextProcessingResult(text: stripped.text,
                                         appliedCorrectionCount: corrected.appliedCount,
                                         removedFillerWordCount: stripped.removedCount)
}


/// Пора ли перезапускать аудиовход из-за того, что в настройках выбрали другой
/// микрофон.
///
/// Отдельной функцией — потому что цена ошибки высокая и незаметная: таймер
/// службы тикает раз в секунду, и «перезапускать всегда» выглядело бы как
/// работающая настройка ровно до первой диктовки. Первый тик после запуска
/// тоже ничего не перезапускает: сравнивать не с чем, а вход уже открыт с той
/// самой настройкой.
func shouldRestartAudioInput(previous: String?, current: String) -> Bool {
    guard let previous else { return false }
    return previous != current
}
