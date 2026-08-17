#!/bin/bash
# Build Orecchino.app from the SwiftPM executable and ad-hoc sign it.
set -euo pipefail
cd "$(dirname "$0")/.."

# CommandLineTools' default (swiftbuild) backend fails to resolve the SDK's
# SwiftUI macros plugin; the native backend finds it.
swift build -c release --build-system native

APP="build/Orecchino.app"
BIN=".build/release/Orecchino"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Orecchino"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>      <string>Orecchino</string>
    <key>CFBundleIdentifier</key>      <string>dev.bentley.orecchino</string>
    <key>CFBundleName</key>            <string>Orecchino</string>
    <key>CFBundleDisplayName</key>     <string>Orecchino</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1.0</string>
    <key>CFBundleVersion</key>         <string>1</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSApplicationCategoryType</key> <string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSHumanReadableCopyright</key> <string>Receive-only ASTM F3411 Remote ID viewer</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP"
echo "Built $APP"
