import AppKit

// Поповер меню-бара по дизайну 1d/1e: статус + тумблер, язык пилюлями,
// микрофон, «Недавнее» (1/5/10 записей — по настройке, hover-действия),
// статистика, футер. Открывается левым кликом по глифу.

@MainActor
protocol QuickPanelDelegate: AnyObject {
    func quickPanelDidToggleEnabled(_ enabled: Bool)
    func quickPanelDidSelectLanguage(_ language: DictationLanguage)
    func quickPanelDidSelectInputDevice(uid: String)
    func quickPanelDidCopyRecent(text: String)
    func quickPanelDidPasteRecent(text: String)
    func quickPanelOpenSettings()
    func quickPanelOpenHistory()
    func quickPanelQuit()
    func quickPanelInstallUpdate()
    func quickPanelCheckForUpdates()
    func quickPanelStatusPrimaryAction()
    func quickPanelStatusSecondaryAction()
}

struct QuickPanelState {
    var enabled: Bool
    var language: DictationLanguage
    var microphoneName: String
    var devices: [AudioInputDevice]
    var recent: [TranscriptHistoryEntry]
    /// История может быть выключена в настройках — тогда пустое «Недавнее»
    /// обязано назвать причину, а не обещать «первая диктовка появится здесь».
    var historyKeepingEnabled: Bool
    var todayCharacters: Int
    var todayAudioSeconds: Double
    var weekBars: [CGFloat]
    var interfaceLanguage: InterfaceLanguage
    /// Версия, которую предлагает канал обновлений, если она есть. Панель —
    /// то, что открывается левым кликом, то есть единственное меню, которое
    /// человек вообще видит; предложение обновиться обязано быть и здесь.
    var availableUpdateVersion: String?
    var installedVersion: String
    var isCheckingForUpdates: Bool
    /// Состояние службы — одно из девяти (макет 8b). Панель показывает его
    /// теми же словами, что и подвал окна.
    var serviceStatus: ServiceStatusKind
}

@MainActor
final class DictorQuickPanel: NSPanel {
    weak var quickDelegate: QuickPanelDelegate?
    var state: QuickPanelState
    private let contentStack = NSStackView()
    private var waveView: QuickPanelWaveView?
    private var outsideClickMonitor: Any?
    /// Проверка, которая ничего не нашла, обязана это сказать. Иначе нажатие
    /// «Проверить» выглядит как нажатие в пустоту — а именно за этим человек
    /// и нажимал.
    var showsUpToDate = false
    var upToDateWorkItem: DispatchWorkItem?
    private var copyResetWorkItem: DispatchWorkItem?

    static let panelWidth: CGFloat = 360

    init(state: QuickPanelState) {
        self.state = state
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        rebuildContent()
    }

    // MARK: - Показ / скрытие

    func toggle(relativeTo button: NSStatusBarButton, state: QuickPanelState) {
        if isVisible {
            close()
        } else {
            show(relativeTo: button, state: state)
        }
    }

    func show(relativeTo button: NSStatusBarButton, state: QuickPanelState) {
        apply(state: state)
        layoutIfNeeded()
        guard let buttonWindow = button.window, let screen = buttonWindow.screen else { return }
        let buttonFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonFrame.midX - frame.width / 2
        x = min(max(x, screen.visibleFrame.minX + 8),
                screen.visibleFrame.maxX - frame.width - 8)
        let y = buttonFrame.minY - frame.height - 6
        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
        waveView?.startAnimating()
        installOutsideClickMonitor()
    }

