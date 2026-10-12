import ApplicationServices
import CoreGraphics
import Dispatch
import Foundation
import StripleCore

/// One window frame to write, in AX coordinates.
public struct FrameWrite: Equatable, Sendable {
    public var id: WindowID
    public var pid: pid_t
    public var frame: CGRect

    public init(id: WindowID, pid: pid_t, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.frame = frame
    }
}

/// Writes frames to real windows. The live version talks to AX; tests use a fake with a fixed delay.
/// Called on a per-app serial queue, never on the main thread.
public protocol FrameWriter: AnyObject, Sendable {
    /// Called once before a batch of writes to one app, and once after it.
    func beginBatch(pid: pid_t)
    func endBatch(pid: pid_t)
    /// Called when an animation has settled, after the app's last write.
    func settle(pid: pid_t)
    /// `previous` is the last frame Striple wrote to this window, nil if none. Return false on an AX error.
    func write(_ write: FrameWrite, previous: CGRect?) -> Bool
}

public extension FrameWriter {
    func beginBatch(pid: pid_t) {}
    func endBatch(pid: pid_t) {}
    func settle(pid: pid_t) {}
}

/// Sends frames to windows as fast as the apps allow.
///
/// - Apps answer AX calls one at a time, but different apps answer in parallel. So each app gets its own
///   serial queue and a tick costs the slowest app, not the sum of all apps.
/// - A frame equal to the last written frame is skipped.
/// - When an app is still busy with the previous tick, the new frames wait and replace each other:
///   only the newest frame is written. A slow app never builds a queue of old frames.
public final class FrameApplier: @unchecked Sendable {
    public struct Counters: Equatable, Sendable {
        public var windowWrites = 0
        public var skipped = 0
        public var coalesced = 0
        public var errors = 0
    }

    /// One window write, for the timing stats.
    public struct WriteTiming: Equatable, Sendable {
        public var pid: pid_t
        /// The time of the AX calls for this window.
        public var axMs: Double
        /// From the `apply` call that queued this frame until it was written: the wait for the app plus `axMs`.
        public var latencyMs: Double
    }

    private struct Pending {
        var write: FrameWrite
        var queuedAt: UInt64
    }

    private struct AppState {
        let queue: DispatchQueue
        /// Unique per state. A drain of a removed app can still run when a new app gets the same pid; it compares
        /// the generation and then does not touch the new app's state.
        let generation: UInt64
        var busy = false
        var pending: [WindowID: Pending] = [:]
        var pendingOrder: [WindowID] = []
        /// Each `apply` that queues a frame for this app increases `queued`. A batch takes every pending frame,
        /// so when it is written, `landed` becomes the `queued` value at the time it was taken.
        var queued: UInt64 = 0
        var landed: UInt64 = 0
        /// Run when `landed` reaches the number.
        var waiters: [(upTo: UInt64, run: @Sendable () -> Void)] = []
        /// Batches in a row in which every write failed. One success sets it to 0.
        var failedBatches = 0
    }

    private let writer: FrameWriter
    private let onWrite: (@Sendable (WriteTiming) -> Void)?
    private let lock = NSLock()
    private var apps: [pid_t: AppState] = [:]
    private var written: [WindowID: CGRect] = [:]
    /// Frames taken out of `pending` that the app's queue is writing now.
    private var inFlight: [WindowID: CGRect] = [:]
    private var counters = Counters()
    private var nextGeneration: UInt64 = 0

    /// `onWrite` runs on the app's queue at the end of each batch, once per window write, and only while the app
    /// is not forgotten. It runs with the applier's lock held: it must not call the applier.
    public init(writer: FrameWriter, onWrite: (@Sendable (WriteTiming) -> Void)? = nil) {
        self.writer = writer
        self.onWrite = onWrite
    }

    public var stats: Counters { lock.withLock { counters } }

    /// The last frame written to a window (what macOS has, as far as Striple knows).
    public func lastWritten(_ id: WindowID) -> CGRect? { lock.withLock { written[id] } }

    /// True when `frame` is one that Striple wrote or will write to the window, or the window is being written
    /// now (AX sets position and size one after the other, so a frame read meanwhile can be half of each).
    /// A move notification with such a frame is Striple's own write arriving, not the user.
    public func isOwnFrame(_ id: WindowID, _ frame: CGRect, tolerance: CGFloat = 2) -> Bool {
        lock.withLock {
            if inFlight[id] != nil { return true }
            let pending = apps.values.lazy.compactMap { $0.pending[id]?.write.frame }.first
            return [written[id], inFlight[id], pending].contains { Policy.same(frame, $0, tolerance: tolerance) }
        }
    }

    /// Forget a window, for example after it closed or the user moved it by hand.
    public func forget(_ id: WindowID) {
        lock.withLock {
            written.removeValue(forKey: id)
            inFlight.removeValue(forKey: id)
        }
    }

    public func forgetApp(_ pid: pid_t) {
        let waiters = lock.withLock { apps.removeValue(forKey: pid)?.waiters ?? [] }
        for w in waiters { w.run() }
    }

