import SwiftUI

/// Native menu controls work with keyboard focus and VoiceOver; switching has no motion.
struct SpaceSwitcher: View {
    let browser: BrowserModel
    @State private var isCreating = false
    @State private var name = ""
    @State private var selectedProfileID = BrowserProfile.defaultID
    @State private var newProfileName = ""
    private let newProfileChoice = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    @State private var errorMessage: String?
    @State private var isShowingProfileSettings = false
    @FocusState private var nameIsFocused: Bool

    var body: some View {
        if !browser.isPrivate && !browser.isExtensionWindow {
            Menu {
                Text("Profile: \(browser.spaces.profiles.profile(browser.profileID)?.title ?? "Unavailable")")
                if !browser.supportsExtensions { Text("Extensions and password autofill are not available in this profile.") }
                if browser.spaces.profiles.loadFailed { Text("Profiles could not be read. Keep Profiles.json for recovery.") }
                ForEach(browser.spaces.spaces) { space in
                    Button {
                        browser.selectSpace(space.id)
                    } label: {
                        if browser.activeSpaceID == space.id {
                            Label(space.title, systemImage: "checkmark")
                        } else { Text(space.title) }
                        Text(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")
                    }
                    .disabled(browser.spaces.profiles.profile(space.profileID) == nil)
                }
                Divider()
                if browser.profileID != BrowserProfile.defaultID {
                    Button("Profile Site Settings…") { isShowingProfileSettings = true }
                    Button("Clear Profile Data…") { browser.isShowingClearData = true }
                    Divider()
                }
                Button("New Space…") { name = ""; selectedProfileID = browser.profileID; newProfileName = ""; errorMessage = nil; isCreating = true }
            } label: {
                Label(browser.spaces.space(browser.activeSpaceID)?.title ?? "Default", systemImage: "square.stack")
                    .lineLimit(1)
            }
            .disabled(browser.tabDrag.payload != nil)
            .help("Spaces in the same profile share logins. Different profiles use separate website data.")
            .accessibilityLabel("Space: \(browser.spaces.space(browser.activeSpaceID)?.title ?? "Default")")
            .sheet(isPresented: $isCreating) { creationSheet }
            .sheet(isPresented: $isShowingProfileSettings) {
                ProfileSiteSettingsView(permissions: browser.sitePermissions, zoom: browser.zoomLevels,
                                        title: browser.spaces.profiles.profile(browser.profileID)?.title ?? "Profile")
            }
        }
    }

    private var creationSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Space").font(.headline)
            Text("Spaces have separate tabs and saved pages. Spaces in the same profile share logins.")
                .foregroundStyle(.secondary)
            TextField("Space name", text: $name).focused($nameIsFocused)
            Picker("Profile", selection: $selectedProfileID) {
                ForEach(browser.spaces.profiles.profiles) { Text($0.title).tag($0.id) }
                Text("New Profile…").tag(newProfileChoice)
            }
            if selectedProfileID == newProfileChoice {
                TextField("Profile name", text: $newProfileName)
            }
            if selectedProfileID != BrowserProfile.defaultID {
                Text("Separate cookies, website data, history, bookmarks, and site settings. Extensions and password autofill are not available. App Settings still manage the Existing Profile. Tracker protection and app preferences apply to all profiles. Downloads save to the shared Downloads folder.")
                    .font(.callout).foregroundStyle(.secondary)
                #if DEBUG
                Text("Debug and QA website data are temporary, even for named profiles.")
                    .font(.callout).foregroundStyle(.secondary)
                #endif
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { isCreating = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    do {
                        if selectedProfileID == newProfileChoice {
                            selectedProfileID = try browser.spaces.profiles.create(title: newProfileName).id
                        }
                        try browser.createSpace(title: name, profileID: selectedProfileID)
                        isCreating = false
                    } catch { errorMessage = error.localizedDescription }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { nameIsFocused = true }
    }
}
