import AppKit

extension DictorControlPanelApp {
    func makeSettingsContentView() -> NSView {
        let draft = settingsDraft ?? ControlPanelSettingsDraft(settings: settings)
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        // Таб-бар лежит на своей полосе во всю ширину, поэтому боковых
        // отступов у корня нет: их держит стек содержимого.
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = false

        root.addArrangedSubview(settingsTabBar())

        // Содержимое вкладки — стопка групп, а не строк: между группами
        // 18 pt, внутри группы строки лежат вплотную под общей крышей.
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 18
        content.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        content.translatesAutoresizingMaskIntoConstraints = false
        switch settingsTab {
        case "text":
            addTextTabRows(to: content, draft: draft)
        case "look":
            addLookTabRows(to: content, draft: draft)
        case "privacy":
            addPrivacyTabRows(to: content)
        case "app":
            addAppTabRows(to: content)
        case "service":
            addServiceTabRows(to: content)
        default:
            addDictationTabRows(to: content, draft: draft)
        }
        root.addArrangedSubview(content)

        let background = PaperBackgroundView()
        background.fill = SD.C.settingsPaper
        background.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(lessThanOrEqualTo: background.bottomAnchor),
        ])

        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        let contentInset = -(content.edgeInsets.left + content.edgeInsets.right)
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor,
                                        constant: contentInset).isActive = true
        }
        return background
    }

    /// Высота окна под контент вкладки, как в макете (min-height 330 у
    /// контентной зоны). Меньше не сжимаем, чтобы окно не «прыгало».
    static func settingsContentHeight(for view: NSView, width: CGFloat = 620) -> CGFloat {
        guard let root = view.subviews.first as? NSStackView else { return 404 }
        // Фиксируем ширину, чтобы fittingSize мерил высоту при реальной
        // ширине окна (многострочные подписи).
        let widthPin = root.widthAnchor.constraint(equalToConstant: width)
        widthPin.isActive = true
        // Переносимая подпись узнаёт свою ширину в layout() — из фрейма
        // контрола, а не из констрейнтов. Пока у контейнера нет фрейма,
        // фреймы детей нулевые, перенос не случается, и высота считается по
        // однострочной подписи: вторая строка потом налезала на разделитель.
        // Поэтому сначала даём заведомо просторный фрейм, раскладываемся —
        // и только потом меряем. Крутим до устойчивой высоты: перенос одной
        // строки может сдвинуть соседнюю.
        let probeHeight = MAIN_WINDOW_SIZE.height * 3
        view.frame = NSRect(x: 0, y: 0, width: width, height: probeHeight)
        // Проходов именно несколько, и выйти по «высота не изменилась» нельзя:
        // перенос проявляется только на третьем. Первый даёт строке фрейм,
        // второй в layout() выставляет ширину переноса, и лишь третий видит
        // двухстрочную подпись. Ранний выход по совпадению первых двух
        // замеров возвращал высоту на строку меньше — и стек, у которого
        // строка сжимаема, съедал у неё нижний отступ: подпись налезала на
        // разделитель.
        for _ in 0..<4 {
            view.layoutSubtreeIfNeeded()
            _ = root.fittingSize
        }
        view.layoutSubtreeIfNeeded()
        let fitting = root.fittingSize.height
        widthPin.isActive = false
        return max(404, ceil(fitting))
    }

    // MARK: - Вкладки настроек (дизайн 2c, адаптировано)

    private func settingsTabBar() -> NSView {
        // Полоса вкладок — своя поверхность с линией снизу: пять вкладок
        // прижаты к левому краю, как строки под ними, а не парят по центру.
        let wrapper = PaperBackgroundView()
        wrapper.fill = SD.C.listPaper
        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 2
        // Макет: таб 27 pt высотой, padding 0 11px, радиус 7, шрифт 12.5;
        // активный — 600 ink на белой карточке с мягкой тенью, неактивный —
        // 500 graphite без подложки. Отступ 11, а не 13: шесть вкладок
        // должны уместиться в 767 pt и по-русски, и по-английски.
        let updateAvailable: Bool
        if case .available = updateState { updateAvailable = true } else { updateAvailable = false }
        for tab in SETTINGS_TABS {
            let (id, title) = (tab.id, tab.title(language))
            let button = SDTabButton(title: title, target: self,
                                     action: #selector(settingsTabClicked(_:)))
            button.isBordered = false
            button.isActiveTab = settingsTab == id
            // Обновление — единственная новость, которую человек иначе не
            // заметит: версия лежит внутри вкладки, а не на виду.
            button.showsBadge = id == "app" && updateAvailable
            button.identifier = NSUserInterfaceItemIdentifier(id)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 27).isActive = true
            let textWidth = ceil(title.size(withAttributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold)
            ]).width)
            let badgeWidth = button.showsBadge
                ? SDTabButton.badgeSize + SDTabButton.badgeGap
                : 0
            button.widthAnchor.constraint(equalToConstant: textWidth + 22 + badgeWidth)
                .isActive = true
            bar.addArrangedSubview(button)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false
        let hairline = SDHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(bar)
        wrapper.addSubview(hairline)
        NSLayoutConstraint.activate([
            // Ровно та же высота, что у верхней полосы сайдбара: вкладки —
            // первое, что есть в панели, и встают вровень с кнопками окна.
            wrapper.heightAnchor.constraint(equalToConstant: MAIN_WINDOW_HEADER_HEIGHT),
            bar.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 16),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor,
                                          constant: -16),
            bar.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            hairline.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            hairline.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrapper
    }

    @objc private func settingsTabClicked(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        hotkeyNotice = nil
        settingsTab = id
        refresh(force: true)
    }

    // MARK: - Раздел «Настройки» (макет 2c/4b/6d внутри окна 6a)

    /// Настройки — такой же раздел окна, как «Сегодня» и «История».
    /// Отдельного окна больше нет: в макете 6a это пункт сайдбара.
    /// Шапки с названием раздела здесь нет намеренно. Слово «Настройки» уже
    /// подсвечено в сайдбаре в тридцати пунктах левее, а содержимое называет
    /// полоса вкладок — заголовок между ними был чистым повтором и съедал
    /// 52 pt высоты у вкладок, которые и так длиннее экрана. У остальных
    /// разделов шапка остаётся: у «Словаря» она несёт кнопку «Добавить», а
    /// «Службе», «Истории» и «Статистике» больше нечем назвать экран.
    func makeSettingsSectionView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper

        let content = makeSettingsContentView()
        content.translatesAutoresizingMaskIntoConstraints = false
        let paneWidth = MAIN_WINDOW_SIZE.width - MAIN_WINDOW_SIDEBAR_WIDTH - 1
        let contentHeight = Self.settingsContentHeight(for: content, width: paneWidth)

        let documentView = SDFlippedView()
        documentView.addSubview(content)
        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: documentView.topAnchor),
            content.heightAnchor.constraint(equalToConstant: contentHeight),
            documentView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
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

        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    @objc func recordDictationShortcutClicked(_ sender: NSButton) {
        guard serviceOperation == nil,
              let kind = ControlPanelShortcutKind(rawValue: sender.tag) else { return }
        if let hotkeyRecorder {
            hotkeyRecorder.present(relativeTo: window)
            return
        }
        let state = AgentRuntimeStateStore.read()
        if state?.isRecording == true || state?.isTranscribing == true {
            showError(
                title: t("Сначала завершите диктовку", "Finish Dictation First"),
                detail: t("Сочетание нельзя менять во время записи или распознавания.",
                          "Shortcuts cannot be changed while recording or transcribing.")
            )
            return
        }
        if DictorAgentService.isAgentRunning(), state?.isReady != true {
            showError(
                title: t("Служба ещё запускается", "Service Is Still Starting"),
                detail: t("Дождитесь статуса «Работает» и попробуйте изменить сочетание ещё раз.",
                          "Wait for the Running status, then try changing the shortcut again.")
            )
            return
        }

        DistributedNotificationCenter.default().postNotificationName(
            HOTKEY_CAPTURE_BEGIN_NOTIFICATION,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        let recorderTitle: String
        switch kind {
        case .dictation:
            recorderTitle = t("Новое сочетание для диктовки", "New Dictation Shortcut")
        case .alternateCompletion:
            recorderTitle = t("Дополнительное сочетание завершения", "Alternative Finish Shortcut")
        }
        let recorder = HotkeyRecorderController(language: language,
                                                titleOverride: recorderTitle) { [weak self] selected in
            DistributedNotificationCenter.default().postNotificationName(
                HOTKEY_CAPTURE_END_NOTIFICATION,
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            guard let self else { return }
            self.hotkeyRecorder = nil
            guard let selected else { return }
            var draft = self.settingsDraft ?? ControlPanelSettingsDraft(settings: self.settings)
            switch kind {
            case .dictation: draft.dictationHotkey = selected
            case .alternateCompletion: draft.alternateCompletionHotkey = selected
            }
            self.settingsDraft = draft
            // Если записали ровно то, что уже стояло, менять нечего —
            // но молчать об этом нельзя.
            let unchanged = draft == ControlPanelSettingsDraft(settings: self.settings)
            self.hotkeyNotice = unchanged
                ? self.t("Это сочетание уже стояло — \(selected.name). Ничего не изменилось.",
                         "That combination was already set — \(selected.name). Nothing changed.")
                : self.t("Новое сочетание: \(selected.name).",
                         "New combination: \(selected.name).")
            self.refreshSettingsWindow()
            // Записанное сочетание применяется сразу: агент подхватывает
            // хоткей только при старте, поэтому служба перезапускается сама.
            if !unchanged {
                self.scheduleSettingsApply(after: 0.15)
            }
        }
        hotkeyRecorder = recorder
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self, weak recorder] in
            guard self?.hotkeyRecorder === recorder else { return }
            recorder?.present(relativeTo: self?.window)
        }
    }

    /// Настройки применяются сами — кнопки «Сохранить» в макете нет.
    /// Хоткей агент читает только при старте, поэтому применение тянет за
    /// собой перезапуск службы; задержка нужна, чтобы щелчки по степперу
    /// не перезапускали её на каждый клик.
    func scheduleSettingsApply(after delay: TimeInterval) {
        pendingSettingsApply?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.applySettingsDraft()
        }
        pendingSettingsApply = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func settingsValidationMessage(_ draft: ControlPanelSettingsDraft) -> String? {
        let shortcuts = draft.alternateCompletionEnabled
            ? [draft.dictationHotkey, draft.alternateCompletionHotkey]
            : [draft.dictationHotkey]
        for firstIndex in shortcuts.indices {
            for secondIndex in shortcuts.indices where secondIndex > firstIndex {
                let first = shortcuts[firstIndex]
                let second = shortcuts[secondIndex]
                if hotkeysConflict(first, second) {
                    return t("Сочетания для диктовки и завершения должны отличаться.",
                             "Dictation and finish shortcuts must be different.")
                }
                if hotkeyIsModifierPrefix(first, of: second)
                    || hotkeyIsModifierPrefix(second, of: first) {
                    return t("Одна активная комбинация не должна быть частью другой.",
                             "One active shortcut cannot be a prefix of another.")
                }
            }
        }
        return nil
    }

    private func applySettingsDraft() {
        pendingSettingsApply = nil
        guard let draft = settingsDraft,
              settingsValidationMessage(draft) == nil,
              draft != ControlPanelSettingsDraft(settings: settings) else { return }
        applySettings(draft)
    }

    private func applySettings(_ draft: ControlPanelSettingsDraft) {
        settings.setConfiguredHotkey(draft.dictationHotkey)
        settings.setConfiguredEnterHotkey(draft.alternateCompletionHotkey)
        settings.primaryCompletionBehavior = draft.primaryCompletionBehavior
        settings.alternateCompletionEnabled = draft.alternateCompletionEnabled
        settings.enterDelayMilliseconds = draft.enterDelayMilliseconds
        settings.recordingHUDRecordingColor = draft.recordingColor
        settings.recordingHUDBackgroundStyle = draft.backgroundStyle
        settings.recordingHUDSize = draft.hudSize
        _ = settings.refreshFromDisk()
        settingsDraft = ControlPanelSettingsDraft(settings: settings)
        // Служба перечитывает хоткеи сама раз в секунду, так что перезапуск
        // нужен только когда её вообще нет. И только если человек её не
        // останавливал: остановленная тумблером служба не должна воскресать
        // от записи хоткея — новое сочетание она прочтёт при запуске.
        if settings.agentEnabled, !DictorAgentService.isAgentRunning() {
            beginServiceOperation(.starting)
        } else {
            refresh(force: true)
        }
    }

    private func refreshSettingsWindow() {
        refresh(force: true)
    }
}
