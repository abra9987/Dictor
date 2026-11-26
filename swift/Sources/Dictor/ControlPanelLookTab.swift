import AppKit

extension DictorControlPanelApp {
    // MARK: Вкладка «Вид» — что видно на экране

    func addLookTabRows(to root: NSStackView, draft: ControlPanelSettingsDraft) {
        // Главный шов старой раскладки: капсула записи была разорвана между
        // «Внешним видом» (тумблер, фон, цвет) и «Продвинутыми» (размер,
        // положение). Пять настроек одного объекта теперь стоят вместе, под
        // одним превью, и видно, что меняется.
        let preview = SDCapsulePreview(
            size: settings.recordingHUDSize,
            backgroundStyle: settings.recordingHUDBackgroundStyle,
            color: settings.recordingHUDRecordingColor.nsColor,
            transcribingColor: settings.recordingHUDTranscribingColor.nsColor,
            language: language)
        preview.translatesAutoresizingMaskIntoConstraints = false

        let hudToggle = SDToggle()
        hudToggle.isOn = settings.showRecordingWaveform
        hudToggle.onToggle = { [weak self] enabled in
            self?.settings.showRecordingWaveform = enabled
        }
        let showRow = SDRowView(
            title: t("Показывать капсулу", "Show the capsule"),
            subtitle: t("Волна и таймер рядом с курсором, пока идёт диктовка",
                        "Wave and timer beside the cursor while dictation runs"),
            control: hudToggle,
            style: .card
        )

        let sizes: [RecordingHUDSize] = [.compact, .standard, .large]
        let sizeSegmented = SDSegmented(titles: ["S", "M", "L"],
                                        values: sizes.map(\.rawValue),
                                        selected: settings.recordingHUDSize.rawValue)
        sizeSegmented.onSelect = { [weak self, weak preview] raw in
            guard let size = RecordingHUDSize(rawValue: raw) else { return }
            self?.settings.recordingHUDSize = size
            self?.settingsDraft?.hudSize = size
            preview?.apply(size: size)
        }
        let sizeRow = SDRowView(title: t("Размер", "Size"),
                                control: sizeSegmented,
                                style: .card)

        let placement = NSPopUpButton()
        placement.isBordered = false
        placement.font = .systemFont(ofSize: 12.5)
        placement.contentTintColor = SD.C.ink
        let placements: [(RecordingHUDPlacement, String)] = [
            (.followsInput, t("У поля ввода", "At the text field")),
            (.bottomCenter, t("Снизу по центру", "Bottom center")),
            (.topCenter, t("Сверху по центру", "Top center")),
        ]
        for (value, title) in placements {
            placement.addItem(withTitle: title)
            placement.lastItem?.identifier = NSUserInterfaceItemIdentifier(value.rawValue)
        }
        placement.selectItem(at: placements.firstIndex { $0.0 == settings.recordingHUDPlacement } ?? 0)
        placement.target = self
        placement.action = #selector(capsulePlacementChanged(_:))
        // Макет предлагал ещё и «перетащите капсулу мышью». Тащить нечего:
        // между диктовками капсулы не существует, это макет 6c. Вместо
        // выдуманной подсказки — правда о запасном варианте.
        let placementRow = SDRowView(
            title: t("Положение", "Position"),
            subtitle: t("Если поле ввода не найдено — сверху по центру",
                        "If no text field is found — top center"),
            control: SDFieldButton(popup: placement),
            style: .card
        )

        let backgroundPills = SDPills(options: RecordingHUDBackgroundStyle.allCases.map {
            .init(title: localizedBackgroundName($0), value: $0.rawValue)
        }, selected: settings.recordingHUDBackgroundStyle.rawValue)
        backgroundPills.onSelect = { [weak self, weak preview] raw in
            guard let style = RecordingHUDBackgroundStyle(rawValue: raw) else { return }
            self?.settings.recordingHUDBackgroundStyle = style
            self?.settingsDraft?.backgroundStyle = style
            preview?.apply(backgroundStyle: style)
        }
        let backgroundRow = SDRowView(title: t("Фон", "Background"),
                                      control: backgroundPills,
                                      style: .card)

        // Макет: кружки-свотчи 22px вместо пилюль с названиями.
        let swatches = SDColorSwatches(
            swatches: RecordingHUDAccentColor.allCases.map {
                .init(value: $0.rawValue, color: $0.nsColor)
            },
            selected: settings.recordingHUDRecordingColor.rawValue
        )
        swatches.onSelect = { [weak self, weak preview] raw in
            guard let color = RecordingHUDAccentColor(rawValue: raw) else { return }
            self?.settings.recordingHUDRecordingColor = color
            self?.settingsDraft?.recordingColor = color
            preview?.apply(color: color.nsColor)
        }
        let colorRow = SDRowView(
            title: t("Цвет волны", "Wave color"),
            // «Он же цвет приложения» тут стояло из макета и было неправдой:
            // акцент интерфейса — константа и за этой настройкой не следует.
            // Правдой это делать нельзя как есть: в палитре белый и серый,
            // подобранные под тёмную капсулу, — акцентом всего окна белый
            // сделал бы невидимыми «Стереть историю…» и точку обновления.
            subtitle: t("Волна в капсуле выше. Цвет фазы распознавания задаётся только через defaults write",
                        "The wave in the capsule above. The transcribing phase color is set through defaults write only"),
            control: swatches,
            style: .card
        )

        // Превью стоит над карточкой: оно показывает то, что настраивают
        // строки под ним, — а не одну из них.
        let previewStage = NSStackView(views: [preview])
        previewStage.orientation = .vertical
        previewStage.alignment = .centerX
        previewStage.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 12, right: 0)

