import AppKit

struct ASRTimingBreakdown: Codable, Equatable, Sendable {
    let totalSeconds: Double
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    init(totalSeconds: Double,
         workerQueueSeconds: Double,
         decoderPreparationSeconds: Double,
         fluidCallSeconds: Double,
         fluidProcessingSeconds: Double) {
        self.totalSeconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
        self.workerQueueSeconds = max(0, workerQueueSeconds.isFinite ? workerQueueSeconds : 0)
        self.decoderPreparationSeconds = max(0, decoderPreparationSeconds.isFinite ? decoderPreparationSeconds : 0)
        self.fluidCallSeconds = max(0, fluidCallSeconds.isFinite ? fluidCallSeconds : 0)
        self.fluidProcessingSeconds = max(0, fluidProcessingSeconds.isFinite ? fluidProcessingSeconds : 0)
    }

    var frameworkOverheadSeconds: Double {
        max(0, totalSeconds - workerQueueSeconds - decoderPreparationSeconds - fluidProcessingSeconds)
    }
}

struct TranscriptHistoryEntry: Codable, Equatable {
    let text: String
    let transcriptionDurationSeconds: Double?
    let asrTiming: ASRTimingBreakdown?
    /// Момент диктовки. Optional: записи до редизайна Dictor его не
    /// имеют и в истории группируются как «Ранее».
    let createdAt: Date?

    init(text: String,
         transcriptionDurationSeconds: Double? = nil,
         asrTiming: ASRTimingBreakdown? = nil,
         createdAt: Date? = nil) {
        self.text = text
        if let duration = transcriptionDurationSeconds,
           duration.isFinite,
           duration >= 0 {
            self.transcriptionDurationSeconds = duration
        } else {
            self.transcriptionDurationSeconds = nil
        }
        self.asrTiming = asrTiming
        self.createdAt = createdAt
    }
}

func limitedRecentTranscriptEntries(_ entries: [TranscriptHistoryEntry],
                                    limit: RecentTranscriptLimit) -> [TranscriptHistoryEntry] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard entries.count > count else { return entries }
    return Array(entries.prefix(count))
}

func limitedTranscriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                                     maximumCount: Int = TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES,
                                     pinned: Set<String> = []) -> [TranscriptHistoryEntry] {
    guard maximumCount > 0 else { return [] }
    guard entries.count > maximumCount else { return entries }
    var kept = Array(entries.prefix(maximumCount))
    // Закреплённые не вытесняются лимитом: пин существует ради «не потерять»,
    // а фильтр «Закреплённые» ищет пины в архиве — вытесненная запись
    // исчезала из него вместе со смыслом пина. Пинов не больше 200 (предел
    // pinnedTranscripts), так что архив ограниченным быть не перестаёт.
    guard !pinned.isEmpty else { return kept }
    var keptTexts = Set(kept.map(\.text))
    for entry in entries.dropFirst(maximumCount)
    where pinned.contains(entry.text) && !keptTexts.contains(entry.text) {
        kept.append(entry)
        keptTexts.insert(entry.text)
    }
    return kept
}

func transcriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                              removing index: Int) -> [TranscriptHistoryEntry] {
    guard entries.indices.contains(index) else { return entries }
    var next = entries
    next.remove(at: index)
    return next
}

// ~11 лет дневной статистики; записи крошечные, храним долго — для
// графиков по месяцам и годам.
let DICTATION_USAGE_MAX_DAYS = 4000

struct DailyDictationUsage: Codable, Equatable {
    let day: String
    var dictationCount: Int
    var characterCount: Int
    var audioSeconds: Double
    var asrSeconds: Double

    init(day: String,
         dictationCount: Int = 0,
         characterCount: Int = 0,
         audioSeconds: Double = 0,
         asrSeconds: Double = 0) {
        self.day = day
        self.dictationCount = max(0, dictationCount)
        self.characterCount = max(0, characterCount)
        self.audioSeconds = max(0, audioSeconds.isFinite ? audioSeconds : 0)
        self.asrSeconds = max(0, asrSeconds.isFinite ? asrSeconds : 0)
    }

    mutating func add(dictations: Int,
                      characters: Int,
                      audio: Double,
                      asr: Double) {
        dictationCount += max(0, dictations)
        characterCount += max(0, characters)
        audioSeconds += max(0, audio.isFinite ? audio : 0)
        asrSeconds += max(0, asr.isFinite ? asr : 0)
    }
}

struct DictationUsageDaySlot: Equatable {
    let date: Date
    let usage: DailyDictationUsage
}

struct DictationUsageWeekSnapshot: Equatable {
    let days: [DictationUsageDaySlot]

