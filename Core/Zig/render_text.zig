//! Row shaping, coverage, clipping, decoration and payload ownership live here.
const std = @import("std");
const font = @import("render_font.zig");
pub const c = font.c;
const a = font.a;
const Object = font.Object;
const proc = @import("render_procedural.zig");
const grapheme = @import("cell_text.zig");
const emoji = @import("emoji.zig");
const Rect = c.CmdyRenderRect;
const Solid = c.CmdyRenderSolid;
const Color = c.CmdyRenderColor;
// A null C pointer is valid for an empty array. Do not form a Zig slice from
// that pointer even at length zero: safety builds correctly reject it.
fn inputSlice(comptime T: type, pointer: [*c]const T, count: usize) error{InvalidInput}![]const T {
    if (count == 0) return &.{};
    if (pointer == null or @intFromPtr(pointer) % @alignOf(T) != 0 or count > @as(usize, std.math.maxInt(isize)) / @sizeOf(T)) return error.InvalidInput;
    return pointer[0..count];
}
fn fl(v: isize) f64 {
    return @floatFromInt(v);
}
fn key(i: u32) Object {
    return c.cmdy_platform_text_attribute_key(i);
}
fn attr(dict: c.CFDictionaryRef, i: u32) Object {
    return if (dict != null) c.CFDictionaryGetValue(dict, key(i)) else null;
}
fn typed(dict: c.CFDictionaryRef, i: u32, kind: u32) Object {
    const value = attr(dict, i);
    return if (value != null and c.cmdy_platform_text_object_kind(value) == kind) value else null;
}
fn num(dict: c.CFDictionaryRef, i: u32) ?i64 {
    const value = typed(dict, i, 3) orelse return null;
    return c.cmdy_platform_text_number_integer(value);
}
fn selectBackground(dict: c.CFDictionaryRef) Object {
    return typed(dict, 3, 2) orelse typed(dict, 4, 2) orelse typed(dict, 2, 2);
}
fn aligned(r: Rect) Rect {
    const x = @floor(r.x);
    const y = @floor(r.y);
    return .{ .x = x, .y = y, .width = @max(0, @ceil(r.x + r.width) - x), .height = @max(0, @ceil(r.y + r.height) - y) };
}
fn sameColor(x: Color, y: Color) bool {
    return x.r == y.r and x.g == y.g and x.b == y.b and x.a == y.a;
}
pub fn appendSolid(list: *std.ArrayList(Solid), value: Solid) !void {
    if (list.items.len > 0) {
        const last = &list.items[list.items.len - 1];
        if (sameColor(last.color, value.color) and last.rect.width > 0 and last.rect.height > 0 and value.rect.width > 0 and value.rect.height > 0 and last.rect.y == value.rect.y and last.rect.height == value.rect.height and last.rect.x + last.rect.width == value.rect.x) {
            last.rect.width += value.rect.width;
            return;
        }
    }
    try list.append(a, value);
}
pub const Row = struct {
    coverage: []u8 = &.{},
    tiles: std.ArrayList(c.CmdyRenderColorTile) = .empty,
    backgrounds: std.ArrayList(Solid) = .empty,
    tints: std.ArrayList(c.CmdyRenderTint) = .empty,
    glyphs: std.ArrayList(c.CmdyRenderGlyphSeed) = .empty,
    decorations: std.ArrayList(Solid) = .empty,
    width: isize,
    height: isize,
    pub fn deinit(self: *Row) void {
        a.free(self.coverage);
        for (self.tiles.items) |tile| a.free(@constCast(tile.bytes[0..tile.byte_count]));
        self.tiles.deinit(a);
        for (self.glyphs.items) |g| font.release(g.font);
        self.glyphs.deinit(a);
        self.backgrounds.deinit(a);
        self.tints.deinit(a);
        self.decorations.deinit(a);
    }
    pub fn view(self: *const Row) c.CmdyRenderRowView {
        return .{ .coverage = self.coverage.ptr, .coverage_count = self.coverage.len, .color_tiles = self.tiles.items.ptr, .color_tile_count = self.tiles.items.len, .backgrounds = self.backgrounds.items.ptr, .background_count = self.backgrounds.items.len, .tints = self.tints.items.ptr, .tint_count = self.tints.items.len, .glyphs = self.glyphs.items.ptr, .glyph_count = self.glyphs.items.len, .decorations = self.decorations.items.ptr, .decoration_count = self.decorations.items.len, .width = self.width, .height = self.height };
    }
};
fn units(text: c.CFStringRef) ![]u16 {
    const length = c.CFStringGetLength(text);
    if (length < 0) return error.InvalidInput;
    const result = try a.alloc(u16, @intCast(length));
    c.CFStringGetCharacters(text, .{ .location = 0, .length = length }, result.ptr);
    return result;
}
fn scalarAt(text: []const u16, offset: *usize) u32 {
    const first = text[offset.*];
    offset.* += 1;
    if (first >= 0xd800 and first <= 0xdbff and offset.* < text.len) {
        const next = text[offset.*];
        if (next >= 0xdc00 and next <= 0xdfff) {
            offset.* += 1;
            return 0x10000 + (@as(u32, first) - 0xd800) * 1024 + (@as(u32, next) - 0xdc00);
        }
    }
    return if (first >= 0xd800 and first <= 0xdfff) 0xfffd else first;
}
pub fn boundaries(text: []const u16) ![]isize {
    var result: std.ArrayList(isize) = .empty;
    errdefer result.deinit(a);
    try result.append(a, 0);
    if (text.len > 0) {
        var offset: usize = 0;
        var state = grapheme.State.init(scalarAt(text, &offset));
        while (offset < text.len) {
            const start = offset;
            const scalar = scalarAt(text, &offset);
            if (!state.continues(scalar)) {
                try result.append(a, @intCast(start));
                state = grapheme.State.init(scalar);
            }
        }
        try result.append(a, @intCast(text.len));
    }
    return result.toOwnedSlice(a);
}
fn adjustedBoundaries(segment: c.CmdyRenderTextSegment, natural: []const isize, len: isize) ![]isize {
    if (segment.has_boundaries != 0) {
        return a.dupe(isize, try inputSlice(isize, segment.boundaries, segment.boundary_count));
    }
    const count: usize = @intCast(segment.character_count + 1);
    const result = try a.alloc(isize, count);
    @memset(result, len);
    @memcpy(result[0..@min(count, natural.len)], natural[0..@min(count, natural.len)]);
    if (natural.len > count) result[count - 1] = len;
    return result;
}
fn glyphRange(index: usize, explicit: []const isize, natural: []const isize) ?c.CFRange {
    const lower = explicit[index];
    const upper = explicit[index + 1];
    if (upper <= lower) return null;
    if (natural.len > 1) for (natural[0 .. natural.len - 1], natural[1..]) |nl, nu| {
        if (lower < nl or lower >= nu) continue;
        if (lower > nl) return null;
        return .{ .location = lower, .length = @max(upper, nu) - lower };
    };
    return .{ .location = lower, .length = upper - lower };
}
fn isColor(text: []const u16, source: Object) bool {
    if (c.cmdy_platform_text_font_emoji_family(source) != 0) return true;
    var i: usize = 0;
    while (i < text.len) {
        const scalar = scalarAt(text, &i);
        if (scalar == 0x231a or scalar == 0x231b or (scalar > 0x238c and emoji.isEmoji(scalar))) return true;
    }
    return false;
}
fn makeLine(source: c.CFAttributedStringRef, range: c.CFRange, shaped: Object, coverage: bool) c.CTLineRef {
    const substring = c.CFAttributedStringCreateWithSubstring(null, source, range) orelse return null;
    defer font.release(substring);
    const mutable = c.CFAttributedStringCreateMutableCopy(null, 0, substring) orelse return null;
    defer font.release(mutable);
    const full = c.CFRange{ .location = 0, .length = c.CFAttributedStringGetLength(mutable) };
    c.CFAttributedStringSetAttribute(mutable, full, @ptrCast(key(0)), shaped);
    if (coverage) c.CFAttributedStringSetAttribute(mutable, full, @ptrCast(key(1)), c.cmdy_platform_text_white());
    var zero: i32 = 0;
    const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &zero) orelse return null;
    defer font.release(number);
    c.CFAttributedStringSetAttribute(mutable, full, @ptrCast(key(8)), number);
    c.CFAttributedStringSetAttribute(mutable, full, @ptrCast(key(12)), number);
    c.CFAttributedStringRemoveAttribute(mutable, full, @ptrCast(key(2)));
    c.CFAttributedStringRemoveAttribute(mutable, full, @ptrCast(key(9)));
    c.CFAttributedStringRemoveAttribute(mutable, full, @ptrCast(key(11)));
    font.prepareFallback(shaped, c.CFAttributedStringGetString(mutable));
    return c.CTLineCreateWithAttributedString(mutable);
}
// One bounded cache belongs to a raster caller. Render owners retain it across
// rows; standalone callers keep it local. Compare exactly the modeled
// attributes left by makeLine's coverage normalization; unknown attributes
// retain the original segment-local behavior.
const GlyphStamp = struct {
    bytes: []u8,
    seed: c.CmdyRenderGlyphSeed, // Font is borrowed from the retained cached line.
    cell_width: usize,
    height: usize,
    baseline: f64,
};
pub const max_ascii_stamp_bytes: usize = 32 * 1024;
pub const ASCIILines = struct {
    attributes: ?c.CmdyRenderAttributeKey = null,
    lines: [95]c.CTLineRef = .{null} ** 95,
    empty: [95]bool = .{false} ** 95,
    cross_row_reusable: bool = false,
    glyph_stamping: bool = true,
    stamps: [95]?GlyphStamp = .{null} ** 95,
    stamp_bytes: usize = 0,

    pub fn deinit(self: *ASCIILines) void {
        for (self.stamps) |stamp| if (stamp) |v| a.free(v.bytes);
        for (self.lines) |line| font.release(line);
        if (self.attributes) |attrs| for (attrs.objects) |obj| font.release(obj);
        self.* = .{ .glyph_stamping = self.glyph_stamping };
    }

    fn finishRow(self: *ASCIILines) void {
        // A font-registration retry may change a fallback-dependent line
        // without changing its primary font. Preserve row-local behavior for
        // those fonts and for unmodeled attributes.
        if (!self.cross_row_reusable) self.deinit();
    }

    fn begin(self: *ASCIILines, attrs: c.CFDictionaryRef, shaped: Object) void {
        var next: c.CmdyRenderAttributeKey = undefined;
        const modeled = cmdy_render_attribute_key(attrs, &next) != 0;
        if (modeled) {
            next.objects[0] = shaped;
            next.objects[1] = c.cmdy_platform_text_white();
            next.objects[2] = null;
            next.integers[0] = 0; // ligature is explicitly disabled
            next.integers[1] = 0; // underline is painted separately
            next.integers[3] = 0; // strikethrough is painted separately
            next.kern_bits = 0;
            next.present = (next.present | (1 << 0) | (1 << 1) | (1 << 8) | (1 << 12)) &
                ~@as(u32, (1 << 2) | (1 << 9) | (1 << 11));
            if (self.attributes) |previous| {
                var equal = previous.present == next.present and previous.kern_bits == next.kern_bits and
                    std.mem.eql(i64, &previous.integers, &next.integers);
                if (equal) for (previous.objects, next.objects) |left, right| {
                    if (!objectsEqual(left, right)) {
                        equal = false;
                        break;
                    }
                };
                if (equal) return;
            }
        }
        self.deinit();
        if (modeled) {
            for (&next.objects) |*obj| obj.* = font.retain(obj.*);
            self.attributes = next;
            var characters: [95]u16 = undefined;
            var glyphs: [95]u16 = undefined;
            for (&characters, 0..) |*character, index| character.* = @intCast(index + 0x20);
            self.cross_row_reusable = shaped != null and
                c.CTFontGetGlyphsForCharacters(font.ct(shaped), &characters, &glyphs, characters.len);
        }
    }
};
const Geometry = struct { font: Object, glyph: u16, rect: Rect };
const Clip = struct {
    envelope: ?Rect = null,
    glyphs: std.ArrayList(Geometry) = .empty,
    fn deinit(self: *Clip) void {
        self.glyphs.deinit(a);
    }
};
fn clipLine(line: c.CTLineRef, x: f64, y: f64, ctx: c.CGContextRef) !Clip {
    var result: Clip = .{};
    errdefer result.deinit();
    const runs = c.CTLineGetGlyphRuns(line);
    const count = c.CFArrayGetCount(runs);
    var ri: isize = 0;
    while (ri < count) : (ri += 1) {
        const run: c.CTRunRef = @ptrCast(c.CFArrayGetValueAtIndex(runs, ri));
        const glyph_count = c.CTRunGetGlyphCount(run);
        if (glyph_count <= 0) continue;
        const attrs = c.CTRunGetAttributes(run);
        const run_font = c.CFDictionaryGetValue(attrs, c.kCTFontAttributeName) orelse continue;
        const glyphs = try a.alloc(u16, @intCast(glyph_count));
        defer a.free(glyphs);
        const positions = try a.alloc(c.CGPoint, @intCast(glyph_count));
        defer a.free(positions);
        c.CTRunGetGlyphs(run, .{ .location = 0, .length = 0 }, glyphs.ptr);
        c.CTRunGetPositions(run, .{ .location = 0, .length = 0 }, positions.ptr);
        for (glyphs, positions) |glyph, position| {
            const bounds = font.glyphBounds(run_font, glyph);
            if (!font.visibleBounds(bounds)) continue;
            const x0 = @floor(bounds.origin.x);
            const y0 = @floor(bounds.origin.y);
            const x1 = @ceil(bounds.origin.x + bounds.size.width);
            const y1 = @ceil(bounds.origin.y + bounds.size.height);
            const r = Rect{ .x = x + position.x + x0, .y = y + position.y + y0, .width = x1 - x0, .height = y1 - y0 };
            try result.glyphs.append(a, .{ .font = run_font, .glyph = glyph, .rect = r });
            result.envelope = if (result.envelope) |env| font.nativeRect(c.CGRectUnion(font.cgRect(env), font.cgRect(r))) else r;
        }
    }
    if (result.envelope == null) {
        c.CGContextClipToRect(ctx, font.rect(0, 0, 0, 0));
        return result;
    }
    c.CGContextBeginPath(ctx);
    for (result.glyphs.items) |g| c.CGContextAddRect(ctx, font.cgRect(g.rect));
    c.CGContextClip(ctx);
    return result;
}
fn yDown(r: Rect, h: f64) Rect {
    return .{ .x = r.x, .y = h - (r.y + r.height), .width = r.width, .height = r.height };
}
fn drawCoverage(row: *Row, line: c.CTLineRef, ctx: c.CGContextRef, r: Rect, input: *const c.CmdyRenderRowInput, foreground: Color) !?Rect {
    const baseline = font.gridBaseline(fl(input.height), input.normal_font, input.scale, input.snaps_y != 0);
    c.CGContextSaveGState(ctx);
    defer c.CGContextRestoreGState(ctx);
    var clip = try clipLine(line, r.x, baseline, ctx);
    defer clip.deinit();
    c.CGContextSetTextPosition(ctx, r.x, baseline);
    c.CTLineDraw(line, ctx);
    for (clip.glyphs.items) |g| {
        const seed = c.CmdyRenderGlyphSeed{ .font = font.retain(g.font), .glyph = g.glyph, .rect = yDown(g.rect, fl(input.height)), .color = foreground };
        row.glyphs.append(a, seed) catch |err| {
            font.release(seed.font);
            return err;
        };
    }
    return if (clip.envelope) |e| yDown(e, fl(input.height)) else null;
}
// Exact column copies are allowed only for an empty, integer-aligned cell.
// The cached source is the existing drawCoverage output, not a new rasterizer.
// Whole-height columns avoid assumptions about bitmap scanline orientation.
fn drawASCIICoverage(row: *Row, line: c.CTLineRef, ctx: c.CGContextRef, r: Rect, input: *const c.CmdyRenderRowInput, foreground: Color, cache: *ASCIILines, code: usize) !?Rect {
    if (!cache.glyph_stamping or !cache.cross_row_reusable or
        !std.math.isFinite(r.x) or !std.math.isFinite(r.width) or
        r.x < 0 or r.width <= 0 or r.x != @floor(r.x) or r.width != @floor(r.width) or
        r.x + r.width > fl(input.width)) return drawCoverage(row, line, ctx, r, input, foreground);
    const width: usize = @intFromFloat(r.width);
    const height: usize = @intCast(input.height);
    const stride: usize = @intCast(input.width);
    const x: usize = @intFromFloat(r.x);
    const bytes = width * height;
    if (bytes > max_ascii_stamp_bytes) return drawCoverage(row, line, ctx, r, input, foreground);
    c.CGContextFlush(ctx);
    const pixels: [*]u8 = @ptrCast(c.CGBitmapContextGetData(ctx) orelse return drawCoverage(row, line, ctx, r, input, foreground));
    for (0..height) |y| for (pixels[y * stride + x ..][0..width]) |value| {
        if (value != 0) return drawCoverage(row, line, ctx, r, input, foreground);
    };
    const baseline = font.gridBaseline(fl(input.height), input.normal_font, input.scale, input.snaps_y != 0);
    if (cache.stamps[code]) |stamp| {
        if (stamp.cell_width == width and stamp.height == height and stamp.baseline == baseline) {
            var seed = stamp.seed;
            seed.font = font.retain(seed.font);
            seed.rect.x += r.x;
            seed.color = foreground;
            row.glyphs.append(a, seed) catch |err| {
                font.release(seed.font);
                return err;
            };
            for (0..height) |y| @memcpy(pixels[y * stride + x ..][0..width], stamp.bytes[y * width ..][0..width]);
            return seed.rect;
        }
        a.free(stamp.bytes);
        cache.stamp_bytes -= stamp.bytes.len;
        cache.stamps[code] = null;
    }
    const seed_start = row.glyphs.items.len;
    const envelope = try drawCoverage(row, line, ctx, r, input, foreground);
    const env = envelope orelse return null;
    if (row.glyphs.items.len != seed_start + 1 or cache.stamp_bytes + bytes > max_ascii_stamp_bytes) return envelope;
    var seed = row.glyphs.items[seed_start];
    if (!std.meta.eql(seed.rect, env) or env.x < r.x or env.x + env.width > r.x + r.width or
        env.y < 0 or env.y + env.height > fl(input.height)) return envelope;
    inline for (.{ "x", "y", "width", "height" }) |field| {
        const value = @field(env, field);
        if (!std.math.isFinite(value) or value != @floor(value)) return envelope;
    }
    const copy = a.alloc(u8, bytes) catch return envelope;
    c.CGContextFlush(ctx);
    for (0..height) |y| @memcpy(copy[y * width ..][0..width], pixels[y * stride + x ..][0..width]);
    seed.rect.x -= r.x;
    cache.stamps[code] = .{ .bytes = copy, .seed = seed, .cell_width = width, .height = height, .baseline = baseline };
    cache.stamp_bytes += bytes;
    return envelope;
}
fn colorTile(source: c.CFAttributedStringRef, range: c.CFRange, shaped: Object, rect: Rect, input: *const c.CmdyRenderRowInput) !?c.CmdyRenderColorTile {
    const w: usize = @intFromFloat(@max(1, @round(rect.width)));
    const h: usize = @intCast(input.height);
    const space = c.CGColorSpaceCreateDeviceRGB() orelse return null;
    defer c.CGColorSpaceRelease(space);
    const context = c.CGBitmapContextCreate(null, w, h, 8, w * 4, space, c.kCGImageAlphaPremultipliedFirst | c.kCGBitmapByteOrder32Little) orelse return null;
    defer c.CGContextRelease(context);
    c.CGContextClearRect(context, font.rect(0, 0, @floatFromInt(w), @floatFromInt(h)));
    c.CGContextSetTextMatrix(context, c.CGAffineTransformIdentity);
    c.CGContextSetAllowsAntialiasing(context, true);
    c.CGContextSetShouldAntialias(context, true);
    const line = makeLine(source, range, shaped, false) orelse return null;
    defer font.release(line);
    const baseline = font.gridBaseline(fl(input.height), input.normal_font, input.scale, input.snaps_y != 0);
    var clip = try clipLine(line, 0, baseline, context);
    defer clip.deinit();
    c.CGContextSetTextPosition(context, 0, baseline);
    c.CTLineDraw(line, context);
    const data: [*]const u8 = @ptrCast(c.CGBitmapContextGetData(context) orelse return null);
    const bytes = try a.dupe(u8, data[0 .. w * h * 4]);
    return .{ .rect = .{ .x = rect.x, .y = 0, .width = @floatFromInt(w), .height = @floatFromInt(h) }, .width = @intCast(w), .height = @intCast(h), .bytes = bytes.ptr, .byte_count = bytes.len };
}
fn underlineStyle(attrs: c.CFDictionaryRef) u8 {
    if (num(attrs, 10)) |raw| {
        const byte: u8 = @truncate(@as(u64, @bitCast(raw)));
        if (byte <= 5) return byte;
    }
    const raw = num(attrs, 9) orelse return 0;
    if (raw == 0) return 0;
    if ((raw & 9) == 9) return 2; // NSUnderlineStyle.double includes the single bit.
    if ((raw & 0x100) != 0) return 4;
    if ((raw & 0x200) != 0 or (raw & 0x300) == 0x300 or (raw & 0x400) != 0) return 5;
    return 1;
}
pub fn underlineRects(style: u8, r: Rect, y: f64, thickness: f64, out: *std.ArrayList(Rect)) !void {
    if (style == 0 or r.width <= 0 or thickness <= 0) return;
    const base = y + thickness / 2;
    if (style == 1 or style == 2) {
        try out.append(a, .{ .x = r.x, .y = base, .width = r.width, .height = thickness });
        if (style == 2) try out.append(a, .{ .x = r.x, .y = base + thickness * 2, .width = r.width, .height = thickness });
        return;
    }
    var x = r.x;
    var phase: usize = 0;
    const offsets = [_]f64{ 0, -thickness, 0, thickness };
    while (x < r.x + r.width) {
        const width = if (style == 5) thickness * 2 else thickness;
        try out.append(a, .{ .x = x, .y = base + (if (style == 3) offsets[phase] else 0), .width = @min(width, @max(0, r.x + r.width - x)), .height = thickness });
        x += thickness * (if (style == 4) @as(f64, 3) else if (style == 5) @as(f64, 4) else @as(f64, 1));
        phase = (phase + 1) % 4;
    }
}
fn strike(r: Rect, y: f64, thickness: f64) Rect {
    return .{ .x = r.x, .y = y + @max(0, thickness - 1) / 2, .width = r.width, .height = 1 };
}
fn decorations(row: *Row, attrs: c.CFDictionaryRef, scaled: Object, foreground: Object, r: Rect, input: *const c.CmdyRenderRowInput) !void {
    const style = underlineStyle(attrs);
    const color = typed(attrs, 6, 2) orelse typed(attrs, 5, 2) orelse foreground;
    const baseline = font.gridBaseline(fl(input.height), scaled, input.scale, false);
    const thickness = @max(1, @round(input.underline_thickness * input.scale));
    const quartz_y = baseline + input.underline_position * input.scale;
    const y = @max(0, @min(fl(input.height) - thickness, fl(input.height) - quartz_y - thickness));
    if (style != 0) {
        var rects: std.ArrayList(Rect) = .empty;
        defer rects.deinit(a);
        try underlineRects(style, r, y, thickness, &rects);
        for (rects.items) |item| try row.decorations.append(a, .{ .rect = item, .color = font.color(color) });
    }
    if (num(attrs, 11)) |raw| {
        if (raw != 0) {
            const sy = fl(input.height) - (baseline + c.CTFontGetAscent(font.ct(scaled)) * 0.36);
            const sc = typed(attrs, 7, 2) orelse foreground;
            try row.decorations.append(a, .{ .rect = strike(r, sy, thickness), .color = font.color(sc) });
        }
    }
}
fn rasterSegment(row: *Row, segment: c.CmdyRenderTextSegment, context: c.CGContextRef, input: *const c.CmdyRenderRowInput, fonts: *font.Fonts, ascii_lines: *ASCIILines) !void {
    if (segment.character_count <= 0 or segment.column_width <= 0 or segment.attributed_string == null) return;
    const attributed: c.CFAttributedStringRef = @ptrCast(segment.attributed_string);
    const length = c.CFAttributedStringGetLength(attributed);
    if (length <= 0) return;
    const text = try units(c.CFAttributedStringGetString(attributed));
    defer a.free(text);
    const natural = try boundaries(text);
    defer a.free(natural);
    const explicit = try adjustedBoundaries(segment, natural, length);
    defer a.free(explicit);
    if (explicit.len != segment.character_count + 1) return;
    var ascii = input.ascii_caching != 0 and segment.column_width == 1 and length == segment.character_count;
    if (ascii) for (text, 0..) |unit, i| {
        if (unit < 0x20 or unit > 0x7e or explicit[i] != i) {
            ascii = false;
            break;
        }
    };
    if (ascii and explicit[explicit.len - 1] != length) ascii = false;
    var effective = c.CFRange{ .location = 0, .length = 0 };
    const first_attrs = c.CFAttributedStringGetAttributes(attributed, 0, &effective);
    if (ascii and (effective.location != 0 or effective.length != length)) ascii = false;
    const segment_x = fl(segment.column) * input.cell_width;
    const segment_w = fl(segment.character_count) * input.cell_width;
    if (ascii and (segment_x < 0 or segment_x + segment_w > fl(input.width))) ascii = false;
    var ascii_configured = false;
    var cell: usize = 0;
    while (cell < @as(usize, @intCast(segment.character_count))) : (cell += 1) {
        const lower = explicit[cell];
        const upper = explicit[cell + 1];
        if (lower < 0 or upper < lower or upper > length) continue;
        const x = if (ascii) segment_x + @as(f64, @floatFromInt(cell)) * input.cell_width else fl(segment.column + @as(isize, @intCast(cell)) * segment.column_width) * input.cell_width;
        const r = Rect{ .x = x, .y = 0, .width = fl(segment.column_width) * input.cell_width, .height = input.cell_height };
        if (x >= fl(input.width) or x + r.width <= 0) continue;
        const attrs = if (ascii) first_attrs else c.CFAttributedStringGetAttributes(attributed, @min(lower, length - 1), null);
        if (selectBackground(attrs)) |background| try appendSolid(&row.backgrounds, .{ .rect = aligned(r), .color = font.color(background) });
        if (upper <= lower) continue;
        const scaled = fonts.scaledFont(typed(attrs, 0, 1));
        defer font.release(scaled);
        const foreground = typed(attrs, 1, 2) orelse input.foreground;
        const rgba = font.color(foreground);
        const range = if (ascii) c.CFRange{ .location = @intCast(cell), .length = 1 } else glyphRange(cell, explicit, natural);
        if (range) |gr| {
            const shaped = fonts.prepared(scaled);
            defer font.release(shaped);
            const lo: usize = @intCast(gr.location);
            const hi: usize = @intCast(gr.location + gr.length);
            if (!ascii and isColor(text[lo..hi], scaled)) {
                if (try colorTile(attributed, gr, shaped, r, input)) |tile| row.tiles.append(a, tile) catch |err| {
                    a.free(@constCast(tile.bytes[0..tile.byte_count]));
                    return err;
                };
            } else {
                var envelope: ?Rect = null;
                if (ascii) {
                    if (!ascii_configured) {
                        ascii_lines.begin(first_attrs, shaped);
                        ascii_configured = true;
                    }
                    const code: usize = text[cell] - 0x20;
                    if (!ascii_lines.empty[code]) {
                        if (ascii_lines.lines[code] == null) ascii_lines.lines[code] = makeLine(attributed, gr, shaped, true);
                        if (ascii_lines.lines[code]) |line| {
                            envelope = try drawASCIICoverage(row, line, context, r, input, rgba, ascii_lines, code);
                            if (envelope == null) ascii_lines.empty[code] = true;
                        }
                    }
                } else {
                    const line = makeLine(attributed, gr, shaped, true);
                    defer font.release(line);
                    if (line != null) envelope = try drawCoverage(row, line, context, r, input, rgba);
                }
                try row.tints.append(a, .{ .rect = r, .envelope = envelope orelse std.mem.zeroes(Rect), .color = rgba, .has_envelope = @intFromBool(envelope != null), .replaced_by_atlas = 1 });
            }
        }
        try decorations(row, attrs, scaled, foreground, r, input);
    }
}
pub fn create(input: *const c.CmdyRenderRowInput) ?*Row {
    var ascii_lines: ASCIILines = .{};
    defer ascii_lines.deinit();
    return createWithCache(input, &ascii_lines);
}
/// The caller exclusively owns the bounded shaping cache. It retains no row
/// geometry or paint output; every raster still resolves those from its input.
pub fn createWithCache(input: *const c.CmdyRenderRowInput, ascii_lines: *ASCIILines) ?*Row {
    if (input.cols <= 0 or input.width <= 0 or input.height <= 0 or input.width > 32768 or input.height > 2048 or input.normal_font == null or input.foreground == null) return null;
    defer ascii_lines.finishRow();
    return createFallible(input, ascii_lines) catch null;
}
fn createFallible(input: *const c.CmdyRenderRowInput, ascii_lines: *ASCIILines) !?*Row {
    const w: usize = @intCast(input.width);
    const h: usize = @intCast(input.height);
    const space = c.CGColorSpaceCreateDeviceGray() orelse return null;
    defer c.CGColorSpaceRelease(space);
    const context = c.CGBitmapContextCreate(null, w, h, 8, w, space, c.kCGImageAlphaNone) orelse return null;
    defer c.CGContextRelease(context);
    c.CGContextSetGrayFillColor(context, 0, 1);
    c.CGContextFillRect(context, font.rect(0, 0, fl(input.width), fl(input.height)));
    c.CGContextSetAllowsAntialiasing(context, true);
    c.CGContextSetShouldAntialias(context, true);
    c.CGContextSetTextMatrix(context, c.CGAffineTransformIdentity);
    const result = try a.create(Row);
    result.* = .{ .width = input.width, .height = input.height };
    errdefer {
        result.deinit();
        a.destroy(result);
    }
    var fonts = font.Fonts.init(input.scale, input.normal_font, input.font_caching != 0);
    defer fonts.deinit();
    for (try inputSlice(c.CmdyRenderTextSegment, input.segments, input.segment_count)) |segment| try rasterSegment(result, segment, context, input, &fonts, ascii_lines);
    const thickness = boxThickness(input.underline_thickness, input.scale);
    for (try inputSlice(c.CmdyRenderBox, input.boxes, input.box_count)) |box| {
        const x = fl(box.column) * input.cell_width;
        const bw = fl(@max(1, box.column_width)) * input.cell_width;
        c.CGContextSaveGState(context);
        c.CGContextClipToRect(context, font.rect(x, 0, bw, input.cell_height));
        c.CGContextTranslateCTM(context, 0, input.cell_height);
        c.CGContextScaleCTM(context, 1, -1);
        proc.draw(box.code_point, context, x, 0, bw / input.scale, input.cell_height / input.scale, input.scale, c.cmdy_platform_text_white(), thickness);
        c.CGContextRestoreGState(context);
        try result.tints.append(a, .{ .rect = .{ .x = x, .y = 0, .width = bw, .height = input.cell_height }, .envelope = std.mem.zeroes(Rect), .has_envelope = 0, .replaced_by_atlas = 0, .color = font.color(box.foreground) });
    }
    for (try inputSlice(c.CmdyRenderBlock, input.blocks, input.block_count)) |block| {
        const x = fl(block.column) * input.cell_width;
        const bw = fl(@max(1, block.column_width)) * input.cell_width;
        for (try inputSlice(c.CmdyRenderBlockRect, block.rects, block.rect_count)) |element| {
            const r = Rect{ .x = x + @as(f64, @floatFromInt(element.x0)) / 8 * bw, .y = @as(f64, @floatFromInt(element.y0)) / 8 * input.cell_height, .width = @as(f64, @floatFromInt(element.x1 - element.x0)) / 8 * bw, .height = @as(f64, @floatFromInt(element.y1 - element.y0)) / 8 * input.cell_height };
            var color = font.color(block.foreground);
            color.a *= blockCoverage(element.alpha, input.coverage_exponent);
            try result.decorations.append(a, .{ .rect = aligned(r), .color = color });
        }
    }
    const data: [*]const u8 = @ptrCast(c.CGBitmapContextGetData(context) orelse return error.NoContextData);
    result.coverage = try a.dupe(u8, data[0 .. w * h]);
    return result;
}
pub fn blockCoverage(alpha: f64, exponent: f32) f32 {
    const quantized: f32 = @floatCast(@round(alpha * 255) / 255);
    return std.math.pow(f32, quantized, exponent);
}
pub fn boxThickness(thickness: f64, scale: f64) isize {
    return @max(1, @as(isize, @intFromFloat(@round(thickness * scale)))) * 2 - 1;
}
export fn cmdy_render_row_create(input: ?*const c.CmdyRenderRowInput) ?*Row {
    return create(input orelse return null);
}
export fn cmdy_render_row_free(self: ?*Row) void {
    if (self) |v| {
        v.deinit();
        a.destroy(v);
    }
}
export fn cmdy_render_row_view(self: ?*const Row, out: ?*c.CmdyRenderRowView) void {
    const o = out orelse return;
    o.* = if (self) |v| v.view() else std.mem.zeroes(c.CmdyRenderRowView);
}
export fn cmdy_render_text_boundaries(text: [*c]const u16, len: usize, out: [*c]isize, capacity: usize) usize {
    const list = boundaries(inputSlice(u16, text, len) catch return 0) catch return 0;
    defer a.free(list);
    if (out != null) @memcpy(out[0..@min(capacity, list.len)], list[0..@min(capacity, list.len)]);
    return list.len;
}
export fn cmdy_render_strikethrough(r: Rect, y: f64, thickness: f64) Rect {
    return strike(r, y, thickness);
}
export fn cmdy_render_underlines(style: u8, r: Rect, y: f64, thickness: f64, out: [*c]Rect, capacity: usize) usize {
    var list: std.ArrayList(Rect) = .empty;
    defer list.deinit(a);
    underlineRects(style, r, y, thickness, &list) catch return 0;
    if (out != null) @memcpy(out[0..@min(capacity, list.items.len)], list.items[0..@min(capacity, list.items.len)]);
    return list.items.len;
}
export fn cmdy_render_block_coverage(alpha: f64, exponent: f32) f32 {
    return blockCoverage(alpha, exponent);
}
export fn cmdy_render_box_thickness(thickness: f64, scale: f64) isize {
    return boxThickness(thickness, scale);
}
export fn cmdy_render_attribute_key(dictionary: Object, out: ?*c.CmdyRenderAttributeKey) u8 {
    const o = out orelse return 0;
    o.* = std.mem.zeroes(c.CmdyRenderAttributeKey);
    const dict: c.CFDictionaryRef = @ptrCast(dictionary orelse return 0);
    const count = c.CFDictionaryGetCount(dict);
    if (count > 13) return 0;
    var keys: [13]Object = undefined;
    var values: [13]Object = undefined;
    c.CFDictionaryGetKeysAndValues(dict, &keys, &values);
    for (keys[0..@intCast(count)], values[0..@intCast(count)]) |ak, value| {
        var index: u32 = 0;
        while (index < 13) : (index += 1) if (c.CFEqual(ak, key(index)) != 0) break;
        if (index == 13) return 0;
        const kind = c.cmdy_platform_text_object_kind(value);
        if (index < 8) {
            if (kind != (if (index == 0) @as(u32, 1) else @as(u32, 2))) return 0;
            o.objects[index] = value;
        } else if (index < 12) {
            if (kind != 3) return 0;
            o.integers[index - 8] = c.cmdy_platform_text_number_integer(value);
        } else {
            if (kind != 3) return 0;
            o.kern_bits = @bitCast(c.cmdy_platform_text_number_double(value));
        }
        o.present |= @as(u32, 1) << @intCast(index);
    }
    return 1;
}

