// Словарь замен на стороне агента: импорт из открытого файла и синхронизация
// с файлом на диске (общий словарь для нескольких Mac).

import AppKit

extension DictorApp {
    /// Двойной клик по файлу `.dictor-corrections` в Finder. Полный
    /// словарный UI живёт в окне, но файл LaunchServices приносит агенту —
    /// поэтому здесь остаётся маленький локализованный диалог поверх той же
    /// логики слияния, что и в окне.
    func importCorrectionsFromOpenedFile(_ url: URL) -> Bool {
        showAppForModal()
        do {
            let imported = try TranscriptCorrectionsTransfer.readCounted(from: url)
            let normalized = normalizedTranscriptCorrections(imported.corrections)
            guard !normalized.isEmpty else {
                showCorrectionTransferError(
                    title: t("В файле нет автозамен", "No Text Corrections Found"),
                    message: t("В файле «\(url.lastPathComponent)» нет ни одной автозамены.",
                               "\(url.lastPathComponent) does not contain any corrections to import."))
                return false
            }
            let summary = correctionImportSummary(existing: settings.transcriptCorrections,
                                                  imported: normalized)
            let countText = correctionImportCountText(sourceName: url.lastPathComponent,
                                                      originalCount: imported.originalCount,
                                                      keptCount: summary.total,
                                                      language: settings.interfaceLanguage)
            let capWarning = correctionImportMergeCapWarningText(
                existingCount: settings.transcriptCorrections.count,
                newCount: summary.newCount,
                language: settings.interfaceLanguage)
            let alert = NSAlert()
            alert.messageText = t("Импортировать автозамены?", "Import Text Corrections?")
            alert.informativeText = t("""
                \(countText)

                Новых: \(summary.newCount) · обновят существующие: \(summary.updatedCount) · уже совпадают: \(summary.unchangedCount).

                «Объединить» сохранит записи этого Mac, которых нет в файле. «Заменить все» сделает словарь точной копией файла.\(capWarning.map { "\n\n" + $0 } ?? "")
                """, """
                \(countText)

                \(summary.newCount) new, \(summary.updatedCount) will update existing corrections, \(summary.unchangedCount) already match.

                Merge keeps local corrections that are not in the file. Replace All makes this Mac match the file exactly.\(capWarning.map { "\n\n" + $0 } ?? "")
                """)
            alert.addButton(withTitle: t("Объединить", "Merge"))
            alert.addButton(withTitle: t("Заменить все", "Replace All"))
            alert.addButton(withTitle: t("Отмена", "Cancel"))
            let mode: CorrectionImportChoice
            switch alert.runModal() {
            case .alertFirstButtonReturn: mode = .merge
            case .alertSecondButtonReturn: mode = .replace
            default: return false
            }
            let next = transcriptCorrections(afterApplying: normalized,
                                             to: settings.transcriptCorrections,
                                             mode: mode)
            updateTranscriptCorrections(next)
            log("correction import read \(normalized.count) corrections from an opened file")
            return true
        } catch {
            showCorrectionTransferError(title: t("Импорт не удался", "Import Failed"),
                                        error: error)
            return false
        }
    }

    private func updateTranscriptCorrections(_ corrections: [TranscriptCorrection],
                                             writeToSync: Bool = true) {
        if let error = settings.storeTranscriptCorrections(normalizedTranscriptCorrections(corrections)) {
            // The previous value is still in place. Surface the failed
            // save like export/sync-write failures do — silently
            // dropping the user's edit looked like data loss.
            showCorrectionTransferError(title: "Saving Corrections Failed", error: error)
            rebuildMenu()
            return
        }
        if writeToSync, !isApplyingCorrectionSyncFile {
            writeCorrectionsToSyncFile(presentErrors: false)
        }
        rebuildMenu()
    }

