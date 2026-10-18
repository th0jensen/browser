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
