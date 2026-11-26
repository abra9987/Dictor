// Раздел «Статистика»: карточки итогов, график по дням, привычки, часы и год,
// экспорт в CSV и сброс.

import AppKit

extension DictorControlPanelApp {
    // MARK: - Раздел «Статистика» (макеты 7a/7b/7c)

    func makeStatsSectionView() -> NSView {
        let summary = StatsCalculator.summary(period: statsPeriod,
                                              usage: settings.dailyDictationUsage,
                                              entries: settings.recentTranscriptEntries,
                                              language: language)
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        // Шапка: заголовок, переключатель периодов, подпись периода и экспорт.
        let periodPills = SDPills(options: StatsPeriod.allCases.map {
            .init(title: $0.title(language), value: $0.rawValue)
        }, selected: statsPeriod.rawValue)
        periodPills.onSelect = { [weak self] raw in
            guard let period = StatsPeriod(rawValue: raw) else { return }
            self?.statsPeriod = period
            self?.refresh(force: true)
        }
        let periodLabel = panelLabel(summary.periodTitle, size: 12.5, color: SD.C.inkSecondary)
        let export = NSButton(title: t("Экспорт CSV", "Export CSV"),
                              target: self,
                              action: #selector(exportStatsCSVClicked(_:)))
        export.isBordered = false
        export.font = .systemFont(ofSize: 12.5)
        export.contentTintColor = SD.C.voice
        let headerRight = NSStackView(views: [periodLabel, export])
        headerRight.orientation = .horizontal
        headerRight.alignment = .centerY
        headerRight.spacing = 12

        let header = NSView()
        let headerTitle = panelLabel(MainWindowSection.stats.title(language),
                                     size: 14, weight: .semibold, color: SD.C.ink)
        for view in [headerTitle, periodPills, headerRight] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let headerHairline = SDHairlineView()
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerHairline)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 24),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            periodPills.leadingAnchor.constraint(equalTo: headerTitle.trailingAnchor, constant: 12),
            periodPills.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerRight.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -24),
            headerRight.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerRight.leadingAnchor.constraint(greaterThanOrEqualTo: periodPills.trailingAnchor,
                                                 constant: 12),
            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 24, right: 24)
        column.translatesAutoresizingMaskIntoConstraints = false

        let cards = statsHeadlineCards(summary)
        column.addArrangedSubview(cards)
        column.setCustomSpacing(18, after: cards)

        let chart = statsChartCard(summary)
        column.addArrangedSubview(chart)
        column.setCustomSpacing(16, after: chart)

        let habitAndHours = NSStackView(views: [statsHabitCard(summary),
                                                statsHoursCard(summary)])
        habitAndHours.orientation = .horizontal
        habitAndHours.distribution = .fillEqually
        habitAndHours.alignment = .top
        habitAndHours.spacing = 12
        column.addArrangedSubview(habitAndHours)

        // Годовой разрез (7c) показываем там, где он уместен.
        if statsPeriod == .year || statsPeriod == .all {
            column.setCustomSpacing(16, after: habitAndHours)
            let year = statsYearCard(summary)
            column.addArrangedSubview(year)
            year.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }

        for view in [cards, chart, habitAndHours] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -48).isActive = true
        }

        let documentView = SDFlippedView()
        documentView.addSubview(column)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: documentView.topAnchor),
            documentView.bottomAnchor.constraint(equalTo: column.bottomAnchor),
        ])
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.verticalScroller?.controlSize = .small
        // Окно с fullSizeContentView: скролл сам добавил бы сверху отступ
        // высотой с тайтлбар, чтобы содержимое не уезжало под кнопки окна.
        // Кнопки лежат над сайдбаром, а не над этой панелью, так что отступ
        // здесь — просто пустая полоса над первой строкой.
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scroll.widthAnchor).isActive = true

        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Четыре показателя вверху. «Правок %» из макета нет — учёта правок
    /// после вставки движок не ведёт, поэтому вместо выдуманного числа
    /// показываем количество диктовок.
    private func statsHeadlineCards(_ summary: StatsSummary) -> NSView {
        let wordsCard = SDStatCardView(
            caption: t("Слов за период", "Words this period"),
            value: formattedUsageInteger(summary.words),
            delta: summary.deltaPercent.map {
                SDStatCardView.Delta(text: $0 >= 0 ? "+\($0)%" : "\($0)%",
                                     isPositive: $0 >= 0)
            },
            footnote: summary.previousWords > 0
                ? t("было \(formattedUsageInteger(summary.previousWords))",
                    "was \(formattedUsageInteger(summary.previousWords))")
                : t("не с чем сравнить", "nothing to compare with"))

        let savedValue = String(format: "%.1f", summary.savedHours)
            .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
        let savedCard = SDStatCardView(
            caption: t("Сэкономлено", "Time saved"),
            value: savedValue,
            unit: t("ч", "h"),
            footnote: summary.workingDays >= 0.1
                ? t("≈ \(String(format: "%.1f", summary.workingDays).replacingOccurrences(of: ".", with: ",")) рабочих дня",
                    "≈ \(String(format: "%.1f", summary.workingDays)) working days")
                : t("считаем от 40 слов/мин на клавиатуре",
                    "assuming 40 wpm typing"))

        let speedCard = SDStatCardView(
            caption: t("Скорость речи", "Speech rate"),
            value: summary.speechWordsPerMinute > 0 ? "\(summary.speechWordsPerMinute)" : "—",
            unit: t("сл/мин", "wpm"),
            footnote: t("на клавиатуре считаем 40", "keyboard assumed at 40"))

        let countCard = SDStatCardView(
            caption: t("Диктовок", "Dictations"),
            value: formattedUsageInteger(summary.dictationCount),
            footnote: summary.averageDictationSeconds > 0
                ? t("в среднем \(statsDurationText(summary.averageDictationSeconds))",
                    "\(statsDurationText(summary.averageDictationSeconds)) on average")
                : t("пока нет данных", "no data yet"))

        let row = NSStackView(views: [wordsCard, savedCard, speedCard, countCard])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 11
        row.translatesAutoresizingMaskIntoConstraints = false
        // 16 + подпись 13 + 8 + число 36 + 10 + сноска 14 + 16 (макет 7a).
        row.heightAnchor.constraint(equalToConstant: 116).isActive = true
        return row
    }

    private func statsChartCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(statsChartTitle(), size: 12.5, weight: .semibold, color: SD.C.ink)
        var peakText: String?
        if let index = summary.peakBucketIndex, summary.buckets[index].words > 0 {
            peakText = formattedUsageInteger(summary.buckets[index].words)
        }
        let subtitle = panelLabel(
            peakText.map { t("пик — \($0) слов", "peak — \($0) words") }
                ?? t("пока пусто", "no data yet"),
            size: 11.5, color: SD.C.subtle)

        let legendCurrent = statsLegendItem(color: SD.C.voice,
                                            text: t("сейчас", "current"))
        let legendPrevious = statsLegendItem(
            color: NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor.white.withAlphaComponent(0.14)
                    : NSColor.black.withAlphaComponent(0.1)
            },
            text: t("прошлый период", "previous"))
        let legend = NSStackView(views: [legendCurrent, legendPrevious])
        legend.orientation = .horizontal
        legend.spacing = 12

        let head = NSStackView(views: [title, subtitle, NSView(), legend])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10

        let chart = SDComparisonBarChart(buckets: summary.buckets,
                                         peakIndex: summary.peakBucketIndex,
                                         peakText: peakText)
        // Подпись столбика под курсором: период, число слов и — если прошлый
        // период у этого столбика непустой — его число. Легенда обещает два
        // ряда, значит и плашка обязана называть оба, иначе серый сегмент
        // остаётся без единого числа во всём разделе.
        chart.calloutFormatter = { [language] bucket in
            let words = formattedUsageInteger(bucket.words)
            var text = "\(bucket.calloutLabel): \(words)"
            if bucket.previousWords > 0 {
                let previous = formattedUsageInteger(bucket.previousWords)
                text += localizedText(" · было \(previous)", " · was \(previous)",
                                      language: language)
            }
            return text
        }
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 168).isActive = true

        let column = NSStackView(views: [head, chart])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 14, right: 18)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [head, chart] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -36).isActive = true
        }
        return card
    }

    private func statsLegendItem(color: NSColor, text: String) -> NSView {
        let swatch = SDLegendSwatch(color: color)
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 8).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let label = panelLabel(text, size: 11, color: SD.C.graphite)
        let row = NSStackView(views: [swatch, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 5
        return row
    }

    private func statsChartTitle() -> String {
        switch statsPeriod {
        case .week: return t("Слов по дням", "Words by day")
        case .month: return t("Слов по дням", "Words by day")
        case .quarter: return t("Слов по неделям", "Words by week")
        case .year, .all: return t("Слов по месяцам", "Words by month")
        }
    }

    private func statsHabitCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(t("Привычка", "Habit"), size: 12.5, weight: .semibold, color: SD.C.ink)
        let streakText: String
        if summary.currentStreak > 0 {
            streakText = t("\(summary.currentStreak) дней подряд · лучший результат \(summary.bestStreak)",
                           "\(summary.currentStreak)-day streak · best \(summary.bestStreak)")
        } else {
            streakText = t("серии пока нет", "no streak yet")
        }
        let subtitle = panelLabel(streakText, size: 11.5, color: SD.C.subtle)
        let head = NSStackView(views: [title, subtitle])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10

        let heatmap = SDHabitHeatmapView(days: summary.habit)
        heatmap.translatesAutoresizingMaskIntoConstraints = false
        heatmap.heightAnchor.constraint(equalToConstant: 7 * 14 - 3).isActive = true

        let note = panelLabel(
            t("Каждый квадрат — день, насыщенность — сколько слов. Выходные обычно пустые, и это нормально.",
              "Each square is a day; the darker it is, the more words. Empty weekends are fine."),
            size: 11.5, color: SD.C.graphite)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 320

        let column = NSStackView(views: [head, heatmap, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 15, right: 17)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [head, heatmap, note] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -34).isActive = true
        }
        return card
    }

    private func statsHoursCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(t("Когда диктуете", "When you dictate"),
                               size: 12.5, weight: .semibold, color: SD.C.ink)
        let histogram = SDHourHistogramView(values: summary.hourly)
        histogram.translatesAutoresizingMaskIntoConstraints = false
        histogram.heightAnchor.constraint(equalToConstant: 88).isActive = true

        let peakHour = summary.hourly.enumerated().max(by: { $0.element < $1.element })
        let noteText: String
        if summary.hourlySampleCount == 0 {
            noteText = t("Считается по времени записей истории — за этот период их пока нет.",
                         "Built from history timestamps — none in this period yet.")
        } else if let peakHour, peakHour.element > 0 {
            noteText = t("Больше всего — около \(peakHour.offset):00. По \(summary.hourlySampleCount) записям истории.",
                         "Busiest around \(peakHour.offset):00, from \(summary.hourlySampleCount) history entries.")
        } else {
            noteText = t("Пока недостаточно записей.", "Not enough entries yet.")
        }
        let note = panelLabel(noteText, size: 11.5, color: SD.C.graphite)
        note.lineBreakMode = .byWordWrapping
        note.maximumNumberOfLines = 3
        note.preferredMaxLayoutWidth = 320

        let column = NSStackView(views: [title, histogram, note])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 12
        column.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 15, right: 17)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [title, histogram, note] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -34).isActive = true
        }
        return card
    }

    /// Год по кварталам и честный итог (макет 7c).
    private func statsYearCard(_ summary: StatsSummary) -> NSView {
        let card = SDCardBackgroundView()
        let title = panelLabel(t("По кварталам", "By quarter"),
                               size: 12.5, weight: .semibold, color: SD.C.ink)
        var sinceText = ""
        if let first = summary.firstDay {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
            formatter.dateFormat = "d MMMM"
            sinceText = t("данные с \(formatter.string(from: first))",
                          "data since \(formatter.string(from: first))")
        }
        let since = panelLabel(sinceText, size: 11.5, color: SD.C.subtle)
        let head = NSStackView(views: [title, NSView(), since])
        head.orientation = .horizontal
        head.alignment = .firstBaseline
        head.spacing = 10

        let bars = SDQuarterBarsView(quarters: summary.quarters, language: language)
        bars.translatesAutoresizingMaskIntoConstraints = false
        bars.heightAnchor.constraint(equalToConstant: 4 * 26 + 3 * 10).isActive = true

        let totalWords = summary.quarters.reduce(0) { $0 + $1.words }
        let totalHours = summary.quarters.reduce(0.0) { $0 + $1.savedHours }
        let conclusion = panelLabel(statsYearConclusion(words: totalWords, hours: totalHours),
                                    size: 15, color: SD.C.ink)
        conclusion.lineBreakMode = .byWordWrapping
        conclusion.maximumNumberOfLines = 3
        conclusion.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 120

        let reset = SDSecondaryButton(title: t("Сбросить статистику", "Reset statistics"),
                                      target: self,
                                      action: #selector(resetStatsClicked(_:)))
        let actions = NSStackView(views: [reset, NSView()])
        actions.orientation = .horizontal
        actions.spacing = 10

        let tone = panelLabel(
            t("Ни одна цифра не считается «нормой» и ни за что не ругает. Упал график — приложение молчит.",
              "No number here is a target, and nothing scolds you. If the chart dips, the app stays quiet."),
            size: 11.5, color: SD.C.graphite)
        tone.lineBreakMode = .byWordWrapping
        tone.maximumNumberOfLines = 3
        tone.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 120

        let column = NSStackView(views: [head, bars, conclusion, actions, tone])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        column.edgeInsets = NSEdgeInsets(top: 15, left: 17, bottom: 16, right: 17)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        for view in [head, bars, conclusion, tone] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -34).isActive = true
        }
        return card
    }

    private func statsYearConclusion(words: Int, hours: Double) -> String {
        guard words > 0 else {
            return t("Пока считать нечего — данные появятся после первых диктовок.",
                     "Nothing to sum up yet — numbers appear after your first dictations.")
        }
        let hoursText = String(format: "%.1f", hours)
            .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
        return t("\(formattedUsageInteger(words)) слов голосом — это \(hoursText) часа, которые не ушли на клавиатуру.",
                 "\(formattedUsageInteger(words)) words by voice — \(hoursText) hours that never went to the keyboard.")
    }

    private func statsDurationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    @objc private func exportStatsCSVClicked(_ sender: NSButton) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "dictor-stats.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var csv = "day,dictations,characters,words,audio_seconds,asr_seconds\n"
        for day in settings.dailyDictationUsage.sorted(by: { $0.day < $1.day }) {
            let words = approximateWordCount(characters: day.characterCount)
            csv += "\(day.day),\(day.dictationCount),\(day.characterCount),\(words),"
            csv += String(format: "%.1f,%.1f\n", day.audioSeconds, day.asrSeconds)
        }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            showError(title: t("Не удалось сохранить файл", "Could not save the file"),
                      detail: error.localizedDescription)
        }
    }

    @objc private func resetStatsClicked(_ sender: NSControl) {
        let alert = NSAlert()
        alert.messageText = t("Сбросить статистику?", "Reset statistics?")
        alert.informativeText = t(
            "Посуточные счётчики будут удалены навсегда. История диктовок останется на месте.",
            "The daily counters are deleted for good. Your dictation history stays.")
        alert.addButton(withTitle: t("Сбросить", "Reset"))
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.dailyDictationUsage = []
        refresh(force: true)
    }
}
