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

// MARK: - Transcription worker
//
// Owns the FluidAudio AsrManager. The Apple Neural Engine doesn't
// tolerate concurrent inference calls against the same compiled
// CoreML graph — but the actor alone does NOT keep that contract.
// Actors are reentrant at suspension points: while
// `await asr.transcribe(...)` is suspended, a second transcribe()
// call would enter the actor and start concurrent inference. The
// real guard is DictorApp.isBusy, which ensures the app never
// issues a second transcribe while one is in flight. The `inFlight`
// flag below is a cheap defensive backstop should that invariant
// ever break: it refuses (and, in DEBUG, asserts on) a re-entrant
// call instead of corrupting ANE state.

enum LoadedSpeechEngine {
    case parakeetV3(AsrManager)
}

struct TranscriptionWorkerResult: Sendable {
    let text: String
    let workerQueueSeconds: Double
    let decoderPreparationSeconds: Double
    let fluidCallSeconds: Double
    let fluidProcessingSeconds: Double

    func timing(totalSeconds: Double) -> ASRTimingBreakdown {
        ASRTimingBreakdown(
            totalSeconds: totalSeconds,
            workerQueueSeconds: workerQueueSeconds,
            decoderPreparationSeconds: decoderPreparationSeconds,
            fluidCallSeconds: fluidCallSeconds,
            fluidProcessingSeconds: fluidProcessingSeconds
        )
    }
}

struct CompletedTranscriptionWorkerResult: Sendable {
    let transcription: TranscriptionWorkerResult
    let completedAt: TimeInterval
}

actor TranscriptionWorker {
    private var engine: LoadedSpeechEngine?
    private var loadedProfile: SpeechModelProfile?
    private(set) var ready = false
    /// Reentrancy backstop — see the comment above. True for the full
    /// duration of transcribe(), including across its await.
    private var inFlight = false

    /// `verificationProgress` — «проверено N файлов из M». Проверка идёт до
    /// двух секунд, и без неё окно всё это время утверждало, что служба
    /// остановлена.
    func load(profile requestedProfile: SpeechModelProfile,
              progressHandler: DownloadUtils.ProgressHandler? = nil,
              verificationProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws {
        let profile = requestedProfile.productionProfile
        if requestedProfile != profile {
            log("ASR: ignoring unsupported speech model \(requestedProfile.shortName); using \(profile.shortName)")
        }
        if ready, engine != nil, loadedProfile == profile {
            log("ASR: \(profile.shortName) already ready")
            return
        }

        if engine != nil {
            await unload()
        }

        if speechModelCacheExists(for: profile) {
            log("ASR: verifying + loading cached \(profile.shortName) CoreML weights…")
        } else {
            log("ASR: downloading + verifying + loading \(profile.shortName) CoreML weights…")
        }
        let t0 = Date()
        engine = .parakeetV3(try await loadParakeetV3(progressHandler: progressHandler,
                                                      verificationProgress: verificationProgress))
        loadedProfile = profile
        ready = true
        log("ASR: \(profile.shortName) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
    }

    private func loadParakeetV3(progressHandler: DownloadUtils.ProgressHandler?,
                                verificationProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> AsrManager {
        if !speechModelCacheExists(for: .multilingualV3) {
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: .multilingualV3)
        }
        var modelDirectory = try await AsrModels.download(version: .v3,
                                                          progressHandler: progressHandler)
        do {
            try ModelIntegrity.verifyParakeetV3Model(at: modelDirectory,
                                                     onProgress: verificationProgress)
        } catch {
            log("ASR: model integrity check failed; redownloading once: \(error.localizedDescription)")
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: .multilingualV3)
            modelDirectory = try await AsrModels.download(force: true,
                                                          version: .v3,
                                                          progressHandler: progressHandler)
            try ModelIntegrity.verifyParakeetV3Model(at: modelDirectory,
                                                     onProgress: verificationProgress)
        }
        let models = try await AsrModels.load(from: modelDirectory,
                                              version: .v3,
                                              progressHandler: progressHandler)
        return AsrManager(config: .default, models: models)
    }

    func transcribe(samples: [Float],
                               language: Language? = nil,
                               requestedAt: TimeInterval) async throws -> TranscriptionWorkerResult {
        let workerEnteredAt = ProcessInfo.processInfo.systemUptime
        guard let engine else { throw NSError(domain: "Dictor", code: -2) }
        guard !inFlight else {
            log("ASR: transcribe re-entered while another transcription is in flight — refusing (DictorApp.isBusy should make this impossible)")
            assertionFailure("TranscriptionWorker.transcribe re-entered across a suspension point")
            throw NSError(domain: "Dictor", code: -3)
        }
        inFlight = true
        defer { inFlight = false }
        switch engine {
        case .parakeetV3(let asr):
            let decoderPreparationStartedAt = ProcessInfo.processInfo.systemUptime
            var state = try TdtDecoderState()
            let fluidCallStartedAt = ProcessInfo.processInfo.systemUptime
            let result = try await asr.transcribe(samples, decoderState: &state, language: language)
            let fluidCallCompletedAt = ProcessInfo.processInfo.systemUptime
            return TranscriptionWorkerResult(
                text: result.text,
                workerQueueSeconds: workerEnteredAt - requestedAt,
                decoderPreparationSeconds: fluidCallStartedAt - decoderPreparationStartedAt,
                fluidCallSeconds: fluidCallCompletedAt - fluidCallStartedAt,
                fluidProcessingSeconds: result.processingTime
            )
        }
    }

    func warmUp() async throws -> ASRTimingBreakdown {
        let samples = [Float](repeating: 0, count: Int(SAMPLE_RATE * 0.4))
        let requestedAt = ProcessInfo.processInfo.systemUptime
        let transcription = try await transcribe(
            samples: samples,
            language: nil,
            requestedAt: requestedAt
        )
        let completedAt = ProcessInfo.processInfo.systemUptime
        return transcription.timing(totalSeconds: completedAt - requestedAt)
    }

    func unload() async {
        engine = nil
        loadedProfile = nil
        ready = false
        log("ASR: unloaded")
    }
}

