import AudioToolbox
import CoreAudio
import Foundation

// MARK: - Ни одного микрофона
//
// У Mac mini своего микрофона нет. Стоит отключить камеру или убрать наушники
// в кейс — и CoreAudio отдаёт движку пустышку «44,1 кГц, 2 канала», запуск
// падает с -10868, а человек видел «Служба не запустилась» и совет
// перезапустить coreaudiod. Совет уводил в сторону: перезагрузка не вставит
// камеру обратно. Здесь — всё, что превращает этот случай в «Нет микрофона»
// и возвращает диктовку, как только микрофон появится.

/// Значение `AgentRuntimeState.failureReason`: окно — отдельный процесс и
/// узнаёт причину сбоя только отсюда. Статус при этом остаётся `"error"`,
/// чтобы окно прошлой версии с новой службой показало обычную ошибку, а не
/// застряло в «запускается».
let AGENT_FAILURE_REASON_NO_MICROPHONE = "no_microphone"

/// Сколько ждать после смены списка устройств. Bluetooth-наушники попадают в
/// список раньше, чем готовы отдавать звук, — запуск сразу же снова упал бы.
let AUDIO_INPUT_DEVICES_SETTLE_SECONDS: TimeInterval = 1.5

/// Классифицируем после неудачной попытки, а не воротами перед ней: пустой
/// список бывает и при сбое самого запроса к CoreAudio, и такой сбой не
/// должен мешать запуску, который мог бы пройти.
func isMissingAudioInputFailure(stage: StartupFailureStage,
                                inputDevices: [AudioInputDevice]) -> Bool {
    stage == .audioInput && inputDevices.isEmpty
}

/// Повторы запуска звука ждут, что CoreAudio одумается. Без устройства ждать
/// нечего — четыре попытки за 13 секунд только откладывали понятный ответ.
func shouldRetryAudioStartup(inputDevices: [AudioInputDevice]) -> Bool {
    !inputDevices.isEmpty
}

/// Подробность для меню, чек-листа и диагностики — по-английски, как и
/// остальные протокольные строки сбоя. Человеку окно показывает перевод из
/// `serviceStatusPresentation(.noMicrophone)`.
let NO_MICROPHONE_FAILURE_DETAIL = """
No microphone is connected to this Mac. Connect a microphone, a headset or a \
webcam with a microphone — Dictor starts audio input on its own as soon as one appears.
"""

/// Капсула при нажатии клавиши, когда служба готова, а микрофон пропал уже
/// после запуска: наушники убрали в кейс. Раньше был только звук ошибки.
func noMicrophoneDictationMessage(language: InterfaceLanguage) -> String {
    localizedText("Нет микрофона — подключите его или наушники",
                  "No microphone — connect one or a headset",
                  language: language)
}

/// Как окно читает состояние `"error"` из файла службы.
func serviceStatusForErrorState(failureReason: String?) -> ServiceStatusKind {
    failureReason == AGENT_FAILURE_REASON_NO_MICROPHONE ? .noMicrophone : .failed
}

/// Перезапускать ли службу после смены списка устройств. Только из сбоя
/// «нет микрофона»: остальные сбои от нового устройства не лечатся, а
/// перезапуск поверх идущего запуска оборвал бы его.
func shouldRestartAfterInputDevicesChanged(failureIsMissingInput: Bool,
                                           hasStartupTask: Bool,
                                           isTerminating: Bool,
                                           inputDevices: [AudioInputDevice]) -> Bool {
    failureIsMissingInput && !hasStartupTask && !isTerminating && !inputDevices.isEmpty
}

/// Строка для диагностики: какие входы видит CoreAudio прямо сейчас. В отчёте
/// папы её не хватило — «нет ни одного входа» пришлось выяснять по SSH.
func inputDevicesDiagnosticsLine(_ devices: [AudioInputDevice]) -> String {
    devices.isEmpty
        ? "- Input devices: none"
        : "- Input devices: " + devices.map(\.name).joined(separator: ", ")
}

/// Следит за списком аудиоустройств и сообщает о смене один раз, когда
/// список успокоился. Колбэк — на главном потоке.
final class AudioInputDeviceWatcher {
    private let onChange: () -> Void
    private var listener: AudioObjectPropertyListenerBlock?
    private var pending: DispatchWorkItem?
    private var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> Bool {
        guard listener == nil else { return true }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                         &address, DispatchQueue.main, block)
        guard status == noErr else {
            log("AudioInputDeviceWatcher: listener install failed (OSStatus \(status))")
            return false
        }
        listener = block
        return true
    }

    func stop() {
        pending?.cancel()
        pending = nil
        guard let listener else { return }
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, DispatchQueue.main, listener)
        self.listener = nil
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.pending = nil
            self?.onChange()
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + AUDIO_INPUT_DEVICES_SETTLE_SECONDS,
                                      execute: item)
    }
}

// MARK: - Самотест

