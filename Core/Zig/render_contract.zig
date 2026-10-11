//! Checked public-contract geometry; the Swift values only marshal inputs.
const std = @import("std");
export fn cmdy_render_segment_span(width: isize, count: isize) isize {
    if (width <= 0 or count <= 0) return 0;
    return std.math.mul(isize, width, count) catch 0;
}
export fn cmdy_render_boundaries_valid(p: ?[*]const isize, count: usize) u8 {
    const ptr = p orelse return 0;
    if (count == 0 or ptr[0] != 0) return 0;
    var i: usize = 1;
    while (i < count) : (i += 1) if (ptr[i] < ptr[i - 1]) return 0;
    return 1;
}
export fn cmdy_render_segment_boundaries_valid(p: ?[*]const isize, count: usize, characters: isize, text_length: isize) u8 {
    const n: usize = @intCast(@max(0, characters));
    if (count != n + 1 or cmdy_render_boundaries_valid(p, count) == 0) return 0;
    return @intFromBool(p.?[count - 1] == text_length);
}
export fn cmdy_render_cell_index(p: ?[*]const isize, count: usize, offset: isize) isize {
    const ptr = p orelse return 0;
    if (count <= 1) return 0;
    const clamped = @min(@max(0, offset), ptr[count - 1]);
    var low: usize = 0;
    var high = count;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (ptr[mid] <= clamped) low = mid + 1 else high = mid;
    }
    return @intCast(@min(count - 2, low -| 1));
}
const Range = extern struct { lower: isize, upper: isize };
export fn cmdy_render_cell_range(p: ?[*]const isize, count: usize, offset: isize, length: isize) Range {
    const cells: isize = @intCast(count -| 1);
    const index = cmdy_render_cell_index(p, count, offset);
    if (cells == 0 or length <= 0) {
        const i = @min(cells, @max(0, index));
        return .{ .lower = i, .upper = i };
    }
    const end = std.math.add(isize, offset, length) catch std.math.maxInt(isize);
    const overflow = @addWithOverflow(offset, length)[1] != 0;
    const last = if (overflow) std.math.maxInt(isize) else @max(offset, end - 1);
    const upper = @min(cells, cmdy_render_cell_index(p, count, last) + 1);
    return .{ .lower = index, .upper = @max(index, upper) };
}
const Policy = extern struct { snaps: u8, padding: u8, nearest: u8, exponent: f32, power: f32 };
export fn cmdy_render_text_policy(mode: u8) Policy {
    const exponent: @TypeOf(@as(f32, 1)) = if (mode == 4 or mode == 5) 1.55 else 1.35;
    return .{ .snaps = 1, .padding = @intFromBool(mode == 2 or mode == 5), .nearest = @intFromBool(mode == 3), .exponent = exponent, .power = 1 / exponent };
}
