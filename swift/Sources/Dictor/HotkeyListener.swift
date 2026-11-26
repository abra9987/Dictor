import AppKit
import Foundation
import CoreGraphics

// MARK: - Hotkey listener
//
// Global event tap on the keyDown / keyUp / flagsChanged stream.
// Right Option is a modifier so it doesn't fire keyDown — we watch
// flagsChanged and diff the .option flag.

enum HotkeyTransitionAction: Equatable, Sendable {
    case press
    case release
    case releaseAlternate
    case cancel
    /// Toggle mode: the press was suppressed because the app is busy
    /// (transcription in flight). Does NOT flip toggle state. Lets the
    /// app play feedback so the user knows the press was received.
    case rejectedBusyPress
}

struct HotkeyTransitionResult: Equatable, Sendable {
    let suppress: Bool
    let actions: [HotkeyTransitionAction]

    static let pass = HotkeyTransitionResult(suppress: false, actions: [])
    static let suppressOnly = HotkeyTransitionResult(suppress: true, actions: [])
}

enum HotkeyShortcutEdge: Equatable {
    case press
    case release
    case suppress
    case pass
}

struct HotkeyShortcutState {
    private var primaryModifierDown = false
    private var shortcutDown = false
    private var suppressingChordRelease = false

    var isEngaged: Bool { primaryModifierDown || shortcutDown || suppressingChordRelease }

    mutating func reset() {
        primaryModifierDown = false
        shortcutDown = false
        suppressingChordRelease = false
    }

    mutating func consume(_ event: HotkeyEventSnapshot,
                          shortcut: HotkeyChoice) -> HotkeyShortcutEdge {
        if !shortcut.isModifier {
            guard event.keycode == shortcut.keycode else { return .pass }
            if event.typeRawValue == CGEventType.keyDown.rawValue {
                guard !event.isAutoRepeat else { return shortcutDown ? .suppress : .pass }
                let modifiers = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
                guard modifiers == shortcut.requiredModifiers else { return .pass }
                shortcutDown = true
                return .press
            }
            if event.typeRawValue == CGEventType.keyUp.rawValue, shortcutDown {
                shortcutDown = false
                return .release
            }
            return .pass
        }

        guard event.typeRawValue == CGEventType.flagsChanged.rawValue,
              let primaryMask = shortcut.modifierFlag else {
            return .pass
        }

        let eventModifier = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == event.keycode })
        let isRequiredModifierEvent = eventModifier?.modifierFlag.map {
            shortcut.requiredModifiers.contains($0)
        } ?? false
        let isRelevant = event.keycode == shortcut.keycode || isRequiredModifierEvent
        guard isRelevant else { return .pass }

        if suppressingChordRelease {
            let allModifiers = shortcut.requiredModifiers.union(primaryMask)
            if event.keycode == shortcut.keycode {
                primaryModifierDown = false
            }
            if event.flags.intersection(allModifiers).isEmpty {
                suppressingChordRelease = false
                primaryModifierDown = false
                shortcutDown = false
            }
            return .suppress
        }

        if event.keycode == shortcut.keycode {
            if primaryModifierDown {
                primaryModifierDown = false
            } else if event.flags.contains(primaryMask) {
                primaryModifierDown = true
            }
        }

        let expectedModifiers = shortcut.requiredModifiers.union(primaryMask)
        let requirementsMet = event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
            == expectedModifiers
        let isNowDown = primaryModifierDown && requirementsMet
        if isNowDown, !shortcutDown {
            shortcutDown = true
            return .press
        }
        if shortcutDown, !isNowDown {
            shortcutDown = false
            suppressingChordRelease = !shortcut.requiredModifiers.isEmpty
            return .release
        }
        if shortcutDown || isRequiredModifierEvent {
            return .suppress
        }
        return .pass
    }
}

struct HotkeyTransitionState {
    private var standardShortcutState = HotkeyShortcutState()
    private var enterShortcutState = HotkeyShortcutState()
    private var toggleActive = false
    private var suppressEscapeKeyUp = false

    mutating func resetAll() {
        standardShortcutState.reset()
        enterShortcutState.reset()
        toggleActive = false
        suppressEscapeKeyUp = false
    }

    mutating func resetToggleState() {
        toggleActive = false
    }

