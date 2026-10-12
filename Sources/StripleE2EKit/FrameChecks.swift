import CoreGraphics
import Foundation

/// Where Striple must put tiled windows on one display. All rects in global top-left coordinates.
public struct StripGeometry: Equatable, Sendable {
    /// The full display.
    public var display: CGRect
    /// The visible frame (no menu bar, no Dock) minus the outer gaps.
    public var work: CGRect
    public var gap: Double
    /// Points of a parked window that stay on the display (config `layout.parkedSliver`).
    public var sliver: Double
    /// Another display touches this side. Striple then moves a column that hangs over that edge onto the
    /// display, or parks it; with no display there, the column stays where the strip puts it.
    public var neighborLeft: Bool
    public var neighborRight: Bool
    /// Another display touches the bottom edge. Striple then parks a column at its side and keeps its y.
    public var neighborBelow: Bool

    public init(display: CGRect, visible: CGRect, innerGap: Double,
                outerTop: Double, outerBottom: Double, outerLeft: Double, outerRight: Double, sliver: Double,
                neighborLeft: Bool = false, neighborRight: Bool = false, neighborBelow: Bool = false) {
        self.neighborLeft = neighborLeft
        self.neighborRight = neighborRight
        self.neighborBelow = neighborBelow
        self.display = display
        self.work = CGRect(x: Double(visible.minX) + outerLeft, y: Double(visible.minY) + outerTop,
                           width: max(Double(visible.width) - outerLeft - outerRight, 1),
                           height: max(Double(visible.height) - outerTop - outerBottom, 1))
        self.gap = innerGap
        self.sliver = sliver
    }

    /// The width of a column with a proportion of the usable width. Proportions include the gaps:
    /// `n` columns of `1/n` fill the work area exactly (docs/SPEC.md).
    public func columnWidth(_ proportion: Double) -> Double {
        max(1, proportion * (Double(work.width) + gap) - gap)
    }

    /// The width of all columns side by side, with the gaps between them.
    public func totalWidth(_ proportions: [Double]) -> Double {
        proportions.map(columnWidth).reduce(0, +) + gap * Double(max(proportions.count - 1, 0))
    }

    /// True when all columns fit the work area: Striple then shows them all, from the left edge.
    public func fits(_ proportions: [Double]) -> Bool { totalWidth(proportions) <= Double(work.width) + 0.5 }

    /// The left edge of each column from the start of the strip, with the inner gaps.
    public func positions(_ proportions: [Double]) -> [Double] {
        var x = 0.0
        return proportions.map { p in
            defer { x += columnWidth(p) + gap }
            return x
        }
    }

    /// The scroll of the default center mode `onOverflow` (docs/SPEC.md F7): 0 when all columns fit, else the
    /// focused column centred, but never past the ends of the strip. The same rule as `Strip.ensureFocusVisible`,
    /// written again here so the E2E check does not trust the code it checks.
    public func expectedScroll(_ proportions: [Double], focused: Int) -> Double {
        guard proportions.indices.contains(focused) else { return 0 }
        let view = Double(work.width), total = totalWidth(proportions)
        guard total > view + 0.5 else { return 0 }
        let centred = positions(proportions)[focused] - (view - columnWidth(proportions[focused])) / 2
        return min(max(centred, 0), total - view)
    }

    /// Where a column with left edge `x` and width `w` (from the strip and the scroll) shows on the display:
    /// its x, or nil when Striple parks it. The rule of docs/SPEC.md: a column fully past an edge with no
    /// display there keeps only a sliver (it is parked); one that hangs over such an edge stays where it is.
    /// Toward a neighbour display, a column is parked when its middle is past the edge, else moved to the edge.
    /// Like the engine (`Layout.pixelAligned`), it rounds x and the width to whole points first.
    public func shownX(_ x: Double, width: Double) -> Double? {
        let x = x.rounded(), w = width.rounded()
        let d0 = Double(display.minX), d1 = Double(display.maxX)
        if x + w > d1 {
            if neighborRight { return x + w / 2 > d1 ? nil : d1 - w }
            return x > d1 - sliver ? nil : x
        }
        if x < d0 {
            if neighborLeft { return x + w / 2 < d0 ? nil : d0 }
            return x + w < d0 + sliver ? nil : x
        }
        return x
    }

    /// Which sides of `frame` touch another display, with the 2 pt tolerance of the engine (Displays.make).
    public static func neighbors(of frame: CGRect, among displays: [CGRect]) -> (left: Bool, right: Bool, below: Bool) {
        let others = displays.filter { $0 != frame }
        func overlapsVertically(_ o: CGRect) -> Bool { o.minY < frame.maxY - 2 && o.maxY > frame.minY + 2 }
        func overlapsHorizontally(_ o: CGRect) -> Bool { o.minX < frame.maxX - 2 && o.maxX > frame.minX + 2 }
        return (others.contains { abs($0.maxX - frame.minX) <= 2 && overlapsVertically($0) },
                others.contains { abs($0.minX - frame.maxX) <= 2 && overlapsVertically($0) },
                others.contains { abs($0.minY - frame.maxY) <= 2 && overlapsHorizontally($0) })
    }

