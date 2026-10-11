const std = @import("std");
const native = @import("parser.zig");
const Parser = native.Parser;
const testing = std.testing;
const Allocator = std.mem.Allocator;

const Recorder = struct {
    allocator: Allocator = testing.allocator,
    log: std.ArrayList(u8) = .empty,
    parser: ?*Parser = null,
    reentry: enum { none, scalar_partial, scalar_escape, control_reset, csi, esc, osc, hook, put, unhook, apc } = .none,
    entered: bool = false,

    fn deinit(self: *Recorder) void {
        self.log.deinit(self.allocator);
    }
    fn integer(self: *Recorder, value: i64) !void {
        var data: [8]u8 = undefined;
        std.mem.writeInt(i64, &data, value, .little);
        try self.log.appendSlice(self.allocator, &data);
    }
    fn bytes(self: *Recorder, value: []const u8) !void {
        try self.integer(@intCast(value.len));
        try self.log.appendSlice(self.allocator, value);
    }
    fn parameters(self: *Recorder, value: []const isize) !void {
        try self.integer(@intCast(value.len));
        for (value) |p| try self.integer(p);
    }
    fn tag(self: *Recorder, value: u8) !void {
        try self.log.append(self.allocator, value);
    }
    pub fn printScalar(self: *Recorder, scalar: u32) !void {
        try self.tag('P');
        try self.integer(scalar);
        if (!self.entered and scalar == 0x20ac) {
            if (self.reentry == .scalar_partial) {
                self.entered = true;
                try self.parser.?.feed(&.{ 0xf0, 0x9f }, self);
            } else if (self.reentry == .scalar_escape) {
                self.entered = true;
                try self.parser.?.feed("\x1b[3", self);
            }
        }
    }
    pub fn printASCII(self: *Recorder, value: []const u8) !void {
        for (value) |b| try self.printScalar(b);
    }
    pub fn execute(self: *Recorder, control: u8) !void {
        try self.tag('E');
        try self.tag(control);
        if (!self.entered and self.reentry == .control_reset) {
            self.entered = true;
            self.parser.?.reset();
        }
    }
    pub fn csi(self: *Recorder, final: u8, params: []const isize, collect: []const u8) !void {
        try self.tag('C');
        try self.tag(final);
        try self.parameters(params);
        try self.bytes(collect);
        if (!self.entered and self.reentry == .csi) {
            self.entered = true;
            try testing.expectEqual(.ground, self.parser.?.state);
            try self.parser.?.feed("\x1b[32;44mR\x1b[", self);
            // Outer input arrays must survive nested clearSequence and growth.
            try testing.expectEqualSlices(isize, &.{ 31, 1 }, params);
            try testing.expectEqualSlices(u8, "?", collect);
        }
    }
    pub fn esc(self: *Recorder, final: u8, collect: []const u8) !void {
        try self.tag('S');
        try self.tag(final);
        try self.bytes(collect);
        if (!self.entered and self.reentry == .esc) {
            self.entered = true;
            try testing.expectEqual(.ground, self.parser.?.state);
            try self.parser.?.feed("\x1b[31;", self);
            try testing.expectEqualSlices(u8, " #", collect);
        }
    }
    pub fn osc(self: *Recorder, code: isize, payload: []const u8) !void {
        try self.tag('O');
        try self.integer(code);
        try self.bytes(payload);
        if (!self.entered and self.reentry == .osc) {
            self.entered = true;
            try testing.expectEqual(.osc_string, self.parser.?.state);
            try testing.expectEqualSlices(u8, "0;title", self.parser.?.osc_buffer.items);
            self.parser.?.reset();
            try self.parser.?.feed("\x1b]1;nested\x07\x1b[31;", self);
            try testing.expectEqualSlices(u8, "title", payload);
        }
    }
    pub fn dcsHook(self: *Recorder, final: u8, params: []const isize, collect: []const u8) !void {
        try self.tag('H');
        try self.tag(final);
        try self.parameters(params);
        try self.bytes(collect);
        if (!self.entered and self.reentry == .hook) {
            self.entered = true;
            try testing.expectEqual(.dcs_intermediate, self.parser.?.state);
            self.parser.?.reset();
            try self.parser.?.feed("\x1b[32m\x1b[", self);
            try testing.expectEqualSlices(isize, &.{ 1, 2 }, params);
            try testing.expectEqualSlices(u8, "$", collect);
        }
    }
    pub fn dcsPut(self: *Recorder, payload: []const u8) !void {
        try self.tag('D');
        try self.bytes(payload);
        if (!self.entered and self.reentry == .put) {
            self.entered = true;
            try testing.expectEqual(.dcs_passthrough, self.parser.?.state);
            try testing.expectEqualSlices(u8, "abc", self.parser.?.dcs_buffer.items);
            self.parser.?.reset();
            try self.parser.?.feed("\x1bPqnew\x1b\\\x1b[", self);
            try testing.expectEqualSlices(u8, "abc", payload);
        }
    }
    pub fn dcsUnhook(self: *Recorder) !void {
        try self.tag('U');
        if (!self.entered and self.reentry == .unhook) {
            self.entered = true;
            try testing.expectEqual(.dcs_passthrough, self.parser.?.state);
            self.parser.?.reset();
            try self.parser.?.feed("\x1b[32;", self);
        }
    }
    pub fn apc(self: *Recorder, payload: []const u8) !void {
        try self.tag('A');
        try self.bytes(payload);
        if (!self.entered and self.reentry == .apc) {
            self.entered = true;
            try testing.expectEqual(.ground, self.parser.?.state);
            try testing.expectEqual(@as(usize, 0), self.parser.?.apc_buffer.items.len);
            try self.parser.?.feed("\x1b_fresh\x1b\\\x1b[31;", self);
            try testing.expectEqualSlices(u8, "image", payload);
        }
    }
};