    /// `canStartRecording` mirrors the app-side guard on handlePress
    /// (ready, not recording, not busy, not terminating). Toggle mode
    /// consults it before flipping state — see the `.toggle` case.
    /// Defaults to true so hold-mode behaviour and existing callers
    /// are unchanged.
    mutating func transition(
        for event: HotkeyEventSnapshot,
        hotkey: HotkeyChoice,
        enterHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                 modifiers: .maskAlternate),
        alternateCompletionEnabled: Bool = true,
        triggerMode: TriggerMode,
        isRecording: Bool,
        canStartRecording: Bool = true
    ) -> HotkeyTransitionResult {
        if event.keycode == ESCAPE_KEYCODE {
            return transitionEscape(for: event, isRecording: isRecording)
        }

        if alternateCompletionEnabled,
           !hotkeyIsModifierPrefix(hotkey, of: enterHotkey) {
            if let completion = transitionEnterShortcut(for: event,
                                                         isRecording: isRecording,
                                                         enterHotkey: enterHotkey) {
                return completion
            }
        }

        let edge = standardShortcutState.consume(event, shortcut: hotkey)
        let claims = claimsEvent(event, shortcut: hotkey)

        switch triggerMode {
        case .hold:
            var actions: [HotkeyTransitionAction] = []
            if edge == .press { actions.append(.press) }
            if edge == .release { actions.append(.release) }
            guard edge != .pass else { return .pass }
            return HotkeyTransitionResult(suppress: claims, actions: actions)
        case .toggle:
            // Toggle mode: every press flips between "start recording"
            // and "stop recording". Releases are no-ops.
            guard edge != .pass else { return .pass }
            guard edge == .press else {
                return HotkeyTransitionResult(suppress: claims, actions: [])
            }
            if toggleActive {
                toggleActive = false
                return HotkeyTransitionResult(suppress: claims, actions: [.release])
            }
            // A press the app will reject (model loading, a
            // transcription in flight, terminating) must not flip the
            // toggle. Otherwise the rejected press strands
            // toggleActive at true, the NEXT press emits a .release
            // the app discards, and only the third press records —
            // with zero feedback in between. Same gate-callback
            // pattern Escape uses via isRecording.
            // .rejectedBusyPress lets the app play feedback without
            // flipping toggle state — handlePress() is never reached
            // in toggle mode because the state machine gates it here.
            guard canStartRecording else {
                return HotkeyTransitionResult(suppress: claims, actions: [.rejectedBusyPress])
            }
            toggleActive = true
            return HotkeyTransitionResult(suppress: claims, actions: [.press])
        }
    }

    /// Может ли перехватчик съесть само событие.
    ///
    /// Только событие той клавиши, которую пользователь назначил. Клавиши
    /// -спутники в аккорде (Command в «Command + правый Option») система
    /// обязана видеть: сочетание набирают на них же. Проглоченное нажатие
    /// Command ломает переключатель приложений — он живёт на удержании
    /// Command, а не на флаге в событии клавиши, поэтому Cmd+C работал, а
    /// Cmd+Tab нет. Проглоченное отпускание ещё хуже: система остаётся
    /// уверенной, что модификатор всё ещё зажат.
    private func claimsEvent(_ event: HotkeyEventSnapshot, shortcut: HotkeyChoice) -> Bool {
        event.keycode == shortcut.keycode
    }

    private mutating func transitionEnterShortcut(
        for event: HotkeyEventSnapshot,
        isRecording: Bool,
        enterHotkey: HotkeyChoice
    ) -> HotkeyTransitionResult? {
        guard isRecording || enterShortcutState.isEngaged else { return nil }
        let claims = claimsEvent(event, shortcut: enterHotkey)
        switch enterShortcutState.consume(event, shortcut: enterHotkey) {
        case .press where isRecording:
            standardShortcutState.reset()
            toggleActive = false
            return HotkeyTransitionResult(suppress: claims, actions: [.releaseAlternate])
        case .press, .release, .suppress:
            return HotkeyTransitionResult(suppress: claims, actions: [])
        case .pass:
            return nil
        }
    }

    private mutating func transitionEscape(
        for event: HotkeyEventSnapshot,
        isRecording: Bool
    ) -> HotkeyTransitionResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue {
            if event.isAutoRepeat, suppressEscapeKeyUp {
                return .suppressOnly
            }
            guard isRecording else { return .pass }
            suppressEscapeKeyUp = true
            return event.isAutoRepeat
                ? .suppressOnly
                : HotkeyTransitionResult(suppress: true, actions: [.cancel])
        }

        if event.typeRawValue == CGEventType.keyUp.rawValue, suppressEscapeKeyUp {
            suppressEscapeKeyUp = false
            return .suppressOnly
        }

        return .pass
    }
}

@MainActor
final class HotkeyListener {

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var transitionState = HotkeyTransitionState()

    /// User's current hotkey (set via Settings → Hotkey submenu).
    var hotkey: HotkeyChoice = hotkeyChoice(forKeycode: DEFAULT_HOTKEY_KEYCODE)
    var enterHotkey: HotkeyChoice = hotkeyChoice(forKeycode: RIGHT_COMMAND_KEYCODE,
                                                 modifiers: .maskAlternate)
    var alternateCompletionEnabled = true
    var triggerMode: TriggerMode = .hold

