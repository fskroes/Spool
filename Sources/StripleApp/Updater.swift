import Foundation

/// Software updates. Stub: the packaging unit replaces this file with the Sparkle version.
@MainActor
final class Updater {
    static let shared = Updater()

    /// False when the build has no update feed. The menu item is then disabled.
    var isConfigured: Bool { false }

    func checkForUpdates() {}
}
