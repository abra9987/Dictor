import AppKit
import ApplicationServices

// MARK: - Печать вместо вставки в поле веб-страницы Chrome
//
// В Chrome ⌘V от Dictor в поля Google (Gemini, поиск) срабатывает через раз:
// «один раз вставится, потом нет». Разбор 13 ноября 2026 на живом Gemini:
// при сбое Chrome отдаёт странице пустой буфер (ни одного типа данных) и
// молча бросает вставку — событие paste есть, текста в поле нет, а Dictor
// пишет в журнал «paste=ok», потому что Chrome успел заглянуть в буфер.
// Вставка через буфер проходила от 1 из 16 до 7 из 7 в зависимости от того,
// чем и как буфер был записан до неё; точный спусковой крючок внутри Chrome
// не найден. Печать юникод-событиями прошла 13 из 13, кириллица и знаки
// целы, — она буфер не трогает вовсе.
//
// Поэтому это обход, а не устранение причины, и он нарочно узкий:
// - только Chrome — других браузеров в опытах не было;
// - только текстовое поле внутри веб-страницы. Без поля напечатанные буквы
//   стали бы горячими клавишами страницы (Gmail, YouTube), а ⌘V без поля
//   безвреден. Адресная строка — интерфейс самого Chrome: там вставка
//   работает, а посимвольная печать сцепилась бы с автодополнением.
//
// Цена печати: редактор видит набор, а не вставку — может применить свои
// правила ввода, и отмена может идти кусками.

enum BrowserTyping {
    /// Программы, где поле веб-страницы получает текст печатью. Пополнять
    /// только после опыта в самой программе — см. комментарий выше.
    static let bundleIdentifiers: Set<String> = [
        "com.google.Chrome",
    ]

