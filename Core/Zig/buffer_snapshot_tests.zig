const std = @import("std");
const t = std.testing;
const Buffer = @import("buffer.zig").Buffer;
const Snapshot = @import("buffer_snapshot.zig").Snapshot;
const graphics = @import("graphics.zig");

test "bounded publication preserves row coordinates modes revisions and clusters" {
    var buffer = try Buffer.init(t.allocator, 8, 4, true, 100);
    defer buffer.deinit();
    const row = buffer.liveLine(1);
    try row.set(0, .{ .cell = .{ .scalar = 'e', .width = 1, .fg = 0x02010203 }, .extras = &.{0x301} });
    row.is_wrapped = true;
    row.render_mode = .doubled_top;
    const version = row.version();
    const snapshot = try Snapshot.capture(t.allocator, &buffer, 1, 2);
    defer snapshot.release();
    try t.expectEqual(@as(isize, 1), snapshot.first);
    try t.expectEqual(@as(usize, 2), snapshot.lines.len);
    const published = snapshot.line(0).?;
    try t.expectEqual(version, published.version());
    try t.expectEqual(row.identity, published.identity);
    try t.expect(published.is_wrapped and published.render_mode == .doubled_top);
    try row.set(0, .{ .cell = .{ .scalar = 'X' } });
    try t.expectEqual(@as(u32, 'e'), published.cell(0).scalar);
    try t.expectEqualSlices(u32, &.{0x301}, published.get(0).extras.?);
    try t.expect(snapshot.line(2) == null);
}

test "publication detaches image geometry and retains exact immutable payload" {
    var buffer = try Buffer.init(t.allocator, 8, 2, false, 0);
    defer buffer.deinit();
    const payload = try graphics.Payload.createHostCopy(t.allocator, .rgba, &.{ 1, 2, 3, 4 }, 1, 1);
    defer payload.release();
    const image = try graphics.LineImage.init(payload, 2);
    defer image.deinit();
    image.is_kitty = true;
    image.image_id = 99;
    image.placement_id = 71;
    image.z_index = -2;
    image.offset_x = 3;
    image.offset_y = 4;
    const row = buffer.liveLine(0);
    row.images = .empty;
    try row.images.?.append(t.allocator, image.clone());
    const version = row.version();
    const snapshot = try Snapshot.capture(t.allocator, &buffer, 0, 1);
    defer snapshot.release();
    const frozen = snapshot.line(0).?;
    const copy = frozen.images.?.items[0];
    try t.expect(copy != image and copy.payload == payload);
    try t.expectEqual(image.render_uuid, copy.render_uuid);
    try t.expectEqual(version, frozen.version());
    try t.expect(copy.lifetime_observer == null and frozen.lifetime_observer == null);
    image.col = 6;
    image.offset_y = 100;
    row.clearImages();
    try t.expectEqual(@as(isize, 2), copy.col);
    try t.expectEqual(@as(isize, 4), copy.offset_y);
    try t.expectEqual(@as(?u32, 99), copy.image_id);
    try t.expectEqual(@as(?u32, 71), copy.placement_id);
    try t.expectEqual(@as(isize, -2), copy.z_index);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, copy.payload.bytes);
}

test "empty ranges and invalid ranges never borrow outside the buffer" {
    var buffer = try Buffer.init(t.allocator, 8, 2, false, 0);
    defer buffer.deinit();
    const empty = try Snapshot.capture(t.allocator, &buffer, 100, 0);
    defer empty.release();
    try t.expect(empty.line(0) == null and empty.lines.len == 0 and empty.first == 100);
    try t.expectError(error.InvalidInput, Snapshot.capture(t.allocator, &buffer, -1, 0));
    try t.expectError(error.InvalidInput, Snapshot.capture(t.allocator, &buffer, 2, 1));
    try t.expectError(error.InvalidInput, Snapshot.capture(t.allocator, &buffer, 1, 2));
    try t.expectError(error.InvalidInput, Snapshot.capture(t.allocator, &buffer, 0, std.math.maxInt(usize)));
}

fn allocationExercise(a: std.mem.Allocator) !void {
    var buffer = try Buffer.init(a, 8, 2, false, 0);
    defer buffer.deinit();
    const payload = try graphics.Payload.createHostCopy(a, .rgba, &.{ 1, 2, 3, 4 }, 1, 1);
    defer payload.release();
    const image = try graphics.LineImage.init(payload, 0);
    defer image.deinit();
    buffer.liveLine(0).images = .empty;
    try buffer.liveLine(0).images.?.ensureTotalCapacity(a, 1);
    buffer.liveLine(0).images.?.appendAssumeCapacity(image.clone());
    const snapshot = try Snapshot.capture(a, &buffer, 0, 2);
    snapshot.release();
}
test "every viewport allocation failure unwinds rows images and payload owners" {
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

test "workers retain one viewport owner after the mutable buffer is destroyed" {
    const Reader = struct {
        snapshot: *Snapshot,
        done: bool = false,
        fn run(self: *@This()) void {
            defer self.snapshot.release();
            self.done = self.snapshot.first == 0 and self.snapshot.lines.len == 2 and
                self.snapshot.line(0).?.cell(0).scalar == 'A';
        }
    };
    var buffer = try Buffer.init(t.allocator, 8, 2, false, 0);
    var alive = true;
    defer if (alive) buffer.deinit();
    try buffer.liveLine(0).setCell(0, .{ .scalar = 'A' });
    const snapshot = try Snapshot.capture(t.allocator, &buffer, 0, 2);
    buffer.deinit();
    alive = false;
    var readers: [8]Reader = undefined;
    for (&readers) |*reader| reader.* = .{ .snapshot = snapshot.retain() };
    snapshot.release();
    var threads: [readers.len]std.Thread = undefined;
    var started: usize = 0;
    var joined = false;
    defer if (!joined) {
        for (threads[0..started]) |thread| thread.join();
        for (readers[started..]) |reader| reader.snapshot.release();
    };
    for (&readers, 0..) |*reader, index| {
        threads[index] = try std.Thread.spawn(.{}, Reader.run, .{reader});
        started += 1;
    }
    for (threads) |thread| thread.join();
    joined = true;
    for (readers) |reader| try t.expect(reader.done);
}
