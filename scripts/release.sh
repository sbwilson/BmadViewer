#!/bin/zsh
# Cuts a GitHub release: notes from the commits since the newest tag, an
# annotated tag, a release build wrapped in a DMG, and a published release
# carrying that DMG — the About window reads GitHub Releases, so this is where
# notes come to exist. The DMG is signed for Sparkle and an appcast.xml is
# published beside it, so installed apps can update themselves.
#
#   scripts/release.sh patch              # bump the newest tag (first cut: 0.1)
#   scripts/release.sh 0.3.0              # or name the version
#   scripts/release.sh minor --dry-run    # show the tag and notes, change nothing
#   scripts/release.sh patch --no-edit    # skip the editor; take the notes as generated
#   scripts/release.sh 0.2 --prerelease   # GitHub marks it a pre-release
#   scripts/release.sh patch --yes        # no confirmation prompt
#
# Notes are generated from the commit log, but a build/release-notes.md already
# in place is kept as written — hand-write the notes for a big release by
# putting them there first. --regen rewrites from the log anyway.
#
# The tag comes before the build, because make-app.sh reads the newest tag into
# Info.plist: the DMG must carry the version it is being released as.
# Requires a clean tree. Signed ad-hoc, like make-app.sh; a download needs
# right-click → Open once past Gatekeeper.
set -euo pipefail
cd "${0:A:h}/.."

# ---------- arguments ----------
BUMP=""; DRY=0; EDIT=1; YES=0; REGEN=0; PRE=()
for a in "$@"; do
  case "$a" in
    --dry-run)    DRY=1 ;;
    --no-edit)    EDIT=0 ;;
    --yes)        YES=1 ;;
    --regen)      REGEN=1 ;;
    --prerelease) PRE=(--prerelease) ;;
    -*)           print -u2 "unknown option: $a"; exit 2 ;;
    *)            BUMP="$a" ;;
  esac
done
if [[ -z "$BUMP" ]]; then
  print -u2 "usage: scripts/release.sh <patch|minor|major|x.y.z> [--dry-run] [--no-edit] [--yes] [--regen] [--prerelease]"
  exit 2
fi

# ---------- version ----------
PREV_TAG="$(git describe --tags --abbrev=0 2>/dev/null || true)"
if [[ -n "$PREV_TAG" ]]; then
  NUMBERS="${PREV_TAG#v}"
  parts=( ${=NUMBERS//./ } )   # word-split on dots: 0.2.3 → 0 2 3
  (( ${#parts[@]} == 2 )) && parts+=(0)   # 0.1 behaves like 0.1.0
  case "$BUMP" in
    major) NEXT="$(( parts[1] + 1 )).0.0" ;;
    minor) NEXT="${parts[1]}.$(( parts[2] + 1 )).0" ;;
    patch) NEXT="${parts[1]}.${parts[2]}.$(( ${parts[3]:-0} + 1 ))" ;;
    *)
      if [[ "$BUMP" =~ '^[0-9]+(\.[0-9]+){1,2}$' ]]; then NEXT="$BUMP"
      else print -u2 "not a bump (patch/minor/major) or a version (x.y[.z]): $BUMP"; exit 2; fi ;;
  esac
else
  NEXT="0.1"   # the app's own default version; the first release keeps it
fi
TAG="v$NEXT"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  print -u2 "$TAG already exists"; exit 1
fi

# ---------- notes ----------
# From the commit subjects, which are full sentences here and pass through as
# bullets — unless build/release-notes.md is already in place, kept as written.
RANGE="${PREV_TAG:+$PREV_TAG..}HEAD"
mkdir -p build
NOTES=build/release-notes.md
if [[ -f "$NOTES" ]] && (( ! REGEN )); then
  print "keeping the notes in $NOTES — delete it or pass --regen to rewrite from the commit log"
else
  {
    git log --no-merges --pretty='- %s' "$RANGE"
    echo
    echo "_Signed ad-hoc, not notarized: if Gatekeeper objects to a download, right-click the app and choose Open._"
  } > "$NOTES"
fi

if (( DRY )); then
  print "from ${PREV_TAG:-the whole history} to HEAD → $TAG"
  print "would build build/dmg/BmadViewer-$NEXT.dmg and publish it with these notes:\n"
  cat "$NOTES"
  exit 0
fi

# ---------- guards ----------
BRANCH="$(git branch --show-current)"
[[ -n "$BRANCH" ]] || { print -u2 "not on a branch"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { print -u2 "working tree is not clean — commit or stash first"; exit 1; }
gh auth status >/dev/null 2>&1 || { print -u2 "gh is not authenticated"; exit 1; }

(( EDIT )) && "${EDITOR:-vi}" "$NOTES"
if (( ! YES )); then
  read -r "REPLY?publish $TAG with these notes? [y/N] "
  [[ "$REPLY" == y ]] || { print "not publishing"; exit 1; }
fi

print "swift test…"
if ! swift test > build/test.log 2>&1; then
  tail -20 build/test.log
  print -u2 "tests failed — full log at build/test.log"
  exit 1
fi
tail -2 build/test.log

# ---------- tag, then build so the bundle carries the version ----------
CREATED_TAG=""; PUSHED=0
trap 'rc=$?; if (( rc != 0 )) && [[ -n "$CREATED_TAG" ]] && (( ! PUSHED )); then
  git tag -d "$CREATED_TAG" >/dev/null && print -u2 "aborted: removed local tag $CREATED_TAG"; fi' EXIT
CREATED_TAG="$TAG"
git tag -a "$TAG" -m "$TAG"
print "Tagged $TAG on $(git rev-parse --short HEAD) ($BRANCH)"

scripts/make-app.sh
APP=build/release/BmadViewer.app
BUNDLED="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$BUNDLED" == "$NEXT" ]] || { print -u2 "the build carries $BUNDLED, not $NEXT"; exit 1; }
codesign --verify --strict "$APP"