const AttributeRun = struct { location: isize, length: isize, value: c.CmdyRenderAttributeKey };
const KeySegment = struct {
    text: c.CFStringRef,
    column: isize,
    column_width: isize,
    count: isize,
    has_boundaries: bool,
    bounds: []isize,
    runs: std.ArrayList(AttributeRun),
    fn deinit(self: *KeySegment) void {
        font.release(self.text);
        a.free(self.bounds);
        for (self.runs.items) |run| for (run.value.objects) |obj| font.release(obj);
        self.runs.deinit(a);
    }
};
pub const TextKey = struct {
    references: usize = 1,
    input: c.CmdyRenderRowInput,
    foreground: Color,
    segments: std.ArrayList(KeySegment) = .empty,
    pub fn deinit(self: *TextKey) void {
        font.release(self.input.normal_font);
        for (self.segments.items) |*segment| segment.deinit();
        self.segments.deinit(a);
    }
};
fn textKeyCreate(input: *const c.CmdyRenderRowInput) !?*TextKey {
    const result = try a.create(TextKey);
    result.* = .{ .input = input.*, .foreground = if (input.foreground != null) font.color(input.foreground) else std.mem.zeroes(Color) };
    result.input.normal_font = font.retain(input.normal_font);
    errdefer {
        result.deinit();
        a.destroy(result);
    }
    for (try inputSlice(c.CmdyRenderTextSegment, input.segments, input.segment_count)) |segment| {
        if (segment.attributed_string == null) return error.InvalidInput;
        if (segment.disable_sharing != 0) return error.UnmodeledAttribute;
        const source: c.CFAttributedStringRef = @ptrCast(segment.attributed_string);
        const string = c.CFStringCreateCopy(null, c.CFAttributedStringGetString(source)) orelse return error.OutOfMemory;
        var item = KeySegment{ .text = string, .column = segment.column, .column_width = segment.column_width, .count = segment.character_count, .has_boundaries = segment.has_boundaries != 0, .bounds = &.{}, .runs = .empty };
        errdefer item.deinit();
        if (item.has_boundaries) item.bounds = try a.dupe(isize, try inputSlice(isize, segment.boundaries, segment.boundary_count));
        const total = c.CFAttributedStringGetLength(source);
        var location: isize = 0;
        while (location < total) {
            var effective: c.CFRange = undefined;
            const attrs = c.CFAttributedStringGetAttributes(source, location, &effective);
            var value: c.CmdyRenderAttributeKey = undefined;
            if (cmdy_render_attribute_key(attrs, &value) == 0) return error.UnmodeledAttribute;
            for (&value.objects) |*obj| obj.* = font.retain(obj.*);
            item.runs.append(a, .{ .location = effective.location, .length = effective.length, .value = value }) catch |err| {
                for (value.objects) |obj| font.release(obj);
                return err;
            };
            if (effective.length <= 0) return error.InvalidInput;
            location = effective.location + effective.length;
        }
        try result.segments.append(a, item);
    }
    return result;
}
fn objectsEqual(x: Object, y: Object) bool {
    if (x == null or y == null) return x == y;
    return c.CFEqual(x, y) != 0;
}
pub fn inputsEqual(x: *const c.CmdyRenderRowInput, y: *const c.CmdyRenderRowInput) bool {
    return x.cell_width == y.cell_width and x.cell_height == y.cell_height and x.scale == y.scale and objectsEqual(x.normal_font, y.normal_font) and x.underline_position == y.underline_position and x.underline_thickness == y.underline_thickness;
}
pub fn keyEqual(x: *const TextKey, y: *const TextKey) bool {
    if (!inputsEqual(&x.input, &y.input) or !sameColor(x.foreground, y.foreground) or x.input.width != y.input.width or x.input.height != y.input.height or x.input.cols != y.input.cols or x.input.snaps_y != y.input.snaps_y or x.input.coverage_exponent != y.input.coverage_exponent or x.input.antialias_blocks != y.input.antialias_blocks or x.segments.items.len != y.segments.items.len) return false;
    for (x.segments.items, y.segments.items) |sx, sy| {
        if (sx.column != sy.column or sx.column_width != sy.column_width or sx.count != sy.count or sx.has_boundaries != sy.has_boundaries or !std.mem.eql(isize, sx.bounds, sy.bounds) or !objectsEqual(sx.text, sy.text) or sx.runs.items.len != sy.runs.items.len) return false;
        for (sx.runs.items, sy.runs.items) |rx, ry| {
            if (rx.location != ry.location or rx.length != ry.length or rx.value.present != ry.value.present or rx.value.kern_bits != ry.value.kern_bits or !std.mem.eql(i64, &rx.value.integers, &ry.value.integers)) return false;
            for (rx.value.objects, ry.value.objects) |ox, oy| if (!objectsEqual(ox, oy)) return false;
        }
    }
    return true;
}
export fn cmdy_render_text_key_create(input: ?*const c.CmdyRenderRowInput) ?*TextKey {
    return textKeyCreate(input orelse return null) catch null;
}
export fn cmdy_render_text_key_equal(x: ?*const TextKey, y: ?*const TextKey) u8 {
    if (x == null or y == null) return @intFromBool(x == y);
    return @intFromBool(keyEqual(x.?, y.?));
}
export fn cmdy_render_text_key_free(self: ?*TextKey) void {
    if (self) |v| {
        v.references -= 1;
        if (v.references == 0) {
            v.deinit();
            a.destroy(v);
        }
    }
}
export fn cmdy_render_text_key_retain(self: ?*TextKey) ?*TextKey {
    if (self) |v| v.references += 1;
    return self;
}
fn hashNumber(hasher: *std.hash.Wyhash, value: anytype) void {
    hasher.update(std.mem.asBytes(&value));
}
fn hashObject(hasher: *std.hash.Wyhash, value: Object) void {
    const hash: usize = if (value == null) 0 else c.CFHash(value);
    hashNumber(hasher, hash);
}
export fn cmdy_render_text_key_hash(self: ?*const TextKey) u64 {
    const value = self orelse return 0;
    var h = std.hash.Wyhash.init(0);
    const in = value.input;
    for ([_]f64{ in.cell_width, in.cell_height, in.scale, in.underline_position, in.underline_thickness }) |v| hashNumber(&h, if (v == 0) @as(f64, 0) else v);
    for ([_]f32{ value.foreground.r, value.foreground.g, value.foreground.b, value.foreground.a, in.coverage_exponent }) |v| hashNumber(&h, if (v == 0) @as(f32, 0) else v);
    hashObject(&h, in.normal_font);
    hashNumber(&h, in.cols);
    hashNumber(&h, in.width);
    hashNumber(&h, in.height);
    hashNumber(&h, in.snaps_y);
    hashNumber(&h, in.antialias_blocks);
    for (value.segments.items) |segment| {
        hashObject(&h, segment.text);
        hashNumber(&h, segment.column);
        hashNumber(&h, segment.column_width);
        hashNumber(&h, segment.count);
        hashNumber(&h, segment.has_boundaries);
        h.update(std.mem.sliceAsBytes(segment.bounds));
        for (segment.runs.items) |run| {
            hashNumber(&h, run.location);
            hashNumber(&h, run.length);
            hashNumber(&h, run.value.present);
            hashNumber(&h, run.value.kern_bits);
            h.update(std.mem.asBytes(&run.value.integers));
            for (run.value.objects) |obj| hashObject(&h, obj);
        }
    }
    return h.final();
}
export fn cmdy_render_solid_merge(previous: ?*Solid, next: ?*const Solid) u8 {
    const last = previous orelse return 0;
    const value = next orelse return 0;
    if (sameColor(last.color, value.color) and last.rect.width > 0 and last.rect.height > 0 and value.rect.width > 0 and value.rect.height > 0 and last.rect.y == value.rect.y and last.rect.height == value.rect.height and last.rect.x + last.rect.width == value.rect.x) {
        last.rect.width += value.rect.width;
        return 1;
    }
    return 0;
}

