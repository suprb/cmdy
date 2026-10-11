// Full generated startup viewport, derived from the preserved frame-grid-03 pure matcher.
// Every cell is validated; no native process/UI APIs. Historical source is unchanged.
import Foundation
import CryptoKit

struct StartupGridError: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}
private func gridRequire(_ value: Bool, _ message: String) throws {
    if !value { throw StartupGridError(message) }
}
func gridCanonical<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func gridHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
struct StartupGridRGB: Codable, Equatable, Sendable {
    let red: Int, green: Int, blue: Int
    init(_ red: Int, _ green: Int, _ blue: Int) { self.red = red; self.green = green; self.blue = blue }
}
struct StartupGridWitness: Codable, Equatable, Sendable {
    let token: String
    let columns: Int, rows: Int, generation: Int, frameKind: Int
    func validate() throws {
        try gridRequire(token.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil
            && (44...255).contains(columns) && (4...255).contains(rows)
            && (1...64).contains(generation) && frameKind == 1, "invalid bounded generated grid witness")
    }
    func payload() throws -> String {
        try validate()
        return "3" + token + String(format: "%02x%02x%02x%x", columns, rows, generation, frameKind)
    }
    func headerColors() throws -> [StartupGridRGB] {
        [StartupGridRGB(238, 40, 40)] + (try payload()).map {
            StartupGridRGB(48 + 12 * Int(String($0), radix: 16)!, 100, 190)
        } + [StartupGridRGB(40, 238, 40)]
    }
    func color(column: Int, row: Int) throws -> StartupGridRGB? {
        try validate()
        try gridRequire((0..<columns).contains(column) && (0..<rows).contains(row), "generated cell lies outside grid")
        if row == 0 && column < 42 { return try headerColors()[column] }
        if row != 0 && row != rows - 1 && column != 0 && column != columns - 1 {
            let text = try payload() + String(format: "/%04x/%04x", column, row)
            var crc: UInt32 = 0xffffffff
            for byte in text.utf8 {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
            }
            let code = Int((~crc) & 15)
            return StartupGridRGB(36 + (code % 4) * 48, 36 + (code / 4) * 48, 212)
        }
        let phase = (column + row) % 3
        let component = ((generation - 1) >> (2 * phase)) & 3
        return StartupGridRGB(55 + 50 * component, 55 + 110 * ((column + row) % 2), 55 + 50 * phase)
    }
    func generatedDigest() throws -> String {
        struct Value: Encodable { let header: String; let cells: [[Int]] }
        var cells: [[Int]] = []
        for row in 0..<rows { for column in 0..<columns {
            if let value = try color(column: column, row: row) {
                cells.append([column, row, value.red, value.green, value.blue])
            }
        }}
        return gridHash(try gridCanonical(Value(header: payload(), cells: cells)))
    }
    static func decode(_ value: String, token: String) throws -> StartupGridWitness {
        try gridRequire(value.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                        "partial generated header")
        let bytes = Array(value)
        try gridRequire(bytes[0] == "3" && String(bytes[1..<33]) == token, "foreign/version-mismatched generated header")
        let result = StartupGridWitness(token: token, columns: Int(String(bytes[33..<35]), radix: 16)!,
            rows: Int(String(bytes[35..<37]), radix: 16)!, generation: Int(String(bytes[37..<39]), radix: 16)!,
            frameKind: Int(String(bytes[39]), radix: 16)!)
        try result.validate(); return result
    }
}
struct StartupGridPixelRect: Equatable, Sendable {
    let x0: Int, y0: Int, x1: Int, y1: Int
}
struct StartupGridBand: Codable, Equatable, Sendable {
    let lower: Int, upper: Int
    var center: Int { (lower + upper - 1) / 2 }
}
struct StartupGridHeader: Codable, Equatable, Sendable {
    let witness: StartupGridWitness
    let red: StartupGridBand, green: StartupGridBand, vertical: StartupGridBand
}
struct StartupGridRaster: Codable, Equatable, Sendable {
    let width: Int, height: Int
    let xEdges: [Int], yEdges: [Int]
    let sampleInsetPixels: Int
    let edgeRoundingPixels: Int
    func validate(columns: Int, rows: Int) throws {
        try gridRequire((1...16384).contains(width) && (1...16384).contains(height)
            && xEdges.count == columns + 1 && yEdges.count == rows + 1
            && sampleInsetPixels == 2 && edgeRoundingPixels == 1, "incomplete full-grid raster geometry")
        for (edges, limit) in [(xEdges, width), (yEdges, height)] {
            try gridRequire(edges.allSatisfy { $0 >= 0 && $0 <= limit }, "raster leaves captured pixels")
            let sizes = zip(edges, edges.dropFirst()).map { $1 - $0 }
            try gridRequire(sizes.allSatisfy { (5...100).contains($0) }
                && sizes.max()! - sizes.min()! <= 2, "cell edges are missing, irregular or below uniform sampling bound")
        }
    }
    func agrees(with other: StartupGridRaster) -> Bool {
        width == other.width && height == other.height && sampleInsetPixels == other.sampleInsetPixels
            && edgeRoundingPixels == other.edgeRoundingPixels
            && xEdges.count == other.xEdges.count && yEdges.count == other.yEdges.count
            && zip(xEdges, other.xEdges).allSatisfy { abs($0 - $1) <= 1 }
            && zip(yEdges, other.yEdges).allSatisfy { abs($0 - $1) <= 1 }
    }
}
struct StartupGridProof: Codable, Equatable, Sendable {
    let witness: StartupGridWitness
    let raster: StartupGridRaster
    let checkedCells: Int, checkedPixels: Int
    let generatedSHA256: String, checkedPixelsSHA256: String
    // Lossless row-major BGRA RLE of only already-validated generated pixels.
    // [count, blue, green, red, alpha]; no unrelated/window/terminal pixels.
    let checkedPixelRuns: [[Int]]
}
struct StartupGridPixels {
    let bytes: UnsafePointer<UInt8>
    let width: Int, height: Int, bytesPerRow: Int
    func valid(_ rectangle: StartupGridPixelRect) -> Bool {
        (1...16384).contains(width) && (1...16384).contains(height) && bytesPerRow >= width * 4
            && rectangle.x0 >= 0 && rectangle.y0 >= 0 && rectangle.x1 <= width && rectangle.y1 <= height
            && rectangle.x0 < rectangle.x1 && rectangle.y0 < rectangle.y1
    }
    func equal(_ x: Int, _ y: Int, _ color: StartupGridRGB) -> Bool {
        guard x >= 0 && x < width && y >= 0 && y < height else { return false }
        let offset = y * bytesPerRow + x * 4
        return abs(Int(bytes[offset]) - color.blue) <= 3 && abs(Int(bytes[offset + 1]) - color.green) <= 3
            && abs(Int(bytes[offset + 2]) - color.red) <= 3 && bytes[offset + 3] >= 250
    }
}

