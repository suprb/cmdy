const std = @import("std");
const m = @import("render_frame_input.zig");
const c = m.c;
const a = std.testing.allocator;
const Ref = struct { count: usize = 1 };
const References = struct {
    fn value(p: anytype) *Ref {
        return @ptrCast(@alignCast(p));
    }
    pub fn retainText(p: *c.CmdyRenderOwnedRowInput) void {
        value(p).count += 1;
    }
    pub fn releaseText(p: *c.CmdyRenderOwnedRowInput) void {
        value(p).count -= 1;
    }
    pub fn retainImage(p: *c.CmdyRenderOwnedImageInput) void {
        value(p).count += 1;
    }
    pub fn releaseImage(p: *c.CmdyRenderOwnedImageInput) void {
        value(p).count -= 1;
    }
};
const Storage = m.Storage(References);
const RowStorage = m.RowStorage(References);
const graphics = @import("graphics.zig");

test "frames share frozen graphics arrays and reuse releases the original owner" {
    var store = graphics.KittyGraphicsStore.init(a);
    defer store.deinit();
    const payload = try graphics.Payload.createHostCopy(a, .rgba, &.{ 1, 2, 3, 4 }, 1, 1);
    defer payload.release();
    const image = try graphics.Image.create(payload, 91, null);
    defer image.deinit();
    try store.store(image);
    _ = try store.place(.{ .image_id = 91, .placement_id = 81, .col = 0, .row = 0, .cols = 2, .rows = 3, .is_virtual = true, .is_alternate_buffer = true });
    const frozen = try m.Graphics.capture(a, &store);
    defer frozen.release();
    var input = std.mem.zeroes(c.CmdyRenderFrameInput);
    input.identity = .{ .surface = 7, .epoch = 2, .sequence = 1 };
    input.alternate_buffer = 1;
    var frame = try Storage.createReferencedGraphics(a, &input, null, 0, frozen);
    defer frame.release();
    store.deleteAll();
    for (2..34) |sequence| {
        input.identity.sequence = sequence;
        const next = try frame.reuse(a, &input);
        frame.release();
        frame = next;
        const view = frame.preparedView();
        try std.testing.expect(view.parameters.kitty_images == @as([*c]const c.CmdyGpuKittyImage, @ptrCast(frozen.views[0].images)));
        try std.testing.expect(view.parameters.kitty_images[0].bytes == payload.bytes.ptr);
        try std.testing.expectEqual(@as(u32, 81), view.parameters.kitty_placements[0].placement_id);
        try std.testing.expectEqual(@as(usize, 2), frozen.refs.load(.acquire));
        try std.testing.expect(frame.content_owner.?.content_owner == null);
        try std.testing.expect(frame.metadata.parameters.kitty_images == null);
    }
}

fn sharedGraphicsAllocationExercise(allocator: std.mem.Allocator) !void {
    var store = graphics.KittyGraphicsStore.init(allocator);
    defer store.deinit();
    const frozen = try m.Graphics.capture(allocator, &store);
    defer frozen.release();
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(allocator, &f.rows[0]);
    defer row.release();
    const references = [_]c.CmdyRenderFrameRowReference{.{ .row = @ptrCast(row), .placement = f.rows[0].placement }};
    var input = scalarUpdate(f.input, 20);
    const frame = try Storage.createReferencedGraphics(allocator, &input, &references, references.len, frozen);
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), frozen.refs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), row.refs.load(.acquire));
}
test "shared graphics frame allocation failures unwind every acquired row and owner" {
    try std.testing.checkAllAllocationFailures(a, sharedGraphicsAllocationExercise, .{});
}

test "shared graphics frames reject mixed borrowed payloads and invalid buffer selectors" {
    var store = graphics.KittyGraphicsStore.init(a);
    defer store.deinit();
    const frozen = try m.Graphics.capture(a, &store);
    defer frozen.release();
    var input = std.mem.zeroes(c.CmdyRenderFrameInput);
    input.identity = .{ .surface = 7, .epoch = 2, .sequence = 1 };
    input.alternate_buffer = 2;
    try std.testing.expectError(error.InvalidInput, Storage.createReferencedGraphics(a, &input, null, 0, frozen));
    input.alternate_buffer = 0;
    inline for (.{ "kitty_images", "kitty_placements", "live_kitty_ids" }) |field| {
        @field(input.parameters, field) = @ptrFromInt(4096);
        try std.testing.expectError(error.InvalidInput, Storage.createReferencedGraphics(a, &input, null, 0, frozen));
        @field(input.parameters, field) = null;
    }
    inline for (.{ "kitty_image_count", "kitty_placement_count", "live_kitty_count" }) |field| {
        @field(input.parameters, field) = 1;
        try std.testing.expectError(error.InvalidInput, Storage.createReferencedGraphics(a, &input, null, 0, frozen));
        @field(input.parameters, field) = 0;
    }
    try std.testing.expectEqual(@as(usize, 1), frozen.refs.load(.acquire));
}

