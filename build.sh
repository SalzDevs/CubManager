#!/bin/bash
# Build CubManager.app — native macOS app manager.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CubManager"
BUNDLE_ID="com.salzdevs.cubmanager"
VERSION="1.0.0"
ICON_SRC="Assets/AppIcon.png"

BUNDLE="$APP_NAME.app"
ICONSET="AppIcon.iconset"
ICNS="AppIcon.icns"

# 1. Generate .icns from the source PNG.
echo "→ Generating $ICNS"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    half=$((size / 2))
    sips -z "$((size * 2))" "$((size * 2))" "$ICON_SRC" --out "$ICONSET/icon_${half}x${half}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"

# 2. Assemble the .app bundle.
echo "→ Building $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

find Sources -name "*.swift" -print0 | xargs -0 swiftc -parse-as-library -O -o "$BUNDLE/Contents/MacOS/$APP_NAME"

cp "$ICNS" "$BUNDLE/Contents/Resources/$ICNS"
cp "Assets/MenuBarIcon.png" "$BUNDLE/Contents/Resources/MenuBarIcon.png"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>$ICNS</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
PLIST

echo "✓ Built $BUNDLE ($(du -sh "$BUNDLE" | cut -f1))"
