//! Snapshot-to-row shaping and style identity. The host supplies platform values;
//! all cell iteration, run boundaries, color policy and reuse decisions live here.
const std = @import("std");
const c = @cImport({
    @cInclude("platform_shape.h");
});
const font = @import("render_font.zig");
const proc = @import("render_procedural.zig");
const Line = @import("line.zig").Line;
const Cell = @import("row.zig").Cell;
const Value = @import("row.zig").Row.Value;
const Placeholder = @import("placeholder.zig");
const a = std.heap.c_allocator;
const Object = ?*const anyopaque;
fn retain(o: Object) Object {
    if (o != null) return c.CFRetain(o);
    return null;
}
fn release(o: Object) void {
    if (o != null) c.CFRelease(o);
}
fn equal(x: Object, y: Object) bool {
    return x == y or (x != null and y != null and c.CFEqual(x, y) != 0);
}
fn slice(comptime T: type, p: [*c]const T, n: usize) []const T {
    return if (n == 0) &.{} else p[0..n];
}
fn components(o: Object) ?[4]f64 {
    const rgb = c.cmdy_platform_shape_color_srgb(o) orelse return null;
    defer release(rgb);
    var result: [4]f64 = undefined;
    for (&result, 0..) |*v, i| v.* = c.cmdy_platform_text_color_component(rgb, @intCast(i));
    return result;
}
fn makeColor(v: [4]f64) Object {
    return c.cmdy_platform_shape_color_create(v[0], v[1], v[2], v[3]);
}
fn resolved(o: Object) Object {
    const v = components(o) orelse return null;
    for (v) |n| if (!std.math.isFinite(n)) return null;
    return makeColor(v);
}
fn complement(o: Object) Object {
    const v = components(o) orelse return retain(o);
    return makeColor(.{ 1 - v[0], 1 - v[1], 1 - v[2], v[3] });
}
fn midpoint(x: Object, y: Object) Object {
    const p = components(x) orelse return retain(x);
    const q = components(y) orelse return retain(x);
    return makeColor(.{ (p[0] + q[0]) / 2, (p[1] + q[1]) / 2, (p[2] + q[2]) / 2, (p[3] + q[3]) / 2 });
}
pub const Style = struct {
    refs: usize = 1,
    palette: []Object,
    fonts: [4]Object,
    colors: [5]Object,
    failed: []isize,
    fn create(input: *const c.CmdyShapeStyleInput) !*Style {
        const palette = try a.alloc(Object, input.palette_count);
        errdefer a.free(palette);
        const failed = try a.dupe(isize, slice(isize, input.failed_rows, input.failed_row_count));
        errdefer a.free(failed);
        std.mem.sort(isize, failed, {}, std.sort.asc(isize));
        const s = try a.create(Style);
        s.* = .{ .palette = palette, .failed = failed, .fonts = undefined, .colors = undefined };
        for (palette, 0..) |*v, i| v.* = retain(input.palette[i]);
        for (&s.fonts, input.fonts) |*v, o| v.* = retain(o);
        for (&s.colors, input.colors) |*v, o| v.* = retain(o);
        return s;
    }
    fn retained(s: *Style) *Style {
        s.refs += 1;
        return s;
    }
    pub fn free(s: *Style) void {
        s.refs -= 1;
        if (s.refs != 0) return;
        for (s.palette) |v| release(v);
        for (s.fonts) |v| release(v);
        for (s.colors) |v| release(v);
        a.free(s.palette);
        a.free(s.failed);
        a.destroy(s);
    }
    pub fn resolve(s: *const Style) ?*Style {
        const palette = a.alloc(Object, s.palette.len) catch return null;
        defer a.free(palette);
        var count: usize = 0;
        defer for (palette[0..count]) |v| release(v);
        for (palette, s.palette) |*out, v| {
            out.* = resolved(v) orelse return null;
            count += 1;
        }
        var resolved_colors: [5]Object = undefined;
        var color_count: usize = 0;
        defer for (resolved_colors[0..color_count]) |v| release(v);
        for (&resolved_colors, s.colors) |*out, v| {
            out.* = resolved(v) orelse return null;
            color_count += 1;
        }
        var input: c.CmdyShapeStyleInput = .{ .palette = palette.ptr, .palette_count = palette.len, .fonts = s.fonts, .colors = resolved_colors, .failed_rows = s.failed.ptr, .failed_row_count = s.failed.len };
        return create(&input) catch null;
    }
    fn eql(s: *const Style, t: *const Style) bool {
        if (s.palette.len != t.palette.len or !std.mem.eql(isize, s.failed, t.failed)) return false;
        for (s.palette, t.palette) |x, y| if (!equal(x, y)) return false;
        for (s.fonts, t.fonts) |x, y| if (!equal(x, y)) return false;
        for (s.colors, t.colors) |x, y| if (!equal(x, y)) return false;
        return true;
    }
    fn failedRow(s: *const Style, row: isize) bool {
        for (s.failed) |r| if (r == row) return true;
        return false;
    }
    fn fontFor(s: *const Style, style: u8) Object {
        return s.fonts[@as(usize, @intFromBool(style & 1 != 0)) + 2 * @as(usize, @intFromBool(style & 64 != 0))];
    }
};
pub const Context = struct {
    frame: ?*Style = null,
    previous: ?*Style = null,
    revision: u64 = 0,
    reusable: bool = false,
    fn begin(ctx: *Context) void {
        if (ctx.frame) |s| s.free();
        ctx.frame = null;
    }
    fn set(ctx: *Context, style: *Style) *Style {
        if (ctx.frame) |s| return s;
        const candidate = style.resolve();
        ctx.reusable = candidate != null;
        const same = if (candidate) |s| if (ctx.previous) |old| s.eql(old) else false else ctx.previous == null;
        if (!same) {
            ctx.revision +%= 1;
            if (ctx.previous) |s| s.free();
            ctx.previous = if (candidate) |s| s.retained() else null;
        }
        ctx.frame = candidate orelse style.retained();
        return ctx.frame.?;
    }
};
export fn cmdy_shape_style_create(p: ?*const c.CmdyShapeStyleInput) ?*Style {
    return Style.create(p orelse return null) catch null;
}
export fn cmdy_shape_style_retain(p: ?*Style) ?*Style {
    return if (p) |s| s.retained() else null;
}
export fn cmdy_shape_style_free(p: ?*Style) void {
    if (p) |s| s.free();
}
export fn cmdy_shape_style_equal(p: ?*const Style, q: ?*const Style) u8 {
    return @intFromBool(if (p) |s| if (q) |t| s.eql(t) else false else q == null);
}
export fn cmdy_shape_style_object(p: ?*const Style, group: u8, index: usize) Object {
    const s = p orelse return null;
    const items: []const Object = switch (group) {
        0 => s.palette,
        1 => &s.fonts,
        2 => &s.colors,
        else => &.{},
    };
    return if (index < items.len) items[index] else null;
}
export fn cmdy_shape_style_count(p: ?*const Style, group: u8) usize {
    const s = p orelse return 0;
    return switch (group) {
        0 => s.palette.len,
        1 => 4,
        2 => 5,
        3 => s.failed.len,
        else => 0,
    };
}
export fn cmdy_shape_style_failed_rows(p: ?*const Style) ?[*]const isize {
    return (p orelse return null).failed.ptr;
}
export fn cmdy_shape_context_create() ?*Context {
    const v = a.create(Context) catch return null;
    v.* = .{};
    return v;
}
export fn cmdy_shape_context_free(p: ?*Context) void {
    const v = p orelse return;
    v.begin();
    if (v.previous) |s| s.free();
    a.destroy(v);
}
export fn cmdy_shape_context_begin(p: ?*Context) void {
    if (p) |v| v.begin();
}
export fn cmdy_shape_context_style(p: ?*Context) ?*Style {
    return (p orelse return null).frame;
}
export fn cmdy_shape_context_set(p: ?*Context, s: ?*Style) ?*Style {
    return (p orelse return null).set(s orelse return null);
}
export fn cmdy_shape_context_revision(p: ?*const Context, version: u64, images: u8, out: ?*u64) u8 {
    const ctx = p orelse return 0;
    if (version == 0 or images != 0 or !ctx.reusable) return 0;
    if (out) |v| v.* = ctx.revision;
    return 1;
}

