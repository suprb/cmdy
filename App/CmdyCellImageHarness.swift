import AppKit
import CmdyCore

/// Direct contract checks for the identity-bearing line-image bridge.
@MainActor
enum CmdyCellImageHarness {
    static func run(_ check: (Bool, String) -> Void) {
        func snapshot(
            identity: UUID = UUID(),
            payload: LineImage.Payload,
            pixelWidth: Int,
            pixelHeight: Int,
            col: Int = 0,
            kittyIsKitty: Bool = false,
            kittyImageId: UInt32? = nil,
            kittyZIndex: Int = 0,
            kittyPixelOffsetX: Int = 0,
            kittyPixelOffsetY: Int = 0
        ) -> CoreLineImageSnapshot {
            CoreLineImageSnapshot(
                renderIdentity: identity,
                payload: payload,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                col: col,
                kittyIsKitty: kittyIsKitty,
                kittyImageId: kittyImageId,
                kittyPlacementId: 91,
                kittyZIndex: kittyZIndex,
                kittyPixelOffsetX: kittyPixelOffsetX,
                kittyPixelOffsetY: kittyPixelOffsetY)
        }

        func renderedColor(
            _ image: NSImage, x: Int, y: Int
        ) -> NSColor? {
            let width = max(1, Int(image.size.width.rounded(.up)))
            let height = max(1, Int(image.size.height.rounded(.up)))
            guard x >= 0, x < width, y >= 0, y < height,
                  let bitmap = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: width,
                    pixelsHigh: height,
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: width * 4,
                    bitsPerPixel: 32),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
                return nil
            }

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: width, height: height).fill()
            image.draw(
                in: NSRect(x: 0, y: 0, width: width, height: height),
                from: .zero,
                operation: .copy,
                fraction: 1)
            context.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
        }

        func isColor(
            _ color: NSColor?,
            red: CGFloat,
            green: CGFloat,
            blue: CGFloat,
            alpha: CGFloat,
            tolerance: CGFloat = 0.01
        ) -> Bool {
            guard let color else { return false }
            return abs(color.redComponent - red) <= tolerance
                && abs(color.greenComponent - green) <= tolerance
                && abs(color.blueComponent - blue) <= tolerance
                && abs(color.alphaComponent - alpha) <= tolerance
        }

        func isTransparent(_ image: NSImage, size: NSSize) -> Bool {
            image.size == size
                && isColor(renderedColor(image, x: 0, y: 0),
                           red: 0, green: 0, blue: 0, alpha: 0)
                && isColor(renderedColor(
                    image,
                    x: max(0, Int(size.width) - 1),
                    y: max(0, Int(size.height) - 1)),
                           red: 0, green: 0, blue: 0, alpha: 0)
        }

        let stableIdentity = UUID()
        let original = snapshot(
            identity: stableIdentity,
            payload: .rgba(
                bytes: [255, 0, 0, 255, 0, 255, 0, 255],
                width: 2,
                height: 1),
            pixelWidth: 2,
            pixelHeight: 1,
            col: 3,
            kittyIsKitty: true,
            kittyImageId: 42,
            kittyZIndex: -7,
            kittyPixelOffsetX: 5,
            kittyPixelOffsetY: 9)
        let firstWrapper = CmdyCellImage.wrap(original)
        let moved = snapshot(
            identity: stableIdentity,
            payload: .rgba(bytes: [0, 0, 0, 0], width: 1, height: 1),
            pixelWidth: 99,
            pixelHeight: 88,
            col: 17,
            kittyIsKitty: false,
            kittyImageId: 99,
            kittyZIndex: 8,
            kittyPixelOffsetX: 4,
            kittyPixelOffsetY: 2)
        let reusedWrapper = CmdyCellImage.wrap(moved)
        check(firstWrapper === reusedWrapper,
              "cell image: stable render UUID reuses wrapper identity")
        check(reusedWrapper.col == 17,
              "cell image: cache hit refreshes mutable anchor column")
        check(reusedWrapper.pixelWidth == 2
                && reusedWrapper.pixelHeight == 1
                && reusedWrapper.kittyIsKitty
                && reusedWrapper.kittyImageId == 42
                && reusedWrapper.kittyZIndex == -7
                && reusedWrapper.kittyPixelOffsetX == 5
                && reusedWrapper.kittyPixelOffsetY == 9,
              "cell image: immutable dimensions and Kitty metadata are retained")

        var cacheSources: [CoreLineImageSnapshot] = []
        var cacheWrappers: [CmdyCellImage] = []
        cacheSources.reserveCapacity(512)
        cacheWrappers.reserveCapacity(512)
        for index in 0..<512 {
            let source = snapshot(
                payload: .rgba(bytes: [UInt8(index & 0xFF), 0, 0, 255],
                               width: 1, height: 1),
                pixelWidth: 1,
                pixelHeight: 1,
                col: index)
            cacheSources.append(source)
            cacheWrappers.append(CmdyCellImage.wrap(source))
        }
        let recentWrapper = cacheWrappers[0]
        let leastRecentWrapper = cacheWrappers[1]
        _ = CmdyCellImage.wrap(cacheSources[0])
        _ = CmdyCellImage.wrap(snapshot(
            payload: .rgba(bytes: [0, 0, 0, 255], width: 1, height: 1),
            pixelWidth: 1,
            pixelHeight: 1))
        check(CmdyCellImage.wrap(cacheSources[0]) === recentWrapper,
              "cell image: cache access protects the recently used wrapper")
        check(CmdyCellImage.wrap(cacheSources[1]) !== leastRecentWrapper,
              "cell image: 513th identity evicts the least recently used wrapper")

        let rgba = CmdyCellImage.wrap(snapshot(
            payload: .rgba(
                bytes: [255, 0, 0, 255, 0, 255, 0, 255],
                width: 2,
                height: 1),
            pixelWidth: 2,
            pixelHeight: 1))
        check(rgba.image.size == NSSize(width: 2, height: 1)
                && isColor(renderedColor(rgba.image, x: 0, y: 0),
                           red: 1, green: 0, blue: 0, alpha: 1)
                && isColor(renderedColor(rgba.image, x: 1, y: 0),
                           red: 0, green: 1, blue: 0, alpha: 1),
              "cell image: validated RGBA keeps dimensions and pixel order")

        let pngBitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 1,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 8,
            bitsPerPixel: 32)
        if let pngBytes = pngBitmap?.bitmapData {
            pngBytes[0] = 255
            pngBytes[1] = 0
            pngBytes[2] = 0
            pngBytes[3] = 255
            pngBytes[4] = 0
            pngBytes[5] = 255
            pngBytes[6] = 0
            pngBytes[7] = 255
        }
        if let pngData = pngBitmap?.representation(
            using: .png, properties: [:]) {
            let png = CmdyCellImage.wrap(snapshot(
                payload: .png(pngData),
                pixelWidth: 2,
                pixelHeight: 1))
            check(png.image.size == NSSize(width: 2, height: 1)
                    && isColor(renderedColor(png.image, x: 0, y: 0),
                               red: 1, green: 0, blue: 0, alpha: 1)
                    && isColor(renderedColor(png.image, x: 1, y: 0),
                               red: 0, green: 1, blue: 0, alpha: 1),
                  "cell image: PNG payload decodes without changing dimensions")
        } else {
            check(false, "cell image: PNG fixture creation succeeds")
        }

        let truncated = CmdyCellImage.wrap(snapshot(
            payload: .rgba(bytes: [255, 0, 0], width: 1, height: 1),
            pixelWidth: 3,
            pixelHeight: 2))
        check(isTransparent(
            truncated.image, size: NSSize(width: 3, height: 2)),
              "cell image: truncated RGBA becomes declared-size transparency")

        let invalidDimensions = CmdyCellImage.wrap(snapshot(
            payload: .rgba(bytes: [], width: 0, height: 1),
            pixelWidth: 4,
            pixelHeight: 3))
        check(isTransparent(
            invalidDimensions.image, size: NSSize(width: 4, height: 3)),
              "cell image: invalid RGBA dimensions fail transparently")

        let overflow = CmdyCellImage.wrap(snapshot(
            payload: .rgba(bytes: [], width: Int.max, height: 2),
            pixelWidth: 5,
            pixelHeight: 2))
        check(isTransparent(
            overflow.image, size: NSSize(width: 5, height: 2)),
              "cell image: RGBA byte-layout overflow fails transparently")

        let malformedPNG = CmdyCellImage.wrap(snapshot(
            payload: .png(Data([0x89, 0x50, 0x4E, 0x47])),
            pixelWidth: 6,
            pixelHeight: 4))
        check(isTransparent(
            malformedPNG.image, size: NSSize(width: 6, height: 4)),
              "cell image: malformed PNG becomes declared-size transparency")
    }
}
