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
    /// `previous` is the last frame Striple wrote to this window, nil if none. Return false on an AX error.
    func write(_ write: FrameWrite, previous: CGRect?) -> Bool
}

public extension FrameWriter {
    func beginBatch(pid: pid_t) {}
    func endBatch(pid: pid_t) {}
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

    private struct AppState {
        let queue: DispatchQueue
        var busy = false
        var pending: [WindowID: FrameWrite] = [:]
        var pendingOrder: [WindowID] = []
    }

    private let writer: FrameWriter
    private let lock = NSLock()
    private var apps: [pid_t: AppState] = [:]
    private var written: [WindowID: CGRect] = [:]
    private var counters = Counters()

    public init(writer: FrameWriter) { self.writer = writer }

    public var stats: Counters { lock.withLock { counters } }

    /// The last frame written to a window (what macOS has, as far as Striple knows).
    public func lastWritten(_ id: WindowID) -> CGRect? { lock.withLock { written[id] } }

    /// Forget a window, for example after it closed or the user moved it by hand.
    public func forget(_ id: WindowID) { lock.withLock { _ = written.removeValue(forKey: id) } }

    public func forgetApp(_ pid: pid_t) { lock.withLock { _ = apps.removeValue(forKey: pid) } }

    public func reset() {
        lock.withLock {
            written.removeAll()
            for pid in apps.keys {
                apps[pid]?.pending.removeAll()
                apps[pid]?.pendingOrder.removeAll()
            }
        }
    }

    /// Queues the writes and returns at once. `completion` runs on an unspecified queue when every batch
    /// started by this call is done, with the wall time in milliseconds. Writes merged into a batch that was
    /// already running count toward that batch.
    public func apply(_ writes: [FrameWrite], completion: (@Sendable (Double) -> Void)? = nil) {
        let start = DispatchTime.now().uptimeNanoseconds
        let group = DispatchGroup()
        var toStart: [(pid_t, DispatchQueue)] = []
        lock.withLock {
            for w in writes {
                let pendingSame = apps[w.pid]?.pending[w.id]
                if pendingSame == nil, written[w.id] == w.frame { counters.skipped += 1; continue }
                if apps[w.pid] == nil {
                    apps[w.pid] = AppState(queue: DispatchQueue(label: "striple.ax.\(w.pid)", qos: .userInteractive))
                }
                if apps[w.pid]!.pending.updateValue(w, forKey: w.id) == nil {
                    apps[w.pid]!.pendingOrder.append(w.id)
                } else {
                    counters.coalesced += 1
                }
            }
            for (pid, state) in apps where !state.busy && !state.pending.isEmpty {
                apps[pid]!.busy = true
                toStart.append((pid, state.queue))
            }
        }
        for (pid, queue) in toStart {
            group.enter()
            queue.async { [self] in
                drain(pid)
                group.leave()
            }
        }
        guard let completion else { return }
        group.notify(queue: .global(qos: .userInteractive)) {
            completion(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
    }

    /// Like `apply`, but waits. Returns the wall time in milliseconds. Not for the main thread in a live tick.
    @discardableResult
    public func applyAndWait(_ writes: [FrameWrite]) -> Double {
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        apply(writes) { ms in box.value = ms; done.signal() }
        done.wait()
        return box.value
    }

    private final class Box: @unchecked Sendable { var value = 0.0 }

    /// Runs on the app's queue. Writes everything pending, then anything that arrived meanwhile.
    private func drain(_ pid: pid_t) {
        while true {
            let batch: [(FrameWrite, CGRect?)] = lock.withLock {
                guard var state = apps[pid], !state.pending.isEmpty else {
                    apps[pid]?.busy = false
                    return []
                }
                let items = state.pendingOrder.compactMap { id in state.pending[id].map { ($0, written[id]) } }
                state.pending.removeAll(keepingCapacity: true)
                state.pendingOrder.removeAll(keepingCapacity: true)
                apps[pid] = state
                return items
            }
            if batch.isEmpty { return }
            writer.beginBatch(pid: pid)
            var results: [(WindowID, CGRect, Bool)] = []
            results.reserveCapacity(batch.count)
            for (w, previous) in batch {
                results.append((w.id, w.frame, writer.write(w, previous: previous)))
            }
            writer.endBatch(pid: pid)
            lock.withLock {
                for (id, frame, ok) in results {
                    counters.windowWrites += 1
                    if ok { written[id] = frame } else { counters.errors += 1; written.removeValue(forKey: id) }
                }
            }
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
    /// tiling slow and wobbly. Turn it off during the batch and back on after.
    func beginBatch(pid: pid_t) {
        guard let app = lock.withLock({ appElements[pid] }) else { return }
        if AX.bool(app, "AXEnhancedUserInterface") == true {
            AX.set(app, "AXEnhancedUserInterface", false)
            lock.withLock { enhancedUI[pid] = true }
        }
    }

    func endBatch(pid: pid_t) {
        let restore = lock.withLock { enhancedUI.removeValue(forKey: pid) ?? false }
        guard restore, let app = lock.withLock({ appElements[pid] }) else { return }
        AX.set(app, "AXEnhancedUserInterface", true)
    }

    func write(_ w: FrameWrite, previous: CGRect?) -> Bool {
        guard let e = lock.withLock({ elements[w.id] }) else { return false }
        let sizeChanged = previous.map { $0.size != w.frame.size } ?? true
        let originChanged = previous.map { $0.origin != w.frame.origin } ?? true
        var ok = true
        // Size, position, size: the first size keeps a large window from being pushed back by the display edge
        // when it moves; the last one applies the size the app may have refused at the old position.
        if sizeChanged { ok = AX.setSize(e, w.frame.size) == .success && ok }
        if originChanged { ok = AX.setPosition(e, w.frame.origin) == .success && ok }
        if sizeChanged && originChanged { AX.setSize(e, w.frame.size) }
        return ok
    }
}
