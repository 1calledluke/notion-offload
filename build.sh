#!/bin/bash
# Builds DIT Media Ingest into a real, signed .app bundle.
# Usage: ./build.sh          (builds into ./dist/DIT Media Ingest.app)
#        ./build.sh install  (also copies it to /Applications)
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DIT Media Ingest"
BUNDLE_ID="com.indexvideo.ditingest"
EXEC_NAME="DITIngest"
DIST="dist"
APP="$DIST/$APP_NAME.app"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/release/$EXEC_NAME" "$APP/Contents/MacOS/$EXEC_NAME"

# Bundle the BRAW thumbnail extractor (built separately from tools/brawthumb.cpp
# against the Blackmagic RAW SDK; used to stamp Finder icons on .braw files).
if [[ -f "tools/brawthumb" ]]; then
    cp "tools/brawthumb" "$APP/Contents/Resources/brawthumb"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXEC_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> Code signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

echo "==> Built: $APP"

if [[ "${1:-}" == "install" ]]; then
    echo "==> Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    echo "==> Installed: /Applications/$APP_NAME.app"
fi
