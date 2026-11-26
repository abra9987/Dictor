// Самотесты журнала и диагностики: приватная запись лога и что попадает
// в текст диагностики и архив отчёта.

import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testPrivateLogAppend() throws {
        try expect(
            privacySafeLogPath("/Users/example/Documents/Dictor Diagnostics.txt"),
            equals: "Dictor Diagnostics.txt",
            "log path labels should omit parent directories"
        )
        try expect(
            privacySafeLogPath("/"),
            equals: "<local path>",
            "log path labels should fall back when no filename is available"
        )
        try expect(
            privacySafeBundlePath("/Applications/Dictor.app"),
            equals: "/Applications/Dictor.app",
            "bundle path labels should keep the canonical install path"
        )
        try expect(
            privacySafeBundlePath("/Users/example/Downloads/Dictor.app"),
            equals: "Dictor.app",
            "bundle path labels should omit parent directories for nonstandard installs"
        )

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-log-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("Dictor.log")
        try appendPrivateLogData(Data("one\n".utf8), to: logFile)
        try appendPrivateLogData(Data("two\n".utf8), to: logFile)

        let attrs = try fm.attributesOfItem(atPath: logFile.path)
        let permissions = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        try expect(permissions & 0o777,
                   equals: 0o600,
                   "log file should be private to the current user")
        try expect(
            String(data: try Data(contentsOf: logFile), encoding: .utf8),
            equals: "one\ntwo\n",
            "log appends should preserve existing content"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("target\n".utf8).write(to: target)
        let link = root.appendingPathComponent("link.log")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        var symlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: link)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected,
                   equals: true,
                   "log appends should reject leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: target), encoding: .utf8),
            equals: "target\n",
            "log symlink rejection should leave the target untouched"
        )

        let hardlinkTarget = root.appendingPathComponent("hardlink-target.log")
        try Data("hardlink target\n".utf8).write(to: hardlinkTarget)
        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(hardlinkTarget.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }

        var hardlinkRejected = false
        do {
            try appendPrivateLogData(Data("bad\n".utf8), to: hardlink)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected,
                   equals: true,
                   "log appends should reject hard-linked files")
        try expect(
            String(data: try Data(contentsOf: hardlinkTarget), encoding: .utf8),
            equals: "hardlink target\n",
            "log hard-link rejection should leave the target untouched"
        )
    }

    static func testDiagnostics() throws {
        let transcriptSecret = "secret dictated phrase 58A03D"
        let correctionSecret = "private correction replacement 9F42"
        let report = diagnosticsReportText(
            from: DiagnosticsReportSnapshot(
                generated: "2026-05-28T10:00:00Z",
                appVersion: "9.8.7",
                appBuild: "123",
                macOS: "Version 26.0",
                bundleID: "com.raul.dictor",
                bundlePath: "/Applications/Dictor.app",
                installKind: "Applications app",
                status: "Hold Right Option to dictate",
                startup: "Runtime ready",
                speechModelReady: true,
                coreRuntimeReady: true,
                readyForDictation: true,
                recordingActive: false,
                transcribing: false,
                memoryLines: ["Resident: 100 MB"],
                permissionLines: ["Microphone: granted", "Accessibility: granted", "Input Monitoring: granted"],
                settingLines: [
                    "Speech model: Multilingual (Parakeet Ultra)",
                    "Language: Auto-detect",
                    "Recent transcripts: Last 5 (1 in memory)",
                    "Text corrections: 1 configured",
                    "Text correction sync: configured",
                ],
                updateLines: ["Pending update: none"],
                microphoneLines: ["Selected: System default", "Available inputs: none reported"],
                logPath: "~/Library/Logs/Dictor.log",
                recentLogLines: ["[10:00:00] release: 1.23 s captured, transcribing"]
            )
        )
        try expect(report.contains(transcriptSecret), equals: false,
                   "diagnostics report should not include transcript contents")
        try expect(report.contains(correctionSecret), equals: false,
                   "diagnostics report should not include text correction contents")
        try expect(report.contains("Text corrections: 1 configured"), equals: true,
                   "diagnostics report should include correction counts")
        try expect(report.contains("Speech model: Multilingual (Parakeet Ultra)"), equals: true,
                   "diagnostics report should include the speech model")
        try expect(report.contains("Recent log lines:"), equals: true,
                   "diagnostics report should include the recent log section")
        try expect(report.contains("Privacy: transcript text and text-correction contents are not included."),
                   equals: true,
                   "diagnostics report should state the privacy boundary")

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-diagnostics-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }

        let logFile = root.appendingPathComponent("Dictor.log")
        for line in 1...6 {
            try appendPrivateLogData(Data("[10:00:0\(line)] line \(line)\n".utf8), to: logFile)
        }
        try expect(
            try recentDiagnosticLogLines(from: logFile, maxBytes: 4096, maxLines: 3),
            equals: ["[10:00:04] line 4", "[10:00:05] line 5", "[10:00:06] line 6"],
            "diagnostic log tail should return the newest bounded lines"
        )

        let target = root.appendingPathComponent("target.log")
        try Data("[10:00:00] target\n".utf8).write(to: target)
        let symlink = root.appendingPathComponent("symlink.log")
        try fm.createSymbolicLink(at: symlink, withDestinationURL: target)
        var symlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: symlink, maxBytes: 4096, maxLines: 3)
        } catch {
            symlinkRejected = true
        }
        try expect(symlinkRejected, equals: true,
                   "diagnostic log tail should reject leaf symlinks")

        let hardlink = root.appendingPathComponent("hardlink.log")
        guard Darwin.link(target.path, hardlink.path) == 0 else {
            throw currentPOSIXError()
        }
        var hardlinkRejected = false
        do {
            _ = try recentDiagnosticLogLines(from: hardlink, maxBytes: 4096, maxLines: 3)
        } catch {
            hardlinkRejected = true
        }
        try expect(hardlinkRejected, equals: true,
                   "diagnostic log tail should reject hard-linked files")

        // Отчёты о сбоях: только Dictor-*.ips, новые первыми; сводка короткая —
        // счётчик, самый свежий и самый старый.
        let crashDir = root.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try fm.createDirectory(at: crashDir, withIntermediateDirectories: true)
        for name in ["Dictor-2026-09-10-002425.ips", "Other-2026-09-10-000001.ips",
                     "Dictor-2026-09-10-231059.ips", "Dictor-2026-09-03-100849.ips", "notes.txt"] {
            try Data("{}".utf8).write(to: crashDir.appendingPathComponent(name))
        }
        try expect(
            dictorCrashReportURLs(in: crashDir).map(\.lastPathComponent),
            equals: ["Dictor-2026-09-10-231059.ips",
                     "Dictor-2026-09-10-002425.ips",
                     "Dictor-2026-09-03-100849.ips"],
            "crash report listing should keep only Dictor reports, newest first"
        )
        try expect(
            crashReportSummaryLines(fileNames: ["Dictor-2026-09-03-100849.ips",
                                                "Dictor-2026-09-10-231059.ips"]),
            equals: ["Total: 2",
                     "Newest: Dictor-2026-09-10-231059.ips",
                     "Oldest: Dictor-2026-09-03-100849.ips"],
            "crash report summary should name the count and the range"
        )
        try expect(crashReportSummaryLines(fileNames: []), equals: [],
                   "no crash reports should yield no summary lines")
        try expect(crashReportSummaryLines(fileNames: ["Dictor-2026-09-10-231059.ips"]),
                   equals: ["Total: 1", "Newest: Dictor-2026-09-10-231059.ips"],
                   "a single crash report should not repeat itself as the oldest")
        try expect(report.contains("Crash reports (~/Library/Logs/DiagnosticReports):"),
                   equals: true,
                   "diagnostics report should carry the crash report section")

        // Проба шрифта: системный шрифт верстается; описание — имя и кегль.
        try expect(SD.textLayoutFailure(font: NSFont.systemFont(ofSize: 12)), equals: nil,
                   "the system font must pass the CoreText probe")
        try expect(SD.describe(NSFont.systemFont(ofSize: 12)).hasSuffix(" 12 pt"), equals: true,
                   "font description should end with the point size")
        try expect(ProblemReport.archiveStamp(for: Date(timeIntervalSince1970: 0)).count,
                   equals: "1970-01-01-0000".count,
                   "archive stamp should be yyyy-MM-dd-HHmm")

        // Архив «Сообщить о проблеме» собирается целиком: диагностика, хвост
        // журнала, и всё это распаковывается тем же ditto, что и пакует.
        let archive = try ProblemReport.build(diagnostics: "probe diagnostics 7C1E")
        try expect(fm.fileExists(atPath: archive.url.path), equals: true,
                   "problem report archive should exist")
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.url.path, unpacked.path]
        unzip.environment = systemToolProcessEnvironment()
        try unzip.run()
        unzip.waitUntilExit()
        try expect(unzip.terminationStatus, equals: 0, "problem report archive should unpack")
        let folder = try fm.contentsOfDirectory(atPath: unpacked.path)
            .first { $0.hasPrefix("Dictor-report-") }
        guard let folder else { throw SelfTestFailure.failed("problem report folder missing") }
        let unpackedFolder = unpacked.appendingPathComponent(folder)
        try expect(
            try String(contentsOf: unpackedFolder.appendingPathComponent("diagnostics.txt"),
                       encoding: .utf8),
            equals: "probe diagnostics 7C1E",
            "problem report should carry the diagnostics text verbatim")
        try expect(fm.fileExists(atPath: unpackedFolder.appendingPathComponent("Dictor.log").path),
                   equals: true,
                   "problem report should carry the log tail")
    }
}
#endif
