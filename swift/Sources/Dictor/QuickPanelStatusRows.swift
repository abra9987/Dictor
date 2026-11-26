import AppKit

extension DictorQuickPanel {
    // MARK: - Ряды

    /// Шапка панели по макету 8b. Маркер 8×8, заголовок 14/600, подпись 12,
    /// тумблер 36×22 — всё на одном месте во всех девяти состояниях; меняются
    /// форма маркера, тексты, высота и наличие кнопок.
    ///
    /// Раньше здесь всегда стояла волна: она шла и когда служба готова, и
    /// когда лежит. Движение — обещание работы, и обещать его в состоянии
    /// покоя значит врать; теперь в «Готово» стоит зелёная точка, а волна
    /// появляется ровно тогда, когда что-то действительно происходит.
    func headerRow() -> NSView {
        let kind = state.serviceStatus
        let view = serviceStatusPresentation(kind, language: state.interfaceLanguage)

        let row = NSView()
        let marker = ServiceStatusMarkerView()
        marker.markerSize = 8
        switch kind {
        case .ready: marker.shape = .dot(SD.C.positive)
        // Пауза, как и «выключено», — намеренный покой: кольцо, без движения.
        case .off, .paused: marker.shape = .hollowRing
        // «Нет микрофона» — тоже ожидание человека, а не поломка службы.
        case .needsPermission, .versionMismatch, .noMicrophone: marker.shape = .hollowSquare
        case .failed: marker.shape = .filledSquare(SD.C.danger)
        default: marker.shape = .wave(slow: kind.waveIsSlow)
        }

        let title = label(view.title, size: 14, weight: .semibold,
                          color: kind == .off ? SD.C.graphite : SD.C.ink)
        let subtitle = label(view.subtitle, size: 12,
                             color: kind == .off ? SD.C.hintText : SD.C.graphite)
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = Self.panelWidth - 32 - 36 - 12

        let toggle = SDToggle()
        toggle.isOn = state.enabled
        // Во время обновления тумблер не нажимается: служба и так сейчас
        // сменится, а нажатие в этот момент только запутает.
        toggle.isEnabled = kind != .updating
        toggle.alphaValue = kind == .updating ? 0.45 : 1
        toggle.onToggle = { [weak self] enabled in
            self?.quickDelegate?.quickPanelDidToggleEnabled(enabled)
        }

        let head = NSStackView(views: [marker, title])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        let textColumn = NSStackView(views: [head, subtitle])
        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 3

        for sub in [textColumn, toggle] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(sub)
        }
        NSLayoutConstraint.activate([
            toggle.widthAnchor.constraint(equalToConstant: 36),
            toggle.heightAnchor.constraint(equalToConstant: 22),
            toggle.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            // Тумблер стоит между заголовком и подписью — по высоте там же,
            // где стоял, пока шапка состояла из двух строк и он центрировался
            // по ней. Когда шапка научилась расти вниз (прогресс, кнопки),
            // центрирование по строке убрали и ничего не поставили взамен:
            // без вертикального ограничения AppKit кладёт вид в y = 0, то есть
            // на нижний край, и тумблер два месяца лежал на разделителе.
            // Привязка к заголовку, а не к середине шапки, держит его на месте
            // во всех девяти состояниях.
            toggle.centerYAnchor.constraint(equalTo: head.bottomAnchor, constant: 1),
            textColumn.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            textColumn.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor,
                                                 constant: -12),
            textColumn.topAnchor.constraint(equalTo: row.topAnchor, constant: 12),
        ])

        // Прогресс и кнопки — только там, где они есть по макету.
        var lastAnchor: NSView = textColumn
        if let ticks = view.ticks {
            let ticksView = ServiceStatusTicksView()
            ticksView.done = ticks.done
            ticksView.total = ticks.total
            ticksView.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(ticksView)
            NSLayoutConstraint.activate([
                ticksView.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                ticksView.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                ticksView.topAnchor.constraint(equalTo: textColumn.bottomAnchor, constant: 8),
                ticksView.heightAnchor.constraint(equalToConstant: 5),
            ])
            lastAnchor = ticksView
        } else if let fraction = view.progressFraction {
            let bar = ServiceStatusProgressView()
            bar.fraction = fraction
            bar.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                bar.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                bar.topAnchor.constraint(equalTo: textColumn.bottomAnchor, constant: 8),
                bar.heightAnchor.constraint(equalToConstant: 5),
            ])
            lastAnchor = bar
        }

        if let primary = view.primaryAction {
            let buttons = NSStackView()
            buttons.orientation = .horizontal
            buttons.alignment = .centerY
            buttons.spacing = 8
            buttons.translatesAutoresizingMaskIntoConstraints = false

            let main = NSButton(title: primary, target: self,
                                action: #selector(statusPrimaryClicked))
            main.isBordered = false
            main.wantsLayer = true
            main.layer?.cornerRadius = 8
            main.layer?.backgroundColor = main.resolvedCGColor(SD.C.voice)
            main.contentTintColor = .white
            main.font = .systemFont(ofSize: 12, weight: .semibold)
            main.heightAnchor.constraint(equalToConstant: 28).isActive = true
            buttons.addArrangedSubview(main)

            if let secondary = view.secondaryAction {
                let quiet = NSButton(title: secondary, target: self,
                                     action: #selector(statusSecondaryClicked))
                quiet.isBordered = false
                quiet.font = .systemFont(ofSize: 12, weight: .medium)
                quiet.contentTintColor = SD.C.inkSecondary
                quiet.heightAnchor.constraint(equalToConstant: 28).isActive = true
                buttons.addArrangedSubview(quiet)
            }
            buttons.addArrangedSubview(NSView())

            row.addSubview(buttons)
            NSLayoutConstraint.activate([
                buttons.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
                buttons.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
                buttons.topAnchor.constraint(equalTo: lastAnchor.bottomAnchor, constant: 10),
            ])
            lastAnchor = buttons
        }

        row.bottomAnchor.constraint(equalTo: lastAnchor.bottomAnchor, constant: 12).isActive = true

        // Отказ подсвечен той же лёгкой подложкой, что и в подвале окна.
        if kind == .failed {
            let wash = ServiceStatusFooterView()
            wash.fill = SD.C.dangerWash
            wash.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(wash, positioned: .below, relativeTo: nil)
            NSLayoutConstraint.activate([
                wash.leadingAnchor.constraint(equalTo: row.leadingAnchor),
                wash.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                wash.topAnchor.constraint(equalTo: row.topAnchor),
                wash.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            ])
        }
        return row
    }

    @objc private func statusPrimaryClicked() {
        close()
        quickDelegate?.quickPanelStatusPrimaryAction()
    }

    @objc private func statusSecondaryClicked() {
        close()
        quickDelegate?.quickPanelStatusSecondaryAction()
    }

    /// Предложение обновиться. Подложка голосового цвета, потому что это
    /// единственная строка панели, которая появляется не всегда, и её
    /// незаметность означала бы, что обновления снова нет.
    func updateRow() -> NSView {
        let row = PaperBackgroundView()
        let caption: NSTextField
        let button: NSButton

        if let version = state.availableUpdateVersion {
            // Единственная строка панели, которая появляется не всегда, —
            // и потому единственная, которой позволено быть цветной. Заливка
            // разбавленная: на плотном оранжевом надпись кнопки тонет, а это
            // ровно та кнопка, ради которой строка и нужна.
            row.fill = NSColor(name: nil) { appearance in
                appearance.isDark
                    ? NSColor(hex: 0xFF6B47).withAlphaComponent(0.16)
                    : NSColor(hex: 0xE8502F).withAlphaComponent(0.10)
            }
            caption = label(t("Доступна версия \(version)", "Version \(version) is available"),
                            size: 12.5, weight: .medium, color: SD.C.ink)
            button = NSButton(title: t("Обновить", "Update"),
                              target: self, action: #selector(installUpdateClicked))
            button.contentTintColor = SD.C.voice
        } else if showsUpToDate {
            row.fill = .clear
            caption = label(t("Установлена последняя версия — \(state.installedVersion)",
                              "You are on the latest version — \(state.installedVersion)"),
                            size: 12, color: SD.C.graphite)
            button = NSButton(title: "", target: nil, action: nil)
            button.isHidden = true
        } else if state.isCheckingForUpdates {
            row.fill = .clear
            caption = label(t("Проверяю обновления…", "Checking for updates…"),
                            size: 12, color: SD.C.graphite)
            button = NSButton(title: "", target: nil, action: nil)
            button.isHidden = true
        } else {
            row.fill = .clear
            caption = label(t("Версия \(state.installedVersion)",
                              "Version \(state.installedVersion)"),
                            size: 12, color: SD.C.graphite)
            button = NSButton(title: t("Проверить", "Check"),
                              target: self, action: #selector(checkUpdatesClicked))
            button.contentTintColor = SD.C.ink
        }
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 12, weight: .semibold)

        for view in [caption, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 36),
            row.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            caption.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            caption.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            button.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -16),
            button.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    @objc private func installUpdateClicked() {
        close()
        quickDelegate?.quickPanelInstallUpdate()
    }

    @objc private func checkUpdatesClicked() {
        quickDelegate?.quickPanelCheckForUpdates()
    }

    func flashUpToDate() {
        upToDateWorkItem?.cancel()
        showsUpToDate = true
        rebuildContent()
        let revert = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showsUpToDate = false
            self.rebuildContent()
        }
        upToDateWorkItem = revert
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: revert)
    }
}
