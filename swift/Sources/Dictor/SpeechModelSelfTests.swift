import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testModelIntegrity() throws {
        try testSpeechModelCachePathSafety()

        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-model-integrity-\(UUID().uuidString)",
                                    isDirectory: true)
        let modelDir = root.appendingPathComponent("Toy.mlmodelc", isDirectory: true)
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let modelFile = modelDir.appendingPathComponent("model.mil")
        try Data("hello".utf8).write(to: modelFile)
        let expected = [
            ModelFileDigest(
                relativePath: "Toy.mlmodelc/model.mil",
                sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
            )
        ]
        try ModelIntegrity.verifyFiles(root: root,
                                       expectedFiles: expected,
                                       strictDirectories: ["Toy.mlmodelc"])

        var rejectedMismatch = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: String(repeating: "0", count: 64))
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedMismatch = true
        }
        try expect(rejectedMismatch, equals: true,
                   "model integrity should reject digest mismatches")

        try Data("extra".utf8).write(to: modelDir.appendingPathComponent("extra.bin"))
        var rejectedUnexpectedFile = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedFile = true
        }
        try expect(rejectedUnexpectedFile, equals: true,
                   "model integrity should reject unpinned files in strict model bundles")

        try fm.removeItem(at: modelDir.appendingPathComponent("extra.bin"))
        try fm.createDirectory(at: modelDir.appendingPathComponent("empty-extra", isDirectory: true),
                               withIntermediateDirectories: true)
        var rejectedUnexpectedDirectory = false
        do {
            try ModelIntegrity.verifyFiles(root: root,
                                           expectedFiles: expected,
                                           strictDirectories: ["Toy.mlmodelc"])
        } catch is ModelIntegrityError {
            rejectedUnexpectedDirectory = true
        }
        try expect(rejectedUnexpectedDirectory, equals: true,
                   "model integrity should reject unpinned directories in strict model bundles")

        var rejectedBadDigest = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(relativePath: "Toy.mlmodelc/model.mil",
                                    sha256: "not-a-sha256")
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedBadDigest = true
        }
        try expect(rejectedBadDigest, equals: true,
                   "model integrity should reject malformed manifest digests")

        var rejectedDotSegment = false
        do {
            try ModelIntegrity.verifyFiles(
                root: root,
                expectedFiles: [
                    ModelFileDigest(
                        relativePath: "Toy.mlmodelc/./model.mil",
                        sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
                    )
                ],
                strictDirectories: ["Toy.mlmodelc"]
            )
        } catch is ModelIntegrityError {
            rejectedDotSegment = true
        }
        try expect(rejectedDotSegment, equals: true,
                   "model integrity should reject dot path segments")

        let symlinkedModelFile = modelDir.appendingPathComponent("model-link.mil")
        try fm.createSymbolicLink(at: symlinkedModelFile, withDestinationURL: modelFile)
        var rejectedSymlinkHashRead = false
        do {
            _ = try ModelIntegrity.sha256Hex(of: symlinkedModelFile,
                                             relativePath: "Toy.mlmodelc/model-link.mil")
        } catch is ModelIntegrityError {
            rejectedSymlinkHashRead = true
        }
        try expect(rejectedSymlinkHashRead, equals: true,
                   "model integrity hashing should not follow leaf symlinks")

        // Манифест обязан называть веса и граф каждой из четырёх моделей и
        // словарь: пустой или обрезанный список прошёл бы компиляцию и
        // сломал бы загрузку у каждого, у кого кеша ещё нет.
        // То же — для модели прошлой версии: служба поднимается на ней,
        // пока скачивается текущая, и проверяется она тем же способом.
        for package in [SpeechModelPackage.current, .previous] {
            let name = package.profile.shortName
            let manifestPaths = Set(package.files.map(\.relativePath))
            for model in ["Decoder", "Encoder", "JointDecisionv3", "Preprocessor"] {
                for file in ["coremldata.bin", "model.mil", "weights/weight.bin"] {
                    try expect(manifestPaths.contains("\(model).mlmodelc/\(file)"), equals: true,
                               "\(name) manifest must pin \(model).mlmodelc/\(file)")
                }
                try expect(package.strictDirectories.contains("\(model).mlmodelc"), equals: true,
                           "\(name) must not tolerate stray files in \(model).mlmodelc")
            }
            try expect(manifestPaths.contains("parakeet_vocab.json"), equals: true,
                       "\(name) manifest must pin the vocabulary")
            try expect(package.repositoryCommit.count, equals: 40,
                       "\(name) manifest must name the repository commit it was taken from")

            // Если модель лежит на этой машине — манифест обязан с ней сходиться.
            if package.filesExist {
                try ModelIntegrity.verify(package, at: package.cacheDirectory)
            }
        }
        try expect(SpeechModelPackage.current.cacheDirectory
                    == SpeechModelPackage.previous.cacheDirectory,
                   equals: false,
                   "the current and the previous model must live in different directories")
        try expect(speechModelCacheDirectory(for: .multilingualUltra),
                   equals: SpeechModelPackage.current.cacheDirectory,
                   "cache reset must point at the current model, never at the previous one")

        try testSpeechModelUpdate()
    }

    /// Обновление модели без простоя: какую модель грузить, когда переходить
    /// на скачанную и как часто повторять неудавшуюся загрузку. Всё это —
    /// чистые решения; сама загрузка и CoreML здесь не трогаются.
    private static func testSpeechModelUpdate() throws {
        try expect(speechModelLoadPlan(currentIsIntact: true, previousIsIntact: true),
                   equals: .loadCurrent,
                   "the current model always wins when it is on disk")
        try expect(speechModelLoadPlan(currentIsIntact: true, previousIsIntact: false),
                   equals: .loadCurrent,
                   "the current model does not need the previous one")
        try expect(speechModelLoadPlan(currentIsIntact: false, previousIsIntact: true),
                   equals: .loadPrevious,
                   "without the current model dictation must come up on the previous one")
        try expect(speechModelLoadPlan(currentIsIntact: false, previousIsIntact: false),
                   equals: .downloadCurrent,
                   "with no usable model the service downloads and waits, as on first install")

        func due(ready: Bool = true, occupied: Bool = false,
                 quiet: TimeInterval = SPEECH_MODEL_SWITCH_QUIET_SECONDS) -> Bool {
            SpeechModelUpdater.switchIsDue(updateIsReady: ready,
                                           serviceIsOccupied: occupied,
                                           secondsSinceLastDictation: quiet)
        }
        try expect(due(), equals: true,
                   "a downloaded model must be picked up once dictation has been quiet long enough")
        try expect(due(ready: false), equals: false,
                   "nothing to switch to while the download is unfinished")
        try expect(due(occupied: true), equals: false,
                   "never restart the service under a recording or a transcription")
        try expect(due(quiet: SPEECH_MODEL_SWITCH_QUIET_SECONDS - 1), equals: false,
                   "a pause between two phrases is not idleness")

        try expect(SpeechModelUpdater.retryDelay(afterFailedAttempt: 1), equals: 300,
                   "the first retry comes in five minutes")
        try expect(SpeechModelUpdater.retryDelay(afterFailedAttempt: 2), equals: 900,
                   "the second retry comes in fifteen minutes")
        try expect(SpeechModelUpdater.retryDelay(afterFailedAttempt: 3), equals: 3600,
                   "later retries come hourly")
        try expect(SpeechModelUpdater.retryDelay(afterFailedAttempt: 40), equals: 3600,
                   "retries never stop and never get rarer than hourly")
        // Скачалось и не сошлось с манифестом — это не сеть: каждая попытка
        // стоит 630 МБ и кончится тем же, поэтому она одна в сутки.
        try expect(
            SpeechModelUpdater.retryDelay(
                afterFailedAttempt: 1,
                failure: SpeechModelUpdateError.downloadFailedVerification("probe")),
            equals: 86_400,
            "a download that fails verification must not be repeated every few minutes")

        // Состояние доезжает до окна через файл службы: поля по отдельности
        // обязаны собираться обратно в то же значение.
        var state = AgentRuntimeState(status: "ready", detail: "", updatedAt: 0, pid: 1,
                                      isReady: true, isRecording: false, isTranscribing: false,
                                      speechModelReady: true, missingPermissions: [],
                                      hotkeyName: "", triggerMode: "")
        try expect(state.speechModelUpdate, equals: nil,
                   "a service on the current model reports no model update")
        state.previousSpeechModelName = "Parakeet TDT v3"
        state.speechModelUpdatePhase = SpeechModelUpdateStatus.Phase.downloading.rawValue
        state.speechModelUpdateFraction = 0.34
        let decoded = try JSONDecoder().decode(AgentRuntimeState.self,
                                               from: JSONEncoder().encode(state))
        try expect(decoded.speechModelUpdate,
                   equals: SpeechModelUpdateStatus(previousModelName: "Parakeet TDT v3",
                                                   phase: .downloading, fraction: 0.34),
                   "the model update must survive the trip through the service state file")

        // И до человека: подвал остаётся «Готово», но вторая строка говорит,
        // что происходит с новой моделью, — в каждой фазе своё.
        var subtitles: Set<String> = []
        let phases: [SpeechModelUpdateStatus.Phase] = [.downloading, .waitingForIdle,
                                                       .retrying, .failedToLoad]
        for phase in phases {
            let update = SpeechModelUpdateStatus(previousModelName: "Parakeet TDT v3",
                                                 phase: phase, fraction: nil)
            let kind = ServiceStatusKind.ready(latencyMilliseconds: 180, modelUpdate: update)
            try expect(kind.identity, equals: "ready",
                       "running on the previous model is still «ready», not a new state")
            try expect(kind.isBusy, equals: false,
                       "running on the previous model must not look like work in progress")
            let shown = serviceStatusPresentation(kind, language: .russian)
            try expect(shown.title,
                       equals: serviceStatusPresentation(.ready(latencyMilliseconds: 180),
                                                         language: .russian).title,
                       "the title stays «ready» while the new model downloads")
            subtitles.insert(shown.subtitle)
        }
        try expect(subtitles.count, equals: phases.count,
                   "each phase of the model update must read differently")
        try expect(
            ServiceStatusKind.ready(
                latencyMilliseconds: 180,
                modelUpdate: SpeechModelUpdateStatus(previousModelName: "Parakeet TDT v3",
                                                     phase: .downloading, fraction: 0.34)
            ).fingerprint
            == ServiceStatusKind.ready(
                latencyMilliseconds: 180,
                modelUpdate: SpeechModelUpdateStatus(previousModelName: "Parakeet TDT v3",
                                                     phase: .downloading, fraction: 0.35)
            ).fingerprint,
            equals: false,
            "download progress must repaint the window")
    }

    private static func testSpeechModelCachePathSafety() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dictor-cache-safety-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("FluidAudio", isDirectory: true)
        let cache = support.appendingPathComponent("Models/parakeet-v3", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try expect(
            isSafeSpeechModelCacheDirectory(
                cache,
                fluidAudioSupportDirectory: support
            ),
            equals: true,
            "speech model cache reset should allow nested FluidAudio cache paths"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(cache,
                                                             fluidAudioSupportDirectory: support),
            equals: true,
            "speech model cache reset should allow existing plain cache directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(support, fluidAudioSupportDirectory: support),
            equals: false,
            "speech model cache reset should not remove the FluidAudio support root"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.deletingLastPathComponent().appendingPathComponent("FluidAudioBackup/parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject sibling support directories"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(
                support.appendingPathComponent("../Outside/parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject paths that normalize outside FluidAudio support"
        )

        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        let outsideCache = outside.appendingPathComponent("parakeet-v3", isDirectory: true)
        try fm.createDirectory(at: outsideCache, withIntermediateDirectories: true)

        let leafLink = support.appendingPathComponent("Models/link-cache", isDirectory: true)
        try fm.createSymbolicLink(at: leafLink, withDestinationURL: outsideCache)
        try expect(
            isSafeSpeechModelCacheDirectory(leafLink, fluidAudioSupportDirectory: support),
            equals: true,
            "speech model cache reset path check should remain string-only"
        )
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(leafLink,
                                                             fluidAudioSupportDirectory: support),
            equals: false,
            "speech model cache reset should reject leaf symlink directories before deletion"
        )

        let linkedParent = support.appendingPathComponent("LinkedModels", isDirectory: true)
        try fm.createSymbolicLink(at: linkedParent, withDestinationURL: outside)
        try expect(
            isExistingSpeechModelCacheDirectorySafeForRemoval(
                linkedParent.appendingPathComponent("parakeet-v3", isDirectory: true),
                fluidAudioSupportDirectory: support
            ),
            equals: false,
            "speech model cache reset should reject symlinked parent directories before deletion"
        )
        try expect(
            isSafeSpeechModelCacheDirectory(speechModelCacheDirectory(for: .multilingualUltra)),
            equals: true,
            "FluidAudio model cache path should remain inside FluidAudio Application Support"
        )
        let defaultModelCache = speechModelCacheDirectory(for: .multilingualUltra)
        if fm.fileExists(atPath: defaultModelCache.path) {
            try expect(
                isExistingSpeechModelCacheDirectorySafeForRemoval(defaultModelCache),
                equals: true,
                "existing FluidAudio model cache path should remain removable"
            )
        }
    }
}
#endif
