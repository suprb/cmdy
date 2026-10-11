// Synthetic BGRA only. No AppKit, application launch, process query or capture.
import Foundation

private func check(_ value: Bool, _ text: String) throws {
    if !value { throw StartupGridError(text) }
}
private struct Canvas {
    var data: Data
    let width: Int, height: Int
    let witness: StartupGridWitness
    let raster: StartupGridRaster
    init(token: String, generation: Int = 1, pitchX: Double = 7, pitchY: Double = 12,
         columns: Int = 98, rows: Int = 29, x: Double = 30, y: Double = 20) throws {
        width = 1400; height = 1000
        data = Data(repeating: 0, count: width * height * 4)
        witness = StartupGridWitness(token: token, columns: columns, rows: rows, generation: generation, frameKind: 1)
        raster = StartupGridRaster(width: width, height: height,
            xEdges: (0...columns).map { Int((x + Double($0) * pitchX).rounded()) },
            yEdges: (0...rows).map { Int((y + Double($0) * pitchY).rounded()) },
            sampleInsetPixels: 2, edgeRoundingPixels: 1)
        for row in 0..<rows { for column in 0..<columns {
            if let color = try witness.color(column: column, row: row) { fill(column, row, color) }
        }}
    }
    mutating func fill(_ column: Int, _ row: Int, _ color: StartupGridRGB, alpha: UInt8 = 255) {
        for y in raster.yEdges[row]..<raster.yEdges[row + 1] {
            for x in raster.xEdges[column]..<raster.xEdges[column + 1] {
                let i = (y * width + x) * 4
                data[i] = UInt8(color.blue); data[i + 1] = UInt8(color.green)
                data[i + 2] = UInt8(color.red); data[i + 3] = alpha
            }
        }
    }
    func match(token: String, rectangle: StartupGridPixelRect? = nil) throws -> StartupGridProof? {
        try data.withUnsafeBytes { raw in
            let pixels = StartupGridPixels(bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                width: width, height: height, bytesPerRow: width * 4)
            let crop = rectangle ?? StartupGridPixelRect(x0: 0, y0: 0, x1: width, y1: height)
            guard let header = try StartupGridMatcher.header(pixels, rectangle: crop, token: token) else { return nil }
            return try StartupGridMatcher.discover(pixels, rectangle: crop, header: header)
        }
    }
}

