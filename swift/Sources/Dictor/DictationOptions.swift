import FluidAudio
import Foundation

enum PasteSuffix: String { case appendSpace = "space", none, appendNewline = "newline" }
let PASTE_SUFFIX_DISPLAY: [PasteSuffix: String] = [
    .appendSpace: "Append space",
    .none: "No suffix",
    .appendNewline: "Append newline",
]

/// User-visible language choice for the v3 decoder script filter. `.auto`
/// passes no hint and lets the decoder pick freely — the right default for
/// almost everyone. Selecting a specific language biases the joint head
/// toward that script (Latin vs Cyrillic), which prevents the occasional
/// Cyrillic-character bleed-through that v3 can emit when transcribing
/// Latin-script speech (FluidAudio v0.14.1 fix). Raw values match
/// FluidAudio's `Language` BCP-47-ish keys so `fluidLanguage` is a direct
/// lookup.
enum DictationLanguage: String, CaseIterable {
    case auto
    case english = "en"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case portuguese = "pt"
    case romanian = "ro"
    case polish = "pl"
    case czech = "cs"
    case slovak = "sk"
    case slovenian = "sl"
    case croatian = "hr"
    case bosnian = "bs"
    case russian = "ru"
    case ukrainian = "uk"
    case belarusian = "be"
    case bulgarian = "bg"
    case serbian = "sr"

    /// Map to FluidAudio's `Language` enum. Returns nil for `.auto` so the
    /// caller passes no hint and the decoder script filter stays off.
    var fluidLanguage: Language? {
        switch self {
        case .auto:        return nil
        case .english:     return .english
        case .spanish:     return .spanish
        case .french:      return .french
        case .german:      return .german
        case .italian:     return .italian
        case .portuguese:  return .portuguese
        case .romanian:    return .romanian
        case .polish:      return .polish
        case .czech:       return .czech
        case .slovak:      return .slovak
        case .slovenian:   return .slovenian
        case .croatian:    return .croatian
        case .bosnian:     return .bosnian
        case .russian:     return .russian
        case .ukrainian:   return .ukrainian
        case .belarusian:  return .belarusian
        case .bulgarian:   return .bulgarian
        case .serbian:     return .serbian
        }
    }
}

/// Три варианта, которые человек видит в окне и в узкой панели.
///
/// Настройка называется «язык», а делает «разреши только этот алфавит»:
/// внутри FluidAudio подсказка языка включает `TokenLanguageFilter`, и токен,
/// не подходящий по script'у, заменяется подходящим. Выбрав «RU», человек
/// думал «я говорю по-русски», а буквально запрещал латиницу — английские
/// слова после этого не могли выйти иначе как кириллицей. Поэтому пилюли
/// говорят про алфавит, а `.auto` стоит первым: смешанная речь — это он.
///
/// Полный список из 18 языков остаётся в меню-баре: там он и был.
struct DictationScriptOption {
    let language: DictationLanguage
    /// Для окна, где места хватает.
    let title: String
    /// Для узкой панели: «Кир.» / «Лат.».
    let shortTitle: String
}

func dictationScriptOptions(interfaceLanguage: InterfaceLanguage) -> [DictationScriptOption] {
    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: interfaceLanguage)
    }
    return [
        DictationScriptOption(language: .auto,
                              title: t("Авто", "Auto"),
                              shortTitle: t("Авто", "Auto")),
        DictationScriptOption(language: .russian,
                              title: t("Кириллица", "Cyrillic"),
                              shortTitle: t("Кир.", "Cyr.")),
        DictationScriptOption(language: .english,
                              title: t("Латиница", "Latin"),
                              shortTitle: t("Лат.", "Lat.")),
    ]
}

/// Кириллические языки декодера — для подписи «Кириллица — украинский».
let DICTATION_CYRILLIC_LANGUAGES: Set<DictationLanguage> =
    [.russian, .ukrainian, .belarusian, .bulgarian, .serbian]

/// Полный список языков для попапа в окне: три обычных варианта первыми,
/// дальше кириллические, затем латинские. Выводится из `allCases`, а не
/// перечисляется руками — новый язык в enum не сможет молча выпасть.
func dictationLanguageMenuOrder() -> [DictationLanguage] {
    let leading: [DictationLanguage] = [.auto, .russian, .english]
    let cyrillic = DictationLanguage.allCases.filter {
        !leading.contains($0) && DICTATION_CYRILLIC_LANGUAGES.contains($0)
    }
    let latin = DictationLanguage.allCases.filter {
        !leading.contains($0) && !DICTATION_CYRILLIC_LANGUAGES.contains($0)
    }
    return leading + cyrillic + latin
}

