# Documentation
Readme is user-facing and should not be edited by clankers.

# Development and QA

Use the Debug configuration and `Browser-Debug.app` for builds, testing, screenshots, and visual QA. Do not compile or launch the Release browser for QA. Build Release only when the user explicitly requests a release build.

Use `just` for compilation and testing. Use `just qa` for GUI QA: it builds Debug in the normal DerivedData directory, copies the app into `/Applications/Browser-Debug.app`, and launches that installed copy with a fresh disposable profile. Do not build or launch a separate QA copy from another DerivedData directory. Use `just test` for automated tests.

Leave the Debug QA build running when QA is finished so the user can continue testing. Do not quit it during cleanup unless the user explicitly requests it.

Debug and Release have separate sandbox identities (`dev.athas.browser.debug` and `dev.athas.browser`). Every Debug launch uses a fresh disposable profile and nonpersistent website data, even when opened directly without arguments. Plain `just` also launches isolated Debug. Use `just qa` for agent QA and confirm its `--qa-profile` argument before attaching UI tools. Deployment stops only the variant being installed; Debug QA leaves Release and its profile alone. Never migrate Debug data into the normal Release profile during builds or QA.

Keep the Debug QA browser on the laptop’s **Built-in Retina Display**, the user’s chosen QA screen. Do not launch or move it onto LG ULTRAGEAR or iPad. Preserve the placement the user has set on the laptop screen and verify the display after relaunching; use Window → Move to Built-in Retina Display if macOS restores it elsewhere.

Launch ongoing QA with `--qa-profile` only. Avoid `-compactToolbar`, `-tabLayout`, or other UserDefaults command-line overrides: the argument domain takes priority over saved settings and can prevent UI preferences from changing during QA.

The deployment script allocates a fresh UUID profile path; the Debug app creates the directory inside its own sandbox. Avoid creating that directory from the launching shell, which may lack access to the app’s protected container.

# Commit attribution

Include this trailer on commits made with this assistant, recording the model name:

Co-authored-by: Codex (GPT-6.1 Sol) <noreply@openai.com>

Keep benchmark measurements and before/after results in the task thread, not PR descriptions or committed reports.

When optimized benchmarking is explicitly requested, `just benchmark` uses the Release-optimized `Benchmark` configuration and `dev.athas.browser.benchmark` identity in normal DerivedData. It runs only isolated XCTest fixtures, never deployment or profile migration, and must leave the installed browsers running. Ordinary GUI QA continues to use Debug.
