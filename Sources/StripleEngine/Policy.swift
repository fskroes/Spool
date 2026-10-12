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