const Fixture = struct {
    text: Ref = .{},
    image: Ref = .{},
    name: [4]u8 = .{ 'M', 'e', 'n', 'l' },
    bytes: [4]u8 = .{ 10, 20, 30, 40 },
    images: [1]c.CmdyRenderFrameImageInput = std.mem.zeroes([1]c.CmdyRenderFrameImageInput),
    placeholders: [1]c.CmdyGpuPlaceholder = std.mem.zeroes([1]c.CmdyGpuPlaceholder),
    rows: [2]c.CmdyRenderFrameRowInput = std.mem.zeroes([2]c.CmdyRenderFrameRowInput),
    kitty: [1]c.CmdyGpuKittyImage = std.mem.zeroes([1]c.CmdyGpuKittyImage),
    placements: [1]c.CmdyGpuKittyPlacement = std.mem.zeroes([1]c.CmdyGpuKittyPlacement),
    ids: [1]u32 = .{91},
    input: c.CmdyRenderFrameInput = std.mem.zeroes(c.CmdyRenderFrameInput),

    fn bind(self: *Fixture) void {
        self.images[0].payload = @ptrCast(&self.image);
        self.images[0].placement = .{ .owner = null, .image = null, .col = 6, .z_index = -4, .width = 20, .height = 30, .offset_x = -2, .offset_y = 3, .kitty_image_id = 17, .has_kitty_id = 1, .is_kitty = 1, .owned_image = null };
        self.placeholders[0] = .{ .image_id = 91, .placement_id = 72, .row = 30, .col = 8, .placeholder_row = 2, .placeholder_col = 3, .msb = 1 };
        for (&self.rows, 0..) |*row, i| {
            row.key.absolute_row = @intCast(100 + i);
            row.key.version = 51;
            row.key.font_name = @ptrCast(&self.name);
            row.font_name_bytes = self.name.len;
            row.revision = .{ .content = 51, .context = 4 };
            row.text = @ptrCast(&self.text);
            row.images = &self.images;
            row.image_count = self.images.len;
            row.placeholders = &self.placeholders;
            row.placeholder_count = self.placeholders.len;
            row.placement = .{ .entry = null, .display_index = @intCast(i), .source_row = @intCast(30 + i), .line_mode = 2, .selection_lower = 2, .selection_upper = 7, .has_selection = 1 };
        }
        self.kitty[0] = .{ .image_id = 91, .kind = 1, .bytes = &self.bytes, .byte_count = self.bytes.len, .width = 1, .height = 1 };
        self.placements[0] = .{ .image_id = 91, .placement_id = 72, .cols = 4, .rows = 5, .offset_x = -2, .offset_y = 3 };
        self.input.identity = .{ .surface = 7, .epoch = 2, .sequence = 19 };
        self.input.parameters.width = 100;
        self.input.parameters.height = 200;
        self.input.parameters.grid_rows = 36;
        self.input.parameters.grid_cols = 120;
        self.input.parameters.cursor_source_row = 31;
        self.input.parameters.cursor_col = 9;
        self.input.parameters.cursor_style = 5;
        self.input.parameters.cursor_valid = 1;
        self.input.parameters.caret = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 0.4 };
        self.input.parameters.shader_mode = 6;
        self.input.parameters.shader_energy = 0.75;
        self.input.parameters.kitty_images = &self.kitty;
        self.input.parameters.kitty_image_count = 1;
        self.input.parameters.kitty_placements = &self.placements;
        self.input.parameters.kitty_placement_count = 1;
        self.input.parameters.live_kitty_ids = &self.ids;
        self.input.parameters.live_kitty_count = 1;
        self.input.buffer_line_count = 800;
        self.input.retained_row_origin = 70;
        self.input.live_top_row = 65;
        self.input.alternate_buffer = 1;
        self.input.rows = &self.rows;
        self.input.row_count = self.rows.len;
    }
};

