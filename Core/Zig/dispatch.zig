//! Native CSI/ESC command semantics, ported from CMDY's TerminalDispatch.swift.
//! Geometry, command-specific quirks and cluster-owner witness boundaries stay
//! explicit: moving a cell and moving its continuation owner are separate acts.
const std = @import("std");
const rows = @import("row.zig");
const buffers = @import("buffer.zig");
const printing = @import("printing.zig");
const modes = @import("modes.zig");
const protocols = @import("terminal_protocols.zig");
const Cell = rows.Cell;
const Value = rows.Row.Value;
const Bounds = printing.Bounds;
const OwnedCell = printing.OwnedCell;
const Coordinate = printing.Coordinate;
const Attributes = std.AutoHashMapUnmanaged(Coordinate, Cell);
const Contents = std.AutoHashMapUnmanaged(Coordinate, OwnedCell);
const Region = struct { rows: Bounds, columns: Bounds };

pub fn param(params: []const isize, index: usize, default: isize) isize {
    if (index >= params.len or params[index] == 0) return default;
    return params[index];
}
fn first(params: []const isize) isize { return if (params.len > 0) params[0] else 0; }
fn marker(collect: []const u8, value: u8) bool { return collect.len > 0 and collect[0] == value; }

pub fn csi(t: anytype, final: u8, raw: []const isize, collect: []const u8) anyerror!void {
    var stack: [257]isize = undefined;
    var allocated: ?[]isize = null;
    defer if (allocated) |values| t.allocator.free(values);
    var params = raw;
    if (final != 'm' and std.mem.indexOfScalar(isize, raw, -1) != null) {
        var filtered: []isize = if (raw.len <= stack.len) stack[0..raw.len] else blk: {
            allocated = try t.allocator.alloc(isize, raw.len);
            break :blk allocated.?;
        };
        var count: usize = 0;
        for (raw) |p| if (p != -1) { filtered[count] = p; count += 1; };
        params = filtered[0..count];
    }
    const private = marker(collect, '?');
    const b = t.buffer();
    switch (final) {
        '@' => {
            if (t.margin_mode and (b.x < b.margin_left or b.x > b.margin_right)) return;
            const right = if (t.margin_mode) b.margin_right else b.cols - 1;
            const col = @mod(b.x, right + 1);
            var guard = try printing.beginCellEdit(t, .{ .first = b.y, .last = b.y }, .{ .first = col, .last = right }, .{
                .refreshSelectorMotion = true, .preserveBackwardAttachmentCoordinateOnInvalidation = true,
            });
            defer guard.deinit(t.allocator);
            try b.liveLine(b.y).insertCells(b.x, param(params, 0, 1), right, .{ .cell = t.eraseCell() });
            _ = try printing.endCellEdit(t, &guard);
        },
        'A' => {
            const old_y = b.y;
            const old_absolute = b.y_base + b.y;
            const was_pending = b.wrap_pending;
            const parked = t.print_state.noWrapParkedAfterPrint;
            const top = if (b.y >= b.scroll_top) b.scroll_top else 0;
            b.y = @max(b.y -| param(params, 0, 1), top);
            if ((was_pending or parked) and b.y < old_y) t.print_state.pendingCursorUpMoved = true;
            printing.recordSelectorOwnerVerticalMotion(t, old_absolute);
        },
        'B' => {
            const old_absolute = b.y_base + b.y;
            const bottom = if (b.y <= b.scroll_bottom) b.scroll_bottom else b.rows - 1;
            b.y = @min(b.y +| param(params, 0, 1), bottom);
            if (b.x >= b.cols) b.x -= 1;
            b.wrap_pending = false;
            printing.recordSelectorOwnerVerticalMotion(t, old_absolute);
        },
        'C' => {
            const old_x = b.x;
            var right = if (t.margin_mode) b.margin_right else b.cols - 1;
            if (b.x > right) right = b.cols - 1;
            b.x = @min(b.x +| param(params, 0, 1), right);
            b.wrap_pending = false;
            printing.recordSelectorOwnerRelativeForwardMotion(t, old_x);
        },
        'D' => {
            const old_x = b.x;
            const old_y = b.y;
            t.print_state.noWrapParkedAfterPrint = false;
            var left: isize = if (t.margin_mode) b.margin_left else 0;
            if (b.x < left) left = 0;
            b.x = @max(b.x -| param(params, 0, 1), left);
            b.wrap_pending = false;
            printing.recordSelectorOwnerRelativeBackwardMotion(t, old_x, old_y);
        },
        'E' => {
            b.y = @min(b.y +| param(params, 0, 1), b.rows - 1);
            if (b.x >= b.cols) b.x -= 1;
            b.x = b.margin_left;
            b.wrap_pending = false;
        },
        'F' => {
            b.y = @max(b.y -| param(params, 0, 1), 0);
            b.x = b.margin_left;
            b.wrap_pending = false;
        },
        'G' => {
            const old_x = b.x;
            const old_y = b.y;
            b.x = std.math.clamp(param(params, 0, 1) -| 1, 0, b.cols - 1);
            printing.recordSelectorOwnerAbsoluteMotion(t, old_x, old_y);
        },
        'H' => setCursorPosition(t, param(params, 0, 1) -| 1, param(params, 1, 1) -| 1),
        'f' => {
            // HVP offsets origin but only clamps its upper screen edge.
            b.y = param(params, 0, 1) -| 1 +| @as(isize, if (t.origin_mode) b.scroll_top else 0);
            if (b.y >= b.rows) b.y = b.rows - 1;
            b.x = param(params, 1, 1) -| 1 +| @as(isize, if (t.usingMargins()) b.margin_left else 0);
            if (b.x >= b.cols) b.x = b.cols - 1;
        },
        'I' => {
            const old_x = b.x;
            var remaining = @min(b.cols - 1, param(params, 0, 1));
            while (remaining > 0) : (remaining -= 1) {
                b.x = b.nextTabStop(b.x, t.margin_mode);
                b.wrap_pending = false;
            }
            printing.recordSelectorOwnerRelativeForwardMotion(t, old_x);
        },
        'J' => try eraseInDisplay(t, first(params)),
        'K' => try eraseInLine(t, first(params)),
        'L' => {
            if (b.y < b.scroll_top or b.y > b.scroll_bottom) return;
            if (t.margin_mode and (b.wrap_pending or b.x < b.margin_left or b.x > b.margin_right)) return;
            const count = @min(b.rows *| 2, param(params, 0, 1));
            const columns: Bounds = if (t.margin_mode) .{ .first = b.margin_left, .last = b.margin_right } else .{ .first = 0, .last = b.cols - 1 };
            const bottom = if (t.margin_mode) @min(b.rows - 1, b.y + b.scroll_bottom - b.scroll_top) else b.scroll_bottom;
            var guard = try printing.beginCellEdit(t, .{ .first = b.y, .last = bottom }, columns, .{ .preserveLineRotationOwnerOnInvalidation = true });
            defer guard.deinit(t.allocator);
            if (t.margin_mode) {
                try marginModeShift(t, true, b.y, count);
            } else {
                const previous_bottom = b.liveLine(b.scroll_bottom).retain();
                defer previous_bottom.release();
                try b.insertLines(b.y, count, t.eraseCell());
                printing.rebindMarginDeleteGenerationWitnesses(t, previous_bottom);
            }
            _ = try printing.endCellEdit(t, &guard);
        },
        'M' => {
            if (t.margin_mode) {
                const effective_x = @min(b.x, b.cols - 1);
                if (effective_x < b.margin_left or effective_x > b.margin_right) {
                    if (b.x >= b.cols) b.x = b.cols - 1;
                    if (t.origin_mode) b.y = std.math.clamp(b.y, b.scroll_top, b.scroll_bottom);
                    return;
                }
            }
            restrictCursor(t);
            const count = @min(b.rows +| 1, param(params, 0, 1));
            const previous_bottom = b.liveLine(b.scroll_bottom).retain();
            defer previous_bottom.release();
            if (!t.margin_mode and (b.y < b.scroll_top or b.y > b.scroll_bottom)) return;
            const columns: Bounds = if (t.margin_mode) .{ .first = b.margin_left, .last = b.margin_right } else .{ .first = 0, .last = b.cols - 1 };
            const bottom = if (t.margin_mode) @min(b.rows - 1, b.y + b.scroll_bottom - b.scroll_top) else b.scroll_bottom;
            var guard = try printing.beginCellEdit(t, .{ .first = b.y, .last = bottom }, columns, .{ .preserveBackwardAttachmentCoordinateOnInvalidation = true });
            defer guard.deinit(t.allocator);
            if (t.margin_mode) try marginModeShift(t, false, b.y, count) else try b.deleteLines(b.y, count, t.eraseCell());
            _ = try printing.endCellEdit(t, &guard);
            if (!t.margin_mode) printing.rebindMarginDeleteGenerationWitnesses(t, previous_bottom);
            try printing.refreshInsertLineOwnerAfterUpwardLineRotation(t);
            printing.retireKittyDisplayReflowClaimDisplacedFromBottom(t, previous_bottom, b);
        },
        'P' => {
            if (t.margin_mode and (b.x < b.margin_left or b.x > b.margin_right)) return;
            const right = if (t.margin_mode) b.margin_right else b.cols - 1;
            if (b.x > right) return;
            var guard = try printing.beginCellEdit(t, .{ .first = b.y, .last = b.y }, .{ .first = b.x, .last = right }, .{ .preserveBackwardAttachmentCoordinateOnInvalidation = true });
            defer guard.deinit(t.allocator);
            try b.liveLine(b.y).deleteCells(b.x, param(params, 0, 1), right, .{ .cell = t.eraseCell() });
            _ = try printing.endCellEdit(t, &guard);
        },
        'S' => {
            var count = @min(b.rows *| 2, param(params, 0, 1));
            if (t.margin_mode) {
                while (count > 0) : (count -= 1) try marginModeScroll(t, true);
            } else {
                const previous_bottom = b.liveLine(b.scroll_bottom).retain();
                defer previous_bottom.release();
                while (count > 0) : (count -= 1) try b.scrollUpRegionOnly(.{});
                printing.rebindMarginDeleteGenerationWitnesses(t, previous_bottom);
            }
            try printing.refreshInsertLineOwnerAfterUpwardLineRotation(t);
        },
        'T' => if (!private and collect.len == 0) {
            var count = @min(b.rows, param(params, 0, 1));
            while (count > 0) : (count -= 1) try marginModeScroll(t, false);
        },
        'X' => try b.liveLine(b.y).fillCell(t.eraseCell(), b.x, @min(b.x +| param(params, 0, 1), b.cols)),
        'Z' => {
            const old_x = b.x;
            const old_y = b.y;
            var count = param(params, 0, 1);
            while (count > 0) : (count -= 1) b.x = b.previousTabStop(b.x);
            b.wrap_pending = false;
            printing.recordSelectorOwnerRelativeBackwardMotion(t, old_x, old_y);
        },
        'a' => b.x = @min(b.x +| param(params, 0, 1), b.cols - 1),
        'b' => try repeatPrecedingCharacter(t, param(params, 0, 1)),
        'c' => if (marker(collect, '>')) {
            try t.sendResponse("\x1b[>0;10;1c");
        } else if (first(params) == 0) {
            try t.sendResponse("\x1b[?62;1;6;9;22c");
        },
        'd' => {
            const old_absolute = b.y_base + b.y;
            b.y = std.math.clamp(param(params, 0, 1) -| 1, 0, b.rows - 1);
            printing.recordSelectorOwnerVerticalMotion(t, old_absolute);
        },
        'e' => {
            b.y = @min(b.y +| param(params, 0, 1), b.rows - 1);
            if (b.x >= b.cols) b.x -= 1;
        },
        'g' => switch (first(params)) { 0 => b.clearTabStop(b.x), 3 => b.clearAllTabStops(), else => {} },
        'h', 'l' => try modes.setModes(t, params, collect, final == 'h'),
        'm' => if (collect.len == 0) { @import("sgr.zig").apply(&t.pen, raw); },
        'n' => if (private) {
            if (first(params) == 6) try response(t, "\x1b[?{d};{d}R", .{ b.y + 1, b.x + 1 });
        } else switch (first(params)) {
            5 => try t.sendResponse("\x1b[0n"),
            6 => try response(t, "\x1b[{d};{d}R", .{ if (t.origin_mode) b.y - b.scroll_top + 1 else b.y + 1, b.x + 1 }),
            else => {},
        },
        'p' => if (collect.len > 0 and collect[collect.len - 1] == '$') {
            try modes.reportMode(t, first(params), private);
        } else if (marker(collect, '!')) {
            softReset(t);
        },
        'q' => if (collect.len > 0 and collect[collect.len - 1] == ' ') { setCursorStyleParam(t, first(params)); },
        'r' => if (!private and collect.len == 0) {
            const top = if (params.len > 0) @max(params[0] -| 1, 0) else 0;
            var bottom = b.rows;
            if (params.len > 1 and params[1] != 0) bottom = @min(params[1], b.rows);
            bottom -= 1;
            if (top < bottom) { b.scroll_bottom = bottom; b.scroll_top = top; }
            setCursorPosition(t, 0, 0);
        },
        's' => if (!private and collect.len == 0) {
            if (t.margin_mode) {
                const left = param(params, 0, 1);
                const right = if (params.len > 1) param(params, 1, 1) else b.cols;
                const a = std.math.clamp(left, 1, b.cols) - 1;
                const z = std.math.clamp(right, 1, b.cols) - 1;
                b.margin_left = @min(a, z);
                b.margin_right = z;
            } else saveCursor(t);
        },
        't' => try windowOps(t, params),
        'u' => if (!private and collect.len == 0) { try restoreCursor(t); } else { try modes.keyboardCSI(t, final, params, collect); },
        else => if (marker(collect, '>') or marker(collect, '=')) { try modes.keyboardCSI(t, final, params, collect); },
    }
}

