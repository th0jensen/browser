# Artifact and source evidence

## 1. Identity

Analysis target: Arc for macOS, version `1.169.0`, build `88758`. The plist reports release commit `Release-88758-f641642e5497f3b97ccbfc6fe31eff7a5a27cb54` and build date `14 Oct 2026, 19:26`. These are self-reported bundle fields.

| Item | SHA-256 |
| --- | --- |
| DMG | `9ea6ae7e62b8bdb70fdc078325da7ff4c62133cefc303af6e07e2b9a4aaf070b` |
| `Contents/MacOS/Arc` | `24e2aca39abd6645528b5f5e1241555a1ab5c925bb6e6c1e9ecaabdd2b83ed51` |
| `ArcCore.framework/Versions/A/ArcCore` | `cb05ce18370e379d87d331f0f0cdc15f511d872b96a5b03f3ded7ef520a3993b` |

The original DMG path is `/tmp/arc-rea/arc-latest.dmg`. REA resolved it under `/private/tmp`. The read-only analysis mount was `/tmp/arc-rea/mounted`. It was detached after inspection. Mount the DMG read-only again before rerunning byte inspection. No file from the app was installed over an existing application.

The DMG was already present. Origin and download time were not established here. A request to `https://releases.arc.net/release/Arc.dmg` returned HTTP 403. Do not call the input a freshly verified official download.

## 2. REA records

### R01: DMG inventory

- `inspect_artifact` parent: `ev_b30416cd69ae59e75d8e2941b93767a9fd658aa693f5f941a24d023bee6ab49a`.
- Summary: `ev_f7b9fc13f20c30b97c10665d50e955d8c7075a33f4595061b4a2ff9e99715fae`.
- Inventory: `ev_6d7ed0685d535d3f3517e2f1f6327adc7b1f706e03410c7d8cc166008b58a190`.
- Graph manifest: `agm_5bf2b731e79f61f93c994222f69bafedf1c44d5ef52042e48f36c45408f2b527`.
- Root SHA-256 matches the DMG identity above.
- Summary reports 1,489 nodes, 1,963 occurrences, 1,929 edges, and zero integrity contradictions.
- `source_complete: true` applies to that inventory, not to semantic feature analysis.

### R02: Info.plist

- Evidence: `ev_74b5f454a042856a648374f2010a4bee7f9d6b51fd8550416ceb9904bd13f661`.
- Operation: `inspect_plist` with explicit `Arc.app/Contents/Info.plist` path.
- Bundle identifier: `company.thebrowser.Browser`.
- Principal class: `Arc.BrowserApp`.
- Version/build: `1.169.0` / `88758`.
- Minimum OS field: `13.0.0`.
- Update feed: `https://releases.arc.net/updates.xml`.
- This plist call was made while the DMG was selected. Its Evidence subject is the DMG; the source plist path is explicit in parameters and result. Do not attribute the DMG digest as a separate plist-file digest.

### R03: main executable Mach-O

- Complete parent: `ev_7a3552a3479876986197bba6b38690793a48457416bd84e69caeee5a934d9efd`.
- Summary: `ev_4322373477687e2b9f5ce891d901ec1f01f6a86cc61edaeebde283716c61e221`.
- Selected architecture: ARM64.
- Universal-file slice offset: `86228992` (`0x523c000`).
- UUID: `48C4AC1D-03DC-3F0C-8725-6DB43D35C92C`.
- Two reported architectures, five segments, 86 dependencies.
- Imports/exports are not exhaustive. Page exhaustion does not prove symbol absence.

### R04: code-signing metadata

- Evidence: `ev_e01f52eeb7d5d000e6424ffc1bf7532e44dee5d2767e911d8b3e6e3f61d63731`.
- Identifier: `company.thebrowser.Browser`.
- Team: `S6N382Y83G`.
- Authority: `Developer ID Application: The Browser Company of New York Inc. (S6N382Y83G)`.
- Hardened runtime: reported true.
- Signing timestamp: `Oct 14, 2026 at 9:46:58 PM`.
- Entitlements include CloudKit container/service declarations, camera, microphone, location, and browser public-key credential access. Declared entitlements are not proof that these services ran.
- REA inspected a digest-verified byte snapshot. Filesystem-bound trust and full signature/notarization validation were not performed.

### R05: ArcCore Mach-O

- Complete parent: `ev_4a786fd62f6efe60b39af95cc6bfca39ae4c8196455458bba633d5b87079bfa5`.
- Summary: `ev_096bba1d0201692e9c3fa93ed57a26c9811773b1d89915b2d4c2f3ca553d228d`.
- Selected architecture: ARM64.
- Universal-file slice offset: `259719168`.
- UUID: `4C4C4498-5555-3144-A130-0BA4CDDC5F11`.
- Two reported architectures, five segments, 67 dependencies.
- Imports/exports are not exhaustive.

## 3. Literal inspection method

S01 is the main-executable byte inspection. S02 is the ArcCore byte inspection. They are local analysis records, not REA Evidence IDs. A Python script read Mach-O headers, selected CPU type `0x100000c`, and walked `LC_SEGMENT_64` sections. It searched candidate text in `__cstring`, `__const`, `__swift5_reflstr`, `__objc_methname`, and `__objc_classname`.

