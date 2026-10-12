import CoreGraphics
import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

/// A writer that acts like a slow app: every write takes `delay` seconds.
private final class FakeWriter: FrameWriter, @unchecked Sendable {
    let delay: Double
    let failing: Set<WindowID>
    private let lock = NSLock()
    private var log: [(pid: pid_t, id: WindowID, frame: CGRect, previous: CGRect?)] = []
    private var batches: [pid_t] = []
    private var settled: [pid_t] = []

    init(delay: Double = 0, failing: Set<WindowID> = []) {
        self.delay = delay
        self.failing = failing
    }

    func beginBatch(pid: pid_t) { lock.withLock { batches.append(pid) } }
    func settle(pid: pid_t) { lock.withLock { settled.append(pid) } }
    var settledApps: [pid_t] { lock.withLock { settled.sorted() } }
    /// Writes of one window, in order.
    func frames(_ id: WindowID) -> [CGRect] { lock.withLock { log.filter { $0.id == id }.map(\.frame) } }

    func write(_ w: FrameWrite, previous: CGRect?) -> Bool {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        lock.withLock { log.append((w.pid, w.id, w.frame, previous)) }
        return !failing.contains(w.id)
    }

    var writes: [(pid: pid_t, id: WindowID, frame: CGRect, previous: CGRect?)] { lock.withLock { log } }
    var batchCount: Int { lock.withLock { batches.count } }
}

private func rect(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 100, height: 100) }

@Suite struct FrameApplierTests {
    @Test func appsAreWrittenInParallel() {
        // 6 apps, one window each, 2 ms per AX write: one after the other would take 12 ms.
        let writer = FakeWriter(delay: 0.002)
        let applier = FrameApplier(writer: writer)
        let writes = (1...6).map { FrameWrite(id: WindowID($0), pid: pid_t($0), frame: rect(CGFloat($0))) }
        _ = applier.applyAndWait(writes.map { FrameWrite(id: $0.id, pid: $0.pid, frame: rect(-1)) }) // warm up the queues
        var best = Double.infinity
        for round in 0..<5 {
            let ms = applier.applyAndWait(writes.map { FrameWrite(id: $0.id, pid: $0.pid, frame: rect(CGFloat(round * 10) + $0.frame.minX)) })!
            best = min(best, ms)
        }
        print("Frame write, 6 apps x 2 ms AX latency: \(String(format: "%.2f", best)) ms (serial about 12 ms)")
        #expect(best < 4, "6 apps x 2 ms took \(best) ms; serial would be about 12 ms")
        #expect(writer.writes.count == 36)
    }