fn mapColor(word: u32, foreground: bool, bold: bool, inverted: bool, s: *const Style) Object {
    const base = s.colors[if (foreground) @as(usize, 0) else 1];
    return switch (word >> 24) {
        1 => blk: {
            var index: usize = word & 0xff;
            if (foreground and bold and index <= 6) index += 8;
            break :blk retain(if (index < s.palette.len) s.palette[index] else base);
        },
        2 => makeColor(.{ @as(f64, @floatFromInt((word >> 16) & 255)) / 255, @as(f64, @floatFromInt((word >> 8) & 255)) / 255, @as(f64, @floatFromInt(word & 255)) / 255, 1 }),
        3 => complement(base),
        else => if (inverted) complement(base) else retain(base),
    };
}
const Colors = struct {
    fg: Object,
    bg: Object,
    explicit: bool,
    fn deinit(v: Colors) void {
        release(v.fg);
        release(v.bg);
    }
};
fn colors(cell: Cell, failed: bool, s: *const Style) Colors {
    if (failed) return .{ .fg = retain(s.colors[3]), .bg = retain(s.colors[4]), .explicit = true };
    const inverse = cell.style & 8 != 0;
    const fgword = if (inverse) cell.bg else cell.fg;
    const bgword = if (inverse) cell.fg else cell.bg;
    var fg = mapColor(fgword, true, cell.style & 1 != 0, inverse, s);
    const bg = mapColor(bgword, false, false, inverse, s);
    if (cell.style & 32 != 0) {
        const mixed = midpoint(fg, bg);
        release(fg);
        fg = mixed;
    }
    if (cell.style & 16 != 0) {
        release(fg);
        fg = retain(bg);
    }
    return .{ .fg = fg, .bg = bg, .explicit = inverse or bgword != 0 };
}
fn put(dict: c.CFMutableDictionaryRef, index: u32, value: Object) void {
    c.CFDictionarySetValue(dict, c.cmdy_platform_text_attribute_key(index), value);
}
fn number(dict: c.CFMutableDictionaryRef, index: u32, value: i32) void {
    var n = value;
    const o = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &n);
    defer release(o);
    put(dict, index, o);
}
/// Scoped to one worker-created row. Sources are immutable resolved/generated
/// colors, never externally supplied dynamic attributes. Each occupied slot
/// owns both objects; hash collisions always verify equality before reuse.
/// Rows of one frame (and successive frames) repeat the same handful of
/// colors. Converting each to a device-RGB snapshot is a ColorSync round trip,
/// so the bounded snapshot cache lives for the shaping thread rather than for
/// one row. Each render worker thread owns its own instance.
threadlocal var thread_snapshots: SnapshotColors = .{};

