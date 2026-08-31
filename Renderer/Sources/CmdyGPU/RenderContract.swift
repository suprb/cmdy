import AppKit
import CoreGraphics
import CoreText
import Foundation

// Source-compatible native spellings retained at the public seam. The
// independent implementation itself uses AppKit types directly.
public typealias TTColor = NSColor
public typealias TTFont = NSFont
public typealias TTImage = NSImage

// MARK: - Public source boundary

/// A renderer input provider. Every requirement is read on the main actor.
/// `captureGrid()` establishes the coordinate snapshot for the rest of a draw.
@MainActor
public protocol MetalRenderSource: AnyObject {
    func captureGrid() -> GridSnapshot
    func lineInfo(forRow row: Int) -> ViewLineInfo
    func lineRenderMode(forRow row: Int) -> RenderLineMode
    func lineVersion(forRow row: Int) -> UInt64
    func cursorCellAttributedString() -> NSAttributedString?

    var kittyStamp: KittyCacheStamp { get }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec]
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload?
    var kittyLiveImageIds: Set<UInt32> { get }

    var viewBounds: CGRect { get }
    func backingScaleFactor() -> CGFloat
    var cellSize: CGSize { get }
    var normalFont: NSFont { get }
    func underlinePosition() -> CGFloat
    func underlineThickness() -> CGFloat
    var contentXOrigin: CGFloat { get }
    var topContentInset: CGFloat { get }
    var bottomContentInset: CGFloat { get }
    var leftContentInset: CGFloat { get }
    var scrollContentOffset: CGPoint { get }
    func getImageScale() -> CGFloat

    var nativeForegroundColor: NSColor { get }
    var nativeBackgroundColor: NSColor { get }
    var caretColor: NSColor { get }
    var caretTextColor: NSColor? { get }
    var caretFocused: Bool { get }
    var antiAliasCustomBlockGlyphs: Bool { get }
    var metalBufferingMode: MetalBufferingMode { get }

    func consumeDirtyRows() -> ClosedRange<Int>?
    var activityKeypressTime: Double { get }
    var activityTypingRate: Float { get }
}

/// An image attached to a retained terminal row. Identity, rather than pixel
/// equality, is the cache key.
public protocol RenderableCellImage: AnyObject {
    var image: NSImage { get }
    var pixelWidth: Int { get }
    var pixelHeight: Int { get }
    var col: Int { get }
    var kittyIsKitty: Bool { get }
    var kittyImageId: UInt32? { get }
    var kittyZIndex: Int { get }
    var kittyPixelOffsetX: Int { get }
    var kittyPixelOffsetY: Int { get }
}

public struct ViewLineSegment {
    public let column: Int
    public let columnWidth: Int
    public let characterCount: Int
    public let attributedString: NSAttributedString
    public let cellUTF16Boundaries: [Int]?

    public var columnSpan: Int {
        guard columnWidth > 0, characterCount > 0,
              columnWidth <= Int.max / characterCount else { return 0 }
        return columnWidth * characterCount
    }

    public init(column: Int,
                columnWidth: Int,
                characterCount: Int,
                attributedString: NSAttributedString,
                cellUTF16Boundaries: [Int]? = nil) {
        self.column = column
        self.columnWidth = max(0, columnWidth)
        self.characterCount = max(0, characterCount)
        self.attributedString = attributedString

        if let boundaries = cellUTF16Boundaries,
           boundaries.count == max(0, characterCount) + 1,
           boundaries.first == 0,
           boundaries.last == attributedString.length,
           zip(boundaries, boundaries.dropFirst()).allSatisfy({ $0 <= $1 }) {
            self.cellUTF16Boundaries = boundaries
        } else {
            self.cellUTF16Boundaries = nil
        }
    }
}

public struct ViewLineInfo {
    public var segments: [ViewLineSegment]
    public var images: [any RenderableCellImage]?
    public var kittyPlaceholders: [KittyPlaceholderCell]
    public var blockElements: [BlockElementRenderItem]
    public var boxDrawings: [BoxDrawingRenderItem]

    public init(segments: [ViewLineSegment],
                images: [any RenderableCellImage]?,
                kittyPlaceholders: [KittyPlaceholderCell] = [],
                blockElements: [BlockElementRenderItem] = [],
                boxDrawings: [BoxDrawingRenderItem] = []) {
        self.segments = segments
        self.images = images
        self.kittyPlaceholders = kittyPlaceholders
        self.blockElements = blockElements
        self.boxDrawings = boxDrawings
    }
}

