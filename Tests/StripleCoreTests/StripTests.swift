import Foundation
import CoreGraphics
import Testing
@testable import StripleCore

let settings = LayoutSettings()
let metrics = StripMetrics(usableWidth: 1000, usableHeight: 800, gap: 10)

func win(_ id: WindowID, _ app: String = "app", _ title: String = "") -> WindowInfo {
    WindowInfo(id: id, pid: 1, bundleID: app, title: title)
}

func strip(_ ids: [WindowID], width: Double = 0.5, focus: Int = 0) -> Strip {
    var s = Strip()
    for id in ids { s.insert(win(id), width: .proportion(width), focus: true) }
    s.focusedColumn = focus
    return s
}

func ids(_ s: Strip) -> [[WindowID]] { s.columns.map { $0.windows.map(\.id) } }

@Suite struct InsertRemoveTests {
    // Round 8 finding: a held window put in to the left of the focused column pushed the focused window away.
    @Test(arguments: [CenterMode.always, .onOverflow, .never])
    func insertKeepingViewDoesNotMoveTheFocusedColumn(mode: CenterMode) {
        var settings = LayoutSettings()
        settings.centerMode = mode
        var s = Strip()
        for i in 1...3 { s.insert(win(WindowID(i)), width: .proportion(0.5), focus: true) }
        s.ensureFocusVisible(settings: settings, metrics: metrics)
        let onScreen = { (s: Strip) in s.columnPositions(metrics: metrics).x[s.focusedColumn] - s.scroll }
        let before = onScreen(s)

        s.insertKeepingView(win(9), width: .proportion(0.5), slot: 2, settings: settings, metrics: metrics)
        #expect(s.allWindows.map(\.id) == [1, 9, 2, 3])
        #expect(s.focusedWindow?.id == 3)
        #expect(abs(onScreen(s) - before) < 0.001)

        // To the right of focus: nothing moves.
        let scroll = s.scroll
        s.insertKeepingView(win(10), width: .proportion(0.5), slot: 5, settings: settings, metrics: metrics)
        #expect(s.scroll == scroll)
        // An empty strip, or no metrics: a plain insert.
        var e = Strip()
        e.insertKeepingView(win(1), width: .proportion(0.5), slot: 1, settings: settings, metrics: nil)
        #expect(e.allWindows.map(\.id) == [1] && e.scroll == 0)
    }

    // Round 9 finding: keeping the view ignored the center mode. A strip that fits must stay left-aligned, and no
    // strip scrolls past its ends.
    @Test(arguments: [CenterMode.onOverflow, .never])
    func insertKeepingViewNeverScrollsAStripPastItsEnds(mode: CenterMode) {
        var settings = LayoutSettings()
        settings.centerMode = mode
        var s = Strip()
        s.insert(win(1), width: .proportion(0.5), focus: true)
        s.insertKeepingView(win(9), width: .proportion(0.4), slot: 1, settings: settings, metrics: metrics)
        #expect(s.allWindows.map(\.id) == [9, 1])
        #expect(s.scroll == 0)

        // Fits before, overflows after: no empty space on the right.
        s.insertKeepingView(win(8), width: .proportion(0.5), slot: 1, settings: settings, metrics: metrics)
        let p = s.columnPositions(metrics: metrics)
        #expect(s.scroll >= 0 && s.scroll <= p.total - metrics.usableWidth + 0.001)
        // The focused window stays fully on screen.
        let x = p.x[s.focusedColumn] - s.scroll
        #expect(x >= -0.001 && x + p.width[s.focusedColumn] <= metrics.usableWidth + 0.001)
    }

    @Test func newWindowGoesRightOfFocused() {
        var s = strip([1, 2, 3], focus: 0)
        s.insert(win(4), width: .proportion(0.5), focus: true)
        #expect(ids(s) == [[1], [4], [2], [3]])
        #expect(s.focusedColumn == 1)
    }

    @Test func newWindowNeverResizesOthers() {
        var s = strip([1, 2])
        s.columns[0].width = .proportion(0.6)
        let before = s.columns.map(\.width)
        s.insert(win(3), width: .proportion(0.5), focus: true)
        #expect(s.columns.filter { $0.windows[0].id != 3 }.map(\.width) == before)
    }

    @Test func backgroundWindowKeepsFocus() {
        var s = strip([1, 2, 3], focus: 1)
        s.scroll = 123
        s.insert(win(9), width: .proportion(0.5), focus: false)
        #expect(s.focusedWindow?.id == 2)
        #expect(s.scroll == 123)
        #expect(ids(s) == [[1], [2], [9], [3]])
    }

