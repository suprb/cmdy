import Foundation

@main
enum ScrollNativeMatcherTests {
    static func main() throws {
        let width = 42 * 6, height = 36 * 6
        let geometry = ScrollRasterGeometry(width: width, height: height,
            columnSamples: (0..<42).map { [$0 * 6 + 1, $0 * 6 + 2, $0 * 6 + 4] },
            rowBands: (0..<36).map { ScrollPixelBand(lower: $0 * 6, upper: ($0 + 1) * 6) },
            calibrationSHA256: String(repeating: "a", count: 64))
        let colors = (0..<36).map { row in (0..<42).map { col in
            ScrollRGB(red: 40 + (row * 3 + col) % 160,
                      green: 70 + (row + col * 5) % 100, blue: 190)
        } }
        let viewport = ScrollExpectedViewport(rows: Array(900..<936), colors: colors,
            canonicalRowsSHA256: String(repeating: "b", count: 64))
        try geometry.validate()
        try viewport.validate()
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let color = colors[y / 6][x / 6]
                let offset = (y * width + x) * 4
                pixels[offset] = UInt8(color.blue)
                pixels[offset + 1] = UInt8(color.green)
                pixels[offset + 2] = UInt8(color.red)
                pixels[offset + 3] = 255
            }
        }
        func matches(_ bytes: [UInt8], stride: Int? = nil) -> Bool {
            bytes.withUnsafeBufferPointer {
                ScrollViewportMatcher.matches(bytes: $0.baseAddress!,
                    bytesPerRow: stride ?? width * 4,
                    geometry: geometry, expected: viewport) != nil
            }
        }
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            guard value else { fatalError("FAIL \(name)") }
            checks += 1
            print("PASS \(name)")
        }
        check(matches(pixels), "all 36 complete generated row codes match")
        var firstEdge = pixels
        firstEdge[(1 * width + 1) * 4] = 0
        check(!matches(firstEdge), "non-center first-row damage rejects early partial viewport")
        var finalEdge = pixels
        finalEdge[((height - 1) * width + 41 * 6 + 4) * 4] = 0
        check(!matches(finalEdge), "last pixel band of row36 is required")
        var shifted = pixels
        shifted.replaceSubrange(width * 4..<shifted.count, with: pixels[0..<(pixels.count - width * 4)])
        check(!matches(shifted), "one-pixel vertical translation cannot pass row-center shortcut")
        var alpha = pixels
        alpha[1 * 4 + 3] = 249
        check(!matches(alpha), "transparent marker is rejected")
        var tolerance = pixels
        tolerance[1 * 4] += 3
        check(matches(tolerance), "declared color quantization tolerance is accepted")
        check(!matches(pixels, stride: width * 4 - 1), "invalid row stride rejected")
        let gap = ScrollRasterGeometry(width: width, height: height,
            columnSamples: geometry.columnSamples,
            rowBands: [ScrollPixelBand(lower: 1, upper: 6)] + Array(geometry.rowBands.dropFirst()),
            calibrationSHA256: geometry.calibrationSHA256)
        // A shifted top edge is not inherently a gap; deliberately break a
        // middle row boundary to verify complete contiguous vertical coverage.
        var bands = gap.rowBands
        bands[10] = ScrollPixelBand(lower: bands[10].lower + 1, upper: bands[10].upper)
        let invalid = ScrollRasterGeometry(width: width, height: height,
            columnSamples: geometry.columnSamples, rowBands: bands,
            calibrationSHA256: geometry.calibrationSHA256)
        do {
            try invalid.validate()
            check(false, "row-band gap rejected")
        } catch {
            check(true, "row-band gap rejected")
        }
        print("PASS \(checks) native synthetic viewport checks; no GUI or event posting")
    }
}
