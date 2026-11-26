import AppKit

#if DEBUG
extension DictorSelfTest {
    static func testHotkey() throws {
        try testHotkeyPreferenceNormalization()
        try testHotkeyPreferenceUpdateResults()
        try testHotkeyRecorderCaptureFlow()
        try testHotkeyRecorderRestartActions()
        try testHandledHotkeySuppression()
        try testCustomShortcutMatching()
        try testModifierOnlyChordMatching()
        try testConfigurableEnterShortcut()
        try testFKeyAutoRepeatSuppressesWithoutAction()
        try testRightModifierReleaseWithLeftFlagStillSet()
        try testOptionCommandEnterChordStopsWithEnter()
        try testEnterShortcutModeSelection()
        try testTogglePressFlipsOnceAndReleaseIsNoOp()
        try testToggleGatedPressDoesNotFlipToggleState()
        try testEscapePassesThroughWhenNotRecording()
        try testEscapeSuppressesCancelRepeatAndKeyUpWhileRecording()
        try testKeycapLabels()
    }

    /// The settings row drew «Command + правый Option» as «⌘ прав.»:
    /// the label was derived from the chord's whole name, so the
    /// required modifier was mistaken for the key. Chords whose key
    /// really is Command hid the bug by coming out right anyway.
    private static func testKeycapLabels() throws {
        func labels(keycode: CGKeyCode, modifiers: CGEventFlags) -> [String] {
            keycapLabels(for: hotkeyChoice(forKeycode: keycode, modifiers: modifiers),
                         language: .russian)
        }

        try expect(
            labels(keycode: 61, modifiers: .maskCommand),
            equals: ["⌘", "⌥ прав."],
            "Command with the right Option should draw the Option key, not a second Command"
        )
        try expect(
            labels(keycode: 54, modifiers: .maskShift),
            equals: ["⇧", "⌘ прав."],
            "Shift with the right Command should draw the Command key"
        )
        try expect(
            labels(keycode: 62, modifiers: .maskShift),
            equals: ["⇧", "⌃ прав."],
            "Shift with the right Control should draw the Control key"
        )
        try expect(
            labels(keycode: 58, modifiers: []),
            equals: ["⌥ лев."],
            "a bare modifier shortcut should draw its own side"
        )
    }

