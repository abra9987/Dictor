// Вкладка «Служба»: работает ли всё сейчас — разрешения, модель, замеры,
// обслуживание, а также запуск и остановка службы из окна.

import AppKit

extension DictorControlPanelApp {
    // MARK: - Раздел «Служба» — состояние, а не настройки

    /// Разрешения, модель, измерения и обслуживание. Ни одного переключателя
    /// предпочтений: всё здесь — ответ на вопрос «что там со службой», и
    /// приходят сюда из подвала сайдбара или из «Приложения».
    // MARK: Вкладка «Служба» — работает ли всё это сейчас

    /// Разрешения, модель, измерения и обслуживание. Ни одного переключателя:
    /// строка вкладок обещает предпочтения, и обещание снимается словами —
    /// подписью сверху, а не заголовком раздела. Отдельным разделом сайдбара
    /// это жило ровно один релиз: сайдбар — про данные (Сегодня, История,
    /// Статистика, Словарь), а состояние службы данными не является.
    func addServiceTabRows(to root: NSStackView) {
        let caption = panelLabel(
            t("Состояние диктовки на этом Mac. Здесь нечего настраивать — только увидеть и починить.",
              "How dictation is doing on this Mac. Nothing to configure here — only to see and to fix."),
            size: 11.5, color: SD.C.subtle)
        caption.preferredMaxLayoutWidth = 640
        root.addArrangedSubview(caption)

        addServicePermissionsGroup(to: root)
        addServiceModelGroup(to: root)
        addServiceMeasurementsGroup(to: root)
        addServiceMaintenanceGroup(to: root)
    }

