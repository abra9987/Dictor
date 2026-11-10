import AppKit
import ApplicationServices

// MARK: - Поле ввода в программах на Electron
//
// Electron строит дерево универсального доступа, только когда его попросят:
// VoiceOver включён или кто-то выставил программе `AXManualAccessibility`.
// Без этого программа не называет системе элемент с фокусом
// (`kAXErrorNoValue`, −25212), и Dictor не видит, куда вставляет: умная
// вставка молчит, капсула не встаёт у курсора. Так было с Claude для Mac —
// в журнале владельца 406 диктовок из 470 «position unknown».
//
// Флаг меняет поведение чужой программы: дерево стоит ей памяти и времени.
// Поэтому он ставится только программам из списка, на который владелец дал
// согласие (9 ноября 2026), и один раз на процесс — флаг живёт, пока
// программа не перезапущена. Замер на Claude: разница в пределах шума
// (~1,3 ГБ на все процессы до и после).

enum ElectronAccessibility {
    /// Программы, которым Dictor включает дерево доступности. Пополнять
    /// только с согласия владельца — см. комментарий выше.
    static let bundleIdentifiers: Set<String> = [
        "com.anthropic.claudefordesktop",
    ]

    /// Процессы, которым флаг уже выставлен.
    private final class EnabledProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<pid_t> = []
        func contains(_ pid: pid_t) -> Bool { lock.withLock { pids.contains(pid) } }
        func insert(_ pid: pid_t) { _ = lock.withLock { pids.insert(pid) } }
    }
    private static let enabled = EnabledProcesses()

    static func needsManualAccessibility(bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(bundleIdentifier)
    }

    /// Вызывается при нажатии клавиши диктовки. Не ждёт ответа: зависшая
    /// программа не должна задерживать начало записи.
    static func enableIfNeeded(pid: pid_t, bundleIdentifier: String) {
        guard needsManualAccessibility(bundleIdentifier: bundleIdentifier) else { return }
        guard !enabled.contains(pid) else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            guard AXIsProcessTrusted() else { return }
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.1)
            let error = AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString,
                                                     kCFBooleanTrue)
            if error == .success {
                enabled.insert(pid)
                log("accessibility tree enabled for \(bundleIdentifier) (pid \(pid))")
            } else {
                log("accessibility tree not enabled for \(bundleIdentifier): AXError \(error.rawValue)")
            }
        }
    }
}