test "frame owns nested inputs after producer mutation" {
    var f: Fixture = .{};
    f.bind();
    const frame = try Storage.create(a, &f.input);
    try std.testing.expectEqual(@as(usize, 3), f.text.count);
    try std.testing.expectEqual(@as(usize, 3), f.image.count);
    f.name = @splat('X');
    f.bytes = @splat(255);
    f.images[0].placement.col = 88;
    f.placeholders[0].col = 99;
    f.rows[0].revision.content = 0;
    f.rows[0].placement.has_selection = 0;
    f.kitty[0].width = 999;
    f.placements[0].offset_y = 444;
    f.ids[0] = 0;
    f.input.identity.epoch = 999;
    f.input.parameters.width = 1;
    const v = &frame.view;
    try std.testing.expectEqual(@as(u64, 2), v.identity.epoch);
    try std.testing.expectEqual(@as(f64, 100), v.parameters.width);
    try std.testing.expectEqual(@as(isize, 70), v.retained_row_origin);
    try std.testing.expectEqual(@as(u8, 1), v.alternate_buffer);
    try std.testing.expectEqual(@as(u64, 51), v.rows[0].revision.content);
    try std.testing.expectEqual(@as(u8, 1), v.rows[0].placement.has_selection);
    try std.testing.expectEqualStrings("Menl", std.mem.span(v.rows[0].key.font_name));
    try std.testing.expectEqual(@as(isize, 6), v.rows[1].images[0].placement.col);
    try std.testing.expectEqual(@as(isize, 8), v.rows[1].placeholders[0].col);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, v.parameters.kitty_images[0].bytes[0..4]);
    try std.testing.expectEqual(@as(isize, 1), v.parameters.kitty_images[0].width);
    try std.testing.expectEqual(@as(isize, 3), v.parameters.kitty_placements[0].offset_y);
    try std.testing.expectEqual(@as(u32, 91), v.parameters.live_kitty_ids[0]);
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "late malformed frame input releases every retained reference" {
    var f: Fixture = .{};
    f.bind();
    f.rows[1].placeholders = null;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
    f.bind();
    f.kitty[0].bytes = null;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "frame refuses host objects and GPU rows or targets" {
    var f: Fixture = .{};
    f.bind();
    const pointer: *const anyopaque = &f.text;
    inline for (.{ "drawable", "pass" }) |field| {
        @field(f.input.parameters, field) = pointer;
        try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
        @field(f.input.parameters, field) = null;
    }
    f.input.parameters.row_count = 1;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.input.parameters.row_count = 0;
    f.rows[1].placement.entry = @ptrCast(pointer);
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.rows[1].placement.entry = null;
    inline for (.{ "owner", "image" }) |field| {
        @field(f.images[0].placement, field) = pointer;
        try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
        @field(f.images[0].placement, field) = null;
    }
    f.images[0].placement.owned_image = @ptrCast(@constCast(pointer));
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.images[0].placement.owned_image = null;
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "frame rejects missing retained handles and identity components" {
    var f: Fixture = .{};
    f.bind();
    inline for (.{ "surface", "epoch", "sequence" }) |field| {
        const old = @field(f.input.identity, field);
        @field(f.input.identity, field) = 0;
        try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
        @field(f.input.identity, field) = old;
    }
    f.rows[1].text = null;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.bind();
    f.images[0].payload = null;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "frame bounds pointer counts and canonicalizes empty arrays" {
    var f: Fixture = .{};
    f.bind();
    f.input.row_count = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.input.row_count = 1;
    f.input.rows = null;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.bind();
    f.rows[1].font_name_bytes = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.bind();
    f.rows[1].key.font_name = null;
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    f.bind();
    f.rows[1].image_count = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidInput, Storage.create(a, &f.input));
    var empty = std.mem.zeroes(c.CmdyRenderFrameInput);
    empty.identity = .{ .surface = 1, .epoch = 1, .sequence = 1 };
    empty.rows = @ptrFromInt(@alignOf(c.CmdyRenderFrameRowInput));
    empty.parameters.kitty_images = @ptrFromInt(@alignOf(c.CmdyGpuKittyImage));
    empty.parameters.kitty_placements = @ptrFromInt(@alignOf(c.CmdyGpuKittyPlacement));
    empty.parameters.live_kitty_ids = @ptrFromInt(@alignOf(u32));
    const frame = try Storage.create(a, &empty);
    defer frame.release();
    try std.testing.expect(frame.view.rows == null and frame.view.parameters.kitty_images == null and frame.view.parameters.kitty_placements == null and frame.view.parameters.live_kitty_ids == null);
}

fn allocationExercise(allocator: std.mem.Allocator) !void {
    var f: Fixture = .{};
    f.bind();
    defer std.debug.assert(f.text.count == 1 and f.image.count == 1);
    const frame = try Storage.create(allocator, &f.input);
    frame.release();
}
test "every frame allocation failure unwinds retained handles" {
    try std.testing.checkAllAllocationFailures(a, allocationExercise, .{});
}

fn reader(frame: *Storage) void {
    for (0..1000) |_| {
        const ref = frame.retain();
        std.debug.assert(ref.view.identity.sequence == 19 and ref.view.rows[0].placement.selection_upper == 7);
        std.debug.assert(ref.view.parameters.kitty_images[0].bytes[2] == 30);
        ref.release();
    }
    frame.release();
}
test "independent worker readers share one immutable frame" {
    var f: Fixture = .{};
    f.bind();
    const frame = try Storage.create(a, &f.input);
    const first = try std.Thread.spawn(.{}, reader, .{frame.retain()});
    const second = try std.Thread.spawn(.{}, reader, .{frame.retain()});
    first.join();
    second.join();
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "ordinary image owns original bytes and preserves payload metadata" {
    var bytes = [_]u8{ 1, 2, 3, 4 };
    var input = std.mem.zeroes(c.CmdyRenderImageInput);
    input.identity = @splat(7);
    input.kind = 1;
    input.width = 1;
    input.height = 1;
    input.bytes = &bytes;
    input.byte_count = bytes.len;
    const image = try m.Image.create(a, &input);
    _ = image.retain();
    image.release();
    bytes = @splat(255);
    input.identity = @splat(0);
    input.width = 9;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, image.view.bytes[0..4]);
    try std.testing.expectEqual(@as(u8, 7), image.view.identity[0]);
    try std.testing.expectEqual(@as(isize, 1), image.view.width);
    image.release();
}

fn imageAllocationExercise(allocator: std.mem.Allocator) !void {
    var input = std.mem.zeroes(c.CmdyRenderImageInput);
    input.bytes = "PNG-data";
    input.byte_count = 8;
    const image = try m.Image.create(allocator, &input);
    image.release();
}
test "every image allocation failure is cleaned up" {
    try std.testing.checkAllAllocationFailures(a, imageAllocationExercise, .{});
}

test "image malformed counts and unsupported kind reject without decoding" {
    var input = std.mem.zeroes(c.CmdyRenderImageInput);
    input.byte_count = 1;
    try std.testing.expectError(error.InvalidInput, m.Image.create(a, &input));
    input.bytes = "x";
    input.byte_count = std.math.maxInt(usize);
    try std.testing.expectError(error.InvalidInput, m.Image.create(a, &input));
    input.byte_count = 0;
    input.kind = 2;
    try std.testing.expectError(error.InvalidInput, m.Image.create(a, &input));
    input.kind = 0;
    input.bytes = @ptrFromInt(1);
    const image = try m.Image.create(a, &input);
    defer image.release();
    try std.testing.expect(image.view.bytes == null);
}

fn scalarUpdate(input: c.CmdyRenderFrameInput, sequence: u64) c.CmdyRenderFrameInput {
    var result = input;
    result.identity.sequence = sequence;
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

test "reused frame owns frozen content after original and producer release" {
    var f: Fixture = .{};
    f.bind();
    var next: ?*Storage = null;
    defer if (next) |value| value.release();
    {
        const original = try Storage.create(a, &f.input);
        defer original.release();
        var update = scalarUpdate(f.input, 20);
        update.parameters.now = 123;
        update.parameters.cursor_col = 40;
        update.parameters.scroll_pixels = 2.5;
        update.parameters.width = 400;
        update.buffer_line_count = 900;
        update.retained_row_origin = 80;
        update.live_top_row = 75;
        update.alternate_buffer = 0;
        next = try original.reuse(a, &update);
        try std.testing.expect(next.?.view.rows == original.view.rows);
        try std.testing.expect(next.?.view.parameters.kitty_images == original.view.parameters.kitty_images);
        try std.testing.expect(next.?.view.parameters.kitty_placements == original.view.parameters.kitty_placements);
        try std.testing.expect(next.?.view.parameters.live_kitty_ids == original.view.parameters.live_kitty_ids);
        try std.testing.expectEqual(@as(usize, 3), f.text.count);
        try std.testing.expectEqual(@as(usize, 3), f.image.count);
        try std.testing.expectEqual(@as(u64, 19), original.view.identity.sequence);
        try std.testing.expectEqual(@as(isize, 9), original.view.parameters.cursor_col);
        update.parameters.cursor_col = 99;
        f.name = @splat('X');
        f.bytes = @splat(255);
        f.rows[0].placement.selection_upper = 100;
        f.images[0].placement.col = 100;
        f.placeholders[0].col = 100;
        f.ids[0] = 0;
    }
    const view = &next.?.view;
    try std.testing.expectEqual(@as(u64, 20), view.identity.sequence);
    try std.testing.expectEqual(@as(f64, 123), view.parameters.now);
    try std.testing.expectEqual(@as(isize, 40), view.parameters.cursor_col);
    try std.testing.expectEqual(@as(f64, 2.5), view.parameters.scroll_pixels);
    try std.testing.expectEqual(@as(f64, 400), view.parameters.width);
    try std.testing.expectEqual(@as(isize, 900), view.buffer_line_count);
    try std.testing.expectEqual(@as(isize, 80), view.retained_row_origin);
    try std.testing.expectEqual(@as(isize, 75), view.live_top_row);
    try std.testing.expectEqual(@as(u8, 0), view.alternate_buffer);
    try std.testing.expectEqualStrings("Menl", std.mem.span(view.rows[0].key.font_name));
    try std.testing.expectEqual(@as(isize, 7), view.rows[0].placement.selection_upper);
    try std.testing.expectEqual(@as(isize, 6), view.rows[1].images[0].placement.col);
    try std.testing.expectEqual(@as(isize, 8), view.rows[1].placeholders[0].col);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, view.parameters.kitty_images[0].bytes[0..4]);
    try std.testing.expectEqual(@as(u32, 91), view.parameters.live_kitty_ids[0]);
    next.?.release();
    next = null;
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "repeated reuse retains the original owner without a frame chain" {
    var f: Fixture = .{};
    f.bind();
    {
        var current = try Storage.create(a, &f.input);
        defer current.release();
        const owner = current;
        for (0..1000) |index| {
            const update = scalarUpdate(current.view, @intCast(100 + index));
            const next = try current.reuse(a, &update);
            current.release();
            current = next;
            try std.testing.expect(current.content_owner.? == owner);
            try std.testing.expect(owner.content_owner == null);
            try std.testing.expectEqual(@as(usize, 1), owner.refs.load(.acquire));
            try std.testing.expectEqual(@as(usize, 3), f.text.count);
            try std.testing.expectEqual(@as(usize, 3), f.image.count);
            try std.testing.expectEqual(@as(u64, 19), owner.view.identity.sequence);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "reuse rejects identity changes and borrowed arrays or GPU targets" {
    var f: Fixture = .{};
    f.bind();
    const original = try Storage.create(a, &f.input);
    defer original.release();
    inline for (.{ "surface", "epoch", "sequence" }) |field| {
        var update = scalarUpdate(f.input, 20);
        @field(update.identity, field) = 0;
        try std.testing.expectError(error.InvalidInput, original.reuse(a, &update));
    }
    inline for (.{ "surface", "epoch" }) |field| {
        var update = scalarUpdate(f.input, 20);
        @field(update.identity, field) += 1;
        try std.testing.expectError(error.InvalidInput, original.reuse(a, &update));
    }
    inline for (.{ "drawable", "pass", "rows", "kitty_images", "kitty_placements", "live_kitty_ids" }) |field| {
        var update = scalarUpdate(f.input, 20);
        @field(update.parameters, field) = @ptrFromInt(64);
        try std.testing.expectError(error.InvalidInput, original.reuse(a, &update));
    }
    inline for (.{ "row_count", "kitty_image_count", "kitty_placement_count", "live_kitty_count" }) |field| {
        var update = scalarUpdate(f.input, 20);
        @field(update.parameters, field) = 1;
        try std.testing.expectError(error.InvalidInput, original.reuse(a, &update));
    }
    var update = scalarUpdate(f.input, 20);
    update.rows = &f.rows;
    try std.testing.expectError(error.InvalidInput, original.reuse(a, &update));
    update.rows = null;
    update.row_count = 1;
    try std.testing.expectError(error.InvalidInput, original.reuse(a, &update));
    try std.testing.expectEqual(@as(usize, 1), original.refs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), f.text.count);
    try std.testing.expectEqual(@as(usize, 3), f.image.count);
}

fn reuseAllocationExercise(allocator: std.mem.Allocator) !void {
    var f: Fixture = .{};
    f.bind();
    defer std.debug.assert(f.text.count == 1 and f.image.count == 1);
    const original = try Storage.create(a, &f.input);
    defer original.release();
    defer std.debug.assert(original.refs.load(.acquire) == 1);
    const update = scalarUpdate(f.input, 20);
    const next = try original.reuse(allocator, &update);
    next.release();
}

test "reuse allocation failure leaves existing frame ownership intact" {
    try std.testing.checkAllAllocationFailures(a, reuseAllocationExercise, .{});
}

fn reuseReader(frame: *Storage) void {
    for (0..1000) |_| {
        const ref = frame.retain();
        std.debug.assert(ref.view.identity.sequence == 20);
        std.debug.assert(ref.view.rows[0].placement.selection_upper == 7);
        std.debug.assert(ref.view.parameters.kitty_images[0].bytes[2] == 30);
        ref.release();
    }
    frame.release();
}

test "reused content remains owned across concurrent worker readers" {
    var f: Fixture = .{};
    f.bind();
    const original = try Storage.create(a, &f.input);
    const update = scalarUpdate(f.input, 20);
    const next = original.reuse(a, &update) catch |err| {
        original.release();
        return err;
    };
    original.release();
    const first = try std.Thread.spawn(.{}, reuseReader, .{next.retain()});
    const second = try std.Thread.spawn(.{}, reuseReader, .{next.retain()});
    first.join();
    second.join();
    next.release();
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "reuse C ABI reports invalid input and returns independently owned metadata" {
    var input = std.mem.zeroes(c.CmdyRenderFrameInput);
    input.identity = .{ .surface = 1, .epoch = 2, .sequence = 3 };
    var status: u32 = 99;
    try std.testing.expect(c.cmdy_render_frame_input_reuse(null, &input, &status) == null);
    try std.testing.expectEqual(@as(u32, c.CMDY_RENDER_INPUT_INVALID), status);
    const original = c.cmdy_render_frame_input_capture(&input, &status).?;
    defer c.cmdy_render_frame_input_release(original);
    try std.testing.expect(c.cmdy_render_frame_input_reuse(original, null, &status) == null);
    try std.testing.expectEqual(@as(u32, c.CMDY_RENDER_INPUT_INVALID), status);
    input.identity.sequence = 4;
    input.parameters.now = 1.25;
    const next = c.cmdy_render_frame_input_reuse(original, &input, &status).?;
    defer c.cmdy_render_frame_input_release(next);
    try std.testing.expectEqual(@as(u32, c.CMDY_RENDER_INPUT_OK), status);
    try std.testing.expectEqual(@as(u64, 4), c.cmdy_render_frame_input_view(next).*.identity.sequence);
    try std.testing.expectEqual(@as(f64, 1.25), c.cmdy_render_frame_input_view(next).*.parameters.now);
    try std.testing.expectEqual(@as(u64, 3), c.cmdy_render_frame_input_view(original).*.identity.sequence);
}

fn referencePair(row: *RowStorage, f: *Fixture) [2]c.CmdyRenderFrameRowReference {
    return .{
        .{ .row = @ptrCast(row), .placement = f.rows[0].placement },
        .{ .row = @ptrCast(row), .placement = f.rows[1].placement },
    };
}

fn referenceMetadata(f: *Fixture) c.CmdyRenderFrameInput {
    var input = f.input;
    input.rows = null;
    input.row_count = 0;
    return input;
}

test "frame referenced rows freeze nested values and survive producer retirement" {
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(a, &f.rows[0]);
    var references = referencePair(row, &f);
    const metadata = referenceMetadata(&f);
    const frame = try Storage.createReferenced(a, &metadata, &references, references.len);
    row.release();
    try std.testing.expectEqual(@as(usize, 2), f.text.count);
    try std.testing.expectEqual(@as(usize, 2), f.image.count);
    try std.testing.expect(!frame.ready.load(.acquire));
    try std.testing.expect(frame.metadata.rows == null and frame.metadata.row_count == 0);
    try std.testing.expect(frame.metadata.parameters.kitty_images == null and frame.metadata.parameters.kitty_image_count == 0);
    try std.testing.expectEqual(@as(f64, 100), frame.metadata.parameters.width);
    f.name = @splat('X');
    f.images[0].placement.col = 88;
    f.placeholders[0].col = 99;
    f.bytes = @splat(255);
    f.ids[0] = 0;
    references[0].placement.has_selection = 0;
    references[1].row = null;
    const view = frame.preparedView();
    try std.testing.expectEqual(@as(usize, 2), view.row_count);
    try std.testing.expectEqualStrings("Menl", std.mem.span(view.rows[1].key.font_name));
    try std.testing.expectEqual(@as(isize, 6), view.rows[0].images[0].placement.col);
    try std.testing.expectEqual(@as(isize, 8), view.rows[1].placeholders[0].col);
    try std.testing.expectEqual(@as(u8, 1), view.rows[0].placement.has_selection);
    try std.testing.expectEqual(@as(isize, 1), view.rows[1].placement.display_index);
    try std.testing.expectEqual(@as(isize, 31), view.rows[1].placement.source_row);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, view.parameters.kitty_images[0].bytes[0..4]);
    try std.testing.expectEqual(@as(u32, 91), view.parameters.live_kitty_ids[0]);
    try std.testing.expect(view.rows[0].key.font_name == view.rows[1].key.font_name);
    try std.testing.expect(view.rows[0].images == view.rows[1].images);
    try std.testing.expect(view.rows[0].placeholders == view.rows[1].placeholders);
    try std.testing.expect(frame.metadata.rows == null and frame.metadata.row_count == 0);
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "frame referenced cancellation before assembly releases row owners" {
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(a, &f.rows[0]);
    const references = referencePair(row, &f);
    const metadata = referenceMetadata(&f);
    const frame = try Storage.createReferenced(a, &metadata, &references, references.len);
    row.release();
    try std.testing.expect(!frame.ready.load(.acquire));
    frame.release();
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

fn rowAllocationExercise(allocator: std.mem.Allocator) !void {
    var f: Fixture = .{};
    f.bind();
    defer std.debug.assert(f.text.count == 1 and f.image.count == 1);
    const row = try RowStorage.create(allocator, &f.rows[0]);
    row.release();
}
test "frame row allocation failures unwind text and images" {
    try std.testing.checkAllAllocationFailures(a, rowAllocationExercise, .{});
}

fn referencedAllocationExercise(allocator: std.mem.Allocator) !void {
    var f: Fixture = .{};
    f.bind();
    defer std.debug.assert(f.text.count == 1 and f.image.count == 1);
    const row = try RowStorage.create(a, &f.rows[0]);
    defer row.release();
    const references = referencePair(row, &f);
    const metadata = referenceMetadata(&f);
    const frame = try Storage.createReferenced(allocator, &metadata, &references, references.len);
    defer frame.release();
    const update = scalarUpdate(metadata, 20);
    const next = try frame.reuse(allocator, &update);
    defer next.release();
    try std.testing.expect(!frame.ready.load(.acquire));
    try std.testing.expect(!next.ready.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), next.preparedView().row_count);
}
test "frame referenced allocation failures unwind reservations and reuse" {
    try std.testing.checkAllAllocationFailures(a, referencedAllocationExercise, .{});
}

test "frame referenced validation rejects late malformed handles and placements" {
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(a, &f.rows[0]);
    defer row.release();
    var references = referencePair(row, &f);
    var metadata = referenceMetadata(&f);
    references[1].row = null;
    try std.testing.expectError(error.InvalidInput, Storage.createReferenced(a, &metadata, &references, references.len));
    try std.testing.expectEqual(@as(usize, 1), row.refs.load(.acquire));
    references = referencePair(row, &f);
    references[1].placement.entry = @ptrCast(&f.text);
    try std.testing.expectError(error.InvalidInput, Storage.createReferenced(a, &metadata, &references, references.len));
    try std.testing.expectEqual(@as(usize, 1), row.refs.load(.acquire));
    try std.testing.expectError(error.InvalidInput, Storage.createReferenced(a, &metadata, null, 2));
    try std.testing.expectError(error.InvalidInput, Storage.createReferenced(a, &metadata, &references, std.math.maxInt(usize)));
    metadata.rows = &f.rows;
    try std.testing.expectError(error.InvalidInput, Storage.createReferenced(a, &metadata, null, 0));
}

test "frame frozen row rejects borrowed GPU resources and malformed nested input" {
    var f: Fixture = .{};
    f.bind();
    inline for (.{ "owner", "image", "owned_image" }) |field| {
        @field(f.images[0].placement, field) = @ptrCast(&f.text);
        try std.testing.expectError(error.InvalidInput, RowStorage.create(a, &f.rows[0]));
        @field(f.images[0].placement, field) = null;
    }
    f.rows[0].placeholders = null;
    try std.testing.expectError(error.InvalidInput, RowStorage.create(a, &f.rows[0]));
    f.bind();
    f.rows[0].key.font_name = null;
    try std.testing.expectError(error.InvalidInput, RowStorage.create(a, &f.rows[0]));
    f.bind();
    f.rows[0].text = null;
    try std.testing.expectError(error.InvalidInput, RowStorage.create(a, &f.rows[0]));
    try std.testing.expectEqual(@as(usize, 1), f.text.count);
    try std.testing.expectEqual(@as(usize, 1), f.image.count);
}

test "frame referenced reuse before preparation retains only original content" {
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(a, &f.rows[0]);
    defer row.release();
    const references = referencePair(row, &f);
    const metadata = referenceMetadata(&f);
    const original = try Storage.createReferenced(a, &metadata, &references, references.len);
    var previous = original.retain();
    for (20..1044) |sequence| {
        var update = scalarUpdate(metadata, sequence);
        update.parameters.now = @floatFromInt(sequence);
        const next = try previous.reuse(a, &update);
        previous.release();
        previous = next;
        try std.testing.expect(next.content_owner == original);
        try std.testing.expect(!next.ready.load(.acquire));
        try std.testing.expectEqual(@as(usize, 2), original.refs.load(.acquire));
    }
    try std.testing.expect(!original.ready.load(.acquire));
    original.release();
    const view = previous.preparedView();
    try std.testing.expectEqual(@as(u64, 1043), view.identity.sequence);
    try std.testing.expectEqual(@as(f64, 1043), view.parameters.now);
    try std.testing.expectEqual(@as(usize, 2), view.row_count);
    previous.release();
    try std.testing.expectEqual(@as(usize, 1), row.refs.load(.acquire));
}

fn referencedReader(frame: *Storage) void {
    for (0..1000) |_| {
        std.debug.assert(frame.metadata.rows == null and frame.metadata.row_count == 0);
        const view = frame.preparedView();
        std.debug.assert(view.row_count == 2 and view.rows[1].placement.source_row == 31);
        std.debug.assert(view.rows[0].key.font_name == view.rows[1].key.font_name);
        std.debug.assert(view.parameters.kitty_images[0].bytes[2] == 30);
        std.debug.assert(frame.metadata.parameters.kitty_images == null);
    }
}
test "frame concurrent first preparation and metadata readers share frozen rows" {
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(a, &f.rows[0]);
    defer row.release();
    const references = referencePair(row, &f);
    const metadata = referenceMetadata(&f);
    const original = try Storage.createReferenced(a, &metadata, &references, references.len);
    defer original.release();
    const update = scalarUpdate(metadata, 20);
    const next = try original.reuse(a, &update);
    defer next.release();
    const first = try std.Thread.spawn(.{}, referencedReader, .{original});
    defer first.join();
    const second = try std.Thread.spawn(.{}, referencedReader, .{next});
    defer second.join();
    referencedReader(next);
    try std.testing.expect(original.preparedView().rows == next.preparedView().rows);
}

test "frame referenced assembly and metadata access allocate nothing" {
    var f: Fixture = .{};
    f.bind();
    const row = try RowStorage.create(a, &f.rows[0]);
    defer row.release();
    const references = referencePair(row, &f);
    const metadata = referenceMetadata(&f);
    var failing = std.testing.FailingAllocator.init(a, .{});
    const frame = try Storage.createReferenced(failing.allocator(), &metadata, &references, references.len);
    defer frame.release();
    const update = scalarUpdate(metadata, 20);
    const next = try frame.reuse(failing.allocator(), &update);
    defer next.release();
    failing.fail_index = failing.alloc_index;
    try std.testing.expect(next.metadata.rows == null);
    try std.testing.expectEqual(@as(usize, 2), next.preparedView().row_count);
    try std.testing.expect(frame.preparedView().rows == next.preparedView().rows);
    try std.testing.expect(!failing.has_induced_failure);
}

test "frame referenced C ABI accepts empty content and exposes scalar metadata" {
    var input = std.mem.zeroes(c.CmdyRenderFrameInput);
    input.identity = .{ .surface = 1, .epoch = 2, .sequence = 3 };
    input.parameters.width = 500;
    var status: u32 = 99;
    try std.testing.expect(c.cmdy_render_frame_row_capture(null, &status) == null);
    try std.testing.expectEqual(@as(u32, c.CMDY_RENDER_INPUT_INVALID), status);
    const frame = c.cmdy_render_frame_input_capture_referenced(&input, null, 0, &status).?;
    defer c.cmdy_render_frame_input_release(frame);
    try std.testing.expectEqual(@as(u32, c.CMDY_RENDER_INPUT_OK), status);
    const metadata = c.cmdy_render_frame_input_metadata(frame);
    try std.testing.expectEqual(@as(f64, 500), metadata.*.parameters.width);
    try std.testing.expect(metadata.*.rows == null and metadata.*.row_count == 0);
    try std.testing.expect(c.cmdy_render_frame_input_view(frame).*.rows == null);
    try std.testing.expect(c.cmdy_render_frame_input_metadata(null) == null);
}