    private func addServicePermissionsGroup(to root: NSStackView) {
        let report = PermissionsDoctor.report()
        var rows: [NSView] = []
        for (index, row) in report.rows.enumerated() {
            let copy = onboardingPermissionCopy(row.permission, language: language)
            let control: NSView
            if row.diagnosis == .missing {
                let button = NSButton(title: t("Разрешить", "Allow"),
                                      target: self,
                                      action: #selector(permissionGrantClicked(_:)))
                button.tag = index
                button.bezelStyle = .rounded
                button.font = .systemFont(ofSize: 12)
                control = button
            } else {
                control = panelLabel(PermissionsDoctor.explain(row.diagnosis, language: language),
                                     size: 12, weight: .medium,
                                     color: row.diagnosis == .granted ? SD.C.positive : SD.C.graphite)
            }
            let dot = SDStatusDot(shape: row.diagnosis == .granted ? .round : .square,
                                  color: row.diagnosis == .granted ? SD.C.positive : SD.C.danger)
            rows.append(SDRowView(title: copy.name,
                                  subtitle: copy.why,
                                  control: control,
                                  style: .card,
                                  leading: dot))
        }

        let fix = NSButton(title: t("Проверить и починить", "Check and repair"),
                           target: self,
                           action: #selector(permissionRepairClicked(_:)))
        fix.bezelStyle = .rounded
        fix.font = .systemFont(ofSize: 12, weight: .semibold)
        rows.append(SDRowView(
            title: t("Разрешение выдано, а не работает", "Granted but not working"),
            subtitle: t("Частая причина — вторая копия приложения или устаревшая "
                        + "запись системы после смены подписи",
                        "Usually a second copy of the app or a stale system record "
                        + "after the signature changed"),
            control: fix,
            style: .card
        ))
        root.addArrangedSubview(settingsGroup(t("Разрешения macOS", "macOS permissions"),
                                              rows: rows))

        // Что кнопка сделает — показываем заранее, а после нажатия заменяем
        // на отчёт о том, что сделано.
        let lines = permissionRepairNotes.isEmpty
            ? PermissionsDoctor.repairPlan(report, language: language)
            : permissionRepairNotes
        for (index, line) in lines.enumerated() {
            // Запуск не из «Программ» — не совет, а причина, по которой всё
            // остальное бесполезно. Он всегда первый и выделен цветом.
            let isBlocker = index == 0 && !report.isInstalledInApplications
            root.addArrangedSubview(permissionsNoteRow(line,
                                                       color: isBlocker ? SD.C.voice : SD.C.subtle))
        }
    }

    private func addServiceModelGroup(to root: NSStackView) {
        let profile = SpeechModelProfile.productionDefault
        // Карточка называет ту модель, которая распознаёт на самом деле. После
        // обновления приложения это может быть модель прошлой версии — пока
        // новая скачивается, — и «используется» рядом с именем новой было бы
        // неправдой.
        let modelUpdate = previewModelUpdateOverride
            ?? AgentRuntimeStateStore.read()?.speechModelUpdate
        let cardTitle: String
        let cardDetail: String
        if let modelUpdate {
            cardTitle = modelUpdate.previousModelName + " · "
                + t("используется, пока не готова новая", "in use until the new one is ready")
            cardDetail = speechModelUpdateDetail(modelUpdate, newModelName: profile.shortName)
        } else {
            cardTitle = profile.shortName + " · " + t("используется", "in use")
            cardDetail = t("~630 МБ · русский, английский и ещё 16 языков · Neural Engine. "
                           + "Работает целиком на этом Mac; скачивается с huggingface.co при установке.",
                           "~630 MB · Russian, English and 16 more · Neural Engine. "
                           + "Runs entirely on this Mac; downloads from huggingface.co at setup.")
        }
        let card = SDModelCard(
            title: cardTitle,
            detail: cardDetail,
            active: true,
            actionTitle: nil,
            target: nil,
            action: nil,
            identifier: profile.rawValue
        )
        card.translatesAutoresizingMaskIntoConstraints = false

        let memoryRow = SDRowView(
            title: t("Модель в памяти", "Model in memory"),
            subtitle: t("Выгружается только при смене модели — первая диктовка без задержки",
                        "Unloaded only when the model changes — the first dictation has no warm-up"),
            control: panelLabel(t("всегда", "always"), size: 12, weight: .medium),
            style: .card
        )

        let wrapper = NSStackView(views: [card, settingsGroup(nil, rows: [memoryRow])])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.spacing = 10
        for view in wrapper.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        }

        let group = NSStackView(views: [
            serviceGroupHeader(t("Модель", "Model")),
            wrapper,
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        for view in group.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        root.addArrangedSubview(group)
    }

    /// Одна строка: подпись карточки модели не переносится.
    private func speechModelUpdateDetail(_ update: SpeechModelUpdateStatus,
                                         newModelName: String) -> String {
        switch update.phase {
        case .downloading:
            let percent = update.fraction.map { " — \(Int(($0 * 100).rounded()))\u{00A0}%" } ?? ""
            return t("\(newModelName) (~630 МБ) скачивается\(percent). Диктовка работает; "
                     + "служба перейдёт на новую модель сама, в паузе.",
                     "\(newModelName) (~630 MB) is downloading\(percent). Dictation works; "
                     + "the service moves to the new model on its own, when idle.")
        case .waitingForIdle:
            return t("\(newModelName) скачана и проверена. Служба перейдёт на неё сама, "
                     + "когда вы пару минут не диктуете.",
                     "\(newModelName) is downloaded and verified. The service moves to it "
                     + "on its own once you stop dictating for a couple of minutes.")
        case .retrying:
            // Причину не называем: это может быть сеть, место на диске или
            // файлы, которые не сошлись с проверкой, — подробности в журнале.
            return t("\(newModelName) (~630 МБ) пока не скачалась. "
                     + "Диктовка работает; загрузка повторится сама.",
                     "\(newModelName) (~630 MB) hasn’t downloaded yet. "
                     + "Dictation works; the download retries on its own.")
        case .failedToLoad:
            return t("\(newModelName) скачана, но на этом Mac не запустилась. "
                     + "Диктовка работает на прежней модели; подробности — в журнале.",
                     "\(newModelName) is downloaded but failed to start on this Mac. "
                     + "Dictation runs on the previous model; the log has the details.")
        }
    }

    private func addServiceMeasurementsGroup(to root: NSStackView) {
        let tiles = performanceTilesRow()
        tiles.translatesAutoresizingMaskIntoConstraints = false
        let group = NSStackView(views: [
            serviceGroupHeader(t("Измерения", "Measurements")),
            tiles,
        ])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 7
        for view in group.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        }
        root.addArrangedSubview(group)
    }

    private func addServiceMaintenanceGroup(to root: NSStackView) {
        // Подсказки «Сегодня» закрываются навсегда — правило макета 6e.
        // Раньше «навсегда» было буквальным: dismissedHints нигде не
        // сбрасывался, и вернуть подсказки не мог никто (аудит, мелочь №15).
        let dismissed = settings.dismissedHints.count
        let hintsRow = SDRowView(
            title: t("Закрытые подсказки", "Dismissed hints"),
            subtitle: dismissed > 0
                ? t("\(dismissed) \(pluralizeRU(dismissed, "подсказка скрыта", "подсказки скрыты", "подсказок скрыто")) на экране «Сегодня»",
                    "\(dismissed) \(dismissed == 1 ? "hint is" : "hints are") hidden on the Today screen")
                : t("Закрытых нет", "Nothing is dismissed"),
            control: panelButton(t("Вернуть", "Restore"),
                                 action: #selector(restoreDismissedHintsFromPanel(_:)),
                                 enabled: dismissed > 0),
            style: .card
        )
        root.addArrangedSubview(settingsGroup(t("Обслуживание", "Maintenance"),
                                              rows: [hintsRow]))
    }

    /// Заголовок группы раздела «Служба» — тот же, что у групп настроек:
    /// раздел читается как продолжение вкладок, а не как чужой экран.
    func serviceGroupHeader(_ title: String) -> NSView {
        let header = settingsGroupHeaderLabel(title)
        let wrapper = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        wrapper.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
            header.topAnchor.constraint(equalTo: wrapper.topAnchor),
            header.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        ])
        return wrapper
    }

