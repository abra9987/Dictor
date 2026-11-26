import AppKit

struct HotkeyEventSnapshot: Sendable {
    let typeRawValue: UInt32
    let keycode: CGKeyCode
    let flagsRawValue: UInt64
    let isAutoRepeat: Bool

    var flags: CGEventFlags {
        CGEventFlags(rawValue: flagsRawValue)
    }
}

enum HotkeyRecordingDecision: Equatable {
    case accept(HotkeyChoice)
    case reject(String)
    case ignore
}

enum HotkeyPreferenceUpdateResult: Equatable {
    case saved(HotkeyChoice)
    case rejected(String)
    case rolledBack(previous: HotkeyChoice, message: String)
}

func hotkeyPreferenceUpdateResult(
    requested: HotkeyChoice,
    previous: HotkeyChoice,
    persisted: HotkeyChoice
) -> HotkeyPreferenceUpdateResult {
    guard let recordable = recordableHotkeyChoice(forKeycode: requested.keycode,
                                                  modifiers: requested.requiredModifiers) else {
        return .rejected("That key cannot be used for dictation.")
    }

    guard persisted == recordable else {
        return .rolledBack(
            previous: previous,
            message: "Dictor could not save that hotkey, so it kept \(previous.name)."
        )
    }

    return .saved(recordable)
}

enum HotkeyRecorderRestartAction: Equatable {
    case none
    case restoredListener
    case recordFailure
}

func hotkeyRecorderRestartAction(
    shouldRestoreHotkeyTap: Bool,
    isTerminating: Bool,
    restartSucceeded: Bool
) -> HotkeyRecorderRestartAction {
    guard shouldRestoreHotkeyTap, !isTerminating else { return .none }
    return restartSucceeded ? .restoredListener : .recordFailure
}

func hotkeyRecordingDecision(for event: HotkeyEventSnapshot) -> HotkeyRecordingDecision {
    if event.isAutoRepeat { return .ignore }

    if event.typeRawValue == CGEventType.flagsChanged.rawValue {
        guard let baseChoice = MODIFIER_HOTKEY_CHOICES.first(where: { $0.keycode == event.keycode }),
              let mask = baseChoice.modifierFlag,
              event.flags.contains(mask) else {
            return .ignore
        }
        guard let choice = recordableHotkeyChoice(forKeycode: event.keycode,
                                                  modifiers: event.flags) else {
            return .ignore
        }
        return .accept(choice)
    }

    guard event.typeRawValue == CGEventType.keyDown.rawValue else { return .ignore }
    guard let choice = recordableHotkeyChoice(
        forKeycode: event.keycode,
        modifiers: event.flags.intersection(HOTKEY_SHORTCUT_MODIFIER_MASK)
    ),
          !choice.isModifier else {
        return .reject("Escape is reserved for canceling dictation. Choose another key or shortcut.")
    }
    return .accept(choice)
}

enum HotkeyRecorderCaptureResult: Equatable {
    case candidate(HotkeyChoice)
    case reject(String)
    case cancel
    case ignore
}

struct HotkeyRecorderCaptureState {
    mutating func consume(_ event: HotkeyEventSnapshot) -> HotkeyRecorderCaptureResult {
        if event.typeRawValue == CGEventType.keyDown.rawValue,
           event.keycode == ESCAPE_KEYCODE {
            return .cancel
        }

        switch hotkeyRecordingDecision(for: event) {
        case .accept(let choice):
            return .candidate(choice)
        case .reject(let message):
            return .reject(message)
        case .ignore:
            return .ignore
        }
    }
}

@MainActor
final class HotkeyRecorderController: NSObject, NSWindowDelegate {
    private let language: InterfaceLanguage
    private let panel: NSPanel
    let status: NSTextField
    private let saveButton: NSButton
    private var captureState = HotkeyRecorderCaptureState()
    private var selected: HotkeyChoice?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var fallbackMonitor: Any?
    private var completion: ((HotkeyChoice?) -> Void)?
    private var isFinished = false

    init(language: InterfaceLanguage,
         titleOverride: String? = nil,
         completion: @escaping (HotkeyChoice?) -> Void) {
        self.language = language
        self.completion = completion
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 230),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        status = NSTextField(labelWithString: localizedText(
            "Ничего не выбрано",
            "Nothing selected",
            language: language
        ))
        saveButton = NSButton(title: localizedText("Сохранить", "Save", language: language),
                              target: nil,
                              action: nil)
        super.init()

        panel.title = "Dictor"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.delegate = self

        let title = NSTextField(labelWithString: titleOverride ?? localizedText(
            "Новое сочетание для диктовки",
            "Record Dictation Shortcut",
            language: language
        ))
        title.font = .systemFont(ofSize: 19, weight: .semibold)

        let instruction = NSTextField(wrappingLabelWithString: localizedText(
            "Нажмите одну клавишу или любое сочетание. Изменение применится только после «Сохранить». Escape закроет окно без изменений.",
            "Press one key or any shortcut. It changes only after you click Save. Escape closes without changes.",
            language: language
        ))
        instruction.font = .systemFont(ofSize: 13)
        instruction.textColor = .secondaryLabelColor

        status.font = .monospacedSystemFont(ofSize: 14, weight: .semibold)
        status.textColor = .labelColor
        status.lineBreakMode = .byTruncatingMiddle