fn response(t: anytype, comptime format: []const u8, values: anytype) !void {
    var bytes: [160]u8 = undefined;
    try t.sendResponse(std.fmt.bufPrint(&bytes, format, values) catch unreachable);
}

pub fn setCursorPosition(t: anytype, row: isize, col: isize) void {
    const b = t.buffer();
    const old_x = b.x;
    const old_y = b.y;
    const first_row = if (t.origin_mode) b.scroll_top else 0;
    const last_row = if (t.origin_mode) b.scroll_bottom else b.rows - 1;
    const first_col = if (t.origin_mode and t.margin_mode) b.margin_left else 0;
    b.y = std.math.clamp(row +| first_row, first_row, last_row);
    b.x = std.math.clamp(col +| first_col, first_col, b.cols - 1);
    b.wrap_pending = false;
    t.print_state.noWrapParkedAfterPrint = false;
    t.print_state.pendingCursorUpMoved = false;
    printing.recordSelectorOwnerAbsoluteMotion(t, old_x, old_y);
}

pub fn restrictCursor(t: anytype) void {
    const b = t.buffer();
    if (b.rows <= 0 or b.cols <= 0) { b.x = 0; b.y = 0; b.wrap_pending = false; return; }
    b.y = std.math.clamp(b.y, if (t.origin_mode) b.scroll_top else 0, if (t.origin_mode) b.scroll_bottom else b.rows - 1);
    b.x = std.math.clamp(b.x, if (t.origin_mode and t.margin_mode) b.margin_left else 0, if (t.origin_mode and t.margin_mode) b.margin_right else b.cols - 1);
    b.wrap_pending = false;
}

