import AppKit
import Foundation

// MARK: - Созвучные названия
//
// Модель слышит английское название в русской речи и записывает его
// кириллицей — каждый раз по-своему. LinkedIn в одной и той же истории диктовок
// встречается как «линктын», «линклине», «линктыде», «линктрина», «лингтына»
// и «линкит ин»; Hetzner — как «хэтснере», «хетснаре» и «хэтценре». Разница
// между вариантами не в пробелах, а в самих буквах, поэтому точное совпадение
// их не ловит, а заводить в словаре запись на каждый бессмысленно: следующий
// вариант будет новым.
//
// Здесь запись словаря сравнивается с услышанным не по буквам, а по звучанию.
// Человек заводит название один раз, варианты подтягиваются сами.
//
// Правило намеренно узкое, и держится оно на трёх ограничениях:
//
//   1. Сравнивается только то, что не является русским словом. «Тикер» звучит
//      как «докер», но это слово русского языка — и трогать его нельзя. Что
//      считать словом, решает системный словарь macOS; нет словаря — нет и
//      сопоставления.
//   2. Сравнивается только с записями, которые меняют алфавит: слева кириллица
//      не короче пяти букв, справа — ни одной кириллической буквы. Это те же
//      записи, которым разрешены падежи и разрыв.
//   3. Близость считается по согласным. Гласные модель путает свободно
//      («гетхаб», «гитхаб»), согласные — почти только по звонкости
//      («тазбар», «таскбар»). Чем короче согласный каркас, тем строже
//      требование: у каркаса из трёх согласных совпасть обязаны и гласные.
//
// Чего здесь нет: догадок о слове, которого в словаре нет. «Солюш» может быть
// «solution», а может и не быть — без записи сопоставлять не с чем.

/// Обычное ли это русское слово. Отдельный протокол — чтобы самотесты
/// проверяли правило на своём списке слов и не зависели от версии системы.
protocol RussianLexicon {
    func isWord(_ word: String) -> Bool
}

/// Системный словарь macOS. Работает на устройстве, знает словоформы и слова,
/// которые человек сам добавил в систему.
///
/// `NSSpellChecker` — класс AppKit и вызывается с главного потока. Ответы
/// кешируются: одна проверка стоит около 0,2 мс, а слова в диктовках
/// повторяются.
final class SystemRussianLexicon: RussianLexicon, @unchecked Sendable {
    /// `nil`, если русского словаря в системе нет: сопоставление тогда
    /// выключено целиком, а не работает без защиты.
    static let shared: SystemRussianLexicon? = {
        let make = { () -> SystemRussianLexicon? in
            let languages = NSSpellChecker.shared.availableLanguages
            guard let language = languages.first(where: { $0 == "ru" })
                    ?? languages.first(where: { $0.hasPrefix("ru") }) else {
                log("phonetic matching: no Russian system dictionary, matching is off")
                return nil
            }
            return SystemRussianLexicon(language: language)
        }
        return Thread.isMainThread ? make() : DispatchQueue.main.sync(execute: make)
    }()

    private static let cacheLimit = 20_000

    private let language: String
    private var cache: [String: Bool] = [:]

    private init(language: String) {
        self.language = language
    }

    func isWord(_ word: String) -> Bool {
        if Thread.isMainThread { return isWordOnMain(word) }
        return DispatchQueue.main.sync { isWordOnMain(word) }
    }

    private func isWordOnMain(_ word: String) -> Bool {
        if let known = cache[word] { return known }
        let misspelled = NSSpellChecker.shared.checkSpelling(of: word,
                                                             startingAt: 0,
                                                             language: language,
                                                             wrap: false,
                                                             inSpellDocumentWithTag: 0,
                                                             wordCount: nil)
        let isWord = misspelled.location == NSNotFound
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[word] = isWord
        return isWord
    }
}

enum PhoneticTermMatcher {
    struct Match: Equatable {
        let range: NSRange
        let replacement: String
    }

    /// Запись словаря в том виде, в каком с ней сравнивают услышанное.
    struct Key {
        let replacement: String
        let skeleton: [Character]
        let vowelForm: [Character]
    }

    // MARK: Звучание

    private static let vowels: Set<Character> = ["а", "е", "ё", "и", "о", "у", "ы", "э", "ю", "я"]

    /// Звонкий согласный записан как его глухая пара: на слух их модель и
    /// путает («тазбар» вместо «таскбар»). «Ц» сведена к «с»: «хецнер» и
    /// «хэтснер» — одно название.
    private static let consonantClass: [Character: Character] = [
        "б": "п", "в": "ф", "г": "к", "д": "т", "ж": "ш", "з": "с", "щ": "ш", "ц": "с",
    ]

    /// Гласные собраны в три класса. Внутри класса модель выбирает свободно:
    /// безударные «а» и «о» на слух неразличимы, «и», «е», «э», «ы» в чужом
    /// слове — дело случая.
    private static let vowelClass: [Character: Character] = [
        "а": "а", "о": "а", "я": "а", "ё": "а",
        "у": "у", "ю": "у",
        "и": "и", "ы": "и", "е": "и", "э": "и", "й": "и",
    ]

