import AppKit

/// What the items of the main menu call. `AppDelegate` implements them.
@MainActor @objc protocol MainMenuActions {
    func showAbout()
    func checkForUpdates()
    func openSettings()
    func openHelp()
    func openGuide()
    func openMacSetup()
    func openConfig()
    func revealLog()
}

/// The menu bar of Striple. Striple shows it only while one of its windows is open (see `DockPresence`); at other
/// times Striple is a menu bar app. The key equivalents work in its windows: ⌘W, ⌘Q, and copy and paste in text fields.
enum MainMenu {
    typealias Actions = MainMenuActions

    @MainActor
    static func install(target: Actions) {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(item("About Striple", #selector(Actions.showAbout), "", target))
        appMenu.addItem(item("Check for Updates…", #selector(Actions.checkForUpdates), "", target))
        appMenu.addItem(.separator())
        appMenu.addItem(item("Settings…", #selector(Actions.openSettings), ",", target))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Striple", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Striple", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        add(appMenu, title: "Striple", to: main)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        add(edit, title: "Edit", to: main)

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        add(window, title: "Window", to: main)
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("Striple Help", #selector(Actions.openHelp), "?", target))
        help.addItem(item("Show the Guide", #selector(Actions.openGuide), "", target))
        help.addItem(item("Mac Setup…", #selector(Actions.openMacSetup), "", target))
        help.addItem(.separator())
        help.addItem(item("Open Configuration File", #selector(Actions.openConfig), "", target))
        help.addItem(item("Reveal Engine Log", #selector(Actions.revealLog), "", target))
        add(help, title: "Help", to: main)
        NSApp.helpMenu = help

        NSApp.mainMenu = main
    }

    @MainActor
    private static func item(_ title: String, _ action: Selector, _ key: String, _ target: Actions) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }

    @MainActor
    private static func add(_ submenu: NSMenu, title: String, to main: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        main.addItem(item)
    }
}