    private static func testHotkeyPreferenceNormalization() throws {
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: Int(DEFAULT_HOTKEY_KEYCODE))),
            equals: DEFAULT_HOTKEY_KEYCODE,
            "stored hotkey normalization should keep supported numeric keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: " 96\n"),
            equals: CGKeyCode(96),
            "stored hotkey normalization should accept legacy string keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 98)),
            equals: CGKeyCode(98),
            "stored hotkey normalization should accept recorded F-key keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(98)),
            equals: HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil),
            "recorded F-key choices should get a stable display name"
        )
        try expect(
            localizedHotkeyName(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE),
                                language: .russian),
            equals: "Правый Command",
            "Russian UI should localize a modifier-only shortcut"
        )
        try expect(
            localizedHotkeyName(hotkeyChoice(forKeycode: 49, modifiers: .maskAlternate),
                                language: .russian),
            equals: "⌥Пробел",
            "Russian UI should localize a chord key name"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: 999)),
            equals: nil,
            "stored hotkey normalization should reject unsupported keycodes"
        )
        try expect(
            normalizedHotkeyKeycode(storedValue: NSNumber(value: -1)),
            equals: nil,
            "stored hotkey normalization should reject negative keycodes"
        )
        try expect(
            hotkeyChoice(forKeycode: CGKeyCode(999)),
            equals: hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE),
            "unknown hotkey choices should fall back to the default"
        )

        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98)),
            equals: .accept(HotkeyChoice(name: "F7", keycode: 98, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept F-key presses outside the quick-pick list"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 0)),
            equals: .accept(HotkeyChoice(name: "A", keycode: 0, isModifier: false, modifierFlag: nil)),
            "hotkey recorder should accept a single typing key"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown,
                                               keycode: 40,
                                               flags: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue)),
            equals: .accept(HotkeyChoice(name: "⇧⌘K",
                                         keycode: 40,
                                         isModifier: false,
                                         modifierFlag: nil,
                                         requiredModifiers: [.maskCommand, .maskShift])),
            "hotkey recorder should accept multi-key shortcuts"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.keyDown, keycode: 98, isAutoRepeat: true)),
            equals: .ignore,
            "hotkey recorder should ignore auto-repeat"
        )
        try expect(
            hotkeyRecordingDecision(for: event(.flagsChanged,
                                               keycode: 61,
                                               flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .accept(HotkeyChoice(name: "Right Option",
                                         keycode: 61,
                                         isModifier: true,
                                         modifierFlag: .maskAlternate)),
            "hotkey recorder should accept right-side modifier presses"
        )
        try expect(
            hotkeyRecordingDecision(for: event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
            )),
            equals: .accept(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                         modifiers: [.maskAlternate, .maskCommand])),
            "hotkey recorder should accept modifier-only chords"
        )
    }

    private static func testHotkeyPreferenceUpdateResults() throws {
        let f5 = hotkeyChoice(forKeycode: 96)
        let f7 = hotkeyChoice(forKeycode: 98)
        let invalid = HotkeyChoice(name: "Escape", keycode: ESCAPE_KEYCODE, isModifier: false, modifierFlag: nil)

        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persisted: f7
            ),
            equals: .saved(f7),
            "hotkey preference update should save supported keys after persistence confirms them"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: invalid,
                previous: f5,
                persisted: f5
            ),
            equals: .rejected("That key cannot be used for dictation."),
            "hotkey preference update should reject unsupported keys before mutating settings"
        )
        try expect(
            hotkeyPreferenceUpdateResult(
                requested: f7,
                previous: f5,
                persisted: f5
            ),
            equals: .rolledBack(
                previous: f5,
                message: "Dictor could not save that hotkey, so it kept F5."
            ),
            "hotkey preference update should roll back when persisted settings disagree"
        )
    }

    private static func testHotkeyRecorderCaptureFlow() throws {
        try expect(
            hotkeyFlags(from: [.command, .option]),
            equals: [.maskCommand, .maskAlternate],
            "recorder should translate AppKit modifier flags without relying on an optional CGEvent"
        )

        var singleCommand = HotkeyRecorderCaptureState()
        let commandDown = event(.flagsChanged,
                                keycode: RIGHT_COMMAND_KEYCODE,
                                flags: CGEventFlags.maskCommand.rawValue)
        let rightCommand = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE)
        try expect(
            singleCommand.consume(commandDown),
            equals: .candidate(rightCommand),
            "pressing Right Command should select it immediately as a one-key shortcut"
        )
        try expect(
            singleCommand.consume(event(.flagsChanged, keycode: RIGHT_COMMAND_KEYCODE)),
            equals: .ignore,
            "releasing Right Command should not be required to preserve its selection"
        )

        var singleModifier = HotkeyRecorderCaptureState()
        let optionDown = event(.flagsChanged,
                               keycode: 58,
                               flags: CGEventFlags.maskAlternate.rawValue)
        let leftOption = hotkeyChoice(forKeycode: 58)
        try expect(
            singleModifier.consume(optionDown),
            equals: .candidate(leftOption),
            "pressing Option should select it immediately as a one-key shortcut"
        )
        try expect(
            singleModifier.consume(event(.flagsChanged, keycode: 58)),
            equals: .ignore,
            "releasing Option should not change the selected shortcut"
        )

        for (keycode, flags, label) in [
            (CGKeyCode(55), CGEventFlags.maskCommand, "Left Command"),
            (CGKeyCode(59), CGEventFlags.maskControl, "Left Control"),
            (FN_KEYCODE, CGEventFlags.maskSecondaryFn, "Fn"),
        ] {
            var modifier = HotkeyRecorderCaptureState()
            try expect(
                modifier.consume(event(.flagsChanged,
                                       keycode: keycode,
                                       flags: flags.rawValue)),
                equals: .candidate(hotkeyChoice(forKeycode: keycode)),
                "pressing \(label) should select it immediately"
            )
        }

        var chord = HotkeyRecorderCaptureState()
        _ = chord.consume(optionDown)
        try expect(
            chord.consume(event(.keyDown,
                                keycode: 40,
                                flags: CGEventFlags.maskAlternate.rawValue)),
            equals: .candidate(hotkeyChoice(forKeycode: 40,
                                            modifiers: .maskAlternate)),
            "pressing a regular key while a modifier is held should select the full chord"
        )

        var modifierChord = HotkeyRecorderCaptureState()
        _ = modifierChord.consume(optionDown)
        try expect(
            modifierChord.consume(event(
                .flagsChanged,
                keycode: RIGHT_COMMAND_KEYCODE,
                flags: CGEventFlags.maskAlternate.rawValue | CGEventFlags.maskCommand.rawValue
            )),
            equals: .candidate(hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                            modifiers: [.maskAlternate, .maskCommand])),
            "pressing a second modifier should select a modifier-only chord"
        )

        var singleKey = HotkeyRecorderCaptureState()
        try expect(
            singleKey.consume(event(.keyDown, keycode: 96)),
            equals: .candidate(hotkeyChoice(forKeycode: 96)),
            "pressing one regular key should select it for confirmation"
        )

        var canceled = HotkeyRecorderCaptureState()
        try expect(
            canceled.consume(event(.keyDown, keycode: ESCAPE_KEYCODE)),
            equals: .cancel,
            "Escape should cancel shortcut recording"
        )
    }

    private static func testHotkeyRecorderRestartActions() throws {
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: false,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not start a listener that was not active"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: true,
                restartSucceeded: false
            ),
            equals: .none,
            "hotkey recorder should not restart the listener during termination"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: true
            ),
            equals: .restoredListener,
            "hotkey recorder should treat a successful restart as recovered"
        )
        try expect(
            hotkeyRecorderRestartAction(
                shouldRestoreHotkeyTap: true,
                isTerminating: false,
                restartSucceeded: false
            ),
            equals: .recordFailure,
            "hotkey recorder should surface restart failure after an active listener was paused"
        )
    }
}
#endif
