import AppKit

/// Striple is a menu bar app (LSUIElement). While one of its windows is open it is a normal app, with a Dock icon,
/// a place in ⌘Tab and a menu bar. Then Settings and the guide cannot get lost behind the windows on the strip.
/// When the last window closes, Striple is a menu bar app again.
struct DockPresence {
    private(set) var open: Set<String> = []

    var policy: NSApplication.ActivationPolicy { open.isEmpty ? .accessory : .regular }
    var hasOpenWindow: Bool { !open.isEmpty }

    /// The policy to set after `id` opened, or nil when it stays the same.
    mutating func opened(_ id: String) -> NSApplication.ActivationPolicy? {
        let before = policy
        open.insert(id)
        return policy == before ? nil : policy
    }

    /// True when the Striple window `closed` was the last one and only the update window is left. Sparkle shows a
    /// scheduled update to a regular app only when the app becomes active, so that update must be brought to the
    /// front now, else Striple stays in the Dock with no window.
    func onlyUpdateLeft(after closed: String) -> Bool {
        closed != UpdateWindows.window && closed != UpdateWindows.alert && open == [UpdateWindows.window]
    }

    /// The policy to set after `id` closed, or nil when it stays the same.
    mutating func closed(_ id: String) -> NSApplication.ActivationPolicy? {
        let before = policy
        open.remove(id)
        return policy == before ? nil : policy
    }
}
