//! Atlas residency and glyph cache identities stay in the native renderer.
const std = @import("std");
const c = @import("render_shader.zig").c;
const a = std.heap.c_allocator;
const Key = struct {
    font: *const anyopaque,
    glyph: u16,
    padding: u8,
    fn init(font: *const anyopaque, glyph_value: u16, preset: u32) Key {
        // Borrow on lookup. A font name and size omit transforms, variations
        // and descriptor attributes; CF equality covers the immutable CTFont.
        return .{ .font = font, .glyph = glyph_value, .padding = @intFromBool(preset == 2 or preset == 5) };
    }
    fn retained(key: Key) Key {
        _ = c.cmdy_gpu_apple_retain(key.font);
        return key;
    }
    fn deinit(k: Key) void {
        c.cmdy_gpu_apple_release(k.font);
    }
};
const KeyContext = struct {
    pub fn hash(_: KeyContext, key: Key) u32 {
        const words = [_]u64{ c.cmdy_gpu_apple_hash(key.font), @as(u64, key.glyph) | (@as(u64, key.padding) << 16) };
        return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&words)));
    }
    pub fn eql(_: KeyContext, left: Key, right: Key, _: usize) bool {
        return left.glyph == right.glyph and left.padding == right.padding and
            c.cmdy_gpu_apple_equal(left.font, right.font) != 0;
    }
};
const LineGlyphs = std.ArrayHashMapUnmanaged(Key, c.CmdyRenderRect, KeyContext, true);
const CompatibilityGlyphs = std.ArrayHashMapUnmanaged(Key, c.CmdyGpuGlyphEntry, KeyContext, true);
const CustomKey = struct { code_point: u32, width: isize, height: isize, scale_bits: u64, antialias: u8 };
pub const Cache = struct {
    device: ?*const anyopaque,
    allocator: std.mem.Allocator = a,
    line_atlas: ?*c.CmdyRenderAtlas = null,
    gray_atlas: ?*c.CmdyRenderAtlas = null,
    color_atlas: ?*c.CmdyRenderAtlas = null,
    line: LineGlyphs = .empty,
    compatibility: CompatibilityGlyphs = .empty,
    custom: std.AutoHashMapUnmanaged(CustomKey, void) = .empty,
    color_allocations: usize = 0,
    pub fn init(device: ?*const anyopaque) Cache {
        return .{ .device = device };
    }
    pub fn deinit(self: *Cache) void {
        for (self.line.keys()) |key| key.deinit();
        for (self.compatibility.keys()) |key| key.deinit();
        self.line.deinit(self.allocator);
        self.compatibility.deinit(self.allocator);
        self.custom.deinit(self.allocator);
        c.cmdy_render_atlas_free(self.line_atlas);
        c.cmdy_render_atlas_free(self.gray_atlas);
        c.cmdy_render_atlas_free(self.color_atlas);
    }
    pub fn invalidatePreset(self: *Cache) void {
        for (self.line.keys()) |key| key.deinit();
        self.line.clearRetainingCapacity();
    }
    fn ensureLine(self: *Cache) ?*c.CmdyRenderAtlas {
        if (self.line_atlas == null) self.line_atlas = c.cmdy_render_atlas_create(self.device, 1024, 1, 0, 1);
        return self.line_atlas;
    }
    pub fn lineTexture(self: *const Cache) ?*const anyopaque {
        return c.cmdy_render_atlas_texture(self.line_atlas);
    }
    pub fn reserveCustom(self: *Cache, input: *const c.CmdyRenderRowInput) void {
        if (input.box_count == 0 and input.block_count == 0) return;
        _ = self.ensureLine() orelse return;
        for (input.boxes[0..input.box_count]) |box| self.reserve(box.code_point, box.column_width, input);
        for (input.blocks[0..input.block_count]) |block| self.reserve(block.code_point, block.column_width, input);
    }
    fn reserve(self: *Cache, code: u32, width: isize, input: *const c.CmdyRenderRowInput) void {
        const key = CustomKey{ .code_point = code, .width = @max(1, @as(isize, @intFromFloat(@round(@as(f64, @floatFromInt(@max(1, width))) * input.cell_width)))), .height = @max(1, @as(isize, @intFromFloat(@round(input.cell_height)))), .scale_bits = @bitCast(input.scale), .antialias = input.antialias_blocks };
        const entry = self.custom.getOrPut(self.allocator, key) catch return;
        if (entry.found_existing) return;
        var region: c.CmdyRenderAtlasRegion = undefined;
        _ = c.cmdy_render_atlas_region(self.line_atlas, key.width, key.height, &region);
    }
    pub fn lineGlyph(self: *Cache, font: ?*const anyopaque, glyph: u16, preset: u32) ?c.CmdyRenderRect {
        const key = Key.init(font orelse return null, glyph, preset);
        if (self.line.get(key)) |rect| return rect;
        const bitmap = c.cmdy_render_glyph_rasterize(font, glyph) orelse return null;
        defer c.cmdy_render_glyph_bitmap_free(bitmap);
        var view: c.CmdyRenderGlyphBitmapView = undefined;
        c.cmdy_render_glyph_bitmap_view(bitmap, &view);
        if (view.is_color != 0) return null;
        // Reserve before changing atlas residency. The final insertion cannot
        // fail after consuming atlas space or invalidating an evicted page.
        self.line.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const atlas = self.ensureLine() orelse return null;
        const padding: isize = key.padding;
        var region: c.CmdyRenderAtlasRegion = undefined;
        if (c.cmdy_render_atlas_insert_glyph(atlas, &view, padding, &region) == 0) return null;
        const rect = c.CmdyRenderRect{ .x = @floatFromInt(region.x + padding), .y = @floatFromInt(region.y + padding), .width = @floatFromInt(view.width), .height = @floatFromInt(view.height) };
        self.line.putAssumeCapacityNoClobber(key.retained(), rect);
        return rect;
    }
    pub fn compatibilityGlyph(self: *Cache, font: ?*const anyopaque, glyph: u16, preset: u32) ?c.CmdyGpuGlyphEntry {
        const key = Key.init(font orelse return null, glyph, preset);
        if (self.compatibility.getIndex(key)) |index| {
            const entry = self.compatibility.values()[index];
            const atlas = if (entry.is_color != 0) self.color_atlas else self.gray_atlas;
            if (c.cmdy_render_atlas_generation(atlas, entry.page) == entry.generation) return entry;
            // Region allocation may have evicted a page before a subsequent
            // allocation failed. Never return stale coordinates on the retry.
            const expired = self.compatibility.keys()[index];
            self.compatibility.swapRemoveAt(index);
            expired.deinit();
        }
        const bitmap = c.cmdy_render_glyph_rasterize(font, glyph) orelse return null;
        defer c.cmdy_render_glyph_bitmap_free(bitmap);
        var view: c.CmdyRenderGlyphBitmapView = undefined;
        c.cmdy_render_glyph_bitmap_view(bitmap, &view);
        self.compatibility.ensureUnusedCapacity(self.allocator, 1) catch return null;
        const color = view.is_color != 0;
        const slot = if (color) &self.color_atlas else &self.gray_atlas;
        if (slot.* == null) {
            slot.* = c.cmdy_render_atlas_create(self.device, 1024, 4, @intFromBool(color), 0);
            if (color and slot.* != null) self.color_allocations += 1;
        }
        const atlas = slot.* orelse return null;
        const padding: isize = key.padding;
        var region: c.CmdyRenderAtlasRegion = undefined;
        if (c.cmdy_render_atlas_region(atlas, view.width + padding * 2, view.height + padding * 2, &region) == 0) return null;
        const evicted = c.cmdy_render_atlas_evicted_page(atlas);
        if (evicted >= 0) {
            var i: usize = 0;
            while (i < self.compatibility.count()) {
                const entry = self.compatibility.values()[i];
                if (entry.is_color == view.is_color and entry.page == evicted) {
                    const expired = self.compatibility.keys()[i];
                    self.compatibility.swapRemoveAt(i);
                    expired.deinit();
                } else i += 1;
            }
        }
        // Compatibility grayscale writes intentionally preserve the frozen
        // byte interpretation; the dedicated line atlas extracts glyph alpha.
        c.cmdy_render_atlas_write(atlas, &region, view.bytes, view.byte_count, view.width, view.height, padding);
        const result = c.CmdyGpuGlyphEntry{ .page = region.page, .x = region.x, .y = region.y, .width = region.width, .height = region.height, .bitmap_width = view.width, .bitmap_height = view.height, .generation = region.generation, .bearing_x = view.bearing_x, .bearing_y = view.bearing_y, .is_color = view.is_color };
        self.compatibility.putAssumeCapacityNoClobber(key.retained(), result);
        return result;
    }
};
