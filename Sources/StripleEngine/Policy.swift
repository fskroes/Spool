import AppKit
import CoreGraphics
import Foundation
import StripleCore

/// Engine decisions that need no system state. Kept pure so tests cover them without Accessibility.
enum Policy {
    // MARK: Focus stealing

    /// True when a window that just got focus took it without the user asking for it.
    ///
    /// - `windowAge`: seconds since Striple first saw the window.
    /// - `secondsSinceInput`: seconds since the last key press, click or scroll.
    /// - `appAge`: seconds since the app launched. A slow app that opens its first window after a long launch
    ///   is not stealing: the user started it.
    static func isFocusSteal(windowAge: Double, secondsSinceInput: Double, appAge: Double?) -> Bool {
        windowAge < 2 && secondsSinceInput > 1 && (appAge ?? .infinity) > 10
    }

    // MARK: Swipes

    /// Converts a horizontal finger movement (in trackpad widths) into a scroll change in points.
    /// With natural scrolling the windows follow the fingers: fingers to the left show the columns on the right.
    static func scrollDelta(dx: Double, viewWidth: Double, settings: GestureSettings) -> Double {
        let points = dx * viewWidth * max(settings.sensitivity, 0.05)
        return settings.natural ? -points : points
    }

    /// The scroll range a swipe can settle in: the first and the last column at their snap positions.
    static func scrollBounds(_ strip: Strip, settings: LayoutSettings, metrics: StripMetrics) -> (lower: Double, upper: Double) {
        guard !strip.columns.isEmpty else { return (0, 0) }
        let p = strip.columnPositions(metrics: metrics)
        let view = metrics.usableWidth
        switch settings.centerMode {
        case .always:
            let n = p.x.count - 1
            return (p.x[0] - (view - p.width[0]) / 2, p.x[n] - (view - p.width[n]) / 2)
        case .onOverflow, .never:
            return (0, max(p.total - view, 0))
        }
    }

    /// Rubber band past the ends, like a scroll view: the further past the end, the less the strip moves.
    /// It never goes more than `dimension` past an end.
    static func rubberBand(_ raw: Double, lower: Double, upper: Double, dimension: Double) -> Double {
        func band(_ over: Double) -> Double { (1 - 1 / (over * 0.55 / max(dimension, 1) + 1)) * dimension }
        if raw > upper { return upper + band(raw - upper) }
        if raw < lower { return lower - band(lower - raw) }
        return raw
    }

    // MARK: Geometry

    /// True when two frames are the same within `tolerance` points. Used to tell Striple's own writes from user moves.
    /// Apps whose windows Striple manages: regular apps that still run, never Striple itself.
    /// This leaves out loginwindow (the lock screen), agents and menu bar apps.
    static func isManageableApp(policy: NSApplication.ActivationPolicy, pid: pid_t, ownPID: pid_t, terminated: Bool) -> Bool {
        policy == .regular && pid != ownPID && !terminated
    }

