// Generated-pixel discovery only. No manual crop or latency-sample fitting.
import CoreVideo
import Foundation

struct ResizeCalibrationResult: Codable {
    let calibration: ResizeRasterCalibration
    let evidenceUTF8: String
    let evidenceSHA256: String
}
private struct ResizeHorizontal: Hashable { let left: Int, right: Int }
private struct ResizeBand: Codable { let first: Int, last: Int }
private struct ResizeCalibrationEvidence: Codable {
    let fixtureVersion: Int
    let nonce: String
    let sequence: UInt32
    let columns: Int, rows: Int
    let displayTicks: UInt64
    let window: ResizeWindowProof
    let displayBounds: ResizeBounds
    let displayMode: ResizeDisplayModeSignature
    let captureWidth: Int, captureHeight: Int
    let markerLeft: Int, markerRight: Int
    let rowBands: [ResizeBand]
    let sampledColors: [ResizeRGB]
    let maximumColorDeviation: Int
    let discoveryNominalTolerance: Int
    let frozenMatchTolerance: Int
}

func resizeDiscover(_ pixels: CVPixelBuffer, nonce: String, sequence: UInt32,
                    columns: Int, rows: Int, window: ResizeWindowProof,
                    displayBounds: ResizeBounds, displayMode: ResizeDisplayModeSignature,
                    displayTicks: UInt64) throws -> ResizeCalibrationResult? {
    try resizeNonce(nonce); try resizeGrid(columns, rows)
    let words = try (0..<rows).map { try resizeWord(nonce, sequence, columns, rows, $0) }
    let classes = words.map { resizeCellClasses(word: $0, columns: columns) }
    let nominal = resizeNominalColors()
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else {
        throw ResizeFailure("calibration capture is not BGRA")
    }
    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
    try resizeRequire(width > 0 && height > 0 && displayBounds.width > 0 && displayBounds.height > 0
        && displayBounds.rectangle.contains(window.bounds.rectangle), "invalid owned calibration crop")
    let sx = Double(width) / displayBounds.width, sy = Double(height) / displayBounds.height
    let windowX = (window.bounds.x - displayBounds.x) * sx
    let windowY = (window.bounds.y - displayBounds.y) * sy
    let x0 = Int(ceil(windowX)), y0 = Int(ceil(windowY))
    let x1 = Int(floor(windowX + window.bounds.width * sx))
    let y1 = Int(floor(windowY + window.bounds.height * sy))
    try resizeRequire(x0 >= 0 && y0 >= 0 && x1 <= width && y1 <= height
        && x1 - x0 >= columns * 3 && y1 - y0 >= rows * 3, "owned window cannot contain expected generated viewport")
    CVPixelBufferLockBaseAddress(pixels, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let address = CVPixelBufferGetBaseAddress(pixels) else { return nil }
    let data = address.assumingMemoryBound(to: UInt8.self)
    let rowBytes = CVPixelBufferGetBytesPerRow(pixels)
    func color(_ x: Int, _ y: Int) -> ResizeRGB? {
        guard x >= x0 && x < x1 && y >= y0 && y < y1 else { return nil }
        let i = y * rowBytes + x * 4
        guard data[i + 3] >= 250 else { return nil }
        return ResizeRGB(red: Int(data[i + 2]), green: Int(data[i + 1]), blue: Int(data[i]))
    }
    func same(_ x: Int, _ y: Int, _ index: Int) -> Bool {
        guard let value = color(x, y) else { return false }
        let expected = nominal[index]
        return max(abs(value.red - expected.red), abs(value.green - expected.green),
                   abs(value.blue - expected.blue)) <= 12
    }
    func rowMatches(_ horizontal: ResizeHorizontal, _ y: Int, _ row: Int) -> Bool {
        let cell = Double(horizontal.right - horizontal.left) / Double(columns)
        guard cell >= 3 else { return false }
        for (column, index) in classes[row].enumerated() {
            let x = horizontal.left + Int(floor((Double(column) + 0.5) * cell))
            if !same(x - 1, y, index) || !same(x, y, index) || !same(x + 1, y, index) { return false }
        }
        return true
    }
    var horizontal = Set<ResizeHorizontal>()
    for y in stride(from: y0, to: y1, by: 2) {
        var x = x0
        while x < x1 {
            guard same(x, y, 16) else { x += 1; continue }
            let left = x
            while x < x1 && same(x, y, 16) { x += 1 }
            guard x - left >= 3 else { continue }
            var end = max(x, left + (columns - 1) * 3)
            while end < x1 {
                guard same(end, y, 17) else { end += 1; continue }
                let greenStart = end
                while end < x1 && same(end, y, 17) { end += 1 }
                guard end - greenStart >= 3 else { continue }
                let candidate = ResizeHorizontal(left: left, right: end)
                if rowMatches(candidate, y, 0) {
                    horizontal.insert(candidate)
                    try resizeRequire(horizontal.count <= 32, "ambiguous calibration candidate bound exceeded")
                }
            }
        }
    }
    var solutions: [ResizeCalibrationResult] = []
    for candidate in horizontal.sorted(by: { ($0.left, $0.right) < ($1.left, $1.right) }) {
        var bands: [ResizeBand] = []
        var nextY = y0
        for row in 0..<rows {
            var found: ResizeBand?
            while nextY < y1 {
                guard rowMatches(candidate, nextY, row) else { nextY += 1; continue }
                let first = nextY
                while nextY < y1 && rowMatches(candidate, nextY, row) { nextY += 1 }
                if nextY - first >= 5 { found = ResizeBand(first: first, last: nextY - 1); break }
            }
            guard let found else { break }
            bands.append(found)
        }
        guard bands.count == rows, let first = bands.first, let last = bands.last else { continue }
        let pitch = Double(last.first - first.first) / Double(rows - 1)
        let interior = Double(bands.map { $0.last - $0.first + 1 }.min()!)
        let offsets = [interior * 0.25, interior * 0.5, interior * 0.75]
        let cell = Double(candidate.right - candidate.left) / Double(columns)
        guard pitch >= interior, offsets.last! < pitch - 1,
              Double(candidate.left) + Double(columns) * cell <= Double(x1),
              Double(first.first) + Double(rows) * pitch <= Double(y1) + 1 else { continue }
        var samples = [[ResizeRGB]](repeating: [], count: 18)
        var valid = true
        for row in 0..<rows {
            for (column, index) in classes[row].enumerated() {
                let x = candidate.left + Int(floor((Double(column) + 0.5) * cell))
                for offset in offsets {
                    let y = Int(floor(Double(first.first) + Double(row) * pitch + offset))
                    for dx in -1...1 {
                        guard same(x + dx, y, index), let value = color(x + dx, y) else {
                            valid = false; continue
                        }
                        samples[index].append(value)
                    }
                }
            }
        }
        guard valid && samples.allSatisfy({ !$0.isEmpty }) else { continue }
        let observed = samples.map { values -> ResizeRGB in
            func median(_ values: [Int]) -> Int { values.sorted()[values.count / 2] }
            return ResizeRGB(red: median(values.map(\.red)), green: median(values.map(\.green)),
                             blue: median(values.map(\.blue)))
        }
        var maximumDeviation = 0
        for index in samples.indices {
            for value in samples[index] {
                maximumDeviation = max(maximumDeviation, abs(value.red - observed[index].red),
                    abs(value.green - observed[index].green), abs(value.blue - observed[index].blue))
            }
        }
        guard maximumDeviation <= 3 else { continue }
        let evidence = ResizeCalibrationEvidence(fixtureVersion: resizeFixtureVersion, nonce: nonce, sequence: sequence, columns: columns, rows: rows,
            displayTicks: displayTicks, window: window, displayBounds: displayBounds, displayMode: displayMode,
            captureWidth: width, captureHeight: height, markerLeft: candidate.left, markerRight: candidate.right,
            rowBands: bands, sampledColors: observed, maximumColorDeviation: maximumDeviation,
            discoveryNominalTolerance: 12, frozenMatchTolerance: 3)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw = try encoder.encode(evidence)
        let hash = resizeDigest(raw)
        let geometry = ResizeRasterCalibration(fixtureVersion: resizeFixtureVersion, columns: columns, rows: rows, outerBounds: window.bounds,
            displayBounds: displayBounds, displayMode: displayMode, captureWidth: width, captureHeight: height,
            xWithinWindowPixels: Double(candidate.left) - windowX,
            yWithinWindowPixels: Double(first.first) - windowY,
            cellWidthPixels: cell, rowPitchPixels: pitch, rowSampleOffsets: offsets,
            colors: observed, tolerance: 3, discoveryEvidenceSHA256: hash)
        try geometry.validate()
        solutions.append(ResizeCalibrationResult(calibration: geometry,
            evidenceUTF8: String(decoding: raw, as: UTF8.self), evidenceSHA256: hash))
    }
    try resizeRequire(solutions.count <= 1, "generated pixels produced multiple calibration solutions")
    return solutions.first
}
