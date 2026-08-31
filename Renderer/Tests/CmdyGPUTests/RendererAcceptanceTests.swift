import AppKit
import CoreText
import MetalKit
import XCTest
@testable import CmdyGPU

@MainActor
final class RendererAcceptanceTests: XCTestCase {
    func testKittyPayloadAspectFitsBeforePlaceholderCellClipping() {
        XCTAssertEqual(
            MetalTerminalRenderer.kittyAspectFitRect(
                imageSize: CGSize(width: 8, height: 8),
                in: CGRect(x: 164, y: 156, width: 36, height: 24)),
            CGRect(x: 170, y: 156, width: 24, height: 24))
        XCTAssertEqual(
            MetalTerminalRenderer.kittyAspectFitRect(
                imageSize: CGSize(width: 8, height: 8),
                in: CGRect(x: 328, y: 312, width: 72, height: 48)),
            CGRect(x: 340, y: 312, width: 48, height: 48))
    }

    func testRowRasterBoxDrawingUsesTerminalYDownOrientation() throws {
        func displayCoverage(_ codePoint: UInt32) throws -> [(Int, Int)] {
            let item = BoxDrawingRenderItem(
                column: 0, columnWidth: 1, codePoint: codePoint,
                foregroundColor: .white)
            let row = try XCTUnwrap(IndependentRowRasterizer.rasterize(
                info: ViewLineInfo(segments: [], images: nil,
                                   boxDrawings: [item]),
                cols: 1, width: 12, height: 24,
                cellWidth: 12, cellHeight: 24, scale: 1,
                normalFont: .monospacedSystemFont(ofSize: 14, weight: .regular),
                nativeForeground: .white,
                underlinePosition: -2, underlineThickness: 1,
                preset: .current, antialiasBlocks: true))
            return (0..<24).flatMap { displayY in
                (0..<12).compactMap { x in
                    row.coverage[displayY * 12 + x] > 0
                        ? (x, displayY) : nil
                }
            }
        }

        let horizontal = try displayCoverage(0x2500)
        XCTAssertEqual(horizontal.count, 12)
        XCTAssertEqual(Set(horizontal.map(\.1)), [11])

        let downAndRight = try displayCoverage(0x250E)
        XCTAssertEqual(downAndRight.count, 31)
        XCTAssertEqual(downAndRight.map(\.1).min(), 11)
        XCTAssertEqual(downAndRight.map(\.1).max(), 23)
    }

    func testFractionalTopInsetRoundsOutwardToPreventChromeLeakage() {
        XCTAssertEqual(TerminalGridScissor.deviceTopInset(7.25, scale: 1), 8)
        XCTAssertEqual(TerminalGridScissor.deviceTopInset(7.25, scale: 2), 15)
    }

    func testBoxDrawingStrokeMatchesReferenceAtOneAndTwoTimesScale() {
        XCTAssertEqual(IndependentRowRasterizer.terminalBoxStrokeThickness(
            underlineThickness: 1, scale: 1), 1)
        XCTAssertEqual(IndependentRowRasterizer.terminalBoxStrokeThickness(
            underlineThickness: 1, scale: 2), 3)
    }

    func testStrikeThroughStaysOneDevicePixelAtBothScales() {
        let rect = CGRect(x: 8, y: 0, width: 12, height: 24)
        XCTAssertEqual(IndependentRowRasterizer.terminalStrikethroughRect(
            rect: rect, y: 15.168, scaledThickness: 1),
                       CGRect(x: 8, y: 15.168, width: 12, height: 1))
        XCTAssertEqual(IndependentRowRasterizer.terminalStrikethroughRect(
            rect: rect, y: 30.337, scaledThickness: 2),
                       CGRect(x: 8, y: 30.837, width: 12, height: 1))
    }

    func testBlockShadesUseQuantizedGlyphCoverageTransfer() {
        XCTAssertEqual(IndependentRowRasterizer.terminalBlockCoverage(
            alpha: .light, preset: .current), 0.1547, accuracy: 0.0001)
        XCTAssertEqual(IndependentRowRasterizer.terminalBlockCoverage(
            alpha: .medium, preset: .current), 0.3944, accuracy: 0.0001)
        XCTAssertEqual(IndependentRowRasterizer.terminalBlockCoverage(
            alpha: .dark, preset: .current), 0.6770, accuracy: 0.0001)
        XCTAssertEqual(IndependentRowRasterizer.terminalBlockCoverage(
            alpha: .full, preset: .current), 1, accuracy: 0.0001)
    }

