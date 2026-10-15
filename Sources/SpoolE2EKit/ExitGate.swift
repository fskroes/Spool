import Foundation

/// Decides who ends the runner: the signal handler (exit 130, no report) or the main thread (report, then the
/// exit code of the report). The first to claim the gate owns the exit; the other must not write or exit.
/// Without it, a signal that comes while the report is written gives a report and exit 130, or two exits.
public final class ExitGate: @unchecked Sendable {
    public enum Owner: Equatable, Sendable { case signal, report }

    private let lock = NSLock()
    private var owner: Owner?

    public init() {}

    /// True when `who` now owns the exit. Later claims, also by the same owner, get false.
    public func claim(_ who: Owner) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard owner == nil else { return false }
        owner = who
        return true
    }

    public var claimedBy: Owner? {
        lock.lock()
        defer { lock.unlock() }
        return owner
    }
}
