//! Public native renderer boundary. Swift owns the MTKView attachment and
//! source adapters; this object owns every mutable rendering resource.
const std = @import("std");
const shader = @import("render_shader.zig");
const cache = @import("render_cache.zig");
const glyph = @import("render_cache_glyph.zig");
const image = @import("render_cache_image.zig");
const frame = @import("render_gpu_frame.zig");
const schedule = @import("render_schedule.zig");
const font_module = @import("render_font.zig");
const trace = @import("render_trace.zig");
const worker = @import("render_worker.zig");
const target = @import("render_gpu_target.zig");
const c = shader.c;
const a = std.heap.c_allocator;
var frames_presented: std.atomic.Value(u64) = .init(0);
const FrameTrace = struct { started: u64, source: isize, frame: u64 };
pub const Renderer = struct {
    refs: usize = 1,
    alive: bool = true,
    // Immutable owner; all mutable resources and reference counts stay on it.
    owner: ?*worker.Worker = null,
    close_requested: std.atomic.Value(bool) = .init(false),
    close_ticket: ?*worker.Completion = null,
    gpu_ticket: ?*worker.Completion = null,
    captured_surface: u64 = 0,
    captured_epoch: u64 = 0,
    // Session-owned revision outlives every active draw. Only the owner changes
    // drawing_revision; producers advance the atomic at the publication fence.
    source_revision: ?*const std.atomic.Value(u64) = null,
    drawing_revision: u64 = 0,
    publication_gate: ?*const std.atomic.Value(bool) = null,
    committed_identity: c.CmdyRenderFrameIdentity = .{ .surface = 0, .epoch = 0, .sequence = 0 },
    core: *shader.Shared,
    glyphs: glyph.Cache,
    rows: cache.Cache,
    images: *image.Cache,
    ring: ?*c.CmdyRenderBufferRing,
    schedule: schedule.State,
    start_time: f64,
    preset: u32 = 0,
    scene: ?*anyopaque = null,
    scene_width: usize = 0,
    scene_height: usize = 0,
    user_pipeline: ?*anyopaque = null,
    user_uses_time: bool = false,
    // Render-owner scalars do not invalidate immutable terminal/UI content.
    // Legacy direct GPU clients retain their frame-provided values.
    input_activity: ?struct { keypress_time: f64, typing_rate: f32 } = null,
    cursor_center: [2]f32 = .{ 0, 0 },
    cursor_continuation: bool = false,
    // Auxiliary offscreen work must not masquerade as a terminal frame.
    counts_frames: bool = true,
    checked_completion: bool = false,
    // Metal writes before publishing its worker completion ticket; only that
    // scoped completion reads it. No second command is in flight concurrently.
    last_gpu_success: bool = true,
    event: c.CmdyRenderGPUEvent = null,
    context: ?*anyopaque = null,
    // Internal owner notification: a stale frame is not a presented frame, but
    // its released slot may unblock a current session request after resize.
    stale_slot_available: ?*const fn (?*anyopaque) callconv(.c) void = null,
    inflight_trace: FrameTrace = .{ .started = 0, .source = 0, .frame = 0 },
    pub fn coveragePower(self: *const Renderer) f32 {
        return 1 / @as(f32, if (self.preset == 4 or self.preset == 5) 1.55 else 1.35);
    }
    fn release(self: *Renderer) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        self.rows.deinit();
        self.glyphs.deinit();
        c.cmdy_render_buffer_ring_free(self.ring);
        c.cmdy_gpu_apple_release(self.scene);
        c.cmdy_gpu_apple_release(self.user_pipeline);
        self.core.release();
        a.destroy(self);
    }
    pub fn commit(self: *Renderer, command: ?*const anyopaque, drawable: ?*const anyopaque, input: *const c.CmdyGpuFrame, identity: c.CmdyRenderFrameIdentity) bool {
        // Trace initialization and allocation must not delay a producer that
        // is waiting to invalidate the final submission boundary.
        const tracing = trace.enabled();
        var presentation: ?*FrameTrace = if (tracing and drawable != null) a.create(FrameTrace) catch null else null;
        defer if (presentation) |value| a.destroy(value);
        {
            if (self.owner) |owner| {
                if (!owner.beginPublication(identity.epoch)) return false;
            }
            defer if (self.owner) |owner| owner.endPublication();
            if (self.close_requested.load(.acquire)) return false;
            if (self.publication_gate) |gate| if (gate.load(.acquire)) return false;
            if (self.source_revision) |revision| {
                if (self.drawing_revision == 0 or revision.load(.acquire) != self.drawing_revision) return false;
            }
            self.committed_identity = identity;
            self.inflight_trace = .{ .started = trace.now(), .source = input.trace_source, .frame = input.trace_started };
            if (presentation) |value| {
                value.* = self.inflight_trace;
                c.cmdy_gpu_apple_presented(drawable, presented, value, disposePresentation);
                presentation = null;
            }
            // Worker mode reserved its reference/ticket before encoding. Only
            // final state and the external Metal submission are serialized.
            if (self.owner == null) self.refs += 1;
            self.schedule.frame_in_flight = true;
            if (self.checked_completion)
                c.cmdy_gpu_apple_commit_checked(command, drawable, gpuCheckedComplete, self)
            else
                c.cmdy_gpu_apple_commit(command, drawable, gpuComplete, self);
        }
        // The writer can initialize a queue, reserve under its own mutex and
        // allocate copied fields, so it runs after publication is unlocked.
        if (tracing) trace.record("draw.commit", self.inflight_trace.started, &.{ .{ .name = "source", .value = input.trace_source }, .{ .name = "frame", .value = @intCast(input.trace_started) } });
        return true;
    }
};
fn renderer(raw: ?*c.CmdyRenderGPU) ?*Renderer {
    const self: *Renderer = @ptrCast(@alignCast(raw orelse return null));
    if (self.owner) |owner| if (!owner.isWorkerThread()) return null;
    if (self.close_requested.load(.acquire)) return null;
    return self;
}
fn constRenderer(raw: ?*const c.CmdyRenderGPU) ?*const Renderer {
    return renderer(@constCast(raw));
}
fn rowHandle(row: ?*cache.Row) ?*const c.CmdyRenderGPURow {
    return if (row) |p| @ptrCast(p) else null;
}
fn notifyImage(context: ?*anyopaque) callconv(.c) void {
    const self: *Renderer = @ptrCast(@alignCast(context.?));
    if (self.alive and !self.close_requested.load(.acquire)) if (self.event) |event| event(self.context, 2);
}
fn presented(context: ?*anyopaque, seconds: f64) callconv(.c) void {
    const value: *const FrameTrace = @ptrCast(@alignCast(context.?));
    if (trace.enabled()) trace.record("draw.presented", value.started, &.{ .{ .name = "source", .value = value.source }, .{ .name = "frame", .value = @intCast(value.frame) }, .{ .name = "presentedNanoseconds", .value = if (std.math.isFinite(seconds)) schedule.geometry.boundedInt(seconds * 1_000_000_000) else 0 } });
}
fn disposePresentation(context: ?*anyopaque) callconv(.c) void {
    a.destroy(@as(*FrameTrace, @ptrCast(@alignCast(context.?))));
}
fn gpuCheckedComplete(context: ?*anyopaque, gpu_start: f64, gpu_end: f64, succeeded: u8) callconv(.c) void {
    const self: *Renderer = @ptrCast(@alignCast(context.?));
    self.last_gpu_success = succeeded != 0;
    gpuComplete(context, gpu_start, gpu_end);
}
fn gpuComplete(context: ?*anyopaque, gpu_start: f64, gpu_end: f64) callconv(.c) void {
    const self: *const Renderer = @ptrCast(@alignCast(context.?));
    const value = self.inflight_trace;
    const duration = gpu_end - gpu_start;
    if (trace.enabled()) trace.record("draw.gpuComplete", value.started, &.{ .{ .name = "source", .value = value.source }, .{ .name = "frame", .value = @intCast(value.frame) }, .{ .name = "gpuNanoseconds", .value = if (std.math.isFinite(duration)) schedule.geometry.boundedInt(@max(0, duration) * 1_000_000_000) else 0 } });
    if (self.gpu_ticket) |ticket| ticket.publish(.ready) else c.cmdy_gpu_apple_dispatch_main(complete, context);
}
fn complete(context: ?*anyopaque) callconv(.c) void {
    finishGPU(context, true);
}
fn ownedComplete(context: ?*anyopaque, _: *worker.Worker, result: u32) callconv(.c) void {
    const self: *Renderer = @ptrCast(@alignCast(context.?));
    self.gpu_ticket = null;
    self.schedule.frame_in_flight = false;
    finishGPU(context, result == @intFromEnum(worker.CompletionResult.ready));
}
fn finishGPU(context: ?*anyopaque, ready: bool) void {
    const self: *Renderer = @ptrCast(@alignCast(context.?));
    defer self.release();
    if (!ready or !self.alive or self.close_requested.load(.acquire)) return;
    // Scoped frame callbacks cannot wake a replacement surface. Raw legacy
    // draws preserve their existing completion-after-stop contract.
    if (self.committed_identity.surface != 0) if (self.owner) |owner| {
        if (owner.currentEpoch() != self.committed_identity.epoch) {
            if (self.stale_slot_available) |available| available(self.context);
            return;
        }
    };
    if (self.counts_frames) _ = frames_presented.fetchAdd(1, .monotonic);
    const continuation = self.cursor_continuation;
    if (self.event) |event| event(self.context, 1) else self.schedule.frame_in_flight = false;
    if (continuation and self.alive and !self.close_requested.load(.acquire)) if (self.event) |event| event(self.context, 3);
}
export fn cmdy_gpu_create(device: ?*const anyopaque, format: u64, samples: usize, now: f64, error_out: [*c]u8, capacity: usize) ?*c.CmdyRenderGPU {
    return create(null, device, format, samples, now, error_out, capacity);
}
export fn cmdy_gpu_create_on_worker(raw_owner: ?*c.CmdyRenderWorker, device: ?*const anyopaque, format: u64, samples: usize, now: f64, error_out: [*c]u8, capacity: usize) ?*c.CmdyRenderGPU {
    const owner: *worker.Worker = @ptrCast(@alignCast(raw_owner orelse return null));
    if (!owner.isWorkerThread() or owner.scope == null) {
        shader.fail(error_out, capacity, "GPU creation requires its render worker and a callback scope");
        return null;
    }
    return create(owner, device, format, samples, now, error_out, capacity);
}
fn create(owner: ?*worker.Worker, device: ?*const anyopaque, format: u64, samples: usize, now: f64, error_out: [*c]u8, capacity: usize) ?*c.CmdyRenderGPU {
    const core = shader.get(device, format, samples, error_out, capacity) orelse return null;
    var adopted = false;
    defer if (!adopted) core.release();
    const self = a.create(Renderer) catch return null;
    const images = image.Cache.create(device, owner) orelse {
        a.destroy(self);
        return null;
    };
    const ring = c.cmdy_render_buffer_ring_create(device, 3, 256 * 1024, 256) orelse {
        images.destroy();
        a.destroy(self);
        return null;
    };
    self.* = .{ .owner = owner, .core = core, .glyphs = glyph.Cache.init(device), .rows = undefined, .images = images, .ring = ring, .schedule = schedule.State.init(now), .start_time = now };
    adopted = true;
    self.rows = cache.Cache.init(device, &self.glyphs);
    if (owner) |thread| self.close_ticket = thread.prepareCompletion(self, ownedClose, noDispose) orelse {
        images.destroy();
        self.release();
        shader.fail(error_out, capacity, "Unable to reserve renderer shutdown");
        return null;
    };
    images.event = notifyImage;
    images.context = self;
    return @ptrCast(self);
}
export fn cmdy_gpu_destroy(raw: ?*c.CmdyRenderGPU) void {
    const self: *Renderer = @ptrCast(@alignCast(raw orelse return));
    if (self.owner) |owner| {
        if (!owner.closePublication(&self.close_requested)) return;
        self.close_ticket.?.publish(.ready);
        return;
    }
    close(self);
}
fn noDispose(_: ?*anyopaque) callconv(.c) void {}
fn ownedClose(context: ?*anyopaque, _: *worker.Worker, _: u32) callconv(.c) void {
    close(@ptrCast(@alignCast(context.?)));
}
fn close(self: *Renderer) void {
    self.alive = false;
    self.event = null;
    self.context = null;
    self.images.destroy();
    self.release();
}
export fn cmdy_gpu_set_event(raw: ?*c.CmdyRenderGPU, event: c.CmdyRenderGPUEvent, context: ?*anyopaque) void {
    const self = renderer(raw) orelse return;
    self.event = event;
    self.context = context;
}
export fn cmdy_zig_gpu_schedule(raw: ?*c.CmdyRenderGPU) ?*anyopaque {
    const self = renderer(raw) orelse return null;
    return &self.schedule;
}
export fn cmdy_gpu_load_shader(raw: ?*c.CmdyRenderGPU, source: [*c]const u8, error_out: [*c]u8, capacity: usize) u8 {
    const self = renderer(raw) orelse return 0;
    c.cmdy_gpu_apple_release(self.user_pipeline);
    self.user_pipeline = null;
    self.user_uses_time = false;
    defer {
        self.schedule.config.has_user_pipeline = self.user_pipeline != null;
        self.schedule.config.user_shader_uses_time = self.user_uses_time;
    }
    if (source == null) return 1;
    const content = std.mem.span(source);
    if (std.mem.trim(u8, content, " \r\n\t").len == 0) return 1;
    if (std.mem.indexOf(u8, content, "cmdy_main") == null) {
        shader.fail(error_out, capacity, "Renderer shader source is missing: cmdy_main");
        return 0;
    }
    self.user_pipeline = shader.userPipeline(self.core.device, self.core.format, @ptrCast(source), error_out, capacity) orelse return 0;
    self.user_uses_time = std.mem.indexOf(u8, content, "u.time") != null or std.mem.indexOf(u8, content, "u . time") != null;
    return 1;
}
export fn cmdy_gpu_has_user_shader(raw: ?*const c.CmdyRenderGPU) u8 {
    const self = constRenderer(raw) orelse return 0;
    return @intFromBool(self.user_pipeline != null);
}
export fn cmdy_gpu_user_shader_uses_time(raw: ?*const c.CmdyRenderGPU) u8 {
    const self = constRenderer(raw) orelse return 0;
    return @intFromBool(self.user_uses_time);
}
export fn cmdy_gpu_set_preset(raw: ?*c.CmdyRenderGPU, preset: u32) void {
    const self = renderer(raw) orelse return;
    if (self.preset != preset) {
        self.preset = preset;
        self.glyphs.invalidatePreset();
    }
    self.rows.clear();
}
export fn cmdy_gpu_resize(raw: ?*c.CmdyRenderGPU) void {
    const self = renderer(raw) orelse return;
    c.cmdy_gpu_apple_release(self.scene);
    self.scene = null;
}
export fn cmdy_gpu_cursor_blink(raw: ?*c.CmdyRenderGPU, eligible: u8) void {
    const self = renderer(raw) orelse return;
    self.schedule.cursor_blink_eligible = eligible != 0;
}
export fn cmdy_gpu_kitty_fit(width: f64, height: f64, container: c.CmdyRenderRect) c.CmdyRenderRect {
    const result = frame.kittyFit(width, height, .{ .x = container.x, .y = container.y, .width = container.width, .height = container.height });
    return .{ .x = result.x, .y = result.y, .width = result.width, .height = result.height };
}
export fn cmdy_gpu_scaled_font(value: ?*const anyopaque, scale: f64) ?*const anyopaque {
    if (value == null) return null;
    var fonts = font_module.Fonts.init(scale, value, false);
    defer fonts.deinit();
    return fonts.scaledFont(value);
}
export fn cmdy_gpu_frame_metrics(rows: isize, cols: isize, cell_width: f64, cell_height: f64, scale: f64, bounds_width: f64, bounds_height: f64, drawable_width: f64, drawable_height: f64) c.CmdyGpuFrameMetrics {
    var result = std.mem.zeroes(c.CmdyGpuFrameMetrics);
    if (rows <= 0 or cols <= 0 or !std.math.isFinite(scale) or scale <= 0 or !std.math.isFinite(cell_width) or !std.math.isFinite(cell_height) or cell_width <= 0 or cell_height <= 0 or bounds_width <= 0 or bounds_height <= 0 or drawable_width <= 0 or drawable_height <= 0) return result;
    result.cell_width = cell_width * scale;
    result.cell_height = cell_height * scale;
    result.cursor_cell_height = result.cell_height / @max(1, scale);
    const width = @ceil(@as(f64, @floatFromInt(cols)) * result.cell_width);
    const height = @ceil(result.cell_height);
    if (!std.math.isFinite(width) or !std.math.isFinite(height) or width <= 0 or height <= 0 or width >= 0x1p63 or height >= 0x1p63) return result;
    result.row_width = @intFromFloat(width);
    result.row_height = @intFromFloat(height);
    result.valid = 1;
    return result;
}
export fn cmdy_gpu_row_lookup(raw: ?*c.CmdyRenderGPU, key: [*c]const c.CmdyGpuRowKey, dirty: u8, revision: c.CmdyGpuRowRevision, inputs: [*c]const c.CmdyRenderRowInput) ?*const c.CmdyRenderGPURow {
    const self = renderer(raw) orelse return null;
    if (key == null) return null;
    return rowHandle(self.rows.lookup(key, dirty != 0, revision, if (inputs == null) null else inputs));
}
export fn cmdy_gpu_row_resolve(raw: ?*c.CmdyRenderGPU, key: [*c]const c.CmdyGpuRowKey, revision: c.CmdyGpuRowRevision, input: [*c]const c.CmdyRenderRowInput, images: [*c]const c.CmdyGpuImagePlacement, image_count: usize, placeholders: [*c]const c.CmdyGpuPlaceholder, placeholder_count: usize) ?*const c.CmdyRenderGPURow {
    const self = renderer(raw) orelse return null;
    if (key == null or input == null) return null;
    return rowHandle(self.rows.resolve(key, revision, input, cache.slice(c.CmdyGpuImagePlacement, images, image_count), cache.slice(c.CmdyGpuPlaceholder, placeholders, placeholder_count)));
}
export fn cmdy_gpu_row_view(raw: ?*const c.CmdyRenderGPURow, out: [*c]c.CmdyGpuRowView) void {
    if (out == null) return;
    const row: *const cache.Row = @ptrCast(@alignCast(raw orelse {
        out.* = std.mem.zeroes(c.CmdyGpuRowView);
        return;
    }));
    out.* = row.payload.view(row.last_use);
}
export fn cmdy_gpu_row_retain(raw: ?*const c.CmdyRenderGPURow) ?*const c.CmdyRenderGPURow {
    const row: *cache.Row = @ptrCast(@alignCast(@constCast(raw orelse return null)));
    return @ptrCast(row.retain());
}
export fn cmdy_gpu_row_release(raw: ?*const c.CmdyRenderGPURow) void {
    const row: *cache.Row = @ptrCast(@alignCast(@constCast(raw orelse return)));
    row.release();
}
export fn cmdy_gpu_row_text_key(raw: ?*const c.CmdyRenderGPURow) ?*const c.CmdyRenderTextKey {
    const row: *const cache.Row = @ptrCast(@alignCast(raw orelse return null));
    return @ptrCast(row.payload.text_key);
}
export fn cmdy_gpu_row_revision(raw: ?*const c.CmdyRenderGPURow) c.CmdyGpuRowRevision {
    const row: *const cache.Row = @ptrCast(@alignCast(raw orelse return .{ .content = 0, .context = 0 }));
    return row.revision;
}
export fn cmdy_gpu_row_raster_inputs(raw: ?*const c.CmdyRenderGPURow, out: [*c]c.CmdyRenderRowInput) void {
    if (out == null) return;
    out.* = std.mem.zeroes(c.CmdyRenderRowInput);
    const row: *const cache.Row = @ptrCast(@alignCast(raw orelse return));
    const v = row.payload.inputs orelse return;
    out[0].cell_width = v.cell_width;
    out[0].cell_height = v.cell_height;
    out[0].scale = v.scale;
    out[0].underline_position = v.underline_position;
    out[0].underline_thickness = v.underline_thickness;
    out[0].normal_font = v.font;
}
export fn cmdy_gpu_weak_owner(weak: ?*const anyopaque) ?*const anyopaque {
    return c.cmdy_gpu_apple_weak_load(weak);
}
export fn cmdy_gpu_rows_clear(raw: ?*c.CmdyRenderGPU) void {
    const self = renderer(raw) orelse return;
    self.rows.clear();
}
export fn cmdy_gpu_rows_trim(raw: ?*c.CmdyRenderGPU, visible: [*c]const isize, count: usize, visible_count: usize) void {
    const self = renderer(raw) orelse return;
    self.rows.trim(cache.slice(isize, visible, count), visible_count);
}
export fn cmdy_gpu_rows_trim_visible(raw: ?*c.CmdyRenderGPU, visible: [*c]const isize, count: usize, grid_rows: usize) void {
    const self = renderer(raw) orelse return;
    self.rows.trim(cache.slice(isize, visible, count), @max(count, grid_rows));
}
export fn cmdy_gpu_rows_count(raw: ?*const c.CmdyRenderGPU) usize {
    const self = constRenderer(raw) orelse return 0;
    return self.rows.rows.count();
}
export fn cmdy_gpu_rows_bytes(raw: ?*const c.CmdyRenderGPU) usize {
    const self = constRenderer(raw) orelse return 0;
    return self.rows.allocated_bytes;
}
export fn cmdy_gpu_rows_keys(raw: ?*const c.CmdyRenderGPU, out: [*c]isize, capacity: usize) usize {
    const self = constRenderer(raw) orelse return 0;
    var it = self.rows.rows.keyIterator();
    var index: usize = 0;
    while (it.next()) |key| {
        if (index < capacity and out != null) out[index] = key.*;
        index += 1;
    }
    return index;
}
export fn cmdy_gpu_row_import(raw: ?*c.CmdyRenderGPU, key: [*c]const c.CmdyGpuRowKey, input: [*c]const c.CmdyGpuRowView) ?*const c.CmdyRenderGPURow {
    const self = renderer(raw) orelse return null;
    if (key == null or input == null) return null;
    return rowHandle(self.rows.importRow(key, input));
}
export fn cmdy_gpu_counter(kind: u32) u64 {
    return switch (kind) {
        0 => frames_presented.load(.monotonic),
        1 => cache.rebuilt.load(.monotonic),
        else => cache.reused.load(.monotonic),
    };
}
export fn cmdy_gpu_counter_set(kind: u32, value: u64) void {
    switch (kind) {
        0 => frames_presented.store(value, .monotonic),
        1 => cache.rebuilt.store(value, .monotonic),
        else => cache.reused.store(value, .monotonic),
    }
}
export fn cmdy_gpu_image_texture(raw: ?*c.CmdyRenderGPU, owner: ?*const anyopaque, image_value: ?*const anyopaque) ?*const anyopaque {
    const self = renderer(raw) orelse return null;
    return self.images.texture(owner, image_value);
}
export fn cmdy_gpu_image_attempts(raw: ?*const c.CmdyRenderGPU) usize {
    const self = constRenderer(raw) orelse return 0;
    return self.images.attempts;
}
export fn cmdy_gpu_image_pending(raw: ?*const c.CmdyRenderGPU) usize {
    const self = constRenderer(raw) orelse return 0;
    return self.images.pendingCount();
}
export fn cmdy_gpu_draw(raw: ?*c.CmdyRenderGPU, input: [*c]const c.CmdyGpuFrame) u8 {
    const self = renderer(raw) orelse return 0;
    return drawWithIdentity(self, input, .{ .surface = 0, .epoch = if (self.owner) |owner| owner.currentEpoch() else 0, .sequence = 0 });
}
fn drawWithIdentity(self: *Renderer, input: [*c]const c.CmdyGpuFrame, identity: c.CmdyRenderFrameIdentity) u8 {
    if (!self.alive or self.schedule.frame_in_flight or self.gpu_ticket != null or input == null or input[0].pass == null) return 0;
    if (self.owner) |owner| {
        self.gpu_ticket = owner.prepareCompletion(self, ownedComplete, noDispose) orelse return 0;
        self.refs += 1;
    }
    const submitted = frame.draw(self, input, identity);
    if (!submitted) if (self.gpu_ticket) |ticket| self.owner.?.rollbackCompletion(ticket);
    return @intFromBool(submitted);
}
export fn cmdy_gpu_draw_captured(raw: ?*c.CmdyRenderGPU, captured: ?*const c.CmdyRenderOwnedFrameInput, drawable: ?*const anyopaque, pass: ?*const anyopaque) u8 {
    const self = renderer(raw) orelse return 0;
    if (pass == null or !self.alive or self.schedule.frame_in_flight or self.gpu_ticket != null) return 0;
    const metadata = c.cmdy_render_frame_input_metadata(captured) orelse return 0;
    if (!capturedCurrent(self, metadata.*.identity)) return 0;
    const input = c.cmdy_render_frame_input_view(captured) orelse return 0;
    if (self.captured_surface != input.*.identity.surface or self.captured_epoch != input.*.identity.epoch) {
        self.rows.clear();
        self.captured_surface = input.*.identity.surface;
        self.captured_epoch = input.*.identity.epoch;
    }
    var rows: std.ArrayList(c.CmdyGpuFrameRow) = .empty;
    defer {
        for (rows.items) |row| (@as(*cache.Row, @ptrCast(@alignCast(@constCast(row.entry.?))))).release();
        rows.deinit(a);
    }
    const native: *const @import("render_frame_input.zig").Frame = @ptrCast(@alignCast(captured.?));
    if (native.viewportInput()) |viewport| {
        if (input.*.alternate_buffer != 0)
            self.rows.pruneAlternate(input.*.retained_row_origin, input.*.buffer_line_count);
        rows.ensureTotalCapacity(a, viewport.visible.count()) catch return 0;
        for (0..viewport.visible.count()) |index| {
            const request = viewport.visible.at(index).?;
            const entry = self.rows.resolveViewport(viewport, request) orelse return 0;
            var row: c.CmdyGpuFrameRow = @bitCast(viewport.placement(request));
            row.entry = rowHandle(entry.retain());
            rows.appendAssumeCapacity(row);
        }
    } else {
        rows.ensureTotalCapacity(a, input.*.row_count) catch return 0;
        for (cache.slice(c.CmdyRenderFrameRowInput, input.*.rows, input.*.row_count)) |*source| {
            const entry = self.rows.resolveCaptured(source) orelse return 0;
            var row = source.placement;
            row.entry = rowHandle(entry.retain());
            rows.appendAssumeCapacity(row);
        }
    }
    var parameters = input.*.parameters;
    parameters.drawable = drawable;
    parameters.pass = pass;
    parameters.rows = if (rows.items.len == 0) null else rows.items.ptr;
    parameters.row_count = rows.items.len;
    return drawWithIdentity(self, &parameters, input.*.identity);
}
fn capturedCurrent(self: *Renderer, identity: c.CmdyRenderFrameIdentity) bool {
    const owner = self.owner orelse return false;
    if (identity.epoch != owner.currentEpoch()) return false;
    const previous = self.committed_identity;
    if (previous.surface != 0 and previous.epoch == identity.epoch) {
        if (previous.surface != identity.surface or identity.sequence < previous.sequence) return false;
    }
    return true;
}
export fn cmdy_gpu_draw_target(raw: ?*c.CmdyRenderGPU, captured: ?*const c.CmdyRenderOwnedFrameInput, raw_target: ?*c.CmdyRenderOwnedTarget) u8 {
    const self = renderer(raw) orelse return 0;
    if (!self.alive or self.schedule.frame_in_flight or self.gpu_ticket != null) return 0;
    const value: *target.Target = @ptrCast(@alignCast(raw_target orelse return 0));
    const input = c.cmdy_render_frame_input_metadata(captured) orelse return 0;
    if (!std.meta.eql(value.identity, input.*.identity) or !capturedCurrent(self, value.identity)) return 0;
    if (value.info.device != self.core.device or value.info.format != self.core.format or value.info.samples != self.core.samples) return 0;
    if (input.*.parameters.width != @as(f64, @floatFromInt(value.info.width)) or
        input.*.parameters.height != @as(f64, @floatFromInt(value.info.height))) return 0;
    if (!value.claim()) return 0;
    return cmdy_gpu_draw_captured(raw, captured, value.drawable, value.pass);
}
export fn cmdy_gpu_cache_glyph(raw: ?*c.CmdyRenderGPU, font: ?*const anyopaque, glyph_value: u16, out: [*c]c.CmdyGpuGlyphEntry) u8 {
    const self = renderer(raw) orelse return 0;
    if (out == null) return 0;
    out.* = self.glyphs.compatibilityGlyph(font, glyph_value, self.preset) orelse return 0;
    return 1;
}
export fn cmdy_gpu_color_atlas_allocations(raw: ?*const c.CmdyRenderGPU) usize {
    const self = constRenderer(raw) orelse return 0;
    return self.glyphs.color_allocations;
}
export fn cmdy_gpu_color_atlas_capacity(raw: ?*const c.CmdyRenderGPU) usize {
    const self = constRenderer(raw) orelse return 0;
    return if (self.glyphs.color_atlas == null) 0 else 4;
}
