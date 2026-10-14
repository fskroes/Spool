import AppKit
import ApplicationServices
import Foundation
import QuartzCore
import StripleCore

extension Engine {
    // MARK: Layout pass

    /// Computes the strip's target frames and starts the animation toward them.
    /// `from`: windows that are not where the animator has them (a window the user just dropped). Their springs
    /// start there, before the first frame is written: a frame at the animator's old value would show the window
    /// in its old slot for one frame.
    func relayout(_ key: StripKey, animate: Bool = true, velocityX: Double? = nil, from current: [WindowID: CGRect] = [:]) {
        guard isActive(key), let d = display(key.display) else { return }
        guard let strip = strips[key], !strip.isEmpty else {
            animators[key] = nil
            layouts[key] = nil
            columnCounts.forget(key)
            return
        }
        let result = Layout.compute(strip, display: d.geometry, settings: config.layout)
        layouts[key] = result
        if let store = metricsStore, store.isEnabled, columnCounts.changed(key, to: strip.columns.count) {
            store.recordColumns(strip.columns.count)
        }
        if Self.targetsChange(animators[key], to: result.frames) { targetChanges &+= 1 }
        var anim = animators[key] ?? FrameAnimator(response: config.animation.response, enabled: config.animation.enabled)
        let now = CACurrentMediaTime()
        let lead = Self.animationLead(period: ticker?.period ?? Self.defaultFramePeriod,
                                      linkRunning: ticker?.isRunning == true)
        let start = Self.animationStart(now: now, velocityX: velocityX, lead: lead, settled: { anim.isSettled(at: $0) })
        Self.retarget(&anim, to: result.frames, at: start, animate: animate, velocityX: velocityX, from: current)
        animators[key] = anim
        kick(now)
    }

    /// Sets the new targets, then starts the windows in `current` from the frame they have on screen.
    /// Animations off (or `animate` false): the windows go straight to their targets, so `current` does not apply.
    nonisolated static func retarget(_ anim: inout FrameAnimator, to targets: [WindowID: CGRect], at start: Double,
                                     animate: Bool, velocityX: Double?, from current: [WindowID: CGRect]) {
        anim.setTargets(targets, at: start, animate: animate, velocityX: velocityX)
        guard animate, anim.enabled else { return }
        for (id, frame) in current where targets[id] != nil { anim.setCurrent(id, frame: frame, at: start) }
    }

    /// The display period when the ticker does not know it: 60 Hz.
    nonisolated static let defaultFramePeriod = 1.0 / 60

    /// How far back an animation from rest starts: one display refresh period. So the kick tick (dt = this lead)
    /// already moves the windows by one frame of motion, and a command's first frame is written in the key handler,
    /// not on the next display refresh. The display link then continues one period later, so the steps from rest
    /// grow from the first one on. A fixed 1/60 s lead on a 240 Hz display made the kick step four refreshes of
    /// motion, larger than the steps after it (a jump, then a slow down).
    /// Clamped to 1/240 ... 1/30 s; a period that is not a positive number gives 1/60 s.
    nonisolated static func firstFrameLead(period: Double) -> Double {
        guard period.isFinite, period > 0 else { return defaultFramePeriod }
        return min(max(period, 1.0 / 240), 1.0 / 30)
    }

    /// The start time of the springs that `relayout` sets. From rest, `now - lead` (`firstFrameLead`). During an
    /// animation, `now`: the springs continue from where they are, so nothing jumps. After a swipe (`velocityX`),
    /// `now`: the release speed applies from the moment of the release.
    /// "At rest" is checked at the early start time, not at `now`: an animation that settled less than one lead ago
    /// is not settled at the early start, so the retarget would read its held size and position from before the last
    /// frame on screen (a shrink would flash back to its old width). Such a strip starts at `now`.
    nonisolated static func animationStart(now: Double, velocityX: Double?, lead: Double = defaultFramePeriod,
                                           settled: (Double) -> Bool) -> Double {
        let early = now - lead
        return velocityX == nil && settled(early) ? early : now
    }

