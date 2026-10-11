import Foundation

/// SGR style flags. Raw values mirror the classic bitfield so differential
/// comparison against other engines is a plain integer compare.
public struct CellStyle: OptionSet, Equatable, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let none: CellStyle = []
    public static let bold = CellStyle(rawValue: 1)
    public static let underline = CellStyle(rawValue: 2)
    public static let blink = CellStyle(rawValue: 4)
    public static let inverse = CellStyle(rawValue: 8)
    public static let invisible = CellStyle(rawValue: 16)
    public static let dim = CellStyle(rawValue: 32)
    public static let italic = CellStyle(rawValue: 64)
    public static let crossedOut = CellStyle(rawValue: 128)
}

/// SGR 4:x underline flavors.
public enum UnderlineKind: UInt8, Equatable, Hashable, Sendable {
    case none = 0, single = 1, double = 2, curly = 3, dotted = 4, dashed = 5
}

/// A cell's color in the terminal's palette model.
public enum CellColor: Equatable, Hashable, Sendable {
    /// Indexed: 0-15 ANSI, 16-231 cube, 232-255 grays.
    case ansi256(UInt8)
    case trueColor(UInt8, UInt8, UInt8)
    /// The terminal's default for the position it appears in — the front
    /// end resolves it (fg default in fg position, bg default in bg).
    case defaultColor
    /// The INVERTED default (reverse-video state checks only; the pen
    /// never writes it — SGR 0/39/49 all reset to defaultColor).
    case defaultInverted
}

/// Everything about how one cell is drawn, minus the character itself.
public struct CellAttribute: Equatable, Hashable, Sendable {
    public var fg: CellColor
    public var bg: CellColor
    public var style: CellStyle
    public var underlineKind: UnderlineKind
    public var underlineColor: CellColor?

    public init(fg: CellColor = .defaultColor,
                bg: CellColor = .defaultColor,
                style: CellStyle = .none,
                underlineKind: UnderlineKind = .none,
                underlineColor: CellColor? = nil) {
        self.fg = fg
        self.bg = bg
        self.style = style
        self.underlineKind = underlineKind
        self.underlineColor = underlineColor
    }

    /// The canonical default: fg AND bg both carry the defaultColor token —
    /// pen resets (SGR 0/39/49), blank cells, and erases all agree (mirrors
    /// the reference engine's defaultAttr, observed via the harness).
    public static let empty = CellAttribute()
    public static let bufferDefault = CellAttribute()
}

/// One grid cell: a scalar (or grapheme-cluster spill), its display width,
/// and its attribute. `width == 0` marks the continuation cell of a wide
/// character; those cells carry scalar 0.
public struct Cell: Equatable, Sendable {
    /// The primary Unicode scalar, or 0 for empty/continuation cells.
    public var scalar: UInt32
    /// Extra combining scalars when this cell holds a full cluster (rare).
    public var clusterExtras: [UInt32]?
    /// Columns occupied: 1 normal, 2 wide (CJK/emoji), 0 continuation.
    public var width: Int8
    public var attribute: CellAttribute
    /// OSC 8 hyperlink id (index into the engine's link table), 0 = none.
    public var linkId: UInt16

    public init(scalar: UInt32 = 0,
                clusterExtras: [UInt32]? = nil,
                width: Int8 = 1,
                attribute: CellAttribute = .bufferDefault,
                linkId: UInt16 = 0) {
        self.scalar = scalar
        self.clusterExtras = clusterExtras
        self.width = width
        self.attribute = attribute
        self.linkId = linkId
    }

    /// A blank cell drawn with the given attribute (EL/ED fill semantics:
    /// erased cells keep the pen's background).
    public static func blank(attribute: CellAttribute) -> Cell {
        Cell(scalar: 0, width: 1, attribute: attribute)
    }

    /// The character to show; space for blanks.
    public var character: Character {
        guard scalar != 0, let first = Unicode.Scalar(scalar) else { return " " }
        guard let extras = clusterExtras, !extras.isEmpty else { return Character(first) }
        var s = String(first)
        for e in extras {
            if let u = Unicode.Scalar(e) { s.unicodeScalars.append(u) }
        }
        return s.first ?? Character(first)
    }

    /// The cell's full text (may be multi-scalar); empty string for blanks.
    public var text: String {
        scalar == 0 ? "" : String(character)
    }
}
