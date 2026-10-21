import SwiftUI
import WebKit

/// Own the clearing operation for the profile selected when the sheet opened.
struct ProfileClearDataView: View {
    @State private var data: BrowsingData

    init(history: HistoryStore, dataStore: WKWebsiteDataStore, session: SessionStore, profileID: UUID,
         spaces: BrowserSpaceStore) {
        _data = State(initialValue: BrowsingData(history: history, session: session,
                                               dataStore: dataStore, includesSharedState: false, profileID: profileID,
                                               ownershipResolver: spaces.owns))
    }

    var body: some View { ClearDataView(data: data) }
}

struct ProfileSiteSettingsView: View {
    let permissions: SitePermissions
    let zoom: ZoomStore
    let title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading) {
            Text("Site Settings: \(title)").font(.headline).padding()
            SiteSettings(contentBlocker: .shared, sitePermissions: permissions, zoomLevels: zoom)
                .formStyle(.grouped)
            Text("Tracker protection applies to all profiles.").foregroundStyle(.secondary).padding(.horizontal)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }.padding()
        }.frame(width: 650, height: 500)
    }
}
