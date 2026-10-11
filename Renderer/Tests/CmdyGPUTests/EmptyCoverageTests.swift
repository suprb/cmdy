import AppKit
import MetalKit
import XCTest
@testable import CmdyGPU

@MainActor
final class EmptyCoverageTests: XCTestCase {
    func testSingleRowsOmitUnusedDECAtlasDataAndPreserveRasterContents() throws {
        let fixtures = [
            line("Atlas A9"),
            line("f + A", attributes: [
                .font: NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 28), toHaveTrait: .italicFontMask),
                .foregroundColor: NSColor.cyan,
                .backgroundColor: NSColor.red.withAlphaComponent(0.3),
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
            ]),
        ]
        for scale: CGFloat in [1, 2] {
            let renderer = try makeRenderer()
            for (row, info) in fixtures.enumerated() {
                let reference = try rasterize(info, scale: scale)
                XCTAssertFalse(reference.glyphSeeds.isEmpty)
                let entry = try resolve(renderer, info: info, row: row, scale: scale)
                XCTAssertTrue(entry.atlasGlyphs.isEmpty,
                              "Single-width rendering never consumes DEC atlas draws")
                XCTAssertEqual(expandedCoverage(try XCTUnwrap(entry.coverageTexture),
                                                width: reference.width), reference.coverage)
                XCTAssertEqual(entry.tintSpans.map(\.rect), reference.tintSpans.map(\.rect))
                XCTAssertEqual(entry.tintSpans.map(\.color), reference.tintSpans.map(\.color))
                XCTAssertEqual(entry.backgrounds.map(\.rect), reference.backgrounds.map(\.rect))
                XCTAssertEqual(entry.decorations.map(\.rect), reference.decorations.map(\.rect))
            }
        }
    }

    func testLineModeChangesRebuildAtlasDataWithUnchangedRowVersion() throws {
        let info = line("Atlas A9")
        for scale: CGFloat in [1, 2] {
            let renderer = try makeRenderer()
            let reference = try rasterize(info, scale: scale)
            // resolve() keeps absolute row, version and text unchanged. Mode
            // alone must invalidate both identity and shared-content reuse.
            for mode: RenderLineMode in [.single, .doubleWidth, .doubledTop, .doubledDown, .single] {
                let rebuilt = MetalTerminalRenderer.rowsRebuilt
                let entry = try resolve(renderer, info: info, scale: scale, mode: mode)
                XCTAssertEqual(MetalTerminalRenderer.rowsRebuilt - rebuilt, 1)
                XCTAssertEqual(entry.atlasGlyphs.isEmpty, mode == .single)
                if mode != .single {
                    XCTAssertEqual(entry.atlasGlyphs.map(\.rect), reference.glyphSeeds.map(\.rect))
                    XCTAssertEqual(entry.atlasGlyphs.map(\.color), reference.glyphSeeds.map(\.color))
                }
                XCTAssertEqual(expandedCoverage(try XCTUnwrap(entry.coverageTexture),
                                                width: reference.width), reference.coverage)
                let reused = MetalTerminalRenderer.rowsReused
                let shared = try resolve(renderer, info: info, row: 1, scale: scale, mode: mode)
                XCTAssertEqual(MetalTerminalRenderer.rowsReused - reused, 1)
                XCTAssertEqual(shared.atlasGlyphs.map(\.rect), entry.atlasGlyphs.map(\.rect))
                XCTAssertTrue(shared.coverageTexture === entry.coverageTexture)
            }
        }
    }

    func testDirtyBlankRowsSharePayloadWithoutCoverageAllocation() throws {
        let renderer = try makeRenderer()
        for color in [NSColor.red, .blue] {
            let info = line(String(repeating: " ", count: 120), attributes: [
                .backgroundColor: color,
            ])
            let reference = try rasterize(info, cols: 120)
            XCTAssertFalse(reference.coverage.contains { $0 != 0 })
            let rebuilt = MetalTerminalRenderer.rowsRebuilt
            let reused = MetalTerminalRenderer.rowsReused
            let entries = try (0..<36).map {
                try resolve(renderer, info: info, row: $0, cols: 120)
            }
            XCTAssertEqual(MetalTerminalRenderer.rowsRebuilt - rebuilt, 1)
            XCTAssertEqual(MetalTerminalRenderer.rowsReused - reused, 35)
            XCTAssertEqual(renderer.rowCacheAllocatedBytesForTesting, 0)
            XCTAssertEqual(entries.map(\.key.absoluteRow), Array(0..<36))
            for entry in entries {
                XCTAssertNil(entry.coverageTexture)
                XCTAssertEqual(entry.backgrounds.map(\.rect), reference.backgrounds.map(\.rect))
                XCTAssertEqual(entry.backgrounds.map(\.color), reference.backgrounds.map(\.color))
                XCTAssertEqual(entry.tintSpans.map(\.rect), reference.tintSpans.map(\.rect))
            }
        }
    }

    func testBlankCoveragePreservesDecorationsBlocksImagesAndPlaceholders() throws {
        let image = EmptyCoverageTestImage()
        var info = line("   ", attributes: [
            .backgroundColor: NSColor.red.withAlphaComponent(0.3),
            .cmdyUnderlineStyle: RenderUnderlineStyle.curly.rawValue,
            .cmdyUnderlineColor: NSColor.green,
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ])
        info.images = [image]
        info.kittyPlaceholders = [KittyPlaceholderCell(
            row: 0, col: 1, imageId: 3, placementId: 4,
            placeholderRow: 0, placeholderCol: 0, msb: 0)]
        info.blockElements = [BlockElementRenderItem(
            column: 2, columnWidth: 1, codePoint: 0x2588,
            rects: [BlockElementRect(x0: 0, x1: 8, y0: 0, y1: 8)],
            foregroundColor: .cyan)]
        for scale: CGFloat in [1, 2] {
            let reference = try rasterize(info, scale: scale)
            let entry = try resolve(makeRenderer(), info: info, scale: scale)
            XCTAssertFalse(reference.coverage.contains { $0 != 0 })
            XCTAssertNil(entry.coverageTexture)
            XCTAssertFalse(reference.decorations.isEmpty)
            XCTAssertEqual(entry.backgrounds.map(\.rect), reference.backgrounds.map(\.rect))
            XCTAssertEqual(entry.backgrounds.map(\.color), reference.backgrounds.map(\.color))
            XCTAssertEqual(entry.decorations.map(\.rect), reference.decorations.map(\.rect))
            XCTAssertEqual(entry.decorations.map(\.color), reference.decorations.map(\.color))
            XCTAssertTrue(entry.images.first?.image.value === image)
            XCTAssertEqual(entry.kittyPlaceholders.count, 1)
            XCTAssertEqual(entry.kittyPlaceholders.first?.imageId, 3)
        }
    }

    func testColorGlyphLayerSurvivesEmptyGrayscaleCoverage() throws {
        let info = line("🙂", boundaries: [0, 2], columnWidth: 2)
        let reference = try rasterize(info)
        let entry = try resolve(makeRenderer(), info: info)
        XCTAssertFalse(reference.coverage.contains { $0 != 0 })
        XCTAssertNil(entry.coverageTexture)
        XCTAssertFalse(reference.colorTiles.isEmpty)
        XCTAssertEqual(entry.colorLayers.count, reference.colorTiles.count)
        for (layer, tile) in zip(entry.colorLayers, reference.colorTiles) {
            XCTAssertEqual(layer.rect, tile.rect)
            XCTAssertEqual(bytes(layer.texture, bytesPerPixel: 4), tile.bytes)
        }
    }

    func testProceduralBoxCoverageSurvivesWithoutAtlasSeeds() throws {
        let info = ViewLineInfo(segments: [], images: nil, boxDrawings: [
            BoxDrawingRenderItem(column: 0, columnWidth: 1, codePoint: 0x253C,
                                 foregroundColor: .white),
        ])
        let reference = try rasterize(info)
        let entry = try resolve(makeRenderer(), info: info)
        XCTAssertTrue(reference.glyphSeeds.isEmpty)
        XCTAssertTrue(reference.coverage.contains { $0 != 0 })
        XCTAssertEqual(expandedCoverage(try XCTUnwrap(entry.coverageTexture), width: reference.width), reference.coverage)
    }

    func testNeighboringBlankCellCannotDiscardOverhangingInk() throws {
        let font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 28), toHaveTrait: .italicFontMask)
        let info = line("f ", attributes: [.font: font])
        for scale: CGFloat in [1, 2] {
            // A narrow terminal cell forces this glyph into the neighboring
            // blank's sample region. A per-character whitespace skip would
            // lose that part of the row's existing coverage composition.
            let reference = try rasterize(info, scale: scale, cellWidth: 6)
            let entry = try resolve(makeRenderer(), info: info, scale: scale, cellWidth: 6)
            let neighborX = Int(6 * scale)..<Int(12 * scale)
            var neighborHasInk = false
            for y in 0..<reference.height {
                for x in neighborX where reference.coverage[y * reference.width + x] != 0 {
                    neighborHasInk = true
                }
            }
            XCTAssertTrue(neighborHasInk)
            XCTAssertEqual(expandedCoverage(try XCTUnwrap(entry.coverageTexture), width: reference.width), reference.coverage)
            XCTAssertEqual(entry.tintSpans.map(\.rect), reference.tintSpans.map(\.rect))
        }
    }

    func testClippedBitmapRetainsTextureWhenDECAtlasGlyphsExist() throws {
        let info = line("—", attributes: [.font: NSFont.systemFont(ofSize: 80)])
        let reference = try rasterize(info, cellHeight: 1)
        let entry = try resolve(makeRenderer(), info: info, cellHeight: 1, mode: .doubledTop)
        XCTAssertFalse(reference.coverage.contains { $0 != 0 })
        XCTAssertFalse(reference.glyphSeeds.isEmpty)
        XCTAssertNotNil(entry.coverageTexture,
                        "The texture also gates independent DEC atlas rendering")
        XCTAssertFalse(entry.atlasGlyphs.isEmpty)
    }

    func testTrailingTransparentColumnsUseLessStorageWithoutChangingRowPixels() throws {
        let info = line("shell prompt $ ", attributes: [.backgroundColor: NSColor.red])
        for scale: CGFloat in [1, 2] {
            let reference = try rasterize(info, cols: 120, scale: scale)
            let entry = try resolve(makeRenderer(), info: info, cols: 120, scale: scale)
            let texture = try XCTUnwrap(entry.coverageTexture)
            XCTAssertLessThan(texture.width, reference.width / 2)
            XCTAssertEqual(entry.width, texture.width)
            XCTAssertEqual(entry.height, texture.height)
            XCTAssertEqual(expandedCoverage(texture, width: reference.width), reference.coverage)
            XCTAssertEqual(entry.tintSpans.map(\.rect), reference.tintSpans.map(\.rect))
            XCTAssertEqual(entry.backgrounds.map(\.rect), reference.backgrounds.map(\.rect))
            let pixels = bytes(texture)
            XCTAssertTrue((0..<texture.height).allSatisfy { pixels[($0 + 1) * texture.width - 1] == 0 })
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .r8Unorm, width: reference.width, height: reference.height, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            let full = try XCTUnwrap(texture.device.makeTexture(descriptor: descriptor))
            XCTAssertLessThan(texture.allocatedSize, full.allocatedSize)
        }
    }

    func testInkAtLastColumnKeepsFullCoverageWidth() throws {
        let info = ViewLineInfo(segments: [], images: nil, boxDrawings: [
            BoxDrawingRenderItem(column: 119, columnWidth: 1, codePoint: 0x2500,
                                 foregroundColor: .white),
        ])
        let reference = try rasterize(info, cols: 120)
        let entry = try resolve(makeRenderer(), info: info, cols: 120)
        let texture = try XCTUnwrap(entry.coverageTexture)
        XCTAssertEqual(texture.width, reference.width)
        XCTAssertEqual(bytes(texture), reference.coverage)
    }

    func testCompactCoverageMatchesFullTextureWithActualMetalSampling() throws {
        let info = line("shell prompt $ ")
        let reference = try rasterize(info, cols: 120, scale: 2)
        let compact = try XCTUnwrap(resolve(makeRenderer(), info: info, cols: 120, scale: 2).coverageTexture)
        let device = compact.device
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: reference.width, height: reference.height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let full = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        reference.coverage.withUnsafeBytes {
            full.replace(region: MTLRegionMake2D(0, 0, reference.width, reference.height),
                         mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: reference.width)
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void compare(texture2d<float> full [[texture(0)]],
                            texture2d<float> compact [[texture(1)]],
                            device uint4 *result [[buffer(0)]], uint index [[thread_position_in_grid]]) {
            uint columns = (full.get_width() + 2) * 4;
            uint count = columns * (full.get_height() + 2) * 2;
            if (index >= count) return;
            float2 pixel = float2(float(index % columns) * 0.25 - 1,
                                 float(index / columns) * 0.5 - 1);
            float2 uvFull = pixel / float2(full.get_width(), full.get_height());
            float2 uvCompact = pixel / float2(compact.get_width(), compact.get_height());
            constexpr sampler nearest(coord::normalized, address::clamp_to_edge, filter::nearest);
            constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
            result[index] = uint4(round(float4(full.sample(nearest, uvFull).r,
                                               compact.sample(nearest, uvCompact).r,
                                               full.sample(linear, uvFull).r,
                                               compact.sample(linear, uvCompact).r) * 255));
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let pipeline = try device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "compare")))
        let count = (reference.width + 2) * 4 * (reference.height + 2) * 2
        let output = try XCTUnwrap(device.makeBuffer(length: count * MemoryLayout<SIMD4<UInt32>>.stride, options: .storageModeShared))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(full, index: 0)
        encoder.setTexture(compact, index: 1)
        encoder.setBuffer(output, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        let pixels = output.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: count)
        let mismatches = (0..<count).filter { pixels[$0].x != pixels[$0].y || pixels[$0].z != pixels[$0].w }
        XCTAssertEqual(mismatches.count, 0, "Nearest/linear coverage changed at \(mismatches.prefix(8))")
    }

    private func makeRenderer() throws -> NativeRendererCacheHarness {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try NativeRendererCacheHarness(
            view: MTKView(frame: .zero, device: device), source: MemoryRenderSource())
    }

    private func line(_ text: String, attributes: [NSAttributedString.Key: Any] = [:],
                      boundaries: [Int]? = nil, columnWidth: Int = 1) -> ViewLineInfo {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
            .foregroundColor: NSColor.white,
        ].merging(attributes, uniquingKeysWith: { _, value in value }))
        let cells = boundaries ?? Array(0...attributed.length)
        return ViewLineInfo(segments: [ViewLineSegment(
            column: 0, columnWidth: columnWidth, characterCount: cells.count - 1,
            attributedString: attributed, cellUTF16Boundaries: cells)], images: nil)
    }

    private func rasterize(_ info: ViewLineInfo, cols: Int = 16, scale: CGFloat = 1,
                           cellWidth: CGFloat = 12, cellHeight: CGFloat = 24) throws -> IndependentCPURow {
        try XCTUnwrap(IndependentRowRasterizer.rasterize(
            info: info, cols: cols,
            width: Int(CGFloat(cols) * cellWidth * scale), height: Int(cellHeight * scale),
            cellWidth: cellWidth * scale, cellHeight: cellHeight * scale, scale: scale,
            normalFont: .monospacedSystemFont(ofSize: 14 * scale, weight: .regular),
            nativeForeground: .white, underlinePosition: -2, underlineThickness: 1,
            preset: .current, antialiasBlocks: true))
    }

    private func resolve(_ renderer: NativeRendererCacheHarness, info: ViewLineInfo,
                         row: Int = 0, cols: Int = 16, scale: CGFloat = 1,
                         cellWidth: CGFloat = 12, cellHeight: CGFloat = 24,
                         mode: RenderLineMode = .single) throws -> IndependentRowCacheEntry {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let key = IndependentRowKey(
            absoluteRow: row, version: 1, lineMode: mode, cols: cols,
            widthPx: Int(CGFloat(cols) * cellWidth * scale), heightPx: Int(cellHeight * scale),
            scaleBits: Double(scale).bitPattern, fontName: font.fontName,
            fontSizeBits: Double(font.pointSize).bitPattern, alternateBuffer: false,
            kittyStamp: KittyCacheStamp(imagesCount: 0, placementsCount: 0,
                                        nextImageId: 0, nextPlacementId: 0),
            foreground: IndependentRowRasterizer.packedColor(.white),
            background: IndependentRowRasterizer.packedColor(.black),
            preset: .current, antialiasBlocks: true, bufferingMode: .perRowPersistent)
        return try XCTUnwrap(renderer.resolveRowEntry(
            key: key, explicitlyDirty: true, info: info,
            scaledFont: .monospacedSystemFont(ofSize: 14 * scale, weight: .regular),
            foreground: .white, underlinePosition: -2, underlineThickness: 1,
            cellWidth: cellWidth * scale, cellHeight: cellHeight * scale, scale: scale))
    }

    private func bytes(_ texture: MTLTexture, bytesPerPixel: Int = 1) -> [UInt8] {
        let stride = texture.width * bytesPerPixel
        var result = [UInt8](repeating: 0, count: stride * texture.height)
        result.withUnsafeMutableBytes { buffer in
            texture.getBytes(buffer.baseAddress!, bytesPerRow: stride,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height),
                             mipmapLevel: 0)
        }
        return result
    }

    private func expandedCoverage(_ texture: MTLTexture, width: Int) -> [UInt8] {
        let pixels = bytes(texture)
        return (0..<texture.height).flatMap { y in
            (0..<width).map { x in pixels[y * texture.width + min(x, texture.width - 1)] }
        }
    }
}

private final class EmptyCoverageTestImage: RenderableCellImage {
    let image = NSImage(size: CGSize(width: 8, height: 8))
    let pixelWidth = 8
    let pixelHeight = 8
    let col = 0
    let kittyIsKitty = false
    let kittyImageId: UInt32? = nil
    let kittyZIndex = 0
    let kittyPixelOffsetX = 0
    let kittyPixelOffsetY = 0
}
