import AppKit
import WebKit
import XCTest
@testable import Browser

@MainActor
final class ProfileSpacePresentationTests: XCTestCase {
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "ProfileSpacePresentation-\(UUID())", directoryHint: .isDirectory)
    }

    func testProfileOwnershipAndSharedAppearanceSurviveCreateEditReloadAndRouteLookup() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfileStore(directory: root, disposableWebsiteData: true)
        let owner = try profiles.create(title: "Work")
        let spaces = BrowserSpaceStore(directory: root, profiles: profiles)
        let browser = BrowserModel(websiteDataStore: .nonPersistent(), spaces: spaces)
        let space = try browser.createSpace(title: "Research", profileID: owner.id, icon: .book,
                                            theme: .purple, symbol: "leaf", emoji: "🦊", color: .blue)
        XCTAssertEqual(browser.profileID, owner.id)
        XCTAssertEqual(browser.activeSpaceID, space.id)
        XCTAssertEqual(space.profileID, owner.id)
        XCTAssertEqual(space.emoji, "🦊")
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        try spaces.updateSpace(space.id, title: "Planning", icon: .book, theme: .purple,
                               symbol: "leaf", emoji: "", color: .blue)
        let reloaded = BrowserSpaceStore(directory: root)
        let destination = LinkRouteDestination(spaceID: space.id, spaces: reloaded)
        XCTAssertTrue(destination.isAvailable)
        XCTAssertEqual(destination.profile?.id, owner.id)
        XCTAssertEqual(destination.space?.profileID, owner.id)
        XCTAssertEqual(destination.space?.displaySymbol, "leaf")
        XCTAssertEqual(destination.space?.emoji, "")
        XCTAssertEqual(destination.space?.color, .blue)
        XCTAssertEqual(destination.space?.theme, .purple)
        XCTAssertFalse(reloaded.profiles.hasLoadedResources(for: owner.id))
    }

    func testUnknownProfileCannotAcquireNewStyledSpaceOrCreateFiles() throws {
        let root = directory()
        let profiles = BrowserProfileStore(directory: root, enabled: false, disposableWebsiteData: true)
        let spaces = BrowserSpaceStore(directory: root, enabled: false, profiles: profiles)
        let browser = BrowserModel(websiteDataStore: .nonPersistent(), spaces: spaces)
        let before = spaces.spaces
        XCTAssertThrowsError(try browser.createSpace(title: "Unknown", profileID: UUID(), icon: .book,
                                                     theme: .blue, symbol: "leaf", emoji: "🦊", color: .blue))
        XCTAssertEqual(spaces.spaces, before)
        XCTAssertEqual(browser.activeSpaceID, BrowserSpaceStore.defaultSpaceID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testMissingOwnersAreExcludedFromBothShortcutIndicesAndVisibilityCountWithoutDeletingMetadata() throws {
        let root = directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let profiles = BrowserProfileStore(directory: root, disposableWebsiteData: true)
        let missing = try profiles.create(title: "Missing")
        let retained = try profiles.create(title: "Retained")
        let spaces = BrowserSpaceStore(directory: root, profiles: profiles)
        let unknown = try spaces.createSpace(title: "Unavailable", profileID: missing.id)
        let reachable = try spaces.createSpace(title: "Reachable", profileID: retained.id)
        let original = try Data(contentsOf: root.appending(path: "Spaces.json"))
        try JSONEncoder().encode(profiles.profiles.filter { $0.id != missing.id })
            .write(to: root.appending(path: "Profiles.json"))
        let recoveredProfiles = BrowserProfileStore(directory: root, disposableWebsiteData: true)
        let recovered = BrowserSpaceStore(directory: root, profiles: recoveredProfiles)
        let browser = BrowserModel(websiteDataStore: .nonPersistent(), spaces: recovered)
        XCTAssertEqual(browser.selectableSpaces.map(\.id), [BrowserSpaceStore.defaultSpaceID, reachable.id])
        XCTAssertTrue(browser.selectSpace(at: 1))
        XCTAssertEqual(browser.activeSpaceID, reachable.id)
        XCTAssertEqual(browser.profileID, retained.id)
        XCTAssertFalse(browser.selectSpace(unknown.id))
        XCTAssertFalse(browser.selectSpace(at: 2))
        XCTAssertFalse(recoveredProfiles.hasLoadedResources(for: missing.id))
        XCTAssertTrue(browser.allTabs.allSatisfy { $0.webView == nil })
        XCTAssertEqual(try Data(contentsOf: root.appending(path: "Spaces.json")), original)
        XCTAssertNotNil(recovered.space(unknown.id), "Unavailable ownership is preserved for recovery")
        XCTAssertEqual(SpaceIndicatorHiding.whenSingleSpace.showsIndicator(spaceCount: browser.selectableSpaces.count), true)
        let onlyDefault = browser.selectableSpaces.filter { $0.profileID == BrowserProfile.defaultID }
        XCTAssertFalse(SpaceIndicatorHiding.whenSingleSpace.showsIndicator(spaceCount: onlyDefault.count))
        XCTAssertTrue(BrowserModel(isPrivate: true, spaces: recovered).selectableSpaces.isEmpty)
    }

    func testDefaultOnlyContextKeepsExistingLabelsAndSingleEditAction() throws {
        let space = BrowserSpace(id: BrowserSpaceStore.defaultSpaceID, title: "Home", profileID: BrowserProfile.defaultID)
        let context = SpaceSelectorProfileContext(titles: [BrowserProfile.defaultID: "Existing Profile"],
                                                 activeProfileID: BrowserProfile.defaultID, canClearData: true,
                                                 showSettings: { _ in XCTFail("Default has no named-profile settings action") },
                                                 clearData: { _ in XCTFail("Default has no named-profile clear action") })
        let view = SpaceSelectorView(frame: NSRect(x: 0, y: 0, width: 236, height: 36))
        view.update(spaces: [space], activeID: space.id, enabled: true, profileContext: context,
                    select: { _ in }, edit: { _ in }, create: {})
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(view.choiceButtons.first)
        XCTAssertEqual(button.toolTip, "Home")
        XCTAssertEqual(button.accessibilityLabel(), "Switch to Space Home")
        XCTAssertEqual(button.menu?.items.map(\.title), ["Edit Space…"])
        XCTAssertEqual(view.spaceMenu.items.map(\.title), ["Home"])
    }

    func testNativeProfileLabelsAndActionsSurviveOptionalControlIntegration() throws {
        let owner = UUID()
        let space = BrowserSpace(id: UUID(), title: "Research", profileID: owner)
        var settings: [UUID] = [], clearing: [UUID] = []
        let context = SpaceSelectorProfileContext(titles: [owner: "Work"], activeProfileID: owner, canClearData: true,
                                                 showSettings: { settings.append($0) }, clearData: { clearing.append($0) })
        let view = SpaceSelectorView(frame: NSRect(x: 0, y: 0, width: 236, height: 36))
        view.update(spaces: [space], activeID: space.id, enabled: true, profileContext: context,
                    select: { _ in }, edit: { _ in }, create: {})
        view.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(view.choiceButtons.first)
        XCTAssertEqual(button.toolTip, "Research, Work")
        XCTAssertEqual(button.accessibilityLabel(), "Switch to Space Research, Work")
        let menu = try XCTUnwrap(button.menu)
        XCTAssertEqual(menu.items.first?.title, "Profile: Work")
        try press("Profile Site Settings…", in: menu)
        try press("Clear Profile Data…", in: menu)
        XCTAssertEqual(settings, [space.id])
        XCTAssertEqual(clearing, [space.id])
        view.clearActions()
        try press("Profile Site Settings…", in: menu)
        try press("Clear Profile Data…", in: menu)
        XCTAssertEqual(settings.count, 1)
        XCTAssertEqual(clearing.count, 1)
    }

    func testRetainedNativeProfileMenusRejectChangedOwnerHiddenIndicatorAndDisabledClear() throws {
        let firstOwner = UUID(), secondOwner = UUID()
        let first = BrowserSpace(id: UUID(), title: "Same title", profileID: firstOwner)
        let second = BrowserSpace(id: UUID(), title: "Same title", profileID: secondOwner)
        var settings = 0, clearing = 0
        func context(_ owner: UUID, canClear: Bool = true) -> SpaceSelectorProfileContext {
            SpaceSelectorProfileContext(titles: [firstOwner: "First", secondOwner: "Second"], activeProfileID: owner,
                                        canClearData: canClear, showSettings: { _ in settings += 1 }, clearData: { _ in clearing += 1 })
        }
        let view = SpaceSelectorView(frame: NSRect(x: 0, y: 0, width: 236, height: 36))
        func update(_ active: BrowserSpace, indicator: Bool = true, canClear: Bool = true) {
            view.update(spaces: [first, second], activeID: active.id, enabled: true, showsIndicator: indicator,
                        profileContext: context(active.profileID, canClear: canClear), select: { _ in }, edit: { _ in }, create: {})
            view.layoutSubtreeIfNeeded()
        }
        update(first)
        let old = try XCTUnwrap(view.choiceButtons.first { $0.spaceID == first.id }?.menu)
        update(second)
        try press("Profile Site Settings…", in: old)
        try press("Clear Profile Data…", in: old)
        XCTAssertEqual(settings, 0)
        XCTAssertEqual(clearing, 0)
        let current = try XCTUnwrap(view.choiceButtons.first { $0.spaceID == second.id }?.menu)
        update(second, indicator: false)
        try press("Profile Site Settings…", in: current)
        try press("Clear Profile Data…", in: current)
        XCTAssertEqual(settings, 0)
        XCTAssertEqual(clearing, 0)
        update(second, canClear: false)
        let disabled = try XCTUnwrap(view.choiceButtons.first { $0.spaceID == second.id }?.menu)
        XCTAssertEqual(disabled.item(withTitle: "Clear Profile Data…")?.isEnabled, false)
        try press("Clear Profile Data…", in: current)
        XCTAssertEqual(clearing, 0)
        XCTAssertNil(view.choiceButtons.first { $0.spaceID == first.id }?.menu?.item(withTitle: "Clear Profile Data…"))
    }

    func testCapturedModelProfileContextCannotRetargetSettingsAfterSelectionOrClose() throws {
        let root = directory()
        let profiles = BrowserProfileStore(directory: root, enabled: false, disposableWebsiteData: true)
        let owner = try profiles.create(title: "Work")
        let spaces = BrowserSpaceStore(directory: root, enabled: false, profiles: profiles)
        let browser = BrowserModel(websiteDataStore: .nonPersistent(), spaces: spaces)
        let space = try browser.createSpace(title: "Work", profileID: owner.id)
        var presentations = 0
        let context = SpaceSelectorProfileContext(browser: browser, showSettings: { presentations += 1 })
        context.showSettings(space.id)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(browser.selectSpace(BrowserSpaceStore.defaultSpaceID))
        context.showSettings(space.id)
        XCTAssertEqual(presentations, 1)
        XCTAssertTrue(browser.selectSpace(space.id))
        browser.windowDidClose()
        context.showSettings(space.id)
        XCTAssertEqual(presentations, 1)
    }

    private func press(_ title: String, in menu: NSMenu) throws {
        let item = try XCTUnwrap(menu.item(withTitle: title))
        let action = try XCTUnwrap(item.action)
        NSApp.sendAction(action, to: item.target, from: item)
    }
}
