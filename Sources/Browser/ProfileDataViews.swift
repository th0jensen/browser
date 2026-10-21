import SwiftUI
import WebKit

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
