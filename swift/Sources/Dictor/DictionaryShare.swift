import AppKit
import Foundation

// MARK: - «Поделиться словарём»
//
// Файл со своим словарём и письмо автору, в котором он уже приложен, — по
// образцу «Сообщить о проблеме». Ничего не уходит само: письмо открывается в
// почтовой программе человека, и отправляет его он.
//
// Зачем: встроенные наборы названий собраны по диктовкам одного человека, а
// модель у каждого ошибается на своих словах. Чужой словарь — это готовый
// список таких ошибок с правильным написанием, и другого способа его увидеть
// нет: приложение ничего о себе не сообщает.
//
// Уходит ровно то, что человек завёл сам. Встроенные наборы у автора и так
// есть, а текста диктовок в словаре нет по построению.

enum DictionaryShare {
    struct SharedFile {
        let url: URL
        let correctionCount: Int
    }

    /// Тот же формат, что у «Экспорта»: присланный файл открывается обычным
    /// импортом, отдельного разбора для него не нужно.
    static func build(corrections: [TranscriptCorrection],
                      now: Date = Date()) throws -> SharedFile {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictor-dictionary-share", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let name = "Dictor-dictionary-\(ProblemReport.archiveStamp(for: now))"
            + ".\(CORRECTIONS_FILE_EXTENSION)"
        let url = root.appendingPathComponent(name)
        let normalized = normalizedTranscriptCorrections(corrections)
        try TranscriptCorrectionsTransfer.write(normalized, to: url)
        return SharedFile(url: url, correctionCount: normalized.count)
    }

    static func messageBody(file: SharedFile, language: InterfaceLanguage) -> String {
        let version = "Dictor \(currentBundleVersion()) (\(currentBundleBuild())), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let count = file.correctionCount
        return localizedText(
            """
            \(version)

            В файле — мой словарь Dictor: \(count) \
            \(pluralizeRU(count, "автозамена", "автозамены", "автозамен")). \
            В каждой — что слышит модель и что должно быть в тексте. \
            Текста диктовок в файле нет.
            """,
            """
            \(version)

            Attached is my Dictor dictionary: \(count) \
            \(count == 1 ? "correction" : "corrections"). \
            Each one says what the model hears and what the text should say. \
            The file holds no dictated text.
            """,
            language: language)
    }

    /// Собирает файл и открывает письмо. Пустым словарём делиться нечем —
    /// вызывающий обязан не доводить до этого (кнопка приглушена), но письмо
    /// с пустым вложением хуже молчания, поэтому проверка стоит и здесь.
    @MainActor
    static func share(corrections: [TranscriptCorrection],
                      anchor: NSView?,
                      language: InterfaceLanguage) {
        guard !normalizedTranscriptCorrections(corrections).isEmpty else { return }
        let file: SharedFile
        do {
            file = try build(corrections: corrections)
        } catch {
            log("dictionary share failed: \(error.localizedDescription)")
            MailHandoff.showAlert(
                title: localizedText("Не удалось собрать файл словаря",
                                     "The dictionary file couldn't be built",
                                     language: language),
                detail: error.localizedDescription)
            return
        }
        // Содержимое словаря в журнал не пишется — только число записей.
        log("dictionary share built: \(file.correctionCount) correction(s)")

        MailHandoff.present(
            subject: "Dictor \(currentBundleVersion()) — "
                + localizedText("мой словарь", "my dictionary", language: language),
            body: messageBody(file: file, language: language),
            attachment: file.url,
            anchor: anchor,
            logLabel: "dictionary share",
            finderTitle: localizedText("Файл словаря готов", "The dictionary file is ready",
                                       language: language),
            finderDetail: localizedText(
                "Почта не настроена. Файл подсвечен в Finder — приложите его к сообщению для \(PROBLEM_REPORT_RECIPIENT).",
                "No mail account is set up. The file is selected in Finder — attach it to a message for \(PROBLEM_REPORT_RECIPIENT).",
                language: language))
    }
}
