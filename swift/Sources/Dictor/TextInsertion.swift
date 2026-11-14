import AppKit

// MARK: - Text insertion
//
// Default path: write to general pasteboard, post Cmd+V. If that setup
// fails, fall back to direct Unicode events so a pasteboard problem
// does not automatically lose the transcript. After a successful paste
// event, restore the previous clipboard if it is still at our temporary
// write, so dictation doesn't replace what the user had copied before
// speaking.

/// `leadingSpace` — пробел от умной вставки: курсор стоял вплотную к
/// предыдущему слову. Как и хвост, это клей между соседями, а не часть
/// диктовки.
func pastedText(from correctedTranscript: String,
                suffix: PasteSuffix,
                leadingSpace: Bool = false) -> String {
    let text = (leadingSpace ? " " : "") + correctedTranscript
    switch suffix {
    case .appendSpace:
        return text + " "
    case .none:
        return text
    case .appendNewline:
        return text + "\n"
    }
}

enum TextInsertionStrategy: String {
    case clipboardPaste
    case directUnicode
    /// Печать в поле веб-страницы Chrome, где ⌘V теряется. См. BrowserTyping.
    case browserTyping

    var displayName: String {
        switch self {
        case .clipboardPaste: return "Clipboard paste"
        case .directUnicode: return "Direct Unicode typing"
        case .browserTyping: return "Browser field typing"
        }
    }
}

func textInsertionStrategyChain(primary: TextInsertionStrategy) -> [TextInsertionStrategy] {
    switch primary {
    case .clipboardPaste:
        return [.clipboardPaste, .directUnicode]
    case .directUnicode:
        return [.directUnicode]
    case .browserTyping:
        return [.browserTyping, .clipboardPaste]
    }
}

func textInsertionStrategyDescription(primary: TextInsertionStrategy) -> String {
    let strategies = textInsertionStrategyChain(primary: primary).map(\.displayName)
    guard let first = strategies.first else { return "Unavailable" }
    guard strategies.count > 1 else { return first }
    return "\(first) with \(strategies.dropFirst().joined(separator: ", ")) fallback"
}

func unicodeInsertionChunks(for text: String, maxUTF16UnitsPerEvent maxUnits: Int) -> [[UInt16]] {
    guard maxUnits > 0 else { return [] }
    var chunks: [[UInt16]] = []
    var current: [UInt16] = []

    for character in text {
        let units = Array(String(character).utf16)
        if units.count > maxUnits {
            if !current.isEmpty {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            chunks.append(units)
            continue
        }
        if !current.isEmpty, current.count + units.count > maxUnits {
            chunks.append(current)
            current.removeAll(keepingCapacity: true)
        }
        current.append(contentsOf: units)
    }

    if !current.isEmpty {
        chunks.append(current)
    }
    return chunks
}

struct KeyboardEventStep: Equatable {
    let virtualKey: CGKeyCode
    let keyDown: Bool
    let flags: CGEventFlags
}

func clipboardPasteKeyboardEventSteps(commandKey: CGKeyCode,
                                              pasteKey: CGKeyCode) -> [KeyboardEventStep] {
    [
        KeyboardEventStep(virtualKey: commandKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: true, flags: .maskCommand),
        KeyboardEventStep(virtualKey: pasteKey, keyDown: false, flags: .maskCommand),
        KeyboardEventStep(virtualKey: commandKey, keyDown: false, flags: []),
    ]
}

func postKeyboardEventSteps(_ steps: [KeyboardEventStep]) -> Bool {
    let source = CGEventSource(stateID: .hidSystemState)
    let events = steps.compactMap { step -> CGEvent? in
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: step.virtualKey,
                                  keyDown: step.keyDown) else {
            return nil
        }
        event.flags = step.flags
        return event
    }
    guard events.count == steps.count else { return false }

    for event in events {
        event.post(tap: .cghidEventTap)
    }
    return true
}

@MainActor
enum KeyboardShortcutPoster {
    @discardableResult
    static func postReturn() -> Bool {
        postKeyboardEventSteps([
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: true, flags: []),
            KeyboardEventStep(virtualKey: RETURN_KEYCODE, keyDown: false, flags: []),
        ])
    }
}

@MainActor
enum TextInserter {
    nonisolated static let defaultStrategy = TextInsertionStrategy.clipboardPaste

    nonisolated static var defaultStrategyDescription: String {
        textInsertionStrategyDescription(primary: defaultStrategy)
    }

    /// Какой стратегией удалась последняя вставка. Enter после диктовки
    /// сверяется с ней: подтверждения чтения буфера ждут только от
    /// clipboardPaste — directUnicode печатает текст сам, ждать там нечего.
    static private(set) var lastSuccessfulStrategy: TextInsertionStrategy?

    /// Единственный открытый вход. Способ выбирается здесь, а не у
    /// вызывающего: так его не обойдёт ни диктовка, ни быстрая панель, ни
    /// будущая третья точка вставки.
    @discardableResult
    static func insert(_ text: String) -> Bool {
        let choice = BrowserTyping.choiceForFrontmostApplication()
        // Журнал — только там, где выбор вообще возможен: так видно, каким
        // путём шла диктовка в Chrome, а остальные программы не шумят.
        if BrowserTyping.bundleIdentifiers.contains(
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") {
            log("text insertion strategy: \(choice.strategy.displayName) (\(choice.reason))")
        }
        return insert(text, strategy: choice.strategy)
    }

    private static func insert(_ text: String, strategy: TextInsertionStrategy) -> Bool {
        lastSuccessfulStrategy = nil
        for candidate in textInsertionStrategyChain(primary: strategy) {
            if insert(text, using: candidate) {
                if candidate != strategy {
                    log("text insertion fallback succeeded: \(candidate.displayName)")
                }
                lastSuccessfulStrategy = candidate
                return true
            }
            log("text insertion attempt failed: \(candidate.displayName)")
        }
        return false
    }

    private static func insert(_ text: String, using strategy: TextInsertionStrategy) -> Bool {
        switch strategy {
        case .clipboardPaste:
            return ClipboardPasteInserter.insert(text)
        case .directUnicode:
            return DirectUnicodeInserter.insert(text)
        case .browserTyping:
            return BrowserTyping.type(text)
        }
    }
}

@MainActor
enum DirectUnicodeInserter {
    private static let maxUTF16UnitsPerEvent = 20

    static func insert(_ text: String) -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        var didPostAll = true

        for chunk in unicodeInsertionChunks(for: text, maxUTF16UnitsPerEvent: maxUTF16UnitsPerEvent) {
            didPostAll = post(chunk, source: source) && didPostAll
        }
        return didPostAll
    }

    private static func post(_ units: [UInt16], source: CGEventSource?) -> Bool {
        // Each chunk posts a keyDown AND a matching keyUp carrying the
        // same unicode payload — standard CGEvent unicode-typing
        // practice. A keyDown-only stream leaves apps that track key
        // state believing a key is still held.
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            return false
        }
        down.flags = []
        up.flags = []
        for event in [down, up] {
            units.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
            }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}

