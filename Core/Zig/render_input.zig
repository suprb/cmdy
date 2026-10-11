//! Immutable text-row input storage for the dedicated rendering owner.
//! No source callbacks, caches, rasterization or GPU work occur during capture.
const std = @import("std");
pub const c = @cImport({
    @cInclude("cmdy_render_input.h");
    @cInclude("platform_text.h");
});
pub const Object = ?*const anyopaque;
pub const Kind = enum { font, color, attributed };
pub const CaptureError = error{ InvalidInput, UnsupportedAttributes, OutOfMemory };

/// Frame-wide raster values, frozen once under the producer's appearance.
/// Subsequent rows retain this packet without consulting platform/UI objects.
pub fn ParameterStorage(comptime Objects: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        refs: std.atomic.Value(usize) = .init(1),
        input: c.CmdyRenderRowInput,

        pub fn create(allocator: std.mem.Allocator, input: *const c.CmdyRenderRowInput) CaptureError!*Self {
            if (input.segments != null or input.segment_count != 0 or input.blocks != null or
                input.block_count != 0 or input.boxes != null or input.box_count != 0) return error.InvalidInput;
            const font = try Objects.capture(allocator, .font, input.normal_font);
            errdefer Objects.release(allocator, font);
            const foreground = try Objects.capture(allocator, .color, input.foreground);
            errdefer Objects.release(allocator, foreground);
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .input = input.* };
            self.input.normal_font = font;
            self.input.foreground = foreground;
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
            if (old != 1) return;
            const allocator = self.allocator;
            Objects.release(allocator, self.input.normal_font);
            Objects.release(allocator, self.input.foreground);
            allocator.destroy(self);
        }
    };
}

fn sourceSlice(comptime T: type, p: [*c]const T, n: usize) CaptureError![]const T {
    if (n == 0) return &.{};
    if (p == null or @intFromPtr(p) % @alignOf(T) != 0 or n > @as(usize, std.math.maxInt(isize)) / @sizeOf(T)) return error.InvalidInput;
    return p[0..n];
}

pub fn Storage(comptime Objects: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        objects: std.ArrayList(Object) = .empty,
        refs: std.atomic.Value(usize) = .init(1),
        input: c.CmdyRenderRowInput,

        pub fn create(allocator: std.mem.Allocator, input: *const c.CmdyRenderRowInput) CaptureError!*Self {
            const self = try allocator.create(Self);
            self.* = .{ .allocator = allocator, .arena = .init(allocator), .input = input.* };
            errdefer self.destroy();
            const arena = self.arena.allocator();
            self.input.normal_font = try self.own(.font, input.normal_font);
            self.input.foreground = try self.own(.color, input.foreground);

            const segments = try arena.dupe(c.CmdyRenderTextSegment, try sourceSlice(c.CmdyRenderTextSegment, input.segments, input.segment_count));
            self.input.segments = if (segments.len == 0) null else segments.ptr;
            for (segments) |*segment| {
                segment.attributed_string = try self.own(.attributed, segment.attributed_string);
                const boundaries = try arena.dupe(isize, try sourceSlice(isize, segment.boundaries, segment.boundary_count));
                segment.boundaries = if (boundaries.len == 0) null else boundaries.ptr;
            }
            const blocks = try arena.dupe(c.CmdyRenderBlock, try sourceSlice(c.CmdyRenderBlock, input.blocks, input.block_count));
            self.input.blocks = if (blocks.len == 0) null else blocks.ptr;
            for (blocks) |*block| {
                block.foreground = try self.own(.color, block.foreground);
                const rects = try arena.dupe(c.CmdyRenderBlockRect, try sourceSlice(c.CmdyRenderBlockRect, block.rects, block.rect_count));
                block.rects = if (rects.len == 0) null else rects.ptr;
            }
            const boxes = try arena.dupe(c.CmdyRenderBox, try sourceSlice(c.CmdyRenderBox, input.boxes, input.box_count));
            self.input.boxes = if (boxes.len == 0) null else boxes.ptr;
            for (boxes) |*box| box.foreground = try self.own(.color, box.foreground);
            return self;
        }

        fn own(self: *Self, kind: Kind, object: Object) CaptureError!Object {
            if (object == null) return null;
            const value = try Objects.capture(self.allocator, kind, object);
            errdefer Objects.release(self.allocator, value);
            try self.objects.append(self.allocator, value);
            return value;
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
            for (self.objects.items) |object| Objects.release(self.allocator, object);
            self.objects.deinit(self.allocator);
            self.arena.deinit();
            const allocator = self.allocator;
            allocator.destroy(self);
        }
    };
}

