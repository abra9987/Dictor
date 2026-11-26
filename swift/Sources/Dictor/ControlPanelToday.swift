import AppKit

extension DictorControlPanelApp {
    // MARK: - Подсказки «Сегодня» (правило макета 6e)

    struct TodayHint {
        let identifier: String
        let text: String
        let actionTitle: String?
        let action: Selector?
    }

    /// Одна подсказка за раз и только когда есть настоящий повод.
    /// Закрытые лежат в `settings.dismissedHints` и не возвращаются.
    private func todayHint() -> TodayHint? {
        let dismissed = Set(settings.dismissedHints)
        let entryCount = settings.recentTranscriptEntries.count

        if entryCount >= 3, !dismissed.contains("history-section") {
            return TodayHint(
                identifier: "history-section",
                text: t("Каждая диктовка остаётся в истории — её можно найти и скопировать целиком или по кусочку.",
                        "Every dictation stays in History — find it there and copy all of it or just a piece."),
                actionTitle: t("Показать", "Show"),
                action: #selector(showHistorySectionClicked(_:)))
        }

        if entryCount >= 5, !settings.removeFillerWords,
           !dismissed.contains("filler-removal") {
            return TodayHint(
                identifier: "filler-removal",
                text: t("«Эээ» и «ммм» пока попадают в текст. Включите очистку — они исчезнут ещё до вставки.",
                        "Filler words still land in your text. Turn cleanup on and they go before the paste."),
                actionTitle: t("Включить", "Turn on"),
                action: #selector(enableFillerRemovalFromHint(_:)))
        }
        return nil
    }

    @objc private func dismissTodayHint(_ sender: NSButton) {
        guard let hint = todayHint() else { return }
        settings.dismissedHints.append(hint.identifier)
        refresh(force: true)
    }

    @objc private func enableFillerRemovalFromHint(_ sender: NSButton) {
        settings.removeFillerWords = true
        settings.dismissedHints.append("filler-removal")
        refresh(force: true)
    }

    @objc private func showHistorySectionClicked(_ sender: NSButton) {
        mainSection = .history
        refresh(force: true)
    }

    /// Кнопка «Диктовать» — само действие делает хоткей в агенте, поэтому
    /// окно лишь напоминает, какую комбинацию зажать.
    @objc private func todayDictateHintClicked(_ sender: NSControl) {
        let caps = keycapLabels(for: settings.configuredHotkey, language: language)
            .joined(separator: " + ")
        let alert = NSAlert()
        alert.messageText = t("Диктовка запускается с клавиатуры",
                              "Dictation starts from the keyboard")
        alert.informativeText = t(
            "Поставьте курсор в любое поле ввода и зажмите \(caps). Текст появится там, где стоит курсор.",
            "Put the cursor in any text field and hold \(caps). The text lands where your cursor is.")
        alert.addButton(withTitle: t("Понятно", "Got it"))
        alert.runModal()
    }

    @objc private func todayRecentRowClicked(_ sender: SDRecentEntryRowView) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sender.transcript, forType: .string)
    }

    /// Из «Сегодня» — в «Историю», на ту же самую запись. В строке текст
    /// обрезан одной строкой, и длинную диктовку прочесть больше негде.
    @objc private func todayRecentRowOpen(_ sender: SDRecentEntryRowView) {
        let entries = settings.recentTranscriptEntries
        guard entries.indices.contains(sender.entryIndex) else { return }
        // Поиск в «Истории» мог остаться набранным с прошлого раза — с ним
        // выбранная запись не попадёт в список и выбор будет не виден.
        mainHistorySearch = ""
        historySelectionKey = historyEntryKey(entries[sender.entryIndex])
        mainSection = .history
        refresh(force: true)
    }

    // MARK: - Раздел «Сегодня» (макет 6a)

