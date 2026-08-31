import AppKit
import CoreText
import Metal
import MetalKit
import XCTest
@testable import CmdyGPU

@MainActor
final class GlyphAtlasPagingTests: XCTestCase {
    func testColorAtlasAllocatesOnlyForColorGlyphsAndOnlyOnce() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let view = MTKView(frame: .zero, device: device)
        let source = AtlasRenderSource()
        let renderer = try MetalTerminalRenderer(view: view, source: source)

        XCTAssertEqual(renderer.colorAtlasAllocationCount, 0)
        XCTAssertNil(renderer.colorAtlasPageCapacityForTesting)

        let asciiFont = CTFontCreateWithName("Menlo" as CFString, 16, nil)
        let asciiGlyph = try glyph(for: "A", font: asciiFont)
        let asciiEntry = try XCTUnwrap(renderer.cacheGlyphForTesting(
            font: asciiFont, glyph: asciiGlyph))
        XCTAssertFalse(asciiEntry.isColor)
        XCTAssertEqual(renderer.colorAtlasAllocationCount, 0)
        XCTAssertNil(renderer.colorAtlasPageCapacityForTesting)

        let emojiFont = CTFontCreateWithName(
            "AppleColorEmoji" as CFString, 32, nil)
        let emojiGlyph = try glyph(for: "😀", font: emojiFont)
        let emojiEntry = try XCTUnwrap(renderer.cacheGlyphForTesting(
            font: emojiFont, glyph: emojiGlyph))
        XCTAssertTrue(emojiEntry.isColor)
        XCTAssertEqual(renderer.colorAtlasAllocationCount, 1)
        XCTAssertEqual(renderer.colorAtlasPageCapacityForTesting, 4)

