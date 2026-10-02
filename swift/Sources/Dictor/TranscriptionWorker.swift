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
    case parakeet(AsrManager)
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

/// На какой модели служба распознаёт.
enum LoadedSpeechModel: Equatable, Sendable {
    case current
    /// Модель прошлой версии приложения: текущей на диске ещё нет, и служба
    /// работает на прежней, пока та скачивается.
    case previous
    /// Тоже прежняя, но по другой причине: текущая на диске и цела, а CoreML
    /// её не поднял. Качать заново бессмысленно — файлы те самые, — поэтому
    /// фоновой загрузки в этом случае нет.
    case previousAfterCurrentFailed
}

/// Что делать с моделями при запуске службы.
enum SpeechModelLoadPlan: Equatable {
    /// Текущая модель на диске и цела — обычный путь.
    case loadCurrent
    /// Текущей нет, прежняя цела: диктовка поднимается на ней сразу.
    case loadPrevious
    /// Годной модели нет вовсе — качать текущую и ждать, как при первой
    /// установке.
    case downloadCurrent
}

/// Решение отдельной функцией — потому что цена ошибки в нём высокая и
/// односторонняя: «прежняя вместо текущей» выглядела бы как работающая
/// диктовка, которая молча распознаёт хуже, чем могла бы.
func speechModelLoadPlan(currentIsIntact: Bool, previousIsIntact: Bool) -> SpeechModelLoadPlan {
    if currentIsIntact { return .loadCurrent }
    return previousIsIntact ? .loadPrevious : .downloadCurrent
}

