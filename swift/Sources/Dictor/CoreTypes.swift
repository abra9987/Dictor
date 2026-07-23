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
let RIGHT_SHIFT_KEYCODE: CGKeyCode = 60
let FN_KEYCODE: CGKeyCode = 63
let ESCAPE_KEYCODE: CGKeyCode = 53
let RETURN_KEYCODE: CGKeyCode = 36
let ENTER_AFTER_INSERT_DELAY_NANOSECONDS: UInt64 = 120_000_000
let MIN_CLIP_SECONDS: Double = 0.25
let UPDATE_CHECK_FIRST_DELAY_SECONDS: TimeInterval = 30
let UPDATE_CHECK_INTERVAL_SECONDS: TimeInterval = 6 * 3600  // 6h
let UPDATE_REMIND_LATER_SECONDS: TimeInterval = 24 * 3600  // 24h
let GITHUB_LATEST_RELEASE_URL = URL(string: "https://api.github.com/repos/shlgd/Dictor/releases/latest")!
let GITHUB_REPOSITORY_PAGE = URL(string: "https://github.com/shlgd/Dictor")!
let GITHUB_RELEASES_PAGE = URL(string: "https://github.com/shlgd/Dictor/releases/latest")!
let GITHUB_UPDATE_MANIFEST_URL = URL(string: "https://raw.githubusercontent.com/shlgd/Dictor/main/update.json")!
let UPDATE_ARCHIVE_MAX_BYTES = 64 * 1024 * 1024
let HOMEBREW_CASK_TAP = "shlgd/dictor"
let HOMEBREW_CASK_TOKEN = "shlgd/dictor/dictor"
let HOMEBREW_CASK_INSTALLED_TOKEN = "dictor"
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
let DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS = 4096
let TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES = 100
let RECORDING_HUD_BASE_SIZE = NSSize(width: 64, height: 38)
let RECORDING_HUD_ANIMATE_IN_SECONDS: TimeInterval = 0.32
let RECORDING_HUD_ANIMATE_OUT_SECONDS: TimeInterval = 0.23
let RECORDING_HUD_TRANSCRIBING_RESOLVE_SECONDS: TimeInterval = 0.20
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
let HOTKEY_CAPTURE_FAILSAFE_SECONDS: TimeInterval = 45
let DICTATION_ERROR_FLASH_SECONDS: TimeInterval = 1.5  // how long the menu-bar icon flags a dropped dictation before returning to idle
let AUDIO_START_RETRY_DELAYS_SECONDS: [UInt64] = [1, 3, 8]
let AUDIO_IDLE_STOP_DELAY_SECONDS: TimeInterval = 5
let AUDIO_CONFIGURATION_CHANGE_SUPPRESSION_SECONDS: TimeInterval = 1
let MODEL_DOWNLOAD_HEADROOM_BYTES: Int64 = 500 * 1024 * 1024

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

/// A global dictation shortcut: either one modifier key or a regular
/// keyboard key with an optional Control/Option/Shift/Command chord.
struct HotkeyChoice: Equatable {
    let name: String
    let keycode: CGKeyCode
    let isModifier: Bool
    /// Which CGEventFlags mask bit fires for this modifier (nil for non-modifiers).
    let modifierFlag: CGEventFlags?
    /// Modifier keys required alongside a non-modifier key.
    let requiredModifiers: CGEventFlags

    init(name: String,
         keycode: CGKeyCode,
         isModifier: Bool,
         modifierFlag: CGEventFlags?,
         requiredModifiers: CGEventFlags = []) {
        self.name = name
        self.keycode = keycode
        self.isModifier = isModifier
        self.modifierFlag = modifierFlag
        self.requiredModifiers = requiredModifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    }
}

let HOTKEY_SHORTCUT_MODIFIER_MASK: CGEventFlags = [
    .maskControl,
    .maskAlternate,
    .maskShift,
    .maskCommand,
    .maskSecondaryFn,
]