    func testDoubleHeightLineModeGeometryClipsEachHalfToItsDisplayRow() {
        let row = CGRect(x: 0, y: 0, width: 288, height: 24)
        XCTAssertEqual(MetalTerminalRenderer.lineModeRect(
            row, displayIndex: 4, mode: .doubledTop,
            xOrigin: 8, yOrigin: 12, cellHeight: 24),
                       CGRect(x: 8, y: 108, width: 576, height: 24))
        XCTAssertEqual(MetalTerminalRenderer.lineModeRect(
            row, displayIndex: 5, mode: .doubledDown,
            xOrigin: 8, yOrigin: 12, cellHeight: 24),
                       CGRect(x: 8, y: 132, width: 576, height: 24))

        let upperOnlyDecoration = CGRect(x: 0, y: 3, width: 12, height: 2)
        XCTAssertEqual(MetalTerminalRenderer.lineModeRect(
            upperOnlyDecoration, displayIndex: 4, mode: .doubledTop,
            xOrigin: 8, yOrigin: 12, cellHeight: 24),
                       CGRect(x: 8, y: 114, width: 24, height: 4))
        XCTAssertEqual(MetalTerminalRenderer.lineModeRect(
            upperOnlyDecoration, displayIndex: 5, mode: .doubledDown,
            xOrigin: 8, yOrigin: 12, cellHeight: 24).height, 0)
    }

    func testUnderlineGeometryPreservesFractionalReferenceStrokesAndPatterns() {
        let cell = CGRect(x: 8, y: 0, width: 12, height: 24)
        let y: CGFloat = 20.8466796875

        XCTAssertEqual(IndependentRowRasterizer.terminalUnderlineRects(
            style: .single, rect: cell, underlineY: y, thickness: 1), [
                CGRect(x: 8, y: y + 0.5, width: 12, height: 1),
            ])
        XCTAssertEqual(IndependentRowRasterizer.terminalUnderlineRects(
            style: .double, rect: cell, underlineY: y, thickness: 1), [
                CGRect(x: 8, y: y + 0.5, width: 12, height: 1),
                CGRect(x: 8, y: y + 2.5, width: 12, height: 1),
            ])
        XCTAssertEqual(IndependentRowRasterizer.terminalUnderlineRects(
            style: .dotted, rect: cell, underlineY: y, thickness: 1).map(\.minX),
                       [8, 11, 14, 17])
        XCTAssertEqual(IndependentRowRasterizer.terminalUnderlineRects(
            style: .dashed, rect: cell, underlineY: y, thickness: 1).map(\.width),
                       [2, 2, 2])

        let curly = IndependentRowRasterizer.terminalUnderlineRects(
            style: .curly, rect: cell, underlineY: y, thickness: 1)
        XCTAssertEqual(curly.prefix(4).map(\.minY),
                       [y + 0.5, y - 0.5, y + 0.5, y + 1.5])
    }

    func testRowRasterPlanCarriesSelectionTextAndImageLayersDeterministically() throws {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let string = NSAttributedString(
            string: "A",
            attributes: [
                .font: font,
                .foregroundColor: NSColor.systemGreen,
                .backgroundColor: NSColor.systemRed,
                .selectionBackgroundColor: NSColor.systemBlue,
            ])
        let image = AcceptanceImage()
        let info = ViewLineInfo(
            segments: [ViewLineSegment(column: 0, columnWidth: 1,
                                       characterCount: 1,
                                       attributedString: string,
                                       cellUTF16Boundaries: [0, 1])],
            images: [image])

        let row = try XCTUnwrap(IndependentRowRasterizer.rasterize(
            info: info,
            cols: 4,
            width: 80,
            height: 40,
            cellWidth: 20,
            cellHeight: 40,
            scale: 2,
            normalFont: NSFont(descriptor: font.fontDescriptor,
                               size: font.pointSize * 2)!,
            nativeForeground: .white,
            underlinePosition: -2,
            underlineThickness: 1,
            preset: .current,
            antialiasBlocks: true))

        XCTAssertEqual(row.coverage.count, 80 * 40)
        XCTAssertGreaterThan(row.coverage.max() ?? 0, 0)
        XCTAssertEqual(row.backgrounds.count, 1)
        XCTAssertEqual(row.backgrounds[0].rect,
                       CGRect(x: 0, y: 0, width: 20, height: 40))
        assertColor(row.backgrounds[0].color,
                    equals: IndependentRowRasterizer.rgba(.systemBlue))
        XCTAssertEqual(row.tintSpans.count, 1)
        assertColor(row.tintSpans[0].color,
                    equals: IndependentRowRasterizer.rgba(.systemGreen))
        XCTAssertEqual(row.images.count, 1)
        XCTAssertTrue(row.images[0].image.value === image)
        XCTAssertEqual(row.images[0].zIndex, -1)
        XCTAssertEqual(row.images[0].pixelOffsetX, 3)
        XCTAssertEqual(row.images[0].pixelOffsetY, 5)
    }

