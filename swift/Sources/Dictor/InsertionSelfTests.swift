import AppKit

#if DEBUG
extension DictorSelfTest {
    /// Список слов вместо системного словаря: правило проверяется на своих
    /// словах и не зависит от того, какие словари стоят на машине.
    private struct ListLexicon: WordLexicon {
        let words: Set<String>
        func isWord(_ word: String) -> Bool { words.contains(word) }
    }

    /// Куда фоновая задача складывает результат для проверки срока ожидания.
    /// Пишет одна задача, читает тест после семафора — гонки тут нет.
    private final class DeadlineProbe: @unchecked Sendable {
        var quick: Int?
        var slow: Int? = 0
        var slowWaitSeconds = 0.0
    }

    /// Умная вставка. Правил два, и у каждого главное свойство одно — молчать,
    /// когда уверенности нет; поэтому отказов здесь проверяется больше, чем
    /// срабатываний.
    static func testSmartInsertion() throws {
        typealias Position = SmartInsertion.CaretPosition

        // Что стоит перед курсором.
        let positions: [(before: String?, expected: Position, why: String)] = [
            (nil, .unknown, "an unreadable field says nothing"),
            ("", .lineStart, "an empty field is a start"),
            ("Привет, ", .continuation(needsSpace: false, afterMark: true), "a comma continues the sentence"),
            ("Привет,", .continuation(needsSpace: true, afterMark: true), "a comma without a space needs one"),
            ("я думаю что", .continuation(needsSpace: true, afterMark: false), "a word continues the sentence"),
            ("цена 100 ", .continuation(needsSpace: false, afterMark: false), "a number continues the sentence"),
            ("Готово. ", .sentenceStart(needsSpace: false), "a period starts a new sentence"),
            ("Готово.", .sentenceStart(needsSpace: true), "a period without a space needs one"),
            ("Что?", .sentenceStart(needsSpace: true), "a question mark ends a sentence"),
            ("Да… ", .sentenceStart(needsSpace: false), "an ellipsis ends a sentence"),
            ("Первая строка.\n", .lineStart, "a new line is a start"),
            ("Первая строка\nвторая", .continuation(needsSpace: true, afterMark: false),
             "only the current line counts"),
            ("- ", .lineStart, "a list marker is not a sentence yet"),
            ("1) ", .lineStart, "a list number is not a sentence yet"),
            ("> ", .lineStart, "a quote marker is not a sentence yet"),
            ("➜  ~ ", .lineStart, "a shell prompt without letters is a start"),
            ("(как вчера) ", .continuation(needsSpace: false, afterMark: false), "a closing bracket is transparent"),
            ("«Привет!» ", .sentenceStart(needsSpace: false),
             "a closing quote after an exclamation is transparent"),
            ("он сказал \"", .unknown, "a straight quote after a space opens, not closes"),
            ("слово \"цитата\" ", .continuation(needsSpace: false, afterMark: false),
             "a straight quote pressed to a word closes"),
            ("слово - ", .continuation(needsSpace: false, afterMark: true), "a spaced hyphen works as a dash"),
            ("слово — ", .continuation(needsSpace: false, afterMark: true), "a dash continues the sentence"),
            ("кто-", .unknown, "a hyphen pressed to a word is the middle of a compound"),
            ("почта user@", .unknown, "a symbol before the caret says nothing"),
            ("см. https://example.com/", .unknown, "a slash before the caret says nothing"),
            ("привет 😀 ", .unknown, "an emoji before the caret says nothing"),
            ("текст (", .unknown, "an opening bracket says nothing"),
        ]
        for item in positions {
            try expect(SmartInsertion.caretPosition(textBeforeCaret: item.before),
                       equals: item.expected, "caret position: \(item.why)")
        }

        // Строчная буква: только то, что словарь знает в строчном виде.
        let lexicons = SmartInsertionLexicons(
            cyrillic: ListLexicon(words: ["привет", "это", "я", "буду", "дальше"]),
            latin: ListLexicon(words: ["the", "it", "that"]))
        let lowercase: [(text: String, expected: String?, why: String)] = [
            ("Привет, как дела.", "привет, как дела.", "an ordinary word goes lowercase"),
            ("Я думаю.", "я думаю.", "a one-letter Russian word goes lowercase"),
            ("The build passed.", "the build passed.", "an ordinary English word goes lowercase"),
            ("It's fine.", "it's fine.", "the word ends at the apostrophe"),
            ("Андрей придёт.", nil, "a name the dictionary knows only capitalised stays"),
            ("Claude ответил.", nil, "a Latin name stays"),
            ("GitHub упал.", nil, "capitals inside the word are spelling, not sentence case"),
            ("MCP работает.", nil, "an acronym stays"),
            ("I think so.", nil, "English «I» stays capital"),
            ("I'm here.", nil, "English «I'm» stays capital"),
            ("привет", nil, "already lowercase — nothing to change"),
            ("5 минут.", nil, "a digit is not a letter to lowercase"),
            ("«Привет».", nil, "text that starts with a quote is left alone"),
            ("Ελληνικά.", nil, "a script without a dictionary is left alone"),
        ]
        // Написание, заданное словарём, побеждает: «python» язык знает и
        // строчным, но заглавную ему дал встроенный набор.
        let dictionary = [TranscriptCorrection(source: "питон", replacement: "Python"),
                          TranscriptCorrection(source: "гугл док", replacement: "Google Docs"),
                          TranscriptCorrection(source: "эйпиай", replacement: "the API")]
        let protected = SmartInsertion.protectedWords(in: dictionary)
        try expect(protected, equals: ["Python", "Google", "Docs", "API"],
                   "protected words are the capitalised words of dictionary replacements")
        let wide = SmartInsertionLexicons(
            cyrillic: ListLexicon(words: ["привет"]),
            latin: ListLexicon(words: ["python", "the", "docs"]))
        try expect(SmartInsertion.lowercasingFirstWord("Python не собирается.", lexicons: wide),
                   equals: "python не собирается.",
                   "without the dictionary «Python» is just an English word")
        try expect(SmartInsertion.lowercasingFirstWord("Python не собирается.",
                                                       lexicons: wide,
                                                       protectedWords: protected),
                   equals: nil,
                   "a spelling the dictionary set must survive the lowercase rule")
        try expect(SmartInsertion.lowercasingFirstWord("The build passed.",
                                                       lexicons: wide,
                                                       protectedWords: protected),
                   equals: "the build passed.",
                   "a lowercase word inside a replacement protects nothing")
        for item in lowercase {
            try expect(SmartInsertion.lowercasingFirstWord(item.text, lexicons: lexicons),
                       equals: item.expected, "lowercase: \(item.why)")
        }
        try expect(
            SmartInsertion.lowercasingFirstWord(
                "Привет.", lexicons: SmartInsertionLexicons(cyrillic: nil, latin: nil)),
            equals: nil,
            "lowercase: without a dictionary the rule must stay silent")

        // Точка в реплике.
        let twelveWords = Array(repeating: "слово", count: 12).joined(separator: " ")
        let period: [(text: String, expected: String?, why: String)] = [
            ("Привет.", "Привет", "a one-word message loses the period"),
            ("Буду через пять минут.", "Буду через пять минут", "a short message loses the period"),
            (twelveWords + ".", twelveWords, "twelve words are still a short message"),
            (twelveWords + " слово.", nil, "thirteen words are a paragraph"),
            ("Привет!", nil, "an exclamation mark is meant"),
            ("Привет?", nil, "a question mark is meant"),
            ("Подожди...", nil, "three dots are not a period"),
            ("Да…", nil, "an ellipsis is not a period"),
            ("Привет. Как дела.", nil, "two sentences keep their punctuation"),
            ("Версия 3.5 вышла.", nil, "a dot inside leaves the text alone"),
            ("Первая строка\nвторая.", nil, "a multi-line text is not a short message"),
            ("Привет", nil, "nothing to drop"),
            (".", nil, "a lone period is not a message"),
            ("Там Иванов, Петров и др.", nil, "the period of an abbreviation is part of it"),
            ("Send it to Acme Inc.", nil, "an English abbreviation keeps its period"),
            ("Это я.", "Это я", "a one-letter word is not an abbreviation"),
        ]
        for item in period {
            try expect(SmartInsertion.droppingChatPeriod(item.text),
                       equals: item.expected, "chat period: \(item.why)")
        }

        // Всё вместе.
        func adjust(_ text: String, before: String?, app: String,
                    enter: Bool = false) -> SmartInsertionResult {
            SmartInsertion.adjust(text,
                                  context: InsertionContext(bundleIdentifier: app,
                                                            textBeforeCaret: before),
                                  lexicons: lexicons,
                                  sentWithEnter: enter)
        }
        let editor = "com.apple.TextEdit"
        let chat = "ru.keepcoder.Telegram"
        let cases: [(result: SmartInsertionResult, text: String, space: Bool, why: String)] = [
            (adjust("Это правильно.", before: "Я думаю, ", app: editor),
             "это правильно.", false, "continuation after a space"),
            (adjust("Это правильно.", before: "Я думаю,", app: editor),
             "это правильно.", true, "continuation pressed to the previous word"),
            (adjust("Это правильно.", before: "я думаю что ", app: editor),
             "это правильно.", false, "a bare word continues the sentence outside a chat"),
            (adjust("Андрей придёт.", before: "Я думаю,", app: editor),
             "Андрей придёт.", true, "a name keeps its capital but still gets the space"),
            (adjust("Дальше тесты.", before: "Готово.", app: editor),
             "Дальше тесты.", true, "a new sentence keeps its capital and gets the space"),
            (adjust("Это правильно.", before: "", app: editor),
             "Это правильно.", false, "the start of a field changes nothing"),
            (adjust("Это правильно.", before: nil, app: editor),
             "Это правильно.", false, "an unreadable field changes nothing"),
            (adjust("Это правильно.", before: "путь /usr/", app: editor),
             "Это правильно.", false, "an unknown position changes nothing"),
            (adjust("Буду через пять минут.", before: nil, app: editor),
             "Буду через пять минут.", false, "outside a chat the period stays"),

            // Мессенджер: точка снимается, только когда диктовка — всё сообщение.
            (adjust("Буду через пять минут.", before: nil, app: chat),
             "Буду через пять минут", false, "a chat message works without reading the field"),
            (adjust("Буду через пять минут.", before: "", app: chat),
             "Буду через пять минут", false, "an empty chat field takes the whole message"),
            (adjust("Привет. Как дела.", before: nil, app: chat),
             "Привет. Как дела.", false, "two sentences in a chat stay as dictated"),
            // Главный случай: вторая диктовка после реплики без точки. Раньше
            // она склеивалась с первой в «Привет я сегодня опоздаю».
            (adjust("Я сегодня опоздаю.", before: "Привет ", app: chat),
             "Я сегодня опоздаю.", false,
             "after a period-less message the next dictation keeps capital and period"),
            (adjust("Это правильно.", before: "Привет. ", app: chat),
             "Это правильно.", false, "a message built from pieces keeps its punctuation"),
            (adjust("Буду позже.", before: "ок, ", app: chat),
             "буду позже.", false, "a comma still continues the sentence in a chat"),
            (adjust("Буду позже.", before: "Привет. ", app: chat, enter: true),
             "Буду позже", false, "a dictation sent with Enter ends the message"),
            (adjust("Буду позже.", before: "Готово. ", app: editor, enter: true),
             "Буду позже.", false, "Enter outside a chat changes nothing"),
        ]
        for item in cases {
            try expect(item.result.text, equals: item.text, "smart insertion text: \(item.why)")
            try expect(item.result.leadingSpace, equals: item.space,
                       "smart insertion space: \(item.why)")
            // Сводка уходит в журнал, а журнал — в отчёт о проблеме.
            try expect(item.result.summary.contains(item.result.text), equals: false,
                       "the log summary must not carry the dictated text")
        }

        // Срок ожидания чтения: готовый результат приходит сразу, зависший —
        // не задерживает вставку дольше срока.
        let waited = DispatchSemaphore(value: 0)
        let outcome = DeadlineProbe()
        Task.detached {
            outcome.quick = await InsertionContextReader.value(of: Task { 7 }, within: 1)
            let startedAt = ProcessInfo.processInfo.systemUptime
            outcome.slow = await InsertionContextReader.value(
                of: Task { try? await Task.sleep(nanoseconds: 2_000_000_000); return 7 },
                within: 0.05)
            outcome.slowWaitSeconds = ProcessInfo.processInfo.systemUptime - startedAt
            waited.signal()
        }
        guard waited.wait(timeout: .now() + 5) == .success else {
            throw SelfTestFailure.failed("waiting for the caret text never returned")
        }
        try expect(outcome.quick, equals: 7, "a finished read must be delivered")
        try expect(outcome.slow, equals: nil, "a read that hangs must be abandoned")
        try expect(outcome.slowWaitSeconds < 1, equals: true,
                   "abandoning a hung read must not take as long as the read")

        // Терминал — не поле ввода: перед курсором там приглашение или рамка.
        // Исключение — Терминал macOS: его курсор стоит в поле Claude Code.
        try expect(SmartInsertion.readsCaretText(in: "com.googlecode.iterm2"), equals: false,
                   "caret text must not be read in an unverified terminal")
        try expect(SmartInsertion.readsCaretText(in: "com.apple.Terminal"), equals: true,
                   "caret text is read in Terminal, where the caret sits in the Claude Code prompt")
        // Хвост, который Терминал отдал пробой 9 ноября: рамка над полем и «❯ ».
        let claudeCodeEmpty = "────────────────\n❯ "
        try expect(SmartInsertion.caretPosition(textBeforeCaret: claudeCodeEmpty), equals: .lineStart,
                   "an empty Claude Code prompt is the start of a message")
        try expect(SmartInsertion.caretPosition(textBeforeCaret: claudeCodeEmpty + "привет как дела"),
                   equals: .continuation(needsSpace: true, afterMark: false),
                   "words typed after the Claude Code prompt are a phrase to continue")
        try expect(SmartInsertion.caretPosition(textBeforeCaret: claudeCodeEmpty + "Сделай так. "),
                   equals: .sentenceStart(needsSpace: false),
                   "after a full stop in the Claude Code prompt a new sentence starts")
        try expect(SmartInsertion.caretPosition(textBeforeCaret: "raul@Mac Dictor % "), equals: .unknown,
                   "a zsh prompt ends with a sign, and the rule leaves the text alone")
        try expect(SmartInsertion.caretPosition(textBeforeCaret: "raul@host:~$ "), equals: .unknown,
                   "a bash prompt ends with a sign, and the rule leaves the text alone")
        // Claude для Mac — Electron: без флага он не называет поле с фокусом.
        try expect(ElectronAccessibility.needsManualAccessibility(
                       bundleIdentifier: "com.anthropic.claudefordesktop"), equals: true,
                   "Claude for Mac gets the accessibility tree switched on")
        try expect(ElectronAccessibility.needsManualAccessibility(bundleIdentifier: editor), equals: false,
                   "other apps are not touched without the owner's consent")
        try expect(SmartInsertion.readsCaretText(in: editor), equals: true,
                   "caret text is read in ordinary apps")
        try expect(SmartInsertion.isChatApp(bundleIdentifier: editor), equals: false,
                   "a text editor is not a chat app")

        // Пробел умной вставки и хвост «После текста добавлять» складываются.
        try expect(pastedText(from: "это правильно.", suffix: .appendSpace, leadingSpace: true),
                   equals: " это правильно. ",
                   "the leading space and the suffix are both glue around the text")
        try expect(pastedText(from: "это правильно.", suffix: .none, leadingSpace: true),
                   equals: " это правильно.",
                   "the leading space does not depend on the suffix")

        // Выключатель: включено по умолчанию и читается из настроек.
        let settings = Settings.shared
        let saved = settings.smartInsertionEnabled
        defer { settings.smartInsertionEnabled = saved }
        settings.smartInsertionEnabled = false
        try expect(settings.smartInsertionEnabled, equals: false,
                   "smart insertion must be switchable off")
        settings.smartInsertionEnabled = true
        try expect(settings.smartInsertionEnabled, equals: true,
                   "smart insertion must be switchable back on")
    }

