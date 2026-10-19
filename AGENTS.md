# Documentation
Readme is user-facing and should not be edited by clankers.

# Development and QA

Use the Debug configuration and `Browser-Debug.app` for builds, testing, screenshots, and visual QA. Do not compile or launch the Release browser for QA. Build Release only when the user explicitly requests a release build.

Use `just` for compilation and testing. Use `just qa` for GUI QA: it builds Debug in the normal DerivedData directory, copies the app into `/Applications/Browser-Debug.app`, and launches that installed copy with a fresh disposable profile. Do not build or launch a separate QA copy from another DerivedData directory. Use `just test` for automated tests.

Leave the Debug QA build running when QA is finished so the user can continue testing. Do not quit it during cleanup unless the user explicitly requests it.

Debug and Release have separate sandbox identities (`dev.athas.browser.debug` and `dev.athas.browser`). Every Debug launch uses a fresh disposable profile and nonpersistent website data, even when opened directly without arguments. Plain `just` also launches isolated Debug. Use `just qa` for agent QA and confirm its `--qa-profile` argument before attaching UI tools. Deployment stops only the variant being installed; Debug QA leaves Release and its profile alone. Never migrate Debug data into the normal Release profile during builds or QA.

Keep the Debug QA browser on the laptop’s **Built-in Retina Display**, the user’s chosen QA screen. Do not launch or move it onto LG ULTRAGEAR or iPad. Preserve the placement the user has set on the laptop screen and verify the display after relaunching; use Window → Move to Built-in Retina Display if macOS restores it elsewhere.

Launch ongoing QA with `--qa-profile` only. Avoid `-compactToolbar`, `-tabLayout`, or other UserDefaults command-line overrides: the argument domain takes priority over saved settings and can prevent UI preferences from changing during QA.

# Commit attribution

Include this trailer on commits made with this assistant, recording the model name:

Co-authored-by: Codex (GPT-6.1 Sol) <noreply@openai.com>

Keep benchmark measurements and before/after results in the task thread, not PR descriptions or committed reports.

When optimized benchmarking is explicitly requested, `just benchmark` uses the Release-optimized `Benchmark` configuration and `dev.athas.browser.benchmark` identity in normal DerivedData. It runs only isolated XCTest fixtures, never deployment or profile migration, and must leave the installed browsers running. Ordinary GUI QA continues to use Debug.

# Link previews

`LinkPreviewController` tracks intentional link hovers in an isolated WebKit content world. Transient cards use a native `NSGlassEffectView` overlay in the source window so the glass can sample webpage content. Keep keyboard focus on the source page; dismiss and cancel transient cards on navigation, window changes, deactivation, or leaving the link/card. Dragging a transient card’s image, text, or padding reparents the same content into an independently owned floating note. Notes survive those events until closed and last for the current app session.

Only kept notes show the title bar and controls. A hover bridge and grace period allow pointer travel between the source link and preview. The clear Liquid Glass card measures its content and scrolls within the available space. Drag tracking uses local AppKit events in screen coordinates; the initiating event can belong to the source window after the card detaches.

`LinkPreviewFetcher` uses an ephemeral, cookie-free session for bounded document and publisher-image requests. `LocalIntelligence` streams structured summaries through the shared model queue. `BrowserIntelligenceTests` injects a summary provider to check native presentation and cancellation without requiring an available on-device model; run these with `just test`.

`LinkPreviewCard` owns presentation and native drag handles. `PreviewNoteEntity` exports the summary, key points, and source URL through App Intents/Transferable. Both menu entry points present from the same annotated `PreviewContentView`, which implements AppKit's read-only text requestor for contextual system actions. Suspend hover dismissal during menu tracking. Keep Copy, Share, and Siri context consistent; do not add a private Siri launcher.
