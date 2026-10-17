//! Renderer geometry and pure motion policies. Host coordinates use doubles;
//! device vertices and cursor interpolation retain the original Float math.
const std = @import("std");
extern "c" fn exp(x: f64) f64;
extern "c" fn expf(x: f32) f32;
extern "c" fn cos(x: f64) f64;

pub const Vec2 = extern struct { x: f32 = 0, y: f32 = 0 };
pub const Rect = extern struct {
    x: f64 = 0, y: f64 = 0, width: f64 = 0, height: f64 = 0,
    fn minX(self: Rect) f64 { return smin(f64, self.x, self.x + self.width); }
    fn maxX(self: Rect) f64 { return smax(f64, self.x, self.x + self.width); }
    fn minY(self: Rect) f64 { return smin(f64, self.y, self.y + self.height); }
};
pub const Scissor = extern struct { x: u64, y: u64, width: u64, height: u64 };
pub const VisibleRow = extern struct { display_index: i64, source_row: i64, cache_row: i64 };
pub const ScrollTranslation = extern struct { snapped_points: f64, rendered_points: f64, y_shift_pixels: f32 };
pub const CursorStep = extern struct { position: Vec2, is_animating: bool };
pub const Revision = extern struct { content: u64, context: u64 };

// Swift's ordered min/max keep the first operand when comparisons with NaN
// are unordered. Do not use LLVM minnum/maxnum, whose NaN rules differ.
pub fn smin(comptime T: type, a: T, b: T) T { return if (b < a) b else a; }
pub fn smax(comptime T: type, a: T, b: T) T { return if (a < b) b else a; }
fn clamp(comptime T: type, value: T, low: T, high: T) T { return smin(T, high, smax(T, low, value)); }
pub fn boundedInt(value: f64) i64 {
    if (std.math.isNan(value)) return 0;
    if (value >= 0x1p63) return std.math.maxInt(i64);
    if (value <= -0x1p63) return std.math.minInt(i64);
    return @intFromFloat(value);
}

pub const VisibleRows = struct {
    display_top: i64,
    retained_origin: i64,
    first: i64,
    end: i64,
    pub fn init(rows: i64, buffer_lines: i64, display_top: i64, retained_origin: i64, requested_extra: i64) VisibleRows {
        var result = VisibleRows{ .display_top = display_top, .retained_origin = retained_origin, .first = 0, .end = 0 };
        if (rows <= 0 or buffer_lines <= 0) return result;
        const extra: i128 = @min(buffer_lines, @max(0, requested_extra));
        const top: i128 = display_top;
        const origin: i128 = retained_origin;
        const first = @max(0, top - extra, @as(i128, std.math.minInt(i64)) - origin, top + std.math.minInt(i64));
        const end = @min(buffer_lines, top + rows + extra, @as(i128, std.math.maxInt(i64)) - origin + 1, top + std.math.maxInt(i64) + 1);
        if (first >= end) return result;
        result.first = @intCast(first);
        result.end = @intCast(end);
        return result;
    }
    pub fn count(self: VisibleRows) usize { return @intCast(self.end - self.first); }
    pub fn at(self: VisibleRows, index: usize) ?VisibleRow {
        if (index >= self.count()) return null;
        const source = self.first + @as(i64, @intCast(index));
        return .{ .display_index = source - self.display_top, .source_row = source, .cache_row = self.retained_origin + source };
    }
};

