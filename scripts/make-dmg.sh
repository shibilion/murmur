#!/bin/bash
# Creates a signed, distributable DMG for Murmur.
# Usage: scripts/make-dmg.sh [--notarize <keychain-profile>]
# Set MURMUR_SIGN_IDENTITY=- for an ad-hoc app build. Set MURMUR_IDENTITY to re-sign with a Developer ID before packaging (required for --notarize).
set -euo pipefail

usage() { echo "usage: make-dmg.sh [--notarize <keychain-profile>]" >&2; exit 2; }

NOTARIZE=false
NOTARIZE_PROFILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --notarize)
            [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || usage
            NOTARIZE=true
            NOTARIZE_PROFILE="$2"
            shift 2
            ;;
        *) usage ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

if $NOTARIZE; then
    if [[ "${MURMUR_IDENTITY:-}" != "Developer ID Application"* ]]; then
        echo "error: --notarize requires MURMUR_IDENTITY to be a 'Developer ID Application' identity" >&2
        exit 1
    fi
fi

# ---- build the app ----------------------------------------------------------
echo "Building Murmur app..."
bash scripts/bundle.sh
APP="$ROOT/build/Murmur.app"

if [[ -n "${MURMUR_IDENTITY:-}" ]]; then
    echo "Re-signing with $MURMUR_IDENTITY..."
    SIGN_ARGS=(--force --options runtime --timestamp --entitlements Resources/Murmur.entitlements)
    # --deep only when the bundle actually contains nested code.
    if [[ -n "$(find "$APP/Contents" \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.app' -o -path '*/PlugIns/*' -o -path '*/Frameworks/*' \) -print -quit)" ]]; then
        SIGN_ARGS+=(--deep)
    fi
    codesign "${SIGN_ARGS[@]}" -s "$MURMUR_IDENTITY" "$APP"
fi

echo "Generating DMG background..."
swift scripts/make-dmg-background.swift
tiffutil -cathidpicheck Resources/dmg-background.png Resources/dmg-background@2x.png -out Resources/dmg-background.tiff

VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
DMG_FILE="$ROOT/build/Murmur-${VERSION}.dmg"

# ---- temp state & cleanup ---------------------------------------------------
STAGE_DIR="$(mktemp -d "$ROOT/build/dmg-stage.XXXXXX")"
MNT="$(mktemp -d "$ROOT/build/dmg-mnt.XXXXXX")"   # mount point we own; the only thing we ever detach
TEMP_DMG="$ROOT/build/Murmur-${VERSION}-temp.$$.dmg"
ATTACHED=false

detach_ours() {
    $ATTACHED || return 0
    local i
    for i in 1 2 3 4 5; do
        if hdiutil detach "$MNT" -quiet 2>/dev/null; then ATTACHED=false; return 0; fi
        sleep 1
    done
    hdiutil detach "$MNT" -force -quiet 2>/dev/null && ATTACHED=false || true
}
cleanup() {
    detach_ours
    rm -f "$TEMP_DMG"
    rm -rf "$STAGE_DIR"
    $ATTACHED || rmdir "$MNT" 2>/dev/null || true
}
trap cleanup EXIT

# ---- stage contents ---------------------------------------------------------
ditto "$APP" "$STAGE_DIR/Murmur.app"
ln -s /Applications "$STAGE_DIR/Applications"
mkdir "$STAGE_DIR/.background"
cp Resources/dmg-background.tiff "$STAGE_DIR/.background/dmg-background.tiff"
cp Resources/THIRD_PARTY_NOTICES.txt "$STAGE_DIR/THIRD_PARTY_NOTICES.txt"
README_NAME="First open — read me.txt"
printf '%s\n' "1. Drag Murmur to Applications." "2. Open Murmur. macOS will say it can't check it for malicious software. Click Done." "3. Open System Settings → Privacy & Security, scroll down, and click Open Anyway next to Murmur. Confirm with your password." "4. Murmur opens and shows Get started. You only do this once." "" "Made by Muhamed Shibili · https://shibili.works/" > "$STAGE_DIR/$README_NAME"

