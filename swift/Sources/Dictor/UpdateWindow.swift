import AppKit

// Окно «Доступно обновление».
//
// Раньше про новую версию сообщал системный NSAlert, а добраться до него
// можно было только через меню, которое открывается правым кликом по иконке
// в меню-баре. Правым кликом по иконке в строке состояния не пользуется
// почти никто, так что предложение обновиться существовало примерно нигде.
//
// Окно нарисовано в том же языке, что и остальное приложение: бумажный фон,
// волна, шрифтовая шкала и кнопки из SDTheme. Системный алерт выглядит как
// сообщение операционной системы — здесь же говорит само приложение, и
// говорить оно должно своим голосом.

@MainActor
protocol UpdateWindowDelegate: AnyObject {
    func updateWindowDidChooseInstall(version: String)
    func updateWindowDidChooseLater(version: String)
    func updateWindowDidChooseSkip(version: String)
}

@MainActor
final class UpdateAvailableWindow: NSWindow {
    weak var updateDelegate: UpdateWindowDelegate?

    private let release: DictorRelease
    private let currentVersion: String
    private let language: InterfaceLanguage
    private var statusLabel: NSTextField?
    private var buttonRow: NSStackView?

    static let windowWidth: CGFloat = 460

    init(release: DictorRelease,
         currentVersion: String,
         language: InterfaceLanguage) {
        self.release = release
        self.currentVersion = currentVersion
        self.language = language
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 460),
                   styleMask: [.titled, .closable, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)
        // Заголовок прозрачный, чтобы бумага доходила до верхнего края:
        // системная полоса поверх фирменного фона выглядит как чужая деталь.
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        contentView = makeContentView()
        fitHeightToContent()
    }

    /// Высота — по содержимому. Заметки к версии бывают в три строки и в
    /// тридцать, а окно с полосой пустоты снизу выглядит как незагрузившееся.
    private func fitHeightToContent() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = content.fittingSize.height
        guard height > 0 else { return }
        setContentSize(NSSize(width: Self.windowWidth, height: height))
    }

    private func t(_ ru: String, _ en: String) -> String {
        localizedText(ru, en, language: language)
    }

    private func makeContentView() -> NSView {
        let background = PaperBackgroundView()
        background.fill = SD.C.paper

        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 0
        root.edgeInsets = NSEdgeInsets(top: 34, left: 28, bottom: 24, right: 28)
        root.translatesAutoresizingMaskIntoConstraints = false

        // Волна — та же, что в поповере и на «Приватности»: подпись приложения,
        // по которой окно узнаётся до чтения текста.
        let wave = QuickPanelWaveView()
        wave.isActive = true
        wave.translatesAutoresizingMaskIntoConstraints = false
        wave.widthAnchor.constraint(equalToConstant: 60).isActive = true
        wave.heightAnchor.constraint(equalToConstant: 20).isActive = true
        root.addArrangedSubview(wave)
        root.setCustomSpacing(16, after: wave)

        let title = SD.windowTitleLabel(t("Доступна версия \(release.version)",
                                          "Version \(release.version) is available"))
        root.addArrangedSubview(title)
        root.setCustomSpacing(6, after: title)

        let subtitle = label(t("Установлена \(currentVersion). Обновление скачается, "
                               + "проверится и установится само.",
                               "You have \(currentVersion). The update downloads, "
                               + "verifies itself and installs."),
                             size: 13, color: SD.C.graphite)
        subtitle.preferredMaxLayoutWidth = Self.windowWidth - 56
        root.addArrangedSubview(subtitle)
        root.setCustomSpacing(18, after: subtitle)

        let notes = notesCard()
        root.addArrangedSubview(notes)
        notes.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true
        root.setCustomSpacing(16, after: notes)

        // Строка проверки — не украшение: приложение не нотаризовано, и человек
        // вправе знать, почему подсунуть чужую сборку по этому пути нельзя.
        let assurance = label(t("Архив сверяется с контрольной суммой и подписью Dictor.",
                                "The archive is checked against its checksum and Dictor’s signature."),
                              size: 11.5, color: SD.C.subtle)
        assurance.preferredMaxLayoutWidth = Self.windowWidth - 56
        root.addArrangedSubview(assurance)
        root.setCustomSpacing(18, after: assurance)

        let install = SDPrimaryActionButton(title: t("Обновить", "Update"),
                                            shortcut: nil,
                                            target: self,
                                            action: #selector(installClicked))
        let later = SDSecondaryButton(title: t("Позже", "Later"),
                                      target: self,
                                      action: #selector(laterClicked))
        let skip = SDSecondaryButton(title: t("Пропустить", "Skip"),
                                     target: self,
                                     action: #selector(skipClicked))
        skip.toolTip = t("Больше не предлагать версию \(release.version)",
                         "Stop offering version \(release.version)")

        let row = NSStackView(views: [install, later, NSView(), skip])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        buttonRow = row
        root.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -56).isActive = true

        // Место под ход установки. Появляется на месте кнопок, чтобы окно не
        // прыгало по высоте в момент нажатия.
        let status = label("", size: 12.5, color: SD.C.graphite)
        status.isHidden = true
        status.preferredMaxLayoutWidth = Self.windowWidth - 56
        statusLabel = status
        root.addArrangedSubview(status)

        background.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            root.topAnchor.constraint(equalTo: background.topAnchor),
            root.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        return background
    }

    /// Заметки к версии на карточке. Текст приходит с канала обновлений —
    /// это наш собственный файл, но выводим его как обычный текст, без
    /// разметки и без ссылок: манифест не должен уметь рисовать в окне.
    private func notesCard() -> NSView {
        let card = SDCardBackgroundView()
        card.translatesAutoresizingMaskIntoConstraints = false

        let body = release.body.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = body.isEmpty
            ? t("Описание изменений не пришло вместе с обновлением.",
                "This version arrived without release notes.")
            : body

        let scroll = SDSelectableTranscriptView(text: text,
                                                font: .systemFont(ofSize: 12.5),
                                                color: SD.C.ink,
                                                lineHeightMultiple: 1.45)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(scroll)
        NSLayoutConstraint.activate([
            card.heightAnchor.constraint(equalToConstant: 168),
            scroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])
        return card
    }

    private func label(_ text: String,
                       size: CGFloat,
                       weight: NSFont.Weight = .regular,
                       color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    /// Ход установки прямо в этом окне. Нажатие, после которого окно просто
    /// закрывается, читается как «ничего не произошло», а установка занимает
    /// десятки секунд.
    func showProgress(_ phase: String) {
        buttonRow?.isHidden = true
        statusLabel?.isHidden = false
        statusLabel?.stringValue = phase
        fitHeightToContent()
    }

    func showFailure(_ message: String) {
        buttonRow?.isHidden = false
        statusLabel?.isHidden = false
        statusLabel?.stringValue = message
        fitHeightToContent()
    }

    @objc private func installClicked() {
        showProgress(t("Начинаю обновление…", "Starting the update…"))
        updateDelegate?.updateWindowDidChooseInstall(version: release.version)
    }

    @objc private func laterClicked() {
        updateDelegate?.updateWindowDidChooseLater(version: release.version)
    }

    @objc private func skipClicked() {
        updateDelegate?.updateWindowDidChooseSkip(version: release.version)
    }
}

/// Рендер окна обновления в PNG — иначе «готово» держится на воображении.
/// Снимаем оба состояния: предложение и ход установки, в обеих темах.
@MainActor
func exportUpdateWindowPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let release = DictorRelease(
        tagName: "v1.1.2",
        version: "1.1.2",
        body: """
        Слово из «Истории» — сразу в словарь. Выделите неправильно услышанное \
        слово в тексте диктовки, и оно подставится в диалог автозамены.

        «Выйти» закрывает Dictor целиком, а не только иконку в меню-баре. \
        ⌘Q в окне делает то же самое.

        Обновление больше не оставляет машину без службы диктовки.
        """,
        htmlURL: UPDATE_CHANNEL_PAGE.absoluteString)

    var exported = 0
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        for (state, phase) in [("offer", String?.none),
                               ("installing", .some("Скачиваю и проверяю архив…"))] {
            let window = UpdateAvailableWindow(release: release,
                                               currentVersion: "1.1.1",
                                               language: .russian)
            window.appearance = NSAppearance(named: appearanceName)
            window.colorSpace = .sRGB
            if let phase { window.showProgress(phase) }
            window.layoutIfNeeded()
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            try data.write(to: directory.appendingPathComponent("update-\(state)-\(suffix).png"))
            exported += 1
        }
    }
    log("update window previews exported: \(exported) → \(directory.path)")
}
