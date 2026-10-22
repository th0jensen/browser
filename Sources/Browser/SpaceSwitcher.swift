import AppKit
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

/// Equal utility gutters keep the selector centered, independent of plus or overflow visibility.
/// The selected icon stays visible; only extremely narrow layouts combine it with All Spaces.
struct SpaceStripLayout: Equatable {
    let visibleIndices: Range<Int>
    let showsOverflow: Bool
    let usesCompactMenu: Bool
    let targetSize: CGFloat
    let utilityGutter: CGFloat

    init(count: Int, selectedIndex: Int, width: CGFloat) {
        let count = max(0, count)
        let width = width.isFinite ? max(0, width) : 0
        targetSize = min(24, width / 3)
        utilityGutter = width >= 88 ? 32 : targetSize
        let available = max(0, width - utilityGutter * 2)
        let capacity = targetSize > 0 ? max(1, Int(min(available / targetSize, 10_000))) : 1
        let visible = min(count, capacity)
        let selected = min(max(0, selectedIndex), max(0, count - 1))
        let start = min(max(0, selected - visible / 2), count - visible)
        visibleIndices = start..<(start + visible)
        showsOverflow = visible < count
        usesCompactMenu = showsOverflow && visible == 1
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
    @State private var profileSettings: ProfileSiteSettingsView?

    private var current: BrowserSpace? { browser.spaces.space(browser.activeSpaceID) }
    private var profileTitle: String { browser.spaces.profiles.profile(browser.profileID)?.title ?? "Profile unavailable" }
    private var choices: [BrowserSpace] { browser.selectableSpaces }

    var body: some View {
        if !browser.isPrivate && !browser.isExtensionWindow,
           style != .sidebar || browser.chromePreferences.showsSpaceControls(spaceCount: choices.count) {
            Group {
                if style == .sidebar { iconStrip }
                else { fallbackMenu }
            }
            .disabled(browser.tabDrag.payload != nil)
            .popover(item: $editor, attachmentAnchor: .rect(.bounds),
                     arrowEdge: style == .sidebar ? .trailing : .bottom) { request in
                SpaceEditor(browser: browser, space: request.space)
            }
            .sheet(isPresented: $isShowingProfileSettings) {
                profileSettings
            }
            .chromePresentation(isPresented: editor != nil || isShowingProfileSettings, controller: browser.chromeHover,
                                region: style == .sidebar ? .sidebar : .toolbar)
            .onChange(of: browser.activeSpaceID) { _, _ in editor = nil; isShowingProfileSettings = false }
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
            Label {
                Text(current?.title ?? "Default")
            } icon: {
                if let current { SpaceIcon(space: current) }
                else { Image(systemName: BrowserSpaceIcon.circle.symbol) }
            }
            .lineLimit(1)
        }
        .help("Spaces in the same profile share logins. Different profiles use separate website data.")
        .accessibilityLabel("Space: \(current?.title ?? "Default")")
    }

    private var iconStrip: some View {
        NativeSpaceSelector(spaces: choices, activeID: browser.activeSpaceID,
            showsIndicator: browser.chromePreferences.spaceIndicatorHiding.showsIndicator(spaceCount: choices.count),
            showsNewSpaceButton: browser.chromePreferences.showsNewSpaceButton,
            profileContext: SpaceSelectorProfileContext(browser: browser, showSettings: requestProfileSettings),
            select: { browser.selectSpace($0) },
            edit: { editor = SpaceEditorRequest(space: $0) },
            create: { editor = SpaceEditorRequest() })
            .frame(height: 36)
            .frame(maxWidth: .infinity)
    }

    private func requestProfileSettings() {
        guard !browser.isClosed, !browser.isPrivate, !browser.isExtensionWindow,
              browser.profileID != BrowserProfile.defaultID else { return }
        profileSettings = ProfileSiteSettingsView(permissions: browser.sitePermissions, zoom: browser.zoomLevels, title: profileTitle)
        isShowingProfileSettings = true
    }

    @ViewBuilder private var profileMenuItems: some View {
        Text("Profile: \(profileTitle)")
        if !browser.supportsExtensions { Text("Extensions and password autofill are not available in this profile.") }
        if browser.spaces.profiles.loadFailed { Text("Profiles could not be read. Keep Profiles.json for recovery.") }
        if browser.profileID != BrowserProfile.defaultID {
            Button("Profile Site Settings…", action: requestProfileSettings)
            Button("Clear Profile Data…") { browser.requestClearData() }
                .disabled(!browser.canRequestClearData)
        }
    }

    @ViewBuilder private var spaceMenuItems: some View {
        ForEach(choices) { space in
            Button { browser.selectSpace(space.id) } label: {
                Label {
                    Text(space.title)
                } icon: {
                    if space.id == browser.activeSpaceID { Image(systemName: "checkmark") }
                    else { SpaceIcon(space: space) }
                }
                Text(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")
            }
            .disabled(browser.spaces.profiles.profile(space.profileID) == nil)
        }
    }
}

private struct NativeSpaceSelector: NSViewRepresentable {
    let spaces: [BrowserSpace]
    let activeID: UUID
    let showsIndicator: Bool
    let showsNewSpaceButton: Bool
    let profileContext: SpaceSelectorProfileContext
    let select: (UUID) -> Void
    let edit: (BrowserSpace) -> Void
    let create: () -> Void

    func makeNSView(context: Context) -> SpaceSelectorView { SpaceSelectorView() }
    func updateNSView(_ view: SpaceSelectorView, context: Context) {
        view.update(spaces: spaces, activeID: activeID, enabled: context.environment.isEnabled,
            rightToLeft: context.environment.layoutDirection == .rightToLeft,
            showsIndicator: showsIndicator, showsNewSpaceButton: showsNewSpaceButton, profileContext: profileContext,
            select: select, edit: edit, create: create)
    }
    static func dismantleNSView(_ view: SpaceSelectorView, coordinator: ()) { view.clearActions() }
}

/// Native controls keep independent hit/focus targets while drawing only dots and the selected symbol.
/// The group is centered in the full footer; utility visibility never participates in that calculation.
final class SpaceSelectorView: NSView {
    let selectorGroup = NSView()
    let plusButton = SpaceSelectorButton()
    let overflowButton = SpaceSelectorButton()
    private(set) var choiceButtons: [SpaceChoiceButton] = []
    private(set) var spaceMenu = NSMenu(title: "All Spaces")
    private var spaces: [BrowserSpace] = []
    private var activeID: UUID?
    private var enabled = true
    private var rightToLeft = false
    private var showsIndicator = true
    private var showsNewSpaceButton = true
    private var profileContext: SpaceSelectorProfileContext?
    private var select: ((UUID) -> Void)?
    private var edit: ((BrowserSpace) -> Void)?
    private var create: (() -> Void)?
    private var compact = false
    private weak var keyViewWindow: NSWindow?
    private var keyViewParticipants: [ObjectIdentifier] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("BrowserSpaceIconStrip")
        setAccessibilityIdentifier("BrowserSpaceIconStrip")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Spaces")
        autoresizesSubviews = false
        selectorGroup.autoresizesSubviews = false
        addSubview(selectorGroup)
        addSubview(overflowButton)
        addSubview(plusButton)
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        plusButton.toolTip = "New Space"
        plusButton.setAccessibilityLabel("New Space")
        plusButton.target = self
        plusButton.action = #selector(createSpace)
        overflowButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        overflowButton.toolTip = "All Spaces"
        overflowButton.setAccessibilityLabel("All Spaces")
        overflowButton.target = self
        overflowButton.action = #selector(showAllSpaces)
        for button in [plusButton, overflowButton] {
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
            button.contentTintColor = .secondaryLabelColor
        }
    }
    required init?(coder: NSCoder) { nil }

    func update(spaces: [BrowserSpace], activeID: UUID, enabled: Bool, rightToLeft: Bool = false,
                showsIndicator: Bool = true, showsNewSpaceButton: Bool = true,
                profileContext: SpaceSelectorProfileContext? = nil,
                select: @escaping (UUID) -> Void, edit: @escaping (BrowserSpace) -> Void, create: @escaping () -> Void) {
        self.spaces = spaces
        self.activeID = activeID
        self.enabled = enabled
        self.rightToLeft = rightToLeft
        self.showsIndicator = showsIndicator
        self.showsNewSpaceButton = showsNewSpaceButton
        self.profileContext = profileContext
        self.select = select
        self.edit = edit
        self.create = create
        spaceMenu = NSMenu(title: "All Spaces")
        spaceMenu.autoenablesItems = false
        if let active = spaces.first(where: { $0.id == activeID }), profileContext != nil {
            appendProfileItems(to: spaceMenu, for: active)
            spaceMenu.addItem(.separator())
        }
        for space in spaces {
            let label = profileContext?.titles[space.profileID].map { "\(space.title) — \($0)" } ?? space.title
            let item = NSMenuItem(title: label, action: #selector(selectMenuItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.state = space.id == activeID ? .on : .off
            item.isEnabled = enabled
            spaceMenu.addItem(item)
        }
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); needsLayout = true }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); needsLayout = true }

    override func layout() {
        super.layout()
        let selected = spaces.firstIndex { $0.id == activeID } ?? 0
        let oldControls: [NSButton] = choiceButtons + [plusButton, overflowButton]
        let layout = SpaceStripLayout(count: showsIndicator ? spaces.count : 0, selectedIndex: selected, width: bounds.width)
        selectorGroup.isHidden = !showsIndicator
        compact = layout.usesCompactMenu
        let side = layout.targetSize
        let groupWidth = CGFloat(layout.visibleIndices.count) * side
        selectorGroup.frame = NSRect(x: bounds.midX - groupWidth / 2, y: bounds.midY - side / 2, width: groupWidth, height: side)
        let old = Dictionary(uniqueKeysWithValues: choiceButtons.map { ($0.spaceID, $0) })
        let visible = layout.visibleIndices.map { spaces[$0] }
        for button in choiceButtons where !visible.contains(where: { $0.id == button.spaceID }) {
            button.isEnabled = false
            button.target = nil
            button.action = nil
            button.menu = nil
            button.removeFromSuperview()
        }
        choiceButtons = visible.enumerated().map { index, space in
            let button = old[space.id] ?? SpaceChoiceButton(spaceID: space.id)
            button.configure(space, selected: space.id == activeID, compact: compact,
                             profileTitle: profileContext?.titles[space.profileID])
            button.isEnabled = enabled
            button.target = self
            button.action = #selector(selectChoice(_:))
            let position = rightToLeft ? visible.count - index - 1 : index
            button.frame = NSRect(x: CGFloat(position) * side, y: 0, width: side, height: side)
            if button.superview !== selectorGroup { selectorGroup.addSubview(button) }
            let menu = NSMenu(title: space.title)
            menu.autoenablesItems = false
            if profileContext != nil {
                appendProfileItems(to: menu, for: space)
                menu.addItem(.separator())
            }
            let item = NSMenuItem(title: "Edit Space…", action: #selector(editSpace(_:)), keyEquivalent: "")
            item.representedObject = space.id
            item.target = self
            item.isEnabled = enabled
            menu.addItem(item)
            button.menu = menu
            return button
        }
        let inset = max(0, (layout.utilityGutter - side) / 2)
        let leadingX = bounds.minX + inset
        let trailingX = bounds.maxX - inset - side
        plusButton.frame = NSRect(x: rightToLeft ? leadingX : trailingX, y: bounds.midY - side / 2, width: side, height: side)
        overflowButton.frame = NSRect(x: rightToLeft ? trailingX : leadingX, y: bounds.midY - side / 2, width: side, height: side)
        overflowButton.isHidden = !showsIndicator || !layout.showsOverflow || compact
        plusButton.isHidden = !showsNewSpaceButton
        plusButton.isEnabled = enabled && showsNewSpaceButton
        overflowButton.isEnabled = enabled && !overflowButton.isHidden
        let controls: [NSButton] = choiceButtons + (overflowButton.isHidden ? [] : [overflowButton]) + (plusButton.isHidden ? [] : [plusButton])
        if let focused = window?.firstResponder as? NSButton,
           oldControls.contains(where: { $0 === focused }), !controls.contains(where: { $0 === focused }) {
            window?.makeFirstResponder(nil)
        }
        setAccessibilityChildren(controls)
        setAccessibilitySelectedChildren(choiceButtons.filter { $0.isSelectedSpace })
        // The window owns both boundaries of this representable's key-view loop.
        // Do not replace its external successor with a private cycle or nil tail.
        let participants = controls.filter(\.isEnabled).sorted {
            $0.convert($0.bounds, to: self).midX < $1.convert($1.bounds, to: self).midX
        }.map(ObjectIdentifier.init)
        if keyViewWindow !== window || keyViewParticipants != participants {
            keyViewWindow = window
            keyViewParticipants = participants
            window?.recalculateKeyViewLoop()
        }
    }

    @objc private func selectChoice(_ sender: SpaceChoiceButton) {
        guard enabled, showsIndicator, choiceButtons.contains(where: { $0 === sender }) else { return }
        if compact { presentMenu(relativeTo: sender) }
        else if enabled { select?(sender.spaceID) }
    }
    @objc private func selectMenuItem(_ sender: NSMenuItem) {
        guard enabled, showsIndicator, let id = sender.representedObject as? UUID, spaces.contains(where: { $0.id == id }) else { return }
        select?(id)
    }
    @objc private func editSpace(_ sender: NSMenuItem) {
        guard enabled, showsIndicator, let id = sender.representedObject as? UUID, let space = spaces.first(where: { $0.id == id }) else { return }
        edit?(space)
    }
    private func appendProfileItems(to menu: NSMenu, for space: BrowserSpace) {
        guard let context = profileContext else { return }
        let label = NSMenuItem(title: "Profile: \(context.titles[space.profileID] ?? "Profile unavailable")", action: nil, keyEquivalent: "")
        label.isEnabled = false
        menu.addItem(label)
        guard space.id == activeID, space.profileID == context.activeProfileID,
              context.activeProfileID != BrowserProfile.defaultID else { return }
        for (title, action, allowed) in [
            ("Profile Site Settings…", #selector(showProfileSettings(_:)), true),
            ("Clear Profile Data…", #selector(clearProfileData(_:)), context.canClearData)
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = space.id
            item.isEnabled = enabled && allowed
            menu.addItem(item)
        }
    }

    private func profileActionOwner(_ sender: NSMenuItem) -> UUID? {
        guard enabled, showsIndicator, let context = profileContext,
              let id = sender.representedObject as? UUID, id == activeID,
              let space = spaces.first(where: { $0.id == id }), space.profileID == context.activeProfileID,
              context.activeProfileID != BrowserProfile.defaultID else { return nil }
        return id
    }

    @objc private func showProfileSettings(_ sender: NSMenuItem) {
        guard let id = profileActionOwner(sender) else { return }
        profileContext?.showSettings(id)
    }

    @objc private func clearProfileData(_ sender: NSMenuItem) {
        guard let id = profileActionOwner(sender), profileContext?.canClearData == true else { return }
        profileContext?.clearData(id)
    }

    @objc private func createSpace() { if enabled && showsNewSpaceButton { create?() } }
    @objc private func showAllSpaces() { presentMenu(relativeTo: overflowButton) }
    private func presentMenu(relativeTo button: NSButton) {
        guard enabled, showsIndicator else { return }
        spaceMenu.popUp(positioning: nil, at: NSPoint(x: button.bounds.midX, y: button.bounds.maxY), in: button)
    }
    func clearActions() {
        select = nil; edit = nil; create = nil
        profileContext = nil
        enabled = false
        let controls: [NSButton] = choiceButtons + [plusButton, overflowButton]
        controls.forEach {
            $0.isEnabled = false
            $0.menu?.items.forEach { $0.isEnabled = false }
        }
        spaceMenu.items.forEach { $0.isEnabled = false }
    }
}

class SpaceSelectorButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        title = ""
        isBordered = false
        setButtonType(.momentaryChange)
        imagePosition = .imageOnly
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { isEnabled && !isHidden }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor && window != nil }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: 2, dy: 2) }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled, !isHidden else { return false }
        performClick(nil)
        return true
    }
}

