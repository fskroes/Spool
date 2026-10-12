import Foundation

/// The result of a strip command. The engine uses it to decide what to do next.
public enum StripChange: Equatable, Sendable {
    /// Nothing changed (for example "focus left" on the first column).
    case none
    /// The layout or focus changed. `focus` is the window that must get keyboard focus.
    case changed(focus: WindowID?)
}

/// Sizes the strip operations need. Derived from the display and the settings.
public struct StripMetrics: Equatable, Sendable {
    public var usableWidth: Double
    public var usableHeight: Double
    public var gap: Double

    public init(usableWidth: Double, usableHeight: Double, gap: Double) {
        self.usableWidth = usableWidth
        self.usableHeight = usableHeight
        self.gap = gap
    }
}

extension Strip {
    // MARK: Adding and removing windows

    /// Adds a window as a new column. With `slot` (1-based) the column goes to that place,
    /// otherwise directly to the right of the focused column.
    /// - Parameter focus: When false, focus and scroll stay where they are (no focus stealing).
    public mutating func insert(_ window: WindowInfo, width: ColumnWidth, slot: Int? = nil, focus: Bool) {
        guard !contains(window.id) else { return }
        let index: Int
        if let slot { index = min(max(slot - 1, 0), columns.count) } else if columns.isEmpty { index = 0 } else {
            index = min(focusedColumn + 1, columns.count)
        }
        columns.insert(Column(window: window, width: width), at: index)
        if focus || columns.count == 1 {
            focusedColumn = index
        } else if index <= focusedColumn {
            focusedColumn += 1
        }
    }

    /// Adds a window without focus, as `insert`, and changes `scroll` so the focused column stays where it is on
    /// screen. A column put in to the left of the focused one does not push the focused window away.
    /// Except with `always`, the strip never scrolls past its ends, so a strip that fits stays left-aligned. The
    /// focused column then moves only as far as needed, and stays fully on screen.
    public mutating func insertKeepingView(_ window: WindowInfo, width: ColumnWidth, slot: Int?,
                                           settings: LayoutSettings, metrics: StripMetrics?) {
        guard let metrics, columns.indices.contains(focusedColumn), !contains(window.id) else {
            return insert(window, width: width, slot: slot, focus: false)
        }
        let before = columnPositions(metrics: metrics).x[focusedColumn]
        insert(window, width: width, slot: slot, focus: false)
        let p = columnPositions(metrics: metrics)
        scroll += p.x[focusedColumn] - before
        if settings.centerMode != .always { scroll = min(max(scroll, 0), max(p.total - metrics.usableWidth, 0)) }
    }

    /// Removes a window. Returns the window that should get focus, if the focused window was removed.
    @discardableResult
    public mutating func remove(_ id: WindowID) -> WindowID? {
        guard let (c, r) = locate(id) else { return nil }
        let wasFocused = c == focusedColumn && columns[c].activeIndex == r
        columns[c].windows.remove(at: r)
        if columns[c].windows.isEmpty {
            columns.remove(at: c)
            if c < focusedColumn || (c == focusedColumn && focusedColumn >= columns.count) {
                focusedColumn = max(focusedColumn - 1, 0)
            }
        } else {
            columns[c].heights.remove(at: r)
            if columns[c].activeIndex > r || columns[c].activeIndex >= columns[c].windows.count {
                columns[c].activeIndex = max(columns[c].activeIndex - 1, 0)
            }
            columns[c].normalize()
            if columns[c].windows.count == 1 { columns[c].isTabbed = false }
        }
        if columns.isEmpty { focusedColumn = 0; scroll = 0; return nil }
        return wasFocused ? focusedWindow?.id : nil
    }

    /// Updates title, pid or bundle ID of a window.
    public mutating func update(_ info: WindowInfo) {
        guard let (c, r) = locate(info.id) else { return }
        columns[c].windows[r] = info
    }

    /// Marks a window as focused (for example after a click). Returns false if the window is not on this strip.
    @discardableResult
    public mutating func setFocus(_ id: WindowID) -> Bool {
        guard let (c, r) = locate(id) else { return false }
        focusedColumn = c
        columns[c].activeIndex = r
        return true
    }

