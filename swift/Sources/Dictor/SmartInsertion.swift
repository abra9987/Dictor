import AppKit
import ApplicationServices
import Foundation

// MARK: - Умная вставка
//
// Модель выдаёт каждую диктовку одинаково: с заглавной буквы и с точкой на
// конце, будто это всегда отдельное предложение. В поле она попадает
// по-разному — в середину начатой фразы, вплотную к предыдущему слову,
// репликой в мессенджер. Здесь два правила, которые подгоняют текст под
// место, и ничего сверх них:
//
//   1. Продолжение фразы. Перед курсором в той же строке стоит слово, запятая
//      или тире — диктовка продолжает начатое: первая буква становится
//      строчной, а если пробела перед курсором нет, он добавляется.
//   2. Реплика в мессенджере. Одно короткое предложение, которое и есть всё
//      сообщение, уходит без точки на конце.
//
// Правила не должны кормить друг друга. Реплика, у которой сняли точку,
// кончается словом — и следующая диктовка приняла бы её за начатую фразу:
// «Привет» + «Я опоздаю.» склеились бы в «Привет я опоздаю». Поэтому в
// мессенджере строчная буква ставится только после запятой или тире, а точка
// снимается, только когда сообщение целиком состоит из этой диктовки.
//
// Языковой модели здесь нет: правила читаются глазами и проверяются
// самотестом на строках. Главное их свойство — молчать, когда уверенности
// нет. Поле не отдало текст, перед курсором значок, а не слово, первое слово
// диктовки похоже на имя — текст уходит таким, каким пришёл. Испорченная
// заглавная в имени обиднее, чем лишняя заглавная посреди фразы.

/// Куда уйдёт диктовка: программа и хвост текста перед курсором.
struct InsertionContext: Equatable, Sendable {
    let bundleIdentifier: String
    /// `nil` — поле текст не отдало (нет разрешения, поле с паролем, программа
    /// без поддержки универсального доступа). Пустая строка — курсор в начале.
    let textBeforeCaret: String?
}

/// Словари, по которым решается, можно ли писать слово со строчной. Отдельной
/// структурой — чтобы самотест подставлял свои списки и не зависел от того,
/// какие словари стоят в системе.
struct SmartInsertionLexicons {
    let cyrillic: WordLexicon?
    let latin: WordLexicon?

    static var system: SmartInsertionLexicons {
        SmartInsertionLexicons(cyrillic: SystemLexicon.russian, latin: SystemLexicon.english)
    }
}

struct SmartInsertionResult: Equatable {
    /// Текст диктовки после правил. Он же ложится в «Историю»: там обязано
    /// быть ровно то, что вставлено.
    let text: String
    /// Пробел перед текстом. Это клей между соседями, а не часть диктовки, —
    /// как и хвост «После текста добавлять», в историю он не идёт.
    let leadingSpace: Bool
    /// Для журнала: что сработало. Без самого текста — журнал уходит в отчёт
    /// о проблеме.
    let summary: String
}

enum SmartInsertion {
    /// Длиннее — уже не реплика, а абзац, и точка в нём на месте.
    static let chatMessageMaxWords = 12

    enum CaretPosition: Equatable {
        /// Сказать нечего — текст не трогаем.
        case unknown
        /// В строке перед курсором ещё нет слов: начало поля, новая строка,
        /// маркер списка, приглашение командной строки.
        case lineStart
        case sentenceStart(needsSpace: Bool)
        /// `afterMark` — перед курсором запятая, двоеточие или тире, а не
        /// просто слово: знак говорит о продолжении однозначно, слово — нет.
        case continuation(needsSpace: Bool, afterMark: Bool)
    }

