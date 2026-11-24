import CryptoKit
import Foundation

// MARK: - Скачивание архива обновления
//
// До 1.11.3 архив качался одним `session.data(for:)` с таймаутом 60 секунд на
// весь ресурс. Из Уфы канал до сервера обновлений режет провайдер: манифест в
// 800 байт приходит за доли секунды, а 4 МБ архива не докачиваются и за две
// минуты. Обновление висело на «скачиваю…», а сбой не попадал в журнал —
// в отчёте о проблеме после «installing» не было ничего.
//
// Поэтому здесь:
// - обрыв — это тишина, а не медленность. Пока байты идут, ждём сколько
//   угодно; если `stallTimeout` секунд не пришло ни байта, соединение рвём сами;
// - после обрыва докачиваем с того же места (Range + If-Range по ETag), а не
//   начинаем заново: на плохом канале каждый новый заход с нуля снова упрётся
//   в ту же стену;
// - сдаёмся только после нескольких попыток подряд, не принёсших ни байта.
//   Попытка, которая что-то докачала, счётчик обнуляет;
// - каждый обрыв и итог пишутся в журнал, а прогресс в байтах виден в окне.
//
// От блокировки сервера провайдером это не спасает — спасает от того, что
// человек не понимает, что происходит. Текст ошибки прямо говорит, что делать.

/// Сколько архива уже на руках. `attempt` больше единицы — идёт докачка после
/// обрыва, и окно говорит об этом, а не делает вид, что всё гладко.
struct UpdateDownloadProgress: Sendable, Equatable {
    let received: Int64
    let total: Int64?
    let attempt: Int
}

struct UpdateDownloadPolicy: Sendable {
    /// Сколько секунд без единого байта считается обрывом.
    var stallTimeout: TimeInterval
    /// Сколько попыток подряд без единого нового байта — и сдаёмся.
    var maxFruitlessAttempts: Int
    /// Пауза перед повтором по номеру неудачи подряд; последняя повторяется.
    var retryDelays: [TimeInterval]
    var maxBytes: Int

    static let standard = UpdateDownloadPolicy(stallTimeout: 30,
                                               maxFruitlessAttempts: 4,
                                               retryDelays: [2, 5, 10],
                                               maxBytes: UPDATE_ARCHIVE_MAX_BYTES)

    func delay(afterFruitless count: Int) -> TimeInterval {
        guard let last = retryDelays.last else { return 0 }
        let index = max(0, count - 1)
        return index < retryDelays.count ? retryDelays[index] : last
    }
}

/// Строка хода скачивания — одна на окно обновления и строку «Версия» в
/// настройках, чтобы два пути установки не рассказывали разное.
func updateDownloadPhaseText(_ progress: UpdateDownloadProgress,
                             language: InterfaceLanguage,
                             capitalized: Bool) -> String {
    func megabytes(_ bytes: Int64) -> String {
        let value = String(format: "%.1f", Double(bytes) / 1_000_000)
        return language == .russian ? value.replacingOccurrences(of: ".", with: ",") : value
    }
    let amount: String
    if let total = progress.total, total > 0 {
        amount = localizedText("\(megabytes(progress.received)) из \(megabytes(total)) МБ",
                               "\(megabytes(progress.received)) of \(megabytes(total)) MB",
                               language: language)
    } else {
        amount = localizedText("\(megabytes(progress.received)) МБ",
                               "\(megabytes(progress.received)) MB",
                               language: language)
    }
    let verb = progress.attempt > 1
        ? localizedText("связь прерывалась, докачиваю", "the connection dropped, resuming",
                        language: language)
        : localizedText("скачиваю", "downloading", language: language)
    let text = "\(verb): \(amount)"
    guard capitalized, let first = text.first else { return text }
    return first.uppercased() + text.dropFirst()
}

