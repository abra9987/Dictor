import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testPasteSuffixFormatting() throws {
        try expect(
            pastedText(from: "hello world", suffix: .appendSpace),
            equals: "hello world ",
            "append-space suffix should preserve the existing default"
        )
        try expect(
            pastedText(from: "hello world", suffix: .none),
            equals: "hello world",
            "no suffix should paste corrected transcript unchanged"
        )
        try expect(
            pastedText(from: "hello world", suffix: .appendNewline),
            equals: "hello world\n",
            "append-newline suffix should add a single newline"
        )
        try expect(
            pastedText(from: "hello world ", suffix: .appendSpace),
            equals: "hello world  ",
            "suffix formatting should not trim or rewrite corrected text"
        )
        try expect(
            TextInserter.defaultStrategy,
            equals: .clipboardPaste,
            "clipboard paste should remain the default insertion strategy"
        )
        try expect(
            textInsertionStrategyChain(primary: .clipboardPaste),
            equals: [.clipboardPaste, .directUnicode],
            "clipboard paste should fall back to direct Unicode insertion"
        )
        try expect(
            textInsertionStrategyChain(primary: .directUnicode),
            equals: [.directUnicode],
            "direct Unicode insertion should not loop back to clipboard paste"
        )
        try expect(
            TextInserter.defaultStrategyDescription,
            equals: "Clipboard paste with Direct Unicode typing fallback",
            "diagnostics should describe the insertion fallback chain"
        )
        let unicodeChunks = unicodeInsertionChunks(for: "ab👩‍💻cd", maxUTF16UnitsPerEvent: 4)
            .map { String(decoding: $0, as: UTF16.self) }
        try expect(
            unicodeChunks,
            equals: ["ab", "👩‍💻", "cd"],
            "direct Unicode insertion should keep extended grapheme clusters together while chunking"
        )
        try expect(
            unicodeInsertionChunks(for: "abc", maxUTF16UnitsPerEvent: 0),
            equals: [],
            "direct Unicode chunking should reject invalid chunk sizes"
        )
        try expect(
            clipboardPasteKeyboardEventSteps(commandKey: 0x37, pasteKey: 0x09),
            equals: [
                KeyboardEventStep(virtualKey: 0x37, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: true, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x09, keyDown: false, flags: .maskCommand),
                KeyboardEventStep(virtualKey: 0x37, keyDown: false, flags: []),
            ],
            "clipboard paste should synthesize a full Command+V key sequence"
        )

        let pasteboardProbe = MainActor.assumeIsolated {
            let pasteboardName = NSPasteboard.Name("com.raul.dictor.self-test.\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: pasteboardName)
            let wrote = ClipboardPasteInserter.write("pasteboard probe", to: pasteboard)
            let snapshot = PasteboardSnapshot.capture(from: pasteboard)
            _ = ClipboardPasteInserter.write("temporary dictation", to: pasteboard)
            snapshot.restore(to: pasteboard)
            return (wrote: wrote, stored: pasteboard.string(forType: .string))
        }
        try expect(
            pasteboardProbe.wrote,
            equals: true,
            "clipboard paste should report pasteboard write success"
        )
        try expect(
            pasteboardProbe.stored,
            equals: "pasteboard probe",
            "clipboard paste should write the intended string before posting Cmd+V"
        )
    }

    /// Вставка через буфер обмена: текст отдаётся по запросу приёмника, а
    /// прежнее содержимое возвращается после того, как его забрали.
    ///
    /// Проверять это живьём почти нечем: нужен приёмник, который читает буфер
    /// медленно, а именно на быстрых приёмниках старый порядок и выглядел
    /// работающим. Весь тест идёт на **своём** буфере — общий буфер человека
    /// самотест трогать не имеет права.
    static func testClipboardPasteTransaction() throws {
        try MainActor.assumeIsolated {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.raul.dictor.selftest"))
            defer { pasteboard.releaseGlobally() }

            func wait(_ seconds: TimeInterval) {
                RunLoop.current.run(until: Date().addingTimeInterval(seconds))
            }

            @MainActor
            func makeTransaction(_ text: String,
                                 timeout: TimeInterval = 5,
                                 afterRead: TimeInterval = 0.05) -> ClipboardPasteTransaction {
                ClipboardPasteTransaction(
                    text: text,
                    pasteboard: pasteboard,
                    previous: PasteboardSnapshot.capture(from: pasteboard),
                    restoreDelayAfterRead: afterRead,
                    restoreTimeout: timeout)
            }

            // 1. Текст доходит до приёмника, и только после чтения буфер
            //    возвращается к прежнему содержимому.
            pasteboard.clearContents()
            pasteboard.setString("прежнее содержимое", forType: .string)
            let first = makeTransaction("продиктованный текст")
            try expect(first.install(), equals: true, "the transaction must claim the pasteboard")
            try expect(first.didProvideText, equals: false,
                       "the text must not be handed out before anybody asks")
            try expect(pasteboard.string(forType: .string), equals: "продиктованный текст",
                       "a reader must get the dictated text, not the previous clipboard")
            try expect(first.didProvideText, equals: true,
                       "reading the pasteboard must go through the provider")
            wait(0.2)
            try expect(pasteboard.string(forType: .string), equals: "прежнее содержимое",
                       "the previous clipboard must come back once the text was read")
            try expect(first.isFinished, equals: true, "a restored transaction is over")

            // 2. Никто не пришёл за текстом — вставки не было. Буфер не
            //    возвращается к прежнему: человеку сейчас нужнее сама
            //    диктовка — ручной ⌘V должен вставить её, а не то, что он
            //    копировал полчаса назад. И наружу уходит сигнал: раньше этот
            //    путь молчал, и «Вставлено» оставалось неисправимой ложью.
            var neverReadSignals: [Bool] = []
            ClipboardPasteInserter.onPasteNeverRead = { neverReadSignals.append($0) }
            defer { ClipboardPasteInserter.onPasteNeverRead = nil }
            pasteboard.clearContents()
            pasteboard.setString("другое прежнее", forType: .string)
            let ignored = makeTransaction("никем не прочитанное", timeout: 0.05)
            try expect(ignored.install(), equals: true, "the transaction must claim the pasteboard")
            wait(0.25)
            try expect(ignored.didProvideText, equals: false,
                       "nobody read it, so the provider must not have fired")
            try expect(pasteboard.string(forType: .string), equals: "никем не прочитанное",
                       "an unread dictation must stay in the clipboard for a manual ⌘V")
            try expect(neverReadSignals, equals: [true],
                       "the never-read failsafe must signal, with the text kept in the clipboard")

            // 3. Человек скопировал своё, пока мы ждали, — не трогаем: ни
            //    возврат старого, ни диктовка не смеют стереть его работу.
            //    Сигнал всё равно уходит — вставки не было, но текст теперь
            //    только в истории.
            pasteboard.clearContents()
            pasteboard.setString("было моё", forType: .string)
            let overtaken = makeTransaction("продиктованное", timeout: 0.05)
            try expect(overtaken.install(), equals: true, "the transaction must claim the pasteboard")
            pasteboard.clearContents()
            pasteboard.setString("человек скопировал сам", forType: .string)
            wait(0.25)
            try expect(pasteboard.string(forType: .string), equals: "человек скопировал сам",
                       "a clipboard the person changed themselves must stay theirs")
            try expect(neverReadSignals, equals: [true, false],
                       "the signal must say the text did not stay in the clipboard")

            // 4. Две диктовки подряд: вторая возвращает буфер за первую, иначе
            //    прежнее содержимое потерялось бы совсем.
            pasteboard.clearContents()
            pasteboard.setString("исходное", forType: .string)
            _ = ClipboardPasteInserter.insert("первая диктовка",
                                              into: pasteboard,
                                              postingKeystroke: false)
            _ = ClipboardPasteInserter.insert("вторая диктовка",
                                              into: pasteboard,
                                              postingKeystroke: false)
            try expect(pasteboard.string(forType: .string), equals: "вторая диктовка",
                       "the second dictation must own the clipboard")
            wait(0.3)
            try expect(pasteboard.string(forType: .string), equals: "исходное",
                       "after both dictations the original clipboard must be back")
            try expect(neverReadSignals, equals: [true, false],
                       "a superseded dictation must not fire the never-read signal")
        }
    }

    /// Живая проверка того же на **общем** буфере и чужим процессом.
    ///
    /// Самотест на своём буфере доказывает логику, но не то, ради чего она
    /// написана: текст кладётся лениво, и забрать его должен посторонний
    /// процесс через межпроцессный механизм AppKit. Здесь за ним приходит
    /// `pbpaste` — то же самое делает любое приложение, куда идёт диктовка.
    ///
    /// Общий буфер человека при этом снимается и возвращается, как история в
    /// экспорте превью. В `testAll` не регистрируется: трогать общий буфер без
    /// спроса рядовой прогон тестов не должен.
    static func testClipboardPasteLive() throws {
        try MainActor.assumeIsolated {
            let pasteboard = NSPasteboard.general
            let saved = PasteboardSnapshot.capture(from: pasteboard)
            defer { saved.restore(to: pasteboard) }

            let dictated = "живая проверка вставки \(Int(Date().timeIntervalSince1970))"
            _ = ClipboardPasteInserter.insert(dictated,
                                              into: pasteboard,
                                              postingKeystroke: false)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            // Главный поток обязан остаться живым: запрос за текстом придёт
            // через межпроцессный механизм AppKit и обслуживается на нём же.
            // Заблокируешь его ожиданием — и чужой процесс получит пустоту с
            // «promise keeping timed out». В приложении это условие выполнено:
            // пауза перед Enter — асинхронная (`await Task.sleep`), а не
            // `Thread.sleep`. Поставишь туда блокирующее ожидание — сломаешь
            // вставку, и этот тест первым это покажет.
            let deadline = Date().addingTimeInterval(5)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let read = String(data: data, encoding: .utf8) ?? ""

            try expect(read, equals: dictated,
                       "another process must receive the dictated text, not the old clipboard")
            print("clipboard-paste-live: pbpaste got \(read.count) chars")

            // И буфер возвращается сам, без нашего участия.
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            let after = pasteboard.string(forType: .string) ?? ""
            try expect(after == dictated, equals: false,
                       "the dictated text must not stay in the clipboard afterwards")
        }
    }
}
#endif