fn activeRegion(t: anytype, requested: ?Bounds, use_stored_columns: bool) ?Region {
    const b = t.buffer();
    if (b.rows <= 0 or b.cols <= 0) return null;
    var row_range: Bounds = .{ .first = b.scroll_top, .last = b.scroll_bottom };
    if (requested) |bounds| {
        row_range.first = @max(row_range.first, bounds.first);
        row_range.last = @min(row_range.last, bounds.last);
        if (row_range.first > row_range.last) return null;
    }
    const columns: Bounds = if (t.margin_mode or use_stored_columns) .{ .first = b.margin_left, .last = b.margin_right } else .{ .first = 0, .last = b.cols - 1 };
    if (columns.first < 0 or columns.last >= b.cols or columns.first > columns.last) return null;
    return .{ .rows = row_range, .columns = columns };
}

pub fn columnIndex(t: anytype, back: bool) anyerror!void {
    const b = t.buffer();
    const old_x = b.x;
    const old_y = b.y;
    var preserve_motion = false;
    defer {
        if (back) printing.recordSelectorOwnerRelativeBackwardMotion(t, old_x, old_y)
        else if (!preserve_motion) printing.recordSelectorOwnerRelativeForwardMotion(t, old_x);
    }
    if (t.margin_mode and (b.x < b.margin_left or b.x > b.margin_right)) {
        const consumed_pending = !back and b.wrap_pending and b.x >= b.cols;
        if (back and b.x > 0) b.x -= 1 else if (!back and b.x < b.cols - 1) b.x += 1;
        preserve_motion = !back and b.x == old_x;
        b.wrap_pending = false;
        if (consumed_pending) t.print_state.noWrapParkedAfterPrint = true;
        return;
    }
    const use_stored = back or (!t.margin_mode and b.x >= b.margin_right);
    const region = activeRegion(t, null, use_stored) orelse return;
    const boundary = if (back) region.columns.first else region.columns.last;
    if (!back and b.x > region.columns.last) {
        if (b.x < b.cols - 1) { b.x += 1; b.wrap_pending = false; }
        return;
    }
    if (back and b.x < region.columns.first) {
        if (!t.margin_mode and b.x > 0) { b.x -= 1; b.wrap_pending = false; }
        return;
    }
    if (b.x == boundary) {
        if (!region.rows.contains(b.y)) return;
        if (!back and boundary > 0 and !t.margin_mode and !use_stored) {
            const line = b.liveLine(b.y);
            if (line.cell(boundary).width == 0 and line.cell(boundary - 1).width == 2) return;
        }
        const last = t.print_state.lastWrite;
        if (!back and t.print_state.lastPrintedScalar != null and last.rows == b.rows and last.cols == b.cols and last.row == b.y_base + b.y and last.x < region.columns.first) preserve_motion = true;
        var forward_tail: ?OwnedCell = if (!back) try OwnedCell.init(t.allocator, b.liveLine(b.y).get(b.cols - 1)) else null;
        defer if (forward_tail) |*tail| tail.deinit(t.allocator);
        const shifted: Bounds = .{ .first = region.columns.first, .last = b.cols - 1 };
        if (back) {
            var guard = try printing.beginBackwardColumnShift(t, region.rows, shifted);
            defer guard.deinit(t.allocator);
            try columnScroll(t, true, use_stored);
            try printing.endBackwardColumnShift(t, &guard);
        } else {
            var guard = try printing.beginCellEdit(t, region.rows, shifted, .{
                .refreshSelectorMotion = true, .preserveBackwardAttachmentCoordinateOnInvalidation = true,
                .refreshLineRotationOwnerAtSavedCoordinate = true,
            });
            defer guard.deinit(t.allocator);
            try columnScroll(t, false, use_stored);
            const handled = try printing.endCellEdit(t, &guard);
            if (handled) preserve_motion = true;
            if (forward_tail) |tail| if (!handled) {
                try printing.retainForwardColumnShiftTail(t, tail.value(), b.cols - 1, b.cols - 2, b.y, region.columns.first);
            };
        }
    } else {
        const movement: Bounds = if (back and b.x > region.columns.last) .{ .first = 0, .last = b.cols - 1 } else region.columns;
        b.x = std.math.clamp(b.x + @as(isize, if (back) -1 else 1), movement.first, movement.last);
    }
    b.wrap_pending = false;
}

