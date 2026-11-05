# Developing BMAD Viewer

SwiftUI shell, AppKit text view (TextKit 1) for documents, no web view.
Building and releasing the app; for what it does, see
[using the app](using-the-app.md).

## Build layout

`scripts/make-app.sh` assembles both configurations into the bundle tree:

```
build/
  debug/BmadViewer.app      # net.xeosdd.BmadViewer.debug, no update feed
  release/BmadViewer.app    # net.xeosdd.BmadViewer, Sparkle feed and keys
  dmg/BmadViewer-<version>.dmg
  tools/                    # Sparkle CLIs (sign_update, generate_keys), gitignored
```

The debug bundle id differs so the two can be installed side by side; only the
release bundle is registered with LaunchServices (Finder's icon) and carries
the Sparkle feed.

## Run

```sh
swift run BmadViewer ~/dev/v6app        # debug, unbundled
swift test                               # the suite
scripts/make-app.sh                      # build/debug/ and build/release/BmadViewer.app
scripts/make-app.sh --install            # …and copy the release to ~/Applications
open build/release/BmadViewer.app --args ~/dev/v6app
```

With no argument it reopens the most recent project; **File › Open Project…** (⌘O) picks another.

## Diagnostics

The `--dump` flag prints what was read and exits, for checking a project from
the terminal without opening a window:

```sh
BmadViewer --dump <project>                                    # tree, epics, stories
BMADV_DIFF=17.5 BmadViewer --dump <project>                    # a story's review range and stop lines
BMADV_QUICKOPEN="9.16|core.rs:940" BmadViewer --dump <project> # top quick-open results
BMADV_SEARCH="DW-1041" BmadViewer --dump <project>             # match counts and timings
```

## Releasing

```sh
scripts/release.sh patch --dry-run   # show the tag and the notes, change nothing
scripts/release.sh 0.1               # tag, build, DMG, publish
```

Cuts a GitHub release from the committed state: notes generated from the commit
subjects since the newest tag — or kept as written if you put your own
`build/release-notes.md` there first — reviewed in your editor before anything
is published, then an annotated tag, a release build wrapped in a DMG with an
Applications shortcut, and a published GitHub release carrying the DMG, which
is what the About window reads
([About and release notes](using-the-app.md#about-and-release-notes)). The tag
is made before the build, so the DMG carries the version it is released as. The
first release is `0.1`; then `patch`, `minor`, `major` or an explicit version.
The build is signed ad-hoc, so a downloaded app needs right-click → Open once.

## Sparkle and the signing key

The DMG is signed for Sparkle and an `appcast.xml` is published beside it, so
installed apps take updates from the stable feed
`releases/latest/download/appcast.xml` — the appcast is written by
`scripts/release.sh` and uploaded as a release asset, and always points at the
newest release's DMG.

Because the app is signed ad-hoc rather than with a developer certificate, the
EdDSA signature on the DMG is the trust anchor. The keypair came from openssl
(Sparkle's own `generate_keys` wants the Keychain):

- **Private key:** `~/.sparkle/BmadViewer-ed25519.key` — outside the repo, on
  purpose. **Losing it means no installed app ever accepts an update again**;
  back it up wherever secrets live. `scripts/release.sh` reads it (or the
  `SPARKLE_PRIVATE_KEY` environment variable, which can name a different file).
- **Public key:** committed at `scripts/sparkle-public-key.txt`, written into
  the release bundle's `SUPublicEDKey` by `scripts/make-app.sh`. Sparkle
  refuses an update whose bundle strips that key or changes the bundle
  identifier — rotation only.

The debug bundle gets no `SUFeedURL`, and the Check for Updates… menu item is
gated on it, so debug builds never offer an update they cannot check.
