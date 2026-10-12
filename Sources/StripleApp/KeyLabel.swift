import Carbon
import Foundation
import StripleCore

/// Key labels for the active keyboard layout. A binding is stored by key code, so on AZERTY
/// the key code of US "A" shows as "Q".
@MainActor
enum KeyLabel {
    /// Modifiers in the macOS order ⌃⌥⇧⌘, then the key.
    static func label(_ combo: KeyCombo) -> String {
        combo.modifiers.symbols + keyName(combo.keyCode)
    }

    static func keyName(_ code: UInt16) -> String {
        if let fixed = fixedNames[code] { return fixed }
        if let typed = translate(code) { return typed.uppercased() }
        return KeyCode.usName(code)
    }

    /// Keys that do not type a character, or whose character is not a useful label.
    static let fixedNames: [UInt16: String] = {
        var names: [UInt16: String] = [
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
            114: "Help", 115: "Home", 119: "End", 116: "Page Up", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        for (i, code) in FunctionKeys.codes.enumerated() { names[code] = "F\(i + 1)" }
        return names
    }()

    private static func translate(_ code: UInt16) -> String? {
        withCurrentLayout { layout in
            var deadKeyState: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState,
                                        chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
            return text
        }
    }

    /// Input methods (for example Japanese) have no key layout data; then the ASCII layout is used.
    /// The input source owns the layout data, so it stays alive while `body` runs.
    private static func withCurrentLayout<T>(_ body: (UnsafePointer<UCKeyboardLayout>) -> T?) -> T? {
        for copy in [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource] {
            guard let source = copy()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            return withExtendedLifetime(source) {
                let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
                guard let bytes = CFDataGetBytePtr(data) else { return nil }
                return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1, body)
            }
        }
        return nil
    }

    /// Posted when the user picks another keyboard layout.
    static let layoutChanged = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
}

enum FunctionKeys {
    /// Key codes of F1 to F20, in order.
    static let codes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109,
                                  103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
}