    var totalDictations: Int { days.reduce(0) { $0 + $1.usage.dictationCount } }
    var totalCharacters: Int { days.reduce(0) { $0 + $1.usage.characterCount } }
    var totalAudioSeconds: Double { days.reduce(0) { $0 + $1.usage.audioSeconds } }
    var totalASRSeconds: Double { days.reduce(0) { $0 + $1.usage.asrSeconds } }
}

func dictationUsageDayKey(for date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d",
                  components.year ?? 0,
                  components.month ?? 0,
                  components.day ?? 0)
}

func mergedDailyDictationUsage(_ stats: [DailyDictationUsage],
                               maximumDays: Int = DICTATION_USAGE_MAX_DAYS) -> [DailyDictationUsage] {
    guard maximumDays > 0 else { return [] }
    var byDay: [String: DailyDictationUsage] = [:]
    for stat in stats where !stat.day.isEmpty {
        var combined = byDay[stat.day] ?? DailyDictationUsage(day: stat.day)
        combined.add(dictations: stat.dictationCount,
                     characters: stat.characterCount,
                     audio: stat.audioSeconds,
                     asr: stat.asrSeconds)
        byDay[stat.day] = combined
    }
    return Array(byDay.values.sorted { $0.day < $1.day }.suffix(maximumDays))
}

func addingDictationUsageSample(to stats: [DailyDictationUsage],
                                at date: Date,
                                characterCount: Int,
                                audioSeconds: Double,
                                asrSeconds: Double,
                                calendar: Calendar) -> [DailyDictationUsage] {
    guard characterCount > 0 else { return stats }
    let day = dictationUsageDayKey(for: date, calendar: calendar)
    var next = stats
    if let index = next.firstIndex(where: { $0.day == day }) {
        next[index].add(dictations: 1,
                        characters: characterCount,
                        audio: audioSeconds,
                        asr: asrSeconds)
    } else {
        next.append(DailyDictationUsage(day: day,
                                        dictationCount: 1,
                                        characterCount: characterCount,
                                        audioSeconds: audioSeconds,
                                        asrSeconds: asrSeconds))
    }
    return mergedDailyDictationUsage(next)
}

func lastSevenCompletedDictationUsage(_ stats: [DailyDictationUsage],
                                      referenceDate: Date,
                                      calendar: Calendar) -> DictationUsageWeekSnapshot {
    let byDay = Dictionary(uniqueKeysWithValues: mergedDailyDictationUsage(stats).map { ($0.day, $0) })
    let today = calendar.startOfDay(for: referenceDate)
    let days = (1...7).reversed().compactMap { offset -> DictationUsageDaySlot? in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let key = dictationUsageDayKey(for: date, calendar: calendar)
        return DictationUsageDaySlot(date: date,
                                     usage: byDay[key] ?? DailyDictationUsage(day: key))
    }
    return DictationUsageWeekSnapshot(days: days)
}

/// Нормализует дневные объёмы в доли [0…1] для мини-баров панели.
/// Пик берётся по всему набору, который рисуется, — включая сегодняшний
/// день. Считать пик только по завершённым дням нельзя: в рекордный день
/// сегодняшняя доля вылезает за единицу, и бар вырастает выше своего блока.
func dictationUsageBarFractions(_ characters: [Int]) -> [CGFloat] {
    let peak = max(1, characters.map { max(0, $0) }.max() ?? 1)
    return characters.map { value in
        min(1, max(0, CGFloat(max(0, value)) / CGFloat(peak)))
    }
}

func importedDailyDictationUsage(from logText: String,
                                 fileCreatedAt: Date,
                                 calendar: Calendar) -> [DailyDictationUsage] {
    let pattern = #"^\[(\d{2}):(\d{2}):(\d{2})\]\s+([0-9]+(?:\.[0-9]+)?) s audio → ([0-9]+(?:\.[0-9]+)?) s → (\d+) chars"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

    var currentDay = calendar.startOfDay(for: fileCreatedAt)
    var previousSecondsOfDay: Int?
    var stats: [DailyDictationUsage] = []

    for lineSlice in logText.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(lineSlice)
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange) else {
            if line.count >= 10,
               line.first == "[",
               let hour = Int(line.dropFirst(1).prefix(2)),
               let minute = Int(line.dropFirst(4).prefix(2)),
               let second = Int(line.dropFirst(7).prefix(2)) {
                let secondsOfDay = (hour * 3_600) + (minute * 60) + second
                if let previousSecondsOfDay, secondsOfDay < previousSecondsOfDay,
                   let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) {
                    currentDay = nextDay
                }
                previousSecondsOfDay = secondsOfDay
            }
            continue
        }

        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let hour = capture(1).flatMap(Int.init),
              let minute = capture(2).flatMap(Int.init),
              let second = capture(3).flatMap(Int.init),
              let audio = capture(4).flatMap(Double.init),
              let asr = capture(5).flatMap(Double.init),
              let characters = capture(6).flatMap(Int.init) else {
            continue
        }

        let secondsOfDay = (hour * 3_600) + (minute * 60) + second
        if let previousSecondsOfDay, secondsOfDay < previousSecondsOfDay,
           let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) {
            currentDay = nextDay
        }
        previousSecondsOfDay = secondsOfDay
        stats = addingDictationUsageSample(to: stats,
                                           at: currentDay,
                                           characterCount: characters,
                                           audioSeconds: audio,
                                           asrSeconds: asr,
                                           calendar: calendar)
    }
    return stats
}

