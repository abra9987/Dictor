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

// MARK: - Constants

let SAMPLE_RATE: Double = 16_000
let MAX_RECORDING_SECONDS: TimeInterval = 20 * 60   // auto-release if held longer
let PENDING_DICTATION_FILE_VERSION: UInt32 = 1
let PENDING_DICTATION_HEADER_SIZE = 16
let PENDING_DICTATION_MAX_SECONDS: TimeInterval = 30 * 60
let PENDING_DICTATION_MAX_BYTES = Int(PENDING_DICTATION_MAX_SECONDS * SAMPLE_RATE * 4) + PENDING_DICTATION_HEADER_SIZE
let DEFAULT_HOTKEY_KEYCODE: CGKeyCode = 54  // Right Command
let RIGHT_COMMAND_KEYCODE: CGKeyCode = 54
let LEFT_COMMAND_KEYCODE: CGKeyCode = 55
let RIGHT_OPTION_KEYCODE: CGKeyCode = 61
let FN_KEYCODE: CGKeyCode = 63
let ESCAPE_KEYCODE: CGKeyCode = 53
let RETURN_KEYCODE: CGKeyCode = 36
let MIN_CLIP_SECONDS: Double = 0.25
let UPDATE_CHECK_FIRST_DELAY_SECONDS: TimeInterval = 30
let UPDATE_CHECK_INTERVAL_SECONDS: TimeInterval = 6 * 3600  // 6h
let UPDATE_REMIND_LATER_SECONDS: TimeInterval = 24 * 3600  // 24h
// Канал обновлений. Исходники Dictor лежат в приватном репозитории, а
// ассеты приватного репозитория GitHub отдаёт только по токену — зашивать
// его в раздаваемое приложение значит раздать вместе с ним доступ к коду.
// Поэтому готовые файлы живут на своём хостинге, и в приложении нет никаких
// учётных данных.
let UPDATE_CHANNEL_PAGE = URL(string: "https://dictor.raulgumerov.com/")!
let UPDATE_MANIFEST_URL = URL(string: "https://dictor.raulgumerov.com/update.json")!

/// Адрес архива выводится из версии, а не берётся из манифеста: иначе
/// подменённый манифест мог бы увести загрузку на чужой хост.
func updateArchiveURL(forVersion version: String) -> URL {
    UPDATE_CHANNEL_PAGE.appendingPathComponent("Dictor-\(version).zip")
}
let UPDATE_ARCHIVE_MAX_BYTES = 64 * 1024 * 1024

/// Отпечаток сертификата, которым подписывается Dictor. Обновление ставится
/// только если новая сборка подписана именно им.
///
/// Без этого `codesign --verify` подтверждал лишь целостность бандла — что
/// подпись есть и совпадает с содержимым. Чья подпись, он не спрашивал, и
/// любая корректно подписанная сборка проходила проверку: кто угодно, кто
/// смог бы подсунуть файл по адресу обновлений, получил бы выполнение кода
/// на всех машинах.
///
/// Если сертификат «Dictor Dev» будет перевыпущен, значение надо обновить,
/// иначе обновления перестанут ставиться. `scripts/check.sh` сверяет его со
/// связкой ключей.
let UPDATE_SIGNING_CERT_SHA1 = "1FE86FCD948E9DCE5229E1C4E7B5B30FE3036C94"

/// Требование, которому обязана удовлетворять скачанная сборка.
var updateCodeRequirement: String {
    "=identifier \"com.raul.dictor\" and certificate leaf = H\"\(UPDATE_SIGNING_CERT_SHA1)\""
}
let INSTALLED_APP_BUNDLE_PATH = "/Applications/Dictor.app"
let AGENT_ARGUMENT = "--agent"
let AGENT_LABEL = "com.raul.dictor.agent"
let APP_SUPPORT_DIR_NAME = "Dictor"
let AGENT_STATUS_FILE_NAME = "AgentStatus.json"
let CONTROL_PANEL_PID_FILE_NAME = "ControlPanel.pid"
let UPDATE_HELPER_LOG_PATH = (NSHomeDirectory() as NSString)
    .appendingPathComponent("Library/Logs/Dictor-update.log")
