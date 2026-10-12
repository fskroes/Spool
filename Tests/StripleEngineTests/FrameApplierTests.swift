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

    init(delay: Double = 0, failing: Set<WindowID> = []) {
        self.delay = delay
        self.failing = failing
    }

    func beginBatch(pid: pid_t) { lock.withLock { batches.append(pid) } }

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
            let ms = applier.applyAndWait(writes.map { FrameWrite(id: $0.id, pid: $0.pid, frame: rect(CGFloat(round * 10) + $0.frame.minX)) })
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
}
