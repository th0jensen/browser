import WebKit
import XCTest
@testable import Browser

@MainActor
final class ContentBlockingTests: XCTestCase {
    private func matches(_ filter: String, _ address: String) throws -> Bool {
        let expression = try NSRegularExpression(pattern: filter)
        return expression.firstMatch(in: address, range: NSRange(address.startIndex..., in: address)) != nil
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "dev.athas.browser.tests.content-blocker"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDomainFiltersMatchTheDomainAndItsSubdomainsOnly() throws {
        let filter = TrackerBlocklist.urlFilter(forDomain: "doubleclick.net")

        XCTAssertTrue(try matches(filter, "https://doubleclick.net/ad.js"))
        XCTAssertTrue(try matches(filter, "https://securepubads.g.doubleclick.net/tag/js/gpt.js"))
        XCTAssertTrue(try matches(filter, "http://ad.doubleclick.net:8080/pixel"))
        XCTAssertFalse(try matches(filter, "https://notdoubleclick.net/"))
        XCTAssertFalse(try matches(filter, "https://doubleclick.net.example.com/"))
        XCTAssertFalse(try matches(filter, "https://example.com/?ref=doubleclick.net/"))
    }

    func testFacebookPixelFiltersKeepTheTrackingEndpointBoundary() throws {
        for address in ["https://www.facebook.com/tr", "https://facebook.com/tr?id=1", "https://facebook.com/tr/pixel"] {
            XCTAssertTrue(try TrackerBlocklist.urlFilters.contains { try matches($0, address) }, address)
        }
        for address in ["https://facebook.com/tracking", "https://example.com/tr", "https://facebook.com.example.org/tr"] {
            XCTAssertFalse(try TrackerBlocklist.urlFilters.contains { try matches($0, address) }, address)
        }
    }

    func testRulesBlockTrackersOnlyWhenAnotherSiteLoadsThem() {
        let rules = TrackerBlocklist.rules()

        XCTAssertEqual(rules.count, Set(TrackerBlocklist.domains).count + TrackerBlocklist.urlFilters.count)
        XCTAssertEqual(Set(rules.map(\.urlFilter)).count, rules.count, "Duplicate rules")
        XCTAssertTrue(rules.allSatisfy { $0.action.type == "block" && $0.trigger.loadType == ["third-party"] })
        XCTAssertTrue(TrackerBlocklist.domains.allSatisfy { $0 == $0.lowercased() && !$0.contains("/") })
    }

    func testExceptionsTurnBlockingOffLast() throws {
        let rules = TrackerBlocklist.rules(exceptions: ["Example.com", "news.site"])
        let last = try XCTUnwrap(rules.last)

        XCTAssertEqual(last.action.type, "ignore-previous-rules")
        XCTAssertEqual(last.trigger.urlFilter, ".*")
        XCTAssertEqual(last.trigger.ifDomain, ["*example.com", "*news.site"])
        XCTAssertEqual(rules.count, TrackerBlocklist.rules().count + 1)
    }

    func testEncodedRulesUseWebKitsKeys() throws {
        let json = TrackerBlocklist.encodedRules(exceptions: ["example.com"])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: [String: Any]]])

        XCTAssertNotNil(rules.first?["trigger"]?["url-filter"])
        XCTAssertEqual(rules.first?["trigger"]?["load-type"] as? [String], ["third-party"])
        XCTAssertEqual(rules.last?["trigger"]?["if-domain"] as? [String], ["*example.com"])
        XCTAssertNil(rules.first?["trigger"]?["if-domain"])
    }

    func testBlockingCanBeTurnedOffForASiteAndItsSubdomains() async {
        let defaults = makeDefaults()
        let blocker = ContentBlocker(defaults: defaults)
        XCTAssertTrue(blocker.isEnabled)
        XCTAssertTrue(blocker.isBlocking(on: "www.example.com"))

        await blocker.setBlocking(false, on: "www.Example.com")

        XCTAssertEqual(blocker.exceptions, ["example.com"])
        XCTAssertFalse(blocker.isBlocking(on: "example.com"))
        XCTAssertFalse(blocker.isBlocking(on: "news.example.com"))
        XCTAssertTrue(blocker.isBlocking(on: "example.org"))
        XCTAssertTrue(blocker.isBlocking(on: "notexample.com"))

        let relaunched = ContentBlocker(defaults: defaults)
        XCTAssertEqual(relaunched.exceptions, ["example.com"])

        await relaunched.setBlocking(true, on: "news.example.com")
        XCTAssertTrue(relaunched.exceptions.isEmpty)
    }

    func testBuiltInProtectionPreservesExtensionRulesDuringUpdatesAndToggles() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let compiled = try await store.compileContentRuleList(forIdentifier: "ExtensionRules",
            encodedContentRuleList: #"[{"trigger":{"url-filter":"example.com"},"action":{"type":"block"}}]"#)
        let foreign = try XCTUnwrap(compiled)
        let controller = RecordingRuleController()
        controller.add(foreign)
        let blocker = ContentBlocker(store: store)
        blocker.attach(controller)
        await blocker.prepare()

        XCTAssertTrue(blocker.isReady, blocker.lastError ?? "Rules never became ready")
        XCTAssertTrue(blocker.isPreparedForNavigation)
        XCTAssertEqual(controller.identifiers, ["ExtensionRules", "Trackers"])
        let additions = controller.additions
        blocker.attach(controller)
        blocker.setEnabled(true)
        await blocker.prepare()
        XCTAssertEqual(controller.additions, additions, "Repeated attachment must not reinstall the current list")
        XCTAssertTrue(controller.removals.isEmpty)
        blocker.setEnabled(false)
        XCTAssertEqual(controller.identifiers, ["ExtensionRules"])
        blocker.setEnabled(true)
        XCTAssertEqual(controller.identifiers, ["ExtensionRules", "Trackers"])
        await blocker.setBlocking(false, on: "example.org")
        XCTAssertTrue(blocker.isReady)
        XCTAssertEqual(controller.identifiers, ["ExtensionRules", "Trackers"])
        XCTAssertEqual(controller.removeAllCalls, 0)
    }

    func testTurningBlockingOffEverywhere() {
        let defaults = makeDefaults()
        let blocker = ContentBlocker(defaults: defaults)

        blocker.setEnabled(false)

        XCTAssertFalse(blocker.isBlocking(on: "example.com"))
        XCTAssertFalse(ContentBlocker(defaults: defaults).isEnabled)
    }

    func testPreparationWaitsForCurrentExceptionsAndNeverInstallsSupersededRules() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        let gate = TrackerRuleCompilationGate()
        defer { gate.resumeAll() }
        let controller = RecordingRuleController()
        var compiledRules: [String] = []
        let blocker = ContentBlocker(store: store, ruleListCompiler: { identifier, rules in
            compiledRules.append(rules)
            await gate.pause()
            return try await store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules)
        })
        blocker.attach(controller)
        try await gate.waitUntil { gate.requests == 1 }
        XCTAssertFalse(blocker.isPreparedForNavigation)
        var prepared = false
        let preparation = Task {
            await blocker.prepare()
            prepared = true
        }

        let firstChange = Task { await blocker.setBlocking(false, on: "first.example") }
        try await gate.waitUntil { blocker.exceptions.contains("first.example") }
        gate.resumeNext()
        try await gate.waitUntil { gate.requests == 2 }
        XCTAssertTrue(controller.additions.isEmpty, "The initial rules were superseded while compiling")
        XCTAssertFalse(prepared, "Navigation must wait for the current exceptions")
        XCTAssertFalse(blocker.isPreparedForNavigation)

        let secondChange = Task { await blocker.setBlocking(false, on: "second.example") }
        try await gate.waitUntil { blocker.exceptions.contains("second.example") }
        gate.resumeNext()
        try await gate.waitUntil { gate.requests == 3 }
        XCTAssertTrue(controller.additions.isEmpty, "A second superseded compilation must not replace protection")
        XCTAssertFalse(prepared)
        gate.resumeNext()
        await firstChange.value
        await secondChange.value
        await preparation.value

        XCTAssertTrue(prepared)
        XCTAssertTrue(blocker.isReady)
        XCTAssertTrue(blocker.isPreparedForNavigation)
        XCTAssertFalse(blocker.isUpdating)
        XCTAssertNil(blocker.lastError)
        XCTAssertEqual(controller.additions, ["Trackers"])
        XCTAssertTrue(try XCTUnwrap(compiledRules.last).contains("*first.example"))
        XCTAssertTrue(try XCTUnwrap(compiledRules.last).contains("*second.example"))
    }

    func testPreparationReportsCompilationFailureWithoutRetryingForever() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(WKContentRuleListStore(url: directory))
        var attempts = 0
        let blocker = ContentBlocker(store: store, ruleListCompiler: { _, _ in
            attempts += 1
            throw NSError(domain: "TrackerRuleCompiler", code: 1, userInfo: [NSLocalizedDescriptionKey: "Controlled compilation failure"])
        })

        await blocker.prepare()
        XCTAssertEqual(attempts, 1)
        XCTAssertFalse(blocker.isReady)
        XCTAssertFalse(blocker.isPreparedForNavigation)
        XCTAssertFalse(blocker.isUpdating)
        XCTAssertTrue(blocker.lastError?.contains("Controlled compilation failure") == true)
        await blocker.prepare()
        XCTAssertEqual(attempts, 2, "A later request may retry once after the previous attempt failed")
        XCTAssertFalse(blocker.isReady)
    }
}

private extension TrackerBlocklist.Rule {
    var urlFilter: String { trigger.urlFilter }
}

@MainActor
private final class RecordingRuleController: WKUserContentController {
    private(set) var identifiers: Set<String> = []
    private(set) var removeAllCalls = 0
    private(set) var additions: [String] = []
    private(set) var removals: [String] = []

    override func add(_ contentRuleList: WKContentRuleList) {
        additions.append(contentRuleList.identifier)
        identifiers.insert(contentRuleList.identifier)
        super.add(contentRuleList)
    }

    override func remove(_ contentRuleList: WKContentRuleList) {
        removals.append(contentRuleList.identifier)
        identifiers.remove(contentRuleList.identifier)
        super.remove(contentRuleList)
    }

    override func removeAllContentRuleLists() {
        removeAllCalls += 1
        identifiers = []
        super.removeAllContentRuleLists()
    }
}

@MainActor
private final class TrackerRuleCompilationGate {
    private(set) var requests = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw NSError(domain: "TrackerRuleCompilationGate", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for a tracker rule update"])
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func pause() async {
        requests += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeNext() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }

    func resumeAll() {
        isOpen = true
        let current = waiters
        waiters = []
        current.forEach { $0.resume() }
    }
}
