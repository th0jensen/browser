set shell := ["bash", "-euo", "pipefail", "-c"]

# Build, copy into /Applications, and launch the separate Debug app.
default: deploy

generate:
    xcodegen generate

build configuration="Debug": generate
    xcodebuild -quiet -project Browser.xcodeproj -scheme Browser -configuration "{{configuration}}" -derivedDataPath DerivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--options=0

deploy: (build "Debug")
    ./scripts/deploy.sh Debug qa

# Use the installed Debug app with a fresh, disposable session for agent QA.
qa: deploy

# Copy an already-built app without compiling or launching it.
install configuration="Debug":
    ./scripts/deploy.sh "{{configuration}}" install

release: (build "Release")
    ./scripts/deploy.sh Release

# Requires a team/provisioning profile approved for Apple's browser passkey entitlement.
deploy-signed team configuration="Debug": generate
    xcodebuild -quiet -project Browser.xcodeproj -scheme Browser -configuration "{{configuration}}" -derivedDataPath DerivedData build DEVELOPMENT_TEAM="{{team}}" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" BROWSER_PASSKEYS=YES -allowProvisioningUpdates
    ./scripts/deploy.sh "{{configuration}}"

test: generate
    xcodebuild -quiet -project Browser.xcodeproj -scheme Browser -configuration Debug -derivedDataPath DerivedData -destination 'platform=macOS' test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM= ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS=--options=0

# Compare isolated Release-optimized workloads without deploying or stopping either installed app.
benchmark label="candidate" mode="core":
    ./scripts/benchmark.sh "{{label}}" "{{mode}}"
