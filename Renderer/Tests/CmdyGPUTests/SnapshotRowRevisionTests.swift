import AppKit
import MetalKit
import XCTest
@_spi(CmdyApp) @testable import CmdyGPU

@MainActor
final class SnapshotRowRevisionTests: XCTestCase {
    func testDistantEditsDoNotRevisitUnchangedRowsInsideDirtySpan() throws {
        let renderer = try makeRenderer()
        for row in 0..<36 {
            _ = try resolve(renderer, row: row, version: UInt64(row + 1),
                            info: line("row \(row)"), revision: token(row + 1))
        }
        var requested: [Int] = []
        func changedInfo(_ row: Int) -> ViewLineInfo {
            requested.append(row)
            return line(row == 0 || row == 34 ? "changed \(row)" : "row \(row)")
        }
        let rebuilt = MetalTerminalRenderer.rowsRebuilt
        for row in 0..<36 {
            let version = row == 0 || row == 34 ? row + 100 : row + 1
            _ = try resolve(renderer, row: row, version: UInt64(version), dirty: row <= 34,
                            info: changedInfo(row), revision: token(version))
        }
        XCTAssertEqual(requested, [0, 34])
        XCTAssertEqual(MetalTerminalRenderer.rowsRebuilt - rebuilt, 2)
    }

    func testContextChangeRevalidatesUnicodeStylesWithUnchangedContentVersion() throws {
        for scale: CGFloat in [1, 2] {
            let renderer = try makeRenderer()
            let original = try resolve(renderer, info: unicodeLine(color: .red),
                                       revision: token(1), scale: scale)
            var calls = 0
            func changedInfo() -> ViewLineInfo {
                calls += 1
                return unicodeLine(color: .green)
            }
            let changed = try resolve(renderer, info: changedInfo(),
                                      revision: token(1, context: 2), scale: scale)
            let fresh = try resolve(makeRenderer(), info: unicodeLine(color: .green),
                                    revision: token(1, context: 2), scale: scale)
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(changed.coverageTexture === original.coverageTexture)
            try assertPayloadEqual(changed, fresh)
            calls = 0
            let reused = try resolve(renderer, info: changedInfo(),
                                     revision: token(1, context: 2), scale: scale)
            XCTAssertEqual(calls, 0)
            XCTAssertTrue(reused.coverageTexture === changed.coverageTexture)
        }
    }

    func testMissingZeroAndMismatchedRevisionsPreserveExplicitDirtyContract() throws {
        for invalid in [nil, token(2), token(1, context: 0), token(0)] {
            let renderer = try makeRenderer()
            let original = try resolve(renderer, info: line("old"), revision: token(1))
            var calls = 0
            func changedInfo() -> ViewLineInfo { calls += 1; return line("new") }
            let changed = try resolve(renderer, info: changedInfo(), revision: invalid)
            XCTAssertEqual(calls, 1)
            XCTAssertNil(changed.snapshotRevision)
            XCTAssertFalse(changed.coverageTexture === original.coverageTexture)
            _ = try resolve(renderer, info: changedInfo(), revision: token(1))
            XCTAssertEqual(calls, 2, "An invalid token must not seed a later shortcut")
        }
    }

    func testExactRasterGeometryFontAndDECStillGateRevisionReuse() throws {
        let variants: [(CGFloat, CGFloat, CGFloat, NSFont, RenderLineMode)] = [
            (11.99, -2, 1, font(), .single),
            (12, -3, 1, font(), .single),
            (12, -2, 2, font(), .single),
            (12, -2, 1, .monospacedSystemFont(ofSize: 14, weight: .bold), .single),
            (12, -2, 1, font(), .doubleWidth),
        ]
        for (width, position, thickness, font, mode) in variants {
            let renderer = try makeRenderer()
            _ = try resolve(renderer, info: line("A"), revision: token(1))
            var calls = 0
            func info() -> ViewLineInfo { calls += 1; return line("A") }
            _ = try resolve(renderer, info: info(), revision: token(1),
                            cellWidth: width, underlinePosition: position,
                            underlineThickness: thickness, normalFont: font, mode: mode)
            XCTAssertEqual(calls, 1)
        }
        let renderer = try makeRenderer()
        _ = try resolve(renderer, info: line("A"), revision: token(1))
        var calls = 0
        func resizedInfo() -> ViewLineInfo { calls += 1; return line("A") }
        _ = try resolve(renderer, info: resizedInfo(), revision: token(1), scale: 2)
        XCTAssertEqual(calls, 1)
    }

