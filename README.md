# Browser

A browser forked from [athas/browser](https://github.com/athasdev/browser) that tries to recreate the experience of Arc, including Arc Max features, while staying minimal, modern, fast and efficient.

Arc Max includes some of the best LLM features for the browser. Apple released the Foundation Models API in macOS 27 which comes with LLM models pre-installed on virtually every Mac. Therefore, the LLM features + inference runs purely on your device and is therefore "free". Model performance might vary based on chip.

## Requirements

- macOS 26 or later
- Xcode 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- [just](https://github.com/casey/just) (`brew install just`)

## Build and run

```sh
just release
```

This generates the Xcode project, builds with local ad-hoc signing, symlinks **/Applications/Browser.app** to the build, and launches it. Repeating the command rebuilds and relaunches the app. Existing non-symlink apps are never overwritten.

For debug builds:
```sh
just
```

`just release` builds, symlinks, and launches **/Applications/Browser.app**. `just build` builds without deployment; `just test` runs the test suite. Keep this checkout and its `DerivedData` folder in place while using the symlinks.

Debug builds use `assets/Browser_Debug.icns`; Release builds use `assets/Browser_Release.icns`. Each build includes only its own app icon.
