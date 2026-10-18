# Ambient light for YouTube

Ready-to-import build of [Wessel Kroos's Ambient light for YouTube](https://github.com/WesselKroos/youtube-ambilight). The extension adds the original project's ambient lighting and player settings to YouTube videos.

## Import into Browser

1. Open **Browser → Settings → Extensions**.
2. Expand **Development** and click **Import Extension…**.
3. Select the `youtube-ambilight` folder beside this file, or `youtube-ambilight.zip`. The folder contains `manifest.json` directly; do not select the enclosing `Extensions` folder.
4. Enable **Ambient light for YouTube™** and allow its requested storage and YouTube website access.
5. Reload any open YouTube tabs and play a video. Use the ambient-light button in the video's player controls to adjust the effect. The extension's toolbar button opens its help, import/export, and privacy settings.

Browser copies imported resources into its profile. To use a rebuilt version, remove the previous import and import the new folder or ZIP.

## Source and build

- Upstream version: **2.38.17**.
- Pinned commit: [`18d17188e5562e5ee913f005192d30c9a60be078`](https://github.com/WesselKroos/youtube-ambilight/commit/18d17188e5562e5ee913f005192d30c9a60be078).
- Browser build version: **2.38.17.2**. `prepare-youtube-ambilight.mjs` adapts script loading for WebKit: the page helper uses a declared `MAIN` world content script, and the renderer and CSS use declared isolated content scripts. This avoids the script tags and dynamic imports that YouTube's Content Security Policy blocks in WebKit. Source maps are included for debugging.
- WebKit currently omits `CanvasRenderingContext2D.filter`, which the original WebGL projector uses for its final Gaussian blur. `compatibility/canvas-blur.js` supplies that blur with two GPU passes, retaining the upstream blur radius, padding, transparency, colors, and Blur/Spread controls. Without it, increasing Blur only changes padding and the glow stays sharp. Browsers with native canvas filters keep the original rendering path.
- The upstream MIT license, privacy policy, and troubleshooting guide are included in the importable folder. Upstream's crash-report controls and defaults are preserved; review **Crash reports & Privacy** in the extension's toolbar popup if desired.
- Browser has no browser-account cloud sync service; use the extension's file import/export controls to transfer settings.

To rebuild, install Git, Node.js/npm, and `zip`, then run from the repository root:

```sh
./Extensions/build-youtube-ambilight.sh
```

Upstream specifies Node **22.5.1**. The build uses the pinned dependency lockfile, installs dependencies in a temporary directory, and builds locally. It skips upstream's Sentry release/source-map publishing steps. No Node.js installation or build step is needed to import the supplied folder or ZIP.

## Verification

The WebKit regression check loads the extension against an offline YouTube-origin fixture whose CSP prohibits page scripts. It verifies the page-world message bridge works without inserting script tags:

```sh
xcrun swiftc -parse-as-library Extensions/tests/verify-webkit.swift -o /tmp/verify-ambilight
/tmp/verify-ambilight "$PWD/Extensions/youtube-ambilight.zip"
```

The check also compares the blur's rendered pixels against an independent Gaussian calculation at several radii and sizes, checks transparent edges for dark halos, and exercises a larger blur radius. The tested full-resolution cases differ by less than one alpha value out of 255.

The packaged build is also checked on a live YouTube video in WebKit, including the original **Hide everything in theater mode** control. Enable that control and enter YouTube's theater view for the distraction-free viewer.

To reproduce settings from Helium, use **Export to file** in the original extension's toolbar popup, then **Import from file** in this extension's popup. Browser profiles have separate extension storage; the import preserves the original configuration without guessing a replacement preset.