const SnapshotColors = struct {
    const Entry = struct { source: Object = null, snapshot: Object = null };
    entries: [64]Entry = @splat(.{}),
    fn capture(self: *SnapshotColors, source: Object) Object {
        const value = source orelse return null;
        const entry = &self.entries[c.CFHash(value) % self.entries.len];
        if (equal(entry.source, value)) return retain(entry.snapshot);
        const snapshot = c.cmdy_platform_text_color_snapshot(value) orelse return null;
        const owned_source = retain(value);
        release(entry.source);
        release(entry.snapshot);
        entry.* = .{ .source = owned_source, .snapshot = retain(snapshot) };
        return snapshot;
    }
    fn deinit(self: *SnapshotColors) void {
        for (&self.entries) |*entry| {
            release(entry.source);
            release(entry.snapshot);
            entry.* = .{};
        }
    }
};

test "row color snapshots preserve exact values across collisions eviction and owner retirement" {
    const t = std.testing;
    var snapshots: SnapshotColors = .{};
    defer snapshots.deinit();
    var expected: [160]Object = @splat(null);
    var actual: [160]Object = @splat(null);
    defer for (expected) |value| release(value);
    defer for (actual) |value| release(value);
    var seen: [64]bool = @splat(false);
    var collisions: usize = 0;
    for (&expected, &actual, 0..) |*reference, *captured, index| {
        const component = @as(f64, @floatFromInt(index)) / 159;
        const source = makeColor(.{ component, 1 - component, component / 2, 0.25 + component / 2 }) orelse return error.OutOfMemory;
        defer release(source);
        const slot = c.CFHash(source) % seen.len;
        if (seen[slot]) collisions += 1;
        seen[slot] = true;
        reference.* = c.cmdy_platform_text_color_snapshot(source) orelse return error.OutOfMemory;
        captured.* = snapshots.capture(source) orelse return error.OutOfMemory;
        const repeated = snapshots.capture(source) orelse return error.OutOfMemory;
        defer release(repeated);
        try t.expect(equal(reference.*, captured.*));
        try t.expect(equal(reference.*, repeated));
    }
    try t.expect(collisions >= expected.len - seen.len);
    snapshots.deinit();
    // Every returned value must still own its normalized color after both the
    // original source objects and all cache slots have gone away.
    for (expected, actual) |reference, captured| try t.expect(equal(reference, captured));
    for (expected) |reference| {
        const restored = snapshots.capture(reference) orelse return error.OutOfMemory;
        defer release(restored);
        try t.expect(equal(reference, restored));
    }
}

