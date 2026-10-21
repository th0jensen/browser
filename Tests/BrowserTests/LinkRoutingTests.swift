import XCTest
@testable import Browser

@MainActor
final class LinkRoutingTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "BrowserRoutes-\(UUID())", directoryHint: .isDirectory)
    }

    private func store() -> LinkRouteRuleStore { LinkRouteRuleStore(directory: directory(), enabled: false) }
    private func spaces() -> BrowserSpaceStore { BrowserSpaceStore(directory: directory(), enabled: false) }
    private let url = URL(string: "https://example.com/Path?Key=Value")!

    func testExactCaseTrailingDotAndIDNHosts() {
        let exact = LinkRouteRule(host: "Example.COM.", includesSubdomains: false, destinationSpaceID: UUID())
        XCTAssertTrue(exact.matches(URL(string: "HTTPS://EXAMPLE.COM.:8443/Keep/Case?Q=V#F")!))
        XCTAssertFalse(exact.matches(URL(string: "https://www.example.com")!))
        let idn = LinkRouteRule(host: "BÜCHER.example.", includesSubdomains: true, destinationSpaceID: UUID())
        XCTAssertEqual(LinkRouteRule.normalizedHost(idn.host), "xn--bcher-kva.example")
        XCTAssertTrue(idn.matches(URL(string: "https://xn--bcher-kva.example")!))
        XCTAssertTrue(idn.matches(URL(string: "https://shop.bücher.example.")!))
    }

    func testSubdomainsRequireALabelBoundaryAndNeverMatchURLSubstrings() {
        let rule = LinkRouteRule(host: "example.com", includesSubdomains: true, destinationSpaceID: UUID())
        for value in ["https://example.com", "https://a.b.example.com"] {
            XCTAssertTrue(rule.matches(URL(string: value)!), value)
        }
        for value in ["https://example.com.evil.test", "https://notexample.com", "https://evil.test/example.com",
                      "https://evil.test/?host=example.com", "https://example.com@evil.test",
                      "file:///example.com", "javascript:example.com", "data:text/plain,example.com"] {
            XCTAssertFalse(rule.matches(URL(string: value)!), value)
        }
    }

    func testRuleInputRejectsURLsPortsCredentialsWildcardsAndUnsafeSchemes() throws {
        let rules = store()
        let spaces = spaces()
        for host in ["", "https://example.com", "javascript:example.com", "file:///tmp/a", "example.com/path",
                     "example.com:443", "user@example.com", "*.example.com", "example.com?x=y", "example.com#x",
                     "example%2ecom", "example..com", "example.com..", "-example.com", "example .com"] {
            XCTAssertNil(LinkRouteRule.normalizedHost(host), host)
            XCTAssertThrowsError(try rules.save(LinkRouteRule(host: host, includesSubdomains: false,
                                                             destinationSpaceID: BrowserSpaceStore.defaultSpaceID), spaces: spaces), host)
        }
        XCTAssertTrue(rules.rules.isEmpty)
        XCTAssertThrowsError(try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: false,
                                                         destinationSpaceID: UUID()), spaces: spaces))
    }

    func testSourceConditionsRequireVerifiedIdentityAndProductionDoesNotGuessIt() throws {
        let rules = store()
        let spaces = spaces()
        let specific = LinkRouteRule(host: "example.com", includesSubdomains: false,
                                     destinationSpaceID: BrowserSpaceStore.defaultSpaceID, sourceBundleID: "com.example.mail")
        try rules.save(specific, spaces: spaces)
        XCTAssertFalse(specific.matches(url))
        XCTAssertFalse(specific.matches(url, verifiedSourceBundleID: "com.example.other"))
        XCTAssertTrue(specific.matches(url, verifiedSourceBundleID: "com.example.mail"))
        XCTAssertNil(rules.firstMatch(for: url))
        let generic = LinkRouteRule(host: "example.com", includesSubdomains: false,
                                    destinationSpaceID: BrowserSpaceStore.defaultSpaceID)
        try rules.save(generic, spaces: spaces)
        XCTAssertEqual(rules.firstMatch(for: url)?.id, generic.id)
    }

    func testRulesPersistInExplicitOrderAndCanBeEditedMovedAndDeleted() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let spaces = spaces()
        let other = try spaces.createSpace(title: "Work")
        let rules = LinkRouteRuleStore(directory: root)
        let broad = LinkRouteRule(host: "EXAMPLE.COM.", includesSubdomains: true, destinationSpaceID: other.id)
        var exact = LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: BrowserSpaceStore.defaultSpaceID)
        try rules.save(broad, spaces: spaces)
        try rules.save(exact, spaces: spaces)
        XCTAssertEqual(rules.firstMatch(for: url)?.id, broad.id)
        try rules.move(exact.id, by: -1)
        XCTAssertEqual(rules.firstMatch(for: url)?.id, exact.id)
        exact.includesSubdomains = true
        try rules.save(exact, spaces: spaces)
        let reopened = LinkRouteRuleStore(directory: root)
        XCTAssertEqual(reopened.rules.map(\.id), [exact.id, broad.id])
        XCTAssertEqual(reopened.rules.last?.host, "example.com")
        XCTAssertTrue(reopened.rules[0].includesSubdomains)
        try reopened.remove(exact.id)
        XCTAssertEqual(LinkRouteRuleStore(directory: root).rules.map(\.id), [broad.id])
        let attributes = try FileManager.default.attributesOfItem(atPath: root.appending(path: "LinkRoutes.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testUnreadableRulesAndWriteFailureNeverPublishOrOverwrite() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appending(path: "LinkRoutes.json")
        let bytes = Data("broken rules".utf8)
        try bytes.write(to: file)
        let rules = LinkRouteRuleStore(directory: root)
        XCTAssertTrue(rules.loadFailed)
        XCTAssertNil(rules.firstMatch(for: url))
        XCTAssertThrowsError(try rules.remove(UUID()))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let blocked = directory()
        defer { try? FileManager.default.removeItem(at: blocked) }
        try bytes.write(to: blocked)
        let unwritable = LinkRouteRuleStore(directory: blocked)
        XCTAssertThrowsError(try unwritable.save(LinkRouteRule(host: "example.com", includesSubdomains: false,
                                                              destinationSpaceID: BrowserSpaceStore.defaultSpaceID), spaces: spaces()))
        XCTAssertTrue(unwritable.rules.isEmpty)
    }

    func testRoutesSelectSpaceBeforeOpeningOnceAndKeepTheWholeURL() throws {
        let spaces = spaces()
        let work = try spaces.createSpace(title: "Work")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: work.id), spaces: spaces)
        let browser = BrowserModel(spaces: spaces)
        let incoming = URL(string: "http://EXAMPLE.com:8080/Keep/Case?Key=VaLue#Part")!
        var opens = 0
        var activations = 0
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { target in
            XCTAssertTrue(target === browser)
            activations += 1
        }, openTabs: { target, urls in
            XCTAssertEqual(target.activeSpaceID, work.id)
            XCTAssertEqual(urls, [incoming])
            opens += 1
            target.openInNewTabs(urls)
        })
        defer { browser.allTabs.forEach { $0.stopLoading() } }
        router.register(browser)
        router.open([incoming])
        router.register(browser)
        XCTAssertEqual(browser.tabs.count, 1)
        // WebKit canonicalizes host case. The router callback above must receive the untouched URL.
        let loaded = try XCTUnwrap(browser.tabs.first?.url)
        XCTAssertEqual(loaded.scheme, incoming.scheme)
        XCTAssertEqual(loaded.port, incoming.port)
        XCTAssertEqual(loaded.path, incoming.path)
        XCTAssertEqual(loaded.query, incoming.query)
        XCTAssertEqual(loaded.fragment, incoming.fragment)
        XCTAssertEqual(browser.tabs.first?.spaceID, work.id)
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(activations, 1)
    }

    func testMixedBatchRestoresOrdinarySpaceForUnmatchedLinksAndFiles() throws {
        let spaces = spaces()
        let work = try spaces.createSpace(title: "Work")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: work.id), spaces: spaces)
        let browser = BrowserModel(spaces: spaces)
        let unmatched = URL(string: "https://elsewhere.test/Path?K=V")!
        let file = URL(filePath: "/tmp/page.html")
        var opened: [URL] = []
        var selected: [UUID] = []
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, urls in
            opened += urls
            selected.append(target.activeSpaceID)
        })
        router.register(browser)
        router.open([url, unmatched, file, URL(string: "javascript:void(0)")!])
        XCTAssertEqual(opened, [url, unmatched, file])
        XCTAssertEqual(selected, [work.id, BrowserSpaceStore.defaultSpaceID, BrowserSpaceStore.defaultSpaceID])
    }

    func testAbsentSourceRuleDoesNotSelectItsDestination() throws {
        let spaces = spaces()
        let work = try spaces.createSpace(title: "Work")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: true, destinationSpaceID: work.id,
                                     sourceBundleID: "com.example.mail"), spaces: spaces)
        let browser = BrowserModel(spaces: spaces)
        var opens = 0
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, _ in
            XCTAssertEqual(target.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
            opens += 1
        })
        router.register(browser)
        router.open([url])
        XCTAssertEqual(opens, 1)
    }

    func testDeletedDestinationFallsBackWithoutTryingTheNextRule() throws {
        let oldSpaces = spaces()
        let deleted = try oldSpaces.createSpace(title: "Deleted")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: true, destinationSpaceID: deleted.id), spaces: oldSpaces)
        let currentSpaces = spaces()
        let other = try currentSpaces.createSpace(title: "Do not choose")
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: other.id), spaces: currentSpaces)
        let browser = BrowserModel(spaces: currentSpaces)
        var opens = 0
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, _ in
            XCTAssertTrue(target === browser)
            XCTAssertEqual(target.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
            opens += 1
        })
        router.register(browser)
        router.open([url])
        XCTAssertEqual(opens, 1)
    }

    func testForeignProfileDestinationUsesFrontOrdinaryFallback() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let foreignID = UUID()
        let foreign = BrowserSpace(id: foreignID, title: "Foreign", profileID: UUID())
        try JSONEncoder().encode([foreign]).write(to: root.appending(path: "Spaces.json"))
        let rule = LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: foreignID)
        try JSONEncoder().encode([rule]).write(to: root.appending(path: "LinkRoutes.json"))
        let rules = LinkRouteRuleStore(directory: root)
        let browser = BrowserModel(spaces: BrowserSpaceStore(directory: root))
        var opens = 0
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, _ in
            XCTAssertEqual(target.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
            opens += 1
        })
        router.register(browser)
        router.open([url])
        XCTAssertEqual(opens, 1)
    }

    func testQueueWaitsThroughPrivateExtensionAndClosedRegistrationsThenOpensOnce() throws {
        let spaces = spaces()
        let work = try spaces.createSpace(title: "Work")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: work.id), spaces: spaces)
        var requests = 0
        var opened: [URL] = []
        let router = ExternalURLRouter(rules: rules, requestWindow: { requests += 1 }, orderBrowsers: { $0 },
                                       activate: { _ in XCTFail("Registration must not activate a desktop window") }, openTabs: { target, urls in
            XCTAssertEqual(target.activeSpaceID, work.id)
            opened += urls
        })
        let privateBrowser = BrowserModel(isPrivate: true)
        let extensionBrowser = BrowserModel()
        extensionBrowser.isExtensionWindow = true
        router.register(privateBrowser)
        router.register(extensionBrowser)
        router.open([url])
        router.open([url]) // Two separate requests are two opens, not a URL-based deduplication.
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(opened.isEmpty)
        let closed = BrowserModel(spaces: spaces)
        closed.windowDidClose()
        router.register(closed)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(opened.isEmpty)
        let browser = BrowserModel(spaces: spaces)
        router.register(browser)
        router.register(browser)
        router.unregister(browser)
        router.register(BrowserModel(spaces: spaces))
        XCTAssertEqual(opened, [url, url])
        XCTAssertTrue(privateBrowser.isBlank)
        XCTAssertTrue(extensionBrowser.isBlank)
        XCTAssertTrue(closed.isBlank)
    }

    func testLaunchBeforeWindowActionAndRestorationAppendExactlyOnce() throws {
        let browser = BrowserModel()
        let saved = URL(string: "https://saved.test/existing")!
        browser.restoreSession(WindowSession(tabs: [TabSession(url: saved, title: "Saved", interactionState: nil)], selectedIndex: 0))
        let router = ExternalURLRouter(rules: store(), orderBrowsers: { $0 }, activate: { _ in })
        defer { browser.allTabs.forEach { $0.stopLoading() } }
        router.open([url])
        router.register(browser)
        router.register(browser)
        XCTAssertEqual(browser.tabs.compactMap(\.url), [saved, url])
    }

    func testCloseRaceAfterWindowOrderingUsesAnotherLiveWindow() {
        let first = BrowserModel()
        let second = BrowserModel()
        var closeFirst = false
        var openedIn: [BrowserModel] = []
        let router = ExternalURLRouter(rules: store(), orderBrowsers: { browsers in
            if closeFirst { first.windowDidClose() }
            return browsers
        }, activate: { _ in }, openTabs: { target, _ in openedIn.append(target) })
        router.register(first)
        router.register(second)
        closeFirst = true
        router.open([url])
        XCTAssertEqual(openedIn.count, 1)
        XCTAssertTrue(openedIn.first === second)
        router.unregister(second)
        router.open([url])
        router.register(first) // A late closed-window callback cannot consume the pending URL.
        XCTAssertEqual(openedIn.count, 1)
        closeFirst = false
        let replacement = BrowserModel()
        router.register(replacement)
        XCTAssertEqual(openedIn.count, 2)
        XCTAssertTrue(openedIn.last === replacement)
    }

    func testDestinationUsesFirstEligibleWindowAndRulePrecedence() throws {
        let spaces = spaces()
        let work = try spaces.createSpace(title: "Work")
        let secondSpace = try spaces.createSpace(title: "Later")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: true, destinationSpaceID: work.id), spaces: spaces)
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: false, destinationSpaceID: secondSpace.id), spaces: spaces)
        let back = BrowserModel(spaces: spaces)
        let front = BrowserModel(spaces: spaces)
        let privateBrowser = BrowserModel(isPrivate: true)
        var opened: [BrowserModel] = []
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0.reversed() }, activate: { _ in }, openTabs: { target, _ in
            XCTAssertEqual(target.activeSpaceID, work.id)
            opened.append(target)
        })
        router.register(back)
        router.register(front)
        router.register(privateBrowser)
        router.open([url])
        XCTAssertEqual(opened.count, 1)
        XCTAssertTrue(opened.first === front)
        XCTAssertEqual(back.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
    }

    func testUnmatchedSuffixAttackKeepsFrontWindowsSelectedSpaceAndOriginalURL() throws {
        let spaces = spaces()
        let personal = try spaces.createSpace(title: "Personal")
        let work = try spaces.createSpace(title: "Work")
        let rules = store()
        try rules.save(LinkRouteRule(host: "example.com", includesSubdomains: true, destinationSpaceID: work.id), spaces: spaces)
        let back = BrowserModel(spaces: spaces)
        let front = BrowserModel(spaces: spaces)
        front.selectSpace(personal.id)
        let attack = URL(string: "https://example.com.evil.test:8443/Example.COM?Next=https://example.com")!
        var opened: [URL] = []
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0.reversed() }, activate: { _ in }, openTabs: { target, urls in
            XCTAssertTrue(target === front)
            XCTAssertEqual(target.activeSpaceID, personal.id)
            opened += urls
        })
        router.register(back)
        router.register(front)
        router.open([attack])
        XCTAssertEqual(opened, [attack])
        XCTAssertEqual(back.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
    }

    func testReentrantRegistrationAndOpenCannotReplayAConsumedURL() {
        let browser = BrowserModel()
        var opened: [URL] = []
        var router: ExternalURLRouter!
        let next = URL(string: "https://second.test")!
        router = ExternalURLRouter(rules: store(), orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, urls in
            opened += urls
            router.register(target)
            if urls == [self.url] { router.open([next]) }
        })
        router.register(browser)
        router.open([url])
        XCTAssertEqual(opened, [url, next])
    }
}
