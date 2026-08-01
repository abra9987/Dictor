import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Transcript corrections
//
// Deterministic local rewrite pass for words or phrases the model
// consistently mishears. Corrections are applied to the transcript
// text before paste/history, never to audio, and replacement text is
// used exactly as the user typed it.

enum SpeechModelTextRepair {
    /// Parakeet TDT v3 emits `<unk>` for Cyrillic "ё" in Russian text.
    /// For Russian and auto-detect (the app's default audience) the
    /// token is replaced with "ё"/"Ё". For every other language the
    /// token is genuinely unknown and is removed entirely so a stray
    /// Cyrillic character doesn't appear in English/French/etc. text.
    static func apply(to text: String,
                      language: DictationLanguage = .auto) -> String {
        guard text.localizedCaseInsensitiveContains("<unk>") else { return text }

        let replaceWithYo: Bool
        switch language {
        case .auto, .russian:
            replaceWithYo = true
        default:
            replaceWithYo = false
        }

        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while index < text.endIndex {
            if matchesUnknownToken(in: text, at: index) {
                if replaceWithYo {
                    result.append(shouldCapitalizeYo(before: result) ? "Ё" : "ё")
                }
                index = text.index(index, offsetBy: 5)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }

        if !replaceWithYo {
            result = result
                .replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func matchesUnknownToken(in text: String, at index: String.Index) -> Bool {
        let token = "<unk>"
        guard let end = text.index(index, offsetBy: token.count, limitedBy: text.endIndex) else {
            return false
        }
        return text[index..<end].lowercased() == token
    }

    private static func shouldCapitalizeYo(before prefix: String) -> Bool {
        guard let last = prefix.last(where: { !$0.isWhitespace }) else { return true }
        return ".!?".contains(last)
    }
}

enum TranscriptCorrector {
    private struct Match {
        let range: NSRange
        let replacement: String
    }

    static func apply(to text: String, corrections: [TranscriptCorrection]) -> (text: String, appliedCount: Int) {
        // Предел шире пользовательского: сюда приходит и встроенный
        // набор написаний, который в настройках не хранится.
        let active = normalizedTranscriptCorrections(
            corrections,
            limit: MAX_TRANSCRIPT_CORRECTIONS + BuiltInSpellings.count
                + LatinTermRestorations.count)
            .sorted { lhs, rhs in
                if lhs.source.count != rhs.source.count { return lhs.source.count > rhs.source.count }
                return lhs.source.localizedCaseInsensitiveCompare(rhs.source) == .orderedAscending
            }

        guard !text.isEmpty, !active.isEmpty else { return (text, 0) }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var matches: [Match] = []

        for correction in active {
            guard let pattern = pattern(for: correction),
                  let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            else { continue }

            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let range = match?.range, range.location != NSNotFound else { return }
                guard !matches.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
                // Уже написанное правильно пропускаем: замена «SQL» на «SQL»
                // ничего не меняет, но попадает в счётчик правок.
                if let found = Range(range, in: text), text[found] == correction.replacement {
                    return
                }
                matches.append(Match(range: range, replacement: correction.replacement))
            }
        }

        guard !matches.isEmpty else { return (text, 0) }

        let rewritten = NSMutableString(string: text)
        for match in matches.sorted(by: { $0.range.location > $1.range.location }) {
            rewritten.replaceCharacters(in: match.range, with: match.replacement)
        }
        return (rewritten as String, matches.count)
    }

    private static func pattern(for correction: TranscriptCorrection) -> String? {
        var parts = correction.source
            .split(whereSeparator: { $0.isWhitespace })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        if russianInflectionAllowed(for: correction), let last = parts.last {
            parts[parts.count - 1] = inflectedWordPattern(for: last)
        }
        return #"(?<![\p{L}\p{N}_])"# + parts.joined(separator: #"\s+"#) + #"(?![\p{L}\p{N}_])"#
    }

    /// Русские окончания, которые разрешено проглотить вместе с названием.
    ///
    /// Список закрыт нарочно. Регулярка вида «гитхаб\w*» подобрала бы и
    /// «гитхабный», и «гитхабище», то есть выдумывала бы за человека; здесь же
    /// множество форм конечно и его можно распечатать целиком — на этом
    /// держится самотест `latin-terms`, который проверяет каждую порождённую
    /// форму против списка русских слов.
    static let RUSSIAN_CASE_ENDINGS: [String] = [
        "а", "е", "у", "ом", "ы", "ов", "ам", "ами", "ах", "ой", "ою", "и", "я", "ю", "ем",
    ]

    /// Падеж проглатывается, но не сохраняется: «запушил в гитхабе» → «запушил
    /// в GitHub», а не «в GitHubе». Латинское название с русским хвостом
    /// читается хуже, и живые люди пишут именно так.
    ///
    /// Право на окончание даёт форма самой записи, а не её происхождение:
    /// источник целиком кириллический и не короче пяти букв, замена — без
    /// единой кириллической буквы. Поэтому ручная запись «кубернетис →
    /// Kubernetes» получает падежи наравне со встроенным набором, а написания
    /// латиницей («postgres → PostgreSQL») под правило не попадают вовсе:
    /// английское слово русских окончаний не носит.
    static func russianInflectionAllowed(for correction: TranscriptCorrection) -> Bool {
        func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
            (0x0400...0x04FF).contains(Int(scalar.value))
        }
        let letters = correction.source.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }
        guard letters.count >= 5, letters.allSatisfy(isCyrillic) else { return false }
        return !correction.replacement.unicodeScalars.contains(where: isCyrillic)
    }

    /// Хвост слова, к которому можно приписать окончание. Слово на -а/-я само
    /// стоит в именительном падеже («джира», «фигма»), поэтому основа — без
    /// последней буквы, и «в джире» находится наравне с «джира».
    private static func inflectedWordPattern(for escapedWord: String) -> String {
        let endings = RUSSIAN_CASE_ENDINGS.joined(separator: "|")
        guard let last = escapedWord.last, last == "а" || last == "я" else {
            return escapedWord + "(?:" + endings + ")?"
        }
        return String(escapedWord.dropLast()) + "(?:" + endings + ")"
    }
}

