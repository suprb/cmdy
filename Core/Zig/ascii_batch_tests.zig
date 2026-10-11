//! Isolated prototype differential tests against the literal previous byte loop.
const std = @import("std");
const testing = std.testing;
const Terminal = @import("terminal.zig").Terminal;
const Line = @import("line.zig").Line;
const printing = @import("printing.zig");
const graphics = @import("graphics.zig");

test "printable ASCII metadata agrees with generated Unicode and emoji tables" {
    const Check = struct {
        fn tableMetadata(scalar: u32) printing.ScalarPrintMetadata {
            const width = @import("unicode.zig").width(scalar);
            if (width < 0) return .{ .width = width, .role = .ordinary, .isEmojiComponent = false };
            const role = printing.clusterRole(scalar, width);
            return .{ .width = width, .role = role, .isEmojiComponent = role == .ordinary and @import("emoji.zig").isZWJComponent(scalar) };
        }
    };
    // Exhaust every printable byte, both range boundaries, controls and the
    // direct byte API's high-byte values. The oracle bypasses the fast return.
    for (0..256) |value| {
        const scalar: u32 = @intCast(value);
        try testing.expectEqualDeep(Check.tableMetadata(scalar), printing.scalarPrintMetadata(scalar));
    }
    // Keep the Unicode follower/emoji roles and invalid-scalar fallbacks in
    // the same metadata contract as ASCII, including keycap components.
    for ([_]u32{ 0x301, 0x200d, 0x20e3, 0x754c, 0xd7ff, 0xd800, 0xdfff, 0xe000, 0xfe0e, 0xfe0f, 0x1f1e6, 0x1f469, 0xe0100, 0xe01ef, 0x10ffff, 0x110000, 0xffffffff }) |scalar|
        try testing.expectEqualDeep(Check.tableMetadata(scalar), printing.scalarPrintMetadata(scalar));
}

fn scalarASCII(t: *Terminal, bytes: []const u8) !void {
    for (bytes) |byte| try t.printScalar(byte);
    t.markDirty(t.buffer().y_base + t.buffer().y);
}

fn follow(t: *Terminal, index: usize) !void {
    switch (index % 6) {
        0 => try t.printScalar(0x301),
        1 => {
            try t.printScalar(0xfe0f);
            try t.printScalar(0x20e3);
        },
        2 => {
            try t.printScalar(0x200d);
            try t.printScalar(0x1f4bb);
        },
        3 => {
            try t.printScalar(0x754c);
            try t.printScalar(0xfe0e);
        },
        4 => {
            try t.feed("\x1b[D");
            try t.printScalar(0x301);
        },
        else => {
            try t.feed("\x1b[1;1H");
            try t.printScalar('Q');
        },
    }
}

fn equivalent(actual: *Terminal, expected: *Terminal) !void {
    try testing.expectEqual(expected.is_alternate, actual.is_alternate);
    try testing.expectEqualDeep(expected.dirty, actual.dirty);
    try testing.expectEqualDeep(expected.pen, actual.pen);
    try testing.expectEqual(expected.active_link_id, actual.active_link_id);
    inline for (.{ "normal", "alternate" }) |field| {
        const a = &@field(actual, field);
        const e = &@field(expected, field);
        inline for (.{ "cols", "rows", "x", "y", "y_base", "y_disp", "dropped_lines", "scroll_top", "scroll_bottom", "margin_left", "margin_right", "wrap_pending" }) |name|
            try testing.expectEqual(@field(e, name), @field(a, name));
        try testing.expectEqual(e.lineCount(), a.lineCount());
        var row: isize = 0;
        while (row < a.lineCount()) : (row += 1) {
            const al = a.line(row).?;
            const el = e.line(row).?;
            try testing.expectEqual(el.is_wrapped, al.is_wrapped);
            try testing.expectEqual(el.render_mode, al.render_mode);
            try testing.expectEqual(el.wrap_style, al.wrap_style);
            try testing.expectEqual(el.images == null, al.images == null);
            if (el.images) |images| try testing.expectEqual(images.items.len, al.images.?.items.len);
            var col: isize = 0;
            while (col < a.cols) : (col += 1) try testing.expect(printing.cellEqual(el.get(col), al.get(col)));
        }
    }
    const a = &actual.print_state;
    const e = &expected.print_state;
    inline for (.{ "lastPrintedScalar", "lastWrite", "selectorExpansionSettledPhysicalPending", "normalBackwardColumnAttachmentWitness", "alternateBackwardColumnAttachmentWitness", "reverseIndexBufferDepartureOwner", "bufferActivationSerial", "noWrapParkedAfterPrint", "pendingCursorUpMoved", "presentationSelectorAuthority", "selectorOwnerAdvancedByRelativeMotion", "selectorRelocationTracksWidthChange", "lastPrintWrappedFromRightOfMargin", "lastPrintAdvancedToFreshRow", "lastPrintAdvancedFromCurrentPendingOwner" }) |name|
        try testing.expectEqualDeep(@field(e, name), @field(a, name));
    try testing.expectEqual(e.pendingWrapOwnerWitness == null, a.pendingWrapOwnerWitness == null);
    if (a.pendingWrapOwnerWitness) |owner| {
        const expected_owner = e.pendingWrapOwnerWitness.?;
        try testing.expectEqual(expected_owner.leadColumn, owner.leadColumn);
        try testing.expect(printing.cellEqual(expected_owner.cell.value(), owner.cell.value()));
    }
    try testing.expectEqual(e.lastWriteDisplacedCell == null, a.lastWriteDisplacedCell == null);
    if (a.lastWriteDisplacedCell) |cell| {
        const expected_cell = e.lastWriteDisplacedCell.?;
        try testing.expectEqual(expected_cell.row, cell.row);
        try testing.expectEqual(expected_cell.column, cell.column);
        try testing.expect(printing.cellEqual(expected_cell.cell.value(), cell.cell.value()));
    }
}

