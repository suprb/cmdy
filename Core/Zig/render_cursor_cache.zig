//! Bounded cursor phase construction. Every mutable resource belongs to one
//! scoped worker; only complete immutable BGRA frames cross that boundary.
const std = @import("std");
const c = @import("render_shader.zig").c;
const gpu = @import("render_gpu.zig");
const worker = @import("render_worker.zig");
const geo = @import("render_geometry.zig");
const captured = @import("render_frame_input.zig");
const a = std.heap.c_allocator;
// The full-viewport readback is temporary. Return its pages when the final
// immutable-frame reference is released instead of retaining a large malloc
// region after the host has copied the pixels into compositor surfaces.
const backing_allocator = std.heap.page_allocator;
const phase_count = 60;
const maximum_bytes = 2 * 1024 * 1024;
const maximum_backing_bytes = 32 * 1024 * 1024;

pub const Frames = struct {
    refs: std.atomic.Value(usize) = .init(1),
    view: c.CmdyRenderCursorFramesView,
    pixels: []u8,
    backing: []u8,
    fn release(self: *Frames) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        a.free(self.pixels);
        backing_allocator.free(self.backing);
        a.destroy(self);
    }
};

fn layout(input: *const c.CmdyRenderFrameInput, native: *const captured.Frame, activity: f64, until: f64) ?c.CmdyRenderCursorFramesView {
    const f = input.parameters;
    if (!std.math.isFinite(activity) or !std.math.isFinite(until) or until < activity + 1.2 or
        f.shader_mode != 0 or f.live_resize != 0 or f.background.a != 1 or
        f.cursor_valid == 0 or f.cursor_hidden != 0 or f.host_cursor_hidden != 0 or
        f.caret_focused == 0 or f.cursor_style > 4 or f.cursor_style % 2 != 0 or
        f.cursor_col < 0 or f.cursor_col >= f.grid_cols or f.cursor_display_row < 0 or
        f.cursor_display_row >= f.grid_rows or input.row_count > 4096 or
        f.kitty_image_count != 0 or f.kitty_placement_count != 0 or f.live_kitty_count != 0) return null;
    inline for (.{ "width", "height", "scale", "cell_width", "cell_height", "cursor_natural_height" }) |name| {
        const value = @field(f, name);
        if (!std.math.isFinite(value) or value <= 0 or value > 32768) return null;
    }
    inline for (.{ "content_x", "scroll_pixels", "top_inset", "bottom_inset", "left_inset", "underline_thickness" }) |name| {
        if (!std.math.isFinite(@field(f, name)) or @abs(@field(f, name)) > 1_000_000) return null;
    }
    if (f.scale > 16) return null;
    var mode: u32 = 0;
    if (native.viewportInput()) |viewport| {
        if (viewport.visible.count() > 4096) return null;
        var cells_left: usize = 1024 * 1024;
        for (0..viewport.visible.count()) |index| {
            const request = viewport.visible.at(index).?;
            const line = viewport.line(request.source_row);
            if (line.images) |images| if (images.items.len != 0) return null;
            const count = line.row.columnCount();
            if (count > cells_left) return null;
            cells_left -= count;
            for (0..count) |col| if (line.row.readValue(col).cell.scalar == 0x10eeee) return null;
            if (request.source_row == f.cursor_source_row) mode = @intFromEnum(line.render_mode);
        }
    }
    for (0..input.row_count) |i| {
        const row = input.rows[i];
        if (row.image_count != 0 or row.placeholder_count != 0) return null;
        // Deferred text can contain decoded graphics placeholders even when
        // the explicit frame-row placeholder array is empty.
        if (c.cmdy_render_input_prepare(row.text, null) == null) return null;
        var decoded: usize = 0;
        _ = c.cmdy_render_input_placeholders(row.text, &decoded);
        if (decoded != 0) return null;
        if (row.placement.source_row == f.cursor_source_row) mode = row.placement.line_mode;
    }
    const cell_width = f.cell_width * @as(f64, if (mode == 0) 1 else 2);
    const x = @round(f.content_x * f.scale) + @as(f64, @floatFromInt(f.cursor_col)) * cell_width;
    const y = @as(f64, @floatFromInt(geo.deviceTopInset(f.top_inset, f.scale))) +
        geo.smoothScrollTranslation(f.scroll_pixels, f.scale).y_shift_pixels +
        @as(f64, @floatFromInt(f.cursor_display_row)) * f.cell_height;
    const natural_y = geo.cursorNaturalY(y, f.cell_height, f.cursor_natural_height);
    const scissor = geo.scissor(f.width, f.height, f.top_inset, f.bottom_inset, f.left_inset, f.scale);
    const left = @max(@as(f64, @floatFromInt(scissor.x)), @floor(x) - 2);
    const top = @max(@as(f64, @floatFromInt(scissor.y)), @floor(@min(y, natural_y)) - 2);
    const right = @min(@as(f64, @floatFromInt(scissor.x + scissor.width)), @ceil(x + cell_width) + 2);
    const bottom = @min(@as(f64, @floatFromInt(scissor.y + scissor.height)), @ceil(@max(y + f.cell_height, natural_y + f.cursor_natural_height)) + 2);
    if (right <= left or bottom <= top) return null;
    const width: usize = @intFromFloat(right - left);
    const height: usize = @intFromFloat(bottom - top);
    if (width > maximum_bytes / phase_count / 4 / height) return null;
    return .{ .identity = input.identity, .x = left, .y = top, .scale = f.scale,
        .viewport_width = f.width, .viewport_height = f.height, .activity_time = activity, .active_until = until,
        .width = width, .height = height, .count = phase_count, .bytes_per_frame = width * height * 4, .bytes = null,
        .backing_width = 0, .backing_height = 0, .backing_byte_count = 0, .backing_bytes = null };
}

