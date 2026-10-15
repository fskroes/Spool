import Foundation

/// Tells a focus that another app took from a focus that Spool lost (docs/E2E.md, "Focus taken by another app").
///
/// Spool manages only the test app in a run (`SPOOL_MANAGE_ONLY`), so it never makes another app active.
/// When the newest activation after the last confirmed focus is an app that is not the test app and not Spool,
/// the user or that app took the focus: the runner gives it back and goes on, at most `maxPerRun` times.
public enum FocusTheft {
    /// More thefts than this in one run: the run fails, because the results would mean little.
    public static let maxPerRun = 3

    /// The app that took the focus after activation `mark`, or nil when the focus was not taken by another app.
    /// It must be the newest activation: when the test app or Spool became active after it, the focus problem
    /// is not that app's doing.
    public static func thief(_ report: WindowReport?, after mark: Int, spoolPID: Int32?) -> AppActivation? {
        guard let report, let last = report.activations?.last, last.index > mark else { return nil }
        guard last.pid > 0, last.pid != report.pid, last.pid != spoolPID else { return nil }
        return last
    }

    /// Whether the runner may give the focus back to test window `want` after a theft. Another app takes only the
    /// system focus: Spool's focus then stays on `want`, or is none (the app has a window that Spool does not
    /// manage). When Spool's focus is on another test window, Spool moved it there: that is Spool's failure,
    /// and a `focus-window` must not hide it.
    public static func mayGiveBack(to want: UInt32, spoolFocus: UInt32?, focusIsTestWindow: Bool) -> Bool {
        guard let focus = spoolFocus, focusIsTestWindow else { return true }
        return focus == want
    }
}