enum UpdateArchiveDownloader {
    static func download(from url: URL,
                         userAgent: String,
                         policy: UpdateDownloadPolicy = .standard,
                         configuration: URLSessionConfiguration? = nil,
                         progress: @escaping @Sendable (UpdateDownloadProgress) -> Void)
        async throws -> Data {
        let startedAt = Date()
        var buffer = Data()
        var validator: String?
        var total: Int64?
        var attempt = 0
        var fruitless = 0
        // Успехом попытки считается новый рекорд, а не просто непустое тело:
        // сервер без докачки, рвущий соединение на одном и том же мегабайте,
        // иначе гонял бы нас по кругу вечно.
        var best = 0

        while true {
            try Task.checkCancellation()
            attempt += 1
            var request = URLRequest(url: url)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            // Без валидатора докачка могла бы склеить два разных файла: сервер
            // подменил архив между попытками. SHA-256 это поймал бы, но лучше
            // честно начать заново.
            if !buffer.isEmpty, let validator {
                request.setValue("bytes=\(buffer.count)-", forHTTPHeaderField: "Range")
                request.setValue(validator, forHTTPHeaderField: "If-Range")
            } else {
                buffer.removeAll(keepingCapacity: true)
            }
            if attempt > 1 {
                progress(UpdateDownloadProgress(received: Int64(buffer.count),
                                                total: total, attempt: attempt))
            }

            let result = await UpdateDownloadAttempt.run(request: request,
                                                         resumeFrom: buffer.count,
                                                         knownTotal: total,
                                                         attempt: attempt,
                                                         policy: policy,
                                                         configuration: configuration,
                                                         progress: progress)
            try Task.checkCancellation()

            if result.restartedFromZero { buffer.removeAll(keepingCapacity: true) }
            buffer.append(result.body)
            if let newTotal = result.total { total = newTotal }
            if let newValidator = result.validator { validator = newValidator }

            switch result.outcome {
            case .finished:
                if let total, Int64(buffer.count) != total {
                    // Сервер закрыл соединение раньше обещанного — это тот же
                    // обрыв, только без ошибки.
                    break
                }
                log("update: archive downloaded, \(buffer.count) bytes in \(attempt) attempt(s), "
                    + String(format: "%.1f s", Date().timeIntervalSince(startedAt)))
                return buffer
            case .httpStatus(let code):
                log("update: archive request answered HTTP \(code)")
                throw DictorUpdateInstallerError.httpStatus(code)
            case .tooLarge:
                log("update: archive exceeds \(policy.maxBytes) bytes, download stopped")
                throw DictorUpdateInstallerError.archiveTooLarge
            case .interrupted:
                break
            }

            if buffer.count > best {
                best = buffer.count
                fruitless = 0
            } else {
                fruitless += 1
            }
            let reason = result.stalled
                ? "no data for \(String(format: "%g", policy.stallTimeout)) s"
                : (result.errorDescription ?? "connection closed early")
            if fruitless >= policy.maxFruitlessAttempts {
                log("update: download gave up after \(attempt) attempt(s) at "
                    + "\(buffer.count)/\(total.map(String.init) ?? "?") bytes: \(reason)")
                if buffer.isEmpty && total == nil {
                    throw DictorUpdateInstallerError.network
                }
                throw DictorUpdateInstallerError.downloadInterrupted(received: Int64(buffer.count),
                                                                     total: total)
            }
            let delay = policy.delay(afterFruitless: max(1, fruitless))
            log("update: download interrupted at \(buffer.count)/\(total.map(String.init) ?? "?") "
                + "bytes (\(reason)), retry \(attempt + 1) in \(String(format: "%.0f", delay)) s")
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }
}

/// Одна попытка: один запрос, тело копится в памяти, сторож тишины рвёт
/// соединение. Всё изменяемое состояние трогается только на `queue` —
/// делегатной очереди сессии, отсюда `@unchecked Sendable`.
private final class UpdateDownloadAttempt: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    enum Outcome { case finished, interrupted, httpStatus(Int), tooLarge }

