import AppKit
import Combine
import SpoolCore
import SpoolEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, MainMenuActions, NSMenuItemValidation {
    private var model: AppModel!
    private var statusMenu: StatusMenu?
    private var ipc: IPCServer?
    private var signalSources: [DispatchSourceSignal] = []
    private var didLaunch = false
    /// What the move from Striple did before the engine log was open (`LegacyApp.takeOver`).
    var migration = LegacyMigration.Result()
    /// URL commands that arrive before launch is complete run after auto-start.
    private var pending: [Command] = []
    /// The key of a `spool://license` URL that arrives before launch is complete.
    private var pendingLicenseKey: String?

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
        Updater.shared.windows.opened = { [weak model] in model?.windowOpened($0) }
        Updater.shared.windows.closed = { [weak model] in model?.windowClosed($0) }
        LoginItem.refreshAfterUpdate()
        MainMenu.install(target: self)
        statusMenu = StatusMenu(app: model)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(otherInstanceOpened),
                                                            name: SingleInstance.reopenNotification, object: nil,
                                                            suspensionBehavior: .deliverImmediately)

        handleQuitSignals()
        migration.lines.forEach { EngineLog.shared.log($0) }
        LoginItem.restoreAfterRename(movedSettings: migration.movedSettings, configOn: model.store.config.behavior.launchAtLogin)
        // Before the engine starts, so the start is counted. Records an unclean exit of the last run by itself.
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        model.engine.enableMetrics { MetricsStore(directory: SpoolPaths.metricsDirectory, appVersion: version) }
        startIPC()
        // Without a license the start is refused at once, so the status (menu, Settings) says why,
        // also when "start at launch" is off.
        if model.store.config.behavior.autoStart || model.license.status == .unlicensed { model.engine.start() }
        didLaunch = true
        for command in pending { model.engine.perform(command, source: .url) }
        pending.removeAll()

        if let key = pendingLicenseKey {
            pendingLicenseKey = nil
            model.activateLicense(fromURL: key)
        }
        // The license window comes before the guide. The guide opens after a successful activation.
        if model.license.status == .unlicensed {
            model.openLicenseWindow()
        } else {
            model.openGuideIfNeeded()
        }
    }

    // `hasVisibleWindows` also counts the overlay panels (border, tab bars), so it does not tell if Settings is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.reopen()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        model.recorder.stop()
        ipc?.stop()
        model.engine.stop()
        model.engine.finishMetrics()
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

    /// The `spool` CLI and Raycast scripts talk to this socket. A failure only turns off the CLI.
    private func startIPC() {
        let engine = model.engine
        let model = self.model!
        let server = IPCServer(socketURL: SpoolPaths.socket) { request in
            // Before the engine: the license requests work while the engine is gated.
            if request.query == .license { return model.license.keeper.statusResponse() }
            if let key = request.licenseKey { return model.license.keeper.response(for: model.activateLicense(key)) }
            return engine.handle(request)
        }
        do {
            try server.start()
            ipc = server
        } catch {
            EngineLog.shared.log("IPC server did not start: \(error.localizedDescription)")
        }
    }

    @objc func showAbout() { model.showAbout() }
    @objc func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc func openSettings() { model.openSettings() }
    @objc func openHelp() { model.openSettings(.help) }
    @objc func openGuide() { model.openGuide() }
    @objc func openMacSetup() { model.openSettings(.macSetup) }
    @objc func openConfig() { model.openConfigFile() }
    @objc func revealLog() { model.revealLog() }

    @objc private func otherInstanceOpened() { model.reopen() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(checkForUpdates) ? Updater.shared.canCheckForUpdates : true
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: text) else {
            reject("a URL event without a valid URL")
            return
        }
        switch URLRoute(url) {
        case .settings(let tab):
            model.openSettings(tab)
        case .license(let key):
            if didLaunch { model.activateLicense(fromURL: key) } else { pendingLicenseKey = key }
        case .command(let command):
            if didLaunch { model.engine.perform(command, source: .url) } else { pending.append(command) }
        case .unknown:
            reject(text)
        }
    }

    private func reject(_ what: String) {
        NSLog("Spool: unknown URL: %@", what)
        NSSound.beep()
    }
}

/// What a `spool://` URL asks for. `spool://open` and `spool://settings[/tab]` open the window;
/// `spool://license?key=<key>` activates a key; all other URLs are commands.
enum URLRoute: Equatable {
    case settings(SettingsTab?)
    /// The key without white space. Empty when the URL has none.
    case license(String)
    case command(Command)
    case unknown

    init(_ url: URL) {
        guard url.scheme?.lowercased() == SpoolURL.scheme else { self = .unknown; return }
        let host = (url.host ?? "").lowercased()
        if host == "open" || host == "settings" {
            let part = url.path.split(separator: "/").first.map { String($0).lowercased() }
            self = .settings(part.flatMap(SettingsTab.init(rawValue:)))
            return
        }
        if let key = SpoolURL.licenseKey(from: url) {
            self = .license(key)
            return
        }
        self = SpoolURL.command(from: url).map(URLRoute.command) ?? .unknown
    }
}
