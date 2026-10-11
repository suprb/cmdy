//! Native font ownership, descriptor preparation, glyph rasterization and metrics.
const std = @import("std");
pub const c = @import("render_text_platform.zig").c;
pub const a = std.heap.c_allocator;
pub const Object = ?*const anyopaque;
var fallback_mutex: std.Thread.Mutex = .{};
var fallback_loader: ?*const fn () callconv(.c) u8 = null;
var fallback_ready: std.atomic.Value(bool) = .init(true);

export fn cmdy_render_set_font_fallback_loader(loader: ?*const fn () callconv(.c) u8) u8 {
    fallback_mutex.lock();
    defer fallback_mutex.unlock();
    if (loader == null or fallback_loader != null) return 0;
    fallback_loader = loader;
    fallback_ready.store(false, .release);
    return 1;
}

pub fn prepareFallback(source: Object, text: c.CFStringRef) void {
    if (fallback_ready.load(.acquire)) return;
    // Bounded stack storage, with no retained text/font or new cache. A split
    // surrogate pair conservatively requests fallback registration as well.
    var chars: [64]u16 = undefined;
    var glyphs: [64]u16 = undefined;
    const length = c.CFStringGetLength(text);
    var offset: isize = 0;
    while (offset < length) {
        const count = @min(length - offset, chars.len);
        c.CFStringGetCharacters(text, .{ .location = offset, .length = count }, &chars);
        if (!c.CTFontGetGlyphsForCharacters(ct(source), &chars, &glyphs, count)) {
            fallback_mutex.lock();
            defer fallback_mutex.unlock();
            if (!fallback_ready.load(.monotonic)) {
                if (fallback_loader) |load| {
                    if (load() != 0) fallback_ready.store(true, .release);
                }
            }
            return;
        }
        offset += count;
    }
}

