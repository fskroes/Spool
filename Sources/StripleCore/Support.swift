import CoreGraphics
import Foundation

// MARK: - Session restore

/// One saved strip.
public struct SessionStrip: Codable, Equatable, Sendable {
    public var displayID: String
    public var spaceID: UInt64
    public var strip: Strip

    public init(displayID: String, spaceID: UInt64, strip: Strip) {
        self.displayID = displayID
        self.spaceID = spaceID
        self.strip = strip
    }
}

/// A saved tiled window whose app did not answer during a restore. It waits for the app, then goes back to
/// its saved place.
public struct HeldWindow: Equatable, Sendable {
    public var info: WindowInfo
    public var displayID: String
    public var spaceID: UInt64
    /// The windows that came before it on the strip, nearest first: live IDs of restored windows, and the IDs
    /// of held windows. A position number would go wrong when a restore drops columns (closed windows).
    public var after: [WindowID]
    public var width: ColumnWidth
    /// A window the user floated. It comes back floating, not in a slot (display, Space, after and width unused).
    public var floats: Bool

    public init(info: WindowInfo, displayID: String, spaceID: UInt64, after: [WindowID], width: ColumnWidth, floats: Bool = false) {
        self.info = info
        self.displayID = displayID
        self.spaceID = spaceID
        self.after = after
        self.width = width
        self.floats = floats
    }

    /// The 1-based slot in `strip`: right after the column of the nearest window before it that is on the strip.
    public func slot(in strip: Strip) -> Int {
        for id in after { if let c = strip.locate(id)?.column { return c + 2 } }
        return 1
    }

    /// Takes the held windows that `live` windows are, in the order of `Session.restore`: first the same ID or
    /// title for all windows, so a loose match never steals an exact one; then (with `byApp`) the remaining
    /// held windows of the same app, in saved order. The result is in the order of `held`, so placing the pairs
    /// in that order finds the anchors of later ones.
    /// `fits`: whether a live window can be a held one when the ID is not the same (for example: it is on the
    /// held window's Space). A window on another Space would go to a strip that is not on screen.
    public static func take(_ held: inout [HeldWindow], for live: [WindowInfo], byApp: Bool,
                            fits: (HeldWindow, WindowInfo) -> Bool = { _, _ in true }) -> [(live: WindowInfo, held: HeldWindow)] {
        var pool = live
        var pick: [Int: WindowInfo] = [:]
        for (i, h) in held.enumerated() {
            if let j = pool.firstIndex(where: { $0.id == h.info.id && $0.bundleID == h.info.bundleID })
                ?? (h.info.title.isEmpty ? nil : pool.firstIndex { $0.bundleID == h.info.bundleID && $0.title == h.info.title && fits(h, $0) }) {
                pick[i] = pool.remove(at: j)
            }
        }
        if byApp {
            // A floating window comes back only by ID or title: a guess would float a window the user tiled.
            for (i, h) in held.enumerated() where pick[i] == nil && !h.floats {
                if let j = pool.firstIndex(where: { $0.bundleID == h.info.bundleID && fits(h, $0) }) { pick[i] = pool.remove(at: j) }
            }
        }
        let out = held.indices.compactMap { i in pick[i].map { (live: $0, held: held[i]) } }
        held = held.indices.filter { pick[$0] == nil }.map { held[$0] }
        return out
    }

    /// A held window came back with a new ID (after a restart). Later held windows that come after it use the new ID.
    public static func rename(_ held: inout [HeldWindow], from old: WindowID, to new: WindowID) {
        guard old != new else { return }
        for i in held.indices { held[i].after = held[i].after.map { $0 == old ? new : $0 } }
    }

    /// Passes the new IDs of a batch from `take` on to the other pairs of the batch and to the held windows that
    /// are left. Do this before the pairs are placed: a pair whose nearest anchor is another pair of the same
    /// batch must find that window by its new ID.
    public static func passOnNewIDs(_ pairs: inout [(live: WindowInfo, held: HeldWindow)], held: inout [HeldWindow]) {
        for p in pairs where p.held.info.id != p.live.id {
            for i in pairs.indices { rename(&pairs[i].held, from: p.held.info.id, to: p.live.id) }
            rename(&held, from: p.held.info.id, to: p.live.id)
        }
    }

