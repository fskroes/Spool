import Testing
@testable import StripleCore

/// `#expect` cannot wrap a mutating call, so the move runs here first.
private func move(_ s: inout Strip, _ id: WindowID, toGap gap: Int) -> Bool { s.moveWindow(id, toGap: gap) }

@Suite struct DragTests {
    @Test func singleColumnMovesWithItsWidth() {
        var s = strip([1, 2, 3, 4], focus: 0)
        s.columns[0].width = .proportion(0.3)
        #expect(move(&s, 1, toGap: 3))
        #expect(ids(s) == [[2], [3], [1], [4]])
        #expect(s.columns[2].width == .proportion(0.3))
        #expect(s.focusedColumn == 2)
        #expect(move(&s, 1, toGap: 0))
        #expect(ids(s) == [[1], [2], [3], [4]])
        #expect(move(&s, 1, toGap: 4))
        #expect(ids(s) == [[2], [3], [4], [1]])
    }

    @Test func droppingInPlaceIsANoOp() {
        var s = strip([1, 2, 3], focus: 0)
        #expect(!move(&s, 2, toGap: 1))
        #expect(!move(&s, 2, toGap: 2))
        #expect(ids(s) == [[1], [2], [3]])
    }

    @Test func windowFromAStackBecomesAColumn() {
        var s = strip([1, 2, 3], focus: 1)
        _ = s.apply(.stackLeft, settings: settings, metrics: metrics) // [[1, 2], [3]]
        _ = s.apply(.toggleTabbed, settings: settings, metrics: metrics)
        #expect(move(&s, 1, toGap: 2))
        #expect(ids(s) == [[2], [3], [1]])
        #expect(s.columns[0].isTabbed == false)
        #expect(s.columns[0].heights == [1])
        #expect(s.focusedWindow?.id == 1)
    }

    @Test func dropGapUsesColumnCentres() {
        let s = strip([1, 2, 3], focus: 0)
        let p = s.columnPositions(metrics: metrics)
        #expect(s.dropGap(atStripX: -50, metrics: metrics) == 0)
        #expect(s.dropGap(atStripX: p.x[1] + p.width[1] / 2 - 1, metrics: metrics) == 1)
        #expect(s.dropGap(atStripX: p.x[1] + p.width[1] / 2 + 1, metrics: metrics) == 2)
        #expect(s.dropGap(atStripX: p.total + 500, metrics: metrics) == 3)
    }

    @Test func unknownWindowIsIgnored() {
        var s = strip([1], focus: 0)
        #expect(!move(&s, 99, toGap: 0))
    }
}
