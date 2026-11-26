import AppKit
import Foundation
import CryptoKit

// MARK: - Update check
//
// Reads update.json from the update channel once at boot + every 6 h.
// Users can
// also force the same lookup from the menu. When a newer version is
// found AND it's not in the user's skipped list, a submenu inserts
// itself at the top of the menu: What's new / Update now / Remind me
// in 24 hours / Skip vX.Y.Z.

struct DictorRelease: Sendable, Equatable {
    let tagName: String      // 'v0.1.7'
    let version: String      // '0.1.7' (no v)
    let body: String         // release notes, raw markdown
    let htmlURL: String
}

/// `update.json` с канала обновлений. Тот же файл читает установщик —
/// он же несёт контрольную сумму архива.
struct DictorUpdateFeedResponse: Decodable {
    let version: String
    let notes: String?
}

/// Why an update check failed. Carried as a value (not a string) so
/// the manual-check alert can explain the actual problem instead of
/// blaming the network for everything; automatic ticks ignore it and
/// stay silent.
enum UpdateCheckFailure: Error, Equatable, Sendable {
    /// The HTTPS request itself failed (offline, DNS, timeout).
    case network
    /// The update server answered with a non-2xx status.
    case httpStatus(Int)
    /// A response arrived but was oversized, malformed, or carried an
    /// unusable tag.
    case unexpectedResponse
}

/// User-facing explanation for a failed *manual* update check. Only
/// the alert behind "Check for Updates…" uses this — automatic and
/// settings-toggle checks never alert.
func manualUpdateCheckFailureText(_ failure: UpdateCheckFailure) -> String {
    switch failure {
    case .network:
        return "Dictor couldn't reach the update server. Check your internet connection and try again."
    case .httpStatus(let code):
        return "The update server returned an error (HTTP \(code)). Try again later."
    case .unexpectedResponse:
        return "The update server returned a response Dictor couldn't read. Try again later, or open \(UPDATE_CHANNEL_PAGE.absoluteString) directly."
    }
}

enum UpdateCheck {
    static let maxReleaseResponseBytes = 512 * 1024

    static func fetchLatest() async -> Result<DictorRelease, UpdateCheckFailure> {
        var req = URLRequest(url: UPDATE_MANIFEST_URL)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // The privacy docs promise exactly this fixed token — no
        // version, device, or user identifiers. Must stay in sync with
        // docs/updates.md and PRIVACY.md.
        req.setValue("dictor-update-check", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: req)
            return parseLatest(data: data, response: response)
        } catch {
            return .failure(.network)
        }
    }

    static func parseLatest(data: Data, response: URLResponse) -> Result<DictorRelease, UpdateCheckFailure> {
        guard let http = response as? HTTPURLResponse else {
            return .failure(.unexpectedResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failure(.httpStatus(http.statusCode))
        }
        guard data.count <= maxReleaseResponseBytes,
              let payload = try? JSONDecoder().decode(DictorUpdateFeedResponse.self, from: data) else {
            return .failure(.unexpectedResponse)
        }

        let raw = payload.version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let version = normalizedReleaseVersion(from: raw) else {
            return .failure(.unexpectedResponse)
        }

        return .success(DictorRelease(
            tagName: "v\(version)",
            version: version,
            body: payload.notes ?? "",
            htmlURL: UPDATE_CHANNEL_PAGE.absoluteString
        ))
    }

    static func normalizedReleaseVersion(from tag: String) -> String? {
        var version = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = version.first, first == "v" || first == "V" {
            version.removeFirst()
        }

        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy({ ("0"..."9").contains($0) }),
                  part == "0" || !part.hasPrefix("0"),
                  Int(part) != nil else {
                return nil
            }
        }
        return parts.joined(separator: ".")
    }

    // Ссылка «что нового» в манифесте не читается вовсе: htmlURL всегда
    // страница канала, зашитая в приложение. Раньше здесь жил санитайзер
    // ссылок из манифеста — его не вызывал никто, а тест на нём создавал
    // впечатление защиты, которой не было в потоке.
}

struct DictorUpdateManifest: Decodable, Equatable, Sendable {
    let version: String
    let sha256: String
}

struct PreparedDictorUpdate: Sendable {
    let version: String
    let workDirectory: URL
    let stagedAppURL: URL
}

