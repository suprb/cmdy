/// Compatibility facade for CmdyCore's scalar-width call sites.
///
/// The implementation and generated Unicode 17.0 tables are Cmdy-owned; this
/// type stays intentionally internal because cell width is an engine policy,
/// not a public API contract.
struct UnicodeUtil {
    @inline(__always)
    static func columnWidth(rune: UnicodeScalar) -> Int {
        CmdyUnicodeWidthPolicy.columnWidth(of: rune)
    }

    @inline(__always)
    static func isRegionalIndicator(_ rune: UnicodeScalar) -> Bool {
        CmdyUnicodeWidthPolicy.isRegionalIndicator(rune)
    }

    @inline(__always)
    static func isEmojiVs16Base(rune: UnicodeScalar) -> Bool {
        CmdyUnicodeWidthPolicy.isEmojiVS16Base(rune)
    }
}
