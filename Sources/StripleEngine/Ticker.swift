import AppKit
import CoreVideo
import Foundation
import QuartzCore

/// Calls `onTick` once per display refresh while running. The engine stops it as soon as
/// everything has settled, so an idle strip costs nothing.
@MainActor
final class Ticker: NSObject {
    private let onTick: (Double) -> Void
    private var link: AnyObject?
    private var cvLink: CVDisplayLink?
    private let cvPending = PendingFlag()

    init(onTick: @escaping (Double) -> Void) { self.onTick = onTick }

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
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
        if #available(macOS 14.0, *), let l = link as? CADisplayLink { l.invalidate() }
        link = nil
        if let cvLink { CVDisplayLinkStop(cvLink) }
        cvLink = nil
    }

    @available(macOS 14.0, *)
    @objc private func step(_ link: CADisplayLink) {
        onTick(CACurrentMediaTime())
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
                    if ticker.isRunning { ticker.onTick(CACurrentMediaTime()) }
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