    func testForceInvalidationAndUnsupportedRowsCannotUseRevisionShortcut() throws {
        let renderer = try makeRenderer()
        _ = try resolve(renderer, info: line("A"), revision: token(1))
        renderer.invalidateRowCache()
        var calls = 0
        func info() -> ViewLineInfo { calls += 1; return line("A") }
        _ = try resolve(renderer, info: info(), revision: token(1))
        XCTAssertEqual(calls, 1)

        var image = line("A")
        image.images = [RevisionTestImage()]
        var kitty = line("A")
        kitty.kittyPlaceholders = [KittyPlaceholderCell(row: 0, col: 0, imageId: 1,
            placementId: 1, placeholderRow: 0, placeholderCol: 0, msb: 0)]
        var procedural = line("A")
        procedural.boxDrawings = [BoxDrawingRenderItem(column: 0, columnWidth: 1,
            codePoint: 0x2500, foregroundColor: .white)]
        let unknown = line("A", attributes: [NSAttributedString.Key("unmodeled"): 1])
        for value in [image, kitty, procedural, unknown] {
            let renderer = try makeRenderer()
            calls = 0
            func unsupported() -> ViewLineInfo { calls += 1; return value }
            let first = try resolve(renderer, info: unsupported(), revision: token(1))
            let second = try resolve(renderer, info: unsupported(), revision: token(1))
            XCTAssertNil(first.snapshotRevision)
            XCTAssertNil(second.snapshotRevision)
            XCTAssertEqual(calls, 2)
        }
    }

    func testCleanCacheHitDoesNotEvaluateRevisionContextOrLineInfo() throws {
        let renderer = try makeRenderer()
        _ = try resolve(renderer, info: line("A"), revision: token(1))
        var infoCalls = 0
        var revisionCalls = 0
        func info() -> ViewLineInfo { infoCalls += 1; return line("A") }
        func revision() -> SnapshotRowRevision { revisionCalls += 1; return token(1) }
        _ = try resolve(renderer, dirty: false, info: info(), revision: revision())
        XCTAssertEqual(infoCalls, 0)
        XCTAssertEqual(revisionCalls, 0)
    }

    private func makeRenderer() throws -> NativeRendererCacheHarness {
        try NativeRendererCacheHarness(view: MTKView(frame: .zero,
            device: XCTUnwrap(MTLCreateSystemDefaultDevice())), source: MemoryRenderSource())
    }

    private func font() -> NSFont { .monospacedSystemFont(ofSize: 14, weight: .regular) }
    private func token(_ version: Int, context: UInt64 = 1) -> SnapshotRowRevision {
        SnapshotRowRevision(content: UInt64(version), context: context)
    }

