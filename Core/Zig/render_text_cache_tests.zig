const std = @import("std");
const text = @import("render_text.zig");
const font = @import("render_font.zig");
const cache_module = @import("render_cache.zig");
const glyph_cache_module = @import("render_cache_glyph.zig");
const c = text.c;
extern fn objc_autoreleasePoolPush() ?*anyopaque;
extern fn objc_autoreleasePoolPop(?*anyopaque) void;

fn string(value: [:0]const u8) !c.CFStringRef {
    return c.CFStringCreateWithCString(null, value, c.kCFStringEncodingUTF8) orelse error.OutOfMemory;
}
fn styled(value: [:0]const u8, selected_font: font.Object, style: usize) !c.CFMutableAttributedStringRef {
    const source = try string(value);
    defer c.CFRelease(source);
    const result = c.CFAttributedStringCreateMutable(null, 0) orelse return error.OutOfMemory;
    errdefer c.CFRelease(result);
    c.CFAttributedStringReplaceString(result, .{ .location = 0, .length = 0 }, source);
    const range = c.CFRange{ .location = 0, .length = c.CFStringGetLength(source) };
    c.CFAttributedStringSetAttribute(result, range, @ptrCast(c.cmdy_platform_text_attribute_key(0)), selected_font);
    c.CFAttributedStringSetAttribute(result, range, @ptrCast(c.cmdy_platform_text_attribute_key(1)), c.cmdy_platform_text_white());
    if (style == 1) c.CFAttributedStringSetAttribute(result, range, @ptrCast(c.cmdy_platform_text_attribute_key(2)), c.cmdy_platform_text_white());
    var raw: i32 = if (style == 4) -3 else 5;
    const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &raw) orelse return error.OutOfMemory;
    defer c.CFRelease(number);
    if (style == 2) {
        c.CFAttributedStringSetAttribute(result, range, @ptrCast(c.cmdy_platform_text_attribute_key(9)), number);
        c.CFAttributedStringSetAttribute(result, range, @ptrCast(c.cmdy_platform_text_attribute_key(11)), number);
    }
    if (style == 3 or style == 4) {
        const unknown = try string("NSBaselineOffset");
        defer c.CFRelease(unknown);
        c.CFAttributedStringSetAttribute(result, range, unknown, number);
    }
    return result;
}
fn dispose(row: *text.Row) void {
    row.deinit();
    font.a.destroy(row);
}
fn equalRows(left: *const text.Row, right: *const text.Row) !void {
    const t = std.testing;
    try t.expectEqual(left.width, right.width);
    try t.expectEqual(left.height, right.height);
    try t.expectEqualSlices(u8, left.coverage, right.coverage);
    inline for (.{ .{ left.backgrounds.items, right.backgrounds.items }, .{ left.decorations.items, right.decorations.items } }) |pair| {
        try t.expectEqual(pair[0].len, pair[1].len);
        for (pair[0], pair[1]) |l, r| try t.expect(std.meta.eql(l, r));
    }
    try t.expectEqual(left.tints.items.len, right.tints.items.len);
    for (left.tints.items, right.tints.items) |l, r| try t.expect(std.meta.eql(l, r));
    try t.expectEqual(left.glyphs.items.len, right.glyphs.items.len);
    for (left.glyphs.items, right.glyphs.items) |l, r| {
        try t.expectEqual(l.glyph, r.glyph);
        try t.expect(std.meta.eql(l.rect, r.rect) and std.meta.eql(l.color, r.color));
        try t.expect(c.CFEqual(l.font, r.font) != 0);
    }
    try t.expectEqual(left.tiles.items.len, right.tiles.items.len);
    for (left.tiles.items, right.tiles.items) |l, r| {
        try t.expect(std.meta.eql(l.rect, r.rect));
        try t.expectEqual(l.width, r.width);
        try t.expectEqual(l.height, r.height);
        try t.expectEqual(l.byte_count, r.byte_count);
        try t.expectEqualSlices(u8, l.bytes[0..l.byte_count], r.bytes[0..r.byte_count]);
    }
}

