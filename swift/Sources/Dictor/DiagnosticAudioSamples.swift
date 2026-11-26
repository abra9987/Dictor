import FluidAudio
import Foundation

// Записи диктовок для разбора ошибок распознавания.
//
// Обычно звук не живёт дольше текста. Но «модель иногда выдаёт бред» нельзя
// разобрать по тексту: нужен тот самый звук, который можно прогнать через
// `--transcribe-file` на другой модели или другой обработке. Поэтому по
// явному включению (`defaults write com.raul.dictor
// diagnostic_audio_samples_v1 -int 100`) служба хранит последние N записей —
// ровно то, что получила модель (16 кГц, моно), — и рядом JSON: сырой текст
// модели, текст после правок, вставленный текст, режим микрофона.
// По умолчанию выключено. Пока включено, вкладка «Приватность» говорит об
// этом вместо «удаляется»: факт там не имеет права врать.

enum DiagnosticAudioSamples {
    static let defaultsKey = "diagnostic_audio_samples_v1"
    static let directoryName = "AudioSamples"
    static let maximumCount = 1000

    /// Сколько записей хранить; 0 — выключено.
    static func keptCount(defaults: UserDefaults = .standard) -> Int {
        min(max(defaults.integer(forKey: defaultsKey), 0), maximumCount)
    }

    static func directory() throws -> URL {
        let url = try dictorApplicationSupportDirectory()
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    struct Metadata: Codable, Equatable {
        let createdAt: Date
        let audioSeconds: Double
        let inputChannels: Int?
        let language: String
        let rawText: String
        let processedText: String
        let insertedText: String
    }

    /// Вызов из пути диктовки: ничего не делает, пока не включено, и пишет
    /// на диск не на главном потоке.
    static func saveIfEnabled(samples: [Float], audioSeconds: Double, inputChannels: Int?,
                              language: DictationLanguage, rawText: String,
                              processedText: String, insertedText: String) {
        let keep = keptCount()
        guard keep > 0 else { return }
        let metadata = Metadata(createdAt: Date(), audioSeconds: audioSeconds,
                                inputChannels: inputChannels, language: language.rawValue,
                                rawText: rawText, processedText: processedText,
                                insertedText: insertedText)
        Task.detached(priority: .utility) {
            save(samples: samples, metadata: metadata, keep: keep)
        }
    }

    /// Пишет запись и убирает лишние старые. Ошибка не мешает диктовке:
    /// это диагностика, а не часть пути текста.
    static func save(samples: [Float], metadata: Metadata, keep: Int,
                     in directory: URL? = nil) {
        guard keep > 0, !samples.isEmpty else { return }
        do {
            let folder = try directory ?? self.directory()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss-SSS"
            let base = formatter.string(from: metadata.createdAt)
            try wavData(samples: samples, sampleRate: Int(SAMPLE_RATE))
                .write(to: folder.appendingPathComponent(base + ".wav"), options: .atomic)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata)
                .write(to: folder.appendingPathComponent(base + ".json"), options: .atomic)
            prune(folder, keep: keep)
        } catch {
            log("diagnostic audio sample not saved: \(error.localizedDescription)")
        }
    }

    /// Имена начинаются с даты, поэтому порядок по имени — порядок по
    /// времени.
    static func prune(_ folder: URL, keep: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let bases = Set(files.filter { $0.hasSuffix(".wav") || $0.hasSuffix(".json") }
            .map { ($0 as NSString).deletingPathExtension })
            .sorted()
        for base in bases.dropLast(keep) {
            for ext in ["wav", "json"] {
                try? FileManager.default.removeItem(at: folder.appendingPathComponent(base + "." + ext))
            }
        }
    }

    /// 16-битный PCM WAV: его читает и `--transcribe-file`, и любой плеер.
    static func wavData(samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 2
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + byteCount))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16)); append(UInt16(1))
        append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(UInt32(byteCount))
        data.reserveCapacity(data.count + byteCount)
        for sample in samples {
            let clamped = sample.isFinite ? max(-1, min(1, sample)) : 0
            append(Int16(clamped * Float(Int16.max)))
        }
        return data
    }
}

#if DEBUG
extension DictorSelfTest {
    static func testDiagnosticAudioSamples() throws {
        let defaults = UserDefaults(suiteName: "com.raul.dictor.selftest.samples")!
        defaults.removePersistentDomain(forName: "com.raul.dictor.selftest.samples")
        try expect(DiagnosticAudioSamples.keptCount(defaults: defaults), equals: 0,
                   "diagnostic audio samples must be off by default")
        defaults.set(5000, forKey: DiagnosticAudioSamples.defaultsKey)
        try expect(DiagnosticAudioSamples.keptCount(defaults: defaults),
                   equals: DiagnosticAudioSamples.maximumCount, "the kept count is capped")
        defaults.removePersistentDomain(forName: "com.raul.dictor.selftest.samples")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("dictor-samples-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let samples = (0..<1600).map { Float(sin(Double($0) / 10)) * 0.5 }
        for second in 0..<4 {
            let metadata = DiagnosticAudioSamples.Metadata(
                createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(second)),
                audioSeconds: 0.1, inputChannels: 3, language: "auto",
                rawText: "Я нажал <unk>Сохранить<unk>.", processedText: "Я нажал «Сохранить».",
                insertedText: "Я нажал «Сохранить».")
            DiagnosticAudioSamples.save(samples: samples, metadata: metadata, keep: 3, in: folder)
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        try expect(files.count, equals: 6, "only the newest three recordings (wav + json) are kept")
        guard let wav = files.first(where: { $0.hasSuffix(".wav") }) else {
            throw SelfTestFailure.failed("no wav file written")
        }
        // Запись должна читаться тем же путём, что и в --transcribe-file.
        let readBack = try AudioConverter().resampleAudioFile(folder.appendingPathComponent(wav))
        try expect(readBack.count, equals: samples.count,
                   "a saved sample must read back at 16 kHz with the same length")
        let json = try Data(contentsOf: folder.appendingPathComponent(
            (wav as NSString).deletingPathExtension + ".json"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(DiagnosticAudioSamples.Metadata.self, from: json)
        try expect(metadata.inputChannels, equals: 3, "metadata keeps the microphone channel count")
    }
}
#endif
