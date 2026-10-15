import AppKit
import SwiftUI

/// A window with SwiftUI content. The content is built when the window opens and dropped when
/// it closes, so no SwiftUI timer or event monitor stays alive while the window is not visible.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate, NSToolbarDelegate {
    enum Content {
        case single(() -> AnyView)
        /// A sidebar and a detail pane, as in System Settings: the sidebar reaches the top of the window and
        /// `title` shows above the detail pane.
        case split(sidebar: () -> AnyView, detail: () -> AnyView)
    }

    private var window: NSWindow?
    private let autosaveName: String
    private let resizable: Bool
    private let content: Content
    /// False until the window has a position: a saved one or a centred one.
    private var hasFrame = false
    var title: String {
        didSet { window?.title = title }
    }
    /// Called before the window comes to the front, also when it is already open.
    var onShow: (() -> Void)?
    var onClose: (() -> Void)?

    init(title: String, autosaveName: String, resizable: Bool, content: Content) {
        self.title = title
        self.autosaveName = autosaveName
        self.resizable = resizable
        self.content = content
    }

    convenience init(title: String, autosaveName: String, resizable: Bool, content: @escaping () -> AnyView) {
        self.init(title: title, autosaveName: autosaveName, resizable: resizable, content: .single(content))
    }

    /// True while the window is on screen or minimized in the Dock. A minimized window is not visible, but it is open.
    var isOpen: Bool { window.map { HostedWindow.isOpen(visible: $0.isVisible, minimized: $0.isMiniaturized) } ?? false }

    nonisolated static func isOpen(visible: Bool, minimized: Bool) -> Bool { visible || minimized }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil {
            let frame = window.frame
            window.contentViewController = makeContentController()
            if hasFrame {
                window.setFrame(frame, display: false)
            } else {
                window.center()
                hasFrame = true
            }
        }
        onShow?()
        App.activate()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private var isSplit: Bool {
        if case .split = content { return true }
        return false
    }

    private func makeContentController() -> NSViewController {
        switch content {
        case .single(let make):
            return NSHostingController(rootView: make())
        case .split(let sidebar, let detail):
            let split = NSSplitViewController()
            let side = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: sidebar()))
            side.canCollapse = false
            side.minimumThickness = 190
            side.maximumThickness = 260
            split.addSplitViewItem(side)
            split.addSplitViewItem(NSSplitViewItem(viewController: NSHostingController(rootView: detail())))
            return split
        }
    }

    private func makeWindow() -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        if isSplit { style.insert(.fullSizeContentView) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: style,
                              backing: .buffered, defer: true)
        window.title = title
        if isSplit {
            // The tracking separator puts the title above the detail pane, next to the sidebar.
            let toolbar = NSToolbar(identifier: "\(autosaveName).toolbar")
            toolbar.delegate = self
            toolbar.displayMode = .iconOnly
            toolbar.allowsUserCustomization = false
            window.toolbar = toolbar
            window.toolbarStyle = .unified
            // No line under the title, as in System Settings. The page scrolls below the title bar, not under it,
            // so `.automatic` would draw the line all the time.
            window.titlebarSeparatorStyle = .none
        }
        window.isReleasedWhenClosed = false
        window.delegate = self
        hasFrame = resizable && window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebarTrackingSeparator] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? { nil }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }
}

enum App {
    /// Takes the focus from the front app. The cooperative `NSApp.activate()` of macOS 14 does not: after a click in
    /// the menu bar menu, Settings opened behind the front app. Sparkle uses the same call.
    static func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
