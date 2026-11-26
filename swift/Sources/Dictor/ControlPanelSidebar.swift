// Каркас главного окна (макет 6a): сайдбар с разделами, статус службы внизу
// сайдбара с его кнопками и выход из приложения целиком.

import AppKit

extension DictorControlPanelApp {
    // MARK: - Главное окно: история (макет 2b/4a)

    // MARK: - Каркас главного окна (макет 6a)

    /// Сайдбар 212pt + раздел. Сайдбар уходит под тайтлбар, первые 52pt
    /// оставлены под кнопки окна.
    func makeMainWindowView() -> NSView {
        // Онбординг занимает окно целиком: ни сайдбара, ни разделов, пока
        // человек не дошёл до конца или не нажал «Пропустить».
        if let onboardingPage { return onboardingPage }

        let sidebar = makeSidebarView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        let divider = SDHairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let content: NSView
        switch mainSection {
        case .today:
            content = makeTodayView()
        case .history:
            content = makeMainHistoryView()
        case .stats:
            content = makeStatsSectionView()
        case .dictionary:
            content = makeDictionarySectionView()
        case .settings:
            content = makeSettingsSectionView()
        }
        content.translatesAutoresizingMaskIntoConstraints = false

        let root = PaperBackgroundView()
        root.fill = SD.C.settingsPaper
        root.addSubview(sidebar)
        root.addSubview(divider)
        root.addSubview(content)

        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: MAIN_WINDOW_SIDEBAR_WIDTH),
            divider.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            divider.topAnchor.constraint(equalTo: root.topAnchor),
            divider.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            content.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        return root
    }

    /// Сайдбар: пустые 52pt под кнопки окна, навигация, статус службы внизу.
    private func makeSidebarView() -> NSView {
        let root = PaperBackgroundView()
        root.fill = SD.C.sidebarPaper

        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 3
        nav.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        nav.translatesAutoresizingMaskIntoConstraints = false

        let historyCount = settings.recentTranscriptEntries.count
        let dictionaryCount = settings.transcriptCorrections.count
        for section in MainWindowSection.allCases {
            let count: Int?
            switch section {
            case .history: count = historyCount
            case .dictionary: count = dictionaryCount
            default: count = nil
            }
            let item = SDSidebarItemView(section: section,
                                         title: section.title(language),
                                         count: count,
                                         isSelected: section == mainSection,
                                         target: self,
                                         action: #selector(sidebarItemClicked(_:)))
            item.translatesAutoresizingMaskIntoConstraints = false
            nav.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: nav.widthAnchor, constant: -24).isActive = true
        }

        let status = makeSidebarStatusView()
        status.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(nav)
        root.addSubview(status)
        NSLayoutConstraint.activate([
            nav.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            nav.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            nav.topAnchor.constraint(equalTo: root.topAnchor,
                                     constant: MAIN_WINDOW_HEADER_HEIGHT),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.topAnchor.constraint(greaterThanOrEqualTo: nav.bottomAnchor),
        ])
        return root
    }

    /// Текущее состояние службы — одно из девяти (макет 8). Раньше их было
    /// два, «готово» и «остановлена», и между ними прятались проверка модели,
    /// её загрузка, прогрев и обновление приложения. После обновления это было
    /// особенно плохо: служба поднимается заново, а подвал утверждал, что она
    /// остановлена, — человек не знал, ждать или чинить.
    ///
    /// Наружу отдаётся не сырое состояние, а выдержавшее паузу (макет 8c):
    /// прогрев и быстрая проверка файлов иначе успевают только мигнуть.
    func currentServiceStatus() -> ServiceStatusKind {
        if let previewStatusOverride { return previewStatusOverride }
        let settled = statusHold.settle(rawServiceStatus())
        scheduleStatusHoldWakeup()
        return settled
    }

    /// Будильник на конец паузы. Без него созревшее состояние ждало бы
    /// очередного тика таймера обновления — до 0,75 с сверх задержки.
    private func scheduleStatusHoldWakeup() {
        statusHoldTimer?.invalidate()
        statusHoldTimer = nil
        guard let deadline = statusHold.pendingDeadline else { return }
        let delay = max(0.05, deadline.timeIntervalSinceNow)
        statusHoldTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func rawServiceStatus() -> ServiceStatusKind {
        let state = AgentRuntimeStateStore.read()
        let running = DictorAgentService.isAgentRunning()

        if state?.isUpdating == true { return .updating }
        if let operation = serviceOperation, operation != .stopping { return .starting }
        if !settings.agentEnabled && !running { return .off }
        if !running { return .failed }

        if let missing = state?.missingPermissions, let first = missing.first,
           let permission = Permission(rawValue: first) {
            return .needsPermission(name: permissionTitle(permission))
        }

        // Служба может работать из бандла прошлой версии — так бывает, когда
        // человек ставит обновление вручную поверх работающего приложения.
        if let running = state?.appVersion, running != currentBundleVersion() {
            return .versionMismatch(running: running, installed: currentBundleVersion())
        }

        switch state?.status {
        case "ready":
            return .ready(latencyMilliseconds: state?.medianLatencyMilliseconds,
                          modelUpdate: state?.speechModelUpdate)
        // Пауза из панели меню-бара: раньше окно её не видело и подвал
        // показывал «Готово», пока хоткей нарочно молчал (аудит №11).
        case "paused":
            return .paused
        case "error":
            return serviceStatusForErrorState(failureReason: state?.failureReason)
        default:
            if let verified = state?.verifiedModelFiles, let total = state?.totalModelFiles {
                return .verifying(done: verified, total: total)
            }
            if state?.speechModelReady == false,
               state?.downloadProgressFraction != nil || state?.downloadedModelFiles != nil {
                return .downloading(fraction: state?.downloadProgressFraction,
                                    files: state?.downloadedModelFiles,
                                    totalFiles: state?.totalDownloadModelFiles)
            }
            if state?.speechModelReady == true { return .warmingUp }
            return .starting
        }
    }

    /// Низ сайдбара по макету 8a. Маркер 7×7 в 16 px от края, заголовок 11,5,
    /// вторая строка 11 — и то, и другое всегда на одном месте: меняется
    /// только форма маркера, движение и высота подвала.
    private func makeSidebarStatusView() -> NSView {
        let kind = currentServiceStatus()
        let view = serviceStatusPresentation(kind, language: language)

        let marker = ServiceStatusMarkerView()
        marker.translatesAutoresizingMaskIntoConstraints = false
        switch kind {
        case .ready: marker.shape = .dot(SD.C.positive)
        case .versionMismatch: marker.shape = .hollowSquare
        // Пауза, как и «выключено», — намеренный покой: кольцо, без движения.
        case .off, .paused: marker.shape = .hollowRing
        // «Нет микрофона» — ожидание человека, как и доступ: пустой квадрат.
        case .needsPermission, .noMicrophone: marker.shape = .hollowSquare
        case .failed: marker.shape = .filledSquare(SD.C.danger)
        default: marker.shape = .wave(slow: kind.waveIsSlow)
        }

        let titleLabel = panelLabel(view.title,
                                    size: 11.5,
                                    weight: view.wantsAttention ? .semibold : .regular,
                                    color: view.wantsAttention
                                        ? SD.C.ink
                                        : (kind == .off ? SD.C.subtle : SD.C.inkSecondary))
        titleLabel.lineBreakMode = .byTruncatingTail

        let head = NSStackView(views: [marker, titleLabel])
        head.orientation = .horizontal
        head.alignment = .centerY
        head.spacing = 8

        let detail = panelLabel(view.subtitle, size: 11,
                                color: kind == .off ? SD.C.hintText : SD.C.subtle)
        // Две строки и перенос по словам: «Parakeet · локально · отклик 180 мс»
        // в 188 px одной строкой не помещается, а многоточие вместо числа —
        // ровно та подпись, ради которой строка и нужна.
        detail.maximumNumberOfLines = 2
        detail.preferredMaxLayoutWidth = 188

        let hairline = SDHairlineView()
        let column = NSStackView(views: [hairline, head, detail])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 5
        column.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 14, right: 16)
        column.setCustomSpacing(14, after: hairline)
        column.translatesAutoresizingMaskIntoConstraints = false

        // Прогресс: засечки по числу файлов модели либо сплошная полоса
        // загрузки. И то, и другое — под второй строкой, с отступом 7.
        if let ticks = view.ticks {
            let ticksView = ServiceStatusTicksView()
            ticksView.done = ticks.done
            ticksView.total = ticks.total
            ticksView.translatesAutoresizingMaskIntoConstraints = false
            ticksView.heightAnchor.constraint(equalToConstant: 5).isActive = true
            column.addArrangedSubview(ticksView)
            column.setCustomSpacing(7, after: detail)
            ticksView.widthAnchor.constraint(equalToConstant: 188).isActive = true
        } else if let fraction = view.progressFraction {
            let bar = ServiceStatusProgressView()
            bar.fraction = fraction
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
            column.addArrangedSubview(bar)
            column.setCustomSpacing(7, after: detail)
            bar.widthAnchor.constraint(equalToConstant: 188).isActive = true
        }

        // Кнопка есть только там, где нужен человек, — она и есть сигнал.
        if let primary = view.primaryAction {
            let button = SDSolidButton(title: primary,
                                       target: self,
                                       action: #selector(serviceStatusPrimaryClicked(_:)))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            if let secondary = view.secondaryAction {
                let quiet = SDSecondaryButton(title: secondary,
                                              target: self,
                                              action: #selector(serviceStatusSecondaryClicked(_:)))
                quiet.translatesAutoresizingMaskIntoConstraints = false
                quiet.heightAnchor.constraint(equalToConstant: 24).isActive = true
                let row = NSStackView(views: [button, quiet])
                row.orientation = .horizontal
                row.alignment = .centerY
                row.spacing = 6
                row.distribution = .fill
                // Главная кнопка занимает остаток строки, тихая — по тексту.
                // Без этого «Запустить» сжималась до многоточия.
                quiet.setContentHuggingPriority(.required, for: .horizontal)
                quiet.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.setContentHuggingPriority(.defaultLow, for: .horizontal)
                row.translatesAutoresizingMaskIntoConstraints = false
                column.addArrangedSubview(row)
                row.widthAnchor.constraint(equalToConstant: 188).isActive = true
            } else {
                column.addArrangedSubview(button)
                button.widthAnchor.constraint(equalToConstant: 188).isActive = true
            }
            column.setCustomSpacing(8, after: column.arrangedSubviews[column.arrangedSubviews.count - 2])
        }

        let container = ServiceStatusFooterView()
        // Подложка лёгким тревожным цветом — только у отказа. У «нужен доступ»
        // подложки нет: это ожидание действия, а не поломка.
        container.fill = kind == .failed ? SD.C.dangerWash : .clear
        container.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            column.topAnchor.constraint(equalTo: container.topAnchor),
            column.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        hairline.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        return container
    }

    /// Точка входа для рендера: собирает подвал для заданного состояния,
    /// не спрашивая живую службу.
    func serviceStatusFooterPreview(for kind: ServiceStatusKind,
                                    language: InterfaceLanguage) -> NSView {
        previewStatusOverride = kind
        defer { previewStatusOverride = nil }
        return makeSidebarStatusView()
    }

    @objc private func serviceStatusPrimaryClicked(_ sender: Any?) {
        switch currentServiceStatus() {
        case .needsPermission:
            // Разрешения — состояние службы, и живут они во вкладке «Служба».
            // Подвал сайдбара ведёт ровно туда, где ответ.
            openServiceTab()
        case .failed:
            settings.agentEnabled = true
            _ = settings.refreshFromDisk()
            beginServiceOperation(.starting)
        case .versionMismatch:
            beginServiceOperation(.restarting)
        default:
            break
        }
    }

    @objc private func serviceStatusSecondaryClicked(_ sender: Any?) {
        openServiceTab()
    }

    /// Поповер попросил открыть раздел в уже запущенном окне.
    @objc func openSectionRequested(_ notification: Notification) {
        guard let raw = notification.object as? String,
              let section = MainWindowSection(rawValue: raw) else { return }
        if section == .settings {
            settingsDraft = ControlPanelSettingsDraft(settings: settings)
        }
        mainSection = section
        hotkeyNotice = nil
        refresh(force: true)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Служба уходит и уводит окно за собой. Останавливать её отсюда не надо —
    /// она уже сняла себя сама, а повторный bootout из второго процесса только
    /// гонялся бы за уже мёртвым джобом.
    @objc func quitRequestedByAgent(_ notification: Notification) {
        log("control panel: quitting because the menu-bar app is quitting")
        NSApp.terminate(nil)
    }

    /// ⌘Q и «Выйти из Dictor» в меню окна. Раньше выход из окна оставлял
    /// службу работать: иконка в меню-баре, живой хоткей и процесс, который
    /// человек только что попросил закрыть. Спрашиваем, потому что диктовка
    /// перестанет работать до следующего запуска, и потому что рядом есть
    /// «Закрыть окно» — ровно для случая «уберите с глаз, но не выключайте».
    @objc func quitEverythingClicked(_ sender: Any?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = t("Выйти из Dictor?", "Quit Dictor?")
        alert.informativeText = t(
            "Диктовка по \(settings.configuredHotkey.name) перестанет работать, пока вы не "
            + "откроете Dictor снова. Чтобы убрать окно и оставить диктовку — "
            + "«Закрыть окно» (⌘W).",
            "Dictation on \(settings.configuredHotkey.name) will stop until you open Dictor "
            + "again. To hide the window and keep dictation running, use Close "
            + "Window (⌘W).")
        alert.addButton(withTitle: t("Оставить работать", "Keep Running"))
        alert.addButton(withTitle: t("Выйти", "Quit"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        log("control panel: quitting the app and the dictation service")
        // Здесь ждать можно: это окно, а не агент. Дедлок ловил только сам
        // агент, который своим bootout ждал собственной смерти.
        Self.applyQuitSideEffects(settings: settings,
                                  stopService: DictorAgentService.stop)
        NSApp.terminate(nil)
    }

    /// Всё, что полный выход делает помимо закрытия окна. Вынесено из
    /// `quitEverythingClicked` ради self-теста «quit-state»: однажды выход
    /// записывал `agentEnabled = false`, флаг переживал перезапуск, и
    /// следующее открытие Dictor поднимало окно без службы и без иконки в
    /// меню-баре — вопреки обещанию диалога «пока вы не откроете Dictor
    /// снова». Выход — про «сейчас», тумблер службы — про «насовсем»,
    /// поэтому настроек здесь не трогаем; выход из меню-бара их тоже не
    /// трогает — пути совпадают. Новые дисковые эффекты выхода добавляйте
    /// сюда, а не в обработчик кнопки, иначе они пройдут мимо теста.
    nonisolated static func applyQuitSideEffects(settings: Settings,
                                                 stopService: () -> Void) {
        stopService()
    }

    /// Решение панели при старте: поднимать ли службу. Пара к
    /// `applyQuitSideEffects` в self-тесте «quit-state»: вместе они
    /// закрепляют сценарий «вышел → открыл снова → служба вернулась».
    nonisolated static func shouldStartAgentOnLaunch(agentEnabled: Bool,
                                                     agentAlreadyRunning: Bool) -> Bool {
        agentEnabled && !agentAlreadyRunning
    }

    @objc private func sidebarItemClicked(_ sender: SDSidebarItemView) {
        guard sender.section != mainSection else { return }
        if sender.section == .settings {
            settingsDraft = ControlPanelSettingsDraft(settings: settings)
        } else {
            hotkeyRecorder?.cancel()
            hotkeyRecorder = nil
            settingsDraft = nil
        }
        mainSection = sender.section
        refresh(force: true)
    }
}