    /// - Parameters:
    ///   - protectedWords: слова, написание которых задано словарём
    ///     («Python», «Windows»). Явная правка человека обязана побеждать, и
    ///     делать такое слово строчным нельзя, даже если язык знает его
    ///     нарицательным. Замыканием — чтобы набор собирался, только когда
    ///     до строчной буквы вообще дошло.
    ///   - sentWithEnter: сразу после вставки будет нажат Enter, то есть
    ///     диктовка заканчивает сообщение.
    static func adjust(_ text: String,
                       context: InsertionContext,
                       lexicons: SmartInsertionLexicons,
                       protectedWords: () -> Set<String> = { [] },
                       sentWithEnter: Bool = false) -> SmartInsertionResult {
        var adjusted = text
        var leadingSpace = false
        var applied: [String] = []
        let isChat = isChatApp(bundleIdentifier: context.bundleIdentifier)

        let position = caretPosition(textBeforeCaret: context.textBeforeCaret)
        switch position {
        case .unknown, .lineStart:
            break
        case .sentenceStart(let needsSpace):
            leadingSpace = needsSpace
        case .continuation(let needsSpace, let afterMark):
            leadingSpace = needsSpace
            // В мессенджере слово без знака перед курсором — скорее всего
            // предыдущая реплика, у которой сняли точку, а не начатая фраза.
            if afterMark || !isChat,
               let lowered = lowercasingFirstWord(adjusted,
                                                  lexicons: lexicons,
                                                  protectedWords: protectedWords()) {
                adjusted = lowered
                applied.append("lowercase")
            }
        }
        if leadingSpace { applied.append("leading space") }

        // Точка снимается, только когда диктовка — всё сообщение: поле пусто,
        // поле не читается (тогда строчных букв не было и склеить нечего)
        // или сообщение сейчас уйдёт по Enter. В поле, где уже есть текст,
        // сообщение собирают из кусков, и пунктуация между ними нужна.
        let isWholeMessage = context.textBeforeCaret == nil
            || position == .lineStart
            || sentWithEnter
        if isChat, isWholeMessage, let withoutPeriod = droppingChatPeriod(adjusted) {
            adjusted = withoutPeriod
            applied.append("no final period")
        }

        return SmartInsertionResult(
            text: adjusted,
            leadingSpace: leadingSpace,
            summary: (applied.isEmpty ? "nothing" : applied.joined(separator: ", "))
                + " (\(describe(position)))")
    }

    // MARK: Что стоит перед курсором

    private static let sentenceTerminators: Set<Character> = [".", "!", "?", "…"]
    private static let continuationMarks: Set<Character> = [",", ";", ":", "–", "—"]
    private static let closers: Set<Character> = [")", "]", "}", "»", "”", "’"]
    private static let straightQuotes: Set<Character> = ["\"", "'"]

    static func caretPosition(textBeforeCaret: String?) -> CaretPosition {
        guard let textBeforeCaret else { return .unknown }
        // Только текущая строка: предыдущий абзац ничего не говорит о том,
        // чем начинается этот.
        let line = Array(textBeforeCaret
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .last ?? "")
        var end = line.count
        while end > 0, line[end - 1].isWhitespace { end -= 1 }
        let needsSpace = end == line.count

        // Пока в строке нет ни одной буквы, фраза ещё не начата: перед
        // курсором маркер списка, номер пункта, «>» цитаты или приглашение
        // командной строки. Всё это — начало, а не продолжение.
        guard line[..<end].contains(where: \.isLetter) else { return .lineStart }

        // Закрывающие скобки и кавычки прозрачны: «(как вчера) и ещё» —
        // продолжение, «„Привет!“ И ушёл» — новое предложение.
        var index = end
        while index > 0 {
            let character = line[index - 1]
            if closers.contains(character) {
                index -= 1
            } else if straightQuotes.contains(character), index >= 2,
                      !line[index - 2].isWhitespace {
                // Прямая кавычка закрывает, только если прижата к слову;
                // после пробела она открывает, и что будет внутри — неизвестно.
                index -= 1
            } else {
                break
            }
        }
        guard index > 0 else { return .unknown }
        let last = line[index - 1]

        if sentenceTerminators.contains(last) { return .sentenceStart(needsSpace: needsSpace) }
        if continuationMarks.contains(last) {
            return .continuation(needsSpace: needsSpace, afterMark: true)
        }
        if last.isLetter || last.isNumber {
            return .continuation(needsSpace: needsSpace, afterMark: false)
        }
        // Дефис в роли тире («слово - слово») — продолжение. Прижатый к
        // слову — середина составного слова, туда не диктуют.
        if last == "-", index >= 2, line[index - 2].isWhitespace {
            return .continuation(needsSpace: needsSpace, afterMark: true)
        }
        return .unknown
    }

    private static func describe(_ position: CaretPosition) -> String {
        switch position {
        case .unknown: return "position unknown"
        case .lineStart: return "line start"
        case .sentenceStart: return "sentence start"
        case .continuation: return "continuation"
        }
    }

    // MARK: Строчная буква в продолжении

