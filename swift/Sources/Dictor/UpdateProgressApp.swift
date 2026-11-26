import AppKit

struct UpdateProgressLaunch {
    let statePath: String
    let logPath: String
    let targetVersion: String
    let cleanupAppPath: String

    init?(arguments: [String]) {
        guard arguments.count >= 5,
              arguments[0] == UPDATE_PROGRESS_ARGUMENT,
              !arguments[1].isEmpty,
              !arguments[2].isEmpty,
              !arguments[3].isEmpty,
              !arguments[4].isEmpty else {
            return nil
        }

        statePath = arguments[1]
        logPath = arguments[2]
        targetVersion = arguments[3]
        cleanupAppPath = arguments[4]
    }
}

struct UpdateProgressState {
    let phase: String
    let message: String

    static func read(from path: String) -> UpdateProgressState? {
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .newlines)
        let parts = trimmed.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return UpdateProgressState(phase: String(parts[0]), message: String(parts[1]))
    }
}

func isSafeUpdateProgressCleanupPath(_ path: String) -> Bool {
    guard !path.isEmpty else { return false }
    let tempPath = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .standardizedFileURL
        .path
    let tempPrefix = tempPath.hasSuffix("/") ? tempPath : "\(tempPath)/"
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    return url.path.hasPrefix(tempPrefix)
        && url.pathExtension == "app"
        && url.lastPathComponent.hasPrefix(UPDATE_PROGRESS_APP_PREFIX)
}

@MainActor
final class UpdateProgressAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let launch: UpdateProgressLaunch
    private var window: NSWindow?
    private var pollTimer: Timer?
    private var closeWorkItem: DispatchWorkItem?
    private var lastPhase = ""
    private var lastMessage = ""

    private var messageLabel: NSTextField!
    private var detailLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var openReleaseButton: NSButton!
    private var closeButton: NSButton!

    init(launch: UpdateProgressLaunch) {
        self.launch = launch
    }

    private var language: InterfaceLanguage { Settings.shared.interfaceLanguage }

    private func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: language)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildWindow()
        pollState()
        pollTimer = Timer.scheduledTimer(timeInterval: 0.5,
                                         target: self,
                                         selector: #selector(updateProgressTimerFired(_:)),
                                         userInfo: nil,
                                         repeats: true)
        pollTimer?.tolerance = 0.15
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        pollTimer = nil
        closeWorkItem?.cancel()
        scheduleCopiedAppCleanup()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func buildWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 184),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = t("Обновление Dictor", "Updating Dictor")
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        root.translatesAutoresizingMaskIntoConstraints = false

        let title = updateProgressLabel(t("Обновление Dictor до v\(launch.targetVersion)",
                                          "Updating Dictor to v\(launch.targetVersion)"),
                                        font: .systemFont(ofSize: 18, weight: .semibold))
        messageLabel = updateProgressLabel(t("Запускаю обновление…", "Starting update…"),
                                           font: .systemFont(ofSize: 13, weight: .medium))
        detailLabel = updateProgressLabel(t("Dictor автоматически откроется после установки.",
                                             "Dictor will reopen automatically when the update finishes."),
                                          font: .systemFont(ofSize: 12),
                                          color: .secondaryLabelColor)
        detailLabel.preferredMaxLayoutWidth = 390

        progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.usesThreadedAnimation = true
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.startAnimation(nil)

        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.translatesAutoresizingMaskIntoConstraints = false

        let openLog = NSButton(title: t("Открыть журнал", "Open Log"),
                               target: self,
                               action: #selector(openUpdateLogClicked(_:)))
        openLog.bezelStyle = .rounded

        openReleaseButton = NSButton(title: t("Открыть страницу релиза", "Open Release Page"),
                                     target: self,
                                     action: #selector(openReleasePageClicked(_:)))
        openReleaseButton.bezelStyle = .rounded
        openReleaseButton.isHidden = true

        closeButton = NSButton(title: t("Закрыть", "Close"),
                               target: self,
                               action: #selector(closeUpdateProgressClicked(_:)))
        closeButton.bezelStyle = .rounded
        closeButton.isHidden = true

        buttonRow.addArrangedSubview(openLog)
        buttonRow.addArrangedSubview(openReleaseButton)
        buttonRow.addArrangedSubview(NSView())
        buttonRow.addArrangedSubview(closeButton)
        buttonRow.setHuggingPriority(.defaultLow, for: .horizontal)

        root.addArrangedSubview(title)
        root.addArrangedSubview(messageLabel)
        root.addArrangedSubview(progress)
        root.addArrangedSubview(detailLabel)
        root.addArrangedSubview(buttonRow)

        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor,
                                        constant: -(root.edgeInsets.left + root.edgeInsets.right)).isActive = true
        }

        let container = NSView()
        container.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            root.topAnchor.constraint(equalTo: container.topAnchor),
            root.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            root.widthAnchor.constraint(equalToConstant: 430),
            progress.heightAnchor.constraint(equalToConstant: 14),
        ])

        window.contentView = container
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func updateProgressLabel(_ text: String,
                                     font: NSFont,
                                     color: NSColor = .labelColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }

    @objc private func updateProgressTimerFired(_ timer: Timer) {
        pollState()
    }

    private func pollState() {
        let state = UpdateProgressState.read(from: launch.statePath)
            ?? UpdateProgressState(phase: "starting",
                                   message: t("Запускаю обновление…", "Starting update…"))
        guard state.phase != lastPhase || state.message != lastMessage else { return }

        lastPhase = state.phase
        lastMessage = state.message
        messageLabel.stringValue = state.message

        switch state.phase {
        case "failed":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Предыдущая версия сохранена. Подробности доступны в журнале.",
                                        "The previous version was preserved. Open the log for details.")
            openReleaseButton.isHidden = false
            closeButton.isHidden = false
            NSApp.activate(ignoringOtherApps: true)
        case "complete":
            progress.stopAnimation(nil)
            progress.isHidden = true
            detailLabel.stringValue = t("Обновлённое приложение открывается. Это окно скоро закроется.",
                                        "The updated app is opening. This window will close shortly.")
            closeButton.isHidden = false
            scheduleClose(after: 4)
        case "installing":
            detailLabel.stringValue = t("Старая версия закрыта, новая устанавливается. Приложение откроется автоматически.",
                                        "The old version has closed while the new one is installed. It will reopen automatically.")
        case "relaunching":
            detailLabel.stringValue = t("Запускаю новую версию Dictor.",
                                        "Opening the new version of Dictor.")
            scheduleClose(after: 0.5)
        default:
            detailLabel.stringValue = t("Dictor автоматически откроется после установки.",
                                        "Dictor will reopen automatically when the update finishes.")
        }
    }

    private func scheduleClose(after delay: TimeInterval) {
        guard closeWorkItem == nil else { return }
        let item = DispatchWorkItem { NSApp.terminate(nil) }
        closeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleCopiedAppCleanup() {
        guard isSafeUpdateProgressCleanupPath(launch.cleanupAppPath) else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "sleep 2; /bin/rm -rf \"$1\"", "cleanup", launch.cleanupAppPath]
        proc.environment = systemToolProcessEnvironment()
        try? proc.run()
    }

    @objc private func openUpdateLogClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(URL(fileURLWithPath: launch.logPath))
    }

    @objc private func openReleasePageClicked(_ sender: NSButton) {
        NSWorkspace.shared.open(UPDATE_CHANNEL_PAGE)
    }

    @objc private func closeUpdateProgressClicked(_ sender: NSButton) {
        NSApp.terminate(nil)
    }
}