    private static func rename(_ h: inout HeldWindow, from old: WindowID, to new: WindowID) {
        h.after = h.after.map { $0 == old ? new : $0 }
    }

    /// An app quit. Its held windows go to another running copy of the same app (`nextPid`), because a held
    /// window is matched by app, not by process. With no other copy they are dropped.
    public static func appQuit(_ held: inout [HeldWindow], pid: Int32, nextPid: Int32?) {
        if let nextPid {
            for i in held.indices where held[i].info.pid == pid { held[i].info.pid = nextPid }
        } else {
            held.removeAll { $0.info.pid == pid }
        }
    }

    /// The strips with the held windows put in their places, in order. For a session save.
    public static func placed<K: Hashable>(_ held: [HeldWindow], into strips: [K: Strip], key: (HeldWindow) -> K) -> [K: Strip] {
        var out = strips
        for h in held where !h.floats {
            var strip = out[key(h)] ?? Strip()
            strip.insert(h.info, width: h.width, slot: h.slot(in: strip), focus: false)
            out[key(h)] = strip
        }
        return out
    }
}

/// The saved state of all strips. Stored in `~/Library/Application Support/Striple/session.json`.
public struct Session: Codable, Equatable, Sendable {
    public var version = 1
    public var strips: [SessionStrip]
    public var floating: [WindowInfo]

    public init(strips: [SessionStrip] = [], floating: [WindowInfo] = []) {
        self.strips = strips
        self.floating = floating
    }

    /// Matches saved windows to live windows.
    ///
    /// Order of matching: same window ID and app, then same app and title, then same app
    /// in saved order. Saved windows with no match are dropped. Live windows with no
    /// match are returned in `unmatched` so the engine can insert them normally. Saved floating
    /// windows with no match are returned in `unmatchedFloating`.
    ///
    /// Tiled windows of the apps in `waitingFor` (apps that do not answer yet) are not dropped: they are returned
    /// in `held`, with the windows that come before them, so the engine can put them back when the app answers.
    public func restore(live: [WindowInfo], waitingFor: Set<String> = []) -> (strips: [SessionStrip], floating: Set<WindowID>,
                                                                             unmatched: [WindowInfo], unmatchedFloating: [WindowInfo],
                                                                             held: [HeldWindow]) {
        var pool = live
        func take(_ saved: WindowInfo) -> WindowInfo? {
            if waitingFor.contains(saved.bundleID) { return nil }
            if let i = pool.firstIndex(where: { $0.id == saved.id && $0.bundleID == saved.bundleID }) { return pool.remove(at: i) }
            if !saved.title.isEmpty, let i = pool.firstIndex(where: { $0.bundleID == saved.bundleID && $0.title == saved.title }) {
                return pool.remove(at: i)
            }
            return nil
        }
        func takeByApp(_ saved: WindowInfo) -> WindowInfo? {
            guard !waitingFor.contains(saved.bundleID), let i = pool.firstIndex(where: { $0.bundleID == saved.bundleID }) else { return nil }
            return pool.remove(at: i)
        }

        // Pass 1 resolves exact matches everywhere first, so a loose match never steals an exact one.
        var resolved: [[[WindowInfo?]]] = strips.map { $0.strip.columns.map { $0.windows.map { take($0) } } }
        var floatingIDs = Set<WindowID>()
        var floatingResolved = floating.map { take($0) }
        for s in strips.indices {
            for c in resolved[s].indices {
                for r in resolved[s][c].indices where resolved[s][c][r] == nil {
                    resolved[s][c][r] = takeByApp(strips[s].strip.columns[c].windows[r])
                }
            }
        }
        for i in floatingResolved.indices where floatingResolved[i] == nil { floatingResolved[i] = takeByApp(floating[i]) }
        for w in floatingResolved.compactMap({ $0 }) { floatingIDs.insert(w.id) }

        var held: [HeldWindow] = []
        for (s, saved) in strips.enumerated() {
            var anchors: [WindowID] = []
            for (c, column) in saved.strip.columns.enumerated() {
                if let first = resolved[s][c].compactMap({ $0 }).first { anchors.insert(first.id, at: 0) }
                for w in column.windows where waitingFor.contains(w.bundleID) {
                    held.append(HeldWindow(info: w, displayID: saved.displayID, spaceID: saved.spaceID, after: anchors, width: column.width))
                    anchors.insert(w.id, at: 0)
                }
            }
        }

        var out: [SessionStrip] = []
        for (s, saved) in strips.enumerated() {
            var strip = saved.strip
            let focusedID = saved.strip.focusedWindow?.id
            var newFocus: Int?
            var columns: [Column] = []
            for (c, column) in saved.strip.columns.enumerated() {
                var col = column
                var windows: [WindowInfo] = []
                var heights: [Double] = []
                var active = 0
                for (r, match) in resolved[s][c].enumerated() {
                    guard let match else { continue }
                    if r == column.activeIndex { active = windows.count }
                    windows.append(match)
                    heights.append(r < column.heights.count ? column.heights[r] : 1)
                }
                guard !windows.isEmpty else { continue }
                col.windows = windows
                col.heights = heights
                col.activeIndex = active
                col.normalize()
                if col.windows.count == 1 { col.isTabbed = false }
                if column.windows.contains(where: { $0.id == focusedID }) { newFocus = columns.count }
                columns.append(col)
            }
            guard !columns.isEmpty else { continue }
            strip.columns = columns
            strip.focusedColumn = min(newFocus ?? min(saved.strip.focusedColumn, columns.count - 1), columns.count - 1)
            out.append(SessionStrip(displayID: saved.displayID, spaceID: saved.spaceID, strip: strip))
        }
        // Floating windows of apps that do not answer wait too, so they come back floating.
        for w in floating where waitingFor.contains(w.bundleID) {
            held.append(HeldWindow(info: w, displayID: "", spaceID: 0, after: [], width: .proportion(0.5), floats: true))
        }
        let lostFloating = floating.indices.filter { floatingResolved[$0] == nil && !waitingFor.contains(floating[$0].bundleID) }.map { floating[$0] }
        return (out, floatingIDs, pool, lostFloating, held)
    }

