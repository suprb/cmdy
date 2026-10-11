// Compile together with an exact frozen Core/Sources/CmdyCore tree. This probe
// deliberately uses the production Swift engine without adapting its behavior.
import Foundation
import CryptoKit

private let null = NSNull()
private func optional<T>(_ value: T?) -> Any { value.map { $0 as Any } ?? null }
private func digest(_ bytes: some Sequence<UInt8>) -> String {
    SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
}
private func color(_ value: CellColor) -> Int {
    switch value {
    case .defaultColor: return 0
    case .defaultInverted: return 0x03000000
    case .ansi256(let n): return 0x01000000 | Int(n)
    case .trueColor(let r, let g, let b): return 0x02000000 | Int(r) << 16 | Int(g) << 8 | Int(b)
    }
}
private func attribute(_ value: CellAttribute) -> [Int] {
    [color(value.fg), color(value.bg), Int(value.style.rawValue), Int(value.underlineKind.rawValue), value.underlineColor.map(color) ?? -1]
}
private func cell(_ value: Cell) -> [Int] {
    [Int(value.scalar), Int(value.width)] + attribute(value.attribute) + [Int(value.linkId), value.clusterExtras?.count ?? -1] + (value.clusterExtras?.map(Int.init) ?? [])
}
private func cellDigest(_ cells: [[Int]]) -> String {
    var bytes = Data()
    for value in cells.joined() {
        var v = Int64(value).littleEndian
        withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
    }
    return digest(bytes)
}
private func payload(_ value: LineImage.Payload) -> [String: Any] {
    switch value {
    case .png(let bytes): return ["format": "png", "bytes": bytes.count, "sha256": digest(bytes)]
    case .rgba(let bytes, let width, let height): return ["format": "rgba", "bytes": bytes.count, "sha256": digest(bytes), "width": width, "height": height]
    }
}
private func lineImage(_ value: LineImage) -> [String: Any] {
    ["payload": payload(value.payload), "width": value.pixelWidth, "height": value.pixelHeight,
     "col": value.col, "kitty": value.kittyIsKitty, "image_id": optional(value.kittyImageId.map(Int.init)),
     "placement_id": optional(value.kittyPlacementId.map(Int.init)), "z": value.kittyZIndex,
     "offset_x": value.kittyPixelOffsetX, "offset_y": value.kittyPixelOffsetY]
}
private func row(_ line: Line, detailed: Bool) -> [String: Any] {
    let cells = line.cells.map(cell)
    let render: Int
    switch line.renderMode { case .single: render = 0; case .doubleWidth: render = 1; case .doubledTop: render = 2; case .doubledDown: render = 3 }
    var result: [String: Any] = ["count": cells.count, "sha256": cellDigest(cells), "wrapped": line.isWrapped,
        "wrap_style": line.wrapStyle == .cells ? 0 : 1, "render": render,
        "images_present": line.images != nil, "images": (line.images ?? []).map(lineImage)]
    if detailed { result["cells"] = cells }
    return result
}
private func buffer(_ b: ScreenBuffer, detailed: Bool) -> [String: Any] {
    var result: [String: Any] = ["cols": b.cols, "rows": b.rows, "x": b.x, "y": b.y,
        "y_base": b.yBase, "y_disp": b.yDisp, "dropped": b.droppedLines,
        "scroll_top": b.scrollTop, "scroll_bottom": b.scrollBottom, "margin_left": b.marginLeft,
        "margin_right": b.marginRight, "wrap_pending": b.wrapPending,
        "has_scrollback": b.hasScrollback, "max_scrollback": b.maxScrollback,
        "tabs": b.tabStops.sorted(), "lines": b.lines.map { row($0, detailed: detailed) }]
    if let s = b.savedCursor {
        result["saved"] = ["x": s.x, "y": s.y, "attribute": attribute(s.attribute), "wrap_pending": s.wrapPending,
            "origin_mode": s.originMode, "auto_wrap": s.autoWrap, "margin_mode": s.marginMode, "reverse_wraparound": s.reverseWraparound]
    } else { result["saved"] = null }
    return result
}
private func block(_ b: TerminalBlock) -> [String: Any] {
    ["index": b.index, "prompt_row": b.promptRow, "input_start": optional(b.inputStart.map { [$0.row, $0.col] }),
     "command_row": b.commandRow, "end_row": optional(b.endRow), "exit_code": optional(b.exitCode),
     "running": b.running, "started_at": b.startedAt, "finished_at": optional(b.finishedAt)]
}
private final class Host: CmdyTerminalDelegate {
    var events: [[String: Any]] = []
    func send(_ terminal: CmdyTerminal, data: ArraySlice<UInt8>) { events.append(["kind": "send", "bytes": Array(data)]) }
    func setTitle(_ terminal: CmdyTerminal, title: String) { events.append(["kind": "title", "bytes": Array(title.utf8)]) }
    func setCurrentDirectory(_ terminal: CmdyTerminal, directory: String?) { events.append(["kind": "directory", "bytes": optional(directory.map { Array($0.utf8) })]) }
    func bell(_ terminal: CmdyTerminal) { events.append(["kind": "bell"]) }
    // This only records a protocol request supplied by the test. No system
    // clipboard APIs or native application surfaces are touched.
    func clipboardCopy(_ terminal: CmdyTerminal, content: Data) { events.append(["kind": "clipboard_write", "bytes": Array(content)]) }
    func contentChanged(_ terminal: CmdyTerminal) { events.append(["kind": "content_changed"]) }
    func willReflow(_ terminal: CmdyTerminal) { events.append(["kind": "will_reflow"]) }
    func didReflow(_ terminal: CmdyTerminal) { events.append(["kind": "did_reflow"]) }
    func now(_ terminal: CmdyTerminal) -> Double { 1.25 }
    func notify(_ terminal: CmdyTerminal, title: String, body: String) { events.append(["kind": "notification", "title": Array(title.utf8), "body": Array(body.utf8)]) }
}
private final class ParserRecorder: VTParserDelegate {
    let host: Host
    init(_ host: Host) { self.host = host }
    private func emit(_ method: Int, _ argument: Int = 0, _ params: [Int] = [], _ collect: [UInt8] = [], _ bytes: [UInt8] = []) {
        host.events.append(["kind": "parser", "method": method, "argument": argument,
                            "params": params, "collect": collect, "bytes": bytes])
    }
    func parserPrint(_ scalar: UnicodeScalar) { emit(1, Int(scalar.value)) }
    func parserPrintASCII(_ bytes: ArraySlice<UInt8>) { emit(2, 0, [], [], Array(bytes)) }
    func parserPrintASCIIAndCRLF(_ bytes: ArraySlice<UInt8>) { emit(3, 0, [], [], Array(bytes)) }
    func parserPrintASCIILines(_ bytes: ArraySlice<UInt8>) { emit(4, 0, [], [], Array(bytes)) }
    func parserExecute(_ byte: UInt8) { emit(5, Int(byte)) }
    func parserCSI(final: UInt8, params: [Int], collect: [UInt8]) { emit(6, Int(final), params, collect) }
    func parserESC(final: UInt8, collect: [UInt8]) { emit(7, Int(final), [], collect) }
    func parserOSC(code: Int, payload: ArraySlice<UInt8>) { emit(8, code, [], [], Array(payload)) }
    func parserDCSHook(final: UInt8, params: [Int], collect: [UInt8]) { emit(9, Int(final), params, collect) }
    func parserDCSPut(_ bytes: ArraySlice<UInt8>) { emit(10, 0, [], [], Array(bytes)) }
    func parserDCSUnhook() { emit(11) }
    func parserAPC(_ bytes: ArraySlice<UInt8>) { emit(12, 0, [], [], Array(bytes)) }
}
private func parserState(_ state: VTParser.State) -> Int {
    switch state {
    case .ground: return 0
    case .escape: return 1
    case .escapeIntermediate: return 2
    case .csiEntry: return 3
    case .csiParam: return 4
    case .csiIntermediate: return 5
    case .csiIgnore: return 6
    case .oscString: return 7
    case .dcsEntry: return 8
    case .dcsParam: return 9
    case .dcsIntermediate: return 10
    case .dcsPassthrough: return 11
    case .dcsIgnore: return 12
    case .sosPmString: return 13
    case .apcString: return 14
    }
}
private func snapshot(_ t: CmdyTerminal, host: Host, detailed: Bool) -> [String: Any] {
    let cursor: Int
    switch t.cursorStyle { case .blinkBlock: cursor = 0; case .steadyBlock: cursor = 1; case .blinkUnderline: cursor = 2; case .steadyUnderline: cursor = 3; case .blinkBar: cursor = 4; case .steadyBar: cursor = 5 }
    let mouse: Int
    switch t.mouseMode { case .off: mouse = 0; case .x10: mouse = 1; case .vt200: mouse = 2; case .buttonEvent: mouse = 3; case .anyEvent: mouse = 4 }
    let encoding: Int
    switch t.mouseProtocol { case .x10: encoding = 0; case .utf8: encoding = 1; case .sgr: encoding = 2; case .urxvt: encoding = 3 }
    let damage = t.consumeDirtyRows()
    let placements: [[String: Any]] = t.kittyGraphics.placementsByKey.values.sorted {
        ($0.imageId, $0.placementId) < ($1.imageId, $1.placementId)
    }.map { p in
        ["image_id": Int(p.imageId), "placement_id": Int(p.placementId), "col": p.col, "row": p.row,
         "cols": p.cols, "rows": p.rows, "z": p.zIndex, "offset_x": p.pixelOffsetX, "offset_y": p.pixelOffsetY,
         "virtual": p.isVirtual, "alternate": p.isAlternateBuffer]
    }
    let images: [[String: Any]] = t.kittyGraphics.imagesById.values.sorted { $0.id < $1.id }.map { i in
        ["id": Int(i.id), "number": optional(i.number.map(Int.init)), "width": i.pixelWidth, "height": i.pixelHeight, "payload": payload(i.payload)]
    }
    let result: [String: Any] = [
        "normal": buffer(t.normalBuffer, detailed: detailed), "alternate": buffer(t.altBuffer, detailed: detailed),
        "is_alternate": t.isAlternateBuffer, "pen": attribute(t.currentAttribute),
        "modes": ["application_cursor_keys": t.applicationCursorKeys, "origin_mode": t.originMode,
            "auto_wrap": t.autoWrap, "insert_mode": t.insertMode, "line_feed_mode": t.lineFeedMode,
            "cursor_hidden": t.cursorHidden, "reverse_video": t.reverseVideo, "bracketed_paste": t.bracketedPaste,
            "focus_reporting": t.focusReporting, "cursor_blink": t.cursorBlink, "synchronized_updates": t.synchronizedUpdates,
            "allow_80_to_132": t.allow80To132, "margin_mode": t.marginMode, "reverse_wraparound": t.reverseWraparound],
        "cursor_style": cursor, "mouse_mode": mouse, "mouse_protocol": encoding,
        "keyboard_normal": t.kittyKeyboardStackNormal, "keyboard_alt": t.kittyKeyboardStackAlt,
        "title": Array(t.title.utf8), "title_stack": t.titleStack.map { Array($0.utf8) },
        "links": t.linkTable.map { Array($0.utf8) }, "active_link_id": Int(t.activeLinkId), "gl_level": t.glLevel,
        "blocks": t.blocks.blocks.map(block), "blocks_dropped_checkpoint": t.blocksDroppedLineCheckpoint,
        "dirty": optional(damage.map { [$0.lowerBound, $0.upperBound] }),
        "graphics": ["images": images, "placements": placements, "payload_bytes": t.kittyGraphics.payloadBytes,
            "next_image_id": Int(t.kittyGraphics.nextImageId), "next_placement_id": Int(t.kittyGraphics.nextPlacementId)],
        "parser_state": parserState(t.parser.state),
        "parser_options": [t.parser.coalescesPrintableASCII, t.parser.decodesContiguousUTF8,
                           t.parser.batchesOrdinaryUnicode, t.parser.coalescesCSIParameters],
        "events": host.events
    ]
    host.events.removeAll(keepingCapacity: true)
    return result
}

