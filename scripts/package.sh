#!/bin/bash
set -e

APP_NAME="PhotoChronicle"
BUILD_DIR=".build/arm64-apple-macosx/release"
ICON_SOURCE="assets/icon.png"
ICONSET_DIR="assets/PhotoChronicle.iconset"
OUTPUT_DIR="dist"

echo "📦 Packaging $APP_NAME..."

# 0. Clean & Prepare
rm -rf "$OUTPUT_DIR"
mkdir -p "$OUTPUT_DIR"
mkdir -p "$ICONSET_DIR"
mkdir -p "$OUTPUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUTPUT_DIR/$APP_NAME.app/Contents/Resources"

# 1. Generate AppIcon.icns
if [ -f "$ICON_SOURCE" ]; then
    echo "🎨 Generating AppIcon..."
    sips -z 16 16     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16.png"
    sips -z 32 32     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png"
    sips -z 32 32     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32.png"
    sips -z 64 64     -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png"
    sips -z 128 128   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128.png"
    sips -z 256 256   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png"
    sips -z 256 256   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256.png"
    sips -z 512 512   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png"
    sips -z 512 512   -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512.png"
    sips -z 1024 1024 -s format png "$ICON_SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png"

    iconutil -c icns "$ICONSET_DIR" -o "$OUTPUT_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns"
else
    echo "⚠️ Warning: No icon found at $ICON_SOURCE"
fi

# 2. Build Release
echo "🔨 Building Release..."
swift build -c release --arch arm64

# 3. Create Bundle Structure
echo "📂 Creating .app Bundle..."
cp "$BUILD_DIR/$APP_NAME" "$OUTPUT_DIR/$APP_NAME.app/Contents/MacOS/"

# Function to extract build number (or default to 1)
VERSION="1.0.0"
BUILD="1"

# Create Info.plist
cat > "$OUTPUT_DIR/$APP_NAME.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.daito.PhotoChronicle</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# 4. Create DMG
echo "💿 Creating DMG Installer..."
DMG_NAME="${APP_NAME}_Installer.dmg"
rm -f "$OUTPUT_DIR/$DMG_NAME"

hdiutil create -volname "$APP_NAME Installer" -srcfolder "$OUTPUT_DIR/$APP_NAME.app" -ov -format UDZO "$OUTPUT_DIR/$DMG_NAME"

echo "✅ Done! Installer at $OUTPUT_DIR/$DMG_NAME"
open "$OUTPUT_DIR"