    /// Разрешения и их починка. Живут в «Продвинутых», потому что сюда идут
    /// именно тогда, когда что-то не работает.
    private func permissionsNoteRow(_ text: String, color: NSColor) -> NSView {
        let label = panelLabel("• " + text, size: 11.5, color: color)
        // Без уступки по сжатию строка вылезала за правый край окна. Точки
        // разрыва внутри пути расставляет PermissionsDoctor.
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let wrapper = NSStackView(views: [label])
        wrapper.orientation = .vertical
        wrapper.alignment = .leading
        wrapper.edgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 6, right: 0)
        label.widthAnchor.constraint(equalTo: wrapper.widthAnchor).isActive = true
        return wrapper
    }

    @objc private func permissionGrantClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        Permissions.request(Permission.allCases[sender.tag])
        refresh(force: true)
    }

    @objc private func permissionRepairClicked(_ sender: NSButton) {
        let report = PermissionsDoctor.report()
        var notes: [String] = []
        let bundleID = Bundle.main.bundleIdentifier ?? "com.raul.dictor"

        if report.needsAgentRestart {
            notes.append(t("Служба перезапущена — теперь она перечитает разрешения.",
                           "The service was restarted — it will re-read permissions now."))
            beginServiceOperation(.restarting)
        }

        let missing = report.rows.filter { $0.diagnosis == .missing }.map(\.permission)
        for permission in missing {
            let name = onboardingPermissionCopy(permission, language: language).name
            notes.append(t("Запись macOS для «\(name)» сброшена, запрос отправлен заново.",
                           "The macOS record for “\(name)” was reset and requested again."))
            TCC.reset(permission, bundleID: bundleID) { [weak self] in
                Permissions.request(permission)
                self?.refresh(force: true)
            }
        }

        if notes.isEmpty {
            notes.append(t("Чинить нечего: все разрешения выданы и служба их видит.",
                           "Nothing to repair: every permission is granted and the service sees it."))
        }
        if !report.isInstalledInApplications {
            notes.append(t("Это не лечится отсюда: перенесите Dictor в «Программы» и выдайте разрешения заново.",
                           "This cannot be fixed from here: move Dictor to Applications and grant the permissions again."))
        }
        log("permissions repair: \(notes.count) action(s)")
        permissionRepairNotes = notes
        refresh(force: true)
    }

    private func performanceTilesRow() -> NSView {
        let entries = settings.recentTranscriptEntries
        let recognition = medianRecognitionSeconds(entries: entries)
        let agentPID = AgentRuntimeStateStore.read()?.pid ?? 0
        let sample = processResourceSample(pid: agentPID)

        let recognitionTile = SDMetricTile(
            value: recognition.map { recognitionDurationLabel($0, language: language) } ?? "—",
            caption: recognition == nil
                ? t("распознайте что-нибудь, и здесь появится цифра",
                    "dictate something and a number shows up here")
                : t("от отпускания клавиши до текста, медиана",
                    "from key release to text, median")
        )
        let memoryTile = SDMetricTile(
            value: sample.map { memoryFootprintLabel($0.physicalFootprintBytes, language: language) } ?? "—",
            caption: sample == nil
                ? t("служба не запущена", "the service is not running")
                : t("памяти у службы", "memory used by the service")
        )
        // Процессорное время имеет смысл только как разница двух замеров,
        // поэтому плитка сначала честно пустая и заполняется через секунду.
        let cpuTile = SDMetricTile(value: "…", caption: t("CPU, пока молчите", "CPU while you are silent"))
        if let sample, agentPID > 0 {
            scheduleCPUTileUpdate(tile: cpuTile, baseline: sample, pid: agentPID)
        } else {
            cpuTile.update(value: "—", caption: t("служба не запущена", "the service is not running"))
        }

        let row = NSStackView(views: [recognitionTile, memoryTile, cpuTile])
        row.orientation = .horizontal
        row.spacing = 10
        row.distribution = .fillEqually
        row.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
            row.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -14),
        ])
        return wrapper
    }

    private func scheduleCPUTileUpdate(tile: SDMetricTile,
                                       baseline: ProcessResourceSample,
                                       pid: Int32) {
        let startedAt = ProcessInfo.processInfo.systemUptime
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: false) { [weak tile] _ in
            MainActor.assumeIsolated {
                // weak tile: вкладка пересобирается на каждом refresh, и
                // к моменту выстрела эта плитка может быть уже не на экране.
                guard let tile, tile.window != nil else { return }
                guard let later = processResourceSample(pid: pid) else { return }
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                guard let percent = cpuLoadPercent(from: baseline,
                                                   to: later,
                                                   elapsedSeconds: elapsed) else { return }
                tile.update(value: percent < 0.5 ? "0%" : String(format: "%.0f%%", percent),
                            caption: nil)
            }
        }
    }

    func compactPermissionsCard() -> NSView {
        let missing = Permission.allCases.filter { !Permissions.isGranted($0) }
        let card = compactCard()
        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 7
        content.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        let color: NSColor = missing.isEmpty ? .systemGreen : .systemOrange
        header.addArrangedSubview(panelSymbol(missing.isEmpty ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                                              color: color,
                                              description: t("Разрешения macOS", "macOS permissions"),
                                              pointSize: 15))
        header.addArrangedSubview(panelLabel(t("Разрешения macOS", "macOS permissions"),
                                             size: 12.5,
                                             weight: .semibold))
        header.addArrangedSubview(NSView())
        header.addArrangedSubview(panelLabel(
            missing.isEmpty ? t("Все выданы", "All granted")
                            : t("Нужно: \(missing.count)", "Missing: \(missing.count)"),
            size: 11.5,
            weight: .medium,
            color: color
        ))
        content.addArrangedSubview(header)

        if missing.isEmpty {
            let ready = panelLabel(
                t("Микрофон, вставка текста и глобальный хоткей доступны.",
                  "Microphone, text insertion, and the global shortcut are available."),
                size: 11,
                color: .secondaryLabelColor
            )
            ready.toolTip = t("Dictor получил все три необходимых разрешения macOS.",
                              "Dictor has all three required macOS permissions.")
            content.addArrangedSubview(ready)
        } else {
            for permission in missing {
                content.addArrangedSubview(compactPermissionRow(permission))
            }
        }
        pin(content, inside: card, horizontal: 13, vertical: 10)
        return card
    }

    private func compactPermissionRow(_ permission: Permission) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        let title = panelLabel(permissionTitle(permission), size: 11.5, weight: .medium)
        title.toolTip = permissionDetail(permission)
        let buttonTitle = (permissionClickCount[permission] ?? 0) >= 1
            ? t("Повторить", "Try Again") : t("Разрешить", "Grant")
        let button = panelButton(buttonTitle,
                                 action: #selector(grantPermissionClicked(_:)),
                                 enabled: serviceOperation == nil,
                                 toolTip: t("Открыть системное разрешение: \(permissionTitle(permission))",
                                            "Open the system permission: \(permissionTitle(permission))"))
        button.controlSize = .small
        button.tag = Permission.allCases.firstIndex(of: permission) ?? -1
        row.addArrangedSubview(title)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(button)
        return row
    }

    func beginServiceOperation(_ operation: ControlPanelServiceOperation) {
        guard serviceOperation == nil else { return }
        serviceOperation = operation
        lastRenderFingerprint = ""
        refresh(force: true)
        let operationStartedAt = Date().timeIntervalSince1970

        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                do {
                    switch operation {
                    case .starting:
                        try DictorAgentService.installAndStart()
                    case .restarting, .applyingSettings:
                        try DictorAgentService.restart()
                    case .stopping:
                        DictorAgentService.stop()
                    }
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value

            guard let self else { return }
            if failure == nil {
                await self.waitForServiceResult(operation: operation, startedAt: operationStartedAt)
            }
            self.serviceOperation = nil
            self.lastRenderFingerprint = ""
            self.refresh(force: true)
            if let failure {
                self.showError(
                    title: self.t("Не удалось изменить состояние службы", "Service operation failed"),
                    detail: failure
                )
            }
        }
    }

    private func waitForServiceResult(operation: ControlPanelServiceOperation,
                                      startedAt: TimeInterval) async {
        for _ in 0..<80 {
            let state = AgentRuntimeStateStore.read()
            if operation == .stopping {
                if state?.status == "stopped" { return }
            } else if let state,
                      state.updatedAt >= startedAt,
                      ["ready", "error", "needs_permissions"].contains(state.status) {
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    @objc private func grantPermissionClicked(_ sender: NSButton) {
        guard Permission.allCases.indices.contains(sender.tag) else { return }
        let permission = Permission.allCases[sender.tag]
        if Permissions.isGranted(permission) {
            permissionClickCount[permission] = nil
            refresh(force: true)
            return
        }

        let clicks = (permissionClickCount[permission] ?? 0) + 1
        permissionClickCount[permission] = clicks
        if clicks >= 2 {
            TCC.reset(permission, bundleID: Bundle.main.bundleIdentifier ?? SETTINGS_SUITE) { [weak self] in
                guard let self else { return }
                Permissions.request(permission)
                self.refresh(force: true)
            }
        } else {
            Permissions.request(permission)
        }
        refresh(force: true)
    }
}