actor TranscriptionWorker {
    private var engine: LoadedSpeechEngine?
    private var loadedProfile: SpeechModelProfile?
    private var loadedModel: LoadedSpeechModel?
    /// Текущая модель прошла проверку сумм и не загрузилась. До перезапуска
    /// процесса её больше не пробуем: иначе служба каждые две минуты
    /// перезапускалась бы ради модели, которая на этой машине не работает.
    private var currentFailedToLoad = false
    private(set) var ready = false
    /// Reentrancy backstop — see the comment above. True for the full
    /// duration of transcribe(), including across its await.
    private var inFlight = false

    /// `verificationProgress` — «проверено N файлов из M». Проверка идёт до
    /// двух секунд, и без неё окно всё это время утверждало, что служба
    /// остановлена.
    ///
    /// Возвращает, какая модель в итоге загружена: вызывающий по ответу
    /// решает, качать ли текущую в фоне.
    ///
    /// `current` и `previous` подставляет только отладочный прогон: служба
    /// всегда грузит настоящие описания.
    @discardableResult
    func load(profile requestedProfile: SpeechModelProfile,
              current: SpeechModelPackage = .current,
              previous: SpeechModelPackage = .previous,
              progressHandler: ProgressHandler? = nil,
              verificationProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> LoadedSpeechModel {
        let profile = requestedProfile.productionProfile
        if requestedProfile != profile {
            log("ASR: ignoring unsupported speech model \(requestedProfile.shortName); using \(profile.shortName)")
        }
        if ready, engine != nil, loadedProfile == profile, let loadedModel {
            switch loadedModel {
            case .current:
                log("ASR: \(profile.shortName) already ready")
                return .current
            case .previousAfterCurrentFailed:
                return .previousAfterCurrentFailed
            case .previous:
                // Пока текущая модель не доехала, перезапуск службы ничего
                // менять не должен: прежняя уже в памяти и работает.
                guard current.filesExist else {
                    log("ASR: still on \(previous.profile.shortName); \(profile.shortName) is not on disk yet")
                    return .previous
                }
            }
        }
        let previousIsLoaded = ready && engine != nil && loadedModel == .previous

        let currentIsIntact = !currentFailedToLoad
            && isIntact(current, onProgress: verificationProgress)
        // Прежнюю проверяем, только когда она нужна: это ещё полторы секунды
        // чтения с диска на каждом запуске.
        let previousIsIntact = !currentIsIntact
            && isIntact(previous, onProgress: verificationProgress)

        let t0 = Date()
        switch speechModelLoadPlan(currentIsIntact: currentIsIntact,
                                   previousIsIntact: previousIsIntact) {
        case .loadCurrent:
            log("ASR: loading cached \(profile.shortName) CoreML weights…")
            do {
                // loadLocal, а не load. Суммы уже сверены, и если CoreML всё
                // равно не поднимает модель, дело не в файлах: load в ответ
                // стёр бы кеш и качал 630 МБ заново — с тем же исходом.
                //
                // Прежняя модель, если она в памяти, выгружается только
                // после того, как поднялась новая: до этой строки отказ
                // оставляет диктовку рабочей.
                let models = try AsrModels.loadLocal(from: current.cacheDirectory,
                                                     version: current.version)
                engine = .parakeet(AsrManager(config: .default, models: models))
                loadedModel = .current
            } catch {
                log("ASR: \(profile.shortName) passed the integrity check but failed to load: \(error.localizedDescription)")
                currentFailedToLoad = true
                if previousIsLoaded {
                    log("ASR: staying on \(previous.profile.shortName)")
                    loadedModel = .previousAfterCurrentFailed
                    return .previousAfterCurrentFailed
                }
                guard isIntact(previous, onProgress: verificationProgress) else { throw error }
                log("ASR: loading \(previous.profile.shortName) instead")
                let models = try AsrModels.loadLocal(from: previous.cacheDirectory,
                                                     version: previous.version)
                engine = .parakeet(AsrManager(config: .default, models: models))
                loadedModel = .previousAfterCurrentFailed
            }

        case .loadPrevious:
            if previousIsLoaded {
                log("ASR: \(profile.shortName) on disk failed verification; staying on \(previous.profile.shortName)")
                return .previous
            }
            do {
                log("ASR: \(profile.shortName) is not usable yet; loading \(previous.profile.shortName) so dictation works meanwhile…")
                if engine != nil { await unload(keepingLoadFailure: true) }
                // И здесь loadLocal: прежняя модель в сеть ходить не должна
                // никогда.
                let models = try AsrModels.loadLocal(from: previous.cacheDirectory,
                                                     version: previous.version)
                engine = .parakeet(AsrManager(config: .default, models: models))
                loadedModel = currentFailedToLoad ? .previousAfterCurrentFailed : .previous
            } catch {
                // Файлы целы, а CoreML их не поднял. Запасной путь не должен
                // делать хуже, чем было без него: дальше — обычная загрузка.
                log("ASR: \(previous.profile.shortName) failed to load, falling back to a blocking download: \(error.localizedDescription)")
                engine = .parakeet(try await downloadAndLoad(
                    current,
                    progressHandler: progressHandler,
                    verificationProgress: verificationProgress))
                loadedModel = .current
            }

        case .downloadCurrent:
            log("ASR: downloading + verifying + loading \(profile.shortName) CoreML weights…")
            if engine != nil { await unload(keepingLoadFailure: true) }
            engine = .parakeet(try await downloadAndLoad(
                current,
                progressHandler: progressHandler,
                verificationProgress: verificationProgress))
            loadedModel = .current
        }

        loadedProfile = profile
        ready = true
        let loaded = loadedModel ?? .current
        let name = loaded == .current ? profile.shortName : previous.profile.shortName
        log("ASR: \(name) ready in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s")
        return loaded
    }

    /// Модель лежит на диске целиком и сходится с манифестом.
    private func isIntact(_ package: SpeechModelPackage,
                          onProgress: (@Sendable (Int, Int) -> Void)?) -> Bool {
        guard package.filesExist else { return false }
        do {
            try ModelIntegrity.verify(package, at: package.cacheDirectory, onProgress: onProgress)
            return true
        } catch {
            log("ASR: \(package.profile.shortName) on disk failed the integrity check: \(error.localizedDescription)")
            // Проверка оборвалась на середине, и счётчик «проверено N из M»
            // остался бы висеть в окне поверх всего, что идёт дальше.
            onProgress?(package.files.count, package.files.count)
            return false
        }
    }

    /// Ultra — та же архитектура, словарь и окно, что у v3, поэтому весь
    /// путь распознавания общий; отличаются только веса. Энкодер у неё в
    /// int8: у 6-битного энкодера v3 при определённом правом контексте
    /// портились токены, и исправленный вариант для v3 так и остался
    /// необязательным.
    private func downloadAndLoad(_ package: SpeechModelPackage,
                                 progressHandler: ProgressHandler?,
                                 verificationProgress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> AsrManager {
        if !FileManager.default.fileExists(atPath: package.cacheDirectory.path) {
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: package.profile)
        }
        var modelDirectory = try await AsrModels.download(to: package.cacheDirectory,
                                                          version: package.version,
                                                          progressHandler: progressHandler)
        do {
            try ModelIntegrity.verify(package, at: modelDirectory,
                                      onProgress: verificationProgress)
        } catch {
            log("ASR: model integrity check failed; redownloading once: \(error.localizedDescription)")
            verificationProgress?(package.files.count, package.files.count)
            try assertSufficientDiskSpaceForSpeechModelDownload(profile: package.profile)
            modelDirectory = try await AsrModels.download(to: package.cacheDirectory,
                                                          force: true,
                                                          version: package.version,
                                                          progressHandler: progressHandler)
            try ModelIntegrity.verify(package, at: modelDirectory,
                                      onProgress: verificationProgress)
        }
        let models = try await AsrModels.load(from: modelDirectory,
                                              version: package.version,
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
        case .parakeet(let asr):
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

    /// `keepingLoadFailure` — выгрузка внутри самой загрузки: память о том,
    /// что текущая модель не поднялась, должна её пережить. Выгрузка по
    /// просьбе человека (сброс кеша модели) начинает с чистого листа.
    func unload(keepingLoadFailure: Bool = false) async {
        if !keepingLoadFailure { currentFailedToLoad = false }
        engine = nil
        loadedProfile = nil
        loadedModel = nil
        ready = false
        log("ASR: unloaded")
    }
}

