import AppKit
import Foundation
import StripleCore

/// Click-through panels that Striple draws on top of the desktop: focus border, dimming, minimap and tab bars.
/// All frames come in AX coordinates and are converted here.
@MainActor
final class Overlays {
    private var border: NSPanel?
    private var borderView: BorderView?
    private(set) var dims: [String: NSPanel] = [:]
    private var minimaps: [String: (panel: NSPanel, view: MinimapView)] = [:]
    private var minimapHide: [String: DispatchWorkItem] = [:]
    private var tabBars: [Int: (panel: NSPanel, view: TabBarView)] = [:]
    let appIcons: AppIconCache
    var onTabClick: ((WindowID) -> Void)?

    /// `appIcons` nil uses a cache that makes icons on a background queue; tests pass their own.
    init(appIcons: AppIconCache? = nil) {
        let appIcons = appIcons ?? AppIconCache()
        self.appIcons = appIcons
        // An icon that was made in the background is drawn at once, also while the minimap does not move.
        // A hidden minimap draws only when it is shown again, so marking it costs nothing.
        appIcons.onLoad = { [weak self] in
            guard let self else { return }
            for entry in minimaps.values { entry.view.needsDisplay = true }
        }
        appIcons.shown = { [weak self] in self?.shownIconKeys() ?? [] }
    }

    /// The apps of the blocks of each minimap that is on screen now, also while it fades out.
    func shownIconKeys() -> Set<AppIconCache.Key> {
        var keys: Set<AppIconCache.Key> = []
        for entry in minimaps.values where entry.panel.isVisible {
            for item in entry.view.model.items { keys.insert(.init(pid: item.pid, bundleID: item.bundleID)) }
        }
        return keys
    }

