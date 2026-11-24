#!/bin/bash
# macOS only; creates an unsigned, device-arm64 IPA for later user signing.
set -euo pipefail
: "${BUNDLE_ID:?Set your permanent Bundle ID before building}"
[[ "$BUNDLE_ID" =~ ^[A-Za-z][A-Za-z0-9-]*(\.[A-Za-z0-9-]+)+$ ]] || { echo 'Invalid Bundle ID' >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo 'Requires macOS with Xcode and Go' >&2; exit 1; }
for tool in go xcrun xcodebuild python3 zip codesign; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
cd "$(dirname "$0")/.."
export IPHONEOS_DEPLOYMENT_TARGET=16.0
# Keep generator dependencies out of the application's go.mod/go.sum.
# Override only deliberately; the selected revision is pinned and reproducible.
mobile_version="${MOBILE_VERSION:-v0.0.0-20240520174638-fa72addaaa1b}"
mkdir -p build/ios/tools build/ios/bridge
export GOBIN="$PWD/build/ios/tools"
export PATH="$GOBIN:$PATH"
go install "golang.org/x/mobile/cmd/gomobile@$mobile_version"
go install "golang.org/x/mobile/cmd/gobind@$mobile_version"
gomobile init
cp go.mod go.sum build/ios/bridge/
# gomobile's generated bridge imports mobile/bind/seq and needs this tool module
# in the binding module graph; a separate modfile leaves upstream modules intact.
go mod edit -modfile=build/ios/bridge/go.mod -require="golang.org/x/mobile@$mobile_version"
go mod download -modfile=build/ios/bridge/go.mod golang.org/x/mobile
GOFLAGS='-mod=mod -modfile=build/ios/bridge/go.mod' gomobile bind -target=ios/arm64 -iosversion=16.0 -o build/ios/Mobile.xcframework ./mobile
framework_dir="$(find build/ios/Mobile.xcframework -type d -name Mobile.framework | head -n 1)"
[[ -n "$framework_dir" ]] || { echo 'Mobile.framework not generated' >&2; exit 1; }
# Build only arm64 iphoneos: no simulator or executable subprocess is shipped.
mkdir -p build/ios/Payload/WorkBuddy.app
app="$PWD/build/ios/Payload/WorkBuddy.app"
BUNDLE_ID="$BUNDLE_ID" python3 - "$app/Info.plist" <<'PY'
import os, plistlib, sys
with open('ios/Info.plist', 'rb') as f:
    info = plistlib.load(f)
info['CFBundleIdentifier'] = os.environ['BUNDLE_ID']
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(info, f)
PY
sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=16.0 \
  -fobjc-arc -O2 -g -F "$(dirname "$framework_dir")" \
  ios/main.m -framework Mobile -framework UIKit -framework Foundation \
  -framework WebKit -framework SafariServices -framework Security \
  -framework CoreFoundation -lresolv -liconv -lc++ -o "$app/WorkBuddy"
xcrun dsymutil "$app/WorkBuddy" -o build/ios/WorkBuddy.app.dSYM
cp LICENSE "$app/LICENSE.txt"
cp ios/gateway-config.js "$app/gateway-config.js"
# No fake signing: this archive needs a real signing tool/provisioning profile
# or the user's compatible installation method before it can be installed.
(cd build/ios && zip -qry WorkBuddy-unsigned.ipa Payload)
shasum -a 256 build/ios/WorkBuddy-unsigned.ipa > build/ios/SHA256SUMS
printf '%s\n' 'Created build/ios/WorkBuddy-unsigned.ipa (not installable until signed)'
