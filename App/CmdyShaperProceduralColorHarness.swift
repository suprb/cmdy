import AppKit
import CmdyCore
import CmdyGPU

/// Pure snapshot fixtures for the private procedural-color experiment. These
/// tests use no PTY, view, user settings, drawable or native event injection.
@MainActor
enum CmdyShaperProceduralColorHarness {
    static func run(_ check: (Bool, String) -> Void) {
        func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
            NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        func same(_ value: NSColor?, _ expected: [CGFloat]) -> Bool {
            guard let rgb = value?.usingColorSpace(.sRGB), expected.count == 4 else {
                return false
            }
            let actual = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
            return zip(actual, expected).allSatisfy { abs($0 - $1) < 0.000_01 }
        }
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        var palette = Array(repeating: color(0.15, 0.25, 0.35), count: 256)
        palette[1] = color(0.3, 0.4, 0.5)
        palette[9] = color(0.6, 0.7, 0.8)
        func style(failed: Bool = false) -> CmdyShapingStyle {
            CmdyShapingStyle(palette: palette, normalFont: font, boldFont: font,
                italicFont: font, boldItalicFont: font,
                foreground: color(0.8, 0.6, 0.4), background: color(0.1, 0.2, 0.3),
                selectionBackground: color(0.2, 0.3, 0.4),
                failedRows: failed ? [0] : [],
                failedForeground: color(0.9, 0.1, 0.2),
                failedBackground: color(0.4, 0.1, 0.1))
        }
        func snapshot(_ cells: [Cell]) -> CoreTerminalSnapshot {
            let terminal = CmdyTerminal(cols: max(2, cells.count), rows: 2)
            let line = terminal.lineForDiff(absolute: 0)!
            for (column, cell) in cells.enumerated() { line[column] = cell }
            return terminal.captureTerminalSnapshot()
        }
        func firstColor(_ info: ViewLineInfo, _ key: NSAttributedString.Key) -> NSColor? {
            guard let segment = info.segments.first, segment.attributedString.length > 0 else {
                return nil
            }
            return segment.attributedString.attribute(key, at: 0, effectiveRange: nil) as? NSColor
        }

        // The exact native full-screen response shape: a colored ED2 keeps a
        // visible blank background in every column, with no procedural items.
        let cleared = CmdyTerminal(cols: 120, rows: 36)
        let before = cleared.captureTerminalSnapshot()
        cleared.feed(text: "\u{1b}[48;2;14;28;42m\u{1b}[2J\u{1b}[H")
        let after = cleared.captureTerminalSnapshot()
        let expectedBackground: [CGFloat] = [14 / 255, 28 / 255, 42 / 255, 1]
        var allRowsMatch = true
        for row in 0..<36 {
            let absoluteRow = after.grid.liveTopRow + row
            let info = CmdySnapshotShaper.lineInfo(snapshot: after, absoluteRow: absoluteRow,
                style: style(), selectedColumns: nil)
            let segment = info.segments.first
            allRowsMatch = allRowsMatch && info.segments.count == 1
                && segment?.attributedString.string == String(repeating: " ", count: 120)
                && segment?.column == 0 && segment?.columnWidth == 1
                && segment?.characterCount == 120
                && segment?.cellUTF16Boundaries == Array(0...120)
                && same(firstColor(info, .backgroundColor), expectedBackground)
                && same(firstColor(info, .foregroundColor), [0.8, 0.6, 0.4, 1])
                && info.blockElements.isEmpty && info.boxDrawings.isEmpty
                && info.kittyPlaceholders.isEmpty && info.images == nil
        }
        check(allRowsMatch, "procedural colors: all 36 colored blank rows preserve exact spans, colors and boundaries")
        check(before.line(absolute: 0)?.cells.allSatisfy { $0.attribute == .bufferDefault } == true
                && after.line(absolute: 0)?.cells.allSatisfy { $0.attribute.bg == .trueColor(14, 28, 42) } == true,
              "procedural colors: the colored erase fixture preserves the retained earlier snapshot")

        // Multiple UTF-16 units and positive-width cells remain the existing
        // cell-to-text contract, including malformed scalar/placeholder spaces.
        let ordinaryAttribute = CellAttribute(fg: .trueColor(51, 102, 153),
                                             bg: .trueColor(204, 153, 102))
        let ordinary = snapshot([
            Cell(scalar: 0x41, attribute: ordinaryAttribute),
            Cell(scalar: 0x65, clusterExtras: [0x301], attribute: ordinaryAttribute),
            Cell(scalar: 0x1F642, width: 2, attribute: ordinaryAttribute),
            Cell(width: 0, attribute: ordinaryAttribute),
            Cell(attribute: ordinaryAttribute),
            Cell(scalar: 0xD800, attribute: ordinaryAttribute),
            Cell(scalar: 0x10EEEE, attribute: ordinaryAttribute),
        ])
        let ordinaryInfo = CmdySnapshotShaper.lineInfo(snapshot: ordinary, absoluteRow: 0,
            style: style(), selectedColumns: nil)
        check(ordinaryInfo.segments.map { $0.attributedString.string } == ["Ae\u{301}", "🙂", "   "]
                && ordinaryInfo.segments.map(\.column) == [0, 2, 4]
                && ordinaryInfo.segments.map(\.columnWidth) == [1, 2, 1]
                && ordinaryInfo.segments.map(\.characterCount) == [2, 1, 3]
                && ordinaryInfo.segments.map(\.cellUTF16Boundaries) == [[0, 1, 3], [0, 2], [0, 1, 2, 3]]
                && ordinaryInfo.blockElements.isEmpty && ordinaryInfo.boxDrawings.isEmpty
                && ordinaryInfo.kittyPlaceholders.isEmpty,
              "procedural colors: ordinary, combining, wide and malformed cells preserve exact text boundaries")
        check(ordinaryInfo.segments.allSatisfy { segment in
            same(segment.attributedString.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor,
                 [0.2, 0.4, 0.6, 1])
                && same(segment.attributedString.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor,
                        [0.8, 0.6, 0.4, 1])
        }, "procedural colors: ordinary run attributes retain true foreground and background colors")

        struct Fixture {
            let name: String
            let attribute: CellAttribute
            let expected: [CGFloat]
            var failed = false
        }
        let fixtures: [Fixture] = [
            Fixture(name: "native defaults", attribute: .bufferDefault, expected: [0.8, 0.6, 0.4, 1]),
            Fixture(name: "bold ANSI bright partner", attribute: CellAttribute(fg: .ansi256(1), style: .bold),
                    expected: [0.6, 0.7, 0.8, 1]),
            Fixture(name: "true color", attribute: ordinaryAttribute, expected: [0.2, 0.4, 0.6, 1]),
            Fixture(name: "inverse true colors", attribute: CellAttribute(fg: ordinaryAttribute.fg,
                    bg: ordinaryAttribute.bg, style: .inverse), expected: [0.8, 0.6, 0.4, 1]),
            Fixture(name: "inverse native defaults", attribute: CellAttribute(style: .inverse),
                    expected: [0.2, 0.4, 0.6, 1]),
            Fixture(name: "inverted default token", attribute: CellAttribute(fg: .defaultInverted),
                    expected: [0.2, 0.4, 0.6, 1]),
            Fixture(name: "dim", attribute: CellAttribute(fg: ordinaryAttribute.fg,
                    bg: ordinaryAttribute.bg, style: .dim), expected: [0.5, 0.5, 0.5, 1]),
            Fixture(name: "inverse dim", attribute: CellAttribute(fg: ordinaryAttribute.fg,
                    bg: ordinaryAttribute.bg, style: [.inverse, .dim]), expected: [0.5, 0.5, 0.5, 1]),
            Fixture(name: "invisible", attribute: CellAttribute(fg: ordinaryAttribute.fg,
                    bg: ordinaryAttribute.bg, style: .invisible), expected: [0.8, 0.6, 0.4, 1]),
            Fixture(name: "dim invisible", attribute: CellAttribute(fg: ordinaryAttribute.fg,
                    bg: ordinaryAttribute.bg, style: [.dim, .invisible]), expected: [0.8, 0.6, 0.4, 1]),
            Fixture(name: "failed row override", attribute: CellAttribute(fg: ordinaryAttribute.fg,
                    bg: ordinaryAttribute.bg, style: [.inverse, .dim, .invisible]),
                    expected: [0.9, 0.1, 0.2, 1], failed: true),
        ]
        for fixture in fixtures {
            let captured = snapshot([
                Cell(scalar: 0x2500, attribute: fixture.attribute),
                Cell(scalar: 0x2588, attribute: fixture.attribute),
            ])
            let info = CmdySnapshotShaper.lineInfo(snapshot: captured, absoluteRow: 0,
                style: style(failed: fixture.failed), selectedColumns: nil)
            check(info.boxDrawings.count == 1 && info.blockElements.count == 1
                    && info.boxDrawings.first?.column == 0 && info.blockElements.first?.column == 1
                    && info.boxDrawings.first?.codePoint == 0x2500 && info.blockElements.first?.codePoint == 0x2588
                    && same(info.boxDrawings.first?.foregroundColor, fixture.expected)
                    && same(info.blockElements.first?.foregroundColor, fixture.expected)
                    && same(firstColor(info, .foregroundColor), fixture.expected)
                    && info.segments.first?.attributedString.string == "  "
                    && info.segments.first?.cellUTF16Boundaries == [0, 1, 2],
                  "procedural colors: box and block \(fixture.name) retain independent expected colors")
        }
    }
}
