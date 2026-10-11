// Synthetic generated BGRA and timestamp tests. No GUI, capture or event APIs.
import Darwin
import Foundation

@main
enum ScrollNativeRasterTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { fatalError("pass generated protocol-vectors.json") }
        let vectors = try JSONSerialization.jsonObject(with: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let token = vectors["token"] as! String
        let fixture = try ScrollFixture(token: token)
        let width = 520, height = 430, left = 31, top = 52, cell = 7, rowHeight = 9
        var count = 0
        func check(_ value: Bool, _ text: String) {
            guard value else { fatalError("FAIL \(text)") }
            count += 1; print("PASS \(text)")
        }
        for row in [0, 900, 958, 964] {
            check(fixture.viewports[row].canonicalRowsSHA256 == (vectors["viewportSHA256"] as! [String: String])[String(row)],
                  "Swift/Python canonical generated viewport \(row) agrees")
        }
        func pixels(first: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: width * height * 4)
            for row in 0..<36 {
                for column in 0..<42 {
                    let color = fixture.viewports[first].colors[row][column]
                    for y in (top + row * rowHeight)..<(top + (row + 1) * rowHeight) {
                        for x in (left + column * cell)..<(left + (column + 1) * cell) {
                            let offset = (y * width + x) * 4
                            bytes[offset] = UInt8(color.blue); bytes[offset + 1] = UInt8(color.green)
                            bytes[offset + 2] = UInt8(color.red); bytes[offset + 3] = 255
                        }
                    }
                }
            }
            return bytes
        }
        func calibrate(_ bytes: [UInt8]) throws -> ScrollRasterGeometry? {
            try bytes.withUnsafeBufferPointer { try ScrollRaster.calibrate(bytes: $0.baseAddress!,
                bytesPerRow: width * 4, width: width, height: height, fixture: fixture) }
        }
        let original = pixels(first: 964)
        guard let geometry = try calibrate(original) else { fatalError("automatic calibration did not find generated content") }
        check(geometry.rowBands.first?.lower == top && geometry.rowBands.last?.upper == top + 36 * rowHeight,
              "automatic raster discovers all 36 exact vertical bands")
        check(geometry.columnSamples[0] == [33, 34, 35] && geometry.columnSamples[41] == [320, 321, 322],
              "sentinel pitch discovers 42 coded columns without a supplied crop")
        func decode(_ bytes: [UInt8]) -> (Int, Int)? {
            bytes.withUnsafeBufferPointer { ScrollRaster.decode(bytes: $0.baseAddress!,
                bytesPerRow: width * 4, geometry: geometry, fixture: fixture) }
        }
        check(decode(original)?.0 == 964 && decode(original)?.1 == 36 * 9 * 42 * 3,
              "all rows decoded and full-band pixel count retained")
        check(decode(pixels(first: 958))?.0 == 958, "frozen raster decodes a new exact generated viewport")
        var shifted = original
        shifted.replaceSubrange(width * 4..<shifted.count, with: original[0..<(original.count - width * 4)])
        check(decode(shifted) == nil, "one-pixel vertical translation cannot acknowledge complete rows")
        var clippedTop = original
        for x in left..<(left + 42 * cell) { clippedTop[(top * width + x) * 4 + 3] = 0 }
        check(try calibrate(clippedTop) == nil, "partially clipped first row cannot become calibration")
        var clippedBottom = original
        for x in left..<(left + 42 * cell) { clippedBottom[((top + 36 * rowHeight - 1) * width + x) * 4 + 3] = 0 }
        check(try calibrate(clippedBottom) == nil, "partially clipped final row cannot become calibration")
        var wrongNonce = original
        for y in top..<(top + 36 * rowHeight) {
            for x in (left + cell)..<(left + cell * 2) {
                wrongNonce[(y * width + x) * 4 + 2] = 255
            }
        }
        check(try decode(wrongNonce) == nil && calibrate(wrongNonce) == nil,
              "correct row ordinal without exact nonce cannot acknowledge")
        let window = ScrollWindowProof(appPID: 100, windowID: 2, frontmostPID: 100,
            x: 120, y: 120, width: 1000, height: 750, processStartSeconds: 1,
            processStartMicroseconds: 2, displayID: 1)
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        func ticks(_ ns: UInt64) -> UInt64 { ns * UInt64(timebase.denom) / UInt64(timebase.numer) + 1 }
        let initial: UInt64 = 1_000_000
        func frame(_ ns: UInt64, row: Int? = 958) -> ScrollRasterFrame {
            let tick = initial + ticks(ns)
            return ScrollRasterFrame(displayTicks: tick, callbackTicks: tick - 1,
                windowQueryFinishedTicks: tick + 1, window: window, firstRow: row,
                checkedPixels: row == nil ? 0 : 36 * 9 * 42 * 3,
                canonicalRowsSHA256: row.map { fixture.viewports[$0].canonicalRowsSHA256 })
        }
        let frames = [frame(0), frame(100_000_000), frame(300_000_000)]
        let stable = try scrollStable(frames.reversed(), target: 958, now: initial + ticks(310_000_000))
        check(stable?.first.displayTicks == frames[0].displayTicks && stable?.laterCorrectDistinctFrames == 2,
              "callback delivery order and signed lead do not replace first display timestamp")
        do {
            _ = try scrollStable([frames[0], frame(100_000_000, row: nil), frames[2]], target: 958,
                                 now: initial + ticks(310_000_000))
            check(false, "transient first target rejected")
        } catch { check(true, "transient first target rejected instead of retiming to settled frame") }
        do {
            _ = try scrollStable(frames + [frame(0, row: nil)], target: 958, now: initial + ticks(310_000_000))
            check(false, "conflicting duplicate display timestamp rejected")
        } catch { check(true, "conflicting duplicate display timestamp rejected") }
        check(try scrollStable([frames[0], frames[1], frames[1]], target: 958,
                              now: initial + ticks(310_000_000)) == nil,
              "duplicate captures cannot manufacture distinct stability frames")
        print("PASS \(count) native synthetic raster/clock checks; no GUI, capture or native event creation")
    }
}
