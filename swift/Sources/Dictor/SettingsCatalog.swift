import AppKit

// MARK: - Реестр настроек
//
// Каждая var из Settings.swift обязана быть описана здесь: показана
// строкой во вкладке настроек, показана в другом месте окна, служебное
// состояние или пользовательские данные — с обязательным «почему».
//
// Зачем реестр существует: в этом проекте класс дефекта «настройка есть,
// работает и недостижима» дважды доходил до релиза (тумблер обновлений,
// девять настроек в англоязычном меню), а alternateCompletionEnabled
// вообще нельзя было выключить иначе как через defaults write. Сверку
// реестра со списком var в Settings.swift в обе стороны держит check.sh:
// новая настройка без записи здесь роняет сборку. Достижимость каждой
// строки `settingsRow` проверяет самотест settings-reachable.

enum SettingsExposure {
    /// Строка во вкладке настроек окна. `tab` — идентификатор вкладки
    /// (settingsTab), `title` — точный русский заголовок строки; самотест
    /// строит вкладку и находит строку по нему. `toggleTest: true` — контрол
    /// является тумблером без побочных эффектов, и тест кликает по нему,
    /// сверяя, что значение в Settings действительно перещёлкнулось.
    case settingsRow(tab: String, title: String, toggleTest: Bool)
    /// Показана в другом месте окна — вне вкладок настроек. Самотест вкладок
    /// её не строит; место названо, чтобы читатель знал, куда смотреть.
    case elsewhere(place: String)
    /// Служебное состояние приложения: интерфейса не имеет по назначению.
    case internalState
    /// Пользовательские данные, а не настройка: правятся своим разделом
    /// окна, а не строкой во вкладке.
    case userData
}

struct SettingsCatalogEntry {
    /// Имя var в Settings.swift — check.sh сверяет список в обе стороны.
    let property: String
    let exposure: SettingsExposure
    /// Почему настройка живёт именно там. Обязательное поле: запись без
    /// причины — это будущий спор с самим собой.
    let why: String
}

