//! Headless tests of the actual glyph cache, linked with its platform bridge.
const std = @import("std");
const t = std.testing;
const Cache = @import("render_cache_glyph.zig").Cache;
const c = @import("render_shader.zig").c;
// Compile the real rasterizer and atlas alongside the cache. Linking the
// monolithic engine object would define render_shader's exports twice.
comptime {
    _ = @import("render_font.zig");
    _ = @import("render_text_storage.zig");
}
extern "c" fn glyph_test_device() ?*const anyopaque;
extern "c" fn glyph_test_font(f64, c_uint) ?*const anyopaque;
extern "c" fn glyph_test_glyph(?*const anyopaque, u32) u16;
extern "c" fn glyph_test_reset(?*const anyopaque) void;
extern "c" fn glyph_test_count(c_uint) u64;
extern "c" fn glyph_test_collide(u8) void;
extern "c" fn glyph_test_line_pixels(?*const anyopaque, *const c.CmdyRenderRect, ?*const anyopaque, u16) u8;
extern "c" fn glyph_test_compatibility_pixels(?*const anyopaque, *const c.CmdyGpuGlyphEntry, ?*const anyopaque, u16, c_uint) u8;

fn device() !*const anyopaque { return glyph_test_device() orelse error.NoMetalDevice; }
fn font(size: f64, variant: c_uint) !*const anyopaque { return glyph_test_font(size, variant) orelse error.NoFixtureFont; }
fn glyph(f: *const anyopaque, code: u32) !u16 {
    const value = glyph_test_glyph(f, code);
    if (value == 0) return error.MissingFixtureGlyph;
    return value;
}
fn cacheFor(d: *const anyopaque, allocator: std.mem.Allocator) Cache {
    var cache = Cache.init(d); cache.allocator = allocator; return cache;
}
fn verify(cache: *Cache, f: *const anyopaque, g: u16, preset: u32) !void {
    const entry = cache.compatibilityGlyph(f, g, preset) orelse return error.GlyphMissing;
    const atlas = if (entry.is_color != 0) cache.color_atlas else cache.gray_atlas;
    try t.expectEqual(entry.generation, c.cmdy_render_atlas_generation(atlas, entry.page));
    const padding: c_uint = @intFromBool(preset == 2 or preset == 5);
    try t.expect(glyph_test_compatibility_pixels(c.cmdy_render_atlas_texture(atlas), &entry, f, g, padding) != 0);
    if (entry.is_color == 0) {
        const rect = cache.lineGlyph(f, g, preset) orelse return error.LineGlyphMissing;
        try t.expect(glyph_test_line_pixels(cache.lineTexture(), &rect, f, g) != 0);
    } else try t.expect(cache.lineGlyph(f, g, preset) == null);
}

test "complete font identity and padding retain exact grayscale and color pixels" {
    const d = try device(); defer c.cmdy_gpu_apple_release(d);
    var cache = cacheFor(d, t.allocator); defer cache.deinit();
    var fonts: [5]*const anyopaque = undefined;
    var initialized: usize = 0;
    defer for (fonts[0..initialized]) |f| c.cmdy_gpu_apple_release(f);
    for (&fonts, 0..) |*item, variant| {
        item.* = try font(24, @intCast(variant));
        initialized += 1;
    }
    try t.expect(c.cmdy_gpu_apple_equal(fonts[0], fonts[1]) == 0);
    try t.expect(c.cmdy_gpu_apple_equal(fonts[2], fonts[3]) == 0);
    for (fonts, 0..) |f, variant| {
        const g = try glyph(f, if (variant == 4) 0x1f600 else 'A');
        for ([_]u32{ 0, 2, 5, 1, 2, 0 }) |preset| try verify(&cache, f, g, preset);
    }
    const count = cache.compatibility.count();
    const equivalent = try font(24, 0); defer c.cmdy_gpu_apple_release(equivalent);
    try t.expect(c.cmdy_gpu_apple_equal(fonts[0], equivalent) != 0);
    try verify(&cache, equivalent, try glyph(equivalent, 'A'), 0);
    try t.expectEqual(count, cache.compatibility.count());
    try t.expect(cache.lineGlyph(null, 1, 0) == null and cache.compatibilityGlyph(null, 1, 0) == null);
}

