# Performance and safety

## 1. What this report can establish

Browser source shows concrete work on the main actor and concrete resource limits. Arc metadata shows feature boundaries, prompts, framework identity, and lifecycle-related names. It does not show Arc's current scheduling algorithm or prove that Arc is faster.

No benchmark was run. No memory or latency comparison with Arc is claimed. Complexity statements below are source analysis, not measurements.

Do not use the size of ArcCore on disk as its runtime memory use. Do not compare one app process with another browser's complete process tree.

## 2. Keep lazy pages and view reuse

### Current implementation

`BrowserTab(newTabIn:)` allocates no web view. Restored background tabs retain descriptors and interaction state. `restore()` creates the view when needed. `suspend()` releases it after cleanup. `expandPeek()` adopts the existing live tab.

Sources: [BrowserTab.swift](../../Sources/Browser/BrowserTab.swift), [BrowserModel.swift](../../Sources/Browser/BrowserModel.swift), and [Session.swift](../../Sources/Browser/Session.swift).

### Arc relation

A03 includes discard/lifecycle names and a `discarded_web_content_count` telemetry key. R05 identifies ArcCore. These do not establish Arc's memory thresholds or prove that its discarding mechanism is the same as releasing a `WKWebView`.

### Recommendation

Keep Browser's public WebKit approach. When adding Spaces, restoring a Space list must not create web views for every tab. When adding an archive, opening the archive list must not load archived pages. When promoting a live preview, move the existing page rather than navigating again.

Expected effect: fewer unnecessary page allocations and reloads. This is a design expectation, not an Arc comparison result.

## 3. Avoid complete suggestion ranking on every edit

### Source finding

`BrowserWindow.editAddress` calls `AddressSuggestions.rank` synchronously. The ranking code builds candidates, calculates matches and scores, sorts all matches, and returns at most six results.

For `n` candidates, candidate work is linear in the input and matching text. Sorting up to `n` matches costs `O(n log n)`. Returning six results does not make the earlier sort a six-item sort.

### Proposed improvement

1. Maintain a normalized index when history/bookmark data changes.
2. Give a query a revision token.
3. Search immutable indexed records outside the main actor when the data set is large.
4. Keep only the best `k` candidates with a bounded selection structure.
5. Publish results only when the query revision is still current.
6. Merge typed live-tab and command results on the same result surface.

For fixed `k`, bounded top-result selection can avoid a full sort. Preserve the existing tie-break rules so results do not jump between edits. Off-main work needs cancellation and revision checks; moving an unbounded queue to another actor is not a complete fix.

### Arc evidence limit

A06 establishes command/search concepts. It does not establish Arc's search index, ranking complexity, debounce policy, or thread use. The optimization above follows from Browser's source, not a recovered Arc algorithm.

## 4. Do not sort suspension candidates again for every tab

### Current code

[BrowserModel.swift](../../Sources/Browser/BrowserModel.swift), `suspendableTabs`, filters the live tab list and sorts it by last activity. `suspendTabs` then uses the property again inside its loop:

```swift
for tab in candidates {
    guard !(await tab.isPlayingMedia()),
          suspendableTabs.contains(where: { $0 === tab }) else { continue }
    tab.suspend()
}
```

The second eligibility check is required. A tab can become selected while the media query is pending. Removing the check would be wrong.

However, checking membership through a newly filtered and sorted list repeats work. For `m` candidates and `n` live tabs, repeated sorting can approach `O(m * n log n)`, apart from WebKit query cost.

### Proposed improvement

Split selection order from live safety checks:

- Compute LRU candidate order once per suspension pass.
- Recheck current eligibility after each awaited media query.
- Use a predicate that does not sort.
- Track structural revisions for tab membership, popup links, and split changes.
- Rebuild any lookup cache when its structural revision changes.

A predicate that still scans the whole tab list reduces sorting but does not make the whole pass linear. Only claim a larger improvement after checking the full call path.

Arc's exact discard eligibility policy remains unknown. This is a source-driven improvement, not an instruction to copy a Chromium internal API.

## 5. Protect page work before discard or archive

Browser already protects visible split members, loading pages, panels waiting for selection, inspector pages, camera/microphone capture, playing media, and live popup/opener links.

`BrowserTab.canSuspend` also states that unsaved form input is not detected. Restoring WebKit interaction state is not proof that every JavaScript editor, upload, or page-local state survives.

Before adding automatic archive, add a conservative dirty-state signal. Use event-driven input/change tracking in an isolated content world where practical. Include explicit reset and navigation behavior. A false negative can lose work, so “unknown” should not mean “safe”. Do not inject a page-wide polling loop.

