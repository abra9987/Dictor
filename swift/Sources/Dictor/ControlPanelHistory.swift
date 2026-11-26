import AppKit

extension DictorControlPanelApp {
    // MARK: - Раздел «История» (макет 6b)

    /// Три колонки: сайдбар (снаружи), список результатов 328pt и
    /// детальный просмотр. Аудио и «как было сказано» из макета не
    /// показываем — запись удаляется сразу, сырой текст не сохраняется.
    func makeMainHistoryView() -> NSView {
        let entries = filteredMainHistory()
        let selected = selectedHistoryEntry(among: entries)

        let list = makeHistoryListColumn(entries: entries, selected: selected)
        list.translatesAutoresizingMaskIntoConstraints = false
        let divider = SDHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        let detail = makeHistoryDetailPane(selected: selected)
        detail.translatesAutoresizingMaskIntoConstraints = false

        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper
        root.addSubview(list)
        root.addSubview(divider)
        root.addSubview(detail)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            list.topAnchor.constraint(equalTo: root.topAnchor),
            list.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            list.widthAnchor.constraint(equalToConstant: 328),
            divider.leadingAnchor.constraint(equalTo: list.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            detail.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            detail.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detail.topAnchor.constraint(equalTo: root.topAnchor),
            detail.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Средняя колонка: поиск, фильтры, счётчик совпадений, список.
    private func makeHistoryListColumn(entries: [(Int, TranscriptHistoryEntry)],
                                       selected: (Int, TranscriptHistoryEntry)?) -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.listPaper

        // Поиск: белое поле 30pt, радиус 8, рамка rgba(0,0,0,.1).
        let searchBox = SDCardBackgroundView()
        searchBox.layer?.cornerRadius = 8
        let magnifier = NSImageView()
        magnifier.image = NSImage(systemSymbolName: "magnifyingglass",
                                  accessibilityDescription: nil)
        magnifier.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11,
                                                                    weight: .regular)
        magnifier.contentTintColor = SD.C.subtle
        let search = NSSearchField()
        search.placeholderString = t("Искать в истории…", "Search history…")
        search.font = .systemFont(ofSize: 12.5)
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.target = self
        search.action = #selector(mainHistorySearchChanged(_:))
        search.stringValue = mainHistorySearch
        search.sendsSearchStringImmediately = true
        search.translatesAutoresizingMaskIntoConstraints = false
        mainHistorySearchField = search
        // Системная лупа-кнопка не нужна: значок нарисован слева по макету.
        (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        // Системный крестик очистки тоже убираем — и вот почему. Поле без
        // рамки (isBordered = false) кладёт редактор текста на всю свою
        // площадь: замерено — редактор −2,5…361,5 при кнопке на 334…356.
        // Крестик рисуется, но попадание мыши достаётся NSTextView, и кнопка
        // не получает ни одного нажатия. Нарисованная и не работающая кнопка
        // хуже её отсутствия, поэтому крестик у нас свой.
        (search.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        magnifier.translatesAutoresizingMaskIntoConstraints = false
        searchBox.addSubview(magnifier)
        searchBox.addSubview(search)
        NSLayoutConstraint.activate([
            searchBox.heightAnchor.constraint(equalToConstant: 30),
            magnifier.leadingAnchor.constraint(equalTo: searchBox.leadingAnchor, constant: 11),
            magnifier.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 8),
            search.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
        ])

        // Крестик появляется только когда есть что стирать.
        if mainHistorySearch.isEmpty {
            search.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor,
                                             constant: -10).isActive = true
        } else {
            let clear = NSButton(title: "×",
                                 target: self,
                                 action: #selector(clearMainHistorySearch(_:)))
            clear.isBordered = false
            clear.font = .systemFont(ofSize: 15)
            clear.contentTintColor = SD.C.subtle
            clear.setButtonType(.momentaryChange)
            clear.toolTip = t("Очистить поиск", "Clear search")
            clear.translatesAutoresizingMaskIntoConstraints = false
            searchBox.addSubview(clear)
            NSLayoutConstraint.activate([
                clear.trailingAnchor.constraint(equalTo: searchBox.trailingAnchor, constant: -6),
                clear.centerYAnchor.constraint(equalTo: searchBox.centerYAnchor),
                clear.widthAnchor.constraint(equalToConstant: 22),
                clear.heightAnchor.constraint(equalToConstant: 22),
                // −8, а не −4: раскладка считает поле по alignment rect, а он
                // уже настоящего кадра, и редактор текста вылезает за границы
                // поля на пару точек. Впритык кнопка снова оказалась бы под
                // текстом.
                search.trailingAnchor.constraint(equalTo: clear.leadingAnchor, constant: -8),
            ])
        }

        // Фильтры. Пилюль по приложениям из макета нет: источник диктовки
        // не сохраняется, поэтому остаются «Все» и «Закреплённые».
        let filters = SDPills(options: [
            .init(title: t("Все", "All"), value: "all"),
            .init(title: t("Закреплённые", "Pinned"), value: "pinned"),
        ], selected: historyShowsPinnedOnly ? "pinned" : "all")
        filters.onSelect = { [weak self] value in
            self?.historyShowsPinnedOnly = value == "pinned"
            self?.refresh(force: true)
        }

        let header = NSStackView(views: [searchBox, filters])
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 9
        header.edgeInsets = NSEdgeInsets(top: 11, left: 14, bottom: 11, right: 14)
        header.translatesAutoresizingMaskIntoConstraints = false
        searchBox.translatesAutoresizingMaskIntoConstraints = false

        let countLabel = NSTextField(labelWithString: "")
        countLabel.attributedStringValue = NSAttributedString(
            string: historyMatchesCaption(count: entries.count).uppercased(),
            attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                .foregroundColor: SD.C.subtle,
                .kern: 0.5,
            ])
        let countRow = NSStackView(views: [countLabel])
        countRow.orientation = .vertical
        countRow.alignment = .leading
        countRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 6, right: 14)