/// Reconstruct the same logical key as a full attributed row. Paint colors
/// remain part of equality and hashing, including their original object values.
pub fn keyCreatePaint(input: *const c.CmdyRenderRowInput, paint: anytype) ?*TextKey {
    const result = (textKeyCreate(input) catch return null) orelse return null;
    std.debug.assert(result.segments.items.len == paint.backgrounds.items.len);
    for (result.segments.items, paint.backgrounds.items) |*segment, background| {
        if (background) |value| for (segment.runs.items) |*run| {
            std.debug.assert(run.value.objects[2] == null);
            run.value.objects[2] = font.retain(value);
            run.value.present |= @as(u32, 1) << 2;
        };
    }
    return result;
}
/// Text uses the unchanged rasterizer. Background solids use the same original
/// segment-local arithmetic, clipping and merge order as rasterSegment.
pub fn createWithPaint(input: *const c.CmdyRenderRowInput, ascii_lines: *ASCIILines, paint: anytype) ?*Row {
    const row = createWithCache(input, ascii_lines) orelse return null;
    std.debug.assert(row.backgrounds.items.len == 0);
    for (paint.result.segments.items, paint.backgrounds.items) |segment, background| {
        const value = background orelse continue;
        const rgba = font.color(value);
        const start = fl(segment.column) * input.cell_width;
        const ascii = input.ascii_caching != 0 and start >= 0 and start + fl(segment.character_count) * input.cell_width <= fl(input.width);
        var cell: isize = 0;
        while (cell < segment.character_count) : (cell += 1) {
            // This path is ASCII, but the caller may disable ASCII caching.
            const x = if (ascii) start + fl(cell) * input.cell_width else fl(segment.column + cell) * input.cell_width;
            if (x >= fl(input.width) or x + input.cell_width <= 0) continue;
            appendSolid(&row.backgrounds, .{ .rect = aligned(.{ .x = x, .y = 0, .width = input.cell_width, .height = input.cell_height }), .color = rgba }) catch {
                row.deinit(); a.destroy(row); return null;
            };
        }
    }
    return row;
}
