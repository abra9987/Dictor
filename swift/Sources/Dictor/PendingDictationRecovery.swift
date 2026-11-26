// Запись, которая переживёт падение: звук диктовки пишется на диск по ходу
// записи и поднимается после перезапуска, если до текста дело не дошло.

import Foundation

enum PendingDictationRecovery {
    private static let directoryName = "PendingDictations"
    private static let fileExtension = "sdaudio"
    private static let magic = Data("SDAR".utf8)

    static func directoryURL() throws -> URL {
        let url = try dictorApplicationSupportDirectory()
            .appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: url.path)
        return url
    }

    static func createJournal() throws -> PendingDictationJournal {
        try PendingDictationJournal(url: directoryURL()
            .appendingPathComponent("pending-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension))
    }

    static func pendingURLs() -> [URL] {
        guard let directory = try? directoryURL(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else { return [] }

        return urls
            .filter { $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix("pending-") }
            .sorted { lhs, rhs in
                let left = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let right = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return left < right
            }
    }

    static func loadSamples(from url: URL) throws -> [Float] {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw currentPOSIXError() }
        defer { _ = Darwin.close(fd) }

        try validateSingleLinkRegularFileDescriptor(fd)
        var st = stat()
        guard Darwin.fstat(fd, &st) == 0 else { throw currentPOSIXError() }
        guard st.st_size >= PENDING_DICTATION_HEADER_SIZE,
              st.st_size <= PENDING_DICTATION_MAX_BYTES else {
            throw posixError(EFBIG)
        }

        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.readToEnd() ?? Data()
        guard data.count >= PENDING_DICTATION_HEADER_SIZE,
              data.prefix(4) == magic,
              readUInt32LE(data, offset: 4) == PENDING_DICTATION_FILE_VERSION,
              readUInt32LE(data, offset: 8) == UInt32(SAMPLE_RATE),
              readUInt32LE(data, offset: 12) == UInt32(MemoryLayout<Float>.size) else {
            throw posixError(EINVAL)
        }

        let payload = data.dropFirst(PENDING_DICTATION_HEADER_SIZE)
        // A process can die halfway through the final write. Preserve every
        // complete float instead of rejecting the whole recording for 1-3
        // trailing bytes.
        let usablePayloadCount = payload.count - (payload.count % MemoryLayout<Float>.size)
        let usablePayload = payload.prefix(usablePayloadCount)
        var samples = [Float](repeating: 0,
                              count: usablePayload.count / MemoryLayout<Float>.size)
        samples.withUnsafeMutableBytes { destination in
            usablePayload.withUnsafeBytes { source in
                destination.copyBytes(from: source)
            }
        }
        return samples
    }

    static func remove(_ url: URL?) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch where (error as NSError).code == NSFileNoSuchFileError {
            return
        } catch {
            log("pending dictation cleanup failed: \(error.localizedDescription)")
        }
    }

    static func headerData() -> Data {
        var data = magic
        appendUInt32LE(PENDING_DICTATION_FILE_VERSION, to: &data)
        appendUInt32LE(UInt32(SAMPLE_RATE), to: &data)
        appendUInt32LE(UInt32(MemoryLayout<Float>.size), to: &data)
        return data
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            return UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
        }
    }
}

final class PendingDictationJournal: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "Dictor.PendingDictationJournal",
                                      qos: .utility)
    private var fileDescriptor: Int32
    private var didLogWriteFailure = false

    init(url: URL) throws {
        self.url = url
        fileDescriptor = -1
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW
        let fd = Darwin.open(url.path, flags, PRIVATE_LOG_FILE_MODE)
        guard fd >= 0 else { throw currentPOSIXError() }
        do {
            try validateSingleLinkRegularFileDescriptor(fd)
            guard Darwin.fchmod(fd, PRIVATE_LOG_FILE_MODE) == 0 else {
                throw currentPOSIXError()
            }
            try writeAllData(PendingDictationRecovery.headerData(), to: fd)
            fileDescriptor = fd
        } catch {
            _ = Darwin.close(fd)
            _ = Darwin.unlink(url.path)
            throw error
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBytes { Data($0) }
        queue.async { [self] in
            guard fileDescriptor >= 0 else { return }
            do {
                try writeAllData(data, to: fileDescriptor)
            } catch where !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation write failed: \(error.localizedDescription)")
            } catch {}
        }
    }

    func finish() {
        queue.sync { [self] in
            guard fileDescriptor >= 0 else { return }
            if Darwin.fsync(fileDescriptor) != 0, !didLogWriteFailure {
                didLogWriteFailure = true
                log("pending dictation sync failed: \(currentPOSIXError().localizedDescription)")
            }
            _ = Darwin.close(fileDescriptor)
            fileDescriptor = -1
        }
    }
}
