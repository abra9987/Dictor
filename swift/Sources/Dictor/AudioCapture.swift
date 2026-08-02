import AppKit
import AVFoundation
import AudioToolbox
import Foundation
import CoreGraphics
import CryptoKit
import Darwin
import ApplicationServices
import DictorObjCSupport
import FluidAudio
import IOKit
import QuartzCore
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Audio capture
//
// AVAudioEngine tap on the input node, downmix to mono / 16 kHz /
// Float32 if needed, append to a buffer while recording.
//
// Deliberately NOT @MainActor. AVAudioEngine's installTap delivers
// callbacks on an audio worker thread. Under Swift 6 strict
// concurrency, calling a @MainActor method from that thread triggers
// dispatch_assert_queue_fail (SIGTRAP) and kills the process. We
// instead guard mutable state with NSLock and let the tap callback
// run wherever AVFoundation calls it.
//
// Locking discipline: `lock` protects ALL mutable state shared with
// the render thread — `samples`, `_isRunning`, `latestLevel`,
// `latestLevelSequence`, `recordingGeneration`, the engine-open flag,
// AND the converter set (`converter`, `converterInputFormat`,
// `tapInputFormat`, `manuallyMixInputToMono`). The set is normally
// written on the main thread in startEngine/stopEngine and read in
// handleTap on AVFoundation's render thread; removeTap(onBus:) does
// NOT wait for in-flight tap callbacks, so an unlocked read could
// race stopEngine nil-ing the converter (an unsynchronised ARC
// pointer read — potential use-after-free). handleTap snapshots the
// set once, inside the same lock acquisition that reads
// `_isRunning`, and works off the snapshots; a straggler callback
// then keeps the old converter alive through its own strong
// reference, which is safe. The one case where the render thread
// *writes* the set is a buffer arriving in a format the converter
// was not built for — configureConverter(onlyWhileRunning: true)
// re-checks the running flag under the lock before publishing.
// `configurationObserver` and `onConfigurationChange` are
// main-thread-only: the observer is registered with queue: .main so
// the notification callback runs on the same thread that installs
// the observer and that clears `onConfigurationChange` at
// termination.

/// Runs `body`, reporting an Objective-C exception raised inside it as
/// a thrown Swift error. AVFoundation still raises for invalid audio
/// formats, and an uncaught raise on a worker thread does not crash —
/// AppKit swallows it and suspends the thread, which is how audio
/// startup once hung forever on "Starting audio input…" with nothing
/// in the log to show for it.
func withObjCExceptionsAsErrors(_ body: () throws -> Void) throws {
    var thrown: Error?
    try DictorExceptionTrap.perform {
        do {
            try body()
        } catch {
            thrown = error
        }
    }
    if let thrown { throw thrown }
}

/// A format CoreAudio can actually be asked to deliver. Zero on either
/// field means the device is busy elsewhere or has just gone away, and
/// every downstream call would raise rather than fail politely.
func audioFormatIsUsable(_ format: AVAudioFormat) -> Bool {
    format.sampleRate > 0 && format.channelCount > 0
}

/// Whether a converter built for `rhs` can be fed buffers of `lhs`.
/// Only the two properties the conversion maths depends on matter;
/// AVAudioEngine node taps always hand over non-interleaved Float32.
func audioFormatsInterchangeable(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat?) -> Bool {
    guard let rhs else { return false }
    return abs(lhs.sampleRate - rhs.sampleRate) < 0.5
        && lhs.channelCount == rhs.channelCount
}

func audioInputFormatUnusableError(_ format: AVAudioFormat) -> NSError {
    NSError(domain: "Dictor", code: -2, userInfo: [
        NSLocalizedDescriptionKey: """
        The microphone reported an unusable format (\(format.sampleRate) Hz, \
        \(format.channelCount) ch). CoreAudio reports this when the input device \
        is held by another app or has just been disconnected.
        """,
    ])
}

struct CapturedAudioSegments {
    let segments: [[Float]]
    let sampleCount: Int

