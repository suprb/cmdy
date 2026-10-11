/// Cmdy's locale-neutral terminal-cell policy over pinned Unicode properties.
///
/// Width is a scalar-level input to the terminal's grapheme-cluster handling:
/// control scalars are rejected (-1), the generated compatibility-zero set is
/// zero-width, wide/fullwidth and default-emoji scalars occupy two columns, and
/// all remaining scalars (including East Asian Ambiguous) occupy one.
enum CmdyUnicodeWidthPolicy {
    @inline(__always)
    static func columnWidth(of scalar: UnicodeScalar) -> Int {
        // The generated map encodes the identical pinned width policy in two
        // bits per scalar. Deduplicated 256-scalar pages keep lookup constant
        // time without a mutable cache or a per-terminal allocation.
        let value = Int(scalar.value)
        let page = Int(GeneratedUnicodeWidthTables.widthPageIndices[value >> 8])
        let word = GeneratedUnicodeWidthTables.widthPageWords[
            page * 8 + ((value >> 5) & 7)]
        return Int((word >> ((value & 31) * 2)) & 3) - 1
    }

    @inline(__always)
    static func isRegionalIndicator(_ scalar: UnicodeScalar) -> Bool {
        contains(scalar.value, in: GeneratedUnicodeWidthTables.regionalIndicators)
    }

    @inline(__always)
    static func isEmojiVS16Base(_ scalar: UnicodeScalar) -> Bool {
        contains(scalar.value, in: GeneratedUnicodeWidthTables.emojiVS16Bases)
    }

    @inline(__always)
    static func isEastAsianAmbiguous(_ scalar: UnicodeScalar) -> Bool {
        contains(scalar.value, in: GeneratedUnicodeWidthTables.ambiguous)
    }

    @inline(__always)
    private static func contains(
        _ value: UInt32,
        in ranges: [CmdyUnicodeScalarRange]
    ) -> Bool {
        var lowerIndex = 0
        var upperIndex = ranges.count
        while lowerIndex < upperIndex {
            let middle = lowerIndex + (upperIndex - lowerIndex) / 2
            let range = ranges[middle]
            if value < range.lowerBound {
                upperIndex = middle
            } else if value > range.upperBound {
                lowerIndex = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}
