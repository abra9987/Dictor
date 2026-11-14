import AppKit

@MainActor
enum ClipboardPasteInserter {
    private static let virtualKeyCommand: CGKeyCode = 0x37  // left Command
    private static let virtualKeyV: CGKeyCode = 0x09  // ANSI 'v'
    /// Сколько ждать после того, как приёмник забрал текст. Ему может
    /// понадобиться ещё один заход за другим типом данных, поэтому не ноль.
    static let restoreDelayAfterRead: TimeInterval = 0.12
    /// И сколько ждать, если он не забрал текст вовсе: буфер человека нельзя
    /// оставлять занятым навсегда из-за приложения, которое не отвечает.
    static let restoreTimeout: TimeInterval = 10
    /// Незавершённая вставка. Диктовок может быть две подряд, и вторая обязана
    /// вернуть буфер за первую, иначе прежнее содержимое потеряется совсем.
    fileprivate static var pending: ClipboardPasteTransaction?
    /// Получатель пришёл за текстом текущей вставки. Надёжен только в
    /// отрицательную сторону: чтение может оказаться менеджером буфера, а вот
    /// отсутствие чтения означает, что ⌘V точно ни во что не вставился.
    static fileprivate(set) var lastPasteWasRead = false
    /// Страховка на restoreTimeout истекла, а за текстом так никто и не
    /// пришёл: вставки не было, «Вставлено» оказалось неправдой. Агент вешает
    /// сюда сигнал человеку; keptInClipboard — остался ли текст в буфере
    /// (false, если человек успел скопировать своё и буфер уже не наш).
    static var onPasteNeverRead: ((_ keptInClipboard: Bool) -> Void)?

    /// Ждёт, пока получатель заберёт текст текущей вставки, но не дольше
    /// timeout. true — забрал; false — так и не пришёл.
    static func waitUntilPasteRead(timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !lastPasteWasRead {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }

    fileprivate static func noteTextProvided(by transaction: ClipboardPasteTransaction) {
        guard pending === transaction else { return }
        lastPasteWasRead = true
    }

    static func write(_ text: String, to pb: NSPasteboard) -> Bool {
        pb.clearContents()
        return pb.setString(text, forType: .string)
    }

    static func insert(_ text: String) -> Bool {
        insert(text, into: NSPasteboard.general, postingKeystroke: true)
    }

    /// Кладёт текст в буфер **лениво** и жмёт Cmd+V.
    ///
    /// Прежний порядок был другим: текст писался строкой, а прежнее содержимое
    /// возвращалось через 0,35 с по таймеру. Приёмник, который читает буфер
    /// медленнее, — Electron, Java, удалённый рабочий стол, просто занятая
    /// машина — успевал получить уже восстановленное старое содержимое и
    /// вставлял не то, что человек продиктовал. Диктовка при этом выглядела
    /// успешной, и найти причину по логу было нечем.
    ///
    /// Теперь в буфер кладётся обещание: текст отдаётся в тот момент, когда
    /// приёмник за ним приходит, и только после этого запускается возврат.
    /// Слепой таймер остаётся лишь страховкой на случай, когда не пришёл никто.
    @discardableResult
    static func insert(_ text: String,
                       into pasteboard: NSPasteboard,
                       postingKeystroke: Bool) -> Bool {
        pending?.restoreNow(reason: "superseded by another dictation")
        lastPasteWasRead = false
        let transaction = ClipboardPasteTransaction(
            text: text,
            pasteboard: pasteboard,
            previous: PasteboardSnapshot.capture(from: pasteboard),
            restoreDelayAfterRead: restoreDelayAfterRead,
            restoreTimeout: restoreTimeout)
        transaction.onFinish = {
            if pending === transaction { pending = nil }
        }
        guard transaction.install() else {
            log("pasteboard write failed")
            return false
        }
        pending = transaction

        guard postingKeystroke else { return true }
        let steps = clipboardPasteKeyboardEventSteps(commandKey: virtualKeyCommand,
                                                     pasteKey: virtualKeyV)
        guard post(steps) else {
            log("paste event creation failed")
            transaction.restoreNow(reason: "paste event creation failed")
            return false
        }
        return true
    }

    private static func post(_ steps: [KeyboardEventStep]) -> Bool {
        // Post Command as real key events instead of only tagging the V
        // events with .maskCommand. Sleep/wake can leave session modifier
        // state unreliable for flag-only synthetic shortcuts.
        return postKeyboardEventSteps(steps)
    }
}

/// Одна вставка через буфер обмена: положили обещание, дождались, пока его
/// прочитают, вернули прежнее содержимое.
///
/// Живёт ровно столько, сколько буфер держит наш `NSPasteboardItem`: провайдер
/// данных — это она сама, и умереть раньше чтения она не имеет права.
@MainActor
final class ClipboardPasteTransaction: NSObject, NSPasteboardItemDataProvider {
    nonisolated let text: String
    private let pasteboard: NSPasteboard
    private let previous: PasteboardSnapshot
    private let restoreDelayAfterRead: TimeInterval
    private let restoreTimeout: TimeInterval
    /// Сообщает владельцу, что транзакция закончилась и ссылку можно отпустить.
    var onFinish: (() -> Void)?
    /// Для самотеста: текст запросили хотя бы раз.
    private(set) var didProvideText = false
    private(set) var isFinished = false