    private func correctionSyncFileURL() -> URL? {
        let path = settings.transcriptCorrectionsSyncFile
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Все записи пути синхронизации из самой службы идут здесь: наблюдатель
    /// настроек сверяет путь с прошлым тиком, и собственную запись он должен
    /// увидеть уже «своей», иначе примет её за внешнюю и перезапустит цикл.
    private func setCorrectionSyncFilePath(_ path: String) {
        settings.transcriptCorrectionsSyncFile = path
        lastSeenCorrectionSyncFilePath = settings.transcriptCorrectionsSyncFile
    }

    func startCorrectionSyncIfConfigured() {
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        guard correctionSyncFileURL() != nil else {
            correctionSyncFileFingerprint = nil
            correctionSyncBaselineCorrections = []
            return
        }

        scheduleCorrectionSyncScan(force: true, presentErrors: false)
        // The timer always starts; if the initial async scan rejects
        // the path it stops the sync (and this timer) from its
        // main-actor completion.
        correctionSyncTimer = Timer.scheduledTimer(timeInterval: 4,
                                                   target: self,
                                                   selector: #selector(correctionSyncTimerFired(_:)),
                                                   userInfo: nil,
                                                   repeats: true)
        correctionSyncTimer?.tolerance = 1
    }

    @objc private func correctionSyncTimerFired(_ timer: Timer) {
        scheduleCorrectionSyncScan(force: false, presentErrors: false)
    }

    /// What a background sync-file scan found. Built off the main
    /// thread, applied on the main actor — so it must be Sendable and
    /// carry everything the apply step needs.
    private enum CorrectionSyncScanOutcome: Sendable {
        case rejectedPath(TranscriptCorrectionsSyncPathError)
        case fingerprintUnavailable
        case unchanged
        case loaded(corrections: [TranscriptCorrection], fingerprint: CorrectionSyncFileFingerprint)
        case readFailed(logDescription: String, alertMessage: String)
    }

    /// Runs on `correctionSyncScanQueue` (hence `nonisolated`). Pure
    /// with respect to app state: everything it needs arrives as
    /// parameters and the result goes back as a value.
    private nonisolated static func performCorrectionSyncScan(url: URL,
                                                  lastFingerprint: CorrectionSyncFileFingerprint?,
                                                  force: Bool) -> CorrectionSyncScanOutcome {
        do {
            try validateCorrectionSyncPath(url)
        } catch let error as TranscriptCorrectionsSyncPathError {
            return .rejectedPath(error)
        } catch {
            // validateCorrectionSyncPath only throws
            // TranscriptCorrectionsSyncPathError today; keep the
            // catch-all defensive rather than crashing the scan.
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
        guard let fingerprint = correctionSyncFingerprint(for: url) else {
            return .fingerprintUnavailable
        }
        guard force || fingerprint != lastFingerprint else { return .unchanged }
        do {
            let corrections = try TranscriptCorrectionsTransfer.read(from: url)
            return .loaded(corrections: corrections, fingerprint: fingerprint)
        } catch {
            return .readFailed(logDescription: "\(error)",
                               alertMessage: error.localizedDescription)
        }
    }

    private func scheduleCorrectionSyncScan(force: Bool, presentErrors: Bool) {
        guard let url = correctionSyncFileURL() else { return }
        // Never let scans overlap — a dataless iCloud file can block
        // one scan for many timer periods. Requests that arrive while
        // a scan is in flight are coalesced (strongest flags win) and
        // re-issued when it completes, so a user's explicit
        // "Sync Corrections Now" is never silently dropped behind a
        // stalled timer scan.
        guard !correctionSyncScanInFlight else {
            let pending = pendingCorrectionSyncScan
            pendingCorrectionSyncScan = (force: (pending?.force ?? false) || force,
                                         presentErrors: (pending?.presentErrors ?? false) || presentErrors)
            return
        }
        correctionSyncScanInFlight = true
        let lastFingerprint = correctionSyncFileFingerprint
        Self.correctionSyncScanQueue.async { [weak self] in
            let outcome = Self.performCorrectionSyncScan(url: url,
                                                         lastFingerprint: lastFingerprint,
                                                         force: force)
            Task { @MainActor in
                guard let self else { return }
                self.correctionSyncScanInFlight = false
                self.applyCorrectionSyncScanOutcome(outcome,
                                                    scannedURL: url,
                                                    scanStartFingerprint: lastFingerprint,
                                                    force: force,
                                                    presentErrors: presentErrors)
                if let pending = self.pendingCorrectionSyncScan {
                    self.pendingCorrectionSyncScan = nil
                    self.scheduleCorrectionSyncScan(force: pending.force,
                                                    presentErrors: pending.presentErrors)
                }
            }
        }
    }

    private func applyCorrectionSyncScanOutcome(_ outcome: CorrectionSyncScanOutcome,
                                                scannedURL: URL,
                                                scanStartFingerprint: CorrectionSyncFileFingerprint?,
                                                force: Bool,
                                                presentErrors: Bool) {
        // The sync file may have been disconnected or repointed while
        // the scan ran; results for a stale path must not touch
        // current state.
        guard let url = correctionSyncFileURL(), url == scannedURL else { return }

        switch outcome {
        case .rejectedPath(let error):
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
        case .fingerprintUnavailable:
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed",
                                            message: "Dictor could not find the selected sync file.")
            }
        case .unchanged:
            break
        case .loaded(let corrections, let fingerprint):
            // If a local edit wrote the sync file (moving the
            // fingerprint) while the scan ran, this outcome holds
            // pre-edit content; applying it would roll the edit back
            // and rewind the baseline. Drop it — a forced scan is
            // re-issued so a "Sync Now" still completes against the
            // post-edit file.
            guard correctionSyncFileFingerprint == scanStartFingerprint else {
                if force {
                    scheduleCorrectionSyncScan(force: true, presentErrors: presentErrors)
                }
                return
            }
            // Non-forced scans only apply genuinely new content
            // (forced scans deliberately re-apply even an unchanged
            // file — that is what "Sync Now" promises).
            guard force || fingerprint != correctionSyncFileFingerprint else { return }
            isApplyingCorrectionSyncFile = true
            updateTranscriptCorrections(corrections, writeToSync: false)
            isApplyingCorrectionSyncFile = false
            correctionSyncFileFingerprint = fingerprint
            correctionSyncBaselineCorrections = normalizedTranscriptCorrections(corrections)
            log("correction sync read \(corrections.count) corrections")
        case .readFailed(let logDescription, let alertMessage):
            log("correction sync read failed: \(logDescription)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", message: alertMessage)
            }
        }
    }

    @discardableResult
    func writeCorrectionsToSyncFile(presentErrors: Bool) -> Bool {
        guard let url = correctionSyncFileURL() else { return true }
        do {
            try validateCorrectionSyncPath(url)
        } catch {
            handleCorrectionSyncRejectedPath(error, presentErrors: presentErrors)
            return false
        }
        do {
            var correctionsToWrite = normalizedTranscriptCorrections(settings.transcriptCorrections)
            if let knownFingerprint = correctionSyncFileFingerprint,
               let currentFingerprint = correctionSyncFingerprint(for: url),
               currentFingerprint != knownFingerprint {
                let remoteCorrections = try TranscriptCorrectionsTransfer.read(from: url)
                let merge = mergedTranscriptCorrectionsForSync(
                    base: correctionSyncBaselineCorrections,
                    local: correctionsToWrite,
                    remote: remoteCorrections
                )
                if !merge.conflictingSources.isEmpty {
                    stopCorrectionSyncAfterConflict(conflictingSources: merge.conflictingSources)
                    log("correction sync stopped after \(merge.conflictingSources.count) conflicting corrections")
                    return false
                }
                // Normalize (cap) the merge result BEFORE it fans out:
                // file, settings, and baseline must all hold the same
                // list. A raw over-cap merge result stored as baseline
                // made capped-out entries look like local deletions on
                // the next merge, silently removing them from the file.
                correctionsToWrite = normalizedTranscriptCorrections(merge.corrections)
                if let storeError = settings.storeTranscriptCorrections(correctionsToWrite) {
                    throw storeError
                }
            }

            let writtenData = try TranscriptCorrectionsTransfer.write(correctionsToWrite, to: url)
            // Fingerprint the exact bytes written, not a re-read of the
            // file: a sync provider replacing the file in the re-read
            // window would have its change fingerprinted as ours and
            // swallowed until the next local edit.
            correctionSyncFileFingerprint = correctionSyncFingerprint(forWrittenData: writtenData, at: url)
            correctionSyncBaselineCorrections = correctionsToWrite
            log("correction sync wrote \(correctionsToWrite.count) corrections")
            return true
        } catch {
            log("correction sync write failed: \(error)")
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return false
        }
    }

    private func handleCorrectionSyncRejectedPath(_ error: Error, presentErrors: Bool) {
        log("correction sync rejected path: \(error)")
        guard shouldStopCorrectionSync(afterPathValidationError: error) else {
            if presentErrors {
                showCorrectionTransferError(title: "Sync Failed", error: error)
            }
            return
        }

        stopCorrectionSyncAfterRejectedPath(error: error, presentErrors: presentErrors)
    }

    private func stopCorrectionSyncAfterConflict(conflictingSources: [String]) {
        setCorrectionSyncFilePath("")
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        rebuildMenu()

        let exampleCount = min(conflictingSources.count, 3)
        let examples = conflictingSources.prefix(exampleCount).joined(separator: "\n")
        let remaining = conflictingSources.count - exampleCount
        let remainingText = remaining > 0 ? "\n…and \(remaining) more." : ""
        showAppForModal()
        showCorrectionTransferError(
            title: "Text Correction Sync Conflict",
            message: """
            The sync file changed before this Mac wrote its latest text correction edits. Dictor kept the corrections on this Mac and stopped syncing so it would not overwrite the file.

            Reconnect the sync file after importing or resolving the conflicting correction\(conflictingSources.count == 1 ? "" : "s"):
            \(examples)\(remainingText)
            """
        )
    }

    private func stopCorrectionSyncAfterRejectedPath(error: Error, presentErrors: Bool) {
        setCorrectionSyncFilePath("")
        correctionSyncTimer?.invalidate()
        correctionSyncTimer = nil
        correctionSyncFileFingerprint = nil
        correctionSyncBaselineCorrections = []
        log("correction sync stopped after rejected path")
        rebuildMenu()

        if presentErrors {
            showCorrectionTransferError(
                title: "Text Correction Sync Stopped",
                message: """
                Dictor stopped syncing because the selected corrections file is no longer safe to use.

                \(error.localizedDescription)
                """
            )
        }
    }

    private func showCorrectionTransferError(title: String, error: Error) {
        showCorrectionTransferError(title: title, message: error.localizedDescription)
    }

    private func showCorrectionTransferError(title: String, message: String) {
        showAppForModal()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