    /// Splits the saved strips into the ones to restore now and the ones to keep for later.
    ///
    /// macOS lists only the windows of the Spaces on screen (`kAXWindows`). A strip of another Space has
    /// no live windows yet, so restoring it now would drop it. It is kept until its Space comes on screen.
    /// - visible: the current Space of each display.
    /// - known: every Space that exists. Empty when Striple cannot read Spaces: then all strips restore now.
    ///   A strip of a Space that no longer exists also restores now.
    public func partition(visible: Set<UInt64>, known: Set<UInt64>) -> (now: Session, later: [SessionStrip]) {
        var now: [SessionStrip] = []
        var later: [SessionStrip] = []
        for s in strips {
            if s.spaceID != 0, !visible.contains(s.spaceID), known.contains(s.spaceID) { later.append(s) } else { now.append(s) }
        }
        return (Session(strips: now, floating: floating), later)
    }

    /// Adds the strips and floating windows kept for later, so a save does not lose them.
    /// Windows that Striple manages now are left out, so no window is saved twice.
    public func merging(later: [SessionStrip], laterFloating: [WindowInfo], managed: Set<WindowID>) -> Session {
        var out = self
        for saved in later {
            var strip = saved.strip
            for w in strip.allWindows where managed.contains(w.id) { _ = strip.remove(w.id) }
            guard !strip.isEmpty else { continue }
            if let i = out.strips.firstIndex(where: { $0.displayID == saved.displayID && $0.spaceID == saved.spaceID }) {
                out.strips[i].strip.columns += strip.columns
            } else {
                out.strips.append(SessionStrip(displayID: saved.displayID, spaceID: saved.spaceID, strip: strip))
            }
        }
        out.strips.sort { ($0.displayID, $0.spaceID) < ($1.displayID, $1.spaceID) }
        let have = Set(out.floating.map(\.id))
        out.floating += laterFloating.filter { !managed.contains($0.id) && !have.contains($0.id) }
        return out
    }
}