    func flattened() -> [Float] {
        guard sampleCount > 0 else { return [] }
        var out: [Float] = []
        out.reserveCapacity(sampleCount)
        for segment in segments {
            out.append(contentsOf: segment)
        }
        return out
    }
}

struct CapturedRecording {
    let samples: [Float]
    let recoveryURL: URL?
    let detachSeconds: TimeInterval
    let journalFlushSeconds: TimeInterval
    let flattenSeconds: TimeInterval
}

enum PendingDictationRecovery {
    private static let directoryName = "PendingDictations"
    private static let fileExtension = "sdaudio"
    private static let magic = Data("SDAR".utf8)

    static func directoryURL() throws -> URL {
        let url = try dictorApplicationSupportDirectory()
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
        return url
    }

    static func createJournal() throws -> PendingDictationJournal {
        try PendingDictationJournal(url: directoryURL()
            .appendingPathComponent("pending-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension))
    }

    static func pendingURLs() -> [URL] {
        guard let directory = try? directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix("pending-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(fd) }

        try validateSingleLinkRegularFileDescriptor(fd)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
        guard st.st_size >= PENDING_DICTATION_HEADER_SIZE,
              st.st_size <= PENDING_DICTATION_MAX_BYTES else {
            throw posixError(EFBIG)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count >= PENDING_DICTATION_HEADER_SIZE,
              data.prefix(4) == magic,
              readUInt32LE(data, offset: 4) == PENDING_DICTATION_FILE_VERSION,
              readUInt32LE(data, offset: 8) == UInt32(SAMPLE_RATE),
              readUInt32LE(data, offset: 12) == UInt32(MemoryLayout<Float>.size) else {
            throw posixError(EINVAL)
        }

        let payload = data.dropFirst(PENDING_DICTATION_HEADER_SIZE)
        // A process can die halfway through the final write. Preserve every
        // complete float instead of rejecting the whole recording for 1-3
        // trailing bytes.
        let usablePayloadCount = payload.count - (payload.count % MemoryLayout<Float>.size)
        let usablePayload = payload.prefix(usablePayloadCount)
        var samples = [Float](repeating: 0,
                              count: usablePayload.count / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { destination in
            usablePayload.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return samples
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return
        } catch {
            log("pending dictation cleanup failed: \(error.localizedDescription)")
        }
    }

    static func headerData() -> Data {
        var data = magic
        appendUInt32LE(PENDING_DICTATION_FILE_VERSION, to: &data)
        appendUInt32LE(UInt32(SAMPLE_RATE), to: &data)
        appendUInt32LE(UInt32(MemoryLayout<Float>.size), to: &data)
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

final class PendingDictationJournal: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "Dictor.PendingDictationJournal",
                                      qos: .utility)
    private var fileDescriptor: Int32
    private var didLogWriteFailure = false

    init(url: URL) throws {
        self.url = url
        fileDescriptor = -1
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
        guard fd >= 0 else { throw currentPOSIXError() }
        do {
            try validateSingleLinkRegularFileDescriptor(fd)
            guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
                throw currentPOSIXError()
            }
            try writeAllData(PendingDictationRecovery.headerData(), to: fd)
            fileDescriptor = fd
        } catch {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(url.path)
            throw error
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        queue.async { [self] in
            guard fileDescriptor >= 0 else { return }
            do {
                try writeAllData(data, to: fileDescriptor)
            } catch where !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation write failed: \(error.localizedDescription)")
            } catch {}
        }
    }

    func finish() {
        queue.sync { [self] in
            guard fileDescriptor >= 0 else { return }
            if Darwin.fsync(fileDescriptor) != 0, !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation sync failed: \(currentPOSIXError().localizedDescription)")
            }
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}

struct AudioSampleAccumulator {
    private var segments: [[Float]] = []
    private(set) var sampleCount = 0

    mutating func append(_ segment: [Float]) {
        guard !segment.isEmpty else { return }
        segments.append(segment)
        sampleCount += segment.count
    }

    mutating func removeAll(keepingCapacity: Bool) {
        segments.removeAll(keepingCapacity: keepingCapacity)
        sampleCount = 0
    }

    mutating func drain() -> CapturedAudioSegments {
        let captured = CapturedAudioSegments(segments: segments,
                                             sampleCount: sampleCount)
        segments.removeAll(keepingCapacity: true)
        sampleCount = 0
        return captured
    }
}

func selectedMonoMixChannelIndices(channelRMS: [Double]) -> [Int] {
    let peak = channelRMS.max() ?? 0
    let active = channelRMS.enumerated()
        .filter { pair in peak > 0 && pair.element >= peak * 0.25 }
        .map { $0.offset }
    return active.isEmpty ? [0] : active
}

func channelRMSValues(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                      channelCount: Int,
                      frameCount: Int) -> [Double] {
    guard channelCount > 0, frameCount > 0 else { return [] }
    var rms = Array(repeating: 0.0, count: channelCount)
    for channelIndex in 0..<channelCount {
        var sumSquares = 0.0
        let source = channels[channelIndex]
        for frameIndex in 0..<frameCount {
            let sample = source[frameIndex]
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
        }
        rms[channelIndex] = sqrt(sumSquares / Double(frameCount))
    }
    return rms
}

func writeMonoMix(channels: UnsafePointer<UnsafeMutablePointer<Float>>,
                  selectedChannels: [Int],
                  frameCount: Int,
                  to mono: UnsafeMutablePointer<Float>) {
    guard frameCount > 0 else { return }
    let selectedChannels = selectedChannels.isEmpty ? [0] : selectedChannels
    let scale = Float(1.0 / Double(selectedChannels.count))
    for frameIndex in 0..<frameCount {
        var mixed: Float = 0
        for channelIndex in selectedChannels {
            mixed += channels[channelIndex][frameIndex] * scale
        }
        mono[frameIndex] = mixed
    }
}

/// What handleTap needs to convert a buffer, kept together so a
/// rebuild can hand all three back at once.
struct ConverterSetup {
    let converter: AVAudioConverter?
    let monoFormat: AVAudioFormat?
    let mixToMono: Bool
}

final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    /// The raw format the tap was last configured for, before any mono
    /// mixing. Compared against every incoming buffer so a device that
    /// changes rate under us is noticed instead of silently resampled
    /// by the wrong ratio.
    private var tapInputFormat: AVAudioFormat?
    private var manuallyMixInputToMono = false
    private let lock = NSLock()
    var samples = AudioSampleAccumulator()
    private var _isRunning = false
    private var latestLevel: Float = 0
    private var latestLevelSequence: UInt64 = 0
    private var recordingGeneration: UInt64 = 0
    private var recoveryJournal: PendingDictationJournal?
    private var engineStarted = false
    /// Whether the last open attempt pinned the audio unit to a specific
    /// device. Main-thread only, like the rest of startEngine.
    private var lastOpenPinnedInputDevice = false
    /// Выбранный микрофон существует, но работать не стал: CoreAudio отверг
    /// закрепление или движок не поднялся с ним, и захват идёт с системного
    /// входа. Имя устройства — для интерфейса: галочка в меню без этой
    /// строки утверждала бы, что запись идёт с выбранного. nil — захват на
    /// том входе, который просили (или предпочтения нет). Main-thread only,
    /// like the rest of startEngine.
    private(set) var inputFallbackDeviceName: String?
    private var configurationObserver: NSObjectProtocol?

    var onConfigurationChange: (@Sendable () -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
    }

    var isEngineStarted: Bool {
        lock.lock(); defer { lock.unlock() }
        return engineStarted
    }

    func startEngine(inputDevicePreference: String = "",
                                 recordingImmediately: Bool = false,
                                 recoveryJournal: PendingDictationJournal? = nil) throws {
        if isEngineStarted {
            if recordingImmediately {
                beginRecording(recoveryJournal: recoveryJournal)
            }
            return
        }

        do {
            try openEngine(inputDevicePreference: inputDevicePreference,
                           recordingImmediately: recordingImmediately,
                           recoveryJournal: recoveryJournal)
            return
        } catch {
            // Pinning the audio unit to one device is the only thing
            // worth surrendering here: it is what makes CoreAudio refuse
            // the unit outright (-10868) when the current output device
            // runs at a different sample rate. Dictating through the
            // system default microphone beats not dictating at all, and
            // both the log and the failure detail name what happened.
            guard lastOpenPinnedInputDevice else {
                clearStoppedCaptureState()
                throw error
            }
            log("AudioCapture: chosen input device rejected by CoreAudio (\(singleLineLogDetail(audioStartupErrorDescription(error)))); retrying with the system default input")
        }

        do {
            try openEngine(inputDevicePreference: "",
                           recordingImmediately: recordingImmediately,
                           recoveryJournal: recoveryJournal)
            // Захват поднялся, но не с тем входом, который просили, — и об
            // этом обязан узнать интерфейс, а не только лог: галочка в меню
            // остаётся у выбранного устройства.
            inputFallbackDeviceName = audioInputDevice(matching: inputDevicePreference)?.name
                ?? inputDevicePreference.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            clearStoppedCaptureState()
            throw error
        }
    }

    private func openEngine(inputDevicePreference: String,
                            recordingImmediately: Bool,
                            recoveryJournal: PendingDictationJournal?) throws {
        let input = engine.inputNode
        lastOpenPinnedInputDevice = applyInputDevicePreference(inputDevicePreference, to: input)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: SAMPLE_RATE,
            channels: 1,
            interleaved: false
        ) else { throw NSError(domain: "Dictor", code: -1) }

        // Only the opening guess at what the tap will deliver. The node
        // is allowed to disagree: switching the input device through the
        // HAL updates it asynchronously, so right after the switch it can
        // still report the rate of a completely different device. With a
        // Bluetooth speaker at 44.1 kHz as the default output and the
        // built-in mic at 48 kHz, that is exactly what happened — and
        // handing the stale rate to installTap raised an Objective-C
        // exception that froze startup outright.
        let inputFormat = input.outputFormat(forBus: 0)
        guard audioFormatIsUsable(inputFormat) else {
            resetEngineInstance()
            throw audioInputFormatUnusableError(inputFormat)
        }

        let prepared = configureConverter(rawInputFormat: inputFormat, target: targetFormat)
        if recordingImmediately {
            lock.lock()
            recordingGeneration &+= 1
            samples.removeAll(keepingCapacity: true)
            latestLevel = 0
            latestLevelSequence &+= 1
            _isRunning = true
            self.recoveryJournal = recoveryJournal
            lock.unlock()
        }
        let mixLabel = prepared.mixToMono ? " via manual mono mix" : ""
        log("AudioCapture: input \(inputFormat.sampleRate) Hz \(inputFormat.channelCount)ch\(mixLabel) → \(targetFormat.sampleRate) Hz mono")

        // format: nil, deliberately. An explicit format that differs
        // from the bus's own raises rather than returns an error, and
        // nil means "whatever this bus actually produces" — a mismatch
        // becomes impossible by construction. handleTap reconciles the
        // converter with the first buffer if the guess above was wrong.
        //
        // Capture targetFormat by value into the closure. self is
        // weak so the engine doesn't keep AudioCapture alive past
        // its owner. The closure runs on AVFoundation's audio
        // thread — handleTap is non-isolated and uses NSLock for
        // any shared-state access.
        do {
            try withObjCExceptionsAsErrors {
                input.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
                    self?.handleTap(buffer: buffer, target: targetFormat)
                }
                try engine.start()
            }
        } catch {
            // No clearStoppedCaptureState() here — startEngine may still
            // retry without the device pin, and clearing would finish the
            // crash-recovery journal of a recording that is about to
            // carry on. The fresh engine drops the tap with it anyway.
            input.removeTap(onBus: 0)
            resetEngineInstance()
            throw error
        }
        lock.lock()
        engineStarted = true
        lock.unlock()
        installConfigurationObserver()

        // Now that the engine is running the node reports the truth.
        // Reconciling here keeps the rebuild off the audio thread in
        // the case where the guess above was stale.
        let settledFormat = input.outputFormat(forBus: 0)
        if audioFormatIsUsable(settledFormat),
           !audioFormatsInterchangeable(settledFormat, inputFormat) {
            log("AudioCapture: input settled at \(settledFormat.sampleRate) Hz \(settledFormat.channelCount)ch after start")
            configureConverter(rawInputFormat: settledFormat, target: targetFormat)
        }
        log("AudioCapture: engine started")
    }

    /// Builds the converter trio for `rawInputFormat` and publishes it
    /// under the lock — handleTap reads these on the render thread (see
    /// the locking-discipline note on the class comment).
    @discardableResult
    private func configureConverter(rawInputFormat: AVAudioFormat,
                                    target: AVAudioFormat,
                                    onlyWhileRunning: Bool = false) -> ConverterSetup {
        let sourceFormat = converterSourceFormat(for: rawInputFormat)
        let mixToMono = rawInputFormat.channelCount > 1 && sourceFormat.channelCount == 1
        let newConverter = AVAudioConverter(from: sourceFormat, to: target)
        lock.lock()
        // Re-checked under the lock for the render-thread caller: it
        // decided to rebuild from a snapshot that a concurrent stop may
        // have invalidated since, and publishing then would leave a live
        // converter sitting behind state that stop had just cleared. The
        // returned setup is still handed back either way — the buffer in
        // flight belongs to the recording that was running when the
        // snapshot was taken, and the generation token drops it later if
        // that recording is already over.
        if !onlyWhileRunning || _isRunning {
            tapInputFormat = rawInputFormat
            converterInputFormat = sourceFormat
            manuallyMixInputToMono = mixToMono
            converter = newConverter
        }
        lock.unlock()
        return ConverterSetup(converter: newConverter,
                              monoFormat: sourceFormat,
                              mixToMono: mixToMono)
    }

    func startRecording(inputDevicePreference: String = "",
                                    recoveryJournal: PendingDictationJournal? = nil) throws {
        if isEngineStarted {
            beginRecording(recoveryJournal: recoveryJournal)
            return
        }
        try startEngine(inputDevicePreference: inputDevicePreference,
                        recordingImmediately: true,
                        recoveryJournal: recoveryJournal)
    }

    func stopEngine() {
        removeConfigurationObserver()

        let wasEngineStarted = isEngineStarted
        clearStoppedCaptureState()

        guard wasEngineStarted else { return }
        engine.inputNode.removeTap(onBus: 0)
        resetEngineInstance()
    }

    private func clearStoppedCaptureState() {
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        let recoveryJournal = self.recoveryJournal
        self.recoveryJournal = nil
        engineStarted = false
        // Clear the converter trio under the same lock the render
        // thread snapshots them with — removeTap below does not wait
        // for an in-flight tap callback. A callback that already took
        // its snapshot keeps the old converter alive through its own
        // strong reference, which is safe.
        converter = nil
        converterInputFormat = nil
        tapInputFormat = nil
        manuallyMixInputToMono = false
        lock.unlock()
        recoveryJournal?.finish()
    }

    private func resetEngineInstance() {
        engine.stop()
        engine.reset()
        engine = AVAudioEngine()
    }

    fileprivate func beginRecording(recoveryJournal: PendingDictationJournal? = nil) {
        lock.lock()
        let previousJournal = self.recoveryJournal
        recordingGeneration &+= 1
        samples.removeAll(keepingCapacity: true)
        latestLevel = 0
        latestLevelSequence &+= 1
        _isRunning = true
        self.recoveryJournal = recoveryJournal
        lock.unlock()
        previousJournal?.finish()
    }

    private func installConfigurationObserver() {
        removeConfigurationObserver()
        // queue: .main — the notification can be posted from an
        // AVFoundation worker thread, and `onConfigurationChange` is
        // an unsynchronised var that the owner clears on the main
        // thread at termination. Hopping to the main queue makes the
        // read of the callback and the nil-ing write happen on the
        // same thread, so a config change racing teardown can never
        // observe a half-released closure.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.onConfigurationChange?()
        }
    }

    private func removeConfigurationObserver() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
    }

