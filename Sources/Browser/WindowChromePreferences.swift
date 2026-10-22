import AppKit
import Observation
import SwiftUI

enum SpaceIndicatorHiding: String, CaseIterable, Identifiable {
    case always, whenSingleSpace, never
    var id: String { rawValue }
    var title: String {
        switch self {
        case .always: "Always"
        case .whenSingleSpace: "When only one Space"
        case .never: "Never"
        }
    }
    func showsIndicator(spaceCount: Int) -> Bool {
        switch self {
        case .always: false
        case .whenSingleSpace: spaceCount > 1
        case .never: spaceCount > 0
        }
    }
}

/// Each window owns its layout and visibility. Only defaults for future windows are saved,
/// under separate build-variant keys; other open windows never observe those defaults.
@MainActor @Observable
final class WindowChromePreferences {
    enum Variant: String { case debug, release
        static var current: Self {
            #if DEBUG
            .debug
            #else
            .release
            #endif
        }
    }
    static let fallback = WindowChromePreferences()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let prefix: String
    var tabLayout: TabLayout { didSet { defaults.set(tabLayout.rawValue, forKey: prefix + ".tabLayout") } }
    var showsSpaceTitle: Bool { didSet { defaults.set(showsSpaceTitle, forKey: prefix + ".spaceTitle") } }
    var showsNewSpaceButton: Bool { didSet { defaults.set(showsNewSpaceButton, forKey: prefix + ".newSpaceButton") } }
    var spaceIndicatorHiding: SpaceIndicatorHiding { didSet { defaults.set(spaceIndicatorHiding.rawValue, forKey: prefix + ".spaceIndicatorHiding") } }

    func showsSpaceControls(spaceCount: Int) -> Bool {
        showsNewSpaceButton || spaceIndicatorHiding.showsIndicator(spaceCount: spaceCount)
    }
    private var hidesToolbar: Bool { didSet { defaults.set(hidesToolbar, forKey: prefix + ".toolbar") } }
    private var hidesSidebar: Bool { didSet { defaults.set(hidesSidebar, forKey: prefix + ".sidebar") } }
    var autoHideToolbar: Bool {
        get { tabLayout == .vertical && hidesToolbar }
        set { hidesToolbar = newValue }
    }
    var autoHideSidebar: Bool {
        get { tabLayout == .vertical && hidesSidebar }
        set { hidesSidebar = newValue }
    }

    init(defaults: UserDefaults = .standard, variant: Variant = .current) {
        self.defaults = defaults
        prefix = "windowChrome.\(variant.rawValue)"
        showsSpaceTitle = defaults.object(forKey: prefix + ".spaceTitle") as? Bool ?? true
        showsNewSpaceButton = defaults.object(forKey: prefix + ".newSpaceButton") as? Bool ?? true
        spaceIndicatorHiding = SpaceIndicatorHiding(rawValue: defaults.string(forKey: prefix + ".spaceIndicatorHiding") ?? "") ?? .never
        tabLayout = TabLayout(rawValue: defaults.string(forKey: prefix + ".tabLayout") ?? defaults.string(forKey: TabLayout.storageKey) ?? "") ?? .horizontal
        hidesToolbar = defaults.object(forKey: prefix + ".toolbar") as? Bool
            ?? defaults.bool(forKey: CompactToolbar.storageKey)
        hidesSidebar = defaults.object(forKey: prefix + ".sidebar") as? Bool
            ?? defaults.bool(forKey: SidebarVisibility.autoHideKey)
        // Migrate once. Later changes to the old shared keys must not alter
        // defaults for either build variant's future windows.
        if defaults.object(forKey: prefix + ".tabLayout") == nil { defaults.set(tabLayout.rawValue, forKey: prefix + ".tabLayout") }
        if defaults.object(forKey: prefix + ".toolbar") == nil { defaults.set(hidesToolbar, forKey: prefix + ".toolbar") }
        if defaults.object(forKey: prefix + ".sidebar") == nil { defaults.set(hidesSidebar, forKey: prefix + ".sidebar") }
    }
}

@MainActor @Observable
final class WindowChromeSettingsTarget {
    static let shared = WindowChromeSettingsTarget()
    weak var browser: BrowserModel?
    var preferences: WindowChromePreferences { browser?.chromePreferences ?? .fallback }
}

private struct WindowChromePreferencesKey: EnvironmentKey {
    static let defaultValue: WindowChromePreferences? = nil
}
extension EnvironmentValues {
    var windowChromePreferences: WindowChromePreferences? {
        get { self[WindowChromePreferencesKey.self] }
        set { self[WindowChromePreferencesKey.self] = newValue }
    }
}
