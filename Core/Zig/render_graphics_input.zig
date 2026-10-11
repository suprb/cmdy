//! Immutable graphics publication from the terminal owner to the render owner.
//! Only payload references and copied metadata survive; mutable stores and
//! image identity observers are never retained.
const std = @import("std");
const graphics = @import("graphics.zig");
pub const c = @cImport(@cInclude("cmdy_render_frame_input.h"));

pub const Graphics = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    payloads: []*graphics.Payload = &.{},
    retained: usize = 0,
    images: []c.CmdyGpuKittyImage = &.{},
    placements: [2][]c.CmdyGpuKittyPlacement = .{ &.{}, &.{} },
    ids: []u32 = &.{},
    views: [2]c.CmdyRenderGraphicsView = std.mem.zeroes([2]c.CmdyRenderGraphicsView),

    pub fn capture(a: std.mem.Allocator, store: *const graphics.KittyGraphicsStore) std.mem.Allocator.Error!*Graphics {
        const self = try a.create(Graphics);
        self.* = .{ .allocator = a };
        errdefer self.release();
        const source = store.images_by_id.values();
        self.payloads = try a.alloc(*graphics.Payload, source.len);
        self.images = try a.alloc(c.CmdyGpuKittyImage, source.len);
        self.ids = try a.alloc(u32, source.len);
        for (source, 0..) |image, index| {
            const payload = image.payload;
            self.payloads[index] = payload.retain();
            self.retained += 1;
            self.ids[index] = image.id;
            const png = payload.format == .png;
            self.images[index] = .{
                .image_id = image.id,
                .kind = if (png) 0 else 1,
                .bytes = if (payload.bytes.len == 0) null else payload.bytes.ptr,
                .byte_count = payload.bytes.len,
                .width = if (png) 0 else payload.source_width,
                .height = if (png) 0 else payload.source_height,
            };
        }
        var counts: [2]usize = .{ 0, 0 };
        for (store.placements_by_key.values()) |placement| {
            if (placement.is_virtual) counts[@intFromBool(placement.is_alternate_buffer)] += 1;
        }
        for (0..2) |buffer| self.placements[buffer] = try a.alloc(c.CmdyGpuKittyPlacement, counts[buffer]);
        counts = .{ 0, 0 };
        for (store.placements_by_key.values()) |placement| {
            if (!placement.is_virtual) continue;
            const buffer = @intFromBool(placement.is_alternate_buffer);
            self.placements[buffer][counts[buffer]] = .{
                .image_id = placement.image_id,
                .placement_id = placement.placement_id,
                .cols = placement.cols,
                .rows = placement.rows,
                .offset_x = placement.offset_x,
                .offset_y = placement.offset_y,
            };
            counts[buffer] += 1;
        }
        for (&self.views, 0..) |*view, buffer| view.* = .{
            .images = if (self.images.len == 0) null else self.images.ptr,
            .image_count = self.images.len,
            .placements = if (self.placements[buffer].len == 0) null else self.placements[buffer].ptr,
            .placement_count = self.placements[buffer].len,
            .live_ids = if (self.ids.len == 0) null else self.ids.ptr,
            .live_count = self.ids.len,
        };
        return self;
    }
    pub fn retain(self: *Graphics) *Graphics {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Graphics) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        const a = self.allocator;
        const payloads = self.payloads;
        const retained = self.retained;
        a.free(self.images);
        for (self.placements) |placements| a.free(placements);
        a.free(self.ids);
        a.destroy(self);
        // An original host payload deallocator may reenter. Native snapshot
        // metadata is already destroyed; do not access self after release.
        for (payloads[0..retained]) |payload| payload.release();
        a.free(payloads);
    }
};

export fn cmdy_render_graphics_input_capture(store: ?*const graphics.KittyGraphicsStore, status: ?*u32) ?*Graphics {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = store orelse return null;
    const result = Graphics.capture(std.heap.c_allocator, source) catch {
        if (status) |out| out.* = c.CMDY_RENDER_INPUT_OUT_OF_MEMORY;
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_graphics_input_retain(value: ?*Graphics) ?*Graphics {
    return if (value) |snapshot| snapshot.retain() else null;
}
export fn cmdy_render_graphics_input_release(value: ?*Graphics) void {
    if (value) |snapshot| snapshot.release();
}
export fn cmdy_render_graphics_input_view(value: ?*const Graphics, alternate: u8) ?*const c.CmdyRenderGraphicsView {
    if (alternate > 1) return null;
    return if (value) |snapshot| &snapshot.views[alternate] else null;
}

test {
    _ = @import("render_graphics_input_tests.zig");
}
