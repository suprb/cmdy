// Full-width generated-color paste response. All 120 cells in every row are checked.
import Foundation
struct PasteRasterDiscovery: Codable, Equatable, Sendable {
    let firstRow: Int
    let redLower: Int, redUpper: Int, greenLower: Int, greenUpper: Int
    let top: Int, rowHeight: Int
}

struct PasteRasterGeometry: Codable, Equatable, Sendable {
    let width: Int
    let height: Int
    let columnSamples: [[Int]]  // Three calibrated interior x pixels/coded cell.
    let rowBands: [ScrollPixelBand]  // Every vertical pixel of all 36 row bands.
    let calibrationSHA256: String
    let discovery: PasteRasterDiscovery

    func validate() throws {
        guard (1...16_384).contains(width), (1...16_384).contains(height), columnSamples.count == 120,
              rowBands.count == 36, calibrationSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ScrollProbeError("missing full-grid raster calibration")
        }
        for points in columnSamples {
            guard points.count == 3, Set(points).count == 3,
                  points == points.sorted(), points.allSatisfy({ 0 <= $0 && $0 < width }) else {
                throw ScrollProbeError("invalid coded-cell x samples")
            }
        }
        for index in 1..<columnSamples.count {
            guard columnSamples[index - 1].last! < columnSamples[index].first! else {
                throw ScrollProbeError("coded-cell x samples overlap or change order")
            }
        }
        for index in rowBands.indices {
            let band = rowBands[index]
            guard band.lower >= 0, band.upper <= height,
                  band.upper - band.lower >= 4,
                  index == 0 || rowBands[index - 1].upper == band.lower else {
                throw ScrollProbeError("row bands have a gap, overlap, or invalid extent")
            }
        }
    }
}

struct PasteExpectedViewport: Codable, Equatable, Sendable {
    let rows: [Int]
    let colors: [[ScrollRGB]]
    let canonicalRowsSHA256: String

    func validate() throws {
        guard rows.count == 36, colors.count == 36,
              let first = rows.first, first >= 0, first + 36 <= 1000,
              rows == Array(first..<(first + 36)),
              canonicalRowsSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              colors.allSatisfy({ $0.count == 120 && $0.allSatisfy {
                  (0...255).contains($0.red) && (0...255).contains($0.green)
                      && (0...255).contains($0.blue)
              } }) else {
            throw ScrollProbeError("expected viewport is not 36 generated consecutive rows")
        }
    }
}

enum PasteViewportMatcher {
    // No OCR or pixel export. Every generated row's complete 120-cell code is
    // checked over its full calibrated vertical span, rather than only at row
    // centers: a partially translated/smooth-scrolling row must not pass early.
    // The horizontal interior points avoid cell-boundary raster rounding only.
    static func matches(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                        geometry: PasteRasterGeometry,
                        expected: PasteExpectedViewport) -> Int? {
        guard bytesPerRow >= geometry.width * 4 else { return nil }
        var checkedPixels = 0
        for row in 0..<36 {
            let band = geometry.rowBands[row]
            for column in 0..<120 {
                let color = expected.colors[row][column]
                for y in band.lower..<band.upper {
                    for x in geometry.columnSamples[column] {
                        let offset = y * bytesPerRow + x * 4
                        guard abs(Int(bytes[offset]) - color.blue) <= 3,
                              abs(Int(bytes[offset + 1]) - color.green) <= 3,
                              abs(Int(bytes[offset + 2]) - color.red) <= 3,
                              bytes[offset + 3] >= 250 else { return nil }
                        checkedPixels += 1
                    }
                }
            }
        }
        return checkedPixels
    }
}


struct PasteFixture: Sendable {
    let token: String
    let viewports: [PasteExpectedViewport]

