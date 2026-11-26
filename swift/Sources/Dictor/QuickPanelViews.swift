import AppKit

// MARK: - Живая мини-волна статуса

final class QuickPanelWaveView: NSView {
    var isActive = true
    var isHot = false
    private var timer: Timer?
    private var phase: CGFloat = 0

    func startAnimating() {
        stopAnimating()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            needsDisplay = true
            return
        }
        let timer = Timer(timeInterval: 1.0 / 12.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.phase += 0.45
                self.needsDisplay = true
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopAnimating() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let barCount = 6
        let barWidth: CGFloat = 1.5
        let gap: CGFloat = 1.5
        let color = isActive ? SD.C.voice : NSColor.tertiaryLabelColor
        color.setFill()
        for index in 0..<barCount {
            let i = CGFloat(index)
            let motion: CGFloat
            if isActive {
                let travel = (sin(phase - i * 0.9) + 1) / 2
                motion = (isHot ? 0.45 : 0.2) + (isHot ? 0.55 : 0.35) * travel
            } else {
                motion = 0.18
            }
            let height = max(2, motion * bounds.height)
            let rect = NSRect(x: CGFloat(index) * (barWidth + gap),
                              y: bounds.midY - height / 2,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
    }
}

// MARK: - Мини-бары недельной статистики

final class QuickPanelStatBars: NSView {
    private let values: [CGFloat]

    init(values: [CGFloat]) {
        self.values = values
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !values.isEmpty else { return }
        let barWidth: CGFloat = 3
        let gap: CGFloat = 2
        SD.C.voice.withAlphaComponent(0.6).setFill()
        for (index, value) in values.enumerated() {
            // Доля обязана лежать в [0…1], но верхнюю кромку держим здесь же:
            // рекордный день не должен рисовать бар поверх соседних строк.
            let fraction = min(1, max(0, value.isFinite ? value : 0))
            let height = min(bounds.height, max(2, fraction * bounds.height))
            // Бары растут от нижней кромки (align-items:end в макете).
            let rect = NSRect(x: CGFloat(index) * (barWidth + gap),
                              y: 0,
                              width: barWidth,
                              height: height)
            NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()
        }
    }
}

// MARK: - Подложка футера поповера

final class QuickPanelFooterView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        (effectiveAppearance.isDark
            ? NSColor.white.withAlphaComponent(0.03)
            : NSColor.black.withAlphaComponent(0.02)).setFill()
        bounds.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Строка с hover-действиями

final class QuickPanelHoverRow: NSView {
    var hoverViews: [NSView] = [] {
        didSet { hoverViews.forEach { $0.isHidden = true } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        hoverViews.forEach { $0.isHidden = false }
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = nil
        hoverViews.forEach { $0.isHidden = true }
    }
}