        let capsuleGroup = NSStackView(views: [
            serviceGroupHeader(t("Капсула записи", "Recording capsule")),
            previewStage,
            SDSettingsGroupCard(rows: [showRow, sizeRow, placementRow,
                                       backgroundRow, colorRow]),
        ])
        capsuleGroup.orientation = .vertical
        capsuleGroup.alignment = .leading
        capsuleGroup.spacing = 7
        for view in capsuleGroup.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: capsuleGroup.widthAnchor).isActive = true
        }
        root.addArrangedSubview(capsuleGroup)

        // Плавающая капсула отделена в свою группу именно потому, что
        // настройки капсулы записи на неё не действуют: соседство в одной
        // карточке обещало бы обратное (аудит №6).
        let capsuleToggle = SDToggle()
        capsuleToggle.isOn = settings.floatingCapsuleEnabled
        capsuleToggle.onToggle = { [weak self] enabled in
            self?.settings.floatingCapsuleEnabled = enabled
        }
        let floatingRow = SDRowView(
            title: t("Постоянная капсула", "Permanent capsule"),
            subtitle: t("Всегда на экране: перетаскивается, прилипает к краям, помнит "
                        + "место, при записи растёт сама. Размер — тот же, что выбран выше",
                        "Always on screen: drag it, it sticks to the edges, remembers "
                        + "its place and grows while recording. Size follows the choice above"),
            control: capsuleToggle,
            style: .card
        )

        // Настройка существовала всегда, но shouldShowDockIcon жёстко
        // возвращал false — пункт старого меню переключал её впустую.
        // Значок принадлежит службе и показывается, пока это окно закрыто.
        let dockToggle = SDToggle()
        dockToggle.isOn = settings.showInDock
        dockToggle.onToggle = { [weak self] enabled in
            self?.settings.showInDock = enabled
        }
        let dockRow = SDRowView(
            title: t("Значок в Dock", "Dock icon"),
            subtitle: t("Клик по значку открывает это окно. Иконка в меню-баре остаётся всегда",
                        "Clicking it opens this window. The menu-bar icon always stays"),
            control: dockToggle,
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("На рабочем столе", "On the desktop"),
                                              rows: [floatingRow, dockRow]))
    }

    @objc func restoreDismissedHintsFromPanel(_ sender: NSButton) {
        settings.dismissedHints = []
        refresh(force: true)
    }

    @objc private func capsulePlacementChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.identifier?.rawValue,
              let placement = RecordingHUDPlacement(rawValue: raw) else { return }
        settings.recordingHUDPlacement = placement
    }

    /// Строка секции «Капсула» из макета: подпись фиксированной ширины 96,
    /// сразу за ней контрол, а всё остальное прижато вправо.
    private func advancedCapsuleRow(title: String,
                                    control: NSView,
                                    trailing: NSView) -> NSView {
        let row = SDAdvancedRowView(rowTitle: title, control: control)
        let label = panelLabel(title, size: 12.5)
        label.textColor = SD.C.ink
        for view in [label, control, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        let hairline = SDHairlineView()
        hairline.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(hairline)

        let squeeze = row.heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow
        NSLayoutConstraint.activate([
            squeeze,
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: 96),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 16),
            control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            trailing.leadingAnchor.constraint(greaterThanOrEqualTo: control.trailingAnchor,
                                              constant: 16),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor, constant: 10),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor, constant: 10),
            row.bottomAnchor.constraint(greaterThanOrEqualTo: trailing.bottomAnchor, constant: 10),
            hairline.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            hairline.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            hairline.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }
}
