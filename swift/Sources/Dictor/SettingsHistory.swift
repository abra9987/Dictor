import Foundation

extension Settings {
    var recentTranscriptLimit: RecentTranscriptLimit {
        get {
            parseRecentTranscriptLimit(storedValue: defaults.object(forKey: Self.keyRecentTranscripts))
                ?? DEFAULT_RECENT_TRANSCRIPT_LIMIT
        }
        set {
            // Запоминаем последний ненулевой выбор, чтобы выключение и
            // повторное включение истории возвращали ту же длину списка
            // в меню-баре, а не молча подменяли её десяткой.
            if newValue != .off {
                defaults.set(newValue.rawValue, forKey: Self.keyPreferredRecentTranscripts)
            }
            defaults.set(newValue.rawValue, forKey: Self.keyRecentTranscripts)
        }
    }

    /// Длина списка в меню-баре, к которой возвращаемся при включении
    /// истории обратно.
    var preferredRecentTranscriptLimit: RecentTranscriptLimit {
        let stored = parseRecentTranscriptLimit(
            storedValue: defaults.object(forKey: Self.keyPreferredRecentTranscripts))
        guard let stored, stored != .off else { return DEFAULT_RECENT_TRANSCRIPT_LIMIT }
        return stored
    }

    var recentTranscriptHistory: [String] {
        get {
            let stored = defaults.stringArray(forKey: Self.keyRecentTranscriptHistory) ?? []
            return Array(
                stored.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
        }
        set {
            let cleaned = Array(
                newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
            if cleaned.isEmpty {
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
            } else {
                defaults.set(cleaned, forKey: Self.keyRecentTranscriptHistory)
            }
            defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
        }
    }

    /// Сырые байты архива истории — как лежат в defaults. Для дешёвого ответа
    /// на «изменилось ли снаружи»: сравнить Data — это memcmp, а декодировать
    /// до 10 000 записей каждую секунду наблюдателя настроек — нет.
    var recentTranscriptEntriesStoredData: Data? {
        defaults.data(forKey: Self.keyRecentTranscriptEntries)
    }

    var recentTranscriptEntries: [TranscriptHistoryEntry] {
        get {
            if let data = defaults.data(forKey: Self.keyRecentTranscriptEntries) {
                // Закреплённые участвуют в ограничении архива, поэтому они —
                // такая же часть ключа, как сами байты.
                let pinned = pinnedTranscripts
                historyCacheLock.lock()
                let cached = historyCache
                historyCacheLock.unlock()
                if let cached, cached.data == data, cached.pinned == pinned {
                    return cached.entries
                }
                if let decoded = try? JSONDecoder().decode([TranscriptHistoryEntry].self, from: data) {
                    let cleaned = decoded.compactMap { entry -> TranscriptHistoryEntry? in
                        let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return nil }
                        return TranscriptHistoryEntry(
                            text: text,
                            transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                            asrTiming: entry.asrTiming,
                            createdAt: entry.createdAt
                        )
                    }
                    let entries = limitedTranscriptHistoryArchive(cleaned, pinned: Set(pinned))
                    historyCacheLock.lock()
                    historyCache = (data, pinned, entries)
                    historyCacheLock.unlock()
                    return entries
                }
            }

            return recentTranscriptHistory.map { TranscriptHistoryEntry(text: $0) }
        }
        set {
            let cleaned = limitedTranscriptHistoryArchive(
                newValue.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming,
                        createdAt: entry.createdAt
                    )
                },
                pinned: Set(pinnedTranscripts)
            )

            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
                return
            }

            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyRecentTranscriptEntries)
            }
            defaults.set(cleaned.map(\.text), forKey: Self.keyRecentTranscriptHistory)
        }
    }

    var dailyDictationUsage: [DailyDictationUsage] {
        get {
            guard let data = defaults.data(forKey: Self.keyDailyDictationUsage),
                  let decoded = try? JSONDecoder().decode([DailyDictationUsage].self, from: data) else {
                return []
            }
            return mergedDailyDictationUsage(decoded)
        }
        set {
            let cleaned = mergedDailyDictationUsage(newValue)
            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyDailyDictationUsage)
                return
            }
            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyDailyDictationUsage)
            }
        }
    }

    var didImportDictationUsageLog: Bool {
        get { defaults.bool(forKey: Self.keyDidImportDictationUsageLog) }
        set { defaults.set(newValue, forKey: Self.keyDidImportDictationUsageLog) }
    }
}