        let statusContainer = NSBox()
        statusContainer.boxType = .custom
        statusContainer.cornerRadius = 7
        statusContainer.borderWidth = 1
        statusContainer.borderColor = .separatorColor
        statusContainer.fillColor = .controlBackgroundColor
        statusContainer.contentViewMargins = NSSize(width: 14, height: 10)
        statusContainer.contentView = status
        statusContainer.heightAnchor.constraint(equalToConstant: 42).isActive = true

        saveButton.target = self
        saveButton.action = #selector(save(_:))
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false
        saveButton.keyEquivalent = ""

        let cancelButton = NSButton(
            title: localizedText("Отмена", "Cancel", language: language),
            target: self,
            action: #selector(cancelClicked(_:))
        )
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = ""

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [buttonSpacer, cancelButton, saveButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 10

        let stack = NSStackView(views: [title, instruction, statusContainer, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        instruction.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        statusContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let contentView = NSView()
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18),
        ])
        panel.contentView = contentView
    }

    func present(relativeTo parent: NSWindow? = nil) {
        guard !isFinished else { return }
        if eventTap != nil || fallbackMonitor != nil {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        if !startEventTap() {
            log("Hotkey recorder: CGEventTap unavailable; using AppKit fallback")
            fallbackMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .keyUp, .flagsChanged]
            ) { [weak self] event in
                let typeRawValue: UInt32
                switch event.type {
                case .flagsChanged: typeRawValue = CGEventType.flagsChanged.rawValue
                case .keyUp: typeRawValue = CGEventType.keyUp.rawValue
                default: typeRawValue = CGEventType.keyDown.rawValue
                }
                self?.consume(HotkeyEventSnapshot(
                    typeRawValue: typeRawValue,
                    keycode: CGKeyCode(event.keyCode),
                    flagsRawValue: hotkeyFlags(from: event.modifierFlags).rawValue,
                    isAutoRepeat: event.isARepeat
                ))
                return nil
            }
        }

        if let parent, let screen = parent.screen {
            let frame = panel.frame
            let parentFrame = parent.frame
            let visibleFrame = screen.visibleFrame
            let x = min(max(visibleFrame.minX, parentFrame.midX - frame.width / 2),
                        visibleFrame.maxX - frame.width)
            let y = min(max(visibleFrame.minY, parentFrame.midY - frame.height / 2),
                        visibleFrame.maxY - frame.height)
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func cancel() {
        finish(with: nil)
    }

    @objc private func save(_ sender: NSButton) {
        guard let selected else { return }
        finish(with: selected)
    }

    @objc private func cancelClicked(_ sender: NSButton) {
        cancel()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private func startEventTap() -> Bool {
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        let opaqueSelf = Unmanaged.passUnretained(self).toOpaque()
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let recorder = Unmanaged<HotkeyRecorderController>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated {
                        if let eventTap = recorder.eventTap {
                            CGEvent.tapEnable(tap: eventTap, enable: true)
                        }
                    }
                    return Unmanaged.passUnretained(event)
                }
                let snapshot = HotkeyEventSnapshot(
                    typeRawValue: type.rawValue,
                    keycode: CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)),
                    flagsRawValue: event.flags.rawValue,
                    isAutoRepeat: type == .keyDown
                        && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                )
                MainActor.assumeIsolated {
                    recorder.consume(snapshot)
                }
                return nil
            },
            userInfo: opaqueSelf
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return false
        }
        self.eventTap = eventTap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        log("Hotkey recorder: dedicated CGEventTap active")
        return true
    }

    private func consume(_ snapshot: HotkeyEventSnapshot) {
        guard !isFinished else { return }
        log("Hotkey recorder: event type=\(snapshot.typeRawValue) keycode=\(snapshot.keycode) flags=0x\(String(snapshot.flagsRawValue, radix: 16))")
        switch captureState.consume(snapshot) {
        case .candidate(let choice):
            selected = choice
            saveButton.isEnabled = true
            log("Hotkey recorder: selected \(choice.name)")
            status.stringValue = localizedText(
                "Выбрано: \(localizedHotkeyName(choice, language: language))",
                "Selected: \(localizedHotkeyName(choice, language: language))",
                language: language
            )
        case .reject(let message):
            selected = nil
            saveButton.isEnabled = false
            status.stringValue = localizedText(
                "Эту клавишу нельзя использовать. Выберите другую.",
                message,
                language: language
            )
            NSSound.beep()
        case .cancel:
            cancel()
        case .ignore:
            break
        }
    }

    private func finish(with choice: HotkeyChoice?) {
        guard !isFinished else { return }
        isFinished = true
        if let fallbackMonitor {
            NSEvent.removeMonitor(fallbackMonitor)
            self.fallbackMonitor = nil
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
        let completion = self.completion
        self.completion = nil
        completion?(choice)
    }
}

func hotkeyFlags(from modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
    var result: CGEventFlags = []
    if modifiers.contains(.control) { result.insert(.maskControl) }
    if modifiers.contains(.option) { result.insert(.maskAlternate) }
    if modifiers.contains(.shift) { result.insert(.maskShift) }
    if modifiers.contains(.command) { result.insert(.maskCommand) }
    if modifiers.contains(.function) { result.insert(.maskSecondaryFn) }
    return result
}