// MARK: - Window rules

/// What the engine knows about a new window when it decides how to handle it.
public struct WindowTraits: Equatable, Sendable {
    public var bundleID: String
    public var role: String
    public var subrole: String
    public var isResizable: Bool
    /// nil when the window has no zoom button.
    public var zoomButtonEnabled: Bool?
    public var isFullscreen: Bool
    public var isMinimized: Bool
    public var isOwnApp: Bool

    public init(bundleID: String, role: String = "AXWindow", subrole: String = "AXStandardWindow", isResizable: Bool = true,
                zoomButtonEnabled: Bool? = true, isFullscreen: Bool = false, isMinimized: Bool = false, isOwnApp: Bool = false) {
        self.bundleID = bundleID
        self.role = role
        self.subrole = subrole
        self.isResizable = isResizable
        self.zoomButtonEnabled = zoomButtonEnabled
        self.isFullscreen = isFullscreen
        self.isMinimized = isMinimized
        self.isOwnApp = isOwnApp
    }
}

public enum WindowDecision: Equatable, Sendable {
    /// Put on the strip. `slot` is a 1-based fixed place from a rule.
    case tile(slot: Int?)
    case float
    /// Not managed at all (fullscreen, minimized, not a window).
    case ignore
}

public enum WindowRules {
    public static func decide(_ t: WindowTraits, config: Config) -> WindowDecision {
        if t.role != "AXWindow" || t.isFullscreen || t.isMinimized { return .ignore }
        if t.isOwnApp { return .float }
        if let rule = config.rule(for: t.bundleID) {
            switch rule.action {
            case .float: return .float
            case .slot(let n): return .tile(slot: max(n, 1))
            case .tile: return t.subrole == "AXStandardWindow" ? .tile(slot: nil) : .float
            }
        }
        if t.subrole != "AXStandardWindow" { return .float }
        if !t.isResizable || t.zoomButtonEnabled == false { return .float }
        return .tile(slot: nil)
    }
}

// MARK: - Minimap

/// What the minimap draws. All rects are in 0...1 of the minimap size.
public struct MinimapModel: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public var rect: CGRect
        public var focused: Bool
        public init(rect: CGRect, focused: Bool) { self.rect = rect; self.focused = focused }
    }

    public var items: [Item]
    public var viewport: CGRect

    public init(items: [Item], viewport: CGRect) { self.items = items; self.viewport = viewport }

    public static func make(strip: Strip, display: DisplayGeometry, settings: LayoutSettings, scroll: Double? = nil) -> MinimapModel {
        let metrics = display.metrics(settings)
        let layout = Layout.compute(strip, display: display, settings: settings, scroll: 0)
        let area = display.workArea(settings)
        let scroll = scroll ?? strip.scroll
        let total = strip.columnPositions(metrics: metrics).total
        let minX = min(0, scroll)
        let maxX = max(total, scroll + metrics.usableWidth)
        let width = max(maxX - minX, 1)
        let height = Double(area.height)
        let focused = strip.focusedWindow?.id
        var items: [Item] = []
        for column in strip.columns {
            for window in column.windows {
                guard let f = layout.frames[window.id] else { continue }
                if column.isTabbed && window.id != column.activeWindow.id { continue }
                let x = Double(f.minX - area.minX) - minX
                let y = Double(f.minY - area.minY)
                items.append(Item(rect: CGRect(x: x / width, y: y / height, width: Double(f.width) / width, height: Double(f.height) / height),
                                  focused: window.id == focused))
            }
        }
        let viewport = CGRect(x: (scroll - minX) / width, y: 0, width: metrics.usableWidth / width, height: 1)
        return MinimapModel(items: items, viewport: viewport)
    }
}

// MARK: - Mac Setup

