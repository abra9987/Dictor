// Самотесты сочетаний на живых событиях клавиатуры: какие нажатия глотаются,
// аккорды из модификаторов, Enter после диктовки, режим переключения и Esc.

import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testHandledHotkeySuppression() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "F-key keyDown should suppress and press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: 97), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "non-hotkey keyDown should pass through"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "F-key keyUp should suppress and release"
        )

        try expect(
            state.transition(for: event(.keyDown, keycode: f7.keycode), hotkey: f7, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "recorded F-key keyDown should suppress and press"
        )
    }

    static func testCustomShortcutMatching() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: 40,
                                    modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown, keycode: 40, flags: commandShift),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "custom shortcut should trigger when its exact modifiers are held"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: 40),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "custom shortcut release should not depend on modifier release order"
        )
        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             triggerMode: .hold,
                             isRecording: false),
            equals: .pass,
            "custom shortcut should ignore incomplete modifier combinations"
        )
    }

    /// Cmd+Tab переставал переключать приложения, стоило назначить
    /// диктовку на «Command + правый Option»: перехватчик глотал каждое
    /// событие Command, потому что Command входит в сочетание.
    /// Cmd+C при этом работал и сбивал с толку — обычные сочетания
    /// читают флаг из самого события клавиши, а переключатель приложений
    /// живёт на удержании Command.
    private static func testCompanionModifierReachesTheSystem() throws {
        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: RIGHT_OPTION_KEYCODE,
                                    modifiers: .maskCommand)
        let unrelatedEnter = hotkeyChoice(forKeycode: 80)
        let command = CGEventFlags.maskCommand.rawValue

        func send(keycode: CGKeyCode, flags: UInt64) -> HotkeyTransitionResult {
            state.transition(for: event(.flagsChanged, keycode: keycode, flags: flags),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnter,
                             triggerMode: .toggle,
                             isRecording: false)
        }

        try expect(
            send(keycode: LEFT_COMMAND_KEYCODE, flags: command),
            equals: .pass,
            "holding Command alone must reach the system, or Cmd+Tab never opens"
        )
        try expect(
            send(keycode: LEFT_COMMAND_KEYCODE, flags: 0),
            equals: .pass,
            "releasing Command must reach the system, or it stays stuck down"
        )

        // Само сочетание при этом продолжает работать.
        _ = send(keycode: LEFT_COMMAND_KEYCODE, flags: command)
        try expect(
            send(keycode: RIGHT_OPTION_KEYCODE,
                 flags: command | CGEventFlags.maskAlternate.rawValue),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "the assigned key still starts dictation and is still swallowed"
        )
        // И отпускание Command после сочетания тоже обязано дойти:
        // иначе система остаётся уверенной, что Command всё ещё зажат.
        _ = send(keycode: RIGHT_OPTION_KEYCODE, flags: command)
        try expect(
            send(keycode: LEFT_COMMAND_KEYCODE, flags: 0).suppress,
            equals: false,
            "the trailing Command release must reach the system too"
        )
    }

    static func testModifierOnlyChordMatching() throws {
        try testCompanionModifierReachesTheSystem()

        var state = HotkeyTransitionState()
        let shortcut = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                    modifiers: [.maskAlternate, .maskCommand])
        let unrelatedEnterShortcut = hotkeyChoice(forKeycode: 80)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = alternate | CGEventFlags.maskCommand.rawValue

        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            // Раньше здесь стояло «первый модификатор аккорда
            // зарезервирован» — и это утверждение и было багом: пока
            // сочетание не набрано, модификатор принадлежит системе.
            "a companion modifier on its own belongs to the system, not to us"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "Option+Command should start dictation when configured as the main shortcut"
        )
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        _ = state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: CGEventFlags.maskCommand.rawValue),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true)
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: shortcut,
                             enterHotkey: unrelatedEnterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            // Аккорд замкнулся на клавише-спутнике, а не на назначенной,
            // поэтому событие уходит системе: диктовка останавливается,
            // но модификатор остаётся её собственностью.
            equals: HotkeyTransitionResult(suppress: false, actions: [.release]),
            "the same modifier chord should stop dictation on its next activation"
        )
    }

    static func testConfigurableEnterShortcut() throws {
        var state = HotkeyTransitionState()
        let standard = hotkeyChoice(forKeycode: 96)
        let enterShortcut = hotkeyChoice(forKeycode: 40,
                                         modifiers: [.maskCommand, .maskShift])
        let commandShift = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue

        try expect(
            state.transition(for: event(.keyDown,
                                        keycode: 40,
                                        flags: commandShift),
                             hotkey: standard,
                             enterHotkey: enterShortcut,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "a user-configured Enter shortcut should use the Enter completion path"
        )
    }

    static func testFKeyAutoRepeatSuppressesWithoutAction() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "initial F-key keyDown should press"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "F-key autorepeat keyDown should suppress without action"
        )
    }

    static func testRightModifierReleaseWithLeftFlagStillSet() throws {
        var state = HotkeyTransitionState()
        let rightOption = hotkeyChoice(forKeycode: 61)
        let alternate = CGEventFlags.maskAlternate.rawValue

        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right modifier flagsChanged should press"
        )
        try expect(
            state.transition(for: event(.flagsChanged, keycode: rightOption.keycode, flags: alternate), hotkey: rightOption, triggerMode: .hold, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right modifier release should be recognized while left-side flag remains set"
        )

        var toggleState = HotkeyTransitionState()
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "right Option should start when it is the configured toggle hotkey"
        )
        _ = toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true)
        try expect(
            toggleState.transition(for: event(.flagsChanged,
                                              keycode: rightOption.keycode,
                                              flags: alternate),
                                   hotkey: rightOption,
                                   triggerMode: .toggle,
                                   isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "right Option should stop instead of being swallowed by the Enter chord"
        )
    }

    static func testOptionCommandEnterChordStopsWithEnter() throws {
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = CGEventFlags.maskAlternate.rawValue
        let commandAlternate = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskAlternate.rawValue

        var state = HotkeyTransitionState()
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "right option opens the enter chord but stays the system's key"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: commandAlternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.releaseAlternate]),
            "right option + right command should stop dictation through the alternate release path"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_COMMAND_KEYCODE,
                                        flags: alternate),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .suppressOnly,
            "enter chord should suppress the paired right command release"
        )
        try expect(
            state.transition(for: event(.flagsChanged,
                                        keycode: RIGHT_OPTION_KEYCODE,
                                        flags: 0),
                             hotkey: rightCommand,
                             triggerMode: .toggle,
                             isRecording: false),
            equals: .pass,
            "the paired right option release goes back to the system, not swallowed"
        )

    }

    static func testEnterShortcutModeSelection() throws {
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insert),
            equals: false,
            "insert mode should make the primary shortcut finish without Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insert),
            equals: true,
            "the alternate shortcut should invert insert mode"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .standard,
                                           primaryBehavior: .insertAndEnter),
            equals: true,
            "insert-and-Enter mode should make the primary shortcut press Enter"
        )
        try expect(
            shouldPressEnterAfterDictation(shortcut: .alternate,
                                           primaryBehavior: .insertAndEnter),
            equals: false,
            "the alternate shortcut should invert insert-and-Enter mode"
        )

        var state = HotkeyTransitionState()
        let primary = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        let alternate = hotkeyChoice(forKeycode: 96)
        try expect(
            state.transition(for: event(.keyDown, keycode: alternate.keycode),
                             hotkey: primary,
                             enterHotkey: alternate,
                             alternateCompletionEnabled: false,
                             triggerMode: .toggle,
                             isRecording: true),
            equals: .pass,
            "a disabled alternate shortcut should not be intercepted"
        )
    }

    static func testTogglePressFlipsOnceAndReleaseIsNoOp() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "first toggle press should start"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: .suppressOnly,
            "toggle release should be a no-op"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "second toggle press should stop"
        )
    }

    static func testToggleGatedPressDoesNotFlipToggleState() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        // A press the app would reject (e.g. a transcription in
        // flight) must suppress the key but not flip the toggle —
        // otherwise the next press emits a swallowed .release and
        // only the third press records.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.rejectedBusyPress]),
            "gated toggle press should suppress without flipping state but emit rejectedBusyPress for feedback"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: false, canStartRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "press after a gated press should start immediately"
        )
        // The stop-side press must NOT be gated: once a recording is
        // active (canStartRecording is false by definition), the
        // press still has to stop it.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .toggle, isRecording: true, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.release]),
            "gate must not block the toggle press that stops a recording"
        )
        // Hold mode ignores the gate entirely — handlePress discarding
        // the press leaves no state behind in hold mode.
        try expect(
            state.transition(for: event(.keyDown, keycode: f5.keycode), hotkey: f5, triggerMode: .hold, isRecording: false, canStartRecording: false),
            equals: HotkeyTransitionResult(suppress: true, actions: [.press]),
            "hold-mode press should be unaffected by the gate"
        )
    }

    static func testEscapePassesThroughWhenNotRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyDown should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape autorepeat should pass through when not recording"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "Escape keyUp should pass through when not recording"
        )
    }

    static func testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording() throws {
        var state = HotkeyTransitionState()
        let f5 = hotkeyChoice(forKeycode: 96)

        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: true),
            equals: HotkeyTransitionResult(suppress: true, actions: [.cancel]),
            "Escape keyDown should suppress and cancel while recording"
        )
        try expect(
            state.transition(for: event(.keyDown, keycode: ESCAPE_KEYCODE, isAutoRepeat: true), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "Escape autorepeat from a canceled press should stay suppressed"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .suppressOnly,
            "paired Escape keyUp should stay suppressed after cancel"
        )
        try expect(
            state.transition(for: event(.keyUp, keycode: ESCAPE_KEYCODE), hotkey: f5, triggerMode: .hold, isRecording: false),
            equals: .pass,
            "later Escape keyUp should pass through once the canceled press is complete"
        )
    }

    static func event(
        _ type: CGEventType,
        keycode: CGKeyCode,
        flags: UInt64 = 0,
        isAutoRepeat: Bool = false
    ) -> HotkeyEventSnapshot {
        HotkeyEventSnapshot(
            typeRawValue: type.rawValue,
            keycode: keycode,
            flagsRawValue: flags,
            isAutoRepeat: isAutoRepeat
        )
    }
}
#endif
