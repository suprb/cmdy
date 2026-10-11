const std = @import("std");
const t = std.testing;
const frame = @import("render_frame_input.zig");
const input = @import("render_input.zig");
const Buffer = @import("buffer.zig").Buffer;
const Snapshot = @import("buffer_snapshot.zig").Snapshot;
const c = frame.c;
const platform = input.c;
const models = @import("render_model_input.zig");

const Fixture = struct {
    snapshot: *Snapshot,
    style: *input.FrozenStyle,
    raster: *input.FrozenParameters,
    fn init() !Fixture {
        var buffer = try Buffer.init(t.allocator, 8, 4, false, 0);
        defer buffer.deinit();
        try buffer.liveLine(1).setCell(0, .{ .scalar = 'A', .width = 1 });
        buffer.liveLine(1).render_mode = .doubled_top;
        const snapshot = try Snapshot.capture(t.allocator, &buffer, 0, 4);
        errdefer snapshot.release();
        const name = platform.CFStringCreateWithCString(null, "Menlo", platform.kCFStringEncodingUTF8).?;
        defer platform.CFRelease(name);
        const font = platform.CTFontCreateWithName(name, 14, null).?;
        defer platform.CFRelease(font);
        var style_input = std.mem.zeroes(c.CmdyShapeStyleInput);
        @memset(&style_input.fonts, font);
        @memset(&style_input.colors, platform.cmdy_platform_text_white());
        const source = c.cmdy_shape_style_create(&style_input).?;
        defer c.cmdy_shape_style_free(source);
        const style: *input.FrozenStyle = @ptrCast(@alignCast(c.cmdy_render_row_style_capture(source, null).?));
        errdefer style.release();
        var raster_input = std.mem.zeroes(input.c.CmdyRenderRowInput);
        raster_input.cols = 8;
        raster_input.width = 96;
        raster_input.height = 20;
        raster_input.cell_width = 12;
        raster_input.cell_height = 20;
        raster_input.scale = 1;
        raster_input.normal_font = font;
        raster_input.foreground = platform.cmdy_platform_text_white();
        const raster = try input.FrozenParameters.create(t.allocator, &raster_input);
        return .{ .snapshot = snapshot, .style = style, .raster = raster };
    }
    fn deinit(self: Fixture) void {
        self.snapshot.release();
        self.style.release();
        self.raster.release();
    }
    fn metadata() c.CmdyRenderFrameInput {
        var value = std.mem.zeroes(c.CmdyRenderFrameInput);
        value.identity = .{ .surface = 9, .epoch = 1, .sequence = 1 };
        value.parameters.grid_rows = 2;
        value.parameters.grid_cols = 8;
        value.parameters.display_top_row = 1;
        value.buffer_line_count = 4;
        value.retained_row_origin = 100;
        return value;
    }
    fn packet(self: Fixture) c.CmdyRenderViewportInput {
        var value = std.mem.zeroes(c.CmdyRenderViewportInput);
        value.snapshot = @ptrCast(self.snapshot);
        value.style = @ptrCast(self.style);
        value.raster = @ptrCast(self.raster);
        value.key.cols = 8;
        value.key.width = 96;
        value.key.height = 20;
        value.key.font_name = "Menlo";
        value.font_name_bytes = 5;
        value.fringe_rows = 1;
        value.has_selection = 1;
        value.selection_start_row = 1;
        value.selection_start_col = -5;
        value.selection_end_row = 2;
        value.selection_end_col = 900;
        return value;
    }
};

fn modelPacket(f: Fixture) models.c.CmdyRenderModelInput {
    var value = std.mem.zeroes(models.c.CmdyRenderModelInput);
    value.snapshot = @ptrCast(f.snapshot);
    value.generation = 8;
    value.rows = 2;
    value.cols = 8;
    value.buffer_line_count = 4;
    value.retained_row_origin = 101;
    value.display_top_row = 1;
    value.live_top_row = 2;
    value.cursor_row = 2;
    value.cursor_col = 3;
    value.cursor_style = 5;
    value.kitty_next_image = 7;
    return value;
}

