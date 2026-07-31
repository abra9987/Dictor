import AppKit

// Онбординг: четыре шага, которые ведут от «что это» до первой удачной
// диктовки. Живёт в главном окне (см. OnboardingPage.swift и
// OnboardingSteps.swift); здесь — только состояние и правила переходов.
//
// 1 приветствие → 2 права macOS (выдаются по очереди) → 3 загрузка модели
// → 4 «попробуйте прямо здесь». Шаги переключаются сами по реальному
// состоянию: права выданы → модель готова → первая диктовка попала в историю.

enum OnboardingStep: Int, CaseIterable {
    case welcome
    case permissions
    case model
    case practice
}

/// Снимок мира для рендера шага. В приложении собирается из
/// Permissions/AgentRuntimeStateStore/Settings; в превью — задаётся руками.
struct OnboardingSnapshot {
    var granted: Set<Permission>
    var modelReady: Bool
    var downloadFraction: Double?
    var hotkeyCaps: [String]
    var dictatedText: String?
    var practiceDone: Bool
    var language: InterfaceLanguage
}

@MainActor
final class OnboardingFlow {
    private(set) var step: OnboardingStep
    private let settings = Settings.shared
    private let historyBaseline: Int

    private init(step: OnboardingStep, historyBaseline: Int) {
        self.step = step
        self.historyBaseline = historyBaseline
    }

    /// Возвращает поток, если онбординг нужно показать, иначе nil.
    static func makeIfNeeded(force: Bool) -> OnboardingFlow? {
        let settings = Settings.shared
        let granted = Set(Permission.allCases.filter { Permissions.isGranted($0) })
        let permissionsMissing = granted.count < Permission.allCases.count
        let modelReady = AgentRuntimeStateStore.read()?.speechModelReady ?? false
        log("onboarding check: force=\(force) completed=\(settings.onboardingCompleted) " +
            "granted=\(granted.count)/\(Permission.allCases.count) " +
            "modelReady=\(modelReady) entries=\(settings.recentTranscriptEntries.count)")

        // Онбординг нельзя «пройти навсегда». Если разрешений нет, приложение
        // не работает вообще, и человек остаётся наедине с молчащим хоткеем —
        // так было после переустановки, когда macOS сбросил TCC из-за смены
        // подписи. В этом случае возвращаемся независимо от флага.
        guard force || !settings.onboardingCompleted || permissionsMissing else {
            log("onboarding: skipped (already completed, nothing missing)")
            return nil
        }
        if !force && !permissionsMissing && modelReady
            && !settings.recentTranscriptEntries.isEmpty {
            // Всё уже настроено (обновление с прошлой версии) — не мешаем.
            log("onboarding: marked complete without showing (everything already set up)")
            settings.onboardingCompleted = true
            return nil
        }

        let step: OnboardingStep
        if force {
            step = .welcome
        } else if settings.onboardingCompleted && permissionsMissing {
            // Возвращающийся человек уже знает, что это за приложение —
            // ведём сразу к разрешениям, а не к приветствию.
            step = .permissions
        } else if permissionsMissing {
            step = .welcome
        } else if !modelReady {
            step = .model
        } else {
            step = .practice
        }
        log("onboarding: presenting at step \(step)")
        return OnboardingFlow(step: step, historyBaseline: settings.recentTranscriptEntries.count)
    }

    func currentSnapshot() -> OnboardingSnapshot {
        let runtime = AgentRuntimeStateStore.read()
        let entries = settings.recentTranscriptEntries
        let practiced = entries.count > historyBaseline
        return OnboardingSnapshot(
            granted: Set(Permission.allCases.filter { Permissions.isGranted($0) }),
            modelReady: runtime?.speechModelReady ?? false,
            downloadFraction: runtime?.downloadProgressFraction,
            hotkeyCaps: keycapLabels(for: settings.configuredHotkey,
                                     language: settings.interfaceLanguage),
            dictatedText: practiced ? entries.first?.text : nil,
            practiceDone: practiced,
            language: settings.interfaceLanguage
        )
    }

    /// Автопереходы по реальному состоянию. Назад шаги не едут: увидев
    /// «выдано», человек не должен через секунду увидеть снова «разрешите».
    func advance(with snapshot: OnboardingSnapshot) {
        switch step {
        case .welcome:
            break
        case .permissions:
            if snapshot.granted.count == Permission.allCases.count {
                step = snapshot.modelReady ? .practice : .model
            }
        case .model:
            if snapshot.modelReady { step = .practice }
        case .practice:
            break
        }
    }

    /// Кнопка «Настроить за минуту» на первом шаге.
    func start(with snapshot: OnboardingSnapshot) {
        guard step == .welcome else { return }
        if snapshot.granted.count < Permission.allCases.count {
            step = .permissions
        } else if !snapshot.modelReady {
            step = .model
        } else {
            step = .practice
        }
    }
}

// MARK: - Экспорт превью

@MainActor
func exportOnboardingPreviews(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let size = MAIN_WINDOW_SIZE
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
    window.colorSpace = .sRGB

    var exported = 0
    for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua),
                                     ("dark", NSAppearance.Name.darkAqua)] {
        window.appearance = NSAppearance(named: appearanceName)
        for step in OnboardingStep.allCases {
            let page = OnboardingPageView(language: .russian, actions: nil)
            window.contentView = page
            page.apply(step: step, snapshot: previewSnapshot(for: step))
            window.layoutIfNeeded()

            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                continue
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let name = "onboarding-\(step.rawValue + 1)-\(suffix).png"
            try data.write(to: directory.appendingPathComponent(name))
            exported += 1
        }
    }
    window.contentView = nil
    log("onboarding previews exported: \(exported) → \(directory.path)")
}

@MainActor
private func previewSnapshot(for step: OnboardingStep) -> OnboardingSnapshot {
    let caps = keycapLabels(for: Settings.shared.configuredHotkey, language: .russian)
    switch step {
    case .welcome:
        return OnboardingSnapshot(granted: [], modelReady: false, downloadFraction: nil,
                                  hotkeyCaps: caps, dictatedText: nil, practiceDone: false,
                                  language: .russian)
    case .permissions:
        return OnboardingSnapshot(granted: [.microphone], modelReady: false,
                                  downloadFraction: nil, hotkeyCaps: caps,
                                  dictatedText: nil, practiceDone: false, language: .russian)
    case .model:
        return OnboardingSnapshot(granted: Set(Permission.allCases), modelReady: false,
                                  downloadFraction: 0.64, hotkeyCaps: caps,
                                  dictatedText: nil, practiceDone: false, language: .russian)
    case .practice:
        return OnboardingSnapshot(granted: Set(Permission.allCases), modelReady: true,
                                  downloadFraction: 1, hotkeyCaps: caps,
                                  dictatedText: "Проверка связи, кажется, всё работает как надо.",
                                  practiceDone: true, language: .russian)
    }
}