private struct Step: Decodable {
    var op: String
    var bytes: [UInt8]?
    var cols: Int?
    var rows: Int?
    var row: Int?
    var text: String?
    var checkpoint: Bool?
}
private struct Case: Decodable {
    var name: String
    var cols: Int
    var rows: Int
    var scrollback: Int
    var detailed: Bool?
    var parser_delegate: String?
    var parser_options: [Bool]?
    var steps: [Step]
}

// Native Host receives every OSC dispatch. The public Swift equivalent is an
// explicit handler registration for that selector. Register a conservative
// superset derived solely from input bytes: every integer token (including its
// optional sign) and the parser's invalid/overflow-selector fallback, zero.
// This covers any selector assembled across feed chunks without consulting
// candidate output, duplicating VT state transitions, or dropping callbacks.
private func observableOSCSelectors(_ request: Case) -> Set<Int> {
    let bytes = request.steps.flatMap { $0.bytes ?? [] }
    var result: Set<Int> = [0]
    var index = 0
    while index < bytes.count {
        guard bytes[index] >= 48, bytes[index] <= 57 else { index += 1; continue }
        let start = index
        while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 { index += 1 }
        if let value = Int(String(decoding: bytes[start..<index], as: UTF8.self)) { result.insert(value) }
        if start > 0, bytes[start - 1] == 43 || bytes[start - 1] == 45,
           let value = Int(String(decoding: bytes[(start - 1)..<index], as: UTF8.self)) { result.insert(value) }
    }
    return result
}

