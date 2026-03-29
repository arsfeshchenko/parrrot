#!/bin/bash
set -e

DEST="/Applications/CarelessWhisper.app"
CERT="Developer ID Application: Arsenii Feshchenko (RQ7PKJYC67)"
ZIP="$HOME/CarelessWhisper.zip"

# Get version from project
VERSION=$(grep -m1 'MARKETING_VERSION' Parrrot.xcodeproj/project.pbxproj | sed 's/.*= //;s/;.*//')

echo "→ Building v${VERSION} (Release)..."
xcodebuild -project Parrrot.xcodeproj -scheme CarelessWhisper -configuration Release clean build 2>&1 | grep -E "(error:|BUILD|warning:.*sign)"

DERIVED=$(ls -d "$HOME/Library/Developer/Xcode/DerivedData/Parrrot-"*/Build/Products/Release/CarelessWhisper.app 2>/dev/null | head -1)

echo "→ Deploying..."
pkill -9 -f "CarelessWhisper" 2>/dev/null || true; sleep 0.5
rm -rf "$DEST"
cp -R "$DERIVED" "$DEST"

echo "→ Signing with Developer ID..."
find "$DEST" -name "*.dylib" -exec codesign --force --sign "$CERT" {} \;
codesign --force --sign "$CERT" "$DEST"

echo "→ Creating zip..."
cd /Applications && zip -r "$ZIP" CarelessWhisper.app
cd - > /dev/null

echo "→ Creating GitHub release v${VERSION}..."
gh release create "v${VERSION}" "$ZIP" --title "v${VERSION}" --notes "Release v${VERSION}"

echo "→ Cleaning up..."
rm "$ZIP"

echo "→ Launching..."
open "$DEST"
echo "✓ Released v${VERSION}"