pub const Job = struct {
    refs: std.atomic.Value(usize) = .init(2), // caller plus accepted GPU work
    cancelled: std.atomic.Value(bool) = .init(false),
    owner: *worker.Worker,
    epoch: u64,
    input: ?*c.CmdyRenderOwnedFrameInput = null,
    renderer: ?*c.CmdyRenderGPU = null,
    texture: ?*anyopaque = null,
    pass: ?*anyopaque = null,
    backing_texture: ?*anyopaque = null,
    backing_pass: ?*anyopaque = null,
    backing_pending: bool = false,
    frames: ?*Frames = null,
    index: usize = 0,
    callback: c.CmdyRenderCursorCacheCallback,
    context: ?*anyopaque,
    dispose: c.CmdyRenderWorkerCallback,

    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) a.destroy(self);
    }
    fn cleanup(self: *Job) void {
        std.debug.assert(self.owner.isWorkerThread());
        if (self.renderer) |raw| {
            c.cmdy_gpu_set_event(raw, null, null);
            const renderer: *gpu.Renderer = @ptrCast(@alignCast(raw));
            renderer.stale_slot_available = null;
            c.cmdy_gpu_destroy(raw);
        }
        self.renderer = null;
        c.cmdy_gpu_apple_release(self.pass);
        c.cmdy_gpu_apple_release(self.texture);
        self.pass = null;
        self.texture = null;
        c.cmdy_gpu_apple_release(self.backing_pass);
        c.cmdy_gpu_apple_release(self.backing_texture);
        self.backing_pass = null;
        self.backing_texture = null;
        c.cmdy_render_frame_input_release(self.input);
        self.input = null;
        if (self.frames) |frames| frames.release();
        self.frames = null;
    }
    fn finish(self: *Job, result: u32) void {
        // Context remains owned until its last callback returns. A callback may
        // cancel/release the caller's handle, but the work reference stays live.
        if (self.callback) |callback| callback(self.context, result,
            if (result == c.CMDY_CURSOR_CACHE_READY) @ptrCast(self.frames.?) else null);
        if (self.dispose) |dispose| dispose(self.context);
        self.cleanup();
        self.release();
    }
    fn stopped(self: *Job) bool {
        return self.cancelled.load(.acquire) or self.owner.currentEpoch() != self.epoch;
    }
    fn submit(self: *Job) bool {
        if (self.stopped()) return false;
        var metadata = c.cmdy_render_frame_input_metadata(self.input).?.*;
        const view = self.frames.?.view;
        if (!self.backing_pending) {
            const origin_y = @as(f64, @floatFromInt(geo.deviceTopInset(metadata.parameters.top_inset, view.scale))) +
                geo.smoothScrollTranslation(metadata.parameters.scroll_pixels, view.scale).y_shift_pixels;
            metadata.parameters.content_x = (@round(metadata.parameters.content_x * view.scale) - view.x) / view.scale;
            metadata.parameters.scroll_pixels = view.y - origin_y;
            metadata.parameters.top_inset = 0;
            metadata.parameters.bottom_inset = 0;
            metadata.parameters.left_inset = 0;
            metadata.parameters.width = @floatFromInt(view.width);
            metadata.parameters.height = @floatFromInt(view.height);
        }
        metadata.parameters.now = view.activity_time + @as(f64, @floatFromInt(self.index)) / 50;
        // Frozen content, placement and graphics are unchanged. Only scalar
        // target coordinates/time differ; reuse does not copy row payloads.
        const frame = c.cmdy_render_frame_input_reuse(self.input, &metadata, null) orelse return false;
        defer c.cmdy_render_frame_input_release(frame);
        return c.cmdy_gpu_draw_captured(self.renderer, frame, null, if (self.backing_pending) self.backing_pass else self.pass) != 0;
    }
    fn completed(context: ?*anyopaque, kind: u32) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        std.debug.assert(self.owner.isWorkerThread());
        if (self.stopped()) { self.finish(c.CMDY_CURSOR_CACHE_CANCELLED); return; }
        const renderer: *gpu.Renderer = @ptrCast(@alignCast(self.renderer.?));
        if (kind != 1 or !renderer.last_gpu_success) { self.finish(c.CMDY_CURSOR_CACHE_FAILED); return; }
        const frames = self.frames.?;
        const bytes = if (self.backing_pending) frames.backing else frames.pixels[self.index * frames.view.bytes_per_frame ..][0..frames.view.bytes_per_frame];
        const texture = if (self.backing_pending) self.backing_texture else self.texture;
        if (c.cmdy_gpu_apple_texture_read_bgra(texture, bytes.ptr, bytes.len) == 0) {
            self.finish(c.CMDY_CURSOR_CACHE_FAILED); return;
        }
        // An opaque base is essential to replacing a patch without changing
        // destination blending. Do not deliver an incomplete/transparent cache.
        var offset: usize = 3;
        while (offset < bytes.len) : (offset += 4) if (bytes[offset] != 255) {
            self.finish(c.CMDY_CURSOR_CACHE_FAILED); return;
        };
        if (self.backing_pending) {
            self.backing_pending = false;
            c.cmdy_gpu_apple_release(self.backing_pass);
            c.cmdy_gpu_apple_release(self.backing_texture);
            self.backing_pass = null;
            self.backing_texture = null;
        } else self.index += 1;
        if (self.index == phase_count) { self.finish(c.CMDY_CURSOR_CACHE_READY); return; }
        if (!self.submit()) self.finish(if (self.stopped()) c.CMDY_CURSOR_CACHE_CANCELLED else c.CMDY_CURSOR_CACHE_FAILED);
    }
    fn stale(context: ?*anyopaque) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        self.finish(c.CMDY_CURSOR_CACHE_CANCELLED);
    }
};

