import AppKit

extension DictorQuickPanel {
    func languageRow() -> NSView {
        // Макет: подпись 12 graphite шириной 72, пилюли как в настройках.
        let row = NSView()
        let caption = label(t("Алфавит", "Script"), size: 12, color: SD.C.graphite)

        // Те же три варианта, что в окне, — только подписи короче: панель
        // узкая, а «Кириллица» целиком в неё не влезает.
        var options: [(String, DictationLanguage)] =
            dictationScriptOptions(interfaceLanguage: state.interfaceLanguage)
                .map { ($0.shortTitle, $0.language) }
        if !options.contains(where: { $0.1 == state.language }) {
            options.insert((state.language.rawValue.uppercased(), state.language), at: 0)
        }
        let pills = SDPills(options: options.map { .init(title: $0.0, value: $0.1.rawValue) },
                            selected: state.language.rawValue)
        pills.onSelect = { [weak self] raw in
            guard let language = DictationLanguage(rawValue: raw) else { return }
            self?.quickDelegate?.quickPanelDidSelectLanguage(language)
        }

        for view in [caption, pills] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 38),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 72),
            pills.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 10),
            pills.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func microphoneRow() -> NSView {
        let row = NSView()
        let caption = label(t("Микрофон", "Microphone"), size: 12, color: SD.C.graphite)
        let popup = NSPopUpButton()
        popup.isBordered = false
        popup.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        popup.addItem(withTitle: t("Системный по умолчанию", "System default"))
        popup.lastItem?.representedObject = ""
        for device in state.devices {
            popup.addItem(withTitle: device.name)
            popup.lastItem?.representedObject = device.uid
        }
        if let index = popup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == state.microphoneUID(popupTitles: popup.itemArray)
        }) {
            popup.selectItem(at: index)
        } else {
            popup.selectItem(at: 0)
        }
        popup.target = self
        popup.action = #selector(microphoneChanged(_:))

        for view in [caption, popup] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            caption.widthAnchor.constraint(equalToConstant: 72),
            popup.leadingAnchor.constraint(equalTo: caption.trailingAnchor, constant: 6),
            popup.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            popup.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func recentHeader() -> NSView {
        // Макет: капс 11/600 с трекингом .05em цвета subtle,
        // справа «История» 11/500 акцентом.
        let row = NSView()
        let caption = NSTextField(labelWithString: "")
        caption.attributedStringValue = NSAttributedString(
            string: t("НЕДАВНЕЕ", "RECENT"),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: SD.C.subtle,
                .kern: 0.55,
            ]
        )
        let historyButton = NSButton(title: t("История", "History"),
                                     target: self,
                                     action: #selector(historyClicked))
        historyButton.isBordered = false
        historyButton.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        historyButton.contentTintColor = SD.C.voice

        for view in [caption, historyButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            historyButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -12),
            historyButton.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
        ])
        return row
    }

    func recentRow(_ entry: TranscriptHistoryEntry) -> NSView {
        // Макет: ряд padding 7px 10px, радиус 8; текст 12 ink,
        // мета 10.5 subtle «14:02 · 34 слова»; hover-действия
        // «Скопировать» ink / «Вставить снова» акцент.
        let row = QuickPanelHoverRow()
        row.wantsLayer = true
        row.layer?.cornerRadius = 8
        let text = label(entry.text, size: 12, color: SD.C.ink)
        let words = entry.text.split(whereSeparator: { $0.isWhitespace }).count
        var parts: [String] = []
        if let createdAt = entry.createdAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: state.interfaceLanguage == .russian
                                          ? "ru_RU" : "en_US")
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            parts.append(formatter.string(from: createdAt))
        }
        parts.append(dictatedWordsLabel(words, language: state.interfaceLanguage))
        let meta = label(parts.joined(separator: " · "), size: 10.5, color: SD.C.subtle)

        let copyButton = NSButton(title: t("Скопировать", "Copy"),
                                  target: self, action: #selector(copyRecentClicked(_:)))
        let pasteButton = NSButton(title: t("Вставить снова", "Paste again"),
                                   target: self, action: #selector(pasteRecentClicked(_:)))
        for button in [copyButton, pasteButton] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        }
        copyButton.contentTintColor = SD.C.ink
        pasteButton.contentTintColor = SD.C.voice
        copyButton.cell?.representedObject = entry.text
        pasteButton.cell?.representedObject = entry.text
        row.hoverViews = [copyButton, pasteButton]

        for view in [text, meta, copyButton, pasteButton] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 44),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            text.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            text.topAnchor.constraint(equalTo: row.topAnchor, constant: 7),
            meta.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 10),
            meta.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 2),
            pasteButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            pasteButton.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: pasteButton.leadingAnchor, constant: -10),
            copyButton.centerYAnchor.constraint(equalTo: meta.centerYAnchor),
        ])
        return row
    }

    func emptyRecentRow() -> NSView {
        let row = NSView()
        let text = label(state.historyKeepingEnabled
                            ? t("Пока тихо — первая диктовка появится здесь.",
                                "Quiet so far — your first dictation will show up here.")
                            : t("История выключена: Настройки → Приватность.",
                                "History is off: Settings → Privacy."),
                         size: 11.5, color: .secondaryLabelColor)
        text.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(text)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            text.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            text.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    func statsRow() -> NSView {
        let row = NSView()
        // Слова оцениваются по символам (в хранилище только characterCount).
        let words = approximateWordCount(characters: state.todayCharacters)
        let minutes = state.todayAudioSeconds / 60
        let wpm = minutes > 0.05 ? Int((Double(words) / minutes).rounded()) : 0
        // Экономия ≈ время печати (40 слов/мин) минус время речи.
        let savedMinutes = max(0, Double(words) / 40 - minutes)

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.addArrangedSubview(statCell(value: formattedUsageInteger(words),
                                          caption: t("слов сегодня", "words today")))
        stack.addArrangedSubview(statCell(value: wpm > 0 ? "\(wpm)" : "—",
                                          caption: t("WPM средний", "avg WPM")))
        stack.addArrangedSubview(statCell(value: savedMinutes >= 1
                                              ? "≈\(Int(savedMinutes.rounded())) \(t("мин", "min"))"
                                              : "—",
                                          caption: t("сэкономлено", "saved")))
        let bars = QuickPanelStatBars(values: state.weekBars)

        for view in [stack, bars] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 54),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            stack.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bars.leadingAnchor.constraint(equalTo: stack.trailingAnchor, constant: 10),
            bars.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            bars.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            bars.widthAnchor.constraint(equalToConstant: 40),
            bars.heightAnchor.constraint(equalToConstant: 22),
        ])
        return row
    }

    private func statCell(value: String, caption: String) -> NSView {
        // Макет: значение mono 600 15 ink, подпись 10 subtle.
        let cell = NSStackView()
        cell.orientation = .vertical
        cell.alignment = .leading
        cell.spacing = 1
        cell.addArrangedSubview(label(value, size: 15, weight: .semibold,
                                      color: SD.C.ink, mono: true))
        cell.addArrangedSubview(label(caption, size: 10, color: SD.C.subtle))
        return cell
    }

    func footerRow() -> NSView {
        // Макет: padding 9px 16px, лёгкая подложка (.02 чёрного / .03 белого),
        // «Выйти» — 12/400 graphite.
        let row = QuickPanelFooterView()
        let settingsButton = NSButton(title: t("Настройки…", "Settings…"),
                                      target: self, action: #selector(settingsClicked))
        let historyButton = NSButton(title: t("История", "History"),
                                     target: self, action: #selector(historyClicked))
        let quitButton = NSButton(title: t("Выйти", "Quit"),
                                  target: self, action: #selector(quitClicked))
        for button in [settingsButton, historyButton] {
            button.isBordered = false
            button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
            button.contentTintColor = SD.C.ink
        }
        quitButton.isBordered = false
        quitButton.font = NSFont.systemFont(ofSize: 12)
        quitButton.contentTintColor = SD.C.graphite
        for button in [settingsButton, historyButton, quitButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(button)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 34),
            settingsButton.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            settingsButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            historyButton.leadingAnchor.constraint(equalTo: settingsButton.trailingAnchor, constant: 14),
            historyButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            quitButton.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            quitButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }
}
