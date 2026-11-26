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

// MARK: - Settings
//
// Thin wrapper around the app's standard NSUserDefaults domain, so
// settings persist at `~/Library/Preferences/com.raul.dictor.plist`.
// One property per user-visible setting; defaults are returned inline
// by each getter when the key is missing, rather than via a central
// `register()` call.

final class Settings: @unchecked Sendable {
    private static let keyHotkeyKeycode = "hotkey_keycode"
    private static let keyHotkeyModifiers = "hotkey_modifiers"
    private static let keyEnterHotkeyKeycode = "enter_hotkey_keycode"
    private static let keyEnterHotkeyModifiers = "enter_hotkey_modifiers"
    private static let keyPrimaryCompletionBehavior = "primary_completion_behavior_v1"
    private static let keyAlternateCompletionEnabled = "alternate_completion_enabled_v1"
    private static let keyInterfaceLanguage = "interface_language"
    private static let keyTriggerMode = "trigger_mode"
    private static let keyPasteSuffix = "paste_suffix"
    static let keyRecentTranscripts = "recent_transcripts"
    static let keyPreferredRecentTranscripts = "recent_transcripts_preferred_v1"
    static let keyRecentTranscriptHistory = "recent_transcript_history"
    static let keyRecentTranscriptEntries = "recent_transcript_entries_v1"
    static let keyDailyDictationUsage = "daily_dictation_usage_v1"
    static let keyDidImportDictationUsageLog = "did_import_dictation_usage_log_v1"
    private static let keyShowRecordingWaveform = "show_recording_waveform"
    private static let keyRecordingHUDRecordingColor = "recording_hud_recording_color"
    private static let keyRecordingHUDTranscribingColor = "recording_hud_transcribing_color"
    private static let keyRecordingHUDBackgroundStyle = "recording_hud_background_style"
    private static let keyRecordingHUDSize = "recording_hud_size"
    private static let keyRecordingHUDPlacement = "recording_hud_placement_v1"
    private static let legacyKeyShowRecordingIndicator = "show_recording_indicator"
    private static let keyMuteWhileRecording = "mute_while_recording"
    private static let keyPlayFeedbackSounds = "play_feedback_sounds"
    private static let keyShowInDock = "show_in_dock"
    private static let keyInputDevice = "input_device"
    static let keyCheckForUpdates = "check_for_updates"
    static let keyLastUpdateCheckAt = "last_update_check_at"
    static let keyLastUpdateCheckSource = "last_update_check_source"
    static let keyLastUpdateCheckResult = "last_update_check_result"
    static let keyLastUpdateCheckVersion = "last_update_check_version"
    static let keyUpdateReminderPausedVersion = "update_reminder_paused_version"
    static let keyUpdateReminderPausedUntil = "update_reminder_paused_until"
    static let keyLastSeenVersion = "last_seen_version"
    static let keySkippedVersions = "skipped_versions"
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyTranscriptCorrectionsSyncFile = "transcript_corrections_sync_file"
    private static let keyDictationLanguage = "dictation_language"
    private static let keySpeechModelProfile = "speech_model_profile"
    private static let keyInitialSpeechModelChoiceRequired = "initial_speech_model_choice_required"
    private static let keyRemoveFillerWords = "remove_filler_words"
    private static let keyEnterDelayMilliseconds = "enter_delay_milliseconds_v1"
    private static let keyActiveRunMarker = "active_run_marker"
    private static let keyAgentEnabled = "agent_enabled"

    let defaults: UserDefaults

    /// Разобранный архив истории вместе с тем, из чего он получен. Архив
    /// читают десятки раз за одну пересборку окна и раз в 0,75 с ради
    /// отпечатка, а разбор тысячи записей из JSON — это 12–25 мс. Сравнить
    /// байты — memcmp, поэтому, пока они те же, отдаётся прошлый результат.
    let historyCacheLock = NSLock()
    var historyCache: (data: Data, pinned: [String], entries: [TranscriptHistoryEntry])?

    static let shared = Settings()

    init() {
        self.defaults = .standard
    }

    @discardableResult
    func refreshFromDisk() -> Bool {
        defaults.synchronize()
    }

