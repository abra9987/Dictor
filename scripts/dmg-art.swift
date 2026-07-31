#!/usr/bin/env swift
//
// Оформление установочного образа: фон окна Finder и иконка самого .dmg.
// Палитра и типографика те же, что в приложении (SDTheme), поэтому образ
// выглядит продолжением Dictor, а не безымянной коробкой.
//
// Использование:
//   swift dmg-art.swift background <фон.png> <фон@2x.png>
//   swift dmg-art.swift icon <иконка.icns> <файл>
//

import AppKit

// MARK: - Палитра и размеры

enum Art {
    /// Размер окна образа. Вся вёрстка живёт в этом прямоугольнике.
    static let width: CGFloat = 660
    static let height: CGFloat = 520

    /// Холст больше окна. Заблокировать размер окна Finder macOS не даёт, а
    /// фон рисуется от левого верхнего угла и не тянется — без запаса
    /// растянутое окно показывало бы вокруг картинки пустой серый провал.
    /// Лишняя площадь — чистый градиент, вёрстку она не трогает.
    static let canvasWidth: CGFloat = 1400
    static let canvasHeight: CGFloat = 900

    static let paperTop = NSColor(srgbRed: 0xF8 / 255, green: 0xF7 / 255, blue: 0xF4 / 255, alpha: 1)
    static let paperBottom = NSColor(srgbRed: 0xEC / 255, green: 0xEA / 255, blue: 0xE4 / 255, alpha: 1)
    static let ink = NSColor(srgbRed: 0x1C / 255, green: 0x1B / 255, blue: 0x19 / 255, alpha: 1)
    static let graphite = NSColor(srgbRed: 0x6E / 255, green: 0x6B / 255, blue: 0x66 / 255, alpha: 1)
    static let subtle = NSColor(srgbRed: 0xA3 / 255, green: 0xA0 / 255, blue: 0x9A / 255, alpha: 1)
    static let voice = NSColor(srgbRed: 0xE8 / 255, green: 0x50 / 255, blue: 0x2F / 255, alpha: 1)
    static let card = NSColor.white

    /// Центры иконок в координатах окна Finder (начало — левый верхний угол).
    static let appIconCenter = CGPoint(x: 170, y: 234)
    static let dropIconCenter = CGPoint(x: 490, y: 234)

    /// Нижняя полоса холста остаётся пустой: у кого включена панель пути
    /// Finder, она накроет именно её, а не текст.
    static let safeBottom: CGFloat = 44
}

// MARK: - Помощники рисования

func roundedRect(_ rect: CGRect, radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

func draw(_ text: String,
          in rect: CGRect,
          font: NSFont,
          color: NSColor,
          alignment: NSTextAlignment = .center,
          lineHeight: CGFloat? = nil) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    (text as NSString).draw(in: rect, withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
        .kern: 0.1
    ])
}

/// Пять столбиков волны — тот же знак, что живёт в меню-баре.
func drawWaveMark(center: CGPoint, unit: CGFloat) {
    let heights: [CGFloat] = [0.34, 0.68, 1.0, 0.68, 0.34]
    let barWidth = unit * 0.62
    let gap = unit * 0.52
    let total = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = center.x - total / 2
    for (index, factor) in heights.enumerated() {
        let barHeight = unit * 2.4 * factor
        let rect = CGRect(x: x, y: center.y - barHeight / 2, width: barWidth, height: barHeight)
        let alpha = index == 2 ? 1.0 : 0.78
        Art.voice.withAlphaComponent(alpha).setFill()
        roundedRect(rect, radius: barWidth / 2).fill()
        x += barWidth + gap
    }
}

/// Стрелка «перетащи сюда»: скруглённая линия и треугольное остриё.
func drawArrow(from start: CGPoint, to end: CGPoint) {
    let headLength: CGFloat = 15
    let headHalfWidth: CGFloat = 8
    let shaftEnd = CGPoint(x: end.x - headLength + 2, y: end.y)

    Art.voice.withAlphaComponent(0.9).setStroke()
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: shaftEnd)
    shaft.lineWidth = 3
    shaft.lineCapStyle = .round
    shaft.stroke()

    Art.voice.withAlphaComponent(0.9).setFill()
    let head = NSBezierPath()
    head.move(to: CGPoint(x: end.x, y: end.y))
    head.line(to: CGPoint(x: end.x - headLength, y: end.y - headHalfWidth))
    head.line(to: CGPoint(x: end.x - headLength, y: end.y + headHalfWidth))
    head.close()
    head.fill()
}

// MARK: - Фон окна

