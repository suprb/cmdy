import SwiftUI

/// Small host-supplied palette used by Bridge's window-edge affordances.
/// Stored as RGB integers so the value is Equatable/Sendable and cheap to
/// publish through SwiftUI without retaining AppKit color objects.
struct BridgeVisualTheme: Equatable, Sendable {
    let background: UInt32
    let foreground: UInt32
    let accent: UInt32
    let border: UInt32

    static let fallback = BridgeVisualTheme(
        background: 0x111827,
        foreground: 0xF9FAFB,
        accent: 0x3B82F6,
        border: 0x374151
    )

    init(backgroundHex: String, foregroundHex: String,
         accentHex: String, borderHex: String) {
        background = Self.rgb(backgroundHex) ?? Self.fallback.background
        foreground = Self.rgb(foregroundHex) ?? Self.fallback.foreground
        accent = Self.rgb(accentHex) ?? Self.fallback.accent
        border = Self.rgb(borderHex) ?? Self.fallback.border
    }

    private init(background: UInt32, foreground: UInt32,
                 accent: UInt32, border: UInt32) {
        self.background = background
        self.foreground = foreground
        self.accent = accent
        self.border = border
    }

    private static func rgb(_ value: String) -> UInt32? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard digits.count == 6 else { return nil }
        return UInt32(digits, radix: 16)
    }

    var backgroundColor: Color { color(background) }
    var foregroundColor: Color { color(foreground) }
    var accentColor: Color { color(accent) }
    var borderColor: Color { color(border) }

    private func color(_ rgb: UInt32) -> Color {
        Color(.sRGB,
              red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255,
              opacity: 1)
    }
}
