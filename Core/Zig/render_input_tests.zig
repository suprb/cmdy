const std = @import("std");
const t = std.testing;
const m = @import("render_input.zig");
const c = m.c;

const Value = struct { number: i32 };
const Objects = struct {
    pub fn capture(a: std.mem.Allocator, _: m.Kind, source: m.Object) m.CaptureError!m.Object {
        const value: *const Value = @ptrCast(@alignCast(source.?));
        if (value.number < 0) return error.UnsupportedAttributes;
        const copy = try a.create(Value);
        copy.* = value.*;
        return copy;
    }
    pub fn release(a: std.mem.Allocator, source: m.Object) void {
        a.destroy(@as(*Value, @ptrCast(@alignCast(@constCast(source.?)))));
    }
};
const Owned = m.Storage(Objects);
fn number(object: m.Object) i32 {
    return @as(*const Value, @ptrCast(@alignCast(object.?))).number;
}
const Fixture = struct {
    font: Value = .{ .number = 14 },
    color: Value = .{ .number = 7 },
    text: Value = .{ .number = 42 },
    boundaries: [3]isize = .{ 0, 1, 3 },
    rects: [1]c.CmdyRenderBlockRect = .{.{ .x0 = 0, .x1 = 8, .y0 = 0, .y1 = 8, .alpha = 0.5 }},
    segment: c.CmdyRenderTextSegment = std.mem.zeroes(c.CmdyRenderTextSegment),
    block: c.CmdyRenderBlock = std.mem.zeroes(c.CmdyRenderBlock),
    box: c.CmdyRenderBox = std.mem.zeroes(c.CmdyRenderBox),
    fn input(self: *Fixture) c.CmdyRenderRowInput {
        self.segment = .{ .attributed_string = &self.text, .column = 1, .column_width = 2, .character_count = 2, .boundaries = &self.boundaries, .boundary_count = 3, .has_boundaries = 1, .disable_sharing = 1 };
        self.block = .{ .column = 5, .column_width = 1, .code_point = 0x2588, .rects = &self.rects, .rect_count = 1, .foreground = &self.color };
        self.box = .{ .column = 6, .column_width = 1, .code_point = 0x2500, .foreground = &self.color };
        var value = std.mem.zeroes(c.CmdyRenderRowInput);
        value.normal_font = &self.font;
        value.foreground = &self.color;
        value.segments = &self.segment;
        value.segment_count = 1;
        value.blocks = &self.block;
        value.block_count = 1;
        value.boxes = &self.box;
        value.box_count = 1;
        value.cols = 80;
        value.width = 640;
        value.height = 20;
        value.cell_width = 8;
        value.cell_height = 20;
        value.scale = 2;
        value.underline_position = 3;
        value.underline_thickness = 1;
        value.coverage_exponent = 1.35;
        value.snaps_y = 1;
        value.antialias_blocks = 1;
        value.ascii_caching = 1;
        value.font_caching = 1;
        return value;
    }
};

test "row capture survives producer mutation of every nested input buffer" {
    var fixture: Fixture = .{};
    var input = fixture.input();
    const owned = try Owned.create(t.allocator, &input);
    defer owned.release();
    fixture.font.number = 100;
    fixture.color.number = 100;
    fixture.text.number = 100;
    fixture.boundaries = .{ 99, 99, 99 };
    fixture.rects[0].alpha = 0;
    fixture.segment.column = 99;
    fixture.block.column = 99;
    fixture.box.column = 99;
    input.width = 1;
    try t.expectEqual(@as(i32, 14), number(owned.input.normal_font));
    try t.expectEqual(@as(i32, 7), number(owned.input.foreground));
    const segment = owned.input.segments[0];
    try t.expectEqual(@as(i32, 42), number(segment.attributed_string));
    try t.expectEqualSlices(isize, &.{ 0, 1, 3 }, segment.boundaries[0..3]);
    try t.expectEqual(@as(isize, 1), segment.column);
    try t.expectEqual(@as(u8, 1), segment.disable_sharing);
    try t.expectEqual(@as(f64, 0.5), owned.input.blocks[0].rects[0].alpha);
    try t.expectEqual(@as(isize, 5), owned.input.blocks[0].column);
    try t.expectEqual(@as(isize, 6), owned.input.boxes[0].column);
    try t.expectEqual(@as(isize, 640), owned.input.width);
    try t.expectEqual(@as(f64, 2), owned.input.scale);
    try t.expectEqual(@as(u8, 1), owned.input.font_caching);
}

test "positive counts reject null buffers at every nesting level" {
    var fixture: Fixture = .{};
    var input = fixture.input();
    input.segments = null;
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
    input = fixture.input();
    input.blocks = null;
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
    input = fixture.input();
    input.boxes = null;
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
    input = fixture.input();
    fixture.segment.boundaries = null;
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
    input = fixture.input();
    fixture.block.rects = null;
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
}

test "empty buffers are never read and normalize to null" {
    var input = std.mem.zeroes(c.CmdyRenderRowInput);
    input.segments = @ptrFromInt(@alignOf(c.CmdyRenderTextSegment));
    input.blocks = @ptrFromInt(@alignOf(c.CmdyRenderBlock));
    input.boxes = @ptrFromInt(@alignOf(c.CmdyRenderBox));
    const owned = try Owned.create(t.allocator, &input);
    defer owned.release();
    try t.expect(owned.input.segments == null and owned.input.blocks == null and owned.input.boxes == null);
}