let UPDATE_PROGRESS_ARGUMENT = "--update-progress"
let UPDATE_PROGRESS_APP_PREFIX = "Dictor-update-progress-"
let MAX_SKIPPED_UPDATE_VERSIONS = 20
let MAX_CORRECTION_SYNC_PATH_BYTES = 4096
let MAX_INPUT_DEVICE_PREFERENCE_BYTES = 512
let DIAGNOSTICS_LOG_MAX_BYTES = 128 * 1024
let DIAGNOSTICS_LOG_MAX_LINES = 40
/// Кому уходит «Сообщить о проблеме». Письмо открывается в почтовой
/// программе человека с уже приложенным архивом; отправляет его он сам.
let PROBLEM_REPORT_RECIPIENT = "gumerovraul@gmail.com"
let DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS = 4096
// История хранится «как в Wispr Flow»: архив практически не
// обрезается (10 000 записей ≈ годы диктовки, ~2 МБ JSON).
// Пользовательский лимит «Хранить историю» влияет только на видимый
// список в поповере/меню, не на архив.
let TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES = 10_000
let RECORDING_HUD_ANIMATE_IN_SECONDS: TimeInterval = 0.32
let RECORDING_HUD_ANIMATE_OUT_SECONDS: TimeInterval = 0.23
let RECORDING_HUD_TRANSCRIBING_MIN_VISIBLE_SECONDS: TimeInterval = 0.24
let RECORDING_HUD_TARGET_REFRESH_INTERVAL: TimeInterval = 0.16
let RECORDING_HUD_TARGET_FOLLOW_RESPONSE: CGFloat = 22
let RECORDING_HUD_TARGET_CACHE_MAX_AGE: TimeInterval = 10 * 60
let RECORDING_HUD_DISPLAY_LINK_MIN_FPS: Float = 60
let RECORDING_HUD_DISPLAY_LINK_MAX_FPS: Float = 120
let RECORDING_HUD_RECORDING_BASE_PHASE_SPEED: CGFloat = 16.96
let RECORDING_HUD_RECORDING_LEVEL_PHASE_SPEED: CGFloat = 10.08
let RECORDING_HUD_TRANSCRIBING_PHASE_SPEED: CGFloat = 10.2
let HOTKEY_CAPTURE_BEGIN_NOTIFICATION = Notification.Name("com.raul.dictor.hotkey-capture-begin")
let HOTKEY_CAPTURE_END_NOTIFICATION = Notification.Name("com.raul.dictor.hotkey-capture-end")
/// Поповер просит окно открыть конкретный раздел (макет 6a): «История»
/// и «Настройки» ведут в приложение, а не открывают ещё одно окно.
let CONTROL_PANEL_SECTION_NOTIFICATION = Notification.Name("com.raul.dictor.open-section")
let CONTROL_PANEL_SECTION_ARGUMENT = "--section"

/// «Выйти» в меню-баре закрывает и окно. Dictor — два процесса: служба с
/// иконкой в меню-баре и окно; выход из одного другого не касался, поэтому
/// после «Выйти» иконка пропадала, а приложение продолжало висеть на экране
/// и в Dock. Для человека это одно приложение, и выход должен быть один.
let CONTROL_PANEL_QUIT_NOTIFICATION = Notification.Name("com.raul.dictor.quit-panel")
let HOTKEY_CAPTURE_FAILSAFE_SECONDS: TimeInterval = 45
let DICTATION_ERROR_FLASH_SECONDS: TimeInterval = 1.5  // how long the menu-bar icon flags a dropped dictation before returning to idle
/// Сколько Enter после вставки готов ждать сверх настроенной задержки, пока
/// получатель заберёт текст из буфера. Не забрал — ⌘V не дошёл, и Enter
/// отправил бы поле, в которое ничего не вставилось.
let ENTER_AFTER_PASTE_READ_GRACE_SECONDS: TimeInterval = 1.0
/// Вспышка «текст не вставился» держится дольше обычной: в ней целая фраза о
/// том, где искать текст, а не один восклицательный знак.
let PASTE_NEVER_READ_FLASH_SECONDS: TimeInterval = 4.0
/// Потолок «Задержки перед Enter» — один для степпера в окне и для
/// нормализации в Settings. Пока это были два разных числа (2000 и 500),
/// степпер честно крутился до 2000, а настройка молча резалась до 500.
let ENTER_DELAY_MAX_MILLISECONDS = 2000
/// Запись шла не меньше этого, а звука не набралось и на минимальный клип —
/// значит, захват молчал (тап без данных, конвертер отверг буферы, микрофон
/// умер после старта). Короче — честное «чиркнул по хоткею», и оно тихое.
let CAPTURE_FAILURE_MIN_RECORDING_SECONDS: TimeInterval = 2.0
let AUDIO_START_RETRY_DELAYS_SECONDS: [UInt64] = [1, 3, 8]
let AUDIO_IDLE_STOP_DELAY_SECONDS: TimeInterval = 5
let AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS: TimeInterval = 1
let MODEL_DOWNLOAD_HEADROOM_BYTES: Int64 = 500 * 1024 * 1024
/// Сколько тишины после последней диктовки нужно, чтобы служба перешла на
/// скачанную в фоне модель. Между фразами одной мысли проходят секунды, между
/// делами — минуты; две минуты отделяют одно от другого с запасом.
let SPEECH_MODEL_SWITCH_QUIET_SECONDS: TimeInterval = 120

