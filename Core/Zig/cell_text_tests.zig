const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const Line = @import("line.zig").Line;
const legacy = @import("legacy_abi.zig");
const a = std.testing.allocator;

test "parser rows preserve raw followers while exposing only each first grapheme" {
    const Case = struct { input: []const u8, text: []const u8, extra: u32 };
    const cases = [_]Case{
        .{ .input = "A\u{200b}B", .text = "AB", .extra = 0x200b },
        .{ .input = "A\u{200e}B", .text = "AB", .extra = 0x200e },
        .{ .input = "A\u{2028}B", .text = "AB", .extra = 0x2028 },
        .{ .input = "A\u{2060}B", .text = "AB", .extra = 0x2060 },
        .{ .input = "A\u{200c}B", .text = "A\u{200c}B", .extra = 0x200c },
        .{ .input = "A\u{200d}\u{1f33e}", .text = "A\u{200d}\u{1f33e} ", .extra = 0x200d },
        .{ .input = "\u{1f469}\u{200d}\u{1f33e}", .text = "\u{1f469}\u{200d}\u{1f33e} ", .extra = 0x200d },
        .{ .input = "\u{1f469}\u{200b}\u{200d}\u{1f33e}", .text = "\u{1f469} ", .extra = 0x200b },
        .{ .input = "\u{1f1e6}\u{301}\u{1f1e7}B", .text = "\u{1f1e6}\u{301} B", .extra = 0x301 },
    };
    for (cases) |case| for ([_]usize{ 1, 65536 }) |chunk| {
        var terminal = try Terminal.init(a, 12, 2, 0);
        defer terminal.deinit();
        var offset: usize = 0;
        while (offset < case.input.len) {
            const end = @min(offset + chunk, case.input.len);
            try terminal.feed(case.input[offset..end]);
            offset = end;
        }
        const line = terminal.buffer().line(0).?;
        const before = try line.clone();
        defer before.release();
        const version_before_text = line.version();
        const text = try line.trimmedText(a);
        defer a.free(text);
        try std.testing.expectEqualStrings(case.text, text);
        try std.testing.expectEqual(case.extra, line.get(0).extras.?[0]);
        try std.testing.expectEqualSlices(u32, before.get(0).extras.?, line.get(0).extras.?);
        try std.testing.expectEqual(version_before_text, line.version());
    };
}

test "line projection preserves blank stub and invalid raw lead semantics" {
    const line = try Line.create(a, 5, .{});
    defer line.release();
    try line.set(0, .{ .cell = .{ .scalar = 0xd800 }, .extras = &.{ 0x301 } });
    try line.set(1, .{ .cell = .{ .scalar = 'A' }, .extras = &.{ 0x110000, 0x301, 'B' } });
    try line.setCell(3, .{ .scalar = 0x1f469, .width = 2 });
    try line.setCell(4, .{ .width = 0 });
    const text = try line.trimmedText(a);
    defer a.free(text);
    try std.testing.expectEqualStrings(" A\u{301} \u{1f469} ", text);
}

test "legacy C text uses native first-grapheme projection after normal feed" {
    const handle = legacy.cmdy_create(8, 2) orelse return error.OutOfMemory;
    defer legacy.cmdy_free(handle);
    const input = "A\u{200b}B";
    legacy.cmdy_feed(handle, input, input.len);
    var output: [32]u8 = @splat(0xff);
    const count = legacy.cmdy_line_text(handle, 0, &output, output.len);
    try std.testing.expectEqual(@as(isize, 2), count);
    try std.testing.expectEqualSlices(u8, "AB\x00", output[0..3]);
    // Existing byte truncation semantics are preserved, including capacity 1.
    try std.testing.expectEqual(@as(isize, 0), legacy.cmdy_line_text(handle, 0, &output, 1));
    try std.testing.expectEqual(@as(u8, 0), output[0]);
}

test "failed-command callback projects both command input and output text" {
    const module = @import("terminal.zig");
    const Sink = struct {
        command: [64]u8 = undefined,
        output: [64]u8 = undefined,
        command_len: usize = 0,
        output_len: usize = 0,
        calls: usize = 0,
        fn event(context: ?*anyopaque, event_value: *const module.Event) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (event_value.kind != .failed_command) return;
            self.calls += 1;
            self.command_len = event_value.length;
            self.output_len = event_value.length2;
            @memcpy(self.command[0..self.command_len], event_value.bytes.?[0..event_value.length]);
            @memcpy(self.output[0..self.output_len], event_value.bytes2.?[0..event_value.length2]);
        }
    };
    var sink: Sink = .{};
    var terminal = try Terminal.init(a, 12, 4, 0);
    defer terminal.deinit();
    terminal.host = .{ .context = &sink, .event = Sink.event };
    terminal.has_failed_command_provider = true;
    try terminal.feed("\x1b]133;A\x07>\x1b]133;B\x07A\u{200b}B\r\n\x1b]133;C\x07O\u{2060}P\r\n\x1b]133;D;1\x07");
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
    try std.testing.expectEqualStrings("AB", sink.command[0..sink.command_len]);
    try std.testing.expectEqualStrings("OP", sink.output[0..sink.output_len]);
}