    /// The lead of `animationStart`. While the display link runs (another strip animates), `kick` writes nothing,
    /// and the first frame of this strip comes on the next refresh: a lead then would add one more period of motion
    /// to that first step (a window dropped on another display jumped 130 px instead of 45). So the lead is 0.
    nonisolated static func animationLead(period: Double, linkRunning: Bool) -> Double {
        linkRunning ? 0 : firstFrameLead(period: period)
    }

    func relayoutAll(animate: Bool) {
        for key in strips.keys where isActive(key) { relayout(key, animate: animate) }
        updateFocusOverlays()
    }

    /// Writes the first frame now (lowest latency for a command) and lets the display link do the rest.
    /// From rest the springs start one display period (`firstFrameLead`) in the past, so this frame already moves
    /// the windows.
    /// While the link runs, it alone writes, so frames never pile up faster than the display refreshes.
    func kick(_ now: Double) {
        guard let ticker else { return }
        if !ticker.isRunning { tick(now) }
    }

    /// One display refresh: writes the animated frames of every visible strip.
    func tick(_ t: Double) {
        guard status == .running else { ticker?.stop(); return }
        var writes: [FrameWrite] = []
        var placed: [(WindowID, Layout.Placement)] = []
        var settled = true
        for key in animators.keys where isActive(key) {
            guard let d = display(key.display), let frames = animators[key]?.writeFrames(at: t),
                  let anim = animators[key] else { continue }
            for (id, f) in frames {
                guard let w = windows[id], w.state == .tiled, drag?.id != id else { continue }
                let p = Layout.physical(f, display: d.geometry, settings: config.layout)
                if let target = anim.target(id),
                   Self.sizedAway(previous: placements[id]?.frame, write: p.frame,
                                  final: Layout.physical(target, display: d.geometry, settings: config.layout).frame) {
                    resizeAtEnd.insert(id)
                }
                placed.append((id, p))
                writes.append(FrameWrite(id: id, pid: w.info.pid, frame: p.frame))
            }
            if !anim.isSettled(at: t) { settled = false }
        }
        let (moved, ends) = Self.tickStep(placed, placements: &placements, settled: settled, swiping: swipe != nil)
        if ends { Self.resizeMarked(&writes, marks: &resizeAtEnd, exists: { windows[$0] != nil }) }
        if !writes.isEmpty {
            // The completion gets a time only when a write was queued, so it may hold the start before `ticked`.
            let taken = commandClock.tickStart(moved: moved, settles: ends)
            let queued = applier.applyTimed(writes, completion: Self.recordTick(recorder, metrics: metricsStore,
                                                                                commandStart: taken?.start,
                                                                                settleAtWrite: taken?.settleAtWrite == true))
            commandClock.ticked(taken, queued: queued)
        }
        updateOverlays()
        if ends {
            if let ms = commandClock.settled(at: t) { metricsStore?.recordCommandSettle(ms: ms) }
            ticker?.stop()
            applier.settle()
            checkHealth()
        } else if ticker?.isRunning == false {
            ticker?.start()
        }
    }

    // MARK: Overlays

    /// Border and tab bars follow the windows on every frame.
    func updateOverlays() {
        let a = config.appearance
        if a.focusBorder, let id = focusedID, let w = windows[id] {
            if w.state == .tiled, let p = placements[id], !p.hidden {
                overlays.showBorder(around: p.frame, windowID: id, appearance: a)
            } else if w.state == .floating, let f = floatingBorderFrame {
                overlays.showBorder(around: f, windowID: id, appearance: a)
            } else {
                overlays.hideBorder()
            }
        } else {
            overlays.hideBorder()
        }
        let barHeight = CGFloat(config.layout.tabBarHeight)
        var bars: [(frame: CGRect, bar: LayoutResult.TabBar, focusedWindow: WindowID?)] = []
        for (key, result) in layouts where isActive(key) {
            for bar in result.tabBars {
                guard let active = bar.windows[safe: bar.activeIndex], let p = placements[active.id], !p.hidden else { continue }
                bars.append((CGRect(x: p.frame.minX, y: p.frame.minY - barHeight, width: p.frame.width, height: barHeight), bar, focusedID))
            }
        }
        overlays.updateTabBars(bars)
    }

