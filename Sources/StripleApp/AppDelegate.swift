import AppKit
import Combine
import StripleCore
import StripleEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel!
    private var statusMenu: StatusMenu?
    private var ipc: IPCServer?
    private var signalSources: [DispatchSourceSignal] = []
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
        LoginItem.refreshAfterUpdate()
        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings))
        statusMenu = StatusMenu(app: model)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(otherInstanceOpened),
                                                            name: SingleInstance.reopenNotification, object: nil,
                                                            suspensionBehavior: .deliverImmediately)

        handleQuitSignals()
        startIPC()
        if model.store.config.behavior.autoStart { model.engine.start() }
        didLaunch = true
        pending.forEach(model.engine.perform)
        pending.removeAll()

        // With a broken config.json the guide would save over the user's file when it closes.
        if !model.store.config.behavior.onboardingDone, !model.store.fileHasError { model.openGuide() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.openSettings()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.recorder.stop()
        ipc?.stop()
        model.engine.stop()
        // Last: if the agent started this process, unregistering it makes launchd stop the process.
        LoginItem.finishOffAtQuit(atQuit: true)
    }

    /// launchd (logout, `launchctl bootout`) and `kill` send signals, which skip `applicationWillTerminate`.
    /// Without this, windows parked off screen would stay there. A normal quit restores them.
    private func handleQuitSignals() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            source.resume()
            signalSources.append(source)
        }
    }

    /// The `striple` CLI and Raycast scripts talk to this socket. A failure only turns off the CLI.
    private func startIPC() {
        let engine = model.engine
        let server = IPCServer(socketURL: StriplePaths.socket) { engine.handle($0) }
        do {
            try server.start()
            ipc = server
        } catch {
            EngineLog.shared.log("IPC server did not start: \(error.localizedDescription)")
        }
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