fn expectSame(a: *const Recorder, b: *const Recorder) !void {
    try testing.expectEqualSlices(u8, a.log.items, b.log.items);
}

test "UTF-8 scalar boundaries, malformed tails, and every split" {
    const leads = [_]u8{ 0xc2, 0xc3, 0xdf, 0xe0, 0xe1, 0xed, 0xef, 0xf0, 0xf1, 0xf4 };
    for (leads) |lead| {
        const count: usize = if (lead < 0xe0) 2 else if (lead < 0xf0) 3 else 4;
        for (0x20..256) |second| {
            var bytes: [4]u8 = .{ lead, @intCast(second), 0x80, 0x80 };
            const scalar: u32 = std.unicode.utf8Decode(bytes[0..count]) catch lead;
            for (0..count + 1) |cut| {
                var parser = try Parser.init(testing.allocator);
                defer parser.deinit();
                var actual: Recorder = .{};
                defer actual.deinit();
                var expected: Recorder = .{};
                defer expected.deinit();
                try parser.feed(bytes[0..cut], &actual);
                try parser.feed(bytes[cut..count], &actual);
                try parser.feed("|", &actual);
                try expected.printScalar(scalar);
                try expected.printScalar('|');
                try expectSame(&actual, &expected);
                try testing.expectEqual(.ground, parser.state);
            }
        }
    }
}

