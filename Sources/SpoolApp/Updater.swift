import AppKit
import Sparkle
import SpoolCore

/// Software updates through Sparkle.
///
/// The updater exists only when the app runs from a bundle whose Info.plist has a
/// non-empty `SUFeedURL` and `SUPublicEDKey`, and an `SUEnableAutomaticChecks` key (without
/// it Sparkle asks for permission on the second launch). `scripts/build-app.sh` writes these
/// keys only when `SPOOL_FEED_URL` and `SPOOL_ED_PUBLIC_KEY` are set at build time.
/// Without them (and under `swift run`) no Sparkle object is created, so Sparkle cannot
/// show an error or check a feed. A test run (`SPOOL_HOME` set) has no updater either:
/// an update window must not appear while `make e2e` moves windows.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?
    /// Sparkle keeps only a weak reference to its user driver delegate.
    let windows = UpdateWindows()

    /// False when the build has no update feed. The menu item is then disabled.
    var isConfigured: Bool { controller != nil }

    /// False while Sparkle checks in the background: a click on Check for Updates would then do nothing.
    /// True while an update is on screen, so the click brings it to the front.
    var canCheckForUpdates: Bool { controller?.updater.canCheckForUpdates ?? false }

    private init(bundle: Bundle = .main) {
        let configured = Updater.isEnabled(hasFeed: Updater.hasUpdateFeed(bundle), isolated: SpoolPaths.isIsolated)
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: windows)
            : nil
    }

    func checkForUpdates() {
        guard let controller else { return }
        // Sparkle shows "Checking for updates…" without a delegate call first. Count it now, but only when Sparkle
        // starts a new session: every user session ends with standardUserDriverWillFinishUpdateSession.
        if controller.updater.canCheckForUpdates {
            windows.opened?(UpdateWindows.window)
            // Sparkle activates only an accessory app, and Spool is now a regular app.
            App.activate()
        }
        controller.checkForUpdates(nil)
    }

    /// Brings the update window to the front. A regular app that is active gets a scheduled update only when it
    /// becomes active again, so without this a Dock click would show nothing.
    func showPendingUpdate() {
        // canCheckForUpdates is false while Sparkle still checks; a check then only logs an error.
        guard let controller, controller.updater.sessionInProgress, controller.updater.canCheckForUpdates else { return }
        controller.checkForUpdates(nil)
    }

    /// Sparkle runs only with a feed and never in a test run.
    nonisolated static func isEnabled(hasFeed: Bool, isolated: Bool) -> Bool { hasFeed && !isolated }

    /// True only for a real app bundle with the Sparkle keys set.
    nonisolated static func hasUpdateFeed(_ bundle: Bundle) -> Bool {
        guard bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" else { return false }
        return hasUpdateFeed(info: bundle.infoDictionary ?? [:])
    }

    /// Without `SUEnableAutomaticChecks` Sparkle asks for permission in a window that ends no update session, so
    /// UpdateWindows would keep the Dock icon. `scripts/build-app.sh` writes the key together with the feed.
    nonisolated static func hasUpdateFeed(info: [String: Any]) -> Bool {
        nonEmpty(info["SUFeedURL"]) && nonEmpty(info["SUPublicEDKey"]) && info["SUEnableAutomaticChecks"] != nil
    }

    private nonisolated static func nonEmpty(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Sparkle's update window and its alerts ("You're up to date") count as open Spool windows. Then they have a Dock
/// icon and a place in ⌘Tab, and they do not get lost behind the windows on the strip when Settings closes.
@MainActor
final class UpdateWindows: NSObject, SPUStandardUserDriverDelegate {
    nonisolated static let window = "update"
    nonisolated static let alert = "update-alert"

    var opened: ((String) -> Void)?
    var closed: ((String) -> Void)?

    func updateWillShow(byStandardDriver: Bool) {
        if byStandardDriver { opened?(Self.window) }
    }

    func alertWillShow() { opened?(Self.alert) }
    func alertDidClose() { closed?(Self.alert) }
    func sessionWillFinish() { closed?(Self.window) }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        MainActor.assumeIsolated { updateWillShow(byStandardDriver: handleShowingUpdate) }
    }

    nonisolated func standardUserDriverWillShowModalAlert() {
        MainActor.assumeIsolated { alertWillShow() }
    }

    nonisolated func standardUserDriverDidShowModalAlert() {
        MainActor.assumeIsolated { alertDidClose() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { sessionWillFinish() }
    }
}
