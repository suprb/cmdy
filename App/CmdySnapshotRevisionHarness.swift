import AppKit
import CmdyCore
@_spi(CmdyApp) import CmdyGPU

/// Snapshot/context checks run with the executable's existing seam selftest.
/// These fixtures have no PTY, window, external files or retained user data.
@MainActor
enum CmdySnapshotRevisionHarness {
    static func run(_ check: (Bool, String) -> Void) {
        let terminal = CmdyTerminal(cols: 120, rows: 36)
        terminal.feed(text: (0..<36).map { "\u{1b}[\($0 + 1);1Hrow \($0)" }.joined())
        // Model an editor whose insertion cursor starts on the first row.
        // Moving from row 35 after capture would correctly dirty that row too.
        terminal.feed(text: "\u{1b}[1;1H")
        let first = terminal.captureTerminalSnapshot()
        let context = CmdySnapshotRowContext()
        var styleCalls = 0
        func countedStyle(_ variant: Int = 0) -> CmdyShapingStyle {
            styleCalls += 1
            return style(variant)
        }
        context.beginFrame()
        check(styleCalls == 0, "snapshot revision: beginning a cache-only frame does not resolve fonts")
        let firstRevision = context.revision(snapshot: first, absoluteRow: 0, style: countedStyle())
        let middleRevision = context.revision(snapshot: first, absoluteRow: 10, style: countedStyle())
        let capturedStyle = context.style(countedStyle())
        check(firstRevision != nil && middleRevision != nil && styleCalls == 1,
              "snapshot revision: rows and shaping use one lazy captured style")

        terminal.feed(text: "\u{1b}[1;1HA\u{301}中🙂\u{1b}[35;1H\u{1b}[41mstatus\u{1b}[0m")
        let edited = terminal.captureTerminalSnapshot()
        check(edited.dirtyRows == 0...34,
              "snapshot revision: distant edits retain the conservative damage span")
        check(context.revision(snapshot: first, absoluteRow: 0, style: countedStyle(6)) == firstRevision
                && context.style(countedStyle(6)) == capturedStyle,
              "snapshot revision: an old capture never reads newer content or a later style")
        context.beginFrame()
        let editedRevision = context.revision(snapshot: edited, absoluteRow: 0, style: countedStyle())
        check(editedRevision != firstRevision
                && context.revision(snapshot: edited, absoluteRow: 10, style: countedStyle()) == middleRevision,
              "snapshot revision: Unicode edit changes identity while intervening syntax stays stable")
        check(styleCalls == 2, "snapshot revision: one style evaluation per used capture")

        // Cursor and native selection are composed separately from text rows.
        terminal.feed(text: "\u{1b}[2;2H")
        let moved = terminal.captureTerminalSnapshot()
        context.beginFrame()
        check(context.revision(snapshot: moved, absoluteRow: 0, style: style()) == editedRevision
                && moved.grid.cursorRow != edited.grid.cursorRow,
              "snapshot revision: cursor movement does not invalidate unchanged row content")
        let plain = CmdySnapshotShaper.lineInfo(snapshot: moved, absoluteRow: 0,
                                               style: style(), selectedColumns: nil)
        check(plain.segments.allSatisfy {
            $0.attributedString.length == 0 || $0.attributedString.attribute(
                .selectionBackgroundColor, at: 0, effectiveRange: nil) == nil
        }, "snapshot revision: native selection remains outside the cached text payload")

        for variant in 1...11 {
            let changedContext = CmdySnapshotRowContext()
            let base = changedContext.revision(snapshot: moved, absoluteRow: 0, style: style())
            changedContext.beginFrame()
            let changed = changedContext.revision(snapshot: moved, absoluteRow: 0, style: style(variant))
            check(base?.content == changed?.content && base?.context != changed?.context,
                  "snapshot revision: shaping input \(variant) invalidates the context")
        }

        // Exercise the public row metadata seam. The parser does not implement
        // ESC #6, so that sequence cannot establish double-width geometry.
        terminal.lineForDiff(absolute: 0)?.renderMode = .doubleWidth
        let doubled = terminal.captureTerminalSnapshot()
        context.beginFrame()
        let doubledRevision = context.revision(snapshot: doubled, absoluteRow: 0, style: style())
        check(doubled.line(absolute: 0)?.renderMode == .doubleWidth
                && doubledRevision != nil && doubledRevision?.content != editedRevision?.content
                && doubledRevision?.context == editedRevision?.context,
              "snapshot revision: DEC row geometry changes the content revision")
        terminal.resize(cols: 60, rows: 36)
        let resized = terminal.captureTerminalSnapshot()
        context.beginFrame()
        check(resized.grid.cols == 60
                && context.revision(snapshot: resized, absoluteRow: 0, style: style()) != doubledRevision,
              "snapshot revision: width reflow produces a new row identity")

        let replacement = CmdyTerminal(cols: 60, rows: 36)
        replacement.feed(text: "replacement")
        let replacementSnapshot = replacement.captureTerminalSnapshot()
        context.beginFrame()
        check(context.revision(snapshot: replacementSnapshot, absoluteRow: 0, style: style())
                != context.revision(snapshot: resized, absoluteRow: 0, style: style()),
              "snapshot revision: content stamps distinguish replacement Line objects")
        check(context.revision(snapshot: resized, absoluteRow: 100_000, style: style()) == nil,
              "snapshot revision: missing rows cannot opt in")

        replacement.lineForDiff(absolute: 0)?.images = [LineImage(
            payload: .rgba(bytes: [255, 0, 0, 255], width: 1, height: 1),
            pixelWidth: 1, pixelHeight: 1, col: 0)]
        let imageSnapshot = replacement.captureTerminalSnapshot()
        context.beginFrame()
        check(imageSnapshot.line(absolute: 0)?.images.count == 1
                && context.revision(snapshot: imageSnapshot, absoluteRow: 0, style: style()) == nil,
              "snapshot revision: mutable external image payloads use the full dirty path")

        let kitty = CmdyTerminal(cols: 20, rows: 4)
        kitty.feed(text: "\u{1b}_Ga=T,f=32,s=1,v=1,i=1;/////w==\u{1b}\\")
        let kittySnapshot = kitty.captureTerminalSnapshot()
        context.beginFrame()
        check(!kittySnapshot.kittyImages.isEmpty
                && context.revision(snapshot: kittySnapshot, absoluteRow: 0, style: style()) == nil,
              "snapshot revision: Kitty image state cannot use content-only row identity")

        checkDynamicAppearance(check)
    }