enum StartupGridMatcher {
    // A header is a candidate only. It cannot acknowledge a full visible grid.
    static func header(_ pixels: StartupGridPixels, rectangle: StartupGridPixelRect,
                       token: String) throws -> StartupGridHeader? {
        guard pixels.valid(rectangle) else { throw StartupGridError("invalid owned pixel rectangle") }
        let red = StartupGridRGB(238, 40, 40), green = StartupGridRGB(40, 238, 40)
        var found: StartupGridHeader?
        func row(_ first: Double, _ last: Double, _ y: Int, _ colors: [StartupGridRGB]) -> Bool {
            let pitch = (last - first) / 41
            guard pitch >= 4 else { return false }
            for index in 0..<42 {
                let center = Int((first + Double(index) * pitch).rounded())
                guard center - 1 >= rectangle.x0 && center + 1 < rectangle.x1,
                      (center - 1...center + 1).allSatisfy({ pixels.equal($0, y, colors[index]) }) else { return false }
            }
            return true
        }
        for y in rectangle.y0..<max(rectangle.y0, rectangle.y1 - 4) {
            var x = rectangle.x0
            while x < rectangle.x1 {
                guard pixels.equal(x, y, red) else { x += 1; continue }
                let left = x
                while x < rectangle.x1 && pixels.equal(x, y, red) { x += 1 }
                guard x - left >= 3 else { continue }
                let first = Double(left + x - 1) / 2
                var right = x
                while right < rectangle.x1 && !pixels.equal(right, y, green) { right += 1 }
                let greenLeft = right
                while right < rectangle.x1 && pixels.equal(right, y, green) { right += 1 }
                guard right - greenLeft >= 3 else { continue }
                let last = Double(greenLeft + right - 1) / 2, pitch = (last - first) / 41
                guard pitch >= 4 && pitch <= 100 else { continue }
                var value = ""
                for index in 1...40 {
                    let center = Int((first + Double(index) * pitch).rounded())
                    guard center >= rectangle.x0 && center < rectangle.x1 else { break }
                    let offset = y * pixels.bytesPerRow + center * 4
                    let digit = Int((Double(Int(pixels.bytes[offset + 2]) - 48) / 12).rounded())
                    guard (0...15).contains(digit), pixels.equal(center, y, StartupGridRGB(48 + 12 * digit, 100, 190)) else { break }
                    value += String(digit, radix: 16)
                }
                guard let witness = try? StartupGridWitness.decode(value, token: token),
                      let colors = try? witness.headerColors(), row(first, last, y, colors),
                      row(first, last, y + 2, colors), row(first, last, y + 4, colors) else { continue }
                var low = y, high = y + 5
                while low > rectangle.y0 && row(first, last, low - 1, colors) { low -= 1 }
                while high < rectangle.y1 && row(first, last, high, colors) { high += 1 }
                let candidate = StartupGridHeader(witness: witness, red: StartupGridBand(lower: left, upper: x),
                    green: StartupGridBand(lower: greenLeft, upper: right), vertical: StartupGridBand(lower: low, upper: high))
                if let found {
                    try gridRequire(found.witness == candidate.witness && found.vertical == candidate.vertical
                        && abs(found.red.lower - candidate.red.lower) <= 1 && abs(found.red.upper - candidate.red.upper) <= 1
                        && abs(found.green.lower - candidate.green.lower) <= 1 && abs(found.green.upper - candidate.green.upper) <= 1,
                        "multiple or inconsistent full launch headers")
                } else { found = candidate }
            }
        }
        return found
    }