let SETTINGS_SUITE = "com.raul.dictor"
let CORRECTIONS_FILE_UTI = "com.raul.dictor.corrections"
let CORRECTIONS_FILE_EXTENSION = "dictor-corrections"
let CORRECTIONS_FILE_NAME = "Dictor Corrections.\(CORRECTIONS_FILE_EXTENSION)"
let MAX_TRANSCRIPT_CORRECTIONS = 512
let MAX_TRANSCRIPT_CORRECTION_SOURCE_BYTES = 512
let MAX_TRANSCRIPT_CORRECTION_REPLACEMENT_BYTES = 4096

/// Visible state of the menu-bar item. Idle/loading/busy use the
/// template image so macOS handles light/dark menu bars. Recording and
/// error states use pre-tinted static frames so the state remains
/// visible even when macOS ignores contentTintColor on template images.
enum MenuBarState {
    case loading
    case idle
    case recording
    case busy
    case error
    /// Диктовка выключена тумблером поповера: линия с разрывом, 40%.
    case paused
}

enum RecordingHUDMode: Equatable {
    case recording
    case transcribing
    /// Подтверждение вставки: галочка + «Вставлено · N слов»,
    /// держится SD.Anim.insertedHoldSeconds и растворяется.
    case inserted
    /// Brief flash shown when a dictation fails (transcription error,
    /// paste failure). Renders a static coral flat-line capsule so the
    /// user gets visual feedback even when the menu-bar icon is hidden.
    case error
}

enum RecentTranscriptLimit: String, CaseIterable {
    case off
    case last1 = "1"
    case last5 = "5"
    case last10 = "10"

    var count: Int {
        switch self {
        case .off: return 0
        case .last1: return 1
        case .last5: return 5
        case .last10: return 10
        }
    }
}

let DEFAULT_RECENT_TRANSCRIPT_LIMIT = RecentTranscriptLimit.last10
let RECENT_TRANSCRIPT_LIMIT_DISPLAY: [RecentTranscriptLimit: String] = [
    .off: "Off",
    .last1: "Last 1",
    .last5: "Last 5",
    .last10: "Last 10",
]

enum RecordingHUDAccentColor: String, CaseIterable {
    case coral
    case graphite
    case red
    case orange
    case pink
    case purple
    case blue
    case cyan
    case green
    case white

    var displayName: String {
        switch self {
        case .coral: return "Coral"
        case .graphite: return "Graphite"
        case .red: return "Red"
        case .orange: return "Orange"
        case .pink: return "Pink"
        case .purple: return "Purple"
        case .blue: return "Blue"
        case .cyan: return "Cyan"
        case .green: return "Green"
        case .white: return "White"
        }
    }

    var nsColor: NSColor {
        switch self {
        case .coral: return SD.C.voiceDark
        case .graphite: return NSColor(hex: 0xA3A09A)
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .pink: return .systemPink
        case .purple: return .systemPurple
        case .blue: return NSColor(calibratedRed: 0.0, green: 0.44, blue: 1.0, alpha: 1)
        case .cyan: return .systemCyan
        case .green: return .systemGreen
        case .white: return .white
        }
    }
}

/// Где показывать капсулу во время диктовки. Макет 6d предлагал ещё и
/// перетаскивание мышью — оно требует постоянно живой капсулы (макет
/// 6c), которой пока нет: капсула существует только пока идёт диктовка.
enum RecordingHUDPlacement: String, CaseIterable {
    /// Над полем ввода, куда попадёт текст; если поле не нашлось —
    /// внутри активного окна, иначе сверху по центру экрана.
    case followsInput
    /// Всегда снизу по центру экрана с курсором.
    case bottomCenter
    /// Всегда сверху по центру — там же, где капсула появлялась раньше,
    /// когда поле ввода определить не удавалось.
    case topCenter
}

enum RecordingHUDSize: String, CaseIterable {
    case compact
    case standard
    case large

    var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .standard: return "Standard"
        case .large: return "Large"
        }
    }

    var visualScale: CGFloat {
        switch self {
        case .compact: return 1.0
        case .standard: return 1.3
        case .large: return 1.55
        }
    }

    /// Высота пилюли по дизайну 1c: 26 / 36 / 44 pt. Ширина — под
    /// контент самого длинного состояния (волна + таймер + подсказка);
    /// панель добавляет поля под тень.
    var capsuleHeight: CGFloat {
        switch self {
        case .compact: return 26
        case .standard: return 36
        case .large: return 44
        }
    }

    var expandedSize: NSSize {
        switch self {
        case .compact: return NSSize(width: 128, height: 42)
        case .standard: return NSSize(width: 248, height: 56)
        case .large: return NSSize(width: 292, height: 66)
        }
    }
}

enum RecordingHUDBackgroundStyle: String, CaseIterable {
    case system
    case dark
    case light