    static func appKitRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    static func makePanel(clickThrough: Bool = true, level: NSWindow.Level = .normal) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = clickThrough
        p.level = level
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        // Hide Striple (⌘H while Settings is open) must not hide the border, the dimming or the tab bars.
        p.canHide = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        return p
    }

    // MARK: Focus border

    func showBorder(around frame: CGRect, windowID: WindowID, appearance: AppearanceSettings) {
        guard appearance.focusBorder else { hideBorder(); return }
        let w = CGFloat(max(appearance.borderWidth, 1))
        if border == nil {
            border = Self.makePanel()
            borderView = BorderView()
            border?.contentView = borderView
        }
        guard let border, let borderView else { return }
        borderView.width = w
        borderView.color = NSColor(hex: appearance.borderColor) ?? .systemBlue
        border.setFrame(Self.appKitRect(frame.insetBy(dx: -w, dy: -w)), display: false)
        borderView.needsDisplay = true
        // Just above the focused window: other windows that overlap it (floating ones) still cover the border.
        border.order(.above, relativeTo: Int(windowID))
    }

    func hideBorder() { border?.orderOut(nil) }

    // MARK: Dimming

    /// Where the dim panel of one display goes in the window order.
    enum DimOrder: Equatable {
        case below(Int)
        case front
    }

    /// On the display of the focused window: just below it. On other displays: on top of the normal windows, but
    /// below `ownBack` (the backmost Striple window, such as Settings, while Striple is active), so no Striple window
    /// is dimmed.
    nonisolated static func dimOrder(display: String, focused: (window: WindowID, display: String)?,
                                     ownBack: Int?) -> DimOrder {
        if let f = focused, f.display == display { return .below(Int(f.window)) }
        if let ownBack { return .below(ownBack) }
        return .front
    }

    /// One of Striple's windows, front to back, for `ownWindowsBackToFront`. `top` is the number of the window it
    /// belongs to (see `topLevel`); `visible` and `normal` are about that window.
    struct OwnWindow: Equatable {
        let number: Int
        let top: Int
        let visible: Bool
        let normal: Bool
    }

    /// Striple's windows that are on screen at the normal level and are not overlays (Settings, the guide, About, an
    /// update window), back to front, each once. A sheet or a child window counts as the window it belongs to.
    nonisolated static func ownWindowsBackToFront(_ windows: [OwnWindow], overlays: Set<Int>) -> [Int] {
        var seen = Set<Int>()
        return windows.reversed()
            .filter { !overlays.contains($0.number) && $0.visible && $0.normal }
            .map(\.top)
            .filter { seen.insert($0).inserted }
    }

    /// The backmost of `ownWindowsBackToFront`. After `raiseOwnWindows` all of them are in front of the other apps,
    /// so a dim just below this one dims none of them. The front one is not enough: the guide or About in front of
    /// Settings would put the dim between the two.
    nonisolated static func backmostOwnWindow(_ windows: [OwnWindow], overlays: Set<Int>) -> Int? {
        ownWindowsBackToFront(windows, overlays: overlays).first
    }

    /// Striple's windows in the order of the window server, front to back.
    private func ownWindows() -> [OwnWindow] {
        (NSWindow.windowNumbers(options: []) ?? []).compactMap { number -> OwnWindow? in
            guard let w = NSApp.window(withWindowNumber: number.intValue) else { return nil }
            let top = Self.topLevel(w)
            return OwnWindow(number: number.intValue, top: top.windowNumber, visible: top.isVisible,
                             normal: top.level == .normal)
        }
    }

    private func overlayNumbers() -> Set<Int> {
        var overlays = Set(dims.values.map(\.windowNumber))
        overlays.formUnion(minimaps.values.map(\.panel.windowNumber))
        overlays.formUnion(tabBars.values.map(\.panel.windowNumber))
        if let border { overlays.insert(border.windowNumber) }
        return overlays
    }

    /// A Dock click or ⌘Tab brings all of Striple's windows forward, a click on one window only that window. While
    /// the dimming is on, this brings the others forward too, in their order, so the window you clicked stays in
    /// front. Then no Striple window stays behind the focused window of another app, under the dim. Without the
    /// dimming the windows keep the order macOS gives them.
    func raiseOwnWindows(dimming: Bool) {
        guard Self.raisesOwnWindows(active: NSApplication.shared.isActive, dimming: dimming) else { return }
        for number in Self.ownWindowsBackToFront(ownWindows(), overlays: overlayNumbers()) {
            NSApp.window(withWindowNumber: number)?.orderFront(nil)
        }
    }

    /// `raiseOwnWindows` does something only while Striple is active and the dimming is on.
    nonisolated static func raisesOwnWindows(active: Bool, dimming: Bool) -> Bool { active && dimming }

    /// The dimming was off and is on now: the windows a click left behind other apps' windows must come along.
    nonisolated static func dimmingTurnedOn(was: Bool, now: Bool) -> Bool { !was && now }

    /// `backmostOwnWindow` for the windows on screen. Nil when Striple is not active.
    private func ownBackWindow() -> Int? {
        guard NSApplication.shared.isActive else { return nil }
        return Self.backmostOwnWindow(ownWindows(), overlays: overlayNumbers())
    }

    /// The window that `window` belongs to: the parent of a sheet or a child window, up to the top.
    static func topLevel(_ window: NSWindow) -> NSWindow {
        var top = window
        while let parent = top.sheetParent ?? top.parent { top = parent }
        return top
    }

    /// Dims everything on the display except the focused window: one panel per display (see `dimOrder`).
    func updateDim(displays: [EngineDisplay], focused: (window: WindowID, display: String)?, appearance: AppearanceSettings) {
        guard appearance.dimInactive else { hideDim(); return }
        let live = Set(displays.map(\.uuid))
        for (id, p) in dims where !live.contains(id) { p.orderOut(nil); dims[id] = nil }
        let ownBack = ownBackWindow()
        for d in displays {
            let p = dims[d.uuid] ?? {
                let p = Self.makePanel()
                p.contentView = NSView()
                p.contentView?.wantsLayer = true
                dims[d.uuid] = p
                return p
            }()
            p.contentView?.layer?.backgroundColor = NSColor.black.withAlphaComponent(CGFloat(appearance.dimAmount)).cgColor
            p.setFrame(Self.appKitRect(d.geometry.frame), display: false)
            switch Self.dimOrder(display: d.uuid, focused: focused, ownBack: ownBack) {
            case .below(let window): p.order(.below, relativeTo: window)
            case .front: p.orderFront(nil)
            }
        }
    }

    func hideDim() { for p in dims.values { p.orderOut(nil) } }

    // MARK: Minimap

    /// The minimap panel of a display, made on first use. It is not shown here.
    func minimapEntry(_ uuid: String) -> (panel: NSPanel, view: MinimapView) {
        if let e = minimaps[uuid] { return e }
        let p = Self.makePanel(level: .statusBar)
        let v = MinimapView()
        let icons = appIcons
        v.icon = { icons.icon(pid: $0, bundleID: $1) }
        p.contentView = v
        let e = (p, v)
        minimaps[uuid] = e
        return e
    }

    func showMinimap(_ model: MinimapModel, on display: EngineDisplay, seconds: Double) {
        let entry = minimapEntry(display.uuid)
        let u = display.geometry.usable
        let height: CGFloat = 54
        let width = min(max(u.width * 0.28, 220), 520)
        let frame = CGRect(x: u.midX - width / 2, y: u.maxY - height - 16, width: width, height: height)
        entry.view.model = model
        entry.panel.setFrame(Self.appKitRect(frame), display: true)
        entry.panel.alphaValue = 1
        entry.panel.orderFrontRegardless()
        minimapHide[display.uuid]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let p = self?.minimaps[display.uuid]?.panel else { return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.25
                    p.animator().alphaValue = 0
                }, completionHandler: { MainActor.assumeIsolated { if p.alphaValue == 0 { p.orderOut(nil) } } })
            }
        }
        minimapHide[display.uuid] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(seconds, 0.2), execute: work)
    }

    func hideMinimaps() { for e in minimaps.values { e.panel.orderOut(nil) } }

    // MARK: Tab bars

    /// Shows one tab bar per tabbed column. `bars` frames are physical (already on screen); hidden bars are skipped.
    func updateTabBars(_ bars: [(frame: CGRect, bar: LayoutResult.TabBar, focusedWindow: WindowID?)]) {
        for i in bars.count..<max(tabBars.count, bars.count) { tabBars[i]?.panel.orderOut(nil) }
        for (i, b) in bars.enumerated() {
            let entry = tabBars[i] ?? {
                let p = Self.makePanel(clickThrough: false)
                let v = TabBarView()
                v.onClick = { [weak self] id in self?.onTabClick?(id) }
                p.contentView = v
                let e = (p, v)
                tabBars[i] = e
                return e
            }()
            entry.view.bar = b.bar
            entry.view.focused = b.focusedWindow
            entry.view.needsDisplay = true
            entry.panel.setFrame(Self.appKitRect(b.frame), display: true)
            if let active = b.bar.windows[safe: b.bar.activeIndex]?.id {
                entry.panel.order(.above, relativeTo: Int(active))
            } else {
                entry.panel.orderFront(nil)
            }
        }
    }

    func hideAll() {
        hideBorder()
        hideDim()
        hideMinimaps()
        updateTabBars([])
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension NSColor {
    /// `#RRGGBB` or `#RRGGBBAA`.
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let a = s.count == 8 ? CGFloat(v & 0xFF) / 255 : 1
        let rgb = s.count == 8 ? v >> 8 : v
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                  blue: CGFloat(rgb & 0xFF) / 255, alpha: a)
    }
}