    func makeTodayView() -> NSView {
        let summary = TodaySummary.make(usage: settings.dailyDictationUsage)
        let entries = settings.recentTranscriptEntries

        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        // Шапка раздела: заголовок + кнопка «Диктовать» с хоткеем.
        let header = NSView()
        let headerTitle = panelLabel(MainWindowSection.today.title(language),
                                     size: 14, weight: .semibold)
        let caps = keycapLabels(for: settings.configuredHotkey, language: language)
        let dictateButton = SDPrimaryActionButton(
            title: t("Диктовать", "Dictate"),
            shortcut: caps.joined(separator: " "),
            target: self,
            action: #selector(todayDictateHintClicked(_:)))
        for view in [headerTitle, dictateButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            header.addSubview(view)
        }
        let headerHairline = SDHairlineView()
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(headerHairline)
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            headerTitle.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 28),
            headerTitle.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            dictateButton.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -28),
            dictateButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        // Приветствие.
        let greeting = panelLabel(t("С возвращением", "Welcome back"),
                                  size: 22, weight: .semibold)
        let subtitle = panelLabel(todayGreetingSubtitle(summary),
                                  size: 13.5, color: SD.C.graphite)
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
            - MAIN_WINDOW_SIDEBAR_WIDTH - 56

        // Три карточки показателей.
        let sparkline = QuickPanelStatBars(values: summary.dayBars)
        sparkline.translatesAutoresizingMaskIntoConstraints = false
        sparkline.widthAnchor.constraint(equalToConstant: 7 * 5 - 2).isActive = true
        sparkline.heightAnchor.constraint(equalToConstant: 22).isActive = true

        let wordsCard = SDStatCardView(
            caption: t("Слов сегодня", "Words today"),
            value: formattedUsageInteger(summary.words),
            delta: summary.deltaPercent.map {
                SDStatCardView.Delta(text: $0 >= 0 ? "+\($0)%" : "\($0)%",
                                     isPositive: $0 >= 0)
            },
            accessory: sparkline)

        let savedCard = SDStatCardView(
            caption: t("Сэкономлено", "Time saved"),
            value: "\(summary.savedMinutesToday)",
            unit: t("мин", "min"),
            footnote: todaySavedMonthText(summary))

        let streakDots = SDStreakDotsView(intensities: summary.streakIntensities,
                                          todayActive: summary.todayActive)
        streakDots.translatesAutoresizingMaskIntoConstraints = false
        streakDots.heightAnchor.constraint(equalToConstant: 15).isActive = true
        let streakCard = SDStatCardView(
            caption: t("Дней подряд", "Day streak"),
            value: "\(summary.streakDays)",
            accessory: streakDots)

        let cards = NSStackView(views: [wordsCard, savedCard, streakCard])
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.translatesAutoresizingMaskIntoConstraints = false
        // 16 + подпись 13 + 8 + число 36 + 10 + спарклайн 22 + 16 (макет 6a).
        cards.heightAnchor.constraint(equalToConstant: 121).isActive = true

        // «Последние диктовки».
        let recentTitle = panelLabel(t("Последние диктовки", "Recent dictations"),
                                     size: 13, weight: .semibold)
        let allHistory = NSButton(title: t("Вся история", "All history"),
                                  target: self,
                                  action: #selector(showHistorySectionClicked(_:)))
        allHistory.isBordered = false
        allHistory.font = .systemFont(ofSize: 12)
        allHistory.contentTintColor = SD.C.voice
        let recentHeader = NSStackView(views: [recentTitle, allHistory])
        recentHeader.orientation = .horizontal
        recentHeader.alignment = .firstBaseline
        recentHeader.spacing = 10

        let recentCard = makeTodayRecentCard(entries: Array(entries.prefix(3)))

        let column = NSStackView(views: [greeting, subtitle, cards,
                                         recentHeader, recentCard])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 24, right: 28)
        column.setCustomSpacing(5, after: greeting)
        column.setCustomSpacing(20, after: subtitle)
        column.setCustomSpacing(24, after: cards)
        column.setCustomSpacing(11, after: recentHeader)

