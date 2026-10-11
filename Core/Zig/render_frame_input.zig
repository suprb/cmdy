//! Immutable frame content. GPU target acquisition and cache mutation belong
//! to the rendering owner, never to this capture operation.
const std = @import("std");
pub const Graphics = @import("render_graphics_input.zig").Graphics;
pub const Viewport = @import("render_viewport.zig").Viewport;
const ImagePayload = @import("graphics.zig").Payload;
pub const c = @cImport(@cInclude("cmdy_render_frame_input.h"));
pub const CaptureError = error{ InvalidInput, OutOfMemory };

fn slice(comptime T: type, pointer: [*c]const T, count: usize) CaptureError![]const T {
    if (count == 0) return &.{};
    if (pointer == null or @intFromPtr(pointer) % @alignOf(T) != 0 or
        count > @as(usize, std.math.maxInt(isize)) / @sizeOf(T)) return error.InvalidInput;
    return pointer[0..count];
}

pub const Image = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    bytes: []const u8,
    payload_owner: ?*ImagePayload = null,
    view: c.CmdyRenderImageInput,

    pub fn create(allocator: std.mem.Allocator, input: *const c.CmdyRenderImageInput) CaptureError!*Image {
        if (input.kind > 1) return error.InvalidInput;
        const source = try slice(u8, input.bytes, input.byte_count);
        const self = try allocator.create(Image);
        errdefer allocator.destroy(self);
        const bytes = try allocator.dupe(u8, source);
        self.* = .{ .allocator = allocator, .bytes = bytes, .view = input.* };
        self.view.bytes = if (bytes.len == 0) null else bytes.ptr;
        return self;
    }
    pub fn retain(self: *Image) *Image {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn share(allocator: std.mem.Allocator, payload: *ImagePayload, identity: [16]u8) CaptureError!*Image {
        const self = try allocator.create(Image);
        const png = payload.format == .png;
        self.* = .{ .allocator = allocator, .payload_owner = payload.retain(), .bytes = payload.bytes, .view = .{ .identity = identity, .kind = if (png) 0 else 1, .bytes = if (payload.bytes.len == 0) null else payload.bytes.ptr, .byte_count = payload.bytes.len, .width = if (png) 0 else payload.source_width, .height = if (png) 0 else payload.source_height } };
        return self;
    }
    pub fn release(self: *Image) void {
        const old = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 0);
        if (old != 1) return;
        const allocator = self.allocator;
        const payload = self.payload_owner;
        if (payload == null) allocator.free(self.bytes);
        allocator.destroy(self);
        if (payload) |owner| owner.release();
    }
};

/// A reusable immutable row description. Frame placement is separate, so a
/// selection or viewport change does not copy text, names or image metadata.
pub fn RowStorage(comptime References: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        refs: std.atomic.Value(usize) = .init(1),
        retained_text: ?*c.CmdyRenderOwnedRowInput = null,
        retained_images: usize = 0,
        view: c.CmdyRenderFrameRowInput,

        pub fn create(allocator: std.mem.Allocator, input: *const c.CmdyRenderFrameRowInput) CaptureError!*Self {
            if (input.placement.entry != null) return error.InvalidInput;
            const text = input.text orelse return error.InvalidInput;
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .arena = .init(allocator), .view = input.* };
            errdefer self.destroy();
            References.retainText(text);
            self.retained_text = text;
            const arena = self.arena.allocator();
            const name = try slice(u8, @ptrCast(input.key.font_name), input.font_name_bytes);
            self.view.key.font_name = try arena.dupeZ(u8, name);
            const images = try arena.dupe(c.CmdyRenderFrameImageInput, try slice(c.CmdyRenderFrameImageInput, input.images, input.image_count));
            self.view.images = if (images.len == 0) null else images.ptr;
            for (images) |image| {
                if (image.placement.owner != null or image.placement.image != null or image.placement.owned_image != null) return error.InvalidInput;
                const payload = image.payload orelse return error.InvalidInput;
                References.retainImage(payload);
                self.retained_images += 1;
            }
            const placeholders = try arena.dupe(c.CmdyGpuPlaceholder, try slice(c.CmdyGpuPlaceholder, input.placeholders, input.placeholder_count));
            self.view.placeholders = if (placeholders.len == 0) null else placeholders.ptr;
            return self;
        }
        pub fn retain(self: *Self) *Self {
            const old = self.refs.fetchAdd(1, .monotonic);
            std.debug.assert(old > 0 and old < std.math.maxInt(usize));
            return self;
        }
        pub fn release(self: *Self) void {
            const old = self.refs.fetchSub(1, .acq_rel);
            std.debug.assert(old > 0);
            if (old == 1) self.destroy();
        }
        fn destroy(self: *Self) void {
            if (self.retained_text) |text| References.releaseText(text);
            for (0..self.retained_images) |i| References.releaseImage(self.view.images[i].payload.?);
            self.arena.deinit();
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}