    // MARK: Commands

    /// Runs a command that only changes this strip. Engine-level commands return `.none`.
    public mutating func apply(_ command: Command, settings: LayoutSettings, metrics: StripMetrics) -> StripChange {
        guard !columns.isEmpty else { return .none }
        focusedColumn = min(max(focusedColumn, 0), columns.count - 1)
        let before = self
        switch command {
        case .focusLeft: focusedColumn = max(focusedColumn - 1, 0)
        case .focusRight: focusedColumn = min(focusedColumn + 1, columns.count - 1)
        case .focusUp: columns[focusedColumn].activeIndex = max(columns[focusedColumn].activeIndex - 1, 0)
        case .focusDown:
            columns[focusedColumn].activeIndex = min(columns[focusedColumn].activeIndex + 1, columns[focusedColumn].windows.count - 1)
        case .focusFirst: focusedColumn = 0
        case .focusLast: focusedColumn = columns.count - 1
        case .focusIndex(let n):
            let target = n >= 9 ? columns.count - 1 : n - 1
            guard columns.indices.contains(target) else { return .none }
            focusedColumn = target
        case .moveLeft: moveColumn(to: focusedColumn - 1)
        case .moveRight: moveColumn(to: focusedColumn + 1)
        case .moveFirst: moveColumn(to: 0)
        case .moveLast: moveColumn(to: columns.count - 1)
        case .moveToIndex(let n): moveColumn(to: n >= 9 ? columns.count - 1 : n - 1)
        case .moveUp: moveInStack(by: -1)
        case .moveDown: moveInStack(by: 1)
        case .cycleWidth: cycleWidth(settings: settings, metrics: metrics)
        case .toggleFullWidth: toggleFullWidth(settings: settings)
        case .wider: changeWidth(by: settings.widthStep, metrics: metrics)
        case .narrower: changeWidth(by: -settings.widthStep, metrics: metrics)
        case .taller: changeHeight(by: settings.heightStep)
        case .shorter: changeHeight(by: -settings.heightStep)
        case .equalizeHeights: columns[focusedColumn].equalizeHeights()
        case .stackLeft: stack(into: focusedColumn - 1)
        case .stackRight: stack(into: focusedColumn + 1)
        case .popLeft: pop(toRight: false)
        case .popRight: pop(toRight: true)
        case .toggleTabbed:
            guard columns[focusedColumn].windows.count > 1 || columns[focusedColumn].isTabbed else { return .none }
            columns[focusedColumn].isTabbed.toggle()
        case .centerColumn:
            center(on: focusedColumn, settings: settings, metrics: metrics)
        case .focusWindow(let id):
            guard setFocus(id) else { return .none }
        case .toggleFloat, .sendToNextDisplay, .start, .stop, .toggleEngine, .restart:
            return .none
        }
        if self == before { return .none }
        return .changed(focus: focusedWindow?.id)
    }

    // MARK: Drag and drop

    /// The gap (0...columns.count) that a point at `x` on the strip falls into: the number of columns whose
    /// centre is left of `x`. `x` is in strip coordinates: screen x minus the work area's left edge plus the scroll.
    public func dropGap(atStripX x: Double, metrics: StripMetrics) -> Int {
        let p = columnPositions(metrics: metrics)
        return p.x.indices.filter { p.x[$0] + p.width[$0] / 2 < x }.count
    }

    /// Moves a dragged window to `gap` (0...columns.count, "before column `gap`"). A window alone in its column
    /// takes its column along, so the width stays. A window from a stack becomes a new column with the stack's width.
    /// The moved window gets focus. Returns false when nothing changed.
    @discardableResult
    public mutating func moveWindow(_ id: WindowID, toGap rawGap: Int) -> Bool {
        guard let (c, r) = locate(id) else { return false }
        let gap = min(max(rawGap, 0), columns.count)
        if columns[c].windows.count == 1 {
            guard gap != c && gap != c + 1 else { return false }
            let column = columns.remove(at: c)
            let index = gap > c ? gap - 1 : gap
            columns.insert(column, at: index)
            focusedColumn = index
            return true
        }
        var source = columns[c]
        let window = source.windows.remove(at: r)
        source.heights.remove(at: r)
        source.activeIndex = min(source.activeIndex, source.windows.count - 1)
        source.normalize()
        if source.windows.count == 1 { source.isTabbed = false }
        columns[c] = source
        columns.insert(Column(window: window, width: source.width), at: gap)
        focusedColumn = gap
        return true
    }

