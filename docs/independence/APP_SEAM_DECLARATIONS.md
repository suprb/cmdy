# CmdyCore shaping and surface seam declarations

Status: implementation-free App seam manifest

Behavioral authority: `SHAPING_SURFACE_CONTRACT.md`

Public renderer authority: `CMDYGPU_PUBLIC_API.md`

This is the declaration-level handoff for an independent App integration. It is not a public binary API: the App is an executable target and these declarations are internal unless a referenced protocol says otherwise. Bodies, private helpers, constants, storage strategy, and former comments are intentionally excluded.

## Surface declaration

`CmdyTerminalSurface` is main-actor/AppKit isolated and is the one terminal
surface held by each terminal pane. Snapshot conversion lives separately in
`App/CmdySnapshotShaper.swift`.

```swift
@MainActor
final class CmdyTerminalSurface: NSView, TerminalSurface, TerminalSession {
    let terminal: TerminalModel
    private(set) var renderSnapshot: CoreTerminalSnapshot
    var frameSnapshot: CoreTerminalSnapshot

    var onSendToProcess: ((ArraySlice<UInt8>) -> Void)?
    var onPasteRequest: ((String) -> String?)?
    var onTerminalMouseDown: (() -> Void)?
    var onOpenLink: ((URL) -> Void)?
    var onSizeChanged: ((Int, Int) -> Void)?
    var onTitleChanged: ((String) -> Void)?
    var onBell: (() -> Void)?
    var onNotification: ((String, String) -> Void)?
    var onCwdChanged: ((String?) -> Void)?
    var onProcessTerminated: ((Int32?) -> Void)?
    var willReflowBuffer: (() -> Void)?
    var didReflowBuffer: (() -> Void)?
    var onViewportChanged: (() -> Void)?
    var onSelectionChanged: (() -> Void)?

    private(set) var cellDimension: CGSize
    var lineHeightMultiplier: CGFloat { get set }
    var font: NSFont { get set }
    var cellSize: CGSize { get }
    var textBaselineFromRowTop: CGFloat { get }

    var nativeForegroundColor: NSColor { get set }
    var nativeBackgroundColor: NSColor { get set }
    var caretColor: NSColor { get set }
    var caretTextColor: NSColor? { get set }
    var selectedTextBackgroundColor: NSColor { get set }
    var optionAsMetaKey: Bool { get set }

    var topContentInset: CGFloat { get set }
    var bottomContentInset: CGFloat { get set }
    var leftContentInset: CGFloat { get set }
    var rightContentInset: CGFloat { get set }
    var showsScroller: Bool { get set }
    var contentXOrigin: CGFloat { get }

    private(set) var metalView: MTKView?
    private(set) var metalRenderer: MetalTerminalRenderer?
    var shaderMode: Int { get set }
    var textRenderingModeName: String { get set }
    var smoothCursor: Bool { get set }
    var hostCursorHidden: Bool { get set }
    var cursorGlideSpeed: CGFloat { get set }
    var cursorGlideMaxDistance: CGFloat { get set }
    var smoothScroll: Bool { get set }
    var failedBlockRows: Set<Int> { get set }
    var failedBlockForegroundColor: NSColor { get set }
    var failedBlockBackgroundColor: NSColor { get set }
    private(set) var visualScrollOffset: CGFloat
    var activityKeypressTime: Double { get set }
    var activityTypingRate: Float { get set }

    override init(frame: CGRect)
    override func setFrameSize(_ newSize: NSSize)
    override func viewDidMoveToWindow()
    override var acceptsFirstResponder: Bool { get }
    override var mouseDownCanMoveWindow: Bool { get }
    override func keyDown(with event: NSEvent)
    override func mouseDown(with event: NSEvent)
    override func mouseDragged(with event: NSEvent)
    override func mouseUp(with event: NSEvent)
    override func scrollWheel(with event: NSEvent)
    override func updateTrackingAreas()
    override func mouseMoved(with event: NSEvent)
    override func mouseExited(with event: NSEvent)
    override func flagsChanged(with event: NSEvent)
    override func resetCursorRects()
    override func viewDidEndLiveResize()

    @objc func paste(_ sender: Any?)
    @objc func copy(_ sender: Any?)
    @objc override func selectAll(_ sender: Any?)

    var view: NSView { get }
    var engine: TerminalEngine { get }
    func send(txt: String)
    func feed(text: String)
    func installColors(_ colors: [TermColor])
    func setUseMetal(_ on: Bool) throws
    var isUsingMetalRenderer: Bool { get }
    @discardableResult func setUserShader(_ source: String?) -> String?
    func forceRedraw()
    func queueDisplay()

    func scrollTo(row: Int)
    func scrollUp(lines: Int)
    func scrollDown(lines: Int)
    var scrollPosition: Double { get }
    var canScroll: Bool { get }
    func resetScrollOffset()

    func selectedText() -> String
    func selectAllContent()
    @discardableResult func adjustSelection(
        _ adjustment: TerminalSelectionAdjustment
    ) -> Bool
    @discardableResult func scrollSelectionIntoView() -> Bool
    func selectedColumnsForShaping(row: Int) -> ClosedRange<Int>?

    @discardableResult func findNext(
        _ term: String,
        options: TermSearchOptions
    ) -> Bool
    @discardableResult func findPrevious(
        _ term: String,
        options: TermSearchOptions
    ) -> Bool
    func searchStatus(
        _ term: String,
        options: TermSearchOptions
    ) -> (index: Int, total: Int)
    func clearSearch()

    func linkURL(at point: NSPoint) -> URL?
    func paletteColor(_ index: Int) -> NSColor
    func fontVariant(bold: Bool, italic: Bool) -> NSFont
    static func defaultPalette() -> [NSColor]
    static func returnKeyBytes(
        modifiers: NSEvent.ModifierFlags,
        kittyKeyboardFlags: Int
    ) -> [UInt8]

    func startProcess(
        executable: String,
        args: [String],
        environment: [String]?,
        currentDirectory: String?
    )
    func terminate()
    var shellPid: pid_t { get }
}
```