    @Test func backgroundWindowInsertedBeforeFocusShiftsFocusIndex() {
        var s = strip([1, 2, 3], focus: 2)
        s.insert(win(9), width: .proportion(0.5), slot: 1, focus: false)
        #expect(s.focusedWindow?.id == 3)
    }

    @Test func fixedSlotRule() {
        var s = strip([1, 2, 3], focus: 2)
        s.insert(win(9), width: .proportion(0.5), slot: 2, focus: true)
        #expect(ids(s) == [[1], [9], [2], [3]])
        var t = strip([1])
        t.insert(win(9), width: .proportion(0.5), slot: 7, focus: true)
        #expect(ids(t) == [[1], [9]])
    }

    @Test func duplicateInsertIsIgnored() {
        var s = strip([1, 2])
        s.insert(win(2), width: .proportion(0.5), focus: true)
        #expect(ids(s) == [[1], [2]])
    }

    @Test func removingFocusedLastColumnFocusesLeft() {
        var s = strip([1, 2, 3], focus: 2)
        #expect(s.remove(3) == 2)
        #expect(s.focusedColumn == 1)
    }

    @Test func removingColumnLeftOfFocusKeepsFocusedWindow() {
        var s = strip([1, 2, 3], focus: 2)
        #expect(s.remove(1) == nil)
        #expect(s.focusedWindow?.id == 3)
    }

    @Test func removingFromStackKeepsColumn() {
        var s = strip([1, 2], focus: 1)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        #expect(ids(s) == [[1, 2]])
        s.remove(2)
        #expect(ids(s) == [[1]])
        #expect(s.columns[0].heights == [1])
        #expect(s.columns[0].isTabbed == false)
    }

    @Test func removingLastWindowResetsStrip() {
        var s = strip([1])
        s.scroll = 50
        s.remove(1)
        #expect(s.isEmpty && s.scroll == 0)
    }
}

@Suite struct CommandTests {
    @Test func focusMovesAndClamps() {
        var s = strip([1, 2, 3], focus: 0)
        #expect(s.apply(.focusLeft, settings: settings, metrics: metrics) == .none)
        #expect(s.apply(.focusRight, settings: settings, metrics: metrics) == .changed(focus: 2))
        #expect(s.apply(.focusLast, settings: settings, metrics: metrics) == .changed(focus: 3))
        #expect(s.apply(.focusRight, settings: settings, metrics: metrics) == .none)
        #expect(s.apply(.focusFirst, settings: settings, metrics: metrics) == .changed(focus: 1))
    }

    @Test func focusIndexNineIsLast() {
        var s = strip([1, 2, 3, 4], focus: 0)
        #expect(s.apply(.focusIndex(9), settings: settings, metrics: metrics) == .changed(focus: 4))
        #expect(s.apply(.focusIndex(2), settings: settings, metrics: metrics) == .changed(focus: 2))
        #expect(s.apply(.focusIndex(7), settings: settings, metrics: metrics) == .none)
    }

    @Test func moveColumn() {
        var s = strip([1, 2, 3], focus: 0)
        _ = s.apply(.moveRight, settings: settings, metrics: metrics)
        #expect(ids(s) == [[2], [1], [3]])
        #expect(s.focusedWindow?.id == 1)
        _ = s.apply(.moveLast, settings: settings, metrics: metrics)
        #expect(ids(s) == [[2], [3], [1]])
        _ = s.apply(.moveToIndex(1), settings: settings, metrics: metrics)
        #expect(ids(s) == [[1], [2], [3]])
        #expect(s.apply(.moveLeft, settings: settings, metrics: metrics) == .none)
    }

    @Test func stackAndPopBothDirections() {
        var s = strip([1, 2, 3], focus: 1)
        _ = s.apply(.stackRight, settings: settings, metrics: metrics)
        #expect(ids(s) == [[1], [3, 2]])
        #expect(s.focusedWindow?.id == 2)
        _ = s.apply(.popLeft, settings: settings, metrics: metrics)
        #expect(ids(s) == [[1], [2], [3]])
        #expect(s.focusedWindow?.id == 2)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        #expect(ids(s) == [[1, 2], [3]])
        _ = s.apply(.popRight, settings: settings, metrics: metrics)
        #expect(ids(s) == [[1], [2], [3]])
        #expect(s.focusedColumn == 1)
    }

    @Test func popKeepsColumnWidth() {
        var s = strip([1, 2], width: 0.4, focus: 1)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        _ = s.apply(.popRight, settings: settings, metrics: metrics)
        #expect(s.columns[1].width == .proportion(0.4))
    }