        let scroll: NSScrollView
        if entries.isEmpty {
            let empty = panelLabel(
                mainHistorySearch.isEmpty
                    ? t("Пока пусто", "Nothing here yet")
                    : t("Ничего не нашлось", "No matches"),
                size: 12.5, color: SD.C.graphite)
            let wrapper = NSStackView(views: [empty])
            wrapper.orientation = .vertical
            wrapper.alignment = .centerX
            wrapper.edgeInsets = NSEdgeInsets(top: 28, left: 12, bottom: 28, right: 12)
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            let documentView = SDFlippedView()
            documentView.addSubview(wrapper)
            NSLayoutConstraint.activate([
                wrapper.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
                wrapper.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
                wrapper.topAnchor.constraint(equalTo: documentView.topAnchor),
                wrapper.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            ])
            let emptyScroll = NSScrollView()
            emptyScroll.drawsBackground = false
            emptyScroll.automaticallyAdjustsContentInsets = false
            emptyScroll.contentInsets = NSEdgeInsetsZero
            emptyScroll.documentView = documentView
            documentView.translatesAutoresizingMaskIntoConstraints = false
            documentView.widthAnchor.constraint(equalTo: emptyScroll.widthAnchor).isActive = true
            scroll = emptyScroll
            mainHistoryListView = nil
        } else {
            let pinned = Set(settings.pinnedTranscripts)
            let selectedIndex = selected?.0
            let query = mainHistorySearch
            let list = SDHistoryListView(rowCount: entries.count) { [weak self] position in
                let (index, entry) = entries[position]
                return SDHistoryResultRow(
                    entryIndex: index,
                    meta: self?.historyRowMetaText(entry) ?? "",
                    time: self?.recentEntryTimeText(entry) ?? "",
                    text: entry.text.replacingOccurrences(of: "\n", with: " "),
                    highlight: query,
                    isPinned: pinned.contains(entry.text),
                    isSelected: index == selectedIndex,
                    target: self,
                    action: #selector(DictorControlPanelApp.historyResultRowClicked(_:)))
            }
            scroll = list
            mainHistoryListView = list
        }
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let headerHairline = SDHairlineView()
        let column = NSStackView(views: [header, headerHairline, countRow, scroll])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor,
                                        constant: MAIN_WINDOW_HEADER_HEIGHT - 11),
            column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        return root
    }

    /// Правая колонка: действия сверху, мета и полный текст диктовки.
    private func makeHistoryDetailPane(selected: (Int, TranscriptHistoryEntry)?) -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        guard let (index, entry) = selected else {
            let empty = makeTodayEmptyState()
            empty.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(empty)
            NSLayoutConstraint.activate([
                empty.centerXAnchor.constraint(equalTo: root.centerXAnchor),
                empty.centerYAnchor.constraint(equalTo: root.centerYAnchor),
                empty.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor),
            ])
            return root
        }

        let isPinned = settings.pinnedTranscripts.contains(entry.text)
        let copyButton = SDPrimaryActionButton(title: t("Копировать", "Copy"),
                                               shortcut: "⌘C",
                                               target: self,
                                               action: #selector(copySelectedHistoryEntry(_:)))
        let pinButton = SDSecondaryButton(
            title: isPinned ? t("Открепить", "Unpin") : t("Закрепить", "Pin"),
            target: self,
            action: #selector(togglePinSelectedHistoryEntry(_:)))
        // Словарь чинит то, что модель услышала не так, а видно это здесь —
        // в собственной расшифровке. Кнопка работает и без выделения (откроет
        // пустой диалог), поэтому её состояние не зависит от того, что сейчас
        // выделено: окно во время выделения намеренно не пересобирается.
        let dictionaryButton = SDSecondaryButton(
            title: t("В словарь", "To dictionary"),
            target: self,
            action: #selector(addHistorySelectionToDictionary(_:)))
        let deleteButton = SDSecondaryButton(title: t("Удалить", "Delete"),
                                             target: self,
                                             action: #selector(deleteSelectedHistoryEntry(_:)))
        deleteButton.tag = index

        let actions = NSStackView(views: [copyButton, pinButton, dictionaryButton,
                                          NSView(), deleteButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        actions.translatesAutoresizingMaskIntoConstraints = false
        let headerHairline = SDHairlineView()
        headerHairline.translatesAutoresizingMaskIntoConstraints = false
        let header = NSView()
        header.addSubview(actions)
        header.addSubview(headerHairline)
        header.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            header.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            actions.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            actions.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            actions.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            headerHairline.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            headerHairline.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            headerHairline.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])

        let badge = SDMiniWaveView(values: [0.35, 0.8, 0.5, 0.6],
                                   color: SD.C.subtle,
                                   barWidth: 1.5,
                                   gap: 1.5)
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 10.5).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 14).isActive = true
        let meta = panelLabel(historyDetailMetaText(entry), size: 12, color: SD.C.graphite)
        let metaRow = NSStackView(views: [badge, meta])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 9

        // Полный текст: 16/1.6, выделяемый — его забирают мышью, по слову
        // и по строке, а не только целиком кнопкой «Копировать».
        let body = SDSelectableTranscriptView(text: entry.text,
                                              font: .systemFont(ofSize: 16),
                                              color: SD.C.ink,
                                              lineHeightMultiple: 1.6)
        body.translatesAutoresizingMaskIntoConstraints = false
        body.setDictionaryItem(title: t("В словарь…", "Add to Dictionary…"),
                               target: self,
                               action: #selector(addHistorySelectionToDictionary(_:)))
        historyDetailTranscriptView = body

        metaRow.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(metaRow)
        root.addSubview(body)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            metaRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            metaRow.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -22),
            metaRow.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            body.topAnchor.constraint(equalTo: metaRow.bottomAnchor, constant: 14),
            body.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22),
        ])
        return root
    }

    private func historyMatchesCaption(count: Int) -> String {
        guard !mainHistorySearch.trimmingCharacters(in: .whitespaces).isEmpty else {
            return historyShowsPinnedOnly
                ? t("Закреплённые", "Pinned")
                : t("Все диктовки", "All dictations")
        }
        if language == .russian {
            let mod100 = count % 100
            let mod10 = count % 10
            let noun: String
            if (11...14).contains(mod100) {
                noun = "совпадений"
            } else if mod10 == 1 {
                noun = "совпадение"
            } else if (2...4).contains(mod10) {
                noun = "совпадения"
            } else {
                noun = "совпадений"
            }
            return "\(count) \(noun)"
        }
        return count == 1 ? "1 match" : "\(count) matches"
    }

    /// Мета строки списка: длительность распознавания и число слов.
    private func historyRowMetaText(_ entry: TranscriptHistoryEntry) -> String {
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        return dictatedWordsLabel(words, language: language)
    }

    private func historyDetailMetaText(_ entry: TranscriptHistoryEntry) -> String {
        var parts: [String] = []
        if let createdAt = entry.createdAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language == .russian ? "ru_RU" : "en_US")
            formatter.dateFormat = language == .russian ? "d MMMM, HH:mm" : "MMMM d, h:mm a"
            parts.append(formatter.string(from: createdAt))
        } else {
            parts.append(t("время не сохранилось", "time not recorded"))
        }
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        parts.append(dictatedWordsLabel(words, language: language))
        if let duration = entry.transcriptionDurationSeconds {
            parts.append(String(format: "%.1f %@", duration,
                                localizedText("с", "s", language: language)))
        }
        return parts.joined(separator: " · ")
    }

    /// Ключ выбора переживает пересборку вида и сдвиг индексов.
    func historyEntryKey(_ entry: TranscriptHistoryEntry) -> String {
        "\(entry.createdAt?.timeIntervalSince1970 ?? 0)|\(entry.text.prefix(64))"
    }

    private func selectedHistoryEntry(among entries: [(Int, TranscriptHistoryEntry)])
        -> (Int, TranscriptHistoryEntry)? {
        if let key = historySelectionKey,
           let match = entries.first(where: { historyEntryKey($0.1) == key }) {
            return match
        }
        return entries.first
    }

    @objc fileprivate func historyResultRowClicked(_ sender: SDHistoryResultRow) {
        let entries = settings.recentTranscriptEntries
        guard entries.indices.contains(sender.entryIndex) else { return }
        historySelectionKey = historyEntryKey(entries[sender.entryIndex])
        refresh(force: true)
    }

    @objc private func copySelectedHistoryEntry(_ sender: NSControl) {
        guard let (_, entry) = selectedHistoryEntry(among: filteredMainHistory()) else {
            log("history copy from window: nothing selected")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        log("history entry copied from window (\(entry.text.count) chars)")
        (sender as? SDPrimaryActionButton)?.flashTitle(
            t("Скопировано", "Copied"),
            revertingTo: t("Копировать", "Copy"))
    }

    @objc private func togglePinSelectedHistoryEntry(_ sender: NSControl) {
        guard let (_, entry) = selectedHistoryEntry(among: filteredMainHistory()) else { return }
        var pinned = settings.pinnedTranscripts
        if let existing = pinned.firstIndex(of: entry.text) {
            pinned.remove(at: existing)
        } else {
            pinned.insert(entry.text, at: 0)
        }
        settings.pinnedTranscripts = pinned
        refresh(force: true)
    }

    @objc private func deleteSelectedHistoryEntry(_ sender: NSControl) {
        deleteMainHistoryEntry(at: sender.tag)
    }

    private func filteredMainHistory() -> [(Int, TranscriptHistoryEntry)] {
        let query = mainHistorySearch
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var indexed = Array(settings.recentTranscriptEntries.enumerated())
        if historyShowsPinnedOnly {
            let pinned = Set(settings.pinnedTranscripts)
            indexed = indexed.filter { pinned.contains($0.1.text) }
        }
        guard !query.isEmpty else { return indexed }
        return indexed.filter { $0.1.text.lowercased().contains(query) }
    }

    @objc private func mainHistorySearchChanged(_ sender: NSSearchField) {
        mainHistorySearch = sender.stringValue
        refresh(force: true)
    }

    @objc private func clearMainHistorySearch(_ sender: NSButton) {
        mainHistorySearch = ""
        mainHistorySearchField?.stringValue = ""
        refresh(force: true)
    }

    private func deleteMainHistoryEntry(at index: Int) {
        let entries = settings.recentTranscriptEntries
        guard entries.indices.contains(index) else { return }
        let removed = entries[index]
        // Удаление — через ту же transcriptHistoryArchive, что и самотест:
        // раньше тест проверял функцию без единого продакшн-вызывающего, а
        // реальное удаление было написано рядом инлайн.
        let next = transcriptHistoryArchive(entries, removing: index)
        settings.recentTranscriptEntries = next
        // Явное удаление сильнее закрепления: без снятия пина его текст
        // оставался в plist невидимкой — фильтр «Закреплённые» ищет пины
        // только среди записей архива.
        if !next.contains(where: { $0.text == removed.text }) {
            settings.pinnedTranscripts = settings.pinnedTranscripts.filter { $0 != removed.text }
        }
        if historySelectionKey == historyEntryKey(removed) {
            historySelectionKey = nil
        }
        refresh(force: true)
    }
}
