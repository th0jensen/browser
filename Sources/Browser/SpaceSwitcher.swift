import SwiftUI

extension BrowserSpaceTheme {
    var color: Color {
        switch self {
        case .system: .accentColor
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .orange: .orange
        case .green: .green
        case .gray: .gray
        }
    }
}

/// Keep the selected icon visible and reserve real targets for overflow and creation.
/// Very narrow layouts combine the selected icon and All Spaces menu, never the plus action.
struct SpaceStripLayout: Equatable {
    let visibleIndices: Range<Int>
    let showsOverflow: Bool
    let usesCompactMenu: Bool

    init(count: Int, selectedIndex: Int, width: CGFloat) {
        let count = max(0, count)
        let selected = min(max(0, selectedIndex), max(0, count - 1))
        usesCompactMenu = !width.isFinite || width < 108
        if count == 0 {
            visibleIndices = 0..<0
            showsOverflow = false
        } else if usesCompactMenu {
            visibleIndices = selected..<(selected + 1)
            showsOverflow = count > 1
        } else if CGFloat(count) * 36 + 40 <= width {
            visibleIndices = 0..<count
            showsOverflow = false
        } else {
            let capacity = min(count, max(1, Int(min(width, 10_000) - 80) / 36))
            let start = min(max(0, selected - capacity / 2), count - capacity)
            visibleIndices = start..<(start + capacity)
            showsOverflow = true
        }
    }
}

private struct SpaceEditorRequest: Identifiable {
    let id = UUID()
    var space: BrowserSpace?
}

/// The sidebar uses a persistent bottom icon strip; horizontal tabs keep the native menu fallback.
struct SpaceSwitcher: View {
    enum Style { case menu, sidebar }
    let browser: BrowserModel
    var style: Style = .menu
    @State private var editor: SpaceEditorRequest?
    @State private var isShowingProfileSettings = false

    private var current: BrowserSpace? { browser.spaces.space(browser.activeSpaceID) }
    private var profileTitle: String { browser.spaces.profiles.profile(browser.profileID)?.title ?? "Profile unavailable" }

    var body: some View {
        if !browser.isPrivate && !browser.isExtensionWindow {
            Group {
                if style == .sidebar { iconStrip }
                else { fallbackMenu }
            }
            .disabled(browser.tabDrag.payload != nil)
            .sheet(item: $editor) { request in SpaceEditor(browser: browser, space: request.space) }
            .sheet(isPresented: $isShowingProfileSettings) {
                ProfileSiteSettingsView(permissions: browser.sitePermissions, zoom: browser.zoomLevels, title: profileTitle)
            }
        }
    }

    private var fallbackMenu: some View {
        Menu {
            profileMenuItems
            Divider()
            spaceMenuItems
            Divider()
            if let current { Button("Edit This Space…") { editor = SpaceEditorRequest(space: current) } }
            Button("New Space…") { editor = SpaceEditorRequest() }
        } label: {
            Label(current?.title ?? "Default", systemImage: current?.icon.symbol ?? BrowserSpaceIcon.circle.symbol)
                .lineLimit(1)
        }
        .help("Spaces in the same profile share logins. Different profiles use separate website data.")
        .accessibilityLabel("Space: \(current?.title ?? "Default")")
    }

    private var iconStrip: some View {
        GeometryReader { geometry in
            let spaces = browser.spaces.spaces
            let selected = spaces.firstIndex { $0.id == browser.activeSpaceID } ?? 0
            let layout = SpaceStripLayout(count: spaces.count, selectedIndex: selected, width: geometry.size.width)
            HStack(spacing: 4) {
                if layout.usesCompactMenu {
                    Menu {
                        profileMenuItems
                        Divider()
                        spaceMenuItems
                    } label: { icon(current, selected: true) }
                        .menuIndicator(.hidden).menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .help("All Spaces — \(current?.title ?? "Default")")
                        .accessibilityLabel("All Spaces, current Space \(current?.title ?? "Default")")
                } else {
                    ForEach(Array(layout.visibleIndices), id: \.self) { index in
                        let space = spaces[index]
                        Button { browser.selectSpace(space.id) } label: {
                            icon(space, selected: space.id == browser.activeSpaceID)
                        }
                        .buttonStyle(.plain)
                        .disabled(browser.spaces.profiles.profile(space.profileID) == nil)
                        .help("\(space.title) — \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")")
                        .accessibilityLabel("Switch to Space \(space.title), \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")")
                        .accessibilityValue(space.id == browser.activeSpaceID ? "Selected" : "")
                        .accessibilityAddTraits(space.id == browser.activeSpaceID ? [.isSelected] : [])
                        .contextMenu {
                            if space.id == browser.activeSpaceID { profileMenuItems }
                            else { Text("Profile: \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")") }
                            Button("Edit Space…") { editor = SpaceEditorRequest(space: space) }
                        }
                    }
                    Spacer(minLength: 0)
                    if layout.showsOverflow {
                        Menu {
                            profileMenuItems
                            Divider()
                            spaceMenuItems
                        } label: {
                            Image(systemName: "ellipsis").frame(width: 28, height: 28)
                        }
                        .menuIndicator(.hidden).menuStyle(.borderlessButton)
                        .frame(width: 28)
                        .help("All Spaces").accessibilityLabel("All Spaces")
                    }
                }
                Button { editor = SpaceEditorRequest() } label: {
                    Image(systemName: "plus").frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("New Space").accessibilityLabel("New Space")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.primary)
            .padding(4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint((current?.theme.color ?? .accentColor).opacity(0.12)), in: Capsule())
        }
        .frame(height: 36)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Spaces")
        .accessibilityIdentifier("BrowserSpaceIconStrip")
    }

    private func icon(_ space: BrowserSpace?, selected: Bool) -> some View {
        Image(systemName: space?.icon.symbol ?? BrowserSpaceIcon.circle.symbol)
            .frame(width: 28, height: 28)
            .background(selected ? (space?.theme.color ?? .accentColor).opacity(0.18) : .clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7).strokeBorder(.primary.opacity(0.35), lineWidth: 1)
                }
            }
    }

