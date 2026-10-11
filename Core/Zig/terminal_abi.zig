//! The C ABI owns its call lifetime. Host callbacks may reenter or request
//! destruction; an outer call never resumes through a freed engine object.
const std = @import("std");
const terminal = @import("terminal.zig");
const unicode = @import("unicode.zig");
const a = std.heap.c_allocator;
pub const Status = enum(i32) { ok = 0, out_of_memory = 1, invalid_input = 2, disposed = 3, engine_error = 4 };
pub const Handle = struct {
    value: terminal.Terminal,
    call_depth: usize = 0,
    disposal_requested: bool = false,
    pub fn enter(h: *Handle) bool {
        if (h.disposal_requested) return false;
        h.call_depth += 1;
        return true;
    }
    pub fn leave(h: *Handle) void {
        std.debug.assert(h.call_depth > 0);
        h.call_depth -= 1;
        if (h.call_depth == 0 and h.disposal_requested) h.destroy();
    }
    fn destroy(h: *Handle) void {
        h.value.deinit();
        a.destroy(h);
    }
};
pub fn liveHandle(handle: ?*Handle) ?*Handle {
    const h = handle orelse return null;
    return if (h.disposal_requested) null else h;
}
fn status(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidInput => .invalid_input,
        else => .engine_error,
    };
}
fn input(comptime T: type, ptr: ?[*]const T, len: usize) error{InvalidInput}![]const T {
    if (len == 0) return &.{};
    return (ptr orelse return error.InvalidInput)[0..len];
}
pub export fn cmdy_zig_engine_abi_version() u32 {
    return 1;
}
pub export fn cmdy_zig_terminal_create(cols: isize, rows: isize, scrollback: isize) ?*Handle {
    const h = a.create(Handle) catch return null;
    const value = terminal.Terminal.init(a, cols, rows, scrollback) catch {
        a.destroy(h);
        return null;
    };
    h.* = .{ .value = value };
    return h;
}
pub export fn cmdy_zig_terminal_free(handle: ?*Handle) void {
    const h = handle orelse return;
    // Payload destructors can reenter while value.deinit() is still running.
    if (h.disposal_requested) return;
    h.disposal_requested = true;
    h.value.host = .{};
    h.value.parser_delegate = .{};
    if (h.call_depth == 0) h.destroy();
}
pub export fn cmdy_zig_terminal_set_host(handle: ?*Handle, host: ?*const terminal.Host) Status {
    const h = handle orelse return .invalid_input;
    if (h.disposal_requested) return .disposed;
    h.value.host = if (host) |v| v.* else .{};
    return .ok;
}
/// Changes delivery only; deliberately allocation-free and safe during callbacks.
pub export fn cmdy_zig_terminal_set_block_change_events(handle: ?*Handle, enabled: u8) Status {
    const h = handle orelse return .invalid_input;
    if (h.disposal_requested) return .disposed;
    h.value.block_change_events_enabled = enabled != 0;
    return .ok;
}
pub export fn cmdy_zig_terminal_set_parser_delegate(handle: ?*Handle, route: ?*const @import("parser_abi.zig").DelegateRoute) Status {
    const h = handle orelse return .invalid_input;
    if (h.disposal_requested) return .disposed;
    h.value.parser_delegate = if (route) |value| value.* else .{};
    return .ok;
}
pub export fn cmdy_zig_terminal_feed(handle: ?*Handle, bytes: ?[*]const u8, len: usize) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const data = input(u8, bytes, len) catch return .invalid_input;
    h.value.feed(data) catch |err| return status(err);
    return .ok;
}
pub export fn cmdy_zig_terminal_resize(handle: ?*Handle, cols: isize, rows: isize) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    h.value.resize(cols, rows) catch |err| return status(err);
    return .ok;
}
pub export fn cmdy_zig_terminal_host_message(handle: ?*Handle, bytes: ?[*]const u8, len: usize) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const data = input(u8, bytes, len) catch return .invalid_input;
    h.value.insertHostMessage(data) catch |err| return status(err);
    return .ok;
}
pub export fn cmdy_zig_terminal_scroll_viewport(handle: ?*Handle, row: isize) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    h.value.scrollViewport(row);
    return .ok;
}
const boolean_fields = [_][]const u8{ "is_alternate", "application_cursor_keys", "origin_mode", "auto_wrap", "insert_mode", "line_feed_mode", "cursor_hidden", "reverse_video", "bracketed_paste", "focus_reporting", "cursor_blink", "synchronized_updates", "allow_80_to_132", "margin_mode", "reverse_wraparound", "writing_host_message", "recording" };
pub export fn cmdy_zig_terminal_get_int(handle: ?*Handle, field: u32) isize {
    const h = liveHandle(handle) orelse return 0;
    const t = &h.value;
    inline for (boolean_fields, 1..) |name, key| if (field == key) return @intFromBool(@field(t, name));
    return switch (field) {
        18 => t.gl_level,
        19 => @intFromEnum(t.cursor_style),
        20 => @intFromEnum(t.mouse_mode),
        21 => @intFromEnum(t.mouse_protocol),
        22 => t.active_link_id,
        23 => t.keyboardFlags(),
        24 => t.blocks_dropped_checkpoint,
        25 => @intFromBool(t.parser.coalesces_printable_ascii),
        26 => @intFromBool(t.parser.decodes_contiguous_utf8),
        27 => @intFromBool(t.has_failed_command_provider),
        28 => if (t.print_state.lastPrintedScalar) |value| value else -1,
        29 => t.print_state.lastWrite.row,
        30 => t.print_state.lastWrite.x,
        31 => t.print_state.lastWrite.cols,
        32 => t.print_state.lastWrite.rows,
        33 => @intFromBool(t.print_state.noWrapParkedAfterPrint),
        34 => @intFromBool(t.print_state.pendingCursorUpMoved),
        35 => @intCast(t.protocol_state.links.entries.items.len),
        else => 0,
    };
}
pub export fn cmdy_zig_terminal_set_int(handle: ?*Handle, field: u32, value: isize) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const t = &h.value;
    if (field == 1) {
        t.setActiveBuffer(value != 0) catch |err| return status(err);
        return .ok;
    }
    inline for (boolean_fields, 1..) |name, key| if (field == key) {
        @field(t, name) = value != 0;
        return .ok;
    };
    switch (field) {
        18 => t.gl_level = std.math.cast(u8, value) orelse return .invalid_input,
        19 => t.cursor_style = std.meta.intToEnum(terminal.CursorShape, value) catch return .invalid_input,
        20 => t.mouse_mode = std.meta.intToEnum(terminal.MouseMode, value) catch return .invalid_input,
        21 => t.mouse_protocol = std.meta.intToEnum(terminal.MouseProtocol, value) catch return .invalid_input,
        22 => t.active_link_id = std.math.cast(u16, value) orelse return .invalid_input,
        24 => t.blocks_dropped_checkpoint = value,
        25 => t.parser.coalesces_printable_ascii = value != 0,
        26 => t.parser.decodes_contiguous_utf8 = value != 0,
        27 => t.has_failed_command_provider = value != 0,
        else => return .invalid_input,
    }
    return .ok;
}
pub export fn cmdy_zig_terminal_get_pen(handle: ?*Handle, out: ?*terminal.Cell) void {
    const destination = out orelse return;
    destination.* = if (liveHandle(handle)) |h| h.value.pen else .{};
}
pub export fn cmdy_zig_terminal_set_pen(handle: ?*Handle, value: ?*const terminal.Cell) Status {
    const h = handle orelse return .invalid_input;
    if (h.disposal_requested) return .disposed;
    h.value.pen = (value orelse return .invalid_input).*;
    return .ok;
}
pub export fn cmdy_zig_terminal_buffer(handle: ?*Handle, which: u32) ?*anyopaque {
    const h = liveHandle(handle) orelse return null;
    return switch (which) {
        0 => h.value.buffer(),
        1 => &h.value.normal,
        2 => &h.value.alternate,
        else => null,
    };
}
pub export fn cmdy_zig_terminal_parser(handle: ?*Handle) ?*anyopaque {
    return if (liveHandle(handle)) |h| &h.value.parser else null;
}
pub export fn cmdy_zig_terminal_blocks(handle: ?*Handle) ?*anyopaque {
    return if (liveHandle(handle)) |h| &h.value.blocks else null;
}
pub export fn cmdy_zig_terminal_graphics(handle: ?*Handle) ?*anyopaque {
    return if (liveHandle(handle)) |h| &h.value.protocol_state.kitty.store else null;
}
pub export fn cmdy_zig_terminal_dirty(handle: ?*Handle, consume: u8, out: ?*terminal.Span) u8 {
    const h = liveHandle(handle) orelse return 0;
    const span = h.value.dirty orelse return 0;
    if (out) |value| value.* = span;
    if (consume != 0) h.value.dirty = null;
    return 1;
}
pub export fn cmdy_zig_terminal_set_dirty(handle: ?*Handle, span: ?*const terminal.Span) void {
    const h = liveHandle(handle) orelse return;
    h.value.dirty = if (span) |v| v.* else null;
}
pub export fn cmdy_zig_terminal_mark_viewport(handle: ?*Handle) void {
    if (liveHandle(handle)) |h| h.value.markAllDirty();
}
pub export fn cmdy_zig_terminal_title(handle: ?*Handle, len: ?*usize) ?[*]const u8 {
    const h = liveHandle(handle);
    if (len) |out| out.* = if (h) |value| value.value.title.len else 0;
    return if (h) |value| value.value.title.ptr else null;
}
pub export fn cmdy_zig_terminal_set_title(handle: ?*Handle, bytes: ?[*]const u8, len: usize) Status {
    const h = handle orelse return .invalid_input;
    if (h.disposal_requested) return .disposed;
    const data = input(u8, bytes, len) catch return .invalid_input;
    const owned = a.dupe(u8, data) catch return .out_of_memory;
    a.free(h.value.title);
    h.value.title = owned;
    return .ok;
}
pub export fn cmdy_zig_terminal_link(handle: ?*Handle, id: u16, len: ?*usize) ?[*]const u8 {
    if (len) |out| out.* = 0;
    const h = liveHandle(handle) orelse return null;
    const uri = h.value.protocol_state.links.uri(id) orelse return null;
    if (len) |out| out.* = uri.len;
    return uri.ptr;
}
pub export fn cmdy_zig_terminal_decrqss(handle: ?*Handle, len: ?*usize) ?[*]const u8 {
    if (len) |out| out.* = 0;
    const h = liveHandle(handle) orelse return null;
    const bytes = h.value.protocol_state.decrqss.items;
    if (len) |out| out.* = bytes.len;
    return bytes.ptr;
}
pub export fn cmdy_zig_terminal_dispatch(handle: ?*Handle, operation: u32, argument: isize, params: ?[*]const isize, param_count: usize, collect: ?[*]const u8, collect_count: usize, bytes: ?[*]const u8, byte_count: usize) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const ps = input(isize, params, param_count) catch return .invalid_input;
    const cs = input(u8, collect, collect_count) catch return .invalid_input;
    const data = input(u8, bytes, byte_count) catch return .invalid_input;
    const t = &h.value;
    const result: anyerror!void = switch (operation) {
        1 => t.printScalar(std.math.cast(u32, argument) orelse return .invalid_input),
        2 => t.printASCII(data),
        3 => t.printASCIIAndCRLF(data),
        4 => t.printASCIILines(data),
        5 => t.execute(std.math.cast(u8, argument) orelse return .invalid_input),
        6 => t.csi(std.math.cast(u8, argument) orelse return .invalid_input, ps, cs),
        7 => t.esc(std.math.cast(u8, argument) orelse return .invalid_input, cs),
        8 => t.osc(argument, data),
        9 => t.dcsHook(std.math.cast(u8, argument) orelse return .invalid_input, ps, cs),
        10 => t.dcsPut(data),
        11 => t.dcsUnhook(),
        12 => t.apc(data),
        13 => t.fullReset(),
        14 => t.softReset(),
        15 => t.executeControl(std.math.cast(u8, argument) orelse return .invalid_input),
        16 => t.synchronizeBlockRowsToScrollback(),
        17 => t.sendResponse(data),
        18 => @import("dispatch.zig").esc(t, std.math.cast(u8, argument) orelse return .invalid_input, cs),
        else => return .invalid_input,
    };
    result catch |err| return status(err);
    return .ok;
}
pub export fn cmdy_zig_scalar_width(scalar: u32) i8 {
    return unicode.width(scalar);
}
pub export fn cmdy_zig_scalar_property(scalar: u32, property: u32) u8 {
    return @intFromBool(switch (property) {
        1 => scalar >= 0x1f1e6 and scalar <= 0x1f1ff,
        2 => @import("unicode_properties.zig").isAmbiguous(scalar),
        3 => @import("emoji.zig").isEmoji(scalar),
        else => false,
    });
}
pub export fn cmdy_zig_terminal_mouse(handle: ?*Handle, button: isize, pressed: u8, motion: u8, modifiers: isize, col: isize, row: isize, out: ?*u8) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    if (out) |value| value.* = 0;
    const reported = @import("terminal_support.zig").sendMouseEvent(&h.value, button, pressed != 0, motion != 0, modifiers, col, row) catch |err| return status(err);
    if (out) |value| value.* = @intFromBool(reported);
    return .ok;
}
pub export fn cmdy_zig_scalar_vs16_base(scalar: u32) u8 {
    return @intFromBool(unicode.isVS16Base(scalar));
}
