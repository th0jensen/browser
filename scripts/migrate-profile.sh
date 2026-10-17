#!/bin/bash
set -euo pipefail

app="${1:?Expected the built app path}"
executable="${2:?Expected the executable name}"
legacy="$HOME/Library/Containers/dev.athas.browser.debug/Data/Library"
current="$HOME/Library/Containers/dev.athas.browser/Data/Library"
marker="$current/Application Support/dev.athas.browser/.migrated-debug-profile"
[[ -d "$legacy" && ! -f "$marker" ]] || exit 0

# Let the signed application create and register its sandbox before migrating data into it.
"$app/Contents/MacOS/$executable" --prepare-profile
migration_temp=""
trap '[[ -z "$migration_temp" ]] || rm -rf "$migration_temp"' EXIT

copy_if_missing() {
    local source="$1" destination="$2"
    [[ -e "$source" && ! -e "$destination" ]] || return 0
    mkdir -p "$(dirname "$destination")"
    migration_temp=$(mktemp -d "$current/.browser-migrate.XXXXXX")
    ditto "$source" "$migration_temp/payload"
    mv "$migration_temp/payload" "$destination"
    rmdir "$migration_temp"
    migration_temp=""
}

# WebKit may initialize an empty store (and its salt) before the first real launch,
# including while running tests. Preserve that empty store and copy the old store
# as a unit so its hashed origin directories continue to match its salt.
if [[ -d "$current/WebKit" && ! -e "$current/Cookies" && ! -e "$current/Application Support/dev.athas.browser/Extensions" ]]; then
    origins="$current/WebKit/WebsiteData/Default"
    if [[ ! -d "$origins" || -z $(find "$origins" -mindepth 1 -type d -print -quit) ]]; then
        backup="$current/WebKit.before-debug-migration"
        [[ -e "$backup" ]] || mv "$current/WebKit" "$backup"
    fi
fi

# Never overwrite an established release profile; keep the old debug container intact.
copy_if_missing "$legacy/WebKit" "$current/WebKit"
copy_if_missing "$legacy/Cookies" "$current/Cookies"
copy_if_missing "$legacy/HTTPStorages/dev.athas.browser.debug" "$current/HTTPStorages/dev.athas.browser"
copy_if_missing "$legacy/Application Support/dev.athas.browser.debug/Extensions" "$current/Application Support/dev.athas.browser/Extensions"
copy_if_missing "$legacy/Preferences/dev.athas.browser.debug.plist" "$current/Preferences/dev.athas.browser.plist"
touch "$marker"
echo "Migrated the debug profile into the shared Browser profile."
