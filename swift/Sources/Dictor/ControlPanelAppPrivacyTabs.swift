import AppKit
import ServiceManagement

extension DictorControlPanelApp {
    // MARK: Вкладка «Приложение» — про сам продукт, а не про диктовку

    func addAppTabRows(to root: NSStackView) {
        // Язык интерфейса включался только через defaults write — английский
        // интерфейс существовал целиком и был недостижим.
        let interfacePills = SDPills(options: [
            .init(title: "Русский", value: InterfaceLanguage.russian.rawValue),
            .init(title: "English", value: InterfaceLanguage.english.rawValue),
        ], selected: settings.interfaceLanguage.rawValue)
        interfacePills.onSelect = { [weak self] raw in
            guard let self, let chosen = InterfaceLanguage(rawValue: raw) else { return }
            self.settings.interfaceLanguage = chosen
            self.refresh(force: true)
        }
        root.addArrangedSubview(settingsGroup(nil, rows: [SDRowView(
            title: t("Язык интерфейса", "Interface language"),
            subtitle: t("Языки диктовки от этого не зависят — они в «Диктовке»",
                        "Dictation languages are separate — they live in Dictation"),
            control: interfacePills,
            style: .card
        )]))

        // Две разные вещи, которые носили одну подпись: автозапуск службы и
        // логин-айтем окна (аудит №16). Тумблер службы значил вдобавок третье
        // — «включена сейчас»; это состояние, и оно уехало в панель меню-бара.
        let autostartToggle = SDToggle()
        autostartToggle.isOn = settings.agentEnabled
        autostartToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            self.setDictationAutostart(enabled)
        }
        let autostartRow = SDRowView(
            title: t("Запускать диктовку в фоне", "Start dictation in the background"),
            subtitle: t("Служба поднимается вместе с системой и слушает хоткей — без окон",
                        "The service comes up with the system and listens for the hotkey — no windows"),
            control: autostartToggle,
            style: .card
        )