    /// onPress fires when a recording should start (press in hold mode,
    /// or first press in toggle mode). onRelease fires when it should
    /// stop (release in hold mode, or second press in toggle mode).
    /// onCancel fires for Escape while a recording is active.
    var onPress: (() -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    var onReleaseAlternate: ((TimeInterval) -> Void)?
    var onCancel: (() -> Void)?
    /// Toggle mode: a press arrived while the app is busy (transcription
    /// in flight). The toggle did NOT flip. Play feedback so the user
    /// knows the press was received but rejected.
    var onRejectedBusyPress: (() -> Void)?
    var isRecordingActive: (() -> Bool)?
    /// Asks the app whether a new recording would actually start if
    /// onPress fired right now (ready, idle, not transcribing, not
    /// terminating). Toggle mode uses it so a press the app would
    /// silently discard doesn't flip the toggle state and leave the
    /// next press emitting a swallowed .release. nil (or no callback
    /// installed) is treated as "would start".
    var canStartRecording: (() -> Bool)?

    @discardableResult
    func start() -> Bool {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            return true
        }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
                              | (1 << CGEventType.keyUp.rawValue)
                              | (1 << CGEventType.flagsChanged.rawValue)

        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let listener = Unmanaged<HotkeyListener>.fromOpaque(userInfo).takeUnretainedValue()
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                let shouldSuppress = MainActor.assumeIsolated {
                    listener.handleTapCallback(snapshot)
                }
                return shouldSuppress ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: opaqueSelf
        ) else {
            log("CGEvent.tapCreate failed — Input Monitoring permission missing?")
            return false
        }

        self.tap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("HotkeyListener: tap active (watching \(hotkey.name))")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        transitionState.resetAll()
    }

    /// Replace the current hotkey choice. Safe to call at runtime —
    /// the tap stays bound, only the per-event filter changes.
    func setHotkey(_ choice: HotkeyChoice) {
        self.hotkey = choice
        self.transitionState.resetAll()
        log("HotkeyListener: hotkey changed → \(choice.name)")
    }

    func setEnterHotkey(_ choice: HotkeyChoice) {
        enterHotkey = choice
        transitionState.resetAll()
        log("HotkeyListener: alternate completion hotkey changed → \(choice.name)")
    }

    func setAlternateCompletionEnabled(_ enabled: Bool) {
        alternateCompletionEnabled = enabled
        transitionState.resetAll()
        log("HotkeyListener: alternate completion → \(enabled ? "enabled" : "disabled")")
    }

    func setTriggerMode(_ mode: TriggerMode) {
        // Reset toggle state when switching modes so we don't get
        // stuck in mid-toggle from a previous session.
        if mode != triggerMode { transitionState.resetToggleState() }
        triggerMode = mode
        log("HotkeyListener: trigger mode → \(mode.rawValue)")
    }

    private func handleTapCallback(_ event: HotkeyEventSnapshot) -> Bool {
        if event.typeRawValue == CGEventType.tapDisabledByTimeout.rawValue
            || event.typeRawValue == CGEventType.tapDisabledByUserInput.rawValue {
            if let tap {
                CGEvent.tapEnable(tap: tap, enable: true)
                log("HotkeyListener: event tap re-enabled after \(event.typeRawValue)")
            }
            return false
        }

        let result = transitionState.transition(for: event,
                                                hotkey: hotkey,
                                                enterHotkey: enterHotkey,
                                                alternateCompletionEnabled: alternateCompletionEnabled,
                                                triggerMode: triggerMode,
                                                isRecording: isRecordingActive?() ?? false,
                                                canStartRecording: canStartRecording?() ?? true)
        dispatchHotkeyActions(result.actions)
        return result.suppress
    }

    private func dispatchHotkeyActions(_ actions: [HotkeyTransitionAction]) {
        guard !actions.isEmpty else { return }
        let detectedAt = ProcessInfo.processInfo.systemUptime

        Task { @MainActor [weak self] in
            self?.performHotkeyActions(actions, detectedAt: detectedAt)
        }
    }

    private func performHotkeyActions(_ actions: [HotkeyTransitionAction], detectedAt: TimeInterval) {
        for action in actions {
            switch action {
            case .press: onPress?()
            case .release: onRelease?(detectedAt)
            case .releaseAlternate: onReleaseAlternate?(detectedAt)
            case .cancel: onCancel?()
            case .rejectedBusyPress: onRejectedBusyPress?()
            }
        }
    }

    /// Called when the recording stops via a path other than the
    /// hotkey (auto-release at max duration, app quitting, etc.) so
    /// toggle mode doesn't end up offset by one.
    func resetToggleState() {
        transitionState.resetToggleState()
    }
}