test "C0 executes without consuming partial UTF-8 and ESC cancels assembly" {
    const scalars = [_][]const u8{ "\xc2\xa2", "\xe2\x82\xac", "\xf0\x9f\x9a\x80" };
    for (scalars) |bytes| {
        for (0..32) |control| {
            if (control == 0x1b) continue;
            for (1..bytes.len) |cut| {
                var parser = try Parser.init(testing.allocator);
                defer parser.deinit();
                var actual: Recorder = .{};
                defer actual.deinit();
                var expected: Recorder = .{};
                defer expected.deinit();
                try parser.feed(bytes[0..cut], &actual);
                try parser.feed(&.{@intCast(control)}, &actual);
                try parser.feed(bytes[cut..], &actual);
                try expected.execute(@intCast(control));
                try expected.printScalar(try std.unicode.utf8Decode(bytes));
                try expectSame(&actual, &expected);
            }
        }
    }
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\xf0\x9f\x1b[31m\x92\xbbX", &actual);
    try expected.csi('m', &.{31}, "");
    try expected.printScalar(0xbb);
    try expected.printScalar('X');
    try expectSame(&actual, &expected);
}

test "raw C1 is inert in ground, Latin-1 junk prints, and encoded C1 prints" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    for (0x80..0xa0) |b| try parser.feed(&.{@intCast(b)}, &actual);
    try parser.feed("\xc0\xc1\xf5\xff\x7f\xc2\x80", &actual);
    for ([_]u32{ 0xc0, 0xc1, 0xf5, 0xff, 0x7f, 0x80 }) |scalar| try expected.printScalar(scalar);
    try expectSame(&actual, &expected);
}

test "CSI keeps entry colon distinct, flat sentinels, empty parameters, and clamps" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b[m\x1b[;31;;m\x1b[:3m\x1b[4:3;38:2::1:2:3m\x1b[?999999999999999999999;m", &actual);
    try expected.csi('m', &.{0}, "");
    try expected.csi('m', &.{ 0, 31, 0, 0 }, "");
    try expected.csi('m', &.{3}, ":");
    try expected.csi('m', &.{ 4, -1, 3, 38, -1, 2, -1, 0, -1, 1, -1, 2, -1, 3 }, "");
    try expected.csi('m', &.{ 65535, 0 }, "?");
    try expectSame(&actual, &expected);
}

test "CSI bounds preserve overflow digits and the final colon pair" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b[", &actual);
    try parser.feed(";" ** 300 ++ "27m", &actual);
    var values: [256]isize = @splat(0);
    values[255] = 27;
    try expected.csi('m', &values, "");
    try parser.feed("\x1b[" ++ ";" ** 254 ++ ":8;9m", &actual);
    var colon_values: [257]isize = @splat(0);
    colon_values[255] = -1;
    colon_values[256] = 89;
    try expected.csi('m', &colon_values, "");
    try parser.feed("\x1b[?1" ++ " " ** 100 ++ "m", &actual);
    try expected.csi('m', &.{1}, "?" ++ " " ** 15);
    try expectSame(&actual, &expected);
}

test "ESC and DCS retain current uncapped parameter and intermediate acceptance" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b" ++ " " ** 300 ++ "Q", &actual);
    try expected.esc('Q', " " ** 300);
    try parser.feed("\x1bP" ++ ";" ** 300 ++ " " ** 300 ++ "qabc\x1b\\", &actual);
    try expected.dcsHook('q', &(@as([301]isize, @splat(0))), " " ** 300);
    try expected.dcsPut("abc");
    try expected.dcsUnhook();
    try expectSame(&actual, &expected);
}

test "OSC selector parsing, embedded controls, aborts and split terminators" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b]0;title\x1b", &actual);
    try testing.expectEqual(@as(usize, 0), actual.log.items.len);
    try parser.feed("\\\x1b]12payload\x07\x1b];empty selector\x07\x1b]bad\x07", &actual);
    try expected.osc(0, "title");
    try expected.osc(12, "payload");
    try expected.osc(0, "empty selector");
    try expected.osc(-1, "bad");
    try parser.feed("\x1b]999999999999999999999999;\x00\x9c\x07\x1b]ignored\x18\x1b]ignored\x1b[31m", &actual);
    try expected.osc(0x10ffff, "\x00\x9c");
    try expected.csi('m', &.{31}, "");
    try expectSame(&actual, &expected);
}

test "OSC and APC truncate payloads at their actual byte cap" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    const bytes = try testing.allocator.alloc(u8, native.max_string_payload + 17);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    try parser.feed("\x1b]0;", &actual);
    try parser.feed(bytes, &actual);
    try testing.expectEqual(native.max_string_payload, parser.osc_buffer.items.len);
    try parser.feed("\x07\x1b_", &actual);
    try parser.feed(bytes, &actual);
    try testing.expectEqual(native.max_string_payload, parser.apc_buffer.items.len);
    try parser.feed("\x1b\\", &actual);
    try expected.osc(0, bytes[0 .. native.max_string_payload - 2]);
    try expected.apc(bytes[0..native.max_string_payload]);
    try expected.esc('\\', "");
    try expectSame(&actual, &expected);
}

