//! C-shaped value and ownership bridge. All terminal state remains in Zig.
const std = @import("std");
const line_mod = @import("line.zig");
const row_mod = @import("row.zig");
const buffer_mod = @import("buffer.zig");
const graphics = @import("graphics.zig");
const Line = line_mod.Line;
const Buffer = buffer_mod.Buffer;
const Snapshot = @import("buffer_snapshot.zig").Snapshot;
const Cell = row_mod.Cell;
const Value = line_mod.Value;
const a = std.heap.c_allocator;
const LifetimeCallback = *const fn (?*anyopaque, u8) callconv(.c) void;
const Bridge = struct {
    context: *anyopaque,
    callback: LifetimeCallback,
    native_owned: bool = true,
    fn retained(context_ptr: *anyopaque, line: *Line) void {
        const bridge: *Bridge = @ptrCast(@alignCast(context_ptr));
        if (bridge.native_owned) return;
        bridge.native_owned = true;
        bridge.callback(bridge.context, 1);
        // The newly acquired native reference replaces the Swift-only one.
        _ = line.refs.fetchSub(1, .monotonic);
    }
    fn finalRelease(context_ptr: *anyopaque, line: *Line) bool {
        const bridge: *Bridge = @ptrCast(@alignCast(context_ptr));
        std.debug.assert(bridge.native_owned);
        bridge.native_owned = false;
        line.refs.store(1, .release);
        const callback = bridge.callback;
        const context = bridge.context;
        callback(context, 0);
        // callback may free bridge and line through Swift deinit.
        return true;
    }
};
fn status(value: anytype) i32 {
    value catch |err| return if (err == error.OutOfMemory) -2 else -1;
    return 0;
}
fn valueOf(cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8) !Value {
    if (present > 1 or (present == 0 and count != 0) or count > std.math.maxInt(u32) - 1 or (count != 0 and extras == null)) return error.InvalidInput;
    return .{ .cell = (cell orelse return error.InvalidInput).*, .extras = if (present == 0) null else if (count == 0) &.{} else extras.?[0..count] };
}
export fn cmdy_zig_line_create(cols: isize, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8) ?*Line {
    return Line.createValue(a, cols, valueOf(cell, extras, count, present) catch return null) catch null;
}
export fn cmdy_zig_line_retain(line: ?*Line) ?*Line {
    return if (line) |l| l.retain() else null;
}
export fn cmdy_zig_line_release(line: ?*Line) void {
    if (line) |l| l.release();
}
export fn cmdy_zig_line_clone(line: ?*const Line) ?*Line {
    return (line orelse return null).clone() catch null;
}
export fn cmdy_zig_line_snapshot(line: ?*const Line) ?*Line {
    return (line orelse return null).cloneSnapshot() catch null;
}
export fn cmdy_zig_line_render_snapshot(line: ?*const Line) ?*Line {
    return (line orelse return null).renderSnapshot() catch null;
}
export fn cmdy_zig_buffer_snapshot_capture(buffer: ?*const Buffer, first: isize, count: usize, result_status: ?*i32) ?*Snapshot {
    if (result_status) |out| out.* = -1;
    const source = buffer orelse return null;
    const value = Snapshot.capture(a, source, first, count) catch |err| {
        if (result_status) |out| out.* = if (err == error.OutOfMemory) -2 else -1;
        return null;
    };
    if (result_status) |out| out.* = 0;
    return value;
}
export fn cmdy_zig_buffer_snapshot_retain(value: ?*Snapshot) ?*Snapshot {
    return if (value) |snapshot| snapshot.retain() else null;
}
export fn cmdy_zig_buffer_snapshot_release(value: ?*Snapshot) void {
    if (value) |snapshot| snapshot.release();
}
export fn cmdy_zig_buffer_snapshot_count(value: ?*const Snapshot) usize {
    return if (value) |snapshot| snapshot.lines.len else 0;
}
export fn cmdy_zig_buffer_snapshot_first(value: ?*const Snapshot) isize {
    return if (value) |snapshot| snapshot.first else 0;
}
export fn cmdy_zig_buffer_snapshot_line(value: ?*const Snapshot, index: usize) ?*const Line {
    return (value orelse return null).line(index);
}
export fn cmdy_zig_line_snapshot_from_cells(cells: ?[*]const row_mod.StoredCell, count: usize, extras: ?[*]const u32, extra_count: usize, wrapped: u8, render_mode: u8, revision: u64) ?*Line {
    if ((count != 0 and cells == null) or (extra_count != 0 and extras == null) or wrapped > 1) return null;
    const mode = std.meta.intToEnum(line_mod.RenderMode, render_mode) catch return null;
    return Line.snapshotFromCells(a, if (count == 0) &.{} else cells.?[0..count], if (extra_count == 0) &.{} else extras.?[0..extra_count], wrapped != 0, mode, revision) catch null;
}
export fn cmdy_zig_line_identity(line: ?*const Line) u64 {
    return (line orelse return 0).identity;
}
export fn cmdy_zig_line_version(line: ?*const Line) u64 {
    return (line orelse return 0).version();
}
export fn cmdy_zig_line_count(line: ?*const Line) isize {
    return (line orelse return 0).count();
}
export fn cmdy_zig_line_swift_context(line: ?*const Line) ?*anyopaque {
    const observer = (line orelse return null).lifetime_observer orelse return null;
    const bridge: *Bridge = @ptrCast(@alignCast(observer.context));
    return bridge.context;
}
export fn cmdy_zig_line_associate(line: ?*Line, context: ?*anyopaque, callback: ?LifetimeCallback) i32 {
    const l = line orelse return -1;
    if (l.lifetime_observer != null or context == null or callback == null) return -1;
    const bridge = l.allocator.create(Bridge) catch return -2;
    bridge.* = .{ .context = context.?, .callback = callback.? };
    l.lifetime_observer = .{ .context = bridge, .retained = Bridge.retained, .final_release = Bridge.finalRelease };
    return 0;
}
export fn cmdy_zig_line_disassociate(line: ?*Line, context: ?*anyopaque) i32 {
    const l = line orelse return -1;
    const observer = l.lifetime_observer orelse return -1;
    const bridge: *Bridge = @ptrCast(@alignCast(observer.context));
    if (context != bridge.context or bridge.native_owned) return -1;
    l.lifetime_observer = null;
    l.allocator.destroy(bridge);
    return 0;
}
export fn cmdy_zig_line_touch(line: ?*Line) void {
    if (line) |l| l.touch();
}
export fn cmdy_zig_line_metadata(line: ?*const Line, field: u32) i32 {
    const l = line orelse return -1;
    return switch (field) {
        0 => @intFromBool(l.is_wrapped),
        1 => @intFromEnum(l.wrap_style),
        2 => @intFromEnum(l.render_mode),
        else => -1,
    };
}
export fn cmdy_zig_line_set_metadata(line: ?*Line, field: u32, value: i32) i32 {
    const l = line orelse return -1;
    switch (field) {
        0 => l.setWrapped(value != 0),
        1 => {
            if (value < 0 or value > 1) return -1;
            l.wrap_style = @enumFromInt(value);
        },
        2 => {
            if (value < 0 or value > 3) return -1;
            l.setRenderMode(@enumFromInt(value));
        },
        else => return -1,
    }
    return 0;
}
export fn cmdy_zig_line_read(line: ?*const Line, col: isize, cell: ?*Cell, extras: ?*?[*]const u32, count: ?*usize, present: ?*u8) i32 {
    const l = line orelse return -1;
    if (cell == null or extras == null or count == null or present == null) return -1;
    const value = l.get(col);
    cell.?.* = value.cell;
    extras.?.* = if (value.extras) |v| if (v.len > 0) v.ptr else null else null;
    count.?.* = if (value.extras) |v| v.len else 0;
    present.?.* = @intFromBool(value.extras != null);
    return 0;
}
export fn cmdy_zig_line_set(line: ?*Line, col: isize, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8) i32 {
    return status((line orelse return -1).set(col, valueOf(cell, extras, count, present) catch return -1));
}
export fn cmdy_zig_line_fill(line: ?*Line, start: isize, end: isize, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8) i32 {
    return status((line orelse return -1).fill(valueOf(cell, extras, count, present) catch return -1, start, end));
}
export fn cmdy_zig_line_resize(line: ?*Line, cols: isize, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8) i32 {
    const l = line orelse return -1;
    if (cols < 0) return -1;
    const value = valueOf(cell, extras, count, present) catch return -1;
    return status(l.resizeValue(cols, value));
}
export fn cmdy_zig_line_reset(line: ?*Line, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8, wrapped: u8) i32 {
    return status((line orelse return -1).resetValue(valueOf(cell, extras, count, present) catch return -1, wrapped != 0));
}
export fn cmdy_zig_line_reset_metadata(line: ?*Line, wrapped: u8) void {
    if (line) |l| l.resetMetadata(wrapped != 0);
}
export fn cmdy_zig_line_write_ascii(line: ?*Line, col: isize, bytes: ?[*]const u8, count: usize, pen: ?*const Cell) i32 {
    if (count > 0 and bytes == null) return -1;
    return status((line orelse return -1).writeASCII(if (count == 0) &.{} else bytes.?[0..count], col, (pen orelse return -1).*));
}
export fn cmdy_zig_line_write_unicode(line: ?*Line, col: isize, values: ?[*]const row_mod.Scalar, count: usize, pen: ?*const Cell, stub: ?*const Cell) i32 {
    const l = line orelse return -1;
    if (col < 0 or (count != 0 and values == null)) return -1;
    return status(l.writeOrdinaryUnicode(if (count == 0) &.{} else values.?[0..count], col, (pen orelse return -1).*, (stub orelse return -1).*));
}
export fn cmdy_zig_line_append_scalar(line: ?*Line, col: isize, scalar: u32, width: i8) i32 {
    return status((line orelse return -1).appendClusterScalar(scalar, col, width));
}
export fn cmdy_zig_line_edit(line: ?*Line, col: isize, n: isize, right: isize, insert: u8, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8) i32 {
    const l = line orelse return -1;
    const value = valueOf(cell, extras, count, present) catch return -1;
    return status(if (insert != 0) l.insertCells(col, n, right, value) else l.deleteCells(col, n, right, value));
}
export fn cmdy_zig_line_copy_columns(line: ?*Line, source: ?*const Line, first: isize, last: isize) i32 {
    const l = line orelse return -1;
    const old = l.version();
    l.copyColumns(source orelse return -1, first, last) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    if (l.version() == old) l.touch(); // Public Swift copyColumns always invalidates.
    return 0;
}
export fn cmdy_zig_line_used_length(line: ?*const Line, width: u8) isize {
    const l = line orelse return 0;
    return if (width != 0) l.trimmedLength() else l.usedLength();
}
export fn cmdy_zig_line_prepare_read(line: ?*Line) i32 {
    return status((line orelse return -1).row.materialize());
}
export fn cmdy_zig_line_cells(line: ?*const Line, count: ?*usize) ?[*]const row_mod.StoredCell {
    const out = count orelse return null;
    out.* = 0;
    const l = line orelse return null;
    if (l.row.deferred != null or l.row.isCompact()) return null;
    out.* = l.row.storage.cells.len;
    return if (out.* == 0) null else l.row.storage.cells.ptr;
}
export fn cmdy_zig_line_extras(line: ?*const Line, count: ?*usize) ?[*]const u32 {
    const out = count orelse return null;
    out.* = 0;
    const l = line orelse return null;
    out.* = l.row.storage.extras.items.len;
    return if (out.* == 0) null else l.row.storage.extras.items.ptr;
}
export fn cmdy_zig_line_image_count(line: ?*const Line) isize {
    return if ((line orelse return -1).images) |images| @intCast(images.items.len) else -1;
}
export fn cmdy_zig_line_image_get(line: ?*const Line, index: usize) ?*graphics.LineImage {
    const images = (line orelse return null).images orelse return null;
    return if (index < images.items.len) images.items[index].clone() else null;
}
fn imageList(l: *Line, input: ?[*]const ?*graphics.LineImage, count: usize, present: u8) !?std.ArrayList(*graphics.LineImage) {
    if (present > 1 or (present == 0 and count != 0) or (count > 0 and input == null)) return error.InvalidInput;
    if (present == 0) return null;
    var list: std.ArrayList(*graphics.LineImage) = .empty;
    errdefer {
        for (list.items) |image| image.deinit();
        list.deinit(l.allocator);
    }
    try list.ensureTotalCapacity(l.allocator, count);
    for (0..count) |i| list.appendAssumeCapacity((input.?[i] orelse return error.InvalidInput).clone());
    return list;
}
export fn cmdy_zig_line_set_images(line: ?*Line, images: ?[*]const ?*graphics.LineImage, count: usize, present: u8) i32 {
    const l = line orelse return -1;
    const replacement = imageList(l, images, count, present) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    const previous = l.images;
    l.images = replacement;
    l.touch();
    if (previous) |old| {
        var owned = old;
        for (owned.items) |image| image.deinit();
        owned.deinit(l.allocator);
    }
    return 0;
}

