//! C0/C1 line motion, rectangular scrolling, and retained cluster ownership.
//! The scalar printing module owns the state schema; this module owns the
//! transformations that preserve it across LF, IND, RI and reverse backspace.
const std = @import("std");
const p = @import("printing.zig");
const Line = @import("line.zig").Line;
const Cell = @import("row.zig").Cell;
const Value = @import("line.zig").Value;
const A = std.mem.Allocator;

pub const BackspacePlan = struct { x: isize, y: isize, clear_wrapped_row: ?isize = null };
pub const BackspaceGeometry = struct {
    screen_columns: p.Bounds,
    vertical_clamp: p.Bounds,
    left_boundary: isize,
    right_boundary: isize,
    scroll_top: isize,
    scroll_bottom: isize,
    margin_mode: bool,
    reverse: bool,
    pub fn plan(g: BackspaceGeometry, raw_x: isize, raw_y: isize, pending_wrap: bool) BackspacePlan {
        const y = @min(g.vertical_clamp.last, @max(g.vertical_clamp.first, raw_y));
        if (pending_wrap and raw_x <= g.screen_columns.last) {
            return .{ .x = if (raw_x > g.right_boundary) @max(g.right_boundary, raw_x -| 1) else @max(g.left_boundary, raw_x -| 1), .y = y };
        }
        if (pending_wrap and raw_x > g.screen_columns.last) {
            return .{ .x = if (g.reverse) g.screen_columns.last else @max(g.screen_columns.first, g.screen_columns.last -| 1), .y = y };
        }
        if (pending_wrap and g.reverse) return .{ .x = g.right_boundary, .y = y };
        const logical_x = if (pending_wrap) @min(raw_x, g.right_boundary) else raw_x;
        const x = if (g.reverse and !pending_wrap and logical_x == g.screen_columns.last +| 1) logical_x else @min(g.screen_columns.last, @max(g.screen_columns.first, logical_x));
        if (g.margin_mode and x < g.left_boundary) {
            if (!g.reverse) return .{ .x = @max(0, x -| 1), .y = y };
            if (y < g.scroll_top and g.vertical_clamp.first < g.scroll_top) {
                if (y <= g.vertical_clamp.first) return .{ .x = x, .y = y };
                return .{ .x = g.right_boundary, .y = y - 1, .clear_wrapped_row = y };
            }
            return g.wrappedPlan(y);
        }
        if (x > g.left_boundary) return .{ .x = x - 1, .y = y };
        if (!g.reverse) return .{ .x = x, .y = y };
        if (y < g.scroll_top and g.vertical_clamp.first < g.scroll_top) {
            if (y <= g.vertical_clamp.first) return .{ .x = x, .y = y };
            return .{ .x = g.right_boundary, .y = y - 1, .clear_wrapped_row = y };
        }
        return g.wrappedPlan(y);
    }
    fn wrappedPlan(g: BackspaceGeometry, y: isize) BackspacePlan {
        if (y == g.scroll_top) return .{ .x = g.right_boundary, .y = g.scroll_bottom };
        if (y > g.scroll_top) return .{ .x = g.right_boundary, .y = y - 1, .clear_wrapped_row = y };
        return .{ .x = g.right_boundary, .y = g.scroll_bottom, .clear_wrapped_row = if (g.scroll_bottom == y) null else g.scroll_bottom };
    }
};
pub fn executeControl(t: anytype, byte: u8) anyerror!void {
    switch (byte) {
        0x00 => {},
        0x07 => t.emit(.{ .kind = .bell }),
        0x08 => try performBackspace(t),
        0x09 => {
            const b = t.buffer();
            const old_x = b.x;
            b.x = b.nextTabStop(b.x, t.margin_mode);
            b.wrap_pending = false;
            p.recordSelectorOwnerRelativeForwardMotion(t, old_x);
        },
        0x0a, 0x0b, 0x0c => {
            if (t.line_feed_mode) try carriageReturn(t);
            try lineFeed(t);
        },
        0x0d => try carriageReturn(t),
        0x0e => t.gl_level = 1,
        0x0f => t.gl_level = 0,
        0x84 => try indexLineFeed(t),
        0x85 => {
            try carriageReturn(t);
            try indexLineFeed(t);
        },
        0x88 => try t.buffer().setTabStop(t.buffer().x),
        0x8d => try reverseLineFeed(t),
        else => {},
    }
}
pub fn carriageReturn(t: anytype) !void {
    const b = t.buffer();
    const old_x = b.x;
    const old_y = b.y;
    b.x = if (t.margin_mode and b.x >= b.margin_left) b.margin_left else 0;
    b.wrap_pending = false;
    t.print_state.noWrapParkedAfterPrint = false;
    p.recordSelectorOwnerStrictLeftReposition(t, old_x, old_y);
}
pub fn performBackspace(t: anytype) !void {
    const b = t.buffer();
    if (b.cols <= 0 or b.rows <= 0) return;
    const old_x = b.x;
    const old_y = b.y;
    const narrow = t.hasNarrowMargins();
    const geometry = BackspaceGeometry{ .screen_columns = .{ .first = 0, .last = b.cols - 1 }, .vertical_clamp = if (t.origin_mode) .{ .first = b.scroll_top, .last = b.scroll_bottom } else .{ .first = 0, .last = b.rows - 1 }, .left_boundary = if (narrow) b.margin_left else 0, .right_boundary = if (narrow) b.margin_right else b.cols - 1, .scroll_top = b.scroll_top, .scroll_bottom = b.scroll_bottom, .margin_mode = narrow, .reverse = t.reverse_wraparound };
    const plan = geometry.plan(b.x, b.y, b.wrap_pending);
    b.x = plan.x;
    b.y = plan.y;
    b.wrap_pending = false;
    p.recordSelectorOwnerRelativeBackwardMotion(t, old_x, old_y);
    if (plan.clear_wrapped_row) |row| if (!t.margin_mode) {
        b.liveLine(row).setWrapped(false);
        t.markDirty(b.y_base + row);
    };
}

