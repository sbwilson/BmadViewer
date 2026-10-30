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

# App icon: an .icns derived from the source PNG, rebuilt every time so the
# bundle always carries what the repo says.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Sources/BmadViewer/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Sources/BmadViewer/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

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
  <key>CFBundleIconFile</key><string>AppIcon</string>
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
