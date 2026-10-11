//! Contained independent Unicode bases share one native row mutation. The
//! first scalar retains its full insertion/cluster path whenever admission
//! would cross a row, callback, pending owner, or terminal mode boundary.
const std = @import("std");
const printing = @import("printing.zig");
const motion = @import("line_motion.zig");
const parser = @import("parser.zig");
const unicode = @import("unicode.zig");
const Scalar = @import("row.zig").Scalar;

/// A pure query of the invoking parser's current state and delegate identity.
/// It is never retained after print returns, and direct engine calls omit it.
pub const Continuation = struct {
    context: ?*anyopaque = null,
    can_continue: *const fn (?*anyopaque) bool,
    fn permits(self: Continuation) bool {
        return self.can_continue(self.context);
    }
};

pub fn print(t: anytype, bytes: []const u8, first: u32, first_byte_count: usize, continuation: ?Continuation) anyerror!usize {
    return printImpl(t, bytes, first, first_byte_count, continuation, false);
}

/// Direct byte printing must never reinterpret bytes as a UTF-8 sequence,
/// including after a scalar fallback has synchronously reentered the host.
pub fn printASCII(t: anytype, bytes: []const u8) anyerror!usize {
    if (bytes.len == 0) return 0;
    return printImpl(t, bytes, bytes[0], 1, null, true);
}

