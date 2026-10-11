//! A single-use owned Metal target, paired with immutable frame identity.
const std = @import("std");
const c = @import("render_shader.zig").c;
const a = std.heap.c_allocator;

pub const Target = struct {
    refs: std.atomic.Value(usize) = .init(1),
    claimed: std.atomic.Value(bool) = .init(false),
    identity: c.CmdyRenderFrameIdentity,
    info: c.CmdyGpuAppleTargetInfo,
    drawable: ?*anyopaque,
    pass: *anyopaque,

    fn release(self: *Target) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        c.cmdy_gpu_apple_release(self.drawable);
        c.cmdy_gpu_apple_release(self.pass);
        c.cmdy_gpu_apple_release(self.info.device);
        a.destroy(self);
    }
    pub fn claim(self: *Target) bool {
        return !self.claimed.swap(true, .acq_rel);
    }
};

export fn cmdy_render_target_capture(identity: c.CmdyRenderFrameIdentity, drawable: ?*const anyopaque, pass: ?*const anyopaque, status: ?*u32) ?*Target {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    if (identity.surface == 0 or identity.epoch == 0 or identity.sequence == 0 or pass == null) return null;
    var info: c.CmdyGpuAppleTargetInfo = undefined;
    const copy = c.cmdy_gpu_apple_capture_pass(pass, drawable, &info) orelse return null;
    const result = a.create(Target) catch {
        c.cmdy_gpu_apple_release(copy);
        if (status) |out| out.* = c.CMDY_RENDER_INPUT_OUT_OF_MEMORY;
        return null;
    };
    info.device = c.cmdy_gpu_apple_retain(info.device);
    result.* = .{ .identity = identity, .info = info, .drawable = c.cmdy_gpu_apple_retain(drawable), .pass = copy };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_target_retain(raw: ?*Target) ?*Target {
    const self = raw orelse return null;
    _ = self.refs.fetchAdd(1, .monotonic);
    return self;
}
export fn cmdy_render_target_release(raw: ?*Target) void {
    if (raw) |self| self.release();
}
