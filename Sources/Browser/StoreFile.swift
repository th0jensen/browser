import Darwin
import Foundation
import Synchronization

/// A store's file, encoded and written on a serial background queue. Publication checks
/// the write generation, so a newer snapshot cannot be replaced by an older queued write.
final class StoreFile: Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "dev.athas.browser.store-file", qos: .utility)
    private let latestWrite = Mutex(0)
    private let persistedData = Mutex<Data?>(nil)

    init(url: URL) {
        self.url = url
    }

    @MainActor
    static func applicationSupport(named name: String) -> StoreFile {
        StoreFile(url: BrowserProfile.directory.appending(path: name))
    }

    func read() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async { [url] in continuation.resume(returning: try? Data(contentsOf: url)) }
        }
    }

    /// Reads right away, for state needed before the first window appears.
    func readNow() -> Data? {
        queue.sync { try? Data(contentsOf: url) }
    }

    func write(_ encode: @escaping @Sendable () -> Data?) {
        let generation = nextWrite()
        queue.async { [self] in
            guard latestWrite.withLock({ $0 == generation }), let data = encode() else { return }
            save(data, generation: generation)
        }
    }

    /// Drains the writer before returning, including when the app is quitting.
    func writeNow(_ data: Data?) {
        let generation = nextWrite()
        queue.sync {
            if let data { save(data, generation: generation) }
        }
    }

    private func nextWrite() -> Int {
        latestWrite.withLock { latest in
            latest += 1
            return latest
        }
    }

    private func save(_ data: Data, generation: Int) {
        guard latestWrite.withLock({ $0 == generation }), persistedData.withLock({ $0 != data }) else { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary = directory.appending(path: ".\(url.lastPathComponent)-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
            guard descriptor >= 0 else { throw posixError() }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer {
                try? handle.close()
                try? FileManager.default.removeItem(at: temporary)
            }
            guard fchmod(descriptor, 0o600) == 0 else { throw posixError() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            // Encoding and fsync stay outside the lock; only the atomic publication
            // must be indivisible with a newer write request.
            let published = try latestWrite.withLock { current in
                guard current == generation else { return false }
                guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
                return true
            }
            guard published else { return }
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else { throw posixError() }
            defer { Darwin.close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { throw posixError() }
            persistedData.withLock { $0 = data }
        } catch {
            NSLog("Could not save Browser store %@: %@", url.lastPathComponent, error.localizedDescription)
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
