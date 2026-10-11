//! Resize integration: the pure reflow map is authoritative for cells, semantic
//! anchors and suspended image placements. Host notifications see final state.
const std = @import("std");
const reflow = @import("reflow.zig");
const p = @import("printing.zig");
const protocols = @import("terminal_protocols.zig");
const Line = @import("line.zig").Line;
const A = std.mem.Allocator;

pub fn resize(t: anytype, requested_cols: isize, requested_rows: isize) anyerror!void {
    const cols = @max(2, requested_cols);
    const rows = @max(1, requested_rows);
    const old_cols = t.normal.cols;
    const old_rows = t.normal.rows;
    const old_x = t.normal.x;
    t.synchronizeBlockRowsToScrollback();
    if (t.is_alternate) {
        var suspended = try protocols.suspendKittyDisplayReflowImages(t, &t.alternate, false);
        defer suspended.deinit(t.allocator);
        errdefer protocols.restoreKittyDisplayReflowImages(t, suspended.items, &t.alternate) catch {};
        try t.alternate.resizeSimple(cols, rows, .{});
        try protocols.restoreKittyDisplayReflowImages(t, suspended.items, &t.alternate);
    }
    if (cols != t.normal.cols) {
        t.emit(.{ .kind = .will_reflow });
        try reflowNormalBuffer(t, cols, rows);
        t.emit(.{ .kind = .did_reflow });
    } else {
        var suspended = try protocols.suspendKittyDisplayReflowImages(t, &t.normal, false);
        defer suspended.deinit(t.allocator);
        errdefer protocols.restoreKittyDisplayReflowImages(t, suspended.items, &t.normal) catch {};
        try t.normal.resizeSimple(cols, rows, .{});
        try protocols.restoreKittyDisplayReflowImages(t, suspended.items, &t.normal);
        if (cols == old_cols and rows == old_rows) t.normal.x = old_x;
    }
    t.synchronizeBlockRowsToScrollback();
    t.emit(.{ .kind = .content_changed });
}
fn indexOf(lines: []const *Line, wanted: *Line) ?isize {
    return if (std.mem.indexOfScalar(*Line, lines, wanted)) |index| @intCast(index) else null;
}
fn appendUnique(a: A, rows: *std.ArrayList(isize), row: isize) !void {
    if (std.mem.indexOfScalar(isize, rows.items, row) == null) try rows.append(a, row);
}
const EndOverride = struct { index: u64, row: isize };
const Mapping = struct {
    rows: []const isize,
    count: isize,
    fn map(self: Mapping, old: isize) isize {
        if (old < 0 or old >= self.rows.len) return -1;
        const mapped = self.rows[@intCast(old)];
        return if (mapped >= 0 and mapped < self.count) mapped else -1;
    }
};
pub fn reflowNormalBuffer(t: anytype, cols: isize, rows: isize) anyerror!void {
    const a = t.allocator;
    const b = &t.normal;
    const s = &t.print_state;
    try protocols.reactivateKittyDisplayReflowLines(t, b);
    var suspended = try protocols.suspendKittyDisplayReflowImages(t, b, true);
    defer suspended.deinit(a);
    errdefer protocols.restoreKittyDisplayReflowImages(t, suspended.items, b) catch {};
    const old_lines = try a.alloc(*Line, @intCast(b.lineCount()));
    defer a.free(old_lines);
    for (old_lines, 0..) |*slot, row| slot.* = b.line(@intCast(row)).?.retain();
    defer for (old_lines) |line| line.release();
    var margin_rows: std.ArrayList(isize) = .empty;
    defer margin_rows.deinit(a);
    var claim_rows: std.ArrayList(isize) = .empty;
    defer claim_rows.deinit(a);
    var boundary_rows: std.ArrayList(isize) = .empty;
    defer boundary_rows.deinit(a);
    if (b.rows > 1 and cols != b.cols and cols > 1) {
        for (s.activeMarginReflowBoundaries.items) |line| if (indexOf(old_lines, line)) |row| try appendUnique(a, &margin_rows, row);
    }
    for (s.kittyDisplayReflowClaims.items) |line| if (indexOf(old_lines, line)) |row| try appendUnique(a, &claim_rows, row);
    for (s.kittyDisplayReflowBoundaries.items) |line| {
        const row = indexOf(old_lines, line) orelse continue;
        const semantic = for (t.blocks.blocks.items) |block| {
            if (block.prompt_row == row or block.command_row == row) break true;
        } else false;
        if (line.usedLength() > 0 or semantic) try appendUnique(a, &boundary_rows, row);
    }
    for (s.kittyDisplayClippedTopReflowRanks.items) |line| if (indexOf(old_lines, line)) |row| try appendUnique(a, &boundary_rows, row);
    const cursor_row = b.y_base + b.y;
    const last = s.lastWrite;
    var trailing_boundary: ?isize = null;
    if (old_lines.len > 0 and cursor_row == old_lines.len - 1 and b.x == b.cols - 1 and
        old_lines[@intCast(cursor_row)].usedLength() == b.cols and s.lastPrintedScalar == null and
        last.row == cursor_row and last.x == b.x and last.cols == b.cols and last.rows == b.rows and t.blocks.blocks.items.len > 0)
    {
        const prompt = t.blocks.blocks.items[t.blocks.blocks.items.len - 1];
        if (prompt.prompt_row == cursor_row and prompt.command_row == cursor_row and prompt.input_start == null and
            prompt.end_row == null and !prompt.running) trailing_boundary = cursor_row;
    }
    var result = try reflow.build(b, cols, rows, .{ .detached_margin_rows = margin_rows.items, .kitty_boundary_rows = boundary_rows.items, .kitty_claimed_rows = claim_rows.items, .trailing_semantic_boundary = trailing_boundary });
    defer result.deinit();
    var overrides: std.ArrayList(EndOverride) = .empty;
    defer overrides.deinit(a);
    for (t.blocks.blocks.items) |block| {
        const old_end = block.end_row orelse continue;
        if (old_end >= 0 and old_end < result.physical_end_overrides.len and result.physical_end_overrides[@intCast(old_end)])
            try overrides.append(a, .{ .index = block.index, .row = result.physical_row_map[@intCast(old_end)] });
    }
    // Complete fallible attachment and claim preparation before replacing the grid.
    for (suspended.items) |entry| {
        const old = indexOf(old_lines, entry.line) orelse continue;
        const target_row = result.image_row_map[@intCast(old)];
        if (target_row < 0 or target_row >= result.lines.items.len) continue;
        const target = result.lines.items[@intCast(target_row)].?;
        const duplicate = if (target.images) |images| for (images.items) |image| {
            if (image.render_id == entry.image.render_id) break true;
        } else false else false;
        if (!duplicate) try target.appendImage(entry.image);
    }
    var claims: std.ArrayList(*Line) = .empty;
    defer {
        for (claims.items) |line| line.release();
        claims.deinit(a);
    }
    for (s.kittyDisplayReflowClaims.items) |line| if (indexOf(old_lines, line) == null) try p.retainUniqueLine(a, &claims, line);
    for (result.claim_row_map) |row| {
        if (row >= 0 and row < result.lines.items.len) try p.retainUniqueLine(a, &claims, result.lines.items[@intCast(row)].?);
    }
    try result.commit(b);
    std.mem.swap(@TypeOf(claims), &claims, &s.kittyDisplayReflowClaims);
    inline for (.{ "kittyDisplayReflowBoundaries", "kittyDisplayClippedTopReflowRanks" }) |name| {
        const list = &@field(s, name);
        var index: usize = 0;
        while (index < list.items.len) {
            if (indexOf(old_lines, list.items[index]) != null) {
                const line = list.orderedRemove(index);
                line.release();
            } else index += 1;
        }
    }
    protocols.pruneKittyDisplayReflowImages(t);
    const mapping = Mapping{ .rows = result.row_map, .count = b.lineCount() };
    t.blocks.remapRows(mapping, Mapping.map);
    for (overrides.items) |override| {
        for (t.blocks.blocks.items) |block| {
            if (block.index == override.index) block.end_row = if (override.row >= 0 and override.row < b.lineCount()) override.row else -1;
        }
    }
    t.emit(.{ .kind = .blocks_changed });
    for (s.activeMarginReflowBoundaries.items) |line| line.release();
    s.activeMarginReflowBoundaries.clearRetainingCapacity();
    t.blocks_dropped_checkpoint = b.dropped_lines;
}