public enum RenderLineMode: Hashable {
    case single
    case doubleWidth
    case doubledTop
    case doubledDown

    var horizontalScale: CGFloat {
        self == .single ? 1 : 2
    }
}

public enum RenderCursorStyle: Hashable {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar

    var blinks: Bool {
        switch self {
        case .blinkBlock, .blinkUnderline, .blinkBar: true
        default: false
        }
    }

    var isBlock: Bool {
        self == .blinkBlock || self == .steadyBlock
    }
}

public struct GridSnapshot {
    public let rows: Int
    public let cols: Int
    public let bufferLineCount: Int
    public let retainedRowOrigin: Int
    public let displayTopRow: Int
    public let liveTopRow: Int
    public let cursorRow: Int
    public let cursorCol: Int
    public let cursorHidden: Bool
    public let cursorStyle: RenderCursorStyle
    public let isAlternateBuffer: Bool

    public init(rows: Int,
                cols: Int,
                bufferLineCount: Int,
                retainedRowOrigin: Int = 0,
                displayTopRow: Int,
                liveTopRow: Int,
                cursorRow: Int,
                cursorCol: Int,
                cursorHidden: Bool,
                cursorStyle: RenderCursorStyle,
                isAlternateBuffer: Bool) {
        self.rows = max(0, rows)
        self.cols = max(0, cols)
        self.bufferLineCount = max(0, bufferLineCount)
        self.retainedRowOrigin = retainedRowOrigin
        self.displayTopRow = displayTopRow
        self.liveTopRow = liveTopRow
        self.cursorRow = cursorRow
        self.cursorCol = cursorCol
        self.cursorHidden = cursorHidden
        self.cursorStyle = cursorStyle
        self.isAlternateBuffer = isAlternateBuffer
    }
}

public enum MetalBufferingMode: Hashable {
    case perRowPersistent
    case perFrameAggregated
}

// MARK: - Graphics payloads

public struct KittyCacheStamp: Hashable {
    public let imagesCount: Int
    public let placementsCount: Int
    public let nextImageId: UInt32
    public let nextPlacementId: UInt32

    public init(imagesCount: Int,
                placementsCount: Int,
                nextImageId: UInt32,
                nextPlacementId: UInt32) {
        self.imagesCount = imagesCount
        self.placementsCount = placementsCount
        self.nextImageId = nextImageId
        self.nextPlacementId = nextPlacementId
    }
}

public struct KittyPlacementSpec {
    public let imageId: UInt32
    public let placementId: UInt32
    public let cols: Int
    public let rows: Int
    public let pixelOffsetX: Int
    public let pixelOffsetY: Int

    public init(imageId: UInt32,
                placementId: UInt32,
                cols: Int,
                rows: Int,
                pixelOffsetX: Int,
                pixelOffsetY: Int) {
        self.imageId = imageId
        self.placementId = placementId
        self.cols = max(0, cols)
        self.rows = max(0, rows)
        self.pixelOffsetX = pixelOffsetX
        self.pixelOffsetY = pixelOffsetY
    }
}

public enum KittyImagePayload {
    case png(Data)
    case rgba(bytes: [UInt8], width: Int, height: Int)
}

public struct KittyPlaceholderCell {
    public let row: Int
    public let col: Int
    public let imageId: UInt32
    public let placementId: UInt32
    public let placeholderRow: Int
    public let placeholderCol: Int
    public let msb: Int

    public init(row: Int,
                col: Int,
                imageId: UInt32,
                placementId: UInt32,
                placeholderRow: Int,
                placeholderCol: Int,
                msb: Int) {
        self.row = row
        self.col = col
        self.imageId = imageId
        self.placementId = placementId
        self.placeholderRow = placeholderRow
        self.placeholderCol = placeholderCol
        self.msb = msb
    }
}

// MARK: - Native attributed text vocabulary

/// Raw values deliberately remain stable across the shaping/renderer seam.
public enum RenderUnderlineStyle: UInt8, Hashable {
    case none = 0
    case single = 1
    case double = 2
    case curly = 3
    case dotted = 4
    case dashed = 5
}

