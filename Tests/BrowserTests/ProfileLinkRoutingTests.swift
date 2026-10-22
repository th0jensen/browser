import SwiftUI
import WebKit
import XCTest
@testable import Browser

@MainActor
final class ProfileLinkRoutingTests: XCTestCase {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ProfileRoutes-\(UUID())", directoryHint: .isDirectory)
    }

    private func fixture(_ directory: URL, durable: Bool = false) throws
        -> (profiles: BrowserProfileStore, spaces: BrowserSpaceStore, profile: BrowserProfileDescriptor, space: BrowserSpace) {
        let profiles = BrowserProfileStore(directory: directory, enabled: durable, disposableWebsiteData: true)
        let profile = try profiles.create(title: "Work Account")
        let spaces = BrowserSpaceStore(directory: directory, enabled: durable, profiles: profiles)
        let space = try spaces.createSpace(title: "Research", profileID: profile.id)
        return (profiles, spaces, profile, space)
    }

    private func rule(_ spaceID: UUID, host: String = "127.0.0.1") -> LinkRouteRule {
        LinkRouteRule(host: host, includesSubdomains: false, destinationSpaceID: spaceID)
    }

    func testNamedDestinationsCanBeCreatedEditedPersistedAndReloadedBesideLegacyRules() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try fixture(directory, durable: true)
        let second = try context.spaces.createSpace(title: "Planning", profileID: context.profile.id)
        let legacyID = UUID()
        let legacy: [[String: Any]] = [["id": legacyID.uuidString, "host": "legacy.example", "includesSubdomains": true,
                                       "destinationSpaceID": BrowserSpaceStore.defaultSpaceID.uuidString]]
        try JSONSerialization.data(withJSONObject: legacy).write(to: directory.appending(path: "LinkRoutes.json"))
        let rules = LinkRouteRuleStore(directory: directory)
        var named = rule(context.space.id)
        try rules.save(named, spaces: context.spaces)
        named.destinationSpaceID = second.id
        named.includesSubdomains = true
        try rules.save(named, spaces: context.spaces)
        let reloadedSpaces = BrowserSpaceStore(directory: directory)
        let reloaded = LinkRouteRuleStore(directory: directory)
        XCTAssertEqual(reloaded.rules.map(\.id), [legacyID, named.id])
        XCTAssertEqual(reloaded.rules.map(\.destinationSpaceID), [BrowserSpaceStore.defaultSpaceID, second.id])
        XCTAssertEqual(reloaded.rules[1], named)
        XCTAssertNil(reloaded.rules[0].sourceBundleID)
        let destination = LinkRouteDestination(spaceID: second.id, spaces: reloadedSpaces)
        XCTAssertTrue(destination.isAvailable)
        XCTAssertEqual(destination.profile, context.profile)
        XCTAssertEqual(destination.space?.profileID, context.profile.id)
        XCTAssertEqual(destination.label, "Work Account — Planning")
        XCTAssertFalse(context.profiles.hasLoadedResources(for: context.profile.id))
        XCTAssertFalse(reloadedSpaces.profiles.hasLoadedResources(for: context.profile.id))
    }

    func testListingLabelsSavingAndSettingsConstructionUseOnlyInjectedDescriptors() throws {
        let directory = root()
        let context = try fixture(directory)
        let secondProfile = try context.profiles.create(title: "Personal Account")
        let sameTitle = try context.spaces.createSpace(title: context.space.title, profileID: secondProfile.id)
        let rules = LinkRouteRuleStore(directory: directory, enabled: false)
        let destinations = LinkRouteDestination.all(in: context.spaces)
        XCTAssertEqual(destinations.map(\.id), [BrowserSpaceStore.defaultSpaceID, context.space.id, sameTitle.id])
        XCTAssertEqual(destinations.map(\.label), ["\(BrowserProfile.displayName) — Default", "Work Account — Research", "Personal Account — Research"])
        XCTAssertTrue(destinations.allSatisfy(\.isAvailable))
        XCTAssertTrue(destinations[1].identityDescription.contains(context.profile.id.uuidString))
        XCTAssertTrue(destinations[1].identityDescription.contains(context.space.id.uuidString))
        try rules.save(rule(context.space.id), spaces: context.spaces)
        let host = NSHostingView(rootView: LinkRoutingSettings(rules: rules, spaces: context.spaces))
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 600)
        host.layoutSubtreeIfNeeded()
        XCTAssertFalse(context.profiles.hasLoadedResources(for: context.profile.id))
        XCTAssertFalse(context.profiles.hasLoadedResources(for: secondProfile.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        // No BrowserModel or WebKit view is needed to enumerate, label, validate, or show these targets.
    }

    func testUnknownAndMismatchedProfileIDsNeverUseAnotherStoreOrDefaultDescriptor() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try fixture(directory, durable: true)
        let unrelatedProfiles = BrowserProfileStore(directory: root(), enabled: false)
        let sameName = try unrelatedProfiles.create(title: context.profile.title)
        let injectedSpaces = BrowserSpaceStore(directory: directory, profiles: unrelatedProfiles)
        let destination = LinkRouteDestination(spaceID: context.space.id, spaces: injectedSpaces)
        XCTAssertEqual(destination.availability, .missingProfile)
        XCTAssertNil(destination.profile)
        XCTAssertTrue(destination.label.contains(context.space.title))
        XCTAssertTrue(destination.label.contains(context.profile.id.uuidString))
        XCTAssertFalse(destination.label.contains(BrowserProfile.displayName))
        let rules = LinkRouteRuleStore(directory: directory, enabled: false)
        XCTAssertThrowsError(try rules.save(rule(context.space.id), spaces: injectedSpaces))
        XCTAssertTrue(rules.rules.isEmpty)
        XCTAssertFalse(unrelatedProfiles.hasLoadedResources(for: sameName.id))
        XCTAssertFalse(context.profiles.hasLoadedResources(for: context.profile.id))
    }

    func testMissingAndUnreadableProfileMetadataIsLabelledWithoutDefaultFallback() throws {
        for unreadable in [false, true] {
            let directory = root()
            defer { try? FileManager.default.removeItem(at: directory) }
            let context = try fixture(directory, durable: true)
            let profileFile = directory.appending(path: "Profiles.json")
            if unreadable { try Data("broken profile descriptors".utf8).write(to: profileFile) }
            else { try FileManager.default.removeItem(at: profileFile) }
            let spaces = BrowserSpaceStore(directory: directory)
            let destination = LinkRouteDestination(spaceID: context.space.id, spaces: spaces)
            XCTAssertEqual(destination.availability, unreadable ? .unreadableProfiles : .missingProfile)
            XCTAssertFalse(destination.isAvailable)
            XCTAssertNil(destination.profile)
            XCTAssertTrue(destination.label.contains(context.profile.id.uuidString))
            let rules = LinkRouteRuleStore(directory: directory, enabled: false)
            XCTAssertThrowsError(try rules.save(rule(context.space.id), spaces: spaces))
            if unreadable {
                XCTAssertFalse(LinkRouteDestination(spaceID: BrowserSpaceStore.defaultSpaceID, spaces: spaces).isAvailable,
                               "A recovery Default descriptor cannot validate an explicit route")
                XCTAssertEqual(try Data(contentsOf: profileFile), Data("broken profile descriptors".utf8))
            }
            XCTAssertFalse(spaces.profiles.hasLoadedResources(for: context.profile.id))
        }
    }

    func testMissingSpaceAndUnreadableSpaceMetadataDoNotListRecoveryDefault() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try fixture(directory, durable: true)
        let deletedID = UUID()
        let missing = LinkRouteDestination(spaceID: deletedID, spaces: context.spaces)
        XCTAssertEqual(missing.availability, .missingSpace)
        XCTAssertTrue(missing.label.contains(deletedID.uuidString))
        XCTAssertNil(missing.space)
        let file = directory.appending(path: "Spaces.json")
        let bytes = Data("broken Space descriptors".utf8)
        try bytes.write(to: file)
        let spaces = BrowserSpaceStore(directory: directory, profiles: context.profiles)
        XCTAssertTrue(spaces.loadFailed)
        XCTAssertTrue(LinkRouteDestination.all(in: spaces).isEmpty)
        let recoveryDefault = LinkRouteDestination(spaceID: BrowserSpaceStore.defaultSpaceID, spaces: spaces)
        XCTAssertEqual(recoveryDefault.availability, .unreadableSpaces)
        XCTAssertNil(recoveryDefault.space)
        let rules = LinkRouteRuleStore(directory: directory, enabled: false)
        XCTAssertThrowsError(try rules.save(rule(BrowserSpaceStore.defaultSpaceID), spaces: spaces))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        XCTAssertFalse(context.profiles.hasLoadedResources(for: context.profile.id))
    }

    func testRoutingSwitchesFrontWindowBetweenDefaultAndNamedProfilesBeforeOpeningOriginalURLOnce() throws {
        for startsNamed in [false, true] {
            let context = try fixture(root())
            let defaultStore = WKWebsiteDataStore.nonPersistent()
            let front = BrowserModel(websiteDataStore: defaultStore, spaces: context.spaces)
            let back = BrowserModel(spaces: context.spaces)
            let destinationID = startsNamed ? BrowserSpaceStore.defaultSpaceID : context.space.id
            let expectedProfileID = startsNamed ? BrowserProfile.defaultID : context.profile.id
            if startsNamed { XCTAssertTrue(front.selectSpace(context.space.id)) }
            else { XCTAssertTrue(back.selectSpace(context.space.id)) }
            let background = try XCTUnwrap(front.activeTab)
            let rules = LinkRouteRuleStore(directory: root(), enabled: false)
            try rules.save(rule(destinationID), spaces: context.spaces)
            let incoming = URL(string: "\(startsNamed ? "https" : "http")://127.0.0.1:9/Keep/Case?Key=VaLue%2FMore#Part")!
            var opened: [URL] = []
            var activations = 0
            let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { target in
                XCTAssertTrue(target === front)
                activations += 1
            }, openTabs: { target, urls in
                XCTAssertTrue(target === front, "The first ordinary window can switch profiles; do not select a back window by current profile")
                XCTAssertEqual(target.activeSpaceID, destinationID)
                XCTAssertEqual(target.profileID, expectedProfileID)
                XCTAssertEqual(urls.map(\.absoluteString), [incoming.absoluteString])
                target.openInNewTabs(urls)
                opened += urls
            })
            defer { (front.allTabs + back.allTabs).forEach { $0.stopLoading() } }
            router.register(front)
            router.register(back)
            router.open([incoming])
            router.register(front)
            XCTAssertEqual(opened, [incoming])
            XCTAssertEqual(activations, 1)
            let loaded = try XCTUnwrap(front.activeTab)
            XCTAssertEqual(loaded.spaceID, destinationID)
            XCTAssertEqual(loaded.profileID, expectedProfileID)
            XCTAssertEqual(loaded.url?.scheme, incoming.scheme)
            XCTAssertEqual(loaded.url?.port, incoming.port)
            XCTAssertEqual(loaded.url?.path, incoming.path)
            XCTAssertEqual(loaded.url?.query, incoming.query)
            let loadedStore = try XCTUnwrap(loaded.webView?.configuration.websiteDataStore)
            XCTAssertTrue(loadedStore === front.websiteDataStore(forProfileID: expectedProfileID))
            XCTAssertEqual(loadedStore === defaultStore, startsNamed)
            XCTAssertTrue(front.tabAcrossSpaces(withID: background.id) === background)
            XCTAssertNil(background.webView)
            XCTAssertEqual(front.addressFocusRequest, front.consumedAddressFocusRequest)
        }
    }

    func testMixedBatchReturnsUnmatchedLinksAndFilesToOriginalNamedProfile() throws {
        let context = try fixture(root())
        let front = BrowserModel(spaces: context.spaces)
        XCTAssertTrue(front.selectSpace(context.space.id))
        let originalTab = try XCTUnwrap(front.activeTab)
        let rules = LinkRouteRuleStore(directory: root(), enabled: false)
        try rules.save(rule(BrowserSpaceStore.defaultSpaceID), spaces: context.spaces)
        let incoming = URL(string: "http://127.0.0.1:9/Keep?Key=Value")!
        let unmatched = URL(string: "https://unmatched.invalid:8443/Other?Q=V")!
        let file = URL(filePath: "/tmp/routing-profile-fixture.html")
        var opened: [URL] = []
        var selected: [UUID] = []
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, urls in
            selected.append(target.profileID)
            opened += urls
        })
        router.register(front)
        router.open([incoming, unmatched, file])
        XCTAssertEqual(opened, [incoming, unmatched, file])
        XCTAssertEqual(selected, [BrowserProfile.defaultID, context.profile.id, context.profile.id])
        XCTAssertTrue(front.activeTab === originalTab)
        XCTAssertTrue(front.allTabs.allSatisfy { $0.webView == nil })
    }

    func testUnavailableFirstNamedRuleUsesCurrentNamedFallbackAndDoesNotTryLaterDefaultRule() throws {
        let directory = root()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try fixture(directory, durable: true)
        let retainedProfile = try context.profiles.create(title: "Current Account")
        let retainedSpace = try context.spaces.createSpace(title: "Current", profileID: retainedProfile.id)
        let rules = LinkRouteRuleStore(directory: directory)
        try rules.save(rule(context.space.id), spaces: context.spaces)
        try rules.save(rule(BrowserSpaceStore.defaultSpaceID), spaces: context.spaces)
        let existing = try XCTUnwrap(context.profiles.profile(BrowserProfile.defaultID))
        try JSONEncoder().encode([existing, retainedProfile]).write(to: directory.appending(path: "Profiles.json"))
        let current = BrowserSpaceStore(directory: directory)
        let browser = BrowserModel(spaces: current)
        XCTAssertTrue(browser.selectSpace(retainedSpace.id))
        var opened = 0
        let incoming = URL(string: "http://127.0.0.1:9/Path?Query=Original")!
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { $0 }, activate: { _ in }, openTabs: { target, urls in
            XCTAssertEqual(target.activeSpaceID, retainedSpace.id)
            XCTAssertEqual(target.profileID, retainedProfile.id)
            XCTAssertEqual(urls, [incoming])
            opened += 1
        })
        let privateBrowser = BrowserModel(isPrivate: true)
        router.register(privateBrowser)
        router.open([incoming])
        XCTAssertEqual(opened, 0)
        router.register(browser)
        router.register(browser)
        XCTAssertEqual(opened, 1)
        XCTAssertTrue(privateBrowser.isBlank)
        XCTAssertFalse(current.profiles.hasLoadedResources(for: context.profile.id))
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
    }

    func testNamedLaunchQueueWaitsThroughPrivateOnlyAndClosedWindowsAndOpensOnce() throws {
        let context = try fixture(root())
        let rules = LinkRouteRuleStore(directory: root(), enabled: false)
        try rules.save(rule(context.space.id), spaces: context.spaces)
        var requests = 0
        var opened: [URL] = []
        let incoming = URL(string: "http://127.0.0.1:9/Original?Q=V")!
        let router = ExternalURLRouter(rules: rules, requestWindow: { requests += 1 }, orderBrowsers: { $0 },
                                       activate: { _ in XCTFail("Queued registration must not activate desktop windows") }, openTabs: { target, urls in
            XCTAssertEqual(target.activeSpaceID, context.space.id)
            XCTAssertEqual(target.profileID, context.profile.id)
            XCTAssertTrue(context.profiles.hasLoadedResources(for: context.profile.id))
            opened += urls
        })
        let privateBrowser = BrowserModel(isPrivate: true, spaces: context.spaces)
        let extensionBrowser = BrowserModel(spaces: context.spaces)
        extensionBrowser.isExtensionWindow = true
        router.register(privateBrowser)
        router.register(extensionBrowser)
        router.open([incoming])
        XCTAssertEqual(requests, 1)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(context.profiles.hasLoadedResources(for: context.profile.id))
        let closed = BrowserModel(spaces: context.spaces)
        closed.windowDidClose()
        router.register(closed)
        XCTAssertEqual(requests, 2)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertFalse(context.profiles.hasLoadedResources(for: context.profile.id))
        let normal = BrowserModel(spaces: context.spaces)
        router.register(normal)
        router.register(normal)
        router.register(closed)
        XCTAssertEqual(opened, [incoming])
        XCTAssertTrue(privateBrowser.isBlank)
        XCTAssertEqual(privateBrowser.profileID, BrowserProfile.defaultID)
        XCTAssertTrue(extensionBrowser.isBlank)
        XCTAssertTrue(closed.isBlank)
    }

    func testNamedRouteCloseRaceSkipsClosedFrontAndSwitchesNextLiveWindow() throws {
        let context = try fixture(root())
        let front = BrowserModel(spaces: context.spaces)
        let back = BrowserModel(spaces: context.spaces)
        let rules = LinkRouteRuleStore(directory: root(), enabled: false)
        try rules.save(rule(context.space.id), spaces: context.spaces)
        var shouldClose = false
        var opened = 0
        let router = ExternalURLRouter(rules: rules, orderBrowsers: { browsers in
            if shouldClose { front.windowDidClose() }
            return browsers
        }, activate: { _ in }, openTabs: { target, _ in
            XCTAssertTrue(target === back)
            XCTAssertEqual(target.activeSpaceID, context.space.id)
            XCTAssertEqual(target.profileID, context.profile.id)
            opened += 1
        })
        router.register(front)
        router.register(back)
        shouldClose = true
        router.open([URL(string: "http://127.0.0.1:9/race")!])
        router.register(front)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(front.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
    }
}
