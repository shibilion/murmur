#!/bin/bash
# Builds release and assembles build/Murmur.app, signed with "Murmur Dev" when present, else ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)"

APP="build/Murmur.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Murmur" "$APP/Contents/MacOS/Murmur"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/THIRD_PARTY_NOTICES.txt "$APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
# llama.cpp (arm64, vendored). The executable carries rpath @executable_path/../Frameworks (Package.swift).
ditto Vendor/llama.xcframework/macos-arm64/llama.framework "$APP/Contents/Frameworks/llama.framework"
# SwiftPM resource bundles (if any dependency ships one).
for b in "$BIN"/*.bundle; do [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"; done

if [ -n "${MURMUR_SIGN_IDENTITY:-}" ]; then
    IDENTITY="$MURMUR_SIGN_IDENTITY"   # e.g. "-" for ad-hoc when the keychain prompt is unavailable
elif security find-identity -v -p codesigning | grep -q '"Murmur Dev"'; then
    IDENTITY="Murmur Dev"
else
    IDENTITY="-"
    echo "warning: signing ad-hoc; permissions will reset on every rebuild until you run scripts/create-signing-identity.sh" >&2
fi
# Sign nested code first, then the app.
codesign --force --options runtime -s "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
codesign --force --options runtime --entitlements Resources/Murmur.entitlements -s "$IDENTITY" "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP (signed: $IDENTITY)"
if [ "${MURMUR_SKIP_SMOKE:-}" != "1" ]; then
    scripts/smoke-launch.sh
fi
