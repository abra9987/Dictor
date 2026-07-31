//
// Где физически лежит запущенный бандл.
//
// Приложение, открытое двойным кликом прямо с .dmg (или из Загрузок под
// карантином), macOS запускает не по своему пути, а из одноразовой копии —
// App Translocation. Копия только для чтения и исчезает вместе с образом.
// Всё, что Dictor делает при первом запуске, к такому пути привязывать
// нельзя: LaunchAgent будет ссылаться на исчезнувший каталог, выданные
// разрешения на микрофон и мониторинг ввода достанутся копии-призраку,
// а образ перестанет извлекаться, потому что служба держит его занятым.
//

import AppKit

enum InstallLocation {
    static var current: URL { Bundle.main.bundleURL }

    static var isInstalled: Bool {
        current.resolvingSymlinksInPath().path == INSTALLED_APP_BUNDLE_PATH
    }

    /// Путь одноразовый: том только для чтения или каталог, который macOS
    /// подсунула вместо настоящего.
    static func isEphemeral(_ url: URL = current) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        if path.contains("/AppTranslocation/") { return true }
        if path.hasPrefix("/Volumes/") { return true }
        if let values = try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]),
           values.volumeIsReadOnly == true {
            return true
        }
        return false
    }

    enum MoveFailure: LocalizedError {
        case copyFailed(String)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let detail): return detail
            case .launchFailed(let detail): return detail
            }
        }
    }

    /// Копирует бандл в «Программы» и открывает уже установленную копию.
    /// Вызывающий обязан сразу завершить текущий процесс — дальше работает
    /// та копия, а не эта.
    static func moveToApplicationsAndRelaunch() throws {
        let source = current
        let target = URL(fileURLWithPath: INSTALLED_APP_BUNDLE_PATH)

        // Старая установленная копия могла оставить работающую службу: пока
        // она жива, каталог занят, а после подмены бинарника она всё равно
        // указывала бы в никуда.
        if FileManager.default.fileExists(atPath: target.path) {
            DictorAgentService.stop()
            try? FileManager.default.removeItem(at: target)
        }

        let copy = DictorAgentService.run("/usr/bin/ditto", [source.path, target.path])
        guard copy.status == 0 else {
            throw MoveFailure.copyFailed(copy.output.isEmpty
                ? "ditto завершился с кодом \(copy.status)"
                : copy.output)
        }

        // Без снятия карантина macOS запустит установленную копию всё той же
        // одноразовой копией, и мы вернёмся ровно туда, откуда ушли.
        _ = DictorAgentService.run("/usr/bin/xattr",
                                   ["-dr", "com.apple.quarantine", target.path])

        let launch = DictorAgentService.run("/usr/bin/open", ["-n", target.path])
        guard launch.status == 0 else {
            throw MoveFailure.launchFailed(launch.output.isEmpty
                ? "open завершился с кодом \(launch.status)"
                : launch.output)
        }
    }
}