    /// True when Striple parks hidden columns at the bottom edge (Layout.park): no display below, or displays
    /// on both sides. Else it parks them at a side and keeps their y.
    public var parksAtTheBottom: Bool { !neighborBelow || (neighborLeft && neighborRight) }
}

/// Pure checks on reported window frames. Each returns a list of failures; empty means the check passed.
public enum FrameChecks {
    /// Rounding: AX and AppKit round frames to whole points, and Striple rounds origin and size apart.
    public static let tolerance = 2.0

    public static func near(_ a: Double, _ b: Double, _ tol: Double = tolerance) -> Bool { abs(a - b) <= tol }

    static func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
    public static func describe(_ r: CGRect) -> String { fmt(r) }

    static func fmt(_ r: CGRect) -> String {
        "(\(fmt(Double(r.minX))), \(fmt(Double(r.minY))), \(fmt(Double(r.width)))x\(fmt(Double(r.height))))"
    }

    public enum Place: Int, Comparable, Sendable {
        case parkedLeft = -1, visible = 0, parkedRight = 1
        public static func < (a: Place, b: Place) -> Bool { a.rawValue < b.rawValue }
    }

    /// Where a window is: parked, or visible. It follows Layout.park:
    /// - Striple parks at the bottom (`parksAtTheBottom`): it moves the window down, and with a free side also
    ///   to a sliver at that side. macOS can stop the window lower than the engine asked (the title bar stays
    ///   on screen; 28 pt on a 2056x1329 display), so the y says only "moved down from the work-area top".
    ///   A column at the work-area top with 1 to 3 pt on the display is visible: Layout.physical leaves it there.
    /// - Else (a display below only) Striple parks at the side and keeps the y, so the x says it.
    /// A window with nothing on the display counts as parked (and then fails the sliver check).
    public static func place(_ f: CGRect, geometry g: StripGeometry) -> Place {
        let d = g.display
        let limit = g.sliver + tolerance
        let overlapX = Double(min(f.maxX, d.maxX) - max(f.minX, d.minX))
        let overlapY = Double(min(f.maxY, d.maxY) - max(f.minY, d.minY))
        let parked: Bool
        if overlapX <= 0 || overlapY <= 0 {
            parked = true
        } else if g.parksAtTheBottom {
            let movedDown = Double(f.minY) > Double(g.work.minY) + tolerance
            parked = movedDown && ((g.neighborLeft && g.neighborRight) || overlapX <= limit)
        } else {
            parked = overlapX <= limit
        }
        guard parked else { return .visible }
        return f.midX < d.midX ? .parkedLeft : .parkedRight
    }

    /// One column of the strip as the runner expects it.
    public struct Column: Equatable, Sendable {
        public var title: String
        public var frame: CGRect
        public var proportion: Double
        public init(title: String, frame: CGRect, proportion: Double) {
            self.title = title
            self.frame = frame
            self.proportion = proportion
        }
    }

