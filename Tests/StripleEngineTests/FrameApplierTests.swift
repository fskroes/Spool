import CoreGraphics
import Foundation
import Testing
@testable import StripleCore
@testable import StripleEngine

/// A writer that acts like a slow app: every write takes `delay` seconds.
private final class FakeWriter: FrameWriter, @unchecked Sendable {
    let delay: Double
    let failing: Set<WindowID>
    /// Per-window delay, used instead of `delay` for these windows.
    var delays: [WindowID: Double] = [:]
    private let lock = NSLock()
    private var log: [(pid: pid_t, id: WindowID, frame: CGRect, previous: CGRect?)] = []
    private var batches: [pid_t] = []
    private var settled: [pid_t] = []
    private var gates: [WindowID: Gate] = [:]
    private var outcomes: [WindowID: [Bool]] = [:]

    /// The results of the next writes of one window, in order; after them, `failing` decides.
    func outcomes(_ id: WindowID, _ list: [Bool]) { lock.withLock { outcomes[id] = list } }

    /// Holds the next write of one window: `started` signals when the write begins, and the write ends after
    /// `release`. A gate holds one write only. The tests use gates to put events in a fixed order, without sleeps.
    final class Gate: Sendable {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
    }

    func gate(_ id: WindowID) -> Gate { lock.withLock { let g = Gate(); gates[id] = g; return g } }

    init(delay: Double = 0, failing: Set<WindowID> = []) {
        self.delay = delay
        self.failing = failing
    }

    func beginBatch(pid: pid_t) { lock.withLock { batches.append(pid) } }
    /// Signals once for every batch that ends.
    let batchEnded = DispatchSemaphore(value: 0)
    func endBatch(pid: pid_t) { batchEnded.signal() }
    func settle(pid: pid_t) { lock.withLock { settled.append(pid) } }
    var settledApps: [pid_t] { lock.withLock { settled.sorted() } }
    /// Writes of one window, in order.
    func frames(_ id: WindowID) -> [CGRect] { lock.withLock { log.filter { $0.id == id }.map(\.frame) } }

    func write(_ w: FrameWrite, previous: CGRect?) -> Bool {
        if let g = lock.withLock({ gates.removeValue(forKey: w.id) }) {
            g.started.signal()
            g.release.wait()
        }
        let wait = delays[w.id] ?? delay
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        return lock.withLock {
            log.append((w.pid, w.id, w.frame, previous))
            if var list = outcomes[w.id], !list.isEmpty {
                let ok = list.removeFirst()
                outcomes[w.id] = list
                return ok
            }
            return !failing.contains(w.id)
        }
    }