    static func same(_ a: CGRect, _ b: CGRect?, tolerance: CGFloat = 2) -> Bool {
        guard let b else { return false }
        return abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// The display that contains `point`, else the one nearest to it. Frames are in AX coordinates.
    static func displayIndex(for point: CGPoint, frames: [CGRect]) -> Int? {
        if let i = frames.firstIndex(where: { $0.contains(point) }) { return i }
        func distance(_ r: CGRect) -> CGFloat {
            let dx = max(r.minX - point.x, 0, point.x - r.maxX)
            let dy = max(r.minY - point.y, 0, point.y - r.maxY)
            return dx * dx + dy * dy
        }
        return frames.indices.min { distance(frames[$0]) < distance(frames[$1]) }
    }

    /// The display after `current` from left to right (then top to bottom), wrapping around.
    static func nextDisplay(after current: Int, frames: [CGRect]) -> Int? {
        guard frames.count > 1, frames.indices.contains(current) else { return nil }
        let order = frames.indices.sorted { (frames[$0].minX, frames[$0].minY) < (frames[$1].minX, frames[$1].minY) }
        let i = order.firstIndex(of: current) ?? 0
        return order[(i + 1) % order.count]
    }

    /// Moves `frame` into `area` (shrinking it if it is bigger). Used to bring parked windows back when Striple
    /// stops or a window starts to float.
    static func bringIntoView(_ frame: CGRect, area: CGRect) -> CGRect {
        var r = frame
        r.size.width = min(r.width, area.width)
        r.size.height = min(r.height, area.height)
        r.origin.x = min(max(r.minX, area.minX), area.maxX - r.width)
        r.origin.y = min(max(r.minY, area.minY), area.maxY - r.height)
        return r
    }

    /// Where a window goes when Striple lets it go (stop, quit, rebuild).
    ///
    /// - target: the strip frame the animation runs toward, for a tiled window on a Space on screen. The window
    ///   goes to its final place, not to a frame from the middle of the animation.
    /// - known: otherwise the last frame Striple wrote (or the parked frame of a hidden or minimized window).
    static func releaseFrame(target: CGRect?, known: CGRect?, display: DisplayGeometry, settings: LayoutSettings) -> CGRect? {
        let area = display.usable
        if let target { return bringIntoView(Layout.physical(target, display: display, settings: settings).frame, area: area) }
        return known.map { bringIntoView($0, area: area) }
    }

    /// Whether a Space is one of a display's Spaces. True when Spaces are unknown, so nothing is hidden by mistake.
    /// `known` comes from `Spaces.all()`: "Main" holds all Spaces when displays do not have separate Spaces.
    static func spaceExists(_ space: UInt64, onDisplay display: String, known: [String: Set<UInt64>]) -> Bool {
        if space == 0 || known.isEmpty { return true }
        return (known[display] ?? known["Main"] ?? []).contains(space)
    }

    /// After an app is watched again: every managed window must be observed again, with the fresh element when
    /// AXWindows lists the window and with the old one otherwise (a window on another Space is not listed).
    static func healPlan<E>(managed: [WindowID: E], fresh: [WindowID: E]) -> (observe: [WindowID: E], renewed: Set<WindowID>) {
        var observe = managed
        var renewed = Set<WindowID>()
        for id in managed.keys {
            if let e = fresh[id] {
                observe[id] = e
                renewed.insert(id)
            }
        }
        return (observe, renewed)
    }

    /// A tiled window that moves while the button is down is dragged by the user only when the mouse moved,
    /// the window was under the mouse at mouse-down, its frame is not one Striple wrote or is writing, and no
    /// other window is dragged already.
    static func isUserDrag(window: WindowID, mouseMoved: Bool, pressedWindow: WindowID?, ownFrame: Bool,
                           currentDrag: WindowID?) -> Bool {
        guard mouseMoved, window == pressedWindow, !ownFrame else { return false }
        return currentDrag == nil || currentDrag == window
    }

    /// A move while the button is down that is not a drag and not Striple's own write (for example a resize
    /// that started outside the hit test, or an app that moved itself). It is checked again after the release:
    /// put back, so the window cannot stay over its neighbour with a size Striple does not know.
    static func correctAfterRelease(isUserDrag: Bool, ownFrame: Bool) -> Bool { !isUserDrag && !ownFrame }

    /// The window under the mouse at mouse-down: the frontmost one whose bounds, widened by `slop`, contain the
    /// point. macOS starts a resize a few points outside the window edge (on macOS 26 mostly outside the
    /// corner), so an exact hit test misses those presses. `frontToBack` is in window-server order.
    /// `parked`: windows Striple parked out of view. They stay on screen as 1 pt slivers at the display edge,
    /// so the window server still lists them, but the user cannot see or press them.
    static func pressedWindow(at p: CGPoint, frontToBack: [(id: WindowID, bounds: CGRect)], slop: CGFloat,
                              parked: Set<WindowID> = []) -> WindowID? {
        frontToBack.first { !parked.contains($0.id) && $0.bounds.insetBy(dx: -slop, dy: -slop).contains(p) }?.id
    }

    /// A saved strip that comes back from the session. Windows that are gone were dropped, so the saved scroll
    /// can point past the end: scroll again so the focused column is in view.
    static func restoredStrip(_ saved: Strip, into existing: Strip?, settings: LayoutSettings, metrics: StripMetrics?) -> Strip {
        var strip = existing ?? Strip()
        if strip.isEmpty { strip = saved } else { strip.columns += saved.columns }
        if let metrics { strip.ensureFocusVisible(settings: settings, metrics: metrics) }
        return strip
    }

    /// The Space a hidden or minimized window goes back to: the one it left, while the window is still on it.
    /// `windowSpaces` is empty when Striple cannot read Spaces. `active` is 0 when Spaces are not used.
    static func putBackSpace(old: UInt64, windowSpaces: [UInt64], active: UInt64) -> UInt64 {
        guard active != 0 else { return 0 }
        if windowSpaces.contains(old) { return old }
        if windowSpaces.contains(active) || windowSpaces.isEmpty { return active }
        return windowSpaces[0]
    }

    /// What a window drag that ends does.
    enum DropKind: Equatable {
        /// Onto another enabled display: move the window to that display's strip.
        case otherDisplay
        /// On its own display: move the window to the gap under the mouse.
        case reorder
        /// Onto a display Striple does not manage, or outside every display: back to its old place.
        case putBack
    }

    static func dropKind(dropDisplay: String?, ownDisplay: String, dropDisplayDisabled: Bool) -> DropKind {
        guard let dropDisplay else { return .putBack }
        if dropDisplay == ownDisplay { return .reorder }
        return dropDisplayDisabled ? .putBack : .otherDisplay
    }

    /// Seconds before the next try to watch an app that did not answer, or nil to give up.
    /// Fast at first (an app that is starting), then every 5 s for about two minutes (a large app that is busy).
    static func watchRetryDelay(attempt n: Int) -> Double? {
        switch n {
        case 1...6: return 0.25 * Double(n)
        case 7...30: return 5
        default: return nil
        }
    }

    /// The strips as the session saves them: hidden and minimized windows go back into the slot they left,
    /// so a restart restores them there. After the restore, the scan takes them off the strip again.
    static func stripsForSession<K: Hashable>(_ strips: [K: Strip], offStrip: [(info: WindowInfo, key: K, slot: Int?, width: ColumnWidth?)],
                                              defaultWidth: ColumnWidth) -> [K: Strip] {
        var out = strips
        let ordered = offStrip.sorted { ($0.slot ?? .max, $0.info.id) < ($1.slot ?? .max, $1.info.id) }
        for w in ordered {
            var strip = out[w.key] ?? Strip()
            strip.insert(w.info, width: w.width ?? defaultWidth, slot: w.slot ?? strip.columns.count + 1, focus: false)
            out[w.key] = strip
        }
        return out
    }

    /// Tiled windows of hidden apps, in a stable order.
    static func windowsToHide(tiled: [WindowID: pid_t], hiddenApps: Set<pid_t>) -> [WindowID] {
        tiled.filter { hiddenApps.contains($0.value) }.keys.sorted()
    }

    /// A left-button drag that moved more than `threshold` points. A click that does not move is not a drag,
    /// even when Striple's own animation moves the window under the mouse.
    static func isDrag(from down: CGPoint?, to now: CGPoint, threshold: CGFloat = 4) -> Bool {
        guard let down else { return false }
        return hypot(now.x - down.x, now.y - down.y) > threshold
    }

    /// The same place on another display: keeps the position relative to the usable area.
    static func translate(_ frame: CGRect, from a: CGRect, to b: CGRect) -> CGRect {
        let rx = a.width > frame.width ? (frame.minX - a.minX) / (a.width - frame.width) : 0
        let ry = a.height > frame.height ? (frame.minY - a.minY) / (a.height - frame.height) : 0
        let w = min(frame.width, b.width), h = min(frame.height, b.height)
        return CGRect(x: b.minX + min(max(rx, 0), 1) * (b.width - w), y: b.minY + min(max(ry, 0), 1) * (b.height - h), width: w, height: h)
    }

    /// The width a column gets when the user resized its window with the mouse.
    static func adoptedWidth(_ width: CGFloat, metrics: StripMetrics) -> ColumnWidth {
        let p = ColumnWidth.fixed(Double(width)).proportion(usableWidth: metrics.usableWidth, gap: metrics.gap)
        return .proportion(min(max(p, 0.05), 1))
    }
}