pub fn displayRow(source: i64, top: i64, rows: i64) ?i64 {
    const value = @subWithOverflow(source, top);
    return if (value[1] == 0 and value[0] >= 0 and value[0] < rows) value[0] else null;
}
pub fn cacheRow(source: i64, origin: i64) ?i64 {
    const value = @addWithOverflow(source, origin);
    return if (value[1] == 0) value[0] else null;
}
pub fn viewportTranslation(content_x: f64, view_height: f64, top_inset: f64, cell_height: f64, display_row: i64, scale: f64) Vec2 {
    const safe_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const row_bottom: f64 = @floatFromInt(@as(i128, display_row) + 1);
    return .{ .x = @floatCast(@round(content_x * safe_scale)), .y = @floatCast(@round((view_height - top_inset - row_bottom * cell_height) * safe_scale)) };
}
pub fn smoothScrollTranslation(offset: f64, scale: f64) ScrollTranslation {
    const safe_scale = if (std.math.isFinite(scale) and scale > 0) clamp(f64, scale, 1, 16) else 1;
    const finite_offset = if (std.math.isFinite(offset)) offset else 0;
    const translated = @round(clamp(f64, finite_offset, -1_000_000, 1_000_000));
    const points = translated / safe_scale;
    return .{ .snapped_points = points, .rendered_points = -points, .y_shift_pixels = @floatCast(-translated) };
}
pub fn effectiveScroll(source: f64, held: f64, glide: f64) f64 {
    if (!std.math.isFinite(source) or !std.math.isFinite(held) or !std.math.isFinite(glide)) return 0;
    return source + held + glide;
}
pub fn decayedGlide(value: f64, elapsed: f64) f64 {
    if (!std.math.isFinite(value) or !std.math.isFinite(elapsed)) return 0;
    // This offset eases discrete wheel steps after the model has moved. Keep
    // the transition brief: a long tail delays the complete target viewport
    // after the wheel has stopped. Precise gestures use the held pixel offset.
    const next = value * exp(-600 * smax(f64, 0.001, smin(f64, 0.05, elapsed)));
    return if (@abs(next) < 0.5) 0 else next;
}
pub fn accumulatedGlide(current: f64, impulse: f64, cell_height: f64) f64 {
    if (!std.math.isFinite(current) or !std.math.isFinite(impulse)) return 0;
    const height = if (std.math.isFinite(cell_height) and cell_height > 0) cell_height else 16;
    const cap = smax(f64, 1, height * 1.25);
    return smax(f64, -cap, smin(f64, cap, current + impulse));
}
pub fn scrollSelfAnimates(glide: f64) bool { return std.math.isFinite(glide) and @abs(glide) >= 0.5; }
pub fn fringeRows(offset: f64, cell_height: f64, enabled: bool) i64 {
    if (!enabled or !std.math.isFinite(offset) or !std.math.isFinite(cell_height) or cell_height <= 0 or @abs(offset) <= 0.5) return 0;
    return boundedInt(@ceil(@abs(offset) / cell_height)) +| 1;
}
pub fn deviceTopInset(inset: f64, scale: f64) i64 {
    const safe_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    return @max(0, boundedInt(@ceil(inset * safe_scale)));
}
pub fn scissor(width_value: f64, height_value: f64, top_inset: f64, bottom_inset: f64, left_inset: f64, scale: f64) Scissor {
    const safe_scale = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const width = @max(0, boundedInt(@floor(width_value)));
    const height = @max(0, boundedInt(@floor(height_value)));
    const left = @min(width, @max(0, boundedInt(@round(left_inset * safe_scale))));
    const top = @min(height, deviceTopInset(top_inset, safe_scale));
    const bottom = @min(height - top, @max(0, boundedInt(@round(bottom_inset * safe_scale))));
    return .{ .x = @intCast(left), .y = @intCast(top), .width = @intCast(width - left), .height = @intCast(height - top - bottom) };
}
pub fn cursorOpacity(blinks: bool, focused: bool, now: f64, activity: f64, active_until: f64) f32 {
    if (!blinks or !focused or !(now < active_until) or !std.math.isFinite(now) or !std.math.isFinite(activity)) return 1;
    const elapsed = smax(f64, 0, now - activity);
    const phase = @rem(elapsed, 1.2) / 1.2;
    return @floatCast(0.5 * (1 + cos(2 * std.math.pi * phase)));
}
pub fn finalCursorFrame(timer_active: bool, blink_eligible: bool, focused: bool, visible: bool, now: f64, active_until: f64) bool {
    return timer_active and blink_eligible and focused and visible and now >= active_until;
}
fn lengthSquared(v: Vec2) f32 { return v.x * v.x + v.y * v.y; }
pub fn cursorStep(from: Vec2, to: Vec2, should_draw: bool, smooth: bool, live_resize: bool, elapsed: f32, speed: f32, maximum_distance: f32, cell: Vec2) CursorStep {
    if (!should_draw or !smooth or live_resize) return .{ .position = to, .is_animating = false };
    const offset = Vec2{ .x = from.x - to.x, .y = from.y - to.y };
    const units = Vec2{ .x = offset.x / smax(f32, 1, cell.x), .y = offset.y / smax(f32, 1, cell.y) };
    const fits = maximum_distance <= 0 or lengthSquared(units) <= maximum_distance * maximum_distance;
    // A move that changes both row and column (a line break, a wrap) jumps:
    // the cursor never slides diagonally across lines.
    const diagonal = @abs(units.x) >= 0.5 and @abs(units.y) >= 0.5;
    if (!(lengthSquared(offset) > 0.25 and fits) or diagonal) return .{ .position = to, .is_animating = false };
    const seconds = clamp(f32, elapsed, 0.001, 0.05);
    const response = clamp(f32, speed, 0.1, 8);
    const retention = expf(-(seconds * (response * 40)));
    const candidate = Vec2{ .x = to.x + offset.x * retention, .y = to.y + offset.y * retention };
    const moving = lengthSquared(.{ .x = to.x - candidate.x, .y = to.y - candidate.y }) > 0.25;
    return .{ .position = if (moving) candidate else to, .is_animating = moving };
}
pub fn selectionRect(lower_value: i64, upper_value: i64, columns: i64, width: f64, height: f64) ?Rect {
    if (columns <= 0 or !std.math.isFinite(width) or width <= 0 or !std.math.isFinite(height) or height <= 0) return null;
    const lower = @max(0, lower_value);
    const upper = @min(columns - 1, upper_value);
    if (lower > upper) return null;
    const x0 = @floor(@as(f64, @floatFromInt(lower)) * width);
    const x1 = @ceil((@as(f64, @floatFromInt(upper)) + 1) * width);
    return .{ .x = x0, .y = 0, .width = smax(f64, 0, x1 - x0), .height = @ceil(height) };
}
pub fn backgroundFragments(rect: Rect, selection: ?Rect, out: *[2]Rect) usize {
    const selected = selection orelse { out[0] = rect; return 1; };
    if (!(rect.maxX() > selected.minX() and rect.minX() < selected.maxX())) { out[0] = rect; return 1; }
    var count: usize = 0;
    if (rect.minX() < selected.minX()) {
        out[count] = .{ .x = rect.minX(), .y = rect.minY(), .width = selected.minX() - rect.minX(), .height = rect.height };
        count += 1;
    }
    if (rect.maxX() > selected.maxX()) {
        out[count] = .{ .x = selected.maxX(), .y = rect.minY(), .width = rect.maxX() - selected.maxX(), .height = rect.height };
        count += 1;
    }
    return count;
}
pub fn cursorHeight(cell_height: f64, natural: f64, scale: f64) f64 {
    if (!std.math.isFinite(cell_height) or !std.math.isFinite(scale) or scale <= 0) return 0;
    return smin(f64, @ceil(cell_height * scale), @ceil(natural * scale));
}
pub fn cursorNaturalY(cell_y: f64, cell_height: f64, natural_height: f64) f64 { return cell_y + smax(f64, 0, cell_height - natural_height); }
pub fn cursorUnderline(thickness: f64, scale: f64) f64 { return smax(f64, 1, thickness * scale * 2); }
pub fn cursorBar(scale: f64) f64 { return smax(f64, 1, scale * 2); }
pub fn lineModeRect(rect: Rect, display_index: i64, mode: u32, x_origin: f64, y_origin: f64, cell_height: f64) Rect {
    const row_y = y_origin + @as(f64, @floatFromInt(display_index)) * cell_height;
    const scale_x: f64 = if (mode == 0) 1 else 2;
    if (mode != 2 and mode != 3) return .{ .x = x_origin + rect.minX() * scale_x, .y = row_y + rect.minY(), .width = rect.width * scale_x, .height = rect.height };
    var y = row_y + rect.minY() * 2;
    if (mode == 3) y -= cell_height;
    const minimum = smax(f64, row_y, y);
    const maximum = smin(f64, row_y + cell_height, y + rect.height * 2);
    return .{ .x = x_origin + rect.minX() * scale_x, .y = minimum, .width = rect.width * scale_x, .height = smax(f64, 0, maximum - minimum) };
}
pub fn revisionValid(revision: Revision, version: u64) bool { return revision.content != 0 and revision.context != 0 and revision.content == version; }
pub fn revisionEqual(a: Revision, b: Revision) bool { return a.content == b.content and a.context == b.context; }

