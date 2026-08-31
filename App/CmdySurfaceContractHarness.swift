import AppKit
import CoreGraphics
import Metal
import MetalKit
import CmdyCore
import CmdyGPU

/// Focused executable-target harness for the independent App seam.  It is run
/// by `cmdy --selftest` without changing the production factory.
@MainActor
enum CmdySurfaceContractHarness {
    static func run(_ check: (Bool, String) -> Void) {
        func drain(_ seconds: TimeInterval = 0.025) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func sameColor(_ lhs: NSColor?, _ rhs: NSColor, tolerance: CGFloat = 0.002) -> Bool {
            guard let lhs = lhs?.usingColorSpace(.sRGB),
                  let rhs = rhs.usingColorSpace(.sRGB) else { return false }
            return abs(lhs.redComponent - rhs.redComponent) <= tolerance
                && abs(lhs.greenComponent - rhs.greenComponent) <= tolerance
                && abs(lhs.blueComponent - rhs.blueComponent) <= tolerance
                && abs(lhs.alphaComponent - rhs.alphaComponent) <= tolerance
        }

        func string(_ info: ViewLineInfo) -> String {
            info.segments.map { $0.attributedString.string }.joined()
        }

        let palette = CmdyTerminalSurface.defaultPalette()
        check(palette.count == 256, "independent seam: palette has 256 entries")
        check(sameColor(palette[16], NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
                && sameColor(palette[231], NSColor.white)
                && sameColor(palette[232], NSColor(
                    srgbRed: 8 / 255, green: 8 / 255, blue: 8 / 255, alpha: 1))
                && sameColor(palette[255], NSColor(
                    srgbRed: 238 / 255, green: 238 / 255, blue: 238 / 255, alpha: 1)),
              "independent seam: cube and gray palette endpoints are exact")

        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let oneX = CmdyTerminalSurface.metricsForTesting(
            font: font, multiplier: 1.15, scale: 1)
        let twoX = CmdyTerminalSurface.metricsForTesting(
            font: font, multiplier: 1.15, scale: 2)
        check(oneX.size.width >= 1 && oneX.size.height >= 1
                && oneX.baseline > 0 && oneX.baseline <= oneX.size.height,
              "independent seam: metrics are positive with a valid baseline")
        check((twoX.size.width * 2).rounded() == twoX.size.width * 2
                && (twoX.size.height * 2).rounded() == twoX.size.height * 2,
              "independent seam: 2x metrics land on device pixels")

        check(CmdyTerminalSurface.returnKeyBytes(
            modifiers: [], kittyKeyboardFlags: 0) == [0x0D],
              "independent seam: unmodified Return is CR")
        check(CmdyTerminalSurface.returnKeyBytes(
            modifiers: [.shift], kittyKeyboardFlags: 0) == [0x1B, 0x0D],
              "independent seam: legacy Shift-Return is ESC CR")
        check(String(decoding: CmdyTerminalSurface.returnKeyBytes(
            modifiers: [.option], kittyKeyboardFlags: 1), as: UTF8.self)
                == "\u{1b}[13;3u",
              "independent seam: Kitty Option-Return is CSI-u")

        let surface = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 420, height: 180))
        check(surface.engine.cols >= 2 && surface.engine.rows >= 1,
              "independent seam: initial grid respects the 2x1 minimum")
        surface.leftContentInset = 13.25
        let origin = surface.contentXOrigin
        surface.setFrameSize(NSSize(width: 437, height: 180))
        check(surface.contentXOrigin == origin,
              "independent seam: resize never horizontally recenters column zero")

        var resizeOrder: [String] = []
        var resizeCallbackSawEngine = false
        surface.willReflowBuffer = { resizeOrder.append("will") }
        surface.onSizeChanged = { cols, rows in
            resizeOrder.append("size")
            resizeCallbackSawEngine = surface.engine.cols == cols
                && surface.engine.rows == rows
        }
        surface.didReflowBuffer = { resizeOrder.append("did") }
        surface.setFrameSize(NSSize(width: 280, height: 160))
        check(resizeOrder == ["will", "size", "did"],
              "independent seam: reflow and resize callbacks are ordered")
        check(resizeCallbackSawEngine,
              "independent seam: size callback observes the resized engine")