    init(token: String) throws {
        guard token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            throw ScrollProbeError("invalid generated fixture nonce")
        }
        self.token = token
        var rows: [Data] = []
        var colors: [[ScrollRGB]] = []
        for ordinal in 0..<1000 {
            let ordinalHex = String(format: "%04x", ordinal)
            let joined = token + ordinalHex
            let hex = Array(joined)
            let input = Data(stride(from: 0, to: hex.count, by: 2).map {
                UInt8(String(hex[$0...($0 + 1)]), radix: 16)!
            })
            let code = joined + scrollHash(input).prefix(4)
            let digits = String(String(repeating: code, count: 3).prefix(118))
            let palette = [ScrollRGB(red: 238, green: 40, blue: 40)]
                + digits.map { ScrollRGB(red: 48 + 12 * Int(String($0), radix: 16)!, green: 100, blue: 190) }
                + [ScrollRGB(red: 40, green: 238, blue: 40)]
            colors.append(palette)
            let marker = palette.map { "\u{1b}[48;2;\($0.red);\($0.green);\($0.blue)m " }.joined()
            rows.append(Data(("\u{1b}[0m" + marker + "\u{1b}[0m").utf8))
        }
        // Prepare hashes before native event observation. Hashing generated
        // text is never added to the event-to-frame measurement path.
        viewports = (0...964).map { first in
            var data = Data()
            for row in first..<(first + 36) {
                if row > first { data.append(contentsOf: [13, 10]) }
                data.append(rows[row])
            }
            return PasteExpectedViewport(rows: Array(first..<(first + 36)),
                colors: Array(colors[first..<(first + 36)]), canonicalRowsSHA256: scrollHash(data))
        }
    }
}

enum PasteRaster {
    // Classify actual sampled pixels before consulting any expected viewport.
    // A cell is retained only if every interior sample over its entire vertical
    // band agrees. 254 means mixed classes; 255 means an unknown color/alpha.
    static func observedCellClasses(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                                    geometry: PasteRasterGeometry) -> Data {
        func classify(_ x: Int, _ y: Int) -> UInt8 {
            if pixel(bytes, bytesPerRow, x, y, ScrollRGB(red: 238, green: 40, blue: 40)) { return 16 }
            if pixel(bytes, bytesPerRow, x, y, ScrollRGB(red: 40, green: 238, blue: 40)) { return 17 }
            let red = Int(bytes[y * bytesPerRow + x * 4 + 2])
            let nibble = Int((Double(red - 48) / 12).rounded())
            if (0..<16).contains(nibble), pixel(bytes, bytesPerRow, x, y,
                ScrollRGB(red: 48 + 12 * nibble, green: 100, blue: 190)) { return UInt8(nibble) }
            return 255
        }
        var result = Data(capacity: 120 * 36)
        for row in 0..<36 {
            let band = geometry.rowBands[row]
            for column in 0..<120 {
                let initial = classify(geometry.columnSamples[column][0], band.lower)
                var value = initial
                for y in band.lower..<band.upper {
                    for x in geometry.columnSamples[column] where classify(x, y) != initial { value = 254 }
                }
                result.append(value)
            }
        }
        return result
    }

    static func pixel(_ bytes: UnsafePointer<UInt8>, _ stride: Int,
                      _ x: Int, _ y: Int, _ color: ScrollRGB) -> Bool {
        let offset = y * stride + x * 4
        return abs(Int(bytes[offset]) - color.blue) <= 3
            && abs(Int(bytes[offset + 1]) - color.green) <= 3
            && abs(Int(bytes[offset + 2]) - color.red) <= 3 && bytes[offset + 3] >= 250
    }

    static func scanline(_ bytes: UnsafePointer<UInt8>, _ stride: Int,
                         _ y: Int, _ points: [[Int]], _ colors: [ScrollRGB]) -> Bool {
        for column in 0..<120 {
            for x in points[column] where !pixel(bytes, stride, x, y, colors[column]) { return false }
        }
        return true
    }

