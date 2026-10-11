const std = @import("std");
const A = std.testing.allocator;
const Buffer = @import("buffer.zig").Buffer;
const Line = @import("line.zig").Line;
const Cell = @import("row.zig").Cell;
const graphics = @import("graphics.zig");
const reflow = @import("reflow.zig");

fn text(line: *const Line, expected: []const u8) !void {
    const actual = try line.trimmedText(A);
    defer A.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

fn immutablePublication(a: std.mem.Allocator) !void {
    const native = @import("row.zig");
    const original = try Line.create(a, 8, .{});
    defer original.release();
    try original.fillCell(.{ .scalar = ' ' }, 0, null);
    try original.writeASCII("Hi", 2, .{});
    const before = native.stamp();
    const published = try original.renderSnapshot();
    defer published.release();
    const cells = [_]native.StoredCell{
        .{ .cell = .{ .scalar = 'A' } },
        .{ .cell = .{ .scalar = 'B' }, .cluster_offset = 0 },
        .{ .cell = .{ .scalar = 'e' }, .cluster_offset = 0, .cluster_count = 1 },
    };
    const value = try Line.snapshotFromCells(a, &cells, &.{0x301}, true, .double_width, 0);
    defer value.release();
    try std.testing.expectEqual(before + 1, native.stamp());
    try std.testing.expectEqual(original.version(), published.version());
    try std.testing.expect(published.row.deferred == null);
    try std.testing.expect(value.get(0).extras == null);
    try std.testing.expectEqual(@as(usize, 0), value.get(1).extras.?.len);
    try std.testing.expectEqualSlices(u32, &.{0x301}, value.get(2).extras.?);
    try std.testing.expectEqual(@as(u64, 0), value.version());
    try original.setCell(2, .{ .scalar = 'X' });
    try std.testing.expectEqual(@as(u32, 'H'), published.cell(2).scalar);
}

test "immutable render publications preserve mutation stamps and allocation lifetimes" {
    try immutablePublication(A);
    try std.testing.checkAllAllocationFailures(A, immutablePublication, .{});
}

test "immutable value imports reject malformed extras without consuming mutation stamps" {
    const native = @import("row.zig");
    const before = native.stamp();
    const missing = [_]native.StoredCell{.{ .cell = .{}, .cluster_count = 1 }};
    const outside = [_]native.StoredCell{.{ .cell = .{}, .cluster_offset = 1, .cluster_count = 1 }};
    try std.testing.expectError(error.InvalidInput, Line.snapshotFromCells(A, &missing, &.{0x301}, false, .single, 0));
    try std.testing.expectError(error.InvalidInput, Line.snapshotFromCells(A, &outside, &.{0x301}, false, .single, 0));
    try std.testing.expectEqual(before + 1, native.stamp());
}

test "capped history rotates stable lines and bounds prefix storage" {
    var b = try Buffer.init(A, 8, 4, true, 32);
    defer b.deinit();
    for (0..10_000) |n| {
        try b.scrollUp(.{}, false, true);
        var bytes: [16]u8 = undefined;
        const label = try std.fmt.bufPrint(&bytes, "L{d}", .{n});
        try b.liveLine(3).writeASCII(label, 0, .{});
    }
    try std.testing.expectEqual(@as(isize, 36), b.lineCount());
    try std.testing.expectEqual(@as(isize, 9968), b.dropped_lines);
    try std.testing.expectEqual(@as(isize, 32), b.y_base);
    try std.testing.expectEqual(b.y_base, b.y_disp);
    try std.testing.expect(b.line_start < 64);
    try std.testing.expect(b.storage.items.len < 100);
    try text(b.line(0).?, "L9964");
    const survivor = b.line(1).?.retain();
    defer survivor.release();
    try b.scrollUp(.{}, false, true);
    try std.testing.expect(survivor == b.line(0).?);
    b.clearScrollback();
    try std.testing.expectEqual(@as(isize, 4), b.lineCount());
    try std.testing.expectEqual(@as(isize, 0), b.y_base);
}

test "region scroll, reverse scroll and insert delete preserve outside rows" {
    var b = try Buffer.init(A, 8, 4, false, 0);
    defer b.deinit();
    for (0..4) |i| try b.liveLine(@intCast(i)).setCell(0, .{ .scalar = @intCast('A' + i) });
    b.scroll_top = 1;
    b.scroll_bottom = 2;
    try b.scrollUp(.{}, false, true);
    try text(b.liveLine(0), "A");
    try text(b.liveLine(1), "C");
    try text(b.liveLine(2), "");
    try text(b.liveLine(3), "D");
    try b.scrollDown(.{});
    try text(b.liveLine(1), "");
    try text(b.liveLine(2), "C");
    try b.insertLines(1, 1, .{});
    try text(b.liveLine(2), "");
    try b.liveLine(2).writeASCII("Z", 0, .{});
    try b.deleteLines(1, 1, .{});
    try text(b.liveLine(1), "Z");
    try text(b.liveLine(3), "D");
}

test "top anchored partial scroll enters history; SU does not" {
    var b = try Buffer.init(A, 8, 4, true, 3);
    defer b.deinit();
    for (0..4) |i| try b.liveLine(@intCast(i)).setCell(0, .{ .scalar = @intCast('A' + i) });
    b.scroll_bottom = 1;
    try b.scrollUp(.{}, false, true);
    try std.testing.expectEqual(@as(isize, 1), b.y_base);
    try text(b.line(0).?, "A");
    try text(b.liveLine(0), "B");
    try text(b.liveLine(1), "");
    try text(b.liveLine(2), "C");
    try text(b.liveLine(3), "D");
    try b.scrollUpRegionOnly(.{});
    try std.testing.expectEqual(@as(isize, 1), b.y_base);
    try text(b.line(0).?, "A");
}

test "ghost rows are stable, capacity modulo wraps, structural scroll expires ghosts" {
    var b = try Buffer.init(A, 8, 3, true, 1000);
    defer b.deinit();
    const ghost = (try b.lineAutovivified(30)).?;
    const id = ghost.identity;
    try ghost.writeASCII("ghost", 0, .{});
    try std.testing.expect(ghost == (try b.lineAutovivified(30)).?);
    try text((try b.lineAutovivified(1033)).?, "ghost");
    try std.testing.expect((try b.lineAutovivified(600)) == null);
    try b.scrollUp(.{}, false, true);
    try std.testing.expect((try b.lineAutovivified(30)).?.identity != id);
    var alt = try Buffer.init(A, 8, 3, false, 0);
    defer alt.deinit();
    try std.testing.expect(alt.liveLine(1) == (try alt.lineAutovivified(4)).?);
}

test "tab margins including cursor beyond right clamp backward" {
    var b = try Buffer.init(A, 25, 2, false, 0);
    defer b.deinit();
    try std.testing.expectEqual(@as(isize, 8), b.nextTabStop(0, false));
    b.margin_right = 5;
    try std.testing.expectEqual(@as(isize, 5), b.nextTabStop(20, true));
    try b.setTabStop(-3);
    try b.setTabStop(12);
    try std.testing.expectEqual(@as(isize, 12), b.previousTabStop(13));
    b.clearAllTabStops();
    try std.testing.expectEqual(@as(isize, 24), b.nextTabStop(0, false));
    try std.testing.expectEqual(@as(isize, 0), b.previousTabStop(13));
}

test "retained snapshot and line references outlive buffer and recycled mutations" {
    var b = try Buffer.init(A, 8, 2, true, 0);
    try b.liveLine(0).set(0, .{ .cell = .{ .scalar = 'e' }, .extras = &.{0x301} });
    const retained = b.liveLine(0).retain();
    defer retained.release();
    const copies = try b.snapshot(A);
    defer Buffer.releaseSnapshots(A, copies);
    try b.scrollUp(.{}, false, true);
    try b.liveLine(1).writeASCII("new", 0, .{});
    b.deinit();
    try text(copies[0], "e\u{301}");
    try text(retained, "new");
}

test "line alias extras, present empty extras, wrapping inserts and wide trim" {
    const l = try Line.create(A, 6, .{});
    defer l.release();
    try l.set(0, .{ .cell = .{ .scalar = 'x' }, .extras = &.{0x301} });
    const borrowed = l.get(0);
    try l.set(1, borrowed);
    try std.testing.expectEqualSlices(u32, &.{0x301}, l.get(1).extras.?);
    try l.set(2, .{ .cell = .{ .scalar = 'y' }, .extras = &.{} });
    try std.testing.expect(l.get(2).extras != null);
    try l.insertCells(7, 1, 5, .{ .cell = .{ .scalar = 'A' } });
    try std.testing.expectEqual(@as(u32, 'A'), l.cell(1).scalar);
    try l.fillCell(.{}, 0, null);
    try l.setCell(4, .{ .scalar = 0x4e00, .width = 2 });
    try l.setCell(5, .{ .width = 0 });
    try std.testing.expectEqual(@as(isize, 5), l.usedLength());
    try std.testing.expectEqual(@as(isize, 6), l.trimmedLength());
}

test "simple resize reveals history, consumes blanks, preserves row identity and cluster snapshots" {
    var b = try Buffer.init(A, 8, 3, true, 10);
    defer b.deinit();
    try b.liveLine(0).writeASCII("old", 0, .{});
    try b.scrollUp(.{}, false, true);
    b.y = 2;
    try b.liveLine(2).writeASCII("live", 0, .{});
    const survivor = b.liveLine(2);
    const saved = try survivor.clone();
    defer saved.release();
    try b.resizeSimple(10, 4, .{});
    try std.testing.expectEqual(@as(isize, 0), b.y_base);
    try std.testing.expectEqual(@as(isize, 3), b.y);
    try std.testing.expect(b.liveLine(3) == survivor);
    try text(b.liveLine(0), "old");
    try std.testing.expectEqual(@as(isize, 8), saved.count());
    try b.resizeSimple(4, 2, .{});
    try std.testing.expectEqual(@as(isize, 2), b.y_base);
    try text(b.liveLine(1), "live");
    try std.testing.expect(b.liveLine(1) == survivor);
}

fn allocationTrace(a: std.mem.Allocator) !void {
    var b = try Buffer.init(a, 16, 3, true, 2);
    defer b.deinit();
    try b.liveLine(0).set(0, .{ .cell = .{ .scalar = 'e' }, .extras = &.{0x301} });
    const copies = try b.snapshot(a);
    defer Buffer.releaseSnapshots(a, copies);
    _ = try b.lineAutovivified(4);
    try b.scrollUp(.{}, false, true);
    try b.scrollUp(.{}, false, true);
    try b.scrollUp(.{}, false, true);
    try b.resizeSimple(10, 5, .{});
    try b.resizeSimple(20, 2, .{});
    try b.hardReset();
}
test "all allocation failures in buffer lifecycle release owned state" {
    try std.testing.checkAllAllocationFailures(A, allocationTrace, .{});
}

test "reflow maps logical row offsets cursor and sparse viewport without fake history" {
    var b = try Buffer.init(A, 10, 8, true, 100);
    defer b.deinit();
    try b.liveLine(0).writeASCII("abcdefghij", 0, .{});
    try b.liveLine(1).writeASCII("klmno", 0, .{});
    b.liveLine(1).setWrapped(true);
    b.x = 5;
    b.y = 1;
    var result = try reflow.build(&b, 4, 8, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(isize, 0), result.y_base);
    try std.testing.expectEqual(@as(isize, 3), result.y);
    try std.testing.expectEqual(@as(isize, 3), result.x);
    try std.testing.expectEqual(@as(isize, 0), result.row_map[0]);
    try std.testing.expectEqual(@as(isize, 2), result.row_map[1]);
    try result.commit(&b);
    try text(b.liveLine(0), "abcd");
    try text(b.liveLine(1), "efgh");
    try text(b.liveLine(2), "ijkl");
    try text(b.liveLine(3), "mno");
    try std.testing.expectEqual(@as(isize, 8), b.lineCount());
    try std.testing.expectEqual(@as(isize, 0), b.y_disp);
    var wider = try reflow.build(&b, 20, 8, .{});
    defer wider.deinit();
    try wider.commit(&b);
    try text(b.liveLine(0), "abcdefghijklmno");
    try std.testing.expectEqual(@as(isize, 0), b.y_base);
    try std.testing.expectEqual(@as(isize, 0), b.y);
    try std.testing.expectEqual(@as(isize, 15), b.x);
}

test "reflow backs off wide continuation and preserves combining extras and attributes" {
    var b = try Buffer.init(A, 6, 4, true, 10);
    defer b.deinit();
    try b.liveLine(0).writeASCII("ab", 0, .{});
    try b.liveLine(0).set(2, .{ .cell = .{ .scalar = 0x4e00, .width = 2, .fg = 0x01000007 }, .extras = &.{0xfe0f} });
    try b.liveLine(0).setCell(3, .{ .width = 0 });
    try b.liveLine(0).writeASCII("cd", 4, .{});
    b.x = 6;
    const retained = try b.liveLine(0).clone();
    defer retained.release();
    var result = try reflow.build(&b, 3, 4, .{});
    defer result.deinit();
    try result.commit(&b);
    try text(b.liveLine(0), "ab");
    try std.testing.expectEqual(@as(u32, 0x4e00), b.liveLine(1).cell(0).scalar);
    try std.testing.expectEqual(@as(i8, 0), b.liveLine(1).cell(1).width);
    try std.testing.expectEqualSlices(u32, &.{0xfe0f}, b.liveLine(1).get(0).extras.?);
    try std.testing.expectEqual(@as(u32, 0x01000007), b.liveLine(1).cell(0).fg);
    try text(b.liveLine(2), "d");
    try std.testing.expectEqual(@as(isize, 6), retained.count());
    for (0..@intCast(b.lineCount())) |i| try std.testing.expect(b.line(@intCast(i)).?.cell(2).width != 2);
}

test "word reflow keeps separator on previous row across round trips" {
    var b = try Buffer.init(A, 40, 10, true, 10);
    defer b.deinit();
    const message = "This is a line with words and spaces.";
    try b.liveLine(0).writeASCII(message, 0, .{});
    b.liveLine(0).wrap_style = .words;
    b.x = message.len;
    for ([_]isize{ 11, 7, 19, 40 }) |width| {
        var result = try reflow.build(&b, width, 10, .{});
        defer result.deinit();
        try result.commit(&b);
        var gathered: std.ArrayList(u8) = .empty;
        defer gathered.deinit(A);
        for (0..@intCast(b.lineCount())) |i| {
            const value = try b.line(@intCast(i)).?.trimmedText(A);
            defer A.free(value);
            if (value.len == 0) continue;
            try std.testing.expect(value[0] != ' ');
            try gathered.appendSlice(A, value);
        }
        try std.testing.expectEqualStrings(message, gathered.items);
    }
}

test "detached rectangular boundaries and Kitty claims preserve logical and physical row maps" {
    var b = try Buffer.init(A, 4, 4, true, 10);
    defer b.deinit();
    try b.liveLine(0).writeASCII("abc", 0, .{});
    b.liveLine(1).setWrapped(true); // trailing empty row at logical offset 3
    try b.liveLine(2).writeASCII("img", 0, .{});
    b.liveLine(2).setWrapped(true);
    b.x = 1;
    b.y = 2;
    var result = try reflow.build(&b, 8, 4, .{ .kitty_boundary_rows = &.{2}, .kitty_claimed_rows = &.{2} });
    defer result.deinit();
    try std.testing.expectEqual(@as(isize, 0), result.row_map[1]);
    try std.testing.expectEqual(@as(isize, 1), result.physical_row_map[1]);
    try std.testing.expect(result.physical_end_overrides[1]);
    try std.testing.expect(!result.physical_end_overrides[0]);
    try std.testing.expectEqual(@as(isize, 2), result.row_map[2]);
    try std.testing.expectEqual(@as(isize, 2), result.claim_row_map[0]);
    try result.commit(&b);
    try text(b.liveLine(0), "abc");
    try text(b.liveLine(1), "");
    try text(b.liveLine(2), "img");
    try std.testing.expect(!b.liveLine(2).is_wrapped);

    b.liveLine(2).setWrapped(true);
    var detached = try reflow.build(&b, 3, 4, .{ .detached_margin_rows = &.{2} });
    defer detached.deinit();
    try std.testing.expectEqual(@as(isize, 2), detached.row_map[2]);
}

test "reflow honors consumed prompt boundary and caps history with absent anchors" {
    var b = try Buffer.init(A, 6, 1, true, 1);
    defer b.deinit();
    try b.liveLine(0).writeASCII("abcdef", 0, .{});
    b.x = 5;
    var result = try reflow.build(&b, 2, 1, .{ .trailing_semantic_boundary = 0 });
    defer result.deinit();
    try std.testing.expectEqual(@as(isize, 2), result.dropped);
    try std.testing.expectEqual(@as(isize, 1), result.semantic_boundary.?);
    try std.testing.expectEqual(@as(isize, 1), result.row_map[0]);
    try std.testing.expectEqual(@as(isize, -1), result.image_row_map[0]);
    try result.commit(&b);
    try std.testing.expectEqual(@as(isize, 2), b.lineCount());
    try std.testing.expectEqual(@as(isize, 2), b.dropped_lines);
    try text(b.line(0).?, "ef");
    try text(b.liveLine(0), "");
}

test "Kitty completed end predicate is retained when trim removes both mapped anchors" {
    var b = try Buffer.init(A, 4, 3, true, 0);
    defer b.deinit();
    try b.liveLine(0).writeASCII("abc", 0, .{});
    b.liveLine(1).setWrapped(true);
    try b.liveLine(2).writeASCII("img", 0, .{});
    b.liveLine(2).setWrapped(true);
    b.y = 2;
    var result = try reflow.build(&b, 8, 1, .{ .kitty_boundary_rows = &.{2}, .kitty_claimed_rows = &.{2} });
    defer result.deinit();
    try std.testing.expectEqual(@as(isize, 2), result.dropped);
    try std.testing.expect(result.physical_end_overrides[1]);
    try std.testing.expectEqual(@as(isize, -1), result.row_map[1]);
    try std.testing.expectEqual(@as(isize, -1), result.physical_row_map[1]);
    try std.testing.expectEqual(@as(isize, 0), result.claim_row_map[0]);
}

test "images survive reflow, snapshot and producer release with stable cache identity" {
    var b = try Buffer.init(A, 8, 4, true, 10);
    defer b.deinit();
    const payload = try graphics.Payload.createCopy(A, .rgba, &.{ 0, 1, 2, 3 }, 1, 1);
    var image = try graphics.LineImage.init(payload, 3);
    payload.release();
    const identity = image.render_id;
    try b.liveLine(1).appendImage(image);
    image.deinit();
    b.liveLine(1).setWrapped(true);
    try b.liveLine(0).writeASCII("abcdefgh", 0, .{});
    try b.liveLine(1).writeASCII("ij", 0, .{});
    b.x = 2;
    b.y = 1;
    const copies = try b.snapshot(A);
    defer Buffer.releaseSnapshots(A, copies);
    var result = try reflow.build(&b, 4, 4, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(isize, 0), result.image_row_map[1]);
    try result.commit(&b);
    try std.testing.expectEqual(identity, b.line(0).?.images.?.items[0].render_id);
    try std.testing.expectEqual(identity, copies[1].images.?.items[0].render_id);
    b.line(0).?.clearImages();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3 }, copies[1].images.?.items[0].payload.bytes);
}

