import AppKit

// Раздел «Статистика» (макеты 7a/7b/7c). Всё считается на этом Mac из
// того, что уже копится: посуточная статистика диктовок и таймстемпы
// записей истории. Ничего не отправляется наружу.
//
// Чего в реализации нет и почему: «Где диктуете» (разбивка по
// приложениям) и «Режимы» требуют источника диктовки и режимов, которых
// движок не записывает; «Правок %» — учёта правок после вставки;
// «Языки» — языка каждой диктовки. Выдумывать эти числа нельзя.

enum StatsPeriod: String, CaseIterable {
    case week
    case month
    case quarter
    case year
    case all

    func title(_ language: InterfaceLanguage) -> String {
        switch self {
        case .week: return localizedText("Неделя", "Week", language: language)
        case .month: return localizedText("Месяц", "Month", language: language)
        case .quarter: return localizedText("Квартал", "Quarter", language: language)
        case .year: return localizedText("Год", "Year", language: language)
        case .all: return localizedText("Всё время", "All time", language: language)
        }
    }
}

/// Столбик графика: значение текущего периода и того же места в прошлом.
struct StatsBucket {
    let label: String
    let words: Int
    let previousWords: Int
    /// Подпись оси рисуется не у каждого столбика (макет: только месяцы).
    let axisLabel: String?
    /// Что сказать про столбик под курсором. Отдельно от `label`: там у
    /// недель и месяцев пустая строка, потому что на оси они не подписаны, —
    /// а называть период, глядя на который человек спрашивает «сколько?»,
    /// нужно всегда. Заполняется там же, где известны даты.
    let calloutLabel: String

    init(label: String,
         words: Int,
         previousWords: Int,
         axisLabel: String?,
         calloutLabel: String? = nil) {
        self.label = label
        self.words = words
        self.previousWords = previousWords
        self.axisLabel = axisLabel
        self.calloutLabel = calloutLabel ?? label
    }
}

struct StatsSummary {
    let periodTitle: String
    let words: Int
    let previousWords: Int
    let savedHours: Double
    let workingDays: Double
    let speechWordsPerMinute: Int
    let dictationCount: Int
    let averageDictationSeconds: Double
    let buckets: [StatsBucket]
    let peakBucketIndex: Int?
    /// Диктовки по часам суток — из таймстемпов истории.
    let hourly: [Int]
    let hourlySampleCount: Int
    /// Дни для тепловой карты привычки, от старого к новому.
    let habit: [StatsDay]
    let currentStreak: Int
    let bestStreak: Int
    let firstDay: Date?
    /// Кварталы года для 7c.
    let quarters: [StatsQuarter]

    var deltaPercent: Int? {
        guard previousWords > 0 else { return nil }
        return Int((Double(words - previousWords) / Double(previousWords) * 100).rounded())
    }
}

struct StatsDay {
    let date: Date
    let words: Int
    let intensity: CGFloat
}

struct StatsQuarter {
    let label: String
    let words: Int
    let savedHours: Double
    let isCurrent: Bool
    let hasData: Bool
}

enum StatsCalculator {
    /// Средняя скорость набора на клавиатуре, от которой считается
    /// «сэкономлено». Это допущение, а не измерение, — так и подписано в UI.
    static let typingWordsPerMinute = 40.0
    static let workingDayHours = 8.0

