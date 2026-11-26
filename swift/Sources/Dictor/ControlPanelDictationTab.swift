import AppKit

extension DictorControlPanelApp {
    // MARK: Вкладка «Диктовка» — всё, что происходит до текста

    func addDictationTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        let missingPermissions = Permission.allCases.filter { !Permissions.isGranted($0) }
        if !missingPermissions.isEmpty {
            root.addArrangedSubview(compactPermissionsCard())
        }

        var startRows: [NSView] = [
            SDRowView(
                title: t("Начать и остановить диктовку", "Start and stop dictation"),
                subtitle: t("Работает в любом приложении, пока служба включена",
                            "Works in any app while the service is running"),
                control: hotkeyControl(shortcut: draft.dictationHotkey, kind: .dictation),
                style: .card
            ),
        ]

        // Режим клавиши жил только в старом меню («Trigger») — по-английски и
        // не там, где настраивают саму клавишу.
        let triggerPills = SDPills(options: [
            .init(title: t("Удерживать", "Hold"), value: TriggerMode.hold.rawValue),
            .init(title: t("Переключать", "Toggle"), value: TriggerMode.toggle.rawValue),
        ], selected: settings.triggerMode.rawValue)
        triggerPills.onSelect = { [weak self] raw in
            guard let mode = TriggerMode(rawValue: raw) else { return }
            self?.settings.triggerMode = mode
        }
        startRows.append(SDRowView(
            title: t("Режим клавиши", "Key behavior"),
            subtitle: t("Удерживать — запись, пока клавиша зажата. Переключать — "
                        + "нажатие включает, следующее выключает",
                        "Hold records while the key is down. Toggle starts on one "
                        + "press and stops on the next"),
            control: triggerPills,
            style: .card
        ))

        // Тумблер существовал только как ключ в настройках: выключить
        // альтернативное завершение из интерфейса было нельзя вовсе.
        let altToggle = SDToggle()
        altToggle.isOn = draft.alternateCompletionEnabled
        altToggle.onToggle = { [weak self] enabled in
            guard let self else { return }
            var draft = self.settingsDraft ?? ControlPanelSettingsDraft(settings: self.settings)
            draft.alternateCompletionEnabled = enabled
            self.settingsDraft = draft
            self.hotkeyNotice = self.settingsValidationMessage(draft)
            self.scheduleSettingsApply(after: 0.15)
            self.refresh(force: true)
        }
        startRows.append(SDRowView(
            title: t("Отдельное сочетание для завершения", "Separate finish shortcut"),
            subtitle: t("Второе сочетание завершает диктовку противоположным действием",
                        "A second shortcut finishes dictation with the opposite action"),
            control: altToggle,
            style: .card
        ))
        // Сочетание — условие тумблера над ним, а не самостоятельная строка:
        // вложенность видна отступом, и объяснять её словами не приходится.
        if draft.alternateCompletionEnabled {
            startRows.append(SDRowView(
                title: t("Сочетание завершения", "Finish shortcut"),
                control: hotkeyControl(shortcut: draft.alternateCompletionHotkey,
                                       kind: .alternateCompletion),
                style: .cardNested
            ))
        }
        root.addArrangedSubview(settingsGroup(t("Как начать", "How it starts"), rows: startRows))

        var inputRows: [NSView] = []

