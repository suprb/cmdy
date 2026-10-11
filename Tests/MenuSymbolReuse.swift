// Appended to the unchanged production source by test-menu-symbol-reuse.py.
// Draws into bitmap images only: no NSApplication, windows or system input.
@main
struct MenuSymbolReuseFixture {
    @MainActor static func oldImage(_ symbol: String, _ title: String) -> NSImage? {
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            ?? NSImage(systemSymbolName: "command", accessibilityDescription: title) else { return nil }
        let image = base.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)) ?? base
        image.isTemplate = true
        return image
    }

    @MainActor static func pixels(_ image: NSImage, _ scale: Int, _ appearance: NSAppearance) -> Data {
        let size = 32 * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: size * 4, bitsPerPixel: 32)!
        memset(bitmap.bitmapData!, 0, bitmap.bytesPerRow * size)
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero,
                       operation: .sourceOver, fraction: 1)
        }
        return Data(bytes: bitmap.bitmapData!, count: bitmap.bytesPerRow * size)
    }

    @MainActor static func main() throws {
        let symbols = try JSONDecoder().decode([String].self, from: Data(contentsOf:
            URL(fileURLWithPath: CommandLine.arguments[1])))
        var comparisons = 0
        for symbol in symbols {
            autoreleasepool {
                let title = "Unique accessible title for " + symbol
                let old = oldImage(symbol, title)!
                let copy = CmdyMenuIconInstaller.menuImage(symbol: symbol, title: title)!
                precondition(old.accessibilityDescription == title && copy.accessibilityDescription == title)
                precondition(old.size == copy.size && old.isTemplate == copy.isTemplate)
                for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                    let appearance = NSAppearance(named: appearanceName)!
                    for scale in [1, 2] {
                        let expected = pixels(old, scale, appearance)
                        let actual = pixels(copy, scale, appearance)
                        precondition(actual == expected, "pixel difference: " + symbol)
                        precondition(actual.contains(where: { $0 != 0 }), "blank symbol: " + symbol)
                        comparisons += 1
                    }
                }
                let expectedSize = copy.size
                copy.accessibilityDescription = "changed"
                copy.isTemplate = false
                copy.size = NSSize(width: 7, height: 9)
                let next = CmdyMenuIconInstaller.menuImage(symbol: symbol, title: "next title")!
                precondition(next !== copy && next.size == expectedSize && next.isTemplate)
                precondition(next.accessibilityDescription == "next title")
                precondition(pixels(next, 2, NSAppearance(named: .darkAqua)!)
                    == pixels(old, 2, NSAppearance(named: .darkAqua)!))
                comparisons += 1
            }
        }
        for index in 0..<200 {
            autoreleasepool {
                let image = CmdyMenuIconInstaller.menuImage(
                    symbol: "cmdy.invalid.symbol.\(index)", title: "fallback \(index)")!
                precondition(image.accessibilityDescription == "fallback \(index)" && image.isTemplate)
                if index == 199 {
                    // The cache is full; a miss must still return correct pixels.
                    precondition(pixels(image, 2, NSAppearance(named: .darkAqua)!)
                        == pixels(oldImage("command", "fallback")!, 2, NSAppearance(named: .darkAqua)!))
                    comparisons += 1
                }
            }
        }
        precondition(CmdyMenuIconInstaller.fixturePrototypeCount == 128)
        print("MENU_SYMBOL_REUSE_PASS symbols=\(symbols.count) exactPixelComparisons=\(comparisons) independentMetadata=\(symbols.count) fallbackRequests=200")
    }
}

extension CmdyMenuIconInstaller {
    fileprivate static var fixturePrototypeCount: Int { menuSymbolPrototypes.count }
}
