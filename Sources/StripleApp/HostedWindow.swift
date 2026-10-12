import AppKit
import SwiftUI

/// A window with SwiftUI content. The content is built when the window opens and dropped when
/// it closes, so no SwiftUI timer or event monitor stays alive while the window is not visible.
@MainActor
final class HostedWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let title: String
    private let autosaveName: String
    private let resizable: Bool
    private let makeContent: () -> AnyView
    /// False until the window has a position: a saved one or a centred one.
    private var hasFrame = false
    var onClose: (() -> Void)?

    init(title: String, autosaveName: String, resizable: Bool, content: @escaping () -> AnyView) {
        self.title = title
        self.autosaveName = autosaveName
        self.resizable = resizable
        self.makeContent = content
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        if window.contentViewController == nil {
            let frame = window.frame
            window.contentViewController = NSHostingController(rootView: makeContent())
            if hasFrame {
                window.setFrame(frame, display: false)
            } else {
                window.center()
                hasFrame = true
            }
        }
        App.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    private func makeWindow() -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560), styleMask: style,
                              backing: .buffered, defer: true)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        hasFrame = resizable && window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        DispatchQueue.main.async { [weak self] in
            guard let window = self?.window, !window.isVisible else { return }
            window.contentViewController = nil
        }
    }
}

enum App {
    static func activate() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