final class SpaceChoiceButton: SpaceSelectorButton {
    let spaceID: UUID
    private(set) var isSelectedSpace = false
    private(set) var displayedSymbol: String?
    private(set) var displayedEmoji = ""

    init(spaceID: UUID) { self.spaceID = spaceID; super.init(frame: .zero) }
    required init?(coder: NSCoder) { nil }

    func configure(_ space: BrowserSpace, selected: Bool, compact: Bool, profileTitle: String? = nil) {
        isSelectedSpace = selected
        displayedEmoji = selected ? space.emoji : ""
        displayedSymbol = selected && displayedEmoji.isEmpty ? space.displaySymbol : nil
        title = displayedEmoji
        imagePosition = displayedEmoji.isEmpty ? .imageOnly : .noImage
        font = .systemFont(ofSize: 14)
        image = displayedSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        contentTintColor = NSColor(space.color.tint)
        let owner = profileTitle.map { ", \($0)" } ?? ""
        toolTip = (compact ? "All Spaces — \(space.title)" : space.title) + owner
        setAccessibilityLabel((compact ? "All Spaces, current Space \(space.title)" : "Switch to Space \(space.title)") + owner)
        setAccessibilitySelected(selected)
        setAccessibilityValue(selected ? "Selected" : "Not selected")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !isSelectedSpace {
            (isEnabled ? NSColor.secondaryLabelColor : .disabledControlTextColor).setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 2, y: bounds.midY - 2, width: 4, height: 4)).fill()
        }
    }
}

