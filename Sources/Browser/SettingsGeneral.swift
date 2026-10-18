import AppKit
import SwiftUI

struct GeneralSettings: View {
    @Bindable var updater: AppUpdater
    @State private var defaultBrowser = DefaultBrowser()
    @AppStorage(SearchEngine.storageKey) private var searchEngine = SearchEngine.google
    @AppStorage(NewTabPage.storageKey) private var newTabPage = NewTabPage.startPage
    @AppStorage(SessionPreferences.restoresWindowsKey) private var restoresPreviousSession = true
    @AppStorage(PinnedNavigation.peekEnabledKey) private var opensLinksToOtherSitesInPeek = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Default web browser") {
                    if defaultBrowser.isDefault {
                        Text("Browser is your default web browser.")
                            .foregroundStyle(.secondary)
                    } else {
                        Button("Make Browser the Default Browser") {
                            Task { await defaultBrowser.makeDefault() }
                        }
                    }
                }
            }

            Section {
                Picker("Search engine", selection: $searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                Picker("New tabs open with", selection: $newTabPage) {
                    ForEach(NewTabPage.allCases) { page in
                        Text(page.title).tag(page)
                    }
                }
                Toggle(isOn: $restoresPreviousSession) {
                    Text("Restore the previous session")
                    Text("Reopen saved windows and tabs when Browser starts or after the last browser window closes. When off, reopen them from the History menu.")
                }
                .accessibilityLabel("Restore the previous session")
            }

            Section("Links") {
                Toggle("Open links to other sites from pinned tabs in Peek", isOn: $opensLinksToOtherSitesInPeek)
            }

            if updater.isAvailable {
                Section("Updates") {
                    Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                    Toggle("Download and install updates automatically", isOn: $updater.downloadsAutomatically)
                        .disabled(!updater.checksAutomatically)
                    LabeledContent("Software update") {
                        Button("Check Now") { updater.checkForUpdates() }
                            .disabled(!updater.canCheckForUpdates)
                    }
                }
            }
        }
        .task { defaultBrowser.refresh() }
        // The default browser can also change in System Settings while Settings is open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            defaultBrowser.refresh()
        }
    }
}

struct DownloadSettings: View {
    @AppStorage(DownloadPreferences.asksWhereToSaveKey) private var asksWhereToSaveDownloads = false

    var body: some View {
        Form {
            Toggle(isOn: $asksWhereToSaveDownloads) {
                Text("Ask where to save each download")
                Text("When off, downloads save to the Downloads folder.")
            }
            .accessibilityLabel("Ask where to save each download")
        }
    }
}