    /// Диктовка с первой буквой в нижнем регистре — или `nil`, если трогать
    /// её нельзя.
    ///
    /// Модель пишет с заглавной и первое слово предложения, и имя, и по
    /// одному слову их не отличить. Поэтому строчной становится только то,
    /// что словарь языка знает именно в строчном виде: «привет» — слово,
    /// «андрей» и «claude» — нет. Нет словаря для этой письменности — правило
    /// молчит.
    ///
    /// Что правило знать не может: имя, совпадающее с обычным словом. «Вера
    /// придёт» в продолжении фразы станет «вера придёт».
    static func lowercasingFirstWord(_ text: String,
                                     lexicons: SmartInsertionLexicons,
                                     protectedWords: Set<String> = []) -> String? {
        guard let first = text.first, first.isLetter, first.isUppercase else { return nil }
        let word = text.prefix(while: \.isLetter)
        // GitHub, MCP, США: заглавные внутри слова — это написание, а не
        // начало предложения.
        guard !word.dropFirst().contains(where: \.isUppercase) else { return nil }
        // «Python» и «Windows» язык знает и строчными, но заглавную им дал
        // словарь — её и оставляем.
        guard !protectedWords.contains(String(word)) else { return nil }
        let lowered = word.lowercased()

        let lexicon: WordLexicon?
        if isCyrillic(first) {
            lexicon = lexicons.cyrillic
        } else if isLatin(first) {
            // Английское «I» остаётся заглавным где угодно.
            guard lowered != "i" else { return nil }
            lexicon = lexicons.latin
        } else {
            lexicon = nil
        }
        guard let lexicon, lexicon.isWord(lowered) else { return nil }
        return first.lowercased() + text.dropFirst()
    }

    /// Слова с заглавной буквы из правых частей словаря: то, чьё написание
    /// человек или встроенный набор задали явно.
    static func protectedWords(in corrections: [TranscriptCorrection]) -> Set<String> {
        var words: Set<String> = []
        for correction in corrections {
            for word in correction.replacement.split(whereSeparator: { !$0.isLetter })
            where word.first?.isUppercase == true {
                words.insert(String(word))
            }
        }
        return words
    }

    private static func isCyrillic(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { (0x0400...0x052F).contains($0.value) }
    }

    private static func isLatin(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy {
            (0x0041...0x005A).contains($0.value) || (0x0061...0x007A).contains($0.value)
                || (0x00C0...0x024F).contains($0.value)
        }
    }

    // MARK: Реплика в мессенджере

    /// Мессенджеры, у которых известен идентификатор программы. Веб-версии в
    /// браузере сюда не попадают: по идентификатору браузера не понять, что
    /// открыто во вкладке.
    private static let chatBundleIdentifiers: Set<String> = [
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.tdesktop.Telegram",
        "net.whatsapp.WhatsApp",
        "desktop.WhatsApp",
        "com.apple.MobileSMS",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "org.whispersystems.signal-desktop",
        "com.viber.osx",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.skype.skype",
        "com.tencent.xinWeChat",
        "jp.naver.line.mac",
        "im.riot.app",
        "Mattermost.Desktop",
    ]

    static func isChatApp(bundleIdentifier: String) -> Bool {
        chatBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Сокращения, у которых точка — часть написания. Список короткий
    /// намеренно: модель пишет слова целиком и сокращает редко, а каждое
    /// лишнее слово здесь — реплика, оставшаяся с точкой.
    private static let periodAbbreviations: Set<String> = [
        "др", "пр", "см", "стр", "тыс", "млн", "млрд", "руб", "коп", "ул", "гг", "г",
        "etc", "inc", "ltd", "corp", "co", "vs", "mr", "mrs", "dr", "jr", "sr",
    ]

    /// Реплика без точки на конце — или `nil`, если это не одна короткая
    /// фраза. Любой знак конца предложения внутри (в том числе точка в
    /// «3.5» или «т.е.») оставляет текст как есть: разбирать сокращения
    /// правилами — значит рано или поздно отрезать точку у сокращения.
    static func droppingChatPeriod(_ text: String) -> String? {
        guard text.hasSuffix("."), !text.hasSuffix("..") else { return nil }
        let body = text.dropLast()
        guard !body.contains(where: { sentenceTerminators.contains($0) || $0.isNewline })
        else { return nil }
        let words = body.split(whereSeparator: \.isWhitespace)
        guard (1...chatMessageMaxWords).contains(words.count),
              let last = words.last,
              !periodAbbreviations.contains(last.lowercased()) else { return nil }
        return String(body)
    }

    // MARK: Где читать нельзя

    /// Терминалы. Текст окна терминала — это не поле ввода: перед курсором
    /// там приглашение командной строки или рамка интерфейса программы, и
    /// «слово перед курсором» запросто оказывается именем каталога. Правило
    /// продолжения фразы там гадало бы, поэтому текст перед курсором в
    /// терминалах не читается вовсе.
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "com.github.wez.wezterm",
        "org.alacritty",
        "co.zeit.hyper",
    ]

