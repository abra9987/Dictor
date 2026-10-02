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
                                           language: language,
                                           lexicon: settings.dictationTermLexicon)
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

#if DEBUG
import AppKit

// MARK: - Замер построения окна
//
// `Dictor --time-main-window` строит каждый раздел главного окна на настоящих
// данных человека и печатает, сколько это заняло. Окно пересобирается целиком
// при любом изменении, так что это время — задержка, которую человек видит,
// переключая разделы. Ничего не записывает.

@MainActor
func runMainWindowTimingTool() -> Int32 {
    let panel = DictorControlPanelApp()
    panel.previewStatusOverride = .ready(latencyMilliseconds: 180)
    let size = MAIN_WINDOW_SIZE
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
    print("history entries: \(Settings.shared.recentTranscriptEntries.count)")
    for section in MainWindowSection.allCases {
        panel.mainSection = section
        var best = Double.infinity
        for _ in 0..<3 {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let view = panel.makeMainWindowView()
            let builtAt = ProcessInfo.processInfo.systemUptime
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            let finishedAt = ProcessInfo.processInfo.systemUptime
            if finishedAt - startedAt < best {
                best = finishedAt - startedAt
                print(String(format: "  %@: build %.0f ms + layout %.0f ms",
                             section.rawValue,
                             (builtAt - startedAt) * 1000,
                             (finishedAt - builtAt) * 1000))
            }
        }
        print(String(format: "%@: %.0f ms", section.rawValue, best * 1000))
    }

    // Поиск: каждая набранная буква пересобирает окно, поэтому мерить надо
    // и запрос с тысячей совпадений, и запрос с одним.
    panel.mainSection = .history
    for query in ["а", "код", "Dictor", "нет такого слова"] {
        panel.mainHistorySearch = query
        var best = Double.infinity
        for _ in 0..<3 {
            let startedAt = ProcessInfo.processInfo.systemUptime
            let view = panel.makeMainWindowView()
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            best = min(best, ProcessInfo.processInfo.systemUptime - startedAt)
        }
        print(String(format: "history search «%@»: %.0f ms", query, best * 1000))
    }
    panel.mainHistorySearch = ""
    return EXIT_SUCCESS
}
#endif

#if DEBUG
// MARK: - Правка текста на корпусе
//
// `Dictor --correct-texts <json>` применяет словарь к готовым текстам и
// печатает только то, что изменилось. Нужен, чтобы видеть действие правила
// на тысяче настоящих диктовок разом: самотест проверяет заранее придуманные
// примеры, а ложные срабатывания живут там, где их никто не придумал.
//
// На входе — JSON-массив строк или объектов с полем `text` (так хранится
// история). Словарь берётся из настроек; третий аргумент — файл с
// дополнительными записями `[{"source":…, "replacement":…}]`.

@MainActor
func runCorrectTextsTool(arguments: [String]) -> Int32 {
    guard (1...2).contains(arguments.count),
          let data = FileManager.default.contents(atPath: arguments[0]),
          let json = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
        fputs("usage: Dictor --correct-texts <texts.json> [extra-corrections.json]\n", stderr)
        return EXIT_FAILURE
    }
    let texts: [String] = json.compactMap { item in
        (item as? String) ?? ((item as? [String: Any])?["text"] as? String)
    }

    var extra: [TranscriptCorrection] = []
    if arguments.count == 2 {
        guard let extraData = FileManager.default.contents(atPath: arguments[1]),
              let rows = try? JSONSerialization.jsonObject(with: extraData) as? [[String: String]] else {
            fputs("cannot read extra corrections from \(arguments[1])\n", stderr)
            return EXIT_FAILURE
        }
        extra = rows.compactMap { row in
            guard let source = row["source"], let replacement = row["replacement"] else { return nil }
            return TranscriptCorrection(source: source, replacement: replacement)
        }
    }

    let settings = Settings.shared
    let corrections = dictationCorrections(user: extra + settings.transcriptCorrections,
                                           includeBuiltInSpellings: settings.builtInSpellingsEnabled,
                                           includeLatinTermRestorations: settings.latinTermRestorationsEnabled)
    guard let lexicon = SystemLexicon.russian else {
        fputs("no Russian system dictionary\n", stderr)
        return EXIT_FAILURE
    }

    var changedTexts = 0
    var phoneticHits = 0
    let startedAt = ProcessInfo.processInfo.systemUptime
    for text in texts {
        let exact = TranscriptCorrector.apply(to: text, corrections: corrections)
        let full = TranscriptCorrector.apply(to: text, corrections: corrections, lexicon: lexicon)
        guard full.text != exact.text else { continue }
        changedTexts += 1
        phoneticHits += full.appliedCount - exact.appliedCount
        // Только отличие от точных совпадений: это и есть работа правила.
        for found in PhoneticTermMatcher.matches(in: text,
                                                 corrections: corrections,
                                                 occupied: [],
                                                 lexicon: lexicon) {
            let heard = (text as NSString).substring(with: found.range)
            print("\(heard.lowercased())\t\(found.replacement)")
        }
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
    fputs(String(format: "texts %d · changed by sound %d · sound-alike hits %d · %.1f ms per text\n",
                 texts.count, changedTexts, phoneticHits,
                 elapsed / Double(max(texts.count, 1)) * 1000), stderr)
    return EXIT_SUCCESS
}
#endif