fn columnScroll(t: anytype, back: bool, use_stored: bool) !void {
    const region = activeRegion(t, null, use_stored) orelse return;
    // Stub cells use default foreground/inverse-default background, matching the
    // independent Swift engine's .stubAttribute, not its erase pen.
    const fill: Cell = if (back) .{ .scalar = ' ', .bg = 0x03000000 } else t.eraseCell();
    var row = region.rows.first;
    while (row <= region.rows.last) : (row += 1) {
        const line = t.buffer().liveLine(row);
        if (back) try line.insertCells(region.columns.first, 1, t.buffer().cols - 1, .{ .cell = fill })
        else try line.deleteCells(region.columns.first, 1, t.buffer().cols - 1, .{ .cell = fill });
    }
    t.markDirtyRange(t.buffer().y_base + region.rows.first, t.buffer().y_base + region.rows.last);
}

fn shiftSlices(t: anytype, region: Region, requested_count: isize, up: bool, fill: Cell) !void {
    const count = @min(@max(0, requested_count), region.rows.last - region.rows.first + 1);
    if (count <= 0) return;
    const size: usize = @intCast(region.rows.last - region.rows.first + 1);
    const snapshots = try t.allocator.alloc(*rows.Row, size);
    defer t.allocator.free(snapshots);
    var captured: usize = 0;
    defer for (snapshots[0..captured]) |snapshot_row| snapshot_row.destroy();
    while (captured < size) : (captured += 1) snapshots[captured] = try t.buffer().liveLine(region.rows.first + @as(isize, @intCast(captured))).row.clone();
    for (0..size) |destination| {
        const source = @as(isize, @intCast(destination)) + if (up) count else -count;
        const line = t.buffer().liveLine(region.rows.first + @as(isize, @intCast(destination)));
        if (source >= 0 and source < size) {
            try line.row.copyColumns(snapshots[@intCast(source)], @intCast(region.columns.first), @intCast(region.columns.last - region.columns.first + 1));
        } else try line.fillColumns(region.columns.first, region.columns.last, fill);
    }
    t.markDirtyRange(t.buffer().y_base + region.rows.first, t.buffer().y_base + region.rows.last);
}

fn destroyContents(a: std.mem.Allocator, map: *Contents) void {
    var values = map.valueIterator();
    while (values.next()) |value| value.deinit(a);
    map.deinit(a);
}
fn removeContent(a: std.mem.Allocator, map: *Contents, position: Coordinate) void {
    if (map.fetchRemove(position)) |removed| { var cell = removed.value; cell.deinit(a); }
}
fn replaceContent(a: std.mem.Allocator, map: *Contents, position: Coordinate, value: Value) !void {
    var owned = try OwnedCell.init(a, value);
    errdefer owned.deinit(a);
    const slot = try map.getOrPut(a, position);
    if (slot.found_existing) slot.value_ptr.deinit(a);
    slot.value_ptr.* = owned;
}
fn cloneContents(a: std.mem.Allocator, original: *const Contents) !Contents {
    var result: Contents = .empty;
    errdefer destroyContents(a, &result);
    try result.ensureTotalCapacity(a, original.count());
    var entries = original.iterator();
    while (entries.next()) |entry| try replaceContent(a, &result, entry.key_ptr.*, entry.value_ptr.value());
    return result;
}
fn blank(value: Value) bool {
    return value.cell.scalar == 0 and value.extras == null and value.cell.width == 1 and value.cell.link_id == 0;
}
fn attributeOf(cell: Cell) Cell {
    return .{ .fg = cell.fg, .bg = cell.bg, .style = cell.style, .underline_color = cell.underline_color,
        .underline_kind = cell.underline_kind, .underline_present = cell.underline_present };
}