    private static func horizontal(_ pixels: StartupGridPixels, rectangle: StartupGridPixelRect,
                                   x: Int, y: Int, colors: [StartupGridRGB]) -> [StartupGridBand]? {
        var cursor = x, bands: [StartupGridBand] = []
        guard cursor >= rectangle.x0 && cursor < rectangle.x1 else { return nil }
        for index in colors.indices {
            if index > 0 {
                var gap = 0
                while cursor < rectangle.x1 && !pixels.equal(cursor, y, colors[index]) && gap <= 2 { cursor += 1; gap += 1 }
                guard gap <= 2 else { return nil }
            }
            let low = cursor
            while cursor < rectangle.x1 && pixels.equal(cursor, y, colors[index]) { cursor += 1 }
            guard cursor < rectangle.x1 && (3...100).contains(cursor - low) else { return nil }
            bands.append(StartupGridBand(lower: low, upper: cursor))
        }
        return bands
    }

    static func discover(_ pixels: StartupGridPixels, rectangle: StartupGridPixelRect,
                         header: StartupGridHeader,
                         diagnostic: ((String, [Int]) -> Void)? = nil) throws -> StartupGridProof? {
        diagnostic?("header-decoded", [header.vertical.lower, header.vertical.upper])
        let witness = header.witness
        try witness.validate()
        guard pixels.valid(rectangle) else { throw StartupGridError("invalid owned raster") }
        let bottomColors = try (0..<witness.columns).map { try witness.color(column: $0, row: witness.rows - 1)! }
        var bottom: (StartupGridBand, [StartupGridBand])?
        var y = header.vertical.upper
        while y < rectangle.y1 {
            var rowBands: [StartupGridBand]?
            for x in max(rectangle.x0, header.red.lower - 2)...min(rectangle.x1 - 1, header.red.lower + 2) {
                if let bands = horizontal(pixels, rectangle: rectangle, x: x, y: y, colors: bottomColors) {
                    rowBands = bands; break
                }
            }
            guard let columns = rowBands else { y += 1; continue }
            let low = y
            while y < rectangle.y1 && horizontal(pixels, rectangle: rectangle, x: columns[0].lower, y: y,
                                                  colors: bottomColors) == columns { y += 1 }
            guard y - low >= 3 else { continue }
            if bottom != nil { throw StartupGridError("ambiguous complete bottom boundary") }
            bottom = (StartupGridBand(lower: low, upper: y), columns)
        }
        guard let (bottomBand, columns) = bottom else { return nil }
        diagnostic?("bottom-decoded", [bottomBand.lower, bottomBand.upper])
        var xEdges = [columns[0].lower]
        for index in 1..<columns.count { xEdges.append((columns[index - 1].upper + columns[index].lower) / 2) }
        xEdges.append(columns.last!.upper)
        let rightX = columns.last!.center
        let sideColors = try (1..<witness.rows).map { try witness.color(column: witness.columns - 1, row: $0)! }
        func side(_ y: Int, _ color: StartupGridRGB) -> Bool {
            (rightX - 1...rightX + 1).allSatisfy { pixels.equal($0, y, color) }
        }
        var cursor = header.vertical.upper
        while cursor < bottomBand.lower && !side(cursor, sideColors[0]) { cursor += 1 }
        var sideBands: [StartupGridBand] = []
        for color in sideColors {
            var gap = 0
            while cursor < rectangle.y1 && !side(cursor, color) && gap <= 2 { cursor += 1; gap += 1 }
            guard gap <= 2 else {
                diagnostic?("side-gap", [sideBands.count, rightX, cursor, gap])
                return nil
            }
            let low = cursor
            while cursor < rectangle.y1 && side(cursor, color) { cursor += 1 }
            guard (3...100).contains(cursor - low) else {
                diagnostic?("side-length", [sideBands.count, rightX, low, cursor])
                return nil
            }
            sideBands.append(StartupGridBand(lower: low, upper: cursor))
        }
        guard sideBands.count == witness.rows - 1,
              abs(sideBands.last!.lower - bottomBand.lower) <= 1,
              abs(sideBands.last!.upper - bottomBand.upper) <= 1 else {
            diagnostic?("side-bottom-mismatch", [sideBands.count, sideBands.last?.lower ?? -1,
                sideBands.last?.upper ?? -1, bottomBand.lower, bottomBand.upper])
            if let diagnostic {
                // Only coordinates of nonce-verified expected-color bands.
                // Unknown pixel colors are neither copied nor serialized.
                let ends = zip(columns, bottomColors).map { band, color in
                    var end = bottomBand.lower
                    while end < rectangle.y1 && (band.center - 1...band.center + 1).allSatisfy({ pixels.equal($0, end, color) }) {
                        end += 1
                    }
                    return end
                }
                diagnostic("bottom-column-ends", ends)
            }
            return nil
        }
        diagnostic?("sides-decoded", [sideBands.count])
        var yEdges = [header.vertical.lower, (header.vertical.upper + sideBands[0].lower) / 2]
        for index in 1..<sideBands.count { yEdges.append((sideBands[index - 1].upper + sideBands[index].lower) / 2) }
        yEdges.append(bottomBand.upper)
        guard abs(yEdges[1] - header.vertical.upper) <= 2 else { return nil }
        let raster = StartupGridRaster(width: pixels.width, height: pixels.height, xEdges: xEdges,
            yEdges: yEdges, sampleInsetPixels: 2, edgeRoundingPixels: 1)
        try raster.validate(columns: witness.columns, rows: witness.rows)
        // Every outer boundary must terminate inside the owned crop. An edge
        // coinciding with its crop limit is indistinguishable from a clipped cell.
        guard xEdges.first! > rectangle.x0 && xEdges.last! < rectangle.x1
            && yEdges.first! > rectangle.y0 && yEdges.last! < rectangle.y1 else { return nil }
        diagnostic?("raster-decoded", [])
        return try verify(pixels, witness: witness, raster: raster)
    }

