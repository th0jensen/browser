#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

configuration="${1:-Debug}"
case "$configuration" in
    Debug) name=Browser-Debug ;;
    Release) name=Browser ;;
    *) echo "Expected Debug or Release, got: $configuration" >&2; exit 1 ;;
esac

app="$PWD/DerivedData/Build/Products/$configuration/$name.app"
link="/Applications/$name.app"
test -d "$app" || { echo "Build missing: $app" >&2; exit 1; }
if [[ -e "$link" && ! -L "$link" ]]; then
    echo "Refusing to replace an existing app at $link. Move it first." >&2
    exit 1
fi

# Both variants share a profile. Finish the running instance before switching builds.
if [[ $(osascript -l JavaScript scripts/stop-browser.js count) != 0 ]]; then
    osascript -l JavaScript scripts/stop-browser.js quit >/dev/null
    for ((attempt = 0; attempt < 100; attempt++)); do
        [[ $(osascript -l JavaScript scripts/stop-browser.js count) != 0 ]] || break
        sleep 0.1
    done
    if [[ $(osascript -l JavaScript scripts/stop-browser.js count) != 0 ]]; then
        echo "Quit Browser, then rerun just deploy." >&2
        exit 1
    fi
fi

./scripts/migrate-profile.sh "$app" "$name"
ln -sfn "$app" "$link"
open -n "$link"
echo "Launched $link → $app"
