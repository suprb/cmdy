import AppKit
import Metal
import MetalKit
import XCTest
@testable import CmdyGPU

@MainActor
final class RowCacheMemoryTests: XCTestCase {
    private let budget = 20 * 1_024 * 1_024

    func testThreeViewportASCIIResidencyUsesExactAllocatedSizesAndHonorsBudget() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalTerminalRenderer(
            view: MTKView(frame: .zero, device: device),
            source: MemoryRenderSource())

        // A large Retina pane: 3000 physical pixels wide, 32 pixels per row,
        // and 90 visible rows. Three viewports intentionally exceed 20 MiB so
        // the production residency policy must evict only older, non-visible
        // rows until the exact Metal allocation total is within budget.
        let viewportRows = 90
        let totalRows = viewportRows * 3
        var entries: [Int: IndependentRowCacheEntry] = [:]
        entries.reserveCapacity(totalRows)
        for row in 0..<totalRows {
            let coverage = try makeTexture(device: device, format: .r8Unorm,
                                           width: 3_000, height: 32)
            entries[row] = entry(row: row, coverage: coverage,
                                 colorLayers: [], lastUse: UInt64(row))
        }
        let untrimmed = entries.values.reduce(0) { $0 + $1.allocatedBytes }
        XCTAssertGreaterThan(untrimmed, budget)

        let visible = Set((totalRows - viewportRows)..<totalRows)
        renderer.replaceAndTrimRowCacheForTesting(
            entries, visibleRows: visible, visibleCount: viewportRows)

        XCTAssertLessThanOrEqual(renderer.rowCacheAllocatedBytesForTesting, budget)
        XCTAssertGreaterThanOrEqual(renderer.rowCacheCountForTesting, viewportRows)
        XCTAssertLessThan(renderer.rowCacheCountForTesting, totalRows)
    }

    func testASCIIRowsDoNotAllocateBGRATexturesAndColorIsSparse() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let coverage = try makeTexture(device: device, format: .r8Unorm,
                                       width: 3_000, height: 32)
        let ascii = entry(row: 0, coverage: coverage,
                          colorLayers: [], lastUse: 0)
        XCTAssertEqual(ascii.allocatedBytes, coverage.allocatedSize)

        let emoji = try makeTexture(device: device, format: .bgra8Unorm,
                                    width: 32, height: 32)
        let mixed = entry(
            row: 1,
            coverage: coverage,
            colorLayers: [IndependentColorLayer(
                texture: emoji,
                rect: CGRect(x: 0, y: 0, width: 32, height: 32))],
            lastUse: 1)
        XCTAssertEqual(mixed.allocatedBytes,
                       coverage.allocatedSize + emoji.allocatedSize)
        XCTAssertLessThan(emoji.allocatedSize, coverage.allocatedSize)
    }

    func testSharedTextTextureCountsOnceAgainstTheResidencyBudget() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalTerminalRenderer(
            view: MTKView(frame: .zero, device: device),
            source: MemoryRenderSource())
        let coverage = try makeTexture(device: device, format: .r8Unorm,
                                       width: 512, height: 20)
        let entries = [
            0: entry(row: 0, coverage: coverage,
                     colorLayers: [], lastUse: 0),
            1: entry(row: 1, coverage: coverage,
                     colorLayers: [], lastUse: 1),
        ]

        renderer.replaceAndTrimRowCacheForTesting(
            entries, visibleRows: [0, 1], visibleCount: 2)

        XCTAssertEqual(renderer.rowCacheCountForTesting, 2)
        XCTAssertEqual(renderer.rowCacheAllocatedBytesForTesting,
                       coverage.allocatedSize)
    }

    func testSharedTextKeyIgnoresTerminalIdentityAndBindsRasterContent() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: 0,
        ]
        let info = ViewLineInfo(segments: [
            ViewLineSegment(
                column: 0, columnWidth: 1, characterCount: 6,
                attributedString: NSAttributedString(
                    string: "repeat", attributes: attributes)),
        ], images: nil)
        let first = try XCTUnwrap(IndependentSharedTextRowKey(
            info: info, rowKey: rowKey(row: 1, version: 4)))
        let moved = try XCTUnwrap(IndependentSharedTextRowKey(
            info: info, rowKey: rowKey(row: 800, version: 99)))
        XCTAssertEqual(first, moved)

        let changedInfo = ViewLineInfo(segments: [
            ViewLineSegment(
                column: 0, columnWidth: 1, characterCount: 6,
                attributedString: NSAttributedString(
                    string: "repeat", attributes: attributes.merging([
                        .foregroundColor: NSColor.systemRed,
                    ], uniquingKeysWith: { _, replacement in replacement }))),
        ], images: nil)
        XCTAssertNotEqual(first, IndependentSharedTextRowKey(
            info: changedInfo, rowKey: rowKey(row: 800, version: 99)))

        let unsupportedInfo = ViewLineInfo(segments: [
            ViewLineSegment(
                column: 0, columnWidth: 1, characterCount: 6,
                attributedString: NSAttributedString(
                    string: "repeat", attributes: [
                        NSAttributedString.Key("cmdy.unmodeled"): "value",
                    ])),
        ], images: nil)
        XCTAssertNil(IndependentSharedTextRowKey(
            info: unsupportedInfo, rowKey: rowKey(row: 1, version: 4)))
    }

    private func makeTexture(device: MTLDevice,
                             format: MTLPixelFormat,
                             width: Int,
                             height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func entry(row: Int,
                       coverage: MTLTexture,
                       colorLayers: [IndependentColorLayer],
                       lastUse: UInt64) -> IndependentRowCacheEntry {
        let key = rowKey(row: row, version: 1,
                         width: coverage.width, height: coverage.height)
        return IndependentRowCacheEntry(
            key: key, sharedTextKey: nil,
            coverageTexture: coverage,
            colorLayers: colorLayers,
            backgrounds: [],
            tintSpans: [],
            decorations: [],
            images: [],
            kittyPlaceholders: [],
            width: coverage.width,
            height: coverage.height,
            lastUse: lastUse)
    }

    private func rowKey(row: Int,
                        version: UInt64,
                        width: Int = 3_000,
                        height: Int = 32) -> IndependentRowKey {
        IndependentRowKey(
            absoluteRow: row,
            version: version,
            lineMode: .single,
            cols: 240,
            widthPx: width,
            heightPx: height,
            scaleBits: Double(2).bitPattern,
            fontName: "Menlo-Regular",
            fontSizeBits: Double(14).bitPattern,
            alternateBuffer: false,
            kittyStamp: KittyCacheStamp(imagesCount: 0, placementsCount: 0,
                                        nextImageId: 0, nextPlacementId: 0),
            foreground: 0,
            background: 0,
            preset: .current,
            antialiasBlocks: true,
            bufferingMode: .perRowPersistent)
    }
}