        surface.feed(text: "A\u{0301}\u{1F600}\u{2500}\u{2588}")
        drain()
        _ = surface.captureGrid()
        let shaped = surface.lineInfo(forRow: 0)
        let boundariesValid = shaped.segments.allSatisfy { segment in
            guard let boundaries = segment.cellUTF16Boundaries else { return false }
            return boundaries.count == segment.characterCount + 1
                && boundaries.first == 0
                && boundaries.last == segment.attributedString.length
                && zip(boundaries, boundaries.dropFirst()).allSatisfy {
                    $0.0 <= $0.1
                }
        }
        check(boundariesValid,
              "independent seam: UTF-16 boundaries stay authoritative per engine cell")
        check(shaped.boxDrawings.count == 1 && shaped.blockElements.count == 1,
              "independent seam: box and block cells become procedural items")
        check(!string(shaped).contains("\u{2500}") && !string(shaped).contains("\u{2588}"),
              "independent seam: procedural glyphs contribute background spacers")
        check(shaped.segments.reduce(0) { $0 + $1.characterCount } < surface.engine.cols,
              "independent seam: default trailing cells are trimmed")

        let frameText = string(shaped)
        surface.feed(text: "Z")
        drain()
        check(string(surface.lineInfo(forRow: 0)) == frameText,
              "independent seam: a captured frame never tears after publication")
        _ = surface.captureGrid()
        check(string(surface.lineInfo(forRow: 0)) != frameText,
              "independent seam: the following capture observes new output")

        _ = surface.consumeDirtyRows()
        surface.feed(text: "\r\nfirst\r\nsecond")
        drain()
        let damage = surface.consumeDirtyRows()
        check(damage != nil && damage!.lowerBound <= damage!.upperBound
                && surface.consumeDirtyRows() == nil,
              "independent seam: published damage unions and transfers once")

        let bold = surface.attributes(
            for: CellAttribute(fg: .ansi256(1), style: .bold), selected: false)
        check(sameColor(bold[.foregroundColor] as? NSColor, surface.paletteColor(9)),
              "independent seam: bold ANSI 0...6 selects the bright partner")
        let brightAlready = surface.attributes(
            for: CellAttribute(fg: .ansi256(8), style: .bold), selected: false)
        check(sameColor(brightAlready[.foregroundColor] as? NSColor,
                        surface.paletteColor(8)),
              "independent seam: bold never shifts indices 8...255")
        let selected = surface.attributes(for: .bufferDefault, selected: true)
        check(selected[.selectionBackgroundColor] != nil
                && selected[.backgroundColor] == nil,
              "independent seam: selection is separate from the native clear background")
        let underlined = surface.attributes(
            for: CellAttribute(style: .underline, underlineKind: .curly),
            selected: false)
        check(underlined[.underlineStyle] != nil,
              "independent seam: underline style survives shaping")