func millisecondsLabel(_ duration: Double) -> String {
    String(format: "%.1f ms", max(0, duration) * 1_000)
}

struct DictationLatencyMetrics: Equatable {
    let audioSeconds: Double
    let hotkeyDispatchSeconds: Double?
    let releasePreparationSeconds: Double
    let settingsRefreshSeconds: Double
    let releasePermissionCheckSeconds: Double
    let audioFinalizeSeconds: Double
    let audioDetachSeconds: Double
    let journalFlushSeconds: Double
    let audioFlattenSeconds: Double
    let transcribingUISeconds: Double
    let taskQueueSeconds: Double
    let releaseToASRSeconds: Double
    let asrTiming: ASRTimingBreakdown
    let postprocessingSeconds: Double
    let historyPersistenceSeconds: Double
    let journalCleanupSeconds: Double
    let permissionRecheckSeconds: Double
    let insertionDispatchSeconds: Double
    let releaseToPasteDispatchSeconds: Double
    let enterDelaySeconds: Double?
    let pasteSucceeded: Bool

    var logLine: String {
        let enter = enterDelaySeconds.map(millisecondsLabel) ?? "off"
        let hotkeyDispatch = hotkeyDispatchSeconds.map(millisecondsLabel) ?? "off"
        let releaseState = max(
            0,
            releasePreparationSeconds - settingsRefreshSeconds - releasePermissionCheckSeconds
        )
        return [
            "latency:",
            "audio=\(String(format: "%.3f", audioSeconds))s",
            "hotkey_dispatch=\(hotkeyDispatch)",
            "release_prep=\(millisecondsLabel(releasePreparationSeconds))",
            "settings_refresh=\(millisecondsLabel(settingsRefreshSeconds))",
            "release_permission=\(millisecondsLabel(releasePermissionCheckSeconds))",
            "release_state=\(millisecondsLabel(releaseState))",
            "audio_finalize=\(millisecondsLabel(audioFinalizeSeconds))",
            "audio_detach=\(millisecondsLabel(audioDetachSeconds))",
            "journal_flush=\(millisecondsLabel(journalFlushSeconds))",
            "audio_flatten=\(millisecondsLabel(audioFlattenSeconds))",
            "transcribing_ui_overlap=\(millisecondsLabel(transcribingUISeconds))",
            "task_queue=\(millisecondsLabel(taskQueueSeconds))",
            "release_to_asr=\(millisecondsLabel(releaseToASRSeconds))",
            "worker_queue=\(millisecondsLabel(asrTiming.workerQueueSeconds))",
            "decoder_setup=\(millisecondsLabel(asrTiming.decoderPreparationSeconds))",
            "fluid_call=\(millisecondsLabel(asrTiming.fluidCallSeconds))",
            "fluid_processing=\(millisecondsLabel(asrTiming.fluidProcessingSeconds))",
            "framework_overhead=\(millisecondsLabel(asrTiming.frameworkOverheadSeconds))",
            "asr_total=\(millisecondsLabel(asrTiming.totalSeconds))",
            "postprocess=\(millisecondsLabel(postprocessingSeconds))",
            "history=\(millisecondsLabel(historyPersistenceSeconds))",
            "journal_cleanup=\(millisecondsLabel(journalCleanupSeconds))",
            "permission_recheck=\(millisecondsLabel(permissionRecheckSeconds))",
            "insert_dispatch=\(millisecondsLabel(insertionDispatchSeconds))",
            "release_to_paste=\(millisecondsLabel(releaseToPasteDispatchSeconds))",
            "enter_wait=\(enter)",
            "paste=\(pasteSucceeded ? "ok" : "failed")",
        ].joined(separator: " ")
    }
}
