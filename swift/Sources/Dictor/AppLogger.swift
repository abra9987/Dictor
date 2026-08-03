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

// MARK: - Logger
//
// All output goes to stderr (line-buffered, so we don't lose lines
// across an abrupt exit) and to ~/Library/Logs/Dictor.log.

final class Logger: @unchecked Sendable {
    static let shared = Logger()
    private let url: URL
    private let q = DispatchQueue(label: "DictorLogger")

    var fileURL: URL { url }

    init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        url = logs.appendingPathComponent("Dictor.log")
    }

    func log(_ msg: String) {
        let stamp = ISO8601DateFormatter.timeOnly.string(from: Date())
        let line = "[\(stamp)] \(msg)\n"
        let data = Data(line.utf8)
        FileHandle.standardError.write(data)
        q.async { [url] in
            do {
                try appendPrivateLogData(data, to: url)
            } catch {
                let fallback = "Logger: file write failed: \(error.localizedDescription)\n"
                FileHandle.standardError.write(Data(fallback.utf8))
            }
        }
    }
}

func log(_ msg: String) { Logger.shared.log(msg) }

func dictorApplicationSupportDirectory() throws -> URL {
    let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(APP_SUPPORT_DIR_NAME, isDirectory: true)
    try FileManager.default.createDirectory(at: url,
                                            withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
    return url
}

struct AgentRuntimeState: Codable {
    var status: String
    var detail: String
    var updatedAt: TimeInterval
    var pid: Int32
    var isReady: Bool
    var isRecording: Bool
    var isTranscribing: Bool
    var speechModelReady: Bool
    var missingPermissions: [String]
    var hotkeyName: String
    var triggerMode: String
    var downloadProgressFraction: Double?
    // Ниже — то, что окно показывает человеку, пока служба ещё не готова.
    // Раньше публиковался только статус, и «Остановлена» выглядела одинаково
    // и когда всё сломано, и когда идёт обычный запуск.
    /// Сколько файлов модели уже проверено и сколько всего (21).
    var verifiedModelFiles: Int?
    var totalModelFiles: Int?
    /// Скачано файлов модели из общего числа. Байты FluidAudio не отдаёт,
    /// поэтому мегабайты не показываем — оценка, выданная за факт, хуже
    /// отсутствия числа.
    var downloadedModelFiles: Int?
    var totalDownloadModelFiles: Int?
    /// Медиана времени распознавания последних тридцати диктовок, мс.
    var medianLatencyMilliseconds: Int?
    /// Приложение сейчас заменяет само себя.
    var isUpdating: Bool?
    /// Версия бандла, из которого запущена служба. Нужна для случая, когда
    /// человек ставит новую версию сам — перетаскивает образ поверх старой:
    /// файлы заменяются, а работающий агент продолжает исполнять прежний код,
    /// и снаружи это «обновился, а ничего не изменилось».
    var appVersion: String?
    /// Выбранный микрофон отказал, захват идёт с системного входа. Имя
    /// отказавшего устройства — окно показывает его в строке «Микрофон»:
    /// иначе галочка у петлички при записи со встроенного — молчаливая ложь.
    var inputFallbackDeviceName: String?
}

enum AgentRuntimeStateStore {
    static var url: URL {
        (try? dictorApplicationSupportDirectory()
            .appendingPathComponent(AGENT_STATUS_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(AGENT_STATUS_FILE_NAME)
    }

    static func write(_ state: AgentRuntimeState) {
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            log("agent state write failed: \(error.localizedDescription)")
        }
    }

    static func read() -> AgentRuntimeState? {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(AgentRuntimeState.self, from: data)
        } catch {
            return nil
        }
    }
}

/// Куда службе ставить activation policy. Чистая: решение «показывать ли
/// значок в Dock» проверяется самотестом без UI. Значок показывается,
/// только когда тумблер включён И окно не запущено — окно `.regular` само,
/// и второй значок того же бандла читался бы как два приложения.
func dockActivationPolicy(showInDock: Bool,
                          panelRunning: Bool) -> NSApplication.ActivationPolicy {
    showInDock && !panelRunning ? .regular : .accessory
}

enum DictorControlPanelRegistry {
    static var url: URL {
        (try? dictorApplicationSupportDirectory()
            .appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)) ??
        FileManager.default.temporaryDirectory.appendingPathComponent(CONTROL_PANEL_PID_FILE_NAME)
    }

    @MainActor
    static func activateExistingPanelIfPresent() -> Bool {
        guard let pid = currentPanelPID() else {
            return false
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
            return true
        }
        return false
    }

    /// Живо ли окно — по pid-файлу, без активации. Нужно службе, чтобы
    /// решить, показывать ли свой значок в Dock.
    static func isPanelRunning() -> Bool {
        currentPanelPID() != nil
    }

    static func claimCurrentPanel() {
        do {
            try "\(getpid())\n".write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log("control panel pid write failed: \(error.localizedDescription)")
        }
    }

    static func clearCurrentPanel() {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid == getpid() else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func currentPanelPID() -> Int32? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let pid = Int32(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0,
              pid != getpid(),
              processIsAlive(pid: pid) else {
            return nil
        }
        return pid
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }
}

struct ProcessRunResult {
    let status: Int32
    let output: String
}

enum DictorAgentService {
    static var launchAgentURL: URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return directory.appendingPathComponent("\(AGENT_LABEL).plist")
    }

    static var launchDomain: String { "gui/\(getuid())" }
    static var launchService: String { "\(launchDomain)/\(AGENT_LABEL)" }

    static func agentExecutablePath() -> String {
        Bundle.main.executablePath ??
        "\(INSTALLED_APP_BUNDLE_PATH)/Contents/MacOS/Dictor"
    }

    static func installAndStart() throws {
        try writeLaunchAgentPlist()
        _ = runLaunchctl(["bootstrap", launchDomain, launchAgentURL.path])
        _ = runLaunchctl(["enable", launchService])
        let kick = runLaunchctl(["kickstart", "-k", launchService])
        if kick.status != 0 && !isAgentRunning() {
            throw NSError(domain: "DictorAgentService",
                          code: Int(kick.status),
                          userInfo: [NSLocalizedDescriptionKey: kick.output])
        }
    }

    static func restart() throws {
        stop()
        Thread.sleep(forTimeInterval: 0.35)
        try installAndStart()
    }

    static func stop() {
        _ = runLaunchctl(["bootout", launchDomain, launchAgentURL.path])
        terminateAgentProcesses()
        try? FileManager.default.removeItem(at: launchAgentURL)
        writeStoppedState()
    }

    /// Снять автозапуск, не трогая работающую службу. Настройка «Запускать
    /// диктовку в фоне» обещает ровно это: следующий вход в систему пройдёт
    /// без диктовки, а текущий сеанс остаётся каким был. Убрать хоткей
    /// сейчас — это пауза в панели меню-бара, отдельное действие.
    ///
    /// Механика: launchd читает plist один раз, при загрузке джоба. Удаление
    /// файла не выгружает уже загруженное — процесс живёт, — но при входе в
    /// систему загружать становится нечего.
    static func disableAutostart() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }
        try? FileManager.default.removeItem(at: launchAgentURL)
        log("launch agent: autostart removed, the running service is left alone")
    }

    static func isAgentRunning() -> Bool {
        if let state = AgentRuntimeStateStore.read(),
           state.pid > 0,
           state.pid != getpid(),
           processIsAlive(pid: state.pid) {
            return true
        }
        return !agentProcessIDs().isEmpty
    }

    static func agentProcessIDs() -> [Int32] {
        let result = run("/usr/bin/pgrep",
                         ["-f", "\(agentExecutablePath()) \(AGENT_ARGUMENT)"])
        guard result.status == 0 else { return [] }
        return result.output
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { $0 != getpid() }
    }

    private static func desiredPlistData() throws -> Data {
        let logPath = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Dictor-agent.launchd.log").path
        let plist: [String: Any] = [
            "Label": AGENT_LABEL,
            "ProgramArguments": [agentExecutablePath(), AGENT_ARGUMENT],
            "RunAtLoad": true,
            // Не голое `true`. С ним launchd поднимает агента после ЛЮБОГО
            // выхода, включая штатный «Quit Dictor» — приложение закрывалось
            // и через секунду возвращалось, и выйти из него было нельзя вообще
            // никак. `SuccessfulExit: false` оставляет перезапуск после падения
            // (ради этого служба и заведена) и уважает чистый выход с кодом 0.
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
            "StandardOutPath": logPath,
            "StandardErrorPath": logPath,
        ]
        return try PropertyListSerialization.data(fromPropertyList: plist,
                                                  format: .xml,
                                                  options: 0)
    }

    private static func writeLaunchAgentPlist() throws {
        let directory = launchAgentURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try desiredPlistData().write(to: launchAgentURL, options: [.atomic])
    }

    /// Обновляет plist, установленный прошлой версией. Уже загруженная в
    /// launchd конфигурация от этого не меняется — новая политика KeepAlive
    /// вступит в силу при следующей загрузке службы, а текущую сессию
    /// закрывает `stopForQuit()`.
    static func refreshInstalledPlistIfNeeded() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path),
              let desired = try? desiredPlistData(),
              let current = try? Data(contentsOf: launchAgentURL),
              current != desired else { return }
        guard (try? desired.write(to: launchAgentURL, options: [.atomic])) != nil else { return }
        log("launch agent: plist refreshed, new KeepAlive policy applies on next load")
    }

    /// Остановка службы из самого агента. `stop()` здесь не годится: он ждёт
    /// завершения `launchctl bootout`, а тот ждёт смерти нашего же процесса —
    /// главный поток встал бы намертво. Поэтому запрос уходит без ожидания,
    /// а вызывающий сразу завершает приложение.
    static func stopForQuit() {
        try? FileManager.default.removeItem(at: launchAgentURL)
        writeStoppedState()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["bootout", launchService]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()  // намеренно без waitUntilExit()
    }

    private static func terminateAgentProcesses() {
        for pid in agentProcessIDs() {
            kill(pid, SIGTERM)
        }
    }

    private static func processIsAlive(pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private static func writeStoppedState() {
        AgentRuntimeStateStore.write(
            AgentRuntimeState(status: "stopped",
                              detail: "Dictation service is stopped.",
                              updatedAt: Date().timeIntervalSince1970,
                              pid: 0,
                              isReady: false,
                              isRecording: false,
                              isTranscribing: false,
                              speechModelReady: false,
                              missingPermissions: [],
                              hotkeyName: Settings.shared.configuredHotkey.name,
                              triggerMode: Settings.shared.triggerMode.rawValue)
        )
    }

    private static func runLaunchctl(_ arguments: [String]) -> ProcessRunResult {
        run("/bin/launchctl", arguments)
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) -> ProcessRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ProcessRunResult(status: process.terminationStatus,
                                    output: String(data: data, encoding: .utf8) ?? "")
        } catch {
            return ProcessRunResult(status: 127, output: error.localizedDescription)
        }
    }
}

