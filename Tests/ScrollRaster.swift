// Pure generated-raster calibration/decoding. No native capture or event APIs.
import CryptoKit
import Foundation

func scrollHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func scrollCanonicalJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}

struct ScrollFixture: Sendable {
    let token: String
    let viewports: [ScrollExpectedViewport]

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
            let digits = joined + scrollHash(input).prefix(4)
            let palette = [ScrollRGB(red: 238, green: 40, blue: 40)]
                + digits.map { ScrollRGB(red: 48 + 12 * Int(String($0), radix: 16)!, green: 100, blue: 190) }
                + [ScrollRGB(red: 40, green: 238, blue: 40)]
            colors.append(palette)
            let marker = palette.map { "\u{1b}[48;2;\($0.red);\($0.green);\($0.blue)m " }.joined()
            var body = String(format: " row %04d generated scroll fixture ", ordinal)
                + scrollHash(Data("\(token)/\(ordinal)".utf8))
            body = String(body.prefix(78)).padding(toLength: 78, withPad: " ", startingAt: 0)
            rows.append(Data(("\u{1b}[0m" + marker + "\u{1b}[0m" + body).utf8))
        }
        // Prepare hashes before native event observation. Hashing generated
        // text is never added to the event-to-frame measurement path.
        viewports = (0...964).map { first in
            var data = Data()
            for row in first..<(first + 36) {
                if row > first { data.append(contentsOf: [13, 10]) }
                data.append(rows[row])
            }
            return ScrollExpectedViewport(rows: Array(first..<(first + 36)),
                colors: Array(colors[first..<(first + 36)]), canonicalRowsSHA256: scrollHash(data))
        }
    }
}

enum ScrollRaster {
    static func pixel(_ bytes: UnsafePointer<UInt8>, _ stride: Int,
                      _ x: Int, _ y: Int, _ color: ScrollRGB) -> Bool {
        let offset = y * stride + x * 4
        return abs(Int(bytes[offset]) - color.blue) <= 3
            && abs(Int(bytes[offset + 1]) - color.green) <= 3
            && abs(Int(bytes[offset + 2]) - color.red) <= 3 && bytes[offset + 3] >= 250
    }

    static func scanline(_ bytes: UnsafePointer<UInt8>, _ stride: Int,
                         _ y: Int, _ points: [[Int]], _ colors: [ScrollRGB]) -> Bool {
        for column in 0..<42 {
            for x in points[column] where !pixel(bytes, stride, x, y, colors[column]) { return false }
        }
        return true
    }

    // Locate both sentinel bands, infer the pitch between their centers, and
    // then verify every generated code. No manual coordinates or image files.
    static func calibrate(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                          width: Int, height: Int, fixture: ScrollFixture,
                          firstRow: Int = 964) throws -> ScrollRasterGeometry? {
        guard (1...16384).contains(width), (1...16384).contains(height),
              bytesPerRow >= width * 4, (0...964).contains(firstRow) else { return nil }
        let viewport = fixture.viewports[firstRow]
        let red = viewport.colors[0][0], green = viewport.colors[0][41]
        var candidates: [ScrollRasterGeometry] = []
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
                let lower = max(x, start + 41 * (cellWidth - 1))
                let upper = min(width, start + 43 * (cellWidth + 1))
                guard lower < upper else { continue }
                var end = lower
                while end < upper && !pixel(bytes, bytesPerRow, end, y, green) { end += 1 }
                guard end < upper else { continue }
                let greenStart = end
                while end < width && pixel(bytes, bytesPerRow, end, y, green) { end += 1 }
                guard abs((end - greenStart) - cellWidth) <= 1 else { continue }
                let redCenter = Double(start + x - 1) / 2
                let greenCenter = Double(greenStart + end - 1) / 2
                let pitch = (greenCenter - redCenter) / 41
                guard pitch >= 4 && abs(pitch - Double(cellWidth)) <= 1 else { continue }
                let points = (0..<42).map { column -> [Int] in
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
                }
                let digest = scrollHash(try scrollCanonicalJSON(GeometryHash(width: width, height: height,
                    columnSamples: points, rowBands: bands)))
                let geometry = ScrollRasterGeometry(width: width, height: height,
                    columnSamples: points, rowBands: bands, calibrationSHA256: digest)
                try geometry.validate()
                if !candidates.contains(geometry) { candidates.append(geometry) }
                guard candidates.count <= 1 else { throw ScrollProbeError("ambiguous generated raster calibration") }
            }
        }
        return candidates.first
    }

    static func decode(bytes: UnsafePointer<UInt8>, bytesPerRow: Int,
                       geometry: ScrollRasterGeometry, fixture: ScrollFixture) -> (Int, Int)? {
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
              let pixels = ScrollViewportMatcher.matches(bytes: bytes, bytesPerRow: bytesPerRow,
                geometry: geometry, expected: fixture.viewports[ordinal]) else { return nil }
        return (ordinal, pixels)
    }
}