`scrollAccumulatorForTesting: CGFloat` and `windowObserverCountForTesting: Int`
are test-only observation seams. They need not be promoted into a product
protocol.

## Renderer-source conformance

`CmdyTerminalSurface.swift` supplies this internal conformance and delegates
pure snapshot conversion to `CmdySnapshotShaper`. Types and actor isolation are
inherited from the public renderer protocol.

```swift
extension CmdyTerminalSurface: MetalRenderSource {
    func captureGrid() -> GridSnapshot
    func lineInfo(forRow row: Int) -> ViewLineInfo
    func lineRenderMode(forRow row: Int) -> CmdyGPU.RenderLineMode
    func lineVersion(forRow row: Int) -> UInt64
    func cursorCellAttributedString() -> NSAttributedString?

    var kittyStamp: KittyCacheStamp { get }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec]
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload?
    var kittyLiveImageIds: Set<UInt32> { get }

    var viewBounds: CGRect { get }
    func backingScaleFactor() -> CGFloat
    var normalFont: NSFont { get }
    func underlinePosition() -> CGFloat
    func underlineThickness() -> CGFloat
    var scrollContentOffset: CGPoint { get }
    func getImageScale() -> CGFloat
    var caretFocused: Bool { get }
    var antiAliasCustomBlockGlyphs: Bool { get }
    var metalBufferingMode: MetalBufferingMode { get }
    func consumeDirtyRows() -> ClosedRange<Int>?

    func mapColor(_ color: CellColor, isFg: Bool, isBold: Bool) -> NSColor
    func attributes(
        for attribute: CellAttribute,
        selected: Bool
    ) -> [NSAttributedString.Key: Any]
    func selectionColumnsForShaping(
        absoluteRow row: Int
    ) -> ClosedRange<Int>?
}
```

The internal image bridge remains identity-bearing because renderer texture caching is identity-based:

```swift
@MainActor
final class CmdyCellImage: RenderableCellImage {
    static func wrap(_ source: CoreLineImageSnapshot) -> CmdyCellImage
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    var col: Int
    let kittyIsKitty: Bool
    let kittyImageId: UInt32?
    let kittyZIndex: Int
    let kittyPixelOffsetX: Int
    let kittyPixelOffsetY: Int
}
```

## Model-observer conformance

```swift
extension CmdyTerminalSurface: TerminalModelObserver {
    func terminalModel(
        _ model: TerminalModel,
        didPublish snapshot: CoreTerminalSnapshot
    )
    func terminalModel(_ model: TerminalModel, didSetTitle title: String)
    func terminalModel(
        _ model: TerminalModel,
        didSetCurrentDirectory directory: String?
    )
    func terminalModelDidBell(_ model: TerminalModel)
    func terminalModel(
        _ model: TerminalModel,
        didRequestNotification title: String,
        body: String
    )
    func terminalModel(
        _ model: TerminalModel,
        didRequestClipboardCopy content: Data
    )
    func terminalModel(_ model: TerminalModel, didSend data: [UInt8])
    func terminalModel(
        _ model: TerminalModel,
        processTerminated exitCode: Int32?
    )
    func consumePublishedDirtyRows() -> ClosedRange<Int>?
}
```

## Source-of-truth public protocols

The class must continue to conform to the declarations in `Kit/Sources/CmdyKit/TerminalCoreProtocols.swift`, especially `TerminalEngine`, `TerminalSurface`, and `TerminalSession`. Do not duplicate or privately narrow those public protocols. Compile-time conformance plus the behavioral contract is the App seam gate.

This manifest uses cmdy names even where the frozen historical declaration used a former product prefix. A name-only product migration is not a behavior or provenance exception.
