import Foundation
import CmdyCore

// lib_cmdy — INTERNAL, UNRELEASED C ABI experiment over CmdyCore.
// It is not a public or supported integration surface and has no compatibility
// or binary-stability promise. The deliberately small spike proves the engine
// embeds cleanly: create/feed/read/resize/free + the blocks query.
//
// Handles are Unmanaged<CmdyTerminal> passed as opaque pointers. All
// calls are single-thread only (the engine's own rule).

private func terminal(_ handle: UnsafeMutableRawPointer?) -> CmdyTerminal? {
    guard let handle else { return nil }
    return Unmanaged<CmdyTerminal>.fromOpaque(handle).takeUnretainedValue()
}

private func validDimensions(_ cols: Int32, _ rows: Int32) -> Bool {
    guard cols > 0, rows > 0, cols <= 4_096, rows <= 4_096 else { return false }
    return Int64(cols) * Int64(rows) <= 4_000_000
}

@_cdecl("cmdy_create")
public func cmdy_create(_ cols: Int32, _ rows: Int32) -> UnsafeMutableRawPointer? {
    guard validDimensions(cols, rows) else { return nil }
    let term = CmdyTerminal(cols: Int(cols), rows: Int(rows))
    return Unmanaged.passRetained(term).toOpaque()
}

@_cdecl("cmdy_free")
public func cmdy_free(_ handle: UnsafeMutableRawPointer?) {
    guard let handle else { return }
    Unmanaged<CmdyTerminal>.fromOpaque(handle).release()
}

@_cdecl("cmdy_feed")
public func cmdy_feed(_ handle: UnsafeMutableRawPointer?,
                         _ bytes: UnsafePointer<UInt8>?, _ length: Int) {
    guard let term = terminal(handle), length >= 0 else { return }
    guard length > 0 else { return }
    guard let bytes else { return }
    let buffer = UnsafeBufferPointer(start: bytes, count: length)
    term.feed(Array(buffer))
}

@_cdecl("cmdy_resize")
public func cmdy_resize(_ handle: UnsafeMutableRawPointer?, _ cols: Int32, _ rows: Int32) {
    guard validDimensions(cols, rows), let term = terminal(handle) else { return }
    term.resize(cols: Int(cols), rows: Int(rows))
}

@_cdecl("cmdy_cols")
public func cmdy_cols(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.cols) } ?? -1
}

@_cdecl("cmdy_rows")
public func cmdy_rows(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.rows) } ?? -1
}

@_cdecl("cmdy_buffer_line_count")
public func cmdy_buffer_line_count(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.bufferLineCount) } ?? -1
}

@_cdecl("cmdy_cursor_row")
public func cmdy_cursor_row(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.scrollInvariantCursorRow) } ?? -1
}

@_cdecl("cmdy_cursor_col")
public func cmdy_cursor_col(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.cursorColumn) } ?? -1
}

@_cdecl("cmdy_live_top_row")
public func cmdy_live_top_row(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.liveScreenTopRow) } ?? -1
}

/// Copy row text (UTF-8, right-trimmed, NUL-terminated) into `out`.
/// Returns the byte length written (excluding NUL), or -1 for a bad row.
@_cdecl("cmdy_line_text")
public func cmdy_line_text(_ handle: UnsafeMutableRawPointer?, _ row: Int32,
                              _ out: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    guard capacity > 0 else { return -1 }   // no room for even the NUL
    guard let out, let text = terminal(handle)?.scrollbackLineText(row: Int(row))
    else { return -1 }
    let bytes = Array(text.utf8.prefix(max(0, capacity - 1)))
    for (i, b) in bytes.enumerated() { out[i] = CChar(bitPattern: b) }
    out[bytes.count] = 0
    return bytes.count
}

/// One cell, C-shaped: codepoint (0 = blank), display width (0 = wide-char
/// continuation), packed colors (0xTTRRGGBB / index; TT: 0 default, 1
/// indexed, 2 truecolor), and SGR style bits (the engine's raw byte).
@_cdecl("cmdy_cell")
public func cmdy_cell(_ handle: UnsafeMutableRawPointer?, _ row: Int32, _ col: Int32,
                         _ codepoint: UnsafeMutablePointer<UInt32>?,
                         _ width: UnsafeMutablePointer<Int32>?,
                         _ fg: UnsafeMutablePointer<UInt32>?,
                         _ bg: UnsafeMutablePointer<UInt32>?,
                         _ style: UnsafeMutablePointer<UInt32>?) -> Int32 {
    guard let term = terminal(handle), let codepoint, let width, let fg, let bg,
          let style else { return -1 }
    guard let line = term.lineForDiff(absolute: Int(row)),
          Int(col) >= 0, Int(col) < line.cells.count else { return -1 }
    let cell = line.cells[Int(col)]
    codepoint.pointee = cell.scalar
    width.pointee = Int32(cell.width)
    fg.pointee = packColor(cell.attribute.fg)
    bg.pointee = packColor(cell.attribute.bg)
    style.pointee = UInt32(cell.attribute.style.rawValue)
    return 0
}

private func packColor(_ color: CellColor) -> UInt32 {
    switch color {
    case .defaultColor: return 0
    case .defaultInverted: return 0x0300_0000
    case .ansi256(let index): return 0x0100_0000 | UInt32(index)
    case .trueColor(let r, let g, let b):
        return 0x0200_0000 | UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
    }
}

// MARK: - Blocks (the semantic feature, queryable from C)

@_cdecl("cmdy_block_count")
public func cmdy_block_count(_ handle: UnsafeMutableRawPointer?) -> Int32 {
    terminal(handle).map { Int32(clamping: $0.blocks.blocks.count) } ?? -1
}

/// Fill out one block's coordinates. exit_code is -1000 while running or
/// when the command exited without a code.
@_cdecl("cmdy_block_get")
public func cmdy_block_get(_ handle: UnsafeMutableRawPointer?, _ index: Int32,
                              _ promptRow: UnsafeMutablePointer<Int32>?,
                              _ commandRow: UnsafeMutablePointer<Int32>?,
                              _ endRow: UnsafeMutablePointer<Int32>?,
                              _ exitCode: UnsafeMutablePointer<Int32>?,
                              _ running: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let term = terminal(handle), let promptRow, let commandRow, let endRow,
          let exitCode, let running else { return -1 }
    let blocks = term.blocks.blocks
    guard Int(index) >= 0, Int(index) < blocks.count else { return -1 }
    let block = blocks[Int(index)]
    promptRow.pointee = Int32(clamping: block.promptRow)
    commandRow.pointee = Int32(clamping: block.commandRow)
    endRow.pointee = Int32(clamping: block.endRow ?? -1)
    exitCode.pointee = Int32(clamping: block.exitCode ?? -1000)
    running.pointee = block.running ? 1 : 0
    return 0
}
