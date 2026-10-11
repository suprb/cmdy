const std = @import("std");
const t = std.testing;
const g = @import("graphics.zig");
const Graphics = @import("render_graphics_input.zig").Graphics;

fn fixture(a: std.mem.Allocator) !g.KittyGraphicsStore {
    var store = g.KittyGraphicsStore.init(a);
    errdefer store.deinit();
    const payload = try g.Payload.createHostCopy(a, .rgba, &.{ 10, 20, 30, 40 }, 1, 1);
    defer payload.release();
    const image = try g.Image.create(payload, 91, null);
    defer image.deinit();
    try store.store(image);
    _ = try store.place(.{ .image_id = 91, .placement_id = 71, .col = 2, .row = 3, .cols = 4, .rows = 5, .offset_x = -2, .offset_y = 7, .is_virtual = true });
    _ = try store.place(.{ .image_id = 91, .placement_id = 72, .col = 6, .row = 8, .cols = 9, .rows = 10, .is_virtual = true, .is_alternate_buffer = true });
    _ = try store.place(.{ .image_id = 91, .placement_id = 73, .col = 0, .row = 0, .cols = 1, .rows = 1, .is_virtual = false });
    return store;
}

test "graphics keeps exact payload storage and both detached virtual placement sets" {
    var store = try fixture(t.allocator);
    var alive = true;
    defer if (alive) store.deinit();
    const payload = store.images_by_id.values()[0].payload;
    const bytes = payload.bytes.ptr;
    const snapshot = try Graphics.capture(t.allocator, &store);
    defer snapshot.release();
    try t.expectEqual(@as(usize, 2), payload.refs.load(.acquire));
    store.deinit();
    alive = false;
    for (snapshot.views, 0..) |view, buffer| {
        try t.expect(view.images[0].bytes == bytes);
        try t.expectEqual(@as(usize, 1), view.image_count);
        try t.expectEqual(@as(u32, 91), view.live_ids[0]);
        try t.expectEqual(@as(usize, 1), view.placement_count);
        try t.expectEqual(@as(u32, @intCast(71 + buffer)), view.placements[0].placement_id);
        try t.expectEqualSlices(u8, &.{ 10, 20, 30, 40 }, view.images[0].bytes[0..4]);
    }
    try t.expectEqual(@as(isize, -2), snapshot.views[0].placements[0].offset_x);
    try t.expectEqual(@as(isize, 7), snapshot.views[0].placements[0].offset_y);
    try t.expectEqual(@as(isize, 9), snapshot.views[1].placements[0].cols);
}

test "large payload capture needs only bounded metadata allocation" {
    var store = g.KittyGraphicsStore.init(t.allocator);
    defer store.deinit();
    const bytes = try t.allocator.alloc(u8, 4 * 1024 * 1024);
    @memset(bytes, 0x7b);
    const payload = g.Payload.createOwned(t.allocator, .rgba, bytes, 1024, 1024) catch |err| {
        t.allocator.free(bytes);
        return err;
    };
    defer payload.release();
    const image = try g.Image.create(payload, 17, null);
    defer image.deinit();
    try store.store(image);
    var metadata: [4096]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&metadata);
    const snapshot = try Graphics.capture(fixed.allocator(), &store);
    defer snapshot.release();
    try t.expect(snapshot.views[0].images[0].bytes == payload.bytes.ptr);
    try t.expectEqual(bytes.len, snapshot.views[0].images[0].byte_count);
    try t.expect(fixed.end_index < metadata.len);
}

test "PNG bytes and arbitrary host dimensions retain legacy decoder inputs" {
    var store = g.KittyGraphicsStore.init(t.allocator);
    defer store.deinit();
    inline for (.{ g.Format.png, g.Format.rgba }, 0..) |format, index| {
        const payload = try g.Payload.createHostCopy(t.allocator, format, &.{ 1, 2 }, -7, 12);
        defer payload.release();
        const image = try g.Image.create(payload, index + 1, null);
        defer image.deinit();
        try store.store(image);
    }
    const snapshot = try Graphics.capture(t.allocator, &store);
    defer snapshot.release();
    try t.expectEqual(@as(u8, 0), snapshot.images[0].kind);
    try t.expectEqual(@as(isize, 0), snapshot.images[0].width);
    try t.expectEqual(@as(u8, 1), snapshot.images[1].kind);
    try t.expectEqual(@as(isize, -7), snapshot.images[1].width);
    try t.expectEqual(@as(isize, 12), snapshot.images[1].height);
}

fn allocationExercise(a: std.mem.Allocator) !void {
    var store = try fixture(a);
    defer store.deinit();
    const snapshot = try Graphics.capture(a, &store);
    snapshot.release();
}
test "every graphics allocation failure releases metadata and payload references" {
    try t.checkAllAllocationFailures(t.allocator, allocationExercise, .{});
}

test "concurrent graphics owners survive registry destruction and release payload once" {
    const Reader = struct {
        snapshot: *Graphics,
        valid: bool = false,
        fn run(self: *@This()) void {
            defer self.snapshot.release();
            self.valid = self.snapshot.views[0].images[0].bytes[2] == 30 and
                self.snapshot.views[1].placements[0].placement_id == 72;
        }
    };
    var store = try fixture(t.allocator);
    const snapshot = Graphics.capture(t.allocator, &store) catch |err| {
        store.deinit();
        return err;
    };
    store.deinit();
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
    for (readers) |reader| try t.expect(reader.valid);
}

test "empty graphics views own no payload or placement buffers" {
    var store = g.KittyGraphicsStore.init(t.allocator);
    defer store.deinit();
    const snapshot = try Graphics.capture(t.allocator, &store);
    defer snapshot.release();
    for (snapshot.views) |view| {
        try t.expect(view.images == null and view.placements == null and view.live_ids == null);
        try t.expect(view.image_count == 0 and view.placement_count == 0 and view.live_count == 0);
    }
}