let MODIFIER_HOTKEY_CHOICES: [HotkeyChoice] = [
    HotkeyChoice(name: "Left Control", keycode: 59, isModifier: true, modifierFlag: .maskControl),
    HotkeyChoice(name: "Right Control", keycode: 62, isModifier: true, modifierFlag: .maskControl),
    HotkeyChoice(name: "Left Option", keycode: 58, isModifier: true, modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Right Option", keycode: 61, isModifier: true, modifierFlag: .maskAlternate),
    HotkeyChoice(name: "Left Shift", keycode: 56, isModifier: true, modifierFlag: .maskShift),
    HotkeyChoice(name: "Right Shift", keycode: 60, isModifier: true, modifierFlag: .maskShift),
    HotkeyChoice(name: "Left Command", keycode: 55, isModifier: true, modifierFlag: .maskCommand),
    HotkeyChoice(name: "Right Command", keycode: 54, isModifier: true, modifierFlag: .maskCommand),
    HotkeyChoice(name: "Fn", keycode: FN_KEYCODE, isModifier: true, modifierFlag: .maskSecondaryFn),
]

let FUNCTION_KEY_NAMES_BY_KEYCODE: [CGKeyCode: String] = [
    122: "F1",
    120: "F2",
    99: "F3",
    118: "F4",
    96: "F5",
    97: "F6",
    98: "F7",
    100: "F8",
    101: "F9",
    109: "F10",
    103: "F11",
    111: "F12",
    105: "F13",
    107: "F14",
    113: "F15",
    106: "F16",
    64: "F17",
    79: "F18",
    80: "F19",
    90: "F20",
]

let HOTKEY_CHOICES: [HotkeyChoice] = [
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 62 })!,
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 61 })!,
    MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == 54 })!,
    HotkeyChoice(name: "F5",            keycode: 96,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F6",            keycode: 97,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F13",           keycode: 105, isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F18",           keycode: 79,  isModifier: false, modifierFlag: nil),
    HotkeyChoice(name: "F19",           keycode: 80,  isModifier: false, modifierFlag: nil),
]

let HOTKEY_KEY_NAMES_BY_KEYCODE: [CGKeyCode: String] = [
    0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
    11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T", 18: "1", 19: "2",
    20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8",
    29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "Return",
    37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N",
    46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
    65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 71: "Clear", 75: "Keypad /",
    76: "Enter", 78: "Keypad -", 81: "Keypad =", 82: "Keypad 0", 83: "Keypad 1",
    84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5", 88: "Keypad 6",
    89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9", 114: "Help", 115: "Home",
    116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down", 123: "Left Arrow",
    124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow",
]

func hotkeyKeyName(for keycode: CGKeyCode) -> String {
    FUNCTION_KEY_NAMES_BY_KEYCODE[keycode]
        ?? HOTKEY_KEY_NAMES_BY_KEYCODE[keycode]
        ?? "Key \(keycode)"
}

func hotkeyModifierSymbols(_ flags: CGEventFlags) -> String {
    var result = ""
    if flags.contains(.maskControl) { result += "⌃" }
    if flags.contains(.maskAlternate) { result += "⌥" }
    if flags.contains(.maskShift) { result += "⇧" }
    if flags.contains(.maskCommand) { result += "⌘" }
    if flags.contains(.maskSecondaryFn) { result += "fn" }
    return result
}

func modifierHotkeyName(primary: HotkeyChoice,
                                requiredModifiers: CGEventFlags) -> String {
    var parts: [String] = []
    if requiredModifiers.contains(.maskControl) { parts.append("Control") }
    if requiredModifiers.contains(.maskAlternate) { parts.append("Option") }
    if requiredModifiers.contains(.maskShift) { parts.append("Shift") }
    if requiredModifiers.contains(.maskCommand) { parts.append("Command") }
    if requiredModifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
    parts.append(primary.name)
    return parts.joined(separator: " + ")
}

