import AppKit
import Sparkle

/// Self-updating through Sparkle: the release bundle's feed URL and EdDSA
/// public key are written into `Info.plist` by `scripts/make-app.sh`, and
/// `scripts/release.sh` signs the DMG it publishes. The trust anchor is the
/// EdDSA signature — the bundle itself is only ad-hoc signed, which Sparkle
/// accepts for updates as long as the archive's signature holds.
///
/// The controller must live for the whole run, so it hangs off a singleton
/// rather than any window's state; `AppDelegate` touches it once at launch so
/// Sparkle's automatic check gets a chance to run.
@MainActor
final class AppUpdater {
    static let shared = AppUpdater()

    private let logging = UpdaterLogging()
    private let controller: SPUStandardUpdaterController

    private init() {
        controller = SPUStandardUpdaterController(startingUpdater: true,
                                                  updaterDelegate: logging,
                                                  userDriverDelegate: nil)
    }

    /// Whether this bundle has an update feed at all: make-app.sh gives the
    /// debug twin none, and the menu item has no business there.
    var isConfigured: Bool {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil
    }

    /// The menu's Check for Updates… — with its result window brought to the
    /// front, since nothing else in the app asked for it.
    func checkForUpdates() {
        NSApp.activate(ignoringOtherApps: true)
        controller.checkForUpdates(nil)
    }
}

/// Sparkle handles the user-facing side of a failed check, but a cycle that
/// ends quietly is invisible in the console; this keeps it at least auditable.
private final class UpdaterLogging: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error {
            NSLog("Sparkle: update check ended with error: %@", error.localizedDescription)
        }
    }
}
