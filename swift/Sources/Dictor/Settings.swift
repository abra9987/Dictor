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
    private static let keyHistoryHotkeyKeycode = "history_hotkey_keycode"
    private static let keyHistoryHotkeyModifiers = "history_hotkey_modifiers"
    private static let keyPrimaryCompletionBehavior = "primary_completion_behavior_v1"
    private static let keyAlternateCompletionEnabled = "alternate_completion_enabled_v1"
    private static let keyInterfaceLanguage = "interface_language"
    private static let keyTriggerMode = "trigger_mode"
    private static let keyPasteSuffix = "paste_suffix"
    private static let keyRecentTranscripts = "recent_transcripts"
    private static let keyRecentTranscriptHistory = "recent_transcript_history"
    private static let keyRecentTranscriptEntries = "recent_transcript_entries_v1"
    private static let keyDailyDictationUsage = "daily_dictation_usage_v1"
    private static let keyDidImportDictationUsageLog = "did_import_dictation_usage_log_v1"
    private static let keyShowRecordingWaveform = "show_recording_waveform"
    private static let keyRecordingHUDRecordingColor = "recording_hud_recording_color"
    private static let keyRecordingHUDTranscribingColor = "recording_hud_transcribing_color"
    private static let keyRecordingHUDBackgroundStyle = "recording_hud_background_style"
    private static let keyRecordingHUDSize = "recording_hud_size"
    private static let legacyKeyShowRecordingIndicator = "show_recording_indicator"
    private static let keyMuteWhileRecording = "mute_while_recording"
    private static let keyPlayFeedbackSounds = "play_feedback_sounds"
    private static let keyShowInDock = "show_in_dock"
    private static let keyInputDevice = "input_device"
    private static let keyCheckForUpdates = "check_for_updates"
    private static let keyLastUpdateCheckAt = "last_update_check_at"
    private static let keyLastUpdateCheckSource = "last_update_check_source"
    private static let keyLastUpdateCheckResult = "last_update_check_result"
    private static let keyLastUpdateCheckVersion = "last_update_check_version"
    private static let keyUpdateReminderPausedVersion = "update_reminder_paused_version"
    private static let keyUpdateReminderPausedUntil = "update_reminder_paused_until"
    private static let keyLastSeenVersion = "last_seen_version"
    private static let keySkippedVersions = "skipped_versions"
    private static let keyTranscriptCorrections = "transcript_corrections"
    private static let keyTranscriptCorrectionsSyncFile = "transcript_corrections_sync_file"
    private static let keyDictationLanguage = "dictation_language"
    private static let keySpeechModelProfile = "speech_model_profile"
    private static let keyInitialSpeechModelChoiceRequired = "initial_speech_model_choice_required"
    private static let keyRemoveFillerWords = "remove_filler_words"
    private static let keyEnterDelayMilliseconds = "enter_delay_milliseconds_v1"
    private static let keyActiveRunMarker = "active_run_marker"
    private static let keyAgentEnabled = "agent_enabled"

    private let defaults: UserDefaults

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
            return max(0, min(500, defaults.integer(forKey: Self.keyEnterDelayMilliseconds)))
        }
        set { defaults.set(max(0, min(500, newValue)), forKey: Self.keyEnterDelayMilliseconds) }
    }

    var historyHotkeyKeycode: CGKeyCode {
        get {
            normalizedHotkeyKeycode(storedValue: defaults.object(forKey: Self.keyHistoryHotkeyKeycode))
                ?? RIGHT_COMMAND_KEYCODE
        }
        set {
            let normalized = normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(newValue)))
                ?? RIGHT_COMMAND_KEYCODE
            defaults.set(Int(normalized), forKey: Self.keyHistoryHotkeyKeycode)
        }
    }

    var historyHotkeyModifiers: CGEventFlags {
        get {
            let raw = defaults.object(forKey: Self.keyHistoryHotkeyModifiers) as? NSNumber
            if raw == nil { return .maskShift }
            return CGEventFlags(rawValue: raw?.uint64Value ?? 0)
                .intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
        }
        set {
            defaults.set(NSNumber(value: newValue.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK).rawValue),
                         forKey: Self.keyHistoryHotkeyModifiers)
        }
    }

    var configuredHistoryHotkey: HotkeyChoice {
        hotkeyChoice(forKeycode: historyHotkeyKeycode, modifiers: historyHotkeyModifiers)
    }

    func setConfiguredHistoryHotkey(_ choice: HotkeyChoice) {
        historyHotkeyKeycode = choice.keycode
        historyHotkeyModifiers = choice.requiredModifiers
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

    var recentTranscriptLimit: RecentTranscriptLimit {
        get {
            parseRecentTranscriptLimit(storedValue: defaults.object(forKey: Self.keyRecentTranscripts))
                ?? DEFAULT_RECENT_TRANSCRIPT_LIMIT
        }
        set { defaults.set(newValue.rawValue, forKey: Self.keyRecentTranscripts) }
    }

    var recentTranscriptHistory: [String] {
        get {
            let stored = defaults.stringArray(forKey: Self.keyRecentTranscriptHistory) ?? []
            return Array(
                stored.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
        }
        set {
            let cleaned = Array(
                newValue.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(TRANSCRIPT_HISTORY_ARCHIVE_MAX_ENTRIES)
            )
            if cleaned.isEmpty {
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
            } else {
                defaults.set(cleaned, forKey: Self.keyRecentTranscriptHistory)
            }
            defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
        }
    }

    var recentTranscriptEntries: [TranscriptHistoryEntry] {
        get {
            if let data = defaults.data(forKey: Self.keyRecentTranscriptEntries),
               let decoded = try? JSONDecoder().decode([TranscriptHistoryEntry].self, from: data) {
                let cleaned = decoded.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming,
                        createdAt: entry.createdAt
                    )
                }
                return limitedTranscriptHistoryArchive(cleaned)
            }

            return recentTranscriptHistory.map { TranscriptHistoryEntry(text: $0) }
        }
        set {
            let cleaned = limitedTranscriptHistoryArchive(
                newValue.compactMap { entry -> TranscriptHistoryEntry? in
                    let text = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return nil }
                    return TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: entry.transcriptionDurationSeconds,
                        asrTiming: entry.asrTiming,
                        createdAt: entry.createdAt
                    )
                }
            )

            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyRecentTranscriptEntries)
                defaults.removeObject(forKey: Self.keyRecentTranscriptHistory)
                return
            }

            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyRecentTranscriptEntries)
            }
            defaults.set(cleaned.map(\.text), forKey: Self.keyRecentTranscriptHistory)
        }
    }

    var dailyDictationUsage: [DailyDictationUsage] {
        get {
            guard let data = defaults.data(forKey: Self.keyDailyDictationUsage),
                  let decoded = try? JSONDecoder().decode([DailyDictationUsage].self, from: data) else {
                return []
            }
            return mergedDailyDictationUsage(decoded)
        }
        set {
            let cleaned = mergedDailyDictationUsage(newValue)
            guard !cleaned.isEmpty else {
                defaults.removeObject(forKey: Self.keyDailyDictationUsage)
                return
            }
            if let data = try? JSONEncoder().encode(cleaned) {
                defaults.set(data, forKey: Self.keyDailyDictationUsage)
            }
        }
    }

    var didImportDictationUsageLog: Bool {
        get { defaults.bool(forKey: Self.keyDidImportDictationUsageLog) }
        set { defaults.set(newValue, forKey: Self.keyDidImportDictationUsageLog) }
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

    var checkForUpdates: Bool {
        get {
            if defaults.object(forKey: Self.keyCheckForUpdates) == nil { return false }
            return defaults.bool(forKey: Self.keyCheckForUpdates)
        }
        set { defaults.set(newValue, forKey: Self.keyCheckForUpdates) }
    }

    var lastUpdateCheckAt: Date? {
        get { defaults.object(forKey: Self.keyLastUpdateCheckAt) as? Date }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Self.keyLastUpdateCheckAt)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckAt)
            }
        }
    }

    var lastUpdateCheckSource: UpdateCheckSource? {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckSource) else {
                return nil
            }
            return UpdateCheckSource(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.keyLastUpdateCheckSource)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckSource)
            }
        }
    }

    var lastUpdateCheckResult: UpdateCheckResult? {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckResult) else {
                return nil
            }
            return UpdateCheckResult(rawValue: raw)
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Self.keyLastUpdateCheckResult)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckResult)
            }
        }
    }

    var lastUpdateCheckVersion: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastUpdateCheckVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyLastUpdateCheckVersion)
            } else {
                defaults.removeObject(forKey: Self.keyLastUpdateCheckVersion)
            }
        }
    }

    /// "Remind me later" pause state, persisted so a relaunch inside
    /// the 24 h window does not re-prompt ~30 s after launch. Both
    /// halves are validated independently and corrupt stored values
    /// degrade to nil; DictorApp treats a missing half as "no pause"
    /// and clears the leftover at startup.
    var updateReminderPausedVersion: String? {
        get {
            guard let raw = defaults.string(forKey: Self.keyUpdateReminderPausedVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return nil
            }
            return normalized
        }
        set {
            if let newValue, let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyUpdateReminderPausedVersion)
            } else {
                defaults.removeObject(forKey: Self.keyUpdateReminderPausedVersion)
            }
        }
    }

    var updateReminderPausedUntil: Date? {
        get {
            normalizedUpdateReminderPauseExpiry(
                storedValue: defaults.object(forKey: Self.keyUpdateReminderPausedUntil)
            )
        }
        set {
            if let newValue,
               normalizedUpdateReminderPauseExpiry(storedValue: newValue) != nil {
                defaults.set(newValue, forKey: Self.keyUpdateReminderPausedUntil)
            } else {
                defaults.removeObject(forKey: Self.keyUpdateReminderPausedUntil)
            }
        }
    }

    var lastSeenVersion: String {
        get {
            guard let raw = defaults.string(forKey: Self.keyLastSeenVersion),
                  let normalized = normalizedStoredAppVersion(raw) else {
                return ""
            }
            return normalized
        }
        set {
            if let normalized = normalizedStoredAppVersion(newValue) {
                defaults.set(normalized, forKey: Self.keyLastSeenVersion)
            } else {
                defaults.removeObject(forKey: Self.keyLastSeenVersion)
            }
        }
    }

    var skippedVersions: [String] {
        get {
            normalizedSkippedUpdateVersions(
                (defaults.array(forKey: Self.keySkippedVersions) as? [String]) ?? []
            )
        }
        set {
            let versions = normalizedSkippedUpdateVersions(newValue)
            if versions.isEmpty {
                defaults.removeObject(forKey: Self.keySkippedVersions)
            } else {
                defaults.set(versions, forKey: Self.keySkippedVersions)
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