The candidate scan used runs of at least five bytes. Some candidates are metadata fragments, not formal symbol definitions. Invalid UTF-8 candidates are excluded from the tables below. Exact prompt extraction separately walked zero-terminated `__cstring` records and preserved complete literal text. Other sections, compressed/encrypted resources, remote configuration, and service-side prompts are outside this search boundary.

For a byte at offset `d` within a section, the recorded virtual address is `section.addr + d`. Its universal-file offset is `slice.offset + section.offset + d`. These are static coordinates, not runtime ASLR addresses.

The following tables are selected evidence, not complete inventories. Leading and trailing whitespace is trimmed for table display; the prompt appendix preserves literal content. A row proves only that its text is present at the recorded location. A source path in a binary is not access to that source file. A telemetry key is not a performance result.

## A01: Spaces, profiles, saved tabs, and Favorites

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x103941a90` | `0x8b7da90` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Browser/Sidebar/SidebarCells/SidebarSpaceState+SplitView.swift |
| `0x103941b00` | `0x8b7db00` | `__TEXT,__cstring` | Arc/SidebarSpaceState+SplitView.swift |
| `0x103948e50` | `0x8b84e50` | `__TEXT,__cstring` | Arc.PinnedTabSectionEduBanner |
| `0x103948e70` | `0x8b84e70` | `__TEXT,__cstring` | Arc/PinnedTabSectionEduBanner.swift |
| `0x10395d500` | `0x8b99500` | `__TEXT,__cstring` | https://resources.arc.net/hc/en-us/articles/19233788518039-Notes-Quickly-Jot-to-an-Arc-Note-or-Your-Favorite-Notes-App |
| `0x10395f760` | `0x8b9b760` | `__TEXT,__cstring` | autoDisableAdBlockOnAllowListedURLsCompleteProfileIDs |
| `0x10395f8d0` | `0x8b9b8d0` | `__TEXT,__cstring` | renamePinnedTabsEnabled |
| `0x10395fdb0` | `0x8b9bdb0` | `__TEXT,__cstring` | excludeFavoritesInSwitchToNthTab |
| `0x103971cd0` | `0x8badcd0` | `__TEXT,__cstring` | sidebarSpacePinnedTabsExpansionToggler |
| `0x103971d80` | `0x8badd80` | `__TEXT,__cstring` | sidebarFavoritesEmptyStateDismissButton |
| `0x103971db0` | `0x8baddb0` | `__TEXT,__cstring` | sidebarFavoritesCollectionView |
| `0x103978810` | `0x8bb4810` | `__TEXT,__cstring` | clearUnpinnedTabs |
| `0x10397b0f0` | `0x8bb70f0` | `__TEXT,__cstring` | unpinnedTabsHeader |
| `0x10397b110` | `0x8bb7110` | `__TEXT,__cstring` | pinnedTabsFooter |
| `0x10397b130` | `0x8bb7130` | `__TEXT,__cstring` | pinnedTabsHeader |
| `0x10398a420` | `0x8bc6420` | `__TEXT,__cstring` | replacePinnedTab |
| `0x1039babe0` | `0x8bf6be0` | `__TEXT,__cstring` | Each Profile has different browser data, so you might get logged out of some websites, see different Favorites up top, or need to re-install extensions. |
| `0x1039f21e0` | `0x8c2e1e0` | `__TEXT,__cstring` | Spaces give you separate sidebars for projects, work, life, and hobbies. |
| `0x103a06a90` | `0x8c42a90` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/SharedWindowFeature/SidebarSpaceState.swift |
| `0x103a06b00` | `0x8c42b00` | `__TEXT,__cstring` | SharedWindowFeature/SidebarSpaceState.swift |
| `0x103a2bf40` | `0x8c67f40` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/ContextMenus/SidebarSpaceState+SpaceContextMenu.swift |
| `0x103a2bfc0` | `0x8c67fc0` | `__TEXT,__cstring` | ContextMenus/SidebarSpaceState+SpaceContextMenu.swift |

## A02: Archive state and settings

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x10373ecb0` | `0x897acb0` | `__TEXT,__const` | AutoArchiveTimeThresholdsPerProfile |
| `0x103947100` | `0x8b83100` | `__TEXT,__cstring` | Reset Auto-Archive EDU |
| `0x103947120` | `0x8b83120` | `__TEXT,__cstring` | Simulate Auto-Archive |
| `0x1039483b0` | `0x8b843b0` | `__TEXT,__cstring` | https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go |
| `0x103960280` | `0x8b9c280` | `__TEXT,__cstring` | eligibleToSeeAutoArchiveEducationBanner |
| `0x1039602b0` | `0x8b9c2b0` | `__TEXT,__cstring` | autoArchiveTimeThresholdsPerProfile |
| `0x1039602e0` | `0x8b9c2e0` | `__TEXT,__cstring` | autoArchiveLittleArcTimeThreshold |
| `0x103960310` | `0x8b9c310` | `__TEXT,__cstring` | autoArchiveTimeThreshold |
| `0x103978902` | `0x8bb4902` | `__TEXT,__cstring` | autoArchive |
| `0x10398c440` | `0x8bc8440` | `__TEXT,__cstring` | onSetAutoArchiveLittleArcTimeThreshold |
| `0x10398c470` | `0x8bc8470` | `__TEXT,__cstring` | onSetAutoArchiveTabsTimeThresholdForProfile |
| `0x10398c4a0` | `0x8bc84a0` | `__TEXT,__cstring` | onSetAutoArchiveTimeThreshold |
| `0x10399ae60` | `0x8bd6e60` | `__TEXT,__cstring` | auto_archive_education_dismissed |
| `0x10399ae90` | `0x8bd6e90` | `__TEXT,__cstring` | auto_archive_education_displayed_when_tabs_auto_archive |
| `0x1039b22f0` | `0x8bee2f0` | `__TEXT,__cstring` | per-profile-auto-archive-pref-available |
| `0x1039b2cc0` | `0x8beecc0` | `__TEXT,__cstring` | auto-archive-little-arc-windows-enabled |
| `0x1039bc470` | `0x8bf8470` | `__TEXT,__cstring` | autoArchiveStartTime |
| `0x1039bc6c0` | `0x8bf86c0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/Archive/ArchiveState+AutoArchive.swift |
| `0x1039bc730` | `0x8bf8730` | `__TEXT,__cstring` | Archive/ArchiveState+AutoArchive.swift |
| `0x1039ea610` | `0x8c26610` | `__TEXT,__cstring` | setAutoArchiveTabsTimeThresholdForProfile(state:profile:archiveType:threshold:) |
| `0x1039ea6c0` | `0x8c266c0` | `__TEXT,__cstring` | Format for message in dialog offering to update all profiles to reflect changes to auto-archive preferences. |
| `0x1039ea950` | `0x8c26950` | `__TEXT,__cstring` | setAutoArchiveTabsTimeThresholdForAllProfiles(state:archiveType:threshold:) |
| `0x1039ec3a0` | `0x8c283a0` | `__TEXT,__cstring` | Manage your default search engine, Auto-Archive, and downloads in Profile Settings. |
| `0x103d848c0` | `0x8fc08c0` | `__TEXT,__swift5_reflstr` | autoArchiveTimer |

## A03: Page lifecycle and discard

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x10393e790` | `0x8b7a790` | `__TEXT,__cstring` | Title for the list of windows in the web lifecycle debug tool |
| `0x10393e7d0` | `0x8b7a7d0` | `__TEXT,__cstring` | Title for the list of tabs in the web lifecycle debug tool |
| `0x103941640` | `0x8b7d640` | `__TEXT,__cstring` | Web Lifecycle Debugger |
| `0x103941660` | `0x8b7d660` | `__TEXT,__cstring` | Window title of the web lifecycle debugger utility |
| `0x103946af0` | `0x8b82af0` | `__TEXT,__cstring` | Title for a menu option that opens the web lifecycle debugging utility |
| `0x1039563a0` | `0x8b923a0` | `__TEXT,__cstring` | tryToClose(skipBeforeUnloadHandlers:) |
| `0x103958410` | `0x8b94410` | `__TEXT,__cstring` | Web content is unloaded |
| `0x103958450` | `0x8b94450` | `__TEXT,__cstring` | Web content has been discarded |
| `0x10395a320` | `0x8b96320` | `__TEXT,__cstring` | Web content came to SessionRestorationBrowserDelegate that doesn't have window id set. It would be impossible to bind later so it got discarded. |
| `0x10395a620` | `0x8b96620` | `__TEXT,__cstring` | didRestoreWebContent came to SessionRestorationBrowserDelegate that doesn't have window id set. It would be impossible to bind later so it got discarded. |
| `0x1039803d0` | `0x8bbc3d0` | `__TEXT,__cstring` | ADKClient.discardWebContent |
| `0x103980fe0` | `0x8bbcfe0` | `__TEXT,__cstring` | ADKClient._requestWebContentDiscard |
| `0x103991120` | `0x8bcd120` | `__TEXT,__cstring` | discardedRedundant |
| `0x103991143` | `0x8bcd143` | `__TEXT,__cstring` | discardedError |
| `0x103992880` | `0x8bce880` | `__TEXT,__cstring` | sync_inbound_orphan_discarded |
| `0x1039929a0` | `0x8bce9a0` | `__TEXT,__cstring` | unloaded_data_types |
| `0x103996da0` | `0x8bd2da0` | `__TEXT,__cstring` | discard_on_low_memory_policy_metrics |
| `0x103997c00` | `0x8bd3c00` | `__TEXT,__cstring` | discarded_web_content_count |
| `0x1039a58b8` | `0x8be18b8` | `__TEXT,__cstring` | Discarding session: %@ |
| `0x1039b9050` | `0x8bf5050` | `__TEXT,__cstring` | Time Decay: Discarded (Wall Clock) |
| `0x1039b9080` | `0x8bf5080` | `__TEXT,__cstring` | Time Decay: Discarded |
| `0x1039dccb0` | `0x8c18cb0` | `__TEXT,__cstring` | [Easel] We are abandoning an in-flight edit session, please either commit or discard your changes. |