    func testCachedASCIIRasterMatchesGeneralCellPathExactly() throws {
        let text = "The shell could not find command. It may be missing from PATH."
        let font = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.systemRed.withAlphaComponent(0.16),
        ])
        let count = attributed.length
        let info = ViewLineInfo(segments: [ViewLineSegment(
            column: 0, columnWidth: 1, characterCount: count,
            attributedString: attributed,
            cellUTF16Boundaries: Array(0...count))], images: nil)
        func rasterize(
            scale: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat,
            asciiCaching: Bool
        ) throws -> IndependentCPURow {
            try XCTUnwrap(IndependentRowRasterizer.rasterize(
                info: info, cols: count,
                width: Int(CGFloat(count) * cellWidth), height: Int(cellHeight),
                cellWidth: cellWidth, cellHeight: cellHeight, scale: scale,
                normalFont: NSFont(
                    descriptor: font.fontDescriptor, size: font.pointSize * scale)!,
                nativeForeground: .white,
                underlinePosition: -2, underlineThickness: 1,
                preset: .current, antialiasBlocks: true,
                asciiCaching: asciiCaching))
        }

        for (scale, cellWidth, cellHeight) in [
            (CGFloat(1), CGFloat(12), CGFloat(24)),
            (CGFloat(2), CGFloat(24), CGFloat(48)),
        ] {
            let cached = try rasterize(
                scale: scale, cellWidth: cellWidth, cellHeight: cellHeight,
                asciiCaching: true)
            let general = try rasterize(
                scale: scale, cellWidth: cellWidth, cellHeight: cellHeight,
                asciiCaching: false)
            XCTAssertEqual(cached.coverage, general.coverage)
            XCTAssertEqual(cached.backgrounds.map(\.rect),
                           general.backgrounds.map(\.rect))
            XCTAssertEqual(cached.backgrounds.map(\.color),
                           general.backgrounds.map(\.color))
            XCTAssertEqual(cached.tintSpans.map(\.rect),
                           general.tintSpans.map(\.rect))
            XCTAssertEqual(cached.tintSpans.map(\.glyphEnvelope),
                           general.tintSpans.map(\.glyphEnvelope))
            XCTAssertEqual(cached.tintSpans.map(\.color),
                           general.tintSpans.map(\.color))
            XCTAssertEqual(cached.glyphSeeds.map(\.glyph),
                           general.glyphSeeds.map(\.glyph))
            XCTAssertEqual(cached.glyphSeeds.map(\.rect),
                           general.glyphSeeds.map(\.rect))
        }
    }

    func testRowBaselineMatchesFrozenExpandedCellPlacementAtBothScales() {
        let ascent: CGFloat = 12.9951171875
        let descent: CGFloat = 3.3017578125

        XCTAssertEqual(
            IndependentRowRasterizer.centeredBaseline(
                rowHeight: 24,
                ascent: ascent,
                descent: descent,
                leading: 0,
                snapsToDevicePixel: false),
            4.1533203125,
            accuracy: 0.000_001)
        XCTAssertEqual(
            IndependentRowRasterizer.centeredBaseline(
                rowHeight: 48,
                ascent: ascent * 2,
                descent: descent * 2,
                leading: 0,
                snapsToDevicePixel: false),
            8.306640625,
            accuracy: 0.000_001)
        XCTAssertEqual(
            IndependentRowRasterizer.centeredBaseline(
                rowHeight: 24,
                ascent: ascent,
                descent: descent,
                leading: 0,
                snapsToDevicePixel: true),
            4)
    }

    func testColorGlyphsUseTheTerminalGridBaseline() throws {
        let gridFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14))
        let colorFont = try XCTUnwrap(NSFont(name: "AppleColorEmoji", size: 14))
        let gridBaseline = IndependentRowRasterizer.gridBaseline(
            rowHeight: 24, font: gridFont, snapsToDevicePixel: false)
        let colorMetricBaseline = IndependentRowRasterizer.centeredBaseline(
            rowHeight: 24,
            ascent: CTFontGetAscent(colorFont as CTFont),
            descent: CTFontGetDescent(colorFont as CTFont),
            leading: CTFontGetLeading(colorFont as CTFont),
            snapsToDevicePixel: false)

        XCTAssertEqual(gridBaseline, 4.1533203125, accuracy: 0.000_001)
        XCTAssertGreaterThan(abs(gridBaseline - colorMetricBaseline), 0.1)
    }

    func testDefaultLineHeightBaselineClearsFullDescentAtBothScales() throws {
        let pointFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        let pointMetrics = pointFont as CTFont
        let naturalHeight = ceil(
            CTFontGetAscent(pointMetrics)
                + CTFontGetDescent(pointMetrics)
                + CTFontGetLeading(pointMetrics))

        for scale: CGFloat in [1, 2] {
            let scaledFont = try XCTUnwrap(NSFont(
                descriptor: pointFont.fontDescriptor,
                size: pointFont.pointSize * scale))
            let rowHeight = ceil(naturalHeight * 1.15 * scale)
            let baseline = IndependentRowRasterizer.gridBaseline(
                rowHeight: rowHeight, font: scaledFont, scale: scale,
                snapsToDevicePixel: true)
            let scaledMetrics = scaledFont as CTFont
            let requiredDescent = ceil(
                (CTFontGetDescent(scaledMetrics)
                    + CTFontGetLeading(scaledMetrics)) / scale) * scale

            XCTAssertGreaterThanOrEqual(baseline, requiredDescent)
            XCTAssertLessThanOrEqual(
                baseline + CTFontGetAscent(scaledMetrics), rowHeight)
        }
    }

    func testDefaultLineHeightDoesNotClipAscendersOrDescenders() throws {
        let pointFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13))
        let pointMetrics = pointFont as CTFont
        let naturalHeight = ceil(
            CTFontGetAscent(pointMetrics)
                + CTFontGetDescent(pointMetrics)
                + CTFontGetLeading(pointMetrics))

        for scale: CGFloat in [1, 2] {
            let rowHeight = Int(ceil(naturalHeight * 1.15 * scale))
            let cellWidth = ceil(pointFont.advancement(
                forGlyph: pointFont.glyph(withName: "zero")).width * scale)
            let text = NSAttributedString(
                string: "Hgy",
                attributes: [.font: pointFont, .foregroundColor: NSColor.white])
            let segment = ViewLineSegment(
                column: 0, columnWidth: 1, characterCount: 3,
                attributedString: text)
            let scaledFont = try XCTUnwrap(NSFont(
                descriptor: pointFont.fontDescriptor,
                size: pointFont.pointSize * scale))
            let row = try XCTUnwrap(IndependentRowRasterizer.rasterize(
                info: ViewLineInfo(segments: [segment], images: nil),
                cols: 3, width: max(3, Int(cellWidth) * 3),
                height: rowHeight, cellWidth: cellWidth,
                cellHeight: CGFloat(rowHeight), scale: scale,
                normalFont: scaledFont, nativeForeground: .white,
                underlinePosition: -1, underlineThickness: 1,
                preset: .current, antialiasBlocks: true))

            XCTAssertFalse(row.glyphSeeds.isEmpty)
            XCTAssertGreaterThan(
                row.glyphSeeds.map { $0.rect.minY }.min() ?? 0, 0)
            XCTAssertLessThan(
                row.glyphSeeds.map { $0.rect.maxY }.max() ?? CGFloat(rowHeight),
                CGFloat(rowHeight))
        }
    }

    func testDefaultFragmentMonoRowsKeepCoverageOffBothTextureEdges() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fontURL = repository
            .appendingPathComponent("Kit/Sources/CmdyKit/Fonts/FragmentMono.ttf")
        var registrationError: Unmanaged<CFError>?
        _ = CTFontManagerRegisterFontsForURL(
            fontURL as CFURL, .process, &registrationError)
        let pointFont = try XCTUnwrap(
            NSFont(name: "FragmentMono-Regular", size: 13))
        let pointMetrics = pointFont as CTFont
        let naturalHeight = ceil(
            CTFontGetAscent(pointMetrics)
                + CTFontGetDescent(pointMetrics)
                + CTFontGetLeading(pointMetrics))

        for scale: CGFloat in [1, 2] {
            let rowHeight = Int(ceil(naturalHeight * 1.15 * scale))
            let scaledFont = try XCTUnwrap(NSFont(
                descriptor: pointFont.fontDescriptor,
                size: pointFont.pointSize * scale))
            let cellWidth = ceil(pointFont.advancement(
                forGlyph: pointFont.glyph(withName: "zero")).width * scale)
            let text = "ÅHgjpq"
            let segment = ViewLineSegment(
                column: 0, columnWidth: 1, characterCount: text.count,
                attributedString: NSAttributedString(
                    string: text,
                    attributes: [.font: pointFont,
                                 .foregroundColor: NSColor.white]))
            let width = max(text.count, Int(cellWidth) * text.count)
            let row = try XCTUnwrap(IndependentRowRasterizer.rasterize(
                info: ViewLineInfo(segments: [segment], images: nil),
                cols: text.count, width: width, height: rowHeight,
                cellWidth: cellWidth, cellHeight: CGFloat(rowHeight),
                scale: scale, normalFont: scaledFont,
                nativeForeground: .white,
                underlinePosition: -1, underlineThickness: 1,
                preset: .current, antialiasBlocks: true))

            XCTAssertTrue(row.coverage.prefix(width).allSatisfy { $0 == 0 })
            XCTAssertTrue(row.coverage.suffix(width).allSatisfy { $0 == 0 })
            XCTAssertEqual(
                IndependentRowRasterizer.gridBaseline(
                    rowHeight: CGFloat(rowHeight), font: scaledFont,
                    scale: scale, snapsToDevicePixel: false),
                ceil((CTFontGetDescent(pointMetrics)
                    + CTFontGetLeading(pointMetrics))) * scale,
                accuracy: 0.000_001)
        }
    }

    func testTerminalCellTextOriginDoesNotCenterNarrowGlyphAdvance() {
        XCTAssertEqual(
            IndependentRowRasterizer.terminalCellTextOrigin(
                cellMinX: 8,
                cellWidth: 12,
                lineWidth: 8.4287109375),
            8)
        XCTAssertEqual(
            IndependentRowRasterizer.terminalCellTextOrigin(
                cellMinX: 16,
                cellWidth: 24,
                lineWidth: 16.857421875),
            16)
    }

    func testOnlyVisibleBlinkingCursorKeepsIdleSchedulingAlive() {
        let visibleBlink = snapshot(style: .blinkBlock)
        XCTAssertTrue(MetalTerminalRenderer.cursorBlinkEligible(
            snapshot: visibleBlink, hostCursorHidden: false))
        XCTAssertFalse(MetalTerminalRenderer.cursorBlinkEligible(
            snapshot: visibleBlink, hostCursorHidden: true))
        XCTAssertFalse(MetalTerminalRenderer.cursorBlinkEligible(
            snapshot: snapshot(style: .steadyBlock), hostCursorHidden: false))
        XCTAssertFalse(MetalTerminalRenderer.cursorBlinkEligible(
            snapshot: snapshot(style: .blinkBlock, hidden: true),
            hostCursorHidden: false))
        XCTAssertFalse(MetalTerminalRenderer.cursorBlinkEligible(
            snapshot: snapshot(style: .blinkBlock, row: 99),
            hostCursorHidden: false))
    }

    func testNonzeroRetainedOriginKeepsSourceRowsLocalAndCacheRowsStable() {
        let grid = GridSnapshot(
            rows: 4, cols: 80, bufferLineCount: 6,
            retainedRowOrigin: 25, displayTopRow: 1, liveTopRow: 1,
            cursorRow: 2, cursorCol: 3, cursorHidden: false,
            cursorStyle: .blinkBlock, isAlternateBuffer: true)

        XCTAssertEqual(grid.independentVisibleRowRequests, [
            IndependentVisibleRowRequest(displayIndex: 0, sourceRow: 1, cacheRow: 26),
            IndependentVisibleRowRequest(displayIndex: 1, sourceRow: 2, cacheRow: 27),
            IndependentVisibleRowRequest(displayIndex: 2, sourceRow: 3, cacheRow: 28),
            IndependentVisibleRowRequest(displayIndex: 3, sourceRow: 4, cacheRow: 29),
        ])
        XCTAssertEqual(grid.independentVisibleRowRequests(extraRows: 2), [
            IndependentVisibleRowRequest(displayIndex: -1, sourceRow: 0, cacheRow: 25),
            IndependentVisibleRowRequest(displayIndex: 0, sourceRow: 1, cacheRow: 26),
            IndependentVisibleRowRequest(displayIndex: 1, sourceRow: 2, cacheRow: 27),
            IndependentVisibleRowRequest(displayIndex: 2, sourceRow: 3, cacheRow: 28),
            IndependentVisibleRowRequest(displayIndex: 3, sourceRow: 4, cacheRow: 29),
            IndependentVisibleRowRequest(displayIndex: 4, sourceRow: 5, cacheRow: 30),
        ])
        XCTAssertEqual(grid.independentDisplayRow(forSourceRow: grid.cursorRow), 1)
        XCTAssertEqual(grid.independentCacheRow(forSourceRow: grid.cursorRow), 27)
        XCTAssertTrue(MetalTerminalRenderer.cursorBlinkEligible(
            snapshot: grid, hostCursorHidden: false))
    }

    func testLeftInsetClipsAllTerminalLayers() {
        let scissor = TerminalGridScissor(
            drawableSize: CGSize(width: 1_000, height: 800),
            topInset: 24, bottomInset: 40, leftInset: 12, scale: 2).rect
        XCTAssertEqual(scissor.x, 24)
        XCTAssertEqual(scissor.y, 48)
        XCTAssertEqual(scissor.width, 976)
        XCTAssertEqual(scissor.height, 672)
    }

    func testOrdinaryImageDecodeIsAsynchronousAndDeduplicated() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalTerminalRenderer(
            view: MTKView(frame: .zero, device: device),
            source: MemoryRenderSource())
        let image = AcceptanceImage(image: try makeImage())

        XCTAssertNil(renderer.textureForTesting(image))
        XCTAssertEqual(renderer.imageDecodeAttemptsForTesting, 1)
        XCTAssertEqual(renderer.imageDecodePendingCountForTesting, 1)
        XCTAssertNil(renderer.textureForTesting(image))
        XCTAssertEqual(renderer.imageDecodeAttemptsForTesting, 1)

        var decoded: MTLTexture?
        for _ in 0..<100 where decoded == nil {
            try await Task.sleep(for: .milliseconds(5))
            decoded = renderer.textureForTesting(image)
        }
        XCTAssertNotNil(decoded)
        XCTAssertEqual(renderer.imageDecodeAttemptsForTesting, 1)
        XCTAssertEqual(renderer.imageDecodePendingCountForTesting, 0)
    }

    private func snapshot(style: RenderCursorStyle,
                          hidden: Bool = false,
                          row: Int = 12) -> GridSnapshot {
        GridSnapshot(rows: 24, cols: 80, bufferLineCount: 200,
                     retainedRowOrigin: 10, displayTopRow: 2,
                     liveTopRow: 176, cursorRow: row, cursorCol: 3,
                     cursorHidden: hidden, cursorStyle: style,
                     isAlternateBuffer: false)
    }

    private func assertColor(_ value: SIMD4<Float>,
                             equals expected: SIMD4<Float>,
                             file: StaticString = #filePath,
                             line: UInt = #line) {
        for component in 0..<4 {
            XCTAssertEqual(value[component], expected[component], accuracy: 0.001,
                           file: file, line: line)
        }
    }

    private func makeImage() throws -> NSImage {
        let bytes: [UInt8] = [
            0, 0, 255, 255, 0, 255, 0, 255,
            255, 0, 0, 255, 255, 255, 255, 255,
        ]
        let data = Data(bytes)
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
        return NSImage(cgImage: image, size: CGSize(width: 2, height: 2))
    }
}

@MainActor
private final class AcceptanceImage: RenderableCellImage {
    let image: NSImage
    let pixelWidth = 8
    let pixelHeight = 6
    let col = 2
    let kittyIsKitty = false
    let kittyImageId: UInt32? = nil
    let kittyZIndex = -1
    let kittyPixelOffsetX = 3
    let kittyPixelOffsetY = 5

    init(image: NSImage = NSImage(size: CGSize(width: 8, height: 6))) {
        self.image = image
    }
}