@MainActor
final class MemoryRenderSource: MetalRenderSource {
    func captureGrid() -> GridSnapshot {
        GridSnapshot(rows: 0, cols: 0, bufferLineCount: 0,
                     displayTopRow: 0, liveTopRow: 0,
                     cursorRow: 0, cursorCol: 0,
                     cursorHidden: true, cursorStyle: .steadyBlock,
                     isAlternateBuffer: false)
    }

    func lineInfo(forRow row: Int) -> ViewLineInfo {
        ViewLineInfo(segments: [], images: nil)
    }
    func lineRenderMode(forRow row: Int) -> RenderLineMode { .single }
    func lineVersion(forRow row: Int) -> UInt64 { 0 }
    func cursorCellAttributedString() -> NSAttributedString? { nil }
    var kittyStamp: KittyCacheStamp {
        KittyCacheStamp(imagesCount: 0, placementsCount: 0,
                        nextImageId: 0, nextPlacementId: 0)
    }
    func kittyVirtualPlacements(alternateBuffer: Bool) -> [KittyPlacementSpec] { [] }
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { nil }
    var kittyLiveImageIds: Set<UInt32> { [] }
    var viewBounds: CGRect { .zero }
    func backingScaleFactor() -> CGFloat { 2 }
    var cellSize: CGSize { CGSize(width: 12.5, height: 16) }
    var normalFont: NSFont { NSFont.monospacedSystemFont(ofSize: 14, weight: .regular) }
    func underlinePosition() -> CGFloat { -2 }
    func underlineThickness() -> CGFloat { 1 }
    var contentXOrigin: CGFloat { 0 }
    var topContentInset: CGFloat { 0 }
    var bottomContentInset: CGFloat { 0 }
    var leftContentInset: CGFloat { 0 }
    var scrollContentOffset: CGPoint { .zero }
    func getImageScale() -> CGFloat { 1 }
    var nativeForegroundColor: NSColor { .white }
    var nativeBackgroundColor: NSColor { .black }
    var caretColor: NSColor { .white }
    var caretTextColor: NSColor? { .black }
    var caretFocused: Bool { false }
    var antiAliasCustomBlockGlyphs: Bool { true }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }
    func consumeDirtyRows() -> ClosedRange<Int>? { nil }
    var activityKeypressTime: Double { 0 }
    var activityTypingRate: Float { 0 }
}