    @Test func unchangedFramesAreSkipped() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        let w = FrameWrite(id: 1, pid: 10, frame: rect(0))
        applier.applyAndWait([w])
        applier.applyAndWait([w])
        applier.applyAndWait([w])
        #expect(writer.writes.count == 1)
        #expect(applier.stats.skipped == 2)
        #expect(applier.lastWritten(1) == rect(0))
    }

    @Test func previousFrameIsPassedToTheWriter() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(50))])
        #expect(writer.writes.map(\.previous) == [nil, rect(0)])
    }

    @Test func busyAppGetsOnlyTheNewestFrame() {
        // While the app is busy with the first write, three more frames arrive: only the last one is written.
        let writer = FakeWriter(delay: 0.03)
        let applier = FrameApplier(writer: writer)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        Thread.sleep(forTimeInterval: 0.005)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(2))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(3))]) { _ in done.signal() }
        _ = done.wait(timeout: .now() + 2)
        // Wait for the drain loop of the first batch to finish too.
        let deadline = Date().addingTimeInterval(1)
        while writer.writes.count < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.005) }
        #expect(writer.writes.map(\.frame) == [rect(0), rect(3)])
        #expect(applier.stats.coalesced == 2)
        #expect(applier.lastWritten(1) == rect(3))
    }

    @Test func failedWritesAreCountedAndRetried() {
        let writer = FakeWriter(failing: [2])
        let applier = FrameApplier(writer: writer)
        let w = FrameWrite(id: 2, pid: 10, frame: rect(0))
        applier.applyAndWait([w])
        applier.applyAndWait([w])
        // A failed write is not remembered, so the same frame is tried again next time.
        #expect(writer.writes.count == 2)
        #expect(applier.stats.errors == 2)
        #expect(applier.lastWritten(2) == nil)
    }

    @Test func forgetMakesTheNextWriteHappen() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        let w = FrameWrite(id: 1, pid: 10, frame: rect(0))
        applier.applyAndWait([w])
        applier.forget(1)
        applier.applyAndWait([w])
        #expect(writer.writes.count == 2)
    }

    @Test func oneBatchPerAppPerApply() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0)), FrameWrite(id: 2, pid: 10, frame: rect(1)),
                              FrameWrite(id: 3, pid: 11, frame: rect(2))])
        #expect(writer.batchCount == 2)
        #expect(applier.stats.windowWrites == 3)
    }

    @Test func writeMergedIntoABusyAppIsWaitedFor() {
        // The first apply keeps app 10 busy. The second one only adds a frame to its queue; applyAndWait must
        // still return after that frame is written. Engine.stop relies on this to release parked windows.
        let writer = FakeWriter(delay: 0.05)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        Thread.sleep(forTimeInterval: 0.01)
        let ms = applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(500))], timeout: 2)
        #expect(ms != nil)
        #expect(writer.frames(1) == [rect(0), rect(500)])
        #expect(applier.lastWritten(1) == rect(500))
    }

    @Test func goingBackToTheOldFrameWhileAWriteIsInFlightIsWritten() {
        // focus-right then focus-left with animation off: the second target equals the frame written before.
        let writer = FakeWriter(delay: 0.05)
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))])
        Thread.sleep(forTimeInterval: 0.01) // rect(500) is being written now
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))], timeout: 2) != nil)
        #expect(writer.frames(1) == [rect(0), rect(500), rect(0)])
        #expect(applier.lastWritten(1) == rect(0))
    }

    @Test func aFrameEqualToTheOneInFlightIsSkippedButWaitedFor() {
        let writer = FakeWriter(delay: 0.05)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))])
        Thread.sleep(forTimeInterval: 0.01)
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(500))], timeout: 2) != nil)
        #expect(writer.frames(1) == [rect(500)])
        #expect(applier.lastWritten(1) == rect(500))
    }

    @Test func ownFramesIncludeWrittenInFlightAndPending() {
        let writer = FakeWriter(delay: 0.05)
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))])
        Thread.sleep(forTimeInterval: 0.01)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(900))]) // pending behind the write in flight
        #expect(applier.isOwnFrame(1, rect(300)), "a half-written frame while the write runs")
        #expect(!applier.isOwnFrame(2, rect(0)))
        _ = applier.settleAndWait(timeout: 2)
        #expect(applier.isOwnFrame(1, rect(901)))
        #expect(!applier.isOwnFrame(1, rect(500)))
        #expect(!applier.isOwnFrame(1, rect(300)))
    }

    @Test func settleCanBeLimitedToSomeApps() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0)), FrameWrite(id: 2, pid: 20, frame: rect(0))])
        #expect(applier.settleAndWait(timeout: 2, pids: [20]))
        #expect(writer.settledApps == [20])
    }

    @Test func waitGivesUpOnAnAppThatDoesNotAnswer() {
        let writer = FakeWriter(delay: 0.5)
        let applier = FrameApplier(writer: writer)
        let start = Date()
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))], timeout: 0.05) == nil)
        #expect(Date().timeIntervalSince(start) < 0.4)
    }

    @Test func forgettingABusyAppReleasesTheWait() {
        let writer = FakeWriter(delay: 0.3)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        Thread.sleep(forTimeInterval: 0.01)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))]) { _ in done.signal() }
        applier.forgetApp(10)
        #expect(done.wait(timeout: .now() + 0.1) == .success)
    }

    @Test func settleRunsAfterTheLastWriteOfEachApp() {
        let writer = FakeWriter(delay: 0.02)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0)), FrameWrite(id: 2, pid: 11, frame: rect(1))])
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.writes.count == 2)
        #expect(writer.settledApps == [10, 11])
    }

    /// The engine records the time of each tick's call as "Frame write". An app slower than the tick rate gets
    /// new frames before it is idle; the time of one call must not grow with the frames of the later ticks.
    @Test func aStreamOfTicksToASlowAppDoesNotInflateTheTimeOfOneCall() {
        let writer = FakeWriter(delay: 0.02)
        let applier = FrameApplier(writer: writer)
        let lock = NSLock()
        var times: [Double] = []
        var early: [Int] = []
        let group = DispatchGroup()
        for x in 0..<40 { // one tick every 8 ms for 320 ms, 20 ms per write
            group.enter()
            applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(CGFloat(x)))]) { ms in
                // Done means this frame or a newer one is on the window.
                let landed = applier.lastWritten(1)?.minX ?? -1
                lock.withLock {
                    times.append(ms)
                    if landed < CGFloat(x) { early.append(x) }
                }
                group.leave()
            }
            Thread.sleep(forTimeInterval: 0.008)
        }
        #expect(group.wait(timeout: .now() + 3) == .success)
        let worst = lock.withLock { times.max() ?? 0 }
        // A frame waits for at most the write in flight and its own write: about 40 ms. Waiting for the app to
        // be idle took the whole stream: about 320 ms.
        #expect(worst < 120, "one call took \(worst) ms")
        #expect(lock.withLock { early }.isEmpty, "calls that finished before their frame landed")
        #expect(applier.lastWritten(1) == rect(39))
    }

    @Test func resetReleasesTheWaitForDroppedFrames() {
        let writer = FakeWriter(delay: 0.05)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        Thread.sleep(forTimeInterval: 0.01)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))]) { _ in done.signal() } // pending
        applier.reset() // drops the pending frame
        #expect(done.wait(timeout: .now() + 1) == .success)
        #expect(writer.frames(1) == [rect(0)])
        // The app is idle again: a new frame is written.
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(2))], timeout: 1) != nil)
        #expect(writer.frames(1) == [rect(0), rect(2)])
    }

    @Test func eachWriteReportsItsAppTheAXTimeAndTheWait() {
        let writer = FakeWriter(delay: 0.01)
        let lock = NSLock()
        var timings: [FrameApplier.WriteTiming] = []
        let applier = FrameApplier(writer: writer) { t in lock.withLock { timings.append(t) } }
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0)), FrameWrite(id: 2, pid: 11, frame: rect(0))])
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))]) // skipped: no timing
        let t = lock.withLock { timings }
        #expect(t.map(\.pid).sorted() == [10, 11])
        #expect(t.allSatisfy { $0.axMs >= 9 && $0.axMs < 200 }, "\(t)")
        #expect(t.allSatisfy { $0.latencyMs >= $0.axMs }, "the wait includes the AX call")
    }

    @Test func appsWhoseWritesAllFailAreReported() {
        let writer = FakeWriter(failing: [2])
        let applier = FrameApplier(writer: writer)
        for x in 0..<3 {
            applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(CGFloat(x))), FrameWrite(id: 2, pid: 11, frame: rect(CGFloat(x)))])
        }
        #expect(applier.failingApps(threshold: 3) == [11])
        #expect(applier.failingApps(threshold: 4).isEmpty)
        applier.clearFailures(11)
        #expect(applier.failingApps(threshold: 1).isEmpty)
    }
}