    /// Stops recording, flushes its crash-recovery journal, and returns the captured samples.
    func endRecording() -> CapturedRecording {
        let startedAt = ProcessInfo.processInfo.systemUptime
        lock.lock()
        _isRunning = false
        latestLevel = 0
        latestLevelSequence &+= 1
        recordingGeneration &+= 1
        let captured = samples.drain()
        let recoveryJournal = self.recoveryJournal
        self.recoveryJournal = nil
        lock.unlock()
        let detachedAt = ProcessInfo.processInfo.systemUptime
        recoveryJournal?.finish()
        let journalFlushedAt = ProcessInfo.processInfo.systemUptime
        let flattened = captured.flattened()
        let flattenedAt = ProcessInfo.processInfo.systemUptime
        return CapturedRecording(
            samples: flattened,
            recoveryURL: recoveryJournal?.url,
            detachSeconds: detachedAt - startedAt,
            journalFlushSeconds: journalFlushedAt - detachedAt,
            flattenSeconds: flattenedAt - journalFlushedAt
        )
    }

    func latestRecordingLevelSnapshot() -> (level: Float, sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return _isRunning
            ? (latestLevel, latestLevelSequence)
            : (0, latestLevelSequence)
    }

    private func handleTap(buffer: AVAudioPCMBuffer, target: AVAudioFormat) {
        // Snapshot the running flag AND the converter trio in one
        // lock acquisition; bail fast if we're not recording so we
        // don't pay conversion cost for nothing. Working off the
        // snapshots keeps this callback consistent even if
        // stopEngine() clears the fields mid-flight — removeTap does
        // not wait for us, and the local strong reference keeps the
        // converter alive for the rest of this call.
        lock.lock()
        let running = _isRunning
        let generation = recordingGeneration
        var converter = self.converter
        var monoMixFormat = converterInputFormat
        var mixToMono = manuallyMixInputToMono
        let configuredFormat = tapInputFormat
        lock.unlock()
        guard running else { return }

        // The tap is installed with a nil format, so the engine picks
        // the bus's real one and it can differ from what the node
        // advertised before it was running. Rebuilding costs one
        // allocation on the first buffer of a recording; feeding the
        // old converter a rate it was not built for would resample by
        // the wrong ratio and pitch-shift the speech into gibberish.
        // Only while running — a straggler callback after a stop must
        // not resurrect the state that stop just cleared.
        if !audioFormatsInterchangeable(buffer.format, configuredFormat) {
            log("AudioCapture: tap delivering \(buffer.format.sampleRate) Hz \(buffer.format.channelCount)ch, rebuilding converter")
            let rebuilt = configureConverter(rawInputFormat: buffer.format,
                                             target: target,
                                             onlyWhileRunning: true)
            converter = rebuilt.converter
            monoMixFormat = rebuilt.monoFormat
            mixToMono = rebuilt.mixToMono
        }
        guard let converter else { return }

        let converterInput = preparedConverterInputBuffer(from: buffer,
                                                          mixToMono: mixToMono,
                                                          monoFormat: monoMixFormat) ?? buffer
        let ratio = target.sampleRate / converterInput.format.sampleRate
        let outCap = AVAudioFrameCount(Double(converterInput.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { return }

        // .noDataNow vs .endOfStream: this is reusing the same
        // AVAudioConverter across every tap callback (~50 Hz). If we
        // signal .endOfStream after the buffer, the converter goes
        // into a terminal state and produces 0 samples on every
        // subsequent call — exactly the "first capture was 0.10s,
        // every press after that was 0.00s" bug we saw before this
        // fix. .noDataNow means "I'm out of input *for this call*,
        // but the stream continues" and leaves the converter usable.
        let inputProvider = AudioConverterInputProvider(buffer: converterInput)
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            log("AudioCapture: convert error: \(error?.localizedDescription ?? "?")")
            return
        }
        guard let ch = out.floatChannelData?[0] else { return }
        let frameCount = Int(out.frameLength)
        var arr: [Float] = []
        arr.reserveCapacity(frameCount)
        var sumSquares: Double = 0
        var finiteSampleCount = 0
        for sample in UnsafeBufferPointer(start: ch, count: frameCount) {
            arr.append(sample)
            guard sample.isFinite else { continue }
            let clamped = max(-1, min(1, sample))
            sumSquares += Double(clamped * clamped)
            finiteSampleCount += 1
        }
        let level = normalizedAudioLevel(sumSquares: sumSquares,
                                         sampleCount: finiteSampleCount)
        // Re-check running under lock — endRecording() might have
        // fired during conversion, then a rapid next recording may
        // already have started. The generation token keeps straggler
        // frames out of the next clip.
        lock.lock()
        if _isRunning && recordingGeneration == generation {
            samples.append(arr)
            recoveryJournal?.append(arr)
            latestLevel = level
            latestLevelSequence &+= 1
        }
        lock.unlock()
    }

    private func converterSourceFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        guard inputFormat.channelCount > 1,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inputFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false) else {
            return inputFormat
        }
        return monoFormat
    }

    /// `mixToMono` / `monoFormat` are the caller's lock-held
    /// snapshots of `manuallyMixInputToMono` / `converterInputFormat`
    /// — this runs on the render thread and must not read the shared
    /// fields directly (see the locking-discipline note on the class
    /// comment).
    private func preparedConverterInputBuffer(from buffer: AVAudioPCMBuffer,
                                              mixToMono: Bool,
                                              monoFormat: AVAudioFormat?) -> AVAudioPCMBuffer? {
        guard mixToMono else { return buffer }
        guard let monoFormat,
              let channels = buffer.floatChannelData else {
            return nil
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        guard channelCount > 1, frameCount > 0 else { return buffer }
        guard let out = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                         frameCapacity: AVAudioFrameCount(frameCount)),
              let mono = out.floatChannelData?[0] else {
            return nil
        }

        let rms = channelRMSValues(channels: channels,
                                   channelCount: channelCount,
                                   frameCount: frameCount)
        writeMonoMix(channels: channels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: frameCount,
                     to: mono)
        out.frameLength = AVAudioFrameCount(frameCount)
        return out
    }

    /// Returns whether the engine's audio unit was actually pinned to a
    /// device. Worth knowing because pinning is the one thing startEngine
    /// can give up on when CoreAudio refuses to open the unit.
    @discardableResult
    private func applyInputDevicePreference(_ preference: String, to input: AVAudioInputNode) -> Bool {
        // Каждая новая попытка открытия начинается с чистого листа: прежний
        // отказ не должен пережить успешное закрепление или смену настройки.
        inputFallbackDeviceName = nil
        let trimmed = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !isDefaultAggregateAudioInputPreference(trimmed) else { return false }

        guard let device = audioInputDevice(matching: trimmed) else {
            log("AudioCapture: saved input device unavailable, using system default")
            return false
        }
        // Pinning the shared audio unit to a device makes it refuse to
        // initialise whenever the current *output* device runs at another
        // sample rate — a Bluetooth speaker at 44.1 kHz against the
        // built-in mic at 48 kHz was enough to kill audio startup
        // outright. Left alone, AVAudioEngine reconciles the two itself.
        // So when the wanted device is the one CoreAudio would choose
        // anyway, ask for nothing. If the system default later moves
        // elsewhere, the route-change observer restarts the engine and
        // this check no longer matches, so the preference is still
        // honoured — it just stops being asserted for free.
        guard device.id != defaultAudioInputDeviceID() else {
            log("AudioCapture: \(device.name) is already the system default input")
            return false
        }
        guard let unit = input.audioUnit else {
            log("AudioCapture: input audio unit unavailable, using system default")
            return false
        }

        var deviceID = device.id
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &deviceID,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            log("AudioCapture: input device switch failed (\(formattedOSStatus(status))), using system default")
            inputFallbackDeviceName = device.name
            return false
        }
        log("AudioCapture: selected input \(device.name)")
        return true
    }
}

final class AudioConverterInputProvider: @unchecked Sendable {
    private let buffer: AVAudioPCMBuffer
    private let lock = NSLock()
    private var didProvideBuffer = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func provide(outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        if didProvideBuffer {
            outStatus.pointee = .noDataNow
            return nil
        }

        didProvideBuffer = true
        outStatus.pointee = .haveData
        return buffer
    }
}

