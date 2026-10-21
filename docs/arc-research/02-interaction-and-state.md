# Interaction and state

## 1. Spaces must be data scope, not a filter

### Arc evidence

A01 contains space state, profile-related names, and the text: “Spaces give you separate sidebars for projects, work, life, and hobbies.” This supports separate context as a product concept. It does not prove the storage schema or account-isolation rules.

### Current code

[BrowserModel.swift](../../Sources/Browser/BrowserModel.swift) owns one live tab array and one selected tab. [TabFolders.swift](../../Sources/Browser/TabFolders.swift) and [PinnedPages.swift](../../Sources/Browser/PinnedPages.swift) use shared ordinary-mode stores. [BrowserProfile.swift](../../Sources/Browser/BrowserProfile.swift) supplies the ordinary WebKit data store.

Current source excerpt:

```swift
private(set) var tabs: [BrowserTab] = []
var activeTabID: UUID? {
    didSet {
        // Selection, page restoration, and focus updates follow here.
    }
}
```

The comment above replaces the body for this excerpt. It is not a proposed replacement for that body.

A sidebar-only filter would leave commands, splits, session saves, and link routing with unclear ownership. It could also imply account isolation that does not exist.

### Proposed design

Design sketch. This is not recovered Arc code or a build-ready patch:

```swift
struct SpaceDescriptor: Codable, Identifiable {
    let id: UUID
    var title: String
    var profileID: UUID
    var pinnedPageIDs: [UUID]
    var essentialPageIDs: [UUID]
}

struct SpaceSession: Codable {
    var spaceID: UUID
    var tabs: [TabSession]
    var selectedTabID: UUID?
}
```

A profile owns login and website data. A Space owns navigation context. Several Spaces may use one profile. Each live tab needs an unambiguous Space owner. Split members must belong to the same Space and profile.

On first migration, put existing state into one default Space. Do not duplicate saved IDs or eagerly load every tab. Keep the previous session file as a recovery copy. Private windows must not write Space or archive state into ordinary stores.

### Better interaction

- Show the active Space name near its switch control.
- Give each Space a stable selected tab.
- Keep Essential Tabs scope explicit. Decide whether it is per Space or per profile before migration.
- Let a tab move between Spaces with one action and undo.
- Preserve focus when changing Space. Do not select the address field unless the user requests it.

## 2. Archive is not suspension

### Arc evidence

A02 records `AutoArchiveTimeThresholdsPerProfile`, `autoArchiveTimer`, and archive education/settings names. These show an archive feature and configurable state. They do not establish the default duration or the timer algorithm.

### Current code

[TabSuspender.swift](../../Sources/Browser/TabSuspender.swift) checks idle tabs every minute. Its idle interval is ten minutes. Under memory pressure it selects part or all of the eligible background tabs.

[BrowserTab.swift](../../Sources/Browser/BrowserTab.swift) releases the web view and retains interaction state:

```swift
suspendedState = webView.interactionState
// Delegate, observation, and task cleanup occurs here.
webView.removeFromSuperview()
self.webView = nil
```

This reduces live page resources. It does not remove a tab from the sidebar. It does not create a durable archive entry. The omitted cleanup must remain in production code.

### Proposed design

Design sketch:

```swift
struct ArchivedTab: Codable, Identifiable {
    let id: UUID
    let spaceID: UUID
    let url: URL
    let title: String
    let archivedAt: Date
    let interactionState: Data?
}
```

Use a persistent wall-clock timestamp for “last used” across restarts. Keep `ContinuousClock` for current-process idle work. A monotonic process clock is not a durable archive timestamp.

Before removing a temporary tab:

1. Recheck that it is not visible, loading, playing media, capturing media, or linked to a live popup.
2. Exclude saved tabs and the complete visible split group.
3. Check dirty-page state. If that state is unknown, use a conservative policy.
4. Write the archive entry durably.
5. Remove the live descriptor only after that write succeeds.
6. Offer undo and an Archive view with restore.

Restoring must not replace an unrelated live tab. Reuse a stable identity or create an explicit restore mapping. Handle a tab that becomes pinned while the archive write is pending.

These rules are proposed Browser safeguards. Arc's exact exclusions were not recovered.

## 3. A command bar should select results, not guess actions

### Arc evidence

A06 has command-bar and tab-switcher names. P03 and P04 contain intent-classification contracts. Their presence does not show when Arc calls a model or how it ranks ordinary suggestions.

### Current code

[BrowserWindow.swift](../../Sources/Browser/BrowserWindow.swift), `editAddress`, calls this on each edit:

```swift
suggestions = AddressSuggestions.rank(text,
    pages: browser.history?.pages ?? [],
    bookmarks: bookmarks.bookmarks)
```

[AddressSuggestions.swift](../../Sources/Browser/AddressSuggestions.swift) combines history and bookmarks, ranks the complete match set, sorts it, and returns six items. A result has a URL, not a typed action. It does not represent a live tab or a command.