    var displayName: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }
}

func parseRecentTranscriptLimit(storedValue value: Any?) -> RecentTranscriptLimit? {
    if let raw = value as? String {
        return RecentTranscriptLimit(rawValue: raw)
    }
    if let number = value as? NSNumber {
        return RecentTranscriptLimit(rawValue: number.stringValue)
    }
    return nil
}

func normalizedStoredAppVersion(_ value: String) -> String? {
    UpdateCheck.normalizedReleaseVersion(from: value)
}

func normalizedSkippedUpdateVersions(_ values: [String]) -> [String] {
    var result: [String] = []
    var seen = Set<String>()

    for value in values.reversed() {
        guard let version = UpdateCheck.normalizedReleaseVersion(from: value),
              !seen.contains(version) else {
            continue
        }
        seen.insert(version)
        result.append(version)
        if result.count == MAX_SKIPPED_UPDATE_VERSIONS { break }
    }

    return result.reversed()
}

enum UpdateCheckSource: String, Equatable {
    case automatic
    case manual
    /// Check fired because the user re-enabled automatic update checks
    /// in the settings menu — user-initiated like .manual but silent like
    /// .automatic, so diagnostics record it as its own source.
    case settingsToggle = "settings_toggle"

    var diagnosticLabel: String {
        switch self {
        case .automatic: return "automatic"
        case .manual: return "manual"
        case .settingsToggle: return "settings toggle"
        }
    }
}

enum UpdateCheckResult: String, Equatable {
    case failed = "failed"
    case upToDate = "up_to_date"
    case available = "available"
    case skipped = "skipped"

    var diagnosticLabel: String {
        switch self {
        case .failed: return "failed or unavailable"
        case .upToDate: return "up to date"
        case .available: return "update available"
        case .skipped: return "skipped version available"
        }
    }
}

func updateCheckResult(for release: DictorRelease?,
                       currentVersion: String,
                       skippedVersions: [String]) -> UpdateCheckResult {
    guard let release else { return .failed }
    guard isNewer(release.version, than: currentVersion) else { return .upToDate }
    return skippedVersions.contains(release.version) ? .skipped : .available
}

func shouldSuppressUpdateForReminder(version: String,
                                     reminderVersion: String?,
                                     reminderUntil: Date?,
                                     now: Date) -> Bool {
    guard let reminderVersion,
          let reminderUntil,
          reminderVersion == version else {
        return false
    }
    return now < reminderUntil
}

/// True when a fetched release makes a stored "Remind me later" pause
/// stale: either the pause expired for the same version (it is about
/// to be re-shown), or a NEWER release superseded the paused one.
/// Without the newer-version case, pausing v0.3.0 and seeing v0.3.1
/// ship within 24 h left diagnostics showing both "Pending update:
/// v0.3.1" and "Reminder paused: v0.3.0 until …". An OLDER fetched
/// version (e.g. a retracted release) keeps the pause.
func shouldClearUpdateReminderPause(fetchedVersion: String, pausedVersion: String?) -> Bool {
    guard let pausedVersion else { return false }
    return fetchedVersion == pausedVersion || isNewer(fetchedVersion, than: pausedVersion)
}

/// Validates a persisted "Remind me later" expiry read back from
/// UserDefaults. Non-Date values and dates further in the future than
/// one full pause window are treated as corrupt and degrade to nil,
/// so a tampered or clock-skewed value re-arms the reminder instead
/// of suppressing updates indefinitely. Past dates pass through —
/// an expired pause is legitimate state that the suppress logic and
/// `shouldClearUpdateReminderPause` handle.
func normalizedUpdateReminderPauseExpiry(storedValue value: Any?,
                                         now: Date = Date(),
                                         maxPauseSeconds: TimeInterval = UPDATE_REMIND_LATER_SECONDS) -> Date? {
    guard let date = value as? Date else { return nil }
    guard date.timeIntervalSince(now) <= maxPauseSeconds else { return nil }
    return date
}

func updateCheckDiagnosticText(checkedAt: Date?,
                               source: UpdateCheckSource?,
                               result: UpdateCheckResult?,
                               releaseVersion: String) -> String {
    guard let checkedAt else { return "never" }
    let timestamp = ISO8601DateFormatter().string(from: checkedAt)
    let sourceText = source?.diagnosticLabel ?? "unknown source"
    let resultText = result?.diagnosticLabel ?? "unknown result"
    let versionText = releaseVersion.isEmpty ? "" : " (latest v\(releaseVersion))"
    return "\(timestamp), \(sourceText), \(resultText)\(versionText)"
}

struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

let CORE_AUDIO_DEFAULT_AGGREGATE_PREFIX = "CADefaultDeviceAggregate-"

struct TranscriptCorrection: Codable, Equatable, Sendable {
    let source: String
    let replacement: String
}

