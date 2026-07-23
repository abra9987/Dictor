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

// MARK: - Filler word removal
//
// Deterministic regex pass that strips standalone non-word fillers
// ("um", "uh", "ah", "er", "erm", "hmm") and cleans up the punctuation
// artifacts left behind. Intentionally conservative: skips ambiguous
// fillers ("like", "you know") that have legitimate non-filler uses,
// and only fires when the user explicitly enables it via Settings →
// Remove filler words. Applied *after* TranscriptCorrector so explicit
// user corrections always win over filler stripping.

enum FillerWordRemover {
    private enum CapitalizationRepairTarget: Hashable {
        case start
        case afterSentenceTerminator(Int)
    }

    /// Non-word interjections only. "like" and "you know" are excluded
    /// because they have valid non-filler meanings ("I like cats", "you
    /// know who"). Most entries are regex fragments that allow the
    /// trailing letter to repeat, since real-world fillers stretch out
    /// ("ummm", "uhhhh", "ahhh", "hmmm") and the word-boundary lookahead
    /// would otherwise reject them. "er" and "erm" deliberately have no
    /// repeat quantifier: "er+" would also match the real word "err".
    private static let fillerPatterns = ["um+", "uh+", "ah+", "er", "erm", "hm+"]

    static func apply(to text: String) -> (text: String, removedCount: Int) {
        guard !text.isEmpty else { return (text, 0) }

        // Word-boundary lookarounds include `'` (so "it's" stays one
        // token) and `-` (so "uh-huh", "uh-oh" don't get split apart).
        let alternation = fillerPatterns.joined(separator: "|")
        let pattern = #"(?i)(?<![\p{L}\p{N}'\-])("# + alternation + #")(?![\p{L}\p{N}'\-])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return (text, 0)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else { return (text, 0) }

        // Preserve sentence-start casing when the removed filler carried
        // the capital ("Um, hello." and "First. Um hello.").
        let capitalizationRepairTargets = capitalizationRepairTargets(for: matches,
                                                                      in: text)

        let mutable = NSMutableString(string: text)
        for match in matches.reversed() {
            mutable.replaceCharacters(in: match.range, with: "")
        }
        var result = mutable as String

        // Clean up artifacts left behind by removal:
        //   1. Comma runs left by consecutive fillers: "x, , , y" →
        //      "x, y". Quantified so a run of ANY length collapses in
        //      one pass — a non-overlapping ",\s*," pattern consumed
        //      pairs and left ",," behind for two-plus fillers.
        //   2. Whitespace before punctuation: "x ." → "x."
        //   3. Orphan comma glued onto terminal punctuation by pass 2:
        //      "x,." → "x." ("That's all, um." must not end ",.")
        //   4. Multiple consecutive spaces → single space
        //   5. Leading punctuation / whitespace, including "?" and "!"
        //      so a removed sentence-initial filler takes its terminal
        //      punctuation with it ("Um? What?" → "What?")
        //   6. Orphan punctuation after an existing sentence terminator:
        //      "x. , y" → "x. y" when removing "Um," after the period.
        //   7. Trailing whitespace
        result = result.replacingOccurrences(of: #"\s*,(?:\s*,)+"#, with: ",", options: .regularExpression)
        result = result.replacingOccurrences(of: #"([.!?])\s+[,.;:!?]+\s*"#, with: "$1 ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+([.,!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #",+([.!?;:])"#, with: "$1", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"^[\s,.;:!?]+"#, with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        result = restoringCapitalization(in: result,
                                         targets: capitalizationRepairTargets)

        return (result, matches.count)
    }

    private static func capitalizationRepairTargets(for matches: [NSTextCheckingResult],
                                                     in text: String) -> Set<CapitalizationRepairTarget> {
        Set(matches.compactMap { match in
            guard let range = Range(match.range, in: text),
                  text[range].first?.isUppercase == true else {
                return nil
            }
            return capitalizationRepairTarget(for: range, in: text)
        })
    }

    private static func capitalizationRepairTarget(for range: Range<String.Index>,
                                                   in text: String) -> CapitalizationRepairTarget? {
        var index = range.lowerBound
        while index > text.startIndex {
            let previous = text.index(before: index)
            let character = text[previous]
            if character.isWhitespace || isBoundaryWrapper(character) {
                index = previous
                continue
            }
            guard isSentenceTerminator(character) else { return nil }
            return .afterSentenceTerminator(sentenceTerminatorOrdinal(at: previous,
                                                                      in: text))
        }
        return .start
    }

    private static func sentenceTerminatorOrdinal(at target: String.Index,
                                                  in text: String) -> Int {
        var ordinal = 0
        var index = text.startIndex
        while index <= target {
            if isSentenceTerminator(text[index]) {
                ordinal += 1
            }
            index = text.index(after: index)
        }
        return ordinal
    }

    private static func restoringCapitalization(in text: String,
                                                targets: Set<CapitalizationRepairTarget>) -> String {
        guard !targets.isEmpty, !text.isEmpty else { return text }

        let sentenceTargets = Set(targets.compactMap { target -> Int? in
            guard case .afterSentenceTerminator(let ordinal) = target else { return nil }
            return ordinal
        })
        var result = ""
        result.reserveCapacity(text.count)
        var sentenceTerminatorOrdinal = 0
        var shouldCapitalizeNextWord = targets.contains(.start)

        for character in text {
            if shouldCapitalizeNextWord {
                if character.isLowercase {
                    result += character.uppercased()
                    shouldCapitalizeNextWord = false
                    continue
                }
                if character.isLetter || character.isNumber {
                    shouldCapitalizeNextWord = false
                }
            }

            result.append(character)

            if isSentenceTerminator(character) {
                sentenceTerminatorOrdinal += 1
                if sentenceTargets.contains(sentenceTerminatorOrdinal) {
                    shouldCapitalizeNextWord = true
                }
            } else if shouldCapitalizeNextWord,
                      !character.isWhitespace,
                      !isBoundaryWrapper(character),
                      !isOrphanSeparator(character) {
                shouldCapitalizeNextWord = false
            }
        }

        return result
    }

    private static func isSentenceTerminator(_ character: Character) -> Bool {
        character == "." || character == "!" || character == "?"
    }

    private static func isBoundaryWrapper(_ character: Character) -> Bool {
        "\"'“”‘’([{".contains(character)
    }

    private static func isOrphanSeparator(_ character: Character) -> Bool {
        ",.;:!?".contains(character)
    }
}

