import Foundation
import Sparkle
import StripleCore

/// Software updates through Sparkle.
///
/// The updater exists only when the app runs from a bundle whose Info.plist has a
/// non-empty `SUFeedURL` and `SUPublicEDKey`. `scripts/build-app.sh` writes these keys
/// only when `STRIPLE_FEED_URL` and `STRIPLE_ED_PUBLIC_KEY` are set at build time.
/// Without them (and under `swift run`) no Sparkle object is created, so Sparkle cannot
/// show an error or check a feed. A test run (`STRIPLE_HOME` set) has no updater either:
/// an update window must not appear while `make e2e` moves windows.
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller: SPUStandardUpdaterController?

    /// False when the build has no update feed. The menu item is then disabled.
    var isConfigured: Bool { controller != nil }

    private init(bundle: Bundle = .main) {
        let configured = Updater.isEnabled(hasFeed: Updater.hasUpdateFeed(bundle), isolated: StriplePaths.isIsolated)
        controller = configured
            ? SPUStandardUpdaterController(startingUpdater: configured, updaterDelegate: nil, userDriverDelegate: nil)
            : nil
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Sparkle runs only with a feed and never in a test run.
    nonisolated static func isEnabled(hasFeed: Bool, isolated: Bool) -> Bool { hasFeed && !isolated }

    /// True only for a real app bundle with both Sparkle keys set.
    nonisolated static func hasUpdateFeed(_ bundle: Bundle) -> Bool {
        guard bundle.bundleIdentifier != nil, bundle.bundleURL.pathExtension == "app" else { return false }
        return nonEmpty(bundle.object(forInfoDictionaryKey: "SUFeedURL"))
            && nonEmpty(bundle.object(forInfoDictionaryKey: "SUPublicEDKey"))
    }

    private nonisolated static func nonEmpty(_ value: Any?) -> Bool {
        guard let text = value as? String else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
