import AppKit
import CoreGraphics
import Foundation
import StripleCore

/// Turns touch samples into a horizontal swipe. Pure, so it is tested without a trackpad.
///
/// A swipe starts when exactly `fingers` touches are down and they moved more horizontally than vertically
/// past a small dead zone. It ends when the finger count changes. Positions are normalised trackpad
/// coordinates (0...1); the delta is in trackpad widths.
struct SwipeTracker {
    enum Event: Equatable {
        case began
        /// Horizontal movement since the last event, in trackpad widths. Positive is to the right.
        case changed(dx: Double)
        /// Velocity in trackpad widths per second at release.
        case ended(velocity: Double)
    }

    var fingers: Int
    var deadZone = 0.015

    private var start: CGPoint?
    private var last: CGPoint?
    private var active = false
    private var rejected = false
    private var samples: [(t: Double, x: Double)] = []

    init(fingers: Int) { self.fingers = fingers }

    var isActive: Bool { active }

    mutating func feed(touches: Int, average: CGPoint, time: Double) -> Event? {
        guard touches == fingers else { return finish(time: time) }
        if rejected { return nil }
        guard let s = start, let l = last else {
            start = average
            last = average
            samples = [(time, Double(average.x))]
            return nil
        }
        if !active {
            let dx = Double(average.x - s.x), dy = Double(average.y - s.y)
            guard abs(dx) > deadZone, abs(dx) > abs(dy) else {
                // Mostly vertical: not ours (Mission Control, App Exposé). Give up for this touch sequence.
                if abs(dy) > deadZone * 2 { rejected = true }
                return nil
            }
            active = true
            last = average
            record(time, Double(average.x))
            return .began
        }
        let dx = Double(average.x - l.x)
        last = average
        record(time, Double(average.x))
        return dx == 0 ? nil : .changed(dx: dx)
    }

    mutating func cancel() {
        start = nil
        last = nil
        active = false
        rejected = false
        samples.removeAll()
    }

    private mutating func finish(time: Double) -> Event? {
        defer { cancel() }
        guard active else { return nil }
        return .ended(velocity: velocity())
    }

    private mutating func record(_ t: Double, _ x: Double) {
        samples.append((t, x))
        // The last 80 ms decide the release velocity.
        while let first = samples.first, t - first.t > 0.08, samples.count > 2 { samples.removeFirst() }
    }

    private func velocity() -> Double {
        guard let a = samples.first, let b = samples.last, b.t - a.t > 0.001 else { return 0 }
        return (b.x - a.x) / (b.t - a.t)
    }
}

/// Reads trackpad touches with a listen-only event tap on gesture events. It never blocks or changes events.
@MainActor
final class GestureTap {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker: SwipeTracker
    private let onEvent: (SwipeTracker.Event) -> Void
    private let log: (String) -> Void

    init(fingers: Int, onEvent: @escaping (SwipeTracker.Event) -> Void, log: @escaping (String) -> Void) {
        tracker = SwipeTracker(fingers: fingers)
        self.onEvent = onEvent
        self.log = log
    }

    var fingers: Int {
        get { tracker.fingers }
        set { tracker.fingers = newValue; tracker.cancel() }
    }

    var isRunning: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() -> Bool {
        guard tap == nil else { return true }
        let gestureMask: CGEventMask = 1 << 29 // NSEvent.EventType.gesture
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                           eventsOfInterest: gestureMask, callback: { _, type, event, user in
            guard let user else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<GestureTap>.fromOpaque(user).takeUnretainedValue()
            MainActor.assumeIsolated { me.handle(type: type, event: event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else {
            log("gesture tap: could not create the event tap")
            return false
        }
        tap = port
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        tracker.cancel()
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Self-healing: macOS turns a tap off when a callback is slow. Turn it back on and say so.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            log("gesture tap: macOS disabled the tap (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), enabled it again")
            return
        }
        guard let ns = NSEvent(cgEvent: event), ns.type == .gesture else { return }
        let touches = ns.allTouches().filter { $0.phase != .ended && $0.phase != .cancelled && !$0.isResting }
        var sum = CGPoint.zero
        for t in touches { sum.x += t.normalizedPosition.x; sum.y += t.normalizedPosition.y }
        let n = CGFloat(max(touches.count, 1))
        if let e = tracker.feed(touches: touches.count, average: CGPoint(x: sum.x / n, y: sum.y / n), time: ns.timestamp) {
            onEvent(e)
        }
    }
}
