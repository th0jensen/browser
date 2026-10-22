import Foundation

/// Descriptor-only labels and owner-checked actions for the native Space selector.
@MainActor
struct SpaceSelectorProfileContext {
    let titles: [UUID: String]
    let activeProfileID: UUID
    let canClearData: Bool
    let showSettings: (UUID) -> Void
    let clearData: (UUID) -> Void

    var hasNamedProfiles: Bool { titles.keys.contains { $0 != BrowserProfile.defaultID } }
    func title(for profileID: UUID) -> String? { hasNamedProfiles ? titles[profileID] : nil }

    init(titles: [UUID: String], activeProfileID: UUID, canClearData: Bool,
         showSettings: @escaping (UUID) -> Void, clearData: @escaping (UUID) -> Void) {
        self.titles = titles
        self.activeProfileID = activeProfileID
        self.canClearData = canClearData
        self.showSettings = showSettings
        self.clearData = clearData
    }

    init(browser: BrowserModel, showSettings: @escaping () -> Void) {
        titles = Dictionary(uniqueKeysWithValues: browser.spaces.profiles.profiles.map { ($0.id, $0.title) })
        let owner = browser.profileID
        activeProfileID = owner
        canClearData = browser.canRequestClearData
        self.showSettings = { [weak browser] spaceID in
            guard let browser, Self.ownsSelection(browser, spaceID: spaceID, profileID: owner) else { return }
            showSettings()
        }
        clearData = { [weak browser] spaceID in
            guard let browser, Self.ownsSelection(browser, spaceID: spaceID, profileID: owner),
                  browser.canRequestClearData else { return }
            browser.requestClearData()
        }
    }

    private static func ownsSelection(_ browser: BrowserModel, spaceID: UUID, profileID: UUID) -> Bool {
        !browser.isClosed && !browser.isPrivate && !browser.isExtensionWindow
            && profileID != BrowserProfile.defaultID && browser.profileID == profileID
            && browser.activeSpaceID == spaceID && browser.spaces.space(spaceID)?.profileID == profileID
            && browser.spaces.profiles.profile(profileID) != nil
    }
}
