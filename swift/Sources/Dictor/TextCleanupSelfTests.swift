// Самотесты правки текста после распознавания: слова-паразиты, встроенные
// написания, латинские термины и цена словаря (corrections-cost, вне all).

import Foundation

#if DEBUG
extension DictorSelfTest {
    static func testFillerWordRemoval() throws {
        // Mid-sentence filler with surrounding commas → orphan comma
        // gets collapsed.
        let mid = FillerWordRemover.apply(to: "So, um, I was going.")
        try expect(mid.text, equals: "So, I was going.", "mid-sentence filler should leave a single comma")
        try expect(mid.removedCount, equals: 1, "mid-sentence filler removal count")

        // Sentence-initial filler with leading-comma cleanup AND
        // capitalisation restored (the original 'U' was uppercase).
        let initial = FillerWordRemover.apply(to: "Um, hello.")
        try expect(initial.text, equals: "Hello.", "sentence-initial filler should re-capitalise the next word")
        try expect(initial.removedCount, equals: 1, "sentence-initial filler removal count")

        let secondSentence = FillerWordRemover.apply(to: "This is the first sentence. Um this is the second sentence.")
        try expect(
            secondSentence.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should re-capitalise the next word"
        )
        try expect(secondSentence.removedCount, equals: 1, "second-sentence filler removal count")

        let secondSentenceWithComma = FillerWordRemover.apply(to: "This is the first sentence. Um, this is the second sentence.")
        try expect(
            secondSentenceWithComma.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler after a period should not leave an orphan comma"
        )
        try expect(secondSentenceWithComma.removedCount, equals: 1, "second-sentence comma filler removal count")

        let secondSentenceQuestion = FillerWordRemover.apply(to: "This is the first sentence. Um? this is the second sentence.")
        try expect(
            secondSentenceQuestion.text,
            equals: "This is the first sentence. This is the second sentence.",
            "sentence-initial filler with its own punctuation should take that punctuation with it"
        )
        try expect(secondSentenceQuestion.removedCount, equals: 1, "second-sentence question filler removal count")

        let capitalizedMidSentence = FillerWordRemover.apply(to: "This is not a sentence boundary Um this stays lowercase.")
        try expect(
            capitalizedMidSentence.text,
            equals: "This is not a sentence boundary this stays lowercase.",
            "capitalized fillers away from sentence starts should not force capitalization"
        )
        try expect(capitalizedMidSentence.removedCount, equals: 1, "capitalized mid-sentence filler removal count")

        // Bare filler with adjacent punctuation collapses to empty.
        let bare = FillerWordRemover.apply(to: "Um.")
        try expect(bare.text, equals: "", "bare filler with trailing punctuation should leave empty string")
        try expect(bare.removedCount, equals: 1, "bare filler removal count")

        // Filler with no surrounding punctuation just leaves a space
        // that gets collapsed away.
        let inline = FillerWordRemover.apply(to: "I'm uh going to the store.")
        try expect(inline.text, equals: "I'm going to the store.", "inline filler should collapse the leftover whitespace")
        try expect(inline.removedCount, equals: 1, "inline filler removal count")

        // Compound interjection "uh-huh" must NOT match — the hyphen is
        // part of the boundary class.
        let uhHuh = FillerWordRemover.apply(to: "Yeah, uh-huh.")
        try expect(uhHuh.text, equals: "Yeah, uh-huh.", "uh-huh must not be stripped")
        try expect(uhHuh.removedCount, equals: 0, "uh-huh removal count")

        // Words that *contain* a filler substring must not match. "her"
        // contains "er", "sum" contains "um", "exercise" contains "er".
        let contains = FillerWordRemover.apply(to: "Her sum exercise is harder.")
        try expect(contains.text, equals: "Her sum exercise is harder.", "filler substrings inside larger words must be preserved")
        try expect(contains.removedCount, equals: 0, "no removals when fillers are embedded in real words")

        // Multiple fillers in one utterance all get stripped.
        let multi = FillerWordRemover.apply(to: "Um, ah, I uh think so.")
        try expect(multi.text, equals: "I think so.", "multiple fillers should all be removed and artifacts cleaned up")
        try expect(multi.removedCount, equals: 3, "multi-filler removal count")

        // Empty input should be a no-op.
        let empty = FillerWordRemover.apply(to: "")
        try expect(empty.text, equals: "", "empty input passes through unchanged")
        try expect(empty.removedCount, equals: 0, "empty input has zero removals")

        // No fillers present → identical text, zero removals.
        let clean = FillerWordRemover.apply(to: "Hello world.")
        try expect(clean.text, equals: "Hello world.", "filler-free input passes through unchanged")
        try expect(clean.removedCount, equals: 0, "filler-free input has zero removals")

        // Elongated fillers — common in real dictation. The word-
        // boundary lookahead would have rejected these without the
        // per-pattern trailing-repeat allowance.
        let elongatedUm = FillerWordRemover.apply(to: "Ummm, hello.")
        try expect(elongatedUm.text, equals: "Hello.", "ummm should be stripped like um")
        try expect(elongatedUm.removedCount, equals: 1, "elongated um removal count")

        let elongatedUh = FillerWordRemover.apply(to: "Uhhh I think so.")
        try expect(elongatedUh.text, equals: "I think so.", "uhhh should be stripped like uh")
        try expect(elongatedUh.removedCount, equals: 1, "elongated uh removal count")

        let elongatedAh = FillerWordRemover.apply(to: "Ahhh, that makes sense.")
        try expect(elongatedAh.text, equals: "That makes sense.", "ahhh should be stripped like ah")
        try expect(elongatedAh.removedCount, equals: 1, "elongated ah removal count")

        // `hm+` covers both "hm" (single m) and "hmmm" (extended). The
        // earlier fixed-list "hmm" entry rejected the single-m form.
        let shortHm = FillerWordRemover.apply(to: "Hm, interesting.")
        try expect(shortHm.text, equals: "Interesting.", "short hm should be stripped like hmm")
        try expect(shortHm.removedCount, equals: 1, "short hm removal count")

        // Words containing the new repeat-friendly patterns must still
        // pass through. "ohm" embeds "hm" but has a leading letter.
        let embedded = FillerWordRemover.apply(to: "An ohm is a unit.")
        try expect(embedded.text, equals: "An ohm is a unit.", "ohm must not match hm")
        try expect(embedded.removedCount, equals: 0, "ohm should produce zero removals")

        // Two consecutive fillers used to leave ",," because the
        // comma-collapse pass was single-pass/non-overlapping: it
        // consumed one ", ," pair and the whitespace-before-punctuation
        // pass then glued the leftover " ," into ",,".
        let consecutive = FillerWordRemover.apply(to: "So, um, uh, yes.")
        try expect(consecutive.text, equals: "So, yes.", "consecutive fillers should collapse to a single comma")
        try expect(consecutive.removedCount, equals: 2, "consecutive filler removal count")

        // Three consecutive fillers exercise runs longer than one
        // collapse step.
        let tripleRun = FillerWordRemover.apply(to: "He said, um, uh, er, no.")
        try expect(tripleRun.text, equals: "He said, no.", "a run of three fillers should collapse to a single comma")
        try expect(tripleRun.removedCount, equals: 3, "triple filler removal count")

        // Consecutive fillers mid-sentence keep exactly one comma,
        // matching the single-filler behavior above.
        let midRun = FillerWordRemover.apply(to: "I think, um, uh, we should go.")
        try expect(midRun.text, equals: "I think, we should go.", "mid-sentence consecutive fillers should keep one comma")
        try expect(midRun.removedCount, equals: 2, "mid-sentence consecutive filler removal count")

        // Trailing filler before terminal punctuation used to leave
        // ",." because no pass cleaned a comma glued onto a period.
        let trailing = FillerWordRemover.apply(to: "That's all, um.")
        try expect(trailing.text, equals: "That's all.", "trailing filler should not leave a comma before the period")
        try expect(trailing.removedCount, equals: 1, "trailing filler removal count")

        let beforeQuestion = FillerWordRemover.apply(to: "Is that right, um?")
        try expect(beforeQuestion.text, equals: "Is that right?", "filler before a question mark should not leave a comma")
        try expect(beforeQuestion.removedCount, equals: 1, "filler before question mark removal count")

        let beforeBang = FillerWordRemover.apply(to: "Stop, um!")
        try expect(beforeBang.text, equals: "Stop!", "filler before an exclamation mark should not leave a comma")
        try expect(beforeBang.removedCount, equals: 1, "filler before exclamation mark removal count")

        // Sentence-initial filler with its own terminal punctuation:
        // the leading-strip class must include "?" and "!" or the
        // orphaned punctuation survives ("Um? What?" → "? What?").
        let leadingQuestion = FillerWordRemover.apply(to: "Um? What?")
        try expect(leadingQuestion.text, equals: "What?", "leading filler question should take its punctuation with it")
        try expect(leadingQuestion.removedCount, equals: 1, "leading filler question removal count")

        let leadingBang = FillerWordRemover.apply(to: "Ah! Careful.")
        try expect(leadingBang.text, equals: "Careful.", "leading filler exclamation should take its punctuation with it")
        try expect(leadingBang.removedCount, equals: 1, "leading filler exclamation removal count")
    }

