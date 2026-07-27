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
                buckets.append(StatsBucket(label: label,
                                           words: dayWords,
                                           previousWords: previousWords,
                                           axisLabel: period == .week
                                               ? label
                                               : (calendar.component(.day, from: cursor) % 7 == 1
                                                   ? label : nil)))
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
                buckets.append(StatsBucket(label: "", words: current,
                                           previousWords: previousWords,
                                           axisLabel: formatter.string(from: cursor)))
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

// MARK: - График сравнения периодов (макет 7a)

/// Столбики: текущий период кораллом от нижней кромки, прошлый —
/// серым сегментом над ним. У пикового столбика — тёмная плашка со значением.
final class SDComparisonBarChart: NSView {
    private let buckets: [StatsBucket]
    private let peakIndex: Int?
    private let peakText: String?

    init(buckets: [StatsBucket], peakIndex: Int?, peakText: String?) {
        self.buckets = buckets
        self.peakIndex = peakIndex
        self.peakText = peakText
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !buckets.isEmpty else { return }
        let axisHeight: CGFloat = 16
        let calloutHeight: CGFloat = peakText == nil ? 0 : 20
        let plotHeight = max(10, bounds.height - axisHeight - calloutHeight)
        let gap: CGFloat = buckets.count > 20 ? 3 : 9
        let columnWidth = max(3, (bounds.width - gap * CGFloat(buckets.count - 1))
            / CGFloat(buckets.count))
        let peak = max(1, buckets.map { max($0.words, $0.previousWords) }.max() ?? 1)
        // Масштаб по сумме сегментов, иначе стопка вылезает за карточку.
        let peakStack = max(1, buckets.map { $0.words + $0.previousWords }.max() ?? 1)
        _ = peak

        for (index, bucket) in buckets.enumerated() {
            let x = CGFloat(index) * (columnWidth + gap)
            let currentHeight = plotHeight * CGFloat(bucket.words) / CGFloat(peakStack)
            let previousHeight = plotHeight * CGFloat(bucket.previousWords) / CGFloat(peakStack)

            if currentHeight > 0.5 {
                let rect = NSRect(x: x, y: axisHeight, width: columnWidth, height: currentHeight)
                (index == peakIndex ? SD.C.voice : SD.C.voice.withAlphaComponent(0.85)).setFill()
                roundedTop(rect).fill()
            }
            if previousHeight > 0.5 {
                let rect = NSRect(x: x,
                                  y: axisHeight + currentHeight + (currentHeight > 0.5 ? 2 : 0),
                                  width: columnWidth,
                                  height: previousHeight)
                NSColor(name: nil) { appearance in
                    appearance.isDark
                        ? NSColor.white.withAlphaComponent(0.14)
                        : NSColor.black.withAlphaComponent(0.1)
                }.setFill()
                roundedTop(rect).fill()
            }

            if let axisLabel = bucket.axisLabel {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10.5),
                    .foregroundColor: SD.C.subtle,
                ]
                let text = axisLabel as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x + (columnWidth - size.width) / 2, y: 1),
                          withAttributes: attributes)
            }

            if index == peakIndex, let peakText {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: SD.C.pillSelectedText,
                ]
                let text = peakText as NSString
                let size = text.size(withAttributes: attributes)
                let pill = NSRect(x: min(max(0, x + columnWidth / 2 - size.width / 2 - 8),
                                         bounds.width - size.width - 16),
                                  y: axisHeight + currentHeight + previousHeight + 6,
                                  width: size.width + 16,
                                  height: 18)
                SD.C.pillSelectedFill.setFill()
                NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
                text.draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3),
                          withAttributes: attributes)
            }
        }
    }

    private func roundedTop(_ rect: NSRect) -> NSBezierPath {
        let radius = min(4, rect.width / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - radius))
        path.appendArc(withCenter: NSPoint(x: rect.minX + radius, y: rect.maxY - radius),
                       radius: radius, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius),
                       radius: radius, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.close()
        return path
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Календарь привычки (макет 7b)

/// Квадрат на день, столбец — неделя. Насыщенность = сколько слов.
final class SDHabitHeatmapView: NSView {
    private let days: [StatsDay]
    private let calendar = Calendar.current
    static let cell: CGFloat = 11
    static let gap: CGFloat = 3