func privacySafeLogPath(_ path: String) -> String {
    privacySafeLogPath(URL(fileURLWithPath: path))
}

func privacySafeLogPath(_ url: URL) -> String {
    let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty || name == "/" ? "<local path>" : name
}

func privacySafeBundlePath(_ path: String) -> String {
    switch path {
    case "/Applications/Dictor.app", "/tmp/Dictor-dev.app":
        return path
    default:
        return privacySafeLogPath(path)
    }
}

let PRIVATE_LOG_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)
let PRIVATE_HELPER_FILE_MODE = mode_t(S_IRUSR | S_IWUSR)

func appendPrivateLogData(_ data: Data, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    let flags = O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NOFOLLOW
    let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
    guard fd >= 0 else { throw currentPOSIXError() }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
        throw currentPOSIXError()
    }

    try writeAllData(data, to: fd)
}

func validateSingleLinkRegularFileDescriptor(_ fd: Int32) throws {
    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else {
        throw currentPOSIXError()
    }
    guard (st.st_mode & S_IFMT) == S_IFREG else {
        throw posixError(EFTYPE)
    }
    guard st.st_nlink == 1 else {
        throw posixError(EMLINK)
    }
}

func writeAllData(_ data: Data, to fd: Int32) throws {
    try data.withUnsafeBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(fd,
                                       base.advanced(by: offset),
                                       rawBuffer.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                throw currentPOSIXError()
            }
            guard written > 0 else { throw POSIXError(.EIO) }
            offset += written
        }
    }
}

func currentPOSIXError() -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
}

func posixError(_ code: Int32) -> POSIXError {
    POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
}

extension ISO8601DateFormatter {
    static let timeOnly: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