let SETTINGS_CATALOG: [SettingsCatalogEntry] = [
    // MARK: Вкладка «Диктовка»
    .init(property: "hotkeyKeycode",
          exposure: .settingsRow(tab: "hotkeys", title: "Начать / остановить диктовку",
                                 toggleTest: false),
          why: "Главный хоткей — первая строка вкладки про диктовку."),
    .init(property: "hotkeyModifiers",
          exposure: .settingsRow(tab: "hotkeys", title: "Начать / остановить диктовку",
                                 toggleTest: false),
          why: "Вторая половина того же сочетания — одна строка на пару ключей."),
    .init(property: "configuredHotkey",
          exposure: .internalState,
          why: "Производное от hotkeyKeycode + hotkeyModifiers, своей строки не имеет."),
    .init(property: "triggerMode",
          exposure: .settingsRow(tab: "hotkeys", title: "Режим клавиши", toggleTest: false),
          why: "Режим — свойство той же клавиши, что настраивается строкой выше."),
    .init(property: "alternateCompletionEnabled",
          exposure: .settingsRow(tab: "hotkeys", title: "Альтернативное завершение",
                                 toggleTest: false),
          why: "Тумблер второго сочетания; идёт через черновик с валидацией "
               + "конфликтов, поэтому кликом в тесте не переключается."),
    .init(property: "enterHotkeyKeycode",
          exposure: .settingsRow(tab: "hotkeys", title: "Сочетание завершения",
                                 toggleTest: false),
          why: "Сочетание видно, пока включён тумблер выше, — выключенное оно мертво."),
    .init(property: "enterHotkeyModifiers",
          exposure: .settingsRow(tab: "hotkeys", title: "Сочетание завершения",
                                 toggleTest: false),
          why: "Вторая половина сочетания завершения — одна строка на пару ключей."),
    .init(property: "configuredEnterHotkey",
          exposure: .internalState,
          why: "Производное от enterHotkeyKeycode + enterHotkeyModifiers."),
    .init(property: "primaryCompletionBehavior",
          exposure: .settingsRow(tab: "hotkeys", title: "После вставки текста",
                                 toggleTest: false),
          why: "Что происходит после вставки — часть поведения диктовки."),
    .init(property: "enterDelayMilliseconds",
          exposure: .settingsRow(tab: "hotkeys", title: "Задержка перед Enter",
                                 toggleTest: false),
          why: "Пара к «После вставки»: осмысленна только рядом с Enter."),
    .init(property: "pasteSuffix",
          exposure: .settingsRow(tab: "hotkeys", title: "После текста добавлять",
                                 toggleTest: false),
          why: "Хвост вставки — завершающий штрих того же цикла диктовки."),

    // MARK: Вкладка «Основное»
    .init(property: "interfaceLanguage",
          exposure: .settingsRow(tab: "general", title: "Язык интерфейса", toggleTest: false),
          why: "Первое, что человек ищет в незнакомом языке интерфейса."),
    .init(property: "agentEnabled",
          exposure: .settingsRow(tab: "general", title: "Служба диктовки", toggleTest: false),
          why: "Тумблер запускает и останавливает службу — кликом в тесте "
               + "его дёргать нельзя."),
    .init(property: "dictationLanguage",
          exposure: .settingsRow(tab: "general", title: "Алфавит вывода", toggleTest: false),
          why: "Настройка распознавания, нужная чаще прочих; дублируется "
               + "пилюлями в панели меню-бара."),
    .init(property: "inputDevice",
          exposure: .settingsRow(tab: "general", title: "Микрофон", toggleTest: false),
          why: "Источник звука — базовый выбор; дублируется в панели меню-бара."),
    .init(property: "muteWhileRecording",
          exposure: .settingsRow(tab: "general", title: "Глушить звук во время записи",
                                 toggleTest: true),
          why: "Поведение на время записи, о котором спрашивают рядом с микрофоном."),
    .init(property: "playFeedbackSounds",
          exposure: .settingsRow(tab: "general", title: "Звуки", toggleTest: true),
          why: "Сигналы диктовки — общесистемное поведение, не внешний вид."),
    .init(property: "checkForUpdates",
          exposure: .settingsRow(tab: "general", title: "Проверять обновления",
                                 toggleTest: true),
          why: "Первая просьба первого стороннего пользователя: тумблер сети "
               + "должен быть там, где его ищут."),

    // MARK: Вкладка «Внешний вид»
    .init(property: "showRecordingWaveform",
          exposure: .settingsRow(tab: "look", title: "Капсула записи", toggleTest: true),
          why: "Первая строка вкладки — раньше всего, чем капсула управляется."),
    .init(property: "floatingCapsuleEnabled",
          exposure: .settingsRow(tab: "look", title: "Плавающая капсула", toggleTest: true),
          why: "Постоянный объект на экране — это внешний вид рабочего стола."),
    .init(property: "recordingHUDBackgroundStyle",
          exposure: .settingsRow(tab: "look", title: "Фон капсулы", toggleTest: false),
          why: "Вид капсулы записи, строкой ниже её тумблера."),
    .init(property: "recordingHUDRecordingColor",
          exposure: .settingsRow(tab: "look", title: "Цвет волны", toggleTest: false),
          why: "Один цвет для записи и бренда — рядом с фоном."),
    .init(property: "showInDock",
          exposure: .settingsRow(tab: "look", title: "Значок в Dock", toggleTest: true),
          why: "Присутствие в Dock — внешний вид системы, не поведение диктовки."),
    .init(property: "recordingHUDTranscribingColor",
          exposure: .internalState,
          why: "Цвет фазы распознавания; контрола нет — фаза длится доли "
               + "секунды, и отдельный свотч для неё дороже пользы. Ключ "
               + "читается капсулой записи и остаётся настраиваемым через "
               + "defaults write."),

    // MARK: Вкладка «Продвинутые»
    .init(property: "recordingHUDSize",
          exposure: .settingsRow(tab: "advanced", title: "Размер", toggleTest: false),
          why: "Размер капсулы стоит рядом с живым превью, как в макете 6d."),
    .init(property: "recordingHUDPlacement",
          exposure: .settingsRow(tab: "advanced", title: "Положение", toggleTest: false),
          why: "Положение капсулы — тонкая настройка рядом с размером."),

    // MARK: Вкладка «Словарь»
    .init(property: "removeFillerWords",
          exposure: .settingsRow(tab: "dict", title: "Убирать слова-паразиты",
                                 toggleTest: true),
          why: "Правка текста после распознавания — это словарная работа."),
    .init(property: "transcriptCorrectionsSyncFile",
          exposure: .settingsRow(tab: "dict", title: "Синхронизация файлом",
                                 toggleTest: false),
          why: "Файл синхронизации — свойство словаря, живёт рядом с ним."),

    // MARK: Вкладка «Приватность»
    .init(property: "recentTranscriptLimit",
          exposure: .settingsRow(tab: "privacy", title: "Хранить историю", toggleTest: true),
          why: "Хранение текстов — решение о приватности; вторая строка "
               + "(«Недавнее в панели меню-бара») управляет той же настройкой."),
    .init(property: "preferredRecentTranscriptLimit",
          exposure: .internalState,
          why: "Память последнего ненулевого лимита: выключение и включение "
               + "истории возвращает прежнюю длину списка."),

    // MARK: Показано вне вкладок настроек
    .init(property: "builtInSpellingsEnabled",
          exposure: .elsewhere(place: "раздел «Словарь» сайдбара, карточка «Написание названий»"),
          why: "Встроенный набор стоит рядом со словами, которыми управляет."),
    .init(property: "latinTermRestorationsEnabled",
          exposure: .elsewhere(place: "раздел «Словарь» сайдбара, карточка «Названия латиницей»"),
          why: "Второй встроенный набор — рядом с первым."),

    // MARK: Пользовательские данные
    .init(property: "transcriptCorrections",
          exposure: .userData,
          why: "Сам словарь: правится в разделе «Словарь», а не строкой настроек."),
    .init(property: "dictationTranscriptCorrections",
          exposure: .internalState,
          why: "Производное: словарь человека плюс включённые встроенные наборы."),
    .init(property: "recentTranscriptEntries",
          exposure: .userData,
          why: "Архив истории: живёт в разделе «История», стирается кнопкой "
               + "в «Приватности»."),
    .init(property: "recentTranscriptHistory",
          exposure: .userData,
          why: "Строковое зеркало архива для обратной совместимости."),
    .init(property: "recentTranscriptEntriesStoredData",
          exposure: .internalState,
          why: "Сырые байты архива для дешёвого сравнения «изменилось ли снаружи»."),
    .init(property: "pinnedTranscripts",
          exposure: .userData,
          why: "Закрепления правятся в самой «Истории», где их видно."),
    .init(property: "dailyDictationUsage",
          exposure: .userData,
          why: "Счётчики статистики: смотрятся в разделе «Статистика»."),
    .init(property: "dismissedHints",
          exposure: .userData,
          why: "Закрытые подсказки «Сегодня»: закрыл — больше не возвращается."),
    .init(property: "floatingCapsulePositions",
          exposure: .userData,
          why: "Память места капсулы по мониторам — ставится перетаскиванием."),

    // MARK: Служебное состояние
    .init(property: "onboardingCompleted",
          exposure: .internalState,
          why: "Флаг «онбординг показан» — человеку переключать нечего."),
    .init(property: "didImportDictationUsageLog",
          exposure: .internalState,
          why: "Одноразовый флаг миграции старого журнала статистики."),
    .init(property: "speechModelProfile",
          exposure: .internalState,
          why: "Производственный профиль один; выбора не существует, карточка "
               + "второго профиля убрана как обещание без поведения."),
    .init(property: "lastUpdateCheckAt",
          exposure: .internalState,
          why: "Отметка времени автопроверки; показывается текстом, не настройка."),
    .init(property: "lastUpdateCheckSource",
          exposure: .internalState,
          why: "Кто запускал последнюю проверку — для честной строки «Версия»."),
    .init(property: "lastUpdateCheckResult",
          exposure: .internalState,
          why: "Исход последней проверки — для той же строки."),
    .init(property: "lastUpdateCheckVersion",
          exposure: .internalState,
          why: "Номер версии из последней проверки."),
    .init(property: "updateReminderPausedVersion",
          exposure: .internalState,
          why: "Половина «Напомнить через 24 часа» — ставится пунктом меню обновления."),
    .init(property: "updateReminderPausedUntil",
          exposure: .internalState,
          why: "Вторая половина того же напоминания."),
    .init(property: "lastSeenVersion",
          exposure: .internalState,
          why: "Какую версию человек уже видел — для «Что нового»."),
    .init(property: "skippedVersions",
          exposure: .internalState,
          why: "Пропущенные версии — ставится пунктом «Пропустить» в меню обновления."),
    .init(property: "hasActiveRunMarker",
          exposure: .internalState,
          why: "Маркер живого запуска для восстановления после сбоя."),
]