    struct Result {
        var outcome: Outcome
        var body: Data
        /// Сервер ответил 200 на запрос докачки — тело начинается с нуля.
        var restartedFromZero: Bool
        var total: Int64?
        var validator: String?
        var stalled: Bool
        var errorDescription: String?
    }

    private let queue = DispatchQueue(label: "DictorUpdateDownload")
    private let resumeFrom: Int
    private let attempt: Int
    private let policy: UpdateDownloadPolicy
    private let progress: @Sendable (UpdateDownloadProgress) -> Void
    private var result: Result
    private var base = 0
    private var lastActivity = Date()
    private var watchdog: DispatchSourceTimer?
    private var stopReason: Outcome?
    private var continuation: CheckedContinuation<Result, Never>?
    private var task: URLSessionDataTask?
    private var cancelled = false

    private init(resumeFrom: Int, knownTotal: Int64?, attempt: Int, policy: UpdateDownloadPolicy,
                 progress: @escaping @Sendable (UpdateDownloadProgress) -> Void) {
        self.resumeFrom = resumeFrom
        self.attempt = attempt
        self.policy = policy
        self.progress = progress
        self.result = Result(outcome: .interrupted, body: Data(), restartedFromZero: false,
                             total: knownTotal, validator: nil, stalled: false,
                             errorDescription: nil)
    }

    static func run(request: URLRequest,
                    resumeFrom: Int,
                    knownTotal: Int64?,
                    attempt: Int,
                    policy: UpdateDownloadPolicy,
                    configuration: URLSessionConfiguration?,
                    progress: @escaping @Sendable (UpdateDownloadProgress) -> Void) async -> Result {
        let worker = UpdateDownloadAttempt(resumeFrom: resumeFrom, knownTotal: knownTotal,
                                           attempt: attempt, policy: policy, progress: progress)
        let config = (configuration?.copy() as? URLSessionConfiguration) ?? .ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        // Свой сторож точнее, но и системный таймаут бездействия пусть совпадает:
        // он же покрывает установку соединения.
        config.timeoutIntervalForRequest = policy.stallTimeout
        // Общего срока нет: медленный, но живой канал докачает сколько бы ни шло.
        config.timeoutIntervalForResource = 24 * 3600
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = worker.queue
        let session = URLSession(configuration: config, delegate: worker,
                                 delegateQueue: delegateQueue)
        defer { session.finishTasksAndInvalidate() }

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result, Never>) in
                worker.queue.async {
                    worker.continuation = continuation
                    let task = session.dataTask(with: request)
                    worker.task = task
                    worker.startWatchdog()
                    task.resume()
                    // Отмена могла прийти раньше, чем появилась задача.
                    if worker.cancelled { task.cancel() }
                }
            }
        } onCancel: {
            worker.queue.async {
                worker.cancelled = true
                worker.task?.cancel()
            }
        }
    }

    private func startWatchdog() {
        lastActivity = Date()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let tick = max(0.05, min(1, policy.stallTimeout / 4))
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self, self.stopReason == nil else { return }
            if Date().timeIntervalSince(self.lastActivity) >= self.policy.stallTimeout {
                self.result.stalled = true
                self.stopReason = .interrupted
                self.task?.cancel()
            }
        }
        watchdog = timer
        timer.resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lastActivity = Date()
        guard let http = response as? HTTPURLResponse else {
            stopReason = .interrupted
            completionHandler(.cancel)
            return
        }
        let header = { (name: String) in http.value(forHTTPHeaderField: name) }
        result.validator = header("ETag") ?? header("Last-Modified")

        switch http.statusCode {
        case 206:
            // «bytes 120000-299999/300000»: начало обязано совпасть с тем, что
            // уже есть, иначе склеится не тот кусок.
            guard let range = header("Content-Range"),
                  let parsed = parseContentRange(range),
                  parsed.start == Int64(resumeFrom) else {
                result.restartedFromZero = true
                stopReason = .interrupted
                completionHandler(.cancel)
                return
            }
            base = resumeFrom
            result.total = parsed.total ?? result.total
        case 200..<300:
            base = 0
            result.restartedFromZero = resumeFrom > 0
            result.total = http.expectedContentLength > 0 ? http.expectedContentLength : nil
        case 416:
            // Сервер не узнал диапазон — файл другой. Следующая попытка с нуля.
            result.restartedFromZero = true
            stopReason = .interrupted
            completionHandler(.cancel)
            return
        default:
            stopReason = .httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        if let total = result.total, total > Int64(policy.maxBytes) {
            stopReason = .tooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lastActivity = Date()
        result.body.append(data)
        let received = base + result.body.count
        if received > policy.maxBytes {
            stopReason = .tooLarge
            dataTask.cancel()
            return
        }
        progress(UpdateDownloadProgress(received: Int64(received), total: result.total,
                                        attempt: attempt))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        watchdog?.cancel()
        watchdog = nil
        if let stopReason {
            result.outcome = stopReason
        } else if let error {
            result.outcome = .interrupted
            result.errorDescription = (error as? URLError).map { "URLError \($0.code.rawValue)" }
                ?? error.localizedDescription
        } else {
            result.outcome = .finished
        }
        if case .tooLarge = result.outcome { result.body = Data() }
        continuation?.resume(returning: result)
        continuation = nil
    }
}

