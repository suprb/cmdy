//! One screen and its retained history. Absolute coordinates are always local
//! to retained history; dropped_lines is the stable-origin displacement.
const std = @import("std");
const rows_native = @import("row.zig");
const backing_pool = @import("row_backing_pool.zig");
pub const Line = @import("line.zig").Line;
pub const Cell = rows_native.Cell;
pub const Value = rows_native.Row.Value;
pub const Error = rows_native.Error;
const A = std.mem.Allocator;

test "initial deferral preserves readable recycled rows when scroll clear is false" {
    const initial: Cell = .{ .scalar = 'Z', .bg = 0x01000004, .link_id = 71, .style = 3 };
    const pen: Cell = .{ .fg = 0x01000002, .link_id = 17 };
    for ([_]bool{ false, true }) |history| {
        for ([_]bool{ false, true }) |partial| {
            for ([_]bool{ false, true }) |filled| {
                var buffer = try Buffer.init(std.testing.allocator, 8, 2, history, 0);
                defer buffer.deinit();
                const original = try Line.create(std.testing.allocator, 8, initial);
                buffer.storage.items[0].?.release();
                buffer.storage.items[0] = original;
                if (partial) try original.writeASCII("BC", 2, pen);
                var expected: [8]Cell = undefined;
                for (&expected, 0..) |*cell, column| cell.* = original.cell(@intCast(column));
                if (filled) try original.fill(.{ .cell = .{ .scalar = 'F', .bg = 0x02010203 } }, 0, null);
                const version = original.version();
                try buffer.scrollUp(.{ .scalar = 'N' }, true, false);
                const recycled = buffer.liveLine(1);
                try std.testing.expectEqual(original, recycled);
                try std.testing.expect(recycled.is_wrapped);
                try std.testing.expect(recycled.version() > version);
                const published = try recycled.renderSnapshot();
                defer published.release();
                for (expected, 0..) |value, column| {
                    try std.testing.expectEqualDeep(value, recycled.cell(@intCast(column)));
                    try std.testing.expectEqualDeep(value, published.cell(@intCast(column)));
                    try std.testing.expect(recycled.get(@intCast(column)).extras == null);
                }
            }
        }
    }
}