export fn cmdy_zig_buffer_create(cols: isize, rows: isize, history: u8, cap: isize) ?*Buffer {
    const b = a.create(Buffer) catch return null;
    b.* = Buffer.init(a, cols, rows, history != 0, cap) catch {
        a.destroy(b);
        return null;
    };
    return b;
}
export fn cmdy_zig_buffer_free(buffer: ?*Buffer) void {
    if (buffer) |b| {
        b.deinit();
        a.destroy(b);
    }
}
export fn cmdy_zig_buffer_compact_history(buffer: ?*Buffer, absolute_start: isize, maximum_rows: usize, output: ?*Buffer.HistoryMaintenance) i32 {
    const result = output orelse return -1;
    const value = buffer orelse return -1;
    result.* = value.compactHistory(absolute_start, maximum_rows);
    return 0;
}
export fn cmdy_zig_buffer_get(buffer: ?*const Buffer, field: u32) isize {
    const b = buffer orelse return 0;
    return switch (field) {
        0 => b.x,
        1 => b.y,
        2 => b.y_base,
        3 => b.y_disp,
        4 => b.cols,
        5 => b.rows,
        6 => b.max_scrollback,
        7 => b.scroll_top,
        8 => b.scroll_bottom,
        9 => b.margin_left,
        10 => b.margin_right,
        11 => @intFromBool(b.wrap_pending),
        12 => b.dropped_lines,
        13 => @intFromBool(b.has_scrollback),
        14 => b.lineCount(),
        15 => @intCast(b.storage.items.len),
        16 => @intCast(b.line_start),
        else => 0,
    };
}
export fn cmdy_zig_buffer_set(buffer: ?*Buffer, field: u32, value: isize) i32 {
    const b = buffer orelse return -1;
    switch (field) {
        0 => b.x = value,
        1 => b.y = value,
        2 => b.y_base = value,
        3 => b.y_disp = value,
        6 => b.max_scrollback = value,
        7 => b.scroll_top = value,
        8 => b.scroll_bottom = value,
        9 => b.margin_left = value,
        10 => b.margin_right = value,
        11 => b.wrap_pending = value != 0,
        else => return -1,
    }
    return 0;
}
export fn cmdy_zig_buffer_line(buffer: ?*const Buffer, absolute: isize) ?*Line {
    return ((buffer orelse return null).line(absolute) orelse return null).retain();
}
export fn cmdy_zig_buffer_ghost_line(buffer: ?*Buffer, absolute: isize) ?*Line {
    return (((buffer orelse return null).lineAutovivified(absolute) catch return null) orelse return null).retain();
}
export fn cmdy_zig_buffer_ghost_keys(buffer: ?*const Buffer, out: ?[*]isize, capacity: usize) isize {
    const b = buffer orelse return -1;
    const count = b.overflow_lines.count();
    if (out != null and capacity >= count) {
        var iterator = b.overflow_lines.keyIterator();
        var index: usize = 0;
        while (iterator.next()) |key| {
            out.?[index] = key.*;
            index += 1;
        }
    }
    return @intCast(count);
}
export fn cmdy_zig_buffer_clear_ghosts(buffer: ?*Buffer) void {
    if (buffer) |b| b.clearOverflowLines();
}
pub const SavedCursor = extern struct { x: isize = 0, y: isize = 0, attribute: Cell = .{}, wrap_pending: u8 = 0, origin_mode: u8 = 0, auto_wrap: u8 = 0, margin_mode: u8 = 0, reverse_wraparound: u8 = 0 };
export fn cmdy_zig_buffer_saved_cursor(buffer: ?*const Buffer, out: ?*SavedCursor) i32 {
    const cursor = (buffer orelse return -1).saved_cursor orelse return 0;
    (out orelse return -1).* = .{ .x = cursor.x, .y = cursor.y, .attribute = cursor.attribute, .wrap_pending = @intFromBool(cursor.wrap_pending), .origin_mode = @intFromBool(cursor.origin_mode), .auto_wrap = @intFromBool(cursor.auto_wrap), .margin_mode = @intFromBool(cursor.margin_mode), .reverse_wraparound = @intFromBool(cursor.reverse_wraparound) };
    return 1;
}
export fn cmdy_zig_buffer_set_saved_cursor(buffer: ?*Buffer, input: ?*const SavedCursor) i32 {
    const b = buffer orelse return -1;
    const v = input orelse {
        b.saved_cursor = null;
        return 0;
    };
    b.saved_cursor = .{ .x = v.x, .y = v.y, .attribute = v.attribute, .wrap_pending = v.wrap_pending != 0, .origin_mode = v.origin_mode != 0, .auto_wrap = v.auto_wrap != 0, .margin_mode = v.margin_mode != 0, .reverse_wraparound = v.reverse_wraparound != 0 };
    return 0;
}
export fn cmdy_zig_buffer_tab_stops(buffer: ?*const Buffer, out: ?[*]isize, capacity: usize) isize {
    const b = buffer orelse return -1;
    const count = b.tab_stops.count();
    if (out != null and capacity >= count) {
        var it = b.tab_stops.keyIterator();
        var i: usize = 0;
        while (it.next()) |key| {
            out.?[i] = key.*;
            i += 1;
        }
    }
    return @intCast(count);
}
export fn cmdy_zig_buffer_reset_tabs(buffer: ?*Buffer) i32 {
    return status((buffer orelse return -1).resetTabStops());
}
export fn cmdy_zig_buffer_set_tab(buffer: ?*Buffer, col: isize) i32 {
    return status((buffer orelse return -1).setTabStop(col));
}
export fn cmdy_zig_buffer_clear_tab(buffer: ?*Buffer, col: isize) void {
    if (buffer) |b| b.clearTabStop(col);
}
export fn cmdy_zig_buffer_clear_tabs(buffer: ?*Buffer) void {
    if (buffer) |b| b.clearAllTabStops();
}
export fn cmdy_zig_buffer_next_tab(buffer: ?*const Buffer, col: isize, margin: u8) isize {
    return (buffer orelse return 0).nextTabStop(col, margin != 0);
}
export fn cmdy_zig_buffer_previous_tab(buffer: ?*const Buffer, col: isize) isize {
    return (buffer orelse return 0).previousTabStop(col);
}
export fn cmdy_zig_buffer_scroll(buffer: ?*Buffer, operation: u32, at: isize, n: isize, cell: ?*const Cell, extras: ?[*]const u32, count: usize, present: u8, wrapped: u8, clear: u8) i32 {
    const b = buffer orelse return -1;
    const value = valueOf(cell, extras, count, present) catch return -1;
    return status(switch (operation) {
        0 => b.scrollUpValue(value, wrapped != 0, clear != 0),
        1 => b.scrollUpRegionOnlyValue(value),
        2 => b.scrollDownValue(value),
        3 => b.insertLinesValue(at, n, value),
        4 => b.deleteLinesValue(at, n, value),
        else => return -1,
    });
}
export fn cmdy_zig_buffer_resize(buffer: ?*Buffer, cols: isize, rows: isize) i32 {
    return status((buffer orelse return -1).resizeSimple(cols, rows, .{}));
}
export fn cmdy_zig_buffer_reset(buffer: ?*Buffer) i32 {
    return status((buffer orelse return -1).hardReset());
}
export fn cmdy_zig_buffer_clear_scrollback(buffer: ?*Buffer) void {
    if (buffer) |b| b.clearScrollback();
}
export fn cmdy_zig_buffer_append_line(buffer: ?*Buffer, line: ?*Line) i32 {
    const b = buffer orelse return -1;
    const l = (line orelse return -1).retain();
    b.appendFullScreenScrollbackLine(l) catch |err| {
        l.release();
        return if (err == error.OutOfMemory) -2 else -1;
    };
    return 0;
}
fn ownedLines(buffer: *Buffer, input: ?[*]const ?*Line, count: usize) !std.ArrayList(?*Line) {
    if (count > 0 and input == null) return error.InvalidInput;
    var result: std.ArrayList(?*Line) = .empty;
    errdefer {
        for (result.items) |line| line.?.release();
        result.deinit(buffer.allocator);
    }
    try result.ensureTotalCapacity(buffer.allocator, count);
    for (0..count) |i| result.appendAssumeCapacity((input.?[i] orelse return error.InvalidInput).retain());
    return result;
}
export fn cmdy_zig_buffer_replace_lines(buffer: ?*Buffer, input: ?[*]const ?*Line, count: usize) i32 {
    const b = buffer orelse return -1;
    const replacement = ownedLines(b, input, count) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    var old = b.storage;
    const start = b.line_start;
    b.storage = replacement;
    b.line_start = 0;
    for (old.items[start..]) |line| line.?.release();
    old.deinit(b.allocator);
    return 0;
}
export fn cmdy_zig_buffer_set_geometry(buffer: ?*Buffer, cols: isize, rows: isize) i32 {
    const b = buffer orelse return -1;
    if (cols < 0 or rows < 0) return -1;
    b.cols = cols;
    b.rows = rows;
    return 0;
}
export fn cmdy_zig_buffer_note_dropped(buffer: ?*Buffer, n: isize) void {
    if (buffer) |b| {
        if (n > 0) b.dropped_lines +|= n;
    }
}
export fn cmdy_zig_buffer_replace_content(buffer: ?*Buffer, input: ?[*]const ?*Line, count: usize, base: isize, disp: isize, x: isize, y: isize, cols: isize, rows: isize, dropped: isize) i32 {
    const b = buffer orelse return -1;
    var lines = ownedLines(b, input, count) catch |err| return if (err == error.OutOfMemory) -2 else -1;
    defer {
        for (lines.items) |line| line.?.release();
        lines.deinit(b.allocator);
    }
    return status(b.replaceContent(&lines, base, disp, x, y, cols, rows, dropped));
}