test "warm indexed lookups allocate no metadata and copy no font names" {
    const d = try device(); defer c.cmdy_gpu_apple_release(d);
    const f = try font(16, 0); defer c.cmdy_gpu_apple_release(f);
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    var cache = cacheFor(d, allocator.allocator()); defer cache.deinit();
    var glyphs: [94]u16 = undefined;
    for (&glyphs, 0..) |*g, index| {
        g.* = try glyph(f, @intCast(33 + index));
        try t.expect(cache.lineGlyph(f, g.*, 0) != null);
        try t.expect(cache.compatibilityGlyph(f, g.*, 0) != null);
    }
    try t.expect(cache.line.index_header != null and cache.compatibility.index_header != null);
    const allocated = allocator.allocated_bytes;
    allocator.fail_index = allocator.alloc_index;
    allocator.resize_fail_index = allocator.resize_index;
    glyph_test_reset(f);
    for (0..100) |_| for (glyphs) |g| {
        try t.expect(cache.lineGlyph(f, g, 0) != null);
        try t.expect(cache.compatibilityGlyph(f, g, 0) != null);
    };
    try t.expectEqual(allocated, allocator.allocated_bytes);
    try t.expect(!allocator.has_induced_failure);
    try t.expectEqual(@as(u64, 0), glyph_test_count(0));
    try t.expectEqual(@as(u64, 0), glyph_test_count(3));
    try t.expectEqual(@as(u64, 0), glyph_test_count(4));
    try t.expectEqual(@as(u64, 18800), glyph_test_count(1));
    try t.expect(glyph_test_count(2) <= 18800 * 2);
    std.debug.print("GLYPH_INDEX_HITS lookups=18800 fontNameCopies=0 metadataAllocations=0 hashCalls={d} equalityCalls={d} cacheBytes={d}\n",
        .{ glyph_test_count(1), glyph_test_count(2), allocator.allocated_bytes - allocator.freed_bytes });
}

test "font hash collisions preserve every distinct font and release owned keys" {
    const d = try device(); defer c.cmdy_gpu_apple_release(d);
    glyph_test_collide(1); defer glyph_test_collide(0);
    var cache = cacheFor(d, t.allocator); defer cache.deinit();
    var fonts: [24]*const anyopaque = undefined;
    var initialized: usize = 0;
    defer for (fonts[0..initialized]) |f| c.cmdy_gpu_apple_release(f);
    for (&fonts, 0..) |*f, index| {
        f.* = try font(10 + @as(f64, @floatFromInt(index)), 0);
        initialized += 1;
    }
    for (fonts) |f| try verify(&cache, f, try glyph(f, 'W'), 0);
    try t.expectEqual(@as(usize, 24), cache.line.count());
    try t.expectEqual(@as(usize, 24), cache.compatibility.count());
    for (0..fonts.len) |index| {
        const f = fonts[fonts.len - index - 1];
        try verify(&cache, f, try glyph(f, 'W'), 0);
    }
}