pub fn clearActiveReverseIndexOwnerRefreshWitness(t: anytype) void {
    p.clearOptional(t.allocator, p.reverseWitness(t));
    t.print_state.reverseIndexBufferDepartureOwner = null;
    p.clearOptional(t.allocator, p.insertWitness(t));
}
pub fn clearReverseIndexOwnerRefreshWitnesses(t: anytype) void {
    const s = &t.print_state;
    inline for (.{ "normalReverseIndexOwnerRefreshWitness", "alternateReverseIndexOwnerRefreshWitness", "normalInsertLineOwnerRefreshWitness", "alternateInsertLineOwnerRefreshWitness" }) |name|
        p.clearOptional(t.allocator, &@field(s, name));
    s.reverseIndexBufferDepartureOwner = null;
}
fn sameContent(value: Value, owned: *const p.OwnedCell) bool {
    return value.cell.scalar == owned.cell.scalar and value.cell.width == owned.cell.width and p.extrasEqual(value.extras, owned.extras);
}
fn validScalar(scalar: u32) bool {
    return scalar <= 0x10ffff and !(scalar >= 0xd800 and scalar <= 0xdfff);
}
pub fn reverseIndexOwnerRefreshIsDisplaced(t: anytype) bool {
    const b = t.buffer();
    if (b.scroll_top >= b.scroll_bottom) return false;
    const refresh = p.reverseWitness(t).* orelse return false;
    if (refresh.activationSerial != t.print_state.bufferActivationSerial or refresh.cols != b.cols or
        refresh.rows != b.rows or refresh.isAlternateBuffer != t.is_alternate) return false;
    const line = b.line(refresh.absoluteRow) orelse return false;
    if (refresh.leadColumn < 0 or refresh.leadColumn >= line.count()) return false;
    return !sameContent(line.get(refresh.leadColumn), &refresh.cell);
}
pub fn finishPrintReverseIndexOwnerRefresh(t: anytype, preserving_displaced: bool, printed_row: isize, printed_col: isize) void {
    p.clearOptional(t.allocator, p.insertWitness(t));
    t.print_state.reverseIndexBufferDepartureOwner = null;
    const refresh = p.reverseWitness(t).*;
    const at_coordinate = if (refresh) |value| printed_row == value.absoluteRow and printed_col == value.leadColumn else false;
    if (!preserving_displaced or !at_coordinate or !reverseIndexOwnerRefreshIsDisplaced(t))
        p.clearOptional(t.allocator, p.reverseWitness(t));
}
pub fn reverseIndexOwnerRefreshSnapshot(t: anytype, absolute_row: isize, lead_column: isize, line: *Line, cell: Value, authority: p.Authority, advanced: bool, tracks_width: bool) !p.ReverseOwner {
    const b = t.buffer();
    const captured = try p.OwnedCell.init(t.allocator, cell);
    return .{ .absoluteRow = absolute_row, .leadColumn = lead_column, .line = line.retain(), .cell = captured, .selectorAuthority = authority, .selectorOwnerAdvancedByRelativeMotion = advanced, .selectorRelocationTracksWidthChange = tracks_width, .activationSerial = t.print_state.bufferActivationSerial, .cols = b.cols, .rows = b.rows, .isAlternateBuffer = t.is_alternate };
}
pub const RebaseOptions = struct { allowCrossActivation: bool = false, allowCoordinateChange: bool = false };
pub fn rebaseActiveReverseIndexOwnerRefreshWitness(t: anytype, options: RebaseOptions) !void {
    const b = t.buffer();
    const refresh = p.reverseWitness(t).* orelse return;
    if ((!options.allowCrossActivation and refresh.activationSerial != t.print_state.bufferActivationSerial) or
        refresh.cols != b.cols or refresh.rows != b.rows or refresh.isAlternateBuffer != t.is_alternate) return;
    const cluster = p.validatedLastCluster(t) orelse return;
    if (!options.allowCoordinateChange and (t.print_state.lastWrite.row != refresh.absoluteRow or cluster.leadColumn != refresh.leadColumn)) return;
    const replacement = try reverseIndexOwnerRefreshSnapshot(t, t.print_state.lastWrite.row, cluster.leadColumn, cluster.line, cluster.cell, t.print_state.presentationSelectorAuthority, t.print_state.selectorOwnerAdvancedByRelativeMotion, t.print_state.selectorRelocationTracksWidthChange);
    p.clearOptional(t.allocator, p.reverseWitness(t));
    p.reverseWitness(t).* = replacement;
}
pub fn captureReverseIndexBufferDeparture(t: anytype) !void {
    try rebaseActiveReverseIndexOwnerRefreshWitness(t, .{ .allowCoordinateChange = true });
    const b = t.buffer();
    const cluster = p.validatedLastCluster(t) orelse {
        t.print_state.reverseIndexBufferDepartureOwner = null;
        return;
    };
    if (cluster.cell.cell.scalar == 0) {
        t.print_state.reverseIndexBufferDepartureOwner = null;
        return;
    }
    t.print_state.reverseIndexBufferDepartureOwner = .{ .absoluteRow = b.y_base + cluster.row, .leadColumn = cluster.leadColumn, .activationSerial = t.print_state.bufferActivationSerial, .cols = b.cols, .rows = b.rows, .isAlternateBuffer = t.is_alternate };
}