    /// Встроенный набор написаний. Проверяем не «список не пуст», а то,
    /// чего от него ждут: имена приходят в канонический вид, слово человека
    /// сильнее встроенного, и ничего не меняется внутри других слов.
    static func testBuiltInSpellings() throws {
        func run(_ text: String,
                 user: [TranscriptCorrection] = [],
                 enabled: Bool = true) -> String {
            TranscriptCorrector.apply(
                to: text,
                corrections: dictationCorrections(user: user,
                                                  includeBuiltInSpellings: enabled,
                                                  includeLatinTermRestorations: false)).text
        }

        // Ровно те промахи, что нашлись в живом архиве диктовок.
        try expect(run("поставил postgres и msql"), equals: "поставил PostgreSQL и MySQL",
                   "database names should come out spelled the way they are written")
        try expect(run("выгрузил в csv через api"), equals: "выгрузил в CSV через API",
                   "abbreviations dictated in lower case should come out upper case")
        try expect(run("собрал на macos в xcode"), equals: "собрал на macOS в Xcode",
                   "Apple names have their own casing and it is not sentence case")

        // Слово человека сильнее встроенного: иначе поправить набор нечем.
        let mine = [TranscriptCorrection(source: "postgres", replacement: "Постгрес")]
        try expect(run("поставил postgres", user: mine), equals: "поставил Постгрес",
                   "a manual entry must win over the built-in spelling")

        // Выключенный набор молчит.
        try expect(run("поставил postgres", enabled: false), equals: "поставил postgres",
                   "with the set off nothing should be rewritten")

        // Границы слова: «api» внутри слова — не аббревиатура.
        try expect(run("это рапира и api"), equals: "это рапира и API",
                   "a match inside another word must not be replaced")

        // Уже написанное правильно не считается правкой — иначе счётчик
        // сообщал бы о работе, которой не было.
        try expect(TranscriptCorrector.apply(
                    to: "открыл GitHub",
                    corrections: dictationCorrections(user: [],
                                                      includeBuiltInSpellings: true,
                                                      includeLatinTermRestorations: false)).appliedCount,
                   equals: 0,
                   "text already spelled correctly must not count as a correction")

        // Набор не съедает пользовательский предел: слова человека остаются
        // все до единого.
        let many = (0..<MAX_TRANSCRIPT_CORRECTIONS).map {
            TranscriptCorrection(source: "слово\($0)", replacement: "Слово\($0)")
        }
        let merged = dictationCorrections(user: many, includeBuiltInSpellings: true,
                                        includeLatinTermRestorations: false)
        try expect(merged.count, equals: MAX_TRANSCRIPT_CORRECTIONS + BuiltInSpellings.count,
                   "the built-in set must not push out the user's own words")

        // В наборе нет замен «кириллица → латиница»: «код» и «баг» — русские
        // слова, а не ошибки распознавания.
        let cyrillic = BuiltInSpellings.all.filter {
            $0.source.unicodeScalars.contains { scalar in
                (0x0400...0x04FF).contains(Int(scalar.value))
            }
        }
        try expect(cyrillic.isEmpty, equals: true,
                   "the set rewrites spelling, not language: \(cyrillic.map(\.source))")
    }