    private var ownedChangeCount: Int?
    private var restoreWork: DispatchWorkItem?

    init(text: String,
         pasteboard: NSPasteboard,
         previous: PasteboardSnapshot,
         restoreDelayAfterRead: TimeInterval,
         restoreTimeout: TimeInterval) {
        self.text = text
        self.pasteboard = pasteboard
        self.previous = previous
        self.restoreDelayAfterRead = restoreDelayAfterRead
        self.restoreTimeout = restoreTimeout
    }

    func install() -> Bool {
        let item = NSPasteboardItem()
        guard item.setDataProvider(self, forTypes: [.string]) else {
            finish()
            return false
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            previous.restore(to: pasteboard)
            finish()
            return false
        }
        ownedChangeCount = pasteboard.changeCount
        scheduleNeverReadFailsafe(after: restoreTimeout)
        return true
    }

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?,
                                item: NSPasteboardItem,
                                provideDataForType type: NSPasteboard.PasteboardType) {
        // Момент, ради которого всё затевалось: приёмник пришёл за текстом.
        guard type == .string else { return }
        item.setString(text, forType: .string)
        MainActor.assumeIsolated {
            didProvideText = true
            ClipboardPasteInserter.noteTextProvided(by: self)
            scheduleRestore(after: restoreDelayAfterRead, reason: "text was read")
        }
    }

    /// Вернуть буфер немедленно — если он всё ещё наш.
    func restoreNow(reason: String) {
        guard !isFinished else { return }
        restoreWork?.cancel()
        restoreWork = nil
        // Человек мог скопировать что-то своё, пока мы ждали. Тогда буфер уже
        // не наш, и возвращать в него старое — значит стереть его работу.
        if let owned = ownedChangeCount, pasteboard.changeCount == owned {
            previous.restore(to: pasteboard)
            log("pasteboard restored (\(reason))")
        } else {
            log("pasteboard restore skipped (\(reason)): clipboard changed meanwhile")
        }
        finish()
    }

    /// Страховка истекла, а за текстом так никто и не пришёл — вставки не
    /// было. Прежнее содержимое не возвращается: человеку сейчас нужнее сама
    /// диктовка — ручной ⌘V должен вставить её, а не то, что он копировал
    /// полчаса назад. Раньше этот путь молча откатывал буфер, и «Вставлено»
    /// оставалось неисправимой ложью.
    private func handleNeverReadTimeout() {
        guard !isFinished else { return }
        guard !didProvideText else {
            // Не должно случаться: чтение само планирует возврат и снимает
            // страховку. Но если гонка всё же свела их — вернуть как обычно.
            restoreNow(reason: "text was read")
            return
        }
        let stillOurs = ownedChangeCount.map { pasteboard.changeCount == $0 } ?? false
        finish()
        var keptInClipboard = false
        if stillOurs {
            if ClipboardPasteInserter.write(text, to: pasteboard) {
                keptInClipboard = true
                log("paste was never read: dictation left in the clipboard for manual ⌘V")
            } else {
                log("paste was never read, and re-writing the clipboard failed")
            }
        } else {
            log("paste was never read: clipboard changed meanwhile, left untouched")
        }
        ClipboardPasteInserter.onPasteNeverRead?(keptInClipboard)
    }

    private func scheduleNeverReadFailsafe(after delay: TimeInterval) {
        guard !isFinished else { return }
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.handleNeverReadTimeout() }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func scheduleRestore(after delay: TimeInterval, reason: String) {
        guard !isFinished else { return }
        restoreWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restoreNow(reason: reason) }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finish() {
        guard !isFinished else { return }
        isFinished = true
        restoreWork?.cancel()
        restoreWork = nil
        onFinish?()
        onFinish = nil
    }
}

@MainActor
struct PasteboardSnapshot {
    private struct Item {
        let values: [(type: NSPasteboard.PasteboardType, data: Data)]
    }

    private let items: [Item]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(values: item.types.compactMap { type in
                guard let data = item.data(forType: type) else { return nil }
                return (type, data)
            })
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restoredItems = items.map { item -> NSPasteboardItem in
            let restored = NSPasteboardItem()
            for value in item.values {
                restored.setData(value.data, forType: value.type)
            }
            return restored
        }
        if !restoredItems.isEmpty {
            pasteboard.writeObjects(restoredItems)
        }
    }
}