pub fn retain(value: Object) Object {
    if (value != null) return c.CFRetain(value);
    return null;
}
pub fn release(value: Object) void {
    if (value != null) c.CFRelease(value);
}
pub fn ct(value: Object) c.CTFontRef {
    return @ptrCast(value);
}
pub fn rect(x: f64, y: f64, w: f64, h: f64) c.CGRect {
    return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = w, .height = h } };
}
pub fn nativeRect(r: c.CGRect) c.CmdyRenderRect {
    return .{ .x = r.origin.x, .y = r.origin.y, .width = r.size.width, .height = r.size.height };
}
pub fn cgRect(r: c.CmdyRenderRect) c.CGRect {
    return rect(r.x, r.y, r.width, r.height);
}
pub fn color(value: Object) c.CmdyRenderColor {
    const rgb = c.cmdy_platform_text_color_device_rgb(value) orelse value;
    return .{ .r = @floatCast(c.cmdy_platform_text_color_component(rgb, 0)), .g = @floatCast(c.cmdy_platform_text_color_component(rgb, 1)), .b = @floatCast(c.cmdy_platform_text_color_component(rgb, 2)), .a = @floatCast(c.cmdy_platform_text_color_component(rgb, 3)) };
}
pub fn shapingFont(source: Object) Object {
    const descriptor = c.CTFontCopyFontDescriptor(ct(source)) orelse return null;
    defer release(descriptor);
    var zero: i32 = 0;
    const number = c.CFNumberCreate(null, c.kCFNumberSInt32Type, &zero) orelse return null;
    defer release(number);
    var tags: [4]Object = undefined;
    var count: usize = 0;
    defer for (tags[0..count]) |tag| release(tag);
    for ([_][*:0]const u8{ "liga", "clig", "dlig", "calt" }, 0..) |name, i| {
        const tag = c.CFStringCreateWithCString(null, name, c.kCFStringEncodingUTF8) orelse return null;
        defer release(tag);
        var values = [_]Object{ tag, number };
        tags[i] = c.CFArrayCreate(null, &values, 2, &c.kCFTypeArrayCallBacks) orelse return null;
        count += 1;
    }
    const settings = c.CFArrayCreate(null, &tags, 4, &c.kCFTypeArrayCallBacks) orelse return null;
    defer release(settings);
    var key = [_]Object{c.kCTFontFeatureSettingsAttribute};
    var value = [_]Object{settings};
    const attrs = c.CFDictionaryCreate(null, &key, &value, 1, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer release(attrs);
    const shaped = c.CTFontDescriptorCreateCopyWithAttributes(descriptor, attrs) orelse return null;
    defer release(shaped);
    return c.CTFontCreateWithFontDescriptor(shaped, c.CTFontGetSize(ct(source)), null);
}
const Entry = struct { source: Object, font: Object };
const Tier = struct {
    first: ?Entry = null,
    extra: std.AutoHashMapUnmanaged(usize, Entry) = .empty,
    fn get(self: *Tier, source: Object) Object {
        if (self.first) |entry| if (entry.source == source) {
            return entry.font;
        };
        if (self.extra.get(@intFromPtr(source))) |entry| return entry.font;
        return null;
    }
    fn put(self: *Tier, source: Object, font: Object) !void {
        const entry: Entry = .{ .source = retain(source), .font = retain(font) };
        if (self.first == null) self.first = entry else self.extra.put(a, @intFromPtr(source), entry) catch |err| {
            release(entry.source);
            release(entry.font);
            return err;
        };
    }
    fn deinit(self: *Tier) void {
        if (self.first) |entry| {
            release(entry.source);
            release(entry.font);
        }
        var it = self.extra.valueIterator();
        while (it.next()) |entry| {
            release(entry.source);
            release(entry.font);
        }
        self.extra.deinit(a);
    }
    fn count(self: *const Tier) usize {
        return @intFromBool(self.first != null) + self.extra.count();
    }
};
pub const Fonts = struct {
    scale: f64,
    normal: Object,
    caching: bool,
    scaled: Tier = .{},
    shaping: Tier = .{},
    pub fn init(scale: f64, normal: Object, caching: bool) Fonts {
        return .{ .scale = scale, .normal = retain(normal), .caching = caching };
    }
    pub fn deinit(self: *Fonts) void {
        self.scaled.deinit();
        self.shaping.deinit();
        release(self.normal);
    }
    // Always return +1, even when a cache supplies the immutable result.
    pub fn scaledFont(self: *Fonts, source: Object) Object {
        if (source == null) return retain(self.normal);
        if (self.caching) if (self.scaled.get(source)) |cached| {
            return retain(cached);
        };
        const result = c.cmdy_platform_text_font_scaled(source, c.cmdy_platform_text_font_size(source) * self.scale) orelse retain(self.normal);
        if (self.caching) self.scaled.put(source, result) catch {};
        return result;
    }
    pub fn prepared(self: *Fonts, source: Object) Object {
        if (self.caching) if (self.shaping.get(source)) |cached| {
            return retain(cached);
        };
        const result = shapingFont(source) orelse retain(source);
        if (self.caching) self.shaping.put(source, result) catch {};
        return result;
    }
};
pub fn centeredBaseline(h: f64, asc: f64, des: f64, lead: f64, snaps: bool) f64 {
    const result = (h - (asc + des + lead)) / 2 + (des - @floor(des));
    return if (snaps) @round(result) else result;
}
pub fn gridBaseline(h: f64, font: Object, scale: f64, snaps: bool) f64 {
    const asc = c.CTFontGetAscent(ct(font));
    const des = c.CTFontGetDescent(ct(font));
    const lead = c.CTFontGetLeading(ct(font));
    const centered = centeredBaseline(h, asc, des, lead, snaps);
    const safe = if (std.math.isFinite(scale) and scale > 0) scale else 1;
    const minimum = @ceil((des + lead) / safe) * safe;
    const result = @min(h, @max(centered, minimum));
    return if (snaps) @round(result) else result;
}
pub fn glyphBounds(font: Object, glyph: u16) c.CGRect {
    var value = glyph;
    return c.CTFontGetBoundingRectsForGlyphs(ct(font), c.kCTFontOrientationDefault, &value, null, 1);
}
pub fn visibleBounds(bounds: c.CGRect) bool {
    return bounds.size.width > 0 and bounds.size.height > 0 and std.math.isFinite(bounds.size.width) and std.math.isFinite(bounds.size.height);
}
pub const Bitmap = struct {
    width: isize,
    height: isize,
    x: f64,
    y: f64,
    bytes: []u8,
    is_color: bool,
    pub fn deinit(self: *Bitmap) void {
        a.free(self.bytes);
    }
};
pub fn glyphRasterize(font: Object, glyph: u16) ?*Bitmap {
    const bounds = glyphBounds(font, glyph);
    if (glyph == 0 or !visibleBounds(bounds)) return null;
    const x = @floor(bounds.origin.x);
    const y = @floor(bounds.origin.y);
    const wd = @ceil(bounds.origin.x + bounds.size.width) - x;
    const hd = @ceil(bounds.origin.y + bounds.size.height) - y;
    if (wd <= 0 or hd <= 0 or wd > 2048 or hd > 2048) return null;
    const w: usize = @intFromFloat(wd);
    const h: usize = @intFromFloat(hd);
    const space = c.CGColorSpaceCreateWithName(c.kCGColorSpaceSRGB) orelse return null;
    defer c.CGColorSpaceRelease(space);
    const context = c.CGBitmapContextCreate(null, w, h, 8, w * 4, space, c.kCGBitmapByteOrder32Little | c.kCGImageAlphaPremultipliedFirst) orelse return null;
    defer c.CGContextRelease(context);
    c.CGContextSetAllowsAntialiasing(context, true);
    c.CGContextSetShouldAntialias(context, true);
    c.CGContextSetAllowsFontSubpixelPositioning(context, true);
    c.CGContextSetShouldSubpixelPositionFonts(context, true);
    c.CGContextSetAllowsFontSubpixelQuantization(context, false);
    c.CGContextSetShouldSubpixelQuantizeFonts(context, false);
    c.CGContextSetAllowsFontSmoothing(context, true);
    c.CGContextSetShouldSmoothFonts(context, true);
    const white = c.cmdy_platform_text_color_cg(c.cmdy_platform_text_white());
    c.CGContextSetFillColorWithColor(context, white);
    c.CGContextSetStrokeColorWithColor(context, white);
    var value = glyph;
    var point = c.CGPoint{ .x = -x, .y = -y };
    c.CTFontDrawGlyphs(ct(font), &value, &point, 1, context);
    const data: [*]const u8 = @ptrCast(c.CGBitmapContextGetData(context) orelse return null);
    const bytes = a.dupe(u8, data[0 .. w * h * 4]) catch return null;
    const result = a.create(Bitmap) catch {
        a.free(bytes);
        return null;
    };
    var colored = false;
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) {
        if (bytes[i] != bytes[i + 1] or bytes[i + 1] != bytes[i + 2]) {
            colored = true;
            break;
        }
    }
    result.* = .{ .width = @intCast(w), .height = @intCast(h), .x = x, .y = y, .bytes = bytes, .is_color = colored };
    return result;
}
export fn cmdy_render_fonts_create(scale: f64, normal: Object, caching: u8) ?*Fonts {
    const result = a.create(Fonts) catch return null;
    result.* = Fonts.init(scale, normal, caching != 0);
    return result;
}
export fn cmdy_render_fonts_free(self: ?*Fonts) void {
    if (self) |v| {
        v.deinit();
        a.destroy(v);
    }
}
export fn cmdy_render_fonts_scaled(self: ?*Fonts, source: Object) Object {
    return if (self) |v| v.scaledFont(source) else null;
}
export fn cmdy_render_fonts_shaping(self: ?*Fonts, source: Object) Object {
    return if (self) |v| v.prepared(source) else null;
}
export fn cmdy_render_shaping_font(source: Object) Object {
    return shapingFont(source);
}
export fn cmdy_render_fonts_count(self: ?*const Fonts, shaping: u8) usize {
    if (self) |v| return if (shaping != 0) v.shaping.count() else v.scaled.count();
    return 0;
}
export fn cmdy_render_fonts_additional_storage(self: ?*const Fonts, shaping: u8) u8 {
    if (self) |v| return @intFromBool(if (shaping != 0) v.shaping.extra.capacity() > 0 else v.scaled.extra.capacity() > 0);
    return 0;
}
export fn cmdy_render_color(value: Object) c.CmdyRenderColor {
    return color(value);
}
export fn cmdy_render_packed_color(value: Object) u64 {
    const rgba = color(value);
    var result: u64 = 0;
    for ([_]f32{ rgba.r, rgba.g, rgba.b, rgba.a }, 0..) |v, i| {
        const component: u64 = @intFromFloat(@max(0, @min(65535, v * 65535)));
        result ^= component << @as(u6, @intCast(i * 16));
    }
    return result;
}
export fn cmdy_render_centered_baseline(h: f64, asc: f64, des: f64, lead: f64, snaps: u8) f64 {
    return centeredBaseline(h, asc, des, lead, snaps != 0);
}
export fn cmdy_render_grid_baseline(h: f64, font: Object, scale: f64, snaps: u8) f64 {
    return gridBaseline(h, font, scale, snaps != 0);
}
export fn cmdy_render_cell_text_origin(x: f64, cell_width: f64, line_width: f64) f64 {
    _ = cell_width;
    _ = line_width;
    return x;
}
export fn cmdy_render_glyph_has_bounds(font: Object, glyph: u16) u8 {
    return @intFromBool(visibleBounds(glyphBounds(font, glyph)));
}
export fn cmdy_render_glyph_rasterize(font: Object, glyph: u16) ?*Bitmap {
    return glyphRasterize(font, glyph);
}
export fn cmdy_render_glyph_bitmap_view(self: ?*const Bitmap, out: ?*c.CmdyRenderGlyphBitmapView) void {
    const o = out orelse return;
    o.* = std.mem.zeroes(c.CmdyRenderGlyphBitmapView);
    const v = self orelse return;
    o.* = .{ .width = v.width, .height = v.height, .bearing_x = v.x, .bearing_y = v.y, .bytes = v.bytes.ptr, .byte_count = v.bytes.len, .is_color = @intFromBool(v.is_color) };
}
export fn cmdy_render_glyph_bitmap_free(self: ?*Bitmap) void {
    if (self) |v| {
        v.deinit();
        a.destroy(v);
    }
}