fn printImpl(t: anytype, bytes: []const u8, first: u32, first_byte_count: usize, continuation: ?Continuation, comptime ascii_bytes: bool) anyerror!usize {
    if (first_byte_count == 0 or first_byte_count > bytes.len or !printing.isValidScalar(first)) return error.InvalidInput;
    const metadata = printing.scalarPrintMetadata(first);
    var includes_first = false;
    if (metadata.permitsOrdinaryUnicodeBatch() and printing.ordinaryPrintModesEnabled(t) and
        printing.reverseWitness(t).* == null and t.print_state.rejectedWidePresentationOwnerWitness == null and
        t.print_state.pendingWrapOwnerWitness == null)
    {
        const current = t.buffer();
        includes_first = current.x >= 0 and current.x < current.cols and current.y >= 0 and current.y < current.rows and
            !current.wrap_pending and metadata.width <= current.cols - current.x and
            (if (continuation) |check| check.permits() else true);
    }
    if (!includes_first) {
        try printing.printScalarWithMetadata(t, first, metadata);
        t.markDirty(t.buffer().y_base + t.buffer().y);
        if (!metadata.permitsOrdinaryUnicodeBatch() or !printing.ordinaryPrintModesEnabled(t) or printing.reverseWitness(t).* != null)
            return first_byte_count;
        // Scalar insertion may release an image, scroll, or reenter another
        // parser. Reacquire every mutable engine fact after that boundary.
        if (continuation) |check| if (!check.permits()) return first_byte_count;
    }
    const b = t.buffer();
    const start = b.x;
    if (start < 0 or start >= b.cols or b.y < 0 or b.y >= b.rows or b.wrap_pending) return first_byte_count;
    const available = b.cols - start;
    // ASCII is width one. Stage its admitted bytes before any allocation can
    // reenter the caller, without expanding or revalidating a Scalar array.
    var storage: [if (ascii_bytes) 0 else 65]Scalar = undefined;
    var ascii_storage: [if (ascii_bytes) 65 else 0]u8 = undefined;
    var source = first_byte_count;
    var count: usize = if (includes_first) 1 else 0;
    var columns: isize = if (includes_first) metadata.width else 0;
    if (includes_first) {
        if (ascii_bytes) ascii_storage[0] = @intCast(first) else storage[0] = .{ .scalar = first, .width = metadata.width };
    }
    const limit: usize = if (includes_first) 65 else 64;
    while (source < bytes.len and count < limit) {
        var scalar: u32 = undefined;
        var byte_count: usize = undefined;
        var width: i8 = undefined;
        const byte = bytes[source];
        if (byte >= 0x20 and byte <= 0x7e) {
            scalar = byte;
            byte_count = 1;
            width = 1;
        } else {
            if (ascii_bytes) break;
            const decoded = parser.contiguousUTF8(bytes[source..]) orelse break;
            width = unicode.width(decoded.scalar);
            // A contained ordinary first base establishes independence;
            // interior emoji bases qualify, while all real followers stop.
            if ((width != 1 and width != 2) or printing.clusterRole(decoded.scalar, width) != .ordinary) break;
            scalar = decoded.scalar;
            byte_count = decoded.count;
        }
        if (columns + width > available) break;
        if (ascii_bytes) ascii_storage[count] = byte else storage[count] = .{ .scalar = scalar, .width = width };
        count += 1;
        columns += width;
        source += byte_count;
    }
    if (count == 0) return first_byte_count;
    const row = b.y_base + b.y;
    const line = b.liveLine(b.y);
    const final: Scalar = if (ascii_bytes) .{ .scalar = ascii_storage[count - 1], .width = 1 } else storage[count - 1];
    const final_column = start + columns - final.width;
    var displaced = try printing.OwnedCell.init(t.allocator, line.get(final_column));
    defer displaced.deinit(t.allocator);
    if (ascii_bytes) {
        try line.writeASCII(ascii_storage[0..count], start, t.penCell(0, 1));
    } else {
        try line.writeOrdinaryUnicode(storage[0..count], start, t.penCell(0, 1), .{ .width = 0, .bg = 0x03000000 });
    }
    const s = &t.print_state;
    if (includes_first) {
        s.selectorExpansionSettledPhysicalPending = null;
        s.pendingCursorUpMoved = false;
        s.noWrapParkedAfterPrint = false;
        s.lastPrintWrappedFromRightOfMargin = false;
        motion.finishPrintReverseIndexOwnerRefresh(t, false, row, final_column);
        printing.backwardWitness(t).* = null;
        s.presentationSelectorAuthority = .available;
        s.selectorOwnerAdvancedByRelativeMotion = false;
        s.selectorRelocationTracksWidthChange = false;
        t.markDirty(row);
    }
    b.x = start + columns;
    b.wrap_pending = b.x == b.cols;
    s.lastWrite = .{ .row = row, .x = final_column, .cols = b.cols, .rows = b.rows };
    s.lastPrintedScalar = final.scalar;
    printing.clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastWriteDisplacedCell = .{ .row = row, .column = final_column, .cols = b.cols, .rows = b.rows, .cell = displaced };
    displaced.extras = null;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    try printing.refreshPendingWrapOwner(t, line, final_column);
    return source;
}

const Terminal = @import("terminal.zig").Terminal;
const testing = std.testing;

fn scalarText(t: *Terminal, bytes: []const u8) !void {
    var index: usize = 0;
    while (index < bytes.len) {
        if (bytes[index] < 0x80) {
            try t.printScalar(bytes[index]);
            index += 1;
        } else {
            const decoded = parser.contiguousUTF8(bytes[index..]) orelse return error.InvalidInput;
            try t.printScalar(decoded.scalar);
            index += decoded.count;
        }
    }
}

fn equivalent(actual: *Terminal, expected: *Terminal) !void {
    try testing.expectEqual(expected.is_alternate, actual.is_alternate);
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
            var col: isize = 0;
            while (col < a.cols) : (col += 1) try testing.expect(printing.cellEqual(el.get(col), al.get(col)));
        }
    }
    const a = &actual.print_state;
    const e = &expected.print_state;
    inline for (.{ "lastPrintedScalar", "lastWrite", "noWrapParkedAfterPrint", "pendingCursorUpMoved", "presentationSelectorAuthority", "selectorOwnerAdvancedByRelativeMotion", "selectorRelocationTracksWidthChange", "lastPrintWrappedFromRightOfMargin", "lastPrintAdvancedToFreshRow", "lastPrintAdvancedFromCurrentPendingOwner" }) |name|
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