    /// Checks a strip of single-window columns, given in strip order (left to right):
    /// - a visible column has the top and the height of the work area, and the width of its proportion;
    /// - parked columns on the left come first, then the visible ones, then parked columns on the right (not
    ///   checked with a display on one side only: Striple then parks all on the free side);
    /// - visible columns go left to right with exactly the inner gap between them, also when a column hangs over
    ///   an edge with no display there (Striple leaves it in place); a column at the edge toward a neighbour
    ///   display is not gap-checked, because Striple moves it there;
    /// - when all columns fit the work area, all are visible and the first starts at the left edge (no hole);
    /// - at least one column is visible, and a parked column keeps a sliver on the display (else macOS can move
    ///   it to another display or forget which display it is on);
    /// - with a `scroll`: each column is where the strip and the scroll put it (x = work area left + its
    ///   position in the strip - scroll), moved or parked at an edge as `StripGeometry.shownX` says.
    public static func checkStrip(_ columns: [Column], geometry g: StripGeometry, scroll: Double? = nil) -> [String] {
        var failures: [String] = []
        let places = columns.map { place($0.frame, geometry: g) }
        if let scroll {
            for (i, x0) in g.positions(columns.map(\.proportion)).enumerated() {
                let c = columns[i], f = c.frame
                let at = Double(g.work.minX) + x0 - scroll
                let why = "(strip x \(fmt(at)), scroll \(fmt(scroll)))"
                switch (g.shownX(at, width: g.columnWidth(c.proportion)), places[i]) {
                case (nil, .visible):
                    failures.append("\(c.title) is visible at x \(fmt(Double(f.minX))), want it parked \(why)")
                case (let want?, let p) where p != .visible:
                    failures.append("\(c.title) is parked \(fmt(f)), want it on the display at x \(fmt(want)) \(why)")
                case (let want?, _) where !near(Double(f.minX), want):
                    failures.append("\(c.title): x \(fmt(Double(f.minX))), want \(fmt(want)) \(why)")
                default:
                    break
                }
            }
        }
        if !columns.isEmpty, !places.contains(.visible) {
            failures.append("no column is visible: all \(columns.count) are parked")
        }
        for (c, p) in zip(columns, places) where p != .visible {
            let d = g.display, f = c.frame
            if min(f.maxX, d.maxX) - max(f.minX, d.minX) <= 0 || min(f.maxY, d.maxY) - max(f.minY, d.minY) <= 0 {
                failures.append("\(c.title) is parked off the display \(fmt(f)): no sliver stays on it")
            }
        }
        for (c, p) in zip(columns, places) where p == .visible {
            let f = c.frame
            if !near(Double(f.minY), Double(g.work.minY)) || !near(Double(f.height), Double(g.work.height)) {
                failures.append("\(c.title): top/height \(fmt(Double(f.minY)))/\(fmt(Double(f.height))), want \(fmt(Double(g.work.minY)))/\(fmt(Double(g.work.height)))")
            }
            let want = g.columnWidth(c.proportion)
            if !near(Double(f.width), want) {
                failures.append("\(c.title): width \(fmt(Double(f.width))), want \(fmt(want)) (proportion \(String(format: "%.3f", c.proportion)))")
            }
        }
        // With a display on one side only, Striple parks every hidden column on the free side (Layout.park):
        // then the side of a parked column says nothing about its place in the strip.
        for i in places.indices.dropFirst() where places[i] < places[i - 1] && g.neighborLeft == g.neighborRight {
            failures.append("order: \(columns[i].title) is \(places[i]) but comes after \(columns[i - 1].title) (\(places[i - 1]))")
        }
        let visible = columns.indices.filter { places[$0] == .visible }
        for (a, b) in zip(visible, visible.dropFirst()) {
            let fa = columns[a].frame, fb = columns[b].frame
            guard fb.minX > fa.minX else {
                failures.append("order: \(columns[b].title) at x \(fmt(Double(fb.minX))) is not right of \(columns[a].title) at x \(fmt(Double(fa.minX)))")
                continue
            }
            // Striple moves a column that hangs toward a neighbour display to that edge, so it can overlap the
            // column next to it: no gap to check for a column at such an edge. With no display on a side, a
            // column that hangs over it stays in the strip and the gap must hold.
            let atNeighbourEdge = { (f: CGRect) in (g.neighborLeft && Double(f.minX) <= Double(g.display.minX) + tolerance)
                || (g.neighborRight && Double(f.maxX) >= Double(g.display.maxX) - tolerance) }
            guard !atNeighbourEdge(fa), !atNeighbourEdge(fb) else { continue }
            let gap = Double(fb.minX - fa.maxX)
            if !near(gap, g.gap) {
                failures.append("gap \(columns[a].title) -> \(columns[b].title): \(fmt(gap)), want \(fmt(g.gap))")
            }
        }
        if g.fits(columns.map(\.proportion)) {
            if let hidden = columns.indices.first(where: { places[$0] != .visible }) {
                failures.append("\(columns[hidden].title) is parked \(fmt(columns[hidden].frame)) but all columns fit")
            } else if let first = columns.first, !near(Double(first.frame.minX), Double(g.work.minX)) {
                failures.append("hole: first column \(first.title) starts at x \(fmt(Double(first.frame.minX))), want \(fmt(Double(g.work.minX)))")
            }
        }
        return failures
    }

    /// The focused column must be fully in view: inside the work area, left to right.
    public static func checkInView(_ title: String, _ f: CGRect, geometry g: StripGeometry) -> [String] {
        let w = g.work
        guard f.minX >= w.minX - tolerance, f.maxX <= w.maxX + tolerance else {
            return ["\(title) \(fmt(f)) is not fully in view (work area x \(fmt(Double(w.minX)))...\(fmt(Double(w.maxX))))"]
        }
        return []
    }

    /// True when `f` is fully inside one of the display frames.
    public static func isFullyOnScreen(_ f: CGRect, displays: [CGRect]) -> Bool {
        displays.contains { d in
            f.minX >= d.minX - tolerance && f.minY >= d.minY - tolerance && f.maxX <= d.maxX + tolerance && f.maxY <= d.maxY + tolerance
        }
    }
}