    /// Названия, услышанные по-русски. Этот набор меняет алфавит, а не форму
    /// записи, поэтому проверять надо не пользу, а безопасность: каждое
    /// правило отбора из `LatinTermRestorations` здесь отдельным тестом, и
    /// половина проверок сторожит не то, что набор делает, а то, чего он
    /// делать не должен.
    static func testLatinTermRestorations() throws {
        func run(_ text: String,
                 user: [TranscriptCorrection] = [],
                 enabled: Bool = true) -> String {
            TranscriptCorrector.apply(
                to: text,
                corrections: dictationCorrections(user: user,
                                                  includeBuiltInSpellings: true,
                                                  includeLatinTermRestorations: enabled)).text
        }

        func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
            (0x0400...0x04FF).contains(Int(scalar.value))
        }

        // Правило 1: слева кириллица, справа — ни одной кириллической буквы.
        // Набор существует ровно ради перехода между алфавитами; правка
        // формы записи — дело `BuiltInSpellings`.
        for entry in LatinTermRestorations.all {
            try expect(entry.source.unicodeScalars.allSatisfy(isCyrillic), equals: true,
                       "source must be plain Cyrillic: \(entry.source)")
            try expect(entry.replacement.unicodeScalars.contains(where: isCyrillic),
                       equals: false,
                       "replacement must not fall back into Cyrillic: \(entry.replacement)")
        }

