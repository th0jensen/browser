import Foundation

/// Where words typed into the address bar are searched for.
enum SearchEngine: String, CaseIterable, Identifiable {
    case google
    case duckDuckGo
    case bing
    case kagi
    case ecosia

    static let storageKey = "searchEngine"

    var id: Self { self }

    var title: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .kagi: "Kagi"
        case .ecosia: "Ecosia"
        }
    }

    /// The engine chosen in Settings ▸ General.
    static var current: SearchEngine {
        UserDefaults.standard.string(forKey: storageKey).flatMap(SearchEngine.init) ?? .google
    }

    func searchURL(for query: String) -> URL? {
        let address = switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .kagi: "https://kagi.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        }
        guard var components = URLComponents(string: address) else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        // Search engines read "+" as a space, so "c++" needs it encoded.
        let encodedQuery = components.percentEncodedQuery?.replacing("+", with: "%2B")
        components.percentEncodedQuery = encodedQuery
        return components.url
    }
}

/// What a new tab shows.
enum NewTabPage: String, CaseIterable, Identifiable {
    /// The greeting, search field, and favorites.
    case startPage
    case blank

    static let storageKey = "newTabPage"

    var id: Self { self }

    var title: String {
        switch self {
        case .startPage: "Start Page"
        case .blank: "Blank Page"
        }
    }
}

enum SessionPreferences {
    /// Whether the windows open when the app quit reopen on launch. Otherwise they wait in History ▸ Reopen All
    /// Windows from Last Session.
    static let restoresWindowsKey = "restoresWindowsOnLaunch"

    static var restoresWindows: Bool {
        UserDefaults.standard.object(forKey: restoresWindowsKey) as? Bool ?? true
    }
}

enum DownloadPreferences {
    /// Whether each download asks where to save it, instead of saving to the Downloads folder.
    static let asksWhereToSaveKey = "asksWhereToSaveDownloads"

    static var asksWhereToSave: Bool {
        UserDefaults.standard.bool(forKey: asksWhereToSaveKey)
    }
}
