import Foundation

struct DiscoveredExtension: Sendable {
    let identifier: String
    let appName: String
    let name: String
    let kind: InstalledExtension.Kind
    let resource: URL

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
                    switch point {
                    case "com.apple.Safari.web-extension": kind = .webExtension; resource = plugin
                    case "com.apple.Safari.content-blocker":
                        guard let rules = bundle.url(forResource: "blockerList", withExtension: "json")
                                ?? bundle.url(forResource: "precompiledList", withExtension: "json") else { continue }
                        kind = .contentBlocker; resource = rules
                    default: continue
                    }
                    guard seen.insert(identifier).inserted else { continue }
                    result.append(DiscoveredExtension(identifier: identifier, appName: appName,
                                                      name: bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? appName,
                                                      kind: kind, resource: resource))
                }
            }
        }
        return result
    }
}
