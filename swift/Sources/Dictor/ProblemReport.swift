import AppKit
import Foundation

// MARK: - «Сообщить о проблеме»
//
// Архив с отчётом диагностики, хвостом журнала и отчётами о сбоях — и
// письмо, в котором он уже приложен. Ничего не уходит само: письмо
// открывается в почтовой программе человека, и отправляет его он.
//
// Появилось 2026-09-10: служба у родственника падала посреди записи
// тринадцать раз, а разбор занял вечер переписки — «пришли лог», «пришли
// отчёты», «заархивируй». Всё это лежало на его Mac с самого начала; не
// хватало одной кнопки, которая соберёт и приложит.

enum ProblemReport {
    struct Archive {
        let url: URL
        let crashReportCount: Int
        let logLineCount: Int
    }

    /// Хвост журнала: этого хватает на несколько дней работы, а в письмо
    /// влезает без вопросов.
    static let logTailMaxBytes = 1_000_000
    static let logTailMaxLines = 20_000
    /// Отчёты о сбоях — только свежие: старые уже не про эту сборку.
    static let crashReportLimit = 15

    static func build(diagnostics: String, now: Date = Date()) throws -> Archive {
        let stamp = archiveStamp(for: now)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Dictor-problem-report", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let folder = root.appendingPathComponent("Dictor-report-\(stamp)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        try diagnostics.write(to: folder.appendingPathComponent("diagnostics.txt"),
                              atomically: true, encoding: .utf8)

        // Тот же санированный хвост, что идёт в «Копировать диагностику»,
        // только длиннее: транскриптов в журнале нет по построению.
        let logLines = (try? recentDiagnosticLogLines(maxBytes: logTailMaxBytes,
                                                       maxLines: logTailMaxLines)) ?? []
        try (logLines.joined(separator: "\n") + "\n")
            .write(to: folder.appendingPathComponent("Dictor.log"),
                   atomically: true, encoding: .utf8)

        let crashes = Array(dictorCrashReportURLs().prefix(crashReportLimit))
        if !crashes.isEmpty {
            let crashFolder = folder.appendingPathComponent("crashes", isDirectory: true)
            try FileManager.default.createDirectory(at: crashFolder, withIntermediateDirectories: true)
            for report in crashes {
                try FileManager.default.copyItem(
                    at: report,
                    to: crashFolder.appendingPathComponent(report.lastPathComponent))
            }
        }

        let zip = root.appendingPathComponent("Dictor-report-\(stamp).zip")
        try zipDirectory(folder, to: zip)
        return Archive(url: zip, crashReportCount: crashes.count, logLineCount: logLines.count)
    }

    static func archiveStamp(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: date)
    }

    private static func zipDirectory(_ folder: URL, to zip: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        process.environment = systemToolProcessEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "Dictor", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ditto exited with status \(process.terminationStatus)",
            ])
        }
    }

    static func messageBody(archive: Archive, language: InterfaceLanguage) -> String {
        let version = "Dictor \(currentBundleVersion()) (\(currentBundleBuild())), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        let crashes = archive.crashReportCount
        return localizedText(
            """
            \(version)

            Что делал и что случилось:
            (опишите здесь)

            В архиве: отчёт диагностики, журнал приложения без текста диктовок, \
            отчёты о сбоях (\(crashes)).
            """,
            """
            \(version)

            What I was doing and what happened:
            (describe here)

            Attached: the diagnostics report, the app log without any dictated text, \
            crash reports (\(crashes)).
            """,
            language: language)
    }

    /// Собирает архив и открывает письмо. Если почта не настроена — системная
    /// панель «Поделиться» (Сообщения, AirDrop) у кнопки; если и её показать
    /// негде — архив подсвечивается в Finder.
    @MainActor
    static func share(diagnostics: String, anchor: NSView?, language: InterfaceLanguage) {
        let archive: Archive
        do {
            archive = try build(diagnostics: diagnostics)
        } catch {
            log("problem report failed: \(error.localizedDescription)")
            showAlert(
                title: localizedText("Не удалось собрать отчёт", "The report couldn't be built",
                                     language: language),
                detail: error.localizedDescription)
            return
        }
        log("problem report built: \(archive.crashReportCount) crash report(s), \(archive.logLineCount) log lines")

        let subject = "Dictor \(currentBundleVersion()) — "
            + localizedText("отчёт о проблеме", "problem report", language: language)
        let items: [Any] = [messageBody(archive: archive, language: language), archive.url]

        if let mail = NSSharingService(named: .composeEmail) {
            mail.recipients = [PROBLEM_REPORT_RECIPIENT]
            mail.subject = subject
            if mail.canPerform(withItems: items) {
                mail.perform(withItems: items)
                log("problem report: mail compose opened")
                return
            }
        }

        if let anchor {
            let picker = NSSharingServicePicker(items: items)
            picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            log("problem report: share picker shown (no mail account)")
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([archive.url])
        log("problem report: archive revealed in Finder")
        showAlert(
            title: localizedText("Архив готов", "The archive is ready", language: language),
            detail: localizedText(
                "Почта не настроена. Архив подсвечен в Finder — приложите его к сообщению для \(PROBLEM_REPORT_RECIPIENT).",
                "No mail account is set up. The archive is selected in Finder — attach it to a message for \(PROBLEM_REPORT_RECIPIENT).",
                language: language))
    }

    @MainActor
    private static func showAlert(title: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
