#!/bin/bash
# Builds Glaude.app into app/build (ad-hoc signed). Needs the Xcode Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Glaude.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

if ! swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/Glaude" Sources/Glaude/*.swift; then
  rm -rf "$APP"
  echo >&2
  echo "Glaude didn't build. If the errors mention a missing macro plugin, your Swift" >&2
  echo "toolchain can't build SwiftUI macros: install Xcode, or download the prebuilt" >&2
  echo "app from https://github.com/vaseemcholakkan123/Glaude/releases instead." >&2
  exit 1
fi


cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>dev.glaude.app</string>
    <key>CFBundleName</key><string>Glaude</string>
    <key>CFBundleExecutable</key><string>Glaude</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