    static func verify(_ pixels: StartupGridPixels, witness: StartupGridWitness,
                       raster: StartupGridRaster, expectedColors: [[StartupGridRGB?]]? = nil,
                       generatedSHA256: String? = nil) throws -> StartupGridProof? {
        try raster.validate(columns: witness.columns, rows: witness.rows)
        if let expectedColors {
            try gridRequire(expectedColors.count == witness.rows
                && expectedColors.allSatisfy { $0.count == witness.columns }, "cached color dimensions differ")
        }
        guard pixels.width == raster.width && pixels.height == raster.height
            && pixels.bytesPerRow >= pixels.width * 4 else { return nil }
        let horizontalPixels = zip(raster.xEdges, raster.xEdges.dropFirst()).reduce(0) { $0 + $1.1 - $1.0 - 4 }
        let verticalPixels = zip(raster.yEdges, raster.yEdges.dropFirst()).reduce(0) { $0 + $1.1 - $1.0 - 4 }
        let expectedPixels = horizontalPixels * verticalPixels
        try gridRequire(expectedPixels <= 10_000_000, "generated viewport proof exceeds pixel bound")
        var checked = Data(), checkedCells = 0, pixelRuns: [[Int]] = []
        for row in 0..<witness.rows { for column in 0..<witness.columns {
            guard let color = try expectedColors.map({ $0[row][column] }) ?? witness.color(column: column, row: row) else { continue }
            checkedCells += 1
            for y in (raster.yEdges[row] + 2)..<(raster.yEdges[row + 1] - 2) {
                let firstX = raster.xEdges[column] + 2
                let lastX = raster.xEdges[column + 1] - 2
                // Verify every pixel, then append the contiguous row segment.
                // Allocating two Swift arrays for every pixel made observation
                // slower than capture and starved the lifetime/cleanup checks.
                for x in firstX..<lastX {
                    guard pixels.equal(x, y, color) else { return nil }
                    let offset = y * pixels.bytesPerRow + x * 4
                    let b = Int(pixels.bytes[offset]), g = Int(pixels.bytes[offset + 1])
                    let r = Int(pixels.bytes[offset + 2]), a = Int(pixels.bytes[offset + 3])
                    let index = pixelRuns.count - 1
                    if index >= 0 && pixelRuns[index][1] == b && pixelRuns[index][2] == g
                        && pixelRuns[index][3] == r && pixelRuns[index][4] == a {
                        pixelRuns[index][0] += 1
                    } else {
                        try gridRequire(pixelRuns.count < 100_000, "generated viewport RLE exceeds bound")
                        pixelRuns.append([1, b, g, r, a])
                    }
                }
                let offset = y * pixels.bytesPerRow + firstX * 4
                let count = lastX - firstX
                checked.append(contentsOf: UnsafeBufferPointer(start: pixels.bytes.advanced(by: offset), count: count * 4))
            }
        }}
        return StartupGridProof(witness: witness, raster: raster, checkedCells: checkedCells,
            checkedPixels: checked.count / 4, generatedSHA256: try generatedSHA256 ?? witness.generatedDigest(),
            checkedPixelsSHA256: gridHash(checked), checkedPixelRuns: pixelRuns)
    }
}