pub fn engineScrollUp(t: anytype, mark_wrapped: bool, clear_new: bool, harden_destinations: bool) anyerror!void {
    const b = t.buffer();
    const fill = t.eraseCell();
    const preserves_generation = t.hasNarrowMargins();
    if (preserves_generation) {
        try scrollNarrowSlices(t, .toward_top, fill, mark_wrapped, harden_destinations);
    } else {
        const whole_viewport = b.canScrollFullScreenIntoScrollback();
        try b.scrollUp(fill, mark_wrapped, clear_new);
        t.synchronizeBlockRowsToScrollback();
        if (!whole_viewport) t.markAllDirty();
    }
    if (!preserves_generation) {
        for (t.print_state.marginDeleteGenerations.items) |*generation| generation.deinit(t.allocator);
        t.print_state.marginDeleteGenerations.clearRetainingCapacity();
    }
    p.invalidateClusterContinuation(t, false);
}
pub fn engineScrollDown(t: anytype, harden_destinations: bool) anyerror!void {
    const b = t.buffer();
    const narrow = t.hasNarrowMargins();
    const witness = if (!narrow and b.scroll_bottom == b.rows - 1) b.liveLine(b.rows - 1).retain() else null;
    defer if (witness) |line| line.release();
    if (narrow) try scrollNarrowSlices(t, .toward_bottom, t.eraseCell(), false, harden_destinations) else {
        try b.scrollDown(t.eraseCell());
        t.markAllDirty();
    }
    if (witness) |line| rebindMarginDeleteGenerationWitnesses(t, line);
    p.invalidateClusterContinuation(t, false);
}
pub fn rebindMarginDeleteGenerationWitnesses(t: anytype, old_bottom: *Line) void {
    const b = t.buffer();
    if (b.scroll_bottom != b.rows - 1) return;
    const current = b.liveLine(b.rows - 1);
    if (current == old_bottom) return;
    for (t.print_state.marginDeleteGenerations.items) |*generation| {
        if (generation.witnessLine == old_bottom) {
            generation.witnessLine.release();
            generation.witnessLine = current.retain();
        }
    }
}
pub const SliceDirection = enum { toward_top, toward_bottom };
pub fn scrollNarrowSlices(t: anytype, direction: SliceDirection, fill: Cell, wrapped: bool, harden: bool) !void {
    const b = t.buffer();
    if (b.scroll_top > b.scroll_bottom or b.margin_left > b.margin_right or b.scroll_top < 0 or b.scroll_bottom >= b.rows or
        b.margin_left < 0 or b.margin_right >= b.cols) return;
    const columns = p.Bounds{ .first = b.margin_left, .last = b.margin_right };
    const row_count: usize = @intCast(b.scroll_bottom - b.scroll_top + 1);
    const retires_outside = if (direction == .toward_bottom)
        if (p.validatedLastCluster(t)) |cluster| cluster.row == b.scroll_top else false
    else
        false;
    for (0..row_count) |index| {
        const line = b.liveLine(b.scroll_top + @as(isize, @intCast(index)));
        if (line.images) |images| for (images.items) |image| {
            if (!image.is_kitty or (!columns.contains(image.col) and !retires_outside)) continue;
            var found = false;
            for (t.print_state.kittyDisplayReflowImages.items) |registered| {
                if (registered.render_id == image.render_id) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                try t.print_state.kittyDisplayReflowImages.ensureUnusedCapacity(t.allocator, 1);
                t.print_state.kittyDisplayReflowImages.appendAssumeCapacity(image.clone());
            }
        };
        const destination = if (direction == .toward_top) index + 1 < row_count else index > 0;
        if (harden and destination and line.is_wrapped and
            std.mem.indexOfScalar(*Line, t.print_state.activeMarginReflowBoundaries.items, line) == null)
        {
            try t.print_state.activeMarginReflowBoundaries.ensureUnusedCapacity(t.allocator, 1);
            t.print_state.activeMarginReflowBoundaries.appendAssumeCapacity(line.retain());
        }
    }
    const snapshots = try t.allocator.alloc(*Line, row_count);
    var populated: usize = 0;
    defer {
        for (snapshots[0..populated]) |line| line.release();
        t.allocator.free(snapshots);
    }
    for (snapshots, 0..) |*snapshot, index| {
        snapshot.* = try b.liveLine(b.scroll_top + @as(isize, @intCast(index))).clone();
        populated += 1;
    }
    for (0..row_count) |index| {
        const line = b.liveLine(b.scroll_top + @as(isize, @intCast(index)));
        const source: isize = @as(isize, @intCast(index)) + (if (direction == .toward_top) @as(isize, 1) else -1);
        if (source >= 0 and source < row_count) try line.copyColumns(snapshots[@intCast(source)], columns.first, columns.last) else try line.fillColumns(columns.first, columns.last, fill);
    }
    b.liveLine(if (direction == .toward_top) b.scroll_bottom else b.scroll_top).setWrapped(wrapped);
    t.markDirtyRange(b.y_base + b.scroll_top, b.y_base + b.scroll_bottom);
}