    static func summary(period: StatsPeriod,
                        usage: [DailyDictationUsage],
                        entries: [TranscriptHistoryEntry],
                        language: InterfaceLanguage,
                        calendar: Calendar = .current,
                        now: Date = Date()) -> StatsSummary {
        var byDay: [String: DailyDictationUsage] = [:]
        for day in usage {
            byDay[day.day] = day
        }
        func usageFor(_ date: Date) -> DailyDictationUsage? {
            byDay[dictationUsageDayKey(for: date, calendar: calendar)]
        }

        let (start, end) = range(for: period, calendar: calendar, now: now, usage: usage)
        let previous = previousRange(for: period, current: (start, end),
                                     calendar: calendar, usage: usage)

        func totals(from: Date, to: Date) -> (words: Int, audio: Double, count: Int) {
            var words = 0
            var audio = 0.0
            var count = 0
            var cursor = calendar.startOfDay(for: from)
            let last = calendar.startOfDay(for: to)
            while cursor <= last {
                if let day = usageFor(cursor) {
                    words += approximateWordCount(characters: day.characterCount)
                    audio += day.audioSeconds
                    count += day.dictationCount
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return (words, audio, count)
        }

        let current = totals(from: start, to: end)
        let past = previous.map { totals(from: $0.0, to: $0.1) }

        let savedMinutes = max(0, Double(current.words) / typingWordsPerMinute - current.audio / 60)
        let speechWPM = current.audio > 30
            ? Int((Double(current.words) / (current.audio / 60)).rounded())
            : 0

        let buckets = makeBuckets(period: period, start: start, end: end,
                                  previousStart: previous?.0,
                                  usageFor: usageFor, calendar: calendar,
                                  language: language)
        var peakIndex: Int?
        if let maxValue = buckets.map(\.words).max(), maxValue > 0 {
            peakIndex = buckets.firstIndex(where: { $0.words == maxValue })
        }

        return StatsSummary(
            periodTitle: periodTitle(period: period, start: start, end: end,
                                     language: language, calendar: calendar),
            words: current.words,
            previousWords: past?.words ?? 0,
            savedHours: savedMinutes / 60,
            workingDays: savedMinutes / 60 / workingDayHours,
            speechWordsPerMinute: speechWPM,
            dictationCount: current.count,
            averageDictationSeconds: current.count > 0 ? current.audio / Double(current.count) : 0,
            buckets: buckets,
            peakBucketIndex: peakIndex,
            hourly: hourlyHistogram(entries: entries, from: start, to: end, calendar: calendar),
            hourlySampleCount: entries.filter {
                guard let created = $0.createdAt else { return false }
                return created >= calendar.startOfDay(for: start)
                    && created <= endOfDay(end, calendar: calendar)
            }.count,
            habit: habitDays(usageFor: usageFor, calendar: calendar, now: now, weeks: 12),
            currentStreak: streak(usageFor: usageFor, calendar: calendar, now: now).current,
            bestStreak: bestStreak(usage: usage, calendar: calendar),
            firstDay: firstDay(usage: usage, calendar: calendar),
            quarters: quarters(usageFor: usageFor, calendar: calendar, now: now)
        )
    }

    // MARK: - Диапазоны

    private static func endOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: DateComponents(day: 1, second: -1),
                      to: calendar.startOfDay(for: date)) ?? date
    }

    static func range(for period: StatsPeriod,
                      calendar: Calendar,
                      now: Date,
                      usage: [DailyDictationUsage]) -> (Date, Date) {
        switch period {
        case .week:
            let interval = calendar.dateInterval(of: .weekOfYear, for: now)
            return (interval?.start ?? now, now)
        case .month:
            let interval = calendar.dateInterval(of: .month, for: now)
            return (interval?.start ?? now, now)
        case .quarter:
            return (startOfQuarter(now, calendar: calendar), now)
        case .year:
            let interval = calendar.dateInterval(of: .year, for: now)
            return (interval?.start ?? now, now)
        case .all:
            return (firstDay(usage: usage, calendar: calendar) ?? now, now)
        }
    }

    private static func previousRange(for period: StatsPeriod,
                                      current: (Date, Date),
                                      calendar: Calendar,
                                      usage: [DailyDictationUsage]) -> (Date, Date)? {
        let component: Calendar.Component
        switch period {
        case .week: component = .weekOfYear
        case .month: component = .month
        case .quarter: component = .quarter
        case .year: component = .year
        case .all: return nil
        }
        guard let start = calendar.date(byAdding: component, value: -1, to: current.0),
              let end = calendar.date(byAdding: component, value: -1, to: current.1) else {
            return nil
        }
        return (start, end)
    }

    static func startOfQuarter(_ date: Date, calendar: Calendar) -> Date {
        let month = calendar.component(.month, from: date)
        let firstMonth = ((month - 1) / 3) * 3 + 1
        var components = calendar.dateComponents([.year], from: date)
        components.month = firstMonth
        components.day = 1
        return calendar.date(from: components) ?? date
    }

    static func quarterNumber(_ date: Date, calendar: Calendar) -> Int {
        (calendar.component(.month, from: date) - 1) / 3 + 1
    }