extension NSAttributedString.Key {
    static let cmdyUnderlineStyle = NSAttributedString.Key("SwiftTermUnderlineStyle")
    static let cmdyUnderlineColor = NSAttributedString.Key("CmdyUnderlineColor")
    static let cmdySelectionBackground = NSAttributedString.Key("CmdySelectionBackground")
}

public extension NSAttributedString.Key {
    static let selectionBackgroundColor = NSAttributedString.Key("SwiftTerm_selectionBackgroundColor")
}

/// Global spellings are provided for code that shares attributes without an
/// extension import. They carry only cmdy-owned names.
public let CmdyUnderlineStyleKey = NSAttributedString.Key.cmdyUnderlineStyle

public enum TextRenderingMode: String, CaseIterable, Hashable {
    case current
    case ySnap = "y-snap"
    case atlasPadding = "atlas-padding"
    case nearest
    case highContrast = "high-contrast"
    case crisp

    // Frozen CmdyGPU resolves every preset to the same device-pixel baseline.
    // The preset names alter padding, sampling, or coverage only.
    var snapsY: Bool { true }
    var padsAtlas: Bool { self == .atlasPadding || self == .crisp }
    var usesNearestSampling: Bool { self == .nearest }
    var coverageExponent: Float {
        switch self {
        case .highContrast, .crisp: 1.55
        default: 1.35
        }
    }
    var coveragePower: Float {
        1 / coverageExponent
    }
}

// MARK: - Terminal-safe Unicode addressing

struct TerminalCellIndexMap: Sendable {
    let boundaries: [Int]
    var cellCount: Int { max(0, boundaries.count - 1) }

    init(text: String) {
        var offsets = [0]
        var utf16Offset = 0
        for character in text {
            utf16Offset += String(character).utf16.count
            offsets.append(utf16Offset)
        }
        boundaries = offsets
    }

    init(cellUTF16Boundaries: [Int]) {
        if cellUTF16Boundaries.isEmpty
            || cellUTF16Boundaries.first != 0
            || !zip(cellUTF16Boundaries, cellUTF16Boundaries.dropFirst())
                .allSatisfy({ $0 <= $1 }) {
            boundaries = [0]
        } else {
            boundaries = cellUTF16Boundaries
        }
    }

    func cellIndex(forUTF16Offset offset: Int) -> Int {
        guard cellCount > 0 else { return 0 }
        let clamped = min(max(0, offset), boundaries.last ?? 0)
        var low = 0
        var high = boundaries.count
        while low < high {
            let middle = (low + high) / 2
            if boundaries[middle] <= clamped { low = middle + 1 }
            else { high = middle }
        }
        return min(cellCount - 1, max(0, low - 1))
    }

    func cellRange(forUTF16Range range: NSRange) -> Range<Int> {
        guard cellCount > 0, range.length > 0 else {
            let index = min(cellCount, max(0, cellIndex(forUTF16Offset: range.location)))
            return index..<index
        }
        let lower = cellIndex(forUTF16Offset: range.location)
        let end = range.location.addingReportingOverflow(range.length)
        let lastOffset = end.overflow ? Int.max : max(range.location, end.partialValue - 1)
        let upper = min(cellCount, cellIndex(forUTF16Offset: lastOffset) + 1)
        return lower..<max(lower, upper)
    }
}

/// Returns a CoreText font descriptor with cell-merging OpenType features
/// disabled. Per-attributed-run `.ligature = 0` is still applied by the row
/// rasterizer because some fallback fonts do not honor descriptor features.
func terminalGridShapingFont(_ font: CTFont) -> CTFont {
    let tags: [[Any]] = ["liga", "clig", "dlig", "calt"].map { [$0, 0] }
    let descriptor = CTFontCopyFontDescriptor(font)
    let attributes = [
        kCTFontFeatureSettingsAttribute: tags as CFArray,
    ] as CFDictionary
    let shapedDescriptor = CTFontDescriptorCreateCopyWithAttributes(descriptor, attributes)
    return CTFontCreateWithFontDescriptor(shapedDescriptor, CTFontGetSize(font), nil)
}

/// Optional cmdy composition state layered over immutable terminal rows.
/// Keeping it separate preserves the stable renderer-source compatibility seam
/// while allowing live selection to avoid row-texture invalidation entirely.
@MainActor
public protocol MetalSelectionRenderSource: AnyObject {
    func selectionColumns(forRow row: Int) -> ClosedRange<Int>?
    var selectionBackgroundColor: NSColor { get }
}