    static func readsCaretText(in bundleIdentifier: String) -> Bool {
        !terminalBundleIdentifiers.contains(bundleIdentifier)
    }
}

// MARK: - Чтение текста перед курсором
//
// Через универсальный доступ — то же разрешение, которым Dictor вставляет
// текст. Читается хвост в восемьдесят знаков перед курсором, целиком в
// памяти: в журнал, в «Историю» и на диск он не попадает.

enum InsertionContextReader {
    struct Reading: Sendable {
        let textBeforeCaret: String?
        /// Программа, которой принадлежит поле с фокусом. Обычно это та, что
        /// впереди, но не всегда: панель Spotlight или Raycast забирает ввод,
        /// не становясь программой впереди, и текст уйдёт в неё.
        let bundleIdentifier: String
        /// Как именно читали и сколько это заняло — для журнала, без текста.
        let diagnostic: String
    }

    /// Правилам нужна только текущая строка, а точнее её конец.
    static let tailUTF16Length = 80
    /// Чтение идёт параллельно с распознаванием и обязано кончиться раньше
    /// него: программа, которая не отвечает, не должна задерживать вставку.
    private static let messagingTimeout: Float = 0.1
    private static let budget: TimeInterval = 0.25

    static func read(frontmostPID: pid_t, frontmostBundleIdentifier: String) -> Reading {
        let startedAt = ProcessInfo.processInfo.systemUptime
        var owner = frontmostBundleIdentifier
        func finish(_ text: String?, _ detail: String) -> Reading {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1_000
            return Reading(textBeforeCaret: text,
                           bundleIdentifier: owner,
                           diagnostic: "\(detail), \(String(format: "%.1f", milliseconds)) ms")
        }
        func outOfBudget() -> Bool {
            ProcessInfo.processInfo.systemUptime - startedAt >= budget
        }

        guard AXIsProcessTrusted() else {
            return finish(nil, "accessibility permission unavailable")
        }

        // Сначала — у системы: она знает, куда на самом деле идёт ввод. Если
        // не ответила, спрашиваем программу впереди. Таймаут системному
        // элементу не ставится: он распространился бы на все запросы
        // универсального доступа в процессе. От зависшего ответа защищает
        // срок, с которым результат ждут в `handleRelease`.
        var focused: AXUIElement?
        if let raw = attribute(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute),
           CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let element = unsafeDowncast(raw, to: AXUIElement.self)
            var ownerPID: pid_t = 0
            if AXUIElementGetPid(element, &ownerPID) == .success, ownerPID != frontmostPID {
                owner = NSRunningApplication(processIdentifier: ownerPID)?.bundleIdentifier ?? ""
            }
            focused = element
        } else {
            let app = AXUIElementCreateApplication(frontmostPID)
            AXUIElementSetMessagingTimeout(app, messagingTimeout)
            if let raw = attribute(app, kAXFocusedUIElementAttribute),
               CFGetTypeID(raw) == AXUIElementGetTypeID() {
                focused = unsafeDowncast(raw, to: AXUIElement.self)
            }
        }
        guard let focused else { return finish(nil, "no focused element") }
        guard SmartInsertion.readsCaretText(in: owner) else {
            return finish(nil, "caret text is not read in terminals")
        }
        guard !outOfBudget() else { return finish(nil, "budget expired") }
        AXUIElementSetMessagingTimeout(focused, messagingTimeout)

        let role = attribute(focused, kAXRoleAttribute) as? String ?? "none"
        // Поле с паролем отдаёт точки вместо букв, но само обращение к нему
        // — уже лишнее.
        if attribute(focused, kAXSubroleAttribute) as? String == kAXSecureTextFieldSubrole as String {
            return finish(nil, "focused=\(role), secure field")
        }
        guard !outOfBudget() else { return finish(nil, "focused=\(role), budget expired") }