const TestBridgeContext = struct {
    line: *Line,
    transfers: usize = 0,
    readoptions: usize = 0,
    free_on_transfer: bool = false,
    fn callback(context: ?*anyopaque, event: u8) callconv(.c) void {
        const self: *TestBridgeContext = @ptrCast(@alignCast(context.?));
        if (event == 0) {
            self.transfers += 1;
            if (self.free_on_transfer) {
                std.debug.assert(cmdy_zig_line_disassociate(self.line, self) == 0);
                self.line.release();
            }
        } else self.readoptions += 1;
    }
};

test "associated line transfers ownership without a retained-wrapper cycle" {
    const line = try Line.create(std.testing.allocator, 2, .{});
    var context = TestBridgeContext{ .line = line };
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_associate(line, &context, TestBridgeContext.callback));
    line.release();
    try std.testing.expectEqual(@as(usize, 1), context.transfers);
    try std.testing.expectEqual(@as(usize, 1), line.refs.load(.acquire));
    try std.testing.expectEqual(@as(?*anyopaque, &context), cmdy_zig_line_swift_context(line));
    for (0..20) |_| {
        _ = line.retain();
        try std.testing.expectEqual(@as(usize, 1), line.refs.load(.acquire));
        _ = line.retain();
        try std.testing.expectEqual(@as(usize, 2), line.refs.load(.acquire));
        line.release();
        line.release();
    }
    try std.testing.expectEqual(@as(usize, 20), context.readoptions);
    try std.testing.expectEqual(@as(usize, 21), context.transfers);
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_disassociate(line, &context));
    line.release();
}

