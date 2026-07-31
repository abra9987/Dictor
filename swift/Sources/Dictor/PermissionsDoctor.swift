import AppKit

// Починка разрешений.
//
// Классическая жалоба: «я всё выдал, а оно всё равно просит». Причин ровно
// три, и человеку снаружи они неразличимы:
//
//  1. Разрешение выдано другой копии приложения. Запущенное с образа
//     приложение macOS подменяет одноразовой копией, и тумблер в системных
//     настройках включается для неё. Закрыто в 1.0.1 (InstallLocation), но
//     у тех, кто уже успел так поставить, запись осталась.
//  2. Мониторинг ввода кешируется процессом. `CGPreflightListenEventAccess()`
//     запоминает ответ на весь срок жизни процесса: тумблер уже включён, а
//     служба до перезапуска продолжает считать, что доступа нет. Это видно
//     по расхождению — панель настроек говорит «выдано», а агент в своём
//     статусе всё ещё числит разрешение недостающим.
//  3. В TCC осталась запись по старой подписи. Лечится `tccutil reset`
//     и повторным запросом.
//
// Диагностика различает эти случаи и чинит каждый своим способом, вместо
// того чтобы оставлять человека наедине с бесконечным «grant access».

enum PermissionDiagnosis: Equatable {
    /// Выдано и в панели, и в службе.
    case granted
    /// Панель видит разрешение, а служба — нет: она запустилась раньше выдачи.
    case staleInAgent
    /// Не выдано.
    case missing
}

struct PermissionsReport {
    var rows: [(permission: Permission, diagnosis: PermissionDiagnosis)]
    var bundlePath: String
    var isInstalledInApplications: Bool
    var agentRunning: Bool

    var needsAgentRestart: Bool {
        rows.contains { $0.diagnosis == .staleInAgent }
    }

    var allGranted: Bool {
        rows.allSatisfy { $0.diagnosis == .granted }
    }
}

@MainActor
enum PermissionsDoctor {
    static func report() -> PermissionsReport {
        let runtime = AgentRuntimeStateStore.read()
        // Агент пишет сюда то, чего не хватает с его точки зрения. Именно
        // расхождение с нашей и ловит закешированный ответ системы.
        let agentMissing = Set(runtime?.missingPermissions ?? [])
        let agentRunning = DictorAgentService.isAgentRunning()

        let rows = Permission.allCases.map { permission -> (Permission, PermissionDiagnosis) in
            let grantedHere = Permissions.isGranted(permission)
            guard grantedHere else { return (permission, .missing) }
            // Пока служба не запущена, сравнивать не с чем — верим панели.
            if agentRunning, agentMissing.contains(permission.rawValue) {
                return (permission, .staleInAgent)
            }
            return (permission, .granted)
        }

        return PermissionsReport(
            rows: rows,
            bundlePath: InstallLocation.current.path,
            isInstalledInApplications: InstallLocation.isInstalled,
            agentRunning: agentRunning)
    }

    /// Человеческое объяснение состояния одной строки.
    static func explain(_ diagnosis: PermissionDiagnosis,
                        language: InterfaceLanguage) -> String {
        func t(_ russian: String, _ english: String) -> String {
            localizedText(russian, english, language: language)
        }
        switch diagnosis {
        case .granted:
            return t("Выдано", "Granted")
        case .staleInAgent:
            return t("Выдано, но служба ещё не увидела", "Granted, service has not picked it up")
        case .missing:
            return t("Не выдано", "Not granted")
        }
    }

    /// Что именно делает кнопка починки, словами и заранее — чтобы нажатие
    /// не было прыжком в темноту.
    static func repairPlan(_ report: PermissionsReport,
                           language: InterfaceLanguage) -> [String] {
        func t(_ russian: String, _ english: String) -> String {
            localizedText(russian, english, language: language)
        }
        var steps: [String] = []

        if !report.isInstalledInApplications {
            // Путь — единственное «слово» без пробелов на всю строку. Ставим
            // после слэшей нулевой пробел: перенос по словам тогда рвёт путь
            // по сегментам, а обычный текст вокруг остаётся целым.
            let shortPath = (report.bundlePath as NSString)
                .abbreviatingWithTildeInPath
                .replacingOccurrences(of: "/", with: "/\u{200B}")
            steps.append(t("Dictor запущен не из «Программ», а из \(shortPath). macOS привязывает разрешения к запущенной копии, поэтому выданное здесь не поможет установленной версии. Перенесите Dictor в «Программы» и выдайте заново.",
                           "Dictor is running outside Applications, from \(shortPath). macOS binds permissions to the running copy, so anything granted here will not help the installed version. Move Dictor to Applications and grant again."))
        }
        if report.needsAgentRestart {
            steps.append(t("Перезапустить службу диктовки — она проверяет доступ один раз при старте и держит ответ до конца работы.",
                           "Restart the dictation service — it checks access once at startup and keeps that answer for its lifetime."))
        }
        let missing = report.rows.filter { $0.diagnosis == .missing }.map(\.permission)
        if !missing.isEmpty {
            let names = missing.map {
                onboardingPermissionCopy($0, language: language).name
            }.joined(separator: ", ")
            steps.append(t("Сбросить запись macOS и запросить заново: \(names). Сброс нужен, если разрешение выдавалось прошлой сборке — система помнит её подпись.",
                           "Reset the macOS record and ask again: \(names). The reset matters when the permission was granted to an older build — the system remembers its signature."))
        }
        if steps.isEmpty {
            steps.append(t("Всё в порядке: все три разрешения выданы, и служба их видит.",
                           "Everything checks out: all three permissions are granted and the service sees them."))
        }
        return steps
    }
}
