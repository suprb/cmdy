import CmdyNative

enum CmdyUnicodeWidthPolicy {
    static func columnWidth(of scalar: UnicodeScalar) -> Int {
        Int(cmdy_zig_scalar_width(scalar.value))
    }
    static func isRegionalIndicator(_ scalar: UnicodeScalar) -> Bool {
        cmdy_zig_scalar_property(scalar.value, 1) != 0
    }
    static func isEmojiVS16Base(_ scalar: UnicodeScalar) -> Bool {
        cmdy_zig_scalar_vs16_base(scalar.value) != 0
    }
    static func isEastAsianAmbiguous(_ scalar: UnicodeScalar) -> Bool {
        cmdy_zig_scalar_property(scalar.value, 2) != 0
    }
}

enum UnicodeUtil {
    static func columnWidth(rune: UnicodeScalar) -> Int {
        CmdyUnicodeWidthPolicy.columnWidth(of: rune)
    }
}