pub fn marginModeShift(t: anytype, insert: bool, y: isize, count: isize) !void {
    const b = t.buffer();
    const columns: Bounds = .{ .first = b.margin_left, .last = b.margin_right };
    if (count <= 0 or y < 0 or y >= b.rows or columns.first < 0 or columns.last >= b.cols or columns.first > columns.last) return;
    if (insert and (y < b.scroll_top or y > b.scroll_bottom)) return;
    const height = b.scroll_bottom - b.scroll_top + 1;
    const witness = b.liveLine(b.rows - 1);
    const retained_row = b.dropped_lines + b.y_base + b.rows - 1;
    const generations = &t.print_state.marginDeleteGenerations;
    var index: ?usize = null;
    for (generations.items, 0..) |generation, i| if (generation.witnessLine == witness and generation.retainedBottomRow == retained_row) { index = i; break; };
    var previous: Attributes = if (index) |i| try generations.items[i].virtualCells.clone(t.allocator) else .empty;
    defer previous.deinit(t.allocator);
    var previous_content: Contents = if (index) |i| try cloneContents(t.allocator, &generations.items[i].virtualContentCells) else .empty;
    defer destroyContents(t.allocator, &previous_content);
    var r: isize = 0;
    while (r < b.rows) : (r += 1) {
        const line = b.liveLine(r);
        var col = columns.first;
        while (col <= columns.last) : (col += 1) {
            const pos: Coordinate = .{ .row = r, .column = col };
            const value = line.get(col);
            if (blank(value)) {
                try previous.put(t.allocator, pos, attributeOf(value.cell));
                removeContent(t.allocator, &previous_content, pos);
            } else {
                _ = previous.remove(pos);
                try replaceContent(t.allocator, &previous_content, pos, value);
            }
        }
    }
    var next = try previous.clone(t.allocator);
    errdefer next.deinit(t.allocator);
    var next_content = try cloneContents(t.allocator, &previous_content);
    errdefer destroyContents(t.allocator, &next_content);
    if (height > 0) {
        const shift = @min(count, height);
        var col = columns.first;
        while (col <= columns.last) : (col += 1) {
            var offset: isize = 0;
            while (offset < height) : (offset += 1) {
                const destination: Coordinate = .{ .row = y + offset, .column = col };
                const source_offset = if (insert) offset - shift else offset + shift;
                if (source_offset >= 0 and source_offset < height) {
                    const source: Coordinate = .{ .row = y + source_offset, .column = col };
                    if (previous.get(source)) |attribute| try next.put(t.allocator, destination, attribute) else { _ = next.remove(destination); }
                    if (previous_content.get(source)) |cell| try replaceContent(t.allocator, &next_content, destination, cell.value()) else removeContent(t.allocator, &next_content, destination);
                } else {
                    try next.put(t.allocator, destination, t.eraseCell());
                    removeContent(t.allocator, &next_content, destination);
                }
            }
        }
    }
    const region: Region = .{ .rows = .{ .first = y, .last = @min(b.rows - 1, y + height - 1) }, .columns = columns };
    try shiftSlices(t, region, @min(count, region.rows.last - region.rows.first + 1), !insert, if (insert) t.eraseCell() else .{});
    // Repaint blank attributes first, then actual retained content, just as the
    // reference's two independent virtual-cell dictionaries do.
    var changed: ?Bounds = null;
    r = 0;
    while (r < b.rows) : (r += 1) {
        const line = b.liveLine(r);
        var col = columns.first;
        while (col <= columns.last) : (col += 1) {
            const position: Coordinate = .{ .row = r, .column = col };
            const attribute = next.get(position) orelse Cell{};
            const old = line.get(col);
            if (blank(old) and !std.meta.eql(attributeOf(old.cell), attribute)) {
                try line.setCell(col, attribute);
                changed = if (changed) |bounds| .{ .first = @min(bounds.first, r), .last = @max(bounds.last, r) } else .{ .first = r, .last = r };
            }
        }
    }
    if (changed) |bounds| t.markDirtyRange(b.y_base + bounds.first, b.y_base + bounds.last);
    changed = null;
    r = 0;
    while (r < b.rows) : (r += 1) {
        const line = b.liveLine(r);
        var col = columns.first;
        while (col <= columns.last) : (col += 1) {
            const value = next_content.get(.{ .row = r, .column = col }) orelse continue;
            if (!printing.cellEqual(line.get(col), value.value())) {
                try line.set(col, value.value());
                changed = if (changed) |bounds| .{ .first = @min(bounds.first, r), .last = @max(bounds.last, r) } else .{ .first = r, .last = r };
            }
        }
    }
    if (changed) |bounds| t.markDirtyRange(b.y_base + bounds.first, b.y_base + bounds.last);
    const next_witness = b.liveLine(b.rows - 1).retain();
    errdefer next_witness.release();
    const next_generation: printing.MarginGeneration = .{ .witnessLine = next_witness,
        .retainedBottomRow = b.dropped_lines + b.y_base + b.rows - 1, .virtualCells = next, .virtualContentCells = next_content };
    if (index) |i| {
        generations.items[i].deinit(t.allocator);
        generations.items[i] = next_generation;
    } else try generations.append(t.allocator, next_generation);
    if (generations.items.len > 32) {
        const removed = generations.items.len - 32;
        for (generations.items[0..removed]) |*generation| generation.deinit(t.allocator);
        std.mem.copyForwards(printing.MarginGeneration, generations.items[0..32], generations.items[removed..]);
        generations.shrinkRetainingCapacity(32);
    }
}

pub fn marginModeScroll(t: anytype, up: bool) !void {
    const region = activeRegion(t, null, false) orelse return;
    try shiftSlices(t, region, 1, up, .{});
}

fn repeatPrecedingCharacter(t: anytype, count: isize) !void {
    const b = t.buffer();
    var remaining = @min(b.cols *| b.rows *| 2, @max(count, 1));
    var source = try OwnedCell.init(t.allocator, if (b.x - 1 < 0) .{} else b.liveLine(b.y).get(b.x - 1));
    defer source.deinit(t.allocator);
    while (remaining > 0) : (remaining -= 1) try printing.insertCellDirect(t, source.value());
}

pub fn eraseInDisplay(t: anytype, mode: isize) !void {
    const b = t.buffer();
    const fill = t.eraseCell();
    switch (mode) {
        0 => {
            try eraseInLine(t, 0);
            var r = b.y + 1;
            while (r < b.rows) : (r += 1) try b.liveLine(r).fillCell(fill, 0, null);
        },
        1 => {
            try eraseInLine(t, 1);
            var r: isize = 0;
            while (r < b.y) : (r += 1) try b.liveLine(r).fillCell(fill, 0, null);
        },
        2 => {
            var r: isize = 0;
            while (r < b.rows) : (r += 1) {
                const line = b.liveLine(r);
                try line.fillCell(fill, 0, null);
                line.setWrapped(false);
                line.clearImages();
            }
            printing.clearKittyDisplayReflowClaims(t, b);
            printing.clearActiveReverseIndexOwnerRefreshWitness(t);
        },
        3 => {
            b.clearScrollback();
            t.blocks.handleScrollbackCleared();
            t.emit(.{ .kind = .blocks_changed });
            if (b == &t.normal) t.blocks_dropped_checkpoint = t.normal.dropped_lines;
        },
        else => {},
    }
}

pub fn eraseInLine(t: anytype, mode: isize) !void {
    const b = t.buffer();
    const line = b.liveLine(b.y);
    switch (mode) {
        0 => try line.fillCell(t.eraseCell(), b.x, null),
        1 => try line.fillCell(t.eraseCell(), 0, b.x +| 1),
        2 => try line.fillCell(t.eraseCell(), 0, null),
        else => {},
    }
}

pub fn esc(t: anytype, final: u8, collect: []const u8) anyerror!void {
    const b = t.buffer();
    if (collect.len > 0) {
        if (final == '8' and collect[0] == '#') {
            var r: isize = 0;
            while (r < b.rows) : (r += 1) try b.liveLine(r).fillCell(.{ .scalar = 'E' }, 0, null);
            b.scroll_top = 0;
            b.scroll_bottom = b.rows - 1;
            b.x = 0;
            b.y = 0;
        }
        return;
    }
    switch (final) {
        '7' => saveCursor(t),
        '8' => try restoreCursor(t),
        '6', '9' => try columnIndex(t, final == '6'),
        'D' => try printing.indexLineFeed(t),
        'E' => {
            const old_x = b.x;
            const old_y = b.y;
            b.x = 0;
            try printing.indexLineFeed(t);
            printing.recordSelectorOwnerAbsoluteMotion(t, old_x, old_y);
        },
        'H' => try b.setTabStop(b.x),
        'M' => try printing.reverseLineFeed(t),
        'Z' => try t.sendResponse("\x1b[?62;1;6;9;22c"),
        'c' => try fullReset(t),
        else => {}, // UTF-8-only charsets, keypad modes and ST are inert.
    }
}

