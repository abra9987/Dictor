import AppKit
import AVFoundation
import AudioToolbox

#if DEBUG
extension DictorSelfTest {
    static func testAudioLevelMetering() throws {
        var accumulator = AudioSampleAccumulator()
        accumulator.append([])
        accumulator.append([1, 2])
        accumulator.append([3, 4, 5])
        try expect(
            accumulator.sampleCount,
            equals: 5,
            "segmented audio accumulator should track total sample count"
        )
        let captured = accumulator.drain()
        try expect(
            accumulator.sampleCount,
            equals: 0,
            "segmented audio accumulator should reset after drain"
        )
        try expect(
            captured.flattened(),
            equals: [1, 2, 3, 4, 5],
            "segmented audio accumulator should preserve sample order when flattened"
        )

        try expect(
            normalizedAudioLevel(from: Array(repeating: 0, count: 128)),
            equals: 0,
            "silence should map to zero recording level"
        )

        let lowVoice = normalizedAudioLevel(from: Array(repeating: 0.004, count: 128))
        let quiet = normalizedAudioLevel(from: Array(repeating: 0.01, count: 128))
        let normal = normalizedAudioLevel(from: Array(repeating: 0.12, count: 128))
        let loud = normalizedAudioLevel(from: Array(repeating: 4.0, count: 128))

        guard lowVoice > 0 else {
            throw SelfTestFailure.failed("low close-mic voice should rise above the visual gate")
        }
        guard quiet > 0 else {
            throw SelfTestFailure.failed("quiet speech-like input should rise above zero")
        }
        guard normal > quiet else {
            throw SelfTestFailure.failed("higher RMS should produce a higher visual level")
        }
        try expect(
            loud,
            equals: 1,
            "out-of-range samples should clamp to maximum visual level"
        )

        try expect(
            normalizedAudioLevel(from: [.nan, .infinity, -.infinity]),
            equals: 0,
            "non-finite samples should not produce a visible level"
        )
        try expect(
            visibleRecordingLevel(rawLevel: .nan),
            equals: 0,
            "visible recording level should ignore non-finite input"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 0.8),
            equals: 0.8,
            "visible recording level should pass through normal input immediately"
        )
        try expect(
            visibleRecordingLevel(rawLevel: 1.2),
            equals: 1,
            "visible recording level should clamp high input"
        )