private final class BorderView: NSView {
    var width: CGFloat = 4
    var color: NSColor = .systemBlue

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2), xRadius: 10 + width / 2, yRadius: 10 + width / 2)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }
}

final class MinimapView: NSView {
    var model = MinimapModel(items: [], viewport: .zero) { didSet { needsDisplay = true } }
    /// The app icon for a pid and bundle ID, or nil.
    var icon: ((Int32, String) -> NSImage?)?
    /// How often the view was asked to draw again. AppKit does not let a test read this from `needsDisplay`:
    /// a hidden panel keeps it true once set, and a panel of zero size drops it. So tests count the requests.
    private(set) var displayRequests = 0
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            if newValue { displayRequests += 1 }
            super.needsDisplay = newValue
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10)
        NSColor(white: 0.08, alpha: 0.78).setFill()
        bg.fill()
        let inner = bounds.insetBy(dx: 10, dy: 8)
        func rect(_ r: CGRect) -> CGRect {
            // Model rects have y down; AppKit views have y up.
            CGRect(x: inner.minX + r.minX * inner.width, y: inner.maxY - r.maxY * inner.height,
                   width: r.width * inner.width, height: r.height * inner.height)
        }
        for item in model.items {
            let r = rect(item.rect).insetBy(dx: 0.75, dy: 0.75)
            let p = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2)
            (item.highlighted ? NSColor.controlAccentColor : NSColor(white: 0.55, alpha: 0.9)).setFill()
            p.fill()
            if let side = MinimapModel.iconSide(itemSize: r.size), let image = icon?(item.pid, item.bundleID) {
                // Aligned to whole pixels, so the edges of the small icon stay sharp.
                let s = side.rounded(.down)
                let target = backingAlignedRect(CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s),
                                                options: .alignAllEdgesNearest)
                image.draw(in: target, from: .zero, operation: .sourceOver, fraction: item.highlighted ? 1 : 0.7)
            }
        }
        let vp = NSBezierPath(roundedRect: rect(model.viewport).insetBy(dx: -2, dy: -3), xRadius: 4, yRadius: 4)
        vp.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.85).setStroke()
        vp.stroke()
    }
}

