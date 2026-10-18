# Browser

A native macOS browser built with SwiftUI and WebKit.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [just](https://github.com/casey/just) (`brew install just xcodegen`)

## Build and run

```sh
just
```

This generates the Xcode project, builds with local ad-hoc signing, symlinks **/Applications/Browser-Debug.app** to the build, and launches it. Repeating the command rebuilds and relaunches the debug app. Existing non-symlink apps are never overwritten.

`just release` builds, symlinks, and launches **/Applications/Browser.app**. `just build` builds without deployment; `just test` runs the test suite. Keep this checkout and its `DerivedData` folder in place while using the symlinks.

Debug builds use `assets/Browser_Debug.icns`; Release builds use `assets/Browser_Release.icns`. Each build includes only its own app icon.

Release builds strip local linker symbols before signing. Debug information remains in the separate dSYM beside the build product, outside the app bundle; both Intel and Apple Silicon architectures are retained.

Debug and release share the `dev.athas.browser` sandbox identity, settings, extensions, and WebKit's persistent disk profile (cookies, local storage, IndexedDB, and extension login state). Deployment quits the running variant before switching. The first deployment migrates data from the former debug sandbox when the corresponding shared data is absent, preserving the old copy. A small private `Session.json` saves the last focused browser window's tab URLs and selection; background tabs restore lazily. Credentials stay in WebKit or the system credential provider, with no extra cookie or password export. Tests use an isolated, nonpersistent website store.

## Tabs and glass

Restored and suspended tabs fetch favicons from the shared icon cache or lightweight icon requests without loading their webpages. Inactive loaded tabs and pinned-page icons are slightly dimmed; unloaded pages are dimmer. Hover and selection brighten them. Sidebar titles use the row’s remaining width; space for the close button is reserved when it is visible. The one-point resize grip has a wider hover target and becomes more prominent nearby. The existing window background uses macOS’s frosted titlebar material.


The address bar, navigation controls, extension buttons, and selected tabs use native Liquid Glass. Vertical tabs normally occupy a pinned sidebar. Turn on **Automatically Hide Sidebar** in Settings or press **⌘S** to let the page fill the window. Hover at the left edge (or click the sidebar button) to reveal a floating glass panel with rounded corners, inset spacing, and a shadow. It hides after the pointer leaves. Press **⌘S** again to pin it.

Press **⌃⌘S** to toggle auto-hide for the toolbar independently of the sidebar. Press **⌘S** to toggle sidebar auto-hide or pin it; in horizontal mode this switches to vertical tabs with an auto-hiding sidebar. Hovering the top edge reveals the header's native glass over the webpage; the left edge reveals only the floating sidebar. The two hover regions reveal and hide independently. With horizontal tabs or a pinned sidebar, revealing the toolbar restores the complete native chrome and its normal content inset. Floating vertical reveals sit one chrome-width inside the page’s outer chrome, with matching top and side insets. Address editing, menus, popovers, and toolbar customization keep their controls available until dismissed. Fullscreen uses the same saved toolbar layout, including dividers, spaces, and extension actions, as a glass overlay over the page.

Press **⌘G** (or **⌘L**) to reveal the address bar and select its entire URL. Press **⌘G** again to return focus to the page and hide the compact toolbar in the same action. Focus loss dismisses the compact toolbar; submitting an address keeps it open until the page reports first contentful paint. Focusing the address bar while using the revealed sidebar keeps that sidebar open and reveals the toolbar too. Hovering the sidebar or pinning it does not reveal the toolbar. The next page’s first contentful paint dismisses compact chrome. Documents without paint-observer support use load completion as a fallback. Both docked and floating sidebars leave room below the toolbar when it is revealed. Reveals use the existing native toolbar and window material; the floating sidebar retains its Liquid Glass surface. **Toolbar Display** in the toolbar’s right-click menu selects icons, text, or both and remembers the choice through SwiftUI’s native toolbar setting.

Right-click the toolbar and choose **Customize Toolbar…** to open macOS's native drag-and-drop toolbar palette. Sidebar layout/pin controls are available alongside individual navigation and extension controls. Add dividers, **Space**, or **Flexible Space** to separate groups; drag the native default set into the toolbar to restore the app's original setup. The address field stays available and expands naturally between the toolbar controls. Drag the sidebar’s right edge to resize it in docked or floating mode; both modes share the saved width. Horizontal tabs occupy the titlebar above the address field. The toolbar context menu groups auto-hide, address focus, tab layout, sidebar behavior, bookmark visibility, display style, and customization. Empty sidebar space provides tab/folder creation and sidebar settings; tab and folder menus contain actions for the clicked item. Back/Forward retain their history menus, and editing an address retains its native text menu. Settings also provides sidebar width and row density.

The default toolbar places sidebar/layout and Back, Forward, Reload controls on the left, the expanding address field next, and Downloads, enabled extension actions, Settings, and New Tab (horizontal mode) on the right. Pinned Pages appears by default in horizontal mode. Extra sidebar and pin controls are available in the native palette. These toolbar controls use Liquid Glass. Dividers break the shared glass between adjacent buttons, so their placement controls grouping. The address field fills spare width unless a flexible space shares it. Vertical tabs start just below it with a small aligned inset. **New Tab** is a plain row after the last vertical tab; when the list is full, that row stays pinned at the bottom while the tabs scroll. The toolbar New Tab button uses Liquid Glass. Both New Tab buttons and ⌘T focus the address field automatically.

Right-click a webpage tab and choose **Pin Page** to keep it. Up to nine pins occupy an adaptive glass grid of compact 40 pt tiles above the sidebar list; the selected tile uses translucent glass tinted from the site’s brand or favicon. In horizontal mode, use the **Pinned Pages** toolbar button or **Tabs → Pinned Pages**. Pins save immediately to disk independently of the window session, survive crashes, and load on demand. Closing a loaded pin’s tab keeps its tile; right-click the tile to unpin it.

Choose **New Folder…** from the empty sidebar’s context menu or **Tabs** menu to organize saved pages. Folder creation and editing open in a popover beside the sidebar row, or the Folders toolbar control in horizontal mode. Click outside or press Escape to dismiss it without saving. Folders support nested folders, custom symbols, emoji, icon colors, and persistent collapse state. Drag a tab onto a folder to save it there, drag a folder onto another to nest it, or use **Move to Folder** in an item’s context menu. Dropping near a row’s top edge reorders it; the gap below the saved items moves an item back to the sidebar root. Right-click a folder for **New Nested Folder…**, **Add Current Page**, or **Edit Name and Icon…**. Removing a folder keeps its contents at the former location.

Folders and their saved page descriptors write immediately to a private `TabFolders.json`, independently of window sessions and shared by Debug and Release. Closing a saved page leaves its item in place; clicking it reuses its tab or loads it on demand. **Move to Temporary Tabs** makes a saved item an ordinary tab. In horizontal mode, open folder pages remain in the tab strip and the customizable **Folders** toolbar button provides the saved tree. Folder membership is also preserved in session snapshots; selecting a saved page with a keyboard shortcut reveals its containing folders.

Settings and the shared right-click menu have separate **Show Bookmarks Bar** and **Show Bookmark Button** toggles. Right-click the star to hide it directly. You can restore it from the toolbar’s menu; ⌘D continues to work when the star is hidden.

| Shortcut | Action |
| --- | --- |
| ⌘S | Auto-hide / pin the vertical sidebar |
| ⌃⌘S | Auto-hide / pin the toolbar |
| ⇧⌘S | Save Webpage As… (`.webarchive`, including page resources) |
| ⌥⌘S | Switch between horizontal and vertical tabs |

Right-click webpage content for WebKit’s native link, image, selection, and editing commands, plus Back, Forward, Reload Page, Copy Page Address, Save Webpage As…, and Pin/Unpin Tab. **Inspect Element** is available in Debug and Release builds and inspects the clicked DOM element. **⌥⌘I** opens Web Inspector from the Develop menu. Inspector access and page-menu customization use guarded private WebKit hooks; inspected tabs are kept loaded.

## Extensions

Safari Web Extensions and bundled content-blocker rules in **Applications** and your user Applications folder appear automatically in **Browser → Settings → Extensions**. **Check for Extensions** rescans without restarting. New extensions start disabled; enable one to review its permissions and website access. Previously enabled extensions restore on launch and their individual toolbar actions update when loading completes. Discovery recognizes previously imported app extensions and preserves their identity, enabled state, and WebKit storage.

For development, expand **Development → Import Extension…** to load an unpacked Web Extension folder, ZIP archive, Safari extension app, or content-blocker JSON. Resources are copied into Browser's profile so browser rebuilds and switching debug/release don't depend on the original import path.

Browser hosts Web Extensions with WebKit’s public `WKWebExtensionController` API, including tab/window access, content scripts, extension storage, permission requests, options pages, and action popups. Compatibility depends on the APIs an extension uses; importing an extension does not share its Safari login or storage. Dashlane’s installed Safari Web Extension can be imported; sign in within Browser separately.

Extension background pages, toolbar popups and verification tabs use the same browser user-agent settings. Extension-created windows and JavaScript popups from extension pages have native windows. Browser swaps web views when navigation crosses between an extension origin and an ordinary website, as WebKit requires. The test suite checks page-load completion, the content-script message exchange used by client-verification flows, origin transitions, and extension-page restoration. A successful extension load alone does not confirm that an account login or third-party client verification will succeed.

Native **Safari App Extensions** and Safari companion **native messaging** cannot be hosted here. 1Blocker’s Scripts extension requires that messaging, so Browser reports it as unavailable and separately loads its bundled content-blocking rules. Discovery selects real rules instead of placeholder JSON and updates previously imported lists while retaining their enabled state. Installed-app updates are picked up on launch or **Check for Extensions**. Categories shipping only placeholders report that they are unavailable rather than claiming to block content. Live Safari settings and custom rules stored by the companion app are not synchronized.

Content blockers also appear in the native toolbar customization palette, grouped by their source app. The **1Blocker** toolbar control uses its app icon and shows list toggles, active rule counts, errors, and **Reload This Page**. Rule counts describe loaded rules, not a count of blocked requests. Existing, newly created, and restored pages receive enabled rule lists; reload an already loaded page after changing a list.

## Passkeys

WebKit handles website WebAuthn requests and validates origins. Browser provides a passkey access control in Settings for iCloud Keychain and configured system credential providers, including Dashlane when enabled in macOS.

Apple requires approval for the managed [`com.apple.developer.web-browser.public-key-credential` entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential). Ordinary ad-hoc debug builds cannot use system passkeys for arbitrary websites. Once your Apple Developer team has approval and a matching provisioning profile, deploy with:

```sh
just deploy-signed YOUR_TEAM_ID
```

This uses `BrowserPasskeys.entitlements` and automatic development signing. Both app variants register HTTP/HTTPS URL handling, as required for browser passkey eligibility. Open Settings → Passkeys → **Enable Passkeys…** to request system access. Apple’s entitlement approval and end-to-end authentication require the approved signed build; adding an entitlement to an unsigned/ad-hoc app does not grant that capability.

## Contributing

See the [contributing guide](CONTRIBUTING.md). Pull requests can only be merged once you agree to the [Contributor License Agreement](CONTRIBUTOR_LICENSE_AGREEMENT.md).

## License

Copyright (C) 2026 Athas

Browser is licensed under the [GNU Affero General Public License v3.0](LICENSE) or later. Athas may also distribute it under other terms, such as through the Mac App Store.
