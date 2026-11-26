// Вкладка «Текст»: в каком виде придёт сказанное — завершение диктовки,
// очистка от слов-паразитов, словарь замен и переходы в «Службу».

import AppKit

extension DictorControlPanelApp {
    // MARK: Вкладка «Текст» — в каком виде придёт сказанное

    func addTextTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        var insertedRows: [NSView] = []

        let completionPills = SDPills(options: [
            .init(title: t("Ничего", "Nothing"), value: DictationCompletionBehavior.insert.rawValue),
            .init(title: t("Нажать Enter", "Press Enter"),
                  value: DictationCompletionBehavior.insertAndEnter.rawValue),
        ], selected: settings.primaryCompletionBehavior.rawValue)
        completionPills.onSelect = { [weak self] raw in
            guard let self, let behavior = DictationCompletionBehavior(rawValue: raw) else { return }
            self.settings.primaryCompletionBehavior = behavior
            // Черновик обязан узнать о прямой записи: иначе следующая запись
            // хоткея применит черновик со вчерашним значением поверх только
            // что сделанного выбора.
            self.settingsDraft?.primaryCompletionBehavior = behavior
            // Задержка ниже приглушается и оживает вместе с выбором —
            // перерисовываем, иначе строка врёт про своё состояние.
            self.refresh(force: true)
        }
        insertedRows.append(SDRowView(
            title: t("После вставки текста", "After inserting text"),
            subtitle: t("Enter отправляет сообщение в мессенджерах и почте",
                        "Enter sends the message in chat apps and mail"),
            control: completionPills,
            style: .card
        ))

        let delayStepper = SDStepperRow(value: settings.enterDelayMilliseconds,
                                        step: 20,
                                        range: 0...ENTER_DELAY_MAX_MILLISECONDS,
                                        suffix: "ms")
        delayStepper.onChange = { [weak self] value in
            self?.settings.enterDelayMilliseconds = value
            self?.settingsDraft?.enterDelayMilliseconds = value
        }
        // Задержка осмысленна только рядом с Enter. Раньше она стояла в
        // полную силу всегда — настройка, которая ни на что не влияет, но
        // выглядит рабочей, читается как поломка.
        let enterChosen = settings.primaryCompletionBehavior == .insertAndEnter
        let delayRow = SDRowView(
            title: t("Задержка перед Enter", "Delay before Enter"),
            subtitle: enterChosen
                ? t("Пауза между вставкой и подтверждением",
                    "Pause between inserting and confirming")
                : t("Заработает, когда выбрано «Нажать Enter»",
                    "Takes effect once “Press Enter” is chosen"),
            control: delayStepper,
            style: .card
        )
        delayStepper.isEnabled = enterChosen
        delayRow.alphaValue = enterChosen ? 1 : 0.55
        insertedRows.append(delayRow)

        // «After Pasting» из старого меню: что дописать после вставленного
        // текста. Пробел стоит по умолчанию, чтобы следующая диктовка не
        // приклеивалась к предыдущей.
        let suffixPills = SDPills(options: [
            .init(title: t("Пробел", "Space"), value: PasteSuffix.appendSpace.rawValue),
            .init(title: t("Ничего", "Nothing"), value: PasteSuffix.none.rawValue),
            .init(title: t("Новая строка", "New line"), value: PasteSuffix.appendNewline.rawValue),
        ], selected: settings.pasteSuffix.rawValue)
        suffixPills.onSelect = { [weak self] raw in
            guard let suffix = PasteSuffix(rawValue: raw) else { return }
            self?.settings.pasteSuffix = suffix
        }
        insertedRows.append(SDRowView(
            title: t("После текста добавлять", "Append after the text"),
            subtitle: t("Чтобы следующая диктовка не склеилась с этой",
                        "So the next dictation doesn't run into this one"),
            control: suffixPills,
            style: .card
        ))

