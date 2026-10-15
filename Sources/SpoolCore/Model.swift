import CoreGraphics
import Foundation

/// The window server ID of a window (`CGWindowID`).
public typealias WindowID = UInt32

/// What Spool knows about a managed window apart from its position.
public struct WindowInfo: Codable, Equatable, Hashable, Sendable {
    public var id: WindowID
    public var pid: Int32
    public var bundleID: String
    public var title: String

    public init(id: WindowID, pid: Int32 = 0, bundleID: String = "", title: String = "") {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.title = title
    }
}

/// The width of a column.
public enum ColumnWidth: Codable, Equatable, Hashable, Sendable {
    /// A part of the usable width. 1.0 is the full width, 0.5 makes two columns fit side by side.
    case proportion(Double)
    /// A fixed width in points.
    case fixed(Double)

    /// Resolves the width in points. Proportions include the gaps, so that
    /// `n` columns of `1/n` fit the usable width exactly.
    public func points(usableWidth: Double, gap: Double) -> Double {
        switch self {
        case .proportion(let p): return max(1, p * (usableWidth + gap) - gap)
        case .fixed(let w): return max(1, min(w, usableWidth))
        }
    }

    /// The width as a proportion of the usable width.
    public func proportion(usableWidth: Double, gap: Double) -> Double {
        switch self {
        case .proportion(let p): return p
        case .fixed(let w): return (w + gap) / max(1, usableWidth + gap)
        }
    }
}

/// One column of the strip. A column holds one window, or several windows in a stack.
public struct Column: Codable, Equatable, Sendable {
    public var windows: [WindowInfo]
    public var width: ColumnWidth
    /// Width to go back to when full width is switched off.
    public var widthBeforeFull: ColumnWidth?
    /// Height of each window as a part of the column height. Same count as `windows`, sum is 1.
    public var heights: [Double]
    public var isTabbed: Bool
    /// The window in the column that has (or last had) focus.
    public var activeIndex: Int

    public init(window: WindowInfo, width: ColumnWidth) {
        self.windows = [window]
        self.width = width
        self.widthBeforeFull = nil
        self.heights = [1]
        self.isTabbed = false
        self.activeIndex = 0
    }

    public var activeWindow: WindowInfo { windows[min(max(activeIndex, 0), windows.count - 1)] }

    public func contains(_ id: WindowID) -> Bool { windows.contains { $0.id == id } }

    public mutating func equalizeHeights() {
        heights = Array(repeating: 1.0 / Double(max(windows.count, 1)), count: windows.count)
    }

    /// Makes sure that `heights` matches `windows` and sums to 1.
    public mutating func normalize() {
        if heights.count != windows.count { equalizeHeights() }
        let sum = heights.reduce(0, +)
        if sum <= 0 { equalizeHeights() } else { heights = heights.map { $0 / sum } }
        activeIndex = min(max(activeIndex, 0), max(windows.count - 1, 0))
    }
}

/// The strip of one display on one Space.
public struct Strip: Codable, Equatable, Sendable {
    public var columns: [Column]
    public var focusedColumn: Int
    /// Strip x coordinate shown at the left edge of the usable area.
    public var scroll: Double

    public init(columns: [Column] = [], focusedColumn: Int = 0, scroll: Double = 0) {
        self.columns = columns
        self.focusedColumn = focusedColumn
        self.scroll = scroll
    }

    public var isEmpty: Bool { columns.isEmpty }

    public var focusedWindow: WindowInfo? {
        guard columns.indices.contains(focusedColumn) else { return nil }
        return columns[focusedColumn].activeWindow
    }

    public var allWindows: [WindowInfo] { columns.flatMap(\.windows) }

    /// Column index and index in the column of a window.
    public func locate(_ id: WindowID) -> (column: Int, row: Int)? {
        for (c, column) in columns.enumerated() {
            if let r = column.windows.firstIndex(where: { $0.id == id }) { return (c, r) }
        }
        return nil
    }

    public func contains(_ id: WindowID) -> Bool { locate(id) != nil }
}
