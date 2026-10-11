//! Logical-line reflow with explicit old-to-new mappings. No callbacks, parser
//! state, platform objects or mutable global state are involved. Construction
//! is transactional: failure leaves the source buffer unchanged.
const std = @import("std");
const buffer_module = @import("buffer.zig");
const line_module = @import("line.zig");
const graphics = @import("graphics.zig");
const Buffer = buffer_module.Buffer;
const Line = line_module.Line;
const Value = line_module.Value;
const Error = line_module.Error;
const A = std.mem.Allocator;

pub const Options = struct {
    /// Absolute source rows starting a new logical line even if is_wrapped.
    detached_margin_rows: []const isize = &.{},
    kitty_boundary_rows: []const isize = &.{},
    kitty_claimed_rows: []const isize = &.{},
    /// The terminal supplies this only for the exact pending semantic prompt
    /// boundary described by TerminalReflow.swift; pure reflow does not infer it.
    trailing_semantic_boundary: ?isize = null,
};
pub const Result = struct {
    allocator: A,
    lines: std.ArrayList(?*Line) = .empty,
    /// Retained-local mapping after trim; -1 means the source anchor is gone.
    row_map: []isize = &.{},
    /// Keeps the rank of trailing physical empty rows, for the exact completed
    /// Kitty-block end override. Ordinary cursor/block anchors use row_map.
    physical_row_map: []isize = &.{},
    /// Exact completed Kitty-block end predicate, evaluated before cap trim
    /// can collapse distinct negative mappings to the shared -1 sentinel.
    physical_end_overrides: []bool = &.{},
    /// First output row of each source row's logical line (image restoration).
    image_row_map: []isize = &.{},
    /// Source claims map in input order, including -1 for dropped claims.
    claim_row_map: []isize = &.{},
    y_base: isize = 0,
    y_disp: isize = 0,
    x: isize = 0,
    y: isize = 0,
    cols: isize,
    rows: isize,
    dropped: isize = 0,
    semantic_boundary: ?isize = null,

    pub fn deinit(self: *Result) void {
        for (self.lines.items) |line| line.?.release();
        self.lines.deinit(self.allocator);
        self.allocator.free(self.row_map);
        self.allocator.free(self.physical_row_map);
        self.allocator.free(self.physical_end_overrides);
        self.allocator.free(self.image_row_map);
        self.allocator.free(self.claim_row_map);
        self.* = undefined;
    }
    /// Transfer lines into their source allocator's buffer. Maps stay owned by
    /// this result, so callers can update blocks and graphics after commit.
    pub fn commit(self: *Result, buffer: *Buffer) Error!void {
        if (self.allocator.ptr != buffer.allocator.ptr or self.allocator.vtable != buffer.allocator.vtable)
            return error.InvalidInput;
        try buffer.replaceContent(&self.lines, self.y_base, self.y_disp, self.x, self.y, self.cols, self.rows, self.dropped);
    }
};
const Logical = struct {
    cells: std.ArrayList(Value) = .empty,
    first_old_row: usize,
    old_starts: std.ArrayList(usize) = .empty,
    new_starts: std.ArrayList(usize) = .empty,
    new_first_row: usize = 0,
    images: ?std.ArrayList(*graphics.LineImage) = null,
    render_mode: line_module.RenderMode = .single,
    wrap_style: line_module.WrapStyle = .cells,
    fn deinit(self: *Logical, a: A) void {
        self.cells.deinit(a);
        self.old_starts.deinit(a);
        self.new_starts.deinit(a);
        if (self.images) |*images| images.deinit(a); // Borrowed; no payload retains here.
    }
};
const Position = struct { row: usize, col: usize };
fn contains(values: []const isize, value: usize) bool {
    return std.mem.indexOfScalar(isize, values, @intCast(value)) != null;
}
fn position(starts: []const usize, offset: usize, cols: usize) Position {
    if (starts.len == 0) return .{ .row = 0, .col = 0 };
    var low: usize = 0;
    var high = starts.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (starts[mid] <= offset) low = mid + 1 else high = mid;
    }
    var row_index = low -| 1;
    var col = offset -| starts[row_index];
    if (col >= cols) {
        row_index += col / cols;
        col %= cols;
    }
    return .{ .row = row_index, .col = col };
}
fn mappedPhysical(old_row: usize, buf: *const Buffer, logicals: []const Logical, row_to_logical: []const usize, cols: usize) usize {
    const logical = &logicals[row_to_logical[old_row]];
    const within = old_row - logical.first_old_row;
    const offset = if (within < logical.old_starts.items.len) logical.old_starts.items[within] else 0;
    if (within > 0 and buf.line(@intCast(old_row)).?.usedLength() == 0 and offset == logical.cells.items.len) {
        if (logical.cells.items.len == 0) return logical.new_first_row + within;
        var prior_empty: usize = 0;
        for (logical.old_starts.items[1..within]) |old_offset| if (old_offset == logical.cells.items.len) {
            prior_empty += 1;
        };
        return logical.new_first_row + logical.new_starts.items.len + prior_empty;
    }
    return logical.new_first_row + position(logical.new_starts.items, offset, cols).row;
}
fn appendBlank(result: *Result) Error!*Line {
    try result.lines.ensureUnusedCapacity(result.allocator, 1);
    const line = try Line.create(result.allocator, result.cols, .{});
    result.lines.appendAssumeCapacity(line);
    return line;
}
fn setLogicalMetadata(line: *Line, logical: *const Logical, first: bool) Error!void {
    line.is_wrapped = !first;
    line.render_mode = logical.render_mode;
    line.wrap_style = logical.wrap_style;
    if (first) if (logical.images) |images| {
        // Preserve nil versus an explicitly empty attachment list.
        line.images = .empty;
        try line.images.?.ensureTotalCapacity(line.allocator, images.items.len);
        for (images.items) |image| line.images.?.appendAssumeCapacity(image.clone());
    };
    line.touch();
}
pub fn build(buffer: *const Buffer, new_cols: isize, new_rows: isize, options: Options) Error!Result {
    if (new_cols < 2 or new_rows < 1) return error.InvalidInput;
    const a = buffer.allocator;
    const old_count: usize = @intCast(buffer.lineCount());
    const columns: usize = @intCast(new_cols);
    var result = Result{ .allocator = a, .cols = new_cols, .rows = new_rows };
    errdefer result.deinit();
    var logicals: std.ArrayList(Logical) = .empty;
    defer {
        for (logicals.items) |*logical| logical.deinit(a);
        logicals.deinit(a);
    }
    const row_to_logical = try a.alloc(usize, old_count);
    defer a.free(row_to_logical);

    // Borrow complete cell values from source lines. Source storage cannot
    // mutate during this call; cluster slices stay valid until construction ends.
    for (0..old_count) |old_row| {
        const line = buffer.line(@intCast(old_row)).?;
        const join = line.is_wrapped and logicals.items.len != 0 and
            !contains(options.detached_margin_rows, old_row) and
            !contains(options.kitty_boundary_rows, old_row) and
            !contains(options.kitty_claimed_rows, old_row);
        if (!join) try logicals.append(a, .{ .first_old_row = old_row, .render_mode = line.render_mode, .wrap_style = line.wrap_style });
        const logical = &logicals.items[logicals.items.len - 1];
        try logical.old_starts.append(a, logical.cells.items.len);
        const used: usize = @intCast(@max(0, @min(line.count(), line.usedLength())));
        try logical.cells.ensureUnusedCapacity(a, used);
        for (0..used) |column| logical.cells.appendAssumeCapacity(line.get(@intCast(column)));
        if (line.images) |images| {
            if (logical.images == null) logical.images = .empty;
            try logical.images.?.appendSlice(a, images.items);
        }
        if (line.wrap_style == .words) logical.wrap_style = .words;
        row_to_logical[old_row] = logicals.items.len - 1;
    }

    const cursor_abs = buffer.y_base +| buffer.y;
    const cursor_old_valid = cursor_abs >= 0 and cursor_abs < @as(isize, @intCast(old_count));
    const cursor_logical = if (cursor_old_valid) row_to_logical[@intCast(cursor_abs)] else logicals.items.len -| 1;
    var cursor_offset: usize = @intCast(@max(0, buffer.x));
    if (cursor_old_valid and cursor_logical < logicals.items.len) {
        const logical = &logicals.items[cursor_logical];
        const within = @as(usize, @intCast(cursor_abs)) - logical.first_old_row;
        if (within < logical.old_starts.items.len) cursor_offset +|= logical.old_starts.items[within];
    }

    for (logicals.items, 0..) |*logical, logical_index| {
        var claimed_old: ?usize = null;
        for (options.kitty_claimed_rows) |candidate| {
            if (candidate >= 0 and candidate < @as(isize, @intCast(old_count)) and
                row_to_logical[@intCast(candidate)] == logical_index)
            {
                claimed_old = @intCast(candidate);
                break;
            }
        }
        if (claimed_old) |old| if (old > 0) {
            const prior_logical = row_to_logical[old - 1];
            if (prior_logical < logical_index) {
                const claimed_start = mappedPhysical(old - 1, buffer, logicals.items, row_to_logical, columns) + 1;
                while (result.lines.items.len < claimed_start) _ = try appendBlank(&result);
            }
        };
        logical.new_first_row = result.lines.items.len;
        if (logical.cells.items.len == 0) {
            const line = try appendBlank(&result);
            try setLogicalMetadata(line, logical, true);
            try logical.new_starts.append(a, 0);
            continue;
        }
        var offset: usize = 0;
        var first = true;
        while (offset < logical.cells.items.len) {
            try logical.new_starts.append(a, offset);
            var end = @min(offset +| columns, logical.cells.items.len);
            if (end < logical.cells.items.len and logical.cells.items[end].cell.width == 0) end -= 1;
            if (logical.wrap_style == .words and end < logical.cells.items.len) {
                var probe = end -| 1;
                while (probe > offset) : (probe -= 1) {
                    const scalar = logical.cells.items[probe].cell.scalar;
                    if (scalar == 0x20 or scalar == 0x09) {
                        end = probe + 1;
                        break;
                    }
                }
            }
            if (end <= offset) end = @min(offset +| columns, logical.cells.items.len);
            const line = try appendBlank(&result);
            for (logical.cells.items[offset..end], 0..) |value, column| try line.set(@intCast(column), value);
            try setLogicalMetadata(line, logical, first);
            first = false;
            offset = end;
        }
    }

    if (options.trailing_semantic_boundary) |old| {
        if (old >= 0 and old < @as(isize, @intCast(old_count))) {
            const logical = &logicals.items[row_to_logical[@intCast(old)]];
            const boundary = logical.new_first_row + logical.new_starts.items.len;
            while (result.lines.items.len <= boundary) _ = try appendBlank(&result);
            result.semantic_boundary = @intCast(boundary);
        }
    }
    result.row_map = try a.alloc(isize, old_count);
    result.physical_row_map = try a.alloc(isize, old_count);
    result.physical_end_overrides = try a.alloc(bool, old_count);
    @memset(result.physical_end_overrides, false);
    result.image_row_map = try a.alloc(isize, old_count);
    result.claim_row_map = try a.alloc(isize, options.kitty_claimed_rows.len);
    for (row_to_logical, 0..) |logical_index, old_row| {
        const logical = &logicals.items[logical_index];
        const within = old_row - logical.first_old_row;
        const offset = if (within < logical.old_starts.items.len) logical.old_starts.items[within] else 0;
        result.row_map[old_row] = @intCast(logical.new_first_row + position(logical.new_starts.items, offset, columns).row);
        if (options.trailing_semantic_boundary != null and options.trailing_semantic_boundary.? == old_row and result.semantic_boundary != null)
            result.row_map[old_row] = result.semantic_boundary.?;
        result.physical_row_map[old_row] = @intCast(mappedPhysical(old_row, buffer, logicals.items, row_to_logical, columns));
        result.image_row_map[old_row] = @intCast(logical.new_first_row);
    }
    for (options.kitty_claimed_rows, result.claim_row_map) |old, *mapped| {
        mapped.* = if (old >= 0 and old < @as(isize, @intCast(old_count))) result.image_row_map[@intCast(old)] else -1;
    }
    for (0..old_count -| 1) |old_row| {
        result.physical_end_overrides[old_row] = buffer.line(@intCast(old_row)).?.usedLength() == 0 and
            buffer.line(@intCast(old_row + 1)).?.is_wrapped and contains(options.kitty_boundary_rows, old_row + 1) and
            row_to_logical[old_row] != row_to_logical[old_row + 1] and
            result.physical_row_map[old_row] == result.row_map[old_row] + 1;
    }
    var cursor_position = Position{ .row = 0, .col = 0 };
    var cursor_row: isize = @intCast(result.lines.items.len -| 1);
    if (cursor_logical < logicals.items.len) {
        const logical = &logicals.items[cursor_logical];
        cursor_position = position(logical.new_starts.items, cursor_offset, columns);
        cursor_row = @intCast(logical.new_first_row + cursor_position.row);
    }
    if (result.semantic_boundary) |boundary| cursor_row = boundary;
    const cursor_col: isize = if (result.semantic_boundary != null) 0 else @intCast(cursor_position.col);
    while (result.lines.items.len < @as(usize, @intCast(new_rows))) _ = try appendBlank(&result);
    cursor_row = @min(cursor_row, @as(isize, @intCast(result.lines.items.len)) - 1);
    const mapped_live = if (buffer.y_base >= 0 and buffer.y_base < @as(isize, @intCast(old_count)))
        result.row_map[@intCast(buffer.y_base)]
    else
        @max(0, @as(isize, @intCast(result.lines.items.len)) - new_rows);
    const mapped_viewport = if (buffer.y_disp >= 0 and buffer.y_disp < @as(isize, @intCast(old_count)))
        result.row_map[@intCast(buffer.y_disp)]
    else
        @min(buffer.y_disp, mapped_live);
    var last_meaningful = cursor_row;
    var index = result.lines.items.len;
    while (index > 0) {
        index -= 1;
        if (result.lines.items[index].?.meaningful()) {
            last_meaningful = @max(last_meaningful, @as(isize, @intCast(index)));
            break;
        }
    }
    const cursor_min = @max(0, cursor_row - new_rows + 1);
    const cursor_max = @max(0, cursor_row);
    const content_min = @max(0, last_meaningful - new_rows + 1);
    const minimum = if (content_min <= cursor_max) @max(cursor_min, content_min) else cursor_min;
    result.y_base = @min(@max(mapped_live, minimum), cursor_max);
    const required: usize = @intCast(result.y_base + new_rows);
    while (result.lines.items.len > required) {
        const tail = result.lines.items[result.lines.items.len - 1].?;
        if (tail.meaningful()) break;
        _ = result.lines.pop();
        tail.release();
    }
    while (result.lines.items.len < required) _ = try appendBlank(&result);
    const was_bottom = buffer.y_disp == buffer.y_base;
    result.y_disp = if (was_bottom) result.y_base else @min(@max(0, mapped_viewport), result.y_base);
    const excess = (@as(isize, @intCast(result.lines.items.len)) - new_rows) - @max(0, buffer.max_scrollback);
    if (excess > 0) {
        result.dropped = @min(excess, result.y_base);
        if (result.dropped > 0) {
            const count: usize = @intCast(result.dropped);
            for (result.lines.items[0..count]) |line| line.?.release();
            const retained = result.lines.items.len - count;
            std.mem.copyForwards(?*Line, result.lines.items[0..retained], result.lines.items[count..]);
            result.lines.shrinkRetainingCapacity(retained);
            result.y_base -= result.dropped;
            result.y_disp = @max(0, result.y_disp - result.dropped);
            cursor_row -= result.dropped;
        }
    }
    result.x = @min(@max(0, cursor_col), new_cols - 1);
    result.y = @min(@max(0, cursor_row - result.y_base), new_rows - 1);
    for ([_][]isize{ result.row_map, result.physical_row_map, result.image_row_map, result.claim_row_map }) |map| {
        for (map) |*row| {
            row.* -= result.dropped;
            if (row.* < 0 or row.* >= @as(isize, @intCast(result.lines.items.len))) row.* = -1;
        }
    }
    if (result.semantic_boundary) |boundary| {
        const remapped = boundary - result.dropped;
        result.semantic_boundary = if (remapped >= 0 and remapped < @as(isize, @intCast(result.lines.items.len))) remapped else null;
    }
    return result;
}
