# Documentation
Readme is user-facing and should not be edited by clankers.

# Development and QA

Use the Debug configuration and `Browser-Debug.app` for builds, testing, screenshots, and visual QA. Do not compile or launch the Release browser for QA. Build Release only when the user explicitly requests a release build.

Leave the Debug QA build running when QA is finished so the user can continue testing. Do not quit it during cleanup unless the user explicitly requests it.

Debug and Release share the normal profile. For isolated GUI QA, launch Debug with `--qa-profile` pointing to a disposable directory inside the app's sandbox. This keeps test tabs out of the user's shared session and uses a nonpersistent website data store. Avoid the deployment script when another browser variant must stay running: that script quits both variants.

Keep the Debug QA browser on the laptop’s **Built-in Retina Display**, the user’s chosen QA screen. Do not launch or move it onto LG ULTRAGEAR or iPad. Preserve the placement the user has set on the laptop screen and verify the display after relaunching; use Window → Move to Built-in Retina Display if macOS restores it elsewhere.

Launch ongoing QA with `--qa-profile` only. Avoid `-compactToolbar`, `-tabLayout`, or other UserDefaults command-line overrides: the argument domain takes priority over saved settings and can prevent UI preferences from changing during QA.
