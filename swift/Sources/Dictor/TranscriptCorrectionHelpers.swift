import Foundation
import CryptoKit

func normalizedTranscriptCorrectionSource(_ source: String) -> String {
    source
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .lowercased()
}

func normalizedTranscriptCorrections(
    _ corrections: [TranscriptCorrection],
    limit: Int = MAX_TRANSCRIPT_CORRECTIONS
) -> [TranscriptCorrection] {
    var result: [TranscriptCorrection] = []
    var indexBySource: [String: Int] = [:]

    for correction in corrections {
        let source = correction.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = correction.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedTranscriptCorrectionSource(source)
        guard !source.isEmpty,
              !replacement.isEmpty,
              !key.isEmpty,
              source.utf8.count <= MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES,
              replacement.utf8.count <= MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES,
              !source.unicodeScalars.contains(where: { $0.value == 0 }),
              !replacement.unicodeScalars.contains(where: { $0.value == 0 }) else {
            continue
        }

        let cleaned = TranscriptCorrection(source: source, replacement: replacement)
        if let existing = indexBySource[key] {
            result[existing] = cleaned
        } else {
            guard result.count < limit else { continue }
            indexBySource[key] = result.count
            result.append(cleaned)
        }
    }

    return result
}

/// First line of the import-confirmation dialog. When the file holds
/// more entries than survive normalization (over the
/// MAX_TRANSCRIPT_CORRECTIONS cap, or invalid/duplicate entries), the
/// dialog must state the file's real count and how many will actually
/// be kept — normalization runs before the dialog, so without this the
/// user is told an oversized file "contains 512 corrections".
func correctionImportCountText(sourceName: String, originalCount: Int, keptCount: Int,
                               language: InterfaceLanguage = .english) -> String {
    guard originalCount > keptCount else {
        return localizedText("Автозамен в файле «\(sourceName)»: \(keptCount).",
                             "\(sourceName) contains \(keptCount) corrections.",
                             language: language)
    }
    return localizedText(
        "Записей в файле «\(sourceName)»: \(originalCount); импортированы будут только "
        + "первые \(keptCount) корректных — Dictor хранит не больше "
        + "\(MAX_TRANSCRIPT_CORRECTIONS).",
        "\(sourceName) contains \(originalCount) entries; only the first \(keptCount) valid corrections (Dictor keeps at most \(MAX_TRANSCRIPT_CORRECTIONS)) will be imported.",
        language: language)
}

/// Appended to the import dialog when choosing Merge would push the
/// combined set over the correction cap. The merge path drops over-cap
/// entries silently, so the dialog has to warn before the user picks.
func correctionImportMergeCapWarningText(existingCount: Int,
                                         newCount: Int,
                                         cap: Int = MAX_TRANSCRIPT_CORRECTIONS,
                                         language: InterfaceLanguage = .english) -> String? {
    let mergedCount = existingCount + newCount
    guard mergedCount > cap else { return nil }
    return localizedText(
        "После объединения вышло бы \(mergedCount) автозамен; Dictor хранит не больше "
        + "\(cap), лишние \(mergedCount - cap) будут отброшены.",
        "Merging would produce \(mergedCount) corrections; Dictor keeps at most \(cap), so \(mergedCount - cap) would be dropped.",
        language: language)
}

func utf8ClippedPrefix(_ text: String, maxBytes: Int) -> String {
    guard maxBytes > 0 else { return "" }
    var result = ""
    var usedBytes = 0
    for character in text {
        let byteCount = String(character).utf8.count
        guard usedBytes + byteCount <= maxBytes else { break }
        result.append(character)
        usedBytes += byteCount
    }
    return result
}

func correctionSourcePrefill(from transcript: String) -> String {
    let flat = transcript
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    return utf8ClippedPrefix(flat, maxBytes: MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES)
}

struct TranscriptCorrectionSyncMergeResult: Equatable {
    let corrections: [TranscriptCorrection]
    let conflictingSources: [String]
}

struct CorrectionSyncFileFingerprint: Equatable {
    let modifiedAt: Date?
    let size: Int?
    let sha256: String
}

func correctionSyncFingerprint(for url: URL) -> CorrectionSyncFileFingerprint? {
    do {
        let digest = try correctionSyncFileSHA256Hex(url)
        let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return CorrectionSyncFileFingerprint(modifiedAt: values.contentModificationDate,
                                             size: values.fileSize,
                                             sha256: digest)
    } catch {
        return nil
    }
}

/// Fingerprint for bytes this process just wrote to `url`. Content
/// hash and size come from the in-memory data — never from re-reading
/// the file, which races with a sync provider replacing it in the
/// write-to-fingerprint window and would swallow that remote change
/// until the next local edit. Only the modification date is read
/// back; if even that races, the SHA mismatch on the next scan still
/// detects the remote change.
func correctionSyncFingerprint(forWrittenData data: Data, at url: URL) -> CorrectionSyncFileFingerprint {
    var hasher = SHA256()
    hasher.update(data: data)
    let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    let modifiedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
    return CorrectionSyncFileFingerprint(modifiedAt: modifiedAt,
                                         size: data.count,
                                         sha256: digest)
}

func correctionSyncFileSHA256Hex(_ url: URL) throws -> String {
    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw TranscriptCorrectionsTransferError.notRegularFile
    }
    guard st.st_size <= TranscriptCorrectionsTransfer.maxFileBytes else {
        throw TranscriptCorrectionsTransferError.fileTooLarge(Int(st.st_size),
                                                              TranscriptCorrectionsTransfer.maxFileBytes)
    }

    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    var hasher = SHA256()
    while true {
        guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
            break
        }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

func mergedTranscriptCorrectionsForSync(base: [TranscriptCorrection],
                                        local: [TranscriptCorrection],
                                        remote: [TranscriptCorrection]) -> TranscriptCorrectionSyncMergeResult {
    let base = normalizedTranscriptCorrections(base)
    let local = normalizedTranscriptCorrections(local)
    let remote = normalizedTranscriptCorrections(remote)

    func dictionaryBySource(_ corrections: [TranscriptCorrection]) -> [String: TranscriptCorrection] {
        Dictionary(uniqueKeysWithValues: corrections.map {
            (normalizedTranscriptCorrectionSource($0.source), $0)
        })
    }

    let baseBySource = dictionaryBySource(base)
    let localBySource = dictionaryBySource(local)
    let remoteBySource = dictionaryBySource(remote)

    var orderedSources: [String] = []
    var seenSources: Set<String> = []
    func appendSources(from corrections: [TranscriptCorrection]) {
        for correction in corrections {
            let key = normalizedTranscriptCorrectionSource(correction.source)
            if seenSources.insert(key).inserted {
                orderedSources.append(key)
            }
        }
    }

    appendSources(from: local)
    appendSources(from: remote)
    appendSources(from: base)

    var merged: [TranscriptCorrection] = []
    var conflicts: [String] = []

    for source in orderedSources {
        let baseline = baseBySource[source]
        let localCorrection = localBySource[source]
        let remoteCorrection = remoteBySource[source]

        let chosen: TranscriptCorrection?
        if localCorrection == remoteCorrection {
            chosen = localCorrection
        } else if localCorrection == baseline {
            chosen = remoteCorrection
        } else if remoteCorrection == baseline {
            chosen = localCorrection
        } else {
            conflicts.append(localCorrection?.source ?? remoteCorrection?.source ?? baseline?.source ?? source)
            continue
        }

        if let chosen {
            merged.append(chosen)
        }
    }

    return TranscriptCorrectionSyncMergeResult(corrections: merged,
                                               conflictingSources: conflicts)
}
