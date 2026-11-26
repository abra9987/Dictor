// Самотест settings-reachable: каждая показанная строка реестра настроек
// находится на живой вкладке и принимает клик.

import AppKit

#if DEBUG
extension DictorSelfTest {
    /// Достижимость настроек — по реестру SETTINGS_CATALOG. Класс дефекта
    /// «настройка есть, работает и недостижима» дважды доходил до релиза;
    /// сверку реестра со списком var в Settings.swift держит check.sh, а
    /// здесь каждая строка `settingsRow` проверяется на живой вкладке:
    /// строка нашлась, hitTest в центре контрола попадает в контрол, строка
    /// не отрезана раскладкой, безопасные тумблеры кликом меняют Settings.
    static func testSettingsReachability() throws {
        try MainActor.assumeIsolated {
            let settings = Settings.shared
            let savedLanguage = settings.interfaceLanguage
            settings.interfaceLanguage = .russian
            defer { settings.interfaceLanguage = savedLanguage }

            // Две строки показываются по условию: «Сочетание завершения»
            // живёт при включённом альтернативном завершении, «Задержка перед
            // Enter» оживает при выбранном Enter. Достижимость проверяется в
            // том состоянии, где строка вправду работает, — иначе тест ловил
            // бы приглушённый контрол и требовал от него отклика.
            let savedAlternate = settings.alternateCompletionEnabled
            let savedCompletion = settings.primaryCompletionBehavior
            settings.alternateCompletionEnabled = true
            settings.primaryCompletionBehavior = .insertAndEnter
            defer {
                settings.alternateCompletionEnabled = savedAlternate
                settings.primaryCompletionBehavior = savedCompletion
            }

            let panel = DictorControlPanelApp()
            // Та же ширина, что даёт вкладкам настоящее окно: раздел
            // «Настройки» = окно минус сайдбар минус линия-разделитель.
            let width = MAIN_WINDOW_SIZE.width - MAIN_WINDOW_SIDEBAR_WIDTH - 1

            @MainActor
            func rows(in view: NSView) -> [NSView & SettingsRowProviding] {
                var found: [NSView & SettingsRowProviding] = []
                if let row = view as? NSView & SettingsRowProviding { found.append(row) }
                for subview in view.subviews { found.append(contentsOf: rows(in: subview)) }
                return found
            }

            var byTab: [String: [(title: String, toggleTest: Bool, property: String)]] = [:]
            for entry in SETTINGS_CATALOG {
                if case .settingsRow(let tab, let title, let toggleTest) = entry.exposure {
                    byTab[tab, default: []].append((title, toggleTest, entry.property))
                }
            }

            // Вкладка из реестра обязана существовать. Без этой проверки
            // запись с чужим идентификатором молча получала бы вкладку по
            // умолчанию (`default:` в makeSettingsContentView) — и, если бы
            // заголовок там случайно нашёлся, тест прошёл бы на настройке,
            // до которой человеку не добраться.
            let known = Set(SETTINGS_TABS.map(\.id))
            for tab in byTab.keys.sorted() {
                try expect(known.contains(tab), equals: true,
                           "the catalog points at tab «\(tab)», which is not in SETTINGS_TABS")
            }
            // И наоборот: вкладка без единой строки — пустой экран, который
            // человек откроет и закроет. Вкладка «Модель» такой и была.
            // Исключение объявляется в самом списке вкладок и с причиной:
            // «Служба» показывает состояние, и настройкам там взяться неоткуда.
            for tab in SETTINGS_TABS {
                let hasRows = byTab[tab.id]?.isEmpty == false
                if let why = tab.holdsNoSettings {
                    try expect(hasRows, equals: false,
                               "tab «\(tab.id)» is declared settings-free (\(why)) "
                               + "but the catalog puts rows in it")
                } else {
                    try expect(hasRows, equals: true,
                               "tab «\(tab.id)» has no settings rows in the catalog")
                }
            }
            // Вкладка без настроек обязана объяснить себя человеку, а не
            // только реестру: строка вкладок обещает предпочтения, и без
            // подписи сверху обещание остаётся невыполненным.
            for tab in SETTINGS_TABS where tab.holdsNoSettings != nil {
                panel.settingsTab = tab.id
                let view = panel.makeSettingsContentView()
                view.frame = NSRect(x: 0, y: 0, width: width,
                                    height: DictorControlPanelApp.settingsContentHeight(
                                        for: view, width: width))
                view.layoutSubtreeIfNeeded()
                // @MainActor на вложенной функции обязателен: сама по себе
                // она nonisolated даже внутри assumeIsolated, и обращение к
                // NSTextField роняло сборку на CI при живой локальной.
                @MainActor
                func collect(_ v: NSView, into captions: inout [String]) {
                    if let label = v as? NSTextField, !label.stringValue.isEmpty {
                        captions.append(label.stringValue)
                    }
                    for sub in v.subviews { collect(sub, into: &captions) }
                }
                var captions: [String] = []
                collect(view, into: &captions)
                try expect(captions.contains { $0.contains("нечего настраивать") },
                           equals: true,
                           "tab «\(tab.id)» holds no settings and must say so on screen")
            }

            for (tab, expectations) in byTab.sorted(by: { $0.key < $1.key }) {
                panel.settingsTab = tab
                let view = panel.makeSettingsContentView()
                let height = DictorControlPanelApp.settingsContentHeight(for: view,
                                                                         width: width)
                view.frame = NSRect(x: 0, y: 0, width: width, height: height)
                view.layoutSubtreeIfNeeded()

                // Вкладки живут в скролле, поэтому «не выше панели» здесь —
                // потолок на взрыв раскладки, а не пиксельная граница: две
                // высоты окна с запасом покрывают самую длинную вкладку.
                try expect(height <= MAIN_WINDOW_SIZE.height * 2, equals: true,
                           "the \(tab) tab exploded to \(height) pt — nobody scrolls that")

                let tabRows = rows(in: view)
                for expectation in expectations {
                    guard let row = tabRows.first(where: { $0.rowTitle == expectation.title })
                    else {
                        throw SelfTestFailure.failed(
                            "\(expectation.property): row «\(expectation.title)» "
                            + "not found in the \(tab) tab")
                    }
                    // Строка не отрезана раскладкой.
                    let frameInView = row.convert(row.bounds, to: view)
                    try expect(view.bounds.contains(frameInView), equals: true,
                               "\(expectation.property): row «\(expectation.title)» "
                               + "sticks out of the \(tab) tab layout")

                    // Клик в центр контрола попадает в контрол, а не в
                    // соседний вью: так умерла кнопка очистки поиска.
                    let control = row.control
                    let centre = control.convert(NSPoint(x: control.bounds.midX,
                                                         y: control.bounds.midY),
                                                 to: view)
                    let hit = view.hitTest(centre)
                    let reachable = hit === control
                        || (hit?.isDescendant(of: control) ?? false)
                    try expect(reachable, equals: true,
                               "\(expectation.property): a click in the middle of "
                               + "«\(expectation.title)» lands on "
                               + (hit.map { "\(type(of: $0))" } ?? "nothing"))

                    // Безопасные тумблеры: клик обязан дойти до Settings.
                    if expectation.toggleTest {
                        guard let toggle = control as? SDToggle else {
                            throw SelfTestFailure.failed(
                                "\(expectation.property): toggleTest expects an SDToggle")
                        }
                        let before = toggle.isOn
                        let click = NSEvent.mouseEvent(
                            with: .leftMouseDown, location: centre, modifierFlags: [],
                            timestamp: 0, windowNumber: 0, context: nil,
                            eventNumber: 0, clickCount: 1, pressure: 1)!
                        toggle.mouseDown(with: click)
                        try expect(toggle.isOn, equals: !before,
                                   "\(expectation.property): the toggle did not flip")
                        toggle.mouseDown(with: click)
                        try expect(toggle.isOn, equals: before,
                                   "\(expectation.property): the toggle did not flip back")
                    }
                }
            }

            // «Поделиться словарём» — действие, а не настройка, и в реестр не
            // входит. Но кнопка, до которой не дотянуться, — тот же дефект,
            // поэтому проверяется здесь же и в обоих состояниях: с пустым
            // словарём она приглушена, с непустым обязана принимать нажатие.
            let savedCorrections = settings.transcriptCorrections
            defer { settings.transcriptCorrections = savedCorrections }
            let shareStates: [(corrections: [TranscriptCorrection], enabled: Bool)] = [
                ([], false),
                ([TranscriptCorrection(source: "проба", replacement: "Probe")], true),
            ]
            for state in shareStates {
                settings.transcriptCorrections = state.corrections
                panel.settingsTab = "text"
                let view = panel.makeSettingsContentView()
                view.frame = NSRect(x: 0, y: 0, width: width,
                                    height: DictorControlPanelApp.settingsContentHeight(
                                        for: view, width: width))
                view.layoutSubtreeIfNeeded()
                guard let row = rows(in: view).first(where: {
                    $0.rowTitle == "Поделиться словарём"
                }), let button = row.control as? NSButton else {
                    throw SelfTestFailure.failed(
                        "the «Поделиться словарём» row with its button is missing from the text tab")
                }
                let centre = button.convert(NSPoint(x: button.bounds.midX,
                                                    y: button.bounds.midY),
                                            to: view)
                let hit = view.hitTest(centre)
                try expect(hit === button || (hit?.isDescendant(of: button) ?? false),
                           equals: true,
                           "a click in the middle of «Поделиться словарём» lands on "
                           + (hit.map { "\(type(of: $0))" } ?? "nothing"))
                try expect(button.isEnabled, equals: state.enabled,
                           "the share button should be enabled only for a non-empty dictionary")
                let receiver = button.target as? NSObject
                try expect(button.action.map { receiver?.responds(to: $0) == true } ?? false,
                           equals: true,
                           "the share button has no receiver for its action")
            }

            // Порядок и подписи полного списка языков: каждый язык модели
            // достижим из попапа ровно один раз — новый case в enum не может
            // молча выпасть из окна.
            let order = dictationLanguageMenuOrder()
            try expect(Set(order).count == order.count
                        && Set(order) == Set(DictationLanguage.allCases),
                       equals: true,
                       "the language popup order must cover every DictationLanguage once")
        }
    }
}
#endif
