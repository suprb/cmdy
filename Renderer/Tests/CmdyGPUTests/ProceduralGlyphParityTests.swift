import AppKit
import CoreGraphics
import CryptoKit
import XCTest
@testable import CmdyGPU

final class ProceduralGlyphParityTests: XCTestCase {
    func testDiagonalStrokeCompensationPreservesOnePixelNonRetinaLines() {
        XCTAssertEqual(BoxDrawingRenderer.diagonalStrokeThickness(base: 1), 1)
        XCTAssertEqual(BoxDrawingRenderer.diagonalStrokeThickness(base: 2), 3)
        XCTAssertEqual(BoxDrawingRenderer.diagonalStrokeThickness(base: 3), 4)
    }

    func testArcAnnulusAxesMatchFrozenDevicePixelGeometry() {
        XCTAssertEqual(BoxDrawingRenderer.arcAxisCoordinate(
            length: 12, thickness: 1), 5.5)
        XCTAssertEqual(BoxDrawingRenderer.arcAxisCoordinate(
            length: 24, thickness: 3), 11.5)
        XCTAssertEqual(BoxDrawingRenderer.arcAxisCoordinate(
            length: 32, thickness: 2), 16)
    }

    func testDashSpansMatchReferenceAtOneAndTwoTimesScale() {
        XCTAssertEqual(BoxDrawingRenderer.dashSpans(
            length: 12, count: 3, horizontal: true,
            heavy: false, minimumThickness: 1), [1..<3, 5..<7, 9..<11])
        XCTAssertEqual(BoxDrawingRenderer.dashSpans(
            length: 24, count: 3, horizontal: true,
            heavy: false, minimumThickness: 3), [2..<6, 10..<14, 18..<22])
        XCTAssertEqual(BoxDrawingRenderer.dashSpans(
            length: 24, count: 3, horizontal: false,
            heavy: false, minimumThickness: 1), [0..<4, 8..<12, 16..<20])
        XCTAssertEqual(BoxDrawingRenderer.dashSpans(
            length: 48, count: 3, horizontal: false,
            heavy: false, minimumThickness: 3), [0..<12, 16..<28, 32..<44])

        XCTAssertEqual(BoxDrawingRenderer.dashSpans(
            length: 12, count: 4, horizontal: true,
            heavy: false, minimumThickness: 1), [0..<2, 3..<5, 6..<8, 9..<11])
        XCTAssertEqual(BoxDrawingRenderer.dashSpans(
            length: 48, count: 4, horizontal: false,
            heavy: false, minimumThickness: 3), [0..<8, 12..<20, 24..<32, 36..<44])
    }

    func testOddHorizontalStrokeUsesUpperBiasedCoreGraphicsBand() {
        var pixels = [UInt8](repeating: 0, count: 12 * 24 * 4)
        pixels.withUnsafeMutableBytes { storage in
            let context = CGContext(
                data: storage.baseAddress,
                width: 12, height: 24, bitsPerComponent: 8,
                bytesPerRow: 12 * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue)!
            let canvas = BoxDrawingCanvas(context: context, origin: .zero,
                                          cellWidthPx: 12, cellHeightPx: 24,
                                          minStrokeThicknessPx: 1)
            XCTAssertEqual(canvas.centeredBand(length: 24, thickness: 1), 11..<12)
            XCTAssertEqual(canvas.centeredBand(
                length: 24, thickness: 1, upperBias: true), 12..<13)
        }
    }

    private struct Edges: OptionSet, Equatable {
        let rawValue: UInt8

        static let up = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let down = Edges(rawValue: 1 << 2)
        static let left = Edges(rawValue: 1 << 3)
    }

    private let boxWidth = 512
    private let boxHeight = 384
    private let blockWidth = 512
    private let blockHeight = 256

    func testBlockElementGalleryMatchesFrozenOraclePixelForPixel() {
        let pixels = renderBlockGallery()

        XCTAssertEqual(
            sha256Hex(pixels),
            "5d47dcc76fe5fd03a1499e7260b0c94d076b815dce1793810a9da7cb4e3abe3c"
        )
    }

    func testBoxDrawingGalleryMatchesFrozenOraclePixelForPixel() {
        XCTAssertEqual(
            sha256Hex(renderBoxGallery()),
            "b51fc23af1b39cad4348b99f03397838472707ee2827e0c2e83755bd5af61434"
        )
    }

    func testEveryContinuousBoxGlyphExposesExactlyItsUnicodeNamedEdges() {
        var checked = 0
        for codePoint in UInt32(0x2500)...UInt32(0x257F) {
            let name = Unicode.Scalar(codePoint)?.properties.name ?? ""
            if name.contains("DASH") || name.contains("DIAGONAL") {
                continue
            }

            let tokens = Set(name.split(separator: " "))
            var expected: Edges = []
            if tokens.contains("UP") || tokens.contains("VERTICAL") {
                expected.insert(.up)
            }
            if tokens.contains("RIGHT") || tokens.contains("HORIZONTAL") {
                expected.insert(.right)
            }
            if tokens.contains("DOWN") || tokens.contains("VERTICAL") {
                expected.insert(.down)
            }
            if tokens.contains("LEFT") || tokens.contains("HORIZONTAL") {
                expected.insert(.left)
            }

            let pixels = renderBoxGlyph(codePoint)
            XCTAssertEqual(
                exposedEdges(in: pixels, width: 32, height: 48),
                expected,
                String(format: "U+%04X %@", codePoint, name)
            )
            checked += 1
        }
        XCTAssertEqual(checked, 113)
    }