test "cross-row shaping cache preserves full rasters through font paint geometry and unknown attributes" {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    var lines: text.ASCIILines = .{};
    defer lines.deinit();
    var legacy: text.ASCIILines = .{ .glyph_stamping = false };
    defer legacy.deinit();
    var alphabet: [95:0]u8 = @splat(0);
    for (0..95) |index| alphabet[index] = @intCast(index + 0x20);
    var comparisons: usize = 0;
    for ([_][:0]const u8{ "Menlo-Regular", "Menlo-Italic", "Menlo-Bold", "TimesNewRomanPSMT" }) |name| {
        const font_name = try string(name);
        defer c.CFRelease(font_name);
        const selected_font = c.CTFontCreateWithName(font_name, 14, null) orelse return error.OutOfMemory;
        defer c.CFRelease(selected_font);
        for ([_]f64{ 1, 1.5, 2 }) |scale| {
            for ([_]f64{ 7.25, 9.5, 12 }) |width| {
                for ([_]usize{ 0, 1, 2, 0, 3, 4, 0 }) |style| {
                    for ([_][:0]const u8{ "abgX 123 abgX 123", "fiffl ffi -> ==", "f中g🙂", "e\u{301}g", &alphabet }) |value| {
                        const attrs = try styled(value, selected_font, style);
                        defer c.CFRelease(attrs);
                        const count: isize = if (std.mem.eql(u8, value, "f中g🙂")) 4 else if (std.mem.eql(u8, value, "e\u{301}g")) 2 else @intCast(value.len);
                        var segment = std.mem.zeroes(c.CmdyRenderTextSegment);
                        segment.attributed_string = attrs;
                        segment.column_width = 1;
                        segment.character_count = count;
                        var input = std.mem.zeroes(c.CmdyRenderRowInput);
                        input.segments = &segment;
                        input.segment_count = 1;
                        input.cols = @max(24, count);
                        input.width = @intFromFloat(@ceil(@as(f64, @floatFromInt(input.cols)) * width * scale));
                        input.height = @intFromFloat(24 * scale);
                        input.cell_width = width * scale;
                        input.cell_height = 24 * scale;
                        input.scale = scale;
                        input.underline_position = -2;
                        input.underline_thickness = 1;
                        input.normal_font = selected_font;
                        input.foreground = c.cmdy_platform_text_white();
                        input.coverage_exponent = 1.35;
                        input.snaps_y = @intFromBool(style % 2 == 0);
                        input.ascii_caching = 1;
                        input.font_caching = 1;
                        const retained = text.createWithCache(&input, &lines) orelse return error.OutOfMemory;
                        defer dispose(retained);
                        const fresh = text.create(&input) orelse return error.OutOfMemory;
                        defer dispose(fresh);
                        try equalRows(fresh, retained);
                        const reference = text.createWithCache(&input, &legacy) orelse return error.OutOfMemory;
                        defer dispose(reference);
                        try std.testing.expect(!legacy.glyph_stamping);
                        try equalRows(reference, retained);
                        try std.testing.expect(lines.stamp_bytes <= text.max_ascii_stamp_bytes);
                        try std.testing.expectEqual(@as(usize, 0), legacy.stamp_bytes);
                        comparisons += 1;
                    }
                }
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1260), comparisons);
    lines.deinit();
    try std.testing.expect(lines.attributes == null);
    for (lines.lines) |line| try std.testing.expect(line == null);
}

test "renderer clear releases the bounded shaping cache and repeated rows reuse immutable lines" {
    const pool = objc_autoreleasePoolPush();
    defer objc_autoreleasePoolPop(pool);
    const name = try string("Menlo-Regular");
    defer c.CFRelease(name);
    const selected_font = c.CTFontCreateWithName(name, 14, null) orelse return error.OutOfMemory;
    defer c.CFRelease(selected_font);
    const attrs = try styled("same same same", selected_font, 0);
    defer c.CFRelease(attrs);
    var segment = std.mem.zeroes(c.CmdyRenderTextSegment);
    segment.attributed_string = attrs;
    segment.column_width = 1;
    segment.character_count = 14;
    var input = std.mem.zeroes(c.CmdyRenderRowInput);
    input.segments = &segment;
    input.segment_count = 1;
    input.cols = 20; input.width = 200; input.height = 24;
    input.cell_width = 10; input.cell_height = 24; input.scale = 1;
    input.normal_font = selected_font; input.foreground = c.cmdy_platform_text_white();
    input.coverage_exponent = 1.35; input.ascii_caching = 1; input.font_caching = 1; input.snaps_y = 1;
    // This tests clear's CPU ownership only. No GPU row or glyph-cache operation
    // is performed, so an unused glyph-cache address needs no Metal device.
    var unused_glyphs: glyph_cache_module.Cache = undefined;
    var cache = cache_module.Cache.init(null, &unused_glyphs);
    defer cache.deinit();
    const first = text.createWithCache(&input, &cache.ascii_lines) orelse return error.OutOfMemory;
    dispose(first);
    const old_line = cache.ascii_lines.lines['s' - 0x20];
    try std.testing.expect(old_line != null);
    try std.testing.expect(cache.ascii_lines.cross_row_reusable);
    try std.testing.expect(cache.ascii_lines.stamp_bytes > 0);
    for (0..100) |_| {
        const row = text.createWithCache(&input, &cache.ascii_lines) orelse return error.OutOfMemory;
        dispose(row);
        try std.testing.expect(cache.ascii_lines.lines['s' - 0x20] == old_line);
    }
    try std.testing.expectEqual(@as(usize, 95), cache.ascii_lines.lines.len);
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.ascii_lines.stamp_bytes);
    try std.testing.expect(cache.ascii_lines.attributes == null);
    for (cache.ascii_lines.lines) |line| try std.testing.expect(line == null);
    const after_clear = text.createWithCache(&input, &cache.ascii_lines) orelse return error.OutOfMemory;
    defer dispose(after_clear);
    const fresh = text.create(&input) orelse return error.OutOfMemory;
    defer dispose(fresh);
    try equalRows(fresh, after_clear);

    var alphabet: [95:0]u8 = @splat(0);
    for (0..95) |index| alphabet[index] = @intCast(index + 0x20);
    const all_attrs = try styled(&alphabet, selected_font, 0);
    defer c.CFRelease(all_attrs);
    segment.attributed_string = all_attrs;
    segment.character_count = 95;
    input.cols = 96;
    input.width = 960;
    const full = text.createWithCache(&input, &cache.ascii_lines) orelse return error.OutOfMemory;
    defer dispose(full);
    var retained_lines: usize = 0;
    for (cache.ascii_lines.lines) |line| if (line != null) { retained_lines += 1; };
    try std.testing.expectEqual(@as(usize, 95), retained_lines);
    const full_fresh = text.create(&input) orelse return error.OutOfMemory;
    defer dispose(full_fresh);
    try equalRows(full_fresh, full);
    cache.clear();
    try std.testing.expectEqual(@as(usize, 0), cache.ascii_lines.stamp_bytes);
    for (cache.ascii_lines.lines) |line| try std.testing.expect(line == null);

    // This font requires fallback for ordinary ASCII letters. Its lines must
    // remain row-local even when a caller supplies the persistent owner cache.
    const emoji_name = try string("AppleColorEmoji");
    defer c.CFRelease(emoji_name);
    const emoji_font = c.CTFontCreateWithName(emoji_name, 14, null) orelse return error.OutOfMemory;
    defer c.CFRelease(emoji_font);
    const fallback_attrs = try styled("fallback ascii", emoji_font, 0);
    defer c.CFRelease(fallback_attrs);
    segment.attributed_string = fallback_attrs;
    segment.character_count = 14;
    input.normal_font = emoji_font;
    const fallback = text.createWithCache(&input, &cache.ascii_lines) orelse return error.OutOfMemory;
    defer dispose(fallback);
    try std.testing.expect(!cache.ascii_lines.cross_row_reusable and cache.ascii_lines.attributes == null);
    for (cache.ascii_lines.lines) |line| try std.testing.expect(line == null);
    const fallback_fresh = text.create(&input) orelse return error.OutOfMemory;
    defer dispose(fallback_fresh);
    try equalRows(fallback_fresh, fallback);
}