/// App icons for the minimap, made once per app as a small bitmap.
/// A cold app icon costs 1 to 90 ms to look up and draw (measured on 8 running apps), which is too much for the
/// main thread during a swipe. So the cache makes each icon on a background queue. Until the icon is ready, `icon`
/// returns nil and the minimap draws the block with no icon; `onLoad` then asks for a redraw.
/// A ready icon is a 20 pt bitmap, so each minimap draw stays cheap.
@MainActor
final class AppIconCache {
    struct Key: Hashable { var pid: Int32; var bundleID: String }
    /// Moves a finished icon from the background queue to the main thread. The queue does not use it after that.
    private struct Made: @unchecked Sendable { let image: NSImage? }
    /// A known icon (nil if the app has none) and the `clock` value of its last use.
    private struct Entry { var image: NSImage?; var used: UInt64 }
    private var images: [Key: Entry] = [:]
    private var clock: UInt64 = 0
    private var pending: Set<Key> = []
    /// Icons (and known missing icons) in the cache now. It is at most the larger of `limit` and (the cached
    /// icons that the minimaps on screen show + 1). So it can be more than `limit` while they show `limit`
    /// apps or more, until the first new icon stored after they show fewer.
    var count: Int { images.count }
    /// Icons that the background queue makes now.
    var pendingCount: Int { pending.count }
    let queue: DispatchQueue?
    private let lookup: @Sendable (Int32, String) -> NSImage?
    /// Called on the main thread when an icon is ready.
    var onLoad: (() -> Void)?
    /// The apps that a minimap on screen shows now. The cache never removes their icons. `Overlays` sets it.
    var shown: () -> Set<Key> = { [] }
    /// The most icons the cache keeps, so icons of quit apps do not stay forever. A new icon then removes the
    /// icon that was used least recently, of the icons that no minimap on screen shows. So a minimap on screen
    /// never loses its icons and does not blink. When the minimaps on screen show `limit` apps or more (in
    /// practice 3 or more displays), the cache keeps them all, and grows past `limit` for that time: else each icon
    /// that is ready would remove another icon on screen, and the redraw from `onLoad` would make it again.
    static let limit = 64
    private(set) var lookups = 0

    /// `queue` nil makes each icon at once on the calling thread; tests use that.
    init(queue: DispatchQueue? = DispatchQueue(label: "striple.icons", qos: .utility, autoreleaseFrequency: .workItem),
         lookup: @escaping @Sendable (Int32, String) -> NSImage? = { AppIconCache.liveIcon(pid: $0, bundleID: $1) }) {
        self.queue = queue
        self.lookup = lookup
    }