# ---- create the read-write image -------------------------------------------
APP_MB=$(( $(du -sk "$STAGE_DIR" | cut -f1) / 1024 + 20 ))
rm -f "$DMG_FILE"
echo "Creating DMG (${APP_MB} MB image)..."
hdiutil create -srcfolder "$STAGE_DIR" -size "${APP_MB}m" -fs HFS+ -volname Murmur -format UDRW -ov -o "$TEMP_DMG" >/dev/null
hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MNT" "$TEMP_DMG" >/dev/null
ATTACHED=true

# ---- Finder layout (best effort) -------------------------------------------
echo "Setting up window layout..."
LAYOUT_OK=false
osascript - "$MNT" "$README_NAME" "THIRD_PARTY_NOTICES.txt" > /dev/null <<'APPLESCRIPT' &
on run argv
    set mntPath to item 1 of argv
    set readmeName to item 2 of argv
    set noticesName to item 3 of argv
    set theDisk to (POSIX file mntPath) as alias
    set bgFile to (POSIX file (mntPath & "/.background/dmg-background.tiff")) as alias
    tell application "Finder"
        open theDisk
        set theWin to container window of theDisk
        set current view of theWin to icon view
        set toolbar visible of theWin to false
        set statusbar visible of theWin to false
        set bounds of theWin to {100, 100, 740, 500}
        set opts to icon view options of theWin
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set text size of opts to 12
        set background picture of opts to bgFile
        set position of item "Murmur.app" of theDisk to {160, 200}
        set position of item "Applications" of theDisk to {480, 200}
        set position of item readmeName of theDisk to {240, 330}
        set position of item noticesName of theDisk to {420, 330}
        update theDisk without registering applications
        delay 2
        close theWin
    end tell
end run
APPLESCRIPT
OSA_PID=$!
# Watchdog: never hang on an Automation prompt.
for _ in $(seq 1 45); do kill -0 "$OSA_PID" 2>/dev/null || break; sleep 1; done
if kill -0 "$OSA_PID" 2>/dev/null; then
    kill "$OSA_PID" 2>/dev/null || true
    wait "$OSA_PID" 2>/dev/null || true
    echo "warning: Finder layout timed out (Automation permission may be pending); DMG will have default layout" >&2
elif wait "$OSA_PID"; then
    LAYOUT_OK=true
else
    echo "warning: Finder layout could not be applied (osascript failed; Automation permission may be needed); DMG will have default layout" >&2
fi

sync
if $LAYOUT_OK; then
    for _ in $(seq 1 10); do [[ -f "$MNT/.DS_Store" ]] && break; sleep 1; done
    if [[ -f "$MNT/.DS_Store" ]]; then
        echo "Finder layout applied."
    else
        echo "warning: Finder reported success but .DS_Store was not written; default layout" >&2
    fi
fi

detach_ours
[[ "$ATTACHED" == false ]] || { echo "error: could not detach $MNT" >&2; exit 1; }

# ---- compress & sign --------------------------------------------------------
hdiutil convert "$TEMP_DMG" -format UDZO -ov -o "$DMG_FILE" >/dev/null
rm -f "$TEMP_DMG"

echo "Signing DMG..."
if [[ -n "${MURMUR_IDENTITY:-}" ]]; then
    codesign --force --timestamp -s "$MURMUR_IDENTITY" "$DMG_FILE"   # no --options runtime on a DMG
else
    codesign --force -s "-" "$DMG_FILE"
fi

SIZE=$(stat -f%z "$DMG_FILE")
echo "DMG size: $SIZE bytes ($(( SIZE / 1024 / 1024 )) MB)"
if (( SIZE > 45 * 1024 * 1024 )); then
    echo "error: DMG exceeds 45 MB limit" >&2
    exit 1
fi

# ---- notarize ---------------------------------------------------------------
if $NOTARIZE; then
    echo "Submitting to notarization..."
    xcrun notarytool submit --keychain-profile "$NOTARIZE_PROFILE" --wait "$DMG_FILE"
    xcrun stapler staple "$DMG_FILE"
    xcrun stapler validate "$DMG_FILE"
fi

echo "Done! Created $DMG_FILE"
