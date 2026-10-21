import Darwin
import Foundation
import Synchronization

/// A store's file, encoded and written on a serial background queue. Pending writes are
/// coalesced so obsolete snapshots do not wait in memory or replace newer state.
final class StoreFile: Sendable {
    private struct WriteRequest: Sendable {
        let generation: Int
        let encode: @Sendable () -> Data?
    }

    private struct WriteState: Sendable {
        var generation = 0
        var workerScheduled = false
        var pending: WriteRequest?
    }

    let url: URL
    private let queue = DispatchQueue(label: "dev.athas.browser.store-file", qos: .utility)
    private let writes = Mutex(WriteState())
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
        let shouldSchedule = writes.withLock { state in
            state.generation += 1
            state.pending = WriteRequest(generation: state.generation, encode: encode)
            guard !state.workerScheduled else { return false }
            state.workerScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        queue.async { [self] in drainWrites() }
    }

    /// Drains the writer before returning, including when the app is quitting.
    func writeNow(_ data: Data?) {
        let generation = writes.withLock { state in
            state.generation += 1
            state.pending = nil
            return state.generation
        }
        queue.sync {
            if let data { save(data, generation: generation) }
        }
    }

    private func drainWrites() {
        while let request = takePendingWrite() {
            guard let data = request.encode() else { continue }
            save(data, generation: request.generation)
        }
    }

    private func takePendingWrite() -> WriteRequest? {
        writes.withLock { state in
            guard let pending = state.pending else {
                state.workerScheduled = false
                return nil
            }
            state.pending = nil
            return pending
        }
    }

    /// An archive restore must save its live descriptor before deleting the durable recovery record.
    /// Unlike `write`, this API reports failed or obsolete publication to the caller.
    func writeAcknowledged(_ data: Data) async throws {
        let generation = writes.withLock { state in
            state.generation += 1
            state.pending = nil
            return state.generation
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard try publish(data, generation: generation) else { throw CocoaError(.userCancelled) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func save(_ data: Data, generation: Int) {
        do { _ = try publish(data, generation: generation) }
        catch { NSLog("Could not save Browser store %@: %@", url.lastPathComponent, error.localizedDescription) }
    }

    private func publish(_ data: Data, generation: Int) throws -> Bool {
        guard writes.withLock({ $0.generation == generation }) else { return false }
        if persistedData.withLock({ $0 == data }) { return true }
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
            let published = try writes.withLock { state in
                guard state.generation == generation else { return false }
                guard Darwin.rename(temporary.path, url.path) == 0 else { throw posixError() }
                return true
            }
            guard published else { return false }
            let directoryDescriptor = Darwin.open(directory.path, O_RDONLY)
            guard directoryDescriptor >= 0 else { throw posixError() }
            defer { Darwin.close(directoryDescriptor) }
            guard fsync(directoryDescriptor) == 0 else { throw posixError() }
            persistedData.withLock { $0 = data }
            return true
        } catch { throw error }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
