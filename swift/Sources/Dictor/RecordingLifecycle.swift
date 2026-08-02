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


/// Чем закончилось нестандартное завершение записи (автостоп по потолку,
/// потеря разрешения, сон): дошёл ли текст до «Истории». Вызывающий решает
/// по исходу, что сказать человеку, — молчать нельзя, вставки-то не было.
enum DictationRecoveryOutcome: Equatable {
    case noAudio
    case savedToHistory
    case emptyTranscription
    case failed
}

/// Текст капсулы после автостопа по потолку записи. Автостоп не вставляет
/// текст вовсе: забытая toggle-запись не должна выливать расшифровку комнаты
/// в поле с курсором. Значит, капсула обязана сказать, куда текст делся —
/// и не обещать «Историю», если туда ничего не легло.
func maxDurationStopMessage(outcome: DictationRecoveryOutcome,
                            limitMinutes: Int,
                            language: InterfaceLanguage) -> String {
    let stopped = localizedText("Запись остановлена: лимит \(limitMinutes) мин",
                                "Recording stopped at the \(limitMinutes)-minute limit",
                                language: language)
    switch outcome {
    case .savedToHistory:
        return stopped + localizedText(" — текст в «Истории»",
                                       " — the text is in History",
                                       language: language)
    case .failed:
        return stopped + localizedText(" — не получилось распознать",
                                       " — transcription failed",
                                       language: language)
    case .noAudio, .emptyTranscription:
        return stopped
    }
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