func recordableHotkeyChoice(forKeycode keycode: CGKeyCode,
                            modifiers: CGEventFlags = []) -> HotkeyChoice? {
    let normalizedModifiers = modifiers.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    if let choice = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == keycode }) {
        let requiredModifiers = choice.modifierFlag.map {
            normalizedModifiers.subtracting($0)
        } ?? normalizedModifiers
        return HotkeyChoice(name: modifierHotkeyName(primary: choice,
                                                     requiredModifiers: requiredModifiers),
                            keycode: choice.keycode,
                            isModifier: true,
                            modifierFlag: choice.modifierFlag,
                            requiredModifiers: requiredModifiers)
    }
    guard keycode <= 255, keycode != ESCAPE_KEYCODE else { return nil }
    let name = hotkeyModifierSymbols(normalizedModifiers) + hotkeyKeyName(for: keycode)
    return HotkeyChoice(name: name,
                        keycode: keycode,
                        isModifier: false,
                        modifierFlag: nil,
                        requiredModifiers: normalizedModifiers)
}

func hotkeyChoice(forKeycode keycode: CGKeyCode,
                  modifiers: CGEventFlags = []) -> HotkeyChoice {
    recordableHotkeyChoice(forKeycode: keycode, modifiers: modifiers)
        ?? HOTKEY_CHOICES.first(where: { $0.keycode == DEFAULT_HOTKEY_KEYCODE })!
}

func normalizedHotkeyKeycode(storedValue value: Any?) -> CGKeyCode? {
    let raw: Int?
    if let number = value as? NSNumber {
        raw = number.intValue
    } else if let string = value as? String {
        raw = Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
    } else {
        raw = nil
    }

    guard let raw,
          raw >= 0,
          raw <= Int(CGKeyCode.max),
          recordableHotkeyChoice(forKeycode: CGKeyCode(raw)) != nil else {
        return nil
    }
    return CGKeyCode(raw)
}

enum TriggerMode: String { case hold, toggle }
let TRIGGER_DISPLAY: [TriggerMode: String] = [
    .hold: "Press and hold",
    .toggle: "Press to toggle",
]

enum DictationCompletionBehavior: String, CaseIterable {
    case insert
    case insertAndEnter

    var opposite: DictationCompletionBehavior {
        self == .insert ? .insertAndEnter : .insert
    }

    var pressesEnter: Bool { self == .insertAndEnter }
}

