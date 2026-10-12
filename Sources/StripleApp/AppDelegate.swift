import AppKit
import Combine
import StripleCore
import StripleEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusMenu: StatusMenu?
    private var didLaunch = false
    /// URL commands that arrive before launch is complete run after auto-start.
    private var pending: [Command] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = ConfigStore()
        model = AppModel(store: store, engine: Engine(configStore: store))
        // Registered here, not later, so the URL that launched the app is not lost.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = Updater.shared
        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings))
        statusMenu = StatusMenu(app: model)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(otherInstanceOpened),
                                                            name: SingleInstance.reopenNotification, object: nil,
                                                            suspensionBehavior: .deliverImmediately)

        if model.store.config.behavior.autoStart { model.engine.start() }
        didLaunch = true
        pending.forEach(model.engine.perform)
        pending.removeAll()

        if !model.store.config.behavior.onboardingDone { model.openGuide() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.recorder.stop()
        model.engine.stop()
    }

    @objc private func openSettings() { model.openSettings() }

    @objc private func otherInstanceOpened() { model.openSettings() }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else {
            reject("a URL event without a valid URL")
            return
        }
        switch URLRoute(url) {
        case .settings(let tab):
            model.openSettings(tab)
        case .command(let command):
            if didLaunch { model.engine.perform(command) } else { pending.append(command) }
        case .unknown:
            reject(text)
        }
    }

    private func reject(_ what: String) {
        NSLog("Striple: unknown URL: %@", what)
        NSSound.beep()
    }
}

/// What a `striple://` URL asks for. `striple://open` and `striple://settings[/tab]` open the window;
/// all other URLs are commands.
enum URLRoute: Equatable {
    case settings(SettingsTab?)
    case command(Command)
    case unknown

    init(_ url: URL) {
        guard url.scheme?.lowercased() == StripleURL.scheme else { self = .unknown; return }
        let host = (url.host ?? "").lowercased()
        if host == "open" || host == "settings" {
            let part = url.path.split(separator: "/").first.map { String($0).lowercased() }
            self = .settings(part.flatMap(SettingsTab.init(rawValue:)))
            return
        }
        self = StripleURL.command(from: url).map(URLRoute.command) ?? .unknown
    }
}
