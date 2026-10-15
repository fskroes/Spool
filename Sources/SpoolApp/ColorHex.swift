import CoreGraphics
import Foundation
import SpoolCore

/// Converts between `#RRGGBB` / `#RRGGBBAA` strings and sRGB components (0...1).
enum ColorHex {
    struct RGBA: Equatable {
        var red: Double, green: Double, blue: Double, alpha: Double
    }

    /// Accepts `#RGB`, `#RRGGBB` and `#RRGGBBAA`, with or without `#`. Returns nil for anything else.
    static func parse(_ text: String) -> RGBA? {
        var hex = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6 || hex.count == 8, let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let v = hasAlpha ? value : (value << 8) | 0xFF
        func byte(_ shift: UInt64) -> Double { Double((v >> shift) & 0xFF) / 255 }
        return RGBA(red: byte(24), green: byte(16), blue: byte(8), alpha: byte(0))
    }

    /// `#RRGGBB` when the colour is opaque, else `#RRGGBBAA`. Components are clamped to 0...1.
    static func format(_ c: RGBA) -> String {
        func byte(_ x: Double) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        let rgb = String(format: "#%02X%02X%02X", byte(c.red), byte(c.green), byte(c.blue))
        return byte(c.alpha) == 255 ? rgb : rgb + String(format: "%02X", byte(c.alpha))
    }

    static func cgColor(_ text: String, fallback: String = AppearanceSettings().borderColor) -> CGColor {
        let c = parse(text) ?? parse(fallback) ?? RGBA(red: 0.3, green: 0.55, blue: 1, alpha: 1)
        return CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: c.alpha)
    }

    static func string(_ color: CGColor) -> String? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: srgb, intent: .defaultIntent, options: nil),
              let comps = converted.components, comps.count >= 3 else { return nil }
        let alpha = comps.count >= 4 ? Double(comps[3]) : 1
        return format(RGBA(red: Double(comps[0]), green: Double(comps[1]), blue: Double(comps[2]), alpha: alpha))
    }
}