func localizedHotkeyName(_ choice: HotkeyChoice,
                         language: InterfaceLanguage) -> String {
    guard language == .russian else { return choice.name }
    if choice.isModifier {
        let primary: String
        switch choice.keycode {
        case 59: primary = "Левый Control"
        case 62: primary = "Правый Control"
        case 58: primary = "Левый Option"
        case 61: primary = "Правый Option"
        case 56: primary = "Левый Shift"
        case 60: primary = "Правый Shift"
        case 55: primary = "Левый Command"
        case 54: primary = "Правый Command"
        case FN_KEYCODE: primary = "Fn"
        default: primary = choice.name
        }
        var parts: [String] = []
        if choice.requiredModifiers.contains(.maskControl) { parts.append("Control") }
        if choice.requiredModifiers.contains(.maskAlternate) { parts.append("Option") }
        if choice.requiredModifiers.contains(.maskShift) { parts.append("Shift") }
        if choice.requiredModifiers.contains(.maskCommand) { parts.append("Command") }
        if choice.requiredModifiers.contains(.maskSecondaryFn) { parts.append("Fn") }
        parts.append(primary)
        return parts.joined(separator: " + ")
    }

    let keyName: String
    switch choice.keycode {
    case 36: keyName = "Return"
    case 48: keyName = "Tab"
    case 49: keyName = "Пробел"
    case 51: keyName = "Delete"
    case 76: keyName = "Enter"
    case 115: keyName = "Home"
    case 116: keyName = "Page Up"
    case 117: keyName = "Forward Delete"
    case 119: keyName = "End"
    case 121: keyName = "Page Down"
    case 123: keyName = "Стрелка влево"
    case 124: keyName = "Стрелка вправо"
    case 125: keyName = "Стрелка вниз"
    case 126: keyName = "Стрелка вверх"
    default: keyName = hotkeyKeyName(for: choice.keycode)
    }
    return hotkeyModifierSymbols(choice.requiredModifiers) + keyName
}

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
    case multilingualV3 = "multilingual_v3"
    // Deprecated production option. Kept only so old saved preferences
    // can be read and migrated back to the supported v3 model.
    case englishUnified = "english_unified"

    static let productionDefault: SpeechModelProfile = .multilingualV3

    var isProductionSupported: Bool {
        self == .multilingualV3
    }

    var productionProfile: SpeechModelProfile {
        isProductionSupported ? self : Self.productionDefault
    }

    var displayName: String {
        switch self {
        case .multilingualV3:
            return "Multilingual (Parakeet TDT v3)"
        case .englishUnified:
            return "English optimized (Parakeet Unified, deprecated)"
        }
    }

    var shortName: String {
        switch self {
        case .multilingualV3:
            return "Parakeet TDT v3"
        case .englishUnified:
            return "Parakeet Unified"
        }
    }

    var aboutModelText: String {
        switch self {
        case .multilingualV3:
            return "FluidAudio · Parakeet TDT v3 multilingual (CoreML / ANE)"
        case .englishUnified:
            return "FluidAudio · Parakeet Unified English (deprecated)"
        }
    }

    var setupReadyDetail: String {
        "\(shortName) is loaded locally."
    }

    var cacheResetDetail: String {
        switch self {
        case .multilingualV3:
            return "Dictor will delete the local Parakeet TDT v3 model cache, unload the current speech model, and download a fresh verified copy before dictation is available again."
        case .englishUnified:
            return "Dictor will delete the local Parakeet TDT v3 model cache, unload the current speech model, and download a fresh verified copy before dictation is available again."
        }
    }

    var estimatedDownloadBytes: Int64 {
        700 * 1024 * 1024
    }

    var downloadSizeText: String {
        "about 500-700 MB"
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

func limitedRecentTranscripts(_ transcripts: [String], limit: RecentTranscriptLimit) -> [String] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard transcripts.count > count else { return transcripts }
    return Array(transcripts.prefix(count))
}

struct ASRTimingBreakdown: Codable, Equatable, Sendable {
    let totalSeconds: Double
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    init(totalSeconds: Double,
         workerQueueSeconds: Double,
         decoderPreparationSeconds: Double,
         fluidCallSeconds: Double,
         fluidProcessingSeconds: Double) {
        self.totalSeconds = max(0, totalSeconds.isFinite ? totalSeconds : 0)
        self.workerQueueSeconds = max(0, workerQueueSeconds.isFinite ? workerQueueSeconds : 0)
        self.decoderPreparationSeconds = max(0, decoderPreparationSeconds.isFinite ? decoderPreparationSeconds : 0)
        self.fluidCallSeconds = max(0, fluidCallSeconds.isFinite ? fluidCallSeconds : 0)
        self.fluidProcessingSeconds = max(0, fluidProcessingSeconds.isFinite ? fluidProcessingSeconds : 0)
    }

    var frameworkOverheadSeconds: Double {
        max(0, totalSeconds - workerQueueSeconds - decoderPreparationSeconds - fluidProcessingSeconds)
    }
}

struct TranscriptHistoryEntry: Codable, Equatable {
    let text: String
    let transcriptionDurationSeconds: Double?
    let asrTiming: ASRTimingBreakdown?

    init(text: String,
         transcriptionDurationSeconds: Double? = nil,
         asrTiming: ASRTimingBreakdown? = nil) {
        self.text = text
        if let duration = transcriptionDurationSeconds,
           duration.isFinite,
           duration >= 0 {
            self.transcriptionDurationSeconds = duration
        } else {
            self.transcriptionDurationSeconds = nil
        }
        self.asrTiming = asrTiming
    }
}

func limitedRecentTranscriptEntries(_ entries: [TranscriptHistoryEntry],
                                    limit: RecentTranscriptLimit) -> [TranscriptHistoryEntry] {
    let count = limit.count
    guard count > 0 else { return [] }
    guard entries.count > count else { return entries }
    return Array(entries.prefix(count))
}

func limitedTranscriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                                     maximumCount: Int = TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES) -> [TranscriptHistoryEntry] {
    guard maximumCount > 0 else { return [] }
    guard entries.count > maximumCount else { return entries }
    return Array(entries.prefix(maximumCount))
}

func transcriptHistoryArchive(_ entries: [TranscriptHistoryEntry],
                              removing index: Int) -> [TranscriptHistoryEntry] {
    guard entries.indices.contains(index) else { return entries }
    var next = entries
    next.remove(at: index)
    return next
}

let DICTATION_USAGE_MAX_DAYS = 400

struct DailyDictationUsage: Codable, Equatable {
    let day: String
    var dictationCount: Int
    var characterCount: Int
    var audioSeconds: Double
    var asrSeconds: Double

    init(day: String,
         dictationCount: Int = 0,
         characterCount: Int = 0,
         audioSeconds: Double = 0,
         asrSeconds: Double = 0) {
        self.day = day
        self.dictationCount = max(0, dictationCount)
        self.characterCount = max(0, characterCount)
        self.audioSeconds = max(0, audioSeconds.isFinite ? audioSeconds : 0)
        self.asrSeconds = max(0, asrSeconds.isFinite ? asrSeconds : 0)
    }

    mutating func add(dictations: Int,
                      characters: Int,
                      audio: Double,
                      asr: Double) {
        dictationCount += max(0, dictations)
        characterCount += max(0, characters)
        audioSeconds += max(0, audio.isFinite ? audio : 0)
        asrSeconds += max(0, asr.isFinite ? asr : 0)
    }
}

struct DictationUsageDaySlot: Equatable {
    let date: Date
    let usage: DailyDictationUsage
}

struct DictationUsageWeekSnapshot: Equatable {
    let days: [DictationUsageDaySlot]

    var totalDictations: Int { days.reduce(0) { $0 + $1.usage.dictationCount } }
    var totalCharacters: Int { days.reduce(0) { $0 + $1.usage.characterCount } }
    var totalAudioSeconds: Double { days.reduce(0) { $0 + $1.usage.audioSeconds } }
    var totalASRSeconds: Double { days.reduce(0) { $0 + $1.usage.asrSeconds } }
    var averageASRSeconds: Double {
        totalDictations > 0 ? totalASRSeconds / Double(totalDictations) : 0
    }
    var averageCharactersPerDictation: Double {
        totalDictations > 0 ? Double(totalCharacters) / Double(totalDictations) : 0
    }
    var realtimeSpeedRatio: Double {
        totalASRSeconds > 0 ? totalAudioSeconds / totalASRSeconds : 0
    }
}

func dictationUsageDayKey(for date: Date, calendar: Calendar) -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d",
                  components.year ?? 0,
                  components.month ?? 0,
                  components.day ?? 0)
}

func mergedDailyDictationUsage(_ stats: [DailyDictationUsage],
                               maximumDays: Int = DICTATION_USAGE_MAX_DAYS) -> [DailyDictationUsage] {
    guard maximumDays > 0 else { return [] }
    var byDay: [String: DailyDictationUsage] = [:]
    for stat in stats where !stat.day.isEmpty {
        var combined = byDay[stat.day] ?? DailyDictationUsage(day: stat.day)
        combined.add(dictations: stat.dictationCount,
                     characters: stat.characterCount,
                     audio: stat.audioSeconds,
                     asr: stat.asrSeconds)
        byDay[stat.day] = combined
    }
    return Array(byDay.values.sorted { $0.day < $1.day }.suffix(maximumDays))
}

