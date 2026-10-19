#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
mode="${2:-normal}"
case "$configuration" in
    Debug) name=Browser-Debug ;;
    Release) name=Browser ;;
    *) echo "Expected Debug or Release, got: $configuration" >&2; exit 1 ;;
esac
# Every Debug deployment is isolated, including plain `just`.
if [[ "$configuration" == Debug && "$mode" == normal ]]; then mode=qa; fi
case "$mode" in
    normal|install) ;;
    qa) [[ "$configuration" == Debug ]] || { echo "QA requires Debug." >&2; exit 1; } ;;
    *) echo "Expected normal, qa, or install, got: $mode" >&2; exit 1 ;;
esac

app="$PWD/DerivedData/Build/Products/$configuration/$name.app"
destination="/Applications/$name.app"
test -d "$app" || { echo "Build missing: $app" >&2; exit 1; }
bundle_identifier=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
expected_identifier=dev.athas.browser
if [[ "$configuration" == Debug ]]; then expected_identifier=dev.athas.browser.debug; fi
[[ "$bundle_identifier" == "$expected_identifier" ]] || { echo "Build identity is outdated; run just build $configuration first." >&2; exit 1; }
if [[ -e "$destination" && ! -L "$destination" ]] &&
   [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true) != dev.athas.browser ]] &&
   [[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true) != dev.athas.browser.debug ]]; then
    echo "Refusing to replace an unrelated app at $destination." >&2
    exit 1
fi

# Stage a real copy first, so a failed copy never removes the installed app.
staging=$(mktemp -d "/Applications/.$name-install.XXXXXX")
cleanup() {
    if [[ ! -e "$destination" && ! -L "$destination" && ( -e "$staging/previous.app" || -L "$staging/previous.app" ) ]]; then
        mv "$staging/previous.app" "$destination"
    fi
    rm -r "$staging"
}
trap cleanup EXIT
cp -R "$app" "$staging/$name.app"
codesign --verify --deep --strict "$staging/$name.app"

# The variants have separate sandboxes. Only stop the variant being replaced.
variant="$name"
if [[ "$mode" != install || ! -L "$destination" ]] &&
   [[ $(osascript -l JavaScript scripts/stop-browser.js count "$variant") != 0 ]]; then
    osascript -l JavaScript scripts/stop-browser.js quit "$variant" >/dev/null
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ $(osascript -l JavaScript scripts/stop-browser.js count "$variant") != 0 ]] || break
        sleep 0.1
    done
    if [[ $(osascript -l JavaScript scripts/stop-browser.js count "$variant") != 0 ]]; then
        echo "Quit the running browser, then rerun this just recipe." >&2
        exit 1
    fi
fi

if [[ -e "$destination" || -L "$destination" ]]; then mv "$destination" "$staging/previous.app"; fi
mv "$staging/$name.app" "$destination"
# Refresh this app's registration after adding or changing its bundled icon.
# Debug and Release register independently, with separate identities and artwork.
touch "$destination"
launch_services="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$launch_services" ]]; then
    "$launch_services" -f "$destination"
fi
if [[ "$mode" == install ]]; then
    echo "Copied $app to $destination"
elif [[ "$mode" == qa ]]; then
    qa_parent="$HOME/Library/Containers/$bundle_identifier/Data/Library/Application Support"
    # The sandboxed app owns profile creation. The launching shell may not have
    # permission to write inside its protected container.
    qa_profile="$qa_parent/BrowserQA.$(uuidgen)"
    open -n "$destination" --args --qa-profile "$qa_profile"
    echo "Launched $destination with disposable QA profile: $qa_profile"
else
    open -n "$destination"
    echo "Launched $destination"
fi