        // Правило 3: не короче пяти букв. Короткое слово рано или поздно
        // столкнётся с обычным русским — «зум», «нода», «гугл» уже столкнулись.
        let short = LatinTermRestorations.all.filter { $0.source.count < 5 }
        try expect(short.isEmpty, equals: true,
                   "short sources collide with ordinary speech: \(short.map(\.source))")

        let sources = LatinTermRestorations.all.map {
            normalizedTranscriptCorrectionSource($0.source)
        }

        // Дубль источника — это молчаливая неопределённость, какая из двух
        // записей победит.
        try expect(Set(sources).count, equals: sources.count,
                   "the set must not carry two entries for one source")

        // Правило 2 и главная проверка безопасности: русское слово в наборе
        // портит текст, а не чинит его.
        let forbidden = sources.filter { RUSSIAN_WORDS_NEVER_RESTORED.contains($0) }
        try expect(forbidden.isEmpty, equals: true,
                   "these are Russian words, not misheard names: \(forbidden)")

        // Наборы не спорят между собой: у написаний источник латиницей, у
        // восстановлений — кириллицей, пересечься им негде.
        let spelled = Set(BuiltInSpellings.all.map {
            normalizedTranscriptCorrectionSource($0.source)
        })
        let overlap = sources.filter { spelled.contains($0) }
        try expect(overlap.isEmpty, equals: true,
                   "a source claimed by both sets: \(overlap)")

        // То, ради чего всё затевалось.
        try expect(run("запушил в гитхаб и починил постгрес"),
                   equals: "запушил в GitHub и починил PostgreSQL",
                   "names heard in Russian should go back to their own spelling")

