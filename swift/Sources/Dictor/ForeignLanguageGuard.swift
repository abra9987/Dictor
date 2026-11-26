import Foundation
import NaturalLanguage

// Чужой язык в русской диктовке.
//
// Parakeet в режиме «Авто» сам выбирает язык из 25, и на короткой русской
// фразе иногда выбирает соседний: «ano» вместо «ага», «Хетцнері» с
// украинской «і». FluidAudio умеет только запретить алфавит целиком
// («Кириллица»), а это убивает английские термины, без которых диктовка
// разработчика не обходится. Поэтому алфавит не запрещается, а проверяется
// результат.
//
// Решение принимается по языкам этого Mac, а не по догадке: если среди них
// есть русский и нет латинских славянских, чешский ответ — заведомо
// ослышка, и та же запись распознаётся ещё раз с кириллицей. Чех, у которого
// в системе чешский, ничего этого не заметит.

enum ForeignLanguageGuard {
    struct Policy: Equatable, Sendable {
        /// Ответ целиком латиницей на латинском славянском языке —
        /// распознать ещё раз с кириллицей.
        var retriesLatinSlavic: Bool
        /// Украинские и белорусские буквы в русском тексте — заменить
        /// русскими.
        var foldsNonRussianCyrillic: Bool

        static let off = Policy(retriesLatinSlavic: false, foldsNonRussianCyrillic: false)
    }

    private static let latinSlavicCodes: Set<String> = ["cs", "sk", "pl", "sl", "hr", "bs", "sr"]
    private static let otherCyrillicCodes: Set<String> = ["uk", "be", "bg", "sr", "mk"]

    static func policy(for language: DictationLanguage,
                       preferredLanguages: [String] = Locale.preferredLanguages) -> Policy {
        let codes = Set(preferredLanguages.map {
            String($0.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "")
        })
        guard codes.contains("ru") else { return .off }
        let folds = codes.isDisjoint(with: otherCyrillicCodes)
        switch language {
        case .auto:
            return Policy(retriesLatinSlavic: codes.isDisjoint(with: latinSlavicCodes),
                          foldsNonRussianCyrillic: folds)
        case .russian:
            // Кириллица и так обязательна: повторять нечего.
            return Policy(retriesLatinSlavic: false, foldsNonRussianCyrillic: folds)
        default:
            return .off
        }
    }

    /// Буквы, которых нет ни в английском, ни в русском, а в чешском,
    /// словацком, польском и хорватском есть.
    private static let latinSlavicLetters = Set("čďěňřšťůžąćęłńśźżĺľŕôđ")

    /// Порог уверенности, выше которого не поднялся ни один термин из
    /// проверочного набора (Telegram — 0,45, Ninja — 0,51), а «ano», «Tak jo»
    /// и «Nie wiem» — от 0,78 до 1,0.
    static let slavicConfidenceThreshold = 0.75

    static func containsCyrillic(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    static func needsCyrillicRetry(_ text: String) -> Bool {
        guard !containsCyrillic(text), text.contains(where: \.isLetter) else { return false }
        if text.lowercased().contains(where: { latinSlavicLetters.contains($0) }) { return true }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = [.english, .czech, .slovak, .polish, .croatian]
        recognizer.processString(text)
        guard let (language, confidence) = recognizer.languageHypotheses(withMaximum: 1).first else {
            return false
        }
        return language != .english && confidence >= slavicConfidenceThreshold
    }

    private static let cyrillicFolding: [Character: Character] = [
        "і": "и", "І": "И", "ї": "и", "Ї": "И", "є": "е", "Є": "Е",
        "ґ": "г", "Ґ": "Г", "ў": "у", "Ў": "У",
    ]

    static func foldNonRussianCyrillic(_ text: String) -> String {
        guard text.contains(where: { cyrillicFolding[$0] != nil }) else { return text }
        return String(text.map { cyrillicFolding[$0] ?? $0 })
    }
}

#if DEBUG
extension DictorSelfTest {
    static func testForeignLanguageGuard() throws {
        let russianMac = ForeignLanguageGuard.policy(for: .auto, preferredLanguages: ["ru-RU"])
        try expect(russianMac, equals: .init(retriesLatinSlavic: true, foldsNonRussianCyrillic: true),
                   "a Russian-only Mac in auto mode should guard against Czech and Ukrainian output")
        try expect(ForeignLanguageGuard.policy(for: .auto, preferredLanguages: ["ru-RU", "en-CA"]),
                   equals: russianMac, "English next to Russian keeps the guard on")
        try expect(ForeignLanguageGuard.policy(for: .auto, preferredLanguages: ["cs-CZ", "ru-RU"]),
                   equals: .init(retriesLatinSlavic: false, foldsNonRussianCyrillic: true),
                   "a Mac with Czech must keep Czech output")
        try expect(ForeignLanguageGuard.policy(for: .auto, preferredLanguages: ["uk-UA", "ru-RU"]),
                   equals: .init(retriesLatinSlavic: true, foldsNonRussianCyrillic: false),
                   "a Mac with Ukrainian must keep Ukrainian letters")
        try expect(ForeignLanguageGuard.policy(for: .auto, preferredLanguages: ["en-US"]),
                   equals: .off, "a Mac without Russian is left alone")
        try expect(ForeignLanguageGuard.policy(for: .english, preferredLanguages: ["ru-RU"]),
                   equals: .off, "an explicit Latin choice is left alone")

        for text in ["ano", "Ano.", "Tak jo.", "Nie wiem", "No a co", "Dobře, udělám to.", "Jasně"] {
            try expect(ForeignLanguageGuard.needsCyrillicRetry(text), equals: true,
                       "Latin-script Slavic output should be retried with Cyrillic: \(text)")
        }
        // Термины и английские фразы, которые человек и правда диктует.
        for text in ["Claude Code", "Telegram", "Ninja", "UI", "Hetzner", "Pixel Rig", "MCP server",
                     "Merge", "Cloudflare", "Supabase", "Vercel", "Kokoro", "Facebook Marketplace",
                     "I was literally dead in sight.", "Better tell your sub agent to do that.",
                     "Нажми ano", "Ок", ""] {
            try expect(ForeignLanguageGuard.needsCyrillicRetry(text), equals: false,
                       "terms, English and Cyrillic text must not be retried: \(text)")
        }

        try expect(ForeignLanguageGuard.foldNonRussianCyrillic("Либо на Хетцнері. Її Ґанок"),
                   equals: "Либо на Хетцнери. Ии Ганок",
                   "Ukrainian letters in Russian text should fold to Russian ones")
        try expect(ForeignLanguageGuard.foldNonRussianCyrillic("Обычный текст, Claude Code."),
                   equals: "Обычный текст, Claude Code.", "ordinary text must stay untouched")
    }
}
#endif