test "page eviction swap-removes only matching residency and rejects stale generations" {
    const d = try device(); defer c.cmdy_gpu_apple_release(d);
    const f = try font(16, 0); defer c.cmdy_gpu_apple_release(f);
    const emoji = try font(24, 4); defer c.cmdy_gpu_apple_release(emoji);
    var cache = cacheFor(d, t.allocator); defer cache.deinit();
    cache.gray_atlas = c.cmdy_render_atlas_create(d, 32, 2, 0, 0) orelse return error.NoAtlas;
    cache.color_atlas = c.cmdy_render_atlas_create(d, 64, 2, 1, 0) orelse return error.NoAtlas;
    const color_glyph = try glyph(emoji, 0x1f600);
    const color_entry = cache.compatibilityGlyph(emoji, color_glyph, 0).?;
    for (0..3) |_| for (33..127) |code| try verify(&cache, f, try glyph(f, @intCast(code)), 0);
    try t.expect(c.cmdy_render_atlas_generation(cache.gray_atlas, 0) > 1);
    try t.expectEqualDeep(color_entry, cache.compatibilityGlyph(emoji, color_glyph, 0).?);
    const g = try glyph(f, 'A');
    const old = cache.compatibilityGlyph(f, g, 0).?;
    // Model an atlas eviction followed by failure before cache bookkeeping.
    var region: c.CmdyRenderAtlasRegion = undefined;
    for (0..3) |_| try t.expect(c.cmdy_render_atlas_region(cache.gray_atlas, 32, 32, &region) != 0);
    try t.expect(c.cmdy_render_atlas_generation(cache.gray_atlas, old.page) != old.generation);
    try verify(&cache, f, g, 0);
    try verify(&cache, emoji, color_glyph, 0);
}

test "cache allocation failure precedes atlas mutation and all backing memory is released" {
    const d = try device(); defer c.cmdy_gpu_apple_release(d);
    const f = try font(12, 0); defer c.cmdy_gpu_apple_release(f);
    var failures: usize = 0;
    for (0..16) |failure| {
        var allocator = t.FailingAllocator.init(t.allocator, .{ .fail_index = failure, .resize_fail_index = 0 });
        {
            var cache = cacheFor(d, allocator.allocator()); defer cache.deinit();
            for (33..127) |code| {
                const g = try glyph(f, @intCast(code));
                const count = cache.compatibility.count();
                const generation = c.cmdy_render_atlas_generation(cache.gray_atlas, 0);
                if (cache.compatibilityGlyph(f, g, 0) == null) {
                    try t.expect(allocator.has_induced_failure);
                    try t.expectEqual(count, cache.compatibility.count());
                    try t.expectEqual(generation, c.cmdy_render_atlas_generation(cache.gray_atlas, 0));
                    if (failure == 0) try t.expect(cache.gray_atlas == null);
                    for (cache.compatibility.keys(), cache.compatibility.values()) |key, entry|
                        try t.expectEqualDeep(entry, cache.compatibilityGlyph(key.font, key.glyph, 0).?);
                    failures += 1;
                    break;
                }
            }
        }
        try t.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
    }
    try t.expect(failures >= 8);
    var allocator = t.FailingAllocator.init(t.allocator, .{ .fail_index = 0 });
    var cache = cacheFor(d, allocator.allocator()); defer cache.deinit();
    try t.expect(cache.lineGlyph(f, try glyph(f, 'A'), 0) == null);
    try t.expect(cache.line_atlas == null and cache.line.count() == 0);
}

test "preset invalidation and teardown balance retained font keys" {
    const d = try device(); defer c.cmdy_gpu_apple_release(d);
    const f = try font(16, 0); defer c.cmdy_gpu_apple_release(f);
    glyph_test_reset(f);
    {
        var cache = cacheFor(d, t.allocator); defer cache.deinit();
        for ([_]u32{ 'A', 'B', 'C' }) |code| try verify(&cache, f, try glyph(f, code), 0);
        try t.expectEqual(@as(u64, 6), glyph_test_count(3));
        cache.invalidatePreset();
        try t.expectEqual(@as(u64, 3), glyph_test_count(4));
        try t.expectEqual(@as(usize, 0), cache.line.count());
        try t.expectEqual(@as(usize, 3), cache.compatibility.count());
        for ([_]u32{ 'A', 'B', 'C' }) |code| try verify(&cache, f, try glyph(f, code), 2);
    }
    try t.expectEqual(glyph_test_count(3), glyph_test_count(4));
    glyph_test_reset(null);
}
