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
        // docs/privacy/network-calls.json.
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

    /// Ссылка «что нового», которую покажем человеку. Принимаем только свой
    /// канал по HTTPS и без пользователя, пароля, запроса и якоря — всё
    /// остальное схлопывается на главную страницу канала. Манифест лежит на
    /// нашем сервере, но обращаться с ним как с доверенным вводом нельзя.
    static func sanitizedReleaseURL(_ value: String?) -> String {
        let fallback = UPDATE_CHANNEL_PAGE.absoluteString
        guard let value else { return fallback }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              components.scheme == "https",
              components.host == UPDATE_CHANNEL_PAGE.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return fallback
        }
        return trimmed
    }
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
                return "The update could not be downloaded. Check your internet connection."
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
            return "Не удалось скачать обновление. Проверьте подключение к интернету."
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

    static func prepare(manifest: DictorUpdateManifest) async throws -> PreparedDictorUpdate {
        guard appCanBeReplaced(at: Bundle.main.bundleURL) else {
            throw DictorUpdateInstallerError.appNotWritable
        }

        let archiveURL = updateArchiveURL(forVersion: manifest.version)
        var request = URLRequest(url: archiveURL)
        request.setValue("dictor-in-app-update", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        let (archiveData, response) = try await fetch(request: request,
                                                      maxBytes: UPDATE_ARCHIVE_MAX_BYTES)
        guard (200..<300).contains(response.statusCode) else {
            throw DictorUpdateInstallerError.httpStatus(response.statusCode)
        }

        var hasher = SHA256()
        hasher.update(data: archiveData)
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(manifest.sha256) == .orderedSame else {
            throw DictorUpdateInstallerError.checksumMismatch
        }

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

func shellSingleQuoted(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
}

func sanitizedEnvironmentValue(_ value: String?) -> String? {
    guard let value,
          !value.isEmpty,
          !value.utf8.contains(0),
          !value.contains(where: { $0.isNewline }) else {
        return nil
    }
    return value
}

func trustedProcessEnvironment(path: String,
                                       current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var env: [String: String] = [
        "HOME": NSHomeDirectory(),
        "PATH": path,
        "SHELL": "/bin/zsh",
        "TMPDIR": NSTemporaryDirectory(),
        "LANG": sanitizedEnvironmentValue(current["LANG"]) ?? "en_US.UTF-8",
    ]

    if let user = sanitizedEnvironmentValue(current["USER"]) {
        env["USER"] = user
    }
    if let logname = sanitizedEnvironmentValue(current["LOGNAME"]) ?? env["USER"] {
        env["LOGNAME"] = logname
    }
    if let encoding = sanitizedEnvironmentValue(current["__CF_USER_TEXT_ENCODING"]) {
        env["__CF_USER_TEXT_ENCODING"] = encoding
    }

    return env
}

func systemToolProcessEnvironment(current: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    trustedProcessEnvironment(path: "/usr/bin:/bin:/usr/sbin:/sbin", current: current)
}

func dictorDirectUpdateHelperScript(pid: pid_t,
                                           targetVersion: String,
                                           statePath: String,
                                           stagedAppPath: String,
                                           workDirectory: String,
                                           backupAppPath: String,
                                           appPath: String,
                                           language: InterfaceLanguage,
                                           relaunch: Bool = true,
                                           // Parameterised for one reason: the self-test runs this
                                           // script for real against a temporary bundle, and a
                                           // hard-coded label made it boot out the live agent —
                                           // running the tests uninstalled the user's dictation
                                           // service. Everything else in the script is already
                                           // addressed by path, so the label was the last thing
                                           // reaching outside the sandbox.
                                           agentLabel: String = AGENT_LABEL) -> String {
    let preparing = localizedText("Подготавливаю замену приложения…",
                                  "Preparing to replace the application…",
                                  language: language)
    let installing = localizedText("Устанавливаю Dictor v\(targetVersion)…",
                                    "Installing Dictor v\(targetVersion)…",
                                    language: language)
    let verifying = localizedText("Проверяю установленную версию…",
                                   "Verifying the installed version…",
                                   language: language)
    let relaunching = localizedText("Обновление готово. Запускаю Dictor…",
                                    "Update complete. Reopening Dictor…",
                                    language: language)
    let complete = localizedText("Dictor v\(targetVersion) установлена.",
                                  "Dictor v\(targetVersion) is installed.",
                                  language: language)
    let failed = localizedText("Обновление не установлено. Предыдущая версия восстановлена.",
                                "The update was not installed. The previous version was restored.",
                                language: language)

    return #"""
    #!/bin/bash
    set -u
    umask 077

    SCRIPT_PATH="$0"
    PANEL_PID=\#(pid)
    TARGET_VERSION=\#(shellSingleQuoted(targetVersion))
    STATE_PATH=\#(shellSingleQuoted(statePath))
    STAGED_APP=\#(shellSingleQuoted(stagedAppPath))
    WORK_DIR=\#(shellSingleQuoted(workDirectory))
    BACKUP_APP=\#(shellSingleQuoted(backupAppPath))
    APP_PATH=\#(shellSingleQuoted(appPath))
    SHOULD_RELAUNCH=\#(relaunch ? "1" : "0")
    APP_PARENT="$(/usr/bin/dirname "$APP_PATH")"
    INFO_PLIST="$APP_PATH/Contents/Info.plist"
    SERVICE="gui/$(/usr/bin/id -u)/\#(agentLabel)"
    AGENT_PLIST="$HOME/Library/LaunchAgents/\#(agentLabel).plist"

    timestamp() {
        /bin/date -u '+%Y-%m-%dT%H:%M:%SZ'
    }

    log() {
        printf '[%s] %s\n' "$(timestamp)" "$*"
    }

    state() {
        local phase="$1"
        local message="$2"
        local tmp="${STATE_PATH}.$$"
        log "$message"
        if printf '%s\t%s\n' "$phase" "$message" >"$tmp"; then
            /bin/chmod 600 "$tmp" 2>/dev/null || true
            /bin/mv -f "$tmp" "$STATE_PATH" 2>/dev/null || true
        else
            /bin/rm -f "$tmp" 2>/dev/null || true
        fi
    }

    cleanup() {
        /bin/rm -rf "$WORK_DIR" 2>/dev/null || true
        /bin/rm -f "$SCRIPT_PATH" 2>/dev/null || true
    }
    trap cleanup EXIT

    wait_for_panel_exit() {
        for _ in {1..40}; do
            if ! /bin/kill -0 "$PANEL_PID" 2>/dev/null; then
                return 0
            fi
            /bin/sleep 0.25
        done
        /bin/kill -TERM "$PANEL_PID" 2>/dev/null || true
        /bin/sleep 1
        ! /bin/kill -0 "$PANEL_PID" 2>/dev/null
    }

    verify_app() {
        [ -x "$APP_PATH/Contents/MacOS/Dictor" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INFO_PLIST" 2>/dev/null)" = "com.raul.dictor" ] || return 1
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null)" = "$TARGET_VERSION" ] || return 1
        /usr/bin/codesign --verify --deep --strict "$APP_PATH"
    }

    rollback() {
        log "Rolling back the application bundle."
        if [ -d "$BACKUP_APP" ]; then
            /bin/rm -rf "$APP_PATH" 2>/dev/null || true
            /bin/mv "$BACKUP_APP" "$APP_PATH" 2>/dev/null || true
        fi
        state "failed" \#(shellSingleQuoted(failed))
        if [ "$SHOULD_RELAUNCH" = "1" ] && [ -d "$APP_PATH" ]; then
            /usr/bin/open "$APP_PATH" 2>/dev/null || true
        fi
        exit 1
    }

    state "preparing" \#(shellSingleQuoted(preparing))
    [ -d "$STAGED_APP" ] || rollback
    [ -d "$APP_PATH" ] || rollback
    [ ! -e "$BACKUP_APP" ] || rollback
    [ -w "$APP_PATH" ] && [ -w "$APP_PARENT" ] || rollback
    wait_for_panel_exit || rollback

    /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
    # Снимаем ВСЕ процессы приложения, а не только службу. Dictor — это ещё и
    # окно, отдельный процесс; оно переживало подмену бандла, и тогда финальный
    # `open` не запускал ничего нового: macOS видел живое приложение с тем же
    # идентификатором и просто выводил его вперёд. Ставить службу обратно
    # оказывалось некому — обновление проходило, а диктовка исчезала.
    /usr/bin/pkill -f "$APP_PATH/Contents/MacOS/Dictor" >/dev/null 2>&1 || true
    /bin/sleep 1

    state "installing" \#(shellSingleQuoted(installing))
    /bin/mv "$APP_PATH" "$BACKUP_APP" || rollback
    /usr/bin/ditto "$STAGED_APP" "$APP_PATH" || rollback

    state "verifying" \#(shellSingleQuoted(verifying))
    verify_app || rollback

    /bin/rm -rf "$BACKUP_APP" || true
    state "relaunching" \#(shellSingleQuoted(relaunching))
    if [ "$SHOULD_RELAUNCH" = "1" ]; then
        /usr/bin/open "$APP_PATH" || rollback
        # Службу поднимаем сами, а не надеемся, что это сделает запущенное
        # приложение: диктовка — то, ради чего Dictor стоит на машине, и
        # обновление не имеет права её потерять. Если приложение поднимет
        # службу первым, bootstrap просто вернёт ошибку «уже загружена».
        if [ -f "$AGENT_PLIST" ]; then
            /bin/sleep 2
            /bin/launchctl bootstrap "gui/$(/usr/bin/id -u)" "$AGENT_PLIST" >/dev/null 2>&1 || true
        fi
    fi
    /bin/sleep 2
    state "complete" \#(shellSingleQuoted(complete))
    """#
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

func writePrivateUpdateHelperScript(_ script: String,
                                            directory: String = NSTemporaryDirectory(),
                                            fileName: String? = nil) throws -> String {
    guard !directory.isEmpty else { throw posixError(EINVAL) }
    let leafName = fileName ?? "dictor-update-\(UUID().uuidString).sh"
    guard !leafName.isEmpty,
          (leafName as NSString).lastPathComponent == leafName else {
        throw posixError(EINVAL)
    }

    let path = (directory as NSString).appendingPathComponent(leafName)
    let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(path, flags, PRIVATE_HELPER_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    var closed = false
    var removeOnFailure = true
    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_HELPER_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        try writeAllData(Data(script.utf8), to: fd)
        try validateSingleLinkRegularFileDescriptor(fd)

        let closeStatus = Darwin.close(fd)
        closed = true
        guard closeStatus == 0 else { throw currentPOSIXError() }

        removeOnFailure = false
        return path
    } catch {
        if !closed { _ = Darwin.close(fd) }
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

struct PrivateOutputFile {
    let path: String
    let handle: FileHandle
}

func openPrivateUpdateHelperLog(preferredPath: String = UPDATE_HELPER_LOG_PATH,
                                        fallbackDirectory: String = NSTemporaryDirectory()) throws -> PrivateOutputFile {
    do {
        let fd = try openPrivateOutputFileDescriptor(atPath: preferredPath,
                                                     exclusive: false,
                                                     removeOnFailure: false)
        return PrivateOutputFile(path: preferredPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    } catch {
        let fallbackPath = (fallbackDirectory as NSString)
            .appendingPathComponent("dictor-update-\(UUID().uuidString).log")
        let fd = try openPrivateOutputFileDescriptor(atPath: fallbackPath,
                                                     exclusive: true,
                                                     removeOnFailure: true)
        return PrivateOutputFile(path: fallbackPath,
                                 handle: FileHandle(fileDescriptor: fd, closeOnDealloc: true))
    }
}

func createPrivateUpdateProgressStateFile(directory: String = NSTemporaryDirectory()) throws -> String {
    let path = (directory as NSString)
        .appendingPathComponent("\(UPDATE_PROGRESS_APP_PREFIX)\(UUID().uuidString).state")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: true,
                                                 removeOnFailure: true)
    do {
        try writeAllData(Data("starting\tStarting update...\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
        return path
    } catch {
        _ = Darwin.close(fd)
        _ = Darwin.unlink(path)
        throw error
    }
}

func writePrivateUpdateProgressState(phase: String,
                                             message: String,
                                             to path: String) throws {
    let safePhase = phase.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let safeMessage = message.replacingOccurrences(of: "\t", with: " ")
        .replacingOccurrences(of: "\n", with: " ")
    let fd = try openPrivateOutputFileDescriptor(atPath: path,
                                                 exclusive: false,
                                                 removeOnFailure: false)
    do {
        try writeAllData(Data("\(safePhase)\t\(safeMessage)\n".utf8), to: fd)
        guard Darwin.close(fd) == 0 else { throw currentPOSIXError() }
    } catch {
        _ = Darwin.close(fd)
        throw error
    }
}

func openPrivateOutputFileDescriptor(atPath path: String,
                                             exclusive: Bool,
                                             removeOnFailure: Bool) throws -> Int32 {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)

    var flags = O_WRONLY | O_CREAT | O_NOFOLLOW
    if exclusive { flags |= O_EXCL }

    let fd = Darwin.open(path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }

    do {
        try validateSingleLinkRegularFileDescriptor(fd)
        guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
            throw currentPOSIXError()
        }
        guard Darwin.ftruncate(fd, 0) == 0 else {
            throw currentPOSIXError()
        }
        return fd
    } catch {
        _ = Darwin.close(fd)
        if removeOnFailure { _ = Darwin.unlink(path) }
        throw error
    }
}

