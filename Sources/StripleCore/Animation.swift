import CoreGraphics
import Foundation

/// A critically damped spring that is solved in closed form, so the result
/// does not depend on the frame rate or on dropped frames.
public struct Spring: Equatable, Sendable {
    public var target: Double
    var start: Double
    var startVelocity: Double
    var startTime: Double
    public var omega: Double

    /// - Parameter response: time in seconds for one natural period (SwiftUI's `response`).
    public init(value: Double, response: Double) {
        target = value
        start = value
        startVelocity = 0
        startTime = 0
        omega = 2 * Double.pi / max(response, 0.01)
    }

    public func value(at t: Double) -> Double {
        let dt = max(t - startTime, 0)
        let d0 = start - target
        return target + (d0 + (startVelocity + omega * d0) * dt) * exp(-omega * dt)
    }

    public func velocity(at t: Double) -> Double {
        let dt = max(t - startTime, 0)
        let d0 = start - target
        return (startVelocity - omega * (startVelocity + omega * d0) * dt) * exp(-omega * dt)
    }

    /// Changes the target and keeps the current position and velocity, so motion stays smooth.
    public mutating func retarget(_ newTarget: Double, at t: Double, velocity: Double? = nil) {
        let x = value(at: t)
        let v = velocity ?? self.velocity(at: t)
        start = x
        startVelocity = v
        startTime = t
        target = newTarget
    }

    /// Jumps to a value with no motion.
    public mutating func snap(_ v: Double, at t: Double) {
        target = v; start = v; startVelocity = 0; startTime = t
    }

    public func isSettled(at t: Double, tolerance: Double = 0.5) -> Bool {
        abs(value(at: t) - target) < tolerance && abs(velocity(at: t)) < tolerance * 20
    }
}

/// Animates the frames of many windows toward their targets.
/// Time is passed in, so the animator is deterministic and testable.
public struct FrameAnimator: Sendable {
    struct Entry: Sendable {
        var x, y, w, h: Spring
        var target: CGRect { CGRect(x: x.target, y: y.target, width: w.target, height: h.target) }
    }

    private var entries: [WindowID: Entry] = [:]
    /// Set it with `setResponse`, so windows that are on screen change speed too.
    public private(set) var response: Double
    public var enabled: Bool

    public init(response: Double = 0.22, enabled: Bool = true) {
        self.response = response
        self.enabled = enabled
    }

    public var windowIDs: [WindowID] { Array(entries.keys) }

    /// Changes the speed of every window, also of motion in progress. Each spring continues from its position
    /// and velocity at `t`, so nothing jumps.
    public mutating func setResponse(_ newResponse: Double, at t: Double) {
        response = newResponse
        let omega = Spring(value: 0, response: newResponse).omega
        for id in entries.keys {
            guard var e = entries[id] else { continue }
            for path in [\Entry.x, \Entry.y, \Entry.w, \Entry.h] as [WritableKeyPath<Entry, Spring>] {
                e[keyPath: path].retarget(e[keyPath: path].target, at: t)
                e[keyPath: path].omega = omega
            }
            entries[id] = e
        }
    }

    /// Sets new targets.
    /// - Parameters:
    ///   - animate: false makes windows jump (used while a swipe follows the fingers).
    ///   - velocityX: start velocity in points per second for the x axis (release of a swipe).
    public mutating func setTargets(_ targets: [WindowID: CGRect], at t: Double, animate: Bool, velocityX: Double? = nil) {
        for id in entries.keys where targets[id] == nil { entries[id] = nil }
        for (id, r) in targets {
            if var e = entries[id], animate && enabled {
                if e.target != r || velocityX != nil {
                    e.x.retarget(Double(r.minX), at: t, velocity: velocityX)
                    e.y.retarget(Double(r.minY), at: t)
                    e.w.retarget(Double(r.width), at: t)
                    e.h.retarget(Double(r.height), at: t)
                    entries[id] = e
                }
            } else if var e = entries[id] {
                e.x.snap(Double(r.minX), at: t); e.y.snap(Double(r.minY), at: t)
                e.w.snap(Double(r.width), at: t); e.h.snap(Double(r.height), at: t)
                entries[id] = e
            } else {
                entries[id] = Entry(x: Spring(value: Double(r.minX), response: response),
                                    y: Spring(value: Double(r.minY), response: response),
                                    w: Spring(value: Double(r.width), response: response),
                                    h: Spring(value: Double(r.height), response: response))
                entries[id]!.x.startTime = t; entries[id]!.y.startTime = t
                entries[id]!.w.startTime = t; entries[id]!.h.startTime = t
            }
        }
    }

    /// Starts a window's animation from a given frame (for example its current frame on screen).
    public mutating func setCurrent(_ id: WindowID, frame r: CGRect, at t: Double) {
        guard var e = entries[id] else { return }
        let target = e.target
        e.x.snap(Double(r.minX), at: t); e.y.snap(Double(r.minY), at: t)
        e.w.snap(Double(r.width), at: t); e.h.snap(Double(r.height), at: t)
        e.x.retarget(Double(target.minX), at: t); e.y.retarget(Double(target.minY), at: t)
        e.w.retarget(Double(target.width), at: t); e.h.retarget(Double(target.height), at: t)
        entries[id] = e
    }

    public func frame(_ id: WindowID, at t: Double) -> CGRect? {
        guard let e = entries[id] else { return nil }
        if isSettled(e, t) { return e.target }
        return CGRect(x: e.x.value(at: t), y: e.y.value(at: t), width: e.w.value(at: t), height: e.h.value(at: t))
    }

    public func frames(at t: Double) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        out.reserveCapacity(entries.count)
        for id in entries.keys { out[id] = frame(id, at: t) }
        return out
    }

    public func target(_ id: WindowID) -> CGRect? { entries[id]?.target }

    private func isSettled(_ e: Entry, _ t: Double) -> Bool {
        e.x.isSettled(at: t) && e.y.isSettled(at: t) && e.w.isSettled(at: t) && e.h.isSettled(at: t)
    }

    /// True when no window moves any more. The display link stops then.
    public func isSettled(at t: Double) -> Bool { entries.values.allSatisfy { isSettled($0, t) } }
}
