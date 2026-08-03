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

/// Вкладки настроек — один список на таб-бар, реестр и самотесты.
/// Правило деления: вкладка отвечает на один вопрос человека, а не на один
/// кусок кода. «Диктовка» — что происходит до текста, «Текст» — что после,
/// «Вид» — что видно на экране, «Приватность» — что уходит с этого Mac,
/// «Приложение» — про сам продукт. Состояние службы (разрешения, модель,
/// измерения) вкладкой не является и живёт разделом окна: переключать там
/// нечего.
struct SettingsTab {
    let id: String
    let ru: String
    let en: String

    func title(_ language: InterfaceLanguage) -> String {
        localizedText(ru, en, language: language)
    }
}

let SETTINGS_TABS: [SettingsTab] = [
    .init(id: "dictation", ru: "Диктовка", en: "Dictation"),
    .init(id: "text", ru: "Текст", en: "Text"),
    .init(id: "look", ru: "Вид", en: "Look"),
    .init(id: "privacy", ru: "Приватность", en: "Privacy"),
    .init(id: "app", ru: "Приложение", en: "App"),
]

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
    // MARK: Вкладка «Диктовка» — всё, что происходит до текста
    .init(property: "hotkeyKeycode",
          exposure: .settingsRow(tab: "dictation", title: "Начать и остановить диктовку",
                                 toggleTest: false),
          why: "Главный хоткей — первая строка группы «Как начать»."),
    .init(property: "hotkeyModifiers",
          exposure: .settingsRow(tab: "dictation", title: "Начать и остановить диктовку",
                                 toggleTest: false),
          why: "Вторая половина того же сочетания — одна строка на пару ключей."),
    .init(property: "configuredHotkey",
          exposure: .internalState,
          why: "Производное от hotkeyKeycode + hotkeyModifiers, своей строки не имеет."),
    .init(property: "triggerMode",
          exposure: .settingsRow(tab: "dictation", title: "Режим клавиши", toggleTest: false),
          why: "Режим — свойство той же клавиши, что настраивается строкой выше."),
    .init(property: "alternateCompletionEnabled",
          exposure: .settingsRow(tab: "dictation", title: "Отдельное сочетание для завершения",
                                 toggleTest: false),
          why: "Тумблер второго сочетания; идёт через черновик с валидацией "
               + "конфликтов, поэтому кликом в тесте не переключается."),
    .init(property: "enterHotkeyKeycode",
          exposure: .settingsRow(tab: "dictation", title: "Сочетание завершения",
                                 toggleTest: false),
          why: "Вложенная строка под своим тумблером: выключенное сочетание мертво, "
               + "и показывать его в общем потоке не за чем."),
    .init(property: "enterHotkeyModifiers",
          exposure: .settingsRow(tab: "dictation", title: "Сочетание завершения",
                                 toggleTest: false),
          why: "Вторая половина сочетания завершения — одна строка на пару ключей."),
    .init(property: "configuredEnterHotkey",
          exposure: .internalState,
          why: "Производное от enterHotkeyKeycode + enterHotkeyModifiers."),
    .init(property: "inputDevice",
          exposure: .settingsRow(tab: "dictation", title: "Микрофон", toggleTest: false),
          why: "Чем слушаем: микрофон вспоминают, когда собираются говорить, а не "
               + "когда читают вкладку про приложение. Дубль в панели меню-бара "
               + "оставлен намеренно — там его меняют в момент диктовки."),
    .init(property: "dictationLanguage",
          exposure: .settingsRow(tab: "dictation", title: "Алфавит вывода", toggleTest: false),
          why: "Свойство речи, а не приложения; стоит рядом с микрофоном. "
               + "Дублируется пилюлями в панели меню-бара."),
    .init(property: "muteWhileRecording",
          exposure: .settingsRow(tab: "dictation", title: "Глушить звук во время записи",
                                 toggleTest: true),
          why: "Тишина вокруг записи — часть того, чем слушаем."),
    .init(property: "playFeedbackSounds",
          exposure: .settingsRow(tab: "dictation", title: "Звуки диктовки", toggleTest: true),
          why: "Сигналы начала и конца диктовки — про саму диктовку, не про вид."),

    // MARK: Вкладка «Текст» — в каком виде придёт сказанное
    .init(property: "primaryCompletionBehavior",
          exposure: .settingsRow(tab: "text", title: "После вставки текста",
                                 toggleTest: false),
          why: "Что происходит с текстом после вставки — вопрос про результат, "
               + "а не про начало диктовки."),
    .init(property: "enterDelayMilliseconds",
          exposure: .settingsRow(tab: "text", title: "Задержка перед Enter",
                                 toggleTest: false),
          why: "Пара к «После вставки»: приглушена и не принимает нажатий, пока "
               + "Enter не выбран, и подписью объясняет своё условие."),
    .init(property: "pasteSuffix",
          exposure: .settingsRow(tab: "text", title: "После текста добавлять",
                                 toggleTest: false),
          why: "Хвост вставки — последний штрих того же результата."),
    .init(property: "removeFillerWords",
          exposure: .settingsRow(tab: "text", title: "Убирать слова-паразиты",
                                 toggleTest: true),
          why: "Правка речи после распознавания — тоже вид текста."),
    .init(property: "builtInSpellingsEnabled",
          exposure: .settingsRow(tab: "text", title: "Написание названий", toggleTest: true),
          why: "Встроенный набор правок. Карточка-дубль в разделе «Словарь» снята: "
               + "два места для одной настройки расходятся сначала подписью, "
               + "потом поведением."),
    .init(property: "latinTermRestorationsEnabled",
          exposure: .settingsRow(tab: "text", title: "Названия латиницей", toggleTest: true),
          why: "Второй встроенный набор — рядом с первым, тоже без дубля."),
    .init(property: "transcriptCorrectionsSyncFile",
          exposure: .settingsRow(tab: "text", title: "Синхронизация файлом",
                                 toggleTest: false),
          why: "Файл синхронизации — свойство своего словаря, стоит рядом с ним."),

    // MARK: Вкладка «Вид» — что видно на экране
    .init(property: "showRecordingWaveform",
          exposure: .settingsRow(tab: "look", title: "Показывать капсулу", toggleTest: true),
          why: "Первая строка группы «Капсула записи»: остальные настраивают то, "
               + "что она показывает."),
    .init(property: "recordingHUDSize",
          exposure: .settingsRow(tab: "look", title: "Размер", toggleTest: false),
          why: "Размер капсулы стоит под её же превью — главный шов старой "
               + "раскладки (тумблер во «Внешнем виде», размер в «Продвинутых») закрыт."),
    .init(property: "recordingHUDPlacement",
          exposure: .settingsRow(tab: "look", title: "Положение", toggleTest: false),
          why: "Положение капсулы — соседняя строка к размеру, в той же группе."),
    .init(property: "recordingHUDBackgroundStyle",
          exposure: .settingsRow(tab: "look", title: "Фон", toggleTest: false),
          why: "Вид капсулы записи, в одной группе с её размером и положением."),
    .init(property: "recordingHUDRecordingColor",
          exposure: .settingsRow(tab: "look", title: "Цвет волны", toggleTest: false),
          why: "Один цвет для записи и бренда — рядом с фоном."),
    .init(property: "floatingCapsuleEnabled",
          exposure: .settingsRow(tab: "look", title: "Плавающая капсула", toggleTest: true),
          why: "Своя группа, а не соседняя строка: настройки капсулы записи на "
               + "плавающую не действуют, и соседство в карточке обещало бы обратное."),
    .init(property: "showInDock",
          exposure: .settingsRow(tab: "look", title: "Значок в Dock", toggleTest: true),
          why: "Присутствие на рабочем столе — тоже «что видно», рядом с плавающей капсулой."),
    .init(property: "recordingHUDTranscribingColor",
          exposure: .internalState,
          why: "Цвет фазы распознавания; контрола нет — фаза длится доли "
               + "секунды, и отдельный свотч для неё дороже пользы. Ключ "
               + "читается капсулой записи, строка «Цвет волны» об этом говорит."),

    // MARK: Вкладка «Приватность» — что уходит с этого Mac
    .init(property: "recentTranscriptLimit",
          exposure: .settingsRow(tab: "privacy", title: "Хранить историю диктовок",
                                 toggleTest: true),
          why: "Хранение текстов — решение о приватности; вторая строка "
               + "(«Недавнее в панели меню-бара») управляет той же настройкой."),
    .init(property: "preferredRecentTranscriptLimit",
          exposure: .internalState,
          why: "Память последнего ненулевого лимита: выключение и включение "
               + "истории возвращает прежнюю длину списка."),

    // MARK: Вкладка «Приложение» — про сам продукт
    .init(property: "interfaceLanguage",
          exposure: .settingsRow(tab: "app", title: "Язык интерфейса", toggleTest: false),
          why: "Свойство продукта, а не диктовки: ищут рядом с версией и обновлениями."),
    .init(property: "agentEnabled",
          exposure: .settingsRow(tab: "app", title: "Запускать диктовку в фоне",
                                 toggleTest: false),
          why: "Только автозапуск. Раньше тот же ключ значил ещё и «включена "
               + "сейчас» — состояние уехало в панель меню-бара (пауза) и в "
               + "подвал сайдбара. Кликом в тесте не дёргаем: тумблер "
               + "устанавливает и снимает службу."),
    .init(property: "checkForUpdates",
          exposure: .settingsRow(tab: "app", title: "Проверять обновления",
                                 toggleTest: true),
          why: "Единственный сетевой запрос живёт одной строкой; «Приватность» "
               + "показывает его следствие и ссылается сюда."),

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
          why: "Закрытые подсказки «Сегодня». Кнопка «Вернуть» в «Продвинутых» "
               + "сбрасывает список — раньше «навсегда» было буквальным."),
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