@main struct StartupGridWitnessTests {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
            exit(1)
        }
    }
    @MainActor static func run() async throws {
        let token = "0123456789abcdef0123456789abcdef"
        var checks = 0
        func reject(_ canvas: Canvas, _ message: String, token override: String? = nil,
                    rectangle: StartupGridPixelRect? = nil) throws {
            do { try check(try canvas.match(token: override ?? token, rectangle: rectangle) == nil, message) }
            catch let error as StartupGridError where error.description != message { /* explicit ambiguity also rejects */ }
            checks += 1
        }
        let exact = try Canvas(token: token)
        guard let proof = try exact.match(token: token) else { throw StartupGridError("complete grid did not match") }
        try check(proof.checkedCells == 98 * 29 && proof.raster == exact.raster, "not every generated cell was measured")
        checks += 1
        // Tolerated native color differences must remain lossless in evidence.
        var varied = exact
        let offset = ((exact.raster.yEdges[10] + 3) * exact.width + exact.raster.xEdges[10] + 2) * 4
        varied.data[offset] += 1
        let colors = try (0..<proof.witness.rows).map { row in
            try (0..<proof.witness.columns).map { column in try proof.witness.color(column: column, row: row) }
        }
        let cached = try varied.data.withUnsafeBytes { raw in
            try StartupGridMatcher.verify(StartupGridPixels(bytes: raw.baseAddress!.assumingMemoryBound(to: UInt8.self),
                width: varied.width, height: varied.height, bytesPerRow: varied.width * 4),
                witness: proof.witness, raster: proof.raster, expectedColors: colors, generatedSHA256: proof.generatedSHA256)
        }
        guard let cached, let rediscovered = try varied.match(token: token) else { throw StartupGridError("tolerated pixel did not match") }
        try check(cached.checkedPixelRuns == rediscovered.checkedPixelRuns
            && cached.checkedPixelsSHA256 == rediscovered.checkedPixelsSHA256
            && cached.checkedPixelsSHA256 != proof.checkedPixelsSHA256,
            "cached proof lost actual pixel variation")
        var decoded = Data()
        for run in cached.checkedPixelRuns { for _ in 0..<run[0] { decoded.append(contentsOf: run.dropFirst().map(UInt8.init)) } }
        try check(gridHash(decoded) == cached.checkedPixelsSHA256, "RLE differs from checked pixels")
        checks += 2
        for pair in [(7.85, 16.2), (8.4, 17.25), (9.25, 18.1)] {
            let fractional = try Canvas(token: token, pitchX: pair.0, pitchY: pair.1, x: 30.6, y: 20.4)
            guard let found = try fractional.match(token: token) else { throw StartupGridError("fractional grid failed") }
            try check(found.raster.agrees(with: fractional.raster), "fractional edges exceed uniform rounding")
            checks += 1
        }
        for cell in [(10, 28), (0, 10), (97, 1), (97, 0), (10,10), (48,15), (96,27)] {
            var broken = exact
            broken.fill(cell.0, cell.1, StartupGridRGB(0, 0, 0))
            try reject(broken, "a missing viewport cell was accepted")
        }
        try reject(exact, "foreign launch nonce was accepted", token: String(repeating: "f", count: 32))
        var stale = exact
        let other = try Canvas(token: token, generation: 64)
        stale.fill(97, 10, try other.witness.color(column: 97, row: 10)!)
        try reject(stale, "a mixed-generation border was accepted")
        var transparent = exact
        transparent.fill(0, 0, StartupGridRGB(238, 40, 40), alpha: 100)
        try reject(transparent, "a transparent header was accepted")
        try reject(exact, "a clipped final column was accepted",
            rectangle: StartupGridPixelRect(x0: 0, y0: 0, x1: exact.raster.xEdges.last! - 2, y1: exact.height))
        try reject(exact, "a clipped initial column was accepted",
            rectangle: StartupGridPixelRect(x0: exact.raster.xEdges[0] + 2, y0: 0, x1: exact.width, y1: exact.height))
        try reject(exact, "a clipped initial row was accepted",
            rectangle: StartupGridPixelRect(x0: 0, y0: exact.raster.yEdges[0] + 2, x1: exact.width, y1: exact.height))
        try reject(exact, "a clipped final row was accepted",
            rectangle: StartupGridPixelRect(x0: 0, y0: 0, x1: exact.width, y1: exact.raster.yEdges.last! - 2))
        let scaled = try Canvas(token: token, pitchX: 7.2)
        guard let scaledProof = try scaled.match(token: token) else { throw StartupGridError("scaled diagnostic fixture failed") }
        try check(!scaledProof.raster.agrees(with: proof.raster), "opening transform matched final calibration")
        checks += 1
        let high = try Canvas(token: token, generation: 64, columns: 120, rows: 36)
        try check(try high.match(token: token)?.witness == high.witness, "highest generation/diagnostic grid failed")
        checks += 1
        try startupStateTests(proof: proof, alternate: high.match(token: token)!, checks: &checks)
        try await startupFinalizationTests(checks: &checks)
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--proof-output" {
            let path = URL(fileURLWithPath: CommandLine.arguments[2])
            try check(!FileManager.default.fileExists(atPath: path.path), "refusing existing synthetic evidence")
            try gridCanonical(proof).write(to: path, options: .withoutOverwriting)
        } else { try check(CommandLine.arguments.count == 1, "unknown synthetic test argument") }
        print("{\"status\":\"pass\",\"syntheticGridChecks\":\(checks),\"nativeCapture\":false}")
    }
}