        _ = try XCTUnwrap(renderer.cacheGlyphForTesting(
            font: emojiFont, glyph: emojiGlyph))
        XCTAssertEqual(renderer.colorAtlasAllocationCount, 1)
        XCTAssertEqual(renderer.colorAtlasPageCapacityForTesting, 4)
    }

    private func glyph(for text: String, font: CTFont) throws -> CGGlyph {
        var characters = Array(text.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        let mapped = CTFontGetGlyphsForCharacters(
            font, &characters, &glyphs, characters.count)
        XCTAssertTrue(mapped)
        return try XCTUnwrap(glyphs.first(where: { $0 != 0 }))
    }

    func testDefaultAtlasCapacityStaysBoundedPerPane() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let grayscale = try XCTUnwrap(GlyphAtlas(
            device: device, format: .grayscale))
        let color = try XCTUnwrap(GlyphAtlas(device: device, format: .bgra))

        XCTAssertEqual(grayscale.size, 1_024)
        XCTAssertEqual(color.size, 1_024)
        XCTAssertEqual(grayscale.texture.arrayLength, 4)
        XCTAssertEqual(color.texture.arrayLength, 4)
        let nominalBytes = 1_024 * 1_024 * 4 * (1 + 4)
        XCTAssertEqual(nominalBytes, 20 * 1_024 * 1_024)
    }

    func testAtlasFillsAnotherPageBeforeEvicting() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, size: 256,
                                             maxPages: 2, format: .grayscale))
        let first = try XCTUnwrap(atlas.ensureRegion(width: 256, height: 256))
        let second = try XCTUnwrap(atlas.ensureRegion(width: 256, height: 256))

        XCTAssertEqual(first.page, 0)
        XCTAssertEqual(second.page, 1)
        XCTAssertNil(atlas.evictedPage)
        XCTAssertEqual(atlas.generation(forPage: 0), first.generation)

        let third = try XCTUnwrap(atlas.ensureRegion(width: 256, height: 256))
        XCTAssertEqual(third.page, 0)
        XCTAssertEqual(atlas.evictedPage, 0)
        XCTAssertNotEqual(third.generation, first.generation)
        XCTAssertEqual(atlas.generation(forPage: 1), second.generation)
    }

    func testGuillotineAllocatorFillsComplementaryRectanglesWithoutOverlap() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, size: 64,
                                             maxPages: 1,
                                             format: .grayscale))
        let left = try XCTUnwrap(atlas.ensureRegion(width: 32, height: 64))
        let upperRight = try XCTUnwrap(atlas.ensureRegion(width: 32, height: 32))
        let lowerRight = try XCTUnwrap(atlas.ensureRegion(width: 32, height: 32))

        XCTAssertNil(atlas.evictedPage)
        let rectangles = [left, upperRight, lowerRight].map {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
        }
        for first in rectangles.indices {
            for second in rectangles.indices where first < second {
                XCTAssertFalse(rectangles[first].intersects(rectangles[second]))
            }
        }
        XCTAssertEqual(rectangles.reduce(0) { $0 + $1.width * $1.height },
                       64 * 64)
    }

    func testTouchProtectsRecentlyUsedPageDuringEviction() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, size: 16,
                                             maxPages: 2,
                                             format: .grayscale))
        _ = try XCTUnwrap(atlas.ensureRegion(width: 16, height: 16))
        _ = try XCTUnwrap(atlas.ensureRegion(width: 16, height: 16))
        atlas.touch(page: 0)
        let replacement = try XCTUnwrap(
            atlas.ensureRegion(width: 16, height: 16))

        XCTAssertEqual(atlas.evictedPage, 1)
        XCTAssertEqual(replacement.page, 1)
    }

    func testStaleGenerationCannotOverwriteRecycledPage() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, size: 4,
                                             maxPages: 1,
                                             format: .grayscale))
        let stale = try XCTUnwrap(atlas.ensureRegion(width: 4, height: 4))
        atlas.write(region: stale, pixels: [UInt8](repeating: 255, count: 16),
                    width: 4, height: 4)
        let current = try XCTUnwrap(atlas.ensureRegion(width: 4, height: 4))
        XCTAssertNotEqual(current.generation, stale.generation)

        atlas.write(region: stale, pixels: [UInt8](repeating: 255, count: 16),
                    width: 4, height: 4)
        var bytes = [UInt8](repeating: 99, count: 16)
        atlas.texture.getBytes(&bytes, bytesPerRow: 4, bytesPerImage: 16,
                               from: MTLRegionMake2D(0, 0, 4, 4),
                               mipmapLevel: 0, slice: current.page)
        XCTAssertEqual(bytes, [UInt8](repeating: 0, count: 16))
    }

    func testAllocatorStressNeverOverlapsWithinAPageGeneration() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, size: 64,
                                             maxPages: 2,
                                             format: .grayscale))
        var occupied: [String: [CGRect]] = [:]
        var state: UInt64 = 0xC0FFEE
        var evictions = 0
        for _ in 0..<800 {
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let width = 2 + Int((state >> 24) % 21)
            state = state &* 6_364_136_223_846_793_005 &+ 1
            let height = 2 + Int((state >> 24) % 21)
            let region = try XCTUnwrap(
                atlas.ensureRegion(width: width, height: height))
            if atlas.evictedPage != nil { evictions += 1 }
            let key = "\(region.page):\(region.generation)"
            let rectangle = CGRect(x: region.x, y: region.y,
                                   width: region.width, height: region.height)
            XCTAssertGreaterThanOrEqual(rectangle.minX, 0)
            XCTAssertGreaterThanOrEqual(rectangle.minY, 0)
            XCTAssertLessThanOrEqual(rectangle.maxX, 64)
            XCTAssertLessThanOrEqual(rectangle.maxY, 64)
            for existing in occupied[key, default: []] {
                XCTAssertFalse(existing.intersects(rectangle))
            }
            occupied[key, default: []].append(rectangle)
        }
        XCTAssertGreaterThan(evictions, 10)
    }

    func testAtlasVertexLayoutsStayMetalCompatible() {
        XCTAssertEqual(MemoryLayout<GlyphVertex>.stride, 48)
        XCTAssertEqual(MemoryLayout<TextCell>.stride, 64)
    }

    func testGlyphPaddingCreatesAZeroCoverageGutter() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let atlas = try XCTUnwrap(GlyphAtlas(device: device, size: 256,
                                             maxPages: 1, format: .grayscale))
        let region = try XCTUnwrap(atlas.ensureRegion(width: 3, height: 3))
        atlas.write(region: region, pixels: [255, 255, 255, 255],
                    width: 1, height: 1, padding: 1)

        var bytes = [UInt8](repeating: 99, count: 9)
        atlas.texture.getBytes(&bytes, bytesPerRow: 3, bytesPerImage: 9,
                               from: MTLRegionMake2D(region.x, region.y, 3, 3),
                               mipmapLevel: 0, slice: region.page)
        XCTAssertEqual(bytes, [0, 0, 0, 0, 255, 0, 0, 0, 0])
    }

    func testTextRenderingLabPresetsMatchFrozenPixelAxes() {
        XCTAssertTrue(TextRenderingMode.current.snapsY)
        XCTAssertTrue(TextRenderingMode.ySnap.snapsY)
        XCTAssertTrue(TextRenderingMode.atlasPadding.snapsY)
        XCTAssertTrue(TextRenderingMode.nearest.snapsY)
        XCTAssertTrue(TextRenderingMode.highContrast.snapsY)
        XCTAssertTrue(TextRenderingMode.atlasPadding.padsAtlas)
        XCTAssertTrue(TextRenderingMode.nearest.usesNearestSampling)
        XCTAssertEqual(TextRenderingMode.current.coverageExponent, 1.35)
        XCTAssertEqual(TextRenderingMode.highContrast.coverageExponent, 1.55)
        XCTAssertLessThan(TextRenderingMode.highContrast.coveragePower,
                          TextRenderingMode.current.coveragePower)
        XCTAssertTrue(TextRenderingMode.crisp.snapsY)
        XCTAssertTrue(TextRenderingMode.crisp.padsAtlas)
    }

    func testDynamicGeometryRingStopsAllocatingAfterWarmup() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = DynamicBufferRing(device: device, frameCount: 3,
                                     minimumPageSize: 4096)
        let values = Array(repeating: UInt64(0xA5), count: 128)

        for _ in 0..<3 {
            ring.beginFrame()
            let first = try XCTUnwrap(ring.write(values))
            let second = try XCTUnwrap(ring.write(values))
            XCTAssertEqual(first.offset % 256, 0)
            XCTAssertEqual(second.offset % 256, 0)
        }
        let warmedAllocations = ring.allocationCount

        for _ in 0..<12 {
            ring.beginFrame()
            _ = try XCTUnwrap(ring.write(values))
            _ = try XCTUnwrap(ring.write(values + values))
        }
        XCTAssertEqual(ring.allocationCount, warmedAllocations)
    }

    func testDefaultDynamicGeometryRingStartsSmallAndGrowsForLargeFrames() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let ring = DynamicBufferRing(device: device)
        ring.beginFrame()
        let small = try XCTUnwrap(ring.write([UInt8](repeating: 1, count: 64)))
        XCTAssertEqual(small.buffer.length, 256 * 1_024)

        let large = try XCTUnwrap(ring.write(
            [UInt8](repeating: 2, count: 400 * 1_024)))
        XCTAssertGreaterThanOrEqual(large.buffer.length, 512 * 1_024)
    }

    func testResizeViewportTranslationStaysOnDevicePixels() {
        let first = ViewportTranslation(contentXOrigin: 10.25,
                                        viewHeight: 500.25,
                                        topContentInset: 24,
                                        cellHeight: 18,
                                        displayRow: 3,
                                        scale: 2)
        let resized = ViewportTranslation(contentXOrigin: 11,
                                          viewHeight: 501,
                                          topContentInset: 24,
                                          cellHeight: 18,
                                          displayRow: 3,
                                          scale: 2)

        XCTAssertEqual(first.x, first.x.rounded())
        XCTAssertEqual(first.y, first.y.rounded())
        XCTAssertEqual(resized.x - first.x, 1)
        XCTAssertEqual(resized.y - first.y, 1)
    }

    func testSmoothScrollUsesDevicePixelsAndKeepsChromeClipped() {
        let translation = SmoothScrollTranslation(offsetPixels: 1.26, scale: 2)
        XCTAssertEqual(translation.snappedPoints, 0.5)
        XCTAssertEqual(translation.renderedPoints, -0.5)
        XCTAssertEqual(translation.yShiftPixels, -1)

        // Crossing from a fractional offset into the preceding model row must
        // leave the same source row at the same device position. The row index
        // advances by one while the retained remainder drops by one row.
        let cellHeightPixels: CGFloat = 37
        let uninterrupted = SmoothScrollTranslation(
            offsetPixels: cellHeightPixels + 2, scale: 2)
        let wrappedRemainder = SmoothScrollTranslation(
            offsetPixels: 2, scale: 2)
        XCTAssertEqual(
            uninterrupted.yShiftPixels,
            -Float(cellHeightPixels) + wrappedRemainder.yShiftPixels)

        let scissor = TerminalGridScissor(
            drawableSize: CGSize(width: 1_000, height: 800),
            topInset: 24, bottomInset: 40, scale: 2).rect
        XCTAssertEqual(scissor.x, 0)
        XCTAssertEqual(scissor.y, 48)
        XCTAssertEqual(scissor.width, 1_000)
        XCTAssertEqual(scissor.height, 672)
    }

    func testSmoothScrollMotionHasOneOffsetAuthorityAndBoundedGlide() {
        XCTAssertEqual(SmoothScrollMotion.effectiveOffset(
            source: 1.26, held: 0, glide: 0), 1.26)
        let held = SmoothScrollMotion.effectiveOffset(
            source: 0, held: 3, glide: 0)
        XCTAssertEqual(held, 3)
        // A published rendered offset is observational; evaluating another
        // frame with the same held input must not compound it to 6, 9, ...
        XCTAssertEqual(SmoothScrollMotion.effectiveOffset(
            source: 0, held: 3, glide: 0), held)

        let decayed = SmoothScrollMotion.decayedGlide(12, elapsed: 0.05)
        XCTAssertEqual(decayed, 12 * exp(-2), accuracy: 0.0001)
        XCTAssertEqual(SmoothScrollMotion.decayedGlide(0.5, elapsed: 0.05), 0)
        XCTAssertEqual(SmoothScrollMotion.accumulatedGlide(
            current: 18, impulse: 20, cellHeight: 16), 20)
        XCTAssertEqual(SmoothScrollMotion.accumulatedGlide(
            current: -18, impulse: -20, cellHeight: 16), -20)
        XCTAssertFalse(SmoothScrollMotion.shouldSelfAnimate(glide: 0.49))
        XCTAssertTrue(SmoothScrollMotion.shouldSelfAnimate(glide: 0.5))
        XCTAssertEqual(SmoothScrollMotion.fringeRows(
            offset: 0.5, cellHeight: 16, enabled: true), 0)
        XCTAssertEqual(SmoothScrollMotion.fringeRows(
            offset: 0.51, cellHeight: 16, enabled: true), 2)
        XCTAssertEqual(SmoothScrollMotion.fringeRows(
            offset: -32, cellHeight: 16, enabled: true), 3)
        XCTAssertEqual(SmoothScrollMotion.fringeRows(
            offset: 32, cellHeight: 16, enabled: false), 0)
    }
}