    private static func periodTitle(period: StatsPeriod,
                                    start: Date,
                                    end: Date,
                                    language: InterfaceLanguage,
                                    calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        switch period {
        case .week:
            formatter.dateFormat = "d MMM"
            return "\(formatter.string(from: start)) — \(formatter.string(from: end))"
        case .month:
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: start).capitalizedFirst
        case .quarter:
            let year = calendar.component(.year, from: start)
            return "Q\(quarterNumber(start, calendar: calendar)) \(year)"
        case .year:
            return "\(calendar.component(.year, from: start))"
        case .all:
            formatter.dateFormat = "d MMMM yyyy"
            return localizedText("с \(formatter.string(from: start))",
                                 "since \(formatter.string(from: start))",
                                 language: language)
        }
    }

    // MARK: - Столбики графика

    private static func makeBuckets(period: StatsPeriod,
                                    start: Date,
                                    end: Date,
                                    previousStart: Date?,
                                    usageFor: (Date) -> DailyDictationUsage?,
                                    calendar: Calendar,
                                    language: InterfaceLanguage) -> [StatsBucket] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")

        func words(dayRange: (Date, Date)) -> Int {
            var total = 0
            var cursor = calendar.startOfDay(for: dayRange.0)
            let last = calendar.startOfDay(for: dayRange.1)
            while cursor <= last {
                if let day = usageFor(cursor) {
                    total += approximateWordCount(characters: day.characterCount)
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
            return total
        }

        // Подпись под курсором называет период словами: у столбика недели и
        // месяца на оси метки нет вовсе, а спрашивают о нём именно наведением.
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = calendar
        dayFormatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        dayFormatter.dateFormat = "d MMMM"

        switch period {
        case .week, .month:
            // По дням.
            formatter.dateFormat = period == .week ? "EEEEE" : "d"
            var buckets: [StatsBucket] = []
            var cursor = calendar.startOfDay(for: start)
            let last = calendar.startOfDay(for: end)
            var index = 0
            while cursor <= last {
                let dayWords = usageFor(cursor).map {
                    approximateWordCount(characters: $0.characterCount)
                } ?? 0
                let previousDay = previousStart.flatMap {
                    calendar.date(byAdding: .day, value: index, to: $0)
                }
                let previousWords = previousDay.flatMap(usageFor).map {
                    approximateWordCount(characters: $0.characterCount)
                } ?? 0
                let label = formatter.string(from: cursor)
                dayFormatter.locale = formatter.locale
                buckets.append(StatsBucket(label: label,
                                           words: dayWords,
                                           previousWords: previousWords,
                                           axisLabel: period == .week
                                               ? label
                                               : (calendar.component(.day, from: cursor) % 7 == 1
                                                   ? label : nil),
                                           calloutLabel: dayFormatter.string(from: cursor)))
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
                index += 1
            }
            return buckets

        case .quarter:
            // По неделям, подпись оси — в начале каждого месяца (макет 7a).
            formatter.dateFormat = "LLL"
            var buckets: [StatsBucket] = []
            var cursor = calendar.dateInterval(of: .weekOfYear, for: start)?.start
                ?? calendar.startOfDay(for: start)
            var index = 0
            var lastMonth = -1
            while cursor <= end {
                let weekEnd = calendar.date(byAdding: .day, value: 6, to: cursor) ?? cursor
                let current = words(dayRange: (cursor, min(weekEnd, end)))
                var previousWords = 0
                if let previousStart,
                   let previousWeek = calendar.date(byAdding: .weekOfYear, value: index,
                                                    to: previousStart) {
                    let previousEnd = calendar.date(byAdding: .day, value: 6, to: previousWeek)
                        ?? previousWeek
                    previousWords = words(dayRange: (previousWeek, previousEnd))
                }
                let month = calendar.component(.month, from: cursor)
                let axis = month != lastMonth ? formatter.string(from: cursor) : nil
                lastMonth = month
                buckets.append(StatsBucket(label: "", words: current,
                                           previousWords: previousWords, axisLabel: axis))
                guard let next = calendar.date(byAdding: .weekOfYear, value: 1, to: cursor) else { break }
                cursor = next
                index += 1
            }
            return buckets

        case .year, .all:
            // По месяцам.
            formatter.dateFormat = "LLL"
            var buckets: [StatsBucket] = []
            var cursor = calendar.dateInterval(of: .month, for: start)?.start
                ?? calendar.startOfDay(for: start)
            var index = 0
            while cursor <= end {
                let monthEnd = calendar.dateInterval(of: .month, for: cursor)?.end
                    .addingTimeInterval(-1) ?? cursor
                let current = words(dayRange: (cursor, min(monthEnd, end)))
                var previousWords = 0
                if let previousStart,
                   let previousMonth = calendar.date(byAdding: .month, value: index,
                                                     to: previousStart) {
                    let previousEnd = calendar.dateInterval(of: .month, for: previousMonth)?.end
                        .addingTimeInterval(-1) ?? previousMonth
                    previousWords = words(dayRange: (previousMonth, previousEnd))
                }
                dayFormatter.dateFormat = "LLLL"
                buckets.append(StatsBucket(label: "", words: current,
                                           previousWords: previousWords,
                                           axisLabel: formatter.string(from: cursor),
                                           calloutLabel: dayFormatter.string(from: cursor)))
                guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
                cursor = next
                index += 1
            }
            return buckets
        }
    }

    // MARK: - Часы, привычка, кварталы

    private static func hourlyHistogram(entries: [TranscriptHistoryEntry],
                                        from: Date,
                                        to: Date,
                                        calendar: Calendar) -> [Int] {
        var hours = Array(repeating: 0, count: 24)
        let start = calendar.startOfDay(for: from)
        let end = endOfDay(to, calendar: calendar)
        for entry in entries {
            guard let created = entry.createdAt, created >= start, created <= end else { continue }
            let hour = calendar.component(.hour, from: created)
            if hours.indices.contains(hour) {
                hours[hour] += 1
            }
        }
        return hours
    }

    private static func habitDays(usageFor: (Date) -> DailyDictationUsage?,
                                  calendar: Calendar,
                                  now: Date,
                                  weeks: Int) -> [StatsDay] {
        // Сетка начинается с понедельника, чтобы столбцы были неделями.
        let todayStart = calendar.startOfDay(for: now)
        let weekday = calendar.component(.weekday, from: todayStart)
        let firstWeekday = calendar.firstWeekday
        let offsetInWeek = (weekday - firstWeekday + 7) % 7
        guard let weekStart = calendar.date(byAdding: .day, value: -offsetInWeek, to: todayStart),
              let start = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: weekStart)
        else { return [] }

        var days: [StatsDay] = []
        var cursor = start
        var peak = 1
        while cursor <= todayStart {
            let words = usageFor(cursor).map {
                approximateWordCount(characters: $0.characterCount)
            } ?? 0
            peak = max(peak, words)
            days.append(StatsDay(date: cursor, words: words, intensity: 0))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days.map {
            StatsDay(date: $0.date,
                     words: $0.words,
                     intensity: $0.words > 0
                         ? 0.25 + 0.75 * CGFloat($0.words) / CGFloat(peak)
                         : 0)
        }
    }

    static func streak(usageFor: (Date) -> DailyDictationUsage?,
                       calendar: Calendar,
                       now: Date) -> (current: Int, todayActive: Bool) {
        let today = calendar.startOfDay(for: now)
        let todayActive = (usageFor(today)?.characterCount ?? 0) > 0
        var count = 0
        var cursor = todayActive
            ? today
            : (calendar.date(byAdding: .day, value: -1, to: today) ?? today)
        while (usageFor(cursor)?.characterCount ?? 0) > 0, count < 4000 {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return (count, todayActive)
    }

    private static func bestStreak(usage: [DailyDictationUsage], calendar: Calendar) -> Int {
        let active = usage.filter { $0.characterCount > 0 }
            .compactMap { dictationUsageDay(from: $0.day, calendar: calendar) }
            .sorted()
        guard !active.isEmpty else { return 0 }
        var best = 1
        var run = 1
        for index in 1..<active.count {
            let previous = active[index - 1]
            let current = active[index]
            let gap = calendar.dateComponents([.day], from: previous, to: current).day ?? 0
            if gap == 1 {
                run += 1
                best = max(best, run)
            } else if gap > 1 {
                run = 1
            }
        }
        return best
    }

    static func firstDay(usage: [DailyDictationUsage], calendar: Calendar) -> Date? {
        usage.filter { $0.characterCount > 0 }
            .compactMap { dictationUsageDay(from: $0.day, calendar: calendar) }
            .min()
    }

    private static func quarters(usageFor: (Date) -> DailyDictationUsage?,
                                 calendar: Calendar,
                                 now: Date) -> [StatsQuarter] {
        let year = calendar.component(.year, from: now)
        let currentQuarter = quarterNumber(now, calendar: calendar)
        var result: [StatsQuarter] = []
        for quarter in 1...4 {
            var components = DateComponents()
            components.year = year
            components.month = (quarter - 1) * 3 + 1
            components.day = 1
            guard let start = calendar.date(from: components),
                  let next = calendar.date(byAdding: .month, value: 3, to: start) else { continue }
            let end = min(calendar.date(byAdding: .day, value: -1, to: next) ?? next, now)
            var words = 0
            var audio = 0.0
            if start <= now {
                var cursor = start
                while cursor <= end {
                    if let day = usageFor(cursor) {
                        words += approximateWordCount(characters: day.characterCount)
                        audio += day.audioSeconds
                    }
                    guard let step = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = step
                }
            }
            let savedMinutes = max(0, Double(words) / typingWordsPerMinute - audio / 60)
            result.append(StatsQuarter(label: "Q\(quarter)",
                                       words: words,
                                       savedHours: savedMinutes / 60,
                                       isCurrent: quarter == currentQuarter,
                                       hasData: start <= now))
        }
        return result
    }
}

/// Разбор ключа посуточной статистики («2026-07-27») обратно в дату.
func dictationUsageDay(from key: String, calendar: Calendar) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    var components = DateComponents()
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
    return calendar.date(from: components)
}