fn attributes(cell: Cell, selected: bool, failed: bool, s: *const Style) Object {
    return storageAttributes(cell, selected, failed, s, null);
}
fn storageAttributes(cell: Cell, selected: bool, failed: bool, s: *const Style, color_cache: ?*SnapshotColors) Object {
    const dict = c.CFDictionaryCreateMutable(null, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return null;
    const v = colors(cell, failed, s);
    defer v.deinit();
    put(dict, 0, s.fontFor(cell.style));
    put(dict, 1, v.fg);
    number(dict, 8, 0);
    if (v.explicit or failed) put(dict, 2, v.bg);
    if (selected) put(dict, 3, s.colors[2]);
    if (cell.style & 2 != 0) {
        number(dict, 9, 1);
        number(dict, 10, if (cell.underline_kind == 0 or cell.underline_kind > 5) 1 else cell.underline_kind);
        const underline = if (cell.underline_present != 0) mapColor(cell.underline_color, true, cell.style & 1 != 0, false, s) else retain(v.fg);
        defer release(underline);
        put(dict, 5, underline);
    }
    if (cell.style & 128 != 0) {
        number(dict, 11, 1);
        put(dict, 7, v.fg);
    }
    if (color_cache) |cache| {
        // Deferred rows already own their style. Preserve the external
        // snapshot's device-RGB representation while constructing this private
        // dictionary, before its immutable attributed string is created.
        for (1..8) |index| {
            const key = c.cmdy_platform_text_attribute_key(@intCast(index));
            const value = c.CFDictionaryGetValue(dict, key) orelse continue;
            const color = cache.capture(value) orelse {
                release(dict);
                return null;
            };
            defer release(color);
            c.CFDictionarySetValue(dict, key, color);
        }
    }
    return dict;
}
export fn cmdy_shape_attributes(cell: ?*const Cell, selected: u8, failed: u8, s: ?*const Style) Object {
    return attributes((cell orelse return null).*, selected != 0, failed != 0, s orelse return null);
}
export fn cmdy_shape_map_color(word: u32, foreground: u8, bold: u8, s: ?*const Style) Object {
    return mapColor(word, foreground != 0, bold != 0, false, s orelse return null);
}
export fn cmdy_shape_explicit_background(cell: ?*const Cell) u8 {
    const v = cell orelse return 0;
    return @intFromBool(v.bg != 0 or v.style & 8 != 0);
}
fn attrEqual(x: Cell, y: Cell) bool {
    return x.fg == y.fg and x.bg == y.bg and x.style == y.style and x.underline_kind == y.underline_kind and x.underline_present == y.underline_present and (x.underline_present == 0 or x.underline_color == y.underline_color);
}
fn valid(s: u32) bool {
    return s <= 0x10ffff and !(s >= 0xd800 and s <= 0xdfff);
}
fn appendScalar(text: *std.ArrayList(u16), s: u32) !void {
    if (s <= 0xffff) {
        try text.append(a, @intCast(s));
    } else {
        const n = s - 0x10000;
        try text.appendSlice(a, &.{ @intCast(0xd800 + (n >> 10)), @intCast(0xdc00 + (n & 0x3ff)) });
    }
}
fn appendText(text: *std.ArrayList(u16), value: Value) !void {
    if (value.cell.scalar == 0 or !valid(value.cell.scalar)) {
        try text.append(a, 32);
        return;
    }
    try appendScalar(text, value.cell.scalar);
    for (value.extras orelse &.{}) |s| if (valid(s)) try appendScalar(text, s);
}
fn attributed(text: []const u16, attrs: Object) Object {
    const string = c.CFStringCreateWithCharacters(null, text.ptr, @intCast(text.len)) orelse return null;
    defer release(string);
    return c.CFAttributedStringCreate(null, string, @ptrCast(attrs));
}
pub const Result = struct {
    segments: std.ArrayList(c.CmdyRenderTextSegment) = .empty,
    blocks: std.ArrayList(c.CmdyShapeBlock) = .empty,
    boxes: std.ArrayList(c.CmdyRenderBox) = .empty,
    placeholders: std.ArrayList(c.CmdyShapePlaceholder) = .empty,
    represented: isize = 0,
    pub fn free(r: *Result) void {
        for (r.segments.items) |seg| {
            release(seg.attributed_string);
            a.free(seg.boundaries[0..seg.boundary_count]);
        }
        for (r.blocks.items) |block| release(block.foreground);
        for (r.boxes.items) |box| release(box.foreground);
        r.segments.deinit(a);
        r.blocks.deinit(a);
        r.boxes.deinit(a);
        r.placeholders.deinit(a);
        a.destroy(r);
    }
};
const Pending = struct {
    cell: Cell = .{},
    selected: bool = false,
    column: isize = 0,
    width: isize = 1,
    count: isize = 0,
    text: std.ArrayList(u16) = .empty,
    bounds: std.ArrayList(isize) = .empty,
    fn deinit(p: *Pending) void {
        p.text.deinit(a);
        p.bounds.deinit(a);
    }
    fn flush(p: *Pending, result: *Result, failed: bool, s: *const Style, color_cache: ?*SnapshotColors) !void {
        if (p.count == 0) return;
        const attrs = storageAttributes(p.cell, p.selected, failed, s, color_cache) orelse return error.OutOfMemory;
        defer release(attrs);
        const string = attributed(p.text.items, attrs) orelse return error.OutOfMemory;
        errdefer release(string);
        const bounds = try a.dupe(isize, p.bounds.items);
        errdefer a.free(bounds);
        try result.segments.append(a, .{ .attributed_string = string, .column = p.column, .column_width = p.width, .character_count = p.count, .boundaries = bounds.ptr, .boundary_count = bounds.len, .has_boundaries = 1 });
        p.count = 0;
        p.text.clearRetainingCapacity();
        p.bounds.clearRetainingCapacity();
    }
};
fn selectedAt(selected: bool, lower: isize, upper: isize, column: isize, width: isize) bool {
    return selected and lower <= column + width - 1 and column <= upper;
}
pub fn shape(line: *const Line, row: isize, s: *const Style, selection: bool, lower: isize, upper: isize) !*Result {
    return shapeWithStyleRow(line, row, row, s, selection, lower, upper);
}
pub fn shapeWithStyleRow(line: *const Line, row: isize, style_row: isize, s: *const Style, selection: bool, lower: isize, upper: isize) !*Result {
    return shapeForStorage(line, row, style_row, s, selection, lower, upper, false);
}
/// Render-owner entry: the caller owns a privately resolved style, and takes
/// sole ownership of the result. Colors match external-input snapshot output.
pub fn shapeFrozenWithStyleRow(line: *const Line, row: isize, style_row: isize, s: *const Style) !*Result {
    return shapeForStorage(line, row, style_row, s, false, 0, 0, true);
}
fn storageColor(value: Object, color_cache: ?*SnapshotColors) Object {
    return if (color_cache) |cache| cache.capture(value) else retain(value);
}
fn shapeForStorage(line: *const Line, row: isize, style_row: isize, s: *const Style, selection: bool, lower: isize, upper: isize, comptime snapshot_colors: bool) !*Result {
    const color_cache: ?*SnapshotColors = if (snapshot_colors) &thread_snapshots else null;
    const r = try a.create(Result);
    r.* = .{};
    errdefer r.free();
    const failed = s.failedRow(style_row);
    var last = line.count();
    while (last > 0) {
        last -= 1;
        const cell = line.cell(last);
        if (cell.width == 0) continue;
        const width = @max(1, @as(isize, cell.width));
        if (failed or selectedAt(selection, lower, upper, last, width) or cell.scalar != 0 or !attrEqual(cell, .{})) {
            r.represented = last + 1;
            break;
        }
    }
    var decoder: Placeholder.State = .{};
    var pending: Pending = .{};
    defer pending.deinit();
    var col: isize = 0;
    while (col < r.represented) : (col += 1) {
        const value = line.get(col);
        const cell = value.cell;
        if (cell.width == 0) continue;
        const width = @max(1, @as(isize, cell.width));
        const selected = selectedAt(selection, lower, upper, col, width);
        if (pending.count != 0 and (!attrEqual(pending.cell, cell) or pending.selected != selected or pending.width != width)) try pending.flush(r, failed, s, color_cache);
        if (pending.count == 0) {
            pending.cell = cell;
            pending.selected = selected;
            pending.column = col;
            pending.width = width;
            try pending.bounds.append(a, 0);
        }
        const placeholder = decoder.decode(cell.scalar, cell.fg, if (cell.underline_present != 0) cell.underline_color else null, value.extras orelse &.{}, row, col);
        var rects: [3]font.c.CmdyRenderBlockRect = undefined;
        const rect_count = proc.blockRects(cell.scalar, &rects);
        if (placeholder) |v| {
            try r.placeholders.append(a, @bitCast(v));
            try pending.text.append(a, 32);
        } else if (cell.scalar == 0x10eeee) {
            try pending.text.append(a, 32);
        } else if (rect_count > 0) {
            const color = colors(cell, failed, s);
            defer color.deinit();
            var block: c.CmdyShapeBlock = std.mem.zeroes(c.CmdyShapeBlock);
            block.column = col;
            block.column_width = width;
            block.code_point = cell.scalar;
            block.rect_count = rect_count;
            block.foreground = storageColor(color.fg, color_cache) orelse return error.OutOfMemory;
            errdefer release(block.foreground);
            for (0..rect_count) |i| block.rects[i] = @bitCast(rects[i]);
            try r.blocks.append(a, block);
            try pending.text.append(a, 32);
        } else if (cell.scalar >= 0x2500 and cell.scalar <= 0x257f) {
            const color = colors(cell, failed, s);
            defer color.deinit();
            const fg = storageColor(color.fg, color_cache) orelse return error.OutOfMemory;
            errdefer release(fg);
            try r.boxes.append(a, .{ .column = col, .column_width = width, .code_point = cell.scalar, .foreground = fg });
            try pending.text.append(a, 32);
        } else {
            decoder.reset();
            try appendText(&pending.text, value);
        }
        pending.count += 1;
        try pending.bounds.append(a, @intCast(pending.text.items.len));
    }
    try pending.flush(r, failed, s, color_cache);
    return r;
}
export fn cmdy_shape_line(line: ?*const Line, row: isize, s: ?*const Style, selected: u8, lower: isize, upper: isize) ?*Result {
    return shape(line orelse return null, row, s orelse return null, selected != 0, lower, upper) catch null;
}
export fn cmdy_shape_result_free(p: ?*Result) void {
    if (p) |r| r.free();
}
export fn cmdy_shape_result_view(p: ?*const Result, out: ?*c.CmdyShapeView) void {
    const r = p orelse return;
    const v = out orelse return;
    v.* = .{ .segments = r.segments.items.ptr, .segment_count = r.segments.items.len, .blocks = r.blocks.items.ptr, .block_count = r.blocks.items.len, .boxes = r.boxes.items.ptr, .box_count = r.boxes.items.len, .placeholders = r.placeholders.items.ptr, .placeholder_count = r.placeholders.items.len, .represented_columns = r.represented };
}
export fn cmdy_shape_cursor(line: ?*const Line, col: isize, s: ?*const Style, caret: Object, text: Object) Object {
    const l = line orelse return null;
    const style = s orelse return null;
    if (col < 0 or col >= l.count()) return null;
    const value = l.get(col);
    var chars: std.ArrayList(u16) = .empty;
    defer chars.deinit(a);
    appendText(&chars, value) catch return null;
    const dict = c.CFDictionaryCreateMutable(null, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer release(dict);
    put(dict, 0, style.fontFor(value.cell.style));
    put(dict, 1, text orelse style.colors[0]);
    put(dict, 2, caret);
    number(dict, 8, 0);
    return attributed(chars.items, dict);
}
export fn cmdy_shape_font_variant(source: Object, bold: u8, italic: u8) Object {
    return c.cmdy_platform_shape_font_traits(source, (if (bold != 0) @as(c_ulong, 2) else 0) | (if (italic != 0) @as(c_ulong, 1) else 0));
}
fn advance(source: Object, character: u16) f64 {
    var ch = character;
    var glyph: c.CGGlyph = 0;
    if (!c.CTFontGetGlyphsForCharacters(@ptrCast(source), &ch, &glyph, 1) or glyph == 0) return 0;
    return c.CTFontGetAdvancesForGlyphs(@ptrCast(source), c.kCTFontOrientationHorizontal, &glyph, null, 1);
}
export fn cmdy_shape_metrics(source: Object, multiplier: f64, scale: f64) c.CmdyShapeMetrics {
    const safe = @max(1, if (std.math.isFinite(scale)) scale else 1);
    const measured = advance(source, 0x30);
    const width = if (measured > 0) measured else @max(1, advance(source, 0x57));
    const ascent = c.cmdy_platform_shape_font_metric(source, 0);
    const descent = @abs(c.cmdy_platform_shape_font_metric(source, 1));
    const leading = c.cmdy_platform_shape_font_metric(source, 2);
    const natural = @ceil(ascent + descent + leading);
    const height = @min(8192, @max(1, natural * multiplier));
    const h = @max(1, @ceil(height * safe) / safe);
    return .{ .width = @max(1, @ceil(width * safe) / safe), .height = h, .baseline = h - @ceil(descent + leading) };
}

/// Internal viewport-only representation. Each original text segment keeps its
/// geometry and glyph work, but owns its normalized background separately.
/// The public attributed-input path never sees these background-free strings.
pub const FrozenPaintResult = struct {
    result: *Result,
    backgrounds: std.ArrayList(Object) = .empty,
    pub fn free(self: *FrozenPaintResult) void {
        self.result.free();
        for (self.backgrounds.items) |background| release(background);
        self.backgrounds.deinit(a);
        a.destroy(self);
    }
};

/// Return null for an unsupported row before creating a partial representation.
/// Every ASCII glyph, including a space in an arbitrary font, is still drawn.
pub fn shapeFrozenPaint(line: *const Line, style_row: isize, style: *const Style) !?*FrozenPaintResult {
    if (style.failedRow(style_row)) return null;
    var represented: isize = 0;
    var column: isize = 0;
    while (column < line.count()) : (column += 1) {
        const value = line.get(column);
        const cell = value.cell;
        if (cell.width != 1 or cell.style & (8 | 16 | 32) != 0 or
            (cell.scalar != 0 and (cell.scalar < 32 or cell.scalar > 126)) or
            (value.extras orelse &.{}).len != 0) return null;
        if (cell.scalar != 0 or !attrEqual(cell, .{})) represented = column + 1;
    }
    const shaped = try a.create(Result);
    shaped.* = .{ .represented = represented };
    errdefer shaped.free();
    const paint = try a.create(FrozenPaintResult);
    paint.* = .{ .result = shaped };
    errdefer {
        for (paint.backgrounds.items) |background| release(background);
        paint.backgrounds.deinit(a);
        a.destroy(paint);
    }
    const snapshots = &thread_snapshots;
    var ink_cell: Cell = .{};
    var ink_attributes: Object = null;
    defer release(ink_attributes);
    var chars: std.ArrayList(u16) = .empty;
    defer chars.deinit(a);
    var bounds: std.ArrayList(isize) = .empty;
    defer bounds.deinit(a);
    column = 0;
    while (column < represented) {
        const first = line.cell(column);
        var end = column + 1;
        while (end < represented and attrEqual(first, line.cell(end))) : (end += 1) {}
        var ink = first;
        ink.bg = 0;
        if (ink_attributes == null or !attrEqual(ink, ink_cell)) {
            const base_attributes = storageAttributes(ink, false, false, style, snapshots) orelse return error.OutOfMemory;
            release(ink_attributes);
            ink_attributes = base_attributes;
            ink_cell = ink;
        }
        const background: Object = if (first.bg == 0) null else bg: {
            const source = mapColor(first.bg, false, false, false, style);
            defer release(source);
            break :bg snapshots.capture(source) orelse return error.OutOfMemory;
        };
        errdefer release(background);
        chars.clearRetainingCapacity();
        bounds.clearRetainingCapacity();
        try bounds.append(a, 0);
        var at = column;
        while (at < end) : (at += 1) {
            const scalar = line.cell(at).scalar;
            try chars.append(a, @intCast(if (scalar == 0) 32 else scalar));
            try bounds.append(a, at - column + 1);
        }
        const string = attributed(chars.items, ink_attributes) orelse return error.OutOfMemory;
        errdefer release(string);
        const boundaries_copy = try a.dupe(isize, bounds.items);
        errdefer a.free(boundaries_copy);
        // Reserve both containers before either takes ownership, so failure
        // cannot leave an unpaired background or double-owned string.
        try shaped.segments.ensureUnusedCapacity(a, 1);
        try paint.backgrounds.ensureUnusedCapacity(a, 1);
        shaped.segments.appendAssumeCapacity(.{ .attributed_string = string, .column = column, .column_width = 1, .character_count = end - column, .boundaries = boundaries_copy.ptr, .boundary_count = boundaries_copy.len, .has_boundaries = 1 });
        paint.backgrounds.appendAssumeCapacity(background);
        column = end;
    }
    return paint;
}