### Proposed design

Design sketch:

```swift
enum CommandResult {
    case switchTab(spaceID: UUID, tabID: UUID)
    case openURL(URL)
    case runCommand(CommandID)
    case search(String)
}
```

`CommandID` is a proposed application command registry, not an existing type.

Use one result model for both the compact address field and an expanded command surface. Keep the existing native text editor and its completion behavior. A live tab result switches to that tab. It must not navigate its page or discard its form state.

Group results by type. Show “Switch to tab”, “Open bookmark”, or “Run command” as an action label. Make the selected action visible before Return. If a result points into another Space, show that Space and switch context explicitly.

Do not call a model while the user types. An optional natural-language action can run after an explicit command. It must produce a preview of destinations, not execute the model's plan directly.

## 4. Pinned navigation and Peek

### Current implementation is already strong

[PeekPage.swift](../../Sources/Browser/PeekPage.swift) compares a target with the saved page's host. [BrowserModel.swift](../../Sources/Browser/BrowserModel.swift), `shouldPeek`, limits automatic Peek to the active saved tab and a web URL. `expandPeek` inserts the same temporary `BrowserTab` into the ordinary tab array:

```swift
tabs.insert(previous.tab, at: insertion)
activeTabID = previous.tab.id
previous.tab.didBecomeSelected()
requestSessionSave()
```

This preserves the live view, history, and page state. Keep this approach. Do not implement expansion as `load(url)` in a new web view.

### Arc comparison limit

A04 includes `PeekState` and two UI-copy literals: “Open a Peek window when clicking on links to other sites” and “Open a Peek window when clicking on links with Shift held”. These are concrete shipped interaction descriptions, not a live gesture test. A07 supports pane concepts. Neither establishes Arc's exact same-site rule or view-reuse mechanism. Browser's reuse mechanism is observed source, not a recovered Arc implementation.

[PageDelegate.swift](../../Sources/Browser/PageDelegate.swift) handles Command/middle-click before automatic saved-tab Peek. The reviewed navigation branch has no explicit Shift-click Peek action. Add an optional Shift-click action for ordinary web links. Keep it separate from Shift-hover AI summaries. Preserve Command/middle-click precedence and reject non-web or extension-window targets. Test same-tab and new-window link paths; do not assume WebKit handles both through one callback.

### Improvements

- Keep Escape and outside-click dismissal consistent.
- Close Peek without changing the saved home address.
- When expanding, preserve focus and the exact live page.
- Recheck source-tab lifetime before delayed focus or navigation work.
- Keep transient link summary cards distinct from interactive live Peek pages.

`PinnedNavigation.isSameSite` intentionally handles the home host and its subdomains. It is not a public-suffix implementation. Test sibling subdomains and unrelated hosts before changing that policy.

## 5. External links: routing before a new window type

### Arc evidence

A04 contains Little Arc and Air Traffic Control names. It supports two concepts: a small external-link window and a routing control. The rule precedence and supported source-app conditions are not established.

### Current code

[ExternalURLRouter.swift](../../Sources/Browser/ExternalURLRouter.swift) filters accepted schemes, skips private/extension/closed destinations, and selects the front ordinary window. URLs wait in a queue if a normal window must open.

### Proposed design

Design sketch:

```swift
struct LinkRouteRule: Codable {
    var host: String
    var includesSubdomains: Bool
    var sourceBundleID: String?
    var destinationSpaceID: UUID
}
```

Do not reuse `BrowserAddress` to evaluate rules. Match normalized hosts, not arbitrary URL substrings. `example.com.evil.test` must not match `example.com`. Define precedence and display which rule matched.

If a rule has no valid destination, use the current ordinary-window fallback. Never route into a private profile unless the user explicitly chooses private browsing. If source application identity is unavailable, do not invent it from the URL.

An optional Little Arc-style window can follow later. It needs an explicit “Open in Space” action. Promotion should transfer or adopt the same live tab where possible. Browser already has a useful ownership example in `expandPeek`.

## 6. Splits, hover chrome, and saved rows

A07 contains split controller and dragger names. Browser already supports persistent two-pane groups. [SplitTabs.swift](../../Sources/Browser/SplitTabs.swift) sets `limit = 2` and protects visible members from suspension through `visibleTabIDs`.

Keep that limit until the layout, keyboard focus, and close behavior work well. “Arc-like” does not mean “increase the pane count”. Arc's exact current limit was not verified.

[ChromeHoverController.swift](../../Sources/Browser/ChromeHoverController.swift) already has independent sidebar and toolbar regions, a single pending hide task per region, and holds for menu tracking and presentation. Keep these event-driven rules. No evidence shows that copying an Arc timing constant would improve them.

Saved names already record manual, automatic, and original sources. Make Restore Original visible. A model result must not replace a manual edit, even if it finishes after the edit.