    init(days: [StatsDay]) {
        self.days = days
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    var columnCount: Int {
        max(1, Int(ceil(Double(days.count) / 7.0)))
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: CGFloat(columnCount) * (Self.cell + Self.gap) - Self.gap,
               height: 7 * (Self.cell + Self.gap) - Self.gap)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !days.isEmpty else { return }
        let today = calendar.startOfDay(for: Date())
        for (index, day) in days.enumerated() {
            let column = index / 7
            let row = index % 7
            let x = CGFloat(column) * (Self.cell + Self.gap)
            // Верхняя строка — первый день недели, поэтому y считаем сверху.
            let y = bounds.height - CGFloat(row + 1) * (Self.cell + Self.gap) + Self.gap
            let rect = NSRect(x: x, y: y, width: Self.cell, height: Self.cell)
            if day.intensity > 0 {
                SD.C.voice.withAlphaComponent(day.intensity).setFill()
            } else {
                NSColor(name: nil) { appearance in
                    appearance.isDark
                        ? NSColor.white.withAlphaComponent(0.07)
                        : NSColor.black.withAlphaComponent(0.06)
                }.setFill()
            }
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            if calendar.isDate(day.date, inSameDayAs: today) {
                SD.C.voice.withAlphaComponent(0.25).setStroke()
                let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5),
                                        xRadius: 4.5, yRadius: 4.5)
                ring.lineWidth = 2
                ring.stroke()
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Часы суток (макет 7a, «Когда диктуете»)

final class SDHourHistogramView: NSView {
    private let values: [Int]

    init(values: [Int]) {
        self.values = values
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let axisHeight: CGFloat = 14
        let plotHeight = max(6, bounds.height - axisHeight)
        let gap: CGFloat = 4
        let barWidth = max(2, (bounds.width - gap * CGFloat(values.count - 1))
            / CGFloat(values.count))
        let peak = max(1, values.max() ?? 1)
        for (hour, value) in values.enumerated() {
            let height = value > 0
                ? max(3, plotHeight * CGFloat(value) / CGFloat(peak))
                : 2
            let x = CGFloat(hour) * (barWidth + gap)
            let rect = NSRect(x: x, y: axisHeight, width: barWidth, height: height)
            let share = CGFloat(value) / CGFloat(peak)
            SD.C.voice.withAlphaComponent(value > 0 ? max(0.28, share) : 0.12).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()

            if hour % 6 == 0 {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10.5),
                    .foregroundColor: SD.C.subtle,
                ]
                let text = "\(hour)" as NSString
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: x + (barWidth - size.width) / 2, y: 0),
                          withAttributes: attributes)
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Кварталы года (макет 7c)

final class SDQuarterBarsView: NSView {
    private let quarters: [StatsQuarter]
    private let language: InterfaceLanguage

    init(quarters: [StatsQuarter], language: InterfaceLanguage) {
        self.quarters = quarters
        self.language = language
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: CGFloat(quarters.count) * 26 + CGFloat(max(0, quarters.count - 1)) * 10)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rowHeight: CGFloat = 26
        let spacing: CGFloat = 10
        let labelWidth: CGFloat = 26
        let savedWidth: CGFloat = 58
        let peak = max(1, quarters.map(\.words).max() ?? 1)

        for (index, quarter) in quarters.enumerated() {
            let y = bounds.height - CGFloat(index + 1) * rowHeight
                - CGFloat(index) * spacing
            let labelAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: quarter.hasData ? SD.C.ink : SD.C.subtle,
            ]
            (quarter.label as NSString).draw(at: NSPoint(x: 0, y: y + 6),
                                             withAttributes: labelAttributes)

            let trackRect = NSRect(x: labelWidth + 11, y: y,
                                   width: bounds.width - labelWidth - savedWidth - 33,
                                   height: rowHeight)
            NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.05)
                    : NSColor.black.withAlphaComponent(0.05)
            }.setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 6, yRadius: 6).fill()

            if quarter.words > 0 {
                let width = max(28, trackRect.width * CGFloat(quarter.words) / CGFloat(peak))
                let fill = NSRect(x: trackRect.minX, y: y, width: width, height: rowHeight)
                (quarter.isCurrent ? SD.C.voice : SD.C.voice.withAlphaComponent(0.55)).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 6, yRadius: 6).fill()
                let valueAttributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .semibold),
                    .foregroundColor: NSColor.white,
                ]
                (formattedUsageInteger(quarter.words) as NSString)
                    .draw(at: NSPoint(x: trackRect.minX + 11, y: y + 6),
                          withAttributes: valueAttributes)
            }

            let savedText: String
            if !quarter.hasData {
                savedText = "—"
            } else if quarter.isCurrent {
                savedText = localizedText("идёт", "ongoing", language: language)
            } else if quarter.savedHours >= 0.1 {
                savedText = String(format: "%.1f ", quarter.savedHours)
                    .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
                    + localizedText("ч", "h", language: language)
            } else {
                savedText = "—"
            }
            let savedAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11.5),
                .foregroundColor: SD.C.graphite,
            ]
            let text = savedText as NSString
            let size = text.size(withAttributes: savedAttributes)
            text.draw(at: NSPoint(x: bounds.width - size.width, y: y + 6),
                      withAttributes: savedAttributes)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
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

/// Квадратик легенды графика.
final class SDLegendSwatch: NSView {
    private let color: NSColor

    init(color: NSColor) {
        self.color = color
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