pub fn saveCursor(t: anytype) void {
    const b = t.buffer();
    b.saved_cursor = .{ .x = b.x, .y = b.y, .attribute = t.pen,
        .wrap_pending = b.wrap_pending, .origin_mode = t.origin_mode, .auto_wrap = t.auto_wrap,
        .margin_mode = t.margin_mode, .reverse_wraparound = t.reverse_wraparound };
}

pub fn restoreCursor(t: anytype) !void {
    const b = t.buffer();
    const saved = b.saved_cursor orelse buffers.SavedCursor{};
    b.x = std.math.clamp(saved.x, 0, b.cols - 1);
    b.y = std.math.clamp(saved.y, 0, b.rows - 1);
    t.pen = saved.attribute;
    t.origin_mode = saved.origin_mode;
    t.auto_wrap = saved.auto_wrap;
    t.margin_mode = saved.margin_mode;
    t.reverse_wraparound = saved.reverse_wraparound;
}

pub fn softReset(t: anytype) void {
    const b = t.buffer();
    t.cursor_hidden = false;
    t.origin_mode = false;
    t.auto_wrap = true;
    t.insert_mode = false;
    t.application_cursor_keys = false;
    b.scroll_top = 0;
    b.scroll_bottom = b.rows - 1;
    b.margin_left = 0;
    b.margin_right = b.cols - 1;
    t.pen = .{};
    b.saved_cursor = null;
    b.wrap_pending = false;
    t.print_state.noWrapParkedAfterPrint = false;
    t.print_state.pendingCursorUpMoved = false;
}

fn clearRetainedList(a: std.mem.Allocator, list: anytype, comptime method: []const u8) void {
    // Releasing an image payload can call the host and recursively change the
    // witness lists. Publish empty before releasing the old, detached storage.
    var removed = list.*;
    list.* = .empty;
    for (removed.items) |entry| @call(.auto, @field(@typeInfo(@TypeOf(entry)).pointer.child, method), .{entry});
    removed.clearRetainingCapacity();
    if (list.capacity == 0) list.* = removed else removed.deinit(a);
}

pub fn fullReset(t: anytype) !void {
    const saved_hidden = t.cursor_hidden;
    const saved_reverse = t.reverse_wraparound;
    softReset(t);
    t.cursor_hidden = saved_hidden;
    const alt_x = t.alternate.x;
    const alt_y = t.alternate.y;
    try t.setActiveBuffer(false);
    try t.normal.hardReset();
    const s = &t.print_state;
    clearRetainedList(t.allocator, &s.activeMarginReflowBoundaries, "release");
    clearRetainedList(t.allocator, &s.kittyDisplayReflowClaims, "release");
    clearRetainedList(t.allocator, &s.kittyDisplayReflowBoundaries, "release");
    clearRetainedList(t.allocator, &s.kittyDisplayReflowImages, "deinit");
    // Transfers are values, while the lists above contain retained pointers.
    var transfers = s.kittyDisplayReflowImageTransfers;
    s.kittyDisplayReflowImageTransfers = .empty;
    for (transfers.items) |*transfer| transfer.deinit();
    transfers.clearRetainingCapacity();
    if (s.kittyDisplayReflowImageTransfers.capacity == 0) s.kittyDisplayReflowImageTransfers = transfers else transfers.deinit(t.allocator);
    t.blocks.reset();
    t.emit(.{ .kind = .blocks_changed });
    t.blocks_dropped_checkpoint = 0;
    t.normal.x = std.math.clamp(alt_x, 0, t.normal.cols);
    t.normal.y = std.math.clamp(alt_y, 0, t.normal.rows - 1);
    t.reverse_video = false;
    t.margin_mode = false;
    t.reverse_wraparound = saved_reverse;
    t.mouse_mode = .off;
    t.mouse_protocol = .x10;
    t.bracketed_paste = false;
    t.line_feed_mode = false;
    t.focus_reporting = false;
    t.synchronized_updates = false;
    t.gl_level = 0;
    t.keyboard_normal.clearRetainingCapacity();
    t.keyboard_alt.clearRetainingCapacity();
    try protocols.resetGraphics(t);
    t.cursor_style = .blink_block;
    t.allocator.free(t.title);
    t.title = &.{};
    printing.clearBackwardColumnAttachmentWitness(t);
    printing.clearReverseIndexOwnerRefreshWitnesses(t);
    s.lastPrintedScalar = null;
}

pub fn setCursorStyleParam(t: anytype, p: isize) void {
    switch (p) {
        0, 1 => t.cursor_style = .blink_block,
        2 => t.cursor_style = .steady_block,
        3 => t.cursor_style = .blink_underline,
        4 => t.cursor_style = .steady_underline,
        5 => t.cursor_style = .blink_bar,
        6 => t.cursor_style = .steady_bar,
        else => {},
    }
}

fn windowOps(t: anytype, params: []const isize) !void {
    switch (first(params)) {
        18 => try response(t, "\x1b[8;{d};{d}t", .{ t.buffer().rows, t.buffer().cols }),
        22 => {
            const title = try t.allocator.dupe(u8, t.title);
            errdefer t.allocator.free(title);
            try t.title_stack.append(t.allocator, title);
        },
        23 => if (t.title_stack.pop()) |title| {
            defer t.allocator.free(title);
            try t.setTitle(title);
        },
        else => {},
    }
}

test "native dispatch preserves CUP HVP and pending-wrap cursor asymmetries" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 10, 5, 8);
    defer t.deinit();
    const b = t.buffer();
    b.scroll_top = 1; b.scroll_bottom = 3;
    b.margin_left = 2; b.margin_right = 5;
    t.origin_mode = true; t.margin_mode = true;
    b.wrap_pending = true;
    try csi(&t, 'H', &.{ 100, 100 }, "");
    try testing.expectEqual(@as(isize, 3), b.y);
    try testing.expectEqual(@as(isize, 9), b.x);
    try testing.expect(!b.wrap_pending);
    b.wrap_pending = true;
    try csi(&t, 'f', &.{ 100, 100 }, "");
    try testing.expectEqual(@as(isize, 4), b.y);
    try testing.expectEqual(@as(isize, 9), b.x);
    try testing.expect(b.wrap_pending);
    try csi(&t, 'G', &.{2}, "");
    try testing.expectEqual(@as(isize, 1), b.x);
    try testing.expect(b.wrap_pending);
    b.x = 10; b.y = 3;
    try csi(&t, 'A', &.{1}, "");
    try testing.expectEqual(@as(isize, 2), b.y);
    try testing.expectEqual(@as(isize, 10), b.x);
    try testing.expect(b.wrap_pending and t.print_state.pendingCursorUpMoved);
    try csi(&t, 'B', &.{1}, "");
    try testing.expectEqual(@as(isize, 3), b.y);
    try testing.expectEqual(@as(isize, 9), b.x);
    try testing.expect(!b.wrap_pending);
}

