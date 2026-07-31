// Dictor — push-to-talk dictation for macOS Apple Silicon.
//
// Swift menu-bar app. The runtime covers hotkey capture (`CGEventTap`), audio capture
// (`AVAudioEngine`), transcription (`FluidAudio` on the Apple
// Neural Engine), paste-at-cursor (`NSPasteboard` + `CGEvent`),
// system-audio mute (`NSAppleScript`), menu-bar UI, settings,
// rolling history, in-app updater, TCC self-healing.
//
// Section comments (`// MARK: -`) tag every major region; Cmd+Ctrl+Up
// in Xcode jumps between them. Keep them honest as you edit.
//
// Architectural invariants the build relies on are documented in
// ../../AGENTS.md — read that before refactoring concurrency,
// resource loading, or codesigning. In particular:
//   - `AudioCapture` is *not* @MainActor (AVAudioEngine tap fires on
//     an audio thread; main-actor entry would SIGTRAP under Swift 6
//     strict concurrency).
//   - `AVAudioConverter` inputBlock must return .noDataNow, never
//     .endOfStream — the latter puts the converter in a terminal
//     state and every press after the first captures silence.
//   - Resources are loaded via `Bundle.main`, never `Bundle.module`
//     — SwiftPM's auto-generated resource bundle has no Info.plist
//     and breaks `codesign --deep`.

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


#if DEBUG
if let status = DictorSelfTest.run(arguments: Array(CommandLine.arguments.dropFirst())) {
    exit(status)
}
#endif

let app = NSApplication.shared
let launchArguments = Array(CommandLine.arguments.dropFirst())
if launchArguments.first == "--export-settings-preview" {
    guard launchArguments.count == 2 else {
        fputs("usage: Dictor --export-settings-preview <directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportSettingsPanelPreviews(to: URL(fileURLWithPath: launchArguments[1],
                                                isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("settings preview export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if launchArguments.first == "--export-history-preview" {
    guard launchArguments.count == 2 || launchArguments.count == 3 else {
        fputs("usage: Dictor --export-history-preview <directory> [ru|en]\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        let previewLanguage: InterfaceLanguage? = launchArguments.count > 2
            ? (launchArguments[2].lowercased().hasPrefix("en") ? .english : .russian)
            : nil
        try exportHistoryPanelPreviews(to: URL(fileURLWithPath: launchArguments[1],
                                               isDirectory: true),
                                       language: previewLanguage)
        exit(EXIT_SUCCESS)
    } catch {
        fputs("history preview export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if launchArguments.first == "--export-onboarding-preview" {
    guard launchArguments.count == 2 else {
        fputs("usage: Dictor --export-onboarding-preview <directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportOnboardingPreviews(to: URL(fileURLWithPath: launchArguments[1],
                                             isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("onboarding preview export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if launchArguments.first == "--export-update-preview" {
    guard launchArguments.count == 2 else {
        fputs("usage: Dictor --export-update-preview <directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportUpdateWindowPreviews(to: URL(fileURLWithPath: launchArguments[1],
                                               isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("update preview export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if launchArguments.first == "--export-status-preview" {
    guard launchArguments.count == 2 else {
        fputs("usage: Dictor --export-status-preview <directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportServiceStatusPreviews(to: URL(fileURLWithPath: launchArguments[1],
                                                isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("status preview export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if launchArguments.first == "--export-popover-preview" {
    guard launchArguments.count == 2 else {
        fputs("usage: Dictor --export-popover-preview <directory>\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        try exportQuickPanelPreviews(to: URL(fileURLWithPath: launchArguments[1],
                                             isDirectory: true))
        exit(EXIT_SUCCESS)
    } catch {
        fputs("popover preview export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
if launchArguments.first == RECORDING_HUD_EXPORT_ARGUMENT {
    guard launchArguments.count == 2 || launchArguments.count == 3 else {
        fputs("usage: Dictor --export-hud-animation <frames-directory> [ru|en]\n", stderr)
        exit(EXIT_FAILURE)
    }
    do {
        // Необязательный третий аргумент — язык кадров (ru/en).
        let hudLanguage: InterfaceLanguage = launchArguments.count > 2
            ? (launchArguments[2].lowercased().hasPrefix("en") ? .english : .russian)
            : Settings.shared.interfaceLanguage
        try exportRecordingHUDAnimationFrames(to: URL(fileURLWithPath: launchArguments[1],
                                                      isDirectory: true),
                                              language: hudLanguage)
        exit(EXIT_SUCCESS)
    } catch {
        fputs("HUD export failed: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
} else if let launch = UpdateProgressLaunch(arguments: launchArguments) {
    let delegate = UpdateProgressAppDelegate(launch: launch)
    app.delegate = delegate
    app.run()
} else if launchArguments.contains(AGENT_ARGUMENT) {
    app.setActivationPolicy(.accessory)
    let delegate = DictorApp()
    app.delegate = delegate
    // Refuse to start under a tampered launch environment that would
    // redirect FluidAudio's model download to an attacker-controlled host.
    // Runs after NSApplication.shared is initialised so NSAlert.runModal
    // has its event loop.
    refuseHostileRegistryEnvironmentAndExit()
    app.run()
} else {
    let delegate = DictorControlPanelApp()
    app.delegate = delegate
    app.run()
}