        let loginItemStatus = loginItemStatus()
        let loginToggle = SDToggle()
        loginToggle.isOn = loginItemStatus == .enabled || loginItemStatus == .requiresApproval
        loginToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    log("panel login item enabled")
                } else {
                    try SMAppService.mainApp.unregister()
                    log("panel login item disabled")
                }
            } catch {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = self.t("Не удалось изменить объект входа",
                                           "Login item couldn't be changed")
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            // Только что изменённое обязано быть видно сразу, а не через
            // срок годности прошлого ответа.
            self.loginItemStatusReading = nil
            self.refresh(force: true)
        }
        let loginSubtitle = loginItemStatus == .requiresApproval
            ? t("Ждёт одобрения: Системные настройки → Основные → Объекты входа",
                "Waiting for approval: System Settings → General → Login Items")
            : t("Только окно. Диктовка работает и без него",
                "The window only. Dictation works without it")
        let loginRow = SDRowView(
            title: t("Открывать это окно", "Open this window"),
            subtitle: loginSubtitle,
            control: loginToggle,
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("При входе в систему", "At login"),
                                              rows: [autostartRow, loginRow]))
        root.addArrangedSubview(settingsFootnote(
            t("Здесь только автозапуск. Приостановить диктовку прямо сейчас — тумблером в панели меню-бара: служба остаётся на месте, хоткей молчит.",
              "Autostart only. To pause dictation right now use the toggle in the menu-bar panel: the service stays, the hotkey goes quiet.")))

        // Выключить автопроверку было можно и раньше — но только через меню по
        // правому клику на иконке в строке меню. Первый же человек со стороны
        // попросил «чтобы проверку обновлений можно было убрать»: настройка,
        // которую нельзя найти там, где её ищут, всё равно что отсутствует.
        let updatesToggle = SDToggle()
        updatesToggle.isOn = settings.checkForUpdates
        updatesToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            self.settings.checkForUpdates = enabled
            log("update checks \(enabled ? "enabled" : "disabled") from settings")
            self.refresh(force: true)
        }
        let updatesRow = SDRowView(
            title: t("Проверять обновления", "Check for updates"),
            subtitle: t("Раз в 6 часов приложение спрашивает номер последней версии. "
                        + "Это единственный сетевой запрос — он же виден в «Приватности»",
                        "Every 6 hours the app asks for the latest version number. "
                        + "It is the only network request — Privacy shows the same one"),
            control: updatesToggle,
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("Обновления", "Updates"),
                                              rows: [updatesRow, versionRow()]))

        // Состояние службы вкладкой не является: переключать там нечего.
        // Дверь оставляем здесь, где человек ищет «а где всё остальное».
        // Кнопка «пожаловаться» живёт рядом с диагностикой: человек, у
        // которого что-то сломалось, ищет её именно здесь, а не в меню-баре.
        root.addArrangedSubview(settingsGroup(nil, rows: [SDRowView(
            title: t("Разрешения, модель, измерения и диагностика",
                     "Permissions, model, measurements and diagnostics"),
            subtitle: t("Это состояние, а не настройки — они в разделе «Служба»",
                        "That is state, not preferences — it lives in the Service section"),
            control: panelButton(t("Открыть «Службу»", "Open Service"),
                                 action: #selector(openServiceSectionFromPanel(_:))),
            style: .card
        ), SDRowView(
            title: t("Сообщить о проблеме", "Report a problem"),
            subtitle: t("Соберёт журнал и отчёты о сбоях в архив и откроет письмо. "
                        + "Ничего не уходит без вашего «Отправить»",
                        "Packs the log and crash reports into an archive and opens an email. "
                        + "Nothing leaves until you press Send"),
            control: panelButton(t("Собрать архив…", "Build archive…"),
                                 action: #selector(reportProblemFromPanel(_:))),
            style: .card
        )]))
    }



    // MARK: Вкладка «Приватность» — что уходит с этого Mac

    func addPrivacyTabRows(to root: NSStackView) {
        // Витрина: волна + главное обещание продукта.
        let wave = QuickPanelWaveView()
        wave.isActive = true
        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.widthAnchor.constraint(equalToConstant: 60).isActive = true
        wave.heightAnchor.constraint(equalToConstant: 20).isActive = true
        let headline = panelLabel(t("Ваш голос не покидает этот Mac",
                                    "Your voice never leaves this Mac"),
                                  size: 15, weight: .bold)
        // «Интернет нужен один раз» перестало быть правдой, когда включился
        // канал обновлений: раз в 6 часов приложение спрашивает версию.
        // Строка ниже говорит, сколько это запросов и за чем именно.
        let sub = panelLabel(
            t("Речь распознаётся моделью на этом компьютере. Ни звук, ни расшифровка никуда не отправляются.",
              "Speech is transcribed by a model on this computer. Neither the audio nor the transcript is sent anywhere."),
            size: 12, color: SD.C.graphite)
        sub.maximumNumberOfLines = 2
        sub.alignment = .center
        sub.preferredMaxLayoutWidth = 420
        let showcase = NSStackView(views: [wave, headline, sub])
        showcase.orientation = .vertical
        showcase.alignment = .centerX
        showcase.spacing = 8
        showcase.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 4, right: 0)
        root.addArrangedSubview(showcase)

        // Раньше здесь стоял один переключатель «Выкл / 1 / 5 / 10» с
        // подписью «Хранить историю», и он врал: цифры никогда не были
        // объёмом хранилища — архив держит до 10 000 диктовок, а 1/5/10
        // ограничивают только список в меню-баре. Во вкладке про
        // приватность это худший из возможных обманов, поэтому теперь
        // две отдельные строки, каждая про своё.
        let historyToggle = SDToggle()
        historyToggle.isOn = settings.recentTranscriptLimit != .off
        historyToggle.onToggle = { [weak self] isOn in
            guard let self else { return }
            self.settings.recentTranscriptLimit = isOn ? self.settings.preferredRecentTranscriptLimit : .off
            self.refresh(force: true)
        }
        // Подпись обещала «стереть» — а выключение только останавливает
        // запись новых текстов; стирает кнопка ниже. И «больше не
        // записывать» неточно в другую сторону: обезличенные счётчики
        // статистики считаются в любом случае.
        var diskRows: [NSView] = [SDRowView(
            title: t("Хранить историю диктовок", "Keep dictation history"),
            subtitle: t("Локально, до \(groupedNumberLabel(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES, language: .russian)) записей. Выключение останавливает запись текстов; счётчики статистики считаются в любом случае",
                        "Locally, up to \(groupedNumberLabel(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES, language: .english)) entries. Switching off stops recording texts; statistics counters keep running either way"),
            control: historyToggle,
            style: .card
        )]

        if settings.recentTranscriptLimit != .off {
            let menuLimits: [RecentTranscriptLimit] = [.last1, .last5, .last10]
            let limitPills = SDPills(options: menuLimits.map {
                .init(title: $0.rawValue, value: $0.rawValue)
            }, selected: settings.recentTranscriptLimit.rawValue)
            limitPills.onSelect = { [weak self] raw in
                guard let limit = RecentTranscriptLimit(rawValue: raw) else { return }
                self?.settings.recentTranscriptLimit = limit
            }
            diskRows.append(SDRowView(
                title: t("Недавнее в панели меню-бара", "Recent list in the menu-bar panel"),
                subtitle: t("Длина списка по клику на иконку. Окно «История» показывает все",
                            "How long the list is when you click the icon. The History window shows all of them"),
                control: limitPills,
                style: .card
            ))
        }

        let showModels = NSButton(title: t("Показать файлы моделей…", "Show model files…"),
                                  target: self, action: #selector(revealModelFilesFromPanel(_:)))
        let wipeHistory = NSButton(title: t("Стереть историю…", "Erase history…"),
                                   target: self, action: #selector(eraseHistoryFromPanel(_:)))
        for button in [showModels, wipeHistory] {
            button.isBordered = false
            button.font = .systemFont(ofSize: 12, weight: .semibold)
        }
        showModels.contentTintColor = SD.C.ink
        wipeHistory.contentTintColor = SD.C.voice
        let actions = NSStackView(views: [showModels, wipeHistory])
        actions.orientation = .horizontal
        actions.spacing = 16
        diskRows.append(SDRowView(title: t("Файлы на диске", "Files on disk"),
                                  control: actions,
                                  style: .card))

        root.addArrangedSubview(settingsGroup(t("Что хранится на диске", "What is kept on disk"),
                                              rows: diskRows))

        // Факты — не переключатели. Раньше они стояли строками вперемешку с
        // тумблерами и выглядели одинаково; здесь у них своя приглушённая
        // карточка без правого столбца управления, и видно, что это ответы.
        // Значение сетевых запросов было зашито как «0 — обновления
        // отключены»: пока проверка стояла за мёртвым `return`, это была
        // правда, а с включённым каналом стало бы враньём ровно в той
        // вкладке, где человек решает, насколько приложению верить.
        let networkFact = privacyFactRow(
            title: t("Сетевые запросы", "Network requests"),
            subtitle: settings.checkForUpdates
                ? t("Единственный. Отключается в «Приложение» → Обновления",
                    "The only one. Switched off in App → Updates")
                : t("Автопроверка выключена — приложение само в сеть не ходит",
                    "Automatic checks are off — the app does not go online on its own"),
            value: settings.checkForUpdates
                ? t("1 раз в 6 ч", "once every 6 h")
                : t("нет", "none"))
        // Записи для диагностики включаются только вручную, но факт обязан
        // сказать правду и тогда.
        let keptSamples = DiagnosticAudioSamples.keptCount()
        let audioFact = privacyFactRow(
            title: t("Аудио после распознавания", "Audio after transcription"),
            subtitle: keptSamples > 0
                ? t("Включены записи для диагностики: последние \(keptSamples) лежат в Application Support/Dictor/AudioSamples",
                    "Diagnostic recordings are on: the latest \(keptSamples) are kept in Application Support/Dictor/AudioSamples")
                : t("На время обработки на диске живёт страховочный журнал. При сбое он остаётся, чтобы вернуть диктовку в историю",
                        "A crash-recovery journal lives on disk while a dictation is handled. After a failure it stays so the dictation can be recovered"),
            value: keptSamples > 0 ? t("хранятся", "kept") : t("удаляется", "deleted"))
        let notificationsFact = privacyFactRow(
            title: t("Системные уведомления", "System notifications"),
            subtitle: t("Приложение не показывает баннеров — ни разу, ни при ошибке",
                        "The app shows no banners — not once, not even on failure"),
            value: t("не отправляются", "never sent"))

        // Умная вставка заглядывает в чужое поле — это надо сказать там, где
        // человек решает, насколько приложению верить, а не только в файле
        // PRIVACY.md. Число знаков берётся из кода: разойтись они не могут.
        let caretFact = privacyFactRow(
            title: t("Текст перед курсором", "Text before the cursor"),
            subtitle: settings.smartInsertionEnabled
                ? t("Умная вставка смотрит на последние \(InsertionContextReader.tailUTF16Length) знаков перед курсором, чтобы понять, продолжается ли фраза. Они не сохраняются и не пишутся в журнал; поля с паролем не читаются",
                    "Smart insertion looks at the last \(InsertionContextReader.tailUTF16Length) characters before the cursor to tell whether a sentence continues. They are neither stored nor logged; password fields are not read")
                : t("Умная вставка выключена — содержимое полей приложение не читает",
                    "Smart insertion is off — the app does not read what is in the field"),
            value: settings.smartInsertionEnabled
                ? t("только в памяти", "in memory only")
                : t("не читается", "not read"))

        let factsCard = SDFactCard(rows: [networkFact, audioFact, caretFact, notificationsFact])
        let factsGroup = NSStackView(views: [
            serviceGroupHeader(t("Факты, а не переключатели", "Facts, not switches")),
            factsCard,
        ])
        factsGroup.orientation = .vertical
        factsGroup.alignment = .leading
        factsGroup.spacing = 7
        for view in factsGroup.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: factsGroup.widthAnchor).isActive = true
        }
        root.addArrangedSubview(factsGroup)
    }

    /// Строка-факт: слева вопрос, справа ответ. Контрола нет намеренно —
    /// это утверждение о поведении программы, а не то, что можно изменить.
    private func privacyFactRow(title: String, subtitle: String, value: String) -> NSView {
        SDRowView(title: title,
                  subtitle: subtitle,
                  control: panelLabel(value, size: 12, weight: .medium, color: SD.C.graphite),
                  style: .card)
    }

    func monoValueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = SD.C.ink
        return label
    }

    @objc private func revealModelFilesFromPanel(_ sender: NSButton) {
        NSWorkspace.shared.activateFileViewerSelecting([speechModelCacheBaseDirectory()])
    }

    @objc private func eraseHistoryFromPanel(_ sender: NSButton) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Стереть всю историю диктовок?", "Erase all dictation history?")
        alert.informativeText = t("Действие необратимо: сотрутся и закреплённые. Модель и настройки не затрагиваются.",
                                  "This cannot be undone; pinned dictations are erased too. The model and settings stay intact.")
        alert.addButton(withTitle: t("Отмена", "Cancel"))
        alert.addButton(withTitle: t("Стереть", "Erase"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        settings.recentTranscriptEntries = []
        // Пины — полные тексты диктовок в том же plist; «стереть всю
        // историю», оставив их, было бы обратимым ровно наполовину.
        settings.pinnedTranscripts = []
        refresh(force: true)
    }
}