        // Русские слова остаются русскими. Первые три — из блок-листа,
        // остальные — те, что однажды в наборе полежали.
        try expect(run("это баг в коде"), equals: "это баг в коде",
                   "ordinary Russian words must survive untouched")
        try expect(run("сервер лёг перед дедлайном"), equals: "сервер лёг перед дедлайном",
                   "ordinary Russian words must survive untouched")
        try expect(run("скала над рекой"), equals: "скала над рекой",
                   "a rock is a rock, not a programming language")
        try expect(run("купил редис"), equals: "купил редис",
                   "a radish is a radish, not a key-value store")
        try expect(run("сделай зум и посмотри на юпитер"),
                   equals: "сделай зум и посмотри на юпитер",
                   "zoom and Jupiter belong to ordinary speech")

        // Падежи: русское окончание проглатывается, но не сохраняется.
        try expect(run("лежит в гитхабе"), equals: "лежит в GitHub",
                   "a Russian case ending must not hide the name behind it")
        try expect(run("работаю с докером"), equals: "работаю с Docker",
                   "a Russian case ending must not hide the name behind it")
        try expect(run("задачу в джире закрыл"), equals: "задачу в Jira закрыл",
                   "a name ending in -а keeps its stem, so «в джире» is the same name")
        try expect(run("поднял кубернетес"), equals: "поднял Kubernetes",
                   "the plain form must keep working")

        // И ровно то, чего окончания не дают: суффиксы словообразования.
        // Список закрыт, поэтому «гитхабный» — не форма названия, а другое
        // слово, и трогать его нельзя.
        try expect(run("гитхабный пайплайн"), equals: "гитхабный пайплайн",
                   "a derived word is not a case form")
        try expect(run("докерище какое-то"), equals: "докерище какое-то",
                   "a derived word is not a case form")

        // Разрыв внутри названия. Модель слышит незнакомое имя верно, а границу
        // слова ставит где придётся: одна и та же запись словаря обязана
        // покрывать все варианты, иначе человек заводит их по одному.
        try expect(run("спросил у антро пик"), equals: "спросил у Anthropic",
                   "a name split by the model is still the same name")
        try expect(run("спросил у ан тропик"), equals: "спросил у Anthropic",
                   "the split may fall anywhere inside the name")
        try expect(run("лежит в гит хабе"), equals: "лежит в GitHub",
                   "a split name keeps swallowing its case ending")
        try expect(run("открыл чат-джипити"), equals: "открыл ChatGPT",
                   "a hyphen is the same kind of break as a space")
        try expect(run("Антро Пик выпустил модель"), equals: "Anthropic выпустил модель",
                   "capitalised halves are still the split name")
        let mineSplit = [TranscriptCorrection(source: "хетцнер", replacement: "Hetzner")]
        try expect(run("сервер на хет цнере", user: mineSplit), equals: "сервер на Hetzner",
                   "a manual entry gets split tolerance on the same terms as the built-in set")

        // И то, чего разрыв давать не должен: обычная фраза, которая случайно
        // складывается в название. Каждая строка — реальное столкновение,
        // найденное перебором всех разрывов набора.
        try expect(run("эта графа не заполнена"), equals: "эта графа не заполнена",
                   "«графа не» is a phrase, not Grafana")
        try expect(run("эта графа нами заполнена"), equals: "эта графа нами заполнена",
                   "«графа нами» is a phrase, not Grafana")
        try expect(run("дайте нам пай"), equals: "дайте нам пай",
                   "«нам пай» is a phrase, not NumPy")
        try expect(run("но ушен он рано"), equals: "но ушен он рано",
                   "a function word is never half of a name")
        try expect(run("призывал к у бунту"), equals: "призывал к у бунту",
                   "a one-letter piece is never half of a name")
        try expect(run("антропик, а потом"), equals: "Anthropic, а потом",
                   "punctuation is not a break inside a name")
        try expect(run("макбук"), equals: "MacBook", "the unsplit form must keep working")

