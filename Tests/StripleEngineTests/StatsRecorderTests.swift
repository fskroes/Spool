import CoreGraphics
import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

@Suite struct StatsRecorderTests {
    private func timing(_ pid: pid_t, _ ax: Double, wait: Double = 0) -> FrameApplier.WriteTiming {
        FrameApplier.WriteTiming(pid: pid, axMs: ax, latencyMs: ax + wait)
    }

    @Test func slowestAppsComeFirstWithTheirNames() {
        let r = StatsRecorder()
        for _ in 0..<10 { r.record(write: timing(10, 2)) }
        for ms in [5.0, 30, 40] { r.record(write: timing(20, ms, wait: 10)) }
        r.record(write: timing(30, 9))
        let s = StatsRecorder.slowest(r.snapshot().apps, bundleIDs: [20: "com.microsoft.teams2", 10: "com.apple.Notes"], limit: 2)
        #expect(s == [
            AppWriteStats(bundleID: "com.microsoft.teams2", pid: 20, writes: 3, axP50: 30, axP95: 40, latencyP95: 50),
            AppWriteStats(bundleID: "", pid: 30, writes: 1, axP50: 9, axP95: 9, latencyP95: 9),
        ])
    }

    @Test func aQuitAppIsForgotten() {
        let r = StatsRecorder()
        r.record(write: timing(10, 2))
        r.record(write: timing(11, 2))
        r.forget(pid: 10)
        #expect(Set(r.snapshot().apps.keys) == [11])
    }

    @Test func stoppingTheEngineForgetsEveryAppAndItsWindows() {
        // Apps can quit while the engine is stopped; a new app with the same pid must start with no samples.
        let r = StatsRecorder()
        let applier = FrameApplier(writer: NoWriter()) { r.record(write: $0) }
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: .init(x: 0, y: 0, width: 10, height: 10))])
        #expect(Set(r.snapshot().apps.keys) == [10])
        Engine.resetWriteState(applier: applier, recorder: r)
        #expect(r.snapshot().apps.isEmpty)
        #expect(applier.appCount == 0)
        #expect(applier.lastWritten(1) == nil)
    }

    @Test func percentilesUseTheNewestWrites() {
        let r = StatsRecorder()
        for _ in 0..<200 { r.record(write: timing(10, 100)) }
        for _ in 0..<128 { r.record(write: timing(10, 1)) }
        let s = StatsRecorder.slowest(r.snapshot().apps, bundleIDs: [:])
        #expect(s.first?.axP95 == 1)
        #expect(s.first?.writes == 328)
    }
}

private final class NoWriter: FrameWriter, @unchecked Sendable {
    func write(_ w: FrameWrite, previous: CGRect?) -> Bool { true }
}
