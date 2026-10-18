#!/bin/sh
set -eu

# Keep the importable build tied to a reviewable upstream revision.
revision=18d17188e5562e5ee913f005192d30c9a60be078
upstream=https://github.com/WesselKroos/youtube-ambilight.git
extensions_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
build_directory=$(mktemp -d "${TMPDIR:-/tmp}/browser-ambilight.XXXXXX")
trap 'rm -rf "$build_directory"' EXIT
trap 'exit 1' HUP INT TERM

for tool in git node npm zip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "Missing required tool: $tool" >&2; exit 1; }
done

git init --quiet "$build_directory/source"
git -C "$build_directory/source" fetch --quiet --depth 1 "$upstream" "$revision"
git -C "$build_directory/source" checkout --quiet --detach FETCH_HEAD
cd "$build_directory/source"

node "$extensions_directory/prepare-youtube-ambilight.mjs" "$build_directory/source"
npm ci --ignore-scripts --no-audit --no-fund
# Build the runtime only; no Sentry CLI downloads or release uploads.
npm run build:scripts:rollup
npm run build:styles
npm run build:manifest
npm run build:html
npm run build:images

for script in dist/scripts/*.js; do
    node --check "$script"
done
cp LICENSE PRIVACY-POLICY.md TROUBLESHOOT.md dist/

cd dist
zip -q -r "$build_directory/youtube-ambilight.zip" .
mkdir -p "$extensions_directory/youtube-ambilight"
cp -R . "$extensions_directory/youtube-ambilight/"
mv "$build_directory/youtube-ambilight.zip" "$extensions_directory/youtube-ambilight.zip"
echo "Ready to import: $extensions_directory/youtube-ambilight"
echo "ZIP archive: $extensions_directory/youtube-ambilight.zip"