    // Locate both sentinel bands, infer the pitch between their centers, and
    // then verify every generated code. No manual coordinates or image files.
    static func calibrate(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                          width: Int, height: Int, fixture: PasteFixture,
                          firstRow: Int = 964) throws -> PasteRasterGeometry? {
        guard (1...16384).contains(width), (1...16384).contains(height),
              bytesPerRow >= width * 4, (0...964).contains(firstRow) else { return nil }
        let viewport = fixture.viewports[firstRow]
        let red = viewport.colors[0][0], green = viewport.colors[0][119]
        var candidates: [PasteRasterGeometry] = []
        for y in 0..<height {
            var x = 0
            while x < width {
                guard pixel(bytes, bytesPerRow, x, y, red) else { x += 1; continue }
                let start = x
                while x < width && pixel(bytes, bytesPerRow, x, y, red) { x += 1 }
                let cellWidth = x - start
                guard (4...100).contains(cellWidth) else { continue }
                // Adjacent palette cells can merge. Sentinels cannot, so their
                // full observed widths constrain fractional-pixel cell pitch.
                let lower = max(x, start + 119 * (cellWidth - 1))
                let upper = min(width, start + 121 * (cellWidth + 1))
                guard lower < upper else { continue }
                var end = lower
                while end < upper && !pixel(bytes, bytesPerRow, end, y, green) { end += 1 }
                guard end < upper else { continue }
                let greenStart = end
                while end < width && pixel(bytes, bytesPerRow, end, y, green) { end += 1 }
                guard abs((end - greenStart) - cellWidth) <= 1 else { continue }
                let redCenter = Double(start + x - 1) / 2
                let greenCenter = Double(greenStart + end - 1) / 2
                let pitch = (greenCenter - redCenter) / 119
                guard pitch >= 4 && abs(pitch - Double(cellWidth)) <= 1 else { continue }
                let points = (0..<120).map { column -> [Int] in
                    let center = Int((redCenter + Double(column) * pitch).rounded())
                    return [center - 1, center, center + 1]
                }
                guard points.flatMap({ $0 }).allSatisfy({ 0 <= $0 && $0 < width }),
                      scanline(bytes, bytesPerRow, y, points, viewport.colors[0]) else { continue }
                // Visit a candidate once at its actual first scanline.
                if y > 0 && scanline(bytes, bytesPerRow, y - 1, points, viewport.colors[0]) { continue }
                var bands: [ScrollPixelBand] = []
                var cursor = y
                for row in 0..<36 {
                    let lower = cursor
                    while cursor < height && scanline(bytes, bytesPerRow, cursor, points, viewport.colors[row]) {
                        cursor += 1
                    }
                    guard cursor - lower >= 4 else { break }
                    bands.append(ScrollPixelBand(lower: lower, upper: cursor))
                }
                guard bands.count == 36 else { continue }
                let heights = bands.map { $0.upper - $0.lower }
                guard heights.max()! == heights.min()! else { continue }
                struct GeometryHash: Encodable {
                    let width: Int, height: Int
                    let columnSamples: [[Int]], rowBands: [ScrollPixelBand]
                    let discovery: PasteRasterDiscovery
                }
                let discovery = PasteRasterDiscovery(firstRow: firstRow, redLower: start, redUpper: x,
                    greenLower: greenStart, greenUpper: end, top: y, rowHeight: heights[0])
                let digest = scrollHash(try scrollCanonicalJSON(GeometryHash(width: width, height: height,
                    columnSamples: points, rowBands: bands, discovery: discovery)))
                let geometry = PasteRasterGeometry(width: width, height: height,
                    columnSamples: points, rowBands: bands, calibrationSHA256: digest, discovery: discovery)
                try geometry.validate()
                if !candidates.contains(geometry) { candidates.append(geometry) }
                guard candidates.count <= 1 else { throw ScrollProbeError("ambiguous generated raster calibration") }
            }
        }
        return candidates.first
    }

    static func decode(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                       geometry: PasteRasterGeometry, fixture: PasteFixture) -> (Int, Int)? {
        // Four ordinal cells follow the 32 nonce cells and first sentinel.
        // Decode at one interior pixel, then validate all 36 complete codes over
        // their entire row bands. A partial/translated row can never acknowledge.
        let y = geometry.rowBands[0].lower
        var ordinal = 0
        for column in 33..<37 {
            let x = geometry.columnSamples[column][1]
            let offset = y * bytesPerRow + x * 4
            let red = Int(bytes[offset + 2])
            let nibble = Int((Double(red - 48) / 12).rounded())
            guard (0..<16).contains(nibble),
                  pixel(bytes, bytesPerRow, x, y, ScrollRGB(red: 48 + nibble * 12, green: 100, blue: 190)) else { return nil }
            ordinal = ordinal * 16 + nibble
        }
        guard ordinal <= 964,
              let pixels = PasteViewportMatcher.matches(bytes: bytes, bytesPerRow: bytesPerRow,
                geometry: geometry, expected: fixture.viewports[ordinal]) else { return nil }
        return (ordinal, pixels)
    }
}