    func testBlockMappingExhaustivelyCoversOnlyItsUnicodeRange() {
        XCTAssertEqual(BlockElementMapping.lowerBoundary, 0x2580)
        XCTAssertEqual(BlockElementMapping.upperBoundary, 0x259F)
        XCTAssertNil(BlockElementMapping.rects(for: 0x257F))
        XCTAssertNil(BlockElementMapping.rects(for: 0x25A0))

        for codePoint in UInt32(0x2580)...UInt32(0x259F) {
            let rects = try! XCTUnwrap(BlockElementMapping.rects(for: codePoint))
            XCTAssertFalse(rects.isEmpty, String(format: "U+%04X", codePoint))
            for rect in rects {
                XCTAssertLessThan(rect.x0, rect.x1)
                XCTAssertLessThan(rect.y0, rect.y1)
                XCTAssertLessThanOrEqual(rect.x1, 8)
                XCTAssertLessThanOrEqual(rect.y1, 8)
            }
        }
    }

    func testCompoundBlockMappingsPreserveReferenceQuadrantDecomposition() {
        let expected: [UInt32: [(UInt8, UInt8, UInt8, UInt8)]] = [
            0x2599: [(0, 4, 0, 4), (0, 4, 4, 8), (4, 8, 4, 8)],
            0x259B: [(0, 4, 0, 4), (4, 8, 0, 4), (0, 4, 4, 8)],
            0x259C: [(0, 4, 0, 4), (4, 8, 0, 4), (4, 8, 4, 8)],
            0x259F: [(4, 8, 0, 4), (0, 4, 4, 8), (4, 8, 4, 8)],
        ]

        for (codePoint, expectedRects) in expected {
            let actual = BlockElementMapping.rects(for: codePoint)?.map {
                ($0.x0, $0.x1, $0.y0, $0.y1)
            }
            XCTAssertEqual(actual?.count, expectedRects.count)
            for (actualRect, expectedRect) in zip(actual ?? [], expectedRects) {
                XCTAssertEqual(actualRect.0, expectedRect.0)
                XCTAssertEqual(actualRect.1, expectedRect.1)
                XCTAssertEqual(actualRect.2, expectedRect.2)
                XCTAssertEqual(actualRect.3, expectedRect.3)
            }
        }
    }

    private func renderBoxGallery() -> [UInt8] {
        bitmap(width: boxWidth, height: boxHeight) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: boxWidth, height: boxHeight))
            context.translateBy(x: 0, y: CGFloat(boxHeight))
            context.scaleBy(x: 1, y: -1)

            for index in 0..<128 {
                BoxDrawingRenderer.draw(
                    codePoint: UInt32(0x2500 + index),
                    in: context,
                    cellOrigin: CGPoint(x: (index % 16) * 32, y: (index / 16) * 48),
                    cellSize: CGSize(width: 16, height: 24),
                    scale: 2,
                    color: .white,
                    baseThicknessPx: 2
                )
            }
        }
    }

    private func renderBlockGallery() -> [UInt8] {
        bitmap(width: blockWidth, height: blockHeight) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: blockWidth, height: blockHeight))

            for index in 0..<32 {
                let row = index / 8
                let column = index % 8
                let origin = CGPoint(x: column * 64, y: (3 - row) * 64)
                for rect in BlockElementMapping.rects(for: UInt32(0x2580 + index)) ?? [] {
                    context.setFillColor(
                        NSColor.white.withAlphaComponent(rect.alpha.rawValue).cgColor
                    )
                    context.fill(
                        rect.rect(
                            in: origin,
                            xEighth: 8,
                            yEighth: 8,
                            cellHeight: 64
                        )
                    )
                }
            }
        }
    }

    private func renderBoxGlyph(_ codePoint: UInt32) -> [UInt8] {
        bitmap(width: 32, height: 48) { context in
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 48))
            context.translateBy(x: 0, y: 48)
            context.scaleBy(x: 1, y: -1)
            BoxDrawingRenderer.draw(
                codePoint: codePoint,
                in: context,
                cellOrigin: .zero,
                cellSize: CGSize(width: 16, height: 24),
                scale: 2,
                color: .white,
                baseThicknessPx: 2
            )
        }
    }

    private func bitmap(width: Int,
                        height: Int,
                        draw: (CGContext) -> Void) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { storage in
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue
            let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            )!
            draw(context)
        }
        return pixels
    }

    private func exposedEdges(in pixels: [UInt8], width: Int, height: Int) -> Edges {
        func hasInk(x: Int, y: Int) -> Bool {
            let offset = (y * width + x) * 4
            return pixels[offset] > 0 || pixels[offset + 1] > 0 || pixels[offset + 2] > 0
        }

        var result: Edges = []
        if (0..<width).contains(where: { hasInk(x: $0, y: 0) }) {
            result.insert(.up)
        }
        if (0..<height).contains(where: { hasInk(x: width - 1, y: $0) }) {
            result.insert(.right)
        }
        if (0..<width).contains(where: { hasInk(x: $0, y: height - 1) }) {
            result.insert(.down)
        }
        if (0..<height).contains(where: { hasInk(x: 0, y: $0) }) {
            result.insert(.left)
        }
        return result
    }

    private func sha256Hex(_ pixels: [UInt8]) -> String {
        SHA256.hash(data: Data(pixels))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
