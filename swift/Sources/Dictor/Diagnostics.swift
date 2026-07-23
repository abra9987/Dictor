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

// MARK: - Sounds
//
// Short system sounds: Tink on recording start, Pop after a
// successful paste, Basso when a dictation is dropped. Loaded from
// /System/Library/Sounds so we don't have to bundle audio resources.

@MainActor
enum Sounds {
    private static let start = systemSound("Tink", volume: 0.55)
    private static let done = systemSound("Pop", volume: 0.45)
    private static let error = systemSound("Basso", volume: 0.30)

    private static func systemSound(_ name: String, volume: Float) -> NSSound? {
        let path = "/System/Library/Sounds/\(name).aiff"
        guard let sound = NSSound(contentsOfFile: path, byReference: true) else { return nil }
        sound.volume = volume
        return sound
    }

    static func playStart() { start?.stop(); start?.play() }
    static func playDone()  { done?.stop();  done?.play() }
    static func playError() { error?.stop(); error?.play() }
}

// MARK: - Bundle version helpers

func currentBundleVersion() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
}

func currentBundleBuild() -> String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
}

struct AppMemoryUsage {
    let residentBytes: UInt64
    let physicalFootprintBytes: UInt64
}

func currentAppMemoryUsage() -> AppMemoryUsage? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_,
                      task_flavor_t(TASK_VM_INFO),
                      rebound,
                      &count)
        }
    }
    guard result == KERN_SUCCESS else { return nil }
    return AppMemoryUsage(residentBytes: UInt64(info.resident_size),
                          physicalFootprintBytes: UInt64(info.phys_footprint))
}

func formattedByteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

// MARK: - Diagnostics
//
// User-triggered local diagnostics for GitHub issue triage. Keep the
// report useful but metadata-only: no transcript text and no text
// correction contents.

struct DiagnosticsReportSnapshot {
    let generated: String
    let appVersion: String
    let appBuild: String
    let macOS: String
    let bundleID: String
    let bundlePath: String
    let installKind: String
    let status: String
    let startup: String
    let speechModelReady: Bool
    let coreRuntimeReady: Bool
    let readyForDictation: Bool
    let recordingActive: Bool
    let transcribing: Bool
    let memoryLines: [String]
    let permissionLines: [String]
    let settingLines: [String]
    let updateLines: [String]
    let microphoneLines: [String]
    let logPath: String
    let recentLogLines: [String]
}

func diagnosticBulletLines(_ lines: [String], emptyText: String) -> String {
    guard !lines.isEmpty else { return "- \(emptyText)" }
    return lines.map { "- \($0)" }.joined(separator: "\n")
}

func diagnosticsReportText(from snapshot: DiagnosticsReportSnapshot) -> String {
    """
    Dictor diagnostics
    Generated: \(snapshot.generated)
    App version: \(snapshot.appVersion) (\(snapshot.appBuild))
    macOS: \(snapshot.macOS)
    Bundle ID: \(snapshot.bundleID)
    Bundle path: \(snapshot.bundlePath)
    Install kind: \(snapshot.installKind)

    Status:
    - Menu: \(snapshot.status)
    - Startup: \(snapshot.startup)
    - Speech model ready: \(snapshot.speechModelReady)
    - Core runtime ready: \(snapshot.coreRuntimeReady)
    - Ready for dictation: \(snapshot.readyForDictation)
    - Recording active: \(snapshot.recordingActive)
    - Transcribing: \(snapshot.transcribing)

    Memory:
    \(diagnosticBulletLines(snapshot.memoryLines, emptyText: "Unavailable"))

    Permissions:
    \(diagnosticBulletLines(snapshot.permissionLines, emptyText: "Unavailable"))

    Settings:
    \(diagnosticBulletLines(snapshot.settingLines, emptyText: "Unavailable"))

    Update:
    \(diagnosticBulletLines(snapshot.updateLines, emptyText: "Unavailable"))

    Microphone:
    \(diagnosticBulletLines(snapshot.microphoneLines, emptyText: "Unavailable"))

    Recent log lines:
    \(diagnosticBulletLines(snapshot.recentLogLines, emptyText: "No recent log lines available"))

    Logs: \(snapshot.logPath)
    Privacy: transcript text and text-correction contents are not included.
    """
}

