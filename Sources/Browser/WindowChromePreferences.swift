import AppKit
import Observation
import SwiftUI

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