## A04: Peek, Little Arc, and link routing

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x1037b6284` | `0x89f2284` | `__TEXT,__const` | PeekState |
| `0x10393e610` | `0x8b7a610` | `__TEXT,__cstring` | little_arc_extensions |
| `0x103948f90` | `0x8b84f90` | `__TEXT,__cstring` | WindowConstants.isLittleArc |
| `0x10395fb80` | `0x8b9bb80` | `__TEXT,__cstring` | didSyncLittleArcArchiveTime |
| `0x1039602e0` | `0x8b9c2e0` | `__TEXT,__cstring` | autoArchiveLittleArcTimeThreshold |
| `0x1039603a0` | `0x8b9c3a0` | `__TEXT,__cstring` | optionCommandClickLittleArcEntryPointEnabled |
| `0x10397f990` | `0x8bbb990` | `__TEXT,__cstring` | showLittleArcOpenInMenu |
| `0x10398a3a0` | `0x8bc63a0` | `__TEXT,__cstring` | openAirTrafficControl |
| `0x10398ab00` | `0x8bc6b00` | `__TEXT,__cstring` | littleArcPlaceholderClick |
| `0x10398c440` | `0x8bc8440` | `__TEXT,__cstring` | onSetAutoArchiveLittleArcTimeThreshold |
| `0x10398d535` | `0x8bc9535` | `__TEXT,__cstring` | peeked |
| `0x10398f3e6` | `0x8bcb3e6` | `__TEXT,__cstring` | littleArc |
| `0x103997c80` | `0x8bd3c80` | `__TEXT,__cstring` | little_arc_window_count |
| `0x10399bf10` | `0x8bd7f10` | `__TEXT,__cstring` | little_arc_moved_to_standard_window |
| `0x1039b3120` | `0x8bef120` | `__TEXT,__cstring` | peeked-modal-controls-alternate-order-enabled |
| `0x1039cd8a0` | `0x8c098a0` | `__TEXT,__cstring` | Toast indicating that Gmail must be auth.’d and favorited for email peeking. |
| `0x1039e7470` | `0x8c23470` | `__TEXT,__cstring` | explains a link opens in Peek mode |
| `0x1039ec990` | `0x8c28990` | `__TEXT,__cstring` | LittleArcHeroImage |
| `0x1039eca00` | `0x8c28a00` | `__TEXT,__cstring` | Open a Peek window when clicking on links to other sites |
| `0x1039eca80` | `0x8c28a80` | `__TEXT,__cstring` | Open a Peek window when clicking on links with Shift held |
| `0x1039ecb70` | `0x8c28b70` | `__TEXT,__cstring` | Peek is a way to preview a link without opening a new tab. It’s perfect for quickly looking at a link from an email, news article, or tweet. |
| `0x103a08bc0` | `0x8c44bc0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/SharedWindowFeature/WindowData+EmailPeeking.swift |
| `0x103a08c40` | `0x8c44c40` | `__TEXT,__cstring` | SharedWindowFeature/WindowData+EmailPeeking.swift |

