import Foundation
import Observation

/// The page zoom the user chose for each site, applied whenever one of its pages loads.
@MainActor
@Observable
final class ZoomStore {
    /// The steps Zoom In and Zoom Out move between.
    static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]
    static let shared = ZoomStore(defaults: BrowserProfile.isTesting || BrowserProfile.qaDirectory != nil ? nil : .standard)
    private static let storageKey = "pageZoomLevels"

    /// `nil` keeps the levels in memory only.
    @ObservationIgnored private let defaults: UserDefaults?
    /// Only levels other than 100%.
    private(set) var levelsByHost: [String: Double]

    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        levelsByHost = defaults?.dictionary(forKey: Self.storageKey) as? [String: Double] ?? [:]
    }

    func level(for host: String?) -> Double {
        host.flatMap { levelsByHost[$0] } ?? 1
    }

    func setLevel(_ level: Double, for host: String?) {
        guard let host else { return }
        levelsByHost[host] = level == 1 ? nil : level
        defaults?.set(levelsByHost, forKey: Self.storageKey)
    }

    func removeAll() {
        levelsByHost = [:]
        defaults?.removeObject(forKey: Self.storageKey)
    }

    static func level(after level: Double) -> Double {
        levels.first { $0 > level + 0.001 } ?? levels[levels.count - 1]
    }

    static func level(before level: Double) -> Double {
        levels.last { $0 < level - 0.001 } ?? levels[0]
    }
}
