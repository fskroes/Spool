import AppKit
import CoreVideo
import Foundation
import QuartzCore

/// What the engine needs of its frame clock. `Ticker` is the display link; tests use a fake.
@MainActor
protocol FrameTicker: AnyObject {
    var isRunning: Bool { get }
    /// The time in seconds until the next frame of the clock: the lead of an animation's first frame
    /// (`Engine.firstFrameLead(period:)`).
    var period: Double { get }
    func start()
    func stop()
}

/// Calls `onTick` once per display refresh while running. The engine stops it as soon as
/// everything has settled, so an idle strip costs nothing.
@MainActor
final class Ticker: NSObject, FrameTicker {
    private let onTick: (Double) -> Void
    private var link: AnyObject?
    private var cvLink: CVDisplayLink?
    private let cvPending = PendingFlag()

    init(onTick: @escaping (Double) -> Void) { self.onTick = onTick }

    private(set) var isRunning = false
    /// The display refresh period in seconds, for the lead of an animation's first frame
    /// (`Engine.firstFrameLead(period:)`). While the link runs, the period of its last refresh. While it is stopped
    /// (an animation from rest), the period of the screen that `start` gives the link: the display can be another one
    /// than in the last run.
    var period: Double { isRunning ? linkPeriod : Self.screenPeriod() }
    private var linkPeriod = 1.0 / 60
    /// Called from the second refresh of a run on: the time since the refresh before and the display period,
    /// both in ms. A run is from `start` to `stop`; the pause between two runs is not an interval.
    var onInterval: ((_ intervalMs: Double, _ periodMs: Double) -> Void)?
    private var lastStep: Double?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        lastStep = nil
        linkPeriod = Self.screenPeriod()
        if #available(macOS 14.0, *), let screen = NSScreen.main ?? NSScreen.screens.first {
            let l = screen.displayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
            return
        }
        startCVDisplayLink()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        lastStep = nil
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
        if let cvLink { CVDisplayLinkStop(cvLink) }
        cvLink = nil
    }

    @available(macOS 14.0, *)
    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        noteStep(now, periodMs: Self.periodMs(timestamp: link.timestamp, targetTimestamp: link.targetTimestamp,
                                              duration: link.duration))
        onTick(now)
    }

    /// The shortest refresh period of the screen the link runs on (8.3 ms on a 120 Hz ProMotion panel).
    static func screenPeriod() -> Double {
        (NSScreen.main ?? NSScreen.screens.first)?.minimumRefreshInterval ?? Engine.defaultFramePeriod
    }

    private func noteStep(_ now: Double, periodMs: Double) {
        if periodMs.isFinite, periodMs > 0 { linkPeriod = periodMs / 1000 }
        if let last = lastStep, let onInterval {
            onInterval((now - last) * 1000, periodMs)
        }
        lastStep = now
    }

    /// macOS 13: CVDisplayLink calls back on its own thread. Hop to main, and drop a tick if the last one is
    /// still waiting, so ticks never pile up.
    private func startCVDisplayLink() {
        var l: CVDisplayLink?
        guard CVDisplayLinkCreateWithActiveCGDisplays(&l) == kCVReturnSuccess, let l else {
            isRunning = false
            return
        }
        let me = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(l, { _, _, _, _, _, user in
            guard let user else { return kCVReturnSuccess }
            let ticker = Unmanaged<Ticker>.fromOpaque(user).takeUnretainedValue()
            guard ticker.cvPending.trySet() else { return kCVReturnSuccess }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ticker.cvPending.clear()
                    guard ticker.isRunning, let link = ticker.cvLink else { return }
                    let now = CACurrentMediaTime()
                    let p = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(link)
                    ticker.noteStep(now, periodMs: Ticker.periodMs(timeValue: p.timeValue, timeScale: p.timeScale,
                                                                   indefinite: p.flags & Int32(CVTimeFlags.isIndefinite.rawValue) != 0))
                    ticker.onTick(now)
                }
            }
            return kCVReturnSuccess
        }, me)
        CVDisplayLinkStart(l)
        cvLink = l
    }
}

private final class PendingFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    /// Sets the flag. False if it was already set.
    func trySet() -> Bool { lock.withLock { if value { return false }; value = true; return true } }
    func clear() { lock.withLock { value = false } }
}
