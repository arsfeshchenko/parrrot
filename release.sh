#!/bin/bash
set -e

DEST="/Applications/CarelessWhisper.app"
CERT="Developer ID Application: Arsenii Feshchenko (RQ7PKJYC67)"
ZIP="$HOME/CarelessWhisper.zip"
DMG="$HOME/CarelessWhisper.dmg"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Get version from project
VERSION=$(grep -m1 'MARKETING_VERSION' Parrrot.xcodeproj/project.pbxproj | sed 's/.*= //;s/;.*//')

echo "→ Building v${VERSION} (Release)..."
xcodebuild -project Parrrot.xcodeproj -scheme CarelessWhisper -configuration Release clean build 2>&1 | grep -E "(error:|BUILD|warning:.*sign)"

DERIVED=$(ls -d "$HOME/Library/Developer/Xcode/DerivedData/Parrrot-"*/Build/Products/Release/CarelessWhisper.app 2>/dev/null | head -1)

echo "→ Deploying..."
pkill -9 -f "CarelessWhisper" 2>/dev/null || true; sleep 0.5
rm -rf "$DEST"
cp -R "$DERIVED" "$DEST"

echo "→ Signing with Developer ID (hardened runtime)..."
find "$DEST" -name "*.dylib" -exec codesign --force --options runtime --sign "$CERT" {} \;
codesign --force --options runtime --sign "$CERT" "$DEST"

echo "→ Notarizing..."
cd /Applications && zip -r "$ZIP" CarelessWhisper.app
cd - > /dev/null
xcrun notarytool submit "$ZIP" --keychain-profile "CarelessWhisper" --wait
xcrun stapler staple "$DEST"

echo "→ Re-creating zip after stapling..."
rm -f "$ZIP"
cd /Applications && zip -r "$ZIP" CarelessWhisper.app
cd - > /dev/null

echo "→ Creating DMG installer..."
DMG_TMP="$HOME/CarelessWhisper-rw.dmg"
DMG_DIR=$(mktemp -d)
BG_IMG="$SCRIPT_DIR/dmg_background.jpeg"

# Stage DMG contents
cp -R "$DEST" "$DMG_DIR/"
ln -s /Applications "$DMG_DIR/Applications"
mkdir -p "$DMG_DIR/.background"
cp "$BG_IMG" "$DMG_DIR/.background/bg.jpeg"

# Background image is 1280x807; window uses half that for Retina
WIN_W=640
WIN_H=404
APP_X=155
APP_Y=200
APPS_X=485
APPS_Y=200
ICON_SIZE=100

# Create writable DMG
rm -f "$DMG_TMP" "$DMG"
hdiutil create -srcfolder "$DMG_DIR" -volname "CarelessWhisper" \
    -fs HFS+ -format UDRW -ov "$DMG_TMP"
rm -rf "$DMG_DIR"

# Mount writable DMG
DEVICE=$(hdiutil attach -readwrite -noverify "$DMG_TMP" | grep "Apple_HFS" | awk '{print $1}')
MOUNT="/Volumes/CarelessWhisper"

# Set window layout with AppleScript
osascript <<APPLESCRIPT
tell application "Finder"
    tell disk "CarelessWhisper"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {200, 200, $((200 + WIN_W)), $((200 + WIN_H))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to ${ICON_SIZE}
        set background picture of viewOptions to file ".background:bg.jpeg"
        set position of item "CarelessWhisper.app" of container window to {${APP_X}, ${APP_Y}}
        set position of item "Applications" of container window to {${APPS_X}, ${APPS_Y}}
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT

# Hide background folder
SetFile -a V "$MOUNT/.background" 2>/dev/null || true

sync
hdiutil detach "$DEVICE"

# Convert to compressed read-only DMG
hdiutil convert "$DMG_TMP" -format UDZO -imagekey zlib-level=9 -o "$DMG"
rm -f "$DMG_TMP"

echo "→ Creating GitHub release v${VERSION}..."
gh release create "v${VERSION}" "$ZIP" "$DMG" \
    --title "v${VERSION}" --notes "Release v${VERSION}"

echo "→ Cleaning up..."
rm -f "$ZIP" "$DMG"

echo "→ Launching..."
open "$DEST"
echo "✓ Released v${VERSION}"
