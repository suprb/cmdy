# CmdyGPU frozen public API manifest

Status: implementation-free compatibility manifest

Baseline module: `CmdyGPU` compiled before replacement at repository ref `584624985809f6000a82d3b3b97e43ef885af572`

Machine-readable authorities: `docs/independence/baselines/CmdyGPU.symbols.json`
and `docs/independence/baselines/CmdyGPU@Foundation.symbols.json`

This file records declarations, not algorithms. It deliberately omits bodies, private types, shader source, buffer layouts, cache constants, and implementation comments. If this readable manifest and the API-digester JSON disagree, the JSON is authoritative.

## Imports and availability

The frozen macOS API imports AppKit, CoreGraphics, CoreText, Foundation, Metal, and MetalKit. `MetalRenderSource` and `MetalTerminalRenderer` are main-actor isolated.

## Declarations

```swift
public enum BlockAlpha: CGFloat, Sendable {
    case full = 1.0
    case dark = 0.75
    case medium = 0.5
    case light = 0.25
}

public struct BlockElementRect: Sendable {
    public let x0: UInt8
    public let x1: UInt8
    public let y0: UInt8
    public let y1: UInt8
    public let alpha: BlockAlpha
    public func rect(
        in cellOrigin: CGPoint,
        xEighth: CGFloat,
        yEighth: CGFloat,
        cellHeight: CGFloat
    ) -> CGRect
}

public struct BlockElementMapping {
    public static func rects(for codePoint: UInt32) -> [BlockElementRect]?
    public static let lowerBoundary: Int
    public static let upperBoundary: Int
}

public struct BlockElementRenderItem {
    public let column: Int
    public let columnWidth: Int
    public let codePoint: UInt32
    public let rects: [BlockElementRect]
    public let foregroundColor: TTColor
    public init(
        column: Int,
        columnWidth: Int,
        codePoint: UInt32,
        rects: [BlockElementRect],
        foregroundColor: TTColor
    )
}

public struct BoxDrawingRenderer {
    public static let lowerBoundary: Int32
    public static let upperBoundary: Int32
    public static func draw(
        codePoint: UInt32,
        in context: CGContext,
        cellOrigin: CGPoint,
        cellSize: CGSize,
        scale: CGFloat,
        color: TTColor,
        baseThicknessPx: Int
    )
}

public struct BoxDrawingRenderItem {
    public let column: Int
    public let columnWidth: Int
    public let codePoint: UInt32
    public let foregroundColor: TTColor
    public init(
        column: Int,
        columnWidth: Int,
        codePoint: UInt32,
        foregroundColor: TTColor
    )
}

public enum MetalBufferingMode {
    case perRowPersistent
    case perFrameAggregated
}

public enum MetalError: Error, CustomStringConvertible {
    case metalKitUnavailable
    case deviceUnavailable
    case commandQueueUnavailable
    case atlasUnavailable
    case shaderLibraryMissing
    case shaderLibraryLoadFailed(String)
    case shaderFunctionMissing(String)
    case shaderSourceMissing(String)
    case shaderCompilationFailed(String)
    case pipelineCreationFailed(String)
    case samplerUnavailable
    public var description: String { get }
}

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

public enum TextRenderingMode: String, CaseIterable {
    case current
    case ySnap = "y-snap"
    case atlasPadding = "atlas-padding"
    case nearest
    case highContrast = "high-contrast"
    case crisp
}

@MainActor
public final class MetalTerminalRenderer: NSObject, MTKViewDelegate {
    public static var framesPresented: Int { get set }
    public static var rowsRebuilt: Int { get set }
    public static var rowsReused: Int { get set }

    public var shaderMode: Int { get set }
    public var smoothCursorEnabled: Bool { get set }
    public var hostCursorHidden: Bool { get set }
    public var cursorGlideSpeed: Float { get set }
    public var cursorGlideMaxDistance: Float { get set }
    public var smoothScrollEnabled: Bool { get set }
    public var textRenderingMode: TextRenderingMode { get set }
    public var onScrollOffsetChanged: ((CGFloat) -> Void)? { get set }

    public init(view: MTKView, source: any MetalRenderSource) throws
    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize)
    public func draw(in view: MTKView)
    @discardableResult public func loadUserShader(source: String?) -> String?
    public static let userShaderPreamble: String
    public func noteScroll(pixels: CGFloat)
    public func setScrollHeld(_ pixels: CGFloat)
    public func noteScrollActivity(pixels: CGFloat)
    public func cancelScrollAnimation()
    public func noteActivity()
    public func invalidateRowCache()
}

public typealias TTColor = NSColor
public typealias TTFont = NSFont
public typealias TTImage = NSImage

public enum RenderUnderlineStyle: UInt8 {
    case none = 0
    case single = 1
    case double = 2
    case curly = 3
    case dotted = 4
    case dashed = 5
}

public let SwiftTermUnderlineStyleKey: NSAttributedString.Key

public extension NSAttributedString.Key {
    static let selectionBackgroundColor: NSAttributedString.Key
}

public struct ViewLineSegment {
    public let column: Int
    public let columnWidth: Int
    public let characterCount: Int
    public let attributedString: NSAttributedString
    public let cellUTF16Boundaries: [Int]?
    public var columnSpan: Int { get }
    public init(
        column: Int,
        columnWidth: Int,
        characterCount: Int,
        attributedString: NSAttributedString,
        cellUTF16Boundaries: [Int]? = nil
    )
}

public struct ViewLineInfo {
    public var segments: [ViewLineSegment]
    public var images: [any RenderableCellImage]?
    public var kittyPlaceholders: [KittyPlaceholderCell]
    public var blockElements: [BlockElementRenderItem]
    public var boxDrawings: [BoxDrawingRenderItem]
    public init(
        segments: [ViewLineSegment],
        images: [any RenderableCellImage]?,
        kittyPlaceholders: [KittyPlaceholderCell] = [],
        blockElements: [BlockElementRenderItem] = [],
        boxDrawings: [BoxDrawingRenderItem] = []
    )
}

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

public struct KittyPlaceholderCell {
    public let row: Int
    public let col: Int
    public let imageId: UInt32
    public let placementId: UInt32
    public let placeholderRow: Int
    public let placeholderCol: Int
    public let msb: Int
    public init(
        row: Int,
        col: Int,
        imageId: UInt32,
        placementId: UInt32,
        placeholderRow: Int,
        placeholderCol: Int,
        msb: Int
    )
}

public enum RenderLineMode {
    case single
    case doubleWidth
    case doubledTop
    case doubledDown
}

public enum RenderCursorStyle {
    case blinkBlock
    case steadyBlock
    case blinkUnderline
    case steadyUnderline
    case blinkBar
    case steadyBar
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
    public init(
        rows: Int,
        cols: Int,
        bufferLineCount: Int,
        retainedRowOrigin: Int = 0,
        displayTopRow: Int,
        liveTopRow: Int,
        cursorRow: Int,
        cursorCol: Int,
        cursorHidden: Bool,
        cursorStyle: RenderCursorStyle,
        isAlternateBuffer: Bool
    )
}

public struct KittyCacheStamp: Hashable {
    public let imagesCount: Int
    public let placementsCount: Int
    public let nextImageId: UInt32
    public let nextPlacementId: UInt32
    public init(
        imagesCount: Int,
        placementsCount: Int,
        nextImageId: UInt32,
        nextPlacementId: UInt32
    )
}

public enum KittyImagePayload {
    case png(Data)
    case rgba(bytes: [UInt8], width: Int, height: Int)
}

public struct KittyPlacementSpec {
    public let imageId: UInt32
    public let placementId: UInt32
    public let cols: Int
    public let rows: Int
    public let pixelOffsetX: Int
    public let pixelOffsetY: Int
    public init(
        imageId: UInt32,
        placementId: UInt32,
        cols: Int,
        rows: Int,
        pixelOffsetX: Int,
        pixelOffsetY: Int
    )
}
```

## Compatibility-name policy

`TTColor`, `TTFont`, and `TTImage` are frozen source/API aliases. Their presence does not require derived implementation; an independent module may retain them as deprecated declaration-only aliases while using AppKit names internally.

`SwiftTermUnderlineStyleKey` is the one approved name-only exception: the independent public API exposes the same typed global as `CmdyUnderlineStyleKey`. The API gate verifies this exact replacement and remains strict for every other declaration. This rename does not permit changing the raw attribute behavior described by the renderer/surface contract.

## Diff gate

The frozen public symbol graphs include conformances and Foundation-extension
exposure that this readable manifest does not spell out. Use
`scripts/check-independent-api.sh` for the strict comparison. Any delta
requires a written compatibility decision. Historical private-layout ABI JSON
is retained for provenance, not equality.