    var writes: [(pid: pid_t, id: WindowID, frame: CGRect, previous: CGRect?)] { lock.withLock { log } }
    var batchCount: Int { lock.withLock { batches.count } }
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func rect(_ x: CGFloat) -> CGRect { CGRect(x: x, y: 0, width: 100, height: 100) }

@Suite struct FrameApplierTests {
    @Test func appsAreWrittenInParallel() {
        // 6 apps, one window each. Every write is held until all 6 have started: with one queue for all apps,
        // the second write could not start while the first one is held.
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        let gates = (1...6).map { writer.gate(WindowID($0)) }
        let done = DispatchSemaphore(value: 0)
        applier.apply((1...6).map { FrameWrite(id: WindowID($0), pid: pid_t($0), frame: rect(CGFloat($0))) }) { _ in done.signal() }
        let started = gates.map { $0.started.wait(timeout: .now() + 2) == .success }
        #expect(started == Array(repeating: true, count: 6), "writes of different apps did not run at the same time")
        gates.forEach { $0.release.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.writes.count == 6)
        #expect(writer.batchCount == 6)
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
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(2))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(3))]) { _ in done.signal() }
        first.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
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
        // The first apply keeps app 10 busy. The second one only adds a frame to its queue; its call must still
        // finish only after that frame is written. Engine.stop relies on this to release parked windows.
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let early = Box<Bool>(false)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))]) { _ in
            early.value = applier.lastWritten(1) != rect(500)
            done.signal()
        }
        first.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(!early.value, "the call finished before its frame was written")
        #expect(writer.frames(1) == [rect(0), rect(500)])
        #expect(applier.lastWritten(1) == rect(500))
    }

    @Test func goingBackToTheOldFrameWhileAWriteIsInFlightIsWritten() {
        // focus-right then focus-left with animation off: the second target equals the frame written before.
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        let second = writer.gate(1)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))])
        #expect(second.started.wait(timeout: .now() + 2) == .success) // rect(500) is being written now
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { _ in done.signal() }
        second.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames(1) == [rect(0), rect(500), rect(0)])
        #expect(applier.lastWritten(1) == rect(0))
    }

    @Test func aFrameBackToTheOneInFlightReplacesTheNewerPendingFrame() {
        // A is in flight, B waits, then the engine wants A again (scroll right, then back). A must be written
        // again after B is dropped; skipping A as "in flight" would leave the window at B.
        let writer = FakeWriter()
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(50))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        held.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(1) == [rect(0), rect(0)])
        #expect(applier.lastWritten(1) == rect(0))
    }

    @Test func aFrameEqualToTheOneInFlightIsSkippedButWaitedFor() {
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))]) { _ in done.signal() }
        #expect(done.wait(timeout: .now() + Self.quiet) == .timedOut, "the call finished before the frame landed")
        first.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames(1) == [rect(500)])
        #expect(applier.stats.skipped == 1)
        #expect(applier.lastWritten(1) == rect(500))
    }

    @Test func ownFramesIncludeWrittenInFlightAndPending() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        let second = writer.gate(1)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(500))])
        #expect(second.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(900))]) // pending behind the write in flight
        #expect(applier.isOwnFrame(1, rect(300)), "a half-written frame while the write runs")
        #expect(!applier.isOwnFrame(2, rect(0)))
        second.release.signal()
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
        let writer = FakeWriter()
        let hung = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))], timeout: 0.05) == nil)
        #expect(hung.started.wait(timeout: .now() + 2) == .success)
        hung.release.signal()
    }

    @Test func forgettingABusyAppReleasesTheWait() {
        let writer = FakeWriter()
        let hung = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(hung.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let time = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))]) { ms in time.set(ms); done.signal() }
        applier.forgetApp(10)
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(time.get() == .some(nil), "a dropped frame has no frame-write time")
        #expect(writer.frames(1).isEmpty, "the wait ended while the app was still hung")
        hung.release.signal()
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
    /// new frames before it is idle; one call must finish when its own frame (or a newer one) lands, not when the
    /// app is idle after the frames of the later ticks.
    @Test func aStreamOfTicksToASlowAppDoesNotWaitForTheLaterTicks() {
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        // `held` is the write in flight. Each gate is set before the gate in front of it opens.
        var held = writer.gate(1)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        for x in 1...4 {
            // Frame x waits behind the write in flight.
            let done = DispatchSemaphore(value: 0)
            let landed = Box<CGFloat>(-1)
            applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(CGFloat(x)))]) { _ in
                landed.value = applier.lastWritten(1)?.minX ?? -1
                done.signal()
            }
            let own = writer.gate(1)
            held.release.signal()
            #expect(own.started.wait(timeout: .now() + 2) == .success, "frame \(x) was not written")
            // The next tick arrives while frame x is written.
            let last = x == 4
            if !last { applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(CGFloat(x) + 0.5))]) }
            #expect(done.wait(timeout: .now() + Self.quiet) == .timedOut, "call \(x) finished before its frame landed")
            let next = writer.gate(1)
            own.release.signal()
            #expect(done.wait(timeout: .now() + 2) == .success, "call \(x) waited for the later ticks")
            #expect(landed.value == CGFloat(x))
            if last { next.release.signal(); break } // no write uses it
            #expect(next.started.wait(timeout: .now() + 2) == .success)
            held = next
        }
        #expect(applier.settleAndWait(timeout: 2))
        #expect(applier.lastWritten(1) == rect(4))
        #expect(writer.frames(1).map(\.minX) == [0, 1, 1.5, 2, 2.5, 3, 3.5, 4])
    }

    @Test func resetReleasesTheWaitForDroppedFrames() {
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let time = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))]) { ms in time.set(ms); done.signal() } // pending
        applier.reset() // drops the pending frame
        first.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(time.get() == .some(nil), "a dropped frame has no frame-write time")
        #expect(writer.frames(1) == [rect(0)])
        // The app is idle again: a new frame is written.
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(2))], timeout: 1) != nil)
        #expect(writer.frames(1) == [rect(0), rect(2)])
    }

    @Test func aWriteThatLandsAfterAResetHasNoFrameWriteTime() {
        // The engine stopped during the write: the caller is released, but the time is not a frame-write sample.
        let writer = FakeWriter()
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        let done = DispatchSemaphore(value: 0)
        let time = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { ms in time.set(ms); done.signal() }
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        applier.reset()
        held.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(time.get() == .some(nil))
    }

    @Test func aFrameDroppedByResetHasNoTimeAlsoWhenTheEngineStartsAgainAtOnce() {
        // A in flight, B pending, reset drops B, then the engine starts again with C for the same app. C's
        // batch lands after B's waiter number: B's call must still get nil, B was never written.
        let writer = FakeWriter()
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let b = TimeBox(), c = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))]) { ms in b.set(ms); done.signal() }
        applier.reset()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(2))]) { ms in c.set(ms); done.signal() }
        held.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(b.get() == .some(nil), "B was dropped")
        #expect(c.get().flatMap { $0 } != nil, "C was written after the reset")
        #expect(writer.frames(1) == [rect(0), rect(2)])
    }

    @Test func aFrameAskedForAgainWhileItsWriteFailsIsWrittenAgain() {
        // The end of an animation repeats the last frame while it is in flight. If that write fails, the frame
        // must be written again for the second call, else the window keeps a wrong frame.
        let writer = FakeWriter()
        writer.outcomes(1, [false, true])
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let time = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { ms in time.set(ms); done.signal() }
        held.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames(1) == [rect(0), rect(0)])
        #expect(applier.lastWritten(1) == rect(0), "the call returned after its frame landed")
        #expect(time.get().flatMap { $0 } != nil)
    }

    @Test func aFrameAskedForAgainWhileItsWriteSucceedsIsWrittenOnce() {
        let writer = FakeWriter()
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        held.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(1) == [rect(0)])
        #expect(applier.stats.skipped == 1)
    }

    @Test func aCallWithEveryFrameSkippedReportsNoTime() {
        // Nothing was written, so there is no frame-write time: the engine must not record a sample of 0 ms.
        let writer = FakeWriter()
        let applier = FrameApplier(writer: writer)
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))], timeout: 2) != nil)
        let done = DispatchSemaphore(value: 0)
        let time = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { ms in time.set(ms); done.signal() }
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(time.get() == .some(nil), "a call that wrote nothing reported \(String(describing: time.get())) ms")
        #expect(writer.batchCount == 1)
        #expect(applier.stats.skipped == 1)
    }

    @Test func aFrameInFlightForAForgottenAppIsWrittenAgainByTheNewApp() {
        // App 10 is forgotten while W1 = A is in flight. A new app gets pid 10 and goes idle. The engine then wants
        // W1 = A: the new app's drain must write it. Waiting for the old write would never end: the new app is idle,
        // and the old drain does not touch the new app's waiters.
        let writer = FakeWriter()
        let old = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(old.started.wait(timeout: .now() + 2) == .success)
        applier.forgetApp(10)
        #expect(applier.applyAndWait([FrameWrite(id: 2, pid: 10, frame: rect(0))], timeout: 2) != nil)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { _ in done.signal() }
        let finished = done.wait(timeout: .now() + 2) == .success
        old.release.signal()
        #expect(finished, "the call waited for the forgotten app's write")
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(1) == [rect(0), rect(0)])
    }

    @Test func aFailedWriteOfAForgottenAppIsNotReportedAsWrittenForTheNewApp() {
        // As above, but the new app is busy (W2 held) and the old write of W1 = A fails. The old drain does not
        // queue A again (the app it belongs to is gone), so the new app must have queued A itself: else the call
        // returns a time and the window keeps a wrong frame.
        let writer = FakeWriter()
        writer.outcomes(1, [false, true])
        let old = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(old.started.wait(timeout: .now() + 2) == .success)
        applier.forgetApp(10)
        let busy = writer.gate(2)
        applier.apply([FrameWrite(id: 2, pid: 10, frame: rect(0))])
        #expect(busy.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let time = TimeBox()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { ms in time.set(ms); done.signal() }
        old.release.signal()
        #expect(writer.batchEnded.wait(timeout: .now() + 2) == .success, "the old batch ended")
        busy.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames(1) == [rect(0), rect(0)], "A was not written again after the old write failed")
        #expect(applier.lastWritten(1) == rect(0))
        #expect(time.get().flatMap { $0 } != nil)
    }

    @Test func aRetryOfAForgottenAppIsNotWrittenByTheNewApp() {
        // W1 = A in flight and asked for again, then app 10 is forgotten. A new app with pid 10 is busy when the
        // old write fails. The retry belonged to the forgotten app (its call already ended as dropped): the new
        // app's drain must not write it.
        let writer = FakeWriter()
        writer.outcomes(1, [false])
        let old = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(old.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        applier.forgetApp(10)
        let busy = writer.gate(2)
        applier.apply([FrameWrite(id: 2, pid: 10, frame: rect(0))])
        #expect(busy.started.wait(timeout: .now() + 2) == .success)
        old.release.signal()
        #expect(writer.batchEnded.wait(timeout: .now() + 2) == .success, "the old batch ended")
        busy.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(1) == [rect(0)], "the new app wrote the forgotten app's retry")
    }

    @Test func aFailedWriteDoesNotReplaceANewerPendingFrame() {
        // A in flight, A asked for again (kept to retry), then B. A fails: B is newer, so the retry of A is dropped.
        let writer = FakeWriter()
        writer.outcomes(1, [false])
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))])
        held.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(1) == [rect(0), rect(1)])
        #expect(applier.lastWritten(1) == rect(1))
    }

    @Test func aWindowQueuedAgainAfterResetIsWrittenOnceInTheBatch() {
        // reset drops B from the pending list too: else C (same window) is in the batch order twice.
        let writer = FakeWriter()
        let held = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(1))])
        applier.reset()
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(2))])
        held.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(1) == [rect(0), rect(2)])
    }

    @Test func aFailedWriteMakesTheOldFrameBeWrittenAgain() {
        // A written, B failed: the window has an unknown frame, so A again is not skipped.
        let writer = FakeWriter()
        writer.outcomes(1, [true, false])
        let applier = FrameApplier(writer: writer)
        for x in [0, 1, 0] { applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(CGFloat(x)))]) }
        #expect(writer.frames(1) == [rect(0), rect(1), rect(0)])
    }

    @Test func forgetDuringAWriteMakesTheNextWriteOfThatFrameHappen() {
        // The user drops a window while Striple's write to it is in flight. The relayout sends the same frame
        // again after the old write lands: it must be written, the window is where the user dropped it.
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.forget(1)
        first.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(applier.lastWritten(1) == nil, "the write that landed after forget was remembered")
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))], timeout: 2) != nil)
        #expect(writer.frames(1) == [rect(0), rect(0)])
        #expect(writer.writes.last?.previous == nil, "the writer was told the window already had the frame")
    }

    @Test func forgetThenTheSameFrameWhileTheWriteIsInFlightIsWritten() {
        // As above, but the relayout sends the frame while the old write is still in flight.
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.forget(1)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))]) { _ in done.signal() }
        first.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames(1) == [rect(0), rect(0)])
        #expect(writer.writes.last?.previous == nil)
        #expect(applier.lastWritten(1) == rect(0))
    }

    @Test func resetDuringAWriteMakesTheNextWriteOfThatFrameHappen() {
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.reset()
        first.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(applier.lastWritten(1) == nil, "the write that landed after reset was remembered")
        #expect(applier.applyAndWait([FrameWrite(id: 1, pid: 10, frame: rect(0))], timeout: 2) != nil)
        #expect(writer.frames(1) == [rect(0), rect(0)])
    }

    @Test func resetForgetsIdleAppsAndTheirFailures() {
        let writer = FakeWriter(failing: [2])
        let applier = FrameApplier(writer: writer)
        for x in 0..<3 { applier.applyAndWait([FrameWrite(id: 2, pid: 11, frame: rect(CGFloat(x)))]) }
        #expect(applier.failingApps(threshold: 3) == [11])
        applier.reset()
        #expect(applier.failingApps(threshold: 1).isEmpty)
        #expect(applier.appCount == 0)
    }

    @Test func resetClearsTheFailuresOfABusyAppToo() {
        // The engine starts again while an app's write is still in flight: the failures from before the stop
        // must not mark the app as failing.
        let writer = FakeWriter(failing: [2])
        let applier = FrameApplier(writer: writer)
        for x in 0..<3 { applier.applyAndWait([FrameWrite(id: 2, pid: 11, frame: rect(CGFloat(x)))]) }
        let held = writer.gate(2)
        applier.apply([FrameWrite(id: 2, pid: 11, frame: rect(9))])
        #expect(held.started.wait(timeout: .now() + 2) == .success)
        applier.reset()
        #expect(applier.failingApps(threshold: 1).isEmpty)
        held.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
    }

    @Test func aBusyAppGoesAwayAfterResetWhenItIsIdle() {
        let writer = FakeWriter()
        let first = writer.gate(1)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.reset()
        #expect(applier.appCount == 1, "the drain still needs the state")
        first.release.signal()
        #expect(writer.batchEnded.wait(timeout: .now() + 2) == .success)
        let deadline = Date().addingTimeInterval(2)
        while applier.appCount > 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.002) }
        #expect(applier.appCount == 0)
    }

    @Test func aBatchThatRunsDuringResetReportsNoTimings() {
        // The engine stops (reset, then the stats forget all apps) while a write is in flight. The write must not
        // put the app back into the stats, even when the app gets a new frame before the write lands.
        let writer = FakeWriter()
        let first = writer.gate(1)
        let lock = NSLock()
        var timings: [FrameApplier.WriteTiming] = []
        let applier = FrameApplier(writer: writer) { t in lock.withLock { timings.append(t) } }
        applier.apply([FrameWrite(id: 1, pid: 9, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.reset()
        applier.apply([FrameWrite(id: 2, pid: 9, frame: rect(0))]) // the engine started again
        first.release.signal()
        #expect(applier.settleAndWait(timeout: 2))
        #expect(writer.frames(2) == [rect(0)])
        #expect(lock.withLock { timings }.count == 1, "only the write after the reset is measured")
        #expect(applier.appCount == 1, "the new apply made the app current again: it stays when idle")
    }

    // The pid-reuse tests below hold writes with gates. Where a test checks that something does NOT happen, it
    // waits a short time (`quiet`). A slow machine can only make such a check pass, never fail.
    private static let quiet = 0.3

    @Test func aDrainOfAForgottenAppDoesNotFinishTheCallsOfANewAppWithTheSamePid() {
        // App 10 is removed while its write runs. A new app gets pid 10 at once and its write is still running
        // when the old drain ends. The old drain must not mark the new app's frame as written.
        let writer = FakeWriter()
        let old = writer.gate(1), new = writer.gate(2)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(old.started.wait(timeout: .now() + 2) == .success)
        applier.forgetApp(10)
        let done = DispatchSemaphore(value: 0)
        applier.apply([FrameWrite(id: 2, pid: 10, frame: rect(0))]) { _ in done.signal() }
        #expect(new.started.wait(timeout: .now() + 2) == .success)
        old.release.signal() // the old drain ends while the new write runs
        #expect(done.wait(timeout: .now() + Self.quiet) == .timedOut, "the call finished before its frame was written")
        new.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(writer.frames(1) == [rect(0)])
        #expect(writer.frames(2) == [rect(0)])
    }

    @Test func aDrainOfAForgottenAppDoesNotTakeTheFramesOfANewAppWithTheSamePid() {
        // As above, but the new app has a frame waiting (W3) when the old drain ends. Only the new app's drain may
        // write it: one writer per app, and the call of W3 finishes after W3 is written.
        let writer = FakeWriter()
        let old = writer.gate(1), new = writer.gate(2), third = writer.gate(3)
        let applier = FrameApplier(writer: writer)
        applier.apply([FrameWrite(id: 1, pid: 10, frame: rect(0))])
        #expect(old.started.wait(timeout: .now() + 2) == .success)
        applier.forgetApp(10)
        applier.apply([FrameWrite(id: 2, pid: 10, frame: rect(0))])
        #expect(new.started.wait(timeout: .now() + 2) == .success)
        let done = DispatchSemaphore(value: 0)
        let early = Box<Bool>(false)
        applier.apply([FrameWrite(id: 3, pid: 10, frame: rect(0))]) { _ in // waits behind W2
            early.value = writer.frames(3).isEmpty
            done.signal()
        }
        old.release.signal()
        let stolen = third.started.wait(timeout: .now() + Self.quiet) == .success
        #expect(!stolen, "the old drain wrote a frame of the new app")
        new.release.signal()
        if !stolen { #expect(third.started.wait(timeout: .now() + 2) == .success) }
        third.release.signal()
        #expect(done.wait(timeout: .now() + 2) == .success)
        #expect(!early.value, "the call finished before its frame was written")
        #expect(writer.frames(3) == [rect(0)])
    }

    @Test func noTimingIsReportedForAnAppThatWasForgottenDuringItsBatch() {
        // removeApp forgets the app in the applier and then in the stats. A batch that was running must not add
        // the app to the stats again.
        let writer = FakeWriter()
        let first = writer.gate(1)
        let lock = NSLock()
        var timings: [FrameApplier.WriteTiming] = []
        let applier = FrameApplier(writer: writer) { t in lock.withLock { timings.append(t) } }
        applier.apply([FrameWrite(id: 1, pid: 9, frame: rect(0)), FrameWrite(id: 2, pid: 9, frame: rect(0))])
        #expect(first.started.wait(timeout: .now() + 2) == .success)
        applier.forgetApp(9)
        first.release.signal()
        #expect(writer.batchEnded.wait(timeout: .now() + 2) == .success)
        Thread.sleep(forTimeInterval: Self.quiet) // the drain records timings after the batch ends
        #expect(writer.writes.count == 2, "the batch that was running finished")
        #expect(lock.withLock { timings }.isEmpty)
        // A new app with the same pid is measured again.
        applier.applyAndWait([FrameWrite(id: 3, pid: 9, frame: rect(0))], timeout: 1)
        #expect(lock.withLock { timings }.map(\.pid) == [9])
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

    @Test func anAppWithSomeGoodWritesInEachBatchIsNotFailing() {
        // A closed window next to good ones: only a batch in which every write failed counts.
        let writer = FakeWriter(failing: [2])
        let applier = FrameApplier(writer: writer)
        for x in 0..<3 {
            applier.applyAndWait([FrameWrite(id: 1, pid: 11, frame: rect(CGFloat(x))), FrameWrite(id: 2, pid: 11, frame: rect(CGFloat(x)))])
        }
        #expect(applier.failingApps(threshold: 1).isEmpty)
    }

    @Test func oneGoodBatchStartsTheFailureCountAgain() {
        let writer = FakeWriter()
        writer.outcomes(1, [false, false, true, false])
        let applier = FrameApplier(writer: writer)
        for x in 0..<4 { applier.applyAndWait([FrameWrite(id: 1, pid: 11, frame: rect(CGFloat(x)))]) }
        #expect(applier.failingApps(threshold: 2).isEmpty, "fail, fail, ok, fail: only 1 in a row")
        #expect(applier.failingApps(threshold: 1) == [11])
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

/// What a completion got: nil until it ran, then the time it was given (itself nil for a dropped frame).
private final class TimeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double??
    func set(_ v: Double?) { lock.withLock { value = .some(v) } }
    func get() -> Double?? { lock.withLock { value } }
}

/// The performance budget from docs/SPEC.md. It measures wall-clock time, so it runs only with `make bench`
/// (STRIPLE_BENCH=1), not as a gate test. `appsAreWrittenInParallel` checks the parallel writes without a clock.
///
/// The fake AX write sleeps 2 ms, and `Thread.sleep` often sleeps longer, more so on a busy Mac. So the gate is
/// on the applier's own time: the wall time of a round minus its slowest write. The wall time, the serial time
/// (the sum of the writes) and the load average are printed for the README.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STRIPLE_BENCH"] != nil))
struct FrameApplierBenchmarkTests {
    private final class Writes: @unchecked Sendable {
        private let lock = NSLock()
        private var ms: [Double] = []
        func add(_ v: Double) { lock.withLock { ms.append(v) } }
        func take() -> [Double] { lock.withLock { defer { ms.removeAll() }; return ms } }
    }

    @Test func sixAppsAt2msEachUnderBudget() {
        let writer = FakeWriter(delay: 0.002)
        let writes = Writes()
        let applier = FrameApplier(writer: writer) { writes.add($0.axMs) }
        let ids = (1...6).map { WindowID($0) }
        _ = applier.applyAndWait(ids.map { FrameWrite(id: $0, pid: pid_t($0), frame: rect(-1)) }) // warm up the queues
        _ = writes.take()
        var wall: [Double] = [], overhead: [Double] = [], serial: [Double] = []
        for round in 0..<100 {
            let ms = applier.applyAndWait(ids.map { FrameWrite(id: $0, pid: pid_t($0), frame: rect(CGFloat(round * 10 + Int($0)))) })!
            // onWrite runs before the call's waiter, so the six writes of this round are in.
            let ax = writes.take()
            #expect(ax.count == ids.count)
            wall.append(ms)
            overhead.append(ms - (ax.max() ?? 0))
            serial.append(ax.reduce(0, +))
        }
        // Nearest rank, as `striple stats` does.
        func p(_ q: Double, _ v: [Double]) -> Double {
            let sorted = v.sorted()
            return sorted[max(Int((q / 100 * Double(sorted.count)).rounded(.up)) - 1, 0)]
        }
        var load = [0.0, 0.0, 0.0]
        _ = getloadavg(&load, 3)
        print(String(format: "Frame write, 6 apps x 2 ms AX latency, 100 rounds: p50 %.2f ms, p95 %.2f ms; applier overhead p95 %.2f ms; one after the other p50 %.2f ms; load average %.1f",
                     p(50, wall), p(95, wall), p(95, overhead), p(50, serial), load[0]))
        #expect(p(95, overhead) < 2, "applier overhead p95 \(p(95, overhead)) ms: over the 4 ms budget minus the 2 ms AX write")
    }
}
