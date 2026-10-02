#if DEBUG
import Foundation
import FluidAudio

// MARK: - Распознавание файла
//
// `Dictor --transcribe-file <язык|auto> <аудио> [аудио…]` прогоняет файлы тем
// же путём, что и диктовку: тот же `TranscriptionWorker` с проверкой
// целостности модели, та же правка текста с теми же настройками. Нужен, чтобы
// сравнивать модели и правила на одной и той же записи: «стало лучше» без
// повторяемого входа — впечатление, а не измерение.
//
// Печатает и сырой текст модели, и текст после правки: что из двух подвело,
// по одному результату не понять.
//
// Только в отладочной сборке: выпускаемому приложению читать произвольные
// файлы незачем.

struct FileTranscription {
    let raw: String
    let processed: String
    let appliedCorrectionCount: Int
    let audioSeconds: Double
    let transcriptionSeconds: Double
}

func transcribeFileLikeDictation(at url: URL,
                                 language: DictationLanguage,
                                 worker: TranscriptionWorker,
                                 settings: Settings = .shared) async throws -> FileTranscription {
    let samples = try AudioConverter().resampleAudioFile(url)
    let requestedAt = ProcessInfo.processInfo.systemUptime
    let result = try await worker.transcribe(samples: samples,
                                             language: language.fluidLanguage,
                                             requestedAt: requestedAt)
    let transcriptionSeconds = ProcessInfo.processInfo.systemUptime - requestedAt
    let processed = processedDictationText(rawTranscript: result.text,
                                           corrections: settings.dictationTranscriptCorrections,
                                           removeFillerWords: settings.removeFillerWords,
                                           language: language)
    return FileTranscription(raw: result.text,
                             processed: processed.text,
                             appliedCorrectionCount: processed.appliedCorrectionCount,
                             audioSeconds: Double(samples.count) / SAMPLE_RATE,
                             transcriptionSeconds: transcriptionSeconds)
}

/// Возвращает код завершения процесса. Модель загружается один раз на все
/// файлы: её загрузка на порядок дольше самого распознавания, и замер времени
/// по файлам иначе мерил бы её.
func runTranscribeFileTool(arguments: [String]) async -> Int32 {
    guard arguments.count >= 2 else {
        fputs("usage: Dictor --transcribe-file <language|auto> <audio> [audio…]\n", stderr)
        return EXIT_FAILURE
    }
    guard let language = DictationLanguage(rawValue: arguments[0].lowercased()) else {
        let known = DictationLanguage.allCases.map(\.rawValue).joined(separator: ", ")
        fputs("unknown language «\(arguments[0])»; known: \(known)\n", stderr)
        return EXIT_FAILURE
    }

    let worker = TranscriptionWorker()
    do {
        try await worker.load(profile: .productionDefault)
        _ = try await worker.warmUp()
    } catch {
        fputs("speech model failed to load: \(error.localizedDescription)\n", stderr)
        return EXIT_FAILURE
    }

    var failed = false
    for path in arguments.dropFirst() {
        let url = URL(fileURLWithPath: path)
        do {
            let result = try await transcribeFileLikeDictation(at: url,
                                                               language: language,
                                                               worker: worker)
            print("== \(url.lastPathComponent)")
            print(String(format: "   audio %.1f s · transcribed in %.2f s · corrections %d",
                         result.audioSeconds, result.transcriptionSeconds,
                         result.appliedCorrectionCount))
            print("   raw:       \(result.raw)")
            print("   processed: \(result.processed)")
        } catch {
            failed = true
            fputs("== \(url.lastPathComponent): \(error.localizedDescription)\n", stderr)
        }
    }
    return failed ? EXIT_FAILURE : EXIT_SUCCESS
}
#endif