/// macOS settings that Mac Setup reads. nil means the key is not set, so the macOS default applies.
public struct MacSetupInputs: Equatable, Sendable {
    public var accessibilityTrusted: Bool
    public var swipeFingers: SwipeFingers
    public var osMajorVersion: Int
    /// `com.apple.AppleMultitouchTrackpad TrackpadFourFingerHorizSwipeGesture`: 0 off, 2 switch apps/desktops.
    public var fourFingerHorizSwipe: Int?
    /// `TrackpadThreeFingerHorizSwipeGesture`: 0 off, 1 swipe between pages, 2 switch apps/desktops.
    public var threeFingerHorizSwipe: Int?
    public var threeFingerDrag: Bool?
    /// `com.apple.dock mru-spaces`
    public var mruSpaces: Bool?
    /// `com.apple.spaces spans-displays`: true means displays do NOT have separate Spaces.
    public var spansDisplays: Bool?
    /// `com.apple.WindowManager GloballyEnabled`
    public var stageManager: Bool?
    public var tilingByEdgeDrag: Bool?
    public var tilingByTopEdgeDrag: Bool?
    public var tilingOptionAccelerator: Bool?
    /// Names of other window managers that are running.
    public var conflictingApps: [String]

    public init(accessibilityTrusted: Bool, swipeFingers: SwipeFingers, osMajorVersion: Int, fourFingerHorizSwipe: Int? = nil,
                threeFingerHorizSwipe: Int? = nil, threeFingerDrag: Bool? = nil, mruSpaces: Bool? = nil, spansDisplays: Bool? = nil,
                stageManager: Bool? = nil, tilingByEdgeDrag: Bool? = nil, tilingByTopEdgeDrag: Bool? = nil,
                tilingOptionAccelerator: Bool? = nil, conflictingApps: [String] = []) {
        self.accessibilityTrusted = accessibilityTrusted
        self.swipeFingers = swipeFingers
        self.osMajorVersion = osMajorVersion
        self.fourFingerHorizSwipe = fourFingerHorizSwipe
        self.threeFingerHorizSwipe = threeFingerHorizSwipe
        self.threeFingerDrag = threeFingerDrag
        self.mruSpaces = mruSpaces
        self.spansDisplays = spansDisplays
        self.stageManager = stageManager
        self.tilingByEdgeDrag = tilingByEdgeDrag
        self.tilingByTopEdgeDrag = tilingByTopEdgeDrag
        self.tilingOptionAccelerator = tilingOptionAccelerator
        self.conflictingApps = conflictingApps
    }
}

public struct MacSetupCheck: Equatable, Identifiable, Sendable {
    public enum Status: String, Equatable, Sendable { case ok, warning, problem }
    public enum Pane: String, Equatable, Sendable { case accessibility, trackpad, pointerControl, desktopDock, none }

    public var id: String
    public var title: String
    public var status: Status
    /// What is wrong and how to fix it. Empty when the status is ok.
    public var fix: String
    public var pane: Pane
}

/// Bundle IDs and process names of other window managers and snapping apps.
public enum KnownWindowManagers {
    public static let bundleIDs: [String: String] = [
        "com.knollsoft.Rectangle": "Rectangle",
        "com.knollsoft.Hookshot": "Rectangle Pro",
        "com.crowdcafe.windowmagnet": "Magnet",
        "com.hegenberg.BetterSnapTool": "BetterSnapTool",
        "com.MrKai77.Loop": "Loop",
        "com.amethyst.Amethyst": "Amethyst",
        "bobko.aerospace": "AeroSpace",
        "com.omninull.omniwm": "OmniWM",
        "com.glzr.glazewm": "GlazeWM",
        "com.manytricks.Moom": "Moom",
        "com.sergey-gorbunov.Spectacle": "Spectacle",
        "com.divvyapp.Divvy": "Divvy",
        "com.lwouis.alt-tab-macos.window-manager": "AltTab window manager",
    ]
    public static let processNames: [String: String] = [
        "yabai": "yabai", "komorebi": "komorebi", "OneMenu": "OneMenu", "ChainYourMac": "ChainYourMac",
    ]
}