test "overflowing lengths are rejected before reading buffers" {
    var fixture: Fixture = .{};
    var input = fixture.input();
    input.segment_count = std.math.maxInt(usize);
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
    input = fixture.input();
    fixture.block.rect_count = std.math.maxInt(usize);
    try t.expectError(error.InvalidInput, Owned.create(t.allocator, &input));
}

test "unsupported object capture releases previously captured objects" {
    var fixture: Fixture = .{};
    const input = fixture.input();
    fixture.text.number = -1;
    try t.expectError(error.UnsupportedAttributes, Owned.create(t.allocator, &input));
}

fn allocationFailureExercise(a: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    const input = fixture.input();
    const owned = try Owned.create(a, &input);
    owned.release();
}
test "every Zig allocation failure unwinds nested arrays and object ownership" {
    try t.checkAllAllocationFailures(t.allocator, allocationFailureExercise, .{});
}

test "retained row inputs can be read and released by independent workers" {
    const Reader = struct {
        row: *Owned,
        done: bool = false,
        fn run(self: *@This()) void {
            defer self.row.release();
            self.done = self.row.input.segments[0].boundaries[2] == 3 and number(self.row.input.segments[0].attributed_string) == 42;
        }
    };
    var fixture: Fixture = .{};
    const input = fixture.input();
    const owned = try Owned.create(t.allocator, &input);
    defer owned.release();
    var first: Reader = .{ .row = owned.retain() };
    const a = std.Thread.spawn(.{}, Reader.run, .{&first}) catch |err| {
        first.row.release();
        return err;
    };
    var joined_a = false;
    defer if (!joined_a) a.join();
    var second: Reader = .{ .row = owned.retain() };
    const b = std.Thread.spawn(.{}, Reader.run, .{&second}) catch |err| {
        second.row.release();
        return err;
    };
    a.join();
    joined_a = true;
    b.join();
    try t.expect(first.done and second.done);
}

const Parameters = m.ParameterStorage(Objects);
fn parameterInput(fixture: *Fixture) c.CmdyRenderRowInput {
    var input = fixture.input();
    input.segments = null;
    input.segment_count = 0;
    input.blocks = null;
    input.block_count = 0;
    input.boxes = null;
    input.box_count = 0;
    return input;
}

test "shared parameters own scalars font and color after producer mutation" {
    var fixture: Fixture = .{};
    var input = parameterInput(&fixture);
    const frozen = try Parameters.create(t.allocator, &input);
    defer frozen.release();
    fixture.font.number = 999;
    fixture.color.number = 999;
    input.width = 1;
    input.scale = 99;
    try t.expectEqual(@as(i32, 14), number(frozen.input.normal_font));
    try t.expectEqual(@as(i32, 7), number(frozen.input.foreground));
    try t.expectEqual(@as(isize, 640), frozen.input.width);
    try t.expectEqual(@as(f64, 2), frozen.input.scale);
    try t.expectEqual(@as(f32, 1.35), frozen.input.coverage_exponent);
}

test "shared parameters reject all borrowed arrays and counts" {
    var fixture: Fixture = .{};
    for (0..6) |index| {
        var input = parameterInput(&fixture);
        switch (index) {
            0 => input.segments = &fixture.segment,
            1 => input.segment_count = 1,
            2 => input.blocks = &fixture.block,
            3 => input.block_count = 1,
            4 => input.boxes = &fixture.box,
            5 => input.box_count = 1,
            else => unreachable,
        }
        try t.expectError(error.InvalidInput, Parameters.create(t.allocator, &input));
    }
}

fn parameterAllocationFailureExercise(a: std.mem.Allocator) !void {
    var fixture: Fixture = .{};
    const input = parameterInput(&fixture);
    const frozen = try Parameters.create(a, &input);
    frozen.release();
}
test "shared parameter allocation failures release partial captures" {
    try t.checkAllAllocationFailures(t.allocator, parameterAllocationFailureExercise, .{});
}

test "unsupported foreground releases the already captured parameter font" {
    var fixture: Fixture = .{};
    const input = parameterInput(&fixture);
    fixture.color.number = -1;
    try t.expectError(error.UnsupportedAttributes, Parameters.create(t.allocator, &input));
}

test "workers share parameter object identity and outlive the producer reference" {
    const Reader = struct {
        packet: *Parameters,
        font: m.Object,
        color: m.Object,
        done: bool = false,
        fn run(self: *@This()) void {
            defer self.packet.release();
            self.done = self.packet.input.normal_font == self.font and self.packet.input.foreground == self.color and
                number(self.font) == 14 and number(self.color) == 7 and self.packet.input.width == 640;
        }
    };
    var fixture: Fixture = .{};
    const input = parameterInput(&fixture);
    const frozen = try Parameters.create(t.allocator, &input);
    var readers: [8]Reader = undefined;
    for (&readers) |*reader| reader.* = .{
        .packet = frozen.retain(),
        .font = frozen.input.normal_font,
        .color = frozen.input.foreground,
    };
    frozen.release();
    var started: usize = 0;
    var joined = false;
    var threads: [readers.len]std.Thread = undefined;
    defer if (!joined) {
        for (threads[0..started]) |thread| thread.join();
        for (readers[started..]) |reader| reader.packet.release();
    };
    for (&readers, 0..) |*reader, index| {
        threads[index] = try std.Thread.spawn(.{}, Reader.run, .{reader});
        started += 1;
    }
    for (threads[0..started]) |thread| thread.join();
    joined = true;
    for (&readers) |*reader| try t.expect(reader.done);
}