struct SpaceIcon: View {
    let space: BrowserSpace
    var body: some View {
        Group {
            if space.emoji.isEmpty { Image(systemName: space.displaySymbol).foregroundStyle(space.color.tint) }
            else { Text(space.emoji).font(.system(size: 14)) }
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
                SpaceIcon(space: space).frame(width: 14, height: 14)
                Text(space.title).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                Button { editor = SpaceEditorRequest(space: space) } label: {
                    Image(systemName: "ellipsis").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Edit Space name and icon")
                .accessibilityLabel("Edit Space \(space.title)")
                .popover(item: $editor, attachmentAnchor: .rect(.bounds), arrowEdge: .trailing) { request in
                    SpaceEditor(browser: browser, space: request.space)
                }
                .chromePresentation(isPresented: editor != nil, controller: browser.chromeHover, region: .sidebar)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.primary)
            .help("\(space.title) — \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")")
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Space \(space.title), \(browser.spaces.profiles.profile(space.profileID)?.title ?? "Profile unavailable")")
            .onChange(of: browser.activeSpaceID) { _, _ in editor = nil }
        }
    }
}

private struct SpaceEditor: View {
    let browser: BrowserModel
    let space: BrowserSpace?
    @State private var name: String
    @State private var symbol: String
    @State private var emoji: String
    @State private var color: FolderColor
    private let theme: BrowserSpaceTheme
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
        _selectedProfileID = State(initialValue: space?.profileID ?? browser.profileID)
        _symbol = State(initialValue: space?.displaySymbol ?? "globe")
        _emoji = State(initialValue: space?.emoji ?? "")
        _color = State(initialValue: space?.color ?? .primary)
        theme = space?.theme ?? .system
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(space == nil ? "New Space" : "Edit Space").font(.headline)
            Text("Spaces in the same profile share logins. Different profiles keep website data separate.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Space name", text: $name).textFieldStyle(.roundedBorder).focused($nameIsFocused)
                .accessibilityLabel("Space name")
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
                Text("Separate cookies, website data, history, bookmarks, and site settings. "
                     + "Extensions and password autofill are not available. App Settings still manage the Existing Profile. "
                     + "Tracker protection and app preferences apply to all profiles. Downloads save to the shared Downloads folder.")
                    .font(.callout).foregroundStyle(.secondary)
                #if DEBUG
                Text("Debug and QA website data are temporary, even for named profiles.")
                    .font(.callout).foregroundStyle(.secondary)
                #endif
            }
            SavedItemIconPicker(symbol: $symbol, emoji: $emoji, color: $color, emojiAccessibilityLabel: "Space emoji")
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
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
        .padding(20).frame(width: 390)
        .background(ChromePresentationMarker(identifier: "BrowserSpaceEditorPopover"))
        .onAppear { nameIsFocused = true }
    }

    private func save() {
        do {
            guard !browser.isPrivate, !browser.isExtensionWindow else { throw BrowserSpaceStore.Failure.unavailable }
            let legacyIcon = BrowserSpaceIcon.allCases.first { $0.symbol == symbol } ?? space?.icon ?? .circle
            if let space {
                try browser.spaces.updateSpace(space.id, title: name, icon: legacyIcon, theme: theme, symbol: symbol, emoji: emoji, color: color)
            } else {
                if selectedProfileID == newProfileChoice {
                    selectedProfileID = try browser.spaces.profiles.create(title: newProfileName).id
                }
                try browser.createSpace(title: name, profileID: selectedProfileID, icon: legacyIcon, theme: theme,
                                        symbol: symbol, emoji: emoji, color: color)
            }
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
