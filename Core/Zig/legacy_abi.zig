//! Compatibility exports for the original internal lib_cmdy interface.
const std = @import("std");
const abi = @import("terminal_abi.zig");
const Handle = abi.Handle;
fn validDimensions(cols: i32, rows: i32) bool {
    return cols > 0 and rows > 0 and cols <= 4096 and rows <= 4096 and @as(i64, cols) * rows <= 4_000_000;
}
fn i32clamp(value: isize) i32 {
    return @intCast(std.math.clamp(value, std.math.minInt(i32), std.math.maxInt(i32)));
}
pub export fn cmdy_create(cols: i32, rows: i32) ?*Handle {
    if (!validDimensions(cols, rows)) return null;
    return abi.cmdy_zig_terminal_create(cols, rows, 10_000);
}
pub export fn cmdy_free(handle: ?*Handle) void {
    abi.cmdy_zig_terminal_free(handle);
}
pub export fn cmdy_feed(handle: ?*Handle, bytes: ?[*]const u8, len: isize) void {
    if (len <= 0 or bytes == null) return;
    _ = abi.cmdy_zig_terminal_feed(handle, bytes, @intCast(len));
}
pub export fn cmdy_resize(handle: ?*Handle, cols: i32, rows: i32) void {
    if (validDimensions(cols, rows)) _ = abi.cmdy_zig_terminal_resize(handle, cols, rows);
}
pub export fn cmdy_cols(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| i32clamp(h.value.buffer().cols) else -1;
}
pub export fn cmdy_rows(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| i32clamp(h.value.buffer().rows) else -1;
}
pub export fn cmdy_buffer_line_count(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| i32clamp(h.value.buffer().lineCount()) else -1;
}
pub export fn cmdy_cursor_row(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| i32clamp(h.value.buffer().y_base + h.value.buffer().y) else -1;
}
pub export fn cmdy_cursor_col(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| i32clamp(h.value.buffer().x) else -1;
}
pub export fn cmdy_live_top_row(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| i32clamp(h.value.buffer().y_base) else -1;
}
pub export fn cmdy_line_text(handle: ?*Handle, row: i32, out: ?[*]u8, capacity: isize) isize {
    const h = abi.liveHandle(handle) orelse return -1;
    const destination = out orelse return -1;
    if (capacity <= 0) return -1;
    const line = h.value.buffer().line(row) orelse return -1;
    const text = line.trimmedText(h.value.allocator) catch return -1;
    defer h.value.allocator.free(text);
    const count = @min(text.len, @as(usize, @intCast(capacity - 1)));
    @memcpy(destination[0..count], text[0..count]);
    destination[count] = 0;
    return @intCast(count);
}
pub export fn cmdy_cell(handle: ?*Handle, row: i32, col: i32, scalar: ?*u32, width: ?*i32, fg: ?*u32, bg: ?*u32, style: ?*u32) i32 {
    const h = abi.liveHandle(handle) orelse return -1;
    if (scalar == null or width == null or fg == null or bg == null or style == null) return -1;
    const line = h.value.buffer().line(row) orelse return -1;
    if (col < 0 or col >= line.count()) return -1;
    const cell = line.cell(col);
    scalar.?.* = cell.scalar;
    width.?.* = cell.width;
    fg.?.* = cell.fg;
    bg.?.* = cell.bg;
    style.?.* = cell.style;
    return 0;
}
pub export fn cmdy_block_count(handle: ?*Handle) i32 {
    return if (abi.liveHandle(handle)) |h| @intCast(@min(h.value.blocks.blocks.items.len, std.math.maxInt(i32))) else -1;
}
pub export fn cmdy_block_get(handle: ?*Handle, index: i32, prompt: ?*i32, command: ?*i32, end: ?*i32, exit: ?*i32, running: ?*i32) i32 {
    const h = abi.liveHandle(handle) orelse return -1;
    if (prompt == null or command == null or end == null or exit == null or running == null or
        index < 0 or index >= h.value.blocks.blocks.items.len) return -1;
    const block = h.value.blocks.blocks.items[@intCast(index)];
    prompt.?.* = i32clamp(block.prompt_row);
    command.?.* = i32clamp(block.command_row);
    end.?.* = i32clamp(block.end_row orelse -1);
    exit.?.* = i32clamp(block.exit_code orelse -1000);
    running.?.* = @intFromBool(block.running);
    return 0;
}
