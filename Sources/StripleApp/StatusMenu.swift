import AppKit
import Combine
import StripleCore
import StripleEngine

/// The menu bar icon and its menu.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let app: AppModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let toggleItem = NSMenuItem(title: "", action: #selector(toggleEngine), keyEquivalent: "")
    private let updatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
    private let configErrorItem = NSMenuItem(title: "", action: #selector(openSettings), keyEquivalent: "")
    /// Saves a mark (docs/METRICS.md). Off while metrics are off.
    private let markItem = NSMenuItem(title: "Mark This Moment", action: #selector(markMoment), keyEquivalent: "")
    private var cancellable: AnyCancellable?

    init(app: AppModel) {
        self.app = app
        super.init()
        buildMenu()
        showConfigError()
        item.menu = menu
        // @Published sends the new value before the property changes, so use the value it sends.
        cancellable = app.engine.$status.sink { [weak self] status in self?.show(status) }
    }

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(target(configErrorItem))
        menu.addItem(target(toggleItem))
        menu.addItem(target(NSMenuItem(title: "Restart Engine", action: #selector(restartEngine), keyEquivalent: "")))
        menu.addItem(.separator())
        menu.addItem(target(NSMenuItem(title: "Open Striple…", action: #selector(openSettings), keyEquivalent: ",")))
        menu.addItem(target(NSMenuItem(title: "Open Configuration File", action: #selector(openConfig), keyEquivalent: "")))
        menu.addItem(target(NSMenuItem(title: "Mac Setup…", action: #selector(openMacSetup), keyEquivalent: "")))
        menu.addItem(.separator())
        updatesItem.isEnabled = Updater.shared.isConfigured
        menu.addItem(target(updatesItem))
        menu.addItem(target(NSMenuItem(title: "Reveal Engine Log", action: #selector(revealLog), keyEquivalent: "")))
        menu.addItem(target(markItem))
        menu.addItem(.separator())
        menu.addItem(target(NSMenuItem(title: "Quit Striple", action: #selector(quit), keyEquivalent: "q")))
    }

    private func target(_ menuItem: NSMenuItem) -> NSMenuItem {
        menuItem.target = self
        return menuItem
    }

    private func show(_ status: Engine.Status) {
        statusLine.title = status.summary
        toggleItem.title = status == .stopped ? "Start Striple" : "Stop Striple"
        guard let button = item.button else { return }
        let symbol = StatusIcon.symbolName(status)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: status.summary)
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "S" : ""
        button.appearsDisabled = status != .running
        button.toolTip = status.summary
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updatesItem.isEnabled = Updater.shared.isConfigured
        markItem.isEnabled = app.store.config.metrics.enabled
        show(app.engine.status)
        showConfigError()
    }

    private func showConfigError() {
        configErrorItem.isHidden = !app.store.hasProblem
        configErrorItem.title = StatusIcon.configErrorTitle
        configErrorItem.toolTip = app.store.loadError
        configErrorItem.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
    }

    @objc private func toggleEngine() { app.engine.perform(.toggleEngine, source: .menu) }
    @objc private func restartEngine() { app.engine.perform(.restart, source: .menu) }
    @objc private func markMoment() { app.engine.perform(.mark, source: .menu) }
    @objc private func openSettings() { app.openSettings() }
    @objc private func openConfig() { app.openConfigFile() }
    @objc private func openMacSetup() { app.openSettings(.macSetup) }
    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func revealLog() { app.revealLog() }
    /// `terminate` exits with status 0, so launchd (KeepAlive SuccessfulExit = false) does not start Striple again.
    @objc private func quit() { NSApp.terminate(nil) }
}

enum StatusIcon {
    /// Opens Settings, which shows the full message.
    static let configErrorTitle = "Problem With config.json…"
    static func symbolName(_ status: Engine.Status) -> String {
        switch status {
        case .running: return "rectangle.split.3x1.fill"
        case .stopped: return "rectangle.split.3x1"
        case .noPermission: return "exclamationmark.triangle"
        }
    }
}