const NativeObjects = struct {
    fn release(_: std.mem.Allocator, object: Object) void {
        if (object) |p| c.CFRelease(p);
    }
    fn capture(_: std.mem.Allocator, kind: Kind, object: Object) CaptureError!Object {
        return switch (kind) {
            .font => if (c.cmdy_platform_text_object_kind(object) == 1) c.CFRetain(object) else error.UnsupportedAttributes,
            .color => if (c.cmdy_platform_text_object_kind(object) == 2) c.cmdy_platform_text_color_snapshot(object) orelse error.UnsupportedAttributes else error.UnsupportedAttributes,
            .attributed => snapshotAttributed(object),
        };
    }
    fn snapshotAttributed(object: Object) CaptureError!Object {
        if (c.cmdy_platform_text_is_attributed_string(object) == 0) return error.InvalidInput;
        const source: c.CFAttributedStringRef = @ptrCast(object);
        const mutable = c.CFAttributedStringCreateMutableCopy(null, 0, source) orelse return error.OutOfMemory;
        defer c.CFRelease(mutable);
        const length = c.CFAttributedStringGetLength(source);
        if (length < 0) return error.InvalidInput;
        var position: isize = 0;
        while (position < length) {
            var range: c.CFRange = undefined;
            const attrs = c.CFAttributedStringGetAttributes(source, position, &range);
            if (attrs == null or range.location < 0 or range.length <= 0 or range.location > position or range.location > length - range.length or range.length <= position - range.location) return error.InvalidInput;
            // Exactly the existing renderer's modeled attribute keys. Reject
            // unknown values without dropping attributes or borrowing them.
            var recognized: isize = 0;
            for (0..13) |index| {
                const key = c.cmdy_platform_text_attribute_key(@intCast(index));
                const value = c.CFDictionaryGetValue(attrs, key) orelse continue;
                recognized += 1;
                const expected: u32 = if (index == 0) 1 else if (index <= 7) 2 else 3;
                if (c.cmdy_platform_text_object_kind(value) != expected) return error.UnsupportedAttributes;
                if (expected == 2) {
                    const color = c.cmdy_platform_text_color_snapshot(value) orelse return error.UnsupportedAttributes;
                    defer c.CFRelease(color);
                    c.CFAttributedStringSetAttribute(mutable, range, @ptrCast(key), color);
                }
            }
            if (recognized != c.CFDictionaryGetCount(attrs)) return error.UnsupportedAttributes;
            position = range.location + range.length;
        }
        return c.CFAttributedStringCreateCopy(null, mutable) orelse error.OutOfMemory;
    }
};
const NativeStorage = Storage(NativeObjects);
pub const FrozenParameters = ParameterStorage(NativeObjects);
const shaper = @import("render_shaper.zig");
const Line = @import("line.zig").Line;
const procedural = @import("render_procedural.zig");
const native_allocator = std.heap.c_allocator;