    /// Apps whose last `threshold` batches all failed: their AX elements or observer are probably dead.
    public func failingApps(threshold: Int) -> [pid_t] {
        lock.withLock { apps.filter { $0.value.failedBatches >= threshold }.map(\.key).sorted() }
    }

    public func clearFailures(_ pid: pid_t) { lock.withLock { apps[pid]?.failedBatches = 0 } }

    /// Tells every app (or only `pids`) that the animation is over, after its last write. Returns at once.
    public func settle(pids: Set<pid_t>? = nil, completion: (@Sendable () -> Void)? = nil) {
        let group = DispatchGroup()
        let queues = lock.withLock { apps.filter { pids?.contains($0.key) ?? true }.map { ($0.key, $0.value.queue) } }
        for (pid, queue) in queues {
            group.enter()
            queue.async { [writer] in
                writer.settle(pid: pid)
                group.leave()
            }
        }
        if let completion { group.notify(queue: .global(qos: .userInteractive), execute: completion) }
    }

    /// Like `settle`, but waits. Returns false on timeout.
    @discardableResult
    public func settleAndWait(timeout: Double, pids: Set<pid_t>? = nil) -> Bool {
        let done = DispatchSemaphore(value: 0)
        settle(pids: pids) { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    public func reset() {
        lock.withLock {
            written.removeAll()
            inFlight.removeAll()
            for pid in apps.keys {
                apps[pid]?.pending.removeAll()
                apps[pid]?.pendingOrder.removeAll()
            }
        }
    }

    /// Queues the writes and returns at once. `completion` runs on an unspecified queue when every frame of this
    /// call is written, or replaced by a newer frame that is written, with the wall time in milliseconds.
    /// A frame merged into an app that was already busy is waited for too, but frames of later calls are not.
    public func apply(_ writes: [FrameWrite], completion: (@Sendable (Double) -> Void)? = nil) {
        let start = DispatchTime.now().uptimeNanoseconds
        let group = DispatchGroup()
        var toStart: [(pid_t, DispatchQueue, UInt64)] = []
        lock.withLock {
            var queuedFor = Set<pid_t>()
            var waitFor = Set<pid_t>()
            for w in writes {
                let pendingSame = apps[w.pid]?.pending[w.id]
                // Compare with the newest frame the window will have: the one in flight, else the written one.
                // A frame equal to an older written frame must still be written after the one in flight.
                if pendingSame == nil, (inFlight[w.id] ?? written[w.id]) == w.frame {
                    counters.skipped += 1
                    // Already being written: callers that wait must wait for it to land.
                    if inFlight[w.id] != nil { waitFor.insert(w.pid) }
                    continue
                }
                if apps[w.pid] == nil {
                    nextGeneration += 1
                    apps[w.pid] = AppState(queue: DispatchQueue(label: "striple.ax.\(w.pid)", qos: .userInteractive),
                                           generation: nextGeneration)
                }
                if apps[w.pid]!.pending.updateValue(Pending(write: w, queuedAt: start), forKey: w.id) == nil {
                    apps[w.pid]!.pendingOrder.append(w.id)
                } else {
                    counters.coalesced += 1
                }
                queuedFor.insert(w.pid)
            }
            for pid in queuedFor { apps[pid]!.queued += 1 }
            for (pid, state) in apps where !state.busy && !state.pending.isEmpty {
                apps[pid]!.busy = true
                toStart.append((pid, state.queue, state.generation))
            }
            guard completion != nil else { return }
            // A frame in flight belongs to a batch taken at or before the current `queued`, so waiting for
            // `queued` covers it.
            for pid in queuedFor.union(waitFor) {
                guard let state = apps[pid], state.landed < state.queued else { continue }
                group.enter()
                apps[pid]!.waiters.append((state.queued, { group.leave() }))
            }
        }
        for (pid, queue, generation) in toStart {
            queue.async { [self] in drain(pid, generation) }
        }
        guard let completion else { return }
        group.notify(queue: .global(qos: .userInteractive)) {
            completion(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
    }

    /// Like `apply`, but waits. Returns the wall time in milliseconds, or nil after `timeout` seconds
    /// (an app that does not answer). Not for the main thread in a live tick.
    @discardableResult
    public func applyAndWait(_ writes: [FrameWrite], timeout: Double = .infinity) -> Double? {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        apply(writes) { ms in box.value = ms; done.signal() }
        if timeout.isFinite {
            guard done.wait(timeout: .now() + timeout) == .success else { return nil }
        } else {
            done.wait()
        }
        return box.value
    }

    private final class Box: @unchecked Sendable { var value = 0.0 }

    /// Runs on the app's queue. Writes everything pending, then anything that arrived meanwhile.
    /// Stops touching the app's state when `forgetApp` removed it (its waiters ran there already).
    private func drain(_ pid: pid_t, _ generation: UInt64) {
        while true {
            var idle: [@Sendable () -> Void] = []
            let taken: (batch: [(Pending, CGRect?)], upTo: UInt64)? = lock.withLock {
                guard var state = apps[pid], state.generation == generation, !state.pending.isEmpty else {
                    // Nothing left: everything queued is written or was dropped by `reset`.
                    if let state = apps[pid], state.generation == generation {
                        apps[pid]!.busy = false
                        apps[pid]!.landed = state.queued
                        idle = state.waiters.map(\.run)
                        apps[pid]!.waiters.removeAll()
                    }
                    return nil
                }
                let items = state.pendingOrder.compactMap { id in state.pending[id].map { ($0, written[id]) } }
                for (p, _) in items { inFlight[p.write.id] = p.write.frame }
                state.pending.removeAll(keepingCapacity: true)
                state.pendingOrder.removeAll(keepingCapacity: true)
                apps[pid] = state
                return (items, state.queued)
            }
            guard let (batch, upTo) = taken else {
                for run in idle { run() }
                return
            }
            writer.beginBatch(pid: pid)
            var results: [(WindowID, CGRect, Bool)] = []
            var timings: [WriteTiming] = []
            results.reserveCapacity(batch.count)
            for (p, previous) in batch {
                let before = DispatchTime.now().uptimeNanoseconds
                let ok = writer.write(p.write, previous: previous)
                let after = DispatchTime.now().uptimeNanoseconds
                results.append((p.write.id, p.write.frame, ok))
                timings.append(WriteTiming(pid: pid, axMs: Double(after - before) / 1_000_000,
                                           latencyMs: Double(after - p.queuedAt) / 1_000_000))
            }
            writer.endBatch(pid: pid)
            let done: [@Sendable () -> Void] = lock.withLock {
                for (id, frame, ok) in results {
                    inFlight.removeValue(forKey: id)
                    counters.windowWrites += 1
                    if ok { written[id] = frame } else { counters.errors += 1; written.removeValue(forKey: id) }
                }
                guard apps[pid]?.generation == generation else { return [] }
                if let onWrite { timings.forEach(onWrite) }
                if results.contains(where: \.2) { apps[pid]!.failedBatches = 0 } else { apps[pid]!.failedBatches += 1 }
                apps[pid]!.landed = max(apps[pid]!.landed, upTo)
                let landed = apps[pid]!.landed
                let ready = apps[pid]!.waiters.filter { $0.upTo <= landed }.map(\.run)
                apps[pid]!.waiters.removeAll { $0.upTo <= landed }
                return ready
            }
            for run in done { run() }
        }
    }
}

/// Writes frames with AX. Holds the AX element of every managed window.
final class AXFrameWriter: FrameWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var elements: [WindowID: AXUIElement] = [:]
    private var appElements: [pid_t: AXUIElement] = [:]
    private var enhancedUI: [pid_t: Bool] = [:]

    func register(_ id: WindowID, element: AXUIElement, pid: pid_t) {
        lock.withLock {
            elements[id] = element
            if appElements[pid] == nil { appElements[pid] = AX.app(pid) }
        }
    }

    func unregister(_ id: WindowID) { lock.withLock { _ = elements.removeValue(forKey: id) } }

    func unregisterApp(_ pid: pid_t) {
        lock.withLock {
            appElements.removeValue(forKey: pid)
            enhancedUI.removeValue(forKey: pid)
        }
    }

    /// Some apps (Chrome, Electron, Office) animate every AX move while AXEnhancedUserInterface is on, which makes
    /// tiling slow and wobbly. Turn it off at the first batch of an animation and back on when it settles: one
    /// read and two writes per app per animation, not per frame.
    func beginBatch(pid: pid_t) {
        guard let app = lock.withLock({ enhancedUI[pid] == nil ? appElements[pid] : nil }) else { return }
        let on = AX.bool(app, "AXEnhancedUserInterface") == true
        if on { AX.set(app, "AXEnhancedUserInterface", false) }
        lock.withLock { enhancedUI[pid] = on }
    }

    func settle(pid: pid_t) {
        let restore = lock.withLock { enhancedUI.removeValue(forKey: pid) ?? false }
        guard restore, let app = lock.withLock({ appElements[pid] }) else { return }
        AX.set(app, "AXEnhancedUserInterface", true)
    }

    func write(_ w: FrameWrite, previous: CGRect?) -> Bool {
        guard let e = lock.withLock({ elements[w.id] }) else { return false }
        let sizeChanged = previous.map { $0.size != w.frame.size } ?? true
        let originChanged = previous.map { $0.origin != w.frame.origin } ?? true
        var results: [AXError] = []
        // Size, position, size: the first size keeps a large window from being pushed back by the display edge
        // when it moves; the last one applies the size the app may have refused at the old position.
        if sizeChanged { results.append(AX.setSize(e, w.frame.size)) }
        if originChanged { results.append(AX.setPosition(e, w.frame.origin)) }
        if sizeChanged && originChanged { AX.setSize(e, w.frame.size) }
        return Policy.frameWriteWorked(results)
    }
}