pub const SavedCursor = struct {
    x: isize = 0,
    y: isize = 0,
    attribute: Cell = .{},
    wrap_pending: bool = false,
    origin_mode: bool = false,
    auto_wrap: bool = false,
    margin_mode: bool = false,
    reverse_wraparound: bool = false,
};
pub const Buffer = struct {
    allocator: A,
    storage: std.ArrayList(?*Line) = .empty,
    line_start: usize = 0,
    dropped_lines: isize = 0,
    y_base: isize = 0,
    y_disp: isize = 0,
    x: isize = 0,
    y: isize = 0,
    cols: isize,
    rows: isize,
    has_scrollback: bool,
    max_scrollback: isize,
    scroll_top: isize = 0,
    scroll_bottom: isize,
    margin_left: isize = 0,
    margin_right: isize = 0,
    saved_cursor: ?SavedCursor = null,
    tab_stops: std.AutoHashMapUnmanaged(isize, void) = .empty,
    wrap_pending: bool = false,
    overflow_lines: std.AutoHashMapUnmanaged(isize, *Line) = .empty,

    pub fn init(a: A, cols: isize, height: isize, history: bool, max_history: isize) Error!Buffer {
        const width = @max(1, cols);
        const rows = @max(1, height);
        if (@as(usize, @intCast(rows)) > std.math.maxInt(usize) / @sizeOf(?*Line)) return error.InvalidInput;
        var self = Buffer{ .allocator = a, .cols = width, .rows = rows, .has_scrollback = history, .max_scrollback = if (history) @max(0, max_history) else 0, .scroll_bottom = rows - 1 };
        errdefer self.deinit();
        try self.storage.ensureTotalCapacity(a, @intCast(rows));
        for (0..@intCast(rows)) |_| self.storage.appendAssumeCapacity(try Line.create(a, width, .{}));
        try self.resetTabStops();
        return self;
    }
    pub fn deinit(self: *Buffer) void {
        self.clearOverflowLines();
        self.overflow_lines.deinit(self.allocator);
        for (self.storage.items[self.line_start..]) |line_ptr| line_ptr.?.release();
        self.storage.deinit(self.allocator);
        self.tab_stops.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn lineCount(self: *const Buffer) isize {
        return @intCast(self.storage.items.len - self.line_start);
    }
    pub fn absoluteRow(self: *const Buffer, r: isize) isize {
        return self.y_base +| r;
    }
    pub fn line(self: *const Buffer, absolute: isize) ?*Line {
        if (absolute < 0 or absolute >= self.lineCount()) return null;
        return self.storage.items[self.line_start + @as(usize, @intCast(absolute))];
    }
    pub fn liveLine(self: *const Buffer, relative: isize) *Line {
        return self.line(self.absoluteRow(relative)) orelse @panic("live terminal row out of range");
    }
    /// Owned immutable cell/metadata snapshots. The array and each cloned line
    /// belong to the caller; releaseSnapshots disposes them together.
    pub fn snapshot(self: *const Buffer, a: A) Error![]*Line {
        const copies = try a.alloc(*Line, @intCast(self.lineCount()));
        var count: usize = 0;
        errdefer {
            for (copies[0..count]) |copy| copy.release();
            a.free(copies);
        }
        for (self.storage.items[self.line_start..]) |item| {
            copies[count] = try item.?.cloneSnapshot();
            count += 1;
        }
        return copies;
    }
    pub fn releaseSnapshots(a: A, copies: []*Line) void {
        for (copies) |copy| copy.release();
        a.free(copies);
    }
    pub fn lineAutovivified(self: *Buffer, absolute: isize) Error!?*Line {
        if (absolute < 0) return null;
        const capacity = @max(1, self.rows +| self.max_scrollback);
        const wrapped = @mod(absolute, capacity);
        if (self.line(wrapped)) |existing| return existing;
        if (wrapped >= self.lineCount() +| 512) return null;
        if (self.overflow_lines.get(wrapped)) |existing| return existing;
        const ghost = try Line.create(self.allocator, self.cols, .{});
        errdefer ghost.release();
        try self.overflow_lines.put(self.allocator, wrapped, ghost);
        return ghost;
    }
    pub fn clearOverflowLines(self: *Buffer) void {
        if (self.overflow_lines.count() == 0) return;
        var previous = self.overflow_lines;
        self.overflow_lines = .empty;
        var iterator = previous.valueIterator();
        while (iterator.next()) |line_ptr| line_ptr.*.release();
        previous.deinit(self.allocator);
    }
    pub fn resetTabStops(self: *Buffer) Error!void {
        var replacement = try defaultTabs(self.allocator, self.cols);
        std.mem.swap(@TypeOf(self.tab_stops), &self.tab_stops, &replacement);
        replacement.deinit(self.allocator);
    }
    fn defaultTabs(a: A, cols: isize) Error!std.AutoHashMapUnmanaged(isize, void) {
        var tabs: std.AutoHashMapUnmanaged(isize, void) = .empty;
        errdefer tabs.deinit(a);
        var col: isize = 8;
        while (col < cols) : (col = col +| 8) {
            try tabs.put(a, col, {});
            if (col > std.math.maxInt(isize) - 8) break;
        }
        return tabs;
    }
    pub fn setTabStop(self: *Buffer, col: isize) Error!void {
        try self.tab_stops.put(self.allocator, col, {});
    }
    pub fn clearTabStop(self: *Buffer, col: isize) void {
        _ = self.tab_stops.remove(col);
    }
    pub fn clearAllTabStops(self: *Buffer) void {
        self.tab_stops.clearRetainingCapacity();
    }
    pub fn nextTabStop(self: *const Buffer, col: isize, margin_mode: bool) isize {
        if (self.cols <= 0) return 0;
        const upper = @min(self.cols - 1, @max(0, if (margin_mode) self.margin_right else self.cols - 1));
        const first = @min(upper, @max(0, col +| 1));
        var found = upper;
        var iterator = self.tab_stops.keyIterator();
        while (iterator.next()) |key| if (key.* >= first and key.* <= found) {
            found = key.*;
        };
        return found;
    }
    pub fn previousTabStop(self: *const Buffer, col: isize) isize {
        var found: isize = 0;
        var iterator = self.tab_stops.keyIterator();
        while (iterator.next()) |key| if (key.* < col and key.* > found) {
            found = key.*;
        };
        return found;
    }
    pub fn canAppendFullScreenScrollbackLine(self: *const Buffer) bool {
        return self.canScrollFullScreenIntoScrollback() and self.lineCount() - self.rows < self.max_scrollback;
    }
    pub fn canScrollFullScreenIntoScrollback(self: *const Buffer) bool {
        return self.has_scrollback and self.scroll_top == 0 and self.scroll_bottom == self.rows - 1;
    }
    pub const HistoryMaintenance = extern struct {
        next_absolute_row: isize = 0,
        visited: usize = 0,
        compacted: usize = 0,
        complete: u8 = 0,
        reserved: [7]u8 = @splat(0),
    };
    /// Explicit cold maintenance on the terminal's serial owner. Parsing and
    /// scrolling never invoke this work. Bound both row visits and inspected
    /// columns so the host can yield between batches. Rows in either the live
    /// screen or displayed history viewport keep their current backing.
    pub fn compactHistory(self: *Buffer, absolute_start: isize, requested_rows: usize) HistoryMaintenance {
        // Keep reclamation outside feed/scroll. The existing idle scheduler
        // continues with the same row cursor while bounded cache work remains.
        _ = backing_pool.trimEmpty(2);
        const history = if (self.has_scrollback)
            @min(@max(0, self.y_base), @max(0, self.lineCount() -| self.rows))
        else 0;
        // Saturated origin coordinates cannot encode continuation progress.
        // This optional maintenance leaves those rows dense instead of
        // repeatedly visiting an unrepresentable absolute row range.
        if (self.dropped_lines > std.math.maxInt(isize) - history)
            return .{ .next_absolute_row = std.math.maxInt(isize), .complete = @intFromBool(!backing_pool.hasCachedEmpty()) };
        var index = @min(history, @max(0, absolute_start -| self.dropped_lines));
        var result = HistoryMaintenance{ .next_absolute_row = self.dropped_lines +| index };
        const limit = @min(requested_rows, 64);
        const column_budget = 8192;
        var inspected_columns: usize = 0;
        while (index < history and result.visited < limit) {
            if (self.line(index)) |value| {
                const columns = value.row.columnCount();
                const displayed = index >= self.y_disp and index < self.y_disp +| self.rows;
                if (!displayed and columns <= column_budget) {
                    if (columns > column_budget - inspected_columns) break;
                    inspected_columns += columns;
                    result.compacted += @intFromBool(value.compactRetainedASCII());
                }
            }
            result.visited += 1;
            index += 1;
        }
        result.next_absolute_row = self.dropped_lines +| index;
        result.complete = @intFromBool(index >= history and !backing_pool.hasCachedEmpty());
        return result;
    }
    /// Takes ownership of a line only on success.
    pub fn appendFullScreenScrollbackLine(self: *Buffer, value: *Line) Error!void {
        if (!self.canAppendFullScreenScrollbackLine()) return error.InvalidInput;
        try self.storage.append(self.allocator, value);
        const at_bottom = self.y_disp == self.y_base;
        self.y_base += 1;
        if (at_bottom) self.y_disp = self.y_base;
    }
    fn validRegion(self: *const Buffer, first: isize, last: isize) bool {
        return first >= 0 and last >= first and last < self.lineCount();
    }
    pub fn scrollUp(self: *Buffer, fill: Cell, wrapped: bool, clear_recycled: bool) Error!void {
        try self.scrollUpValue(.{ .cell = fill }, wrapped, clear_recycled);
    }
    pub fn scrollUpValue(self: *Buffer, fill: Value, wrapped: bool, clear_recycled: bool) Error!void {
        const top = self.y_base +| self.scroll_top;
        const bottom = self.y_base +| self.scroll_bottom;
        if (!self.validRegion(top, bottom)) return;
        const at_bottom = self.y_disp == self.y_base;
        if (self.scroll_top == 0 and self.has_scrollback) {
            const tail = bottom >= self.lineCount() - 1;
            const full = self.lineCount() - self.rows >= @max(0, self.max_scrollback);
            try self.storage.ensureUnusedCapacity(self.allocator, 1);
            if (tail and full) {
                const recycled = self.storage.items[self.line_start].?;
                self.clearOverflowLines();
                self.storage.items[self.line_start] = null;
                self.line_start += 1;
                // Swift publishes the departing slot before releasing the
                // recycled image payload. Exposed host wrappers can observe
                // this count and mutate cursor coordinates in their release.
                errdefer {
                    self.line_start -= 1;
                    self.storage.items[self.line_start] = recycled;
                }
                if (clear_recycled) try recycled.resetValue(fill, wrapped) else recycled.resetMetadata(wrapped);
                self.storage.appendAssumeCapacity(recycled);
                self.dropped_lines +|= 1;
                self.y_disp = @max(0, self.y_disp -| 1);
                self.compactDeferredPrefixIfNeeded();
            } else {
                const fresh = try Line.createValue(self.allocator, self.cols, fill);
                fresh.setWrapped(wrapped);
                self.clearOverflowLines();
                self.storage.insertAssumeCapacity(self.line_start + @as(usize, @intCast(bottom + 1)), fresh);
                self.y_base += 1;
                self.trimScrollback();
            }
        } else {
            self.clearOverflowLines();
            try self.resetAndRotate(top, bottom, true, fill, wrapped, clear_recycled);
        }
        if (at_bottom) self.y_disp = self.y_base;
    }
    fn rotate(self: *Buffer, first: isize, last: isize, up: bool) void {
        const top = self.line_start + @as(usize, @intCast(first));
        const bottom = self.line_start + @as(usize, @intCast(last));
        const value = self.storage.items[if (up) top else bottom];
        if (up) std.mem.copyForwards(?*Line, self.storage.items[top..bottom], self.storage.items[top + 1 .. bottom + 1]) else std.mem.copyBackwards(?*Line, self.storage.items[top + 1 .. bottom + 1], self.storage.items[top..bottom]);
        self.storage.items[if (up) bottom else top] = value;
    }
    fn resetAndRotate(self: *Buffer, first: isize, last: isize, up: bool, fill: Value, wrapped: bool, clear: bool) Error!void {
        const source = self.line_start + @as(usize, @intCast(if (up) first else last));
        const target = self.line_start + @as(usize, @intCast(if (up) last else first));
        const recycled = self.storage.orderedRemove(source).?;
        errdefer self.storage.insertAssumeCapacity(source, recycled);
        if (clear) try recycled.resetValue(fill, wrapped) else recycled.resetMetadata(wrapped);
        self.storage.insertAssumeCapacity(target, recycled);
    }
    pub fn scrollUpRegionOnly(self: *Buffer, fill: Cell) Error!void {
        try self.scrollUpRegionOnlyValue(.{ .cell = fill });
    }
    pub fn scrollUpRegionOnlyValue(self: *Buffer, fill: Value) Error!void {
        const top = self.y_base +| self.scroll_top;
        const bottom = self.y_base +| self.scroll_bottom;
        if (!self.validRegion(top, bottom)) return;
        try self.resetAndRotate(top, bottom, true, fill, false, true);
    }
    pub fn scrollDown(self: *Buffer, fill: Cell) Error!void {
        try self.scrollDownValue(.{ .cell = fill });
    }
    pub fn scrollDownValue(self: *Buffer, fill: Value) Error!void {
        const top = self.y_base +| self.scroll_top;
        const bottom = self.y_base +| self.scroll_bottom;
        if (!self.validRegion(top, bottom)) return;
        try self.resetAndRotate(top, bottom, false, fill, false, true);
    }
    pub fn insertLines(self: *Buffer, at: isize, count: isize, fill: Cell) Error!void {
        try self.insertLinesValue(at, count, .{ .cell = fill });
    }
    pub fn insertLinesValue(self: *Buffer, at: isize, count: isize, fill: Value) Error!void {
        if (at < self.scroll_top or at > self.scroll_bottom or count <= 0) return;
        const top = self.y_base +| at;
        const bottom = self.y_base +| self.scroll_bottom;
        if (!self.validRegion(top, bottom)) return;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            try self.resetAndRotate(top, bottom, false, fill, false, true);
        }
    }
    pub fn deleteLines(self: *Buffer, at: isize, count: isize, fill: Cell) Error!void {
        try self.deleteLinesValue(at, count, .{ .cell = fill });
    }
    pub fn deleteLinesValue(self: *Buffer, at: isize, count: isize, fill: Value) Error!void {
        if (at < self.scroll_top or at > self.scroll_bottom or count <= 0) return;
        const top = self.y_base +| at;
        const bottom = self.y_base +| self.scroll_bottom;
        if (!self.validRegion(top, bottom)) return;
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            try self.resetAndRotate(top, bottom, true, fill, false, true);
        }
    }
    pub fn trimScrollback(self: *Buffer) void {
        const excess = (self.lineCount() - self.rows) - @max(0, self.max_scrollback);
        if (excess <= 0) return;
        const removed = @min(excess, @max(0, self.y_base));
        self.removeFirstLines(removed);
        self.dropped_lines +|= removed;
        self.y_base -= removed;
        self.y_disp = @max(0, self.y_disp -| removed);
    }
    pub fn removeFirstLines(self: *Buffer, count: isize) void {
        const removed: usize = @intCast(@min(@max(0, count), self.lineCount()));
        const end = self.line_start + removed;
        for (self.line_start..end) |index| {
            const line_ptr = self.storage.items[index].?;
            self.storage.items[index] = null;
            line_ptr.release();
        }
        self.line_start = end;
        self.compactDeferredPrefixIfNeeded();
    }
    pub fn compactDeferredPrefixIfNeeded(self: *Buffer) void {
        const retained = self.storage.items.len - self.line_start;
        if (self.line_start < @max(64, retained)) return;
        std.mem.copyForwards(?*Line, self.storage.items[0..retained], self.storage.items[self.line_start..]);
        self.storage.shrinkRetainingCapacity(retained);
        self.line_start = 0;
    }
    pub fn clearScrollback(self: *Buffer) void {
        if (self.y_base <= 0) return;
        self.dropped_lines +|= self.y_base;
        self.removeFirstLines(self.y_base);
        self.y_base = 0;
        self.y_disp = 0;
    }
    pub fn hardReset(self: *Buffer) Error!void {
        var fresh = try Buffer.init(self.allocator, self.cols, self.rows, self.has_scrollback, self.max_scrollback);
        fresh.margin_right = self.cols - 1;
        std.mem.swap(Buffer, self, &fresh);
        fresh.deinit();
    }
    /// Preparation owns every fallible allocation; committing geometry never
    /// leaves half-resized native rows, and surviving Line identities stay put.
    pub fn resizeSimple(self: *Buffer, new_cols: isize, new_rows: isize, fill: Cell) Error!void {
        _ = fill; // Reference pads resized and new rows with the default Cell.
        if (new_cols < 1 or new_rows < 1) return error.InvalidInput;
        var tabs = try defaultTabs(self.allocator, new_cols);
        defer tabs.deinit(self.allocator);
        var replacements: std.ArrayList(*rows_native.Row) = .empty;
        defer {
            for (replacements.items) |row_ptr| row_ptr.destroy();
            replacements.deinit(self.allocator);
        }
        if (new_cols != self.cols) {
            try replacements.ensureTotalCapacity(self.allocator, @intCast(self.lineCount()));
            for (self.storage.items[self.line_start..]) |item| {
                const replacement = try item.?.row.clone();
                replacements.appendAssumeCapacity(replacement);
                try replacement.resize(@intCast(new_cols), .{});
            }
        }
        const reveal = if (new_rows > self.rows) @min(new_rows - self.rows, self.y_base) else 0;
        const append_count = if (new_rows > self.rows) new_rows - self.rows - reveal else 0;
        var added: std.ArrayList(*Line) = .empty;
        defer {
            for (added.items) |item| item.release();
            added.deinit(self.allocator);
        }
        try added.ensureTotalCapacity(self.allocator, @intCast(append_count));
        for (0..@intCast(append_count)) |_| added.appendAssumeCapacity(try Line.create(self.allocator, new_cols, .{}));
        try self.storage.ensureUnusedCapacity(self.allocator, @intCast(append_count));
        const at_bottom = self.y_disp == self.y_base;
        if (new_cols != self.cols) {
            for (self.storage.items[self.line_start..], replacements.items) |item, *replacement| {
                std.mem.swap(*rows_native.Row, &item.?.row, replacement);
            }
            self.cols = new_cols;
        }
        self.clearOverflowLines();
        if (new_rows > self.rows) {
            self.y_base -= reveal;
            self.y += reveal;
            for (added.items) |item| self.storage.appendAssumeCapacity(item);
            added.clearRetainingCapacity();
        } else if (new_rows < self.rows) {
            var to_remove = self.rows - new_rows;
            while (to_remove > 0 and self.lineCount() > self.y_base + self.y + 1) {
                const last = self.storage.items[self.storage.items.len - 1].?;
                if (last.usedLength() != 0 or last.images != null) break;
                _ = self.storage.pop();
                last.release();
                to_remove -= 1;
            }
            if (to_remove > 0) {
                self.y_base += to_remove;
                self.y = @max(0, self.y - to_remove);
                if (!self.has_scrollback) {
                    self.removeFirstLines(@min(to_remove, self.lineCount() - new_rows));
                    self.y_base = @max(0, self.lineCount() - new_rows);
                }
            }
        }
        self.rows = new_rows;
        self.scroll_top = 0;
        self.scroll_bottom = new_rows - 1;
        if (self.margin_right > self.cols - 1) self.margin_right = self.cols - 1;
        if (self.margin_left >= self.margin_right) self.margin_left = self.margin_right;
        self.x = @min(self.x, self.cols - 1);
        self.y = @min(self.y, self.rows - 1);
        self.y_disp = if (at_bottom) self.y_base else @min(self.y_disp, self.y_base);
        self.trimScrollback();
        std.mem.swap(@TypeOf(self.tab_stops), &self.tab_stops, &tabs);
    }
    /// Atomically transfer a fully prepared reflow result into this buffer.
    /// The input array is consumed on success, unchanged on allocation failure.
    pub fn replaceContent(self: *Buffer, lines: *std.ArrayList(?*Line), y_base: isize, y_disp: isize, x: isize, y: isize, cols: isize, height: isize, dropped: isize) Error!void {
        if (cols < 1 or height < 1 or y_base < 0 or
            y_base > @as(isize, @intCast(lines.items.len)) - height) return error.InvalidInput;
        var tabs = try defaultTabs(self.allocator, cols);
        defer tabs.deinit(self.allocator);
        self.clearOverflowLines();
        var previous = self.storage;
        const previous_start = self.line_start;
        self.storage = lines.*;
        lines.* = .empty;
        self.line_start = 0;
        for (previous.items[previous_start..]) |item| item.?.release();
        previous.deinit(self.allocator);
        self.y_base = y_base;
        self.y_disp = y_disp;
        self.x = x;
        self.y = y;
        self.cols = cols;
        self.rows = height;
        self.scroll_top = 0;
        self.scroll_bottom = height - 1;
        self.wrap_pending = false;
        self.dropped_lines +|= @max(0, dropped);
        std.mem.swap(@TypeOf(self.tab_stops), &self.tab_stops, &tabs);
    }
};
