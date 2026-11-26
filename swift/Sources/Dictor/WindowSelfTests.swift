import AppKit

#if DEBUG
extension DictorSelfTest {
    /// Плавающая капсула (макет 6c): прилипание к краям и удержание в
    /// пределах экрана. Проверить это мышью нельзя — нужен второй монитор,
    /// терпение и хорошая память на пиксели.
    static func testFloatingCapsuleGeometry() throws {
        let m = FloatingCapsuleMetrics.self
        // Экран без Дока и строки меню: visibleFrame, а не frame.
        let visible = NSRect(x: 0, y: 60, width: 1440, height: 840)
        let size = NSSize(width: 200 + m.shadowInset * 2, height: 30 + m.shadowInset * 2)

        func window(capsuleAt point: NSPoint) -> NSRect {
            // Из положения капсулы — положение окна: оно шире на поле под тень.
            NSRect(origin: NSPoint(x: point.x - m.shadowInset, y: point.y - m.shadowInset),
                   size: size)
        }

        // Отпущена в семи точках от левого края — прилипает и встаёт на 16.
        let nearLeft = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: NSPoint(x: visible.minX + 7, y: 400)),
            visibleFrame: visible)
        try expect(nearLeft.x + m.shadowInset, equals: visible.minX + m.snapMargin,
                   "a capsule dropped near the left edge should snap to it")

        // Отпущена посреди экрана — остаётся там, где её отпустили.
        let middlePoint = NSPoint(x: 600, y: 400)
        let middle = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: middlePoint), visibleFrame: visible)
        try expect(middle, equals: window(capsuleAt: middlePoint).origin,
                   "a capsule dropped in the open should stay where it was left")

        // Правый край: прилипает правым боком капсулы, а не окна.
        let nearRight = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: NSPoint(x: visible.maxX - 200 - 5, y: 400)),
            visibleFrame: visible)
        try expect(nearRight.x + m.shadowInset + 200,
                   equals: visible.maxX - m.snapMargin,
                   "the capsule's own right edge should land on the margin")

        // Низ экрана: над Доком, а не под ним.
        let nearBottom = FloatingCapsuleMetrics.snappedOrigin(
            windowFrame: window(capsuleAt: NSPoint(x: 600, y: visible.minY + 9)),
            visibleFrame: visible)
        try expect(nearBottom.y + m.shadowInset, equals: visible.minY + m.snapMargin,
                   "a capsule near the bottom should sit above the Dock, not under it")

        // Уехавшую за экран возвращаем: монитор мог отключиться или сменить
        // разрешение, и капсула осталась бы недосягаемой.
        let offscreen = FloatingCapsuleMetrics.clampedOrigin(
            NSPoint(x: 5000, y: -3000), windowSize: size, visibleFrame: visible)
        try expect(offscreen.x + m.shadowInset + 200, equals: visible.maxX,
                   "a capsule off the right side should come back to the edge")
        try expect(offscreen.y + m.shadowInset, equals: visible.minY,
                   "a capsule below the screen should come back to the bottom")

        // Состояния растут в одну сторону: покой → наведение → запись.
        try MainActor.assumeIsolated {
            let view = FloatingCapsuleView(frame: .zero)
            view.hotkeyTitle = "⌘ ⌥"
            let idle = view.capsuleWidth(for: .idle)
            let hover = view.capsuleWidth(for: .hover)
            let recording = view.capsuleWidth(for: .recording)
            try expect(idle < hover, equals: true,
                       "hover shows actions and must be wider than rest: \(idle) vs \(hover)")
            // Строго по макету 6c: запись — самое широкое состояние. Раньше
            // здесь стояла дизъюнкция (hover < recording || recording > idle),
            // которая при уже доказанном idle < hover почти не могла упасть.
            try expect(hover < recording, equals: true,
                       "recording is the widest state: \(hover) vs \(recording)")
            try expect(view.geometry.height(for: .idle)
                        < view.geometry.height(for: .recording), equals: true,
                       "the capsule grows from rest to recording, never shrinks")

            // Размер — общий с капсулой у курсора: в записи высоты совпадают
            // число в число, Large — макет 6c как есть, и ширина следует за
            // размером, а не остаётся от прежнего.
            let large = FloatingCapsuleGeometry(size: .large)
            try expect([large.idleHeight, large.hoverHeight, large.recordingHeight],
                       equals: [30, 40, 44],
                       "Large keeps the mockup 6c heights")
            for size in RecordingHUDSize.allCases {
                let geometry = FloatingCapsuleGeometry(size: size)
                try expect(geometry.recordingHeight, equals: size.capsuleHeight,
                           "recording height must match the cursor capsule for \(size.rawValue)")
                try expect(geometry.idleHeight < geometry.hoverHeight
                            && geometry.hoverHeight < geometry.recordingHeight, equals: true,
                           "states must grow rest → hover → recording for \(size.rawValue)")
                for pointSize in [geometry.hotkeyFontSize, geometry.dictateFontSize,
                                  geometry.historyFontSize, geometry.timerFontSize,
                                  geometry.hintFontSize] {
                    try expect(pointSize >= 10, equals: true,
                               "no capsule text may drop below 10 pt for \(size.rawValue)")
                }
            }
            view.geometry = FloatingCapsuleGeometry(size: .compact)
            let compactRecording = view.capsuleWidth(for: .recording)
            try expect(compactRecording < recording, equals: true,
                       "a compact capsule must be narrower than the large one: \(compactRecording) vs \(recording)")
            try expect(view.windowSize(for: .recording).height,
                       equals: RecordingHUDSize.compact.capsuleHeight + FloatingCapsuleMetrics.shadowInset * 2,
                       "the window follows the geometry height")
        }
    }

    /// Список «Истории» создаёт только видимые строки.
    ///
    /// Раньше он строил строку на каждую диктовку: на 1125 записях раскладка
    /// раздела занимала 27 секунд, и столько же — каждый клик и каждая буква
    /// в поиске, потому что окно пересобирается целиком. Заметить это на
    /// превью было нельзя: фикстура превью — четыре записи.
    ///
    /// Тест держит то, что экран снимком не показывает: число созданных строк
    /// не зависит от длины списка, а строка остаётся достижимой для мыши и
    /// умещается в видимую область.
    static func testHistoryListVirtualization() throws {
        try MainActor.assumeIsolated {
            final class Receiver: NSObject {
                var clickedIndex: Int?
                @objc func clicked(_ sender: SDHistoryResultRow) { clickedIndex = sender.entryIndex }
            }
            let receiver = Receiver()
            let rowCount = 5_000
            var created = 0
            let list = SDHistoryListView(rowCount: rowCount) { position in
                created += 1
                return SDHistoryResultRow(
                    entryIndex: position,
                    meta: "12 слов",
                    time: "10:00",
                    text: "Диктовка номер \(position): достаточно длинный текст, чтобы перенестись на вторую строку",
                    highlight: "",
                    isPinned: false,
                    isSelected: position == 0,
                    target: receiver,
                    action: #selector(Receiver.clicked(_:)))
            }
            let size = NSSize(width: 328, height: 600)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered,
                                  defer: false)
            list.frame = NSRect(origin: .zero, size: size)
            window.contentView = list
            list.layoutSubtreeIfNeeded()
            window.layoutIfNeeded()
            window.displayIfNeeded()

            try expect(list.materializedRowCount > 0, equals: true,
                       "the list must show something")
            try expect(list.materializedRowCount < 40, equals: true,
                       "only visible rows may exist as views, got \(list.materializedRowCount) of \(rowCount)")
            try expect(created < 200, equals: true,
                       "row construction must not scale with the list: \(created) rows built for \(rowCount) entries")

            @MainActor
            func firstRow(in view: NSView) -> SDHistoryResultRow? {
                if let row = view as? SDHistoryResultRow { return row }
                for subview in view.subviews {
                    if let found = firstRow(in: subview) { return found }
                }
                return nil
            }
            guard let row = firstRow(in: list) else {
                throw SelfTestFailure.failed("the list shows no row")
            }
            let rowFrame = row.convert(row.bounds, to: list)
            try expect(rowFrame.maxX <= list.contentView.frame.maxX + 0.5, equals: true,
                       "a row must fit the visible width: \(rowFrame.maxX) vs \(list.contentView.frame.maxX)")
            try expect(rowFrame.width > 200, equals: true,
                       "a row must take the column width, got \(rowFrame.width)")

            // Достижимость: точка внутри строки обязана попадать в неё, а не в
            // таблицу, — иначе клик достанется механизму выделения.
            let probe = NSPoint(x: rowFrame.midX, y: rowFrame.midY)
            var hit = list.hitTest(list.superview?.convert(probe, from: list) ?? probe)
            var reachedRow = false
            while let view = hit {
                if view === row { reachedRow = true; break }
                hit = view.superview
            }
            try expect(reachedRow, equals: true, "a click inside a row must land on the row")
            NSApp.sendAction(#selector(Receiver.clicked(_:)), to: receiver, from: row)
            try expect(receiver.clickedIndex, equals: row.entryIndex,
                       "the row must report which entry was clicked")
        }
    }

    /// Крестик очистки поиска по истории.
    ///
    /// Системный крестик NSSearchField в этом окне не работал вовсе: поле без
    /// рамки (`isBordered = false`) кладёт редактор текста на всю свою площадь
    /// и ещё на пару точек за края — замерено. Кнопка при этом честно
    /// рисовалась, но попадание мыши доставалось NSTextView, и нажатий она не
    /// видела ни одного. Нарисованная и мёртвая кнопка хуже отсутствующей,
    /// поэтому крестик теперь свой — и лежит за пределами поля.
    ///
    /// Тест сторожит именно достижимость: кнопка не должна пересекаться с
    /// полем и обязана иметь адресата.
    static func testHistorySearchClearButton() throws {
        try MainActor.assumeIsolated {
            let panel = DictorControlPanelApp()
            panel.mainSection = .history
            panel.mainHistorySearch = "звонка"
            let view = panel.makeMainWindowView()
            view.frame = NSRect(origin: .zero, size: MAIN_WINDOW_SIZE)
            view.layoutSubtreeIfNeeded()

            @MainActor
            func firstSearchField(in view: NSView) -> NSSearchField? {
                if let field = view as? NSSearchField { return field }
                for subview in view.subviews {
                    if let found = firstSearchField(in: subview) { return found }
                }
                return nil
            }

            guard let field = firstSearchField(in: view), let box = field.superview else {
                throw SelfTestFailure.failed("history search field not found")
            }
            guard let clear = box.subviews.compactMap({ $0 as? NSButton }).first else {
                throw SelfTestFailure.failed("clear button is missing while the query is not empty")
            }
            try expect(clear.target != nil && clear.action != nil, equals: true,
                       "the clear button must have somewhere to send the click")
            // Зазор в 4 pt: редактор поля вылезает за его границы примерно на
            // 3,5 pt, и меньший зазор снова спрятал бы кнопку под текст.
            try expect(clear.frame.minX >= field.frame.maxX + 4, equals: true,
                       "the clear button must sit clear of the text editor, " +
                       "button at \(clear.frame.minX), field ends at \(field.frame.maxX)")

            // И обратное: без запроса крестика быть не должно — стирать нечего.
            panel.mainHistorySearch = ""
            let empty = panel.makeMainWindowView()
            empty.frame = NSRect(origin: .zero, size: MAIN_WINDOW_SIZE)
            empty.layoutSubtreeIfNeeded()
            guard let emptyField = firstSearchField(in: empty),
                  let emptyBox = emptyField.superview else {
                throw SelfTestFailure.failed("history search field not found for the empty query")
            }
            try expect(emptyBox.subviews.contains(where: { $0 is NSButton }), equals: false,
                       "an empty query should show no clear button")
        }
    }

    /// Кнопки строки «Сегодня»: копировать и открыть запись целиком.
    ///
    /// Тест действия прошёл бы и на кнопке, до которой нельзя дотянуться —
    /// ровно так однажды и вышло с крестиком в поиске. Поэтому проверяется
    /// достижимость: у строки есть адресат обоих селекторов, значки не
    /// налезают на время, и `hitTest` в центре значка возвращает значок, а не
    /// лежащий поверх текст.
    static func testTodayRecentRowActions() throws {
        try MainActor.assumeIsolated {
            let panel = DictorControlPanelApp()
            let copySelector = Selector(("todayRecentRowClicked:"))
            let openSelector = Selector(("todayRecentRowOpen:"))
            try expect(panel.responds(to: copySelector), equals: true,
                       "the copy action has no receiver")
            try expect(panel.responds(to: openSelector), equals: true,
                       "the open action has no receiver")

            // Значки живут под наведением мыши; курсора в тесте нет, поэтому
            // включаем тот же режим, которым пользуется экспорт превью.
            SDRecentEntryRowView.previewForcesActionsVisible = true
            defer { SDRecentEntryRowView.previewForcesActionsVisible = false }

            let row = SDRecentEntryRowView(
                transcript: "Привет! По итогам звонка присылаю короткое резюме",
                entryIndex: 0,
                preview: "Привет! По итогам звонка присылаю короткое резюме",
                time: "14:32",
                copyTooltip: "Копировать",
                openTooltip: "Открыть целиком",
                target: panel,
                copyAction: copySelector,
                openAction: openSelector)
            row.frame = NSRect(x: 0, y: 0, width: 700, height: 48)
            row.layoutSubtreeIfNeeded()

            @MainActor
            func icons(in view: NSView) -> [SDRowIconButton] {
                if let button = view as? SDRowIconButton { return [button] }
                return view.subviews.flatMap(icons(in:))
            }
            let buttons = icons(in: row)
            try expect(buttons.count, equals: 2,
                       "the row should offer copy and open, nothing else")

            for button in buttons {
                // Значок без подписи молчит: tooltip здесь — единственное,
                // что объясняет, что случится по нажатию.
                try expect(button.toolTip?.isEmpty == false, equals: true,
                           "an icon button without a tooltip explains nothing")
                // Строка лежит в начале координат, поэтому её собственная
                // система совпадает с той, в которой считает `hitTest`.
                let centre = button.convert(NSPoint(x: button.bounds.midX,
                                                    y: button.bounds.midY),
                                            to: row)
                let hit = row.hitTest(centre)
                let reachable = hit === button || (hit?.isDescendant(of: button) ?? false)
                try expect(reachable, equals: true,
                           "a click in the middle of the icon lands on \(hit.map { "\(type(of: $0))" } ?? "nothing")")
            }

            // Значки не должны наезжать на время: макет 6a кладёт их правее,
            // и пересечение означало бы, что одно из двух не нажать.
            let timeLabel = { () -> NSTextField? in
                @MainActor
                func fields(in view: NSView) -> [NSTextField] {
                    if let field = view as? NSTextField { return [field] }
                    return view.subviews.flatMap(fields(in:))
                }
                return fields(in: row).first { $0.stringValue == "14:32" }
            }()
            guard let timeLabel else {
                throw SelfTestFailure.failed("the row lost its time label")
            }
            for button in buttons {
                let frame = button.convert(button.bounds, to: row)
                try expect(frame.minX >= timeLabel.frame.maxX, equals: true,
                           "an icon overlaps the time: icon at \(frame.minX), "
                           + "time ends at \(timeLabel.frame.maxX)")
                try expect(frame.maxX <= row.bounds.maxX, equals: true,
                           "an icon hangs off the row: \(frame.maxX) > \(row.bounds.maxX)")
            }

            // И последнее звено: действие доходит до эффекта. Кнопка с живым
            // адресатом, которая никуда не переключает, — тот же мёртвый код,
            // только с виду рабочий.
            let settings = Settings.shared
            let savedEntries = settings.recentTranscriptEntries
            defer { settings.recentTranscriptEntries = savedEntries }
            settings.recentTranscriptEntries = [
                TranscriptHistoryEntry(text: "первая диктовка",
                                       transcriptionDurationSeconds: 1,
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_000)),
                TranscriptHistoryEntry(text: "вторая диктовка",
                                       transcriptionDurationSeconds: 1,
                                       createdAt: Date(timeIntervalSince1970: 1_700_000_100)),
            ]
            panel.mainSection = .today
            // Запрос с прошлого раза не должен спрятать выбранную запись.
            panel.mainHistorySearch = "ничего такого в истории нет"
            let secondRow = SDRecentEntryRowView(
                transcript: "вторая диктовка",
                entryIndex: 1,
                preview: "вторая диктовка",
                time: "14:33",
                copyTooltip: "Копировать",
                openTooltip: "Открыть целиком",
                target: panel,
                copyAction: copySelector,
                openAction: openSelector)
            panel.perform(openSelector, with: secondRow)
            try expect(panel.mainSection.rawValue, equals: MainWindowSection.history.rawValue,
                       "opening an entry must switch the window to History")
            try expect(panel.mainHistorySearch, equals: "",
                       "a stale search query would hide the entry that was just opened")
            try expect(panel.historySelectionKey?.contains("вторая диктовка"), equals: true,
                       "History must select the very entry that was clicked, "
                       + "got \(panel.historySelectionKey ?? "nothing")")
        }
    }

    /// Пауза перед показом состояния службы (макет 8c). Проверять её живьём
    /// нечем: прогрев длится 0,2 с, и увидеть, что он не мигнул, можно только
    /// по часам.
    static func testServiceStatusHold() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

        // Первое состояние показывается сразу: пустой подвал хуже мигания.
        let hold = ServiceStatusHold()
        try expect(hold.settle(.ready(latencyMilliseconds: 180), now: at(0)).identity,
                   equals: "ready",
                   "first status should show without waiting")

        // Прогрев на 0,2 с не должен показаться вовсе.
        try expect(hold.settle(.warmingUp, now: at(0.1)).identity, equals: "ready",
                   "a fresh status must wait out the pause")
        try expect(hold.settle(.ready(latencyMilliseconds: 180), now: at(0.3)).identity,
                   equals: "ready",
                   "a status shorter than the pause must never reach the screen")

        // Состояние, которое выдержало паузу, показывается.
        try expect(hold.settle(.verifying(done: 3, total: 21), now: at(1.0)).identity,
                   equals: "ready",
                   "the pause starts when the new status appears")
        try expect(hold.settle(.verifying(done: 5, total: 21), now: at(1.3)).fingerprint,
                   equals: "verifying:5/21",
                   "a status that outlived the pause should be shown with fresh numbers")

        // Числа внутри показанного состояния идут без задержки: задержанный
        // прогресс — это вторая ложь вместо первой.
        try expect(hold.settle(.verifying(done: 9, total: 21), now: at(1.31)).fingerprint,
                   equals: "verifying:9/21",
                   "numbers inside the shown status must pass through immediately")

        // Пока пауза идёт, окно знает, когда её будить.
        let pending = ServiceStatusHold()
        _ = pending.settle(.ready(latencyMilliseconds: nil), now: at(0))
        try expect(pending.pendingDeadline, equals: nil,
                   "a settled status needs no wake-up")
        _ = pending.settle(.failed, now: at(1))
        try expect(pending.pendingDeadline, equals: at(1 + ServiceStatusHold.delay),
                   "a waiting status should ask for a wake-up at the end of the pause")
        _ = pending.settle(.failed, now: at(1.3))
        try expect(pending.pendingDeadline, equals: nil,
                   "a shown status should cancel its wake-up")
    }

    /// Сценарий «вышел → открыл снова»: выход обязан остановить службу
    /// сейчас, но не отключить её насовсем. Регрессия v1.7.0: выход из окна
    /// писал `agentEnabled = false`, флаг переживал перезапуск, и следующее
    /// открытие Dictor поднимало окно без службы — в меню-баре пусто,
    /// диктовка мертва, а диалог выхода обещал «пока вы не откроете Dictor
    /// снова». Тест гоняет реальные дисковые эффекты выхода против живых
    /// Settings и сверяет их с решением панели при следующем старте.
    static func testQuitLeavesServiceEnabled() throws {
        let settings = Settings.shared
        let saved = settings.agentEnabled
        defer { settings.agentEnabled = saved }

        // Служба была включена, человек вышел целиком.
        settings.agentEnabled = true
        var serviceStopped = false
        DictorControlPanelApp.applyQuitSideEffects(settings: settings,
                                                   stopService: { serviceStopped = true })
        try expect(serviceStopped, equals: true,
                   "quit must stop the running service")
        try expect(settings.agentEnabled, equals: true,
                   "quit must not disable the service for the next launch")
        try expect(DictorControlPanelApp.shouldStartAgentOnLaunch(
                       agentEnabled: settings.agentEnabled,
                       agentAlreadyRunning: false),
                   equals: true,
                   "after quit, reopening Dictor must bring the service back")

        // Служба выключена тумблером — выход не должен её воскрешать.
        settings.agentEnabled = false
        DictorControlPanelApp.applyQuitSideEffects(settings: settings,
                                                   stopService: {})
        try expect(settings.agentEnabled, equals: false,
                   "quit must not re-enable a service the user switched off")
        try expect(DictorControlPanelApp.shouldStartAgentOnLaunch(
                       agentEnabled: settings.agentEnabled,
                       agentAlreadyRunning: false),
                   equals: false,
                   "a switched-off service must stay off after reopening")

        // Служба уже работает — второй запуск не поднимает её повторно.
        try expect(DictorControlPanelApp.shouldStartAgentOnLaunch(
                       agentEnabled: true,
                       agentAlreadyRunning: true),
                   equals: false,
                   "a running service must not be started twice")
    }

    /// Наведение на график. Столбик без подписи оси и без шкалы Y сообщает
    /// ровно одно — «выше соседнего»; число под курсором и есть та шкала.
    /// Тест держит достижимость: за годом столбики уходят в три пикселя, и
    /// колонка обязана ловить курсор целиком, включая зазор и пустоту над
    /// коротким столбиком, — иначе часть чисел не увидеть вовсе.
    static func testStatsChartHover() throws {
        try MainActor.assumeIsolated {
            let buckets = (0..<30).map { index in
                StatsBucket(label: "день \(index + 1)",
                            words: index == 7 ? 46 : index,
                            previousWords: index % 4,
                            axisLabel: nil)
            }
            let chart = SDComparisonBarChart(buckets: buckets, peakIndex: 7, peakText: "46")
            chart.frame = NSRect(x: 0, y: 0, width: 700, height: 168)
            chart.layoutSubtreeIfNeeded()

            // Каждый столбик достижим мышью хотя бы в одной точке.
            var reachable = Set<Int>()
            for step in 0..<700 {
                if let index = chart.bucketIndex(at: NSPoint(x: CGFloat(step) + 0.5, y: 84)) {
                    reachable.insert(index)
                }
            }
            try expect(reachable.count, equals: buckets.count,
                       "every bucket must be hoverable; \(buckets.count - reachable.count) "
                       + "of \(buckets.count) cannot be pointed at")

            // Соседние столбики различимы: попадание не съезжает на один и
            // тот же индекс по всей ширине.
            try expect(chart.bucketIndex(at: NSPoint(x: 5, y: 84)), equals: 0,
                       "the leftmost pixel must hit the first bucket")
            try expect(chart.bucketIndex(at: NSPoint(x: 695, y: 84)),
                       equals: buckets.count - 1,
                       "the rightmost pixel must hit the last bucket")

            // Пустой столбик тоже отзывается: ноль — это ответ, а не промах.
            let zeroIndex = 0
            let zeroX = (700.0 / CGFloat(buckets.count)) * (CGFloat(zeroIndex) + 0.5)
            try expect(chart.bucketIndex(at: NSPoint(x: zeroX, y: 84)), equals: zeroIndex,
                       "a bucket with zero words must still be hoverable")

            // Подпись под курсором — про этот столбик, а не про пик.
            chart.calloutFormatter = { "\($0.label): \($0.words)" }
            let hoverX = (700.0 / CGFloat(buckets.count)) * 3.5
            let move = NSEvent.mouseEvent(
                with: .mouseMoved, location: NSPoint(x: hoverX, y: 84), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 0, pressure: 0)!
            chart.mouseMoved(with: move)
            try expect(chart.hoveredIndex, equals: 3,
                       "moving the mouse over the fourth column must select it")
            chart.mouseExited(with: move)
            try expect(chart.hoveredIndex, equals: nil,
                       "leaving the chart must hand the callout back to the peak")
        }
    }
}
#endif