test "final native release permits synchronous wrapper and line destruction" {
    const line = try Line.create(std.testing.allocator, 2, .{});
    var context = TestBridgeContext{ .line = line, .free_on_transfer = true };
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_associate(line, &context, TestBridgeContext.callback));
    line.release();
    try std.testing.expectEqual(@as(usize, 1), context.transfers);
}

test "line C bridge preserves empty extras, aliased resize values and retained snapshots" {
    const line = try Line.create(std.testing.allocator, 2, .{});
    defer line.release();
    const cell = Cell{ .scalar = 101 };
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_set(line, 0, &cell, null, 0, 1));
    const extras = [_]u32{ 0x301, 0x302 };
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_set(line, 1, &cell, &extras, extras.len, 1));
    const copy = cmdy_zig_line_clone(line).?;
    defer copy.release();
    var value: Cell = undefined;
    var pointer: ?[*]const u32 = null;
    var count: usize = 0;
    var present: u8 = 0;
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_read(line, 1, &value, &pointer, &count, &present));
    try std.testing.expectEqual(@as(i32, 0), cmdy_zig_line_resize(line, 5, &value, pointer, count, present));
    try std.testing.expectEqual(@as(isize, 2), copy.count());
    try std.testing.expectEqualSlices(u32, &extras, line.get(4).extras.?);
    try std.testing.expectEqual(@as(usize, 0), copy.get(0).extras.?.len);
    try std.testing.expectEqualSlices(u32, &extras, copy.get(1).extras.?);
    try std.testing.expectEqual(@as(i32, -1), cmdy_zig_line_set(line, 0, &cell, null, 1, 1));
    try std.testing.expectEqual(@as(i32, -1), cmdy_zig_line_associate(line, null, TestBridgeContext.callback));
}

test "fresh line publishes the last issued global version" {
    const target = try Line.create(std.testing.allocator, 2, .{});
    defer target.release();
    const witness = try Line.create(std.testing.allocator, 1, .{});
    const next = witness.version() + 1;
    witness.release();
    try target.setCell(0, .{ .scalar = 65 });
    try std.testing.expectEqual(next, target.version());
}