/// UI Style.refs is deliberately never touched from another owner. This
/// wrapper owns a separate resolved Style with exactly one private reference.
pub const FrozenStyle = struct {
    refs: std.atomic.Value(usize) = .init(1),
    style: *shaper.Style,
    fn create(source: *const shaper.Style) CaptureError!*FrozenStyle {
        const style = source.resolve() orelse return error.UnsupportedAttributes;
        errdefer style.free();
        const self = try native_allocator.create(FrozenStyle);
        self.* = .{ .style = style };
        return self;
    }
    pub fn retain(self: *FrozenStyle) *FrozenStyle {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *FrozenStyle) void {
        const old = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 0);
        if (old != 1) return;
        self.style.free();
        native_allocator.destroy(self);
    }
};
const Deferred = struct {
    line: *Line,
    style: *FrozenStyle,
    row: isize,
    style_row: isize,
    parameters: *FrozenParameters,
    fn create(source: *const Line, row: isize, style: *FrozenStyle, parameters: *FrozenParameters) CaptureError!*Deferred {
        const line = source.renderSnapshot() catch return error.OutOfMemory;
        errdefer line.release();
        const self = try native_allocator.create(Deferred);
        self.* = .{ .line = line, .style = style.retain(), .row = row, .style_row = row, .parameters = parameters.retain() };
        return self;
    }
    // Classification traverses cell contents, so it belongs to preparation on
    // the render owner, never producer capture or a host eligibility query.
    fn revisionReusable(self: *const Deferred) bool {
        var col: isize = 0;
        while (col < self.line.count()) : (col += 1) {
            const cell = self.line.cell(col);
            if (cell.width == 0) continue;
            var rects: [3]@import("render_font.zig").c.CmdyRenderBlockRect = undefined;
            if (cell.scalar == 0x10eeee or (cell.scalar >= 0x2500 and cell.scalar <= 0x257f) or
                procedural.blockRects(cell.scalar, &rects) != 0)
            {
                return false;
            }
        }
        return true;
    }
    fn destroy(self: *Deferred) void {
        self.line.release();
        self.style.release();
        self.parameters.release();
        native_allocator.destroy(self);
    }
    fn prepare(self: *const Deferred) CaptureError!*Prepared {
        const shaped = shaper.shapeFrozenWithStyleRow(self.line, self.row, self.style_row, self.style.style) catch return error.OutOfMemory;
        errdefer shaped.free();
        var input = self.parameters.input;
        input.segments = @ptrCast(shaped.segments.items.ptr);
        input.segment_count = shaped.segments.items.len;
        input.boxes = @ptrCast(shaped.boxes.items.ptr);
        input.box_count = shaped.boxes.items.len;
        const blocks = try native_allocator.alloc(c.CmdyRenderBlock, shaped.blocks.items.len);
        errdefer native_allocator.free(blocks);
        for (shaped.blocks.items, blocks) |*source, *dest| {
            dest.* = .{ .column = source.column, .column_width = source.column_width, .code_point = source.code_point, .rects = @ptrCast(&source.rects), .rect_count = source.rect_count, .foreground = source.foreground };
        }
        input.blocks = blocks.ptr;
        input.block_count = blocks.len;
        const placeholders = try native_allocator.alloc(c.CmdyShapePlaceholder, shaped.placeholders.items.len);
        errdefer native_allocator.free(placeholders);
        for (shaped.placeholders.items, placeholders) |source, *dest| dest.* = @bitCast(source);
        const prepared = try native_allocator.create(Prepared);
        // The worker just created these immutable strings from its privately
        // resolved style. Transfer the sole result owner instead of running it
        // through the external-input deep snapshot path a second time. Segment
        // boundaries, block rectangles and box colors stay alive with shaped;
        // the frame parameters own the already resolved font and foreground.
        prepared.* = .{
            .input = input,
            .owner = .{ .shaped = .{ .result = shaped, .parameters = self.parameters.retain(), .blocks = blocks } },
            .placeholders = placeholders,
            .revision_reusable = self.revisionReusable(),
        };
        return prepared;
    }
};
const Prepared = struct {
    input: c.CmdyRenderRowInput,
    owner: union(enum) {
        captured: *NativeStorage,
        shaped: struct { result: *shaper.Result, parameters: *FrozenParameters, blocks: []c.CmdyRenderBlock },
    },
    placeholders: []c.CmdyShapePlaceholder = &.{},
    revision_reusable: bool = false,
    fn destroy(self: *Prepared) void {
        switch (self.owner) {
            .captured => |storage| storage.release(),
            .shaped => |value| {
                value.result.free();
                value.parameters.release();
                native_allocator.free(value.blocks);
            },
        }
        native_allocator.free(self.placeholders);
        native_allocator.destroy(self);
    }
};
pub const Owned = struct {
    refs: std.atomic.Value(usize) = .init(1),
    prepared: std.atomic.Value(?*Prepared) = .init(null),
    preparation_lock: std.Thread.Mutex = .{},
    deferred: ?*Deferred = null,
    fn create(input: *const c.CmdyRenderRowInput) CaptureError!*Owned {
        const storage = try NativeStorage.create(native_allocator, input);
        errdefer storage.release();
        const prepared = try native_allocator.create(Prepared);
        errdefer native_allocator.destroy(prepared);
        prepared.* = .{ .input = storage.input, .owner = .{ .captured = storage } };
        const self = try native_allocator.create(Owned);
        self.* = .{ .prepared = .init(prepared) };
        return self;
    }
    fn createDeferred(line: *const Line, row: isize, style: *FrozenStyle, parameters: *const c.CmdyRenderRowInput) CaptureError!*Owned {
        const frozen = try FrozenParameters.create(native_allocator, parameters);
        defer frozen.release();
        return createFrozen(line, row, style, frozen);
    }
    fn createFrozen(line: *const Line, row: isize, style: *FrozenStyle, parameters: *FrozenParameters) CaptureError!*Owned {
        const deferred = try Deferred.create(line, row, style, parameters);
        errdefer deferred.destroy();
        const self = try native_allocator.create(Owned);
        self.* = .{ .deferred = deferred };
        return self;
    }
    fn prepare(self: *Owned) CaptureError!*const c.CmdyRenderRowInput {
        if (self.prepared.load(.acquire)) |p| return &p.input;
        self.preparation_lock.lock();
        defer self.preparation_lock.unlock();
        if (self.prepared.load(.acquire)) |p| return &p.input;
        const deferred = self.deferred orelse return error.InvalidInput;
        const p = try deferred.prepare();
        // Prepared owns every font, color, text array and placeholder it uses.
        // Failures above keep the snapshot available for retry. Successful
        // publication retires it once, while all first preparers hold the lock.
        self.deferred = null;
        deferred.destroy();
        self.prepared.store(p, .release);
        return &p.input;
    }
    pub fn createViewportRow(line: *const Line, row: isize, style_row: isize, style: *FrozenStyle, parameters: *FrozenParameters) CaptureError!*Owned {
        const owned = try createFrozen(line, row, style, parameters);
        owned.deferred.?.style_row = style_row;
        return owned;
    }
    fn retain(self: *Owned) *Owned {
        const old = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(old > 0 and old < std.math.maxInt(usize));
        return self;
    }
    fn release(self: *Owned) void {
        const old = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(old > 0);
        if (old != 1) return;
        if (self.prepared.load(.acquire)) |p| p.destroy();
        if (self.deferred) |d| d.destroy();
        native_allocator.destroy(self);
    }
};
fn captureStatus(status: ?*u32, err: CaptureError) void {
    if (status) |out| out.* = switch (err) {
        error.InvalidInput => c.CMDY_RENDER_INPUT_INVALID,
        error.UnsupportedAttributes => c.CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES,
        error.OutOfMemory => c.CMDY_RENDER_INPUT_OUT_OF_MEMORY,
    };
}
export fn cmdy_render_input_capture(input: ?*const c.CmdyRenderRowInput, status: ?*u32) ?*Owned {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const value = Owned.create(source) catch |err| {
        if (status) |out| out.* = switch (err) {
            error.InvalidInput => c.CMDY_RENDER_INPUT_INVALID,
            error.UnsupportedAttributes => c.CMDY_RENDER_INPUT_UNSUPPORTED_ATTRIBUTES,
            error.OutOfMemory => c.CMDY_RENDER_INPUT_OUT_OF_MEMORY,
        };
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return value;
}
export fn cmdy_render_input_view(value: ?*const Owned) ?*const c.CmdyRenderRowInput {
    const self = value orelse return null;
    return if (self.prepared.load(.acquire)) |p| &p.input else null;
}
export fn cmdy_render_input_prepare(value: ?*Owned, status: ?*u32) ?*const c.CmdyRenderRowInput {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const self = value orelse return null;
    const input = self.prepare() catch |err| {
        captureStatus(status, err);
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return input;
}
export fn cmdy_render_input_placeholders(value: ?*const Owned, count: ?*usize) ?[*]const c.CmdyShapePlaceholder {
    if (count) |out| out.* = 0;
    const self = value orelse return null;
    const prepared = self.prepared.load(.acquire) orelse return null;
    if (count) |out| out.* = prepared.placeholders.len;
    return if (prepared.placeholders.len == 0) null else prepared.placeholders.ptr;
}
export fn cmdy_render_input_revision_reusable(value: ?*const Owned) u8 {
    const self = value orelse return 0;
    const prepared = self.prepared.load(.acquire) orelse return 0;
    return @intFromBool(prepared.revision_reusable);
}
export fn cmdy_render_row_style_capture(source: ?*const shaper.Style, status: ?*u32) ?*FrozenStyle {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const style = source orelse return null;
    const result = FrozenStyle.create(style) catch |err| {
        captureStatus(status, err);
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_row_style_retain(value: ?*FrozenStyle) ?*FrozenStyle {
    return if (value) |s| s.retain() else null;
}
export fn cmdy_render_row_style_release(value: ?*FrozenStyle) void {
    if (value) |s| s.release();
}
export fn cmdy_render_row_parameters_capture(input: ?*const c.CmdyRenderRowInput, status: ?*u32) ?*FrozenParameters {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = input orelse return null;
    const result = FrozenParameters.create(native_allocator, source) catch |err| {
        captureStatus(status, err);
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_row_parameters_retain(value: ?*FrozenParameters) ?*FrozenParameters {
    return if (value) |p| p.retain() else null;
}
export fn cmdy_render_row_parameters_release(value: ?*FrozenParameters) void {
    if (value) |p| p.release();
}
export fn cmdy_render_input_capture_frozen(line: ?*const Line, row: isize, style: ?*FrozenStyle, parameters: ?*FrozenParameters, status: ?*u32) ?*Owned {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = line orelse return null;
    const frozen = style orelse return null;
    const input = parameters orelse return null;
    const result = Owned.createFrozen(source, row, frozen, input) catch |err| {
        captureStatus(status, err);
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_input_capture_deferred(line: ?*const Line, row: isize, style: ?*FrozenStyle, parameters: ?*const c.CmdyRenderRowInput, status: ?*u32) ?*Owned {
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_INVALID;
    const source = line orelse return null;
    const frozen = style orelse return null;
    const input = parameters orelse return null;
    const result = Owned.createDeferred(source, row, frozen, input) catch |err| {
        captureStatus(status, err);
        return null;
    };
    if (status) |out| out.* = c.CMDY_RENDER_INPUT_OK;
    return result;
}
export fn cmdy_render_input_retain(value: ?*Owned) ?*Owned {
    return if (value) |self| self.retain() else null;
}
export fn cmdy_render_input_release(value: ?*Owned) void {
    if (value) |self| self.release();
}

test {
    _ = @import("render_input_tests.zig");
}

test "worker preparation publishes revision eligibility and retires cell and style ownership" {
    const t = std.testing;
    const name = c.CFStringCreateWithCString(null, "Menlo", c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
    defer c.CFRelease(name);
    const font = c.CTFontCreateWithName(name, 14, null) orelse return error.OutOfMemory;
    defer c.CFRelease(font);
    const white = c.cmdy_platform_text_white();
    var style_input = std.mem.zeroes(c.CmdyShapeStyleInput);
    @memset(&style_input.fonts, font);
    @memset(&style_input.colors, white);
    const raw_style = c.cmdy_shape_style_create(&style_input) orelse return error.OutOfMemory;
    defer c.cmdy_shape_style_free(raw_style);
    const style = try FrozenStyle.create(@ptrCast(@alignCast(raw_style)));
    defer style.release();
    var parameters = std.mem.zeroes(c.CmdyRenderRowInput);
    parameters.normal_font = font;
    parameters.foreground = white;
    parameters.cols = 8;
    parameters.width = 96;
    parameters.height = 20;
    parameters.cell_width = 12;
    parameters.cell_height = 20;
    parameters.scale = 1;
    for ([_]u32{ 'A', 0x2500, 0x2588, 0x10eeee }) |scalar| {
        const line = try Line.createASCII(t.allocator, "AAAAAAAA", 8, .{}, .{}, false);
        defer line.release();
        try line.setCell(0, .{ .scalar = scalar, .width = 1 });
        const storage = line.row.storage;
        const expected: u8 = @intFromBool(scalar == 'A');
        const owned = try Owned.createDeferred(line, 100, style, &parameters);
        defer owned.release();
        try t.expectEqual(@as(usize, 2), storage.refs.load(.acquire));
        try t.expectEqual(@as(usize, 2), style.refs.load(.acquire));
        try t.expectEqual(@as(u8, 0), cmdy_render_input_revision_reusable(owned));
        try t.expect(cmdy_render_input_view(owned) == null);
        const view = try owned.prepare();
        try t.expectEqual(@as(usize, 1), storage.refs.load(.acquire));
        try t.expectEqual(@as(usize, 1), style.refs.load(.acquire));
        try t.expectEqual(expected, cmdy_render_input_revision_reusable(owned));
        try line.setCell(0, .{ .scalar = 'Z', .width = 1 });
        try t.expect(line.row.storage == storage); // No unnecessary COW detach.
        try t.expect(view == try owned.prepare());
        try t.expectEqual(expected, cmdy_render_input_revision_reusable(owned));
        const cancelled = try Owned.createDeferred(line, 100, style, &parameters);
        try t.expectEqual(@as(usize, 2), storage.refs.load(.acquire));
        cancelled.release();
        try t.expectEqual(@as(usize, 1), storage.refs.load(.acquire));
        try t.expectEqual(@as(usize, 1), style.refs.load(.acquire));
    }
}

test "deferred owned shaping matches external snapshots after all source owners retire" {
    const t = std.testing;
    const Pair = struct { expected: *Owned, actual: *Owned, placeholders: usize };
    for ([_]f64{ 1, 2 }) |scale| for ([_]bool{ false, true }) |failed| {
        const pair: Pair = blk: {
            const name = c.CFStringCreateWithCString(null, "Menlo", c.kCFStringEncodingUTF8) orelse return error.OutOfMemory;
            defer c.CFRelease(name);
            const font = c.CTFontCreateWithName(name, 14, null) orelse return error.OutOfMemory;
            defer c.CFRelease(font);
            const white = c.cmdy_platform_text_white();
            var style_input = std.mem.zeroes(c.CmdyShapeStyleInput);
            @memset(&style_input.fonts, font);
            @memset(&style_input.colors, white);
            const failed_rows = [_]isize{3};
            style_input.failed_rows = &failed_rows;
            style_input.failed_row_count = @intFromBool(failed);
            const raw_style = c.cmdy_shape_style_create(&style_input) orelse return error.OutOfMemory;
            defer c.cmdy_shape_style_free(raw_style);
            const style = try FrozenStyle.create(@ptrCast(@alignCast(raw_style)));
            defer style.release();
            var parameters = std.mem.zeroes(c.CmdyRenderRowInput);
            parameters.normal_font = font;
            parameters.foreground = white;
            parameters.cols = 16;
            parameters.width = @intFromFloat(16 * 9 * scale);
            parameters.height = @intFromFloat(20 * scale);
            parameters.cell_width = 9;
            parameters.cell_height = 20;
            parameters.scale = scale;
            parameters.underline_position = -2;
            parameters.underline_thickness = 1;
            parameters.coverage_exponent = 1;
            parameters.antialias_blocks = 1;
            const frozen = try FrozenParameters.create(native_allocator, &parameters);
            defer frozen.release();
            const line = try Line.createASCII(t.allocator, "                ", 16, .{}, .{}, false);
            defer line.release();
            const scalars = [_]u32{ 'A', ' ', 'e', 0x2500, 0x2588, 0x10eeee, 0x754c, 0, 0x1f680, 0, 'f', 'i', 'Z', ' ', 'X', 'Y' };
            const styles = [_]u8{ 1, 8, 2, 32, 128, 0, 64, 0, 0, 0, 2 | 128, 16, 2, 8, 32, 0 };
            for (scalars, styles, 0..) |scalar, flags, index| {
                const extras: ?[]const u32 = if (index == 2) &.{0x301} else if (index == 5) &.{0x305} else null;
                try line.set(@intCast(index), .{
                    .cell = .{ .scalar = scalar, .width = if (index == 7 or index == 9) 0 else if (index == 6 or index == 8) 2 else 1,
                        .fg = 0x024080c0, .bg = 0x02201008 + @as(u32, @intCast(index * 257)), .style = flags,
                        .underline_present = 1, .underline_kind = @intCast(index % 5 + 1), .underline_color = 0x02a03050 },
                    .extras = extras,
                });
            }
            const shaped = try shaper.shape(line, 3, style.style, false, 0, 0);
            defer shaped.free();
            var input = frozen.input;
            input.segments = @ptrCast(shaped.segments.items.ptr);
            input.segment_count = shaped.segments.items.len;
            input.boxes = @ptrCast(shaped.boxes.items.ptr);
            input.box_count = shaped.boxes.items.len;
            const blocks = try t.allocator.alloc(c.CmdyRenderBlock, shaped.blocks.items.len);
            defer t.allocator.free(blocks);
            for (shaped.blocks.items, blocks) |*source, *dest|
                dest.* = .{ .column = source.column, .column_width = source.column_width, .code_point = source.code_point,
                    .rects = @ptrCast(&source.rects), .rect_count = source.rect_count, .foreground = source.foreground };
            input.blocks = blocks.ptr;
            input.block_count = blocks.len;
            const expected = try Owned.create(&input);
            errdefer expected.release();
            const actual = try Owned.createFrozen(line, 3, style, frozen);
            errdefer actual.release();
            try line.setCell(0, .{ .scalar = 'Q', .width = 1 });
            break :blk .{ .expected = expected, .actual = actual, .placeholders = shaped.placeholders.items.len };
        };
        defer pair.expected.release();
        defer pair.actual.release();
        const expected = try pair.expected.prepare();
        const actual = try pair.actual.prepare();
        try t.expect(actual == try pair.actual.prepare());
        try t.expectEqual(pair.placeholders, pair.actual.prepared.load(.acquire).?.placeholders.len);
        try t.expectEqual(expected.segment_count, actual.segment_count);
        for (expected.segments[0..expected.segment_count], actual.segments[0..actual.segment_count]) |left, right| {
            try t.expect(c.CFEqual(left.attributed_string, right.attributed_string) != 0);
            try t.expectEqual(left.column, right.column);
            try t.expectEqual(left.column_width, right.column_width);
            try t.expectEqual(left.character_count, right.character_count);
            try t.expectEqualSlices(isize, left.boundaries[0..left.boundary_count], right.boundaries[0..right.boundary_count]);
        }
        const left = c.cmdy_render_row_create(expected) orelse return error.OutOfMemory;
        defer c.cmdy_render_row_free(left);
        const right = c.cmdy_render_row_create(actual) orelse return error.OutOfMemory;
        defer c.cmdy_render_row_free(right);
        var lhs: c.CmdyRenderRowView = undefined;
        var rhs: c.CmdyRenderRowView = undefined;
        c.cmdy_render_row_view(left, &lhs);
        c.cmdy_render_row_view(right, &rhs);
        try t.expectEqualSlices(u8, lhs.coverage[0..lhs.coverage_count], rhs.coverage[0..rhs.coverage_count]);
        inline for (.{ .{ "backgrounds", "background_count" }, .{ "tints", "tint_count" }, .{ "decorations", "decoration_count" } }) |names| {
            try t.expectEqual(@field(lhs, names[1]), @field(rhs, names[1]));
            for (@field(lhs, names[0])[0..@field(lhs, names[1])], @field(rhs, names[0])[0..@field(rhs, names[1])]) |x, y| try t.expect(std.meta.eql(x, y));
        }
        try t.expectEqual(lhs.color_tile_count, rhs.color_tile_count);
        for (lhs.color_tiles[0..lhs.color_tile_count], rhs.color_tiles[0..rhs.color_tile_count]) |x, y| {
            try t.expectEqual(x.width, y.width);
            try t.expectEqual(x.height, y.height);
            try t.expect(std.meta.eql(x.rect, y.rect));
            try t.expectEqualSlices(u8, x.bytes[0..x.byte_count], y.bytes[0..y.byte_count]);
        }
        try t.expectEqual(lhs.glyph_count, rhs.glyph_count);
        for (lhs.glyphs[0..lhs.glyph_count], rhs.glyphs[0..rhs.glyph_count]) |x, y| {
            try t.expect(c.CFEqual(x.font, y.font) != 0);
            var normalized = y;
            normalized.font = x.font;
            try t.expect(std.meta.eql(x, normalized));
        }
    };
}