test "model publication rebases selection and style while preserving frozen UI geometry" {
    const f = try Fixture.init();
    defer f.deinit();
    var metadata = Fixture.metadata();
    metadata.parameters.scroll_pixels = 0.25;
    var packet = f.packet();
    const original = try frame.Frame.createViewport(t.allocator, &metadata, &packet, null);
    defer original.release();
    var source = modelPacket(f);
    source.alternate_buffer = 1;
    const model = try models.Model.create(t.allocator, &source);
    defer model.release();
    source.cursor_col = 900; // The producer may immediately reuse its POD input.
    const next = try model.apply(t.allocator, original);
    defer next.release();
    const viewport = next.viewportInput().?;
    try t.expectEqual(@as(u64, 8), viewport.settings.model_generation);
    try t.expectEqual(@as(isize, 1), viewport.settings.style_row_offset);
    try t.expectEqual(@as(isize, 0), viewport.settings.selection_start_row);
    try t.expectEqual(@as(isize, 1), viewport.settings.selection_end_row);
    try t.expectEqual(@as(isize, 3), next.metadata.parameters.cursor_col);
    try t.expectEqual(@as(isize, 1), next.metadata.parameters.cursor_display_row);
    try t.expectEqual(@as(u8, 1), next.metadata.parameters.cursor_valid);
    try t.expectEqual(@as(u8, 1), next.metadata.alternate_buffer);
    try t.expectEqual(@as(u8, 1), viewport.settings.key.alternate_buffer);
    try t.expectEqual(@as(u32, 7), viewport.settings.key.kitty_next_image);
    try t.expectEqual(@as(f64, 0.25), next.metadata.parameters.scroll_pixels);
    try t.expectEqual(metadata.identity, next.metadata.identity);
    try t.expectEqual(@as(isize, 0), original.viewportInput().?.settings.style_row_offset);
    // Re-applying the same origin must not cumulatively move UI coordinates.
    const again = try model.apply(t.allocator, next);
    defer again.release();
    try t.expectEqual(@as(isize, 1), again.viewportInput().?.settings.style_row_offset);
    try t.expectEqual(@as(isize, 0), again.viewportInput().?.settings.selection_start_row);
}

test "replacing model frames does not retain previous frame or snapshot chains" {
    const f = try Fixture.init();
    defer f.deinit();
    var metadata = Fixture.metadata();
    var packet = f.packet();
    var latest = try frame.Frame.createViewport(t.allocator, &metadata, &packet, null);
    defer latest.release();
    var buffer = try Buffer.init(t.allocator, 8, 4, false, 0);
    defer buffer.deinit();
    const replacement = try Snapshot.capture(t.allocator, &buffer, 0, 4);
    defer replacement.release();
    var source = modelPacket(f);
    source.snapshot = @ptrCast(replacement);
    for (0..128) |i| {
        source.generation = i + 1;
        const model = try models.Model.create(t.allocator, &source);
        const next = model.apply(t.allocator, latest) catch |err| {
            model.release();
            return err;
        };
        model.release();
        latest.release();
        latest = next;
        try t.expectEqual(@as(usize, 1), f.snapshot.refs.load(.acquire));
        try t.expectEqual(@as(usize, 2), replacement.refs.load(.acquire));
        try t.expectEqual(@as(usize, 2), f.style.refs.load(.acquire));
        try t.expectEqual(@as(usize, 2), f.raster.refs.load(.acquire));
    }
}

fn modelAllocationCase(a: std.mem.Allocator, source: *const models.c.CmdyRenderModelInput, original: *frame.Frame) !void {
    const model = try models.Model.create(a, source);
    defer model.release();
    const next = try model.apply(a, original);
    defer next.release();
}

test "model capture and UI recombination release ownership at every allocation failure" {
    const f = try Fixture.init();
    defer f.deinit();
    var metadata = Fixture.metadata();
    var packet = f.packet();
    const original = try frame.Frame.createViewport(t.allocator, &metadata, &packet, null);
    defer original.release();
    const source = modelPacket(f);
    try t.checkAllAllocationFailures(t.allocator, modelAllocationCase, .{ &source, original });
    try t.expectEqual(@as(usize, 2), f.snapshot.refs.load(.acquire));
    try t.expectEqual(@as(usize, 2), f.style.refs.load(.acquire));
    try t.expectEqual(@as(usize, 2), f.raster.refs.load(.acquire));
}

test "model publication rejects missing viewport rows and incompatible UI dimensions" {
    const f = try Fixture.init();
    defer f.deinit();
    var source = modelPacket(f);
    source.generation = 0;
    try t.expectError(error.InvalidInput, models.Model.create(t.allocator, &source));
    source.generation = 1;
    source.buffer_line_count = 10;
    source.display_top_row = 7;
    try t.expectError(error.InvalidInput, models.Model.create(t.allocator, &source));
    source = modelPacket(f);
    source.cols = 9;
    const model = try models.Model.create(t.allocator, &source);
    defer model.release();
    var metadata = Fixture.metadata();
    var packet = f.packet();
    const original = try frame.Frame.createViewport(t.allocator, &metadata, &packet, null);
    defer original.release();
    try t.expectError(error.InvalidInput, model.apply(t.allocator, original));
}

