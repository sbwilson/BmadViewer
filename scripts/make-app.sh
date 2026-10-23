#!/bin/zsh
# Builds BmadViewer.app from the Swift package: a release binary wrapped in a
# minimal bundle, so it gets a Dock icon, Open Recent and Launch Services.
#   scripts/make-app.sh            → build/BmadViewer.app
#   scripts/make-app.sh --install  → also copies it to ~/Applications
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release --product BmadViewer
BIN="$(swift build -c release --show-bin-path)"
APP=build/BmadViewer.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/BmadViewer" "$APP/Contents/MacOS/"
# SwiftPM resource bundles, if any dependency ships one.
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

VERSION="$(git describe --tags --always 2>/dev/null || echo 0.1)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>BMAD Viewer</string>
  <key>CFBundleDisplayName</key><string>BMAD Viewer</string>
  <key>CFBundleIdentifier</key><string>net.xeosdd.BmadViewer</string>
  <key>CFBundleExecutable</key><string>BmadViewer</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/BmadViewer.app
  cp -R "$APP" ~/Applications/
  echo "Installed ~/Applications/BmadViewer.app"
fi