    /// The icon if it is ready, else nil (and the icon is made once, in the background).
    /// The bundle ID is part of the key, so a pid that a new app reuses does not get the old icon.
    func icon(pid: Int32, bundleID: String) -> NSImage? {
        guard pid > 0 else { return nil }
        let key = Key(pid: pid, bundleID: bundleID)
        if images[key] != nil {
            clock += 1
            images[key]?.used = clock
            return images[key]?.image
        }
        if pending.contains(key) { return nil }
        lookups += 1
        let lookup = self.lookup
        let make: @Sendable () -> Made = { Made(image: lookup(pid, bundleID).flatMap { Self.bitmap($0, side: MinimapModel.maxIconSide) }) }
        guard let queue else {
            let image = make().image
            store(key, image)
            return image
        }
        pending.insert(key)
        queue.async { [weak self] in
            let made = make()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finish(key, made.image) } }
        }
        return nil
    }

    /// The icon of the app with this pid, if that app still has this bundle ID. The lookup runs later than the
    /// request, so the app can have quit and another app can have the pid now.
    nonisolated static func liveIcon(pid: Int32, bundleID: String) -> NSImage? {
        guard let app = NSRunningApplication(processIdentifier: pid), (app.bundleIdentifier ?? "") == bundleID else { return nil }
        return app.icon
    }

    private func finish(_ key: Key, _ image: NSImage?) {
        pending.remove(key)
        store(key, image)
        if image != nil { onLoad?() }
    }

    /// Stores the icon as the most recently used one. If the cache is full, it first removes the icons that were
    /// used least recently, of the icons that no minimap on screen shows, until there is space for one more. This
    /// runs only for a new app, and the cache is small, so the sort is cheap.
    private func store(_ key: Key, _ image: NSImage?) {
        if images[key] == nil, images.count >= Self.limit {
            let keep = shown()
            let old = images.filter { !keep.contains($0.key) }.sorted { $0.value.used < $1.value.used }
            for entry in old.prefix(images.count - Self.limit + 1) { images.removeValue(forKey: entry.key) }
        }
        clock += 1
        images[key] = Entry(image: image, used: clock)
    }

    /// Draws `icon` into a bitmap of `side` points at 2x, for Retina displays. Safe on any thread: the context
    /// belongs to the bitmap. Nil if the bitmap cannot be made.
    nonisolated static func bitmap(_ icon: NSImage, side: CGFloat) -> NSImage? {
        let pixels = Int(side * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        // Set the size before the context is made: the context takes its point-to-pixel scale from it.
        rep.size = NSSize(width: side, height: side)
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private final class TabBarView: NSView {
    var bar: LayoutResult.TabBar?
    var focused: WindowID?
    var onClick: ((WindowID) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        guard let bar, !bar.windows.isEmpty else { return }
        let w = bounds.width / CGFloat(bar.windows.count)
        for (i, win) in bar.windows.enumerated() {
            let r = CGRect(x: CGFloat(i) * w, y: 0, width: w, height: bounds.height).insetBy(dx: 1, dy: 2)
            let active = i == bar.activeIndex
            let fill: NSColor = active ? (win.id == focused ? .controlAccentColor : NSColor(white: 0.45, alpha: 0.95))
                : NSColor(white: 0.2, alpha: 0.9)
            fill.setFill()
            NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
            let title = win.title.isEmpty ? win.bundleID : win.title
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: active ? .semibold : .regular),
                .foregroundColor: NSColor.white, .paragraphStyle: style,
            ]
            let text = NSAttributedString(string: title, attributes: attrs)
            let h = text.size().height
            text.draw(in: CGRect(x: r.minX + 6, y: r.midY - h / 2, width: r.width - 12, height: h))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let bar, !bar.windows.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let i = min(max(Int(x / (bounds.width / CGFloat(bar.windows.count))), 0), bar.windows.count - 1)
        onClick?(bar.windows[i].id)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
