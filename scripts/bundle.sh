#!/bin/sh
# Builds a release binary and wraps it into build/GPUWatcher.app (ad-hoc signed, menu bar only).
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=build/GPUWatcher.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/GPUWatcher "$APP/Contents/MacOS/GPUWatcher"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>GPU Watcher</string>
    <key>CFBundleDisplayName</key><string>GPU Watcher</string>
    <key>CFBundleIdentifier</key><string>dev.gpuwatcher.app</string>
    <key>CFBundleExecutable</key><string>GPUWatcher</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