test "DCS put boundaries preserve escapes, ignored entry controls, and cancellation" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1bP\x071;2$q" ++ "x" ** 4095 ++ "\x1b", &actual);
    try expected.dcsHook('q', &.{ 1, 2 }, "$");
    try expectSame(&actual, &expected);
    try parser.feed("Qtail\x18Z\x1bP:ignored\x1b\\!", &actual);
    try expected.dcsPut("x" ** 4095 ++ "\x1bQ");
    try expected.dcsPut("tail");
    try expected.dcsUnhook();
    try expected.printScalar('Z');
    try expected.printScalar('!');
    try expectSame(&actual, &expected);
    try testing.expectEqual(.ground, parser.state);
}

test "APC delivers at ESC, aborts on CAN and C1, and accepts UTF-8 payload bytes" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b_image\xc2\xa2\x1b", &actual);
    try expected.apc("image\xc2\xa2");
    try expectSame(&actual, &expected);
    try testing.expectEqual(.escape, parser.state);
    try parser.feed("\\\x1b_aborted\x18\x1b_aborted\x9b31m\x1b_new\x1b[32m", &actual);
    try expected.esc('\\', "");
    try expected.csi('m', &.{31}, "");
    try expected.apc("new");
    try expected.csi('m', &.{32}, "");
    try expectSame(&actual, &expected);
}

test "C1 diversion and high-byte handling differ across sequence states" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{};
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b[?7\x9b31m\x1b[7 \x9b32m\x1bXignored\xa1\x9d0;title\x07\x1b \x9b", &actual);
    try expected.csi('m', &.{31}, "");
    try expected.printASCII("32m");
    try expected.osc(0, "title");
    try expected.esc(0x9b, " ");
    try expectSame(&actual, &expected);
}

test "reset cancels assembly and sequences while retaining exact callback ordering" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{ .parser = &parser, .reentry = .control_reset };
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\xe2\x07\x82\xac", &actual);
    try expected.execute(7);
    try expected.printScalar(0xac);
    try parser.feed("\xed\xa0", &actual);
    parser.reset();
    try parser.feed("A", &actual);
    try expected.printScalar('A');
    try expectSame(&actual, &expected);
}

test "UTF-8 callbacks can establish partial Unicode or escape state" {
    for ([_]bool{ false, true }) |contiguous| {
        var parser = try Parser.init(testing.allocator);
        defer parser.deinit();
        parser.decodes_contiguous_utf8 = contiguous;
        var actual: Recorder = .{ .parser = &parser, .reentry = .scalar_partial };
        defer actual.deinit();
        var expected: Recorder = .{};
        defer expected.deinit();
        try parser.feed("\xe2\x82\xac\x9a\x80", &actual);
        try expected.printScalar(0x20ac);
        try expected.printScalar(0x1f680);
        actual.reentry = .scalar_escape;
        actual.entered = false;
        try parser.feed("\xe2\x82\xac1mZ", &actual);
        try expected.printScalar(0x20ac);
        try expected.csi('m', &.{31}, "");
        try expected.printScalar('Z');
        try expectSame(&actual, &expected);
    }
}