        if let hint = todayHint() {
            let banner = SDHintBannerView(text: hint.text,
                                          actionTitle: hint.actionTitle,
                                          target: self,
                                          action: hint.action,
                                          dismissAction: #selector(dismissTodayHint(_:)))
            column.addArrangedSubview(banner)
            column.setCustomSpacing(18, after: recentCard)
        }

        column.translatesAutoresizingMaskIntoConstraints = false
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(column)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: header.bottomAnchor),
            column.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor),
        ])
        for view in [cards, recentHeader, recentCard] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor,
                                        constant: -56).isActive = true
        }
        if let banner = column.arrangedSubviews.last as? SDHintBannerView {
            banner.widthAnchor.constraint(equalTo: column.widthAnchor,
                                          constant: -56).isActive = true
        }
        return root
    }

    /// Карточка со списком последних диктовок (или пустое состояние 5f).
    private func makeTodayRecentCard(entries: [TranscriptHistoryEntry]) -> NSView {
        let card = SDCardBackgroundView()
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        if entries.isEmpty {
            let empty = makeTodayEmptyState()
            column.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        } else {
            for (index, entry) in entries.enumerated() {
                if index > 0 {
                    let hairline = SDHairlineView()
                    column.addArrangedSubview(hairline)
                    hairline.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
                }
                let row = SDRecentEntryRowView(
                    transcript: entry.text,
                    entryIndex: index,
                    preview: entry.text.replacingOccurrences(of: "\n", with: " "),
                    time: recentEntryTimeText(entry),
                    copyTooltip: t("Копировать", "Copy"),
                    openTooltip: t("Открыть целиком в «Истории»", "Open in full in History"),
                    target: self,
                    copyAction: #selector(todayRecentRowClicked(_:)),
                    openAction: #selector(todayRecentRowOpen(_:)))
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
            }
        }

        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            column.topAnchor.constraint(equalTo: card.topAnchor),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])
        return card
    }

    /// Пустое состояние по макету 5f: волна, заголовок, что нажать.
    func makeTodayEmptyState() -> NSView {
        let wave = SDMiniWaveView(values: [0.09, 0.09, 0.09, 0.3, 0.09, 0.09, 0.09],
                                  color: SD.C.subtle,
                                  barWidth: 2,
                                  gap: 2)
        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.widthAnchor.constraint(equalToConstant: 26).isActive = true
        wave.heightAnchor.constraint(equalToConstant: 14).isActive = true

        let title = panelLabel(t("Здесь появятся ваши диктовки",
                                 "Your dictations will show up here"),
                               size: 13, weight: .semibold)
        let caps = keycapLabels(for: settings.configuredHotkey, language: language)
            .joined(separator: " + ")
        let hint = panelLabel(
            t("Откройте любое поле ввода, зажмите \(caps) и скажите пару слов.",
              "Open any text field, hold \(caps) and say a few words."),
            size: 11.5, color: SD.C.graphite)
        hint.alignment = .center
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2
        hint.preferredMaxLayoutWidth = 300

        let column = NSStackView(views: [wave, title, hint])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 0
        column.edgeInsets = NSEdgeInsets(top: 22, left: 20, bottom: 22, right: 20)
        column.setCustomSpacing(10, after: wave)
        column.setCustomSpacing(4, after: title)
        return column
    }

    private func todayGreetingSubtitle(_ summary: TodaySummary) -> String {
        guard summary.words > 0 else {
            return t("Сегодня вы ещё не диктовали. Зажмите хоткей в любом поле ввода — текст появится там, где стоит курсор.",
                     "No dictations today yet. Hold the hotkey in any text field and the text lands where your cursor is.")
        }
        let words = formattedUsageInteger(summary.words)
        if summary.savedMinutesToday >= 1 {
            let minutes = dictationMinutesLabel(summary.savedMinutesToday, language: language)
            return t("За сегодня вы наговорили \(words) слов. Это примерно \(minutes), которые не ушли на клавиатуру.",
                     "You dictated \(words) words today — about \(minutes) that never went to the keyboard.")
        }
        return t("За сегодня вы наговорили \(words) слов.",
                 "You dictated \(words) words today.")
    }

    private func todaySavedMonthText(_ summary: TodaySummary) -> String {
        guard summary.savedHoursMonth >= 0.1 else {
            return t("за месяц пока немного", "not much this month yet")
        }
        let hours = String(format: "%.1f", summary.savedHoursMonth)
            .replacingOccurrences(of: ".", with: language == .russian ? "," : ".")
        return t("\(hours) часа за месяц", "\(hours) hours this month")
    }

    func recentEntryTimeText(_ entry: TranscriptHistoryEntry) -> String {
        guard let createdAt = entry.createdAt else {
            return t("ранее", "earlier")
        }
        let elapsed = Date().timeIntervalSince(createdAt)
        if elapsed < 60 {
            return t("только что", "just now")
        }
        if elapsed < 3600 {
            let minutes = Int(elapsed / 60)
            return t("\(minutes) мин назад", "\(minutes) min ago")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: createdAt)
    }
}
