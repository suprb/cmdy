//! Native-owned Metal source and immutable pipeline sharing.
const std = @import("std");
pub const c = @cImport({
    @cInclude("platform_gpu.h");
    @cInclude("cmdy_render_gpu.h");
    @cInclude("cmdy_render_frame_input.h");
    @cInclude("cmdy_render_session.h");
    @cInclude("cmdy_render_cursor_cache.h");
});
const a = std.heap.c_allocator;
pub const core_source = @embedFile("render_shader_core.metal");
pub const effect_source = @embedFile("render_shader_effects.metal");
pub const preamble = @embedFile("render_shader_preamble.metal");
pub const wrapper = @embedFile("render_shader_wrapper.metal");
pub const Shared = struct {
    refs: std.atomic.Value(usize) = .init(1),
    device: ?*anyopaque,
    format: u64,
    samples: usize,
    queue: ?*anyopaque = null,
    solid: ?*anyopaque = null,
    coverage: ?*anyopaque = null,
    image: ?*anyopaque = null,
    post: ?*anyopaque = null,
    scene_effect: ?*anyopaque = null,
    databloom: ?*anyopaque = null,
    linear: ?*anyopaque = null,
    nearest: ?*anyopaque = null,
    pub fn retain(self: *Shared) *Shared {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    pub fn release(self: *Shared) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        inline for (.{ "device", "queue", "solid", "coverage", "image", "post", "scene_effect", "databloom", "linear", "nearest" }) |field| c.cmdy_gpu_apple_release(@field(self, field));
        a.destroy(self);
    }
};
var shared: std.ArrayList(*Shared) = .empty;
var shared_mutex: std.Thread.Mutex = .{};
var constructions: usize = 0;
pub fn fail(error_out: [*c]u8, capacity: usize, message: []const u8) void {
    if (error_out == null or capacity == 0) return;
    const n = @min(message.len, capacity - 1);
    @memcpy(error_out[0..n], message[0..n]);
    error_out[n] = 0;
}
/// Returns an owned reference, acquired before reset can remove the registry's.
pub fn get(device: ?*const anyopaque, format: u64, sample_count: usize, error_out: [*c]u8, capacity: usize) ?*Shared {
    shared_mutex.lock();
    defer shared_mutex.unlock();
    const samples = @max(1, sample_count);
    for (shared.items) |value| if (value.device == device and value.format == format and value.samples == samples) return value.retain();
    const value = a.create(Shared) catch return null;
    value.* = .{ .device = c.cmdy_gpu_apple_retain(device), .format = format, .samples = samples };
    var success = false;
    defer if (!success) value.release();
    value.queue = c.cmdy_gpu_apple_queue(device) orelse {
        fail(error_out, capacity, "Unable to create a Metal command queue");
        return null;
    };
    const library = c.cmdy_gpu_apple_library(device, core_source, error_out, capacity) orelse return null;
    defer c.cmdy_gpu_apple_release(library);
    const effects = c.cmdy_gpu_apple_library(device, effect_source, error_out, capacity) orelse return null;
    defer c.cmdy_gpu_apple_release(effects);
    value.solid = c.cmdy_gpu_apple_pipeline(device, library, "cmdy_independent_vertex", "cmdy_independent_solid", "cmdy independent cmdy_independent_solid", format, samples, 1, error_out, capacity) orelse return null;
    value.coverage = c.cmdy_gpu_apple_pipeline(device, library, "cmdy_independent_vertex", "cmdy_independent_coverage", "cmdy independent cmdy_independent_coverage", format, samples, 2, error_out, capacity) orelse return null;
    value.image = c.cmdy_gpu_apple_pipeline(device, library, "cmdy_independent_vertex", "cmdy_independent_image", "cmdy independent cmdy_independent_image", format, samples, 2, error_out, capacity) orelse return null;
    value.post = c.cmdy_gpu_apple_pipeline(device, library, "cmdy_independent_vertex", "cmdy_independent_post", "cmdy independent cmdy_independent_post", format, samples, 0, error_out, capacity) orelse return null;
    value.scene_effect = c.cmdy_gpu_apple_pipeline(device, effects, "cmdy_scene_effect_vertex", "cmdy_scene_effect_fragment", "Cmdy built-in effect: cmdy_scene_effect_fragment", format, samples, 0, error_out, capacity) orelse return null;
    value.databloom = c.cmdy_gpu_apple_pipeline(device, effects, "cmdy_databloom_glyph_vertex", "cmdy_databloom_glyph_fragment", "Cmdy built-in effect: cmdy_databloom_glyph_fragment", format, samples, 2, error_out, capacity) orelse return null;
    value.linear = c.cmdy_gpu_apple_sampler(device, 0) orelse return null;
    value.nearest = c.cmdy_gpu_apple_sampler(device, 1) orelse return null;
    shared.append(a, value) catch return null;
    constructions += 1;
    success = true;
    return value.retain();
}
pub fn userPipeline(device: ?*const anyopaque, format: u64, source: [*:0]const u8, error_out: [*c]u8, capacity: usize) ?*anyopaque {
    const full = std.mem.concatWithSentinel(a, u8, &.{ preamble, "\n", std.mem.span(source), "\n", wrapper }, 0) catch return null;
    defer a.free(full);
    const library = c.cmdy_gpu_apple_library(device, full, error_out, capacity) orelse return null;
    defer c.cmdy_gpu_apple_release(library);
    return c.cmdy_gpu_apple_pipeline(device, library, "cmdy_user_vertex", "cmdy_user_fragment", "cmdy independent user shader", format, 1, 0, error_out, capacity);
}
export fn cmdy_gpu_shader_source(kind: u32) [*:0]const u8 {
    return switch (kind) {
        0 => core_source,
        1 => effect_source,
        2 => preamble,
        else => wrapper,
    };
}
export fn cmdy_gpu_shader_library(device: ?*const anyopaque, kind: u32, error_out: [*c]u8, capacity: usize) ?*const anyopaque {
    return c.cmdy_gpu_apple_library(device, cmdy_gpu_shader_source(kind), error_out, capacity);
}
export fn cmdy_gpu_effect_pipeline(device: ?*const anyopaque, format: u64, samples: usize, glyph: u8, error_out: [*c]u8, capacity: usize) ?*const anyopaque {
    const value = get(device, format, samples, error_out, capacity) orelse return null;
    defer value.release();
    return c.cmdy_gpu_apple_retain(if (glyph != 0) value.databloom else value.scene_effect);
}
export fn cmdy_gpu_shared_identity(device: ?*const anyopaque, format: u64, samples: usize, error_out: [*c]u8, capacity: usize) ?*const anyopaque {
    const value = get(device, format, samples, error_out, capacity) orelse return null;
    defer value.release();
    // Keep the returned identity alive even if a concurrent reset removes core.
    return c.cmdy_gpu_apple_retain(value.queue);
}
export fn cmdy_gpu_shared_queue(device: ?*const anyopaque, format: u64, samples: usize, error_out: [*c]u8, capacity: usize) ?*const anyopaque {
    return cmdy_gpu_shared_identity(device, format, samples, error_out, capacity);
}
export fn cmdy_gpu_shared_reset() void {
    shared_mutex.lock();
    var previous = shared;
    shared = .empty;
    shared_mutex.unlock();
    for (previous.items) |value| value.release();
    previous.deinit(a);
}
export fn cmdy_gpu_shared_constructions() usize {
    shared_mutex.lock();
    defer shared_mutex.unlock();
    return constructions;
}