    private static func letters(_ text: String) -> [Character] {
        text.lowercased().filter { ("а"..."я").contains($0) || $0 == "ё" }
    }

    private static func collapsed(_ characters: [Character]) -> [Character] {
        var result: [Character] = []
        result.reserveCapacity(characters.count)
        for character in characters where result.last != character {
            result.append(character)
        }
        return result
    }

    /// Согласный каркас: гласные, «й» и знаки выброшены, звонкость снята,
    /// удвоения схлопнуты. «Линктын», «лингтына» и «линкедин» дают «лнктн».
    static func skeleton(_ text: String) -> [Character] {
        collapsed(letters(text).compactMap { letter -> Character? in
            if vowels.contains(letter) || letter == "й" || letter == "ь" || letter == "ъ" {
                return nil
            }
            return consonantClass[letter] ?? letter
        })
    }

    /// То же слово с гласными, сведёнными к классам: по нему отличают
    /// действительно близкое написание от совпавшего каркаса.
    static func vowelForm(_ text: String) -> [Character] {
        collapsed(letters(text).compactMap { letter -> Character? in
            if letter == "ь" || letter == "ъ" { return nil }
            return vowelClass[letter] ?? consonantClass[letter] ?? letter
        })
    }

    static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            current.reserveCapacity(rhs.count + 1)
            for (j, right) in rhs.enumerated() {
                current.append(min(previous[j + 1] + 1,
                                   current[j] + 1,
                                   previous[j] + (left == right ? 0 : 1)))
            }
            previous = current
        }
        return previous[rhs.count]
    }

    // MARK: Ключи

    /// Сопоставлять можно только с записью, которая меняет алфавит, — та же
    /// граница, что у падежей и разрыва. Название на -а/-я даёт и ключ без
    /// последней буквы: «в асане» — это «асан» плюс окончание.
    static func keys(for corrections: [TranscriptCorrection]) -> [Key] {
        var result: [Key] = []
        for correction in corrections
        where TranscriptCorrector.russianInflectionAllowed(for: correction) {
            let joined = String(letters(correction.source))
            var forms = [joined]
            if let last = joined.last, last == "а" || last == "я" {
                forms.append(String(joined.dropLast()))
            }
            for form in forms {
                let formSkeleton = skeleton(form)
                guard !formSkeleton.isEmpty else { continue }
                result.append(Key(replacement: correction.replacement,
                                  skeleton: formSkeleton,
                                  vowelForm: vowelForm(form)))
            }
        }
        return result
    }

    // MARK: Решение

    /// Пороги подобраны на истории из 1118 диктовок: 122 срабатывания, каждое
    /// просмотрено с контекстом. Менять их — значит повторить этот просмотр.
    private static let minimumVowelSimilarityShortSkeleton = 0.70   // каркас из четырёх согласных
    private static let minimumVowelSimilarity = 0.60                // каркас длиннее
    private static let minimumVowelSimilarityOneOff = 0.72          // каркас отличается одной согласной
    private static let minimumSkeletonForOneOff = 5

    /// Уровень уверенности. Чем выше, тем меньше правило домысливает.
    private enum Tier: Double {
        /// Каркас отличается одной согласной: «тазбар» и «таскбар».
        case oneConsonantOff = 0
        /// Каркас совпал, гласные близки: «линктын» и «линкедин».
        case sameSkeleton = 0.3
        /// Аббревиатура без единой гласной: «мцп» и «эмсипи».
        case abbreviation = 0.5
        /// Совпало всё с точностью до класса гласных: «гетхаб» и «гитхаб».
        case sameSound = 1
    }

    /// Лучшая запись для услышанного и её оценка — или `nil`, если ничто не
    /// подошло. Окончание из закрытого списка снимается перед сравнением: «на
    /// хетснаре» — это «хетснар» плюс падеж.
    static func bestKey(for heard: String, keys: [Key]) -> (replacement: String, score: Double)? {
        let heardLetters = letters(heard)
        guard heardLetters.count >= 3 else { return nil }
        let hasVowel = heardLetters.contains(where: vowels.contains)

        var forms: [(text: String, strippedEnding: Bool)] = [(String(heardLetters), false)]
        for ending in TranscriptCorrector.RUSSIAN_CASE_ENDINGS {
            let endingLetters = Array(ending)
            guard heardLetters.count - endingLetters.count >= 3,
                  heardLetters.suffix(endingLetters.count).elementsEqual(endingLetters) else {
                continue
            }
            forms.append((String(heardLetters.dropLast(endingLetters.count)), true))
        }

        var best: (replacement: String, score: Double)?
        for form in forms {
            let heardSkeleton = skeleton(form.text)
            let heardVowelForm = vowelForm(form.text)
            guard !heardSkeleton.isEmpty else { continue }

            for key in keys {
                let tier: Tier
                let similarity: Double
                if heardVowelForm == key.vowelForm {
                    tier = .sameSound
                    similarity = 1
                } else {
                    // Первый согласный модель не теряет и не подменяет: без
                    // этой проверки короткий каркас цепляется за что попало.
                    guard heardSkeleton.first == key.skeleton.first else { continue }
                    let skeletonDistance = editDistance(heardSkeleton, key.skeleton)
                    let longest = max(heardVowelForm.count, key.vowelForm.count)
                    similarity = 1 - Double(editDistance(heardVowelForm, key.vowelForm)) / Double(longest)

                    if skeletonDistance == 0 {
                        if !hasVowel, key.skeleton.count >= 3, !form.strippedEnding {
                            tier = .abbreviation
                        } else if key.skeleton.count >= 5, similarity >= minimumVowelSimilarity {
                            tier = .sameSkeleton
                        } else if key.skeleton.count == 4,
                                  similarity >= minimumVowelSimilarityShortSkeleton {
                            tier = .sameSkeleton
                        } else {
                            continue
                        }
                    } else if skeletonDistance == 1,
                              key.skeleton.count >= minimumSkeletonForOneOff,
                              similarity >= minimumVowelSimilarityOneOff {
                        tier = .oneConsonantOff
                    } else {
                        continue
                    }
                }

                let score = similarity + tier.rawValue
                if let current = best, current.score >= score { continue }
                best = (key.replacement, score)
            }
        }
        return best
    }

    // MARK: Поиск в тексте

    private static let wordPattern = try! NSRegularExpression(pattern: "[А-Яа-яЁё]+")

    /// Названия в тексте, записанные по звучанию.
    ///
    /// Услышанное может быть разорвано на два-три слова («гет хаб», «линкит
    /// ин», «эйч тимель»), поэтому сравниваются и одиночные слова, и короткие
    /// цепочки через пробел или дефис. Из цепочек, начинающихся в одном месте,
    /// берётся та, что подошла лучше, — иначе к названию прилипает соседнее
    /// слово.
    ///
    /// `occupied` — участки, уже занятые точными совпадениями: их правило не
    /// трогает.
    static func matches(in text: String,
                        corrections: [TranscriptCorrection],
                        occupied: [NSRange],
                        lexicon: RussianLexicon) -> [Match] {
        let keys = keys(for: corrections)
        guard !keys.isEmpty, !text.isEmpty else { return [] }

        let source = text as NSString
        let words = wordPattern.matches(in: text, range: NSRange(location: 0, length: source.length))
            .map(\.range)
        guard !words.isEmpty else { return [] }

        func isFree(_ range: NSRange) -> Bool {
            !occupied.contains { NSIntersectionRange($0, range).length > 0 }
        }

        /// Имя собственное модель пишет с заглавной, и словарь знает его
        /// только в таком виде: «Андрей» — слово, «андрей» — нет. Поэтому
        /// написанное с заглавной проверяется как написано, а строчное — как
        /// строчное: «клауд» посреди фразы именем не считается.
        func isOrdinaryWord(_ word: String) -> Bool {
            let lowered = word.lowercased()
            if lexicon.isWord(lowered) { return true }
            guard let first = word.first, first.isUppercase else { return false }
            return lexicon.isWord(first.uppercased() + lowered.dropFirst())
        }

        var result: [Match] = []
        var index = 0
        while index < words.count {
            var best: (match: Match, score: Double, lastIndex: Int)?

            for length in 1...3 {
                let lastIndex = index + length - 1
                guard lastIndex < words.count else { break }
                let pieces = (index...lastIndex).map { source.substring(with: words[$0]) }
                let range = NSUnionRange(words[index], words[lastIndex])
                guard isFree(range) else { break }

                if length > 1 {
                    // Между словами цепочки — ровно один разрыв, без знаков
                    // препинания: запятая означает, что это разные слова.
                    let previousEnd = NSMaxRange(words[lastIndex - 1])
                    let gap = source.substring(with: NSRange(location: previousEnd,
                                                             length: words[lastIndex].location - previousEnd))
                    guard gap.count == 1, let separator = gap.first,
                          TranscriptCorrector.SPLIT_SEPARATORS.contains(separator) else { break }
                    // Те же два правила, что у разрыва: кусок не короче двух
                    // букв и ни один кусок не служебное слово.
                    guard pieces.allSatisfy({ piece in
                        piece.count >= 2
                            && !TranscriptCorrector.RUSSIAN_SPLIT_BLOCKERS.contains(piece.lowercased())
                    }) else { continue }
                }

                // Цепочка целиком из русских слов — это фраза, а не название.
                guard !pieces.allSatisfy(isOrdinaryWord) else { continue }
                guard let found = bestKey(for: pieces.joined(), keys: keys) else { continue }
                if let current = best, current.score >= found.score { continue }
                best = (Match(range: range, replacement: found.replacement), found.score, lastIndex)
            }

            if let best {
                result.append(best.match)
                index = best.lastIndex + 1
            } else {
                index += 1
            }
        }
        return result
    }
}