    /// Роли, которые Chrome даёт полям ввода веб-страницы: textarea и
    /// contenteditable — AXTextArea, input — AXTextField, поле с подсказками —
    /// AXComboBox.
    static let textRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
    ]

    static let webAreaRole = "AXWebArea"

    /// Что известно о фокусе в момент вставки.
    struct FocusReading: Equatable {
        /// Роль элемента с фокусом; nil — программа не назвала его.
        var role: String?
        /// Элемент лежит внутри веб-страницы, а не в интерфейсе браузера.
        var isInsideWebArea: Bool
    }

    struct Choice: Equatable {
        var strategy: TextInsertionStrategy
        /// Для журнала: почему выбрано именно так.
        var reason: String
    }

    /// Чистое решение — его и проверяет самотест.
    static func choose(bundleIdentifier: String?, focus: FocusReading?) -> Choice {
        guard let bundleIdentifier, bundleIdentifiers.contains(bundleIdentifier) else {
            return Choice(strategy: TextInserter.defaultStrategy, reason: "not a typing browser")
        }
        guard let focus, let role = focus.role else {
            return Choice(strategy: TextInserter.defaultStrategy,
                          reason: "\(bundleIdentifier), focused element unknown")
        }
        guard textRoles.contains(role) else {
            return Choice(strategy: TextInserter.defaultStrategy,
                          reason: "\(bundleIdentifier), focused \(role) is not a text field")
        }
        guard focus.isInsideWebArea else {
            return Choice(strategy: TextInserter.defaultStrategy,
                          reason: "\(bundleIdentifier), \(role) belongs to the browser itself")
        }
        return Choice(strategy: .browserTyping,
                      reason: "\(bundleIdentifier), \(role) in a web page")
    }

    /// Решение для программы на переднем плане. Фокус спрашивается только у
    /// браузеров из списка: остальным лишний запрос ни к чему.
    @MainActor
    static func choiceForFrontmostApplication() -> Choice {
        let app = NSWorkspace.shared.frontmostApplication
        let bundleIdentifier = app?.bundleIdentifier
        guard let app, let bundleIdentifier, bundleIdentifiers.contains(bundleIdentifier) else {
            return choose(bundleIdentifier: bundleIdentifier, focus: nil)
        }
        return choose(bundleIdentifier: bundleIdentifier,
                      focus: readFocus(pid: app.processIdentifier))
    }

    /// Шаг печати: кусок текста или перевод строки.
    enum Step: Equatable {
        case text(String)
        case lineBreak
    }

    /// Перевод строки печатается как Shift+Return, а не символом: юникод-
    /// событие с «\n» Chrome отдаёт странице как Enter, и чат отправил бы
    /// сообщение. Shift+Return в чатах даёт новую строку — как при вставке.
    static func steps(for text: String) -> [Step] {
        var steps: [Step] = []
        var current = ""
        for character in text {
            if character.isNewline {
                if !current.isEmpty { steps.append(.text(current)) }
                current = ""
                steps.append(.lineBreak)
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { steps.append(.text(current)) }
        return steps
    }

    private static let shiftKeyCode: CGKeyCode = 0x38  // left Shift

    @MainActor
    static func type(_ text: String) -> Bool {
        var didPostAll = true
        for step in steps(for: text) {
            switch step {
            case .text(let chunk):
                didPostAll = DirectUnicodeInserter.insert(chunk) && didPostAll
            case .lineBreak:
                didPostAll = postKeyboardEventSteps([
                    KeyboardEventStep(virtualKey: shiftKeyCode, keyDown: true, flags: .maskShift),
                    KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: true, flags: .maskShift),
                    KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: false, flags: .maskShift),
                    KeyboardEventStep(virtualKey: shiftKeyCode, keyDown: false, flags: []),
                ]) && didPostAll
            }
        }
        return didPostAll
    }

    /// Роль элемента с фокусом и то, лежит ли он внутри веб-страницы.
    /// Таймаут короткий: вставка идёт на главном потоке, и зависший браузер
    /// не должен её задерживать — без ответа остаётся обычная вставка.
    private static func readFocus(pid: pid_t) -> FocusReading? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused = element(application, kAXFocusedUIElementAttribute) else {
            return nil
        }
        let role = string(focused, kAXRoleAttribute)
        var isInsideWebArea = false
        var ancestor = element(focused, kAXParentAttribute)
        // Глубина ограничена: поле Gemini лежит в дереве на пару десятков
        // уровней, а битое дерево не должно зациклить вставку.
        for _ in 0..<60 {
            guard let current = ancestor else { break }
            if string(current, kAXRoleAttribute) == webAreaRole {
                isInsideWebArea = true
                break
            }
            ancestor = element(current, kAXParentAttribute)
        }
        return FocusReading(role: role, isInsideWebArea: isInsideWebArea)
    }

    private static func element(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

// MARK: - Самотест

// Самотесты собираются только в отладочной сборке — как и весь SelfTests.swift.
#if DEBUG
extension DictorSelfTest {
    /// Решение «печатать или вставлять» и разбор текста на шаги печати.
    /// Достижимость обеспечена устройством: у `TextInserter` один открытый
    /// вход `insert(_:)`, и выбор способа живёт внутри него — обе точки
    /// вставки (диктовка и быстрая панель) проходят через выбор.
    static func testBrowserTyping() throws {
        let chrome = "com.google.Chrome"
        let webField = BrowserTyping.FocusReading(role: "AXTextArea", isInsideWebArea: true)

        try expect(BrowserTyping.choose(bundleIdentifier: chrome, focus: webField).strategy,
                   equals: .browserTyping,
                   "a text field inside a Chrome web page must be typed into")
        try expect(BrowserTyping.choose(
                       bundleIdentifier: chrome,
                       focus: .init(role: "AXTextField", isInsideWebArea: true)).strategy,
                   equals: .browserTyping, "an <input> in a page is a text field too")
        try expect(BrowserTyping.choose(
                       bundleIdentifier: chrome,
                       focus: .init(role: "AXTextField", isInsideWebArea: false)).strategy,
                   equals: .clipboardPaste,
                   "the address bar is Chrome's own UI: paste works there, typing fights autocomplete")
        try expect(BrowserTyping.choose(
                       bundleIdentifier: chrome,
                       focus: .init(role: "AXWebArea", isInsideWebArea: false)).strategy,
                   equals: .clipboardPaste,
                   "without a focused field typed letters would become page shortcuts")
        try expect(BrowserTyping.choose(
                       bundleIdentifier: chrome,
                       focus: .init(role: "AXGroup", isInsideWebArea: true)).strategy,
                   equals: .clipboardPaste, "a group is not a text field")
        try expect(BrowserTyping.choose(bundleIdentifier: chrome, focus: nil).strategy,
                   equals: .clipboardPaste, "an unknown focus keeps the safe paste")
        try expect(BrowserTyping.choose(bundleIdentifier: "com.anthropic.claudefordesktop",
                                        focus: webField).strategy,
                   equals: .clipboardPaste, "programs outside the list keep paste")
        try expect(BrowserTyping.choose(bundleIdentifier: nil, focus: webField).strategy,
                   equals: .clipboardPaste, "no frontmost program keeps paste")

        try expect(BrowserTyping.steps(for: "привет, мир "),
                   equals: [.text("привет, мир ")], "plain text is one chunk")
        try expect(BrowserTyping.steps(for: "строка\nещё\r\nконец\n"),
                   equals: [.text("строка"), .lineBreak, .text("ещё"), .lineBreak,
                            .text("конец"), .lineBreak],
                   "every newline, CRLF included, becomes Shift+Return instead of Enter")
        try expect(BrowserTyping.steps(for: ""), equals: [], "nothing to type")

        try expect(textInsertionStrategyChain(primary: .browserTyping),
                   equals: [.browserTyping, .clipboardPaste],
                   "if typing cannot be posted, paste is still tried")
    }
}
#endif