extension String {
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}

// MARK: - Плитки производительности (макет 6d)

/// Медиана времени распознавания последних диктовок — от отпускания
/// клавиши до готового текста, как его измеряет сам конвейер.
/// Медиана, а не среднее: одна диктовка на сорок слов иначе перекашивает
/// цифру, которую пользователь сверяет с ощущением «моментально».
/// nil, когда мерить ещё нечего — плитка тогда честно говорит об этом,
/// а не показывает ноль.
func medianRecognitionSeconds(entries: [TranscriptHistoryEntry],
                              limit: Int = 30) -> Double? {
    let values = entries.prefix(limit).compactMap { entry -> Double? in
        if let total = entry.asrTiming?.totalSeconds, total > 0 { return total }
        guard let duration = entry.transcriptionDurationSeconds, duration > 0 else {
            return nil
        }
        return duration
    }.sorted()
    guard !values.isEmpty else { return nil }
    let middle = values.count / 2
    return values.count.isMultiple(of: 2)
        ? (values[middle - 1] + values[middle]) / 2
        : values[middle]
}

/// «48 МБ». Не ByteCountFormatter: он берёт единицы из системной локали,
/// и при русском интерфейсе на англоязычной macOS плитка писала «42,3 MB»
/// рядом с русскими подписями.
func memoryFootprintLabel(_ bytes: UInt64, language: InterfaceLanguage) -> String {
    let megabytes = Double(bytes) / 1_048_576
    return "\(Int(megabytes.rounded())) \(localizedText("МБ", "MB", language: language))"
}

/// «180 мс» / «1,4 с» — секунды становятся нечитаемыми в миллисекундах,
/// а миллисекунды в секундах.
func recognitionDurationLabel(_ seconds: Double, language: InterfaceLanguage) -> String {
    if seconds < 1 {
        return "\(Int((seconds * 1000).rounded())) \(localizedText("мс", "ms", language: language))"
    }
    let formatted = String(format: "%.1f", seconds)
        .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
    return "\(formatted) \(localizedText("с", "s", language: language))"
}

/// «10 000» — разряды через узкий неразрывный пробел, как принято в
/// русской типографике; в английском — запятая. Не системная локаль:
/// разряды должны следовать языку интерфейса, а не языку macOS.
func groupedNumberLabel(_ value: Int, language: InterfaceLanguage) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = true
    formatter.groupingSize = 3
    formatter.groupingSeparator = language == .russian ? "\u{202F}" : ","
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}
