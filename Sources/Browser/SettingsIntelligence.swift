import SwiftUI

struct IntelligenceSettings: View {
    @State private var windowSettingsTarget = WindowChromeSettingsTarget.shared
    @AppStorage(BrowserIntelligence.tidyTabTitlesKey) private var tidyTabTitles = false
    @AppStorage(BrowserIntelligence.tidyDownloadsKey) private var tidyDownloads = false
    @AppStorage(BrowserIntelligence.fiveSecondPreviewsKey) private var fiveSecondPreviews = false

    private var browser: BrowserModel? { windowSettingsTarget.browser }
    private var isTidyingTabs: Bool { browser?.isTidyingTabs == true }
    private var canTidyTabs: Bool {
        browser?.canTidyTabs == true && BrowserIntelligence.unavailableReason == nil
    }

    var body: some View {
        Form {
            Section {
                Button(isTidyingTabs ? "Cancel Tidy Tabs" : "Tidy Tabs") {
                    if isTidyingTabs { browser?.cancelTidyingTabs() }
                    else { browser?.tidyTemporaryTabs() }
                }
                .disabled(!isTidyingTabs && !canTidyTabs)
            } footer: {
                Text("Group temporary tabs by topic in the current browser window. Available with seven or more temporary web tabs. You can also choose Tabs → Tidy Tabs.")
            }

            Section("Automatic Features") {
                Toggle(isOn: $tidyTabTitles) {
                    Text("Tidy Tab Titles")
                    Text("Automatically shorten titles for tabs saved in sidebar folders. Titles you set yourself are kept.")
                }
                .accessibilityLabel("Tidy Tab Titles")
                Toggle(isOn: $tidyDownloads) {
                    Text("Tidy Downloads")
                    Text("Give automatically saved downloads clearer filenames. Click a renamed file’s name in Downloads to restore its original name.")
                }
                .accessibilityLabel("Tidy Downloads")
                Toggle(isOn: $fiveSecondPreviews) {
                    Text("5-second Previews")
                    Text("Hold Shift and hover over a link for a short page summary. On supported search and social sites, hovering is enough.")
                }
                .accessibilityLabel("5-second Previews")
            }

            Section("On This Mac") {
                Text(BrowserIntelligence.modelDescription)
                    .foregroundStyle(.secondary)
                Text("Summaries, tab groups, and suggested names are generated on this Mac. These features are turned off in private windows.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: fiveSecondPreviews) { _, isEnabled in
            LinkPreviewController.shared.setEnabled(isEnabled)
        }
    }
}