    /// Dimming changes only with focus, not on every frame.
    func updateFocusOverlays() {
        let a = config.appearance
        if a.dimInactive {
            var focused: (window: WindowID, display: String)?
            if let id = focusedID, let w = windows[id] {
                if let key = w.key, w.state == .tiled {
                    focused = (id, key.display)
                } else if let f = floatingBorderFrame, let d = display(containing: CGPoint(x: f.midX, y: f.midY)) {
                    focused = (id, d.uuid)
                }
            }
            overlays.updateDim(displays: displays, focused: focused, appearance: a)
        } else {
            overlays.hideDim()
        }
        updateOverlays()
    }

    /// Highlights the focused window. During a swipe on this strip it highlights the swipe target instead: the
    /// column that the release with no speed focuses. That column comes from the fingers (`swipe.shown`), not
    /// from `strip.scroll`, because a command in the middle of a swipe can scroll the strip.
    func showMinimap(_ key: StripKey) {
        guard config.appearance.minimap, let d = display(key.display), let strip = strips[key], strip.columns.count > 1 else { return }
        var highlight: Int?
        if let s = swipe, s.key == key, let m = metrics(key) {
            highlight = strip.swipeTarget(at: s.shown, settings: config.layout, metrics: m)
        }
        let model = MinimapModel.make(strip: strip, display: d.geometry, settings: config.layout, highlightColumn: highlight)
        if let sink = minimapSink { sink(model, d); return }
        overlays.showMinimap(model, on: d, seconds: config.appearance.minimapSeconds)
    }

    // MARK: Moves and resizes

