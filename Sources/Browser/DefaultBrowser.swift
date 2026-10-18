import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Whether macOS opens web links from other apps in this app, and asks it to.
@MainActor
@Observable
final class DefaultBrowser {
    private(set) var isDefault = false

    func refresh() {
        guard let probe = URL(string: "https://example.com"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else {
            isDefault = false
            return
        }
        isDefault = Bundle(url: handler)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks the user to confirm before it changes the default browser.
    func makeDefault() async {
        let app = Bundle.main.bundleURL
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            // macOS usually changes HTTPS along with HTTP, which would make asking again a second prompt.
            refresh()
            if !isDefault {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
            }
            try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpen: .html)
        } catch {
            // The user kept their current browser.
        }
        refresh()
    }
}