    private mutating func moveColumn(to rawTarget: Int) {
        let target = min(max(rawTarget, 0), columns.count - 1)
        guard target != focusedColumn else { return }
        let column = columns.remove(at: focusedColumn)
        columns.insert(column, at: target)
        focusedColumn = target
    }

    private mutating func moveInStack(by delta: Int) {
        var column = columns[focusedColumn]
        let from = column.activeIndex
        let to = from + delta
        guard column.windows.indices.contains(to) else { return }
        column.windows.swapAt(from, to)
        column.heights.swapAt(from, to)
        column.activeIndex = to
        columns[focusedColumn] = column
    }

    private mutating func cycleWidth(settings: LayoutSettings, metrics: StripMetrics) {
        let presets = settings.presetWidths.sorted()
        guard !presets.isEmpty else { return }
        let current = columns[focusedColumn].width.proportion(usableWidth: metrics.usableWidth, gap: metrics.gap)
        let next = presets.first { $0 > current + 0.01 } ?? presets[0]
        columns[focusedColumn].width = .proportion(next)
        columns[focusedColumn].widthBeforeFull = nil
    }

    private mutating func toggleFullWidth(settings: LayoutSettings) {
        var column = columns[focusedColumn]
        if column.width == .proportion(1) {
            column.width = column.widthBeforeFull ?? .proportion(settings.defaultWidth)
            column.widthBeforeFull = nil
        } else {
            column.widthBeforeFull = column.width
            column.width = .proportion(1)
        }
        columns[focusedColumn] = column
    }

    private mutating func changeWidth(by step: Double, metrics: StripMetrics) {
        let current = columns[focusedColumn].width.proportion(usableWidth: metrics.usableWidth, gap: metrics.gap)
        let next = (min(max(current + step, 0.1), 1) * 1000).rounded() / 1000
        columns[focusedColumn].width = .proportion(next)
        columns[focusedColumn].widthBeforeFull = nil
    }

    private mutating func changeHeight(by step: Double) {
        var column = columns[focusedColumn]
        let n = column.windows.count
        guard n > 1, !column.isTabbed else { return }
        column.normalize()
        let minimum = 0.1
        let a = column.activeIndex
        let newActive = min(max(column.heights[a] + step, minimum), 1 - minimum * Double(n - 1))
        let othersBefore = 1 - column.heights[a]
        let othersAfter = 1 - newActive
        for i in 0..<n where i != a {
            column.heights[i] = othersBefore > 0 ? column.heights[i] * othersAfter / othersBefore : othersAfter / Double(n - 1)
        }
        column.heights[a] = newActive
        column.normalize()
        columns[focusedColumn] = column
    }

    /// Moves the focused window into the column at `target` (appended at the bottom).
    private mutating func stack(into target: Int) {
        guard columns.indices.contains(target) else { return }
        var source = columns[focusedColumn]
        let window = source.windows.remove(at: source.activeIndex)
        source.heights.remove(at: source.activeIndex)
        var destination = columns[target]
        destination.windows.append(window)
        destination.heights.append(1.0 / Double(destination.windows.count))
        destination.activeIndex = destination.windows.count - 1
        destination.equalizeHeights()
        columns[target] = destination
        if source.windows.isEmpty {
            columns.remove(at: focusedColumn)
            focusedColumn = target > focusedColumn ? target - 1 : target
        } else {
            source.activeIndex = min(source.activeIndex, source.windows.count - 1)
            source.normalize()
            if source.windows.count == 1 { source.isTabbed = false }
            columns[focusedColumn] = source
            focusedColumn = target
        }
    }

