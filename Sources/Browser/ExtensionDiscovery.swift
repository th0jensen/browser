import Foundation

struct DiscoveredExtension: Sendable {
    let identifier: String
    let appName: String
    let name: String
    let kind: InstalledExtension.Kind
    let resource: URL
    var appURL: URL? = nil
    var ruleCount: Int? = nil

    /// Some apps ship a sentinel blockerList.json beside their real precompiled list.
    static func blockerResource(in bundle: Bundle) -> (url: URL, count: Int)? {
        let candidates = ["blockerList", "precompiledList"].compactMap {
            // Bundle caches missing resources. Check the actual resource path so
            // rescanning an updated app can see a newly supplied real rule list.
            if let direct = bundle.resourceURL?.appending(path: "\($0).json"),
               FileManager.default.fileExists(atPath: direct.path) { return direct }
            return bundle.url(forResource: $0, withExtension: "json")
        }.compactMap { url -> (url: URL, count: Int)? in
            guard let data = try? Data(contentsOf: url), let count = usableRuleCount(data) else { return nil }
            return (url, count)
        }
        return candidates.first { $0.count > 0 } ?? candidates.first
    }

    static func usableRuleCount(_ data: Data) -> Int? {
        guard let rules = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        if rules.count == 1, let trigger = rules[0]["trigger"] as? [String: Any],
           trigger["url-filter"] as? String == "webkit.svg" { return 0 }
        return rules.count
    }

    static let applicationDirectories = [URL(filePath: "/Applications")]
        + FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)

    static func scan(_ directories: [URL]) -> [DiscoveredExtension] {
        var result: [DiscoveredExtension] = []
        var seen = Set<String>()
        for directory in directories {
            guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let appURL as URL in enumerator where appURL.pathExtension == "app" {
                let app = Bundle(url: appURL)
                let appName = app?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? appURL.deletingPathExtension().lastPathComponent
                let plugins = (try? FileManager.default.contentsOfDirectory(at: appURL.appending(path: "Contents/PlugIns"), includingPropertiesForKeys: nil)) ?? []
                for plugin in plugins where plugin.pathExtension == "appex" {
                    guard let bundle = Bundle(url: plugin), let identifier = bundle.bundleIdentifier,
                          let settings = bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any],
                          let point = settings["NSExtensionPointIdentifier"] as? String else { continue }
                    let kind: InstalledExtension.Kind
                    let resource: URL
                    var ruleCount: Int?
                    switch point {
                    case "com.apple.Safari.web-extension": kind = .webExtension; resource = plugin
                    case "com.apple.Safari.content-blocker":
                        guard let rules = blockerResource(in: bundle) else { continue }
                        kind = .contentBlocker; resource = rules.url; ruleCount = rules.count
                    default: continue
                    }
                    guard seen.insert(identifier).inserted else { continue }
                    result.append(DiscoveredExtension(identifier: identifier, appName: appName,
                                                      name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? appName,
                                                      kind: kind, resource: resource, appURL: appURL, ruleCount: ruleCount))
                }
            }
        }
        return result
    }
}