test "first scalar admission and interior emoji preserve exact consumed bytes" {
    const cases = .{
        .{ "α", true },        .{ "界", true },        .{ "é", true },      .{ "#", true },        .{ "*", true },         .{ "0", true },
        .{ "❤", false },      .{ "👩", false },      .{ "🇺", false },   .{ "\u{301}", false }, .{ "\u{200d}", false }, .{ "\u{fe0e}", false },
        .{ "\u{fe0f}", false }, .{ "\u{e0100}", false }, .{ "\u{85}", false },
    };
    inline for (cases) |case| {
        var actual = try Terminal.init(testing.allocator, 20, 3, 7);
        defer actual.deinit();
        var expected = try Terminal.init(testing.allocator, 20, 3, 7);
        defer expected.deinit();
        const first: u32 = if (case[0][0] < 0x80) case[0][0] else parser.contiguousUTF8(case[0]).?.scalar;
        const bytes = case[0] ++ "βγ";
        const count = try print(&actual, bytes, first, case[0].len, null);
        try testing.expectEqual(if (case[1]) bytes.len else case[0].len, count);
        try scalarText(&expected, bytes[0..count]);
        try equivalent(&actual, &expected);
        inline for (.{ "\u{fe0f}", "\u{200d}💻", "\u{301}Z" }) |suffix| {
            try scalarText(&actual, suffix);
            try scalarText(&expected, suffix);
            try equivalent(&actual, &expected);
        }
    }
    var t = try Terminal.init(testing.allocator, 20, 3, 7);
    defer t.deinit();
    const mixed = "α👩❤β";
    try testing.expectEqual(mixed.len, try print(&t, mixed, 0x3b1, 2, null));
}

test "contained batch writes once and snapshots preserve displaced extras" {
    var t = try Terminal.init(testing.allocator, 8, 3, 7);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try line.set(4, .{ .cell = .{ .scalar = 101 }, .extras = &.{0x301} });
    const snapshot = try line.cloneSnapshot();
    defer snapshot.release();
    const stamp_witness = try @import("line.zig").Line.create(testing.allocator, 1, .{});
    const next = stamp_witness.version() + 1;
    stamp_witness.release();
    const bytes = "α👩❤β";
    try testing.expectEqual(bytes.len, try print(&t, bytes, 0x3b1, 2, null));
    try testing.expectEqual(next, line.version());
    try testing.expectEqualSlices(u32, &.{0x301}, snapshot.get(4).extras.?);
    try testing.expectEqualSlices(u32, &.{0x301}, t.print_state.lastWriteDisplacedCell.?.cell.extras.?);
    try testing.expectEqual(@as(isize, 4), t.print_state.lastWrite.x);
    try testing.expectEqual(@as(isize, 5), t.buffer().x);
}

test "capacity, row transitions, wide overwrites and followers match scalar insertion" {
    const texts = [_][]const u8{ "α❤\u{fe0f}\u{fe0e}", "α👩🏽\u{200d}💻", "α🏳\u{fe0f}\u{200d}🌈", "α#\u{fe0f}\u{20e3}", "αβ🇺🇸", "α❤\u{301}\u{fe0f}", "α👩\u{200d}\u{200d}💻", "α👩\u{e0067}\u{e007f}" };
    for ([_]isize{ 1, 2, 3, 7, 20, 66 }) |cols| for (texts) |bytes| {
        var start: isize = 0;
        while (start <= cols) : (start += @max(1, @divTrunc(cols, 3))) {
            var actual = try Terminal.init(testing.allocator, cols, 3, 7);
            defer actual.deinit();
            var expected = try Terminal.init(testing.allocator, cols, 3, 7);
            defer expected.deinit();
            for ([_]*Terminal{ &actual, &expected }) |t| {
                try scalarText(t, "界界e\u{301}界");
                t.buffer().x = start;
                t.buffer().wrap_pending = start == cols;
                t.buffer().y = 2;
                t.pen.bg = 0x01000004;
            }
            const consumed = try print(&actual, bytes, 0x3b1, 2, null);
            try scalarText(&expected, bytes[0..consumed]);
            try equivalent(&actual, &expected);
            try scalarText(&actual, bytes[consumed..]);
            try scalarText(&expected, bytes[consumed..]);
            try equivalent(&actual, &expected);
        }
    };
    var t = try Terminal.init(testing.allocator, 200, 3, 7);
    defer t.deinit();
    const bytes = "α" ++ "β" ** 128;
    try testing.expectEqual(@as(usize, 130), try print(&t, bytes, 0x3b1, 2, null));
    t.buffer().x = 200;
    t.buffer().wrap_pending = true;
    try testing.expectEqual(@as(usize, 130), try print(&t, bytes, 0x3b1, 2, null));
}

