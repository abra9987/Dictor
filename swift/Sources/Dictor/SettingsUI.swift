import AppKit

// Контролы окна настроек — построены с нуля по макету 2c/4b
// («Настройки Dictor», тёмная/светлая бумага). Никаких системных
// NSPopUpButton/NSSwitch: пилюли, тумблер и кейкапы рисуются сами,
// чтобы совпадать с дизайном в обеих темах.

// MARK: - Строка настройки (title + subtitle слева, контрол справа)

/// Контракт строки настройки для самотеста settings-reachable: заголовок,
/// по которому строку ищут, и контрол, в центр которого бьёт hitTest.
/// Реализуют обе разновидности строк — обычная и «Продвинутых».
@MainActor
protocol SettingsRowProviding {
    var rowTitle: String { get }
    var control: NSView { get }
}

/// Оформление строки. `plain` — старый вид (во всю ширину, хайрлайн снизу):
/// им живут строки вне вкладок настроек. `card` и `cardNested` — новая
/// раскладка, где строки лежат внутри группы-карточки: разделители рисует
/// группа, а строка знает только про свои отступы и типографику.
/// `cardNested` — строка-условие тумблера над ней (отступ и подложка
/// показывают подчинение, не повторяя его словами).
enum SDRowStyle {
    case plain
    case card
    case cardNested

    var leadingInset: CGFloat {
        switch self {
        case .plain: return 0
        case .card: return 14
        case .cardNested: return 30
        }
    }

    var trailingInset: CGFloat {
        switch self {
        case .plain: return 0
        case .card, .cardNested: return 14
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .plain: return 13
        case .card, .cardNested: return 11
        }
    }

    var titleFont: NSFont {
        switch self {
        case .plain: return .systemFont(ofSize: 13)
        case .card: return .systemFont(ofSize: 12.5, weight: .semibold)
        case .cardNested: return .systemFont(ofSize: 12.5, weight: .medium)
        }
    }

    var titleColor: NSColor {
        switch self {
        case .plain, .card: return SD.C.ink
        case .cardNested: return SD.C.inkSecondary
        }
    }

    var subtitleSize: CGFloat {
        switch self {
        case .plain: return 11
        case .card, .cardNested: return 11.5
        }
    }
}

final class SDRowView: NSView, SettingsRowProviding {
    private let hairline: Bool
    private let style: SDRowStyle
    /// Заголовок и контрол — открыты для самотеста settings-reachable:
    /// он находит строку по заголовку и бьёт hitTest в центр контрола.
    let rowTitle: String
    let control: NSView
    private var subtitleLabel: NSTextField?

    // Макет: padding 13px 0, разделитель rgba .06/.07 снизу,
    // заголовок 13px ink, подпись 11px subtle с отступом 1px.
    init(title: String,
         subtitle: String? = nil,
         control: NSView,
         hairline: Bool = true,
         verticalPadding: CGFloat? = nil,
         style: SDRowStyle = .plain,
         leading: NSView? = nil) {
        self.hairline = hairline && style == .plain
        self.style = style
        self.rowTitle = title
        self.control = control
        let verticalPadding = verticalPadding ?? style.verticalPadding
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = style.titleFont
        titleLabel.textColor = style.titleColor

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.addArrangedSubview(titleLabel)
        if let subtitle, !subtitle.isEmpty {
            let subtitleLabel = NSTextField(labelWithString: subtitle)
            subtitleLabel.font = .systemFont(ofSize: style.subtitleSize)
            subtitleLabel.textColor = SD.C.subtle
            // Длинная подпись переносится, а не толкает контрол за правый
            // край панели: однострочная intrinsic-ширина у трёх вкладок
            // выжимала строки на 26 pt за пределы видимой области.
            subtitleLabel.lineBreakMode = .byWordWrapping
            subtitleLabel.maximumNumberOfLines = 0
            subtitleLabel.setContentCompressionResistancePriority(.defaultLow,
                                                                  for: .horizontal)
            textStack.addArrangedSubview(subtitleLabel)
            self.subtitleLabel = subtitleLabel
        }

        for view in [textStack, control] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        // Высота строки = 2×padding + самый высокий элемент; без
        // low-priority «сжатия» неравенства дают неоднозначную высоту,
        // и стек растягивает строку произвольно.
        let squeeze = heightAnchor.constraint(equalToConstant: 0)
        squeeze.priority = .defaultLow
        // Маркер состояния слева — не контрол: он ничего не делает, поэтому
        // и не участвует в hitTest самотеста. Его место — перед заголовком,
        // как в макете «Службы».
        var textLeading: CGFloat = style.leadingInset
        if let leading {
            leading.translatesAutoresizingMaskIntoConstraints = false
            addSubview(leading)
            NSLayoutConstraint.activate([
                leading.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                 constant: style.leadingInset),
                leading.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            textLeading += 7 + 12
        }

        NSLayoutConstraint.activate([
            squeeze,
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor,
                                               constant: textLeading),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor,
                                           constant: verticalPadding),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -12),
            control.trailingAnchor.constraint(equalTo: trailingAnchor,
                                              constant: -style.trailingInset),
            control.centerYAnchor.constraint(equalTo: centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: topAnchor,
                                         constant: verticalPadding),
            bottomAnchor.constraint(greaterThanOrEqualTo: textStack.bottomAnchor,
                                    constant: verticalPadding),
            bottomAnchor.constraint(greaterThanOrEqualTo: control.bottomAnchor,
                                    constant: verticalPadding),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        // Ширину переноса нельзя задать в init — до первой раскладки ширина
        // строки нулевая (урок SDEnamelView). Контрол прижат к правому краю,
        // поэтому доступное подписи место от подписи не зависит — обратной
        // связи и вечной перераскладки тут нет.
        guard let subtitleLabel else { return }
        let available = control.frame.minX - 12 - style.leadingInset
        if available > 80, abs(subtitleLabel.preferredMaxLayoutWidth - available) > 0.5 {
            subtitleLabel.preferredMaxLayoutWidth = available
            subtitleLabel.invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Вложенная строка живёт на приглушённой подложке во всю ширину
        // карточки: отступа слева мало, чтобы прочесть подчинение.
        if style == .cardNested {
            SD.C.nestedRowWash.setFill()
            bounds.fill()
        }
        guard hairline else { return }
        SD.C.rowHairline.setFill()
        NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }

    override var isFlipped: Bool { true }
}

/// Маркер состояния 7×7 слева от строки. Форма отличает состояния помимо
/// цвета: выданное разрешение — круг, отозванное — скруглённый квадрат.
/// Цветом одним обходиться нельзя, и дело не только в дальтонизме: в списке
/// из трёх строк форма считывается быстрее оттенка.
final class SDStatusDot: NSView {
    enum Shape { case round, square }