# ---------- DMG: the app beside an Applications shortcut, drag to install ----------
mkdir -p build/dmg
DMG="build/dmg/BmadViewer-$NEXT.dmg"
STAGE=build/dmg-staging
rm -rf "$STAGE" "$DMG"
mkdir "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "BMAD Viewer" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
print "Built $DMG"

# ---------- Sparkle: sign the DMG and publish an appcast ----------
# The feed lives at releases/latest/download/appcast.xml, so every release
# uploads one. The private half of the signing key lives outside the repo;
# losing it means no future update is trusted by installed apps.
# (A --prerelease cut is invisible to /latest; give pre-releases their own feed
# if that ever matters.)
KEY="${SPARKLE_PRIVATE_KEY:-$HOME/.sparkle/BmadViewer-ed25519.key}"
[[ -f "$KEY" ]] || { print -u2 "no Sparkle signing key at $KEY — set SPARKLE_PRIVATE_KEY"; exit 1; }
TOOLS=build/tools
[[ -x "$TOOLS/sign_update" ]] || {
  print "fetching Sparkle signing tools…"
  mkdir -p "$TOOLS"
  curl -sL https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz \
    | tar -xJ -C "$TOOLS" --strip-components=1 ./bin/sign_update
}
SIGNATURE="$("$TOOLS/sign_update" --ed-key-file "$KEY" -p "$DMG")"
[[ -n "$SIGNATURE" ]] || { print -u2 "sign_update produced no signature"; exit 1; }
SIZE="$(stat -f %z "$DMG")"
APPCAST=build/dmg/appcast.xml
cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>BMAD Viewer Releases</title>
    <link>https://github.com/sbwilson/BmadViewer</link>
    <description>BMAD Viewer updates.</description>
    <language>en</language>
    <item>
      <title>BMAD Viewer $NEXT</title>
      <link>https://github.com/sbwilson/BmadViewer/releases/tag/$TAG</link>
      <pubDate>$(date -R)</pubDate>
      <sparkle:version>$NEXT</sparkle:version>
      <sparkle:shortVersionString>$NEXT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/sbwilson/BmadViewer/releases/download/$TAG/$(basename "$DMG")"
                 sparkle:edSignature="$SIGNATURE"
                 length="$SIZE"
                 type="application/octet-stream"/>
    </item>
  </channel>
</rss>
XML
print "Signed the DMG and wrote $APPCAST"

# ---------- publish ----------
git push origin "$BRANCH"
git push origin "$TAG"
PUSHED=1
gh release create "$TAG" "$DMG" "$APPCAST" \
  --title "BMAD Viewer $NEXT" \
  --notes-file "$NOTES" \
  "${PRE[@]}"
# GitHub holds the notes from here; drop the local draft so the next release
# cannot pick it up by accident.
rm "$NOTES"
print "Published $TAG with $(basename "$DMG") attached — the notes now live on the release."