test "native margins preserve omitted versus explicit zero right endpoints" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 10, 5, 8);
    defer t.deinit();
    t.margin_mode = true;
    try csi(&t, 's', &.{4}, "");
    try testing.expectEqual(@as(isize, 3), t.buffer().margin_left);
    try testing.expectEqual(@as(isize, 9), t.buffer().margin_right);
    try csi(&t, 's', &.{ 4, 0 }, "");
    try testing.expectEqual(@as(isize, 0), t.buffer().margin_left);
    try testing.expectEqual(@as(isize, 0), t.buffer().margin_right);
    try csi(&t, 's', &.{ 8, 3 }, "");
    try testing.expectEqual(@as(isize, 2), t.buffer().margin_left);
    try testing.expectEqual(@as(isize, 2), t.buffer().margin_right);
    t.buffer().x = 7; t.buffer().y = 4;
    try csi(&t, 'r', &.{ 4, 2 }, "");
    try testing.expectEqual(@as(isize, 0), t.buffer().scroll_top);
    try testing.expectEqual(@as(isize, 4), t.buffer().scroll_bottom);
    try testing.expectEqual(@as(isize, 0), t.buffer().x);
    try testing.expectEqual(@as(isize, 0), t.buffer().y);
}

test "native cursor save defaults disable wrapping and restore leaves wrap-pending untouched" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 10, 5, 8);
    defer t.deinit();
    t.buffer().x = 8; t.buffer().y = 4; t.buffer().wrap_pending = true;
    try restoreCursor(&t);
    try testing.expect(!t.auto_wrap);
    try testing.expect(t.buffer().wrap_pending);
    try testing.expectEqual(@as(isize, 0), t.buffer().x);
    t.auto_wrap = true; t.origin_mode = true; t.margin_mode = true;
    t.pen = .{ .fg = 0x01000004, .bg = 0x02010203, .style = 64 };
    t.buffer().x = 10; t.buffer().y = 2;
    saveCursor(&t);
    t.pen = .{}; t.auto_wrap = false; t.origin_mode = false; t.margin_mode = false;
    t.buffer().x = 0; t.buffer().y = 0; t.buffer().wrap_pending = false;
    try restoreCursor(&t);
    try testing.expectEqual(@as(isize, 9), t.buffer().x);
    try testing.expectEqual(@as(isize, 2), t.buffer().y);
    try testing.expectEqual(@as(u32, 0x01000004), t.pen.fg);
    try testing.expect(t.auto_wrap and t.origin_mode and t.margin_mode);
    try testing.expect(!t.buffer().wrap_pending);
}

test "native ICH and DCH preserve dormant combining owner coordinates" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 8, 3, 8);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try line.writeASCII("ABCDEFGH", 0, .{});
    t.buffer().x = 2;
    t.print_state.lastPrintedScalar = 'C';
    t.print_state.lastWrite = .{ .row = 0, .x = 2, .cols = 8, .rows = 3 };
    t.print_state.presentationSelectorAuthority = .available;
    try csi(&t, '@', &.{1}, "");
    try testing.expectEqual(@as(u32, 0), line.cell(2).scalar);
    try testing.expectEqual(@as(u32, 'C'), line.cell(3).scalar);
    try testing.expectEqual(@as(?u32, null), t.print_state.lastPrintedScalar);
    try testing.expectEqual(.dormantCoordinate, printing.backwardWitness(&t).*.?.phase);
    try csi(&t, 'P', &.{1}, "");
    try testing.expectEqual(@as(u32, 'C'), line.cell(2).scalar);
    try testing.expectEqual(@as(?u32, 'C'), t.print_state.lastPrintedScalar);
    try testing.expectEqual(@as(isize, 2), t.print_state.lastWrite.x);
    try testing.expectEqual(@as(?printing.Attachment, null), printing.backwardWitness(&t).*);
    try t.printScalar(0x301);
    try testing.expectEqualSlices(u32, &.{0x301}, line.get(2).extras.?);
}

test "native DECBI inserts exact stub cells across stored horizontal bounds" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 6, 2, 8);
    defer t.deinit();
    const b = t.buffer();
    try b.liveLine(0).writeASCII("ABCDEF", 0, .{});
    try b.liveLine(1).writeASCII("abcdef", 0, .{});
    b.margin_left = 2; b.margin_right = 3; b.x = 2;
    try esc(&t, '6', "");
    try testing.expectEqual(@as(u32, ' '), b.liveLine(0).cell(2).scalar);
    try testing.expectEqual(@as(u32, 0), b.liveLine(0).cell(2).fg);
    try testing.expectEqual(@as(u32, 0x03000000), b.liveLine(0).cell(2).bg);
    try testing.expectEqual(@as(u32, 'E'), b.liveLine(0).cell(5).scalar);
    try testing.expectEqual(@as(u32, 'e'), b.liveLine(1).cell(5).scalar);
    try testing.expectEqual(@as(isize, 2), b.x);
}

test "native margin shifts retain cluster extras and untouched exterior cells" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 5, 4, 8);
    defer t.deinit();
    const b = t.buffer();
    for (0..4) |index| {
        try b.liveLine(@intCast(index)).fillCell(.{ .scalar = @as(u32, 'A') + @as(u32, @intCast(index)) }, 0, null);
    }
    try b.liveLine(2).set(2, .{ .cell = .{ .scalar = 'C', .fg = 0x01000003 }, .extras = &.{ 0x301, 0x302 } });
    b.margin_left = 1; b.margin_right = 3; b.scroll_top = 0; b.scroll_bottom = 2;
    t.margin_mode = true; t.pen.bg = 0x01000006;
    try marginModeShift(&t, false, 1, 1);
    try testing.expectEqual(@as(u32, 'B'), b.liveLine(1).cell(0).scalar);
    try testing.expectEqual(@as(u32, 'B'), b.liveLine(1).cell(4).scalar);
    try testing.expectEqual(@as(u32, 'C'), b.liveLine(1).cell(2).scalar);
    try testing.expectEqualSlices(u32, &.{ 0x301, 0x302 }, b.liveLine(1).get(2).extras.?);
    try testing.expectEqual(@as(u32, 0), b.liveLine(3).cell(2).scalar);
    try testing.expectEqual(@as(u32, 0x01000006), b.liveLine(3).cell(2).bg);
    try testing.expectEqual(@as(usize, 1), t.print_state.marginDeleteGenerations.items.len);
    try marginModeShift(&t, true, 1, 1);
    try testing.expectEqual(@as(u32, 'C'), b.liveLine(2).cell(2).scalar);
    try testing.expectEqualSlices(u32, &.{ 0x301, 0x302 }, b.liveLine(2).get(2).extras.?);
}