    @ViewBuilder private var profileMenuItems: some View {
        Text("Profile: \(profileTitle)")
        if !browser.supportsExtensions { Text("Extensions and password autofill are not available in this profile.") }
        if browser.spaces.profiles.loadFailed { Text("Profiles could not be read. Keep Profiles.json for recovery.") }
        if browser.profileID != BrowserProfile.defaultID {
            Button("Profile Site Settings…") { isShowingProfileSettings = true }
            Button("Clear Profile Data…") { browser.isShowingClearData = true }
        }
    }

    @ViewBuilder private var spaceMenuItems: some View {
        ForEach(browser.spaces.spaces) { space in
            Button { browser.selectSpace(space.id) } label: {
                Label(space.title, systemImage: space.id == browser.activeSpaceID ? "checkmark" : space.icon.symbol)
                Text(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")
            }
            .disabled(browser.spaces.profiles.profile(space.profileID) == nil)
        }
    }
}

/// Space title is adjacent to its saved/temporary content; this control edits, not switches.
struct BrowserSpaceHeading: View {
    let browser: BrowserModel
    @State private var editor: SpaceEditorRequest?

    var body: some View {
        if !browser.isPrivate && !browser.isExtensionWindow,
           let space = browser.spaces.space(browser.activeSpaceID) {
            HStack(spacing: 7) {
                Image(systemName: space.icon.symbol)
                Text(space.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { editor = SpaceEditorRequest(space: space) } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Edit Space name, icon, and theme")
                .accessibilityLabel("Edit Space \(space.title)")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .help("\(space.title) — \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Space \(space.title), \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")")
            .sheet(item: $editor) { request in SpaceEditor(browser: browser, space: request.space) }
        }
    }
}

private struct SpaceEditor: View {
    let browser: BrowserModel
    let space: BrowserSpace?
    @State private var name: String
    @State private var icon: BrowserSpaceIcon
    @State private var theme: BrowserSpaceTheme
    @State private var errorMessage: String?
    @State private var selectedProfileID: UUID
    @State private var newProfileName = ""
    private let newProfileChoice = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    @FocusState private var nameIsFocused: Bool
    @Environment(\.dismiss) private var dismiss

    init(browser: BrowserModel, space: BrowserSpace?) {
        self.browser = browser
        self.space = space
        _name = State(initialValue: space?.title ?? "")
        _icon = State(initialValue: space?.icon ?? .circle)
        _theme = State(initialValue: space?.theme ?? .system)
        _selectedProfileID = State(initialValue: space?.profileID ?? browser.profileID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(space == nil ? "New Space" : "Edit Space").font(.headline)
            Text("Spaces have separate pinned and temporary tabs. Spaces in the same profile share logins.")
                .foregroundStyle(.secondary)
            TextField("Space name", text: $name).focused($nameIsFocused)
            if let space {
                LabeledContent("Profile", value: browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")
                Text("A Space’s profile cannot change. Create a new Space to use another profile.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Profile", selection: $selectedProfileID) {
                    ForEach(browser.spaces.profiles.profiles) { Text($0.title).tag($0.id) }
                    Text("New Profile…").tag(newProfileChoice)
                }
                if selectedProfileID == newProfileChoice { TextField("Profile name", text: $newProfileName) }
            }
            if selectedProfileID != BrowserProfile.defaultID {
                Text("Separate cookies, website data, history, bookmarks, and site settings. Extensions and password autofill are not available. App Settings still manage the Existing Profile. Tracker protection and app preferences apply to all profiles. Downloads save to the shared Downloads folder.")
                    .font(.callout).foregroundStyle(.secondary)
                #if DEBUG
                Text("Debug and QA website data are temporary, even for named profiles.")
                    .font(.callout).foregroundStyle(.secondary)
                #endif
            }
            Picker("Icon", selection: $icon) {
                ForEach(BrowserSpaceIcon.allCases) { icon in Label(icon.title, systemImage: icon.symbol).tag(icon) }
            }
            Picker("Theme", selection: $theme) {
                ForEach(BrowserSpaceTheme.allCases) { theme in Text(theme.title).tag(theme) }
            }
            Label(name.isEmpty ? "Space Preview" : name, systemImage: icon.symbol)
                .foregroundStyle(.primary).padding(10)
                .glassEffect(.regular.tint(theme.color.opacity(0.15)), in: RoundedRectangle(cornerRadius: 8))
            if let errorMessage { Text(errorMessage).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(space == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || (space == nil && selectedProfileID == newProfileChoice
                                  && newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20).frame(width: 360)
        .onAppear { nameIsFocused = true }
    }

    private func save() {
        do {
            guard !browser.isPrivate, !browser.isExtensionWindow else { throw BrowserSpaceStore.Failure.unavailable }
            if let space { try browser.spaces.updateSpace(space.id, title: name, icon: icon, theme: theme) }
            else {
                if selectedProfileID == newProfileChoice {
                    selectedProfileID = try browser.spaces.profiles.create(title: newProfileName).id
                }
                try browser.createSpace(title: name, profileID: selectedProfileID, icon: icon, theme: theme)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