func recentDiagnosticLogLines(from url: URL = Logger.shared.fileURL,
                              maxBytes: Int = DIAGNOSTICS_LOG_MAX_BYTES,
                              maxLines: Int = DIAGNOSTICS_LOG_MAX_LINES) throws -> [String] {
    guard maxBytes > 0, maxLines > 0 else { return [] }

    let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
    guard fd >= 0 else {
        if errno == ENOENT { return [] }
        throw currentPOSIXError()
    }
    defer { _ = Darwin.close(fd) }

    try validateSingleLinkRegularFileDescriptor(fd)

    var st = stat()
    guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
    guard st.st_size > 0 else { return [] }

    let startOffset = max(Int64(0), Int64(st.st_size) - Int64(maxBytes))
    guard Darwin.lseek(fd, off_t(startOffset), SEEK_SET) >= 0 else {
        throw currentPOSIXError()
    }

    var data = Data()
    data.reserveCapacity(min(maxBytes, Int(st.st_size)))
    while data.count < maxBytes {
        let remaining = maxBytes - data.count
        var buffer = [UInt8](repeating: 0, count: min(8192, remaining))
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer in
            Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
        }
        if bytesRead < 0 {
            if errno == EINTR { continue }
            throw currentPOSIXError()
        }
        guard bytesRead > 0 else { break }
        data.append(buffer, count: bytesRead)
    }

    var text = String(decoding: data, as: UTF8.self)
    if startOffset > 0, let firstNewline = text.firstIndex(of: "\n") {
        text = String(text[text.index(after: firstNewline)...])
    }

    let sanitized = text
        .components(separatedBy: .newlines)
        .map(sanitizedDiagnosticLogLine)
        .filter { !$0.isEmpty }
    return Array(sanitized.suffix(maxLines))
}

func sanitizedDiagnosticLogLine(_ line: String) -> String {
    var result = String()
    result.reserveCapacity(min(line.count, DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS))
    for scalar in line.unicodeScalars {
        guard result.count < DIAGNOSTICS_LOG_MAX_LINE_CHARACTERS else { break }
        if scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7f) {
            result.unicodeScalars.append(scalar)
        } else {
            result.append(" ")
        }
    }
    return result.trimmingCharacters(in: .whitespaces)
}

func parseSemver(_ s: String) -> [Int] {
    // Strip leading whitespace + 'v', split on '.', take leading
    // digit run from each chunk. Tolerant by design; "" returns []
    // which compares less than any real version.
    let trimmed = s.trimmingCharacters(in: .whitespaces)
        .drop(while: { $0 == "v" || $0 == "V" })
    return trimmed.split(separator: ".").map { chunk in
        var n = 0
        var seen = false
        for c in chunk {
            guard let d = c.wholeNumberValue else { break }
            let multiplied = n.multipliedReportingOverflow(by: 10)
            if multiplied.overflow { return Int.max }
            let added = multiplied.partialValue.addingReportingOverflow(d)
            if added.overflow { return Int.max }
            n = added.partialValue
            seen = true
        }
        return seen ? n : 0
    }
}

func isNewer(_ candidate: String, than current: String) -> Bool {
    let a = parseSemver(candidate)
    let b = parseSemver(current)
    for i in 0..<max(a.count, b.count) {
        let x = i < a.count ? a[i] : 0
        let y = i < b.count ? b[i] : 0
        if x != y { return x > y }
    }
    return false
}

// MARK: - TCC recovery
//
// macOS's TCC database occasionally ends up with a DENIED entry
// for our bundle id that the user can't easily clear (typical
// trigger: an upgrade that changes the signed binary while a
// previous denial is still cached). On a fresh launch after an
// upgrade (CFBundleShortVersionString differs from
// settings.lastSeenVersion), we proactively `tccutil reset` any
// DENIED entry for `com.raul.dictor`. GRANTED entries stay
// intact — we never reset away permissions the user gave us.
//
// The companion to this is the click-twice-to-reset retry in the
// permission rows: if the user clicks a ⚠ row, sees the OS dialog
// say nothing useful, and clicks the same row again, the second
// click runs `tccutil reset` to clear stuck state and re-request.

enum TCC {
    /// Maps the human-readable permission name we use in the menu to
    /// the TCC service identifier `tccutil reset` accepts. Input
    /// Monitoring is "ListenEvent" internally.
    static let serviceName: [Permission: String] = [
        .microphone: "Microphone",
        .accessibility: "Accessibility",
        .inputMonitoring: "ListenEvent",
    ]

    /// Serial so multiple resets (e.g. the upgrade-recovery loop)
    /// execute in the order they were requested.
    private static let queue = DispatchQueue(label: "DictorTCCReset", qos: .userInitiated)

    /// Runs `tccutil reset` on a background queue. tccutil is usually
    /// quick but waitUntilExit() on the main thread would run behind
    /// the session-wide event tap, where any stall delays every
    /// keystroke system-wide. `completion`, if provided, is invoked
    /// on the main actor after the reset has finished — callers that
    /// re-request the permission must do so from the completion, or
    /// the request would race the scrub it depends on.
    static func reset(_ p: Permission,
                      bundleID: String,
                      completion: (@MainActor @Sendable () -> Void)? = nil) {
        guard let service = serviceName[p] else {
            if let completion { Task { @MainActor in completion() } }
            return
        }
        queue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", service, bundleID]
            proc.environment = systemToolProcessEnvironment()
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                log("  tccutil reset \(service) \(bundleID) → exit \(proc.terminationStatus)")
            } catch {
                log("  tccutil reset \(service) failed: \(error)")
            }
            if let completion { Task { @MainActor in completion() } }
        }
    }
}