    override func close() {
        waveView?.stopAnimating()
        removeOutsideClickMonitor()
        super.close()
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    func apply(state: QuickPanelState) {
        self.state = state
        rebuildContent()
    }

    func t(_ russian: String, _ english: String) -> String {
        localizedText(russian, english, language: state.interfaceLanguage)
    }

    // MARK: - Сборка контента

    func rebuildContent() {
        let container = PaperBackgroundView()
        container.fill = SD.C.popoverPaper
        container.cornerRadius = 12
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        contentStack.subviews.forEach { $0.removeFromSuperview() }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(headerRow())
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(languageRow())
        stack.addArrangedSubview(microphoneRow())
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(recentHeader())
        // Макет: блок записей с полем 4px 6px 6px, ряды со скруглением 8.
        let recentBlock = NSStackView()
        recentBlock.orientation = .vertical
        recentBlock.alignment = .leading
        recentBlock.spacing = 0
        recentBlock.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 6, right: 6)
        // Сколько записей показывать, решает настройка «Недавнее в панели
        // меню-бара» (1/5/10): список приходит уже обрезанным по ней. Жёсткий
        // prefix(3) делал пилюли 1/5/10 враньём — они управляли только
        // подменю старого меню.
        for entry in state.recent {
            let row = recentRow(entry)
            recentBlock.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: recentBlock.widthAnchor,
                                       constant: -12).isActive = true
        }
        if state.recent.isEmpty {
            recentBlock.addArrangedSubview(emptyRecentRow())
        }
        stack.addArrangedSubview(recentBlock)
        stack.addArrangedSubview(hairline())
        stack.addArrangedSubview(statsRow())
        stack.addArrangedSubview(hairline(inset: 0))
        stack.addArrangedSubview(updateRow())
        stack.addArrangedSubview(footerRow())

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            // Жёсткая ширина: без неё длинная запись в «Недавнем»
            // продавливает fitting-ширину, и окно разъезжается на весь экран.
            stack.widthAnchor.constraint(equalToConstant: Self.panelWidth),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        for view in stack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

        contentView = container
        let height = stack.fittingSize.height
        setContentSize(NSSize(width: Self.panelWidth, height: height))
    }

    private func hairline(inset: CGFloat = 16) -> NSView {
        let line = SDHairlineView()
        line.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(line)
        NSLayoutConstraint.activate([
            wrapper.heightAnchor.constraint(equalToConstant: 1),
            line.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: inset),
            line.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -inset),
            line.centerYAnchor.constraint(equalTo: wrapper.centerYAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
        ])
        return wrapper
    }

    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = .labelColor, mono: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = mono
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        field.maximumNumberOfLines = 1
        // Текст обязан обрезаться, а не распирать панель.
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    // MARK: - Действия

    @objc func microphoneChanged(_ sender: NSPopUpButton) {
        let uid = (sender.selectedItem?.representedObject as? String) ?? ""
        quickDelegate?.quickPanelDidSelectInputDevice(uid: uid)
    }

    @objc func copyRecentClicked(_ sender: NSButton) {
        guard let text = sender.cell?.representedObject as? String else { return }
        quickDelegate?.quickPanelDidCopyRecent(text: text)
        confirmCopy(on: sender)
    }

    /// Копирование — единственное действие панели, которое ничего не меняет
    /// на экране: окно остаётся открытым, текст уходит в буфер молча, и
    /// человеку неоткуда узнать, сработало ли. Кнопка отвечает за себя сама.
    private func confirmCopy(on button: NSButton) {
        copyResetWorkItem?.cancel()
        let originalTitle = t("Скопировать", "Copy")
        button.title = t("Скопировано", "Copied")
        button.contentTintColor = SD.C.positive
        let reset = DispatchWorkItem { [weak button] in
            guard let button else { return }
            button.title = originalTitle
            button.contentTintColor = SD.C.ink
        }
        copyResetWorkItem = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: reset)
    }

    @objc func pasteRecentClicked(_ sender: NSButton) {
        guard let text = sender.cell?.representedObject as? String else { return }
        close()
        quickDelegate?.quickPanelDidPasteRecent(text: text)
    }

    @objc func settingsClicked() {
        close()
        quickDelegate?.quickPanelOpenSettings()
    }

    @objc func historyClicked() {
        close()
        quickDelegate?.quickPanelOpenHistory()
    }

    @objc func quitClicked() {
        close()
        quickDelegate?.quickPanelQuit()
    }
}

extension QuickPanelState {
    func microphoneUID(popupTitles: [NSMenuItem]) -> String {
        devices.first(where: { $0.name == microphoneName })?.uid ?? ""
    }
}

/// Оценка числа слов по символам: в хранилище статистики только
/// characterCount. 5.8 символа на слово — среднее для русского с
/// пробелами; для честности везде показывается как оценка.
func approximateWordCount(characters: Int) -> Int {
    max(0, Int((Double(characters) / 5.8).rounded()))
}
