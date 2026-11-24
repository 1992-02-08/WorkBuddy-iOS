# iOS development

This is an independent iOS 16+ application fork. Do not integrate LoopAI. Preserve LICENSE and the original upstream source history. The upstream repository stopped maintenance on 2026-10-21; OAuth and inference availability are not verified.

## Architecture and source ownership

- `mobile/`: Go library bound by gomobile, using the original HTTP/SSE gateway and embedded Web panel. No subprocess, daemon, remote website shell, or background service.
- `ios/main.m`: native Home/Accounts/Settings tab navigation, status cards, per-account operations, common configuration form and JSON editor; WKWebView is the advanced-panel entry, and SFSafariViewController hosts official OAuth. Account/config requests use ephemeral URLSession, current MobileAPIKey and generation checks; stopping cancels requests and polling. No UI behavior has been exercised yet. Application Support/WorkBuddy is resolved at runtime. The app listens only on IPv4 loopback; no LAN sharing.
- `internal/panel`: GatewayOnly mode blocks reward/task/checkin/compensation routes and removes automatic login rewards. Original desktop behavior is retained outside this mode.
- `scripts/build-ios.sh`: macOS device-arm64 static framework and unsigned IPA builder.
- `.github/workflows/ios-ipa.yml`: manually dispatched macOS build/tests; artifact upload only. No repository creation, push, install, or release is authorized.

## Build

Requires macOS, full Xcode with iphoneos SDK, Go 1.23.12, Python 3 and zip. Run `go test ./...` and `go test -race ./mobile`, then `BUNDLE_ID=<user-chosen-id> bash scripts/build-ios.sh`. Script pins gomobile and uses a separate modfile. Inspect generated `Mobile/Mobile.h` against native bridge declarations if updating gomobile.

Output is `build/ios/WorkBuddy-unsigned.ipa`, SHA256SUMS and dSYM. An unsigned IPA is not directly installable: the user supplies signing/provisioning or a compatible signing/installation tool. Never claim a signed IPA or installed behavior from source checks. This workspace intentionally has no Apelin `.deb` build script because the requested artifact is an IPA.

## Checks and limits

On the present iPhone, Go, Swift and xcodebuild are absent. `bash -n scripts/build-ios.sh` passes. `clang -arch arm64 -fobjc-arc -fsyntax-only -Werror -Fbuild/check ios/main.m` passes using temporary bridge declarations with Clang modules disabled (modules caused a compiler illegal-instruction crash). Stubs under ignored `build/check/` are not part of the application and do not verify generated bridge compatibility or linking. No Go tests, framework link, IPA build or device UI behavior has yet been validated. Use the manually dispatched workflow to perform the first full build.

After building, confirm the permanent Bundle ID before installation (no install authorized). Exercise startup/shutdown/restart, panel auth, config persistence, task route rejection, own-account OAuth in the browser, and `/v1/models` plus both streaming/nonstreaming chat. Test airplane mode, malformed configuration, background stop and restart. Test actual provider traffic only with the user's own authorized account. Do not log access/refresh/API tokens.

Screen reads/actions and screenshots require the user's consent according to the session rules. Do not invent OAuth redirect URIs: upstream uses server-issued device state and polling. SFSafariViewController keeps the app foreground while authorization runs; switching away stops the gateway, invalidating pending state. User must start a new authorization after restart.