fn scalarMetadata(input: c.CmdyRenderFrameInput) c.CmdyRenderFrameInput {
    var result = input;
    result.rows = null;
    result.row_count = 0;
    result.parameters.drawable = null;
    result.parameters.pass = null;
    result.parameters.rows = null;
    result.parameters.row_count = 0;
    result.parameters.kitty_images = null;
    result.parameters.kitty_image_count = 0;
    result.parameters.kitty_placements = null;
    result.parameters.kitty_placement_count = 0;
    result.parameters.live_kitty_ids = null;
    result.parameters.live_kitty_count = 0;
    return result;
}

pub fn Storage(comptime References: type) type {
    return struct {
        const Self = @This();
        const Row = RowStorage(References);
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        refs: std.atomic.Value(usize) = .init(1),
        texts: std.ArrayList(*c.CmdyRenderOwnedRowInput) = .empty,
        images: std.ArrayList(*c.CmdyRenderOwnedImageInput) = .empty,
        graphics_owner: ?*Graphics = null,
        viewport: ?*Viewport = null,
        content_owner: ?*Self = null,
        row_references: []const c.CmdyRenderFrameRowReference = &.{},
        assembled_rows: []c.CmdyRenderFrameRowInput = &.{},
        ready: std.atomic.Value(bool) = .init(true),
        preparation: std.Thread.Mutex = .{},
        metadata: c.CmdyRenderFrameInput,
        view: c.CmdyRenderFrameInput,

        pub fn create(allocator: std.mem.Allocator, input: *const c.CmdyRenderFrameInput) CaptureError!*Self {
            const f = input.parameters;
            if (input.identity.surface == 0 or input.identity.epoch == 0 or input.identity.sequence == 0 or
                f.drawable != null or f.pass != null or f.rows != null or f.row_count != 0) return error.InvalidInput;
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .arena = .init(allocator), .metadata = scalarMetadata(input.*), .view = input.* };
            errdefer self.destroy();
            const arena = self.arena.allocator();

            const rows = try arena.dupe(c.CmdyRenderFrameRowInput, try slice(c.CmdyRenderFrameRowInput, input.rows, input.row_count));
            self.view.rows = if (rows.len == 0) null else rows.ptr;
            for (rows) |*row| {
                if (row.placement.entry != null) return error.InvalidInput;
                const text = row.text orelse return error.InvalidInput;
                try self.texts.append(allocator, text);
                References.retainText(text);
                const name = try slice(u8, @ptrCast(row.key.font_name), row.font_name_bytes);
                row.key.font_name = try arena.dupeZ(u8, name);
                const images = try arena.dupe(c.CmdyRenderFrameImageInput, try slice(c.CmdyRenderFrameImageInput, row.images, row.image_count));
                row.images = if (images.len == 0) null else images.ptr;
                for (images) |image| {
                    if (image.placement.owner != null or image.placement.image != null or image.placement.owned_image != null) return error.InvalidInput;
                    const payload = image.payload orelse return error.InvalidInput;
                    try self.images.append(allocator, payload);
                    References.retainImage(payload);
                }
                const placeholders = try arena.dupe(c.CmdyGpuPlaceholder, try slice(c.CmdyGpuPlaceholder, row.placeholders, row.placeholder_count));
                row.placeholders = if (placeholders.len == 0) null else placeholders.ptr;
            }
            const kitty = try arena.dupe(c.CmdyGpuKittyImage, try slice(c.CmdyGpuKittyImage, f.kitty_images, f.kitty_image_count));
            self.view.parameters.kitty_images = if (kitty.len == 0) null else kitty.ptr;
            for (kitty) |*image| {
                const bytes = try arena.dupe(u8, try slice(u8, image.bytes, image.byte_count));
                image.bytes = if (bytes.len == 0) null else bytes.ptr;
            }
            const placements = try arena.dupe(c.CmdyGpuKittyPlacement, try slice(c.CmdyGpuKittyPlacement, f.kitty_placements, f.kitty_placement_count));
            self.view.parameters.kitty_placements = if (placements.len == 0) null else placements.ptr;
            const ids = try arena.dupe(u32, try slice(u32, f.live_kitty_ids, f.live_kitty_count));
            self.view.parameters.live_kitty_ids = if (ids.len == 0) null else ids.ptr;
            return self;
        }
        pub fn createReferenced(allocator: std.mem.Allocator, input: *const c.CmdyRenderFrameInput, references: [*c]const c.CmdyRenderFrameRowReference, count: usize) CaptureError!*Self {
            if (input.rows != null or input.row_count != 0) return error.InvalidInput;
            const source = try slice(c.CmdyRenderFrameRowReference, references, count);
            const self = try Self.create(allocator, input);
            errdefer self.destroy();
            const arena = self.arena.allocator();
            const rows = try arena.dupe(c.CmdyRenderFrameRowReference, source);
            // Reserve uninitialized destination storage on the producer. The
            // render worker only fills it; first-view assembly cannot fail.
            self.assembled_rows = try arena.alloc(c.CmdyRenderFrameRowInput, count);
            for (rows, 0..) |reference, i| {
                if (reference.placement.entry != null) return error.InvalidInput;
                const row = reference.row orelse return error.InvalidInput;
                if (@intFromPtr(row) % @alignOf(Row) != 0) return error.InvalidInput;
                _ = (@as(*Row, @ptrCast(@alignCast(row)))).retain();
                self.row_references = rows[0 .. i + 1];
            }
            self.ready.store(false, .monotonic);
            return self;
        }
        pub fn createReferencedGraphics(allocator: std.mem.Allocator, input: *const c.CmdyRenderFrameInput, references: [*c]const c.CmdyRenderFrameRowReference, count: usize, graphics: *Graphics) CaptureError!*Self {
            const f = input.parameters;
            if (input.alternate_buffer > 1 or
                f.kitty_images != null or f.kitty_image_count != 0 or
                f.kitty_placements != null or f.kitty_placement_count != 0 or
                f.live_kitty_ids != null or f.live_kitty_count != 0) return error.InvalidInput;
            const self = try Self.createReferenced(allocator, input, references, count);
            self.graphics_owner = graphics.retain();
            const view = graphics.views[input.alternate_buffer];
            self.view.parameters.kitty_images = @ptrCast(view.images);
            self.view.parameters.kitty_image_count = view.image_count;
            self.view.parameters.kitty_placements = @ptrCast(view.placements);
            self.view.parameters.kitty_placement_count = view.placement_count;
            self.view.parameters.live_kitty_ids = view.live_ids;
            self.view.parameters.live_kitty_count = view.live_count;
            return self;
        }
        /// Metadata never reads the mutable-to-frozen view. Only this method
        /// publishes that view; acquire/release makes concurrent readers safe.
        /// No allocation, source access, text preparation or GPU work occurs.
        pub fn preparedView(self: *Self) *const c.CmdyRenderFrameInput {
            if (self.ready.load(.acquire)) return &self.view;
            self.preparation.lock();
            defer self.preparation.unlock();
            if (self.ready.load(.acquire)) return &self.view;
            if (self.content_owner) |owner| {
                self.adoptContent(owner.preparedView());
            } else {
                for (self.row_references, self.assembled_rows) |reference, *row| {
                    row.* = (@as(*const Row, @ptrCast(@alignCast(reference.row.?)))).view;
                    row.placement = reference.placement;
                }
                self.view.rows = if (self.assembled_rows.len == 0) null else self.assembled_rows.ptr;
                self.view.row_count = self.assembled_rows.len;
            }
            self.ready.store(true, .release);
            return &self.view;
        }
        pub fn viewportInput(self: *const Self) ?*const Viewport {
            return if (self.content_owner) |owner| owner.viewport else self.viewport;
        }
        pub fn createViewport(allocator: std.mem.Allocator, input: *const c.CmdyRenderFrameInput, source: *const c.CmdyRenderViewportInput, graphics: ?*Graphics) CaptureError!*Self {
            const f = input.parameters;
            if (input.rows != null or input.row_count != 0 or f.kitty_images != null or f.kitty_image_count != 0 or
                f.kitty_placements != null or f.kitty_placement_count != 0 or f.live_kitty_ids != null or f.live_kitty_count != 0) return error.InvalidInput;
            const self = if (graphics) |g| try createReferencedGraphics(allocator, input, null, 0, g) else try create(allocator, input);
            errdefer self.release();
            self.viewport = try Viewport.capture(allocator, @ptrCast(input), @ptrCast(source));
            return self;
        }
        fn adoptContent(self: *Self, content: *const c.CmdyRenderFrameInput) void {
            self.view.rows = content.rows;
            self.view.row_count = content.row_count;
            self.view.parameters.kitty_images = content.parameters.kitty_images;
            self.view.parameters.kitty_image_count = content.parameters.kitty_image_count;
            self.view.parameters.kitty_placements = content.parameters.kitty_placements;
            self.view.parameters.kitty_placement_count = content.parameters.kitty_placement_count;
            self.view.parameters.live_kitty_ids = content.parameters.live_kitty_ids;
            self.view.parameters.live_kitty_count = content.parameters.live_kitty_count;
        }
        /// Reuse only frozen nested content. The caller establishes that row
        /// contents, placements, selection ranges and Kitty resources match.
        /// Every scalar comes from the new metadata. Descendants retain the
        /// original content owner directly, avoiding an unbounded frame chain.
        pub fn reuse(self: *Self, allocator: std.mem.Allocator, input: *const c.CmdyRenderFrameInput) CaptureError!*Self {
            const f = input.parameters;
            if (input.identity.surface != self.metadata.identity.surface or
                input.identity.epoch != self.metadata.identity.epoch or input.identity.sequence == 0 or
                input.rows != null or input.row_count != 0 or
                f.drawable != null or f.pass != null or f.rows != null or f.row_count != 0 or
                f.kitty_images != null or f.kitty_image_count != 0 or
                f.kitty_placements != null or f.kitty_placement_count != 0 or
                f.live_kitty_ids != null or f.live_kitty_count != 0) return error.InvalidInput;
            const owner = self.content_owner orelse self;
            const result = try allocator.create(Self);
            result.* = .{ .allocator = allocator, .arena = .init(allocator), .metadata = scalarMetadata(input.*), .view = input.*, .content_owner = owner.retain() };
            if (owner.ready.load(.acquire)) {
                result.adoptContent(&owner.view);
            } else {
                // Producer/session admission must not assemble an older frame.
                result.ready.store(false, .monotonic);
            }
            return result;
        }
        pub fn retain(self: *Self) *Self {
            const old = self.refs.fetchAdd(1, .monotonic);
            std.debug.assert(old > 0 and old < std.math.maxInt(usize));
            return self;
        }
        pub fn release(self: *Self) void {
            const old = self.refs.fetchSub(1, .acq_rel);
            std.debug.assert(old > 0);
            if (old == 1) self.destroy();
        }
        fn destroy(self: *Self) void {
            for (self.row_references) |reference| (@as(*Row, @ptrCast(@alignCast(reference.row.?)))).release();
            for (self.texts.items) |text| References.releaseText(text);
            for (self.images.items) |image| References.releaseImage(image);
            self.texts.deinit(self.allocator);
            self.images.deinit(self.allocator);
            self.arena.deinit();
            const owner = self.content_owner;
            const graphics = self.graphics_owner;
            const viewport = self.viewport;
            const allocator = self.allocator;
            allocator.destroy(self);
            if (owner) |parent| parent.release();
            if (graphics) |snapshot| snapshot.release();
            if (viewport) |snapshot| snapshot.destroy();
        }
    };
}
const NativeReferences = struct {
    fn retainText(text: *c.CmdyRenderOwnedRowInput) void {
        _ = c.cmdy_render_input_retain(text);
    }
    fn releaseText(text: *c.CmdyRenderOwnedRowInput) void {
        c.cmdy_render_input_release(text);
    }
    fn retainImage(image: *c.CmdyRenderOwnedImageInput) void {
        _ = (@as(*Image, @ptrCast(@alignCast(image)))).retain();
    }
    fn releaseImage(image: *c.CmdyRenderOwnedImageInput) void {
        (@as(*Image, @ptrCast(@alignCast(image)))).release();
    }
};
pub const Frame = Storage(NativeReferences);
pub const FrameRow = RowStorage(NativeReferences);

