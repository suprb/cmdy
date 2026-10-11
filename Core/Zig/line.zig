//! Platform independent row ownership. Cell storage uses the qualified native
//! Row implementation; metadata and image payload ownership stay with a line.
const std = @import("std");
const native = @import("row.zig");
const graphics = @import("graphics.zig");
pub const Cell = native.Cell;
pub const Value = native.Row.Value;
pub const Error = native.Error;
pub const WrapStyle = enum(u8) { cells, words };
pub const RenderMode = enum(u8) { single, double_width, doubled_top, doubled_down };
pub const Line = struct {
    /// Optional host identity bridge. It is absent on rows that the host has
    /// never exposed. A final-release handler may transfer ownership or free
    /// the row synchronously; true means the caller must not touch it again.
    pub const LifetimeObserver = struct {
        context: *anyopaque,
        retained: *const fn (*anyopaque, *Line) void,
        final_release: *const fn (*anyopaque, *Line) bool,
    };
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    identity: u64,
    row: *native.Row,
    is_wrapped: bool = false,
    wrap_style: WrapStyle = .cells,
    render_mode: RenderMode = .single,
    images: ?std.ArrayList(*graphics.LineImage) = null,
    metadata_version: u64 = 0,
    lifetime_observer: ?LifetimeObserver = null,

    pub fn create(a: std.mem.Allocator, cols: isize, blank: Cell) Error!*Line {
        if (cols < 0) return error.InvalidInput;
        const row = try native.Row.createForLine(a, @intCast(cols), blank);
        errdefer row.destroy();
        const result = try a.create(Line);
        const identity = native.stamp();
        result.* = .{ .allocator = a, .row = row, .identity = identity, .metadata_version = identity };
        return result;
    }
    pub fn createASCII(a: std.mem.Allocator, bytes: []const u8, cols: isize, pen: Cell, blank: Cell, wrapped: bool) Error!*Line {
        if (cols < 0) return error.InvalidInput;
        const row = try native.Row.createBytes(a, bytes, @intCast(cols), pen, blank);
        errdefer row.destroy();
        const result = try a.create(Line);
        const identity = native.stamp();
        result.* = .{ .allocator = a, .row = row, .identity = identity, .metadata_version = identity, .is_wrapped = wrapped };
        return result;
    }
    pub fn retain(self: *Line) *Line {
        _ = self.refs.fetchAdd(1, .monotonic);
        if (self.lifetime_observer) |observer| observer.retained(observer.context, self);
        return self;
    }
    pub fn release(self: *Line) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.lifetime_observer) |observer| {
            if (observer.final_release(observer.context, self)) return;
        }
        self.clearImages();
        self.row.destroy();
        self.allocator.destroy(self);
    }
    pub fn deinit(self: *Line) void {
        self.release();
    }
    pub fn clone(self: *const Line) Error!*Line {
        const row = try self.row.clone();
        errdefer row.destroy();
        const result = try self.allocator.create(Line);
        errdefer self.allocator.destroy(result);
        result.* = .{ .allocator = self.allocator, .row = row, .identity = native.stamp(), .is_wrapped = self.is_wrapped, .wrap_style = self.wrap_style, .render_mode = self.render_mode, .metadata_version = native.stamp() };
        if (self.images) |images| {
            var copy: std.ArrayList(*graphics.LineImage) = .empty;
            try copy.ensureTotalCapacity(self.allocator, images.items.len);
            for (images.items) |image| copy.appendAssumeCapacity(image.clone());
            result.images = copy;
        }
        return result;
    }
    /// Published frames own frozen image geometry. The public clone() above
    /// deliberately shares mutable image identity, matching Swift Line.clone.
    pub fn cloneSnapshot(self: *const Line) Error!*Line {
        const result = try self.clone();
        errdefer result.release();
        if (result.images) |*images| {
            for (images.items) |*slot| {
                const snapshot = try slot.*.snapshot();
                slot.*.deinit();
                slot.* = snapshot;
            }
        }
        return result;
    }
    /// Immutable renderer publication; image geometry is published separately.
    /// No new mutable identity, mutation stamp, or Swift owner is introduced.
    pub fn renderSnapshot(self: *const Line) Error!*Line {
        const row = try self.row.snapshot();
        errdefer row.destroy();
        const result = try self.allocator.create(Line);
        result.* = .{ .allocator = self.allocator, .row = row, .identity = self.identity, .is_wrapped = self.is_wrapped, .wrap_style = self.wrap_style, .render_mode = self.render_mode, .metadata_version = self.metadata_version };
        return result;
    }
    /// A complete immutable publication with the original row revision and
    /// detached image geometry. Neither row nor image lifetime observers cross
    /// this boundary; immutable image payload bytes remain reference-counted.
    pub fn renderSnapshotWithImages(self: *const Line) Error!*Line {
        const result = try self.renderSnapshot();
        errdefer result.release();
        if (self.images) |images| {
            result.images = .empty;
            const copies = &result.images.?;
            try copies.ensureTotalCapacity(self.allocator, images.items.len);
            for (images.items) |image| copies.appendAssumeCapacity(try image.snapshot());
        }
        return result;
    }
    pub fn snapshotFromCells(a: std.mem.Allocator, cells: []const native.StoredCell, extras: []const u32, wrapped: bool, render_mode: RenderMode, revision: u64) Error!*Line {
        const row = try native.Row.fromSnapshotCells(a, cells, extras, revision);
        errdefer row.destroy();
        const result = try a.create(Line);
        result.* = .{ .allocator = a, .row = row, .identity = 0, .is_wrapped = wrapped, .render_mode = render_mode, .metadata_version = revision };
        return result;
    }
    pub fn compactRetainedASCII(self: *Line) bool {
        // Host-exposed or retained mutable lines keep their existing backing.
        // Arbitrary allocator callbacks retain their original call boundaries.
        if (self.allocator.vtable != std.heap.c_allocator.vtable or self.lifetime_observer != null or
            self.refs.load(.acquire) != 1 or self.images != null) return false;
        return self.row.compactASCII() catch false;
    }
    pub fn count(self: *const Line) isize {
        return @intCast(self.row.columnCount());
    }
    pub fn version(self: *const Line) u64 {
        return @max(self.metadata_version, self.row.revision);
    }
    pub fn touch(self: *Line) void {
        self.metadata_version = native.stamp();
    }
    pub fn setWrapped(self: *Line, value: bool) void {
        self.is_wrapped = value;
        self.touch();
    }
    pub fn setRenderMode(self: *Line, value: RenderMode) void {
        self.render_mode = value;
        self.touch();
    }
    pub fn clearImages(self: *Line) void {
        if (self.images) |previous| {
            var images = previous;
            self.images = null;
            self.touch();
            for (images.items) |image| image.deinit();
            images.deinit(self.allocator);
        }
    }
    /// Retain image payload and preserve its renderer identity on attachment.
    pub fn appendImage(self: *Line, image: *graphics.LineImage) Error!void {
        if (self.images) |*images| {
            try images.ensureUnusedCapacity(self.allocator, 1);
            images.appendAssumeCapacity(image.clone());
        } else {
            var images: std.ArrayList(*graphics.LineImage) = .empty;
            try images.ensureUnusedCapacity(self.allocator, 1);
            images.appendAssumeCapacity(image.clone());
            self.images = images;
        }
        self.touch();
    }
    /// Returned extras are borrowed until the next mutation of this line.
    pub fn get(self: *const Line, col: isize) Value {
        return if (col < 0) .{} else self.row.readValue(@intCast(col));
    }
    pub fn cell(self: *const Line, col: isize) Cell {
        return self.get(col).cell;
    }
    pub fn set(self: *Line, col: isize, value: Value) Error!void {
        if (col < 0 or col >= self.count()) return;
        const copied = try self.copyAliasedExtras(value.extras);
        defer if (copied) |data| self.allocator.free(data);
        try self.row.set(@intCast(col), value.cell, if (copied) |data| data else value.extras);
    }
    fn copyAliasedExtras(self: *const Line, values: ?[]const u32) Error!?[]u32 {
        if (values) |data| {
            if (self.row.ownsExtras(data)) return try self.allocator.dupe(u32, data);
        }
        return null;
    }
    pub fn setCell(self: *Line, col: isize, value: Cell) Error!void {
        try self.set(col, .{ .cell = value });
    }
    pub fn appendClusterScalar(self: *Line, scalar: u32, col: isize, width: i8) Error!void {
        if (col < 0 or col >= self.count()) return;
        try self.row.appendScalar(@intCast(col), scalar, width);
    }
    pub fn writeASCII(self: *Line, bytes: []const u8, col: isize, pen: Cell) Error!void {
        if (col < 0 or col > self.count() or bytes.len > @as(usize, @intCast(self.count() - col))) return;
        try self.row.bytes(@intCast(col), bytes, pen);
    }
    pub fn writeOrdinaryUnicode(self: *Line, values: []const native.Scalar, col: isize, pen: Cell, stub: Cell) Error!void {
        if (col < 0) return error.InvalidInput;
        try self.row.unicode(@intCast(col), values, pen, stub);
    }
    pub fn resetMetadata(self: *Line, wrapped: bool) void {
        self.row.discardDeferred();
        self.is_wrapped = wrapped;
        self.wrap_style = .cells;
        self.render_mode = .single;
        self.clearImages();
        self.touch();
    }
    pub fn reset(self: *Line, blank: Cell, wrapped: bool) Error!void {
        try self.resetValue(.{ .cell = blank }, wrapped);
    }
    pub fn resetValue(self: *Line, blank: Value, wrapped: bool) Error!void {
        try self.fill(blank, 0, null);
        // resetMetadata discards a deferred clear; preserve it here instead.
        self.is_wrapped = wrapped;
        self.wrap_style = .cells;
        self.render_mode = .single;
        self.clearImages();
        self.touch();
    }
    pub fn createValue(a: std.mem.Allocator, cols: isize, blank: Value) Error!*Line {
        const result = try create(a, cols, blank.cell);
        errdefer result.release();
        if (blank.extras != null) try result.fill(blank, 0, null);
        return result;
    }
    pub fn resetDeferred(self: *Line, blank: Cell, wrapped: bool) Error!void {
        try self.reset(blank, wrapped);
    }
    pub fn resize(self: *Line, cols: isize, blank: Cell) Error!void {
        try self.resizeValue(cols, .{ .cell = blank });
    }
    pub fn resizeValue(self: *Line, cols: isize, blank: Value) Error!void {
        if (cols < 0) return error.InvalidInput;
        const copied = try self.copyAliasedExtras(blank.extras);
        defer if (copied) |data| self.allocator.free(data);
        try self.row.resizeValue(@intCast(cols), blank.cell, if (copied) |data| data else blank.extras);
    }
    pub fn fill(self: *Line, value: Value, start: isize, end: ?isize) Error!void {
        const upper = @min(end orelse self.count(), self.count());
        if (start < 0 or start >= upper) return;
        const copied = try self.copyAliasedExtras(value.extras);
        defer if (copied) |data| self.allocator.free(data);
        try self.row.fillValue(@intCast(start), @intCast(upper - start), value.cell, if (copied) |data| data else value.extras);
    }
    pub fn fillCell(self: *Line, value: Cell, start: isize, end: ?isize) Error!void {
        try self.fill(.{ .cell = value }, start, end);
    }
    pub fn insertCells(self: *Line, pos: isize, n: isize, right_margin: ?isize, value: Value) Error!void {
        try self.editCells(pos, n, right_margin, value, true);
    }
    pub fn deleteCells(self: *Line, pos: isize, n: isize, right_margin: ?isize, value: Value) Error!void {
        try self.editCells(pos, n, right_margin, value, false);
    }
    fn editCells(self: *Line, pos: isize, n: isize, right_margin: ?isize, value: Value, insert: bool) Error!void {
        if (self.count() == 0 or pos < 0 or n <= 0) return;
        const margin = right_margin orelse (self.count() - 1);
        if (margin < 0) return;
        const active = @min(margin, self.count() - 1) + 1;
        const start = if (insert) @mod(pos, active) else pos;
        if (start >= active) return;
        const count_to_edit = @min(n, active - start);
        const copied = try self.copyAliasedExtras(value.extras);
        defer if (copied) |data| self.allocator.free(data);
        try self.row.edit(@intCast(start), @intCast(count_to_edit), @intCast(active), insert, value.cell, if (copied) |data| data else value.extras);
    }
    /// Inclusive column range; images and row metadata do not move in DECSLRM.
    pub fn copyColumns(self: *Line, source: *const Line, first: isize, last: isize) Error!void {
        const end = @min(last, @min(self.count(), source.count()) - 1);
        if (first < 0 or first > end) return;
        try self.row.copyColumns(source.row, @intCast(first), @intCast(end - first + 1));
    }
    pub fn fillColumns(self: *Line, first: isize, last: isize, value: Cell) Error!void {
        if (last == std.math.maxInt(isize)) return self.fillCell(value, first, null);
        try self.fillCell(value, first, last + 1);
    }
    pub fn usedLength(self: *const Line) isize {
        return self.row.usedLength(false);
    }
    pub fn trimmedLength(self: *const Line) isize {
        return self.row.usedLength(true);
    }
    pub fn meaningful(self: *const Line) bool {
        if (self.is_wrapped or self.render_mode != .single) return true;
        if (self.images) |images| if (images.items.len != 0) return true;
        for (0..self.row.columnCount()) |i| {
            const value = self.row.readValue(i);
            if (!std.meta.eql(value.cell, Cell{}) or value.extras != null) return true;
        }
        return false;
    }
    pub fn trimmedText(self: *const Line, allocator: std.mem.Allocator) Error![]u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);
        const length: usize = @intCast(@max(0, @min(self.trimmedLength(), self.count())));
        for (0..length) |i| {
            const value = self.row.readValue(i);
            if (value.cell.scalar == 0) try output.append(allocator, ' ') else try @import("cell_text.zig").append(&output, allocator, value.cell.scalar, value.extras);
        }
        return output.toOwnedSlice(allocator);
    }
};

test "canonical engine Line creation uses direct compact ASCII and preserves retained contents" {
    const line = try Line.create(std.heap.c_allocator, 120, .{}); defer line.release();
    try std.testing.expect(line.row.isCompact());
    try line.writeASCII("plain", 0, .{});
    try std.testing.expect(line.row.isCompact());
    const frozen = try line.cloneSnapshot(); defer frozen.release();
    try line.writeASCII("color", 0, .{ .fg = 0x01000003 });
    try std.testing.expect(line.row.isCompact());
    for ([_]u32{0x01000004, 0x01000005, 0x01000006}) |color| try line.writeASCII("X", 8, .{ .fg = color });
    try std.testing.expect(!line.row.isCompact());
    try std.testing.expectEqual(@as(u32, 'p'), frozen.get(0).cell.scalar);
    try std.testing.expectEqual(@as(u32, 'c'), line.get(0).cell.scalar);
}