    /// Takes the focused window out of its stack into a new column next to it.
    private mutating func pop(toRight: Bool) {
        var source = columns[focusedColumn]
        guard source.windows.count > 1 else { return }
        let window = source.windows.remove(at: source.activeIndex)
        source.heights.remove(at: source.activeIndex)
        source.activeIndex = min(source.activeIndex, source.windows.count - 1)
        source.normalize()
        if source.windows.count == 1 { source.isTabbed = false }
        columns[focusedColumn] = source
        let index = toRight ? focusedColumn + 1 : focusedColumn
        columns.insert(Column(window: window, width: source.width), at: index)
        focusedColumn = index
    }

    // MARK: Scrolling

    /// Strip x of each column and the total strip width.
    public func columnPositions(metrics: StripMetrics) -> (x: [Double], width: [Double], total: Double) {
        var xs: [Double] = []
        var ws: [Double] = []
        var x = 0.0
        for column in columns {
            let w = column.width.points(usableWidth: metrics.usableWidth, gap: metrics.gap)
            xs.append(x)
            ws.append(w)
            x += w + metrics.gap
        }
        return (xs, ws, max(x - metrics.gap, 0))
    }

    public mutating func center(on index: Int, settings: LayoutSettings, metrics: StripMetrics) {
        guard columns.indices.contains(index) else { return }
        let p = columnPositions(metrics: metrics)
        scroll = p.x[index] - (metrics.usableWidth - p.width[index]) / 2
    }

    /// Sets `scroll` so the focused column is shown as the center mode asks.
    public mutating func ensureFocusVisible(settings: LayoutSettings, metrics: StripMetrics) {
        guard columns.indices.contains(focusedColumn) else { scroll = 0; return }
        let p = columnPositions(metrics: metrics)
        let x = p.x[focusedColumn]
        let w = p.width[focusedColumn]
        let view = metrics.usableWidth
        switch settings.centerMode {
        case .always:
            scroll = x - (view - w) / 2
        case .onOverflow:
            if p.total <= view + 0.5 {
                scroll = 0
            } else {
                scroll = min(max(x - (view - w) / 2, 0), p.total - view)
            }
        case .never:
            if w >= view || x < scroll {
                scroll = x
            } else if x + w > scroll + view {
                scroll = x + w - view
            }
        }
    }

    /// Where the strip settles after a swipe, and which column gets focus.
    /// `velocity` is in points per second. The strip coasts about 0.15 s in that direction first.
    /// Snap points: the centred position of each column (`always`, `onOverflow`), or the
    /// left-aligned and right-aligned positions of each column (`never`).
    public func snappedScroll(from scroll: Double, velocity: Double, settings: LayoutSettings, metrics: StripMetrics) -> (scroll: Double, column: Int) {
        guard !columns.isEmpty else { return (0, 0) }
        let p = columnPositions(metrics: metrics)
        let view = metrics.usableWidth
        let maxScroll = max(p.total - view, 0)
        let projected = scroll + velocity * 0.15
        var candidates: [(scroll: Double, column: Int)] = []
        for i in columns.indices {
            switch settings.centerMode {
            case .always:
                candidates.append((p.x[i] - (view - p.width[i]) / 2, i))
            case .onOverflow:
                let s = p.total <= view + 0.5 ? 0 : min(max(p.x[i] - (view - p.width[i]) / 2, 0), maxScroll)
                candidates.append((s, i))
            case .never:
                candidates.append((min(max(p.x[i], 0), maxScroll), i))
                candidates.append((min(max(p.x[i] + p.width[i] - view, 0), maxScroll), i))
            }
        }
        // Nearest snap point; on a tie, the column that is closest to the middle of the view wins.
        func midDistance(_ c: (scroll: Double, column: Int)) -> Double {
            abs(p.x[c.column] + p.width[c.column] / 2 - (c.scroll + view / 2))
        }
        let best = candidates.min { a, b in
            let da = abs(a.scroll - projected), db = abs(b.scroll - projected)
            if abs(da - db) > 0.5 { return da < db }
            return midDistance(a) < midDistance(b)
        }!
        return best
    }
}
