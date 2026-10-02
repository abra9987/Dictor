import Foundation
import FluidAudio

// MARK: - Обновление модели без простоя
//
// Пока служба распознаёт на модели прошлой версии, текущая скачивается здесь —
// в фоне и только как файлы. В память она не загружается: CoreML готовит
// модель под Neural Engine десятки секунд, и делать это рядом с идущей
// диктовкой нельзя — первая подготовка энкодера при открытом аудиовходе
// зависает (см. порядок запуска в `startStartup`). Поэтому переход устроен в
// два шага: файлы доезжают незаметно, а сама замена — обычный перезапуск
// службы в момент, когда человек не диктует. Тем же путём служба поднимается
// после каждого обновления приложения, так что новых состояний у неё нет.
//
// Мгновенная подмена модели прямо под работающей диктовкой отвергнута
// сознательно: она потребовала бы держать в памяти две модели и готовить
// вторую рядом с первой, а цена её отказа — ровно та, от которой эта функция
// защищает: человек без диктовки.

/// Что окну и панели сказать про модель, пока служба работает на прежней.
struct SpeechModelUpdateStatus: Equatable {
    enum Phase: String {
        /// Новая модель скачивается.
        case downloading
        /// Скачана и проверена, ждёт паузы между диктовками.
        case waitingForIdle
        /// Не скачалась; будет ещё попытка.
        case retrying
        /// Скачана и цела, но на этой машине не запустилась. Попыток больше
        /// нет до следующего запуска службы.
        case failedToLoad
    }

    /// Короткое имя модели, на которой служба работает сейчас.
    let previousModelName: String
    let phase: Phase
    /// Доля скачанного, 0…1. Есть только у `.downloading`, и то не сразу.
    let fraction: Double?

    /// Для отпечатка перерисовки окна.
    var fingerprint: String {
        let percent = fraction.map { String(Int(($0 * 100).rounded())) } ?? "-"
        return "\(previousModelName):\(phase.rawValue):\(percent)"
    }
}

enum SpeechModelUpdateError: LocalizedError {
    /// Только что скачанные файлы не сошлись с манифестом.
    case downloadFailedVerification(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailedVerification(let detail):
            return "The freshly downloaded speech model does not match the pinned manifest: \(detail)"
        }
    }
}

enum SpeechModelUpdater {
    /// Скачивает текущую модель и сверяет её с манифестом. Ничего не
    /// загружает в память и не трогает модель, на которой идёт распознавание.
    static func fetchCurrentModel(_ package: SpeechModelPackage = .current,
                                  progressHandler: ProgressHandler?) async throws {
        let directory = package.cacheDirectory

        if package.filesExist {
            if (try? ModelIntegrity.verify(package, at: directory)) != nil { return }
            // Все файлы на месте, а суммы не сходятся — докачивать нечего,
            // чинить можно только заменой. Недокачанный каталог сюда не
            // попадает: его загрузчик продолжает с места обрыва.
            log("ASR: \(package.profile.shortName) on disk is damaged; downloading it again")
            _ = try await removeSpeechModelCacheDirectory(directory)
        }

        try assertSufficientDiskSpaceForSpeechModelDownload(profile: package.profile)
        // ModelHub.download, а не AsrModels.download: второй после загрузки
        // файлов ещё и поднимает каждую модель в CoreML.
        try await ModelHub.download(package.repo,
                                    to: directory.deletingLastPathComponent(),
                                    progressHandler: progressHandler)
        try Task.checkCancellation()
        do {
            try ModelIntegrity.verify(package, at: directory)
        } catch {
            throw SpeechModelUpdateError.downloadFailedVerification(error.localizedDescription)
        }
    }

    /// Через сколько повторить неудавшуюся загрузку. Причина почти всегда —
    /// сеть, и она либо возвращается за минуты, либо её нет часами: первые
    /// попытки частые, дальше раз в час, чтобы не будить диск и радио зря.
    ///
    /// Отдельный случай — скачалось целиком, а с манифестом не сходится. Это
    /// не сеть: файлы у автора модели изменились, и повтор принесёт те же
    /// 630 МБ с тем же исходом, пока не выйдет обновление Dictor с новым
    /// манифестом. Здесь попытка одна в сутки.
    static func retryDelay(afterFailedAttempt attempt: Int,
                           failure: Error? = nil) -> TimeInterval {
        if failure is SpeechModelUpdateError { return 24 * 60 * 60 }
        switch attempt {
        case ...1: return 5 * 60
        case 2: return 15 * 60
        default: return 60 * 60
        }
    }

    /// Пора ли переходить на скачанную модель.
    ///
    /// Переход — это перезапуск службы: на несколько секунд (а при первой
    /// подготовке модели — до сорока) диктовка недоступна. Поэтому он
    /// дожидается тишины: никто не записывает и не распознаёт, аудиовход
    /// закрыт, а с последней диктовки прошло достаточно, чтобы человек успел
    /// отойти от разговора, а не просто набрать воздуха.
    static func switchIsDue(updateIsReady: Bool,
                            serviceIsOccupied: Bool,
                            audioInputIsOpen: Bool,
                            secondsSinceLastDictation: TimeInterval) -> Bool {
        updateIsReady
            && !serviceIsOccupied
            && !audioInputIsOpen
            && secondsSinceLastDictation >= SPEECH_MODEL_SWITCH_QUIET_SECONDS
    }
}