func addingDictationUsageSample(to stats: [DailyDictationUsage],
                                at date: Date,
                                characterCount: Int,
                                audioSeconds: Double,
                                asrSeconds: Double,
                                calendar: Calendar) -> [DailyDictationUsage] {
    guard characterCount > 0 else { return stats }
    let day = dictationUsageDayKey(for: date, calendar: calendar)
    var next = stats
    if let index = next.firstIndex(where: { $0.day == day }) {
        next[index].add(dictations: 1,
                        characters: characterCount,
                        audio: audioSeconds,
                        asr: asrSeconds)
    } else {
        next.append(DailyDictationUsage(day: day,
                                        dictationCount: 1,
                                        characterCount: characterCount,
                                        audioSeconds: audioSeconds,
                                        asrSeconds: asrSeconds))
    }
    return mergedDailyDictationUsage(next)
}

func lastSevenCompletedDictationUsage(_ stats: [DailyDictationUsage],
                                      referenceDate: Date,
                                      calendar: Calendar) -> DictationUsageWeekSnapshot {
    let byDay = Dictionary(uniqueKeysWithValues: mergedDailyDictationUsage(stats).map { ($0.day, $0) })
    let today = calendar.startOfDay(for: referenceDate)
    let days = (1...7).reversed().compactMap { offset -> DictationUsageDaySlot? in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let key = dictationUsageDayKey(for: date, calendar: calendar)
        return DictationUsageDaySlot(date: date,
                                     usage: byDay[key] ?? DailyDictationUsage(day: key))
    }
    return DictationUsageWeekSnapshot(days: days)
}

func importedDailyDictationUsage(from logText: String,
                                 fileCreatedAt: Date,
                                 calendar: Calendar) -> [DailyDictationUsage] {
    let pattern = #"^\[(\d{2}):(\d{2}):(\d{2})\]\s+([0-9]+(?:\.[0-9]+)?) s audio → ([0-9]+(?:\.[0-9]+)?) s → (\d+) chars"#
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }

    var currentDay = calendar.startOfDay(for: fileCreatedAt)
    var previousSecondsOfDay: Int?
    var stats: [DailyDictationUsage] = []

    for lineSlice in logText.split(separator: "\n", omittingEmptySubsequences: true) {
        let line = String(lineSlice)
        let fullRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = expression.firstMatch(in: line, range: fullRange) else {
            if line.count >= 10,
               line.first == "[",
               let hour = Int(line.dropFirst(1).prefix(2)),
               let minute = Int(line.dropFirst(4).prefix(2)),
               let second = Int(line.dropFirst(7).prefix(2)) {
                let secondsOfDay = (hour * 3_600) + (minute * 60) + second
                if let previousSecondsOfDay, secondsOfDay < previousSecondsOfDay,
                   let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) {
                    currentDay = nextDay
                }
                previousSecondsOfDay = secondsOfDay
            }
            continue
        }

        func capture(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else { return nil }
            return String(line[range])
        }
        guard let hour = capture(1).flatMap(Int.init),
              let minute = capture(2).flatMap(Int.init),
              let second = capture(3).flatMap(Int.init),
              let audio = capture(4).flatMap(Double.init),
              let asr = capture(5).flatMap(Double.init),
              let characters = capture(6).flatMap(Int.init) else {
            continue
        }

        let secondsOfDay = (hour * 3_600) + (minute * 60) + second
        if let previousSecondsOfDay, secondsOfDay < previousSecondsOfDay,
           let nextDay = calendar.date(byAdding: .day, value: 1, to: currentDay) {
            currentDay = nextDay
        }
        previousSecondsOfDay = secondsOfDay
        stats = addingDictationUsageSample(to: stats,
                                           at: currentDay,
                                           characterCount: characters,
                                           audioSeconds: audio,
                                           asrSeconds: asr,
                                           calendar: calendar)
    }
    return stats
}

func transcriptionDurationLabel(_ duration: Double?) -> String {
    guard let duration, duration.isFinite, duration >= 0 else { return "\u{2014}" }
    return String(format: "%.3f s", duration)
}

func millisecondsLabel(_ duration: Double) -> String {
    String(format: "%.1f ms", max(0, duration) * 1_000)
}

