# Arc reference and visual acceptance contract

The user requires reference-based verification of both the plan and the implementation. Functional tests alone do not establish design fidelity. This contract updates the earlier minimal UI plan. Keep Browser's native macOS behavior and Liquid Glass; retain the useful structure and interaction hierarchy shown by Arc.

## Sources inspected

1. [Spaces: Distinct Browsing Areas](https://resources.arc.net/hc/en-us/articles/19228064149143-Spaces-Distinct-Browsing-Areas). Arc's official article. Its public [Help Center API](https://resources.arc.net/api/v2/help_center/en-us/articles/19228064149143.json) was readable when the HTML endpoint returned HTTP 403. It specifies separate Pinned and Unpinned sections, a theme and icon, a bottom-sidebar Space switcher and plus button, sidebar swipes, and Control-number switching on macOS.
2. [Arc — Your space on internet](https://medium.com/design-bootcamp/arc-your-space-on-internet-91f54771f245), Eliso Kirvalidze, 7 August 2023. User-supplied visual reference. The article was read through a public reader after Medium returned HTTP 403. Original public image assets were downloaded and inspected. The screenshots are historical design evidence, not proof of current Arc behavior.
   - [Sidebar image](https://miro.medium.com/v2/resize:fit:1400/0*bOB5O74yq9BfWByt.png): top favorite tiles, saved and temporary sections, content-first layout, persistent bottom utility row.
   - [Spaces overview image](https://miro.medium.com/v2/resize:fit:1400/1*hCl6wa0lAZgqKiJuaoYpCQ.png): named, icon-marked Spaces with distinct themes. This is the overview, not the bottom switcher.
   - [Command Bar image](https://miro.medium.com/v2/resize:fit:1400/1*kn6wEaweuxJ6-jyqAkl1tA.png): one centered floating palette, prominent input, compact selected result below, and a visible source page behind it. This example shows a supported site-search mode; it does not justify adding a fake mode chip.
3. [Favorites: Top Tabs Across Every Space](https://resources.arc.net/hc/en-us/articles/19230755904151-Favorites-Top-Tabs-Across-Every-Space) and [Pinned Tabs: Tabs you want to stick around](https://resources.arc.net/hc/en-us/articles/19231060187159-Pinned-Tabs-Tabs-you-want-to-stick-around). Official references distinguish cross-Space Favorites from Space-local Pinned Tabs and folders. Browser must not treat these as the same storage scope without an explicit, reviewed deviation. Profile boundaries remain mandatory.

## Spaces acceptance

- Keep a visible icon strip at the bottom of the vertical sidebar, outside the tab scroller. Do not use a top dropdown as the primary switcher.
- Include a visible plus control, a distinct selected state, hover names, keyboard focus, and VoiceOver names and selection state. Many Spaces and narrow sidebars must remain usable.
- Keep the active Space title and its saved/temporary content hierarchy clear. Store a stable icon and theme per Space, with backward-compatible decoding and existing IDs/order intact. Use restrained tint and semantic foreground colors; do not copy the old opaque Arc screenshot literally.
- Support Control-number selection on macOS. Audit sidebar swipe behavior against the reference; do not substitute a mouse drag and claim trackpad verification.
- Preserve tab objects, page state, selected tabs, split focus, lazy inactive views, and profile identity while switching.
- Separate the scopes of Favorites/Essential tiles, Space Pinned Tabs/folders, and temporary tabs. Confirm the Favorites/profile relationship from official profile guidance before changing storage.
- Do not add a fake Share Space permalink or cloud sharing service. Record this as a deliberate local-only boundary.

## Command Bar acceptance

- Present an Arc-like floating palette, centered in the browser content area, instead of calling an ordinary address-field dropdown a Command Bar.
- Use one dominant native editor, compact keyboard-selectable results, clear action/Space context, and a strong selected row. Keep the underlying page visible. Use genuine Regular Liquid Glass and semantic colors, not a simulated blur or copied Arc colors.
- Command-T opens the palette for a new destination without eagerly creating a web view. Escape and outside dismissal restore focus without navigation or a phantom tab. Preserve Browser's existing address editing and IME behavior; document any intentional shortcut difference from Arc.
- Preserve the checked local result/action engine. Accepted tab results select the exact existing tab, including when Peek is open. Rejected stale results must not change selection or dismiss valid work.
- Do not add inference on typing, misleading search-mode chips, or decorative controls without implemented actions.

## Verification gate for every UI section

1. Record the official behavior source and at least one usable visual reference where available. Distinguish text-only evidence, a reference image inspected, source review, XCTest, and actual GUI inspection.
2. Compare placement, hierarchy, density, selection, keyboard behavior, focus, and material treatment. List deliberate Browser adaptations and unresolved gaps.
3. Run Debug tests. Then use `just qa`, the installed `Browser-Debug.app`, a confirmed `--qa-profile`, and Built-in Retina Display for native screenshots and interaction checks. Do not use Release or a separate QA DerivedData copy. Leave Debug running.
4. Capture comparable states, not unrelated screens. Check narrow layout, multiple Spaces, long names, light/dark appearance, contrast, and keyboard-only interaction where relevant.
5. Keep a UI PR in draft until missing visual checks are explicit. A build, source rendering, DOM test, or synthetic event is not a passed native visual comparison.

## Current result

Reference inspection found two design gaps in the initial minimal implementation: a top Space menu instead of a bottom icon strip, and address suggestions instead of an Arc-like Command Bar. Their reference-aligned revisions are now implemented and tested. The independent audit also identified profile-shared Favorites and the Find-linked answer surface; these corrections are tracked separately.

A partial native pass on installed Debug source snapshot `dfebf2d` checked bottom placement, native icon/theme creation, six-Space overflow, Control-number selection and exact retained form state. Debug was moved with Window → Move to Built-in Retina Display and its fresh `--qa-profile` and native bounds were confirmed. The app was left running. A WindowServer-ID screenshot of the synthetic form and selected Work footer was saved and inspected; inactive capture is not proof of active glass treatment.

A separate installed Debug pass on QA merge `a9e3347` (Command parent `189accd`) confirmed the centered palette, active Regular glass, native address editing, no-phantom New Tab entry, outside-click swallowing and exact live form retention after a paced existing-tab round trip. It used injected OS keyboard/pointer events, not physical hardware. Built-in Retina Display, disposable launch arguments and explicit WindowServer screenshot ID were confirmed. An earlier unpaced macro produced an unintended dummy search; no successful retention claim is assigned to that attempt.

That Command pass also found a real layout failure: with only three or five results at normal window width, action/context labels are clipped under the scroller and the final row's second line is cut. A source correction and regression tests are in progress. The palette remains draft and must be recaptured after the fix. Passing XCTest did not reveal this native defect.

This is not full visual acceptance. Narrow resize requests snapped back; a source audit established no cause, so no speculative product workaround was added. Physical trackpad behavior, real webpage IME, VoiceOver, appearance/contrast variants and final integrated screenshots remain pending. Do not generalize either partial pass to Profiles, Archive, Ask or Favorites. Debug remains running; later metadata/swipe tests and source reviews do not retroactively validate those native states.
