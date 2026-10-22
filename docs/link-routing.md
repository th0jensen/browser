# External link routing

Use **Settings → Link Routing** to add explicit host rules. Each destination shows the profile name, then the Space name. The destination menu includes available Spaces in both the Existing Profile and named ordinary profiles. A Space keeps its owning profile for its lifetime. Editing a rule selects a destination; it does not reassign a Space or move a live page into another profile.

## Rules and fallback

- Rules run in visible order. The first matching rule wins. Move rules up or down to change their priority.
- Enter a host, not a URL, port, path, or wildcard. Exact matching uses the normalized host. Include Subdomains also accepts complete subdomain labels. `example.com.evil.test` does not match `example.com`.
- Matching normalizes case, trailing ASCII dots, and international host names. Routing passes the original URL to navigation without rebuilding its scheme, port, path, query, or fragment.
- A valid rule selects its Space and owning profile before opening the URL. The front ordinary window can switch from a named profile to the Existing Profile, or from the Existing Profile to a named profile.
- Missing Spaces, missing profile descriptors, and unreadable metadata are labelled unavailable. The first matching unavailable rule uses the ordinary fallback. It does not try a later rule or substitute a Default profile descriptor.
- The ordinary fallback uses the front ordinary window and its selected Space. A mixed batch restores that original selection for unmatched links and local files. If no ordinary window exists, links wait for one. Private, extension, and closed windows cannot receive them.
- Only web URLs can match a rule. Local files keep the existing ordinary-window behavior. Unsafe incoming schemes are rejected.
- The application URL callback has no verified source-app identity. There is no source-app selector. A source condition retained in an imported rule cannot match that callback.

## Storage and lazy ownership

`LinkRoutes.json` keeps existing rule IDs, order, host scope, and destination Space UUIDs. No rule migration or profile field is needed: the Space descriptor identifies its immutable owning profile. Existing rules keep their destination IDs.

Listing, labelling, and validating destinations read only the same injected Space and profile descriptors. These operations do not request profile resources, cookie stores, or web views. Recovery Default values from unreadable metadata cannot validate explicit routes. Resource selection occurs only when an actual ordinary-window route selects a valid Space. Background tabs and profile data remain owned by their original Spaces.

Delete all rules to restore ordinary routing. Unreadable rule files stay untouched for recovery.

## Arc references and intentional differences

The official [Air Traffic Control article](https://resources.arc.net/hc/en-us/articles/22932014625431-Air-Traffic-Control-Automate-Your-Link-Routing) describes link preferences, visible routes, destination Space controls, route creation, and removal. Its [route panel image](https://resources.arc.net/hc/article_attachments/22932014616343) shows a URL condition directly above an Open in destination control. The article and its actual route-panel and removal images were inspected for this change. The official [Profiles article](https://resources.arc.net/hc/en-us/articles/19227964556183-Profiles-Separate-Work-Personal-Browsing) establishes profile-scoped login and cookie ownership across one or more Spaces.

Browser keeps the useful condition → destination hierarchy. It uses a native Settings section, grouped controls, and a native edit sheet rather than a copy of Arc's modal routing panel. Profile names are explicit because a route can switch login contexts. Browser uses host boundaries rather than Arc's URL Contains/Is equal to conditions. It keeps the existing front-window fallback, has no Little Arc window or editable default route, and retains unavailable rules for explicit repair rather than automatically deleting them. First-match ordering and these safety choices are local Browser design. This change adds no prompts, model calls, source-app inference, or cloud service.

These differences are intentional; they are not a claim of visual parity. Native comparison remains pending for the coordinator under the coordinator's Arc visual acceptance contract. Check long profile/Space names, narrow settings layout, light and dark appearance, keyboard focus, VoiceOver labels, and the displayed destination after profile switches. Source review, inspected Arc reference images, and XCTest are not native GUI verification.