        let idlePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0)
        let voicePhaseSpeed = recordingHUDPhaseSpeed(mode: .recording, level: 0.8)
        guard voicePhaseSpeed > idlePhaseSpeed else {
            throw SelfTestFailure.failed("voice should visibly accelerate the recording waveform")
        }
        // Уровни 0.37 и 0.9 вместо 1 и 0: единица и ноль — мультипликативные
        // единица и аннулятор, с ними «независимость от уровня» прошла бы и
        // у реализации вида «константа × уровень».
        try expect(
            recordingHUDPhaseSpeed(mode: .transcribing, level: 0.37),
            equals: RECORDING_HUD_TRANSCRIBING_PHASE_SPEED,
            "transcribing animation speed should not depend on stale microphone level"
        )
        try expect(
            recordingHUDPhaseSpeed(mode: .error, level: 0.9),
            equals: 0,
            "error HUD should be static (zero phase speed) at any level"
        )
    }

    static func testAudioConversion() throws {
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 48_000,
                                               channels: 2,
                                               interleaved: false),
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 48_000,
                                             channels: 1,
                                             interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: 16_000,
                                               channels: 1,
                                               interleaved: false),
              let stereo = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 480),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 480),
              let stereoChannels = stereo.floatChannelData,
              let monoChannel = mono.floatChannelData?[0] else {
            throw SelfTestFailure.failed("could not create audio conversion test buffers")
        }
        stereo.frameLength = 480
        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = 0.02
        }

        let rms = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: rms),
            equals: [0],
            "manual mono mix should select the active close-mic channel when another channel is near-silent"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: rms),
                     frameCount: 480,
                     to: monoChannel)
        mono.frameLength = 480
        try expect(
            monoChannel[0],
            equals: 0.5,
            "manual mono mix should preserve the selected active channel"
        )

        for i in 0..<480 {
            stereoChannels[0][i] = 0.5
            stereoChannels[1][i] = -0.5
        }
        let balancedRMS = channelRMSValues(channels: stereoChannels, channelCount: 2, frameCount: 480)
        try expect(
            selectedMonoMixChannelIndices(channelRMS: balancedRMS),
            equals: [0, 1],
            "manual mono mix should average multiple similarly active channels"
        )
        writeMonoMix(channels: stereoChannels,
                     selectedChannels: selectedMonoMixChannelIndices(channelRMS: balancedRMS),
                     frameCount: 480,
                     to: monoChannel)
        try expect(
            monoChannel[0],
            equals: 0,
            "manual mono mix should average selected channels with equal weight"
        )

        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 320),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat) else {
            throw SelfTestFailure.failed("could not create audio converter")
        }
        var error: NSError?
        let inputProvider = AudioConverterInputProvider(buffer: mono)
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            inputProvider.provide(outStatus: outStatus)
        }
        if status == .error {
            throw SelfTestFailure.failed("audio conversion failed: \(error?.localizedDescription ?? "?")")
        }
        guard converted.format.channelCount == 1,
              Int(converted.format.sampleRate) == 16_000,
              converted.frameLength > 0 else {
            throw SelfTestFailure.failed("audio conversion should produce 16 kHz mono samples")
        }

        try testAudioInputFormatReconciliation()
    }

    /// Guards the fix for a freeze that had no symptom other than a
    /// status line stuck on "Starting audio input…": the input node
    /// advertised the default *output* device's 44.1 kHz while the mic
    /// ran at 48 kHz, that stale format went into installTap, and the
    /// Objective-C exception it raised suspended the startup thread.
    private static func testAudioInputFormatReconciliation() throws {
        guard let mic48k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: 48_000,
                                         channels: 1,
                                         interleaved: false),
              let speaker44k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: 44_100,
                                             channels: 1,
                                             interleaved: false),
              let stereo48k = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: 48_000,
                                            channels: 2,
                                            interleaved: false) else {
            throw SelfTestFailure.failed("could not create input format reconciliation test formats")
        }

        try expect(
            audioFormatsInterchangeable(mic48k, mic48k),
            equals: true,
            "a format should be interchangeable with itself"
        )
        try expect(
            audioFormatsInterchangeable(mic48k, speaker44k),
            equals: false,
            "a 48 kHz buffer must not be fed to a converter built for 44.1 kHz"
        )
        try expect(
            audioFormatsInterchangeable(mic48k, stereo48k),
            equals: false,
            "channel count difference should force a converter rebuild"
        )
        try expect(
            audioFormatsInterchangeable(mic48k, nil),
            equals: false,
            "an unconfigured tap format should always force a rebuild"
        )
        try expect(
            audioFormatIsUsable(mic48k),
            equals: true,
            "a 48 kHz mono format should be usable"
        )

        // The trap itself: without it the raise below would suspend
        // this thread instead of failing, and the whole reason the
        // freeze went undiagnosed for a session is that nothing
        // reported it.
        var ranPastRaise = false
        var trapped: Error?
        do {
            try withObjCExceptionsAsErrors {
                NSException(name: .invalidArgumentException,
                            reason: "self-test raise",
                            userInfo: nil).raise()
                ranPastRaise = true
            }
        } catch {
            trapped = error
        }
        try expect(
            ranPastRaise,
            equals: false,
            "an Objective-C exception should abort the trapped block"
        )
        try expect(
            (trapped as NSError?)?.localizedDescription,
            equals: "self-test raise",
            "a trapped Objective-C exception should surface its reason as an error"
        )

        var swiftErrorPropagated = false
        do {
            try withObjCExceptionsAsErrors {
                throw SelfTestFailure.failed("swift error")
            }
        } catch {
            swiftErrorPropagated = true
        }
        try expect(
            swiftErrorPropagated,
            equals: true,
            "the exception trap should still propagate ordinary Swift errors"
        )
    }

    static func testAudioInputDeviceFiltering() throws {
        let pseudo = AudioInputDevice(id: 1,
                                      uid: "CADefaultDeviceAggregate-42159-0",
                                      name: "CADefaultDeviceAggregate-42159-0")
        let real = AudioInputDevice(id: 2,
                                    uid: "real-yeti-nano",
                                    name: "Yeti Nano")

        try expect(
            isDefaultAggregateAudioInputDevice(pseudo),
            equals: true,
            "CoreAudio default aggregate devices should be recognized"
        )
        try expect(
            isDefaultAggregateAudioInputDevice(real),
            equals: false,
            "named microphones should remain selectable"
        )
        try expect(
            normalizedInputDevicePreference(" Yeti Nano\n"),
            equals: "Yeti Nano",
            "input device preferences should be trimmed before storing"
        )
        try expect(
            normalizedInputDevicePreference(pseudo.uid),
            equals: nil,
            "input device preferences should reject CoreAudio default aggregates"
        )
        try expect(
            normalizedInputDevicePreference("real\u{0}device"),
            equals: nil,
            "input device preferences should reject NUL bytes"
        )
        try expect(
            normalizedInputDevicePreference(String(repeating: "x", count: MAX_INPUT_DEVICE_PREFERENCE_BYTES + 1)),
            equals: nil,
            "input device preferences should reject oversized values"
        )
        try expect(
            audioInputDevice(matching: pseudo.uid, in: [pseudo, real])?.uid,
            equals: nil,
            "CoreAudio default aggregate preferences should fall back to system default"
        )
        try expect(
            audioInputDevice(matching: " real-yeti-nano\n", in: [real])?.uid,
            equals: "real-yeti-nano",
            "input device preferences should resolve after trimming"
        )
        try expect(
            audioInputDevice(matching: "Yeti Nano", in: [real])?.uid,
            equals: "real-yeti-nano",
            "named microphone preferences should still resolve by display name"
        )
    }
}
#endif