    private func line(_ text: String, attributes: [NSAttributedString.Key: Any] = [:]) -> ViewLineInfo {
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font(), .foregroundColor: NSColor.white,
        ].merging(attributes, uniquingKeysWith: { _, value in value }))
        return ViewLineInfo(segments: [ViewLineSegment(column: 0, columnWidth: 1,
            characterCount: attributed.length, attributedString: attributed,
            cellUTF16Boundaries: Array(0...attributed.length))], images: nil)
    }

    private func unicodeLine(color: NSColor) -> ViewLineInfo {
        var segments: [ViewLineSegment] = []
        for (text, column, width) in [("e\u{301}", 0, 1), ("中", 1, 2), ("🙂", 3, 2)] {
            let attributed = NSAttributedString(string: text, attributes: [
                .font: font(), .foregroundColor: color,
                .backgroundColor: NSColor.blue.withAlphaComponent(0.2),
                .cmdyUnderlineStyle: RenderUnderlineStyle.curly.rawValue,
                .cmdyUnderlineColor: color,
            ])
            segments.append(ViewLineSegment(column: column, columnWidth: width,
                characterCount: 1, attributedString: attributed,
                cellUTF16Boundaries: [0, attributed.length]))
        }
        return ViewLineInfo(segments: segments, images: nil)
    }

    private func resolve(_ renderer: NativeRendererCacheHarness, row: Int = 0,
                         version: UInt64 = 1, dirty: Bool = true,
                         info: @autoclosure () -> ViewLineInfo,
                         revision: @autoclosure () -> SnapshotRowRevision?,
                         scale: CGFloat = 1, cellWidth: CGFloat = 12,
                         underlinePosition: CGFloat = -2, underlineThickness: CGFloat = 1,
                         normalFont: NSFont? = nil, mode: RenderLineMode = .single) throws
        -> IndependentRowCacheEntry {
        let font = normalFont ?? self.font()
        let key = IndependentRowKey(absoluteRow: row, version: version,
            lineMode: mode, cols: 16, widthPx: Int(192 * scale), heightPx: Int(24 * scale),
            scaleBits: Double(scale).bitPattern, fontName: font.fontName,
            fontSizeBits: Double(font.pointSize).bitPattern, alternateBuffer: false,
            kittyStamp: KittyCacheStamp(imagesCount: 0, placementsCount: 0,
                nextImageId: 0, nextPlacementId: 0),
            foreground: IndependentRowRasterizer.packedColor(.white),
            background: IndependentRowRasterizer.packedColor(.black), preset: .current,
            antialiasBlocks: true, bufferingMode: .perRowPersistent)
        return try XCTUnwrap(renderer.resolveRowEntry(key: key, explicitlyDirty: dirty,
            info: info(), revision: revision(),
            scaledFont: NSFont(descriptor: font.fontDescriptor, size: font.pointSize * scale)!,
            foreground: .white, underlinePosition: underlinePosition,
            underlineThickness: underlineThickness,
            cellWidth: cellWidth * scale, cellHeight: 24 * scale, scale: scale))
    }

    private func assertPayloadEqual(_ actual: IndependentRowCacheEntry,
                                    _ expected: IndependentRowCacheEntry) throws {
        XCTAssertEqual(bytes(actual.coverageTexture), bytes(expected.coverageTexture))
        XCTAssertEqual(actual.backgrounds.map(\.rect), expected.backgrounds.map(\.rect))
        XCTAssertEqual(actual.backgrounds.map(\.color), expected.backgrounds.map(\.color))
        XCTAssertEqual(actual.tintSpans.map(\.rect), expected.tintSpans.map(\.rect))
        XCTAssertEqual(actual.tintSpans.map(\.color), expected.tintSpans.map(\.color))
        XCTAssertEqual(actual.decorations.map(\.rect), expected.decorations.map(\.rect))
        XCTAssertEqual(actual.decorations.map(\.color), expected.decorations.map(\.color))
        XCTAssertEqual(actual.colorLayers.map(\.rect), expected.colorLayers.map(\.rect))
        for (a, b) in zip(actual.colorLayers, expected.colorLayers) {
            XCTAssertEqual(bytes(a.texture), bytes(b.texture))
        }
    }

    private func bytes(_ texture: MTLTexture?) -> [UInt8] {
        guard let texture else { return [] }
        let stride = texture.width * (texture.pixelFormat == .r8Unorm ? 1 : 4)
        var result = [UInt8](repeating: 0, count: stride * texture.height)
        result.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: stride,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        return result
    }
}

private final class RevisionTestImage: RenderableCellImage {
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