/// Подпись языка в попапе. Ведёт с алфавита, а не с языка: настройка
/// буквально ограничивает алфавит вывода (см. DictationScriptOption), и
/// «Кириллица — украинский» говорит правду о том, что случится с текстом.
func dictationLanguageMenuTitle(_ language: DictationLanguage,
                                interfaceLanguage: InterfaceLanguage) -> String {
    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: interfaceLanguage)
    }
    let name: String
    switch language {
    case .auto:
        return t("Авто — смешанная речь", "Auto — mixed speech")
    case .english:    name = t("английский", "English")
    case .spanish:    name = t("испанский", "Spanish")
    case .french:     name = t("французский", "French")
    case .german:     name = t("немецкий", "German")
    case .italian:    name = t("итальянский", "Italian")
    case .portuguese: name = t("португальский", "Portuguese")
    case .romanian:   name = t("румынский", "Romanian")
    case .polish:     name = t("польский", "Polish")
    case .czech:      name = t("чешский", "Czech")
    case .slovak:     name = t("словацкий", "Slovak")
    case .slovenian:  name = t("словенский", "Slovenian")
    case .croatian:   name = t("хорватский", "Croatian")
    case .bosnian:    name = t("боснийский", "Bosnian")
    case .russian:    name = t("русский", "Russian")
    case .ukrainian:  name = t("украинский", "Ukrainian")
    case .belarusian: name = t("белорусский", "Belarusian")
    case .bulgarian:  name = t("болгарский", "Bulgarian")
    case .serbian:    name = t("сербский", "Serbian")
    }
    let script = DICTATION_CYRILLIC_LANGUAGES.contains(language)
        ? t("Кириллица", "Cyrillic")
        : t("Латиница", "Latin")
    return "\(script) — \(name)"
}

let DICTATION_LANGUAGE_DISPLAY: [DictationLanguage: String] = [
    .auto: "Auto-detect",
    .english: "English",
    .spanish: "Spanish",
    .french: "French",
    .german: "German",
    .italian: "Italian",
    .portuguese: "Portuguese",
    .romanian: "Romanian",
    .polish: "Polish",
    .czech: "Czech",
    .slovak: "Slovak",
    .slovenian: "Slovenian",
    .croatian: "Croatian",
    .bosnian: "Bosnian",
    .russian: "Russian",
    .ukrainian: "Ukrainian",
    .belarusian: "Belarusian",
    .bulgarian: "Bulgarian",
    .serbian: "Serbian",
]

enum SpeechModelProfile: String, CaseIterable {
    case multilingualUltra = "multilingual_ultra"
    // Прежние варианты. Оставлены только затем, чтобы сохранённая настройка
    // читалась и переезжала на поддерживаемую модель: v3 был моделью по
    // умолчанию до перехода на Ultra, Unified — ещё раньше.
    case multilingualV3 = "multilingual_v3"
    case englishUnified = "english_unified"

    static let productionDefault: SpeechModelProfile = .multilingualUltra

    var isProductionSupported: Bool {
        self == .multilingualUltra
    }

    var productionProfile: SpeechModelProfile {
        isProductionSupported ? self : Self.productionDefault
    }

    var displayName: String {
        switch self {
        case .multilingualUltra:
            return "Multilingual (Parakeet Ultra)"
        case .multilingualV3:
            return "Multilingual (Parakeet TDT v3, deprecated)"
        case .englishUnified:
            return "English optimized (Parakeet Unified, deprecated)"
        }
    }

    var shortName: String {
        switch self {
        case .multilingualUltra:
            return "Parakeet Ultra"
        case .multilingualV3:
            return "Parakeet TDT v3"
        case .englishUnified:
            return "Parakeet Unified"
        }
    }

    var aboutModelText: String {
        switch self {
        case .multilingualUltra:
            return "FluidAudio · Parakeet Ultra multilingual (CoreML / ANE)"
        case .multilingualV3:
            return "FluidAudio · Parakeet TDT v3 multilingual (deprecated)"
        case .englishUnified:
            return "FluidAudio · Parakeet Unified English (deprecated)"
        }
    }

    var setupReadyDetail: String {
        "\(shortName) is loaded locally."
    }

    /// Загружается всегда поддерживаемая модель, какой бы профиль ни был
    /// сохранён, поэтому и сбрасывается её кеш, а не кеш названного профиля.
    var cacheResetDetail: String {
        "Dictor will delete the local \(Self.productionDefault.shortName) model cache, unload the current speech model, and download a fresh verified copy. Dictation is unavailable until then — unless the previous model is still on this Mac, in which case it carries on with that one."
    }

    /// Реальная модель на диске — 632 МБ (603 МиБ): энкодер Ultra хранится в
    /// int8, а не в 6-битной палитре, как у v3, у которой было 461 МиБ.
    /// Оценка, текст и строка Needed: под ним обязаны называть одно и то же
    /// число — однажды они расходились втрое.
    var estimatedDownloadBytes: Int64 {
        603 * 1024 * 1024
    }

    var downloadSizeText: String {
        "about 630 MB"
    }
}

func productionSpeechModelProfile(rawValue: String?) -> SpeechModelProfile {
    guard let rawValue,
          let profile = SpeechModelProfile(rawValue: rawValue),
          profile.isProductionSupported else {
        return .productionDefault
    }
    return profile
}