test "ASCII prototype all bytes preserve literal scalar semantics and followers" {
    for (0..256) |byte| for ([_]isize{ 1, 3, 8 }) |cols| {
        var actual = try Terminal.init(testing.allocator, cols, 3, 7);
        defer actual.deinit();
        var expected = try Terminal.init(testing.allocator, cols, 3, 7);
        defer expected.deinit();
        const bytes = [_]u8{ 'a', @intCast(byte), '#', '0', '*', 'Z' };
        try actual.printASCII(&bytes);
        try scalarASCII(&expected, &bytes);
        try equivalent(&actual, &expected);
        try follow(&actual, byte);
        try follow(&expected, byte);
        try equivalent(&actual, &expected);
    };
    var actual = try Terminal.init(testing.allocator, 20, 3, 7);
    defer actual.deinit();
    var expected = try Terminal.init(testing.allocator, 20, 3, 7);
    defer expected.deinit();
    const encoded = "A\xc3\xa9\xf0\x9f\x98\x80Z\x00\xff";
    try actual.printASCII(encoded);
    try scalarASCII(&expected, encoded);
    try equivalent(&actual, &expected);
    try testing.expectEqual(@as(u32, 0xc3), actual.buffer().liveLine(0).cell(1).scalar);
}

test "ASCII prototype every printable boundary and terminal mode matches scalar path" {
    var ascii: [95]u8 = undefined;
    for (&ascii, 0..) |*byte, index| byte.* = @intCast(index + 0x20);
    for ([_]isize{ 1, 2, 7, 65, 80, 132 }) |cols| for (0..8) |mode| for (0..5) |start_case| {
        var actual = try Terminal.init(testing.allocator, cols, 3, 7);
        defer actual.deinit();
        var expected = try Terminal.init(testing.allocator, cols, 3, 7);
        defer expected.deinit();
        for ([_]*Terminal{ &actual, &expected }) |t| {
            try t.printScalar(0x754c);
            try t.printScalar('e');
            try t.printScalar(0x301);
            try t.printScalar(0x754c);
            t.auto_wrap = mode != 1;
            t.insert_mode = mode == 2;
            t.margin_mode = mode == 3 or mode == 4;
            t.origin_mode = mode == 4;
            if (mode == 5) t.is_alternate = true;
            const b = t.buffer();
            b.margin_left = if (cols > 3) 1 else 0;
            b.margin_right = if (cols > 3) cols - 2 else cols - 1;
            b.x = switch (start_case) {
                0 => -1,
                1 => 0,
                2 => cols - 1,
                3 => cols,
                else => cols + 1,
            };
            b.y = if (mode == 6) 0 else 2;
            b.wrap_pending = start_case >= 3;
            if (mode == 7) {
                b.liveLine(b.y).render_mode = .double_width;
                b.scroll_top = 1;
                b.scroll_bottom = 2;
            }
            t.pen.fg = 0x01000002;
            t.pen.bg = 0x01000004;
            t.pen.style = 7;
            t.active_link_id = 42;
            t.dirty = null;
        }
        try actual.printASCII(&ascii);
        try scalarASCII(&expected, &ascii);
        try equivalent(&actual, &expected);
        try follow(&actual, mode);
        try follow(&expected, mode);
        try equivalent(&actual, &expected);
    };
}