export fn cmdy_render_cursor_cache_begin(raw_owner: ?*c.CmdyRenderWorker, device: ?*const anyopaque,
    input: ?*c.CmdyRenderOwnedFrameInput, preset: u32, activity: f64, until: f64,
    callback: c.CmdyRenderCursorCacheCallback, context: ?*anyopaque, dispose: c.CmdyRenderWorkerCallback) ?*Job
{
    return begin(raw_owner, device, input, preset, activity, until, callback, context, dispose, false);
}
export fn cmdy_render_cursor_cache_begin_with_backing(raw_owner: ?*c.CmdyRenderWorker, device: ?*const anyopaque,
    input: ?*c.CmdyRenderOwnedFrameInput, preset: u32, activity: f64, until: f64,
    callback: c.CmdyRenderCursorCacheCallback, context: ?*anyopaque, dispose: c.CmdyRenderWorkerCallback) ?*Job
{
    return begin(raw_owner, device, input, preset, activity, until, callback, context, dispose, true);
}
fn begin(raw_owner: ?*c.CmdyRenderWorker, device: ?*const anyopaque,
    input: ?*c.CmdyRenderOwnedFrameInput, preset: u32, activity: f64, until: f64,
    callback: c.CmdyRenderCursorCacheCallback, context: ?*anyopaque, dispose: c.CmdyRenderWorkerCallback, with_backing: bool) ?*Job
{
    const owner: *worker.Worker = @ptrCast(@alignCast(raw_owner orelse return null));
    if (!owner.isWorkerThread() or owner.scope == null or device == null or callback == null or preset > 5) return null;
    const source = input orelse return null;
    const source_view = c.cmdy_render_frame_input_view(source) orelse return null;
    const epoch = owner.currentEpoch();
    if (epoch == 0 or source_view.*.identity.epoch != epoch) return null;
    var view = layout(source_view, @ptrCast(@alignCast(source)), activity, until) orelse return null;
    if (with_backing) {
        if (@floor(view.viewport_width) != view.viewport_width or @floor(view.viewport_height) != view.viewport_height) return null;
        view.backing_width = @intFromFloat(view.viewport_width);
        view.backing_height = @intFromFloat(view.viewport_height);
        if (view.backing_width > maximum_backing_bytes / 4 / view.backing_height) return null;
        view.backing_byte_count = view.backing_width * view.backing_height * 4;
    }
    const pixels = a.alloc(u8, view.bytes_per_frame * phase_count) catch return null;
    const backing = backing_allocator.alloc(u8, view.backing_byte_count) catch { a.free(pixels); return null; };
    const frames = a.create(Frames) catch { a.free(pixels); backing_allocator.free(backing); return null; };
    view.bytes = pixels.ptr;
    view.backing_bytes = if (backing.len == 0) null else backing.ptr;
    frames.* = .{ .pixels = pixels, .backing = backing, .view = view };
    const self = a.create(Job) catch { frames.release(); return null; };
    self.* = .{ .owner = owner, .epoch = epoch, .input = c.cmdy_render_frame_input_retain(source),
        .frames = frames, .backing_pending = with_backing, .callback = callback, .context = context, .dispose = dispose };
    var accepted = false;
    defer if (!accepted) { self.cleanup(); a.destroy(self); };
    var error_text: [512]u8 = @splat(0);
    self.renderer = c.cmdy_gpu_create_on_worker(raw_owner, device, 80, 1, activity, &error_text, error_text.len) orelse return null;
    const renderer: *gpu.Renderer = @ptrCast(@alignCast(self.renderer.?));
    renderer.counts_frames = false;
    renderer.checked_completion = true;
    renderer.schedule.config.smooth_cursor = false;
    renderer.stale_slot_available = Job.stale;
    c.cmdy_gpu_set_preset(self.renderer, preset);
    c.cmdy_gpu_set_event(self.renderer, Job.completed, self);
    self.texture = c.cmdy_gpu_apple_texture(device, view.width, view.height, 0, 80, 1, 0) orelse return null;
    self.pass = c.cmdy_gpu_apple_pass(self.texture) orelse return null;
    if (with_backing) {
        self.backing_texture = c.cmdy_gpu_apple_texture(device, view.backing_width, view.backing_height, 0, 80, 1, 0) orelse return null;
        self.backing_pass = c.cmdy_gpu_apple_pass(self.backing_texture) orelse return null;
    }
    if (!self.submit()) return null;
    accepted = true;
    return self;
}
export fn cmdy_render_cursor_cache_cancel(self: ?*Job) void {
    if (self) |job| job.cancelled.store(true, .release);
}
export fn cmdy_render_cursor_cache_release(self: ?*Job) void {
    if (self) |job| job.release();
}
export fn cmdy_render_cursor_frames_retain(self: ?*Frames) ?*Frames {
    if (self) |frames| _ = frames.refs.fetchAdd(1, .monotonic);
    return self;
}
export fn cmdy_render_cursor_frames_release(self: ?*Frames) void {
    if (self) |frames| frames.release();
}
export fn cmdy_render_cursor_frames_view(self: ?*const Frames) ?*const c.CmdyRenderCursorFramesView {
    return if (self) |frames| &frames.view else null;
}