    static func testInsertionTargetTracking() throws {
        func target(pid: pid_t, window: UInt, element: UInt) -> FocusedInsertionTargetFrame {
            FocusedInsertionTargetFrame(
                frame: NSRect(x: 100, y: 100, width: 2, height: 18),
                visualFrame: NSRect(x: 80, y: 80, width: 300, height: 48),
                resolutionKind: "self-test",
                identity: FocusedInsertionTargetIdentity(
                    applicationPID: pid,
                    windowToken: window,
                    elementToken: element
                )
            )
        }

        let first = target(pid: 10, window: 1, element: 1)
        let secondField = target(pid: 10, window: 1, element: 2)
        let otherApp = target(pid: 20, window: 2, element: 1)
        var stabilizer = RecordingHUDTargetStabilizer()
        stabilizer.reset(initialApplicationPID: 10)

        switch stabilizer.observe(first) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "initial target from the starting app should be accepted immediately")
        default:
            throw SelfTestFailure.failed("initial insertion target was not accepted")
        }

        switch stabilizer.observe(first) {
        case .update(let accepted):
            try expect(accepted.identity, equals: first.identity,
                       "the confirmed insertion target should update without another switch")
        default:
            throw SelfTestFailure.failed("confirmed insertion target did not produce an update")
        }

        if case .none = stabilizer.observe(secondField) {
            // Expected: a new field in the same app needs two matching observations.
        } else {
            throw SelfTestFailure.failed("same-app target switched without confirmation")
        }
        switch stabilizer.observe(secondField) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: secondField.identity,
                       "same-app target should switch after confirmation")
        default:
            throw SelfTestFailure.failed("same-app target did not switch after confirmation")
        }

        for attempt in 1...2 {
            if case .none = stabilizer.observe(otherApp) {
                continue
            }
            throw SelfTestFailure.failed("cross-app target switched on observation \(attempt)")
        }
        switch stabilizer.observe(otherApp) {
        case .switchTarget(let accepted):
            try expect(accepted.identity, equals: otherApp.identity,
                       "cross-app target should switch after three stable observations")
        default:
            throw SelfTestFailure.failed("cross-app target did not switch after confirmation")
        }

        if case .none = stabilizer.observe(nil) {
            // A missing AX sample must not discard the confirmed target.
        } else {
            throw SelfTestFailure.failed("missing target unexpectedly changed HUD ownership")
        }
        switch stabilizer.observe(otherApp) {
        case .update:
            break
        default:
            throw SelfTestFailure.failed("confirmed target was lost after one missing AX sample")
        }

        let screen = InsertionTargetScreenGeometry(
            frame: NSRect(x: 0, y: 0, width: 1_920, height: 1_080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1_920, height: 1_055)
        )
        let context = InsertionTargetQueryContext(
            applicationPID: 10,
            applicationName: "self-test",
            bundleIdentifier: "self-test",
            screens: [screen],
            coordinateReferenceMaxY: screen.frame.maxY,
            lastClickPoint: nil
        )
        let documentFrame = NSRect(x: 560, y: 150, width: 946, height: 698)
        let caretFrame = NSRect(x: 582, y: 419, width: 2, height: 17)
        let documentVisualFrame = FocusedInsertionTargetLocator.visualTargetFrame(
            elementFrame: documentFrame,
            caretFrame: caretFrame,
            context: context
        )
        try expect(documentVisualFrame.minX, equals: documentFrame.minX,
                   "large editors should retain their block's left edge")
        try expect(documentVisualFrame.minY, equals: caretFrame.minY,
                   "large editors should anchor vertically to the caret line")
        try expect(documentVisualFrame.height, equals: caretFrame.height,
                   "large editors should not place the HUD above the whole document")

        let compactFrame = NSRect(x: 700, y: 120, width: 720, height: 96)
        try expect(
            FocusedInsertionTargetLocator.visualTargetFrame(
                elementFrame: compactFrame,
                caretFrame: NSRect(x: 720, y: 150, width: 2, height: 18),
                context: context
            ),
            equals: compactFrame,
            "compact composers should keep the HUD above the whole input block"
        )
    }

    static func testLiveInsertionTargetProbe() throws {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw SelfTestFailure.failed("frontmost application unavailable")
        }
        let screens = NSScreen.screens.map {
            InsertionTargetScreenGeometry(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
        let context = InsertionTargetQueryContext(
            applicationPID: app.processIdentifier,
            applicationName: app.localizedName ?? "unknown",
            bundleIdentifier: app.bundleIdentifier ?? "unknown",
            screens: screens,
            coordinateReferenceMaxY: screens.first?.frame.maxY ?? 0,
            lastClickPoint: nil
        )
        let result = FocusedInsertionTargetLocator.query(context: context)
        try expect(result.applicationPID, equals: app.processIdentifier,
                   "live target query should preserve the requested application")
        try expect(result.diagnostic.isEmpty, equals: false,
                   "live target query should always explain its result")
        let targetSummary = result.target.map {
            "\($0.resolutionKind) frame=\(NSStringFromRect($0.frame)) visual=\(NSStringFromRect($0.visualFrame))"
        } ?? "unavailable"
        print("AX_PROBE \(result.applicationName) (\(result.bundleIdentifier)): \(targetSummary); \(result.diagnostic)")
    }
}
#endif
