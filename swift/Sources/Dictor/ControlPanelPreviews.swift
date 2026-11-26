import AppKit

// MARK: - Превью настроек (для визуальной сверки с макетом)

struct SettingsPreviewExportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
func exportSettingsPanelPreviews(to directory: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let panel = DictorControlPanelApp()
    // Ширина настоящая: раздел «Настройки» = окно минус сайдбар минус линия.
    // На 620 вкладки мерились уже, и это давало ложные «строки вылезли».
    let size = NSSize(width: MAIN_WINDOW_SIZE.width - MAIN_WINDOW_SIDEBAR_WIDTH - 1,
                      height: 560)
    // Вне NSWindow layer-backed view не проходит через window server и
    // bitmapImageRepForCachingDisplay возвращает пустой битмап — поэтому
    // рендерим в офскрин-окне.
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.colorSpace = .sRGB
    var exported = 0
    for tab in SETTINGS_TABS.map(\.id) {
        panel.settingsTab = tab
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                         ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearanceName)
            let view = panel.makeSettingsContentView()
            let height = DictorControlPanelApp.settingsContentHeight(for: view,
                                                                     width: size.width)
            window.setContentSize(NSSize(width: size.width, height: height))
            view.frame = NSRect(origin: .zero,
                                size: NSSize(width: size.width, height: height))
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw SettingsPreviewExportError(message: "no bitmap rep for \(tab)-\(suffix)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SettingsPreviewExportError(message: "PNG encode failed for \(tab)-\(suffix)")
            }
            let url = directory.appendingPathComponent("settings-\(tab)-\(suffix).png")
            try png.write(to: url, options: .atomic)
            exported += 1
        }
    }

    // Отдельными кадрами — строка «Версия» в трёх состояниях. «Доступно»:
    // у вкладки «Приложение» появляется точка, и это единственное место, где
    // она вообще бывает. «Скачивание» и «сбой» — тексты загрузчика как в бою:
    // сбой длинный, и влезает ли он в подзаголовок, видно только на снимке.
    let previewLanguage = Settings.shared.interfaceLanguage
    let updateStates: [(String, ControlPanelUpdateState)] = [
        ("update", .available(DictorRelease(tagName: "v1.8.0", version: "1.8.0",
                                            body: "", htmlURL: ""))),
        ("updating", .preparing(version: "1.8.0", phase: updateDownloadPhaseText(
            UpdateDownloadProgress(received: 1_234_567, total: 4_292_088, attempt: 2),
            language: previewLanguage, capitalized: false))),
        ("update-failed", .failed(DictorUpdateInstallerError
            .downloadInterrupted(received: 1_234_567, total: 4_292_088)
            .message(language: previewLanguage))),
    ]
    panel.settingsTab = "app"
    for (stateName, state) in updateStates {
    panel.updateState = state
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeSettingsContentView()
        let height = DictorControlPanelApp.settingsContentHeight(for: view, width: size.width)
        window.setContentSize(NSSize(width: size.width, height: height))
        view.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: height))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for \(stateName)-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for \(stateName)-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("settings-app-\(stateName)-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }
    }
    panel.updateState = .notChecked

    // И ещё одним — «Служба», пока распознаёт модель прошлой версии.
    panel.previewModelUpdateOverride = SpeechModelUpdateStatus(
        previousModelName: SpeechModelPackage.previous.profile.shortName,
        phase: .downloading,
        fraction: 0.34)
    panel.settingsTab = "service"
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeSettingsContentView()
        let height = DictorControlPanelApp.settingsContentHeight(for: view, width: size.width)
        window.setContentSize(NSSize(width: size.width, height: height))
        view.frame = NSRect(origin: .zero, size: NSSize(width: size.width, height: height))
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for model-update-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for model-update-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("settings-service-model-update-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }
    panel.previewModelUpdateOverride = nil

    window.contentView = nil
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("SETTINGS_PREVIEW exported \(exported) files to \(directory.path)")
}

