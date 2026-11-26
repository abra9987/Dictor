// Самотесты словаря замен: правила замены по словам и фразам, падежи,
// конфликты, импорт и отправка словаря.

import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testTranscriptCorrections() throws {
        try expect(
            correctionSourcePrefill(from: "  first line\n\nsecond\tline  "),
            equals: "first line second line",
            "correction source prefill should collapse transcript whitespace"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "a", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 4)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should stay inside correction source byte limits"
        )
        try expect(
            correctionSourcePrefill(from: String(repeating: "é", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)).utf8.count,
            equals: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
            "correction source prefill should clip at character boundaries"
        )

        let normalized = normalizedTranscriptCorrections([
            TranscriptCorrection(source: "  Yeti   Nano  ", replacement: "  Blue mic  "),
            TranscriptCorrection(source: "yeti nano", replacement: "USB mic"),
            TranscriptCorrection(source: "", replacement: "ignored"),
            TranscriptCorrection(source: "empty replacement", replacement: "   ")
        ])
        try expect(
            normalized,
            equals: [TranscriptCorrection(source: "yeti nano", replacement: "USB mic")],
            "normalization should trim, drop incomplete entries, collapse duplicate sources, and keep the latest replacement"
        )

        let boundedCorrections = normalizedTranscriptCorrections(
            [
                TranscriptCorrection(source: String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES + 1),
                                     replacement: "replacement"),
                TranscriptCorrection(source: "source",
                                     replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES + 1)),
                TranscriptCorrection(source: "nul\u{0}source", replacement: "replacement"),
                TranscriptCorrection(source: "valid", replacement: "replacement")
            ]
            + (0..<(MAX_TRANSCRIPT_CORRECTIONS + 3)).map {
                TranscriptCorrection(source: "source-\($0)", replacement: "replacement-\($0)")
            }
            + [
                TranscriptCorrection(source: "source-0", replacement: "updated")
            ]
        )
        try expect(
            boundedCorrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalization should cap stored correction count"
        )
        try expect(
            boundedCorrections.first,
            equals: TranscriptCorrection(source: "valid", replacement: "replacement"),
            "normalization should keep valid corrections while dropping oversized and NUL-containing entries"
        )
        try expect(
            boundedCorrections.dropFirst().first,
            equals: TranscriptCorrection(source: "source-0", replacement: "updated"),
            "normalization should still let later duplicates update retained corrections"
        )
        try expect(
            boundedCorrections.contains(where: { $0.source == "source-\(MAX_TRANSCRIPT_CORRECTIONS)" }),
            equals: false,
            "normalization should drop new unique corrections after the cap"
        )

        let applied = TranscriptCorrector.apply(
            to: "parakeet tdt and parakeetish and PARakeet",
            corrections: [
                TranscriptCorrection(source: "parakeet", replacement: "Dictor"),
                TranscriptCorrection(source: "parakeet tdt", replacement: "Parakeet TDT")
            ]
        )
        try expect(
            applied.text,
            equals: "Parakeet TDT and parakeetish and Dictor",
            "corrections should prefer longer phrases and respect word boundaries"
        )
        try expect(
            applied.appliedCount,
            equals: 2,
            "correction count should track applied non-overlapping replacements"
        )

        // Обещания диалога «В словарь» из «Истории». Он говорит человеку три
        // вещи, и каждая должна быть правдой — иначе это дефект того же рода,
        // что «Хранить историю: 10» над архивом на десять тысяч записей.
        let promised = [TranscriptCorrection(source: "пятниц", replacement: "пятниц")]

        // 1. «Слово находится целиком»: форма с окончанием — другое слово.
        try expect(
            TranscriptCorrector.apply(to: "до пятницы", corrections: promised).appliedCount,
            equals: 0,
            "a correction must not fire inside a longer word form"
        )
        // 2. «...и в любом регистре».
        try expect(
            TranscriptCorrector.apply(
                to: "ПЯТНИЦ",
                corrections: [TranscriptCorrection(source: "пятниц", replacement: "пятниц!")]
            ).appliedCount,
            equals: 1,
            "matching must ignore case, as the dialog promises"
        )
        // 3. «...а подставляется ровно так, как написано справа»: регистр
        // найденного слова не переносится на замену. Диалог обещает именно
        // это, потому что движок именно так и делает.
        try expect(
            TranscriptCorrector.apply(
                to: "Диктор молодец",
                corrections: [TranscriptCorrection(source: "диктор", replacement: "Dictor")]
            ).text,
            equals: "Dictor молодец",
            "replacement text must be inserted verbatim, not case-matched to the source"
        )
        // Выделение из «Истории» приходит как есть — с пробелами по краям,
        // если человек прихватил лишнего мышью. Нормализация их снимает,
        // иначе запись не совпала бы ни с чем.
        try expect(
            normalizedTranscriptCorrections([
                TranscriptCorrection(source: "  пятниц \n", replacement: " пятниц ")
            ]),
            equals: [TranscriptCorrection(source: "пятниц", replacement: "пятниц")],
            "a selection dragged from the history pane must survive trimming"
        )

        let transferred = try TranscriptCorrectionsTransfer.decode(
            TranscriptCorrectionsTransfer.encode([
                TranscriptCorrection(source: "  Right Option  ", replacement: "R-Option")
            ])
        )
        try expect(
            transferred,
            equals: [TranscriptCorrection(source: "Right Option", replacement: "R-Option")],
            "document transfer should round-trip normalized corrections"
        )

        let legacyData = try JSONEncoder().encode([
            TranscriptCorrection(source: "  old phrase  ", replacement: "new phrase")
        ])
        try expect(
            try TranscriptCorrectionsTransfer.decode(legacyData),
            equals: [TranscriptCorrection(source: "old phrase", replacement: "new phrase")],
            "legacy bare-array correction files should remain importable"
        )

        var oversizedDecodeRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.decode(
                Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedDecodeRejected = true
            }
        }
        try expect(oversizedDecodeRejected, equals: true,
                   "correction transfer should reject oversized in-memory data before decoding")

        let transferTmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let transferFileManager = FileManager.default
        let oversized = transferTmpDir
            .appendingPathComponent("dictor-corrections-oversized-\(UUID().uuidString).json")
        try Data(repeating: 0x20, count: TranscriptCorrectionsTransfer.maxFileBytes + 1)
            .write(to: oversized)
        defer { try? transferFileManager.removeItem(at: oversized) }
        var oversizedRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: oversized)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .fileTooLarge = error {
                oversizedRejected = true
            }
        }
        try expect(oversizedRejected, equals: true,
                   "correction transfer should reject oversized files before decoding")

        let nonFile = transferTmpDir
            .appendingPathComponent("dictor-corrections-directory-\(UUID().uuidString)")
        try transferFileManager.createDirectory(at: nonFile, withIntermediateDirectories: false)
        defer { try? transferFileManager.removeItem(at: nonFile) }
        var nonFileRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: nonFile)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                nonFileRejected = true
            }
        }
        try expect(nonFileRejected, equals: true,
                   "correction transfer should reject non-file paths")

        let readTarget = transferTmpDir
            .appendingPathComponent("dictor-corrections-read-target-\(UUID().uuidString).json")
        try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "source", replacement: "replacement")],
            to: readTarget
        )
        defer { try? transferFileManager.removeItem(at: readTarget) }
        let readLink = transferTmpDir
            .appendingPathComponent("dictor-corrections-read-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: readLink, withDestinationURL: readTarget)
        defer { try? transferFileManager.removeItem(at: readLink) }
        var symlinkReadRejected = false
        do {
            _ = try TranscriptCorrectionsTransfer.read(from: readLink)
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkReadRejected = true
            }
        }
        try expect(symlinkReadRejected, equals: true,
                   "correction transfer should reject reads through leaf symlinks")

        let writeTarget = transferTmpDir
            .appendingPathComponent("dictor-corrections-write-target-\(UUID().uuidString).json")
        try Data("target\n".utf8).write(to: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeTarget) }
        let writeLink = transferTmpDir
            .appendingPathComponent("dictor-corrections-write-link-\(UUID().uuidString).json")
        try transferFileManager.createSymbolicLink(at: writeLink, withDestinationURL: writeTarget)
        defer { try? transferFileManager.removeItem(at: writeLink) }
        var symlinkWriteRejected = false
        do {
            try TranscriptCorrectionsTransfer.write(
                [TranscriptCorrection(source: "source", replacement: "replacement")],
                to: writeLink
            )
        } catch let error as TranscriptCorrectionsTransferError {
            if case .notRegularFile = error {
                symlinkWriteRejected = true
            }
        }
        try expect(symlinkWriteRejected, equals: true,
                   "correction transfer should reject writes through leaf symlinks")
        try expect(
            String(data: try Data(contentsOf: writeTarget), encoding: .utf8),
            equals: "target\n",
            "correction transfer symlink rejection should leave the target untouched"
        )

        let remoteOnlyChange = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            local: [TranscriptCorrection(source: "old phrase", replacement: "old")],
            remote: [TranscriptCorrection(source: "old phrase", replacement: "remote")]
        )
        try expect(
            remoteOnlyChange,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [TranscriptCorrection(source: "old phrase", replacement: "remote")],
                conflictingSources: []
            ),
            "sync merge should accept remote changes when local has not changed"
        )

        let nonConflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old")
            ],
            local: [TranscriptCorrection(source: "shared", replacement: "local")],
            remote: [
                TranscriptCorrection(source: "shared", replacement: "old"),
                TranscriptCorrection(source: "removed locally", replacement: "old"),
                TranscriptCorrection(source: "remote only", replacement: "remote")
            ]
        )
        try expect(
            nonConflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(
                corrections: [
                    TranscriptCorrection(source: "shared", replacement: "local"),
                    TranscriptCorrection(source: "remote only", replacement: "remote")
                ],
                conflictingSources: []
            ),
            "sync merge should combine non-conflicting local edits, local deletes, and remote additions"
        )

        let conflictingMerge = mergedTranscriptCorrectionsForSync(
            base: [TranscriptCorrection(source: "same source", replacement: "old")],
            local: [TranscriptCorrection(source: "same source", replacement: "local")],
            remote: [TranscriptCorrection(source: "same source", replacement: "remote")]
        )
        try expect(
            conflictingMerge,
            equals: TranscriptCorrectionSyncMergeResult(corrections: [],
                                                        conflictingSources: ["same source"]),
            "sync merge should report same-source edits that changed differently on both sides"
        )

        let normalizedSyncPath = normalizedCorrectionSyncFilePath(" /tmp/dictor/../Dictor Corrections.dictor-corrections\n")
        try expect(
            normalizedSyncPath,
            equals: "/tmp/Dictor Corrections.dictor-corrections",
            "correction sync path normalization should trim and standardize absolute paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("relative/path.dictor-corrections"),
            equals: nil,
            "correction sync path normalization should reject relative paths"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/tmp/\u{0}dictor.dictor-corrections"),
            equals: nil,
            "correction sync path normalization should reject NUL bytes"
        )
        try expect(
            normalizedCorrectionSyncFilePath("/" + String(repeating: "x", count: MAX_CORRECTION_SYNC_PATH_BYTES)),
            equals: nil,
            "correction sync path normalization should reject oversized paths"
        )

        // Reject leaf-symlinks at the sync path so an attacker who can
        // plant a symlink at the persisted sync-file location cannot use
        // the periodic auto-write to overwrite an unrelated file.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
        let fm = FileManager.default
        let nonexistent = tmpDir.appendingPathComponent("dictor-sync-test-missing-\(UUID().uuidString).json")
        try validateCorrectionSyncPath(nonexistent) // missing files are allowed (first-time write)

        let regular = tmpDir.appendingPathComponent("dictor-sync-test-regular-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: regular)
        defer { try? fm.removeItem(at: regular) }
        try validateCorrectionSyncPath(regular)

        let target = tmpDir.appendingPathComponent("dictor-sync-test-target-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: target)
        defer { try? fm.removeItem(at: target) }
        let link = tmpDir.appendingPathComponent("dictor-sync-test-link-\(UUID().uuidString).json")
        try fm.createSymbolicLink(at: link, withDestinationURL: target)
        defer { try? fm.removeItem(at: link) }
        var rejected = false
        do {
            try validateCorrectionSyncPath(link)
        } catch is TranscriptCorrectionsSyncPathError {
            rejected = true
        }
        try expect(rejected, equals: true,
                   "validateCorrectionSyncPath should reject a leaf symlink")
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: TranscriptCorrectionsSyncPathError.isSymbolicLink),
            equals: true,
            "unsafe sync paths should stop configured correction sync"
        )
        try expect(
            shouldStopCorrectionSync(afterPathValidationError: NSError(domain: "DictorTest", code: 1)),
            equals: false,
            "unrelated sync errors should not clear the configured correction sync path"
        )
        try expect(
            correctionSyncFingerprint(for: link),
            equals: nil,
            "correction sync fingerprinting should not follow leaf symlinks"
        )

        let sameSizeA = tmpDir.appendingPathComponent("dictor-sync-fingerprint-a-\(UUID().uuidString).json")
        let sameSizeB = tmpDir.appendingPathComponent("dictor-sync-fingerprint-b-\(UUID().uuidString).json")
        try Data("aaaa".utf8).write(to: sameSizeA)
        try Data("bbbb".utf8).write(to: sameSizeB)
        defer {
            try? fm.removeItem(at: sameSizeA)
            try? fm.removeItem(at: sameSizeB)
        }
        let sharedModifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeA.path)
        try fm.setAttributes([.modificationDate: sharedModifiedAt], ofItemAtPath: sameSizeB.path)

        guard let fingerprintA = correctionSyncFingerprint(for: sameSizeA),
              let fingerprintB = correctionSyncFingerprint(for: sameSizeB) else {
            throw SelfTestFailure.failed("correction sync fingerprint should read regular files")
        }
        try expect(
            fingerprintA.size,
            equals: fingerprintB.size,
            "same-size sync files should have equal size metadata in the fingerprint"
        )
        try expect(
            fingerprintA == fingerprintB,
            equals: false,
            "correction sync fingerprint should detect content changes even when file size matches"
        )

        // The full legal correction set must encode within the
        // transfer cap: 512 entries at the per-field caps is ~2.4 MB
        // encoded, which silently failed to save under the old 2 MiB
        // cap. Also pin that it really is over 2 MiB, documenting why
        // the cap moved to 4 MiB.
        let worstCaseSet = (0..<MAX_TRANSCRIPT_CORRECTIONS).map { index in
            TranscriptCorrection(
                source: String(format: "%06d-", index)
                    + String(repeating: "s", count: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES - 7),
                replacement: String(repeating: "r", count: MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES)
            )
        }
        let worstCaseData = try TranscriptCorrectionsTransfer.encode(worstCaseSet)
        try expect(
            worstCaseData.count > 2 * 1024 * 1024,
            equals: true,
            "worst-case legal correction set should exceed the old 2 MiB cap (why the cap is now larger)"
        )
        try expect(
            worstCaseData.count <= TranscriptCorrectionsTransfer.maxFileBytes,
            equals: true,
            "worst-case legal correction set must fit the transfer cap with JSON-overhead headroom"
        )
        try expect(
            try TranscriptCorrectionsTransfer.decode(worstCaseData).count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "worst-case legal correction set should round-trip through the transfer cap"
        )

        // Near the correction cap a merge can briefly exceed it. The
        // sync baseline must store the same normalized (capped) list
        // that is written to the file — a raw over-cap baseline makes
        // the capped-out entry look like a local deletion later.
        let sharedNearCap = (0..<(MAX_TRANSCRIPT_CORRECTIONS - 1)).map {
            TranscriptCorrection(source: "shared-\($0)", replacement: "same")
        }
        let nearCapMerge = mergedTranscriptCorrectionsForSync(
            base: sharedNearCap,
            local: sharedNearCap + [TranscriptCorrection(source: "local-extra", replacement: "local")],
            remote: sharedNearCap + [TranscriptCorrection(source: "remote-extra", replacement: "remote")]
        )
        try expect(
            nearCapMerge.conflictingSources,
            equals: [],
            "near-cap merge with disjoint additions should not conflict"
        )
        try expect(
            nearCapMerge.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 1,
            "near-cap merge result can exceed the cap before normalization"
        )
        let nearCapNormalized = normalizedTranscriptCorrections(nearCapMerge.corrections)
        try expect(
            nearCapNormalized.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "normalizing the near-cap merge result should drop the over-cap entry"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "local-extra", replacement: "local")),
            equals: true,
            "normalization keeps the earlier (local) addition at the cap"
        )
        try expect(
            nearCapNormalized.contains(TranscriptCorrection(source: "remote-extra", replacement: "remote")),
            equals: false,
            "the capped-out remote addition is exactly what the baseline must also drop"
        )

        // Fingerprinting the bytes we wrote must agree with a fresh
        // disk fingerprint when nobody touched the file in between —
        // the sync path uses the in-memory form so a provider replacing
        // the file in the write-to-fingerprint window is still detected
        // by the next scan.
        let fingerprintWriteTarget = tmpDir
            .appendingPathComponent("dictor-sync-written-fingerprint-\(UUID().uuidString).json")
        let fingerprintWrittenData = try TranscriptCorrectionsTransfer.write(
            [TranscriptCorrection(source: "fingerprint", replacement: "match")],
            to: fingerprintWriteTarget
        )
        defer { try? fm.removeItem(at: fingerprintWriteTarget) }
        guard let fingerprintFromDisk = correctionSyncFingerprint(for: fingerprintWriteTarget) else {
            throw SelfTestFailure.failed("disk fingerprint should be readable right after a write")
        }
        try expect(
            correctionSyncFingerprint(forWrittenData: fingerprintWrittenData, at: fingerprintWriteTarget),
            equals: fingerprintFromDisk,
            "fingerprint of written bytes should match the disk fingerprint of an untouched file"
        )

        // Counted decode keeps the file's pre-normalization entry count
        // so the import dialog can disclose truncation.
        let countedOriginal = (0..<(MAX_TRANSCRIPT_CORRECTIONS + 5)).map {
            TranscriptCorrection(source: "counted-\($0)", replacement: "kept")
        }
        let countedEncoder = JSONEncoder()
        countedEncoder.dateEncodingStrategy = .iso8601
        let countedDocument = TranscriptCorrectionsDocument(
            schemaVersion: TranscriptCorrectionsTransfer.schemaVersion,
            exportedAt: Date(),
            appVersion: currentBundleVersion(),
            corrections: countedOriginal
        )
        let counted = try TranscriptCorrectionsTransfer.decodeCounted(countedEncoder.encode(countedDocument))
        try expect(
            counted.originalCount,
            equals: MAX_TRANSCRIPT_CORRECTIONS + 5,
            "counted decode should report the file's pre-normalization entry count"
        )
        try expect(
            counted.corrections.count,
            equals: MAX_TRANSCRIPT_CORRECTIONS,
            "counted decode should still normalize down to the correction cap"
        )
        let countedLegacy = try TranscriptCorrectionsTransfer.decodeCounted(
            try JSONEncoder().encode([TranscriptCorrection(source: "  legacy  ", replacement: "entry")])
        )
        try expect(
            countedLegacy,
            equals: TranscriptCorrectionsTransfer.CountedDecodeResult(
                corrections: [TranscriptCorrection(source: "legacy", replacement: "entry")],
                originalCount: 1
            ),
            "counted decode should support legacy bare-array files"
        )

        // Import dialog copy: state the original count when entries
        // will be dropped, and warn before a cap-overflowing merge.
        try expect(
            correctionImportCountText(sourceName: "file.dictor-corrections",
                                      originalCount: 3,
                                      keptCount: 3),
            equals: "file.dictor-corrections contains 3 corrections.",
            "import count text should stay simple when nothing is dropped"
        )
        let truncatedImportText = correctionImportCountText(
            sourceName: "big.dictor-corrections",
            originalCount: MAX_TRANSCRIPT_CORRECTIONS + 88,
            keptCount: MAX_TRANSCRIPT_CORRECTIONS
        )
        try expect(
            truncatedImportText.contains("contains \(MAX_TRANSCRIPT_CORRECTIONS + 88) entries"),
            equals: true,
            "import count text should state the file's original entry count when entries are dropped"
        )
        try expect(
            truncatedImportText.contains("first \(MAX_TRANSCRIPT_CORRECTIONS)"),
            equals: true,
            "import count text should state how many corrections will actually be kept"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: 10, newCount: 10),
            equals: nil,
            "merge cap warning should stay silent when the merged set fits"
        )
        try expect(
            correctionImportMergeCapWarningText(existingCount: MAX_TRANSCRIPT_CORRECTIONS,
                                                newCount: 8)?.contains("8 would be dropped"),
            equals: true,
            "merge cap warning should state how many corrections a merge would drop"
        )

        // Слияние импорта — общая логика окна и службы. Раньше она была
        // приватной внутри службы и не проверялась ничем.
        let existing = [TranscriptCorrection(source: "kept", replacement: "Kept"),
                        TranscriptCorrection(source: "stale", replacement: "Old")]
        let incoming = [TranscriptCorrection(source: "stale", replacement: "New"),
                        TranscriptCorrection(source: "added", replacement: "Added"),
                        TranscriptCorrection(source: "kept", replacement: "Kept")]

        let summary = correctionImportSummary(existing: existing, imported: incoming)
        try expect(summary.total, equals: 3, "import summary should count every entry")
        try expect(summary.newCount, equals: 1, "import summary should count new sources")
        try expect(summary.updatedCount, equals: 1,
                   "import summary should count sources whose replacement changes")
        try expect(summary.unchangedCount, equals: 1,
                   "import summary should count entries that already match")

        let merged = transcriptCorrections(afterApplying: incoming, to: existing, mode: .merge)
        try expect(
            merged,
            equals: [TranscriptCorrection(source: "kept", replacement: "Kept"),
                     TranscriptCorrection(source: "stale", replacement: "New"),
                     TranscriptCorrection(source: "added", replacement: "Added")],
            "merge should update matching sources in place and append new ones"
        )
        try expect(
            transcriptCorrections(afterApplying: incoming, to: existing, mode: .replace),
            equals: normalizedTranscriptCorrections(incoming),
            "replace should make the dictionary an exact copy of the file"
        )
        try expect(
            transcriptCorrections(afterApplying: [], to: existing, mode: .replace),
            equals: [],
            "replace with an empty file should empty the dictionary"
        )

        try testDictionaryShare()
    }

    /// «Поделиться словарём»: файл собирается тем же форматом, что экспорт, и
    /// читается обычным импортом — иначе присланное пришлось бы разбирать
    /// руками. В письме — число записей и ни одной самой записи: тело письма
    /// человек видит до отправки, но словарь в нём дублировать незачем.
    private static func testDictionaryShare() throws {
        let fm = FileManager.default
        let shared = try DictionaryShare.build(
            corrections: [
                TranscriptCorrection(source: "  клауд   код ", replacement: "Claude Code"),
                TranscriptCorrection(source: "клауд код", replacement: "Claude Code"),
                TranscriptCorrection(source: "тазбар", replacement: "Taskbar"),
                TranscriptCorrection(source: "", replacement: "ignored"),
            ],
            now: Date(timeIntervalSince1970: 0))
        defer { try? fm.removeItem(at: shared.url.deletingLastPathComponent()) }

        try expect(shared.correctionCount, equals: 2,
                   "the shared file should count normalized corrections, not raw entries")
        try expect(shared.url.pathExtension, equals: CORRECTIONS_FILE_EXTENSION,
                   "the shared file should open with the ordinary dictionary import")
        try expect(shared.url.lastPathComponent.hasPrefix("Dictor-dictionary-"), equals: true,
                   "the shared file name should say what it is")
        try expect(
            try TranscriptCorrectionsTransfer.read(from: shared.url),
            equals: [TranscriptCorrection(source: "клауд код", replacement: "Claude Code"),
                     TranscriptCorrection(source: "тазбар", replacement: "Taskbar")],
            "the shared file should round-trip through the import reader")

        for language in [InterfaceLanguage.russian, .english] {
            let body = DictionaryShare.messageBody(file: shared, language: language)
            try expect(body.contains("Dictor \(currentBundleVersion())"), equals: true,
                       "the share message should name the app version")
            try expect(body.contains("Claude Code") || body.contains("тазбар"), equals: false,
                       "the share message should not repeat dictionary entries")
        }
        try expect(
            DictionaryShare.messageBody(file: shared, language: .russian).contains("2 автозамены"),
            equals: true,
            "the Russian share message should say how many corrections are attached")
        try expect(
            DictionaryShare.messageBody(file: shared, language: .english).contains("2 corrections"),
            equals: true,
            "the English share message should say how many corrections are attached")
    }
}
#endif
