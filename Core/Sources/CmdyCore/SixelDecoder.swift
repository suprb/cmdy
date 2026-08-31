import Foundation

/// Streaming sixel decoder: DCS q payload bytes → RGBA pixels. Pure math,
/// bounded by both colored-pixel and final-canvas limits.
public final class SixelDecoder {
    private var palette: [Int: (UInt8, UInt8, UInt8)] = [:]
    private var currentColor = 0
    private var x = 0
    private var band = 0                       // each band is 6 pixels tall
    private var maxX = 0
    private var maxY = -1
    private var pixels: [Int: (UInt8, UInt8, UInt8)] = [:]   // y*stride+x sparse
    private var repeatCount: Int?
    private var pendingNumbers: [Int] = []
    private var collectingNumber = false
    private var mode: Mode = .data
    private var rejected = false

    private enum Mode { case data, colorIntro, rasterIntro }

    private static let maxColoredPixels = 1_000_000
    private static let maxCanvasPixels = 4_000_000
    private static let maxWidth = 10_000    // one `!<repeat>` can't spin past this
    private static let maxBands = 4_000     // caps image height to 24,000
    private static let maxPaletteEntries = 4_096

    public init() {
        // VT340 default palette entries 0-15 (xterm's defaults).
        let defaults: [(UInt8, UInt8, UInt8)] = [
            (0, 0, 0), (51, 51, 204), (204, 33, 33), (51, 204, 51),
            (204, 51, 204), (51, 204, 204), (204, 204, 51), (120, 120, 120),
            (69, 69, 69), (87, 87, 153), (153, 69, 69), (87, 153, 87),
            (153, 87, 153), (87, 153, 153), (153, 153, 87), (204, 204, 204)
        ]
        for (i, c) in defaults.enumerated() { palette[i] = c }
    }

    public func feed(_ bytes: ArraySlice<UInt8>) {
        for b in bytes { step(b) }
    }

    private func step(_ b: UInt8) {
        switch b {
        case UInt8(ascii: "#"):
            flushNumber()
            applyPending()
            mode = .colorIntro
            pendingNumbers.removeAll()
        case UInt8(ascii: "\""):
            flushNumber()
            applyPending()
            mode = .rasterIntro
            pendingNumbers.removeAll()
        case UInt8(ascii: "!"):
            flushNumber()
            applyPending()
            mode = .data
            collectingNumber = true
            numberValue = 0
            isRepeat = true
        case UInt8(ascii: "$"):
            flushNumber()
            applyPending()
            x = 0
        case UInt8(ascii: "-"):
            flushNumber()
            applyPending()
            x = 0
            band = min(band + 1, SixelDecoder.maxBands - 1)
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            if !collectingNumber { collectingNumber = true; numberValue = 0 }
            // Clamp — a repeat count / color index never needs more, and
            // unclamped Int accumulation traps on overflow at ~19 digits.
            numberValue = min(0x7FFF_FFFF, numberValue * 10 + Int(b - UInt8(ascii: "0")))
        case UInt8(ascii: ";"):
            flushNumber()
        case 0x3F...0x7E:
            flushNumber()
            applyPending()
            drawSixel(b - 0x3F)
        default:
            break
        }
    }

    private var numberValue = 0
    private var isRepeat = false

    private func flushNumber() {
        if collectingNumber {
            if isRepeat {
                repeatCount = numberValue
                isRepeat = false
            } else if pendingNumbers.count < 5 {
                pendingNumbers.append(numberValue)
            }
            collectingNumber = false
            numberValue = 0
        }
    }

