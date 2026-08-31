import AppKit
import CmdyKit

/// Renders the project app icon and writes a full .iconset (run via the
/// product executable with `--make-iconset <dir>`, then `iconutil -c icns`).
enum IconGenerator {
    private static func color(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// Canonical project artwork. Packaging runs from the repository root, so
    /// one brand master feeds every generated icon size without duplicating
    /// name-specific assets throughout the build.
    private static let brandIcon: NSImage? = {
        let cwd = FileManager.default.currentDirectoryPath + "/Brand/Assets/app-icon.png"
        guard let data = try? BoundedFileReader.data(
            at: URL(fileURLWithPath: cwd), maxBytes: 16 * 1024 * 1024
        ) else { return nil }
        return NSImage(data: data)
    }()

    /// Draw the icon into the current graphics context at the given point/pixel size.
    private static func draw(_ size: CGFloat) {
        let rect = NSRect(x: 0, y: 0, width: size, height: size)
        if let brandIcon, brandIcon.size.width > 0, brandIcon.size.height > 0 {
            NSGraphicsContext.current?.imageInterpolation = .high
            brandIcon.draw(
                in: rect,
                from: NSRect(origin: .zero, size: brandIcon.size),
                operation: .copy,
                fraction: 1.0
            )
            return
        }

        // Defensive fallback for a source checkout missing its brand assets.
        // Release packaging verifies the canonical artwork before this path
        // can be used.
        let bg = color(0xF2, 0xF0, 0xEB)
        let ink = color(0x14, 0x14, 0x14)

        let corner = size * 0.225
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).fill()

        let font = NSFont.monospacedSystemFont(
            ofSize: max(7, size * 0.22), weight: .semibold)
        let wordmark = NSAttributedString(
            string: "cmdy",
            attributes: [.font: font, .foregroundColor: ink])
        let wordmarkSize = wordmark.size()
        wordmark.draw(at: NSPoint(
            x: ((size - wordmarkSize.width) / 2).rounded(),
            y: ((size - wordmarkSize.height) / 2).rounded()))
    }

    private static func pngData(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(CGFloat(pixels))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Write a standard .iconset directory (used with `iconutil -c icns`).
    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let specs: [(name: String, px: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for spec in specs {
            if let data = pngData(pixels: spec.px) {
                try? data.write(to: URL(fileURLWithPath: "\(dir)/\(spec.name).png"))
            }
        }
        print("wrote iconset to \(dir)")
    }
}
