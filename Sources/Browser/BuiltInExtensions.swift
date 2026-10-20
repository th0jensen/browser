import Foundation

enum BuiltInExtensions {
    static let forcedDarkIdentifier = "dev.athas.browser.builtin.forced-dark"
    static let forcedDarkID = UUID(uuidString: "F04CEDDA-4B2A-4D41-9A11-DABA00000001")!

    struct SynchronizationResult {
        let installed: [InstalledExtension]
        let changed: Bool
    }

    static func forcedDarkURL(in bundle: Bundle = .main) -> URL? {
        guard let resourceURL = bundle.resourceURL?.appending(path: "ForcedDark", directoryHint: .isDirectory),
              isForcedDarkResource(resourceURL) else { return nil }
        return resourceURL
    }

    static func synchronizeForcedDark(from source: URL, in directory: URL,
                                      installed: [InstalledExtension]) throws -> SynchronizationResult {
        guard isForcedDarkResource(source) else {
            throw ExtensionFailure("Browser’s built-in Forced Dark resources are invalid.")
        }

        var result = installed
        let candidates = result.filter {
            $0.managedIdentifier == forcedDarkIdentifier || ($0.kind == .webExtension && $0.name == "Forced Dark")
        }
        let retainedID = candidates.first(where: { $0.managedIdentifier == forcedDarkIdentifier })?.id
            ?? candidates.first?.id ?? forcedDarkID
        var changed = false
        var previousResource: URL?

        if let index = result.firstIndex(where: { $0.id == retainedID }) {
            let previousFilename = result[index].filename
            if result[index].managedIdentifier != forcedDarkIdentifier || previousFilename != "resources" {
                result[index].managedIdentifier = forcedDarkIdentifier
                result[index].filename = "resources"
                changed = true
            }
            if previousFilename != "resources" {
                previousResource = directory.appending(path: retainedID.uuidString).appending(path: previousFilename)
            }
        } else {
            result.append(InstalledExtension(
                id: retainedID, name: "Forced Dark", kind: .webExtension, filename: "resources",
                needsNativeMessaging: false, isEnabled: true, managedIdentifier: forcedDarkIdentifier))
            changed = true
        }

        let duplicateIDs = Set(candidates.lazy.map(\.id).filter { $0 != retainedID })
        if !duplicateIDs.isEmpty {
            result.removeAll { duplicateIDs.contains($0.id) }
            changed = true
        }

        let destination = directory.appending(path: retainedID.uuidString, directoryHint: .isDirectory)
            .appending(path: "resources", directoryHint: .isDirectory)
        if try synchronizeDirectory(from: source, to: destination) { changed = true }
        if let previousResource { try? FileManager.default.removeItem(at: previousResource) }
        for identifier in duplicateIDs {
            try? FileManager.default.removeItem(at: directory.appending(path: identifier.uuidString))
        }
        return SynchronizationResult(installed: result, changed: changed)
    }

    static func isForcedDarkResource(_ resource: URL) -> Bool {
        let manifest = resource.appending(path: "manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return value["name"] as? String == "Forced Dark"
            && value["description"] as? String == BrowserExtensions.forcedDarkDescription
    }

    @discardableResult
    private static func synchronizeDirectory(from source: URL, to destination: URL) throws -> Bool {
        if FileManager.default.fileExists(atPath: destination.path), try directoriesMatch(source, destination) {
            return false
        }
        let parent = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appending(path: ".forced-dark-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        return true
    }

    private static func directoriesMatch(_ first: URL, _ second: URL) throws -> Bool {
        let firstFiles = try relativeFiles(in: first)
        let secondFiles = try relativeFiles(in: second)
        guard firstFiles == secondFiles else { return false }
        return try firstFiles.allSatisfy { relativePath in
            let lhs = first.appending(path: relativePath)
            let rhs = second.appending(path: relativePath)
            let lhsSize = try lhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let rhsSize = try rhs.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard lhsSize == rhsSize else { return false }
            return try Data(contentsOf: lhs) == Data(contentsOf: rhs)
        }
    }

    private static func relativeFiles(in root: URL) throws -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var files: [String] = []
        for case let url as URL in enumerator {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            files.append(String(url.path.dropFirst(root.path.count + 1)))
        }
        return files.sorted()
    }
}
