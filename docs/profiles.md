# Spaces and profiles

A Space owns tabs and saved pages. A profile owns website data. Spaces that select the same profile share logins. Spaces that select different profiles do not share WebKit cookies or local storage.

Use **New Space → Profile** to select an existing profile or create a new one. Profile ownership does not change after a Space or tab is created. A live page is never moved into another profile.

## Sidebar and Space editing

The current Spaces presentation is inherited, not replaced. New and existing Spaces use the same anchored icon/emoji/colour picker as folders. New Space keeps profile selection and creation. Editing an existing Space cannot change its owner. The title, New Space button and indicator remain independent controls; the original sidebar material and docked alignment remain intact.

Named-profile context menus retain Profile Site Settings and Clear Profile Data. Their callbacks check the exact active Space and profile before acting. Settings capture their services before presentation and close when the active Space changes. Hidden, disabled, switched or dismantled native controls cannot reuse old profile actions.

The sidebar, overflow, indicator count and Control-number menu use the same descriptor-only eligible Space list. A missing profile does not become a misleading shortcut slot or count as a reachable Space. Its metadata remains available for recovery. Default-only labels and the single Edit Space context-menu action stay unchanged.

## Stored data

- The Existing Profile keeps its original WebKit default store and existing files. No login data is moved.
- Each new ordinary profile has a saved UUID for the public WebKit named-store API. Its history, bookmarks, camera and microphone permissions, and page zoom use `Profiles/<profile UUID>/` under the current application profile directory.
- Saved pages and Essential Tabs remain Space-scoped. The Default Space keeps its original files. Other Spaces keep their own files under `Spaces/<Space UUID>/`.
- Downloads have separate in-memory lists per ordinary profile. Files still save to the shared Downloads folder. Download permission decisions are profile-scoped and session-only.
- Session records contain Space and profile ownership. Background pages restore lazily. Unknown or mismatched owners remain recovery records; they do not load with default-profile cookies.
- Clearing all history removes only records that the current Space descriptors validate as belonging to that profile. Clearing and restore use the same validator. Unknown-Space records, descriptor/profile mismatches, and unavailable-owner recovery remain, even before restore classifies them. Open windows are not closed.

## External links

[Link Routing](link-routing.md) can target available Spaces in the Existing Profile or named ordinary profiles. Settings shows the owning profile and Space together. An ordinary window can switch to the destination's profile before opening a link. Unknown or unavailable destinations use the existing ordinary fallback; private windows are never selected. Listing and validating destinations uses descriptors only and does not load profile website data.

## Limits

Extensions, extension content blockers, and browser password save/autofill work only in the Existing Profile. Named profiles do not receive its extension controller or password scripts. Browser Settings labels this scope. The Space menu provides named-profile site settings and data clearing.

Built-in tracker protection, its exceptions, appearance, intelligence preferences, and other app preferences apply to all profiles. System credential and passkey sheets remain system-managed; a profile is not a separate macOS account.

Only the Existing Profile uses the durable favicon cache. Named and private icon views use uncached requests and view-local images. All auxiliary icon requests are cookie-free and credential-free. History, saved-page, split, bookmark, address-suggestion, and tab icons use this boundary. Clearing Existing Profile icons does not delete another profile's durable icons, because those icons are not stored.

Debug and QA named profiles always use nonpersistent WebKit stores. Their descriptors and local files stay under the disposable Debug/QA directory. They never enter the Release profile. Private windows do not select ordinary Spaces or resolve ordinary named stores.

Profile deletion, profile renaming, and profile-specific extensions or password vaults are not included. Restored WebKit interaction state does not grant new access to local files. The session tests check the real archived file history without broadening file-read grants.

## Provenance and validation

This is local Browser design based on the Arc research delivery plan. It is not a recovered Arc implementation. This feature adds no prompts or model calls. Automated tests cover separate same-site cookies/local storage, stable named-store identifiers, persistence, migration, lazy restore, unknown owners, private/QA isolation, background callbacks, anonymous icons, and profile-scoped recovery clearing. The latest Spaces parent and its shared appearance/visibility controls are integrated. Additional regression tests cover profile-owned appearance persistence, missing-owner ordering, default-only compatibility and retained native profile actions. GUI validation is separate; passing background-hosted XCTest fixtures is not physical-input or screenshot acceptance. No native screenshot parity is claimed. The current Space-local Essential scope is an explicit pending integration decision against Arc's cross-Space Favorites guidance, not a verified match.
