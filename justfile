set shell := ["bash", "-euo", "pipefail", "-c"]

# Build, install a symlink, and launch a separate debug app.
default: deploy

generate:
    xcodegen generate

build configuration="Debug": generate
    xcodebuild -quiet -project Browser.xcodeproj -scheme Browser -configuration "{{configuration}}" -derivedDataPath DerivedData build CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=

deploy: (build "Debug")
    ./scripts/deploy.sh Debug

release: (build "Release")
    ./scripts/deploy.sh Release

# Requires a team/provisioning profile approved for Apple's browser passkey entitlement.
deploy-signed team configuration="Debug": generate
    xcodebuild -quiet -project Browser.xcodeproj -scheme Browser -configuration "{{configuration}}" -derivedDataPath DerivedData build DEVELOPMENT_TEAM="{{team}}" CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" CODE_SIGN_ENTITLEMENTS=BrowserPasskeys.entitlements -allowProvisioningUpdates
    ./scripts/deploy.sh "{{configuration}}"

test: generate
    xcodebuild -quiet -project Browser.xcodeproj -scheme Browser -configuration Debug -derivedDataPath DerivedData -destination 'platform=macOS' test CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES DEVELOPMENT_TEAM=