test "viewport frame retains one frozen window and resolves coordinates modes and clamped selection" {
    const f = try Fixture.init();
    defer f.deinit();
    var metadata = Fixture.metadata();
    var packet = f.packet();
    var name = [_]u8{ 'M', 'e', 'n', 'l', 'o' };
    packet.key.font_name = &name;
    const owned = try frame.Frame.createViewport(t.allocator, &metadata, &packet, null);
    defer owned.release();
    @memset(&name, 'X');
    try t.expectEqual(@as(usize, 2), f.snapshot.refs.load(.acquire));
    try t.expectEqual(@as(usize, 2), f.style.refs.load(.acquire));
    try t.expectEqual(@as(usize, 2), f.raster.refs.load(.acquire));
    try t.expectEqual(@as(usize, 0), owned.preparedView().row_count);
    const viewport = owned.viewportInput().?;
    try t.expectEqualStrings("Menlo", viewport.name);
    try t.expectEqual(@as(usize, 4), viewport.visible.count());
    for (0..4) |i| {
        const request = viewport.visible.at(i).?;
        const key = viewport.key(request);
        const placement = viewport.placement(request);
        try t.expectEqual(@as(isize, @intCast(i)) + 100, key.absolute_row);
        try t.expectEqual(@as(isize, @intCast(i)) - 1, placement.display_index);
        try t.expectEqual(@as(u8, @intFromBool(i == 1 or i == 2)), placement.has_selection);
        if (placement.has_selection != 0) {
            try t.expectEqual(@as(isize, 0), placement.selection_lower);
            try t.expectEqual(@as(isize, 7), placement.selection_upper);
        }
        if (i == 1) {
            try t.expectEqual(@as(u32, 2), key.line_mode);
            try t.expectEqual(@as(u32, 'A'), viewport.line(1).cell(0).scalar);
        }
    }
    for (2..66) |sequence| {
        metadata.identity.sequence = sequence;
        const reused = try owned.reuse(t.allocator, &metadata);
        try t.expect(reused.viewportInput() == viewport);
        try t.expectEqual(@as(usize, 2), f.snapshot.refs.load(.acquire));
        reused.release();
    }
}

fn allocationExercise(a: std.mem.Allocator, f: *const Fixture) !void {
    var metadata = Fixture.metadata();
    var packet = f.packet();
    defer {
        std.debug.assert(f.snapshot.refs.load(.acquire) == 1);
        std.debug.assert(f.style.refs.load(.acquire) == 1);
        std.debug.assert(f.raster.refs.load(.acquire) == 1);
    }
    const owned = try frame.Frame.createViewport(a, &metadata, &packet, null);
    owned.release();
}
test "every viewport frame allocation failure unwinds snapshot style raster and font ownership" {
    const f = try Fixture.init();
    defer f.deinit();
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{&f});
}

test "viewport capture rejects missing rows mismatched raster and reversed selection" {
    const f = try Fixture.init();
    defer f.deinit();
    var metadata = Fixture.metadata();
    var packet = f.packet();
    metadata.buffer_line_count = 5;
    metadata.parameters.grid_rows = 4;
    try t.expectError(error.InvalidInput, frame.Frame.createViewport(t.allocator, &metadata, &packet, null));
    metadata = Fixture.metadata();
    packet.key.width = 1;
    try t.expectError(error.InvalidInput, frame.Frame.createViewport(t.allocator, &metadata, &packet, null));
    packet = f.packet();
    packet.selection_start_row = 3;
    try t.expectError(error.InvalidInput, frame.Frame.createViewport(t.allocator, &metadata, &packet, null));
    try t.expectEqual(@as(usize, 1), f.snapshot.refs.load(.acquire));
}

test "line image input shares large payload storage within a small metadata allocation" {
    const graphics = @import("graphics.zig");
    const bytes = try t.allocator.alloc(u8, 4 * 1024 * 1024);
    const payload = try graphics.Payload.createOwned(t.allocator, .rgba, bytes, 1024, 1024);
    var arena: [1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&arena);
    const owned = try frame.Image.share(fixed.allocator(), payload, [_]u8{19} ** 16);
    try t.expect(owned.view.bytes == payload.bytes.ptr);
    try t.expectEqual(@as(usize, 2), payload.refs.load(.acquire));
    payload.release();
    try t.expectEqual(@as(usize, 4 * 1024 * 1024), owned.view.byte_count);
    owned.release();
}