const PreservedMotion = struct {
    scalar: ?u32,
    authority: p.Authority,
    displaced: ?p.DisplacedCell,
    wrapped_from_right: bool,
    advanced_fresh: bool,
    advanced_pending: bool,
    fn capture(s: *p.State) PreservedMotion {
        const value = PreservedMotion{ .scalar = s.lastPrintedScalar, .authority = s.presentationSelectorAuthority, .displaced = s.lastWriteDisplacedCell, .wrapped_from_right = s.lastPrintWrappedFromRightOfMargin, .advanced_fresh = s.lastPrintAdvancedToFreshRow, .advanced_pending = s.lastPrintAdvancedFromCurrentPendingOwner };
        s.lastWriteDisplacedCell = null; // Move ownership across scroll invalidation.
        return value;
    }
    fn restore(self: *PreservedMotion, t: anytype) void {
        const s = &t.print_state;
        s.lastPrintedScalar = self.scalar;
        s.presentationSelectorAuthority = self.authority;
        p.clearOptional(t.allocator, &s.lastWriteDisplacedCell);
        s.lastWriteDisplacedCell = self.displaced;
        self.displaced = null;
        s.lastPrintWrappedFromRightOfMargin = self.wrapped_from_right;
        s.lastPrintAdvancedToFreshRow = self.advanced_fresh;
        s.lastPrintAdvancedFromCurrentPendingOwner = self.advanced_pending;
    }
};
fn crossedActivationAllowsReverseIndexOwnerRefresh(t: anytype, refresh: p.ReverseOwner) bool {
    const b = t.buffer();
    if (t.is_alternate) return false;
    const historical = refresh.absoluteRow < b.y_base;
    const departure = t.print_state.reverseIndexBufferDepartureOwner orelse return !historical;
    if (departure.activationSerial +% 1 != t.print_state.bufferActivationSerial or departure.cols != b.cols or
        departure.rows != b.rows or departure.isAlternateBuffer == t.is_alternate) return !historical;
    return historical and departure.absoluteRow == refresh.absoluteRow and departure.leadColumn == refresh.leadColumn;
}
fn crossedActivationHistoricalOwnerRefresh(t: anytype) !?p.ReverseOwner {
    const b = t.buffer();
    const departure = t.print_state.reverseIndexBufferDepartureOwner orelse return null;
    if (departure.activationSerial +% 1 != t.print_state.bufferActivationSerial or departure.cols != b.cols or
        departure.rows != b.rows or departure.isAlternateBuffer == t.is_alternate or departure.absoluteRow >= b.y_base) return null;
    const line = b.line(departure.absoluteRow) orelse return null;
    if (departure.leadColumn < 0 or departure.leadColumn >= line.count()) return null;
    const cell = line.get(departure.leadColumn);
    if (cell.cell.width <= 0 or cell.cell.scalar == 0) return null;
    return try reverseIndexOwnerRefreshSnapshot(t, departure.absoluteRow, departure.leadColumn, line, cell, p.selectorAuthority(cell), false, departure.absoluteRow != b.y_base + b.y);
}
fn expireCrossedReverseIndexOwnerRefresh(t: anytype) void {
    const s = &t.print_state;
    const preserve_pending = p.pendingWrapOwnerStillOccupiesDeparture(t);
    p.clearOptional(t.allocator, p.reverseWitness(t));
    s.lastPrintedScalar = null;
    s.presentationSelectorAuthority = .unavailable;
    s.lastWrite = .{};
    p.clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastPrintWrappedFromRightOfMargin = false;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    s.selectorOwnerAdvancedByRelativeMotion = false;
    s.selectorRelocationTracksWidthChange = false;
    s.selectorExpansionSettledPhysicalPending = null;
    if (!preserve_pending) p.clearOptional(t.allocator, &s.pendingWrapOwnerWitness);
}
fn reverseIndexOwnerRefreshCandidate(t: anytype) !?p.ReverseOwner {
    const b = t.buffer();
    const columns = if (t.hasNarrowMargins()) p.Bounds{ .first = b.margin_left, .last = b.margin_right } else p.Bounds{ .first = 0, .last = b.cols - 1 };
    try rebaseActiveReverseIndexOwnerRefreshWitness(t, .{});
    if (p.reverseWitness(t).*) |*refresh| {
        if (refresh.activationSerial != t.print_state.bufferActivationSerial) return null;
        if (refresh.cols == b.cols and refresh.rows == b.rows and refresh.isAlternateBuffer == t.is_alternate and
            refresh.absoluteRow >= b.y_base + b.scroll_top and refresh.absoluteRow <= b.y_base + b.scroll_bottom and columns.contains(refresh.leadColumn))
            return try refresh.clone(t.allocator);
    }
    if (p.validatedLastCluster(t)) |cluster| {
        if (cluster.row >= b.scroll_top and cluster.row <= b.scroll_bottom and columns.contains(cluster.leadColumn)) {
            var refresh = try reverseIndexOwnerRefreshSnapshot(t, t.print_state.lastWrite.row, cluster.leadColumn, cluster.line, cluster.cell, t.print_state.presentationSelectorAuthority, t.print_state.selectorOwnerAdvancedByRelativeMotion, t.print_state.selectorRelocationTracksWidthChange);
            errdefer refresh.deinit(t.allocator);
            const returned = try refresh.clone(t.allocator);
            p.clearOptional(t.allocator, p.reverseWitness(t));
            p.reverseWitness(t).* = refresh;
            return returned;
        }
    }
    return null;
}
fn adoptOwner(t: anytype, absolute_row: isize, lead: isize, cell: Value, authority: p.Authority, advanced: bool, tracks_width: bool) void {
    const b = t.buffer();
    const s = &t.print_state;
    p.backwardWitness(t).* = null;
    s.lastPrintedScalar = cell.cell.scalar;
    s.presentationSelectorAuthority = authority;
    s.lastWrite = .{ .row = absolute_row, .x = lead, .cols = b.cols, .rows = b.rows };
    p.clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastPrintWrappedFromRightOfMargin = false;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    s.selectorOwnerAdvancedByRelativeMotion = advanced;
    s.selectorRelocationTracksWidthChange = tracks_width;
    s.selectorExpansionSettledPhysicalPending = null;
    p.clearOptional(t.allocator, &s.pendingWrapOwnerWitness);
}
pub fn restoreReverseIndexOwnerRefreshWitnessForFollower(t: anytype) !bool {
    const b = t.buffer();
    if (try crossedActivationHistoricalOwnerRefresh(t)) |historical| {
        p.clearOptional(t.allocator, p.reverseWitness(t));
        p.reverseWitness(t).* = historical;
    }
    const refresh = p.reverseWitness(t).* orelse return false;
    if (refresh.cols != b.cols or refresh.rows != b.rows or refresh.isAlternateBuffer != t.is_alternate) return false;
    const crossed = refresh.activationSerial != t.print_state.bufferActivationSerial;
    if (crossed and !crossedActivationAllowsReverseIndexOwnerRefresh(t, refresh)) {
        expireCrossedReverseIndexOwnerRefresh(t);
        return false;
    }
    const line = b.line(refresh.absoluteRow) orelse {
        if (crossed) expireCrossedReverseIndexOwnerRefresh(t);
        return false;
    };
    if (line != refresh.line or refresh.leadColumn < 0 or refresh.leadColumn >= line.count()) {
        if (crossed) expireCrossedReverseIndexOwnerRefresh(t);
        return false;
    }
    const cell = line.get(refresh.leadColumn);
    if (!sameContent(cell, &refresh.cell) or !validScalar(cell.cell.scalar)) {
        if (crossed) expireCrossedReverseIndexOwnerRefresh(t);
        return false;
    }
    adoptOwner(t, refresh.absoluteRow, refresh.leadColumn, cell, refresh.selectorAuthority, refresh.selectorOwnerAdvancedByRelativeMotion, refresh.selectorRelocationTracksWidthChange or refresh.absoluteRow != b.y_base + b.y);
    try rebaseActiveReverseIndexOwnerRefreshWitness(t, .{ .allowCrossActivation = true });
    return true;
}
fn refreshOwnerAfterTopReverseIndex(t: anytype, refresh: *const p.ReverseOwner) !void {
    const b = t.buffer();
    const line = b.line(refresh.absoluteRow) orelse return;
    if (refresh.leadColumn < 0 or refresh.leadColumn >= line.count()) return;
    const cell = line.get(refresh.leadColumn);
    if (cell.cell.width <= 0 or cell.cell.scalar == 0 or sameContent(cell, &refresh.cell) or !validScalar(cell.cell.scalar)) return;
    const tracks = refresh.absoluteRow != b.y_base + b.y;
    const replacement = try reverseIndexOwnerRefreshSnapshot(t, refresh.absoluteRow, refresh.leadColumn, line, cell, p.selectorAuthority(cell), false, tracks);
    adoptOwner(t, refresh.absoluteRow, refresh.leadColumn, cell, p.selectorAuthority(cell), false, tracks);
    p.clearOptional(t.allocator, p.reverseWitness(t));
    p.reverseWitness(t).* = replacement;
}
const ForwardOwner = struct {
    absolute_row: isize,
    visible_row: isize,
    lead_column: isize,
    cell: p.OwnedCell,
    cols: isize,
    rows: isize,
    alternate: bool,
    fn deinit(self: *ForwardOwner, a: A) void {
        self.cell.deinit(a);
    }
};
fn forwardLineScrollOwnerCandidate(t: anytype) !?ForwardOwner {
    const b = t.buffer();
    const cluster = p.validatedLastCluster(t) orelse return null;
    return .{ .absolute_row = t.print_state.lastWrite.row, .visible_row = cluster.row, .lead_column = cluster.leadColumn, .cell = try p.OwnedCell.init(t.allocator, cluster.cell), .cols = b.cols, .rows = b.rows, .alternate = t.is_alternate };
}
fn refreshOwnerAfterForwardLineScroll(t: anytype, owner: *const ForwardOwner) void {
    const b = t.buffer();
    const columns = if (t.hasNarrowMargins()) p.Bounds{ .first = b.margin_left, .last = b.margin_right } else p.Bounds{ .first = 0, .last = b.cols - 1 };
    if (owner.cols != b.cols or owner.rows != b.rows or owner.alternate != t.is_alternate or
        owner.visible_row < b.scroll_top or owner.visible_row > b.scroll_bottom or !columns.contains(owner.lead_column)) return;
    const line = b.line(owner.absolute_row) orelse return;
    if (owner.lead_column < 0 or owner.lead_column >= line.count()) return;
    const cell = line.get(owner.lead_column);
    if (!t.is_alternate and cell.cell.width == 0) {
        p.invalidateClusterContinuation(t, false);
        return;
    }
    if ((sameContent(cell, &owner.cell) and t.is_alternate) or cell.cell.width <= 0 or cell.cell.scalar == 0 or !validScalar(cell.cell.scalar)) return;
    clearActiveReverseIndexOwnerRefreshWitness(t);
    const cursor_abs = b.y_base + b.y;
    const beyond = cursor_abs == owner.absolute_row and b.x > owner.lead_column + cell.cell.width;
    adoptOwner(t, owner.absolute_row, owner.lead_column, cell, p.selectorAuthority(cell), beyond, cursor_abs != owner.absolute_row or beyond);
}
pub fn refreshInsertLineOwnerAfterUpwardLineRotation(t: anytype) !void {
    const b = t.buffer();
    const witness = p.insertWitness(t).* orelse return;
    if (witness.cols != b.cols or witness.rows != b.rows or witness.isAlternateBuffer != t.is_alternate) return;
    const line = b.line(witness.absoluteRow) orelse return;
    if (witness.leadColumn < 0 or witness.leadColumn >= line.count()) return;
    const cell = line.get(witness.leadColumn);
    if (cell.cell.width <= 0 or cell.cell.scalar == 0 or !validScalar(cell.cell.scalar)) return;
    const absolute = witness.absoluteRow;
    const lead = witness.leadColumn;
    clearActiveReverseIndexOwnerRefreshWitness(t);
    const cursor_abs = b.y_base + b.y;
    const beyond = cursor_abs == absolute and b.x > lead + cell.cell.width;
    adoptOwner(t, absolute, lead, cell, p.selectorAuthority(cell), beyond, cursor_abs != absolute or beyond);
}
pub fn consumeLineMotionEdgeState(t: anytype, normalize_column: bool) void {
    const b = t.buffer();
    if (normalize_column and b.x >= b.cols) b.x = b.cols - 1;
    b.wrap_pending = false;
    t.print_state.noWrapParkedAfterPrint = false;
}
pub fn lineFeed(t: anytype) anyerror!void {
    const b = t.buffer();
    const old_row = b.y_base + b.y;
    var owner = try forwardLineScrollOwnerCandidate(t);
    defer if (owner) |*value| value.deinit(t.allocator);
    var scrolled = false;
    const eligible = b.x >= b.margin_left and b.x <= b.margin_right;
    {
        var retained = PreservedMotion.capture(&t.print_state);
        defer retained.restore(t);
        if (b.y == b.scroll_bottom) {
            if (eligible) {
                scrolled = true;
                try engineScrollUp(t, false, true, true);
            }
        } else if (b.y < b.rows - 1) b.y += 1;
    }
    consumeLineMotionEdgeState(t, true);
    p.recordSelectorOwnerVerticalMotion(t, old_row);
    if (scrolled) {
        if (owner) |*value| refreshOwnerAfterForwardLineScroll(t, value) else try refreshInsertLineOwnerAfterUpwardLineRotation(t);
    }
    t.markDirty(old_row);
    t.markDirty(b.y_base + b.y);
}
pub fn indexLineFeed(t: anytype) anyerror!void {
    const b = t.buffer();
    if (t.origin_mode) b.y = @min(b.scroll_bottom, @max(b.scroll_top, b.y));
    const old_row = b.y_base + b.y;
    var owner = try forwardLineScrollOwnerCandidate(t);
    defer if (owner) |*value| value.deinit(t.allocator);
    var scrolled = false;
    consumeLineMotionEdgeState(t, true);
    const eligible = b.x >= b.margin_left and b.x <= b.margin_right;
    {
        var retained = PreservedMotion.capture(&t.print_state);
        defer retained.restore(t);
        if (b.y >= b.scroll_bottom) {
            if (eligible) {
                scrolled = true;
                try engineScrollUp(t, false, true, true);
            }
        } else b.y += 1;
    }
    p.recordSelectorOwnerVerticalMotion(t, old_row);
    if (scrolled) {
        if (owner) |*value| refreshOwnerAfterForwardLineScroll(t, value) else try refreshInsertLineOwnerAfterUpwardLineRotation(t);
    }
    t.markDirty(old_row);
    t.markDirty(b.y_base + b.y);
}
pub fn advanceOneRow(t: anytype) anyerror!void {
    const b = t.buffer();
    const old_row = b.y;
    if (b.y == b.scroll_bottom) {
        try engineScrollUp(t, false, true, false);
        b.y = b.scroll_bottom;
    } else if (b.y < b.rows - 1) b.y += 1;
    b.wrap_pending = false;
    p.invalidateClusterContinuation(t, false);
    t.markDirty(b.y_base + old_row);
    t.markDirty(b.y_base + b.y);
}
pub fn reverseLineFeed(t: anytype) anyerror!void {
    const b = t.buffer();
    if (t.origin_mode) b.y = @min(b.scroll_bottom, @max(b.scroll_top, b.y));
    const old_row = b.y_base + b.y;
    consumeLineMotionEdgeState(t, true);
    const eligible = b.x >= b.margin_left and b.x <= b.margin_right;
    var refresh: ?p.ReverseOwner = null;
    defer if (refresh) |*value| value.deinit(t.allocator);
    {
        var retained = PreservedMotion.capture(&t.print_state);
        defer retained.restore(t);
        if (b.y == b.scroll_top) {
            if (eligible) {
                refresh = try reverseIndexOwnerRefreshCandidate(t);
                try engineScrollDown(t, true);
            }
        } else if (b.y > 0) b.y -= 1;
    }
    p.recordSelectorOwnerVerticalMotion(t, old_row);
    if (refresh) |*value| try refreshOwnerAfterTopReverseIndex(t, value);
    t.markDirty(old_row);
    t.markDirty(b.y_base + b.y);
}

