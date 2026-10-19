import Synchronization
import WebKit
import XCTest
@testable import Browser

@MainActor
final class FaviconTests: XCTestCase {
    private let page = URL(string: "https://example.com/docs/page.html")!
    /// A 1×1 PNG.
    private static let pixelPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

    func testIgnoresUnsupportedSchemesAndOversizedAddresses() {
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "javascript:alert(1)", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: " ", baseURL: page))
        XCTAssertNotNil(FaviconCandidate(rel: "icon", href: "data:image/png;base64,AAAA", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "https://example.com/" + String(repeating: "x", count: 3_000),
                                     baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "data:image/png;base64," +
                                     String(repeating: "A", count: FaviconData.maxDataURLCharacters), baseURL: page))
    }

    func testSkipsSVGIcons() {
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "/icon.svg", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "/icon", type: "image/svg+xml", baseURL: page))
        XCTAssertNil(FaviconCandidate(rel: "icon", href: "data:image/svg+xml;base64,AAAA", baseURL: page))
        XCTAssertEqual(FaviconCandidate(rel: "icon", href: "/icon.png", sizes: "any", baseURL: page)?.isScalable, true)
    }

    func testReadingStopsPastTheLimit() async throws {
        func read(_ count: Int, limit: Int) async throws -> FaviconData.Read {
            try await FaviconData.read(AsyncStream { continuation in
                for byte in 0..<count { continuation.yield(UInt8(byte % 256)) }
                continuation.finish()
            }, limit: limit)
        }

        let whole = try await read(4, limit: 4)
        XCTAssertEqual(whole, FaviconData.Read(bytes: Data([0, 1, 2, 3]), isTruncated: false))
        let truncated = try await read(10, limit: 4)
        XCTAssertEqual(truncated, FaviconData.Read(bytes: Data([0, 1, 2, 3]), isTruncated: true))
    }

    func testAcceptsOnlyRasterIconTypes() throws {
        XCTAssertTrue(FaviconData.isIconMIMEType("image/x-icon"))
        XCTAssertTrue(FaviconData.isIconMIMEType("image/PNG"))
        XCTAssertTrue(FaviconData.isIconMIMEType("application/octet-stream"))
        XCTAssertFalse(FaviconData.isIconMIMEType("image/svg+xml"))
        XCTAssertFalse(FaviconData.isIconMIMEType("application/pdf"))
        XCTAssertFalse(FaviconData.isIconMIMEType("text/html"))

        let png = try XCTUnwrap(Data(base64Encoded: Self.pixelPNG))
        XCTAssertEqual(FaviconData.imageType(of: png), .png)
        XCTAssertEqual(FaviconData.imageType(of: Data([0, 0, 1, 0, 1, 0])), .ico)
        XCTAssertEqual(FaviconData.imageType(of: Data("GIF89a".utf8)), .gif)
        XCTAssertEqual(FaviconData.imageType(of: Data("RIFF\0\0\0\0WEBPVP8 ".utf8)), .webP)
        XCTAssertNil(FaviconData.imageType(of: Data("%PDF-1.7".utf8)))
        XCTAssertNil(FaviconData.imageType(of: Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)))

        XCTAssertNotNil(FaviconData.image(from: png))
        XCTAssertNil(FaviconData.image(from: Data("%PDF-1.7".utf8)))
        XCTAssertNil(FaviconData.image(from: png + Data(count: FaviconData.maxIconBytes)))
    }

    func testRanksSizesNearTheDisplaySizeFirst() {
        let icon = { (path: String, sizes: [Int], scalable: Bool, touch: Bool) in
            FaviconCandidate(url: URL(string: "https://example.com/\(path)")!, sizes: sizes,
                             isScalable: scalable, isTouchIcon: touch)
        }
        let candidates = [
            icon("touch.png", [], false, true),
            icon("16.png", [16], false, false),
            icon("unknown.ico", [], false, false),
            icon("icon.svg", [], true, false),
            icon("192.png", [192], false, false),
            icon("48.png", [48], false, false),
            icon("24.png", [24], false, false),
        ]

        XCTAssertEqual(FaviconCandidate.ranked(candidates, pageURL: page).map(\.lastPathComponent),
                       ["48.png", "192.png", "icon.svg", "unknown.ico", "24.png", "16.png", "touch.png",
                        "favicon.ico"])
    }

    func testRankingFallsBackToTheSiteFavicon() {
        let favicon = URL(string: "https://example.com/favicon.ico")!

        XCTAssertEqual(FaviconCandidate.ranked([], pageURL: page), [favicon])
        XCTAssertEqual(FaviconCandidate.ranked([FaviconCandidate(url: favicon)], pageURL: page), [favicon])
        XCTAssertEqual(FaviconCandidate.ranked([], pageURL: URL(string: "file:///tmp/a.html")!), [])
    }

    func testCacheEntriesExpire() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = FaviconCache(directory: directory)
        let entry = FaviconCache.Entry(source: URL(string: "https://example.com/favicon.ico")!, data: Data([1, 2, 3]))

        cache.save(entry, forHost: "example.com")

        XCTAssertEqual(cache.entry(forHost: "example.com"), entry)
        XCTAssertEqual(cache.entry(forHost: "example.com", now: .now.addingTimeInterval(6 * 24 * 60 * 60)), entry)
        XCTAssertNil(cache.entry(forHost: "example.com", now: .now.addingTimeInterval(8 * 24 * 60 * 60)))
        XCTAssertNil(cache.entry(forHost: "example.org"))
    }

    func testPageCandidateCollectionIsBoundedBeforeCrossingTheWebKitBridge() async throws {
        let webView = WKWebView()
        let icons = (0..<300).map { index in
            "<link rel='icon' \(index == 250 ? "sizes='64x64'" : "") href='https://cdn.example.com/\(index).png'>"
        }.joined()
        webView.loadHTMLString("<head>\(icons)</head>", baseURL: page)
        try await waitUntil { !webView.isLoading && webView.url == page }

        let candidates = await FaviconStore.candidates(in: webView)
        XCTAssertEqual(candidates.count, FaviconStore.maximumPageCandidates)
        XCTAssertEqual(candidates.first?.url.lastPathComponent, "250.png")
        XCTAssertEqual(candidates.last?.url.lastPathComponent, "30.png")
    }

    func testReadsAndLoadsTheIconsOfAnOpenPage() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        let originalCache = FaviconStore.cache
        FaviconStore.cache = FaviconCache(directory: directory)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
            await MainActor.run { FaviconStore.cache = originalCache }
        }
        let iconURL = "data:image/png;base64,\(Self.pixelPNG)"
        let pageURL = URL(string: "https://favicon-test.invalid/app/")!
        let webView = WKWebView()
        webView.loadHTMLString(#"<head><link rel="mask-icon" href="m.svg"><link rel="icon" href="\#(iconURL)"></head>"#,
                               baseURL: pageURL)
        try await waitUntil { !webView.isLoading && webView.url == pageURL }

        let candidates = await FaviconStore.candidates(in: webView)
        XCTAssertEqual(candidates, [FaviconCandidate(url: URL(string: iconURL)!)])

        let icon = await FaviconStore.icon(forPage: pageURL, candidates: candidates)
        XCTAssertNotNil(icon)
        XCTAssertNotNil(FaviconStore.cachedIcon(for: pageURL))
        XCTAssertEqual(FaviconStore.cache.entry(forHost: "favicon-test.invalid")?.source, URL(string: iconURL))
    }
}