// Самотесты собираются только в отладочной сборке — как и весь SelfTests.swift.
#if DEBUG
extension DictorSelfTest {
    /// Цепочка целиком: пустой список входов → без повторов → сбой с
    /// причиной → файл службы → окно и панель → человеческий заголовок.
    /// Достижимость — через те же функции, что зовут служба и окно.
    static func testMissingMicrophone() throws {
        let microphone = AudioInputDevice(id: 42, uid: "probe-mic", name: "AirPods")

        // Классификация и повторы.
        try expect(isMissingAudioInputFailure(stage: .audioInput, inputDevices: []), equals: true,
                   "an audio failure with no inputs at all is the no-microphone case")
        try expect(isMissingAudioInputFailure(stage: .audioInput, inputDevices: [microphone]),
                   equals: false,
                   "with a microphone present the failure is CoreAudio's, not a missing device")
        try expect(isMissingAudioInputFailure(stage: .speechModel, inputDevices: []), equals: false,
                   "a speech model failure is never blamed on the microphone")
        try expect(shouldRetryAudioStartup(inputDevices: []), equals: false,
                   "retrying without any input only delays the answer")
        try expect(shouldRetryAudioStartup(inputDevices: [microphone]), equals: true,
                   "a present device keeps the CoreAudio retries")

        // Автозапуск при подключении.
        try expect(shouldRestartAfterInputDevicesChanged(failureIsMissingInput: true,
                                                         hasStartupTask: false,
                                                         isTerminating: false,
                                                         inputDevices: [microphone]),
                   equals: true, "a connected microphone must restart the service on its own")
        try expect(shouldRestartAfterInputDevicesChanged(failureIsMissingInput: true,
                                                         hasStartupTask: false,
                                                         isTerminating: false,
                                                         inputDevices: []),
                   equals: false, "a device list that is still empty must not restart anything")
        try expect(shouldRestartAfterInputDevicesChanged(failureIsMissingInput: false,
                                                         hasStartupTask: false,
                                                         isTerminating: false,
                                                         inputDevices: [microphone]),
                   equals: false, "other failures are not cured by a new device")
        try expect(shouldRestartAfterInputDevicesChanged(failureIsMissingInput: true,
                                                         hasStartupTask: true,
                                                         isTerminating: false,
                                                         inputDevices: [microphone]),
                   equals: false, "a restart on top of a running startup would cut it short")

        // Слушатель устройств действительно встаёт в CoreAudio — иначе
        // автозапуск был бы написан и недостижим.
        let watcher = AudioInputDeviceWatcher {}
        try expect(watcher.start(), equals: true,
                   "the device-list listener must install in CoreAudio")
        watcher.stop()

        // Через файл службы до окна. Окно прошлой версии поле не знает, а
        // окно этой версии обязано понимать файл прошлой службы.
        var state = AgentRuntimeState(status: "error", detail: NO_MICROPHONE_FAILURE_DETAIL,
                                      updatedAt: 0, pid: 1, isReady: false, isRecording: false,
                                      isTranscribing: false, speechModelReady: true,
                                      missingPermissions: [], hotkeyName: "", triggerMode: "")
        state.failureReason = AGENT_FAILURE_REASON_NO_MICROPHONE
        let decoded = try JSONDecoder().decode(AgentRuntimeState.self,
                                               from: JSONEncoder().encode(state))
        try expect(serviceStatusForErrorState(failureReason: decoded.failureReason),
                   equals: .noMicrophone,
                   "the window must read «no microphone» from the service state file")
        try expect(serviceStatusForErrorState(failureReason: nil), equals: .failed,
                   "an error without a known reason stays the generic failure")
        let legacyJSON = Data("""
        {"status":"error","detail":"x","updatedAt":0,"pid":1,"isReady":false,
         "isRecording":false,"isTranscribing":false,"speechModelReady":true,
         "missingPermissions":[],"hotkeyName":"","triggerMode":""}
        """.utf8)
        let legacy = try JSONDecoder().decode(AgentRuntimeState.self, from: legacyJSON)
        try expect(legacy.failureReason, equals: nil,
                   "a state file from the previous service must still decode")

        // До человека: свой заголовок, без «Запустить», не «идёт работа».
        let russian = serviceStatusPresentation(.noMicrophone, language: .russian)
        try expect(russian.title, equals: "Нет микрофона",
                   "the window must name the cause instead of «the service didn't start»")
        try expect(russian.primaryAction, equals: nil,
                   "«Start» does not cure a missing device — connecting one does")
        try expect(serviceStatusPresentation(.noMicrophone, language: .english).title,
                   equals: "No microphone", "the English interface names the cause too")
        try expect(ServiceStatusKind.noMicrophone.isBusy, equals: false,
                   "waiting for a microphone is not work in progress")

        // Меню и чек-лист настройки показывают ту же причину, а совет про
        // coreaudiod остаётся только для сбоя с живым устройством.
        let failure = StartupFailure(stage: .audioInput, detail: NO_MICROPHONE_FAILURE_DETAIL,
                                     isMissingAudioInput: true)
        let row = audioInputSetupRowState(isSpeechModelReady: true, isCoreRuntimeReady: false,
                                          isStartupInProgress: false, failure: failure)
        try expect(row.detail.contains("No microphone"), equals: true,
                   "the setup checklist must name the missing microphone")
        try expect(row.detail.contains("coreaudiod"), equals: false,
                   "no coreaudiod advice when there is simply no microphone")

        // Капсула при нажатии клавиши, когда микрофон пропал после запуска.
        try expect(noMicrophoneDictationMessage(language: .russian).hasPrefix("Нет микрофона"),
                   equals: true, "the hotkey press must say why nothing records")

        // Отчёт о проблеме: причина видна в теле письма и в диагностике.
        try expect(ProblemReport.serviceLine(state: decoded).contains(AGENT_FAILURE_REASON_NO_MICROPHONE),
                   equals: true, "the report e-mail must carry the failure reason")
        try expect(ProblemReport.serviceLine(state: nil), equals: "Service: not running",
                   "a report without a service says so")
        try expect(inputDevicesDiagnosticsLine([]), equals: "- Input devices: none",
                   "diagnostics must say plainly that there are no inputs")
        try expect(inputDevicesDiagnosticsLine([microphone]), equals: "- Input devices: AirPods",
                   "diagnostics list the inputs by name")
    }
}
#endif