test "native margin generation retention is capped and releases all owned cells" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 3, 3, 40);
    defer t.deinit();
    const b = t.buffer();
    b.margin_left = 1; b.margin_right = 1; t.margin_mode = true;
    for (0..40) |_| {
        try b.liveLine(1).set(1, .{ .cell = .{ .scalar = 'X' }, .extras = &.{0x301} });
        try marginModeShift(&t, false, 0, 1);
        try b.scrollUp(.{}, false, true);
    }
    try testing.expectEqual(@as(usize, 32), t.print_state.marginDeleteGenerations.items.len);
}

test "native RIS preserves visibility and reverse wrap and copies alternate cursor" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 6, 3, 8);
    defer t.deinit();
    t.cursor_hidden = true; t.reverse_wraparound = true; t.line_feed_mode = true;
    t.bracketed_paste = true; t.focus_reporting = true; t.synchronized_updates = true;
    t.alternate.x = 6; t.alternate.y = 2;
    try t.normal.liveLine(0).writeASCII("normal", 0, .{});
    try fullReset(&t);
    try testing.expect(t.cursor_hidden and t.reverse_wraparound);
    try testing.expect(!t.is_alternate and !t.line_feed_mode and !t.bracketed_paste and !t.focus_reporting and !t.synchronized_updates);
    try testing.expectEqual(@as(isize, 6), t.normal.x);
    try testing.expectEqual(@as(isize, 2), t.normal.y);
    try testing.expectEqual(@as(u32, 0), t.normal.liveLine(0).cell(0).scalar);
}

const TestHost = struct {
    bytes: std.ArrayList(u8) = .empty,
    fn event(context: ?*anyopaque, value: *const @import("terminal.zig").Event) callconv(.c) void {
        const self: *TestHost = @ptrCast(@alignCast(context.?));
        if (value.kind == .send or value.kind == .title) {
            self.bytes.appendSlice(std.testing.allocator, if (value.bytes) |p| p[0..value.length] else &.{}) catch @panic("test allocation failed");
        }
    }
};

test "native reports and title stack emit exact host payloads" {
    const testing = std.testing;
    var t = try @import("terminal.zig").Terminal.init(testing.allocator, 10, 5, 8);
    defer t.deinit();
    var host: TestHost = .{};
    defer host.bytes.deinit(testing.allocator);
    t.host = .{ .context = &host, .event = TestHost.event };
    t.buffer().x = 3; t.buffer().y = 3; t.buffer().scroll_top = 2; t.origin_mode = true;
    try csi(&t, 'n', &.{6}, "");
    try csi(&t, 'n', &.{6}, "?");
    try csi(&t, 'c', &.{0}, ">");
    try csi(&t, 'c', &.{0}, "");
    try csi(&t, 't', &.{18}, "");
    try testing.expectEqualSlices(u8, "\x1b[2;4R\x1b[?4;4R\x1b[>0;10;1c\x1b[?62;1;6;9;22c\x1b[8;5;10t", host.bytes.items);
    host.bytes.clearRetainingCapacity();
    try t.setTitle("first");
    try csi(&t, 't', &.{22}, "");
    try t.setTitle("second");
    try csi(&t, 't', &.{23}, "");
    try testing.expectEqualSlices(u8, "firstsecondfirst", host.bytes.items);
    try testing.expectEqualSlices(u8, "first", t.title);
    try testing.expectEqual(@as(usize, 0), t.title_stack.items.len);
}

fn dispatchAllocationScenario(allocator: std.mem.Allocator) !void {
    var t = try @import("terminal.zig").Terminal.init(allocator, 5, 4, 8);
    defer t.deinit();
    const b = t.buffer();
    b.margin_left = 1; b.margin_right = 3; t.margin_mode = true;
    try b.liveLine(2).set(2, .{ .cell = .{ .scalar = 'C' }, .extras = &.{ 0x301, 0x302 } });
    try marginModeShift(&t, false, 1, 1);
    try marginModeShift(&t, true, 1, 1);
    try b.scrollUp(.{}, false, true);
    try marginModeShift(&t, false, 0, 1);
    b.x = 2; b.y = 1;
    try b.liveLine(1).set(2, .{ .cell = .{ .scalar = 'D' }, .extras = &.{0x303} });
    t.print_state.lastPrintedScalar = 'D';
    t.print_state.lastWrite = .{ .row = b.y_base + 1, .x = 2, .cols = 5, .rows = 4 };
    try csi(&t, 'L', &.{1}, "");
}

test "native dispatch cleans up every allocation failure in margin snapshots and owner guards" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, dispatchAllocationScenario, .{});
}

test "RIS witness release callbacks observe empty storage and preserve reentrant additions" {
    const Witness = struct {
        released: usize = 0,
        list: ?*std.ArrayList(*@This()) = null,
        replacement: ?*@This() = null,
        saw_empty: bool = false,
        pub fn release(self: *@This()) void {
            self.released += 1;
            if (self.list) |list| {
                self.saw_empty = list.items.len == 0;
                list.append(std.testing.allocator, self.replacement.?) catch unreachable;
            }
        }
    };
    var list: std.ArrayList(*Witness) = .empty;
    defer list.deinit(std.testing.allocator);
    var replacement = Witness{};
    var first_witness = Witness{ .list = &list, .replacement = &replacement };
    var second = Witness{};
    try list.appendSlice(std.testing.allocator, &.{ &first_witness, &second });
    clearRetainedList(std.testing.allocator, &list, "release");
    try std.testing.expect(first_witness.saw_empty);
    try std.testing.expectEqual(@as(usize, 1), first_witness.released);
    try std.testing.expectEqual(@as(usize, 1), second.released);
    try std.testing.expectEqual(@as(usize, 0), replacement.released);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expect(list.items[0] == &replacement);
    clearRetainedList(std.testing.allocator, &list, "release");
    try std.testing.expectEqual(@as(usize, 1), replacement.released);
}