/// Превью главного окна истории. Сеет сэмпл-данные в defaults ТЕКУЩЕГО
/// процесса (CLI-домен, не приложение) и рендерит светлый/тёмный вариант.
@MainActor
func exportHistoryPanelPreviews(to directory: URL,
                                language: InterfaceLanguage? = nil) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    let now = Date()
    let settings = Settings.shared
    // Превью подменяет историю и статистику сэмплами. Раньше подмена была
    // безвозвратной: запуск ключа у установленного .app стирал реальные
    // диктовки пользователя. Снимаем состояние и возвращаем его на выходе.
    let savedEntries = settings.recentTranscriptEntries
    let savedUsage = settings.dailyDictationUsage
    // Язык — тем же приёмом, что история: подменяем и возвращаем. Нужен для
    // англоязычных снимков в витрине проекта; настройка общая с работающим
    // приложением, поэтому возврат обязателен даже при исключении.
    let savedLanguage = settings.interfaceLanguage
    if let language { settings.interfaceLanguage = language }
    // Закрытые подсказки — тем же приёмом. Иначе «Сегодня» снимается без
    // плашки подсказки у всякого, кто хоть раз её закрыл, и проверить эмаль
    // (макет 8d) рендером нечем.
    let savedDismissedHints = settings.dismissedHints
    settings.dismissedHints = []
    // Словарь — тоже сэмплами: у чистой копии он пуст, и «Словарь» снимался
    // пустым экраном «Пока пусто», хотя показывать надо, как раздел работает.
    let savedCorrections = settings.transcriptCorrections
    settings.transcriptCorrections = settings.interfaceLanguage == .english
        ? [TranscriptCorrection(source: "kubernetis", replacement: "Kubernetes"),
           TranscriptCorrection(source: "postgres ql", replacement: "PostgreSQL"),
           TranscriptCorrection(source: "raoul", replacement: "Raul"),
           TranscriptCorrection(source: "dictor app", replacement: "Dictor")]
        : [TranscriptCorrection(source: "кубернетис", replacement: "Kubernetes"),
           TranscriptCorrection(source: "постгрес", replacement: "PostgreSQL"),
           TranscriptCorrection(source: "раул", replacement: "Раул"),
           TranscriptCorrection(source: "диктор", replacement: "Dictor")]
    // Кнопки строки «Сегодня» проявляются по наведению, а снимок делается
    // без курсора — иначе иконки не проверить рендером вовсе.
    SDRecentEntryRowView.previewForcesActionsVisible = true
    defer {
        settings.interfaceLanguage = savedLanguage
        settings.recentTranscriptEntries = savedEntries
        settings.dailyDictationUsage = savedUsage
        settings.dismissedHints = savedDismissedHints
        settings.transcriptCorrections = savedCorrections
        SDRecentEntryRowView.previewForcesActionsVisible = false
    }
    // Сэмплы на языке интерфейса: английские снимки с русскими диктовками
    // внутри выглядят как незаконченный перевод.
    let sampleTexts = settings.interfaceLanguage == .english
        ? ["Hey! Sending a short recap of the call and the three next steps — take a look before Friday",
           "Let's talk Thursday at three, I'll send the invite",
           "Headline: local dictation with no cloud — a look at Dictor",
           "We cut the beta scope down to the dictionary and the modes"]
        : ["Привет! По итогам звонка присылаю короткое резюме и три следующих шага, посмотри до пятницы",
           "Давай созвонимся в четверг в три, я закину приглашение",
           "Заголовок: локальная диктовка без облака — обзор Dictor",
           "Собираем бету в пятницу, режем скоуп до словаря и режимов"]
    settings.recentTranscriptEntries = [
        TranscriptHistoryEntry(text: sampleTexts[0],
                               transcriptionDurationSeconds: 1.2,
                               createdAt: now.addingTimeInterval(-3600)),
        TranscriptHistoryEntry(text: sampleTexts[1],
                               transcriptionDurationSeconds: 0.7,
                               createdAt: now.addingTimeInterval(-9000)),
        TranscriptHistoryEntry(text: sampleTexts[2],
                               transcriptionDurationSeconds: 0.6,
                               createdAt: now.addingTimeInterval(-16000)),
        TranscriptHistoryEntry(text: sampleTexts[3],
                               transcriptionDurationSeconds: 0.9,
                               createdAt: now.addingTimeInterval(-100_000)),
    ]
    var usage: [DailyDictationUsage] = []
    let calendar = Calendar.current
    for offset in 0..<30 {
        guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { continue }
        let key = dictationUsageDayKey(for: day, calendar: calendar)
        usage.append(DailyDictationUsage(day: key,
                                         dictationCount: 8,
                                         characterCount: 2500 + (offset * 137) % 2200,
                                         audioSeconds: 400,
                                         asrSeconds: 10))
    }
    settings.dailyDictationUsage = usage

    let panel = DictorControlPanelApp()
    // Витрина показывает рабочее состояние службы. Без этого подвал сообщал бы
    // о расхождении версий — правду про запуск из /tmp, но не про программу.
    panel.previewStatusOverride = .ready(latencyMilliseconds: 180)
    let size = MAIN_WINDOW_SIZE
    // Окно рендера повторяет настоящее: `.titled` + `.fullSizeContentView`.
    // В безрамочном окне AppKit не считает безопасную зону под тайтлбар — и
    // пустая полоса, которую скролл сам себе добавлял над первой строкой, в
    // превью не появлялась вовсе. Дефект, невидимый рендером, ловится только
    // глазами на живом окне; повторяем конфигурацию, чтобы не ловить.
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .fullSizeContentView],
                          backing: .buffered,
                          defer: false)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.colorSpace = .sRGB
    var exported = 0
    // Каждый раздел окна (макет 6a/6b) в обеих темах.
    for section in MainWindowSection.allCases {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                         ("dark", NSAppearance.Name.darkAqua)] {
            window.appearance = NSAppearance(named: appearanceName)
            panel.mainSection = section
            // «Статистику» снимаем ещё и в годовом периоде — там живёт
            // блок по кварталам с итогом (макет 7c).
            panel.statsPeriod = section == .stats ? .month : .month
            let name = "\(section.rawValue)-\(suffix)"
            let view = panel.makeMainWindowView()
            view.frame = NSRect(origin: .zero, size: size)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw SettingsPreviewExportError(message: "no bitmap rep for \(name)")
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw SettingsPreviewExportError(message: "PNG encode failed for \(name)")
            }
            try png.write(to: directory.appendingPathComponent("\(name).png"),
                          options: .atomic)
            exported += 1
        }
    }
    // История с набранным запросом. Без неё не проверить ни подсветку
    // совпадений, ни крестик очистки: пустое поле не показывает ни того,
    // ни другого.
    panel.mainSection = .history
    panel.mainHistorySearch = settings.interfaceLanguage == .english ? "call" : "звонка"
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeMainWindowView()
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for history-search-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for history-search-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("history-search-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }
    panel.mainHistorySearch = ""

    // Годовой разрез статистики (макет 7c). Окно превью выше рабочего,
    // чтобы карточка кварталов попала в кадр целиком, а не под прокрутку.
    panel.mainSection = .stats
    panel.statsPeriod = .year
    let tallSize = NSSize(width: size.width, height: 1180)
    window.setContentSize(tallSize)
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeMainWindowView()
        view.frame = NSRect(origin: .zero, size: tallSize)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for stats-year-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for stats-year-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("stats-year-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }

    // Отдельным кадром — график под курсором. Наведение это состояние вида,
    // и увидеть его надо картинкой: подпись столбика и есть та шкала,
    // которой у графика нет по оси Y.
    // Месяц и год — разные ветки подписи: у дней она из даты, у месяцев
    // года на оси метки нет вовсе, и подпись под курсором единственная.
    for (period, periodName) in [(StatsPeriod.month, "month"), (StatsPeriod.year, "year")] {
    panel.statsPeriod = period
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        let view = panel.makeMainWindowView()
        view.frame = NSRect(origin: .zero, size: tallSize)
        window.contentView = view
        view.layoutSubtreeIfNeeded()

        func findChart(_ v: NSView) -> SDComparisonBarChart? {
            if let chart = v as? SDComparisonBarChart { return chart }
            for sub in v.subviews {
                if let found = findChart(sub) { return found }
            }
            return nil
        }
        guard let chart = findChart(view) else {
            throw SettingsPreviewExportError(message: "no chart for stats-hover-\(periodName)-\(suffix)")
        }
        let point = NSPoint(x: chart.bounds.width * 0.62, y: chart.bounds.midY)
        let move = NSEvent.mouseEvent(
            with: .mouseMoved,
            location: chart.convert(point, to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 0, pressure: 0)!
        chart.mouseMoved(with: move)

        view.layoutSubtreeIfNeeded()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for stats-hover-\(periodName)-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for stats-hover-\(periodName)-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("stats-hover-\(periodName)-\(suffix).png"),
                      options: .atomic)
        exported += 1
    }
    }
    window.contentView = nil
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("HISTORY_PREVIEW exported \(exported) files to \(directory.path)")
}
