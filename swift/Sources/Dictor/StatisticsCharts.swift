import AppKit

// MARK: - График сравнения периодов (макет 7a)

/// Столбики: текущий период кораллом от нижней кромки, прошлый —
/// серым сегментом над ним. У пикового столбика — тёмная плашка со значением.
final class SDComparisonBarChart: NSView {
    private let buckets: [StatsBucket]
    private let peakIndex: Int?
    private let peakText: String?
    /// Столбик под курсором. Пока его нет, плашку носит пик — иначе график
    /// молчит о своей шкале: без подписей у оси Y высота столбика сама по
    /// себе не значит ничего, и «пик — 46» отвечал ровно на один вопрос из
    /// тридцати.
    private(set) var hoveredIndex: Int? {
        didSet {
            guard hoveredIndex != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Подпись столбика для плашки. Локаль берётся из окна: график живёт в
    /// разделе «Статистика», а не в настройках, и своего языка не знает.
    var calloutFormatter: ((StatsBucket) -> String)?

    init(buckets: [StatsBucket], peakIndex: Int?, peakText: String?) {
        self.buckets = buckets
        self.peakIndex = peakIndex
        self.peakText = peakText
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        hoveredIndex = bucketIndex(at: point)
    }

    override func mouseExited(with event: NSEvent) {
        hoveredIndex = nil
    }

    /// Столбик по горизонтали: попадать нужно в колонку целиком, включая
    /// зазор и пустое место над коротким столбиком, — целиться мышью в
    /// трёхпиксельную полоску года никто не станет.
    func bucketIndex(at point: NSPoint) -> Int? {
        guard !buckets.isEmpty, bounds.width > 0 else { return nil }
        let step = bounds.width / CGFloat(buckets.count)
        let index = Int(point.x / step)
        guard buckets.indices.contains(index) else { return nil }
        return index
    }

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

        // Плашку носит столбик под курсором, а пока курсора нет — пик.
        let calloutIndex = hoveredIndex ?? peakIndex
        for (index, bucket) in buckets.enumerated() {
            let x = CGFloat(index) * (columnWidth + gap)
            let currentHeight = plotHeight * CGFloat(bucket.words) / CGFloat(peakStack)
            let previousHeight = plotHeight * CGFloat(bucket.previousWords) / CGFloat(peakStack)

            // Пустой столбик под курсором тоже отзывается: подложка говорит,
            // что попал именно сюда и что здесь ноль, а не промах мышью.
            if index == hoveredIndex {
                SD.C.rowHairline.setFill()
                NSRect(x: x, y: axisHeight, width: columnWidth,
                       height: plotHeight).fill()
            }

            if currentHeight > 0.5 {
                let rect = NSRect(x: x, y: axisHeight, width: columnWidth, height: currentHeight)
                (index == calloutIndex ? SD.C.voice : SD.C.voice.withAlphaComponent(0.85)).setFill()
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

            // Плашка пикового столбика показывала одно число на весь график.
            // Под курсором она показывает число этого столбика и его период:
            // высота без шкалы сама по себе не сообщает ничего.
            let calloutString: String?
            if index == hoveredIndex {
                calloutString = calloutFormatter?(bucket) ?? "\(bucket.words)"
            } else if index == peakIndex, hoveredIndex == nil {
                calloutString = peakText
            } else {
                calloutString = nil
            }
            if let calloutString {
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: SD.C.pillSelectedText,
                ]
                let text = calloutString as NSString
                let size = text.size(withAttributes: attributes)
                // Плашка живёт в полосе, отведённой ей над графиком, а не над
                // своим столбиком: у пустого столбика «над» — это у самой оси,
                // и число терялось внизу, а при движении мыши прыгало по
                // высоте вслед за соседями.
                let pill = NSRect(x: min(max(0, x + columnWidth / 2 - size.width / 2 - 8),
                                         bounds.width - size.width - 16),
                                  y: axisHeight + plotHeight + 2,
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