const TestTerminal = struct {
    allocator: A,
    normal: @import("buffer.zig").Buffer,
    alternate: @import("buffer.zig").Buffer,
    print_state: p.State = .{},
    is_alternate: bool = false,
    margin_mode: bool = false,
    origin_mode: bool = false,
    reverse_wraparound: bool = false,
    line_feed_mode: bool = false,
    gl_level: u8 = 0,
    pen: Cell = .{},
    marks: usize = 0,
    bells: usize = 0,
    fn init(a: A, cols: isize, rows: isize, cap: isize) !TestTerminal {
        var normal = try @import("buffer.zig").Buffer.init(a, cols, rows, true, cap);
        errdefer normal.deinit();
        normal.margin_right = normal.cols - 1;
        return .{ .allocator = a, .normal = normal, .alternate = try @import("buffer.zig").Buffer.init(a, cols, rows, true, 1) };
    }
    fn deinit(t: *TestTerminal) void {
        t.print_state.deinit(t.allocator);
        t.normal.deinit();
        t.alternate.deinit();
    }
    pub fn buffer(t: *TestTerminal) *@import("buffer.zig").Buffer {
        return if (t.is_alternate) &t.alternate else &t.normal;
    }
    pub fn hasNarrowMargins(t: *TestTerminal) bool {
        const b = t.buffer();
        return t.margin_mode and (b.margin_left > 0 or b.margin_right < b.cols - 1);
    }
    pub fn eraseCell(t: *TestTerminal) Cell {
        return .{ .bg = t.pen.bg };
    }
    pub fn synchronizeBlockRowsToScrollback(_: *TestTerminal) void {}
    pub fn markAllDirty(t: *TestTerminal) void {
        t.marks += 1;
    }
    pub fn markDirty(t: *TestTerminal, _: isize) void {
        t.marks += 1;
    }
    pub fn markDirtyRange(t: *TestTerminal, _: isize, _: isize) void {
        t.marks += 1;
    }
    pub fn emit(t: *TestTerminal, _: struct { kind: enum { bell } }) void {
        t.bells += 1;
    }
};
fn seedOwner(t: *TestTerminal, row: isize, col: isize, value: Value) !void {
    const b = t.buffer();
    try b.line(row).?.set(col, value);
    t.print_state.lastPrintedScalar = value.cell.scalar;
    t.print_state.lastWrite = .{ .row = row, .x = col, .cols = b.cols, .rows = b.rows };
    t.print_state.presentationSelectorAuthority = p.selectorAuthority(value);
}
test "backspace resolves physical pending and margin bounds independently" {
    const g = BackspaceGeometry{ .screen_columns = .{ .first = 0, .last = 9 }, .vertical_clamp = .{ .first = 0, .last = 3 }, .left_boundary = 2, .right_boundary = 5, .scroll_top = 1, .scroll_bottom = 3, .margin_mode = true, .reverse = false };
    try std.testing.expectEqual(@as(isize, 6), g.plan(7, 1, true).x);
    try std.testing.expectEqual(@as(isize, 4), g.plan(5, 1, true).x);
    try std.testing.expectEqual(@as(isize, 8), g.plan(10, 1, true).x);
    var reverse = g;
    reverse.reverse = true;
    try std.testing.expectEqual(@as(isize, 9), reverse.plan(10, 1, true).x);
    try std.testing.expectEqual(@as(isize, 3), reverse.plan(2, 1, false).y);
    try std.testing.expectEqual(@as(isize, 0), reverse.plan(0, 0, false).y);
    try std.testing.expectEqual(@as(isize, 0), reverse.plan(0, 0, false).x);
}
test "reverse backspace clears whole-row wrapping and preserves rectangular wrapping" {
    var t = try TestTerminal.init(std.testing.allocator, 8, 3, 10);
    defer t.deinit();
    t.reverse_wraparound = true;
    t.normal.x = 0;
    t.normal.y = 1;
    t.normal.liveLine(1).setWrapped(true);
    try performBackspace(&t);
    try std.testing.expectEqual(@as(isize, 7), t.normal.x);
    try std.testing.expectEqual(@as(isize, 0), t.normal.y);
    try std.testing.expect(!t.normal.liveLine(1).is_wrapped);
    t.margin_mode = true;
    t.normal.margin_left = 2;
    t.normal.margin_right = 5;
    t.normal.x = 2;
    t.normal.y = 1;
    t.normal.liveLine(1).setWrapped(true);
    try performBackspace(&t);
    try std.testing.expect(t.normal.liveLine(1).is_wrapped);
    try std.testing.expectEqual(@as(isize, 5), t.normal.x);
}
test "LF raw pending gate differs from IND normalization and RI restores owner coordinate" {
    var t = try TestTerminal.init(std.testing.allocator, 8, 3, 10);
    defer t.deinit();
    t.normal.x = 8;
    t.normal.y = 2;
    t.normal.wrap_pending = true;
    try lineFeed(&t);
    try std.testing.expectEqual(@as(isize, 0), t.normal.y_base);
    try std.testing.expectEqual(@as(isize, 7), t.normal.x);
    t.normal.x = 8;
    t.normal.wrap_pending = true;
    try indexLineFeed(&t);
    try std.testing.expectEqual(@as(isize, 1), t.normal.y_base);
    try t.normal.hardReset();
    try t.normal.liveLine(0).setCell(0, .{ .scalar = 'A' });
    try seedOwner(&t, 1, 0, .{ .cell = .{ .scalar = 'B' }, .extras = &.{0x301} });
    t.normal.x = 0;
    t.normal.y = 0;
    try reverseLineFeed(&t);
    try std.testing.expectEqual(@as(u32, 'A'), t.print_state.lastPrintedScalar.?);
    try std.testing.expectEqual(@as(isize, 1), t.print_state.lastWrite.row);
    try std.testing.expect(p.reverseWitness(&t).*.?.line == t.normal.line(1).?);
    try std.testing.expect(try restoreReverseIndexOwnerRefreshWitnessForFollower(&t));
}
test "rectangular motion snapshots source slices and retains outside cells and row identities" {
    var t = try TestTerminal.init(std.testing.allocator, 6, 3, 10);
    defer t.deinit();
    for (0..3) |i| try t.normal.liveLine(@intCast(i)).fillCell(.{ .scalar = @intCast('A' + i) }, 0, null);
    const ids = [_]u64{ t.normal.liveLine(0).identity, t.normal.liveLine(1).identity, t.normal.liveLine(2).identity };
    t.margin_mode = true;
    t.normal.margin_left = 2;
    t.normal.margin_right = 3;
    t.normal.liveLine(0).setWrapped(true);
    t.normal.liveLine(1).setWrapped(true);
    try engineScrollUp(&t, false, true, true);
    try std.testing.expectEqual(@as(u32, 'A'), t.normal.liveLine(0).cell(0).scalar);
    try std.testing.expectEqual(@as(u32, 'B'), t.normal.liveLine(0).cell(2).scalar);
    try std.testing.expectEqual(@as(u32, 'C'), t.normal.liveLine(1).cell(2).scalar);
    try std.testing.expectEqual(@as(u32, 0), t.normal.liveLine(2).cell(2).scalar);
    try std.testing.expectEqual(@as(usize, 2), t.print_state.activeMarginReflowBoundaries.items.len);
    for (ids, 0..) |id, i| try std.testing.expectEqual(id, t.normal.liveLine(@intCast(i)).identity);
    try engineScrollDown(&t, true);
    try std.testing.expectEqual(@as(u32, 'B'), t.normal.liveLine(1).cell(2).scalar);
    try std.testing.expectEqual(@as(u32, 'C'), t.normal.liveLine(2).cell(2).scalar);
}
test "dormant reverse owner keeps payload alive and revives only on matching row identity" {
    var t = try TestTerminal.init(std.testing.allocator, 8, 3, 10);
    defer t.deinit();
    try seedOwner(&t, 0, 0, .{ .cell = .{ .scalar = 'e' }, .extras = &.{0x301} });
    const original = t.normal.liveLine(0);
    try reverseLineFeed(&t);
    try std.testing.expect(reverseIndexOwnerRefreshIsDisplaced(&t));
    try std.testing.expect(!try restoreReverseIndexOwnerRefreshWitnessForFollower(&t));
    try t.normal.scrollUpRegionOnly(.{});
    try std.testing.expect(t.normal.liveLine(0) == original);
    try std.testing.expect(try restoreReverseIndexOwnerRefreshWitnessForFollower(&t));
    try std.testing.expectEqualSlices(u32, &.{0x301}, p.reverseWitness(&t).*.?.cell.extras.?);
    finishPrintReverseIndexOwnerRefresh(&t, true, 0, 0);
    try std.testing.expect(p.reverseWitness(&t).* == null);
}
fn motionAllocationTrace(a: A) !void {
    var t = try TestTerminal.init(a, 8, 3, 10);
    defer t.deinit();
    try seedOwner(&t, 0, 0, .{ .cell = .{ .scalar = 'e' }, .extras = &.{0x301} });
    try reverseLineFeed(&t);
    try t.normal.scrollUpRegionOnly(.{});
    _ = try restoreReverseIndexOwnerRefreshWitnessForFollower(&t);
    try captureReverseIndexBufferDeparture(&t);
    t.margin_mode = true;
    t.normal.margin_left = 1;
    t.normal.margin_right = 4;
    try engineScrollDown(&t, true);
    try engineScrollUp(&t, false, true, true);
    try executeControl(&t, 0x09);
    try executeControl(&t, 0x0d);
    try executeControl(&t, 0x07);
    try executeControl(&t, 0x88);
}
test "line motion allocator failures release snapshots and retained owner payloads" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, motionAllocationTrace, .{});
}

