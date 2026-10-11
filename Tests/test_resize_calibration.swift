// Generated CPU pixels and protocol bytes only. No native UI.
import CoreVideo
import Foundation

private let nonce = "0123456789abcdef0123456789abcdef"
private func geometry(_ columns: Int = 120, _ rows: Int = 36,
                      width: Int = 640, height: Int = 400) -> ResizeRasterCalibration {
    ResizeRasterCalibration(fixtureVersion: resizeFixtureVersion, columns: columns, rows: rows,
        outerBounds: ResizeBounds(x: 20, y: 20, width: Double(width - 40), height: Double(height - 40)),
        displayBounds: ResizeBounds(x: 0, y: 0, width: Double(width), height: Double(height)),
        displayMode: ResizeDisplayModeSignature(modeID: 7, flags: 0, width: width, height: height,
            pixelWidth: width, pixelHeight: height, refreshRate: 60, rotation: 0),
        captureWidth: width, captureHeight: height, xWithinWindowPixels: 10, yWithinWindowPixels: 10,
        cellWidthPixels: 4, rowPitchPixels: 8, rowSampleOffsets: [2, 4, 6],
        colors: resizeNominalColors(), tolerance: 3, discoveryEvidenceSHA256: String(repeating: "0", count: 64))
}
private func proof(_ value: ResizeRasterCalibration) -> ResizeWindowProof {
    ResizeWindowProof(identity: ResizeProcessIdentity(pid: 123, parentPID: 122, uid: 501, startSeconds: 1,
        startMicroseconds: 2, executable: "/generated/fixture"), windowID: 456, displayID: 1,
        bounds: value.outerBounds, foregroundPID: 123, occluded: false, queriedTicks: 110)
}
private func pixels(_ expected: ResizeFrameExpectation, missingRow: Int? = nil,
                    duplicateRow: Int? = nil, shift: Int = 0, secondX: Int? = nil,
                    corruptSample: Bool = false, corruptColumn: Int? = nil) throws -> CVPixelBuffer {
    let g = expected.calibration
    var result: CVPixelBuffer?
    try resizeRequire(CVPixelBufferCreate(kCFAllocatorDefault, g.captureWidth, g.captureHeight,
        kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess, "allocation failed")
    let buffer = result!
    CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let stride = CVPixelBufferGetBytesPerRow(buffer), address = CVPixelBufferGetBaseAddress(buffer)!
    let data = address.assumingMemoryBound(to: UInt8.self)
    memset(address, 0, stride * g.captureHeight)
    for y in 0..<g.captureHeight { for x in 0..<g.captureWidth { data[y * stride + 4 * x + 3] = 255 } }
    for left in [30] + (secondX.map { [$0] } ?? []) {
        for row in 0..<g.rows where row != missingRow {
            let index = row == duplicateRow ? max(0, row - 1) : row
            let classes = resizeCellClasses(word: expected.words[index], columns: g.columns)
            for (column, color) in classes.enumerated() {
                let value = g.colors[column == corruptColumn ? (color + 1) % 16 : color]
                for y in (30 + row * 8)..<(38 + row * 8) {
                    for x in (left + column * 4)..<(left + (column + 1) * 4) {
                        let offset = y * stride + x * 4
                        let variation = corruptSample && row == 20 && column == 10 && y % 8 == 4 ? 10 : shift
                        data[offset] = UInt8(clamping: value.blue + variation)
                        data[offset + 1] = UInt8(clamping: value.green + variation)
                        data[offset + 2] = UInt8(clamping: value.red + variation)
                    }
                }
            }
        }
    }
    return buffer
}
private struct Oracle: Decodable {
    struct Item: Decodable {
        let nonce: String, sequence: UInt32, columns: Int, rows: Int
        let words: [String], historySHA256: String, visibleSHA256: String
        let cellClasses: [[Int]], cellClassesSHA256: String
    }
    let cases: [Item]
}
@main private struct ResizeExtendedTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ name: String) throws {
            try resizeRequire(value, name); checks += 1; print("PASS " + name)
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; print("PASS " + name); return }
            throw ResizeFailure(name + " accepted")
        }
        let oracle = try JSONDecoder().decode(Oracle.self,
            from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        try check(oracle.cases.count == 6, "six independent Python generation contexts supplied")
        for (index, item) in oracle.cases.enumerated() {
            let expected = try resizeExpectation(nonce: item.nonce, sequence: item.sequence,
                calibration: geometry(item.columns, item.rows))
            try check(expected.words == item.words, "every-row Python CRC/context equality \(index)")
            let cells = expected.words.map { resizeCellClasses(word: $0, columns: item.columns) }
            try check(cells == item.cellClasses, "every-cell Python color-class equality \(index)")
            try check(resizeCellClassesDigest(expected) == item.cellClassesSHA256,
                      "every-cell Python row-major digest equality \(index)")
            let history = try resizeHistoryRows(item.nonce).joined(separator: "\r\n") + "\r\n"
            try check(resizeDigest(Data(history.utf8)) == item.historySHA256, "Python 147000-byte history equality \(index)")
            let visible = try resizeVisibleRows(item.nonce, item.sequence, item.columns, item.rows).joined(separator: "\r\n") + "\r\n"
            try check(resizeDigest(Data(visible.utf8)) == item.visibleSHA256, "Python visible row text equality \(index)")
        }
        let expected = try resizeExpectation(nonce: nonce, sequence: 5, calibration: geometry())
        try rejects("calibration cannot fit only the barcode while clipping the full grid") {
            try geometry(width: 400).validate()
        }
        func discover(_ buffer: CVPixelBuffer, _ e: ResizeFrameExpectation = expected) throws -> ResizeCalibrationResult? {
            try resizeDiscover(buffer, nonce: e.nonce, sequence: e.sequence,
                columns: e.calibration.columns, rows: e.calibration.rows, window: proof(e.calibration),
                displayBounds: e.calibration.displayBounds, displayMode: e.calibration.displayMode,
                displayTicks: 100)
        }
        let normal = try discover(pixels(expected))
        try check(normal != nil && normal?.calibration.cellWidthPixels == 4
            && normal?.calibration.rowPitchPixels == 8 && normal?.calibration.xWithinWindowPixels == 10
            && normal?.calibration.yWithinWindowPixels == 10, "automatic complete-grid geometry discovery")
        try check(normal!.evidenceSHA256 == resizeDigest(Data(normal!.evidenceUTF8.utf8))
            && normal!.calibration.discoveryEvidenceSHA256 == normal!.evidenceSHA256,
            "discovery evidence is exact hash preimage")
        let regenerated = try resizeExpectation(nonce: nonce, sequence: 5, calibration: normal!.calibration)
        try check(try resizeMatches(pixels(expected), expected: regenerated, window: regenerated.calibration.outerBounds),
            "discovered geometry reproduces independent matcher")
        let larger = try resizeExpectation(nonce: nonce, sequence: 5, calibration: geometry(132, 40))
        try check(try discover(pixels(larger), larger) != nil, "automatic 132x40 discovery")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode([normal!, discover(pixels(larger), larger)!])
            .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        try check(try discover(pixels(expected, missingRow: 35)) == nil, "calibration rejects missing last row")
        try check(try discover(pixels(expected, duplicateRow: 20)) == nil, "calibration rejects duplicate ordinal")
        let stale = try resizeExpectation(nonce: nonce, sequence: 4, calibration: geometry())
        try check(try discover(pixels(stale)) == nil, "calibration rejects stale sequence")
        let shifted = try discover(pixels(expected, shift: 2))
        try check(shifted?.calibration.tolerance == 3 && shifted?.calibration.colors[0].red == 38,
                  "unpooled discovery freezes actual stable palette")
        try check(try discover(pixels(expected, shift: 13)) == nil, "calibration refuses arbitrary color adaptation")
        try check(try discover(pixels(expected, corruptSample: true)) == nil, "spatially varying color invalidates calibration")
        try check(try discover(pixels(expected, corruptColumn: 119)) == nil,
                  "calibration rejects incorrect right edge beyond old row code")
        try check(try discover(pixels(larger, corruptColumn: 93), larger) == nil,
                  "calibration rejects incorrect interior beyond old row code")
        let wide = try resizeExpectation(nonce: nonce, sequence: 5, calibration: geometry(width: 1280, height: 400))
        try rejects("two complete candidate origins are ambiguous") { _ = try discover(pixels(wide, secondX: 650), wide) }

        print("ALL PASS \(checks)")
    }
}
