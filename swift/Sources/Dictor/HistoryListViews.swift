import AppKit

// MARK: - Список «Истории»

/// Средняя колонка «Истории»: строки создаются только для того, что видно.
///
/// Раньше список был стопкой из всех диктовок разом. Окно при любом изменении
/// пересобирается целиком, и на 1125 записях одна только раскладка занимала
/// 27 секунд: каждый клик по строке, каждый символ в поиске, каждая новая
/// диктовка. Стоимость росла вместе с историей, а предел архива — десять
/// тысяч записей. Таблица держит десяток видимых строк независимо от длины
/// списка.
///
/// Строка остаётся тем же `SDHistoryResultRow`: таблица здесь только
/// механизм, а не внешний вид — выделения, заголовка и сетки у неё нет.
final class SDHistoryListView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let rowCount: Int
    private let makeRow: (Int) -> SDHistoryResultRow

    /// `makeRow` получает позицию в отфильтрованном списке и возвращает
    /// готовую строку.
    init(rowCount: Int, makeRow: @escaping (Int) -> SDHistoryResultRow) {
        self.rowCount = rowCount
        self.makeRow = makeRow
        super.init(frame: .zero)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.focusRingType = .none
        table.allowsColumnResizing = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.intercellSpacing = NSSize(width: 0, height: 3)
        // Строка занимает одну или две строки текста, поэтому высоту считает
        // раскладка; число здесь — только оценка для ещё не показанных строк.
        table.usesAutomaticRowHeights = true
        table.rowHeight = 62
        table.dataSource = self
        table.delegate = self

        documentView = table
        drawsBackground = false
        hasVerticalScroller = true
        verticalScroller?.controlSize = .small
        // Окно с fullSizeContentView: скролл сам добавил бы сверху отступ
        // высотой с тайтлбар, чтобы содержимое не уезжало под кнопки окна.
        // Кнопки лежат над сайдбаром, а не над этой панелью, так что отступ
        // здесь — просто пустая полоса над первой строкой.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 12, right: 0)
    }

    required init?(coder: NSCoder) { nil }

    /// Колонка обязана быть ровно шириной видимой области. Таблица создаётся
    /// раньше, чем узнаёт свой размер, и сама колонку под него не подгоняет:
    /// строка получалась шире окна, текст не переносился, а время справа
    /// уезжало за край. Видимая область уже на полосу прокрутки, если в
    /// системе включён её постоянный показ, — поэтому ширина берётся отсюда,
    /// а не из макета.
    override func tile() {
        super.tile()
        let width = contentView.bounds.width
        guard width > 0, let column = table.tableColumns.first,
              abs(column.width - width) > 0.5 else { return }
        column.minWidth = width
        column.maxWidth = width
        column.width = width
        // Высота строки зависит от ширины: при другой ширине текст
        // переносится иначе.
        table.reloadData()
    }

    /// Сколько строк сейчас существует как виды. Для самотеста: он сторожит
    /// именно то, ради чего список стал таблицей.
    var materializedRowCount: Int {
        table.rows(in: table.visibleRect).length
    }

    var verticalOffset: CGFloat {
        get { contentView.bounds.origin.y }
        set {
            contentView.scroll(to: NSPoint(x: 0, y: newValue))
            reflectScrolledClipView(contentView)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let content = makeRow(row)
        content.translatesAutoresizingMaskIntoConstraints = false
        // Поля по 8 pt с каждой стороны, как у прежней стопки строк.
        content.layoutWidth = (tableColumn?.width ?? contentView.bounds.width) - 16
        let cell = NSView()
        cell.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            content.topAnchor.constraint(equalTo: cell.topAnchor),
            content.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
        ])
        return cell
    }

    /// Выбранную запись рисует сама строка — белой карточкой с коралловым
    /// кольцом; выделение таблицы легло бы поверх второй рамкой.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
}

// MARK: - Полный текст диктовки

/// Текст диктовки в правой колонке «Истории». Настоящий NSTextView, а не
/// подпись: диктовку разбирают по кускам — выделяют слово двойным щелчком,
/// строку тройным, копируют выделенное на ⌘C или через контекстное меню.
/// Подпись отдавала только всё целиком, кнопкой «Копировать».
/// NSTextView с одним добавленным пунктом контекстного меню — «В словарь…».
/// Слово, которое модель услышала не так, попадается на глаза именно здесь,
/// в собственной расшифровке; заставлять человека запомнить его, уйти в
/// «Словарь» и набрать заново — это просить его поработать за программу.
final class SDTranscriptTextView: NSTextView {
    weak var dictionaryTarget: AnyObject?
    var dictionaryAction: Selector?
    var dictionaryItemTitle = ""

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        // Только при выделении: пункт «В словарь…» без выделенного слова
        // ничего не значит, а неактивный пункт в меню — это вопрос без ответа.
        guard let menu, let action = dictionaryAction, selectedRange().length > 0 else {
            return menu
        }
        menu.insertItem(.separator(), at: 0)
        let item = NSMenuItem(title: dictionaryItemTitle, action: action, keyEquivalent: "")
        item.target = dictionaryTarget
        menu.insertItem(item, at: 0)
        return menu
    }
}

final class SDSelectableTranscriptView: NSScrollView {
    let textView = SDTranscriptTextView()

    /// Выделенный кусок расшифровки — то, что человек показал пальцем.
    var selectedText: String {
        let range = textView.selectedRange()
        guard range.length > 0,
              let text = textView.textStorage?.string as NSString? else { return "" }
        return text.substring(with: range)
    }

    /// Настроить пункт «В словарь…». Заголовок приходит снаружи: язык
    /// интерфейса живёт в панели, а не во вью.
    func setDictionaryItem(title: String, target: AnyObject?, action: Selector) {
        textView.dictionaryItemTitle = title
        textView.dictionaryTarget = target
        textView.dictionaryAction = action
    }

    init(text: String, font: NSFont, color: NSColor, lineHeightMultiple: CGFloat) {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        verticalScroller?.controlSize = .small
        autohidesScrollers = true
        borderType = .noBorder

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeightMultiple

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isRichText = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        // Перенос по ширине колонки: контейнер тянется за вью, вью — за
        // шириной скролла. Без этого длинная диктовка уезжает в одну строку.
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textStorage?.setAttributedString(NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ]))
        documentView = textView
    }

    required init?(coder: NSCoder) { nil }

    /// Пока в тексте что-то выделено, окно не имеет права пересобираться:
    /// пересборка заменит вью и выделение исчезнет прямо под курсором.
    var hasSelection: Bool { textView.selectedRange().length > 0 }

    /// ⌘C на кнопке «Копировать» обещает копию всей диктовки, а NSTextView
    /// без выделения по ⌘C не копирует ничего. Пустое выделение — значит
    /// пользователь просил запись целиком; непустое обрабатывает сам
    /// NSTextView. Чужой текст (поле поиска в фокусе) не трогаем.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "c",
              !hasSelection,
              !someoneElseIsEditing else {
            return super.performKeyEquivalent(with: event)
        }
        let text = textView.string
        guard !text.isEmpty else { return super.performKeyEquivalent(with: event) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        return true
    }

    private var someoneElseIsEditing: Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder === textView { return false }
        return responder is NSText || responder is NSTextView
    }
}
