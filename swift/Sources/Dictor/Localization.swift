import Foundation

enum InterfaceLanguage: String, CaseIterable {
    case russian = "ru"
    case english = "en"
}

func localizedText(_ russian: String,
                   _ english: String,
                   language: InterfaceLanguage) -> String {
    language == .russian ? russian : english
}

/// Русское склонение по числу: «1 замена», «2 замены», «5 замен». Английский
/// обходится тернарником на месте, а русский без этой функции даёт «5 замены»
/// — мелкая неряшливость, которая читается как машинный перевод.
func pluralizeRU(_ count: Int, _ one: String, _ few: String, _ many: String) -> String {
    let hundred = abs(count) % 100
    if (11...14).contains(hundred) { return many }
    switch hundred % 10 {
    case 1: return one
    case 2...4: return few
    default: return many
    }
}

/// Единственный источник человеческих имён разрешений — им пользуются и окно,
/// и поповер службы. Раньше поповер показывал сырой rawValue («Нужен доступ:
/// Input Monitoring» в русском интерфейсе), а окно рядом переводило честно.
func localizedPermissionTitle(_ permission: Permission,
                              language: InterfaceLanguage) -> String {
    switch permission {
    case .microphone:
        return localizedText("Микрофон", "Microphone", language: language)
    case .accessibility:
        return localizedText("Универсальный доступ", "Accessibility", language: language)
    case .inputMonitoring:
        return localizedText("Мониторинг ввода", "Input Monitoring", language: language)
    }
}
