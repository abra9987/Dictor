import AppKit
import AVFoundation

#if DEBUG
extension DictorSelfTest {
    static func testReadiness() throws {
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: false,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "not-ready app without core runtime should wait and rebuild only"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.microphone]),
            equals: .blockForPermissions([.microphone]),
            "core-ready app with missing microphone should block"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: [.accessibility]),
            equals: .blockForPermissions([.accessibility]),
            "ready app with missing accessibility should block"
        )
        try expect(
            readinessTransition(isReady: false,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .startHotkeyListener,
            "core-ready app with all permissions should start hotkey"
        )
        try expect(
            readinessTransition(isReady: true,
                                isCoreRuntimeReady: true,
                                missingPermissions: []),
            equals: .rebuildMenuOnly,
            "ready app with all permissions should remain ready and rebuild only"
        )

        try expect(
            productionSpeechModelProfile(rawValue: nil),
            equals: .multilingualUltra,
            "missing speech model setting should use the production default"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.multilingualUltra.rawValue),
            equals: .multilingualUltra,
            "stored Ultra speech model should remain valid"
        )
        // Сохранённая «multilingual_v3» лежит в настройках у каждого, кто
        // хоть раз выбирал модель до перехода: она обязана читаться и
        // переезжать, а не сбрасывать человека на экран выбора.
        try expect(
            productionSpeechModelProfile(rawValue: "multilingual_v3"),
            equals: .multilingualUltra,
            "stored v3 speech model setting should migrate to Ultra"
        )
        try expect(
            productionSpeechModelProfile(rawValue: SpeechModelProfile.englishUnified.rawValue),
            equals: .multilingualUltra,
            "deprecated Unified speech model setting should migrate to Ultra"
        )
        try expect(
            productionSpeechModelProfile(rawValue: "unknown_model"),
            equals: .multilingualUltra,
            "unknown speech model setting should migrate to Ultra"
        )
        try expect(SpeechModelProfile.multilingualV3.productionProfile,
                   equals: .multilingualUltra,
                   "a deprecated profile must resolve to the model that is actually loaded")

        try expect(
            speechModelSetupRowState(profile: .multilingualUltra,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: true,
                                     startupStatusTitle: "Downloading speech model… 50%",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Downloading speech model… 50%",
                                           status: "Loading",
                                           buttonTitle: nil),
            "setup checklist should show speech model progress"
        )
        try expect(
            speechModelSetupRowState(profile: .multilingualUltra,
                                     isSpeechModelReady: false,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: StartupFailure(stage: .speechModel, detail: "download failed")),
            equals: SetupChecklistRowState(detail: "download failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for speech model failures"
        )
        try expect(
            speechModelSetupRowState(profile: .multilingualUltra,
                                     isSpeechModelReady: true,
                                     isStartupInProgress: false,
                                     startupStatusTitle: "Loading speech model…",
                                     failure: nil),
            equals: SetupChecklistRowState(detail: "Parakeet Ultra is loaded locally.",
                                           status: "Ready",
                                           buttonTitle: nil),
            "setup checklist should show the speech model when ready"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: true,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: false,
                                    failure: StartupFailure(stage: .audioInput, detail: "no input device")),
            equals: SetupChecklistRowState(detail: "no input device",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for audio input failures"
        )
        try expect(
            audioInputSetupRowState(isSpeechModelReady: false,
                                    isCoreRuntimeReady: false,
                                    isStartupInProgress: true,
                                    failure: nil),
            equals: SetupChecklistRowState(detail: "Available after the speech model loads.",
                                           status: "Waiting",
                                           buttonTitle: nil),
            "setup checklist should not start audio before the speech model is ready"
        )
        try expect(
            hotkeySetupRowState(isReady: false,
                                hotkeyTestSucceeded: false,
                                triggerMode: .hold,
                                hotkeyName: "Right Option",
                                failure: StartupFailure(stage: .hotkeyListener, detail: "event tap failed")),
            equals: SetupChecklistRowState(detail: "event tap failed",
                                           status: "Needs retry",
                                           buttonTitle: "Retry"),
            "setup checklist should offer retry for hotkey listener failures"
        )
        try expect(
            hotkeySetupRowState(isReady: true,
                                hotkeyTestSucceeded: true,
                                triggerMode: .toggle,
                                hotkeyName: "F5",
                                failure: nil),
            equals: SetupChecklistRowState(detail: "Press F5 to dictate.",
                                           status: "Detected",
                                           buttonTitle: nil),
            "setup checklist should show detected hotkey state"
        )

        try expect(
            previousExitNoticeAction(previousRunWasActive: false),
            equals: .none,
            "clean previous exits should not show the abnormal-exit notice"
        )
        try expect(
            previousExitNoticeAction(previousRunWasActive: true),
            equals: .showNotice,
            "active run markers should show the abnormal-exit notice on next launch"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "SHA-256 mismatch").contains("Reset Speech Model Cache"),
            equals: true,
            "speech model integrity failures should point to cache reset"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "download timed out").contains("audio is not uploaded"),
            equals: true,
            "speech model download failures should preserve the local-audio privacy boundary"
        )
        try expect(
            speechModelFailureDetail(errorDescription: "Free some disk space, then retry loading the speech model."),
            equals: "Free some disk space, then retry loading the speech model.",
            "disk-space failures should not add unrelated reset-cache guidance"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, errorDescription: "no input device"),
            equals: "no input device",
            "non-model startup failures should keep their original detail"
        )

        let coreAudioStopError = NSError(
            domain: "com.apple.coreaudio.avfaudio",
            code: 1_937_010_544,
            userInfo: ["failed call": "PerformCommand(*ioNode, kAUStartIO, NULL, 0)"]
        )
        let coreAudioErrorDescription = audioStartupErrorDescription(coreAudioStopError)
        try expect(
            coreAudioErrorDescription.contains("OSStatus 1937010544"),
            equals: true,
            "CoreAudio startup errors should include the decimal OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("0x73746f70"),
            equals: true,
            "CoreAudio startup errors should include the hex OSStatus"
        )
        try expect(
            coreAudioErrorDescription.contains("'stop'"),
            equals: true,
            "CoreAudio startup errors should include printable four-character codes"
        )
        try expect(
            coreAudioErrorDescription.contains("PerformCommand(*ioNode, kAUStartIO, NULL, 0)"),
            equals: true,
            "CoreAudio startup errors should preserve the failed AVFAudio call"
        )
        try expect(
            startupFailureDetail(stage: .audioInput, error: coreAudioStopError).contains("restart CoreAudio"),
            equals: true,
            "exhausted CoreAudio startup failures should give OS recovery guidance"
        )
    }

    static func testSpeechModelStartupStatus() throws {
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0,
                                                phase: .listing)),
            equals: "Checking speech model files…",
            "listing phase should be visible during first-launch model setup"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.25,
                                                phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: "Downloading speech model… 50% (2/4)",
            "download phase should show quantized progress"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 0.5,
                                                phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: "Loading cached speech model…",
            "cached model load should not pretend to download files"
        )
        try expect(
            speechModelStartupStatusTitle(.init(fractionCompleted: 1,
                                                phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: "Preparing speech model…",
            "compile phase should be visible without exposing model internals"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0,
                                                  phase: .listing)),
            equals: nil,
            "listing phase should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0.25,
                                                  phase: .downloading(completedFiles: 2, totalFiles: 4))),
            equals: 0.5,
            "download phase should expose normalized model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 0.5,
                                                  phase: .downloading(completedFiles: 0, totalFiles: 0))),
            equals: nil,
            "cached model load should show indeterminate model progress"
        )
        try expect(
            speechModelStartupProgressValue(.init(fractionCompleted: 1,
                                                  phase: .compiling(modelName: "Encoder.mlmodelc"))),
            equals: nil,
            "compile phase should show indeterminate model progress"
        )
        let requiredBytes = speechModelDownloadRequiredBytes(for: .multilingualUltra,
                                                             headroomBytes: 100)
        try expect(
            requiredBytes,
            equals: 603 * 1024 * 1024 + 100,
            "speech model download requirement should include model estimate plus headroom"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualUltra,
                                              availableBytes: requiredBytes - 1,
                                              requiredBytes: requiredBytes)?.contains("Free some disk space"),
            equals: true,
            "low disk-space failures should explain how to recover"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualUltra,
                                              availableBytes: requiredBytes,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "disk-space check should pass once required space is available"
        )
        try expect(
            speechModelDiskSpaceFailureDetail(profile: .multilingualUltra,
                                              availableBytes: nil,
                                              requiredBytes: requiredBytes),
            equals: nil,
            "unknown disk-space readings should not block model startup"
        )
    }
}
#endif