func drawBackground() {
    let bounds = CGRect(x: 0, y: 0, width: Art.canvasWidth, height: Art.canvasHeight)

    // Градиент доходит до низа окна ровно так же, как раньше, а ниже держит
    // конечный цвет — иначе на запасной площади он бы растянулся и верхняя,
    // видимая часть окна выцвела бы.
    let stop = Art.height / Art.canvasHeight
    let gradient = NSGradient(colorsAndLocations: (Art.paperTop, 0),
                              (Art.paperBottom, stop),
                              (Art.paperBottom, 1))
    gradient?.draw(in: bounds, angle: -90)

    // Шапка.
    drawWaveMark(center: CGPoint(x: Art.width / 2, y: 40), unit: 8)

    draw("Dictor",
         in: CGRect(x: 0, y: 60, width: Art.width, height: 44),
         font: .systemFont(ofSize: 33, weight: .semibold),
         color: Art.ink)

    draw("Локальная диктовка для macOS",
         in: CGRect(x: 0, y: 104, width: Art.width, height: 22),
         font: .systemFont(ofSize: 14, weight: .regular),
         color: Art.graphite)

    // Зона броска: пунктирная рамка вокруг папки «Программы».
    let dropRect = CGRect(x: Art.dropIconCenter.x - 88,
                          y: Art.dropIconCenter.y - 90,
                          width: 176,
                          height: 186)
    let dropPath = roundedRect(dropRect, radius: 22)
    NSColor.white.withAlphaComponent(0.55).setFill()
    dropPath.fill()
    Art.subtle.withAlphaComponent(0.75).setStroke()
    dropPath.lineWidth = 1.5
    dropPath.setLineDash([7, 6], count: 2, phase: 0)
    dropPath.stroke()

    drawArrow(from: CGPoint(x: Art.appIconCenter.x + 90, y: Art.appIconCenter.y),
              to: CGPoint(x: Art.dropIconCenter.x - 108, y: Art.appIconCenter.y))

    // Карточка первого запуска.
    let cardRect = CGRect(x: 48, y: 352, width: Art.width - 96, height: 94)
    let cardPath = roundedRect(cardRect, radius: 16)
    NSGraphicsContext.current?.cgContext.setShadow(
        offset: CGSize(width: 0, height: 3),
        blur: 10,
        color: NSColor.black.withAlphaComponent(0.07).cgColor)
    Art.card.setFill()
    cardPath.fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
    NSColor.black.withAlphaComponent(0.07).setStroke()
    cardPath.lineWidth = 1
    cardPath.stroke()

    // Значок-восклицание в фирменном цвете.
    let badgeRect = CGRect(x: cardRect.minX + 22, y: cardRect.minY + 22, width: 30, height: 30)
    Art.voice.withAlphaComponent(0.12).setFill()
    NSBezierPath(ovalIn: badgeRect).fill()
    draw("!",
         in: CGRect(x: badgeRect.minX, y: badgeRect.minY + 5, width: badgeRect.width, height: 22),
         font: .systemFont(ofSize: 17, weight: .bold),
         color: Art.voice)

    let textX = cardRect.minX + 68
    let textWidth = cardRect.width - 68 - 24

    draw("Первый запуск",
         in: CGRect(x: textX, y: cardRect.minY + 20, width: textWidth, height: 20),
         font: .systemFont(ofSize: 13.5, weight: .semibold),
         color: Art.ink,
         alignment: .left)

    draw("""
         macOS скажет, что не может проверить разработчика — приложение подписано \
         самостоятельно. Системные настройки → «Конфиденциальность и безопасность» \
         → «Открыть всё равно».
         """,
         in: CGRect(x: textX, y: cardRect.minY + 41, width: textWidth, height: 48),
         font: .systemFont(ofSize: 12, weight: .regular),
         color: Art.graphite,
         alignment: .left,
         lineHeight: 16)

    // Подвал.
    draw("Apple Silicon · macOS 14 или новее · при первом запуске скачает модель ~460 МБ",
         in: CGRect(x: 0, y: Art.height - Art.safeBottom - 18, width: Art.width, height: 18),
         font: .systemFont(ofSize: 11, weight: .regular),
         color: Art.subtle)
}

func renderBackground(to url: URL, scale: CGFloat) throws {
    let pixelWidth = Int(Art.canvasWidth * scale)
    let pixelHeight = Int(Art.canvasHeight * scale)
    guard let context = CGContext(data: nil,
                                  width: pixelWidth,
                                  height: pixelHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else {
        throw ArtError("Не удалось создать растровый контекст.")
    }

    // Начало координат — левый верхний угол, как в окне Finder.
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: Art.canvasHeight)
    context.scaleBy(x: 1, y: -1)

    let previous = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    drawBackground()
    NSGraphicsContext.current = previous

    guard let image = context.makeImage() else {
        throw ArtError("Не удалось получить изображение из контекста.")
    }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: Art.canvasWidth, height: Art.canvasHeight)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw ArtError("Не удалось закодировать PNG.")
    }
    try data.write(to: url)
}

// MARK: - Иконка файла

func applyIcon(icns: URL, to file: URL) throws {
    guard let image = NSImage(contentsOf: icns) else {
        throw ArtError("Не удалось прочитать \(icns.path)")
    }
    guard NSWorkspace.shared.setIcon(image, forFile: file.path, options: []) else {
        throw ArtError("Не удалось назначить иконку файлу \(file.path)")
    }
}

// MARK: - Точка входа

struct ArtError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let arguments = Array(CommandLine.arguments.dropFirst())

do {
    switch arguments.first {
    case "background":
        guard arguments.count == 3 else {
            throw ArtError("Использование: dmg-art.swift background <фон.png> <фон@2x.png>")
        }
        try renderBackground(to: URL(fileURLWithPath: arguments[1]), scale: 1)
        try renderBackground(to: URL(fileURLWithPath: arguments[2]), scale: 2)
    case "icon":
        guard arguments.count == 3 else {
            throw ArtError("Использование: dmg-art.swift icon <иконка.icns> <файл>")
        }
        try applyIcon(icns: URL(fileURLWithPath: arguments[1]),
                      to: URL(fileURLWithPath: arguments[2]))
    default:
        throw ArtError("Неизвестная команда. Доступны: background, icon.")
    }
} catch {
    FileHandle.standardError.write("dmg-art: \(error)\n".data(using: .utf8)!)
    exit(1)
}