enum DictorUpdateInstallerError: LocalizedError, Equatable, Sendable {
    case network
    /// Связь была, но обрывалась раз за разом: часть архива пришла, остальное нет.
    case downloadInterrupted(received: Int64, total: Int64?)
    case httpStatus(Int)
    case invalidManifest
    case manifestVersionMismatch(expected: String, actual: String)
    case archiveTooLarge
    case checksumMismatch
    case extractionFailed(String)
    case invalidBundle(String)
    case appNotWritable

    var errorDescription: String? { message(language: .russian) }

    func message(language: InterfaceLanguage) -> String {
        if language == .english {
            switch self {
            case .network:
                return "Dictor couldn't reach the update server. Check your internet connection; if it works, the network may be blocking the server — try a VPN or another network, then try again."
            case .downloadInterrupted(let received, let total):
                return "The download kept breaking off (\(updateDownloadPhaseText(UpdateDownloadProgress(received: received, total: total, attempt: 1), language: .english, capitalized: false))). If the internet works, the network is probably throttling the update server — turn on a VPN or switch networks, then try again."
            case .httpStatus(let code):
                return "The update server returned HTTP \(code)."
            case .invalidManifest:
                return "The update manifest is damaged or has an unknown format."
            case .manifestVersionMismatch(let expected, let actual):
                return "The update channel offers version \(expected), but the manifest reports \(actual). The update was stopped."
            case .archiveTooLarge:
                return "The update archive exceeds the allowed size."
            case .checksumMismatch:
                return "The archive checksum did not match. The application was not replaced."
            case .extractionFailed(let detail):
                return "The update could not be extracted: \(detail)"
            case .invalidBundle(let detail):
                return "The new application failed verification: \(detail)"
            case .appNotWritable:
                return "Dictor cannot replace the application in Applications. Run the regular installer once."
            }
        }
        switch self {
        case .network:
            return "Не удалось связаться с сервером обновлений. Проверьте интернет; если он работает — сеть, вероятно, не пускает к серверу: включите VPN или другую сеть и попробуйте ещё раз."
        case .downloadInterrupted(let received, let total):
            return "Скачивание раз за разом обрывалось (\(updateDownloadPhaseText(UpdateDownloadProgress(received: received, total: total, attempt: 1), language: .russian, capitalized: false))). Если интернет работает, сеть, вероятно, режет сервер обновлений: включите VPN или другую сеть и попробуйте ещё раз."
        case .httpStatus(let code):
            return "Сервер обновлений вернул ошибку HTTP \(code)."
        case .invalidManifest:
            return "Манифест обновления повреждён или имеет неизвестный формат."
        case .manifestVersionMismatch(let expected, let actual):
            return "Канал обновлений предлагает версию \(expected), а манифест сообщает о версии \(actual). Обновление остановлено."
        case .archiveTooLarge:
            return "Архив обновления превышает допустимый размер."
        case .checksumMismatch:
            return "Контрольная сумма архива не совпала. Приложение не будет заменено."
        case .extractionFailed(let detail):
            return "Не удалось распаковать обновление: \(detail)"
        case .invalidBundle(let detail):
            return "Проверка нового приложения не пройдена: \(detail)"
        case .appNotWritable:
            return "Dictor не может заменить приложение в папке Applications. Запустите обычный установщик один раз."
        }
    }
}

enum DictorUpdateInstaller {
    private static let manifestMaxBytes = 16 * 1024

    static func fetchManifest(expectedVersion: String) async throws -> DictorUpdateManifest {
        var request = URLRequest(url: UPDATE_MANIFEST_URL)
        request.setValue("dictor-in-app-update", forHTTPHeaderField: "User-Agent")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.timeoutInterval = 15
        let (data, response) = try await fetch(request: request, maxBytes: manifestMaxBytes)
        guard (200..<300).contains(response.statusCode) else {
            throw DictorUpdateInstallerError.httpStatus(response.statusCode)
        }
        return try parseManifest(data, expectedVersion: expectedVersion)
    }