fn fail(status: ?*u32, err: CaptureError) void {
    if (status) |value| value.* = switch (err) {
        error.InvalidInput => c.CMDY_RENDER_INPUT_INVALID,
        error.OutOfMemory => c.CMDY_RENDER_INPUT_OUT_OF_MEMORY,
    };
}
export fn cmdy_render_image_input_capture(input: ?*const c.CmdyRenderImageInput, status: ?*u32) ?*Image {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const result = Image.create(std.heap.c_allocator, source) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_image_input_view(image: ?*const Image) ?*const c.CmdyRenderImageInput {
    return if (image) |p| &p.view else null;
}
export fn cmdy_render_image_input_retain(image: ?*Image) ?*Image {
    return if (image) |p| p.retain() else null;
}
export fn cmdy_render_image_input_release(image: ?*Image) void {
    if (image) |p| p.release();
}
export fn cmdy_render_frame_input_capture(input: ?*const c.CmdyRenderFrameInput, status: ?*u32) ?*Frame {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const result = Frame.create(std.heap.c_allocator, source) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_frame_row_capture(input: ?*const c.CmdyRenderFrameRowInput, status: ?*u32) ?*FrameRow {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const result = FrameRow.create(std.heap.c_allocator, source) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_frame_row_retain(row: ?*FrameRow) ?*FrameRow {
    return if (row) |p| p.retain() else null;
}
export fn cmdy_render_frame_row_release(row: ?*FrameRow) void {
    if (row) |p| p.release();
}
export fn cmdy_render_frame_input_capture_referenced(input: ?*const c.CmdyRenderFrameInput, rows: [*c]const c.CmdyRenderFrameRowReference, count: usize, status: ?*u32) ?*Frame {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const result = Frame.createReferenced(std.heap.c_allocator, source, rows, count) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_frame_input_metadata(frame: ?*const Frame) ?*const c.CmdyRenderFrameInput {
    return if (frame) |p| &p.metadata else null;
}
export fn cmdy_render_frame_input_capture_referenced_graphics(input: ?*const c.CmdyRenderFrameInput, rows: [*c]const c.CmdyRenderFrameRowReference, count: usize, graphics: ?*Graphics, status: ?*u32) ?*Frame {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const snapshot = graphics orelse return null;
    const result = Frame.createReferencedGraphics(std.heap.c_allocator, source, rows, count, snapshot) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_frame_input_view(frame: ?*const Frame) ?*const c.CmdyRenderFrameInput {
    return if (frame) |p| @constCast(p).preparedView() else null;
}
export fn cmdy_render_frame_input_capture_viewport(input: ?*const c.CmdyRenderFrameInput, viewport: ?*const c.CmdyRenderViewportInput, graphics: ?*Graphics, status: ?*u32) ?*Frame {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const result = Frame.createViewport(std.heap.c_allocator, input orelse return null, viewport orelse return null, graphics) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_frame_input_reuse(previous: ?*Frame, input: ?*const c.CmdyRenderFrameInput, status: ?*u32) ?*Frame {
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_INVALID;
    const frame = previous orelse return null;
    const source = input orelse return null;
    const result = frame.reuse(std.heap.c_allocator, source) catch |err| {
        fail(status, err);
        return null;
    };
    if (status) |value| value.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_frame_input_retain(frame: ?*Frame) ?*Frame {
    return if (frame) |p| p.retain() else null;
}
export fn cmdy_render_frame_input_release(frame: ?*Frame) void {
    if (frame) |p| p.release();
}

test {
    _ = @import("render_frame_input_tests.zig");
}
