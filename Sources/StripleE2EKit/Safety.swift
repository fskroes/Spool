import CoreGraphics
import Foundation

/// A window of another app, from `CGWindowListCopyWindowInfo`. Bounds and owner need no permission.
public struct WindowSnapshot: Codable, Equatable, Sendable {
    public var number: UInt32
    public var pid: Int32
    public var owner: String
    public var layer: Int
    public var bounds: CGRect
    /// True when the owner is a regular app (`NSApplication.ActivationPolicy.regular`). Striple manages only
    /// regular apps (`Policy.isManageableApp`), so it cannot write to the windows of other processes.
    public var regularApp: Bool

    public init(number: UInt32, pid: Int32, owner: String, layer: Int, bounds: CGRect, regularApp: Bool = true) {
        self.number = number
        self.pid = pid
        self.owner = owner
        self.layer = layer
        self.bounds = bounds
        self.regularApp = regularApp
    }
}

/// The safety check: Striple must not move or resize a window of any other app.
public enum SafetyCheck {
    /// The compared window levels: normal (0) up to, not with, the main menu level (24,
    /// `kCGMainMenuWindowLevel`). So floating panels and modal windows of apps are compared too. The menu bar,
    /// status items, Control Center and notifications (24 and up) move by themselves, for example when Striple
    /// adds its menu bar icon.
    public static let comparedLayers = 0..<24

    /// System processes whose windows change by themselves (the Dock, the window server, Stage Manager).
    /// They are not apps that Striple can manage.
    public static let systemOwners: Set<String> = [
        "Window Server", "Dock", "SystemUIServer", "Control Center", "Notification Center", "WindowManager",
        "Spotlight", "loginwindow", "TextInputMenuAgent", "TextInputSwitcher",
    ]

    /// The windows of other apps in `comparedLayers`, from a CGWindowList result. Windows of `excluding`
    /// (the test app, Striple, the runner) and of `systemOwners` are left out. `isRegularApp` tells the regular
    /// apps from background processes (for example the AutoFill helper of Safari, which resizes its own windows).
    public static func snapshot(_ list: [[String: Any]], excluding: Set<Int32>,
                                isRegularApp: (Int32) -> Bool = { _ in true }) -> [WindowSnapshot] {
        list.compactMap { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            guard let n = (w[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  comparedLayers.contains(layer), !excluding.contains(pid), !systemOwners.contains(owner),
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary) else { return nil }
            return WindowSnapshot(number: n, pid: pid, owner: owner, layer: layer, bounds: bounds, regularApp: isRegularApp(pid))
        }
    }

    public struct Change: Equatable, Sendable {
        public var before: WindowSnapshot
        public var after: WindowSnapshot
        public var description: String {
            "\(before.owner) (pid \(before.pid), window \(before.number)): \(FrameChecks.fmt(before.bounds)) -> \(FrameChecks.fmt(after.bounds))"
        }
    }

    /// Windows that exist before and after with other bounds. 0 points allowed. A window that closed or
    /// opened in between is no change: the user may work while the test runs.
    public static func changes(before: [WindowSnapshot], after: [WindowSnapshot]) -> [Change] {
        let later = Dictionary(after.map { ($0.number, $0) }, uniquingKeysWith: { a, _ in a })
        return before.compactMap { b in
            guard let a = later[b.number], a.bounds != b.bounds else { return nil }
            return Change(before: b, after: a)
        }
    }

    /// The safety row of the report. FAIL when a window of a regular app moved or resized. The app counts as
    /// regular when it was regular before or after: an app can change its activation policy during the run.
    /// SKIP (counts as a failure) when nothing proves the windows stayed: `before` is nil (the setup failed
    /// before the snapshot), there are no windows of regular apps, or fewer than half of them still exist
    /// after. Windows of background processes are compared too, but a change
    /// there is only listed: Striple cannot write to them, and some (AutoFill) resize themselves.
    public static func verdict(before: [WindowSnapshot]?, after: [WindowSnapshot]) -> (result: Report.Result, details: String) {
        guard let before else { return (.skip, "no snapshot of the windows of other apps was taken before the run") }
        let found = Set(after.map(\.number))
        let apps = before.filter(\.regularApp)
        let compared = apps.filter { found.contains($0.number) }.count
        let changed = changes(before: before, after: after)
        let isApp = { (c: Change) in c.before.regularApp || c.after.regularApp }
        let failed = changed.filter(isApp)
        let ignored = changed.filter { !isApp($0) }
        let background = ignored.isEmpty ? "" : "\nNot counted, \(ignored.count) window(s) of background processes changed "
            + "(Striple manages only regular apps):\n" + ignored.map(\.description).joined(separator: "\n")
        if !failed.isEmpty { return (.fail, failed.map(\.description).joined(separator: "\n") + background) }
        if apps.isEmpty {
            return (.skip, "no windows of other apps to compare, so nothing proves that none moved. Open a window of "
                    + "another app and run again." + background)
        }
        let counts = "\(compared) of \(apps.count) windows of other apps compared"
        if compared * 2 < apps.count {
            return (.skip, "\(counts): too many windows closed during the run to prove that none moved. Run again." + background)
        }
        return (.pass, "\(counts), 0 px allowed: none moved or resized" + background)
    }
}

/// The second safety row: every window in every `striple state` was a test window. SKIP when no state was read,
/// because then nothing was checked. `foreign` maps a window to its bundle ID and title.
public enum ManagedCheck {
    public static func verdict(statesRead: Int, foreign: [String: String]) -> (result: Report.Result, details: String) {
        if !foreign.isEmpty { return (.fail, foreign.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")) }
        if statesRead == 0 { return (.skip, "no `striple state` was read, so nothing was checked") }
        return (.pass, "every window in \(statesRead) `striple state` reads had bundle ID \(E2EIDs.windowsBundleID)")
    }
}

/// The markdown report.
public enum Report {
    public enum Result: String, Sendable { case pass = "PASS", fail = "FAIL", skip = "SKIP" }

    public struct Row: Equatable, Sendable {
        public var scenario: String
        public var result: Result
        public var details: String
        public init(scenario: String, result: Result, details: String) {
            self.scenario = scenario
            self.result = result
            self.details = details
        }
    }

    /// One table cell: pipes escaped, newlines as `<br>`.
    public static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
    }

    public static func markdown(title: String, rows: [Row], notes: [String]) -> String {
        var out = "# \(title)\n\n"
        // The same rule as exitCode: only PASS passes. A SKIP proves nothing, so it is not a pass.
        let fails = rows.filter { $0.result == .fail }.count
        let skips = rows.filter { $0.result == .skip }.count
        if rows.isEmpty {
            out += "Result: **FAIL** (no checks ran)\n\n"
        } else if fails + skips == 0 {
            out += "Result: **PASS** (\(rows.count) checks)\n\n"
        } else {
            out += "Result: **FAIL** (\(fails + skips) of \(rows.count) checks did not pass: \(fails) FAIL, \(skips) SKIP)\n\n"
        }
        out += "| Scenario | Result | Details |\n|---|---|---|\n"
        for r in rows { out += "| \(cell(r.scenario)) | \(r.result.rawValue) | \(cell(r.details)) |\n" }
        if !notes.isEmpty {
            out += "\n## Notes\n\n"
            for n in notes { out += "- \(n)\n" }
        }
        return out
    }

    /// Exit code of the runner: 0 only when no row failed and at least one ran.
    public static func exitCode(_ rows: [Row]) -> Int32 {
        rows.isEmpty || rows.contains { $0.result != .pass } ? 1 : 0
    }
}