    static func parseManifest(_ data: Data,
                              expectedVersion: String) throws -> DictorUpdateManifest {
        guard let manifest = try? JSONDecoder().decode(DictorUpdateManifest.self, from: data),
              UpdateCheck.normalizedReleaseVersion(from: manifest.version) == manifest.version,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            throw DictorUpdateInstallerError.invalidManifest
        }
        guard manifest.version == expectedVersion else {
            throw DictorUpdateInstallerError.manifestVersionMismatch(
                expected: expectedVersion,
                actual: manifest.version
            )
        }
        return manifest
    }

    /// Архив целиком и с проверенной суммой. Отдельно от `prepare`, чтобы
    /// самотест гонял ровно эту цепочку — загрузчик с докачкой и SHA-256 —
    /// через заглушку сервера, а не её копию.
    static func downloadVerifiedArchive(
        manifest: DictorUpdateManifest,
        policy: UpdateDownloadPolicy = .standard,
        configuration: URLSessionConfiguration? = nil,
        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void
    ) async throws -> Data {
        let archiveData = try await UpdateArchiveDownloader.download(
            from: updateArchiveURL(forVersion: manifest.version),
            userAgent: "dictor-in-app-update",
            policy: policy,
            configuration: configuration,
            progress: progress)

        var hasher = SHA256()
        hasher.update(data: archiveData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            log("update: archive checksum mismatch for v\(manifest.version)")
            throw DictorUpdateInstallerError.checksumMismatch
        }
        return archiveData
    }

    static func prepare(manifest: DictorUpdateManifest,
                        progress: @escaping @Sendable (UpdateDownloadProgress) -> Void)
        async throws -> PreparedDictorUpdate {
        guard appCanBeReplaced(at: Bundle.main.bundleURL) else {
            throw DictorUpdateInstallerError.appNotWritable
        }

        let archiveData = try await downloadVerifiedArchive(manifest: manifest,
                                                            progress: progress)

        let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Dictor-update-\(UUID().uuidString)", isDirectory: true)
        let archiveFile = workDirectory.appendingPathComponent("Dictor.zip")
        let extractedDirectory = workDirectory.appendingPathComponent("release", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: extractedDirectory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try archiveData.write(to: archiveFile, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw DictorUpdateInstallerError.extractionFailed(error.localizedDescription)
        }

        let extraction = await Task.detached(priority: .userInitiated) {
            DictorAgentService.run("/usr/bin/ditto",
                                         ["-x", "-k", archiveFile.path, extractedDirectory.path])
        }.value
        guard extraction.status == 0 else {
            try? FileManager.default.removeItem(at: workDirectory)
            throw DictorUpdateInstallerError.extractionFailed(extraction.output)
        }

        let stagedAppURL = extractedDirectory.appendingPathComponent("Dictor.app",
                                                                      isDirectory: true)
        do {
            try validateApp(at: stagedAppURL, expectedVersion: manifest.version)
        } catch let error as DictorUpdateInstallerError {
            try? FileManager.default.removeItem(at: workDirectory)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: workDirectory)
            throw DictorUpdateInstallerError.invalidBundle(error.localizedDescription)
        }
        return PreparedDictorUpdate(version: manifest.version,
                                          workDirectory: workDirectory,
                                          stagedAppURL: stagedAppURL)
    }

    static func appCanBeReplaced(at appURL: URL) -> Bool {
        let fileManager = FileManager.default
        guard appURL.pathExtension == "app",
              fileManager.fileExists(atPath: appURL.path) else { return false }
        return fileManager.isWritableFile(atPath: appURL.path)
            && fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    static func validateApp(at appURL: URL, expectedVersion: String) throws {
        let fileManager = FileManager.default
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Dictor")
        guard appURL.lastPathComponent == "Dictor.app",
              fileManager.fileExists(atPath: infoURL.path),
              fileManager.isExecutableFile(atPath: executableURL.path),
              let infoData = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: infoData,
                                                                     format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.raul.dictor",
              info["CFBundleShortVersionString"] as? String == expectedVersion else {
            throw DictorUpdateInstallerError.invalidBundle("неверный идентификатор или версия")
        }

        if let enumerator = fileManager.enumerator(at: appURL,
                                                   includingPropertiesForKeys: [.isSymbolicLinkKey],
                                                   options: []) {
            for case let itemURL as URL in enumerator {
                if (try? itemURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    throw DictorUpdateInstallerError.invalidBundle("архив содержит символическую ссылку")
                }
            }
        }

        // `-R` — обязателен. Без него проверяется только целостность бандла,
        // но не то, кем он подписан (см. UPDATE_SIGNING_CERT_SHA1).
        let signature = DictorAgentService.run(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", "-R", updateCodeRequirement, appURL.path])
        guard signature.status == 0 else {
            throw DictorUpdateInstallerError.invalidBundle("codesign: \(signature.output)")
        }
    }

    private static func fetch(request: URLRequest,
                              maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = request.timeoutInterval
        configuration.timeoutIntervalForResource = request.timeoutInterval
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DictorUpdateInstallerError.network
            }
            guard data.count <= maxBytes else {
                throw DictorUpdateInstallerError.archiveTooLarge
            }
            return (data, http)
        } catch let error as DictorUpdateInstallerError {
            throw error
        } catch {
            throw DictorUpdateInstallerError.network
        }
    }
}

