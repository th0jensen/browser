import SwiftUI

struct BrowserSettings: View {
    let browsingData: BrowsingData
    private enum Category: String, CaseIterable, Identifiable {
        case general = "General", linkRouting = "Link Routing", appearance = "Appearance", privacy = "Privacy", passwords = "Passwords", siteSettings = "Site Settings", downloads = "Downloads", extensions = "Extensions", intelligence = "Intelligence"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .linkRouting: "arrow.triangle.branch"
            case .appearance: "paintpalette"
            case .privacy: "hand.raised"
            case .passwords: "key"
            case .siteSettings: "globe"
            case .downloads: "arrow.down.circle"
            case .extensions: "puzzlepiece.extension"
            case .intelligence: "sparkles"
            }
        }
    }
    @State private var selection: Category? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section("Browser") { category(.general); category(.appearance); category(.downloads) }
                Section("Privacy and Security") { category(.privacy); category(.passwords); category(.siteSettings) }
                Section("Features") { category(.linkRouting); category(.extensions); category(.intelligence) }
            }
            .listStyle(.sidebar)
            .frame(width: 190)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                Text((selection ?? .general).rawValue)
                    .font(.system(size: 22, weight: .semibold))
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 4)
                Group {
                    switch selection ?? .general {
                    case .general: GeneralSettings(updater: .shared)
                    case .linkRouting: LinkRoutingSettings(rules: .shared, spaces: .shared)
                    case .appearance: AppearanceSettings()
                    case .privacy: PrivacySettings(browsingData: browsingData, contentBlocker: .shared)
                    case .passwords: PasswordSettings(passwords: .shared, passkeys: .shared)
                    case .siteSettings: SiteSettings(contentBlocker: .shared, sitePermissions: .shared, zoomLevels: .shared)
                    case .downloads: DownloadSettings()
                    case .extensions: ExtensionSettings()
                    case .intelligence: IntelligenceSettings()
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .modifier(ScrollbarVisibility())
        .frame(minWidth: 730, idealWidth: 780, minHeight: selection == .appearance ? 620 : 520, idealHeight: 620)
    }

    private func category(_ value: Category) -> some View { Label(value.rawValue, systemImage: value.symbol).tag(value) }

}