test "ASCII prototype contains a row transaction and keeps published snapshot immutable" {
    var t = try Terminal.init(testing.allocator, 80, 3, 7);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try line.set(62, .{ .cell = .{ .scalar = 'e' }, .extras = &.{ 0x301, 0xfe0f } });
    const snapshot = try line.cloneSnapshot();
    defer snapshot.release();
    const old_snapshot_version = snapshot.version();
    const witness = try Line.create(testing.allocator, 1, .{});
    const next_version = witness.version() + 1;
    witness.release();
    try t.printASCII("A" ** 63);
    try testing.expectEqual(next_version, line.version());
    try testing.expectEqual(old_snapshot_version, snapshot.version());
    try testing.expectEqual(@as(u32, 'e'), snapshot.cell(62).scalar);
    try testing.expectEqualSlices(u32, &.{ 0x301, 0xfe0f }, snapshot.get(62).extras.?);
    try testing.expectEqualSlices(u32, &.{ 0x301, 0xfe0f }, t.print_state.lastWriteDisplacedCell.?.cell.extras.?);
    try testing.expectEqual(@as(isize, 63), t.buffer().x);
}

test "ASCII prototype mutable host callback bytes are never decoded as UTF8" {
    const Reentry = struct {
        terminal: *Terminal,
        bytes: *[7]u8,
        count: usize = 0,
        fn released(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            self.terminal.is_alternate = true;
            self.terminal.pen.fg = 0x01000003;
            self.terminal.active_link_id = 7;
            self.terminal.parser.state = .csi_param;
            self.bytes[1] = 0xc3;
            self.bytes[2] = 0xa9;
        }
        fn install(self: *@This()) !void {
            const t = self.terminal;
            t.buffer().x = 4;
            t.buffer().y = 1;
            t.buffer().wrap_pending = true;
            const payload = try graphics.Payload.createHostCopy(testing.allocator, .png, "host", 1, 1);
            defer payload.release();
            payload.host_owner = self;
            payload.host_release = released;
            const image = try graphics.LineImage.init(payload, 0);
            defer image.deinit();
            try t.buffer().liveLine(0).appendImage(image);
        }
    };
    var actual = try Terminal.init(testing.allocator, 4, 2, 0);
    defer actual.deinit();
    var expected = try Terminal.init(testing.allocator, 4, 2, 0);
    defer expected.deinit();
    var actual_bytes: [7]u8 = "ABCDEFG".*;
    var expected_bytes: [7]u8 = actual_bytes;
    var ar = Reentry{ .terminal = &actual, .bytes = &actual_bytes };
    var er = Reentry{ .terminal = &expected, .bytes = &expected_bytes };
    try ar.install();
    try er.install();
    try actual.printASCII(&actual_bytes);
    try scalarASCII(&expected, &expected_bytes);
    try testing.expectEqual(@as(usize, 1), ar.count);
    try testing.expectEqual(er.count, ar.count);
    try equivalent(&actual, &expected);
}

test "ASCII prototype dirty empty call and repeated native chunks preserve state" {
    var actual = try Terminal.init(testing.allocator, 80, 3, 7);
    defer actual.deinit();
    var expected = try Terminal.init(testing.allocator, 80, 3, 7);
    defer expected.deinit();
    for (0..50) |index| {
        const bytes = if (index % 5 == 0) "" else "CDEFG1234";
        actual.dirty = null;
        expected.dirty = null;
        try actual.printASCII(bytes);
        try scalarASCII(&expected, bytes);
        try equivalent(&actual, &expected);
    }
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    var t = try Terminal.init(allocator, 8, 3, 7);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try line.set(6, .{ .cell = .{ .scalar = 'e' }, .extras = &.{ 0x301, 0xfe0f } });
    const snapshot = try line.cloneSnapshot();
    defer snapshot.release();
    try t.printASCII("abc#*0Z");
    try testing.expectEqualSlices(u32, &.{ 0x301, 0xfe0f }, snapshot.get(6).extras.?);
}

test "ASCII prototype allocation failure preserves snapshot ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationCase, .{});
}

