//! Frame composition is native: paint order, clipping, UV transforms, cursor
//! inversion, and shader passes are encoded here, never in the Apple bridge.
const std = @import("std");
const cache = @import("render_cache.zig");
const c = cache.c;
const geo = @import("render_geometry.zig");
const trace = @import("render_trace.zig");
const a = std.heap.c_allocator;
const Rect = geo.Rect;
const Color = c.CmdyRenderColor;
const Vertex = extern struct { position: [2]f32, uv: [2]f32, color: [4]f32 };
const Raster = extern struct { resolution: [2]f32, coverage_power: f32, databloom_energy: f32 };
const Uniforms = extern struct { resolution: [2]f32, time: f32, curvature: f32, background: [4]f32, cursor: [2]f32, key_age: f32, typing_rate: f32, opacity: f32, pass_index: u32, padding: [2]u32 = .{ 0, 0 } };
const Databloom = extern struct { energy: f32, velocity: f32, opacity: f32, pass_index: f32 };
fn rect(r: c.CmdyRenderRect) Rect {
    return .{ .x = r.x, .y = r.y, .width = r.width, .height = r.height };
}
fn vector(color: Color) [4]f32 {
    return .{ color.r, color.g, color.b, color.a };
}
fn minX(r: Rect) f64 {
    return @min(r.x, r.x + r.width);
}
fn maxX(r: Rect) f64 {
    return @max(r.x, r.x + r.width);
}
fn minY(r: Rect) f64 {
    return @min(r.y, r.y + r.height);
}
fn maxY(r: Rect) f64 {
    return @max(r.y, r.y + r.height);
}
fn intersect(l: Rect, r: Rect) ?Rect {
    const x = @max(minX(l), minX(r));
    const y = @max(minY(l), minY(r));
    const w = @min(maxX(l), maxX(r)) - x;
    const h = @min(maxY(l), maxY(r)) - y;
    if (w <= 0 or h <= 0) return null;
    return .{ .x = x, .y = y, .width = w, .height = h };
}
fn quad(r: Rect, uv: Rect, color: Color, preserve: bool) [6]Vertex {
    const x0: f32 = @floatCast(minX(r));
    const x1: f32 = @floatCast(maxX(r));
    const y0: f32 = @floatCast(minY(r));
    const y1: f32 = @floatCast(maxY(r));
    const uv_x0: f32 = @floatCast(if (preserve) uv.x else minX(uv));
    const uv_x1: f32 = @floatCast(if (preserve) uv.x + uv.width else maxX(uv));
    const uv_y0: f32 = @floatCast(if (preserve) uv.y else minY(uv));
    const uv_y1: f32 = @floatCast(if (preserve) uv.y + uv.height else maxY(uv));
    const col = vector(color);
    return .{ .{ .position = .{ x0, y0 }, .uv = .{ uv_x0, uv_y0 }, .color = col }, .{ .position = .{ x1, y0 }, .uv = .{ uv_x1, uv_y0 }, .color = col }, .{ .position = .{ x0, y1 }, .uv = .{ uv_x0, uv_y1 }, .color = col }, .{ .position = .{ x1, y0 }, .uv = .{ uv_x1, uv_y0 }, .color = col }, .{ .position = .{ x1, y1 }, .uv = .{ uv_x1, uv_y1 }, .color = col }, .{ .position = .{ x0, y1 }, .uv = .{ uv_x0, uv_y1 }, .color = col } };
}
const full_uv = Rect{ .width = 1, .height = 1 };
const white = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
fn uvRect(r: Rect, width: isize, height: isize, flipped: bool) Rect {
    if (width <= 0 or height <= 0) return .{};
    const w: f64 = @floatFromInt(width);
    const h: f64 = @floatFromInt(height);
    const value = Rect{ .x = minX(r) / w, .y = minY(r) / h, .width = r.width / w, .height = r.height / h };
    return if (flipped) .{ .x = value.x, .y = value.y + value.height, .width = value.width, .height = -value.height } else value;
}
fn glyphSpan(source: Rect, index: isize, mode: u32, x: f64, y: f64, cell_height: f64) ?struct { destination: Rect, sample: Rect } {
    const row_y = y + @as(f64, @floatFromInt(index)) * cell_height;
    if (mode == 0 or mode == 1) {
        const horizontal: f64 = if (mode == 0) 1 else 2;
        return .{ .destination = .{ .x = x + minX(source) * horizontal, .y = row_y + minY(source), .width = source.width * horizontal, .height = source.height }, .sample = source };
    }
    var unbounded = Rect{ .x = x + minX(source) * 2, .y = row_y + minY(source) * 2, .width = source.width * 2, .height = source.height * 2 };
    if (mode == 3) unbounded.y -= cell_height;
    const destination = intersect(unbounded, .{ .x = unbounded.x, .y = row_y, .width = unbounded.width, .height = cell_height }) orelse return null;
    if (unbounded.height <= 0) return null;
    const top = (minY(destination) - minY(unbounded)) / unbounded.height;
    const fraction = destination.height / unbounded.height;
    return .{ .destination = destination, .sample = .{ .x = minX(source), .y = minY(source) + source.height * top, .width = source.width, .height = source.height * fraction } };
}
const Encoding = struct {
    encoder: ?*const anyopaque,
    ring: ?*c.CmdyRenderBufferRing,
    resolution: [2]f32,
    fn vertices(self: Encoding, values: []const Vertex) bool {
        if (values.len == 0) return false;
        var offset: usize = 0;
        const buffer = c.cmdy_render_buffer_ring_write(self.ring, values.ptr, values.len * @sizeOf(Vertex), &offset) orelse return false;
        c.cmdy_gpu_apple_encoder_vertex_buffer(self.encoder, buffer, offset, 0);
        return true;
    }
    fn bytes(self: Encoding, value: anytype, index: usize, fragment: bool) void {
        c.cmdy_gpu_apple_encoder_bytes(self.encoder, &value, @sizeOf(@TypeOf(value)), index, @intFromBool(fragment));
    }
    fn raster(self: Encoding, power: f32, energy: f32) Raster {
        return .{ .resolution = self.resolution, .coverage_power = power, .databloom_energy = energy };
    }
    fn solid(self: Encoding, core: anytype, values: []const Vertex) void {
        if (!self.vertices(values)) return;
        c.cmdy_gpu_apple_encoder_pipeline(self.encoder, core.solid);
        self.bytes(self.raster(1, 0), 1, false);
        c.cmdy_gpu_apple_encoder_draw(self.encoder, values.len);
    }
    fn texture(self: Encoding, core: anytype, texture_value: ?*const anyopaque, destination: Rect, uv: Rect, flipped: bool, color: Color) void {
        var vertices_value = quad(destination, uv, color, false);
        if (flipped) for (&vertices_value) |*v| {
            v.uv[1] = 1 - v.uv[1];
        };
        if (!self.vertices(&vertices_value)) return;
        c.cmdy_gpu_apple_encoder_pipeline(self.encoder, core.image);
        self.bytes(self.raster(1, 0), 1, false);
        c.cmdy_gpu_apple_encoder_texture(self.encoder, texture_value, 0);
        c.cmdy_gpu_apple_encoder_sampler(self.encoder, core.linear, 0);
        c.cmdy_gpu_apple_encoder_draw(self.encoder, 6);
    }
    fn coverageTexture(self: Encoding, core: anytype, texture_value: ?*const anyopaque, destination: Rect, uv: Rect, color: Color, power: f32) void {
        const vertices_value = quad(destination, uv, color, false);
        if (!self.vertices(&vertices_value)) return;
        c.cmdy_gpu_apple_encoder_pipeline(self.encoder, core.coverage);
        const u = self.raster(power, 0);
        self.bytes(u, 1, false);
        self.bytes(u, 0, true);
        c.cmdy_gpu_apple_encoder_texture(self.encoder, texture_value, 0);
        c.cmdy_gpu_apple_encoder_sampler(self.encoder, core.linear, 0);
        c.cmdy_gpu_apple_encoder_draw(self.encoder, 6);
    }
};
// Keep triangle order while amortizing vertex uploads and draw submission.
// Flush before changing texture, pipeline or uniforms. Storage is stack bounded.
const QuadBatch = struct {
    values: [64 * 6]Vertex = undefined,
    count: usize = 0,
    fn append(self: *QuadBatch, e: Encoding, values: *const [6]Vertex) void {
        @memcpy(self.values[self.count..][0..6], values);
        self.count += 6;
        if (self.count == self.values.len) self.flush(e);
    }
    fn flush(self: *QuadBatch, e: Encoding) void {
        if (self.count == 0) return;
        const values = self.values[0..self.count];
        if (e.vertices(values)) {
            c.cmdy_gpu_apple_encoder_draw(e.encoder, values.len);
        } else {
            // Preserve the smaller upload path if a larger arena cannot grow.
            var i: usize = 0;
            while (i < values.len) : (i += 6) {
                if (e.vertices(values[i..][0..6])) c.cmdy_gpu_apple_encoder_draw(e.encoder, 6);
            }
        }
        self.count = 0;
    }
};
fn rowValue(v: c.CmdyGpuFrameRow) *const cache.Row {
    return @ptrCast(@alignCast(v.entry.?));
}
fn transform(r: Rect, row: c.CmdyGpuFrameRow, x: f64, y: f64, height: f64) Rect {
    return geo.lineModeRect(r, row.display_index, row.line_mode, x, y, height);
}
// Adjacent ordinary tint cells share one coverage texture and affine UV map.
// Restrict merging to finite integer geometry; preserve DEC/Databloom ordering.
fn mergeCoverageRect(left: Rect, right: Rect) ?Rect {
    inline for (.{ "x", "y", "width", "height" }) |name| {
        const l = @field(left, name);
        const r = @field(right, name);
        if (!std.math.isFinite(l) or !std.math.isFinite(r) or l != @floor(l) or r != @floor(r) or @abs(l) > 1_000_000 or @abs(r) > 1_000_000) return null;
    }
    if (left.width <= 0 or right.width <= 0 or left.height <= 0 or
        left.y != right.y or left.height != right.height or left.x + left.width != right.x or
        left.width + right.width > 1_000_000) return null;
    return .{ .x = left.x, .y = left.y, .width = left.width + right.width, .height = left.height };
}
fn encodeCoverage(self: anytype, row: c.CmdyGpuFrameRow, e: Encoding, f: *const c.CmdyGpuFrame, x: f64, y: f64) void {
    const p = rowValue(row).payload;
    const texture = p.coverage orelse return;
    const bloom = f.shader_mode == 68;
    c.cmdy_gpu_apple_encoder_pipeline(e.encoder, if (bloom) self.core.databloom else self.core.coverage);
    c.cmdy_gpu_apple_encoder_sampler(e.encoder, if (self.preset == 3) self.core.nearest else self.core.linear, 0);
    c.cmdy_gpu_apple_encoder_texture(e.encoder, texture, 0);
    const power = self.coveragePower();
    if (bloom) {
        e.bytes(@as(f32, 1) / @max(@as(f32, 0.1), power), 0, true);
        e.bytes(Databloom{ .energy = f.shader_energy, .velocity = f.shader_velocity, .opacity = 1, .pass_index = 0 }, 1, true);
    } else e.bytes(e.raster(power, 0), 0, true);
    e.bytes(e.raster(power, f.shader_energy), 1, false);
    const atlas = self.glyphs.lineTexture();
    const uses_atlas = row.line_mode != 0 and p.atlas_glyphs.len != 0 and atlas != null;
    var batch: QuadBatch = .{};
    if (uses_atlas) {
        c.cmdy_gpu_apple_encoder_texture(e.encoder, atlas, 0);
        for (p.atlas_glyphs) |glyph| {
            const source = rect(glyph.rect);
            const span = glyphSpan(source, row.display_index, row.line_mode, x, y, f.cell_height) orelse continue;
            if (source.width <= 0 or source.height <= 0) continue;
            const ar = rect(glyph.atlas_rect);
            const xf = (minX(span.sample) - minX(source)) / source.width;
            const yf = (minY(span.sample) - minY(source)) / source.height;
            const wf = span.sample.width / source.width;
            const hf = span.sample.height / source.height;
            const sample = Rect{ .x = minX(ar) + ar.width * xf, .y = maxY(ar) - ar.height * (yf + hf), .width = ar.width * wf, .height = ar.height * hf };
            const vertices_value = quad(span.destination, uvRect(sample, 1024, 1024, true), glyph.color, true);
            if (bloom) {
                if (!e.vertices(&vertices_value)) continue;
                c.cmdy_gpu_apple_encoder_draw(e.encoder, 6);
            } else batch.append(e, &vertices_value);
        }
        batch.flush(e);
        c.cmdy_gpu_apple_encoder_texture(e.encoder, texture, 0);
    }
    var tint_index: usize = 0;
    while (tint_index < p.tints.len) {
        const tint = p.tints[tint_index];
        tint_index += 1;
        if (uses_atlas and tint.replaced_by_atlas != 0) continue;
        var source = rect(if (row.line_mode != 0 and tint.has_envelope != 0) tint.envelope else tint.rect);
        const row_y = y + @as(f64, @floatFromInt(row.display_index)) * f.cell_height;
        if (!bloom and row.line_mode == 0 and std.math.isFinite(x) and std.math.isFinite(row_y) and x == @floor(x) and row_y == @floor(row_y)) {
            while (tint_index < p.tints.len) {
                const next = p.tints[tint_index];
                if (!std.meta.eql(tint.color, next.color)) break;
                source = mergeCoverageRect(source, rect(next.rect)) orelse break;
                tint_index += 1;
            }
        }
        const span = glyphSpan(source, row.display_index, row.line_mode, x, y, f.cell_height) orelse continue;
        const uv = uvRect(span.sample, p.width, p.height, true);
        var vertices_value = quad(span.destination, uv, tint.color, false);
        if (!bloom) {
            batch.append(e, &vertices_value);
            continue;
        }
        if (!e.vertices(&vertices_value)) continue;
        c.cmdy_gpu_apple_encoder_draw(e.encoder, 6);
        if (bloom and f.shader_energy > 0.01) {
            e.bytes(Databloom{ .energy = f.shader_energy, .velocity = f.shader_velocity, .opacity = f.shader_energy * 0.7, .pass_index = 1 }, 1, true);
            var shifted = span.destination;
            shifted.x += @as(f64, @floatCast(@max(@as(f32, -10), @min(@as(f32, 10), f.shader_velocity * 0.012))));
            vertices_value = quad(shifted, uv, tint.color, false);
            if (e.vertices(&vertices_value)) c.cmdy_gpu_apple_encoder_draw(e.encoder, 6);
        }
    }
    batch.flush(e);
}
pub fn kittyFit(width: f64, height: f64, container: Rect) Rect {
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0 or !std.math.isFinite(container.width) or !std.math.isFinite(container.height) or container.width <= 0 or container.height <= 0) return .{};
    const factor = @min(container.width / width, container.height / height);
    const w = width * factor;
    const h = height * factor;
    return .{ .x = container.x + (container.width - w) / 2, .y = container.y + (container.height - h) / 2, .width = w, .height = h };
}
fn encodeKitty(self: anytype, e: Encoding, f: *const c.CmdyGpuFrame, x: f64, y: f64) void {
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| for (rowValue(row).payload.placeholders) |placeholder| {
        var input: ?c.CmdyGpuKittyImage = null;
        for (cache.slice(c.CmdyGpuKittyImage, f.kitty_images, f.kitty_image_count)) |image| if (image.image_id == placeholder.image_id) {
            input = image;
            break;
        };
        const texture = self.images.kittyTexture(input orelse continue) orelse continue;
        var placement: ?c.CmdyGpuKittyPlacement = null;
        for (cache.slice(c.CmdyGpuKittyPlacement, f.kitty_placements, f.kitty_placement_count)) |v| if (v.image_id == placeholder.image_id and v.placement_id == placeholder.placement_id) {
            placement = v;
        };
        const spec = placement orelse continue;
        const scale = if (std.math.isFinite(f.scale)) @max(0, f.scale) else 1;
        const container = Rect{ .x = x + @as(f64, @floatFromInt(placeholder.col - placeholder.placeholder_col)) * f.cell_width + @as(f64, @floatFromInt(spec.offset_x)) * scale, .y = y + @as(f64, @floatFromInt(placeholder.row - placeholder.placeholder_row - f.display_top_row)) * f.cell_height - @as(f64, @floatFromInt(spec.offset_y)) * scale, .width = @as(f64, @floatFromInt(@max(1, spec.cols))) * f.cell_width, .height = @as(f64, @floatFromInt(@max(1, spec.rows))) * f.cell_height };
        const fitted = kittyFit(@floatFromInt(c.cmdy_gpu_apple_texture_width(texture)), @floatFromInt(c.cmdy_gpu_apple_texture_height(texture)), container);
        const cell = Rect{ .x = x + @as(f64, @floatFromInt(placeholder.col)) * f.cell_width, .y = y + @as(f64, @floatFromInt(placeholder.row - f.display_top_row)) * f.cell_height, .width = f.cell_width, .height = f.cell_height };
        const visible = intersect(fitted, cell) orelse continue;
        if (fitted.width <= 0 or fitted.height <= 0) continue;
        const uv = Rect{ .x = (visible.x - fitted.x) / fitted.width, .y = (visible.y - fitted.y) / fitted.height, .width = visible.width / fitted.width, .height = visible.height / fitted.height };
        e.texture(self.core, texture, visible, uv, true, white);
    };
}
fn encodeRows(self: anytype, e: Encoding, f: *const c.CmdyGpuFrame, x: f64, y: f64) void {
    const background_started = trace.now();
    var backgrounds: std.ArrayList(Vertex) = .empty;
    defer backgrounds.deinit(a);
    var selections: std.ArrayList(Vertex) = .empty;
    defer selections.deinit(a);
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| {
        const selection = if (row.has_selection != 0) geo.selectionRect(row.selection_lower, row.selection_upper, f.grid_cols, f.cell_width, f.cell_height) else null;
        for (rowValue(row).payload.backgrounds) |solid| {
            var fragments: [2]Rect = undefined;
            const count = geo.backgroundFragments(rect(solid.rect), selection, &fragments);
            for (fragments[0..count]) |fragment| backgrounds.appendSlice(a, &quad(transform(fragment, row, x, y, f.cell_height), full_uv, solid.color, false)) catch {};
        }
        if (selection) |selected| selections.appendSlice(a, &quad(transform(selected, row, x, y, f.cell_height), full_uv, f.selection, false)) catch {};
    }
    backgrounds.appendSlice(a, selections.items) catch {};
    e.solid(self.core, backgrounds.items);
    if (trace.enabled()) trace.record("draw.backgroundEncoding", background_started, &.{ .{ .name = "rows", .value = @intCast(f.row_count) }, .{ .name = "quads", .value = @intCast(backgrounds.items.len / 6) }, .{ .name = "selectionQuads", .value = @intCast(selections.items.len / 6) } });
    const glyph_started = trace.now();
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| {
        encodeCoverage(self, row, e, f, x, y);
        for (rowValue(row).payload.colors) |layer| e.texture(self.core, layer.texture, transform(rect(layer.rect), row, x, y, f.cell_height), full_uv, false, white);
    }
    if (trace.enabled()) trace.record("draw.glyphEncoding", glyph_started, &.{.{ .name = "rows", .value = @intCast(f.row_count) }});
    backgrounds.clearRetainingCapacity();
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| for (rowValue(row).payload.decorations) |solid| {
        backgrounds.appendSlice(a, &quad(transform(rect(solid.rect), row, x, y, f.cell_height), full_uv, solid.color, false)) catch {};
    };
    e.solid(self.core, backgrounds.items);
    encodeKitty(self, e, f, x, y);
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| for (rowValue(row).payload.images) |placement| {
        var owner: ?*const anyopaque = null;
        defer c.cmdy_gpu_apple_release(owner);
        const texture = (if (placement.owned_image) |input|
            self.images.ownedTexture(input)
        else blk: {
            owner = c.cmdy_gpu_apple_weak_load(placement.owner) orelse continue;
            break :blk self.images.texture(owner, placement.image);
        }) orelse continue;
        const content = if (std.math.isFinite(f.image_scale)) @max(0, f.image_scale) else 1;
        const scale = if (std.math.isFinite(f.scale)) @max(0, f.scale) else 1;
        const box = kittyImageBox(placement, f.cell_width, f.cell_height, content * scale);
        const destination = Rect{ .x = x + @as(f64, @floatFromInt(placement.col)) * f.cell_width, .y = y + @as(f64, @floatFromInt(row.display_index)) * f.cell_height, .width = box.width, .height = box.height };
        e.texture(self.core, texture, destination, box.uv, false, white);
    };
}