extension FaviconTests {
    func testSharedMemoryCacheEvictsToItsCostAndCountBudgets() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        let originalCache = FaviconStore.cache
        FaviconStore.cache = FaviconCache(directory: directory)
        await FaviconStore.clear(since: .distantPast)
        addTeardownBlock {
            await FaviconStore.clear(since: .distantPast)
            try? FileManager.default.removeItem(at: directory)
            await MainActor.run { FaviconStore.cache = originalCache }
        }
        let source = FaviconCandidate(url: try XCTUnwrap(URL(string: "data:image/png;base64,\(Self.pixelPNG)")))
        for index in 0..<FaviconStore.maximumMemoryIcons {
            let page = try XCTUnwrap(URL(string: "https://favicon-\(index).example/page"))
            let icon = await FaviconStore.icon(forPage: page, candidates: [source])
            XCTAssertNotNil(icon)
        }
        XCTAssertNotNil(FaviconStore.cachedIcon(for: URL(string: "https://favicon-0.example/page")))
        let count = FaviconStore.maximumMemoryIcons + 16
        for index in FaviconStore.maximumMemoryIcons..<count {
            let page = try XCTUnwrap(URL(string: "https://favicon-\(index).example/page"))
            let icon = await FaviconStore.icon(forPage: page, candidates: [source])
            XCTAssertNotNil(icon)
        }