fn reflowAllocationTrace(a: std.mem.Allocator) !void {
    var b = try Buffer.init(a, 8, 3, true, 2);
    defer b.deinit();
    try b.liveLine(0).set(0, .{ .cell = .{ .scalar = 'e' }, .extras = &.{0x301} });
    try b.liveLine(0).writeASCII("abcdef", 1, .{});
    b.liveLine(1).setWrapped(true);
    try b.liveLine(1).writeASCII("next", 0, .{});
    const id = b.liveLine(0).identity;
    const before = b.liveLine(0).version();
    var result = reflow.build(&b, 3, 2, .{ .kitty_claimed_rows = &.{2}, .kitty_boundary_rows = &.{2} }) catch |err| {
        try std.testing.expectEqual(id, b.liveLine(0).identity);
        try std.testing.expectEqual(before, b.liveLine(0).version());
        try std.testing.expectEqual(@as(isize, 8), b.cols);
        try std.testing.expectEqual(@as(u32, 'e'), b.liveLine(0).cell(0).scalar);
        return err;
    };
    defer result.deinit();
    try result.commit(&b);
}
test "every reflow allocation failure preserves original content ownership and geometry" {
    try std.testing.checkAllAllocationFailures(A, reflowAllocationTrace, .{});
}

// Independent reference: frozen production Swift, generated from 64 seeds by
// /private/tmp/cmdy-zig-engine-20260911-01/buffer-oracle/main.swift. Complete
// source pins, compiler receipt and executable are retained alongside it.
const ReferenceRng = struct {
    state: u64,
    fn next(self: *ReferenceRng, limit: usize) usize {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return @intCast((self.state >> 32) % limit);
    }
};
const ReferenceDigest = struct {
    value: u64 = 14695981039346656037,
    fn add(self: *ReferenceDigest, value: u64) void {
        var shift: u7 = 0;
        while (shift < 64) : (shift += 8) self.value = (self.value ^ ((value >> @as(u6, @intCast(shift))) & 255)) *% 1099511628211;
    }
    fn signed(self: *ReferenceDigest, value: isize) void {
        self.add(@bitCast(@as(i64, @intCast(value))));
    }
};
fn referenceDigest(b: *const Buffer) u64 {
    var d: ReferenceDigest = .{};
    for ([_]isize{ b.cols, b.rows, b.lineCount(), b.y_base, b.y_disp, b.x, b.y, b.dropped_lines, b.scroll_top, b.scroll_bottom, b.margin_left, b.margin_right, @intFromBool(b.wrap_pending) }) |value| d.signed(value);
    for (0..@intCast(b.lineCount())) |row_index| {
        const line = b.line(@intCast(row_index)).?;
        d.add(@intFromBool(line.is_wrapped));
        d.add(@intFromBool(line.wrap_style == .words));
        d.add(@intFromEnum(line.render_mode));
        for (0..@intCast(line.count())) |column| {
            const value = line.get(@intCast(column));
            const cell = value.cell;
            d.add(cell.scalar);
            d.signed(cell.width);
            d.add(cell.fg);
            d.add(cell.bg);
            d.add(cell.style);
            d.add(cell.link_id);
            d.add(cell.underline_kind);
            d.add(if (cell.underline_present == 1) cell.underline_color else std.math.maxInt(u64));
            d.add(if (value.extras) |extras| extras.len else std.math.maxInt(u64));
            if (value.extras) |extras| for (extras) |scalar| {
                d.add(scalar);
            };
        }
    }
    var col: isize = 0;
    while (col < b.cols) : (col += 1) if (b.tab_stops.contains(col)) {
        d.signed(col);
    };
    return d.value;
}
test "64 randomized pure reflows match frozen Swift before and after byte-for-byte state digests" {
    const expected = [_]u64{
        0xb8d1853b025c7053, 0xad0da6005d818e58,
        0x926f4c55e7284c8d, 0xd3de319e09c1f1a1,
        0x632897e0fa93fc4d, 0xf387e957c7d19c6c,
        0xd0fc62599eb1b774, 0xd3c21e50b2cb283b,
        0xff5e5bb89adfd084, 0x62b9ddca3f8821e8,
        0xef96637e73b9e5b0, 0x0b91d392bbd4de00,
        0xc8d5599847f7ec2b, 0xd15e4ac0a70856c0,
        0xb6667d4547d850c5, 0x301d2f3f4d2b9fec,
        0xa27a52d0336820d4, 0x705a749fdac9e5a3,
        0x72bab8d256bddef0, 0x2c50369aa04eaabc,
        0x9eae46b4df64df74, 0x53bca86e36fcd2e7,
        0x81810a054bdf3dcb, 0x4837767f605f7b5f,
        0x4c4bac1b9efcff43, 0x174822338a6b1dea,
        0x78fe2f02ca918ee3, 0x43927bfc0dd21074,
        0x804cf6af9cd50ecd, 0x77a6897d9dfa840c,
        0xea29e82c622f357d, 0xb4d3df666dd25fc0,
        0xbb51e1d79ea50788, 0x251657a3a70c6fef,
        0x32b84f1200162d0b, 0x5a7594ad5573ebc9,
        0xc80eb50930764345, 0xec17e38f8d2668ce,
        0xb01c2fc03f20c53f, 0x126795062b611a6f,
        0x5c13444c92e584e5, 0x8c35ba2ff09170bc,
        0xf55593be9097d717, 0x1894468f1651d045,
        0x02d4033e489c45b8, 0xc35558546ea35076,
        0x94349e4591151ea0, 0x720303e550ff3933,
        0x1bf1b79b271c5deb, 0xdea8ca7e12570625,
        0x963a8fae9b3237af, 0xba5986d4748fc47b,
        0xc22808d132714f33, 0xbe18356b79125448,
        0x83ca9bcdd8e8b2b3, 0x8f6a41cdb35ac329,
        0x0251e8f8bc041945, 0x5b3ee66df90b7510,
        0x4ac14e07c5beb3d9, 0xbd6bb6d8ff853ce0,
        0x6427742f684d2498, 0xdff0b3543aabe5ae,
        0xc8d94fae795a5599, 0xa07614f0b641785c,
        0x0c13dea9292dc03d, 0xd1c765a9dcae15a0,
        0xc4da30d9627d8414, 0x3d4bcb337039b7e2,
        0x9a64817f13c21a63, 0xe1d0eb9842f0fc4f,
        0xd34fc1ecdf285e1a, 0xe9fd3fedd6baba57,
        0x3a1efd6e91765492, 0xb07f53f48be044f5,
        0xe1777fe8ac3ba072, 0x3250fd20f4b87a37,
        0xc67e9641fee0f2b7, 0x61ea4756428bfa78,
        0x4038fc176f4f1df5, 0x7f761f03451fcac3,
        0xac197a638783422d, 0xaad09c4e9ec6f7fa,
        0xddc365c202be75c2, 0x6284c8950429bfaa,
        0x49878c46c9eeb04c, 0x5a700654a79e72a3,
        0xfd3ff0bb670345c8, 0xb8755c790effaf1f,
        0x20c16dac3f109a1c, 0x4a6a14af42a97996,
        0x4eaa6197626957a4, 0x59875568d96671e1,
        0x99fc48a37385c59f, 0x984d7255c1a1c79b,
        0x9056b7d18cfd4663, 0xcff84273d5cd10b5,
        0xa15c23a87fec707e, 0x9f654e85e277aaad,
        0xe5c59f048884dc9b, 0xe09ebf3da27a6f69,
        0x67254bddae871463, 0xbad838927cfe3feb,
        0x7e521d6245b224ef, 0x9a036ff5e239a68b,
        0x30a8479568380b36, 0x0f33f68bb47e415d,
        0x026d833256947964, 0x982bcd17f4df6ead,
        0x6b5983c9c6db9916, 0x71237f76eccfaa3f,
        0xeaad9af88860e66d, 0xe7bbe5f8a8e65963,
        0x4eb06943526cca30, 0x966d8bd60e10df78,
        0xc1296ea11acff94b, 0xc9cb7473f5685161,
        0xcebf47a982ca08a6, 0x79a67493d948397b,
        0x72fb519e8f337fce, 0xaf2299c207240799,
        0xffed27e6fea651d6, 0xed94c57694e1344c,
        0xe67a5accc081b00d, 0x51cc927cded3299f,
        0x6bf209bc471af608, 0x2baf5cc8b6cae11c,
        0x99bd278ce8575690, 0x476db3156f31557e,
    };
    for (1..65) |seed| {
        var rng = ReferenceRng{ .state = seed };
        const cols: isize = @intCast(2 + rng.next(20));
        const height: isize = @intCast(1 + rng.next(10));
        const cap: isize = @intCast(rng.next(8));
        var b = try Buffer.init(A, cols, height, true, cap);
        defer b.deinit();
        b.margin_right = cols - 1;
        const history = rng.next(@intCast(cap + 1));
        for (0..history) |_| try b.scrollUp(.{}, false, true);
        for (0..@intCast(b.lineCount())) |row_index| {
            const line = b.line(@intCast(row_index)).?;
            line.setWrapped(rng.next(3) == 0);
            line.wrap_style = if (rng.next(4) == 0) .words else .cells;
            const render = rng.next(16);
            line.setRenderMode(if (render == 1) .double_width else if (render == 2) .doubled_top else if (render == 3) .doubled_down else .single);
            const used = rng.next(@intCast(cols + 1));
            var x: usize = 0;
            while (x < used) : (x += 1) {
                const kind = rng.next(6);
                const scalar: u32 = @intCast(97 + rng.next(26));
                const fg: u32 = @intCast(rng.next(16));
                const bg: u32 = @intCast(rng.next(16));
                const style: u8 = @intCast(rng.next(256));
                const link: u16 = @intCast(rng.next(4));
                var cell = Cell{ .scalar = scalar, .fg = 0x01000000 | fg, .bg = 0x01000000 | bg, .style = style, .link_id = link };
                if (kind == 4 and x + 1 < @as(usize, @intCast(cols))) {
                    cell.scalar = 0x4e00 + scalar;
                    cell.width = 2;
                    try line.setCell(@intCast(x), cell);
                    x += 1;
                    try line.setCell(@intCast(x), .{ .width = 0 });
                } else {
                    cell.scalar = if (kind == 0) 0 else if (kind == 1) 32 else scalar;
                    try line.set(@intCast(x), .{ .cell = cell, .extras = if (kind == 5) &.{0x301} else null });
                }
            }
        }
        b.x = @intCast(rng.next(@intCast(cols + 1)));
        b.y = @intCast(rng.next(@intCast(height)));
        b.y_disp = @intCast(rng.next(@intCast(b.y_base + 1)));
        const before = referenceDigest(&b);
        if (before != expected[(seed - 1) * 2]) std.debug.print("reference setup differs for seed {d}\n", .{seed});
        try std.testing.expectEqual(expected[(seed - 1) * 2], before);
        var width: isize = @intCast(2 + rng.next(20));
        if (width == cols) width += 1;
        const new_height: isize = @intCast(1 + rng.next(10));
        var result = try reflow.build(&b, width, new_height, .{});
        defer result.deinit();
        try result.commit(&b);
        const after = referenceDigest(&b);
        if (after != expected[(seed - 1) * 2 + 1]) std.debug.print("reference reflow differs for seed {d}, geometry {d}x{d}\n", .{ seed, width, new_height });
        try std.testing.expectEqual(expected[(seed - 1) * 2 + 1], after);
    }
}