/// «bytes 120000-299999/300000» → начало и полный размер («*» — неизвестен).
private func parseContentRange(_ value: String) -> (start: Int64, total: Int64?)? {
    let trimmed = value.trimmingCharacters(in: .whitespaces)
    guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
    let spec = trimmed.dropFirst("bytes ".count)
    let parts = spec.split(separator: "/", maxSplits: 1)
    guard parts.count == 2,
          let dash = parts[0].firstIndex(of: "-"),
          let start = Int64(parts[0][..<dash]) else { return nil }
    return (start, Int64(parts[1]))
}

// MARK: - Самотест

// Самотесты собираются только в отладочной сборке — как и весь SelfTests.swift.
#if DEBUG
/// Заглушка сервера обновлений: каждый запрос берёт следующий ответ из
/// сценария. Подставляется в конфигурацию сессии, так что загрузчик идёт
/// своим обычным путём, а в сеть не уходит ни байта.
final class UpdateDownloadStubProtocol: URLProtocol, @unchecked Sendable {
    enum Ending { case finish, drop, stall }
    struct Reply {
        var status = 200
        var honorRange = true
        /// Сколько байт тела отдать до `ending`; nil — всё.
        var bytes: Int?
        var ending = Ending.finish
        /// Отказ ещё до ответа: соединение не установилось.
        var refuse = false
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var payload = Data()
    nonisolated(unsafe) private static var script: [Reply] = []
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func install(payload: Data, script: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        self.payload = payload
        self.script = script
        requests = []
    }

    static var seenRequests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let reply = Self.script.isEmpty ? Reply(refuse: true) : Self.script.removeFirst()
        let payload = Self.payload
        Self.lock.unlock()

        if reply.refuse {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var start = 0
        if reply.honorRange,
           let range = request.value(forHTTPHeaderField: "Range"),
           range.hasPrefix("bytes="), range.hasSuffix("-"),
           let from = Int(range.dropFirst("bytes=".count).dropLast()) {
            start = from
        }
        let status = reply.status == 200 && start > 0 ? 206 : reply.status
        var headers = ["ETag": "\"stub\"", "Content-Length": "\(payload.count - start)"]
        if status == 206 {
            headers["Content-Range"] = "bytes \(start)-\(payload.count - 1)/\(payload.count)"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        guard (200..<300).contains(status) else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let end = min(payload.count, start + (reply.bytes ?? payload.count))
        var offset = start
        while offset < end {
            let next = min(end, offset + 32 * 1024)
            client?.urlProtocol(self, didLoad: payload.subdata(in: offset..<next))
            offset = next
        }
        switch reply.ending {
        case .finish: client?.urlProtocolDidFinishLoading(self)
        case .drop:
            // Обрыв — чуть позже данных: система доставляет их делегату не
            // мгновенно, а мгновенная ошибка выбросила бы ещё не доставленное.
            // В живой сети между последним пакетом и обрывом тоже проходит время.
            let client = client
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            }
        case .stall: break  // молчим, пока загрузчик сам не оборвёт
        }
    }