    var hotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHotkeyKeycode))
                ?? DEFAULT_HOTKEY_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? DEFAULT_HOTKEY_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHotkeyKeycode)
        }
    }

    var hotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHotkeyModifiers) as? NSNumber
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHotkeyModifiers)
        }
    }

    var configuredHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: hotkeyKeycode, modifiers: hotkeyModifiers)
    }

    func setConfiguredHotkey(_ choice: HotkeyChoice) {
        hotkeyKeycode = choice.keycode
        hotkeyModifiers = choice.requiredModifiers
    }

    var enterHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyEnterHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyEnterHotkeyKeycode)
        }
    }

    var enterHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyEnterHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskAlternate }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyEnterHotkeyModifiers)
        }
    }

    var configuredEnterHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: enterHotkeyKeycode, modifiers: enterHotkeyModifiers)
    }

    func setConfiguredEnterHotkey(_ choice: HotkeyChoice) {
        enterHotkeyKeycode = choice.keycode
        enterHotkeyModifiers = choice.requiredModifiers
    }

    var primaryCompletionBehavior: DictationCompletionBehavior {
        get {
            guard let raw = defaults.string(forKey: Self.keyPrimaryCompletionBehavior),
                  let behavior = DictationCompletionBehavior(rawValue: raw) else {
                // Preserve the behavior of releases before v0.2.35.
                return .insert
            }
            return behavior
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPrimaryCompletionBehavior) }
    }

    var alternateCompletionEnabled: Bool {
        get {
            guard defaults.object(forKey: Self.keyAlternateCompletionEnabled) != nil else {
                // The alternate finish shortcut was always enabled before v0.2.35.
                return true
            }
            return defaults.bool(forKey: Self.keyAlternateCompletionEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAlternateCompletionEnabled) }
    }

    /// Delay between pasting the transcribed text and posting the
    /// Return key when the completion behavior includes "+ Enter".
    /// Some apps (Electron, VMs) need a beat to process the paste
    /// before they can handle a keystroke. Stored in milliseconds;
    /// the default (120) matches the original hardcoded constant.
    var enterDelayMilliseconds: Int {
        get {
            guard defaults.object(forKey: Self.keyEnterDelayMilliseconds) != nil else {
                return 120
            }
            return max(0, min(ENTER_DELAY_MAX_MILLISECONDS,
                              defaults.integer(forKey: Self.keyEnterDelayMilliseconds)))
        }
        set {
            defaults.set(max(0, min(ENTER_DELAY_MAX_MILLISECONDS, newValue)),
                         forKey: Self.keyEnterDelayMilliseconds)
        }
    }

    var interfaceLanguage: InterfaceLanguage {
        get {
            guard let raw = defaults.string(forKey: Self.keyInterfaceLanguage),
                  let language = InterfaceLanguage(rawValue: raw) else {
                return .russian
            }
            return language
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyInterfaceLanguage) }
    }

    var triggerMode: TriggerMode {
        get {
            if let v = defaults.string(forKey: Self.keyTriggerMode), let m = TriggerMode(rawValue: v) {
                return m
            }
            return .toggle
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyTriggerMode) }
    }

    var agentEnabled: Bool {
        get {
            if defaults.object(forKey: Self.keyAgentEnabled) == nil { return true }
            return defaults.bool(forKey: Self.keyAgentEnabled)
        }
        set { defaults.set(newValue, forKey: Self.keyAgentEnabled) }
    }

    /// Онбординг показан и закрыт (пройден или пропущен).
    var onboardingCompleted: Bool {
        get { defaults.bool(forKey: "onboarding_completed_v1") }
        set { defaults.set(newValue, forKey: "onboarding_completed_v1") }
    }

    /// Закреплённые диктовки (макет 6b): хранятся текстом, чтобы пережить
    /// чистку архива по лимиту.
    var pinnedTranscripts: [String] {
        get { defaults.stringArray(forKey: "pinned_transcripts_v1") ?? [] }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var unique: [String] = []
            for text in cleaned where !unique.contains(text) {
                unique.append(text)
            }
            defaults.set(Array(unique.prefix(200)), forKey: "pinned_transcripts_v1")
        }
    }

    /// Закрытые подсказки экрана «Сегодня». Правило макета 6e: закрыли —
    /// больше не возвращается.
    /// Встроенный набор написаний технических названий. Включён по
    /// умолчанию: он меняет только форму записи латиницей («postgres» →
    /// «PostgreSQL»), смысла текста не трогает, и человек, диктующий про
    /// работу, ожидает увидеть названия написанными правильно.
    var builtInSpellingsEnabled: Bool {
        get {
            guard defaults.object(forKey: "built_in_spellings_enabled_v1") != nil
            else { return true }
            return defaults.bool(forKey: "built_in_spellings_enabled_v1")
        }
        set { defaults.set(newValue, forKey: "built_in_spellings_enabled_v1") }
    }

    /// Названия, услышанные по-русски: «гитхаб» → GitHub. Включён по
    /// умолчанию — в наборе только имена собственные, у которых нет принятого
    /// русского написания, и портить в русском тексте им нечего.
    var latinTermRestorationsEnabled: Bool {
        get {
            guard defaults.object(forKey: "latin_term_restorations_v1") != nil
            else { return true }
            return defaults.bool(forKey: "latin_term_restorations_v1")
        }
        set { defaults.set(newValue, forKey: "latin_term_restorations_v1") }
    }

    /// Созвучные варианты: «линктын», «лингтына» и «линкит ин» находят запись
    /// «линкедин → LinkedIn» сами.
    ///
    /// Выключено по умолчанию, и тумблера в настройках пока нет: на истории
    /// из 1118 диктовок прототип правила дал 122 срабатывания без единого
    /// ложного, а перенесённый в приложение код — 64, и расхождение не
    /// разобрано. Правило, которое само переписывает текст, не уходит людям,
    /// пока не сходится со своей проверкой. Включается ключом
    /// `phonetic_term_matching_v1` для доводки.
    var phoneticTermMatchingEnabled: Bool {
        get { defaults.bool(forKey: "phonetic_term_matching_v1") }
        set { defaults.set(newValue, forKey: "phonetic_term_matching_v1") }
    }

    /// Словарь, отличающий русское слово от названия, — или `nil`, если
    /// сопоставление по звучанию выключено либо русского словаря в системе нет.
    var dictationTermLexicon: WordLexicon? {
        phoneticTermMatchingEnabled ? SystemLexicon.russian : nil
    }

    /// Что уходит в правку расшифровки: слова человека плюс встроенные наборы.
    var dictationTranscriptCorrections: [TranscriptCorrection] {
        dictationCorrections(user: transcriptCorrections,
                             includeBuiltInSpellings: builtInSpellingsEnabled,
                             includeLatinTermRestorations: latinTermRestorationsEnabled)
    }

    /// Плавающая капсула (макет 6c). По умолчанию выключена: это постоянный
    /// объект поверх чужих окон, и появиться он должен потому, что человек
    /// его позвал, а не потому, что вышло обновление.
    var floatingCapsuleEnabled: Bool {
        get { defaults.bool(forKey: "floating_capsule_enabled_v1") }
        set { defaults.set(newValue, forKey: "floating_capsule_enabled_v1") }
    }

    /// Где капсула стоит на каждом мониторе. Ключ — номер дисплея: у человека
    /// с ноутбуком и внешним экраном привычное место у них разное, и таскать
    /// капсулу заново при каждом подключении — работа за программу.
    var floatingCapsulePositions: [String: NSPoint] {
        get {
            guard let raw = defaults.dictionary(forKey: "floating_capsule_positions_v1")
            else { return [:] }
            // Числа читаем через NSNumber, а не приведением к [CGFloat]:
            // целое из plist («174», а не «174.0») такому приведению не
            // поддаётся, и весь словарь молча превращается в пустой —
            // капсула «забывает» место, ничем об этом не сообщая.
            return raw.compactMapValues { value in
                guard let pair = value as? [NSNumber], pair.count == 2 else { return nil }
                return NSPoint(x: CGFloat(pair[0].doubleValue),
                               y: CGFloat(pair[1].doubleValue))
            }
        }
        set {
            // Мониторы приходят и уходят, а запись о каждом остаётся навсегда:
            // держим последние шестнадцать.
            let trimmed = newValue.prefix(16)
            let raw = Dictionary(uniqueKeysWithValues: trimmed.map { key, point in
                (key, [point.x, point.y])
            })
            defaults.set(raw, forKey: "floating_capsule_positions_v1")
        }
    }

    var dismissedHints: [String] {
        get { defaults.stringArray(forKey: "dismissed_hints_v1") ?? [] }
        set {
            let cleaned = Array(Set(newValue)).sorted().prefix(64)
            defaults.set(Array(cleaned), forKey: "dismissed_hints_v1")
        }
    }

    var pasteSuffix: PasteSuffix {
        get {
            if let v = defaults.string(forKey: Self.keyPasteSuffix), let s = PasteSuffix(rawValue: v) {
                return s
            }
            return .appendSpace
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyPasteSuffix) }
    }

    /// Умная вставка: строчная буква и пробел в продолжении фразы, реплика
    /// в мессенджере без точки. Включена по умолчанию — правила молчат везде,
    /// где не уверены, а выключенной по умолчанию функции никто не находит.
    var smartInsertionEnabled: Bool {
        get {
            guard defaults.object(forKey: "smart_insertion_v1") != nil else { return true }
            return defaults.bool(forKey: "smart_insertion_v1")
        }
        set { defaults.set(newValue, forKey: "smart_insertion_v1") }
    }

    var showRecordingWaveform: Bool {
        get {
            if defaults.object(forKey: Self.keyShowRecordingWaveform) != nil {
                return defaults.bool(forKey: Self.keyShowRecordingWaveform)
            }
            if defaults.object(forKey: Self.legacyKeyShowRecordingIndicator) != nil {
                return defaults.bool(forKey: Self.legacyKeyShowRecordingIndicator)
            }
            return true
        }
        set { defaults.set(newValue, forKey: Self.keyShowRecordingWaveform) }
    }

    var recordingHUDRecordingColor: RecordingHUDAccentColor {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDRecordingColor),
                  let color = RecordingHUDAccentColor(rawValue: raw) else {
                return .coral
            }
            return color
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDRecordingColor)
            defaults.synchronize()
        }
    }

    var recordingHUDTranscribingColor: RecordingHUDAccentColor {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDTranscribingColor),
                  let color = RecordingHUDAccentColor(rawValue: raw) else {
                return .graphite
            }
            return color
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDTranscribingColor)
            defaults.synchronize()
        }
    }

    var recordingHUDBackgroundStyle: RecordingHUDBackgroundStyle {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDBackgroundStyle),
                  let style = RecordingHUDBackgroundStyle(rawValue: raw) else {
                return .system
            }
            return style
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDBackgroundStyle)
            defaults.synchronize()
        }
    }

    var recordingHUDSize: RecordingHUDSize {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDSize),
                  let size = RecordingHUDSize(rawValue: raw) else {
                return .standard
            }
            return size
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDSize)
            defaults.synchronize()
        }
    }

    var recordingHUDPlacement: RecordingHUDPlacement {
        get {
            guard let raw = defaults.string(forKey: Self.keyRecordingHUDPlacement),
                  let placement = RecordingHUDPlacement(rawValue: raw) else {
                return .followsInput
            }
            return placement
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.keyRecordingHUDPlacement)
            defaults.synchronize()
        }
    }

    var muteWhileRecording: Bool {
        get {
            if defaults.object(forKey: Self.keyMuteWhileRecording) == nil { return true }
            return defaults.bool(forKey: Self.keyMuteWhileRecording)
        }
        set { defaults.set(newValue, forKey: Self.keyMuteWhileRecording) }
    }

    var playFeedbackSounds: Bool {
        get {
            if defaults.object(forKey: Self.keyPlayFeedbackSounds) == nil { return true }
            return defaults.bool(forKey: Self.keyPlayFeedbackSounds)
        }
        set { defaults.set(newValue, forKey: Self.keyPlayFeedbackSounds) }
    }

    var showInDock: Bool {
        get {
            if defaults.object(forKey: Self.keyShowInDock) == nil { return false }
            return defaults.bool(forKey: Self.keyShowInDock)
        }
        set { defaults.set(newValue, forKey: Self.keyShowInDock) }
    }

    var inputDevice: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyInputDevice),
                  let normalized = normalizedInputDevicePreference(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedInputDevicePreference(newValue) {
                defaults.set(normalized, forKey: Self.keyInputDevice)
            } else {
                defaults.removeObject(forKey: Self.keyInputDevice)
            }
        }
    }

    var transcriptCorrections: [TranscriptCorrection] {
        get {
            guard let data = defaults.data(forKey: Self.keyTranscriptCorrections) else { return [] }
            do {
                return try TranscriptCorrectionsTransfer.decode(data)
            } catch {
                log("settings: transcript correction decode failed: \(error)")
                return []
            }
        }
        set { storeTranscriptCorrections(newValue) }
    }

    /// Persists corrections and reports failure to the caller instead
    /// of swallowing it. With the per-field/per-count caps the encoded
    /// set always fits maxFileBytes in practice (see its derivation
    /// comment), but if encoding or the size guard ever fails the
    /// user's edit must not silently vanish — UI entry points alert on
    /// a non-nil return. The property setter above keeps the
    /// fire-and-forget shape (and the log below) for internal callers.
    @discardableResult
    func storeTranscriptCorrections(_ newValue: [TranscriptCorrection]) -> Error? {
        let corrections = normalizedTranscriptCorrections(newValue)
        guard !corrections.isEmpty else {
            defaults.removeObject(forKey: Self.keyTranscriptCorrections)
            return nil
        }
        do {
            let data = try JSONEncoder().encode(corrections)
            try TranscriptCorrectionsTransfer.validateTransferSize(data.count)
            defaults.set(data, forKey: Self.keyTranscriptCorrections)
            return nil
        } catch {
            log("settings: transcript correction encode failed: \(error)")
            return error
        }
    }

    var transcriptCorrectionsSyncFile: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyTranscriptCorrectionsSyncFile),
                  let normalized = normalizedCorrectionSyncFilePath(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedCorrectionSyncFilePath(newValue) {
                defaults.set(normalized, forKey: Self.keyTranscriptCorrectionsSyncFile)
            } else {
                defaults.removeObject(forKey: Self.keyTranscriptCorrectionsSyncFile)
            }
        }
    }

    var dictationLanguage: DictationLanguage {
        get {
            if let v = defaults.string(forKey: Self.keyDictationLanguage),
               let lang = DictationLanguage(rawValue: v) {
                return lang
            }
            return .auto
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyDictationLanguage) }
    }

    var speechModelProfile: SpeechModelProfile {
        get {
            productionSpeechModelProfile(rawValue: defaults.string(forKey: Self.keySpeechModelProfile))
        }
        set { defaults.set(newValue.productionProfile.rawValue, forKey: Self.keySpeechModelProfile) }
    }

    @discardableResult
    func normalizeSpeechModelProfileForCurrentBuild() -> Bool {
        var changed = false
        if let raw = defaults.string(forKey: Self.keySpeechModelProfile) {
            let normalized = productionSpeechModelProfile(rawValue: raw)
            if normalized.rawValue != raw {
                defaults.set(SpeechModelProfile.productionDefault.rawValue,
                             forKey: Self.keySpeechModelProfile)
                changed = true
            }
        }
        if defaults.object(forKey: Self.keyInitialSpeechModelChoiceRequired) != nil {
            defaults.removeObject(forKey: Self.keyInitialSpeechModelChoiceRequired)
            changed = true
        }
        return changed
    }

    var removeFillerWords: Bool {
        get { defaults.bool(forKey: Self.keyRemoveFillerWords) }
        set { defaults.set(newValue, forKey: Self.keyRemoveFillerWords) }
    }

    var hasActiveRunMarker: Bool {
        get { defaults.bool(forKey: Self.keyActiveRunMarker) }
        set {
            if newValue {
                defaults.set(true, forKey: Self.keyActiveRunMarker)
            } else {
                defaults.removeObject(forKey: Self.keyActiveRunMarker)
            }
        }
    }
}

