import SwiftUI

/// Keep tab URL/title/selection observation outside the window's chrome hierarchy.
struct SessionPersistenceView: View {
    let browser: BrowserModel
    var session: SessionStore? = nil
    @State private var cachedSnapshot: BrowserSessionSnapshot?

    var body: some View {
        let snapshot = BrowserSessionSnapshot(browser: browser)
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: snapshot, initial: true) { _, snapshot in
                guard cachedSnapshot != snapshot else { return }
                cachedSnapshot = snapshot
                if !browser.isPrivate { session?.requestSave() }
            }
            .onDisappear { if !browser.isPrivate { session?.requestSave() } }
    }
}
