import AppKit
import CmdyCore
import CmdyGPU

@main
struct ShaperDifferential {
    @MainActor static func main() {
        var failures = 0, checks = 0, cases = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures += 1; if failures < 30 { print("FAIL \(label)") } }
        }
        CmdyShaperPendingRunHarness.run(check)
        CmdyShaperProceduralColorHarness.run(check)
        CmdySnapshotRevisionHarness.run(check)
        CmdyCellImageHarness.run(check)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let both = NSFontManager.shared.convert(font, toHaveTrait: [.boldFontMask, .italicFontMask])
        let palette: [NSColor] = (0..<256).map { index in
            let red = CGFloat(index) / 255
            let green = CGFloat(255 - index) / 255
            let blue = CGFloat((index * 17) % 256) / 255
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: 1)
        }
        var random: UInt64 = 0x123456781abcdef
        func next(_ limit: Int) -> Int {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            return Int((random >> 32) % UInt64(limit))
        }
        func token(_ value: Int) -> CellColor {
            switch value % 5 {
            case 0: .defaultColor
            case 1: .defaultInverted
            case 2: .ansi256(UInt8(value % 256))
            case 3: .trueColor(UInt8(value % 256), UInt8(value * 7 % 256), UInt8(value * 19 % 256))
            default: .ansi256(UInt8(value % 8))
            }
        }
        func key(_ rect: BlockElementRect) -> String {
            "\(rect.x0),\(rect.x1),\(rect.y0),\(rect.y1),\(rect.alpha.rawValue)"
        }
        func same(_ lhs: ViewLineInfo, _ rhs: ViewLineInfo, _ label: String) {
            check(lhs.segments.count == rhs.segments.count, label+" segment count")
            for (l,r) in zip(lhs.segments,rhs.segments) {
                check(l.column == r.column && l.columnWidth == r.columnWidth && l.characterCount == r.characterCount
                    && l.cellUTF16Boundaries == r.cellUTF16Boundaries && l.attributedString.isEqual(to:r.attributedString), label+" segment")
            }
            check(lhs.blockElements.count == rhs.blockElements.count, label+" block count")
            for (l,r) in zip(lhs.blockElements,rhs.blockElements) {
                check(l.column == r.column && l.columnWidth == r.columnWidth && l.codePoint == r.codePoint
                    && l.rects.map(key) == r.rects.map(key) && l.foregroundColor == r.foregroundColor, label+" block")
            }
            check(lhs.boxDrawings.count == rhs.boxDrawings.count, label+" box count")
            for (l,r) in zip(lhs.boxDrawings,rhs.boxDrawings) {
                check(l.column == r.column && l.columnWidth == r.columnWidth && l.codePoint == r.codePoint
                    && l.foregroundColor == r.foregroundColor, label+" box")
            }
            check(lhs.kittyPlaceholders.count == rhs.kittyPlaceholders.count, label+" placeholder count")
            for (l,r) in zip(lhs.kittyPlaceholders,rhs.kittyPlaceholders) {
                check(l.row == r.row && l.col == r.col && l.imageId == r.imageId && l.placementId == r.placementId
                    && l.placeholderRow == r.placeholderRow && l.placeholderCol == r.placeholderCol && l.msb == r.msb, label+" placeholder")
            }
        }
        let scalars: [UInt32] = [0,32,65,101,0x301,0x1f469,0x200d,0x1f4bb,0xfe0f,0x10eeee,0xd800,0x110000,
            0x2500,0x2501,0x2510,0x257f,0x2580,0x2585,0x2591,0x2592,0x2593,0x259f,0x4e00]
        for iteration in 0..<1200 {
            autoreleasepool {
                let failed: Set<Int> = iteration % 7 == 0 ? [0] : []
                let style = CmdyShapingStyle(palette:palette,normalFont:font,boldFont:bold,italicFont:italic,boldItalicFont:both,
                    foreground:.white,background:.black,selectionBackground:.blue,failedRows:failed,failedForeground:.red,failedBackground:.gray)
                let original = OriginalCmdyShapingStyle(palette:palette,normalFont:font,boldFont:bold,italicFont:italic,boldItalicFont:both,
                    foreground:.white,background:.black,selectionBackground:.blue,failedRows:failed,failedForeground:.red,failedBackground:.gray)
                let terminal = CmdyTerminal(cols: 32, rows: 2)
                let line = terminal.lineForDiff(absolute:0)!
                for col in 0..<32 {
                    let extra: [UInt32]? = switch next(6) {
                    case 0: nil
                    case 1: []
                    case 2: [0x301,0x302]
                    case 3: [0x305,0x30d,0x30e]
                    case 4: [0x200d,0x1f4bb]
                    default: [0xd800,0x41,0x110000]
                    }
                    let styleBits = UInt8(truncatingIfNeeded: iteration+col)
                    let attr = CellAttribute(fg:token(next(256)),bg:token(next(256)),style:CellStyle(rawValue:styleBits),
                        underlineKind:UnderlineKind(rawValue:UInt8(next(6)))!,underlineColor:next(3)==0 ? nil : token(next(256)))
                    line[col] = Cell(scalar:scalars[next(scalars.count)],clusterExtras:extra,width:Int8(next(4)),attribute:attr,linkId:UInt16(next(100)))
                }
                let snapshot = terminal.captureTerminalSnapshot(extraScreens:0)
                let lower = next(40)-4
                let selection: ClosedRange<Int>? = iteration % 3 == 0 ? nil : lower...(lower+next(20))
                let actual = CmdySnapshotShaper.lineInfo(snapshot:snapshot,absoluteRow:0,style:style,selectedColumns:selection)
                let expected = OriginalCmdySnapshotShaper.lineInfo(snapshot:snapshot,absoluteRow:0,style:original,selectedColumns:selection)
                same(actual,expected,"case \(iteration)")
                let actualCursor = CmdySnapshotShaper.cursorString(snapshot:snapshot,style:style,caretColor:.yellow,caretTextColor:iteration%2==0 ? nil:.cyan)
                let originalCursor = OriginalCmdySnapshotShaper.cursorString(snapshot:snapshot,style:original,caretColor:.yellow,caretTextColor:iteration%2==0 ? nil:.cyan)
                check(actualCursor == originalCursor,"case \(iteration) cursor")
                cases += 1
            }
        }
        print("Shaper differential: \(cases) rows, \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