const ImageBox = struct { width: f64, height: f64, uv: Rect };

/// Kitty `x,y,w,h` crops the source and `c,r` sets the display box in cells;
/// with only one of `c,r` the other follows the crop's aspect ratio. Without
/// either, the crop keeps its own pixel size. Other images use their own size.
pub fn kittyImageBox(placement: c.CmdyGpuImagePlacement, cell_width: f64, cell_height: f64, pixel_scale: f64) ImageBox {
    const image_width: f64 = @floatFromInt(@max(0, placement.width));
    const image_height: f64 = @floatFromInt(@max(0, placement.height));
    if (placement.is_kitty == 0 or image_width <= 0 or image_height <= 0) {
        return .{ .width = image_width * pixel_scale, .height = image_height * pixel_scale, .uv = full_uv };
    }
    const sx = @min(image_width, @as(f64, @floatFromInt(@max(0, placement.source_x))));
    const sy = @min(image_height, @as(f64, @floatFromInt(@max(0, placement.source_y))));
    var sw = image_width - sx;
    var sh = image_height - sy;
    if (placement.source_width > 0) sw = @min(sw, @as(f64, @floatFromInt(placement.source_width)));
    if (placement.source_height > 0) sh = @min(sh, @as(f64, @floatFromInt(placement.source_height)));
    const uv = Rect{ .x = sx / image_width, .y = sy / image_height, .width = sw / image_width, .height = sh / image_height };
    if (sw <= 0 or sh <= 0) return .{ .width = 0, .height = 0, .uv = uv };
    const cols: f64 = @floatFromInt(@max(0, placement.cell_cols));
    const rows: f64 = @floatFromInt(@max(0, placement.cell_rows));
    var width = sw * pixel_scale;
    var height = sh * pixel_scale;
    if (cols > 0 and rows > 0) {
        width = cols * cell_width;
        height = rows * cell_height;
    } else if (cols > 0) {
        width = cols * cell_width;
        height = width * sh / sw;
    } else if (rows > 0) {
        height = rows * cell_height;
        width = height * sw / sh;
    }
    return .{ .width = width, .height = height, .uv = uv };
}
fn encodeCursor(self: anytype, e: Encoding, f: *const c.CmdyGpuFrame, x: f64, y: f64) void {
    if (f.cursor_valid == 0 or f.cursor_col < 0 or f.cursor_col >= f.grid_cols) {
        self.schedule.cursorInvalid();
        self.cursor_center = .{ 0, 0 };
        return;
    }
    var cursor_row: ?c.CmdyGpuFrameRow = null;
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| if (row.source_row == f.cursor_source_row) {
        cursor_row = row;
        break;
    };
    const width = f.cell_width * @as(f64, if (cursor_row != null and cursor_row.?.line_mode != 0) 2 else 1);
    const target = geo.Vec2{ .x = @floatCast(x + @as(f64, @floatFromInt(f.cursor_col)) * width), .y = @floatCast(y + @as(f64, @floatFromInt(f.cursor_display_row)) * f.cell_height) };
    const should_draw = f.cursor_hidden == 0 and f.host_cursor_hidden == 0;
    const opacity = self.schedule.opacity(f.cursor_style % 2 == 0, f.caret_focused != 0, f.now);
    const step = self.schedule.cursorStep(target, should_draw, f.live_resize != 0, .{ .x = @floatCast(width), .y = @floatCast(f.cell_height) }, f.now);
    self.cursor_center = .{ step.position.x + @as(f32, @floatCast(width / 2)), step.position.y + @as(f32, @floatCast(f.cell_height / 2)) };
    if (!should_draw) return;
    var color = f.caret;
    color.a *= opacity;
    const natural_y = geo.cursorNaturalY(step.position.y, f.cell_height, f.cursor_natural_height);
    var solids: [4]Rect = undefined;
    var count: usize = 0;
    if (f.cursor_style < 2) {
        const block = Rect{ .x = step.position.x, .y = natural_y, .width = width, .height = f.cursor_natural_height };
        if (f.caret_focused != 0) {
            solids[0] = block;
            count = 1;
        } else {
            const t = @max(1, @round(f.scale));
            solids = .{ .{ .x = block.x, .y = block.y, .width = block.width, .height = t }, .{ .x = block.x, .y = maxY(block) - t, .width = block.width, .height = t }, .{ .x = block.x, .y = block.y, .width = t, .height = block.height }, .{ .x = maxX(block) - t, .y = block.y, .width = t, .height = block.height } };
            count = 4;
        }
    } else if (f.cursor_style < 4) {
        const t = geo.cursorUnderline(f.underline_thickness, f.scale);
        solids[0] = .{ .x = step.position.x, .y = step.position.y + f.cell_height - t, .width = width, .height = t };
        count = 1;
    } else {
        solids[0] = .{ .x = step.position.x, .y = natural_y, .width = geo.cursorBar(f.scale), .height = f.cursor_natural_height };
        count = 1;
    }
    var vertices_value: [24]Vertex = undefined;
    for (solids[0..count], 0..) |solid, i| @memcpy(vertices_value[i * 6 ..][0..6], &quad(solid, full_uv, color, false));
    e.solid(self.core, vertices_value[0 .. count * 6]);
    if (f.cursor_style < 2 and f.caret_focused != 0 and !step.is_animating) {
        if (cursor_row) |row| {
            const p = rowValue(row).payload;
            if (p.coverage) |texture| {
                const source = Rect{ .x = @as(f64, @floatFromInt(f.cursor_col)) * f.cell_width, .width = f.cell_width, .height = @floatFromInt(p.height) };
                const destination = Rect{ .x = step.position.x, .y = step.position.y, .width = width, .height = f.cell_height };
                var text_color = f.caret_text;
                text_color.r *= opacity;
                text_color.g *= opacity;
                text_color.b *= opacity;
                text_color.a *= opacity;
                e.coverageTexture(self.core, texture, destination, uvRect(source, p.width, p.height, true), text_color, self.coveragePower());
            }
        }
    }
    if (step.is_animating) self.cursor_continuation = true;
}
fn postProcess(self: anytype, e: Encoding, f: *const c.CmdyGpuFrame) void {
    c.cmdy_gpu_apple_encoder_pipeline(e.encoder, if (f.shader_mode == -1 and self.user_pipeline != null) self.user_pipeline else self.core.scene_effect);
    c.cmdy_gpu_apple_encoder_texture(e.encoder, self.scene, 0);
    c.cmdy_gpu_apple_encoder_sampler(e.encoder, self.core.linear, 0);
    const keypress_time = if (self.input_activity) |activity| activity.keypress_time else f.activity_keypress_time;
    const typing_rate = if (self.input_activity) |activity| activity.typing_rate else f.typing_rate;
    const u = Uniforms{ .resolution = e.resolution, .time = @floatCast(f.now - self.start_time), .curvature = 0.08, .background = vector(f.background), .cursor = self.cursor_center, .key_age = @floatCast(@max(0, @min(10, f.now - keypress_time))), .typing_rate = typing_rate, .opacity = f.background.a, .pass_index = @intCast(@max(0, f.shader_mode)) };
    e.bytes(u, 0, true);
    if (f.shader_mode >= 1) {
        e.bytes(f.shader_mode, 1, true);
        c.cmdy_gpu_apple_encoder_draw(e.encoder, 3);
    } else {
        const vertices_value = quad(.{ .width = f.width, .height = f.height }, full_uv, white, false);
        if (!e.vertices(&vertices_value)) return;
        e.bytes(e.raster(1, 0), 1, false);
        c.cmdy_gpu_apple_encoder_draw(e.encoder, 6);
    }
}
pub fn draw(self: anytype, f: *const c.CmdyGpuFrame, identity: c.CmdyRenderFrameIdentity) bool {
    const maintenance_started = trace.now();
    var visible: std.ArrayList(isize) = .empty;
    defer visible.deinit(a);
    visible.ensureTotalCapacity(a, f.row_count) catch return false;
    for (cache.slice(c.CmdyGpuFrameRow, f.rows, f.row_count)) |row| visible.appendAssumeCapacity(rowValue(row).key.value.absolute_row);
    self.rows.trim(visible.items, @max(@as(usize, @intCast(@max(0, f.grid_rows))), f.row_count));
    self.images.prune(cache.slice(u32, f.live_kitty_ids, f.live_kitty_count));
    if (trace.enabled()) trace.record("draw.cacheMaintenance", maintenance_started, &.{ .{ .name = "source", .value = f.trace_source }, .{ .name = "frame", .value = @intCast(f.trace_started) } });
    const command = c.cmdy_gpu_apple_command_buffer(self.core.queue) orelse return false;
    defer c.cmdy_gpu_apple_release(command);
    c.cmdy_render_buffer_ring_begin(self.ring);
    const needs_scene = (f.shader_mode >= 1 and f.shader_mode <= 67) or (f.shader_mode == -1 and self.user_pipeline != null);
    if (!needs_scene) {
        c.cmdy_gpu_apple_release(self.scene);
        self.scene = null;
    }
    var owned_pass: ?*anyopaque = null;
    defer c.cmdy_gpu_apple_release(owned_pass);
    var pass = f.pass;
    if (needs_scene) {
        const width: @TypeOf(self.scene_width) = @intFromFloat(@max(1, @round(f.width)));
        const height: @TypeOf(self.scene_height) = @intFromFloat(@max(1, @round(f.height)));
        if (self.scene == null or self.scene_width != width or self.scene_height != height) {
            c.cmdy_gpu_apple_release(self.scene);
            self.scene = c.cmdy_gpu_apple_texture(self.core.device, width, height, 0, self.core.format, 1, 1);
            self.scene_width = width;
            self.scene_height = height;
        }
        if (self.scene) |texture| {
            owned_pass = c.cmdy_gpu_apple_pass(texture);
            pass = owned_pass;
        }
    }
    // Built-in effects sample a premultiplied scene and convert their colors
    // at their output boundary. Custom shaders retain the documented straight
    // scene texture/input contract; their wrapper premultiplies the result.
    const background_alpha: f32 = if (needs_scene and f.shader_mode == -1) 1 else f.background.a;
    c.cmdy_gpu_apple_pass_clear(pass, f.background.r * background_alpha,
        f.background.g * background_alpha, f.background.b * background_alpha, f.background.a);
    const encoder = c.cmdy_gpu_apple_encoder(command, pass) orelse return false;
    defer c.cmdy_gpu_apple_release(encoder);
    const scissor = geo.scissor(f.width, f.height, f.top_inset, f.bottom_inset, f.left_inset, f.scale);
    if (scissor.width == 0 or scissor.height == 0) {
        c.cmdy_gpu_apple_encoder_end(encoder);
        return false;
    }
    c.cmdy_gpu_apple_encoder_scissor(encoder, scissor.x, scissor.y, scissor.width, scissor.height);
    const snapped = geo.smoothScrollTranslation(f.scroll_pixels, f.scale);
    const x = @round(f.content_x * f.scale);
    const y = @as(f64, @floatFromInt(geo.deviceTopInset(f.top_inset, f.scale))) + snapped.y_shift_pixels;
    const e = Encoding{ .encoder = encoder, .ring = self.ring, .resolution = .{ @floatCast(f.width), @floatCast(f.height) } };
    const encoding_started = trace.now();
    self.cursor_continuation = false;
    self.images.beginOwnedFrame();
    defer self.images.endOwnedFrame();
    encodeRows(self, e, f, x, y);
    encodeCursor(self, e, f, x, y);
    c.cmdy_gpu_apple_encoder_end(encoder);
    if (needs_scene and self.scene != null) {
        if (c.cmdy_gpu_apple_encoder(command, f.pass)) |final_encoder| {
            defer c.cmdy_gpu_apple_release(final_encoder);
            postProcess(self, .{ .encoder = final_encoder, .ring = self.ring, .resolution = e.resolution }, f);
            c.cmdy_gpu_apple_encoder_end(final_encoder);
        }
    }
    if (trace.enabled()) trace.record("draw.encoding", encoding_started, &.{ .{ .name = "source", .value = f.trace_source }, .{ .name = "frame", .value = @intCast(f.trace_started) } });
    return self.commit(command, f.drawable, f, identity);
}

test "coverage spans preserve adjacency and conservative geometry boundaries" {
    const t = std.testing;
    const first = Rect{ .x = 0, .y = 0, .width = 12, .height = 20 };
    const second = Rect{ .x = 12, .y = 0, .width = 12, .height = 20 };
    try t.expectEqual(@as(f64, 24), mergeCoverageRect(first, second).?.width);
    var changed = second;
    changed.x = 11; try t.expect(mergeCoverageRect(first, changed) == null);
    changed.x = 13; try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.y = 1; try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.width = 12.5; try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.height = 19; try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.width = 0; try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.width = -12; try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.x = std.math.nan(f64); try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.width = std.math.inf(f64); try t.expect(mergeCoverageRect(first, changed) == null);
    changed = second; changed.width = 1_000_001; try t.expect(mergeCoverageRect(first, changed) == null);
}
