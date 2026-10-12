import AppKit
import Foundation
import StripleCore

/// Click-through panels that Striple draws on top of the desktop: focus border, dimming, minimap and tab bars.
/// All frames come in AX coordinates and are converted here.
@MainActor
final class Overlays {
    private var border: NSPanel?
    private var borderView: BorderView?
    private var dims: [String: NSPanel] = [:]
    private var minimaps: [String: (panel: NSPanel, view: MinimapView)] = [:]
    private var minimapHide: [String: DispatchWorkItem] = [:]
    private var tabBars: [Int: (panel: NSPanel, view: TabBarView)] = [:]
    var onTabClick: ((WindowID) -> Void)?

    static func appKitRect(_ r: CGRect) -> CGRect {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    private static func makePanel(clickThrough: Bool = true, level: NSWindow.Level = .normal) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = clickThrough
        p.level = level
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
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

    /// Dims everything on the display except the focused window: one panel per display, ordered just below the
    /// focused window. On other displays the panel sits on top of the normal windows.
    func updateDim(displays: [EngineDisplay], focused: (window: WindowID, display: String)?, appearance: AppearanceSettings) {
        guard appearance.dimInactive else { hideDim(); return }
        let live = Set(displays.map(\.uuid))
        for (id, p) in dims where !live.contains(id) { p.orderOut(nil); dims[id] = nil }
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
            if let f = focused, f.display == d.uuid {
                p.order(.below, relativeTo: Int(f.window))
            } else {
                p.orderFront(nil)
            }
        }
    }

    func hideDim() { for p in dims.values { p.orderOut(nil) } }

    // MARK: Minimap

    func showMinimap(_ model: MinimapModel, on display: EngineDisplay, seconds: Double) {
        let entry = minimaps[display.uuid] ?? {
            let p = Self.makePanel(level: .statusBar)
            let v = MinimapView()
            p.contentView = v
            let e = (p, v)
            minimaps[display.uuid] = e
            return e
        }()
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

private final class MinimapView: NSView {
    var model = MinimapModel(items: [], viewport: .zero) { didSet { needsDisplay = true } }

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
            let p = NSBezierPath(roundedRect: rect(item.rect).insetBy(dx: 0.75, dy: 0.75), xRadius: 2, yRadius: 2)
            (item.focused ? NSColor.controlAccentColor : NSColor(white: 0.55, alpha: 0.9)).setFill()
            p.fill()
        }
        let vp = NSBezierPath(roundedRect: rect(model.viewport).insetBy(dx: -2, dy: -3), xRadius: 4, yRadius: 4)
        vp.lineWidth = 1.5
        NSColor.white.withAlphaComponent(0.85).setStroke()
        vp.stroke()
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