test "CSI and ESC callbacks retain their arguments through nested feed" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{ .parser = &parser, .reentry = .csi };
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b[?31;1m0mZ", &actual);
    try expected.csi('m', &.{ 31, 1 }, "?");
    try expected.csi('m', &.{ 32, 44 }, "");
    try expected.printScalar('R');
    try expected.csi('m', &.{0}, "");
    try expected.printScalar('Z');
    actual.reentry = .esc;
    actual.entered = false;
    try parser.feed("\x1b #Q4m", &actual);
    try expected.esc('Q', " #");
    try expected.csi('m', &.{ 31, 4 }, "");
    try expectSame(&actual, &expected);
}

test "OSC callback sees old state and outer cleanup replaces nested partial state" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{ .parser = &parser, .reentry = .osc };
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b]0;title\x07m", &actual);
    try expected.osc(0, "title");
    try expected.osc(1, "nested");
    try expected.printScalar('m');
    try expectSame(&actual, &expected);
    try testing.expectEqual(.ground, parser.state);
}

test "DCS hook, put and unhook preserve legacy publication and snapshot lifetimes" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{ .parser = &parser, .reentry = .hook };
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1bP1;2$qabc\x1b\\Z", &actual);
    try expected.dcsHook('q', &.{ 1, 2 }, "$");
    try expected.csi('m', &.{32}, "");
    try expected.dcsPut("abc");
    try expected.dcsUnhook();
    try expected.printScalar('Z');
    actual.reentry = .put;
    actual.entered = false;
    try parser.feed("\x1bPqabc\x1b\\m", &actual);
    try expected.dcsHook('q', &.{0}, "");
    try expected.dcsPut("abc");
    try expected.dcsHook('q', &.{0}, "");
    try expected.dcsPut("new");
    try expected.dcsUnhook();
    try expected.dcsUnhook();
    try expected.printScalar('m');
    actual.reentry = .unhook;
    actual.entered = false;
    try parser.feed("\x1bPq\x1b\\m", &actual);
    try expected.dcsHook('q', &.{0}, "");
    try expected.dcsUnhook();
    try expected.printScalar('m');
    try expectSame(&actual, &expected);
}

test "APC clears before callback and publishes escape after nested feed" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var actual: Recorder = .{ .parser = &parser, .reentry = .apc };
    defer actual.deinit();
    var expected: Recorder = .{};
    defer expected.deinit();
    try parser.feed("\x1b_image\x1bm", &actual);
    try expected.apc("image");
    try expected.apc("fresh");
    try expected.esc('\\', "");
    try expected.esc('m', "");
    try expectSame(&actual, &expected);
}

test "every byte in every parser state has identical events and final state across chunks" {
    const prefixes = [_][]const u8{
        "", "\x1b", "\x1b ", "\x1b[", "\x1b[31;", "\x1b[31 ", "\x1b[31?",
        "\x1b]0;title", "\x1b]0;title\x1b", "\x1bP", "\x1bP1;", "\x1bP1$",
        "\x1bPqdata", "\x1bPqdata\x1b", "\x1bP:", "\x1bP:\x1b", "\x1bX",
        "\x1b_image", "\xc2", "\xe2\x82", "\xf0\x9f\x9a",
    };
    for (prefixes) |prefix| {
        for (0..256) |byte| {
            var payload: std.ArrayList(u8) = .empty;
            defer payload.deinit(testing.allocator);
            try payload.appendSlice(testing.allocator, prefix);
            try payload.append(testing.allocator, @intCast(byte));
            try payload.appendSlice(testing.allocator, "31m\x1b\\\x18\x1b[0m!");
            var reference = try Parser.init(testing.allocator);
            defer reference.deinit();
            reference.coalesces_printable_ascii = false;
            reference.decodes_contiguous_utf8 = false;
            var expected: Recorder = .{};
            defer expected.deinit();
            try reference.feed(payload.items, &expected);
            for ([_]usize{ 1, 2, 3, 7, 1024 }) |chunk| {
                var parser = try Parser.init(testing.allocator);
                defer parser.deinit();
                var actual: Recorder = .{};
                defer actual.deinit();
                var index: usize = 0;
                while (index < payload.items.len) : (index += chunk) {
                    try parser.feed(payload.items[index..@min(index + chunk, payload.items.len)], &actual);
                }
                try expectSame(&actual, &expected);
                try testing.expectEqual(reference.state, parser.state);
            }
        }
    }
}