test "row geometry clips fringe and rejects integer wraparound" {
    const rows = VisibleRows.init(3, 12, 5, 100, 1);
    try std.testing.expectEqual(@as(usize, 5), rows.count());
    try std.testing.expectEqual(VisibleRow{ .display_index = -1, .source_row = 4, .cache_row = 104 }, rows.at(0).?);
    try std.testing.expectEqual(@as(usize, 1), VisibleRows.init(3, 12, 0, std.math.maxInt(i64), 1).count());
    try std.testing.expectEqual(@as(?i64, null), displayRow(std.math.maxInt(i64), -1, 5));
    try std.testing.expectEqual(@as(?i64, null), cacheRow(1, std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(i64, std.math.maxInt(i64)), fringeRows(1e300, 1e-300, true));
}
test "cursor pursuit preserves frozen Float rate and settling" {
    const step = cursorStep(.{}, .{ .x = 100, .y = 0 }, true, true, false, 1.0 / 60.0, 1.6, 0, .{ .x = 10, .y = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 65.58462), step.position.x, 0.0001);
    try std.testing.expect(step.is_animating);
    try std.testing.expect(!cursorStep(.{}, .{ .x = 0.3, .y = 0.4 }, true, true, false, 1.0 / 60.0, 1, 0, .{ .x = 10, .y = 20 }).is_animating);
    try std.testing.expectApproxEqAbs(@as(f32, 0), cursorOpacity(true, true, 10.6, 10, 22), 0.0001);
}

test "wheel ease retains motion and settles monotonically within one 60 Hz interval" {
    for ([_]f64{ 16, 40, 80, 160 }) |height| {
        for ([_]f64{ -1, 1 }) |direction| {
            const start = accumulatedGlide(0, direction * height * 3, height);
            const first = decayedGlide(start, 0.001);
            try std.testing.expect(@abs(first) >= 0.5 and @abs(first) < @abs(start));
            try std.testing.expect(first * direction > 0);
            var position = start;
            for (0..17) |_| {
                const next = decayedGlide(position, 0.001);
                try std.testing.expect(@abs(next) <= @abs(position));
                try std.testing.expect(next == 0 or next * direction > 0);
                position = next;
            }
            try std.testing.expectEqual(@as(f64, 0), position);
            try std.testing.expectEqual(@as(f64, 0), decayedGlide(start, 1.0 / 60.0));
            try std.testing.expectEqual(@as(f64, 0), decayedGlide(start, 2));
        }
    }
    try std.testing.expectEqual(@as(f64, 0), decayedGlide(std.math.inf(f64), 0.001));
    try std.testing.expectEqual(@as(f64, 0), decayedGlide(12, std.math.nan(f64)));
}