        // Запись из нескольких слов разрывов не получает: в ней пробел уже
        // несёт смысл, и «клауд код» не должен находиться в «кла удкод».
        let twoWords = [TranscriptCorrection(source: "клауд код", replacement: "Claude Code")]
        try expect(run("запустил клауд код", user: twoWords), equals: "запустил Claude Code",
                   "a multi-word entry keeps matching as written")
        try expect(run("запустил кла удкод", user: twoWords), equals: "запустил кла удкод",
                   "a multi-word entry must not be re-split")

        // Правило разрыва закрыто так же, как окончания: ни один кусок короче
        // двух букв и ни одно служебное слово.
        try expect(TranscriptCorrector.splitMatchAllowed("антро пик"), equals: true,
                   "two content halves form a split name")
        try expect(TranscriptCorrector.splitMatchAllowed("графа на"), equals: false,
                   "a function word blocks the split")
        try expect(TranscriptCorrector.splitMatchAllowed("у бунту"), equals: false,
                   "a one-letter piece blocks the split")
        try expect(TranscriptCorrector.splitMatchAllowed("антропик"), equals: true,
                   "an unsplit match is not subject to the split rule")
        let longBlockers = TranscriptCorrector.RUSSIAN_SPLIT_BLOCKERS.filter { $0.count > 4 }
        try expect(longBlockers.isEmpty, equals: true,
                   "blockers are short function words; a content word here would hide names: \(longBlockers)")

        // Каждая порождаемая форма проверяется против списка русских слов —
        // тот же тест безопасности, что поймал «скалу» и «редис», только
        // теперь на всём множестве форм, а не на исходных записях.
        var generated: [String] = []
        for entry in LatinTermRestorations.all {
            let source = entry.source
            let stem = (source.hasSuffix("а") || source.hasSuffix("я"))
                ? String(source.dropLast())
                : source
            generated.append(source)
            for ending in TranscriptCorrector.RUSSIAN_CASE_ENDINGS {
                generated.append(stem + ending)
            }
        }
        let collisions = generated.filter { RUSSIAN_WORDS_NEVER_RESTORED.contains($0) }
        try expect(collisions.isEmpty, equals: true,
                   "a generated case form collides with an ordinary Russian word: \(collisions)")
        try expect(generated.count >= LatinTermRestorations.count, equals: true,
                   "every entry must generate at least its own plain form")

        // Написания латиницей окончаний не получают: английское слово русских
        // падежей не носит, и «postgres» должен вести себя как раньше.
        try expect(run("поставил postgres"), equals: "поставил PostgreSQL",
                   "Latin-script spellings must keep working untouched")
        try expect(run("поставил postgresом"), equals: "поставил postgresом",
                   "a Latin-script spelling must not swallow a Russian ending")

        // Уже написанное правильно не считается правкой — иначе счётчик
        // сообщал бы о работе, которой не было.
        try expect(TranscriptCorrector.apply(
                    to: "запушил в GitHub",
                    corrections: dictationCorrections(user: [],
                                                      includeBuiltInSpellings: true,
                                                      includeLatinTermRestorations: true)).appliedCount,
                   equals: 0,
                   "text already spelled correctly must not count as a correction")

        // Повторный проход по своему же результату ничего не добавляет.
        let once = run("запушил в гитхаб")
        try expect(run(once), equals: once, "applying the set twice must be a no-op")

        // Слово человека сильнее набора: иначе поправить его нечем.
        let mine = [TranscriptCorrection(source: "гитхаб", replacement: "Гитхаб")]
        try expect(run("запушил в гитхаб", user: mine), equals: "запушил в Гитхаб",
                   "a manual entry must win over the built-in restoration")

        // Выключенный набор молчит — но написания продолжают работать: это
        // два разных тумблера, и путать их нельзя.
        try expect(run("запушил в гитхаб", enabled: false), equals: "запушил в гитхаб",
                   "with the set off nothing should be rewritten")
        try expect(run("поставил postgres", enabled: false), equals: "поставил PostgreSQL",
                   "turning restorations off must not turn spellings off")