const BatchRecorder = struct {
    single: usize = 0,
    crlf: usize = 0,
    lines: usize = 0,
    scalars: usize = 0,
    controls: usize = 0,
    pub fn printScalar(self: *BatchRecorder, _: u32) void { self.scalars += 1; }
    pub fn printASCII(self: *BatchRecorder, bytes: []const u8) void { self.single += bytes.len; }
    pub fn printASCIIAndCRLF(self: *BatchRecorder, bytes: []const u8) void { self.crlf += bytes.len; }
    pub fn printASCIILines(self: *BatchRecorder, bytes: []const u8) void { self.lines += bytes.len; }
    pub fn execute(self: *BatchRecorder, _: u8) void { self.controls += 1; }
    pub fn csi(_: *BatchRecorder, _: u8, _: []const isize, _: []const u8) void {}
    pub fn esc(_: *BatchRecorder, _: u8, _: []const u8) void {}
    pub fn osc(_: *BatchRecorder, _: isize, _: []const u8) void {}
    pub fn dcsHook(_: *BatchRecorder, _: u8, _: []const isize, _: []const u8) void {}
    pub fn dcsPut(_: *BatchRecorder, _: []const u8) void {}
    pub fn dcsUnhook(_: *BatchRecorder) void {}
    pub fn apc(_: *BatchRecorder, _: []const u8) void {}
};

test "optional ASCII batching callbacks and void sinks preserve record boundaries" {
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var sink: BatchRecorder = .{};
    try parser.feed("abc\r\ndef\r\nX\nY\r\n\r\nZ\x7f", &sink);
    try testing.expectEqual(@as(usize, 10), sink.lines);
    try testing.expectEqual(@as(usize, 1), sink.crlf);
    try testing.expectEqual(@as(usize, 2), sink.single);
    try testing.expectEqual(@as(usize, 1), sink.scalars);
    try testing.expectEqual(@as(usize, 3), sink.controls);
}

fn allocationScenario(allocator: Allocator) !void {
    var parser = try Parser.init(allocator);
    defer parser.deinit();
    var sink: Recorder = .{ .allocator = allocator };
    defer sink.deinit();
    try parser.feed("\x1b[4:3;38:2::1:2:3m\x1b]0;title\x07\x1b_image\x1b\\", &sink);
    try parser.feed("\x1b" ++ " " ** 300 ++ "Q\x1bP" ++ ";" ** 300 ++ " " ** 300 ++ "qpayload\x1b\\", &sink);
}

test "all parser and sink allocation failures propagate without leaks" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "sink errors retain their original identity" {
    const Failing = struct {
        pub fn printScalar(_: *@This(), _: u32) error{InvalidInput}!void { return error.InvalidInput; }
        pub fn printASCII(_: *@This(), _: []const u8) error{InvalidInput}!void { return error.InvalidInput; }
        pub fn execute(_: *@This(), _: u8) void {}
        pub fn csi(_: *@This(), _: u8, _: []const isize, _: []const u8) void {}
        pub fn esc(_: *@This(), _: u8, _: []const u8) void {}
        pub fn osc(_: *@This(), _: isize, _: []const u8) void {}
        pub fn dcsHook(_: *@This(), _: u8, _: []const isize, _: []const u8) void {}
        pub fn dcsPut(_: *@This(), _: []const u8) void {}
        pub fn dcsUnhook(_: *@This()) void {}
        pub fn apc(_: *@This(), _: []const u8) void {}
    };
    var parser = try Parser.init(testing.allocator);
    defer parser.deinit();
    var sink: Failing = .{};
    try testing.expectError(error.InvalidInput, parser.feed("X", &sink));
}