## A05: Max, naming, grouping, and prompt infrastructure

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x103651df0` | `0x888ddf0` | `__TEXT,__const` | SidebarTidyButton |
| `0x103728ba0` | `0x8964ba0` | `__TEXT,__const` | TidyTabTitlesClient |
| `0x103729070` | `0x8965070` | `__TEXT,__const` | BundledTidyTitles |
| `0x103813a81` | `0x8a4fa81` | `__TEXT,__const` | PromptTemplate |
| `0x103813b00` | `0x8a4fb00` | `__TEXT,__const` | PrivateContentDetectionSystemPromptDynamic |
| `0x103813b50` | `0x8a4fb50` | `__TEXT,__const` | PrivateContentDetectionSystemPromptStatic |
| `0x103944320` | `0x8b80320` | `__TEXT,__cstring` | Button Title; Tidy unpinned tabs in this space |
| `0x10394cd90` | `0x8b88d90` | `__TEXT,__cstring` | Arc.SidebarTidyButton |
| `0x10395d030` | `0x8b99030` | `__TEXT,__cstring` | tidyTabTitlesFeedback |
| `0x103960c4f` | `0x8b9cc4f` | `__TEXT,__cstring` | tidyTabsEnabled |
| `0x10396ed30` | `0x8baad30` | `__TEXT,__cstring` | ChatGPTSiteSearchPreview |
| `0x10398c2b0` | `0x8bc82b0` | `__TEXT,__cstring` | onToggleTidyTabsEnabled |
| `0x10398e0b0` | `0x8bca0b0` | `__TEXT,__cstring` | chatGptMemoryOptIn |
| `0x10398f2ed` | `0x8bcb2ed` | `__TEXT,__cstring` | tidy_tabs |
| `0x10398f385` | `0x8bcb385` | `__TEXT,__cstring` | tidyTabs |
| `0x1039b2020` | `0x8bee020` | `__TEXT,__cstring` | tidyTabTitlesClient |
| `0x1039cb550` | `0x8c07550` | `__TEXT,__cstring` | ChatGPT in your Command Bar: |
| `0x1039cd410` | `0x8c09410` | `__TEXT,__cstring` | Toast accessory indicating that the user can open Arc Max Preferences to opt-in to ChatGPT in the Command Bar. |
| `0x1039cde20` | `0x8c09e20` | `__TEXT,__cstring` | ChatGPT in the Command Bar not enabled |
| `0x1039cde50` | `0x8c09e50` | `__TEXT,__cstring` | Letting user know that they need opt into ChatGPT in the Command Bar. |
| `0x1039ce460` | `0x8c0a460` | `__TEXT,__cstring` | Letting user know that their download rename by Tidy Downloads has been reverted. |
| `0x1039ce4e0` | `0x8c0a4e0` | `__TEXT,__cstring` | Letting user know that their download has been automatically renamed by Tidy Downloads. |
| `0x1039d02c0` | `0x8c0c2c0` | `__TEXT,__cstring` | tidyTabsFeedbackSubmitted |
| `0x1039e3170` | `0x8c1f170` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/LLM/OpenAI/ChatGPT.swift |
| `0x1039ecde0` | `0x8c28de0` | `__TEXT,__cstring` | Add ChatGPT to your Search suggestions, or start typing “ChatGPT”, hit Tab, to ask any question instantly. |
| `0x1039ed050` | `0x8c29050` | `__TEXT,__cstring` | tidyTabsDescription |
| `0x103a0ab10` | `0x8c46b10` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/SharedWindowFeature/WindowData+TidyTabTitles.swift |
| `0x103a0ab90` | `0x8c46b90` | `__TEXT,__cstring` | SharedWindowFeature/WindowData+TidyTabTitles.swift |

## A06: Command and tab search

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x1038081c0` | `0x8a441c0` | `__TEXT,__const` | LinearTabSwitcherSpaceState |
| `0x10393f470` | `0x8b7b470` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Browser/CommandBar/Placeholder/WindowState+CommandBarPlaceholder.swift |
| `0x10393f4f0` | `0x8b7b4f0` | `__TEXT,__cstring` | Arc/WindowState+CommandBarPlaceholder.swift |
| `0x1039418e0` | `0x8b7d8e0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBarAdditionalRankingDataStoreClient/Client.swift |
| `0x103943ff0` | `0x8b7fff0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Browser/Windows/Store/WindowState+CommandBarHelpers.swift |
| `0x103944060` | `0x8b80060` | `__TEXT,__cstring` | Arc/WindowState+CommandBarHelpers.swift |
| `0x1039485f0` | `0x8b845f0` | `__TEXT,__cstring` | Arc/CommandBarPlaceholderTextView.swift |
| `0x103949dd0` | `0x8b85dd0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBar/SearchClient.swift |
| `0x103949e40` | `0x8b85e40` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBar/Store/SearchEngineClient.swift |
| `0x103954620` | `0x8b90620` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBar/Instance/CommandBarIntegrationClient.swift |
| `0x1039f5fd0` | `0x8c31fd0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBar/Suggestions/Suggestion+ViewState.swift |
| `0x1039f6050` | `0x8c32050` | `__TEXT,__cstring` | CommandBar/Suggestion+ViewState.swift |
| `0x1039f6080` | `0x8c32080` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBar/Instance/CommandBarIntegrationClient+Implementations.swift |
| `0x1039f6110` | `0x8c32110` | `__TEXT,__cstring` | CommandBar/CommandBarIntegrationClient+Implementations.swift |
| `0x1039f6260` | `0x8c32260` | `__TEXT,__cstring` | CommandBar/CommandBarIntegrationClient.swift |
| `0x1039f6290` | `0x8c32290` | `__TEXT,__cstring` | CommandBar/SearchClient.swift |
| `0x1039f6e10` | `0x8c32e10` | `__TEXT,__cstring` | CommandBar/CommandBarDebugWindowController.swift |
| `0x1039f6f00` | `0x8c32f00` | `__TEXT,__cstring` | CommandBar/DefaultBrowserPromptView.swift |
| `0x1039f8470` | `0x8c34470` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBar/URLInputSearchClient+Live.swift |
| `0x1039f84e0` | `0x8c344e0` | `__TEXT,__cstring` | CommandBar/URLInputSearchClient+Live.swift |
| `0x103a02ea0` | `0x8c3eea0` | `__TEXT,__cstring` | CommandBarAdditionalRankingDataStoreClient/Client.swift |
| `0x103a02ee0` | `0x8c3eee0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/CommandBarAdditionalRankingDataStoreClient/CommandBarAdditionalRankingData.swift |
| `0x103a02f80` | `0x8c3ef80` | `__TEXT,__cstring` | CommandBarAdditionalRankingDataStoreClient/CommandBarAdditionalRankingData.swift |

## A07: Split presentation and pane controls

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x10393f200` | `0x8b7b200` | `__TEXT,__cstring` | Arc/SplitViewCellCustomInfoView.swift |
| `0x103940390` | `0x8b7c390` | `__TEXT,__cstring` | Arc/SplitViewDraggerHandleView.swift |
| `0x1039403f0` | `0x8b7c3f0` | `__TEXT,__cstring` | Arc/SplitViewCellChildrenContainerView.swift |
| `0x103940c30` | `0x8b7cc30` | `__TEXT,__cstring` | Arc/SplitViewCellChildItemView.swift |
| `0x103941a90` | `0x8b7da90` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Browser/Sidebar/SidebarCells/SidebarSpaceState+SplitView.swift |
| `0x103941b00` | `0x8b7db00` | `__TEXT,__cstring` | Arc/SidebarSpaceState+SplitView.swift |
| `0x103942f70` | `0x8b7ef70` | `__TEXT,__cstring` | Arc.WebContentViewControllerSplitView |
| `0x103947b20` | `0x8b83b20` | `__TEXT,__cstring` | Arc/SplitViewContentPlaceholderView.swift |
| `0x10394e530` | `0x8b8a530` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/WindowContents/SplitView/ContentToolbarInteractionTracker.swift |
| `0x103953b60` | `0x8b8fb60` | `__TEXT,__cstring` | Arc/SplitViewBottomDraggerHandleView.swift |
| `0x10396e920` | `0x8baa920` | `__TEXT,__cstring` | ARCUI/SplitViewContentPaneView.swift |
| `0x10396e9d0` | `0x8baa9d0` | `__TEXT,__cstring` | ARCUI/SplitViewController.swift |
| `0x1039725a0` | `0x8bae5a0` | `__TEXT,__cstring` | SwiftUIIntrospect/NavigationSplitView.swift |
| `0x1039f2f90` | `0x8c2ef90` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/WindowContents/Presentation/WindowContentPresentationMutationContext+SplitView.swift |
| `0x1039f3030` | `0x8c2f030` | `__TEXT,__cstring` | WindowContents/WindowContentPresentationMutationContext+SplitView.swift |
| `0x1039f33e0` | `0x8c2f3e0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/WindowContents/SplitView/SplitViewLayoutCache.swift |
| `0x1039f3480` | `0x8c2f480` | `__TEXT,__cstring` | WindowContents/SplitViewLayoutCache.swift |
| `0x1039fb220` | `0x8c37220` | `__TEXT,__cstring` | SidebarFeature/SidebarState+SplitView.swift |
| `0x103a0a200` | `0x8c46200` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/SharedWindowFeature/WindowData+SplitViewHelpers.swift |
| `0x103a0a280` | `0x8c46280` | `__TEXT,__cstring` | SharedWindowFeature/WindowData+SplitViewHelpers.swift |
| `0x103a0e580` | `0x8c4a580` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/SharedWindowsFeature/WindowsData+SplitView.swift |
| `0x103a0e600` | `0x8c4a600` | `__TEXT,__cstring` | SharedWindowsFeature/WindowsData+SplitView.swift |

## A08: Boosts and site customization

| Static address | Universal-file offset | Section | Text |
| --- | --- | --- | --- |
| `0x1037eddc0` | `0x8a29dc0` | `__TEXT,__const` | BoostsInstallationDialog |
| `0x1037ee0c0` | `0x8a2a0c0` | `__TEXT,__const` | BoostsInstallationDialogUI |
| `0x1039439a0` | `0x8b7f9a0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Browser/Windows/Store/WindowState+Boosts.swift |
| `0x103943a00` | `0x8b7fa00` | `__TEXT,__cstring` | Arc/WindowState+Boosts.swift |
| `0x1039464b0` | `0x8b824b0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARCClients/Sources/BoostsClient/BoostsClient.swift |
| `0x10399cd20` | `0x8bd8d20` | `__TEXT,__cstring` | BoostsClient/BoostsClient.swift |
| `0x10399cfb0` | `0x8bd8fb0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARCClients/Sources/BoostsClient/StorableBoostsDataStore.swift |
| `0x10399d140` | `0x8bd9140` | `__TEXT,__cstring` | BoostsClient/BoostsStorageFirebaseImpl.swift |
| `0x10399d170` | `0x8bd9170` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARCClients/Sources/BoostsClient/BoostsStorageFirebaseImpl.swift |
| `0x10399d2d0` | `0x8bd92d0` | `__TEXT,__cstring` | BoostsClient/StorableBoostsDataStore.swift |
| `0x10399d3a0` | `0x8bd93a0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARCClients/Sources/BoostsClient/UI_macOS/BoostFaviconView.swift |
| `0x10399d420` | `0x8bd9420` | `__TEXT,__cstring` | BoostsClient/BoostFaviconView.swift |
| `0x1039ac7c0` | `0x8be87c0` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/BoostsEditor/BoostsEditor.swift |
| `0x1039ac830` | `0x8be8830` | `__TEXT,__cstring` | BoostsEditor/BoostsEditor.swift |
| `0x1039ac870` | `0x8be8870` | `__TEXT,__cstring` | BoostsEditor/resource_bundle_accessor.swift |
| `0x1039acc70` | `0x8be8c70` | `__TEXT,__cstring` | BoostsEditor/BoostsEditorView.swift |
| `0x1039acd30` | `0x8be8d30` | `__TEXT,__cstring` | BoostsEditor/BoostsEditorWindowContent.swift |
| `0x1039acdb0` | `0x8be8db0` | `__TEXT,__cstring` | BoostsEditor/BoostsEditorWindowController.swift |
| `0x1039ace40` | `0x8be8e40` | `__TEXT,__cstring` | BoostsEditor/JS.swift |
| `0x1039acee0` | `0x8be8ee0` | `__TEXT,__cstring` | BoostsEditor/SelectorPicker.swift |
| `0x1039acf50` | `0x8be8f50` | `__TEXT,__cstring` | BoostsEditor/Assets.swift |
| `0x1039b0430` | `0x8bec430` | `__TEXT,__cstring` | SiteControlCenter/SiteControlCenterBoostsView.swift |
| `0x1039b9b30` | `0x8bf5b30` | `__TEXT,__cstring` | WebContent/WebContentState+Boosts.swift |
| `0x1039b9b80` | `0x8bf5b80` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/WebContent/WebContentState+Boosts.swift |
| `0x103a02840` | `0x8c3e840` | `__TEXT,__cstring` | /Users/admin/actions-runner/_work/arc/arc/Frameworks/ARC/Sources/BoostsDialog/BoostsInstallationDialog.swift |
| `0x103a028b0` | `0x8c3e8b0` | `__TEXT,__cstring` | BoostsDialog/BoostsInstallationDialog.swift |

## 4. ArcCore search boundary

ArcCore SHA-256 is `cb05ce18370e379d87d331f0f0cdc15f511d872b96a5b03f3ded7ef520a3993b`. The same selected-section scan was used. Chromium-related code, settings, and diagnostic text occur in this framework. No full framework decompilation was performed. Generic Chromium settings in a shipped framework do not establish Arc-specific active defaults.

Selected examples:

| Static address | Universal-file offset | Text |
| --- | --- | --- |
| `0xc48efb7` | `0x1bc3efb7` | performance_tuning.tab_discarding.exceptions |
| `0xc48efe4` | `0x1bc3efe4` | performance_tuning.tab_discarding.exceptions_with_time |
| `0xc65a208` | `0x1be0a208` | performance_tuning.tab_discarding.exceptions_managed |
| `0xc661b76` | `0x1be11b76` | Discarding.DailyDiscards.External |
| `0xc661b98` | `0x1be11b98` | Discarding.DailyDiscards.Urgent |
| `0xc661bb8` | `0x1be11bb8` | Discarding.DailyDiscards.Proactive |
| `0xc661bdb` | `0x1be11bdb` | Discarding.DailyDiscards.Suggested |
| `0xc661bfe` | `0x1be11bfe` | Discarding.DailyDiscards.FrozenWithGrowingMemory |
| `0xc661c2f` | `0x1be11c2f` | Discarding.DailyReloads.External |
| `0xc661c50` | `0x1be11c50` | Discarding.DailyReloads.Urgent |
| `0xc661c6f` | `0x1be11c6f` | Discarding.DailyReloads.Proactive |
| `0xc661c91` | `0x1be11c91` | Discarding.DailyReloads.Suggested |

## 5. Source snapshot

Browser commit: `6088fe585c246074c7fa504ac45077b6cf844863`. The source files were not changed during this study. Use this commit, not an unversioned line number, to reproduce the comparisons.

| Path | SHA-256 |
| --- | --- |
| `README.md` | `e32ce644c5d9fc958a59f6c40723fe2411dddc76ae7ea6522fbf1a5bf5eb59e0` |
| `Sources/Browser/BrowserApp.swift` | `60e40e6c663333f77252799d650325cd6e920c70d2e13a1ac63f5734fbb9fd0c` |
| `Sources/Browser/BrowserModel.swift` | `6158f748bda8946e789b31a9e0a1b33f6ac7feedf379877aaca9ec655f1c4317` |
| `Sources/Browser/BrowserProfile.swift` | `33f96ed7114192f1bba1270069149772bddf33faba833f0921d473694ba95d02` |
| `Sources/Browser/BrowserTab.swift` | `992c36dd34a2dc7562325954fc3d790734fa0a6d6a6eb10b93358be5517888d0` |
| `Sources/Browser/BrowserIntelligence.swift` | `a059d19d4a817490935c0fa28c87b390e24463f7a9167f72e1e02c89a363ece3` |
| `Sources/Browser/LinkPreviews.swift` | `7b8a9d0ac4af0063d028e6e2d7e3a6d4139f1c424a09e1a8d8bd308bd2c80f99` |
| `Sources/Browser/Downloads.swift` | `a2b22ba35a94fa0c6a782394b8472f4d0760907d8e4104cd2b698f4ced67f89b` |
| `Sources/Browser/AddressSuggestions.swift` | `155ea33b4f3709d8c0ace28d3e677b380dbbffd5c2c3a0bb6e038bb9769ddcc0` |
| `Sources/Browser/BrowserWindow.swift` | `c378b0b59a52059915891bf9a8934ebdef5ee535fa30ce8b6cc52181eef9ebe2` |
| `Sources/Browser/AddressField.swift` | `38f20132ded6630da3f393eb17cc34899a6e4f3de045f34ef8e43ee920655723` |
| `Sources/Browser/ExternalURLRouter.swift` | `5f9ddad8cd8c180aa3de084aac33d1b0882d42af0c89a0e6472899c28d0c7b41` |
| `Sources/Browser/PeekPage.swift` | `2a01334c7dfb890b203d932f3b6e5b703435b30ea136cb5d5cbb5a455099ab78` |
| `Sources/Browser/SplitTabs.swift` | `c70cd00f3daad957eced0d7927f1b9f3d9889c5bddceb591bcb1f66090713df4` |
| `Sources/Browser/TabSuspender.swift` | `0bbad52c0022f20325eb13b5d7e7948cefe3ae7b871f70d86be8b92d14273794` |
| `Sources/Browser/TabFolders.swift` | `58bccb57303275780c4998586f2396da173d03fa3d5220875a4ab19cd731e2e1` |
| `Sources/Browser/PinnedPages.swift` | `5a5aba28508420ec47dd3f147add3a657fbefbe0dd341ba97ba725c869cecaf6` |
| `Sources/Browser/PageDelegate.swift` | `b8479b38c6512822895e5bbb542c5722db42e30490a233d7c588b9bc99c7c993` |
| `Sources/Browser/Session.swift` | `7e7e7342b741debbe8895da20a9efea0794fbfa56586c85060991e3902602bd9` |
| `Sources/Browser/StoreFile.swift` | `9879e0077ec08d4ecccc6a39ae551c4a39dc683e41632c3e5284018fdbd120e5` |
| `Sources/Browser/ChromeHoverController.swift` | `136823d9c6b14b2304cadbbcb8e8db0de127c3d5eb467b054cb0cd95fe844a58` |

Primary symbols reviewed: `BrowserModel.tidyTemporaryTabs`, `applyTidyTabs`, `tidySavedTabTitle`, `suspendableTabs`, `suspendTabs`, `shouldPeek`, `openPeek`, `expandPeek`, `restoreSession`; `BrowserTab.suspend`, `restore`, `canSuspend`, `captureThumbnail`; `LocalIntelligence.makeSession`, `generate`, `tidy`, `summarize`; `DownloadManager.tidyDownload`, `renameDownloadedFile`, `tidyFilename`; `AddressSuggestions.rank`; `ExternalURLRouter.open`; `SessionStore.scheduleSave`; `StoreFile.save`.

The pi-lens review graph was stale and Swift module outlining failed to parse `BrowserIntelligence.swift`. The conclusions use direct file reads and focused searches, not the stale graph as authority. A bounded source search found no named Space/auto-archive/routing subsystem in the reviewed source. This is not proof against every possible alternative implementation name.

## 6. REA and acquisition limits

- Live MCP server: `rea-agents 6.7.0`; pi client `1.3.0`; skill expectation `42`; catalog advertises 207 tools. Tool discovery works.
- Hopper was listed as available, but its configured native helper failed at app discovery through Spotlight. Availability is not a successful analysis.
- A process-local direct-launch CLI attempt reached installed Hopper `6.6.0-demo`, but the bridge did not become ready. REA returned timeout and incomplete cleanup diagnostics. No successful function, string-reference, or pseudocode record came from it.
- Demo/loader UI and a Python-unavailable status were observed. No license bypass, runtime installation, or persistent configuration change was made.
- The CLI and its launched Hopper process later exited. The owned private runtime directory was then removed. Its files were not copied into this report. The connected REA MCP session was closed and reported no pending cleanup.
- `extract_artifact` returned `unsupported_target`: DMG has no extraction reader in this route. A separate `hdiutil attach -readonly -nobrowse` mount supplied files for explicit-path inspection. The app was not executed.
- Ghidra was not configured. No fallback decompiler was installed.
- Arc help-page requests returned HTTP 403. External help content was not used as verified runtime evidence.

## 7. Reproduction handles

Raw, uncommitted work products were stored in `/tmp/arc-rea/`. Temporary storage can be removed by the OS. The identities, coordinates, exact prompt text, and REA references above remain in these Markdown files. REA session references alone are not portable evidence bundles.

| Work product | Purpose |
| --- | --- |
| `rea-mcp-evidence.json` | Complete first-session REA bundle for DMG/main executable metadata |
| `rea-mcp-all-evidence.json` | Separate ArcCore-session REA bundle; despite its filename, it is not a merged bundle |
| `session-initial.json` | Live server identity and availability |
| `Arc-section-strings.json` | Main ARM64 selected-section candidates |
| `ArcCore-section-strings.json` | Framework ARM64 selected-section candidates |
| `ai-candidates.json` | Bounded long main-executable AI-text candidates |
| `direct-launch-search.json` | Failed standalone CLI diagnostic, not a successful analysis |
| `scan_arc.py` | Local section parser and candidate search |
| `build_appendices.py` | Exact literal and evidence-appendix extraction |

Reproduce metadata through REA `open_binary`, `inspect_artifact(detail: "summary")`, `inspect_plist`, `inspect_macho(detail: "summary")`, and `inspect_signature`. Export complete Evidence before closing each native target. Use the exact input hashes. Do not call `search_strings` or `analyze_function` successful until the native provider returns a complete result.

## 8. Reference URLs not verified in this run

- <https://github.com/morluto/rea>
- <https://resources.arc.net/hc/en-us/articles/19335160678679-Arc-Max-Boost-Your-Browsing-with-AI>
- <https://resources.arc.net/hc/en-us/articles/19228855311127-Auto-Archive-Clean-as-you-go>
- <https://resources.arc.net/hc/en-us/articles/19335393146775-Split-View-View-Multiple-Tabs-at-Once>

The Arc URLs are reference handles, not successful page reads. The REA repository URL identifies the requested tool project. Tool behavior in this report follows the connected 6.7.0 server and the installed skill, not an assumed newer repository version.
