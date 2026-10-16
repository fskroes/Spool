import Foundation
import SwiftUI
import SpoolCore

/// The license of this copy of Spool, for the app. The rules live in `LicenseKeeper` (SpoolCore).
@MainActor
final class LicenseGate: ObservableObject {
    static let buyURL = URL(string: "https://1yc.dev/spool")!
    static let restoreURL = URL(string: "https://1yc.dev/spool/restore")!

    let keeper: LicenseKeeper
    @Published private(set) var status: LicenseStatus
    /// The text under the paste field: the last key that failed. Nil after a success.
    @Published var error: String?

    init(keeper: LicenseKeeper = LicenseGate.appKeeper()) {
        self.keeper = keeper
        status = keeper.status
    }

    /// Reads `SpoolLicensePublicKey` from Info.plist and the bundle type of the running process.
    nonisolated static func appKeeper(bundle: Bundle = .main) -> LicenseKeeper {
        LicenseKeeper(publicKey: LicenseKeeper.publicKey(info: bundle.infoDictionary),
                      inAppBundle: LicenseKeeper.isAppBundle(bundle.bundleURL))
    }

    var allowsStart: Bool { status.allowsStart }

    /// The email of the license, for the Settings line. Nil when there is none.
    var licensedEmail: String? {
        if case .licensed(let license) = status { return license.email }
        return nil
    }

    /// Checks and stores `text`. Updates `status` and `error`.
    func activate(_ text: String) -> LicenseKeeper.Outcome {
        let outcome = keeper.activate(text)
        switch outcome {
        case .activated, .notRequired: error = nil
        case .invalid: error = LicenseKey.invalidMessage
        case .saveFailed(let message): error = message
        }
        status = keeper.status
        return outcome
    }
}