@MainActor
private final class AtlasRenderSource: MetalRenderSource {
    func captureGrid() -> GridSnapshot {
        GridSnapshot(
            rows: 1, cols: 1, bufferLineCount: 1,
            displayTopRow: 0, liveTopRow: 0,
            cursorRow: 0, cursorCol: 0, cursorHidden: true,
            cursorStyle: .steadyBlock, isAlternateBuffer: false)
    }

    func lineInfo(forRow row: Int) -> ViewLineInfo {
        ViewLineInfo(segments: [], images: nil)
    }

    func lineRenderMode(forRow row: Int) -> RenderLineMode { .single }
    func lineVersion(forRow row: Int) -> UInt64 { 0 }
    func cursorCellAttributedString() -> NSAttributedString? { nil }

    let kittyStamp = KittyCacheStamp(
        imagesCount: 0, placementsCount: 0,
        nextImageId: 1, nextPlacementId: 1)
    func kittyVirtualPlacements(
        alternateBuffer: Bool
    ) -> [KittyPlacementSpec] { [] }
    func kittyImagePayload(imageId: UInt32) -> KittyImagePayload? { nil }
    let kittyLiveImageIds: Set<UInt32> = []

    var viewBounds: CGRect { CGRect(x: 0, y: 0, width: 100, height: 100) }
    func backingScaleFactor() -> CGFloat { 2 }
    var cellSize: CGSize { CGSize(width: 8, height: 16) }
    let normalFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    func underlinePosition() -> CGFloat { 1 }
    func underlineThickness() -> CGFloat { 1 }
    var contentXOrigin: CGFloat { 0 }
    var topContentInset: CGFloat { 0 }
    var bottomContentInset: CGFloat { 0 }
    var leftContentInset: CGFloat { 0 }
    var scrollContentOffset: CGPoint { .zero }
    func getImageScale() -> CGFloat { 1 }

    let nativeForegroundColor = NSColor.white
    let nativeBackgroundColor = NSColor.black
    let caretColor = NSColor.white
    var caretTextColor: NSColor? { NSColor.black }
    var caretFocused: Bool { false }
    var antiAliasCustomBlockGlyphs: Bool { false }
    var metalBufferingMode: MetalBufferingMode { .perRowPersistent }

    func consumeDirtyRows() -> ClosedRange<Int>? { nil }
    var activityKeypressTime: Double { 0 }
    var activityTypingRate: Float { 0 }
}
