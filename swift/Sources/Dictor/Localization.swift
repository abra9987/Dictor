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