test "ASCII byte transactions preserve deferred blanks, detached publication and gap writes" {
    var actual = try Terminal.init(testing.allocator, 132, 3, 1);
    defer actual.deinit();
    var expected = try Terminal.init(testing.allocator, 132, 3, 1);
    defer expected.deinit();
    const blank = @import("row.zig").Cell{ .bg = 0x01000004, .fg = 0x01000002, .style = 3 };
    for ([_]*Terminal{ &actual, &expected }) |t| {
        try t.printASCII("Z" ** 132);
        t.buffer().x = 0;
        t.buffer().wrap_pending = false;
        printing.invalidateClusterContinuation(t, false);
        try t.buffer().liveLine(0).fillCell(blank, 0, null);
        t.pen.fg = 0x01000003;
        t.active_link_id = 42;
        t.dirty = null;
    }
    const initial = try actual.buffer().liveLine(0).renderSnapshot();
    defer initial.release();
    try actual.printASCII("A" ** 65);
    try scalarASCII(&expected, "A" ** 65);
    try equivalent(&actual, &expected);
    const partial = try actual.buffer().liveLine(0).renderSnapshot();
    defer partial.release();
    const partial_version = partial.version();
    for ([_]*Terminal{ &actual, &expected }) |t| t.buffer().x = 100;
    try actual.printASCII("B" ** 32);
    try scalarASCII(&expected, "B" ** 32);
    try equivalent(&actual, &expected);
    // Cross full-screen recycling with both earlier publications retained.
    try actual.printASCII("C" ** 1500);
    try scalarASCII(&expected, "C" ** 1500);
    try equivalent(&actual, &expected);
    try testing.expectEqual(partial_version, partial.version());
    for (0..132) |column| {
        try testing.expectEqualDeep(blank, initial.cell(@intCast(column)));
        if (column < 65) {
            try testing.expectEqual(@as(u32, 'A'), partial.cell(@intCast(column)).scalar);
            try testing.expectEqual(@as(u16, 42), partial.cell(@intCast(column)).link_id);
        } else try testing.expectEqualDeep(blank, partial.cell(@intCast(column)));
    }
}

fn deferredASCIIAllocationCase(allocator: std.mem.Allocator) !void {
    var t = try Terminal.init(allocator, 132, 3, 0);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try t.printASCII("Z" ** 132);
    const published = try line.renderSnapshot();
    defer published.release();
    const published_version = published.version();
    defer {
        testing.expectEqual(published_version, published.version()) catch @panic("published revision changed");
        for (0..132) |column|
            testing.expectEqual(@as(u32, 'Z'), published.cell(@intCast(column)).scalar) catch @panic("published cell changed");
    }
    t.buffer().x = 0;
    t.buffer().wrap_pending = false;
    printing.invalidateClusterContinuation(&t, false);
    try line.fillCell(.{ .bg = 0x01000004 }, 0, null);
    try t.printASCII("A" ** 65);
    t.buffer().x = 100;
    try t.printASCII("B" ** 32);
}

test "ASCII byte writer allocation failures preserve shared deferred-row publication" {
    try testing.checkAllAllocationFailures(testing.allocator, deferredASCIIAllocationCase, .{});
}

test "ASCII allocator reentry preserves admitted source bytes before displaced extras allocation" {
    const Mutation = struct {
        child: std.mem.Allocator,
        bytes: *[3]u8,
        armed: bool = false,
        changes: usize = 0,
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const result = self.child.rawAlloc(len, alignment, address);
            if (result != null and self.armed and len == @sizeOf(u32)) {
                self.armed = false;
                self.changes += 1;
                self.bytes[1] = '\n';
            }
            return result;
        }
        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.child.rawResize(memory, alignment, len, address);
        }
        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.child.rawRemap(memory, alignment, len, address);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.child.rawFree(memory, alignment, address);
        }
    };
    var bytes: [3]u8 = "ABC".*;
    var mutation = Mutation{ .child = testing.allocator, .bytes = &bytes };
    var t = try Terminal.init(mutation.allocator(), 8, 3, 0);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try line.set(2, .{ .cell = .{ .scalar = 'e' }, .extras = &.{0x301} });
    mutation.armed = true;
    const consumed = try @import("ordinary_printing.zig").printASCII(&t, &bytes);
    try testing.expectEqual(@as(usize, 3), consumed);
    try testing.expectEqual(@as(usize, 1), mutation.changes);
    try testing.expectEqual(@as(u8, '\n'), bytes[1]);
    for ("ABC", 0..) |scalar, column| try testing.expectEqual(@as(u32, scalar), line.cell(@intCast(column)).scalar);
    try testing.expectEqualSlices(u32, &.{0x301}, t.print_state.lastWriteDisplacedCell.?.cell.extras.?);
    try t.printScalar(0x301);
    try testing.expectEqualSlices(u32, &.{0x301}, line.get(2).extras.?);
}