        let input = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 480, height: 140))
        var sent: [UInt8] = []
        input.onSendToProcess = { sent.append(contentsOf: $0) }
        func key(_ keyCode: UInt16, _ characters: String,
                 _ modifiers: NSEvent.ModifierFlags = []) -> String {
            sent.removeAll(keepingCapacity: true)
            let event = NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode)!
            input.keyDown(with: event)
            drain()
            return String(decoding: sent, as: UTF8.self)
        }
        check(key(126, "") == "\u{1b}[A"
                && key(126, "", [.shift, .control]) == "\u{1b}[1;6A",
              "independent seam: arrows encode normal and modified CSI forms")
        input.feed(text: "\u{1b}[?1h")
        drain()
        check(key(126, "") == "\u{1b}OA",
              "independent seam: application cursor mode uses SS3")
        check(key(116, "") == "\u{1b}[5~"
                && key(121, "", [.option]) == "\u{1b}[6;3~"
                && key(117, "", [.control]) == "\u{1b}[3;5~",
              "independent seam: page and forward-delete tilde keys include modifiers")
        check(key(48, "\t", [.shift]) == "\u{1b}[Z"
                && Array(key(51, "", [.option]).utf8) == [0x1B, 0x7F],
              "independent seam: Shift-Tab and Option-Backspace are exact")
        check(key(122, "") == "\u{1b}OP"
                && key(111, "", [.shift]) == "\u{1b}[24;2~",
              "independent seam: F1 and F12 cover SS3 and tilde families")
        check(Array(key(0, "a", [.control]).utf8) == [1],
              "independent seam: Control-A maps to byte 1")
        input.optionAsMetaKey = true
        check(key(0, "a", [.option]) == "\u{1b}a",
              "independent seam: Option-as-Meta prefixes the unmodified character")

        let oldPasteboard = NSPasteboard.general.string(forType: .string)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("paste", forType: .string)
        input.feed(text: "\u{1b}[?2004h")
        drain()
        sent.removeAll()
        var pasteHookCalls = 0
        input.onPasteRequest = { pasteHookCalls += 1; return $0.uppercased() }
        input.paste(nil)
        drain()
        check(pasteHookCalls == 1
                && String(decoding: sent, as: UTF8.self) == "\u{1b}[200~PASTE\u{1b}[201~",
              "independent seam: bracketed paste transforms once and brackets once")
        NSPasteboard.general.clearContents()
        if let oldPasteboard { NSPasteboard.general.setString(oldPasteboard, forType: .string) }

        let selection = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 480, height: 140))
        selection.feed(text: "alpha beta")
        drain()
        let rowY = selection.bounds.height - selection.cellSize.height / 2
        func mouse(_ type: NSEvent.EventType, x: CGFloat,
                   modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: x, y: rowY),
                modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        var selectionNotifications = 0
        selection.onSelectionChanged = { selectionNotifications += 1 }
        _ = selection.consumePublishedDirtyRows()
        selection.mouseDown(with: mouse(.leftMouseDown, x: 1))
        let mouseDownDamage = selection.consumePublishedDirtyRows()
        selection.mouseDragged(with: mouse(
            .leftMouseDragged, x: selection.cellSize.width * 4.5))
        let mouseDragDamage = selection.consumePublishedDirtyRows()
        selection.mouseUp(with: mouse(
            .leftMouseUp, x: selection.cellSize.width * 4.5))
        let mouseUpDamage = selection.consumePublishedDirtyRows()
        check(selection.selectedText() == "alpha" && selectionNotifications == 1,
              "independent seam: completed primary drag selects absolute cells once")
        check(mouseDownDamage == nil && mouseDragDamage == nil
                && mouseUpDamage == nil,
              "independent seam: selection drag preserves cached text rows")
        _ = selection.captureGrid()
        let selectedLine = selection.lineInfo(forRow: 0)
        let bakedSelection = selectedLine.segments.contains { segment in
            guard segment.attributedString.length > 0 else { return false }
            return segment.attributedString.attribute(
                .selectionBackgroundColor, at: 0, effectiveRange: nil) != nil
        }
        check(selection.selectionColumns(forRow: 0) == 0...4
                && !bakedSelection,
              "independent seam: selection is dynamic geometry, not row texture state")

        let resizedSelection = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 480, height: 140))
        let wideColumns = resizedSelection.engine.cols
        let selectedTail = "tail"
        let selectedTailStart = wideColumns - selectedTail.count - 1
        resizedSelection.feed(text:
            String(repeating: "x", count: selectedTailStart) + selectedTail)
        drain()
        let selectionStartRow = resizedSelection.renderSnapshot.grid.displayTopRow
        resizedSelection.setSelectionForTesting(
            anchor: .init(row: selectionStartRow, col: selectedTailStart),
            active: .init(
                row: selectionStartRow,
                col: selectedTailStart + selectedTail.count - 1))
        let selectedBeforeNarrowing = resizedSelection.selectedText()
        var resizeSelectionNotifications = 0
        resizedSelection.onSelectionChanged = {
            resizeSelectionNotifications += 1
        }
        resizedSelection.setFrameSize(NSSize(
            width: resizedSelection.cellSize.width * 6,
            height: resizedSelection.bounds.height))
        _ = resizedSelection.captureGrid()
        check(selectedBeforeNarrowing == selectedTail
                && wideColumns > resizedSelection.engine.cols
                && resizedSelection.selectedText().isEmpty
                && resizedSelection.selectionColumns(forRow: selectionStartRow) == nil
                && resizeSelectionNotifications == 1,
              "independent seam: a narrower reflow clears rather than retargets selection")

        let boundedCopy = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        boundedCopy.setFrameSize(NSSize(
            width: boundedCopy.cellSize.width * 6,
            height: boundedCopy.bounds.height))
        boundedCopy.feed(text: "abcdef")
        drain()
        let boundedRow = boundedCopy.renderSnapshot.grid.displayTopRow
        boundedCopy.setSelectionForTesting(
            anchor: .init(row: boundedRow, col: -20),
            active: .init(row: boundedRow, col: 1))
        let lowerBoundedText = boundedCopy.selectedText()
        boundedCopy.setSelectionForTesting(
            anchor: .init(row: boundedRow, col: 4),
            active: .init(row: boundedRow, col: 99))
        let upperBoundedText = boundedCopy.selectedText()
        boundedCopy.setSelectionForTesting(
            anchor: .init(row: boundedRow, col: 99),
            active: .init(row: boundedRow, col: 100))
        check(boundedCopy.engine.cols == 6
                && lowerBoundedText == "ab"
                && upperBoundedText == "ef"
                && boundedCopy.selectedText().isEmpty,
              "independent seam: copy bounds intersect valid cells without trapping")

        selection.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        drain()
        var mouseBytes: [UInt8] = []
        selection.onSendToProcess = { mouseBytes.append(contentsOf: $0) }
        mouseBytes.removeAll()
        selection.mouseDown(with: mouse(.leftMouseDown, x: 1))
        selection.mouseDragged(with: mouse(
            .leftMouseDragged, x: selection.cellSize.width * 4.5))
        selection.mouseUp(with: mouse(
            .leftMouseUp, x: selection.cellSize.width * 4.5))
        drain()
        check(mouseBytes.isEmpty && selection.selectedText() == "alpha",
              "independent seam: tracked primary drag becomes native selection")
        mouseBytes.removeAll()
        selection.mouseDown(with: mouse(.leftMouseDown, x: 1))
        selection.mouseUp(with: mouse(.leftMouseUp, x: 1))
        drain()
        let clickReport = String(decoding: mouseBytes, as: UTF8.self)
        check(clickReport.contains("\u{1b}[<0;")
                && clickReport.contains("M") && clickReport.contains("m"),
              "independent seam: tracked primary click emits press then release")

        let links = CmdyTerminalSurface(
            frame: NSRect(x: 0, y: 0, width: 600, height: 120))
        links.feed(text: "\u{1b}]8;;https://example.com/a\u{7}docs\u{1b}]8;;\u{7} localhost:4173/x")
        drain()
        let linkY = links.bounds.height - links.cellSize.height / 2
        check(links.linkURL(at: NSPoint(
            x: links.cellSize.width * 1.5, y: linkY))?.absoluteString
                == "https://example.com/a",
              "independent seam: OSC 8 link resolves at its cell")
        check(links.linkURL(at: NSPoint(
            x: links.cellSize.width * 8.5, y: linkY))?.absoluteString
                == "http://localhost:4173/x",
              "independent seam: localhost text link normalizes to HTTP")
        links.feed(text: "\r\nneedle\r\nother needle")
        drain()
        check(links.findNext("needle", options: .init())
                && links.searchStatus("needle", options: .init()).total == 2
                && links.findPrevious("needle", options: .init()),
              "independent seam: search enumerates and wraps across retained rows")
        links.clearSearch()
        check(links.selectedText().isEmpty,
              "independent seam: clearing search also clears selection")

        let firstHost = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 100))
        let secondHost = NSView(frame: firstHost.bounds)
        let firstWindow = NSWindow(
            contentRect: firstHost.bounds, styleMask: [.borderless],
            backing: .buffered, defer: false)
        let secondWindow = NSWindow(
            contentRect: secondHost.bounds, styleMask: [.borderless],
            backing: .buffered, defer: false)
        firstWindow.contentView = firstHost
        secondWindow.contentView = secondHost
        let moving = CmdyTerminalSurface(frame: firstHost.bounds)
        firstHost.addSubview(moving)
        let firstObserverCount = moving.windowObserverCountForTesting
        moving.removeFromSuperview()
        secondHost.addSubview(moving)
        check(firstObserverCount == 4 && moving.windowObserverCountForTesting == 4,
              "independent seam: window reparent replaces rather than accumulates observers")
        moving.removeFromSuperview()
        check(moving.windowObserverCountForTesting == 0,
              "independent seam: detaching removes all window observers")
        firstWindow.close()
        secondWindow.close()

        if MTLCreateSystemDefaultDevice() != nil {
            let renderLifecycle = CmdyTerminalSurface(frame: NSRect(
                x: 0, y: 0, width: 240, height: 100))
            do {
                try renderLifecycle.setUseMetal(true)
                try renderLifecycle.setUseMetal(true)
                let oneView = renderLifecycle.subviews.filter { $0 is MTKView }.count == 1
                renderLifecycle.terminate()
                check(oneView && renderLifecycle.metalView == nil
                        && renderLifecycle.metalRenderer == nil,
                      "independent seam: renderer enable is idempotent and teardown is immediate")
            } catch {
                check(false, "independent seam: Metal renderer initializes: \(error)")
            }
        }

        surface.terminate()
        input.terminate()
        selection.terminate()
        links.terminate()
        moving.terminate()
    }
}
