import AppKit
@_spi(CmdyApp) import CmdyCore
@_spi(CmdyApp) import CmdyGPU
import CmdyNative

@MainActor private func pixels(_ image: NSImage) -> [UInt8] {
    let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    let bitmap = NSBitmapImageRep(cgImage: cg)
    return Array(UnsafeBufferPointer(start: bitmap.bitmapData!, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
}

@main private struct ImageSmoke {
    @MainActor static func main() {
        autoreleasepool {
            let rgba: [UInt8] = [12, 34, 56, 128]
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let cg = CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
            let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
            let payloads: [LineImage.Payload] = [.rgba(bytes: rgba, width: 1, height: 1), .png(png)]
            for payload in payloads {
                let identity = UUID()
                func snapshot(col: Int) -> CoreLineImageSnapshot {
                    .init(renderIdentity: identity, payload: payload, pixelWidth: 24, pixelHeight: 12,
                          col: col, kittyIsKitty: false, kittyImageId: nil, kittyPlacementId: nil,
                          kittyZIndex: 2, kittyPixelOffsetX: 3, kittyPixelOffsetY: 4)
                }
                cmdy_image_bridge_clear()
                let value = CmdyCellImage.wrap(snapshot(col: 2))
                precondition(!value.hasDecodedImageForFixture)
                let encoded: any EncodedRenderableCellImage = value
                precondition(encoded.renderIdentity == identity)
                switch (payload, encoded.encodedPayload) {
                case (.png(let expected), .png(let actual)): precondition(actual == expected)
                case (.rgba(let expected, let w, let h), .rgba(let actual, let aw, let ah)):
                    precondition(expected == actual && w == aw && h == ah)
                default: preconditionFailure("Payload format changed")
                }
                precondition(!value.hasDecodedImageForFixture)
                let moved = CmdyCellImage.wrap(snapshot(col: 8))
                precondition(moved === value && moved.col == 8 && !moved.hasDecodedImageForFixture)
                let decoded = value.image
                precondition(value.hasDecodedImageForFixture && value.image === decoded)
                cmdy_image_bridge_clear()
                let reference = OriginalCmdyCellImage.wrap(snapshot(col: 8))
                precondition(decoded.size == reference.image.size && pixels(decoded) == pixels(reference.image))
                precondition(value.pixelWidth == reference.pixelWidth && value.pixelHeight == reference.pixelHeight)
                precondition(value.kittyZIndex == reference.kittyZIndex && value.kittyPixelOffsetX == reference.kittyPixelOffsetX)
            }
            cmdy_image_bridge_clear()
            print("Actual app image wrapper: lazy PNG/RGBA decoding, stable encoded identity, placement reuse and legacy pixel parity PASS")
        }
    }
}