        let usage = FaviconStore.memoryUsage
        XCTAssertLessThanOrEqual(usage.icons, FaviconStore.maximumMemoryIcons)
        XCTAssertLessThanOrEqual(usage.iconCost, FaviconStore.maximumMemoryIconCost)
        XCTAssertNotNil(FaviconStore.cachedIcon(for: URL(string: "https://favicon-0.example/page")))
        XCTAssertNil(FaviconStore.cachedIcon(for: URL(string: "https://favicon-1.example/page")))
        XCTAssertNotNil(FaviconStore.cachedIcon(for: URL(string: "https://favicon-\(count - 1).example/page")))
        await FaviconStore.clear(since: .distantPast)
    }

    func testClearingCacheRejectsWritesFromRequestsStartedBeforeClear() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FaviconCache(directory: directory)
        let generation = cache.writeGeneration
        let entry = FaviconCache.Entry(source: URL(string: "https://example.com/favicon.ico")!, data: Data([1]))
        cache.save(entry, forHost: "example.com", generation: generation)
        cache.removeEntries(since: .distantPast)
        cache.save(entry, forHost: "example.com", generation: generation)
        XCTAssertNil(cache.entry(forHost: "example.com"))
        cache.save(entry, forHost: "example.com", generation: cache.writeGeneration)
        XCTAssertEqual(cache.entry(forHost: "example.com"), entry)
    }

    func testPrivateDocumentIconDoesNotPopulateSharedMemoryOrDisk() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "FaviconTests-\(UUID().uuidString)")
        let originalCache = FaviconStore.cache
        FaviconStore.cache = FaviconCache(directory: directory)
        defer {
            FaviconStore.cache = originalCache
            try? FileManager.default.removeItem(at: directory)
        }
        let page = URL(string: "https://private-\(UUID().uuidString).invalid/")!
        let icon = FaviconCandidate(url: URL(string: "data:image/png;base64,\(Self.pixelPNG)")!)
        let image = await FaviconStore.icon(forPage: page, candidates: [icon], remember: false)
        XCTAssertNotNil(image)
        XCTAssertNil(FaviconStore.cachedIcon(for: page))
        XCTAssertNil(FaviconStore.cache.entry(forHost: page.host()!))
    }
}

private actor FaviconRequestRecorder {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

extension FaviconTests {
    func testSpeculativeIconRequestNeverReplaysCallbackURLOrFallsBackToPage() async {
        let callback = URL(string: "https://login.example/callback?code=single-use&state=AbC")!
        let recorder = FaviconRequestRecorder()
        let result: Data? = await FaviconRequests.siteIcon(for: callback) { url in
            await recorder.record(url)
            return nil // A missing favicon must not trigger a GET of the callback page.
        }
        let requests = await recorder.urls
        XCTAssertNil(result)
        XCTAssertEqual(requests, [URL(string: "https://login.example/favicon.ico")!])
        XCTAssertFalse(requests.contains(callback))
        XCTAssertNil(requests.first?.query)
        XCTAssertNil(requests.first?.fragment)
    }

    func testLoopbackCallbackListenerIsNeverProbedForAnIcon() async {
        let recorder = FaviconRequestRecorder()
        let callbacks = [
            "http://127.0.0.1:54321/?user_id=123&access_token=single-use",
            "http://localhost:54321/callback?code=single-use",
            "http://[::1]:54321/callback?code=single-use",
        ]
        for address in callbacks {
            let result: Data? = await FaviconRequests.siteIcon(for: URL(string: address)!) { url in
                await recorder.record(url)
                return Data() // Model a one-shot listener: any request would consume it.
            }
            XCTAssertNil(result, address)
        }
        let requests = await recorder.urls
        XCTAssertTrue(requests.isEmpty)
    }

    func testIconNetworkPolicyRejectsLoopbackRedirectDestinations() {
        for address in [
            "http://localhost:8765/callback", "https://localhost./callback", "http://app.localhost/callback",
            "http://127.0.0.1:8765/", "http://127.4.5.6/", "http://127.1/", "http://2130706433/",
            "http://0x7f000001/", "http://0177.0.0.1/", "http://0.0.0.0:8765/",
            "http://[::1]:8765/", "http://[0:0:0:0:0:0:0:1]/", "http://[::]/",
            "http://[::ffff:127.0.0.1]:8765/",
        ] {
            XCTAssertFalse(FaviconRequests.allowsNetworkRequest(to: URL(string: address)!), address)
        }
        for address in ["https://example.com/favicon.ico", "http://127.example.com/favicon.ico",
                        "https://localhost.example/favicon.ico", "http://[2001:db8::1]/favicon.ico"] {
            XCTAssertTrue(FaviconRequests.allowsNetworkRequest(to: URL(string: address)!), address)
        }
    }
}


extension FaviconTests {
    func testURLSessionRedirectBoundaryRejectsLoopbackCallbackRequests() throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let icon = URL(string: "https://example.com/favicon.ico")!
        let task = session.dataTask(with: icon)
        let response = try XCTUnwrap(HTTPURLResponse(url: icon, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil))
        let policy = FaviconRedirectPolicy()
        for target in ["http://127.0.0.1:52815/?code=single-use", "http://localhost:52815/callback",
                       "http://[::1]:52815/callback"] {
            let redirect = URLRequest(url: URL(string: target)!)
            let accepted = FaviconRedirectResult(redirect)
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirect) { request in
                accepted.request.withLock { $0 = request }
            }
            XCTAssertNil(accepted.request.withLock { $0 }, target)
        }
        let publicRedirect = URLRequest(url: URL(string: "https://cdn.example.com/icon.png")!)
        let accepted = FaviconRedirectResult(nil)
        policy.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: publicRedirect) { request in
            accepted.request.withLock { $0 = request }
        }
        XCTAssertEqual(accepted.request.withLock { $0?.url }, publicRedirect.url)
    }
}


private final class FaviconRedirectResult: Sendable {
    let request: Mutex<URLRequest?>
    init(_ request: URLRequest?) { self.request = Mutex(request) }
}