Test media, WebRTC, unsaved forms, active downloads, uploads, editors, popup relationships, and system sleep/wake. Do not infer their safety from a generic `discard` literal in Arc.

## 6. Keep bounded local inference

### Current safeguards

[BrowserIntelligence.swift](../../Sources/Browser/BrowserIntelligence.swift) provides:

- one asynchronous inference gate;
- higher priority for interactive previews and tidying than background naming;
- cancellation-aware waiters;
- fresh model sessions and bounded output tokens;
- short-lived prepared sessions;
- bounded naming inputs and a 64-entry name cache;
- typed outputs with application-side checks.

These are existing strengths. Do not replace them with a model request per pointer move or per address edit.

### Improvements to evaluate

- Use explicit cache entries with prompt/schema versions when the prompt changes.
- Include every input that can change output in the cache key.
- Consider predictable LRU eviction instead of arbitrary dictionary-key eviction if repeated misses are observed.
- Keep cancelled jobs out of both the queue and the result-application path.
- If Ask on Page is added, give it an explicit priority and a bounded context.

The artifact contains `BundledTidyTitles` names. This suggests a possible title-data path, but its contents, lookup order, and hit rate are not verified. It does not justify claiming that Arc avoids model calls through a cache or a bundled dictionary.

## 7. Improve content selection before increasing context

The link fetcher limits the HTML buffer and strips markup. Summary generation uses the first bounded text slice. Increasing that slice can raise inference cost while still including the wrong content.

First improve static content selection:

1. Prefer main/article text within the existing byte limit.
2. Preserve title, headings, paragraph boundaries, and source identity.
3. Detect challenge, login, and insufficient-text pages.
4. Generate a summary only from selected source blocks.

Do not render arbitrary fetched HTML in a hidden web view just to obtain readable text. That could execute scripts, load subresources, and change the current cookie-free preview contract.

P05 supports the value of an explicit blocked-page outcome. It does not supply a safe extractor implementation.

## 8. Retain file and persistence safeguards

### Downloads

[Downloads.swift](../../Sources/Browser/Downloads.swift) keeps file movement outside the model. Keep extension preservation, same-directory checks, collision refusal, completion checks, quarantine, and undo.

Arc P02 gives useful naming examples. It gives no evidence of Arc's file-move race handling. Do not weaken Browser's checks to match its prompt shape.

### Sessions

[Session.swift](../../Sources/Browser/Session.swift) is the active multi-window store used by `BrowserApp`. `BrowserSessionStore` in `BrowserSession.swift` is not the current app's primary session architecture.

`SessionStore` coalesces saves. [StoreFile.swift](../../Sources/Browser/StoreFile.swift) encodes and writes on a serial queue, rejects obsolete generations, uses a private temporary file, and atomically publishes it. Termination has a synchronous flush path.

Keep these properties when adding Spaces or archive state. A background writer must not publish a stale Space snapshot after the user switches context. An archive operation needs an acknowledged durable write, not only a queued write, before removing the tab.

## 9. Existing presentation work should remain bounded

`BrowserTab.captureThumbnail` captures only an attached visible page, limits the captured region to the hover card's aspect, and checks source view/URL before publishing. It has in-flight state and a pending request.

`ChromeHoverController` uses pointer events and one pending hide task per region. It avoids restarting a hide timer on every move and holds presentation while menus or customization are active.

Keep those designs. Arc's presence does not prove a better snapshot or hover algorithm. A future comparison must check redundant snapshots, timer count, view allocation, and focus changes rather than compare animation appearance alone.

## 10. Security boundaries

- A Space is not a sandbox or profile unless it owns an explicit data-store relationship.
- A model response cannot select a profile or authorize a file operation.
- A citation instruction is not a citation validator.
- A public-looking hostname is not proof of a public network destination.
- The preview fetcher resolves destinations before a request, but URLSession performs its own lookup. DNS changes between those steps remain a limit. Do not describe the current check as a complete DNS-rebinding defense.
- Redirects and publisher images need the same destination policy as the document.
- Normal-page text can contain private authenticated content. Page questions should be explicit and local.
- Do not infer privacy or server-retention policy from a provider name in a binary.

## 11. Validation plan

Use synthetic history sets, tab sets, and local fixture pages. Compare old and proposed Browser paths first. Keep algorithm changes separate from new UI so a regression has a small cause.

Record performance measurements in the task thread, not in committed reports. Use the project's approved benchmark path only when optimized benchmarking is explicitly requested. Ordinary implementation work uses `just test`; GUI QA uses installed Debug through `just qa`.