        // Пользовательский предел не съедается ни одним из встроенных наборов.
        let many = (0..<MAX_TRANSCRIPT_CORRECTIONS).map {
            TranscriptCorrection(source: "слово\($0)", replacement: "Слово\($0)")
        }
        let merged = dictationCorrections(user: many,
                                          includeBuiltInSpellings: true,
                                          includeLatinTermRestorations: true)
        try expect(merged.count,
                   equals: MAX_TRANSCRIPT_CORRECTIONS + BuiltInSpellings.count
                       + LatinTermRestorations.count,
                   "the built-in sets must not push out the user's own words")

        // Пилюли алфавита. Окно и узкая панель берут их из одного места —
        // тест сторожит сам набор: три варианта, `.auto` первым (смешанная
        // речь — это он), значения переживают round-trip через rawValue,
        // короткая подпись не длиннее полной.
        for interfaceLanguage in [InterfaceLanguage.russian, .english] {
            let options = dictationScriptOptions(interfaceLanguage: interfaceLanguage)
            try expect(options.map(\.language), equals: [.auto, .russian, .english],
                       "the script pills must start with auto and offer both scripts")
            for option in options {
                try expect(DictationLanguage(rawValue: option.language.rawValue),
                           equals: option.language,
                           "a pill value must parse back into DictationLanguage")
                try expect(option.title.isEmpty || option.shortTitle.isEmpty, equals: false,
                           "a pill without a title is a pill nobody can read")
                try expect(option.shortTitle.count <= option.title.count, equals: true,
                           "the short title is for the narrow panel: \(option.shortTitle)")
            }
            try expect(Set(options.map(\.title)).count, equals: options.count,
                       "two pills with the same title are indistinguishable")
        }
    }

    /// Сколько стоит вся правка расшифровки. Не сторож, а измеритель: печатает
    /// время и не проверяет ничего, поэтому в `testAll` не регистрируется.
    ///
    /// Понадобился, когда набору восстановлений разрешили глотать русские
    /// окончания: шаблонов стало столько же, но каждый чуть длиннее, и
    /// утверждение «дороже не стало» должно быть числом, а не обещанием.
    /// Замер показал 143,8 мс до правки против 144,9 после — разница в шуме.
    ///
    /// ⚠️ Число сравнительное, не абсолютное. Самотесты живут только в
    /// debug-сборке, где нет оптимизации всего модуля, и та же работа здесь
    /// занимает примерно в пятьдесят раз больше времени, чем в готовом
    /// приложении: в живом журнале строка `postprocess=` показывает 2–6 мс при
    /// распознавании около 380 мс. Сравнивать этим бенчем можно только два
    /// прогона в одинаковых условиях.
    static func testTranscriptCorrectionsCost() throws {
        // Корпус под живой архив: 132 диктовки, в среднем 125 символов.
        let sentences = [
            "Привет! По итогам звонка присылаю короткое резюме и три следующих шага, посмотри до пятницы",
            "Запушил в гитхаб и починил постгрес, завтра разберусь с докером и терраформом",
            "Давай созвонимся в четверг в три, я закину приглашение и повестку",
            "Собираем бету в пятницу, режем скоуп до словаря и режимов, остальное потом",
        ]
        let corpus = (0..<132).map { sentences[$0 % sentences.count] + " \($0)" }
        let corrections = dictationCorrections(
            user: [TranscriptCorrection(source: "линктрина", replacement: "LinkedIn"),
                   TranscriptCorrection(source: "индид", replacement: "Indeed")],
            includeBuiltInSpellings: true,
            includeLatinTermRestorations: true)

        var total = 0.0
        let rounds = 5
        for _ in 0..<rounds {
            let started = Date()
            for text in corpus {
                _ = TranscriptCorrector.apply(to: text, corrections: corrections)
            }
            total += Date().timeIntervalSince(started)
        }
        let perDictation = total / Double(rounds * corpus.count) * 1000
        print(String(format: "corrections: %d rules, %.3f ms per dictation",
                     corrections.count, perDictation))
    }
}
#endif