    /// A window moved or changed size. It can be the user dragging it, an app moving itself, a native fullscreen
    /// switch, or Striple's own write arriving.
    func geometryChanged(_ element: AXUIElement, pid: pid_t, resized: Bool) {
        guard let id = windowID(of: element, pid: pid), let w = windows[id] else {
            // A window that left fullscreen (or was ignored before) may need to be adopted now.
            if resized, let c = classify(element, pid: pid, onlyNew: true), case .tile = c.decision { adopt(c, isNew: false) }
            return
        }
        switch w.state {
        case .tiled:
            if resized, AX.bool(element, "AXFullScreen") == true {
                takeOff(id, as: .fullscreen)
                return
            }
            if NSEvent.pressedMouseButtons & 1 != 0, swipe == nil {
                // Only a real drag of the pressed window counts. While Striple animates, every window moves and
                // the button can be down for a click or a text selection; taking that for a drag would reorder
                // the strip.
                guard let f = AX.frame(element) else { return }
                let own = applier.isOwnFrame(id, f)
                let isDrag = Policy.isUserDrag(window: id, mouseMoved: mouseDragging, pressedWindow: mouseDownWindow,
                                               ownFrame: own, currentDrag: drag?.id)
                guard isDrag else {
                    if Policy.correctAfterRelease(isUserDrag: isDrag, ownFrame: own) { buttonMoves.insert(id) }
                    return
                }
                buttonMoves.remove(id)
                if drag == nil { drag = DragState(id: id, resize: false) }
                if let last = applier.lastWritten(id), abs(f.width - last.width) > 2 || abs(f.height - last.height) > 2 {
                    drag?.resize = true
                }
                return
            }
            scheduleCorrection(id)
        case .fullscreen:
            if resized, AX.bool(element, "AXFullScreen") != true {
                // Leaving fullscreen animates; put the window back once the frame is final.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated { self?.putBack(id, focus: true) }
                }
            }
        case .floating:
            if focusedID == id { floatingBorderFrame = AX.frame(element); updateOverlays() }
            // It may be on a managed display now: it tiles there when the move ends.
            if w.offDisplay, !w.userFloating { scheduleCorrection(id) }
        default:
            break
        }
    }

    /// An app moved or resized a tiled window by itself. Put it back, unless it keeps refusing (a minimum size).
    func scheduleCorrection(_ id: WindowID) {
        correctionWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.correct(id) }
        }
        correctionWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func correct(_ id: WindowID) {
        correctionWork[id] = nil
        guard status == .running, let w = windows[id] else { return }
        switch Policy.correctionStep(state: w.state, offDisplay: w.offDisplay, userFloating: w.userFloating,
                                     dragging: drag != nil, swiping: swipe != nil,
                                     mouseDown: NSEvent.pressedMouseButtons & 1 != 0, animating: ticker?.isRunning == true) {
        case .drop:
            return
        case .wait:
            scheduleCorrection(id)
            return
        case .respaceOnly:
            _ = respace(id, relayoutNow: true)
            return
        case .correct:
            break
        }
        // Moved by macOS to a Space of another display (Mission Control): the window goes to that strip, it is not
        // put back.
        if !respace(id, relayoutNow: true).isEmpty {
            scheduleSessionSave()
            return
        }
        guard let f = AX.frame(w.element), let last = applier.lastWritten(id), !Policy.same(f, last) else { return }
        let now = CACurrentMediaTime()
        let recent = (corrections[id] ?? []).filter { now - $0 < 5 }
        guard recent.count < 2 else { return }
        corrections[id] = recent + [now]
        log.log("correct: window \(id) of \(w.info.bundleID) moved by its app (wrote \(Policy.text(last)), now \(Policy.text(f))), putting it back")
        if !w.info.bundleID.isEmpty { metricsStore?.record(.appCorrection, bundleID: w.info.bundleID) }
        applier.forget(id)
        tick(now)
    }

    func mouseUp() {
        guard let d = drag else { return }
        drag = nil
        guard let w = windows[d.id], w.state == .tiled else { return }
        finishDrag(d, at: mouseLocation(), dropped: AX.frame(w.element))
    }

    /// The end of a drag: the mouse was released at `p`, and the window is at `dropped` (read with AX).
    func finishDrag(_ d: DragState, at p: CGPoint, dropped: CGRect?) {
        guard let w = windows[d.id], w.state == .tiled, let key = w.key, var strip = strips[key],
              let disp = display(key.display) else { return }
        let target = display(containing: p)
        let drop = d.resize || !config.behavior.dragToReorder ? nil
            : Policy.dropKind(dropDisplay: target?.uuid, ownDisplay: key.display,
                              dropDisplayDisabled: target.map { isDisabled($0.uuid) } ?? false)
        if !w.info.bundleID.isEmpty,
           let kind = Self.dragFriction(resize: d.resize, dragToReorder: config.behavior.dragToReorder, drop: drop) {
            metricsStore?.record(kind, bundleID: w.info.bundleID)
        }
        let m = disp.geometry.metrics(config.layout)
        applier.forget(d.id)
        if d.resize {
            if let f = dropped, let (c, _) = strip.locate(d.id) {
                strip.columns[c].width = Policy.adoptedWidth(f.width, metrics: m)
                strip.setFocus(d.id)
                strip.ensureFocusVisible(settings: config.layout, metrics: m)
            }
            strips[key] = strip
        } else if let drop {
            switch drop {
            case .putBack:
                // Not onto a display Striple manages: the window goes back to its own slot.
                strip.setFocus(d.id)
                strip.ensureFocusVisible(settings: config.layout, metrics: m)
                strips[key] = strip
            case .reorder:
                let area = disp.geometry.workArea(config.layout)
                let gap = strip.dropGap(atStripX: Double(p.x - area.minX) + strip.scroll, metrics: m)
                strip.moveWindow(d.id, toGap: gap)
                strip.setFocus(d.id)
                strip.ensureFocusVisible(settings: config.layout, metrics: m)
                strips[key] = strip
            case .otherDisplay:
                guard let target else { break }
                let width = strip.locate(d.id).map { strip.columns[$0.column].width }
                strip.remove(d.id)
                strip.ensureFocusVisible(settings: config.layout, metrics: m)
                strips[key] = strip
                let tkey = activeKey(target)
                let tm = target.geometry.metrics(config.layout)
                var ts = strips[tkey] ?? Strip()
                let area = target.geometry.workArea(config.layout)
                let gap = ts.dropGap(atStripX: Double(p.x - area.minX) + ts.scroll, metrics: tm)
                ts.insert(w.info, width: width ?? .proportion(config.layout.defaultWidth), slot: gap + 1, focus: true)
                ts.ensureFocusVisible(settings: config.layout, metrics: tm)
                strips[tkey] = ts
                windows[d.id]?.key = tkey
                relayout(key)
                // The new strip's animator gets the window at its target: start it where the user let go.
                relayout(tkey, from: dropped.map { [d.id: $0] } ?? [:])
                focusWindow(d.id, scroll: true, fromCommand: false)
                scheduleSessionSave()
                return
            }
        }
        // Animate from where the user let go, not from the old slot. `relayout` starts the window there before it
        // writes the first frame; a `setCurrent` after it came one frame late, so the window flashed back to its
        // old slot.
        relayout(key, from: dropped.map { [d.id: $0] } ?? [:])
        scheduleSessionSave()
    }

    // MARK: Mouse

    func installMouseMonitors() {
        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.mouseUp()
                    self.mouseDownAt = nil
                    self.mouseDragging = false
                    self.mouseDownWindow = nil
                    for id in self.buttonMoves { self.scheduleCorrection(id) }
                    self.buttonMoves.removeAll()
                }
            }
        }
        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.mouseDownAt = NSEvent.mouseLocation
                    self.mouseDragging = false
                    self.mouseDownWindow = self.topWindow(at: self.mouseLocation(), slop: Self.pressSlop)
                    self.buttonMoves.removeAll()
                }
            }
        }
        if mouseDraggedMonitor == nil {
            mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.mouseDragging else { return }
                    self.mouseDragging = Policy.isDrag(from: self.mouseDownAt, to: NSEvent.mouseLocation)
                }
            }
        }
        updateFocusFollowsMouse()
    }

    func removeMouseMonitors() {
        for m in [mouseUpMonitor, mouseDownMonitor, mouseDraggedMonitor, mouseMovedMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        mouseUpMonitor = nil
        mouseDownMonitor = nil
        mouseDraggedMonitor = nil
        mouseMovedMonitor = nil
    }

    /// The mouse-moved monitor runs only while focus-follows-mouse is on: it is the busiest event there is.
    func updateFocusFollowsMouse() {
        let want = status == .running && config.behavior.focusFollowsMouse
        if want, mouseMovedMonitor == nil {
            mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
                MainActor.assumeIsolated { self?.mouseMoved() }
            }
        } else if !want, let m = mouseMovedMonitor {
            NSEvent.removeMonitor(m)
            mouseMovedMonitor = nil
        }
    }

    private func mouseMoved() {
        let now = CACurrentMediaTime()
        guard now - lastFocusFollow > 0.05, swipe == nil, drag == nil, NSEvent.pressedMouseButtons == 0,
              ticker?.isRunning != true else { return }
        lastFocusFollow = now
        let p = mouseLocation()
        guard let id = topWindow(at: p), id != focusedID, let w = windows[id], w.state == .tiled || w.state == .floating else { return }
        focusWindow(id, scroll: false, fromCommand: false)
    }

    /// How far outside its edge a press still belongs to a window (the resize area of macOS 26 windows).
    nonisolated static let pressSlop: CGFloat = 8

    /// The front-most normal window under a point, from the window server's list (front to back).
    /// `slop` widens every window, for presses on the resize area just outside the edge.
    private func topWindow(at p: CGPoint, slop: CGFloat = 0) -> WindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let candidates = Self.hitCandidates(list, ownPID: getpid(), managed: Set(windows.keys))
        let parked = Set(placements.lazy.filter { $0.value.hidden }.map(\.key))
        return Policy.pressedWindow(at: p, frontToBack: candidates, slop: slop, parked: parked)
    }

    /// Normal windows (level 0) and windows Striple manages at any level (a video player set to "Float on Top"),
    /// front to back. Striple's own windows (overlays) are left out.
    nonisolated static func hitCandidates(_ list: [[String: Any]], ownPID: pid_t, managed: Set<WindowID>) -> [(id: WindowID, bounds: CGRect)] {
        var out: [(id: WindowID, bounds: CGRect)] = []
        for info in list {
            guard let n = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (info[kCGWindowLayer as String] as? Int) == 0 || managed.contains(n),
                  (info[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let b = info[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { continue }
            out.append((n, r))
        }
        return out
    }

    // MARK: Swipes

    func startGestures() {
        guard config.gestures.fingers != .off else { return }
        let tap = GestureTap(fingers: config.gestures.fingers.rawValue,
                             onEvent: { [weak self] in self?.swipeEvent($0) },
                             log: { [weak self] in self?.log.log($0) })
        if !tap.start() { log.log("gestures: trackpad swipes are off (event tap refused)") }
        gestureTap = tap
    }

    func swipeEvent(_ event: SwipeTracker.Event) {
        guard status == .running else { return }
        switch event {
        case .began:
            guard let d = display(containing: mouseLocation()), !isDisabled(d.uuid) else { return }
            let key = activeKey(d)
            guard let strip = strips[key], !strip.isEmpty else { return }
            swipe = SwipeState(key: key, raw: strip.scroll, shown: strip.scroll)
            commandClock.swipeBegan()
        case .changed(let dx):
            guard var s = swipe, var strip = strips[s.key], let m = metrics(s.key) else { return }
            s.raw += Policy.scrollDelta(dx: dx, viewWidth: m.usableWidth, settings: config.gestures)
            let b = Policy.scrollBounds(strip, settings: config.layout, metrics: m)
            s.shown = Policy.rubberBand(s.raw, lower: b.lower, upper: b.upper, dimension: m.usableWidth * 0.25)
            swipe = s
            strip.scroll = s.shown
            strips[s.key] = strip
            relayout(s.key, animate: false)
            if ticker?.isRunning == false { ticker?.start() }
            showMinimap(s.key)
        case .ended(let velocity):
            guard let s = swipe else { return }
            swipe = nil
            guard var strip = strips[s.key], let m = metrics(s.key) else { return }
            let v = Policy.scrollDelta(dx: velocity, viewWidth: m.usableWidth, settings: config.gestures)
            let snap = strip.snappedScroll(from: s.shown, velocity: v, settings: config.layout, metrics: m)
            if let store = metricsStore {
                store.record(.swipe)
                // A fling: the speed of the fingers, not only where they stopped, picked the column.
                if snap.column != strip.swipeTarget(at: s.shown, settings: config.layout, metrics: m) {
                    store.record(.fling)
                }
            }
            strip.scroll = snap.scroll
            strip.focusedColumn = snap.column
            strips[s.key] = strip
            // Windows move opposite to the scroll, so they start with the fingers' speed.
            relayout(s.key, animate: true, velocityX: -v)
            showMinimap(s.key)
            if let id = strip.focusedWindow?.id, id != focusedID { focusWindow(id, scroll: false, fromCommand: false) }
            scheduleSessionSave()
        }
    }

    // MARK: Session

    /// The live strips plus the saved ones still waiting for their Space, so a save never drops those.
    func sessionSnapshot() -> Session {
        let off = windows.values.compactMap { w -> (info: WindowInfo, key: StripKey, slot: Int?, width: ColumnWidth?)? in
            guard w.state == .hidden || w.state == .minimized, let key = w.key else { return nil }
            return (w.info, key, w.slot, w.width)
        }
        let withHeld = HeldWindow.placed(heldWindows, into: strips) { StripKey(display: $0.displayID, space: $0.spaceID) }
        let all = Policy.stripsForSession(withHeld, offStrip: off, defaultWidth: .proportion(config.layout.defaultWidth))
        let saved = all.filter { !$0.value.isEmpty }
            .map { SessionStrip(displayID: $0.key.display, spaceID: $0.key.space, strip: $0.value) }
            .sorted { ($0.displayID, $0.spaceID) < ($1.displayID, $1.spaceID) }
        let floating = (windows.values.filter { $0.state == .floating && $0.userFloating }.map(\.info)
                        + heldWindows.filter(\.floats).map(\.info)).sorted { $0.id < $1.id }
        return Session(strips: saved, floating: floating)
            .merging(later: laterStrips, laterFloating: laterFloating, managed: Set(windows.keys))
    }

    func scheduleSessionSave() {
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.saveSessionNow() } }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    /// `sync`: write before returning. Stop uses it, because at quit the process ends right after.
    func saveSessionNow(sync: Bool = false) {
        sessionSaveWork?.cancel()
        sessionSaveWork = nil
        guard status == .running, let data = try? JSONEncoder().encode(sessionSnapshot()) else { return }
        let url = StriplePaths.sessionFile
        let write: @Sendable () -> Void = {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        if sync { write() } else { DispatchQueue.global(qos: .utility).async(execute: write) }
    }

    func loadSession() -> Session? {
        guard let data = try? Data(contentsOf: StriplePaths.sessionFile) else { return nil }
        do {
            return try JSONDecoder().decode(Session.self, from: data)
        } catch {
            log.log("session: could not read \(StriplePaths.sessionFile.path): \(error)")
            return nil
        }
    }

    // MARK: Config

    func configChanged(_ new: Config) {
        let old = config
        config = new
        if old.metrics != new.metrics { metricsSettingChanged() }
        if old.bindings != new.bindings { registerHotkeys() }
        guard status == .running else { return }
        if old.gestures.fingers != new.gestures.fingers {
            // The gesture tracker drops a running swipe without an end event, so end it here: the strip snaps
            // to the swipe target and the minimap shows the focus again, not a stale target.
            if swipe != nil { swipeEvent(.ended(velocity: 0)) }
            if new.gestures.fingers == .off {
                gestureTap?.stop()
                gestureTap = nil
            } else if let tap = gestureTap {
                tap.fingers = new.gestures.fingers.rawValue
            } else {
                startGestures()
            }
        }
        if old.animation != new.animation {
            for key in animators.keys {
                animators[key]?.setResponse(new.animation.response, at: CACurrentMediaTime())
                animators[key]?.enabled = new.animation.enabled
            }
        }
        if old.behavior.focusFollowsMouse != new.behavior.focusFollowsMouse { updateFocusFollowsMouse() }
        if old.rules != new.rules || old.disabledDisplays != new.disabledDisplays {
            rebuild()
            return
        }
        if old.layout != new.layout {
            for (key, var strip) in strips {
                guard let m = metrics(key) else { continue }
                strip.ensureFocusVisible(settings: new.layout, metrics: m)
                strips[key] = strip
            }
            relayoutAll(animate: true)
        }
        if old.appearance != new.appearance {
            if !new.appearance.minimap { overlays.hideMinimaps() }
            updateFocusOverlays()
        }
    }

    /// Starts over with the current windows in their current places (after rule or display changes).
    func rebuild() {
        let session = sessionSnapshot()
        ticker?.stop()
        releaseAll()
        overlays.hideAll()
        clearState()
        scanAll(session: session)
        relayoutAll(animate: true)
        syncFocusWithSystem()
        log.log("engine: rebuilt after a rule or display change")
    }
}
