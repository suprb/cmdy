//! Immutable raster payloads with native row identity, shared-content lookup,
//! exact texture residency, and one-pass LRU eviction.
const std = @import("std");
pub const c = @import("render_shader.zig").c;
const glyph = @import("render_cache_glyph.zig");
const trace = @import("render_trace.zig");
const text_module = @import("render_text.zig");
const coverage_storage = @import("render_coverage_storage.zig");
const captured = @import("render_frame_input.zig");
const viewport_module = @import("render_viewport.zig");
const LineImage = @import("graphics.zig").LineImage;
const FrozenStyle = @import("render_input.zig").FrozenStyle;
const FrozenParameters = @import("render_input.zig").FrozenParameters;
const a = std.heap.c_allocator;
extern fn cmdy_render_text_key_create(*const c.CmdyRenderRowInput) ?*anyopaque;
extern fn cmdy_render_text_key_equal(?*const anyopaque, ?*const anyopaque) u8;
extern fn cmdy_render_text_key_free(?*anyopaque) void;
pub var rebuilt: std.atomic.Value(u64) = .init(0);
pub var reused: std.atomic.Value(u64) = .init(0);
pub fn slice(comptime T: type, ptr: [*c]const T, count: usize) []const T {
    return if (count == 0) &.{} else ptr[0..count];
}
pub const Inputs = struct {
    cell_width: f64,
    cell_height: f64,
    scale: f64,
    underline_position: f64,
    underline_thickness: f64,
    font: ?*anyopaque,
    foreground: c.CmdyRenderColor,
    fn init(v: *const c.CmdyRenderRowInput) Inputs {
        return .{ .cell_width = v.cell_width, .cell_height = v.cell_height, .scale = v.scale, .underline_position = v.underline_position, .underline_thickness = v.underline_thickness, .font = c.cmdy_gpu_apple_retain(v.normal_font), .foreground = c.cmdy_render_color(v.foreground) };
    }
    fn deinit(v: *Inputs) void {
        c.cmdy_gpu_apple_release(v.font);
    }
    fn equal(v: Inputs, other: *const c.CmdyRenderRowInput) bool {
        return v.cell_width == other.cell_width and v.cell_height == other.cell_height and v.scale == other.scale and v.underline_position == other.underline_position and v.underline_thickness == other.underline_thickness and c.cmdy_gpu_apple_equal(v.font, other.normal_font) != 0 and std.meta.eql(v.foreground, c.cmdy_render_color(other.foreground));
    }
};
pub const Key = struct {
    value: c.CmdyGpuRowKey,
    name: [:0]u8,
    fn init(v: *const c.CmdyGpuRowKey) !Key {
        const name = try a.dupeZ(u8, if (v.font_name == null) "" else std.mem.span(v.font_name));
        var result = Key{ .value = v.*, .name = name };
        result.value.font_name = name;
        return result;
    }
    fn deinit(v: *Key) void {
        a.free(v.name);
    }
    pub fn equal(v: Key, other: *const c.CmdyGpuRowKey, identity: bool) bool {
        inline for (std.meta.fields(c.CmdyGpuRowKey)) |field| {
            if (comptime std.mem.eql(u8, field.name, "font_name")) {
                if (!std.mem.eql(u8, v.name, if (other.font_name == null) "" else std.mem.span(other.font_name))) return false;
            } else if (comptime std.mem.eql(u8, field.name, "absolute_row") or std.mem.eql(u8, field.name, "version")) {
                if (identity and @field(v.value, field.name) != @field(other, field.name)) return false;
            } else {
                if (@field(v.value, field.name) != @field(other, field.name)) return false;
            }
        }
        return true;
    }
};
pub const Payload = struct {
    refs: usize = 1,
    raster: ?*c.CmdyRenderRowRaster = null,
    text_key: ?*anyopaque = null,
    inputs: ?Inputs = null,
    coverage: ?*anyopaque = null,
    colors: []c.CmdyGpuColorLayer = &.{},
    backgrounds: []c.CmdyRenderSolid = &.{},
    tints: []c.CmdyRenderTint = &.{},
    atlas_glyphs: []c.CmdyGpuAtlasGlyph = &.{},
    decorations: []c.CmdyRenderSolid = &.{},
    images: []c.CmdyGpuImagePlacement = &.{},
    placeholders: []c.CmdyGpuPlaceholder = &.{},
    width: isize = 0,
    height: isize = 0,
    fn retain(p: *Payload) *Payload {
        p.refs += 1;
        return p;
    }
    fn release(p: *Payload) void {
        p.refs -= 1;
        if (p.refs != 0) return;
        c.cmdy_render_row_free(p.raster);
        cmdy_render_text_key_free(p.text_key);
        if (p.inputs) |*inputs| inputs.deinit();
        c.cmdy_gpu_apple_release(p.coverage);
        for (p.colors) |layer| c.cmdy_gpu_apple_release(layer.texture);
        for (p.images) |image| {
            c.cmdy_gpu_apple_release(image.owner);
            c.cmdy_gpu_apple_release(image.image);
            c.cmdy_render_image_input_release(image.owned_image);
        }
        inline for (.{ "colors", "backgrounds", "tints", "atlas_glyphs", "decorations", "images", "placeholders" }) |name| a.free(@field(p, name));
        a.destroy(p);
    }
    pub fn view(p: *const Payload, last_use: u64) c.CmdyGpuRowView {
        return .{ .coverage_texture = p.coverage, .color_layers = p.colors.ptr, .color_layer_count = p.colors.len, .backgrounds = p.backgrounds.ptr, .background_count = p.backgrounds.len, .tints = p.tints.ptr, .tint_count = p.tints.len, .atlas_glyphs = p.atlas_glyphs.ptr, .atlas_glyph_count = p.atlas_glyphs.len, .decorations = p.decorations.ptr, .decoration_count = p.decorations.len, .images = p.images.ptr, .image_count = p.images.len, .placeholders = p.placeholders.ptr, .placeholder_count = p.placeholders.len, .width = p.width, .height = p.height, .last_use = last_use };
    }
};
pub const Row = struct {
    references: usize = 1,
    key: Key,
    payload: *Payload,
    revision: c.CmdyGpuRowRevision,
    last_use: u64,
    captured_text: ?*c.CmdyRenderOwnedRowInput = null,
    viewport_style: ?*FrozenStyle = null,
    viewport_raster: ?*FrozenParameters = null,
    viewport_source_row: isize = 0,
    viewport_style_row: isize = 0,
    pub fn retain(self: *Row) *Row {
        self.references += 1;
        return self;
    }
    pub fn release(self: *Row) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.key.deinit();
        self.payload.release();
        c.cmdy_render_input_release(self.captured_text);
        if (self.viewport_style) |style| style.release();
        if (self.viewport_raster) |raster| raster.release();
        a.destroy(self);
    }
};
const Allocation = struct { bytes: usize, refs: usize };
pub const Cache = struct {
    device: ?*const anyopaque,
    glyphs: *glyph.Cache,
    ascii_lines: text_module.ASCIILines = .{},
    rows: std.AutoHashMapUnmanaged(isize, *Row) = .empty,
    residency: std.AutoHashMapUnmanaged(usize, Allocation) = .empty,
    allocated_bytes: usize = 0,
    clock: u64 = 0,
    pub fn init(device: ?*const anyopaque, glyphs: *glyph.Cache) Cache {
        return .{ .device = device, .glyphs = glyphs };
    }
    pub fn deinit(self: *Cache) void {
        self.clear();
        self.rows.deinit(a);
        self.residency.deinit(a);
    }
    pub fn clear(self: *Cache) void {
        self.ascii_lines.deinit();
        var iterator = self.rows.valueIterator();
        while (iterator.next()) |row| self.destroyRow(row.*);
        self.rows.clearRetainingCapacity();
        std.debug.assert(self.allocated_bytes == 0 and self.residency.count() == 0);
    }
    fn tick(self: *Cache) u64 {
        self.clock +%= 1;
        return self.clock;
    }
    fn retainTexture(self: *Cache, texture: ?*const anyopaque) void {
        const t = texture orelse return;
        const entry = self.residency.getOrPut(a, @intFromPtr(t)) catch return;
        if (entry.found_existing) entry.value_ptr.refs += 1 else {
            const bytes = c.cmdy_gpu_apple_texture_bytes(t);
            entry.value_ptr.* = .{ .bytes = bytes, .refs = 1 };
            self.allocated_bytes += bytes;
        }
    }
    fn releaseTexture(self: *Cache, texture: ?*const anyopaque) void {
        const t = texture orelse return;
        const entry = self.residency.getPtr(@intFromPtr(t)) orelse return;
        entry.refs -= 1;
        if (entry.refs == 0) {
            self.allocated_bytes -= entry.bytes;
            _ = self.residency.remove(@intFromPtr(t));
        }
    }
    fn destroyRow(self: *Cache, row: *Row) void {
        self.releaseTexture(row.payload.coverage);
        for (row.payload.colors) |layer| self.releaseTexture(layer.texture);
        // Cache accounting ends here even when a currently assembling frame
        // still owns this immutable row after a reentrant invalidation.
        row.release();
    }
    fn store(self: *Cache, key: *const c.CmdyGpuRowKey, payload: *Payload, revision: c.CmdyGpuRowRevision, last_use: u64) ?*Row {
        const row = a.create(Row) catch return null;
        row.* = .{ .key = Key.init(key) catch {
            a.destroy(row);
            return null;
        }, .payload = payload.retain(), .revision = revision, .last_use = last_use };
        // Retain before removing a prior row: replacement may share textures.
        self.retainTexture(payload.coverage);
        for (payload.colors) |layer| self.retainTexture(layer.texture);
        const old = self.rows.fetchPut(a, key.absolute_row, row) catch {
            self.destroyRow(row);
            return null;
        };
        if (old) |previous| self.destroyRow(previous.value);
        return row;
    }
    pub fn lookup(self: *Cache, key: *const c.CmdyGpuRowKey, dirty: bool, revision: c.CmdyGpuRowRevision, inputs: ?*const c.CmdyRenderRowInput) ?*Row {
        const row = self.rows.get(key.absolute_row) orelse return null;
        if (!row.key.equal(key, true)) return null;
        if (dirty) {
            if (revision.content == 0 or revision.context == 0 or revision.content != key.version or !std.meta.eql(revision, row.revision)) return null;
            const previous = row.payload.inputs orelse return null;
            if (!previous.equal(inputs orelse return null)) return null;
        }
        row.last_use = self.tick();
        _ = reused.fetchAdd(1, .monotonic);
        return row;
    }
    pub fn resolve(self: *Cache, key: *const c.CmdyGpuRowKey, revision: c.CmdyGpuRowRevision, input: *const c.CmdyRenderRowInput, images: []const c.CmdyGpuImagePlacement, placeholders: []const c.CmdyGpuPlaceholder) ?*Row {
        return self.resolveWithPaint(key, revision, input, images, placeholders, null);
    }
    fn resolveWithPaint(self: *Cache, key: *const c.CmdyGpuRowKey, revision: c.CmdyGpuRowRevision, input: *const c.CmdyRenderRowInput, images: []const c.CmdyGpuImagePlacement, placeholders: []const c.CmdyGpuPlaceholder, paint: ?*const @import("render_shaper.zig").FrozenPaintResult) ?*Row {
        const key_started = trace.now();
        var text_key: ?*anyopaque = null;
        if (images.len == 0 and placeholders.len == 0 and input.block_count == 0 and input.box_count == 0) text_key = if (paint) |value| @ptrCast(text_module.keyCreatePaint(@ptrCast(input), value)) else cmdy_render_text_key_create(input);
        if (trace.enabled()) trace.record("row.sharedKey", key_started, &.{ .{ .name = "row", .value = key.absolute_row }, .{ .name = "shareable", .value = @intFromBool(text_key != null) } });
        const lookup_started = trace.now();
        var actual_revision = c.CmdyGpuRowRevision{ .content = 0, .context = 0 };
        if (text_key != null and revision.content == key.version and revision.content != 0 and revision.context != 0) actual_revision = revision;
        if (text_key) |key_object| {
            var iterator = self.rows.valueIterator();
            while (iterator.next()) |entry| {
                const row = entry.*;
                if (row.key.equal(key, false) and row.payload.text_key != null and cmdy_render_text_key_equal(key_object, row.payload.text_key) != 0) {
                    if (trace.enabled()) trace.record("row.sharedLookup", lookup_started, &.{ .{ .name = "row", .value = key.absolute_row }, .{ .name = "reused", .value = 1 } });
                    cmdy_render_text_key_free(key_object);
                    _ = reused.fetchAdd(1, .monotonic);
                    return self.store(key, row.payload, actual_revision, self.tick());
                }
            }
        }
        if (trace.enabled()) trace.record("row.sharedLookup", lookup_started, &.{ .{ .name = "row", .value = key.absolute_row }, .{ .name = "reused", .value = 0 } });
        const entry_started = trace.now();
        defer if (trace.enabled()) trace.record("row.entry", entry_started, &.{ .{ .name = "row", .value = key.absolute_row }, .{ .name = "widthPixels", .value = key.width }, .{ .name = "heightPixels", .value = key.height } });
        const p = a.create(Payload) catch {
            cmdy_render_text_key_free(text_key);
            return null;
        };
        p.* = .{ .text_key = text_key, .inputs = Inputs.init(input) };
        defer p.release();
        self.glyphs.reserveCustom(input);
        const raster_started = trace.now();
        p.raster = @ptrCast((if (paint) |value| text_module.createWithPaint(@ptrCast(input), &self.ascii_lines, value) else text_module.createWithCache(@ptrCast(input), &self.ascii_lines)) orelse return null);
        var cpu: c.CmdyRenderRowView = undefined;
        c.cmdy_render_row_view(p.raster, &cpu);
        if (trace.enabled()) trace.record("row.raster", raster_started, &.{ .{ .name = "row", .value = key.absolute_row }, .{ .name = "backgrounds", .value = @intCast(cpu.background_count) }, .{ .name = "glyphSeeds", .value = @intCast(cpu.glyph_count) }, .{ .name = "decorations", .value = @intCast(cpu.decoration_count) } });
        p.width = cpu.width;
        p.height = cpu.height;
        const coverage = slice(u8, cpu.coverage, cpu.coverage_count);
        const stored_width = coverage_storage.width(coverage, @intCast(cpu.width), @intCast(cpu.height), cpu.glyph_count != 0);
        if (stored_width != 0) {
            // Geometry and tint spans remain in full row coordinates. UVs use
            // the stored texture width; its final transparent column preserves
            // samples in the omitted blank tail without copying CPU pixels.
            p.width = @intCast(stored_width);
            p.coverage = makeTexture(self.device, p.width, cpu.height, 10, coverage, cpu.width);
        }
        var colors: std.ArrayList(c.CmdyGpuColorLayer) = .empty;
        defer colors.deinit(a);
        for (slice(c.CmdyRenderColorTile, cpu.color_tiles, cpu.color_tile_count)) |tile| {
            const texture = makeTexture(self.device, tile.width, tile.height, 80, slice(u8, tile.bytes, tile.byte_count), tile.width * 4) orelse continue;
            colors.append(a, .{ .texture = texture, .rect = tile.rect }) catch {
                c.cmdy_gpu_apple_release(texture);
                return null;
            };
        }
        p.colors = colors.toOwnedSlice(a) catch return null;
        p.backgrounds = a.dupe(c.CmdyRenderSolid, slice(c.CmdyRenderSolid, cpu.backgrounds, cpu.background_count)) catch return null;
        p.tints = a.dupe(c.CmdyRenderTint, slice(c.CmdyRenderTint, cpu.tints, cpu.tint_count)) catch return null;
        p.decorations = a.dupe(c.CmdyRenderSolid, slice(c.CmdyRenderSolid, cpu.decorations, cpu.decoration_count)) catch return null;
        // Only DEC line modes draw these atlas glyphs. Mode participates in
        // both row-identity and shared-content keys, so a later mode change
        // rebuilds this payload before it can need the atlas.
        if (key.line_mode != 0) {
            var atlas: std.ArrayList(c.CmdyGpuAtlasGlyph) = .empty;
            defer atlas.deinit(a);
            for (slice(c.CmdyRenderGlyphSeed, cpu.glyphs, cpu.glyph_count)) |seed| {
                const atlas_rect = self.glyphs.lineGlyph(seed.font, seed.glyph, key.preset) orelse continue;
                atlas.append(a, .{ .rect = seed.rect, .atlas_rect = atlas_rect, .color = seed.color }) catch return null;
            }
            p.atlas_glyphs = atlas.toOwnedSlice(a) catch return null;
        }
        p.images = copyImages(images) catch return null;
        p.placeholders = a.dupe(c.CmdyGpuPlaceholder, placeholders) catch return null;
        // Row metadata and GPU uploads are immutable now. Coverage bytes and
        // temporary CoreText/font arrays belong to the build, not residency.
        c.cmdy_render_row_free(p.raster);
        p.raster = null;
        const row = self.store(key, p, actual_revision, self.tick()) orelse return null;
        _ = rebuilt.fetchAdd(1, .monotonic);
        return row;
    }
    /// Reuse requires the same immutable text handle and all image/placeholder
    /// content, not merely a producer revision that may exclude graphics.
    pub fn resolveCaptured(self: *Cache, input: *const c.CmdyRenderFrameRowInput) ?*Row {
        const text = input.text orelse return null;
        const view = c.cmdy_render_input_prepare(text, null) orelse return null;
        const images = slice(c.CmdyRenderFrameImageInput, input.images, input.image_count);
        const supplied = slice(c.CmdyGpuPlaceholder, input.placeholders, input.placeholder_count);
        var decoded_count: usize = 0;
        const decoded_pointer = c.cmdy_render_input_placeholders(text, &decoded_count);
        const decoded = slice(c.CmdyShapePlaceholder, decoded_pointer, decoded_count);
        const total_placeholders = std.math.add(usize, supplied.len, decoded.len) catch return null;
        if (self.rows.get(input.key.absolute_row)) |row| {
            if (row.key.equal(&input.key, true) and row.captured_text == text and
                capturedImagesEqual(row.payload.images, images) and row.payload.placeholders.len == total_placeholders and
                placeholdersEqual(row.payload.placeholders[0..supplied.len], supplied))
            {
                // Decoded placeholders belong to the same immutable text handle.
                row.last_use = self.tick();
                _ = reused.fetchAdd(1, .monotonic);
                return row;
            }
        }
        const combined = if (decoded.len != 0) a.alloc(c.CmdyGpuPlaceholder, total_placeholders) catch return null else null;
        defer if (combined) |items| a.free(items);
        if (combined) |items| {
            @memcpy(items[0..supplied.len], supplied);
            for (decoded, items[supplied.len..]) |source, *dest| {
                dest.* = .{ .image_id = source.image_id, .placement_id = source.placement_id, .row = source.row, .col = source.col, .placeholder_row = source.placeholder_row, .placeholder_col = source.placeholder_col, .msb = source.msb };
            }
        }
        const placeholders: []const c.CmdyGpuPlaceholder = combined orelse supplied;
        const bound = a.alloc(c.CmdyGpuImagePlacement, images.len) catch return null;
        defer a.free(bound);
        for (images, bound) |source, *dest| {
            dest.* = source.placement;
            dest.owned_image = source.payload;
        }
        const row = self.resolve(&input.key, input.revision, view, bound, placeholders) orelse return null;
        const retained = c.cmdy_render_input_retain(text);
        c.cmdy_render_input_release(row.captured_text);
        row.captured_text = retained;
        return row;
    }
    /// Traverse immutable engine rows on the GPU owner. A complete native key,
    /// exact resolved style, raster settings and frozen image geometry guard
    /// reuse before shaping; unchanged rows allocate nothing here.
    pub fn resolveViewport(self: *Cache, viewport: *const viewport_module.Viewport, request: @import("render_geometry.zig").VisibleRow) ?*Row {
        const key: c.CmdyGpuRowKey = @bitCast(viewport.key(request));
        const line = viewport.line(request.source_row);
        const style_row = std.math.cast(isize, @as(i128, request.source_row) + viewport.settings.style_row_offset) orelse return null;
        const images: []const *LineImage = if (line.images) |items| items.items else &.{};
        if (key.version != 0) if (self.rows.get(key.absolute_row)) |row| {
            if (row.key.equal(&key, true) and row.viewport_style == viewport.style and
                row.viewport_source_row == request.source_row and row.viewport_style_row == style_row and row.payload.inputs != null and row.viewport_raster != null and
                (row.viewport_raster == viewport.raster or
                    (viewportRasterScalarsEqual(row.viewport_raster.?, viewport.raster) and
                        row.payload.inputs.?.equal(@ptrCast(&viewport.raster.input)))) and viewportImagesEqual(row.payload.images, images))
            {
                // Retained immutable parameters need no repeated platform font
                // or color comparison. Adopt an equivalent new packet once so
                // subsequent animation frames take the same identity path.
                if (row.viewport_raster != viewport.raster) {
                    const previous = row.viewport_raster.?;
                    row.viewport_raster = viewport.raster.retain();
                    previous.release();
                }
                row.last_use = self.tick();
                _ = reused.fetchAdd(1, .monotonic);
                return row;
            }
        };
        var private_row: ?*Row = null;
        if (images.len == 0) {
            if (@import("render_shaper.zig").shapeFrozenPaint(line, style_row, viewport.style.style) catch return null) |paint| {
                defer paint.free();
                var input = viewport.raster.input;
                input.segments = @ptrCast(paint.result.segments.items.ptr);
                input.segment_count = paint.result.segments.items.len;
                private_row = self.resolveWithPaint(&key, .{ .content = 0, .context = 0 }, @ptrCast(&input), &.{}, &.{}, paint) orelse return null;
            }
        }
        const row = private_row orelse legacy: {
        const owned_text = @import("render_input.zig").Owned.createViewportRow(line, request.source_row, style_row, viewport.style, viewport.raster) catch return null;
        const text: *c.CmdyRenderOwnedRowInput = @ptrCast(owned_text);
        defer c.cmdy_render_input_release(text);
        const frozen_images = a.alloc(c.CmdyRenderFrameImageInput, images.len) catch return null;
        var retained: usize = 0;
        defer {
            for (frozen_images[0..retained]) |image| c.cmdy_render_image_input_release(image.payload);
            a.free(frozen_images);
        }
        for (images, frozen_images) |image, *dest| {
            const owner = captured.Image.share(a, image.payload, image.render_uuid) catch return null;
            dest.* = .{ .payload = @ptrCast(owner), .placement = viewportImagePlacement(image) };
            retained += 1;
        }
        var input = std.mem.zeroes(c.CmdyRenderFrameRowInput);
        input.key = key;
        input.font_name_bytes = viewport.name.len;
        input.text = text;
        input.images = frozen_images.ptr;
        input.image_count = frozen_images.len;
            break :legacy self.resolveCaptured(&input) orelse return null;
        };
        if (row.viewport_style) |old| old.release();
        row.viewport_style = viewport.style.retain();
        if (row.viewport_raster) |old| old.release();
        row.viewport_raster = viewport.raster.retain();
        row.viewport_source_row = request.source_row;
        row.viewport_style_row = style_row;
        return row;
    }
    pub fn importRow(self: *Cache, key: *const c.CmdyGpuRowKey, v: *const c.CmdyGpuRowView) ?*Row {
        const p = a.create(Payload) catch return null;
        p.* = .{ .width = v.width, .height = v.height, .coverage = c.cmdy_gpu_apple_retain(v.coverage_texture) };
        defer p.release();
        p.colors = a.dupe(c.CmdyGpuColorLayer, slice(c.CmdyGpuColorLayer, v.color_layers, v.color_layer_count)) catch return null;
        for (p.colors) |*layer| layer.texture = c.cmdy_gpu_apple_retain(layer.texture);
        p.backgrounds = a.dupe(c.CmdyRenderSolid, slice(c.CmdyRenderSolid, v.backgrounds, v.background_count)) catch return null;
        p.tints = a.dupe(c.CmdyRenderTint, slice(c.CmdyRenderTint, v.tints, v.tint_count)) catch return null;
        p.atlas_glyphs = a.dupe(c.CmdyGpuAtlasGlyph, slice(c.CmdyGpuAtlasGlyph, v.atlas_glyphs, v.atlas_glyph_count)) catch return null;
        p.decorations = a.dupe(c.CmdyRenderSolid, slice(c.CmdyRenderSolid, v.decorations, v.decoration_count)) catch return null;
        p.images = copyImages(slice(c.CmdyGpuImagePlacement, v.images, v.image_count)) catch return null;
        p.placeholders = a.dupe(c.CmdyGpuPlaceholder, slice(c.CmdyGpuPlaceholder, v.placeholders, v.placeholder_count)) catch return null;
        self.clock = @max(self.clock, v.last_use);
        return self.store(key, p, .{ .content = 0, .context = 0 }, v.last_use);
    }
    /// Alternate rows outside the captured buffer's retained range cannot be
    /// displayed again. Keep valid fringe rows and primary scrollback entries;
    /// frame-owned Row references survive removal of cache ownership.
    pub fn pruneAlternate(self: *Cache, origin: isize, count: isize) void {
        var obsolete: std.ArrayList(isize) = .empty;
        defer obsolete.deinit(a);
        var iterator = self.rows.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.*.key.value.alternate_buffer == 0) continue;
            const offset = @as(i128, entry.key_ptr.*) - @as(i128, origin);
            if (offset < 0 or offset >= @as(i128, count))
                obsolete.append(a, entry.key_ptr.*) catch return;
        }
        // Collect first: allocation failure leaves cache ownership unchanged,
        // and removal never invalidates a live hash-map iterator.
        for (obsolete.items) |key| {
            if (self.rows.fetchRemove(key)) |entry| self.destroyRow(entry.value);
        }
    }
    pub fn trim(self: *Cache, visible: []const isize, visible_count: usize) void {
        const limit = @max(1, visible_count *| 3);
        const budget = 20 * 1024 * 1024;
        if (self.rows.count() <= limit and self.allocated_bytes <= budget) return;
        const Victim = struct { row: isize, last_use: u64 };
        var candidates: std.ArrayList(Victim) = .empty;
        defer candidates.deinit(a);
        var iterator = self.rows.iterator();
        while (iterator.next()) |entry| {
            if (std.mem.indexOfScalar(isize, visible, entry.key_ptr.*) == null) candidates.append(a, .{ .row = entry.key_ptr.*, .last_use = entry.value_ptr.*.last_use }) catch return;
        }
        std.mem.sort(Victim, candidates.items, {}, struct {
            fn less(_: void, l: Victim, r: Victim) bool {
                return if (l.last_use == r.last_use) l.row < r.row else l.last_use < r.last_use;
            }
        }.less);
        for (candidates.items) |candidate| {
            if (self.rows.count() <= limit and self.allocated_bytes <= budget) break;
            if (self.rows.fetchRemove(candidate.row)) |entry| self.destroyRow(entry.value);
        }
    }
};
fn viewportImagePlacement(image: *const LineImage) c.CmdyGpuImagePlacement {
    return .{ .owner = null, .image = null, .owned_image = null, .col = image.col, .z_index = image.z_index, .width = image.pixel_width, .height = image.pixel_height, .offset_x = image.offset_x, .offset_y = image.offset_y, .kitty_image_id = image.image_id orelse 0, .has_kitty_id = @intFromBool(image.image_id != null), .is_kitty = @intFromBool(image.is_kitty),
        .cell_cols = image.cell_cols, .cell_rows = image.cell_rows, .source_x = image.source_x, .source_y = image.source_y,
        .source_width = image.source_width, .source_height = image.source_height };
}
fn viewportRasterScalarsEqual(left: *const FrozenParameters, right: *const FrozenParameters) bool {
    var l = left.input;
    var r = right.input;
    // Inputs.equal compares full platform font equality and resolved color.
    l.normal_font = null;
    l.foreground = null;
    r.normal_font = null;
    r.foreground = null;
    return std.meta.eql(l, r);
}
fn viewportImagesEqual(previous: []const c.CmdyGpuImagePlacement, images: []const *LineImage) bool {
    if (previous.len != images.len) return false;
    for (previous, images) |old, image| {
        const handle: *const captured.Image = @ptrCast(@alignCast(old.owned_image orelse return false));
        if (handle.payload_owner != image.payload or !std.mem.eql(u8, &handle.view.identity, &image.render_uuid)) return false;
        var placement = old;
        placement.owned_image = null;
        if (!std.meta.eql(placement, viewportImagePlacement(image))) return false;
    }
    return true;
}
fn copyImages(images: []const c.CmdyGpuImagePlacement) ![]c.CmdyGpuImagePlacement {
    const result = try a.dupe(c.CmdyGpuImagePlacement, images);
    for (result) |*image| {
        if (image.owned_image != null) {
            image.owner = null;
            image.image = null;
            image.owned_image = c.cmdy_render_image_input_retain(image.owned_image);
        } else {
            image.owner = c.cmdy_gpu_apple_weak_create(image.owner);
            image.image = c.cmdy_gpu_apple_retain(image.image);
        }
    }
    return result;
}
fn capturedImagesEqual(previous: []const c.CmdyGpuImagePlacement, incoming: []const c.CmdyRenderFrameImageInput) bool {
    if (previous.len != incoming.len) return false;
    for (previous, incoming) |old, new| {
        var bound = new.placement;
        bound.owned_image = new.payload;
        if (!std.meta.eql(old, bound)) return false;
    }
    return true;
}
fn placeholdersEqual(previous: []const c.CmdyGpuPlaceholder, incoming: []const c.CmdyGpuPlaceholder) bool {
    if (previous.len != incoming.len) return false;
    for (previous, incoming) |old, new| if (!std.meta.eql(old, new)) return false;
    return true;
}
pub fn makeTexture(device: ?*const anyopaque, width: isize, height: isize, format: u64, bytes: []const u8, bytes_per_row: isize) ?*anyopaque {
    if (width <= 0 or height <= 0 or bytes_per_row <= 0) return null;
    const total = std.math.mul(usize, @intCast(bytes_per_row), @intCast(height)) catch return null;
    if (bytes.len < total) return null;
    const texture = c.cmdy_gpu_apple_texture(device, @intCast(width), @intCast(height), 0, format, 0, 0) orelse return null;
    c.cmdy_gpu_apple_texture_write(texture, 0, 0, @intCast(width), @intCast(height), 0, bytes.ptr, @intCast(bytes_per_row));
    return texture;
}