@main private enum Reference {
    static func main() throws {
        let requests = try JSONDecoder().decode([Case].self, from: FileHandle.standardInput.readDataToEndOfFile())
        for request in requests {
            let t = CmdyTerminal(cols: request.cols, rows: request.rows, scrollback: request.scrollback)
            let host = Host()
            let parserRecorder = ParserRecorder(host)
            defer { withExtendedLifetime(parserRecorder) {} }
            t.delegate = host
            if let mode = request.parser_delegate, mode != "owner" {
                precondition(mode == "custom" || mode == "nil")
                t.parser.delegate = mode == "custom" ? parserRecorder : nil
            }
            if let options = request.parser_options {
                precondition(options.count == 4)
                t.parser.coalescesPrintableASCII = options[0]
                t.parser.decodesContiguousUTF8 = options[1]
                t.parser.batchesOrdinaryUnicode = options[2]
                t.parser.coalescesCSIParameters = options[3]
            }
            for code in observableOSCSelectors(request) {
                t.registerOscHandler(code: code) { payload in
                    host.events.append(["kind": "osc", "code": code, "bytes": Array(payload)])
                }
            }
            t.blocks.onChange = { host.events.append(["kind": "blocks_changed"]) }
            t.blocks.onCommandFinished = { b in host.events.append(["kind": "command_finished", "index": b.index]) }
            var checkpoints: [[String: Any]] = [["step": -1, "state": snapshot(t, host: host, detailed: request.detailed ?? false)]]
            for (i, step) in request.steps.enumerated() {
                switch step.op {
                case "feed": t.feed(step.bytes ?? [])
                case "resize": t.resize(cols: step.cols!, rows: step.rows!)
                case "viewport": t.scrollViewport(to: step.row!)
                case "host_message": t.insertHostMessage(step.text ?? "")
                case "reset": t.fullReset()
                default: throw NSError(domain: "ZigEngineReference", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unknown operation: \(step.op)"])
                }
                if step.checkpoint ?? true { checkpoints.append(["step": i, "state": snapshot(t, host: host, detailed: request.detailed ?? false)]) }
            }
            let result: [String: Any] = ["name": request.name, "checkpoints": checkpoints]
            var bytes = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            bytes.append(10)
            FileHandle.standardOutput.write(bytes)
        }
    }
}