public enum MacSetup {
    public static func evaluate(_ i: MacSetupInputs) -> [MacSetupCheck] {
        var out: [MacSetupCheck] = []
        out.append(MacSetupCheck(
            id: "accessibility", title: "Accessibility permission",
            status: i.accessibilityTrusted ? .ok : .problem,
            fix: i.accessibilityTrusted ? "" : "Turn on Striple in System Settings › Privacy & Security › Accessibility.",
            pane: .accessibility))

        let four = i.fourFingerHorizSwipe ?? 2
        let three = i.threeFingerHorizSwipe ?? 0
        let drag = i.threeFingerDrag ?? false
        switch i.swipeFingers {
        case .off:
            out.append(MacSetupCheck(id: "swipe", title: "Swipe to scroll the strip", status: .warning,
                                     fix: "The swipe is off. Pick 3 or 4 fingers in Striple › Configuration to scroll the strip with the trackpad.",
                                     pane: .none))
        case .four:
            out.append(MacSetupCheck(
                id: "swipe", title: "4-finger swipe is free for the strip",
                status: four == 0 ? .ok : .problem,
                fix: four == 0 ? "" : "Set Trackpad › More Gestures › Swipe between full-screen applications to Off (or to three fingers). Log out and in if desktops still switch.",
                pane: .trackpad))
        case .three:
            let free = three == 0
            out.append(MacSetupCheck(
                id: "swipe", title: "3-finger swipe is free for the strip",
                status: free ? .ok : .problem,
                fix: free ? "" : (three == 1
                    ? "Set Trackpad › More Gestures › Swipe between pages to Scroll left or right with two fingers."
                    : "Set Trackpad › More Gestures › Swipe between full-screen applications to four fingers."),
                pane: .trackpad))
            out.append(MacSetupCheck(
                id: "three-finger-drag", title: "Three-finger drag is off",
                status: drag ? .problem : .ok,
                fix: drag ? "Three-finger drag uses the same fingers. Turn it off in Accessibility › Pointer Control › Trackpad Options, or swipe the strip with 4 fingers." : "",
                pane: .pointerControl))
        }
        if i.swipeFingers == .four, three == 1 {
            out.append(MacSetupCheck(id: "pages", title: "Swipe between pages uses two fingers", status: .warning,
                                     fix: "A 3-finger swipe goes back a page in Safari. Set Swipe between pages to two fingers if that bothers you.",
                                     pane: .trackpad))
        }
        let mru = i.mruSpaces ?? true
        out.append(MacSetupCheck(
            id: "mru-spaces", title: "Spaces keep a fixed order",
            status: mru ? .warning : .ok,
            fix: mru ? "Turn off Desktop & Dock › Mission Control › Automatically rearrange Spaces based on most recent use." : "",
            pane: .desktopDock))
        let spans = i.spansDisplays ?? false
        out.append(MacSetupCheck(
            id: "separate-spaces", title: "Displays have separate Spaces",
            status: spans ? .warning : .ok,
            fix: spans ? "Turn on Desktop & Dock › Mission Control › Displays have separate Spaces, then log out and in." : "",
            pane: .desktopDock))
        let stage = i.stageManager ?? false
        out.append(MacSetupCheck(
            id: "stage-manager", title: "Stage Manager is off",
            status: stage ? .problem : .ok,
            fix: stage ? "Stage Manager moves windows too. Turn it off in Desktop & Dock › Desktop & Stage Manager." : "",
            pane: .desktopDock))
        if i.osMajorVersion >= 15 {
            let on = [(i.tilingByEdgeDrag ?? true, "Drag windows to screen edges to tile"),
                      (i.tilingByTopEdgeDrag ?? true, "Drag windows to menu bar to fill screen"),
                      (i.tilingOptionAccelerator ?? true, "Hold ⌥ key while dragging windows to tile")].filter(\.0).map(\.1)
            out.append(MacSetupCheck(
                id: "macos-tiling", title: "macOS window tiling is off",
                status: on.isEmpty ? .ok : .warning,
                fix: on.isEmpty ? "" : "In Desktop & Dock › Windows, turn off: " + on.joined(separator: ", ") + ".",
                pane: .desktopDock))
        }
        out.append(MacSetupCheck(
            id: "other-wm", title: "No other window manager is running",
            status: i.conflictingApps.isEmpty ? .ok : .problem,
            fix: i.conflictingApps.isEmpty ? "" : "Quit " + i.conflictingApps.sorted().joined(separator: ", ") + ". It moves windows too.",
            pane: .none))
        return out
    }
}