    @Test func stackOnEdgeDoesNothing() {
        var s = strip([1, 2], focus: 0)
        #expect(s.apply(.stackLeft, settings: settings, metrics: metrics) == .none)
        #expect(s.apply(.popRight, settings: settings, metrics: metrics) == .none)
    }

    @Test func moveAndFocusInsideStack() {
        var s = strip([1, 2, 3], focus: 1)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        #expect(s.apply(.stackLeft, settings: settings, metrics: metrics) == .none)
        _ = s.apply(.focusUp, settings: settings, metrics: metrics)
        #expect(s.focusedWindow?.id == 1)
        _ = s.apply(.moveDown, settings: settings, metrics: metrics)
        #expect(ids(s) == [[2, 1], [3]])
        #expect(s.focusedWindow?.id == 1)
    }

    @Test func cycleWidthGoesThroughPresets() {
        var s = strip([1], width: 0.5)
        _ = s.apply(.cycleWidth, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(2.0 / 3.0))
        _ = s.apply(.cycleWidth, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(1.0 / 3.0))
        _ = s.apply(.cycleWidth, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(0.5))
    }

    @Test func fullWidthToggleRestores() {
        var s = strip([1], width: 0.4)
        _ = s.apply(.toggleFullWidth, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(1))
        _ = s.apply(.toggleFullWidth, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(0.4))
    }

    @Test func widerNarrowerClamp() {
        var s = strip([1], width: 0.95)
        _ = s.apply(.wider, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(1))
        #expect(s.apply(.wider, settings: settings, metrics: metrics) == .none)
        s.columns[0].width = .proportion(0.15)
        _ = s.apply(.narrower, settings: settings, metrics: metrics)
        #expect(s.columns[0].width == .proportion(0.1))
    }

    @Test func tallerShorterKeepSumAndMinimum() {
        var s = strip([1, 2, 3], focus: 1)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        s.focusedColumn = 1
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        #expect(ids(s) == [[1, 2, 3]])
        for _ in 0..<20 { _ = s.apply(.taller, settings: settings, metrics: metrics) }
        let h = s.columns[0].heights
        #expect(abs(h.reduce(0, +) - 1) < 1e-9)
        #expect(h.allSatisfy { $0 >= 0.1 - 1e-9 })
        #expect(h[2] > 0.79)
        _ = s.apply(.equalizeHeights, settings: settings, metrics: metrics)
        #expect(s.columns[0].heights.allSatisfy { abs($0 - 1.0 / 3.0) < 1e-9 })
    }

    @Test func tabbedNeedsAStack() {
        var s = strip([1, 2], focus: 1)
        #expect(s.apply(.toggleTabbed, settings: settings, metrics: metrics) == .none)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics)
        _ = s.apply(.toggleTabbed, settings: settings, metrics: metrics)
        #expect(s.columns[0].isTabbed)
        _ = s.apply(.popRight, settings: settings, metrics: metrics)
        #expect(s.columns[0].isTabbed == false)
    }

    @Test func engineCommandsDoNotTouchStrip() {
        var s = strip([1, 2])
        for c in [Command.toggleFloat, .sendToNextDisplay, .stop, .start, .toggleEngine, .restart] {
            #expect(s.apply(c, settings: settings, metrics: metrics) == .none)
        }
    }
}

@Suite struct CommandNameTests {
    @Test func everyBindableCommandRoundTrips() {
        for c in Command.bindable { #expect(Command(name: c.name) == c) }
        for c in [Command.start, .stop, .restart, .focusWindow(42)] { #expect(Command(name: c.name) == c) }
    }

    @Test func lenientParsing() {
        #expect(Command(name: "Focus Left") == .focusLeft)
        #expect(Command(name: "focus-index/3") == .focusIndex(3))
        #expect(Command(name: "focus_index 3") == .focusIndex(3))
        #expect(Command(name: "focus-index-0") == nil)
        #expect(Command(name: "focus-index-10") == nil)
        #expect(Command(name: "nope") == nil)
    }

    @Test func urls() {
        #expect(StripleURL.command(from: URL(string: "striple://focus-left")!) == .focusLeft)
        #expect(StripleURL.command(from: URL(string: "striple://focus-index/3")!) == .focusIndex(3))
        #expect(StripleURL.command(from: URL(string: "striple://command?name=cycle-width")!) == .cycleWidth)
        #expect(StripleURL.command(from: URL(string: "other://focus-left")!) == nil)
        for c in Command.bindable { #expect(StripleURL.command(from: StripleURL.url(for: c)) == c) }
    }
}
