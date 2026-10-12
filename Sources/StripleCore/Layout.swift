import CoreGraphics
import Foundation

/// The geometry of one display, in Accessibility coordinates (origin top-left of the main display, y down).
public struct DisplayGeometry: Equatable, Sendable {
    /// The full display.
    public var frame: CGRect
    /// The display without the menu bar and the Dock.
    public var usable: CGRect
    /// Other displays that touch this one on that side.
    public var neighborLeft: Bool
    public var neighborRight: Bool
    public var neighborBelow: Bool

    public init(frame: CGRect, usable: CGRect, neighborLeft: Bool = false, neighborRight: Bool = false, neighborBelow: Bool = false) {
        self.frame = frame
        self.usable = usable
        self.neighborLeft = neighborLeft
        self.neighborRight = neighborRight
        self.neighborBelow = neighborBelow
    }

    /// The area windows are laid out in: the usable area minus the outer gaps.
    public func workArea(_ settings: LayoutSettings) -> CGRect {
        let g = settings.outerGaps
        return CGRect(x: usable.minX + g.left, y: usable.minY + g.top,
                      width: max(usable.width - g.left - g.right, 1), height: max(usable.height - g.top - g.bottom, 1))
    }

    public func metrics(_ settings: LayoutSettings) -> StripMetrics {
        let w = workArea(settings)
        return StripMetrics(usableWidth: Double(w.width), usableHeight: Double(w.height), gap: settings.innerGap)
    }
}

/// Where the layout wants every window, before clamping to the display.
public struct LayoutResult: Equatable, Sendable {
    /// Frames on the endless strip. They can be far outside the display.
    public var frames: [WindowID: CGRect]
    /// Window order: the focused window last, so the applier raises it last.
    public var order: [WindowID]
    /// Tab bar of each tabbed column: frame, titles, active index.
    public var tabBars: [TabBar]

    public struct TabBar: Equatable, Sendable {
        public var frame: CGRect
        public var windows: [WindowInfo]
        public var activeIndex: Int
    }
}

public enum Layout {
    /// Computes the frame of every window on the strip for a given scroll position.
    public static func compute(_ strip: Strip, display: DisplayGeometry, settings: LayoutSettings, scroll: Double? = nil) -> LayoutResult {
        let area = display.workArea(settings)
        let metrics = display.metrics(settings)
        let gap = settings.innerGap
        let scroll = scroll ?? strip.scroll
        var frames: [WindowID: CGRect] = [:]
        frames.reserveCapacity(strip.columns.count)
        var tabBars: [LayoutResult.TabBar] = []
        var x = Double(area.minX) - scroll
        for column in strip.columns {
            let w = column.width.points(usableWidth: metrics.usableWidth, gap: gap)
            if column.isTabbed && column.windows.count > 1 {
                let bar = settings.tabBarHeight
                let frame = CGRect(x: x, y: Double(area.minY) + bar, width: w, height: max(Double(area.height) - bar, 1))
                for window in column.windows { frames[window.id] = frame }
                tabBars.append(.init(frame: CGRect(x: x, y: Double(area.minY), width: w, height: bar),
                                     windows: column.windows, activeIndex: column.activeIndex))
            } else {
                let n = column.windows.count
                let available = max(Double(area.height) - gap * Double(n - 1), Double(n))
                var y = Double(area.minY)
                let heights = column.heights.count == n ? column.heights : Array(repeating: 1.0 / Double(n), count: n)
                for (i, window) in column.windows.enumerated() {
                    let h = i == n - 1 ? Double(area.maxY) - y : (available * heights[i]).rounded()
                    frames[window.id] = CGRect(x: x, y: y, width: w, height: max(h, 1))
                    y += h + gap
                }
            }
            x += w + gap
        }
        var order: [WindowID] = []
        for (c, column) in strip.columns.enumerated() where c != strip.focusedColumn {
            order.append(contentsOf: column.windows.map(\.id))
        }
        if strip.columns.indices.contains(strip.focusedColumn) {
            let column = strip.columns[strip.focusedColumn]
            let active = column.activeWindow.id
            order.append(contentsOf: column.windows.map(\.id).filter { $0 != active })
            order.append(active)
        }
        return LayoutResult(frames: frames, order: order, tabBars: tabBars)
    }

    /// A frame as macOS will get it.
    public struct Placement: Equatable, Sendable {
        public var frame: CGRect
        /// The window is out of view and parked at the edge.
        public var hidden: Bool
    }

    /// Turns a frame on the strip into a frame macOS accepts.
    ///
    /// - Partly out of view on a side without another display: left as is.
    /// - Partly out of view on a side with another display: pushed flush to the edge, so it does not
    ///   show on the other display. When more than half of it is past the edge, it is parked.
    /// - Out of view: parked with a sliver at the edge, at the bottom if no display is below.
    public static func physical(_ frame: CGRect, display: DisplayGeometry, settings: LayoutSettings) -> Placement {
        let d = display.frame
        let sliver = CGFloat(settings.parkedSliver)
        var f = frame.integral
        if f.maxX > d.maxX {
            let hidden = display.neighborRight ? f.midX > d.maxX : f.minX > d.maxX - sliver
            if hidden { return park(f, toRight: true, display: display, sliver: sliver) }
            if display.neighborRight { f.origin.x = d.maxX - f.width }
        } else if f.minX < d.minX {
            let hidden = display.neighborLeft ? f.midX < d.minX : f.maxX < d.minX + sliver
            if hidden { return park(f, toRight: false, display: display, sliver: sliver) }
            if display.neighborLeft { f.origin.x = d.minX }
        }
        return Placement(frame: f, hidden: false)
    }

    private static func park(_ f: CGRect, toRight: Bool, display: DisplayGeometry, sliver: CGFloat) -> Placement {
        let d = display.frame
        var right = toRight
        if right && display.neighborRight && !display.neighborLeft { right = false }
        if !right && display.neighborLeft && !display.neighborRight { right = true }
        var p = f
        if display.neighborLeft && display.neighborRight {
            // No free side: park below, inside the display horizontally.
            p.origin.x = right ? max(d.maxX - f.width, d.minX) : d.minX
            p.origin.y = d.maxY - sliver
        } else {
            p.origin.x = right ? d.maxX - sliver : d.minX - f.width + sliver
            if !display.neighborBelow { p.origin.y = d.maxY - sliver }
        }
        return Placement(frame: p, hidden: true)
    }
}