        // Выключатель обязателен: правило само меняет сказанное, и человек,
        // которому оно мешает в его программе, должен убрать его одним
        // движением, а не терпеть до следующей версии.
        let smartToggle = SDToggle()
        smartToggle.isOn = settings.smartInsertionEnabled
        smartToggle.onToggle = { [weak self] enabled in
            self?.settings.smartInsertionEnabled = enabled
        }
        insertedRows.append(SDRowView(
            title: t("Умная вставка", "Smart insertion"),
            subtitle: t("Продолжение фразы — со строчной и через пробел, "
                        + "реплика в мессенджере — без точки",
                        "A continued sentence starts lowercase after a space, "
                        + "a chat message drops its period"),
            control: smartToggle,
            style: .card
        ))
        root.addArrangedSubview(settingsGroup(t("Когда текст вставлен", "Once the text is in"),
                                              rows: insertedRows))

        addTextCleanupGroup(to: root)
        addTextDictionaryGroup(to: root)
    }


    func hotkeyControl(shortcut: HotkeyChoice, kind: ControlPanelShortcutKind) -> NSView {
        let caps = SDKeycaps(keys: keycapLabels(for: shortcut, language: language))
        let change = NSButton(title: t("Изменить", "Change"),
                              target: self,
                              action: #selector(recordDictationShortcutClicked(_:)))
        change.isBordered = false
        change.font = .systemFont(ofSize: 11)
        change.contentTintColor = SD.C.graphite
        change.tag = kind.rawValue
        let stack = NSStackView(views: [caps, change])
        stack.orientation = .horizontal
        stack.spacing = 11
        return stack
    }

    /// «Чистится само» — встроенные правки, которые применяются без участия
    /// человека. Раньше жили вкладкой «Словарь» вперемешку со своим списком
    /// замен; это тоже вид текста, а не работа со словарём.
    private func addTextCleanupGroup(to root: NSStackView) {
        let fillerToggle = SDToggle()
        fillerToggle.isOn = settings.removeFillerWords
        fillerToggle.onToggle = { [weak self] enabled in
            self?.settings.removeFillerWords = enabled
        }
        let fillerRow = SDRowView(
            title: t("Убирать слова-паразиты", "Remove filler words"),
            subtitle: t("«Эээ», «ммм» и подобное исчезают из текста",
                        "“Uh”, “um” and similar vanish from the text"),
            control: fillerToggle,
            style: .card
        )

        // Тумблеры встроенных наборов живут здесь и только здесь: карточки-
        // дубли в разделе «Словарь» сняты. Два места для одной настройки
        // неизбежно расходятся — сначала подписью, потом поведением.
        let spellingsToggle = SDToggle()
        spellingsToggle.isOn = settings.builtInSpellingsEnabled
        spellingsToggle.onToggle = { [weak self] enabled in
            self?.settings.builtInSpellingsEnabled = enabled
        }
        let spellingsRow = SDRowView(
            title: t("Написание названий", "Name spelling"),
            subtitle: t("\(BuiltInSpellings.count) названий: postgres → PostgreSQL · sql → SQL · macos → macOS",
                        "\(BuiltInSpellings.count) names: postgres → PostgreSQL · sql → SQL · macos → macOS"),
            control: spellingsToggle,
            style: .card
        )

        let latinToggle = SDToggle()
        latinToggle.isOn = settings.latinTermRestorationsEnabled
        latinToggle.onToggle = { [weak self] enabled in
            self?.settings.latinTermRestorationsEnabled = enabled
        }
        let latinRow = SDRowView(
            title: t("Названия латиницей", "Names in Latin script"),
            subtitle: t("\(LatinTermRestorations.count) названий: гитхаб → GitHub · постгрес → PostgreSQL",
                        "\(LatinTermRestorations.count) names: гитхаб → GitHub · постгрес → PostgreSQL"),
            control: latinToggle,
            style: .card
        )

        root.addArrangedSubview(settingsGroup(t("Чистится само", "Cleaned up automatically"),
                                              rows: [fillerRow, spellingsRow, latinRow]))
    }

    /// «Свой словарь» — настройки списка замен и явная дверь в сам список.
    /// Список остался разделом окна: с ним работают долго, как с историей,
    /// и строкой настроек он не притворяется.
    private func addTextDictionaryGroup(to root: NSStackView) {
        let count = settings.transcriptCorrections.count
        let openButton = panelButton(t("Открыть словарь", "Open dictionary"),
                                     action: #selector(openDictionarySectionFromPanel(_:)))
        let listRow = SDRowView(
            title: t("Список автозамен", "Correction list"),
            subtitle: count == 0
                ? t("Пока пусто — сам список живёт в разделе «Словарь»",
                    "Empty so far — the list itself lives in the Dictionary section")
                : t("\(count) \(pluralizeRU(count, "своя замена", "свои замены", "своих замен")) · сам список живёт в разделе «Словарь»",
                    "\(count) own \(count == 1 ? "replacement" : "replacements") · the list itself lives in the Dictionary section"),
            control: openButton,
            style: .card
        )

        // Синхронизация и перенос жили только в старом меню по правому клику —
        // то есть их не существовало ни для кого, кто в это меню не заглядывал.
        let syncPath = settings.transcriptCorrectionsSyncFile
        let syncRow: SDRowView
        if syncPath.isEmpty {
            syncRow = SDRowView(
                title: t("Синхронизация файлом", "Sync through a file"),
                subtitle: t("Файл в iCloud Drive или Dropbox держит словарь общим "
                            + "для нескольких Mac",
                            "A file in iCloud Drive or Dropbox keeps the dictionary "
                            + "shared between Macs"),
                control: panelButton(t("Настроить…", "Set up…"),
                                     action: #selector(setUpDictionarySyncFromPanel(_:))),
                style: .card
            )
        } else {
            syncRow = SDRowView(
                title: t("Синхронизация файлом", "Sync through a file"),
                subtitle: (syncPath as NSString).abbreviatingWithTildeInPath,
                control: panelButton(t("Отключить…", "Disconnect…"),
                                     action: #selector(stopDictionarySyncFromPanel(_:))),
                style: .card
            )
        }

        let transferButtons = NSStackView(views: [
            panelButton(t("Импорт…", "Import…"),
                        action: #selector(importDictionaryFromPanel(_:))),
            panelButton(t("Экспорт…", "Export…"),
                        action: #selector(exportDictionaryFromPanel(_:))),
        ])
        transferButtons.orientation = .horizontal
        transferButtons.spacing = 8
        let transferRow = SDRowView(
            title: t("Перенос словаря", "Move the dictionary"),
            subtitle: t("Файлом — на другой Mac или в резерв",
                        "As a file — to another Mac or to a backup"),
            control: transferButtons,
            style: .card
        )

        // Встроенные наборы названий собраны по диктовкам одного человека.
        // Чужой словарь — готовый список слов, на которых модель ошибается у
        // других, и узнать о них больше неоткуда: приложение о себе молчит.
        let shareRow = SDRowView(
            title: t("Поделиться словарём", "Share the dictionary"),
            subtitle: count == 0
                ? t("Пока нечем — словарь пуст",
                    "Nothing to share yet — the dictionary is empty")
                : t("Откроет письмо автору с файлом словаря: так встроенный набор "
                    + "пополняется словами, на которых модель ошибается. "
                    + "Ничего не уходит без вашего «Отправить»",
                    "Opens an email to the author with the dictionary file: that is how "
                    + "the built-in set learns the words the model gets wrong. "
                    + "Nothing leaves until you press Send"),
            control: panelButton(t("Открыть письмо…", "Open email…"),
                                 action: #selector(shareDictionaryFromPanel(_:)),
                                 enabled: count > 0),
            style: .card
        )

        root.addArrangedSubview(settingsGroup(t("Свой словарь", "Your dictionary"),
                                              rows: [listRow, syncRow, transferRow, shareRow]))
    }

    @objc private func shareDictionaryFromPanel(_ sender: NSButton) {
        DictionaryShare.share(corrections: settings.transcriptCorrections,
                              anchor: sender,
                              language: settings.interfaceLanguage)
    }

    @objc private func openDictionarySectionFromPanel(_ sender: NSButton) {
        mainSection = .dictionary
        refresh(force: true)
    }

    /// Диплинк во вкладку «Служба» — из «Приложения», из подвала сайдбара и
    /// из баннера «текст не вставился». Состояние прячется за кликом, поэтому
    /// каждое место, где человек упирается в неработающую диктовку, обязано
    /// вести прямо сюда, а не «в настройки, там разберётесь».
    func openServiceTab() {
        mainSection = .settings
        settingsTab = "service"
        hotkeyNotice = nil
        refresh(force: true)
    }

    @objc func openServiceSectionFromPanel(_ sender: NSButton) {
        openServiceTab()
    }

    @objc func reportProblemFromPanel(_ sender: NSButton) {
        ProblemReport.share(diagnostics: panelDiagnosticsText(),
                            anchor: sender,
                            language: settings.interfaceLanguage)
    }

    /// Окно — отдельный процесс, полного отчёта службы у него нет. Зато есть
    /// то, что служба публикует на диск, и настройки, которые к сбою
    /// относятся чаще всего: капсула, режим клавиши, приглушение.
    private func panelDiagnosticsText() -> String {
        var lines = [
            "Dictor diagnostics (control panel)",
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "App version: \(currentBundleVersion()) (\(currentBundleBuild()))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "",
            "Service:",
        ]
        if let state = AgentRuntimeStateStore.read() {
            lines += [
                "- Status: \(state.status) — \(state.detail)",
                "- Ready: \(state.isReady), recording: \(state.isRecording), transcribing: \(state.isTranscribing)",
                "- Speech model ready: \(state.speechModelReady)",
                "- Missing permissions: \(state.missingPermissions.isEmpty ? "none" : state.missingPermissions.joined(separator: ", "))",
                "- Hotkey: \(state.hotkeyName), trigger: \(state.triggerMode)",
            ]
            if let reason = state.failureReason {
                lines.append("- Failure reason: \(reason)")
            }
        } else {
            lines.append("- State file unavailable (service not running?)")
        }
        lines.append(inputDevicesDiagnosticsLine(availableAudioInputDevices()))
        lines += [
            "",
            "Settings:",
            "- Capsule size: \(settings.recordingHUDSize.rawValue)",
            "- Show capsule: \(settings.showRecordingWaveform)",
            "- Trigger mode: \(settings.triggerMode.rawValue)",
            "- Mute while recording: \(settings.muteWhileRecording)",
            "- Interface language: \(settings.interfaceLanguage.rawValue)",
            "",
            "Crash reports (~/Library/Logs/DiagnosticReports):",
        ]
        let crashLines = crashReportSummaryLines(
            fileNames: dictorCrashReportURLs().map(\.lastPathComponent))
        lines += crashLines.isEmpty ? ["- None found"] : crashLines.map { "- \($0)" }
        lines.append("")
        lines.append("Privacy: transcript text and text-correction contents are not included.")
        return lines.joined(separator: "\n")
    }

    /// Автозапуск диктовки. Включение поднимает службу сразу — ждать входа в
    /// систему, чтобы проверить, что тумблер сработал, никто не станет.
    /// Выключение только снимает автозапуск: живую службу не трогаем, иначе
    /// строка под заголовком «При входе в систему» делала бы вторую вещь
    /// молча — ту самую путаницу, ради которой её и разделили.
    func setDictationAutostart(_ enabled: Bool) {
        settings.agentEnabled = enabled
        _ = settings.refreshFromDisk()
        if enabled {
            beginServiceOperation(.starting)
        } else {
            DictorAgentService.disableAutostart()
            refresh(force: true)
        }
    }
}