// Independent frozen Swift control oracle and compiler/source receipts:
// /private/tmp/cmdy-zig-engine-20260911-01/buffer-motion-oracle-02/
const BackspaceReferenceRng = struct {
    state: u64,
    fn next(self: *BackspaceReferenceRng, limit: usize) usize {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @intCast((self.state >> 32) % limit);
    }
};
test "256 backspace geometries match frozen Swift including pending outside coordinates" {
    const expected = [_]u64{
        0x0000000f00020000,
        0x0000003f00040100,
        0x000000ff00011000,
        0x0000000300010c00,
        0x0000000f00030100,
        0x0000003f00040300,
        0x000000ff00011000,
        0x0000000300010900,
        0x0000000f00030000,
        0x0000003f00000600,
        0x000000ff00050400,
        0x0000000300010900,
        0x0000000f00030300,
        0x0000003f00020800,
        0x000000ff00050f00,
        0x0000000300010700,
        0x0000000f00030100,
        0x0000003f00021300,
        0x000000ff00060100,
        0x0000000300010400,
        0x0000000f00030000,
        0x0000003f00011000,
        0x000000ff00000000,
        0x0000000300000000,
        0x0000000f00001400,
        0x0000003f00030600,
        0x000000ff00020700,
        0x0000000300000300,
        0x0000000f00020000,
        0x0000003f00020500,
        0x000000ff00020700,
        0x0000000300010400,
        0x0000000f00000d00,
        0x0000003f00030900,
        0x000000ff00060900,
        0x0000000300000000,
        0x0000000f00010e00,
        0x0000003f00030c00,
        0x000000ff00050000,
        0x0000000300011200,
        0x0000000f00000400,
        0x0000003f00050800,
        0x000000ff00000200,
        0x0000000300010100,
        0x0000000f00030700,
        0x0000003f00050600,
        0x000000ff00020500,
        0x0000000300010700,
        0x0000000f00000000,
        0x0000003f00050700,
        0x000000ff00030100,
        0x0000000300010600,
        0x0000000f00000400,
        0x0000003f00020200,
        0x000000ff00040200,
        0x0000000300000900,
        0x0000000f00030200,
        0x0000003f00050500,
        0x000000ff00061100,
        0x0000000300000900,
        0x0000000f00000000,
        0x0000003f00030000,
        0x000000ff00050f00,
        0x0000000300000100,
        0x0000000f00020000,
        0x0000003f00000100,
        0x000000ff00060900,
        0x0000000300010000,
        0x0000000f00010500,
        0x0000003f00040200,
        0x000000ff00050e00,
        0x0000000300010200,
        0x0000000f00010400,
        0x0000003f00010c00,
        0x000000ff00040900,
        0x0000000300010a00,
        0x0000000f00010100,
        0x0000003f00040d00,
        0x0000000100000600,
        0x0000000700020600,
        0x0000001f00020400,
        0x0000007f00060600,
        0x0000000100000900,
        0x0000000700000000,
        0x0000001f00040200,
        0x0000007f00030200,
        0x0000000100000300,
        0x0000000700000500,
        0x0000001f00031300,
        0x0000007f00010d00,
        0x0000000100000600,
        0x0000000700000200,
        0x0000001f00040400,
        0x0000007f00060d00,
        0x0000000100000600,
        0x0000000700010000,
        0x0000001f00000300,
        0x0000007f00040700,
        0x0000000100000700,
        0x0000000700000000,
        0x0000001f00010f00,
        0x0000007f00000000,
        0x0000000100000400,
        0x0000000700020b00,
        0x0000001f00040200,
        0x0000007f00050800,
        0x0000000100000200,
        0x0000000700020f00,
        0x0000001f00040600,
        0x0000007f00010a00,
        0x0000000100000400,
        0x0000000700020c00,
        0x0000001f00000a00,
        0x0000007f00050400,
        0x0000000100000000,
        0x0000000700020000,
        0x0000001f00030200,
        0x0000007f00000200,
        0x0000000100000100,
        0x0000000700000b00,
        0x0000001f00040800,
        0x0000007f00040500,
        0x0000000100001200,
        0x0000000700000700,
        0x0000001f00000000,
        0x0000007f00020300,
        0x0000000100000f00,
        0x0000000700000c00,
        0x0000001f00020100,
        0x0000007f00051000,
        0x0000000100001000,
        0x0000000700000100,
        0x0000001f00020300,
        0x0000007f00060100,
        0x0000000100000c00,
        0x0000000700000200,
        0x0000001f00010400,
        0x0000007f00000000,
        0x0000000100001000,
        0x0000000700010500,
        0x0000001f00000200,
        0x0000007f00061300,
        0x0000000100000900,
        0x0000000700020000,
        0x0000001f00040400,
        0x0000007f00030400,
        0x0000000100000100,
        0x0000000700020000,
        0x0000001f00010100,
        0x0000007f00040c00,
        0x0000000100000300,
        0x0000000700000500,
        0x0000001f00000800,
        0x0000007f00000000,
        0x0000000100000800,
        0x0000000700020100,
        0x0000001f00040600,
        0x0000007f00050900,
        0x0000000100000500,
        0x0000000700010000,
        0x0000001f00030900,
        0x0000007f00030900,
        0x0000000100000600,
        0x0000000700000000,
        0x0000001f00030f00,
        0x0000007f00060a00,
        0x0000000100000300,
        0x0000000700010200,
        0x0000001f00000e00,
        0x0000007f00060700,
        0x0000000100000300,
        0x0000000700020900,
        0x0000001f00010b00,
        0x0000007f00010a00,
        0x0000000100000300,
        0x0000000700000d00,
        0x0000001f00030700,
        0x0000007f00050600,
        0x0000000100000f00,
        0x0000000700011100,
        0x0000001f00000b00,
        0x0000007f00040300,
        0x0000000100000000,
        0x0000000700010000,
        0x0000001f00010700,
        0x0000007f00020300,
        0x0000000100000e00,
        0x0000000700000b00,
        0x0000001f00030800,
        0x0000007f00030100,
        0x0000000100000000,
        0x0000000700020700,
        0x0000001f00010500,
        0x0000007f00060300,
        0x0000000100001000,
        0x0000000700000a00,
        0x0000001f00000200,
        0x0000007f00030000,
        0x0000000100000000,
        0x0000000700020800,
        0x0000001f00030200,
        0x0000007f00000200,
        0x0000000100000a00,
        0x0000000700010300,
        0x0000001f00030000,
        0x0000007f00010d00,
        0x0000000100000b00,
        0x0000000700020100,
        0x0000001f00010000,
        0x0000007f00010e00,
        0x0000000100000500,
        0x0000000700020600,
        0x0000001f00001200,
        0x0000007f00040000,
        0x0000000100000400,
        0x0000000700020400,
        0x0000001f00000d00,
        0x0000007f00060200,
        0x0000000100000400,
        0x0000000700000000,
        0x0000001f00020000,
        0x0000007f00000b00,
        0x0000000100000300,
        0x0000000700000100,
        0x0000001f00000b00,
        0x0000007f00060b00,
        0x0000000100000500,
        0x0000000700000200,
        0x0000001f00001100,
        0x0000007f00060900,
        0x0000000100000200,
        0x0000000700010100,
        0x0000001f00030000,
        0x0000007f00060400,
        0x0000000100000200,
        0x0000000700021100,
        0x0000001f00040a00,
        0x0000007f00000300,
        0x0000000100000100,
        0x0000000700010700,
        0x0000001f00000500,
        0x0000007f00010000,
        0x0000000300010000,
        0x0000000f00030d00,
        0x0000003f00050400,
        0x000000ff00000000,
        0x0000000300010000,
        0x0000000f00030b00,
        0x0000003f00040300,
        0x000000ef00030400,
        0x0000000300011100,
        0x0000000f00030b00,
        0x0000003f00050800,
        0x000000ff00040000,
        0x0000000300000c00,
        0x0000000f00030000,
    };
    for (1..257) |seed| {
        var rng = BackspaceReferenceRng{ .state = seed };
        const cols: isize = @intCast(2 + rng.next(20));
        const rows: isize = @intCast(1 + rng.next(8));
        var t = try TestTerminal.init(std.testing.allocator, cols, rows, 5);
        defer t.deinit();
        const b = &t.normal;
        b.margin_left = @intCast(rng.next(@intCast(cols)));
        b.margin_right = b.margin_left + @as(isize, @intCast(rng.next(@intCast(cols - b.margin_left))));
        b.scroll_top = @intCast(rng.next(@intCast(rows)));
        b.scroll_bottom = b.scroll_top + @as(isize, @intCast(rng.next(@intCast(rows - b.scroll_top))));
        t.margin_mode = rng.next(2) == 1;
        t.origin_mode = rng.next(2) == 1;
        t.reverse_wraparound = rng.next(2) == 1;
        b.x = @as(isize, @intCast(rng.next(@intCast(cols + 5)))) - 2;
        b.y = @as(isize, @intCast(rng.next(@intCast(rows + 4)))) - 2;
        b.wrap_pending = rng.next(2) == 1;
        for (0..@intCast(b.lineCount())) |i| b.line(@intCast(i)).?.setWrapped(true);
        try executeControl(&t, 8);
        var bits = (@as(u64, @intCast(b.x)) << 8) | (@as(u64, @intCast(b.y)) << 16);
        for (0..@intCast(b.lineCount())) |i| if (b.line(@intCast(i)).?.is_wrapped) {
            bits |= @as(u64, 1) << @as(u6, @intCast(32 + i));
        };
        if (bits != expected[seed - 1]) std.debug.print("backspace reference differs at seed {d}\n", .{seed});
        try std.testing.expectEqual(expected[seed - 1], bits);
    }
}