/// Запускает подготовленное обновление: окно прогресса плюс helper-скрипт,
/// который ждёт смерти вызывающего процесса и подменяет бандл.
///
/// Живёт здесь, а не в панели или в агенте, потому что звать его должны оба:
/// пункт «Update now…» в меню-баре — это агент, а окно обновляется из своего
/// процесса. Пока установка была написана в одном ControlPanel, из меню-бара
/// до неё было не дотянуться, и кнопка вместо обновления показывала совет
/// установить приложение заново вручную.
///
/// **Вызывающий обязан завершиться сразу после успешного возврата.** Скрипт
/// ждёт смерти переданного pid и только тогда трогает бандл; живой процесс
/// держит установку на месте до таймаута, после чего получает SIGTERM.
func launchPreparedDictorUpdate(_ prepared: PreparedDictorUpdate,
                                language: InterfaceLanguage,
                                pid: pid_t = getpid(),
                                appURL: URL = Bundle.main.bundleURL) throws {
    let statePath = try createPrivateUpdateProgressStateFile()
    let helperLog = try openPrivateUpdateHelperLog()
    let backupURL = appURL.deletingLastPathComponent()
        .appendingPathComponent(".Dictor-update-backup-\(UUID().uuidString).app",
                                isDirectory: true)
    let script = dictorDirectUpdateHelperScript(
        pid: pid,
        targetVersion: prepared.version,
        statePath: statePath,
        stagedAppPath: prepared.stagedAppURL.path,
        workDirectory: prepared.workDirectory.path,
        backupAppPath: backupURL.path,
        appPath: appURL.path,
        language: language
    )
    let helperPath = try writePrivateUpdateHelperScript(script)

    let progressAppPath: String
    do {
        progressAppPath = try launchDictorUpdateProgressApp(
            statePath: statePath,
            logPath: helperLog.path,
            targetVersion: prepared.version
        )
    } catch {
        try? FileManager.default.removeItem(atPath: helperPath)
        try? FileManager.default.removeItem(atPath: statePath)
        try? FileManager.default.removeItem(at: prepared.workDirectory)
        helperLog.handle.closeFile()
        throw error
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = [helperPath]
    process.environment = systemToolProcessEnvironment()
    process.standardOutput = helperLog.handle
    process.standardError = helperLog.handle
    do {
        try process.run()
    } catch {
        try? FileManager.default.removeItem(atPath: helperPath)
        try? FileManager.default.removeItem(atPath: statePath)
        try? FileManager.default.removeItem(at: prepared.workDirectory)
        try? FileManager.default.removeItem(atPath: progressAppPath)
        helperLog.handle.closeFile()
        throw error
    }
}

/// Окно прогресса — копия приложения во временной папке: свой бандл через
/// секунду будет переименован и заменён, а показывать ход установки должно
/// что-то, что это переживёт.
func launchDictorUpdateProgressApp(statePath: String,
                                   logPath: String,
                                   targetVersion: String) throws -> String {
    let sourceAppURL = Bundle.main.bundleURL
    guard sourceAppURL.pathExtension == "app",
          let executableName = Bundle.main.executableURL?.lastPathComponent else {
        throw posixError(EINVAL)
    }
    let progressAppURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).app",
                                isDirectory: true)
    try FileManager.default.copyItem(at: sourceAppURL, to: progressAppURL)
    let executableURL = progressAppURL
        .appendingPathComponent("Contents/MacOS", isDirectory: true)
        .appendingPathComponent(executableName)
    let process = Process()
    process.executableURL = executableURL
    process.arguments = [
        UPDATE_PROGRESS_ARGUMENT,
        statePath,
        logPath,
        targetVersion,
        progressAppURL.path,
    ]
    process.environment = systemToolProcessEnvironment()
    do {
        try process.run()
        return progressAppURL.path
    } catch {
        try? FileManager.default.removeItem(at: progressAppURL)
        throw error
    }
}