    private func applyPending() {
        switch mode {
        case .colorIntro:
            guard let idx = pendingNumbers.first else { break }
            if (0..<SixelDecoder.maxPaletteEntries).contains(idx),
               pendingNumbers.count >= 5 {
                let system = pendingNumbers[1]
                let p1 = pendingNumbers[2], p2 = pendingNumbers[3], p3 = pendingNumbers[4]
                if system == 2 {          // RGB percentages
                    palette[idx] = (UInt8(clamping: p1 * 255 / 100),
                                    UInt8(clamping: p2 * 255 / 100),
                                    UInt8(clamping: p3 * 255 / 100))
                } else if system == 1 {   // HLS
                    palette[idx] = SixelDecoder.hlsToRGB(h: p1, l: p2, s: p3)
                }
            }
            currentColor = idx
            pendingNumbers.removeAll()
            mode = .data
        case .rasterIntro:
            pendingNumbers.removeAll()   // aspect + size hints — ignored
            mode = .data
        case .data:
            break
        }
    }

    private func drawSixel(_ bits: UInt8) {
        let n = repeatCount ?? 1
        repeatCount = nil
        guard !rejected else { return }
        let color = palette[currentColor] ?? (255, 255, 255)
        // Cap the repeat: a single `!<huge>` must not spin ~1e9 iterations or
        // fill the pixel map. Never advance past maxWidth, and stop when the
        // pixel budget is spent (re-checked INSIDE the loop, not just on entry).
        let room = max(0, SixelDecoder.maxWidth - x)
        let count = min(max(1, n), room)
        for _ in 0..<count {
            let proposedWidth = max(maxX, x + 1)
            if maxY >= 0 && !canvasFits(width: proposedWidth, height: maxY + 1) {
                reject()
                return
            }
            for bit in 0..<6 where bits & (1 << bit) != 0 {
                let y = band * 6 + bit
                guard canvasFits(width: proposedWidth, height: max(maxY, y) + 1) else {
                    reject()
                    return
                }
                let key = y * SixelDecoder.maxWidth + x
                if pixels[key] == nil, pixels.count >= SixelDecoder.maxColoredPixels {
                    reject()
                    return
                }
                pixels[key] = color
                maxY = max(maxY, y)
            }
            x += 1
            maxX = proposedWidth
        }
    }

    /// Final RGBA buffer (nil when nothing was drawn).
    public func finish() -> ([UInt8], Int, Int)? {
        flushNumber()
        applyPending()
        guard !rejected else { return nil }
        let width = maxX
        let height = maxY + 1
        guard width > 0, height > 0, !pixels.isEmpty else { return nil }
        guard canvasFits(width: width, height: height) else { return nil }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow else { return nil }
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !byteOverflow else { return nil }
        var rgba = [UInt8](repeating: 0, count: byteCount)
        for (key, color) in pixels {
            let y = key / SixelDecoder.maxWidth
            let px = key % SixelDecoder.maxWidth
            guard px < width, y < height else { continue }
            let o = (y * width + px) * 4
            rgba[o] = color.0; rgba[o + 1] = color.1; rgba[o + 2] = color.2; rgba[o + 3] = 255
        }
        return (rgba, width, height)
    }

    private func canvasFits(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        return !overflow && count <= SixelDecoder.maxCanvasPixels
    }

    private func reject() {
        rejected = true
        pixels.removeAll(keepingCapacity: false)
    }

    static func hlsToRGB(h: Int, l: Int, s: Int) -> (UInt8, UInt8, UInt8) {
        let hue = (Double(h) + 240).truncatingRemainder(dividingBy: 360) / 360
        let light = Double(l) / 100
        let sat = Double(s) / 100
        if sat == 0 {
            let v = UInt8(clamping: Int(light * 255))
            return (v, v, v)
        }
        let q = light < 0.5 ? light * (1 + sat) : light + sat - light * sat
        let p = 2 * light - q
        func channel(_ t: Double) -> UInt8 {
            var t = t
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            let v: Double
            if t < 1 / 6 { v = p + (q - p) * 6 * t }
            else if t < 1 / 2 { v = q }
            else if t < 2 / 3 { v = p + (q - p) * (2 / 3 - t) * 6 }
            else { v = p }
            return UInt8(clamping: Int(v * 255))
        }
        return (channel(hue + 1 / 3), channel(hue), channel(hue - 1 / 3))
    }
}
