import AppKit

// MARK: - Превью поповера (для визуальной сверки с макетом 1d/1e)

@MainActor
/// Язык — параметром, как у экспорта окна: витрина проекта двуязычная, и
/// английская страница с русской панелью выглядит как незаконченный перевод.
func exportQuickPanelPreviews(to directory: URL,
                              language: InterfaceLanguage = .russian) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var exported = 0
    // Строка обновления живёт в двух видах — «версия и кнопка проверки» и
    // «доступна новая версия». Снимаем оба: цветная строка появляется редко,
    // и увидеть её иначе можно только дождавшись релиза.
    for (base, appearanceName) in
        [("light", NSAppearance.Name.aqua),
         ("dark", NSAppearance.Name.darkAqua)] {
      // Третий кадр — служба на модели прошлой версии: в шапке самая длинная
      // из строк состояния, и проверять надо, что панель от неё не раздалась.
      let retrying = SpeechModelUpdateStatus(previousModelName: "Parakeet TDT v3",
                                             phase: .retrying, fraction: nil)
      let variants: [(String, String?, SpeechModelUpdateStatus?)] = [
          ("", nil, nil), ("-update", "1.1.3", nil), ("-model-update", nil, retrying),
      ]
      for (variant, offered, modelUpdate) in variants {
        let suffix = base + variant
        let now = Date()
        let state = QuickPanelState(
            enabled: true,
            language: .russian,
            microphoneName: language == .english
                ? "MacBook Pro (built-in)"
                : "MacBook Pro (встроенный)",
            devices: [],
            recent: (language == .english
                ? ["Hey! Sending a short recap of the call and the three next steps…",
                   "Let's talk Thursday at three, I'll send the invite",
                   "Headline: local dictation with no cloud — a look at Dictor"]
                : ["Привет! По итогам звонка присылаю короткое резюме и три следующих шага…",
                   "Давай созвонимся в четверг в три, я закину приглашение",
                   "Заголовок: локальная диктовка без облака — обзор Dictor"])
                .enumerated().map { index, text in
                    TranscriptHistoryEntry(
                        text: text,
                        transcriptionDurationSeconds: [1.2, 0.9, 0.8][index],
                        createdAt: now.addingTimeInterval([-120, -9000, -17000][index]))
                },
            historyKeepingEnabled: true,
            todayCharacters: 7192,
            todayAudioSeconds: 810,
            // Бары считаем боевой функцией из сырых символов, как живая
            // панель: семь завершённых дней плюс сегодняшний, и сегодня —
            // рекорд. Готовые доли в фикстуре скрывали перекос нормировки,
            // из-за которого рекордный бар вырастал выше своего блока.
            weekBars: dictationUsageBarFractions(
                [2_100, 3_900, 2_800, 5_600, 4_600, 7_000, 3_500, 7_192]),
            interfaceLanguage: language,
            availableUpdateVersion: offered,
            // Своя версия, а не зашитая: на витрине она была вечной 1.1.2.
            // Снимать поповер поэтому нужно собранным приложением
            // (`dist/Dictor.app/Contents/MacOS/Dictor`), а не debug-бинарём:
            // у того нет бандла, и версия выйдет 0.0.0.
            installedVersion: currentBundleVersion(),
            isCheckingForUpdates: false,
            serviceStatus: .ready(latencyMilliseconds: 180, modelUpdate: modelUpdate)
        )
        let panel = DictorQuickPanel(state: state)
        panel.appearance = NSAppearance(named: appearanceName)
        panel.apply(state: state)
        guard let view = panel.contentView else {
            throw SettingsPreviewExportError(message: "no popover content view")
        }
        view.layoutSubtreeIfNeeded()
        panel.layoutIfNeeded()
        panel.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw SettingsPreviewExportError(message: "no bitmap rep for popover-\(suffix)")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw SettingsPreviewExportError(message: "PNG encode failed for popover-\(suffix)")
        }
        try png.write(to: directory.appendingPathComponent("popover-\(suffix).png"),
                      options: .atomic)
        exported += 1
      }
    }
    guard exported > 0 else {
        throw SettingsPreviewExportError(message: "nothing exported")
    }
    print("POPOVER_PREVIEW exported \(exported) files to \(directory.path)")
}