        guard let rangeRaw = attribute(focused, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeRaw) == AXValueGetTypeID() else {
            return finish(nil, "focused=\(role), no selected range")
        }
        var selection = CFRange()
        guard AXValueGetValue(unsafeDowncast(rangeRaw, to: AXValue.self), .cfRange, &selection),
              selection.location >= 0 else {
            return finish(nil, "focused=\(role), unreadable selected range")
        }
        guard selection.location > 0 else { return finish("", "focused=\(role), caret at start") }
        guard !outOfBudget() else { return finish(nil, "focused=\(role), budget expired") }

        let length = min(selection.location, tailUTF16Length)
        var tail = CFRange(location: selection.location - length, length: length)
        if let tailValue = AXValueCreate(.cfRange, &tail) {
            var raw: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(
                focused, kAXStringForRangeParameterizedAttribute as CFString,
                tailValue, &raw) == .success,
               let text = raw as? String {
                return finish(text, "focused=\(role), string for range")
            }
        }
        guard !outOfBudget() else { return finish(nil, "focused=\(role), budget expired") }

        // Не все поля умеют отдавать кусок по диапазону; тогда — значение
        // целиком, и хвост вырезается здесь.
        guard let value = attribute(focused, kAXValueAttribute) as? String else {
            return finish(nil, "focused=\(role), text unavailable")
        }
        let whole = value as NSString
        guard selection.location <= whole.length else {
            return finish(nil, "focused=\(role), caret beyond the value")
        }
        return finish(whole.substring(with: NSRange(location: tail.location, length: tail.length)),
                      "focused=\(role), whole value")
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &raw) == .success else {
            return nil
        }
        return raw
    }

    /// Сколько вставка готова ждать чтение сверх распознавания. Обычно оно
    /// давно готово; срок нужен на случай программы, которая не отвечает.
    static let insertionWaitSeconds: TimeInterval = 0.15

    /// Результат чтения — или `nil`, если к сроку его нет. Задачу при этом
    /// никто не отменяет: запрос универсального доступа прервать нельзя, его
    /// просто перестают ждать.
    static func value<T: Sendable>(of task: Task<T, Never>,
                                   within seconds: TimeInterval) async -> T? {
        let gate = OnceGate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            Task.detached {
                let value = await task.value
                if gate.open() { continuation.resume(returning: value) }
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if gate.open() { continuation.resume(returning: nil) }
            }
        }
    }
}

/// Пропускает ровно одного: у ожидания со сроком два претендента на ответ, а
/// отвечать можно один раз.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isOpen else { return false }
        isOpen = true
        return true
    }
}

#if DEBUG
/// `--probe-insertion-context [секунды]` — что умная вставка видит в поле
/// программы, которая сейчас впереди. Пауза нужна, чтобы успеть перейти в
/// нужное окно и поставить курсор.
///
/// Сам текст не печатается: буквы заменены на «L», цифры на «9». Этого хватает,
/// чтобы понять, почему правило сработало или промолчало, и можно показать
/// кому угодно.
@MainActor
func runInsertionContextProbe(arguments: [String]) -> Int32 {
    let delay = arguments.first.flatMap(Double.init) ?? 0
    if delay > 0 {
        print("Probing in \(delay) s — switch to the app and put the caret where you dictate.")
        Thread.sleep(forTimeInterval: delay)
    }
    guard let app = NSWorkspace.shared.frontmostApplication else {
        print("no frontmost application")
        return EXIT_FAILURE
    }
    let reading = InsertionContextReader.read(
        frontmostPID: app.processIdentifier,
        frontmostBundleIdentifier: app.bundleIdentifier ?? "")
    let bundleIdentifier = reading.bundleIdentifier
    print("app in front: \(app.bundleIdentifier ?? "")")
    print("focus owner: \(bundleIdentifier)")
    print("chat app: \(SmartInsertion.isChatApp(bundleIdentifier: bundleIdentifier))")
    print("caret text is used: \(SmartInsertion.readsCaretText(in: bundleIdentifier))")
    print("read: \(reading.diagnostic)")
    if let text = reading.textBeforeCaret {
        let masked = String(text.map { character -> Character in
            if character.isNewline { return "↵" }
            if character.isWhitespace { return "·" }
            if character.isLetter { return "L" }
            if character.isNumber { return "9" }
            return character
        })
        print("before caret (\(text.utf16.count) units): \(masked)")
    } else {
        print("before caret: unavailable")
    }
    print("position: \(SmartInsertion.caretPosition(textBeforeCaret: reading.textBeforeCaret))")
    return EXIT_SUCCESS
}
#endif