func asrTimingTooltip(_ timing: ASRTimingBreakdown?) -> String? {
    guard let timing else { return nil }
    return [
        "ASR total  \(millisecondsLabel(timing.totalSeconds))",
        "FluidAudio  \(millisecondsLabel(timing.fluidProcessingSeconds))",
        "Decoder setup  \(millisecondsLabel(timing.decoderPreparationSeconds))",
        "Actor + framework  \(millisecondsLabel(timing.workerQueueSeconds + timing.frameworkOverheadSeconds))",
    ].joined(separator: "\n")
}

struct DictationLatencyMetrics: Equatable {
    let audioSeconds: Double
    let hotkeyDispatchSeconds: Double?
    let releasePreparationSeconds: Double
    let settingsRefreshSeconds: Double
    let releasePermissionCheckSeconds: Double
    let audioFinalizeSeconds: Double
    let audioDetachSeconds: Double
    let journalFlushSeconds: Double
    let audioFlattenSeconds: Double
    let transcribingUISeconds: Double
    let taskQueueSeconds: Double
    let releaseToASRSeconds: Double
    let asrTiming: ASRTimingBreakdown
    let postprocessingSeconds: Double
    let historyPersistenceSeconds: Double
    let journalCleanupSeconds: Double
    let permissionRecheckSeconds: Double
    let insertionDispatchSeconds: Double
    let releaseToPasteDispatchSeconds: Double
    let enterDelaySeconds: Double?
    let pasteSucceeded: Bool

    var logLine: String {
        let enter = enterDelaySeconds.map(millisecondsLabel) ?? "off"
        let hotkeyDispatch = hotkeyDispatchSeconds.map(millisecondsLabel) ?? "off"
        let releaseState = max(
            0,
            releasePreparationSeconds - settingsRefreshSeconds - releasePermissionCheckSeconds
        )
        return [
            "latency:",
            "audio=\(String(format: "%.3f", audioSeconds))s",
            "hotkey_dispatch=\(hotkeyDispatch)",
            "release_prep=\(millisecondsLabel(releasePreparationSeconds))",
            "settings_refresh=\(millisecondsLabel(settingsRefreshSeconds))",
            "release_permission=\(millisecondsLabel(releasePermissionCheckSeconds))",
            "release_state=\(millisecondsLabel(releaseState))",
            "audio_finalize=\(millisecondsLabel(audioFinalizeSeconds))",
            "audio_detach=\(millisecondsLabel(audioDetachSeconds))",
            "journal_flush=\(millisecondsLabel(journalFlushSeconds))",
            "audio_flatten=\(millisecondsLabel(audioFlattenSeconds))",
            "transcribing_ui_overlap=\(millisecondsLabel(transcribingUISeconds))",
            "task_queue=\(millisecondsLabel(taskQueueSeconds))",
            "release_to_asr=\(millisecondsLabel(releaseToASRSeconds))",
            "worker_queue=\(millisecondsLabel(asrTiming.workerQueueSeconds))",
            "decoder_setup=\(millisecondsLabel(asrTiming.decoderPreparationSeconds))",
            "fluid_call=\(millisecondsLabel(asrTiming.fluidCallSeconds))",
            "fluid_processing=\(millisecondsLabel(asrTiming.fluidProcessingSeconds))",
            "framework_overhead=\(millisecondsLabel(asrTiming.frameworkOverheadSeconds))",
            "asr_total=\(millisecondsLabel(asrTiming.totalSeconds))",
            "postprocess=\(millisecondsLabel(postprocessingSeconds))",
            "history=\(millisecondsLabel(historyPersistenceSeconds))",
            "journal_cleanup=\(millisecondsLabel(journalCleanupSeconds))",
            "permission_recheck=\(millisecondsLabel(permissionRecheckSeconds))",
            "insert_dispatch=\(millisecondsLabel(insertionDispatchSeconds))",
            "release_to_paste=\(millisecondsLabel(releaseToPasteDispatchSeconds))",
            "enter_wait=\(enter)",
            "paste=\(pasteSucceeded ? "ok" : "failed")",
        ].joined(separator: " ")
    }
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

func updateCheckResult(for release: GitHubRelease?,
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