        let microphonePopup = NSPopUpButton()
        microphonePopup.addItem(withTitle: t("Системный по умолчанию", "System default"))
        microphonePopup.lastItem?.representedObject = ""
        let devices = availableAudioInputDevices()
        let saved = settings.inputDevice.trimmingCharacters(in: .whitespacesAndNewlines)
        for device in devices {
            microphonePopup.addItem(withTitle: device.name)
            microphonePopup.lastItem?.representedObject = device.uid
        }
        if let index = microphonePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == saved
        }) {
            microphonePopup.selectItem(at: index)
        }
        microphonePopup.target = self
        microphonePopup.action = #selector(selectMicrophoneFromPanel(_:))
        // Служба сообщает, если выбранное устройство отказало и запись идёт
        // с системного входа: без этого выбранное имя в попапе — молчаливая
        // ложь о том, откуда берётся звук.
        let microphoneSubtitle: String
        if let failed = AgentRuntimeStateStore.read()?.inputFallbackDeviceName {
            microphoneSubtitle = t("\(failed) отказал — запись идёт с системного входа",
                                   "\(failed) failed — recording from the system default input")
        } else {
            microphoneSubtitle = t("Если этот пропадёт — вернёмся ко встроенному",
                                   "Falls back to the built-in mic if this one disappears")
        }
        inputRows.append(SDRowView(
            title: t("Микрофон", "Microphone"),
            subtitle: microphoneSubtitle,
            control: SDFieldButton(popup: microphonePopup),
            style: .card
        ))

        // Полный список языков раньше жил только в меню по правому клику.
        // Подписи ведут с алфавита: настройка ограничивает алфавит вывода,
        // и «Кириллица» для английской речи означает «инглиш по-русски».
        let languagePopup = NSPopUpButton()
        for option in dictationLanguageMenuOrder() {
            if option == dictationLanguageMenuOrder().dropFirst(3).first {
                languagePopup.menu?.addItem(.separator())
            }
            languagePopup.addItem(withTitle: dictationLanguageMenuTitle(
                option, interfaceLanguage: language))
            languagePopup.lastItem?.representedObject = option.rawValue
        }
        if let index = languagePopup.itemArray.firstIndex(where: {
            ($0.representedObject as? String) == settings.dictationLanguage.rawValue
        }) {
            languagePopup.selectItem(at: index)
        }
        languagePopup.target = self
        languagePopup.action = #selector(selectDictationLanguageFromPanel(_:))
        inputRows.append(SDRowView(
            title: t("Алфавит вывода", "Output script"),
            subtitle: t("Авто — смешанная речь. Кириллица — английские слова "
                        + "запишутся по-русски",
                        "Auto handles mixed speech. Cyrillic makes English words "
                        + "come out in Russian letters"),
            control: SDFieldButton(popup: languagePopup),
            style: .card
        ))

        // Глушение жило только в старом меню («Mute system audio…»).
        let muteToggle = SDToggle()
        muteToggle.isOn = settings.muteWhileRecording
        muteToggle.onToggle = { [weak self] enabled in
            self?.settings.muteWhileRecording = enabled
        }
        inputRows.append(SDRowView(
            title: t("Глушить звук во время записи", "Mute audio while recording"),
            subtitle: t("Музыка и уведомления приглушаются, чтобы не попасть в диктовку",
                        "Music and alerts are ducked so they don't leak into the dictation"),
            control: muteToggle,
            style: .card
        ))

        let soundsToggle = SDToggle()
        soundsToggle.isOn = settings.playFeedbackSounds
        soundsToggle.onToggle = { [weak self] enabled in
            self?.settings.playFeedbackSounds = enabled
        }
        inputRows.append(SDRowView(
            title: t("Звуки диктовки", "Dictation sounds"),
            subtitle: t("Сигналы начала, конца и ошибки",
                        "Cues for start, finish and errors"),
            control: soundsToggle,
            style: .card
        ))
        root.addArrangedSubview(settingsGroup(t("Чем слушаем", "What listens"),
                                              rows: inputRows))

        if let notice = hotkeyNotice {
            let noticeLabel = panelLabel(notice, size: 11.5, weight: .medium, color: SD.C.voice)
            noticeLabel.preferredMaxLayoutWidth = MAIN_WINDOW_SIZE.width
                - MAIN_WINDOW_SIDEBAR_WIDTH - 100
            root.addArrangedSubview(noticeLabel)
        }
        root.addArrangedSubview(settingsFootnote(
            t("Микрофон и алфавит вывода продублированы в панели меню-бара. Это осознанный дубль: их меняют в момент диктовки, а не в момент настройки.",
              "The microphone and the output script are also in the menu-bar panel. That duplicate is deliberate: they get changed while dictating, not while configuring.")))
    }

    /// Сноска под группами: точка-маркер и приглушённый текст. Место для
    /// правды, которая не является настройкой, — например про осознанный
    /// дубль в другом месте интерфейса.
    func settingsFootnote(_ text: String) -> NSView {
        let dot = PaperBackgroundView()
        dot.fill = SD.C.subtle
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.translatesAutoresizingMaskIntoConstraints = false

        let label = panelLabel(text, size: 11.5, color: SD.C.subtle)
        label.preferredMaxLayoutWidth = 600
        label.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = NSView()
        wrapper.addSubview(dot)
        wrapper.addSubview(label)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            dot.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 5),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 9),
            label.topAnchor.constraint(equalTo: wrapper.topAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            label.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ])
        return wrapper
    }

    @objc private func selectMicrophoneFromPanel(_ sender: NSPopUpButton) {
        settings.inputDevice = (sender.selectedItem?.representedObject as? String) ?? ""
    }

    @objc private func selectDictationLanguageFromPanel(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let chosen = DictationLanguage(rawValue: raw) else { return }
        settings.dictationLanguage = chosen
    }
}