test "continuation is checked after a first scalar fallback and modes remain scalar" {
    const Check = struct {
        calls: usize = 0,
        fn allowed(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return false;
        }
    };
    var t = try Terminal.init(testing.allocator, 20, 3, 7);
    defer t.deinit();
    var check = Check{};
    try testing.expectEqual(@as(usize, 2), try print(&t, "αβγ", 0x3b1, 2, .{ .context = &check, .can_continue = Check.allowed }));
    try testing.expectEqual(@as(usize, 2), check.calls);
    for (0..3) |mode| {
        t.auto_wrap = mode != 0;
        t.insert_mode = mode == 1;
        t.margin_mode = mode == 2;
        try testing.expectEqual(@as(usize, 2), try print(&t, "αβγ", 0x3b1, 2, null));
    }
}

test "first scalar image release reentry reacquires active buffer pen and invoking parser" {
    const graphics = @import("graphics.zig");
    const Reentry = struct {
        terminal: *Terminal,
        stop_parser: bool,
        releases: usize = 0,
        fn released(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.releases += 1;
            self.terminal.is_alternate = true;
            self.terminal.pen.fg = 0x01000002;
            self.terminal.active_link_id = 7;
            if (self.stop_parser) self.terminal.parser.state = .csi_param;
        }
        fn canContinue(context: ?*anyopaque) bool {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            return self.terminal.parser.canContinueOrdinaryUnicodeBatch();
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
    for ([_]bool{ false, true }) |stop| {
        var actual = try Terminal.init(testing.allocator, 4, 2, 0);
        defer actual.deinit();
        var expected = try Terminal.init(testing.allocator, 4, 2, 0);
        defer expected.deinit();
        var actual_reentry = Reentry{ .terminal = &actual, .stop_parser = stop };
        var expected_reentry = Reentry{ .terminal = &expected, .stop_parser = stop };
        try actual_reentry.install();
        try expected_reentry.install();
        const bytes = "αβγ";
        const consumed = try print(&actual, bytes, 0x3b1, 2, .{ .context = &actual_reentry, .can_continue = Reentry.canContinue });
        try testing.expectEqual(@as(usize, if (stop) 2 else bytes.len), consumed);
        try scalarText(&expected, bytes[0..consumed]);
        try testing.expectEqual(@as(usize, 1), actual_reentry.releases);
        try testing.expectEqual(@as(usize, 1), expected_reentry.releases);
        try equivalent(&actual, &expected);
    }
}

fn allocationCase(a: std.mem.Allocator) !void {
    var t = try Terminal.init(a, 8, 3, 7);
    defer t.deinit();
    const line = t.buffer().liveLine(0);
    try line.set(4, .{ .cell = .{ .scalar = 101 }, .extras = &.{ 0x301, 0x302 } });
    const retained = try line.cloneSnapshot();
    defer retained.release();
    _ = try print(&t, "α👩❤β", 0x3b1, 2, null);
    try testing.expectEqualSlices(u32, &.{ 0x301, 0x302 }, retained.get(4).extras.?);
}
test "ordinary Unicode allocation failures release temporary ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationCase, .{});
}