    override func stopLoading() {}
}

private final class UpdateDownloadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [UpdateDownloadProgress] = []
    var outcome: Result<Data, Error>?

    func record(_ progress: UpdateDownloadProgress) {
        lock.lock(); events.append(progress); lock.unlock()
    }

    var progress: [UpdateDownloadProgress] {
        lock.lock(); defer { lock.unlock() }
        return events
    }
}

extension DictorSelfTest {
    /// Загрузчик архива против заглушки, которая ведёт себя как плохой канал:
    /// рвёт, замолкает, не умеет докачку, отвечает ошибкой. Достижимость —
    /// через `downloadVerifiedArchive`, ту же функцию, что зовёт `prepare`.
    static func testUpdateDownload() throws {
        let payload = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let manifest = DictorUpdateManifest(version: "9.8.7", sha256: digest)
        let quick = UpdateDownloadPolicy(stallTimeout: 0.3, maxFruitlessAttempts: 3,
                                         retryDelays: [0.01], maxBytes: UPDATE_ARCHIVE_MAX_BYTES)
        typealias Reply = UpdateDownloadStubProtocol.Reply

        func run(_ script: [Reply],
                 manifest: DictorUpdateManifest = manifest,
                 policy: UpdateDownloadPolicy = quick) throws -> UpdateDownloadProbe {
            UpdateDownloadStubProtocol.install(payload: payload, script: script)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [UpdateDownloadStubProtocol.self]
            let probe = UpdateDownloadProbe()
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let data = try await DictorUpdateInstaller.downloadVerifiedArchive(
                        manifest: manifest, policy: policy, configuration: configuration,
                        progress: { probe.record($0) })
                    probe.outcome = .success(data)
                } catch {
                    probe.outcome = .failure(error)
                }
                done.signal()
            }
            guard done.wait(timeout: .now() + 15) == .success else {
                throw SelfTestFailure.failed("update download never returned")
            }
            return probe
        }

        func expectError(_ probe: UpdateDownloadProbe,
                         _ expected: DictorUpdateInstallerError, _ message: String) throws {
            guard case .failure(let error)? = probe.outcome else {
                throw SelfTestFailure.failed("\(message): the download succeeded")
            }
            try expect(error as? DictorUpdateInstallerError, equals: expected, message)
        }

        func expectPayload(_ probe: UpdateDownloadProbe, _ message: String) throws {
            guard case .success(let data)? = probe.outcome else {
                throw SelfTestFailure.failed("\(message): \(String(describing: probe.outcome))")
            }
            try expect(data == payload, equals: true, message)
        }

        // Обрыв посреди архива: вторая попытка просит ровно недостающее.
        let dropped = try run([Reply(bytes: 120_000, ending: .drop), Reply()])
        try expectPayload(dropped, "a dropped download must resume to the full archive")
        let resumed = UpdateDownloadStubProtocol.seenRequests
        try expect(resumed.count, equals: 2, "one drop costs exactly one more request")
        try expect(resumed.last?.value(forHTTPHeaderField: "Range"), equals: "bytes=120000-",
                   "the retry must ask only for the missing bytes")
        try expect(resumed.last?.value(forHTTPHeaderField: "If-Range"), equals: "\"stub\"",
                   "the retry must pin the same file by its ETag")
        try expect(dropped.progress.last,
                   equals: UpdateDownloadProgress(received: 300_000, total: 300_000, attempt: 2),
                   "progress must end at the full size and admit it was a resumed attempt")
        let received = dropped.progress.map(\.received)
        try expect(received == received.sorted(), equals: true,
                   "progress must never go backwards after a resume")

        // Тишина: сервер отдал кусок и замолчал — рвём сами и докачиваем.
        let startedAt = Date()
        let stalled = try run([Reply(bytes: 50_000, ending: .stall), Reply()])
        try expectPayload(stalled, "a stalled download must be cut and resumed")
        try expect(Date().timeIntervalSince(startedAt) >= 0.3, equals: true,
                   "a stall is declared only after the silence timeout")
        try expect(UpdateDownloadStubProtocol.seenRequests.last?
                    .value(forHTTPHeaderField: "Range"),
                   equals: "bytes=50000-", "after a stall the download resumes, not restarts")

        // Сервер не умеет докачку: ответ 200 целиком заменяет начатое.
        let ignored = try run([Reply(bytes: 100_000, ending: .drop), Reply(honorRange: false)])
        try expectPayload(ignored, "a server that ignores Range must still yield the right archive")

        // Связи нет вовсе: столько попыток, сколько разрешено, и честная ошибка.
        let refused = try run([Reply(refuse: true), Reply(refuse: true), Reply(refuse: true),
                               Reply(refuse: true)])
        try expectError(refused, .network, "no connection at all is a network failure")
        try expect(UpdateDownloadStubProtocol.seenRequests.count, equals: 3,
                   "give up after the allowed number of fruitless attempts")

        // Кусок пришёл, дальше ни байта: ошибка говорит, сколько успело прийти.
        let partial = try run([Reply(bytes: 1_000, ending: .drop), Reply(refuse: true),
                               Reply(refuse: true), Reply(refuse: true), Reply(refuse: true)])
        try expectError(partial, .downloadInterrupted(received: 1_000, total: 300_000),
                        "a download that stopped advancing reports how far it got")
        try expect(UpdateDownloadStubProtocol.seenRequests.count, equals: 4,
                   "a productive attempt resets the count of fruitless ones")

        // Ответ сервера с ошибкой не повторяется: это не обрыв.
        let missing = try run([Reply(status: 404), Reply()])
        try expectError(missing, .httpStatus(404), "HTTP errors surface as they are")
        try expect(UpdateDownloadStubProtocol.seenRequests.count, equals: 1,
                   "an HTTP error is not retried")

        // Слишком большой архив отвергается по заголовку, не скачиваясь.
        var small = quick
        small.maxBytes = 100_000
        let huge = try run([Reply()], policy: small)
        try expectError(huge, .archiveTooLarge, "an oversized archive is refused")
        try expect(huge.progress.isEmpty, equals: true,
                   "an oversized archive is refused before its body is read")

        // Сумма — после докачки, по склеенному целому.
        let forged = DictorUpdateManifest(version: "9.8.7", sha256: String(repeating: "0", count: 64))
        let mismatch = try run([Reply(bytes: 120_000, ending: .drop), Reply()], manifest: forged)
        try expectError(mismatch, .checksumMismatch, "a resumed archive is still checksummed")

        // Подпись хода: та же строка уходит в окно и в настройки.
        let sample = UpdateDownloadProgress(received: 1_234_567, total: 4_292_088, attempt: 1)
        try expect(updateDownloadPhaseText(sample, language: .russian, capitalized: true),
                   equals: "Скачиваю: 1,2 из 4,3 МБ", "Russian progress uses a decimal comma")
        try expect(updateDownloadPhaseText(UpdateDownloadProgress(received: 1_234_567,
                                                                  total: nil, attempt: 3),
                                           language: .english, capitalized: false),
                   equals: "the connection dropped, resuming: 1.2 MB",
                   "a resumed attempt says so, and an unknown size is not invented")
        try expect(DictorUpdateInstallerError.downloadInterrupted(received: 1_000_000,
                                                                  total: 4_300_000)
                    .message(language: .russian).contains("VPN"),
                   equals: true, "the failure tells the person what to do next")
    }
}
#endif
