import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testRecentTranscriptLimit() throws {
        let transcripts = ["newest", "second", "third", "fourth", "fifth", "sixth"]

        // Проверяется именно limitedRecentTranscriptEntries — то, чем живёт
        // меню (visibleHistory). Раньше тут стояла строковая
        // limitedRecentTranscripts, которую продакшн не вызывал вовсе: тест
        // утверждал поведение, которого в продукте нет.
        let plainEntries = transcripts.map { TranscriptHistoryEntry(text: $0) }
        try expect(
            limitedRecentTranscriptEntries(plainEntries, limit: .off).map(\.text),
            equals: [],
            "off should keep no recent transcripts"
        )
        try expect(
            limitedRecentTranscriptEntries(plainEntries, limit: .last1).map(\.text),
            equals: ["newest"],
            "last-one history should keep only the newest transcript"
        )
        try expect(
            limitedRecentTranscriptEntries(plainEntries, limit: .last5).map(\.text),
            equals: ["newest", "second", "third", "fourth", "fifth"],
            "last-five history should preserve the current default cap"
        )
        try expect(
            parseRecentTranscriptLimit(storedValue: NSNumber(value: 1)),
            equals: .last1,
            "numeric defaults writes should be accepted for last-one history"
        )

        let timedEntries = transcripts.enumerated().map { index, text in
            TranscriptHistoryEntry(
                text: text,
                transcriptionDurationSeconds: Double(index + 1) / 10
            )
        }
        try expect(
            limitedRecentTranscriptEntries(timedEntries, limit: .last1),
            equals: [TranscriptHistoryEntry(text: "newest", transcriptionDurationSeconds: 0.1)],
            "history trimming should preserve transcription timing metadata"
        )

        let archivedEntries = limitedTranscriptHistoryArchive(timedEntries, maximumCount: 6)
        try expect(
            archivedEntries.count,
            equals: 6,
            "the archive should retain entries beyond the visible history limit"
        )
        // Закреплённая запись переживает чистку по лимиту: пин существует
        // ради «не потерять», а вытеснение убивало запись из «Закреплённых».
        // Незакреплённый хвост при этом честно вытесняется.
        try expect(
            limitedTranscriptHistoryArchive(timedEntries,
                                            maximumCount: 4,
                                            pinned: ["sixth"]).map(\.text),
            equals: ["newest", "second", "third", "fourth", "sixth"],
            "a pinned entry must survive the archive limit while the unpinned tail is evicted"
        )
        let archiveAfterDeletion = transcriptHistoryArchive(archivedEntries, removing: 2)
        try expect(
            limitedRecentTranscriptEntries(archiveAfterDeletion, limit: .last5).map(\.text),
            equals: ["newest", "second", "fourth", "fifth", "sixth"],
            "deleting a visible history entry should backfill it from the archive"
        )
        try expect(
            transcriptHistoryArchive(archivedEntries, removing: 99),
            equals: archivedEntries,
            "an invalid history deletion index should leave the archive unchanged"
        )
        let timing = ASRTimingBreakdown(
            totalSeconds: 0.295,
            workerQueueSeconds: 0.001,
            decoderPreparationSeconds: 0.002,
            fluidCallSeconds: 0.290,
            fluidProcessingSeconds: 0.286
        )
        let entriesWithBreakdown = [
            TranscriptHistoryEntry(
                text: "timed",
                transcriptionDurationSeconds: timing.totalSeconds,
                asrTiming: timing
            )
        ]
        let encodedEntries = try JSONEncoder().encode(entriesWithBreakdown)
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: encodedEntries),
            equals: entriesWithBreakdown,
            "history timing metadata should survive persistence"
        )
        let legacyEntryData = Data(
            #"[{"text":"legacy","transcriptionDurationSeconds":0.25}]"#.utf8
        )
        try expect(
            try JSONDecoder().decode([TranscriptHistoryEntry].self, from: legacyEntryData),
            equals: [TranscriptHistoryEntry(text: "legacy", transcriptionDurationSeconds: 0.25)],
            "history entries saved before detailed metrics should remain decodable"
        )

        let metricLine = DictationLatencyMetrics(
            audioSeconds: 2,
            hotkeyDispatchSeconds: 0.0005,
            releasePreparationSeconds: 0.001,
            settingsRefreshSeconds: 0.0002,
            releasePermissionCheckSeconds: 0.0003,
            audioFinalizeSeconds: 0.002,
            audioDetachSeconds: 0.0001,
            journalFlushSeconds: 0.0015,
            audioFlattenSeconds: 0.0004,
            transcribingUISeconds: 0.003,
            taskQueueSeconds: 0.004,
            releaseToASRSeconds: 0.010,
            asrTiming: timing,
            postprocessingSeconds: 0.005,
            historyPersistenceSeconds: 0.006,
            journalCleanupSeconds: 0.007,
            permissionRecheckSeconds: 0.008,
            insertionDispatchSeconds: 0.009,
            releaseToPasteDispatchSeconds: 0.330,
            enterDelaySeconds: nil,
            pasteSucceeded: true
        ).logLine
        try expect(
            metricLine.contains("hotkey_dispatch=0.5 ms")
                && metricLine.contains("journal_flush=1.5 ms")
                && metricLine.contains("fluid_processing=286.0 ms")
                && metricLine.contains("release_to_paste=330.0 ms")
                && metricLine.contains("paste=ok"),
            equals: true,
            "latency log should expose model, end-to-end, and insertion outcomes"
        )
    }

    /// Плитки вкладки «Продвинутые» показывают замеры, а не украшения:
    /// пустая история должна давать «—», а не убедительный ноль.
    private static func testPerformanceMetrics() throws {
        func entry(_ seconds: Double?) -> TranscriptHistoryEntry {
            TranscriptHistoryEntry(text: "x", transcriptionDurationSeconds: seconds)
        }

        try expect(
            medianRecognitionSeconds(entries: []),
            equals: Optional<Double>.none,
            "no dictations means no median to show"
        )
        try expect(
            medianRecognitionSeconds(entries: [entry(0.1), entry(0.2), entry(0.9)]),
            equals: Optional(0.2),
            "an odd number of dictations should take the middle one"
        )
        try expect(
            medianRecognitionSeconds(entries: [entry(0.1), entry(0.3)]),
            equals: Optional(0.2),
            "an even number of dictations should average the middle pair"
        )
        try expect(
            medianRecognitionSeconds(entries: [entry(nil), entry(0), entry(0.4)]),
            equals: Optional(0.4),
            "entries without a usable timing should be skipped, not counted as zero"
        )
        // 40 быстрых диктовок после одной медленной: окно в 30 записей
        // отсекает старую, иначе плитка годами помнит первый запуск.
        let recent = Array(repeating: entry(0.2), count: 30) + [entry(9)]
        try expect(
            medianRecognitionSeconds(entries: recent),
            equals: Optional(0.2),
            "the median should only look at the recent window"
        )

        try expect(
            recognitionDurationLabel(0.18, language: .russian),
            equals: "180 мс",
            "sub-second timings should read in milliseconds"
        )
        try expect(
            recognitionDurationLabel(1.42, language: .russian),
            equals: "1,4 с",
            "timings over a second should read in seconds with a decimal comma"
        )
        try expect(
            memoryFootprintLabel(50_331_648, language: .russian),
            equals: "48 МБ",
            "memory should read in megabytes in the interface language"
        )

        try expect(
            groupedNumberLabel(10_000, language: .russian),
            equals: "10\u{202F}000",
            "Russian thousands are split by a narrow no-break space, not a comma"
        )
        try expect(
            groupedNumberLabel(10_000, language: .english),
            equals: "10,000",
            "English thousands keep the comma regardless of the system locale"
        )

        let base = ProcessResourceSample(physicalFootprintBytes: 0, cpuSeconds: 10)
        let later = ProcessResourceSample(physicalFootprintBytes: 0, cpuSeconds: 10.02)
        try expect(
            cpuLoadPercent(from: base, to: later, elapsedSeconds: 1).map { Int($0.rounded()) },
            equals: Optional(2),
            "cpu load should be the share of the interval actually spent running"
        )
        try expect(
            cpuLoadPercent(from: base, to: later, elapsedSeconds: 0),
            equals: Optional<Double>.none,
            "a degenerate interval should report nothing rather than divide by it"
        )
    }

    static func testDictationUsageStatistics() throws {
        try testPerformanceMetrics()

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reference = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))!
        let july10 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: 10))!
        let july11 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 10))!
        let july17 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 10))!
        let july18 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 10))!

        var stats: [DailyDictationUsage] = []
        stats = addingDictationUsageSample(to: stats,
                                           at: july10,
                                           characterCount: 40,
                                           audioSeconds: 4,
                                           asrSeconds: 0.4,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july11,
                                           characterCount: 100,
                                           audioSeconds: 10,
                                           asrSeconds: 0.5,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july17,
                                           characterCount: 300,
                                           audioSeconds: 30,
                                           asrSeconds: 0.75,
                                           calendar: calendar)
        stats = addingDictationUsageSample(to: stats,
                                           at: july18,
                                           characterCount: 900,
                                           audioSeconds: 90,
                                           asrSeconds: 1.2,
                                           calendar: calendar)

        let snapshot = lastSevenCompletedDictationUsage(stats,
                                                         referenceDate: reference,
                                                         calendar: calendar)
        try expect(snapshot.days.count, equals: 7,
                   "statistics should always contain seven completed calendar days")
        try expect(snapshot.days.first?.usage.day, equals: "2026-07-11",
                   "statistics should begin seven days before today")
        try expect(snapshot.days.last?.usage.day, equals: "2026-07-17",
                   "statistics should end yesterday")
        try expect(snapshot.totalCharacters, equals: 400,
                   "statistics should exclude both older data and today's dictations")
        try expect(snapshot.totalDictations, equals: 2,
                   "statistics should aggregate completed dictations")
        try expect(snapshot.totalAudioSeconds, equals: 40,
                   "statistics should aggregate recorded audio duration")
        try expect(snapshot.totalASRSeconds, equals: 1.25,
                   "statistics should aggregate ASR duration")

        let log = """
        [23:59:58] 2.00 s audio → 0.20 s → 20 chars
        [00:00:01] HotkeyListener: tap active
        [00:00:02] 3.00 s audio → 0.30 s → 30 chars
        [00:00:03] 1.00 s audio → 0.10 s → 0 chars
        """
        let imported = importedDailyDictationUsage(
            from: log,
            fileCreatedAt: calendar.date(from: DateComponents(year: 2026, month: 7, day: 3))!,
            calendar: calendar
        )
        try expect(imported.count, equals: 2,
                   "log import should infer a new day when timestamps cross midnight")
        try expect(imported.first?.characterCount, equals: 20,
                   "log import should preserve the first day's characters")
        try expect(imported.last?.characterCount, equals: 30,
                   "log import should ignore empty transcripts")

        // Панель рисует семь завершённых дней плюс сегодняшний. Пик считается
        // по всему набору: в рекордный день доля обязана остаться единицей,
        // иначе бар вырастает выше отведённых ему 22 pt и лезет на соседей.
        let recordToday = dictationUsageBarFractions([100, 200, 0, 400, 150, 300, 250, 4_000])
        try expect(recordToday.count, equals: 8,
                   "week bars should keep one column per drawn day")
        try expect(recordToday.max(), equals: Optional<CGFloat>(1),
                   "a record-breaking today should cap the bar at the block height")
        try expect(recordToday.last, equals: Optional<CGFloat>(1),
                   "the record day itself should be the tallest bar")
        try expect(recordToday.first, equals: Optional<CGFloat>(0.025),
                   "quieter days should scale against the same peak")
        try expect(dictationUsageBarFractions([0, 0, 0]),
                   equals: [CGFloat(0), 0, 0],
                   "a silent week should not divide by zero")
        try expect(dictationUsageBarFractions([-50, 100]),
                   equals: [CGFloat(0), 1],
                   "corrupted negative counts should clamp to an empty bar")
    }
}
#endif