    private let shape: Shape
    private let color: NSColor

    init(shape: Shape, color: NSColor) {
        self.shape = shape
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 7),
            heightAnchor.constraint(equalToConstant: 7),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 7, height: 7) }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        switch shape {
        case .round:
            NSBezierPath(ovalIn: bounds).fill()
        case .square:
            NSBezierPath(roundedRect: bounds, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// MARK: - Группа настроек (заголовок + карточка со строками)

/// Карточка одной темы: заголовок-подпись над бумагой, внутри — строки,
/// разделённые тонкой линией. Заголовок группы делает то, что раньше
/// сделала бы подвкладка, и позволяет держать навигацию плоской.
final class SDSettingsGroupCard: NSView {
    private let rowViews: [NSView]

    init(rows: [NSView]) {
        self.rowViews = rows
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 10, yRadius: 10)
        SD.C.groupCard.setFill()
        card.fill()
        // Разделители рисует карточка, а не строки: строке не полагается
        // знать, первая она в группе или последняя.
        // Координаты строки берём переводом, а не из frame: строки лежат в
        // NSStackView, чья система координат не перевёрнута, а карточка —
        // перевёрнута. Прямое чтение frame.minY отсчитывало разделители от
        // низа, и они ложились поперёк подписей.
        SD.C.groupRowDivider.setFill()
        for row in rowViews.dropFirst() {
            let top = row.convert(row.bounds, to: self).minY
            NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
        }
        SD.C.groupCardBorder.setStroke()
        card.lineWidth = 1
        card.stroke()
    }
}

/// Карточка фактов: та же геометрия, что у группы настроек, но приглушённая
/// подложка и никакого правого столбца управления. Утверждение и переключатель
/// больше не выглядят одинаково — а ни один ответ при этом не потерян.
final class SDFactCard: NSView {
    private let rowViews: [NSView]

    init(rows: [NSView]) {
        self.rowViews = rows
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        for row in rows {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 10, yRadius: 10)
        SD.C.factCard.setFill()
        card.fill()
        // Тот же перевод координат, что и в группе настроек.
        SD.C.groupRowDivider.setFill()
        for row in rowViews.dropFirst() {
            let top = row.convert(row.bounds, to: self).minY
            NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
        }
    }
}

/// Заголовок группы + её карточка. Отдельный тип, чтобы вкладка собиралась
/// из групп, а не из строк: раскладка тогда описывает смысл, а не пиксели.
@MainActor
func settingsGroup(_ title: String?, rows: [NSView]) -> NSView {
    let card = SDSettingsGroupCard(rows: rows)
    card.translatesAutoresizingMaskIntoConstraints = false
    guard let title, !title.isEmpty else { return card }

    let header = settingsGroupHeaderLabel(title)
    header.translatesAutoresizingMaskIntoConstraints = false

    let wrapper = NSView()
    wrapper.addSubview(header)
    wrapper.addSubview(card)
    NSLayoutConstraint.activate([
        header.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 2),
        header.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
        header.topAnchor.constraint(equalTo: wrapper.topAnchor),
        card.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
        card.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
        card.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
        card.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
    ])
    return wrapper
}

/// Строка «Продвинутых»: узкая подпись 96 pt, контрол и живое превью
/// справа. Класс существует ради самотеста достижимости — раскладку
/// целиком строит вызывающий (advancedCapsuleRow).
final class SDAdvancedRowView: NSView, SettingsRowProviding {
    let rowTitle: String
    let control: NSView

    init(rowTitle: String, control: NSView) {
        self.rowTitle = rowTitle
        self.control = control
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }
}
