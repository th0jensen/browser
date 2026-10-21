import XCTest
@testable import Browser

@MainActor
final class StoreFileTests: XCTestCase {
    func testNewerWriteWinsOverEncodingAlreadyInProgress() async throws {
        let directory = URL.temporaryDirectory.appending(path: "StoreFileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = StoreFile(url: directory.appending(path: "History.plist"))
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        file.write {
            started.signal()
            resume.wait()
            return Data("old".utf8)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        file.write { Data("new".utf8) }
        resume.signal()
        let saved = await file.read()
        XCTAssertEqual(saved, Data("new".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["History.plist"])
    }

    func testPendingWritesReleaseObsoleteCapturedSnapshots() async throws {
        let directory = URL.temporaryDirectory.appending(path: "StoreFileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = StoreFile(url: directory.appending(path: "Session.plist"))
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        file.write {
            started.signal()
            resume.wait()
            return Data("active".utf8)
        }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)

        var captured: [WeakStorePayload] = []
        for value in 0..<64 {
            var payload: StorePayload? = StorePayload(Data("snapshot-\(value)".utf8))
            captured.append(WeakStorePayload(payload))
            file.write { [payload] in payload?.data }
            payload = nil
        }

        XCTAssertTrue(captured.dropLast().allSatisfy { $0.value == nil })
        XCTAssertNotNil(captured.last?.value)
        resume.signal()
        let saved = await file.read()
        XCTAssertEqual(saved, Data("snapshot-63".utf8))
        XCTAssertTrue(captured.allSatisfy { $0.value == nil })
    }

    func testAcknowledgedWriteReportsFailureAndCanRetryWithoutLosingNewerFlush() async throws {
        let directory = URL.temporaryDirectory.appending(path: "StoreFileTests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let file = StoreFile(url: directory.appending(path: "Session.plist"))
        do { try await file.writeAcknowledged(Data("live".utf8)); XCTFail("A failed write cannot acknowledge durability") }
        catch { }
        try FileManager.default.removeItem(at: directory)
        file.write { Data("obsolete".utf8) }
        try await file.writeAcknowledged(Data("live".utf8))
        XCTAssertEqual(file.readNow(), Data("live".utf8))
        file.writeNow(Data("termination".utf8))
        XCTAssertEqual(file.readNow(), Data("termination".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testIdenticalSnapshotDoesNotRewriteFile() throws {
        let directory = URL.temporaryDirectory.appending(path: "StoreFileTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = StoreFile(url: directory.appending(path: "Session.plist"))
        let data = Data("snapshot".utf8)
        file.writeNow(data)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.url.path)
        file.writeNow(data)
        let modified = try FileManager.default.attributesOfItem(atPath: file.url.path)[.modificationDate] as? Date
        XCTAssertEqual(modified, oldDate)
    }
}

private final class StorePayload: @unchecked Sendable {
    let data: Data

    init(_ data: Data) {
        self.data = data
    }
}

private final class WeakStorePayload {
    private(set) weak var value: StorePayload?

    init(_ value: StorePayload?) {
        self.value = value
    }
}
