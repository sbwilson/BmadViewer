#!/bin/zsh
# Builds BmadViewer.app from the Swift package, debug and release, each in its
# own folder under build/:
#   scripts/make-app.sh            → build/debug/BmadViewer.app
#                                     build/release/BmadViewer.app
#   scripts/make-app.sh --install  → also copies the release one to ~/Applications
# The debug bundle carries a .debug bundle identifier and its own display name,
# so it launches beside the release build instead of Launch Services waking
# that one, and its preferences — recent projects and all — are its own.
# Only the release bundle is registered with Launch Services, and only it gets
# the Sparkle feed: updates are signed for shipping, not for the debug twin.
set -euo pipefail
cd "${0:A:h}/.."

VERSION="$(git describe --tags --always 2>/dev/null | sed 's/^v//' || true)"
: "${VERSION:=0.1}"
# The short version is the newest tag minus its v, so the About window's version
# and the GitHub release tags say the same thing.
SHORT_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
: "${SHORT_VERSION:=0.1}"

# Sparkle self-update identity. The public key ships with the repo; the private
# half lives outside it (~/.sparkle/BmadViewer-ed25519.key) and scripts/release.sh
# signs updates with it. Only the release bundle gets a feed: a debug build
# updating itself to a release build would swap identities under the user.
SPARKLE_FEED_URL="https://github.com/sbwilson/BmadViewer/releases/latest/download/appcast.xml"
SPARKLE_PUBLIC_ED_KEY="$(cat scripts/sparkle-public-key.txt)"

# The app icon, derived from the source PNG and built once for both bundles, so
# each always carries what the repo says.
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z $size $size Sources/BmadViewer/icon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) Sources/BmadViewer/icon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o build/AppIcon.icns
rm -rf "$ICONSET"

# assemble <config> <app path> <bundle id> <display name> <build version> <sparkle feed url>
assemble() {
  local conf="$1" app="$2" bundle_id="$3" display="$4" build="$5" feed="$6"
  swift build -c "$conf" --product BmadViewer
  local bin
  bin="$(swift build -c "$conf" --show-bin-path)"

  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
  cp "$bin/BmadViewer" "$app/Contents/MacOS/"
  # SwiftPM resource bundles, if any dependency ships one.
  for b in "$bin"/*.bundle(N); do cp -R "$b" "$app/Contents/Resources/"; done
  # Sparkle, so updates can be installed in place. The binary finds it by
  # @rpath, and SwiftPM's rpaths point back at the build directory — the
  # bundle needs its own.
  cp -R "$bin"/Sparkle.framework "$app/Contents/Frameworks/"
  if ! otool -l "$app/Contents/MacOS/BmadViewer" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/BmadViewer"
  fi
  cp build/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"

  local sparkle_plist=""
  if [[ -n "$feed" ]]; then
    sparkle_plist="  <key>SUFeedURL</key><string>${feed}</string>
  <key>SUPublicEDKey</key><string>${SPARKLE_PUBLIC_ED_KEY}</string>
  <key>SUEnableAutomaticChecks</key><true/>"
  fi

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>${display}</string>
  <key>CFBundleDisplayName</key><string>${display}</string>
  <key>CFBundleIdentifier</key><string>${bundle_id}</string>
  <key>CFBundleExecutable</key><string>BmadViewer</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${SHORT_VERSION}</string>
  <key>CFBundleVersion</key><string>${build}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
${sparkle_plist}
</dict>
</plist>
PLIST

  # The nested pieces of Sparkle must carry signatures of their own before the
  # app seals the bundle: copy broke the signatures they shipped with, and an
  # updater the system will not launch is worse than none.
  for nested in "$app"/Contents/Frameworks/Sparkle.framework/Versions/*/XPCServices/*.xpc(N) \
                "$app"/Contents/Frameworks/Sparkle.framework/Versions/*/Updater.app(N); do
    codesign --force --deep --sign - "$nested" >/dev/null
  done
  codesign --force --sign - "$app"/Contents/Frameworks/Sparkle.framework >/dev/null
  codesign --force --sign - "$app" >/dev/null
  echo "Built $app"
}

assemble debug build/debug/BmadViewer.app net.xeosdd.BmadViewer.debug "BMAD Viewer (Debug)" "${VERSION}-debug" ""
assemble release build/release/BmadViewer.app net.xeosdd.BmadViewer "BMAD Viewer" "$VERSION" "$SPARKLE_FEED_URL"

# A rebuild takes the registered bundle away and the new one is, to Launch
# Services, a stranger wearing its clothes; without this it keeps the stale
# entry and Finder and the Dock show a blank icon until the cache clears on
# its own — which is what makes the icon look like it vanished after a rebuild.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -f build/release/BmadViewer.app

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/BmadViewer.app
  cp -R build/release/BmadViewer.app ~/Applications/
  "$LSREGISTER" -f ~/Applications/BmadViewer.app
  echo "Installed ~/Applications/BmadViewer.app"
fi