    private static func checkDynamicAppearance(_ check: (Bool, String) -> Void) {
        let terminal = CmdyTerminal(cols: 20, rows: 4)
        terminal.feed(text: "\u{1b}[7mA\u{1b}[0;31;4mB\u{1b}[0m")
        let snapshot = terminal.captureTerminalSnapshot()
        let base = style()
        var palette = base.palette
        palette[1] = .textColor
        func dynamicStyle(foreground: NSColor = .white) -> CmdyShapingStyle {
            CmdyShapingStyle(palette: palette, normalFont: base.normalFont,
                boldFont: base.boldFont, italicFont: base.italicFont, boldItalicFont: base.boldItalicFont,
                foreground: foreground, background: .textBackgroundColor,
                selectionBackground: .selectedTextBackgroundColor, failedRows: [],
                failedForeground: .textColor, failedBackground: .textBackgroundColor)
        }
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        let context = CmdySnapshotRowContext()
        let dynamic = dynamicStyle()
        let lightRevision = context.revision(snapshot: snapshot, absoluteRow: 0,
                                            style: dynamic, appearance: light)
        let lightStyle = context.style(dynamic, appearance: light)
        let lightInfo = CmdySnapshotShaper.lineInfo(snapshot: snapshot, absoluteRow: 0,
                                                  style: lightStyle, selectedColumns: nil)
        context.beginFrame()
        let darkRevision = context.revision(snapshot: snapshot, absoluteRow: 0,
                                           style: dynamic, appearance: dark)
        let darkStyle = context.style(dynamic, appearance: dark)
        let darkInfo = CmdySnapshotShaper.lineInfo(snapshot: snapshot, absoluteRow: 0,
                                                 style: darkStyle, selectedColumns: nil)
        func components(_ color: NSColor?) -> [CGFloat]? {
            guard let rgb = color?.usingColorSpace(.sRGB) else { return nil }
            return [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        }
        check(lightRevision != nil && darkRevision != nil
                && lightRevision?.content == darkRevision?.content
                && lightRevision?.context != darkRevision?.context
                && components(lightStyle.foreground) == components(darkStyle.foreground)
                && components(lightStyle.background) != components(darkStyle.background)
                && components(lightStyle.palette[1]) != components(darkStyle.palette[1]),
              "snapshot revision: appearance changes dynamic context even with fixed fallback foreground")
        func firstColor(_ info: ViewLineInfo, _ key: NSAttributedString.Key) -> NSColor? {
            info.segments.first?.attributedString.attribute(
                key, at: 0, effectiveRange: nil) as? NSColor
        }
        // The shaping contract complements each role's native default. Fixed
        // white foreground therefore stays black; dynamic background changes.
        func complement(_ color: NSColor) -> [CGFloat]? {
            components(color).map { [1 - $0[0], 1 - $0[1], 1 - $0[2], $0[3]] }
        }
        check(components(firstColor(lightInfo, .foregroundColor)) == complement(lightStyle.foreground)
                && components(firstColor(darkInfo, .foregroundColor)) == complement(darkStyle.foreground)
                && components(firstColor(lightInfo, .backgroundColor)) == complement(lightStyle.background)
                && components(firstColor(darkInfo, .backgroundColor)) == complement(darkStyle.background)
                && components(firstColor(lightInfo, .backgroundColor)) != components(firstColor(darkInfo, .backgroundColor)),
              "snapshot revision: inverse cells bind resolved appearance colors in their shared text key")
        let capturedBackground = components(lightStyle.background)
        var frozenAcrossAppearance = false
        dark.performAsCurrentDrawingAppearance {
            frozenAcrossAppearance = components(lightStyle.background) == capturedBackground
        }
        check(frozenAcrossAppearance,
              "snapshot revision: captured style colors remain immutable under another appearance")

        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 8, height: 8)))
        context.beginFrame()
        let unsupported = context.revision(snapshot: snapshot, absoluteRow: 0,
            style: dynamicStyle(foreground: pattern), appearance: light)
        check(unsupported == nil
                && context.style(dynamicStyle(foreground: pattern), appearance: light).foreground === pattern,
              "snapshot revision: unresolvable colors preserve original shaping and the full dirty path")
    }

    /// Change each actual shaping input independently, including all fallback
    /// font variants and failed/selection colors even when not visible today.
    private static func style(_ variant: Int = 0) -> CmdyShapingStyle {
        var palette = CmdyTerminalSurface.defaultPalette()
        if variant == 1 { palette[1] = .green }
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        let changedFont = NSFont.monospacedSystemFont(ofSize: 18, weight: .bold)
        return CmdyShapingStyle(
            palette: palette,
            normalFont: variant == 2 ? changedFont : font,
            boldFont: variant == 3 ? changedFont : font,
            italicFont: variant == 4 ? changedFont : font,
            boldItalicFont: variant == 5 ? changedFont : font,
            foreground: variant == 6 ? .cyan : .white,
            background: variant == 7 ? .blue : .black,
            selectionBackground: variant == 8 ? .purple : .orange,
            failedRows: variant == 9 ? [0] : [],
            failedForeground: variant == 10 ? .yellow : .red,
            failedBackground: variant == 11 ? .orange : .brown)
    }
}
