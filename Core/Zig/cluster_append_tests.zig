//! Storage guarantees live here rather than in Swift tests: a Swift Cell read
//! materializes an Array, whose address/capacity does not expose the native row.
//! These checks use Terminal.feed and inspect allocations that are still alive.
const std = @import("std");
const testing = std.testing;
const Terminal = @import("terminal.zig").Terminal;
const printing = @import("printing.zig");

test "native cluster append reuses unique reserved arena for combining and joined followers" {
    const Case = struct { seed: []const u8, followers: [3][]const u8, extras: []const u32 };
    const cases = [_]Case{
        .{ .seed = "e\u{301}", .followers = .{ "\u{308}", "\u{305}", "\u{e0100}" }, .extras = &.{ 0x301, 0x308, 0x305, 0xe0100 } },
        .{ .seed = "\u{2764}\u{fe0f}\u{200d}", .followers = .{ "\u{1f525}", "\u{200d}", "\u{1f525}" }, .extras = &.{ 0xfe0f, 0x200d, 0x1f525, 0x200d, 0x1f525 } },
    };
    for (cases) |case| {
        var terminal = try Terminal.init(testing.allocator, 32, 3, 10);
        defer terminal.deinit();
        try terminal.feed(case.seed);
        const line = terminal.buffer().liveLine(0);
        const storage = line.row.storage;
        try testing.expectEqual(@as(usize, 1), storage.refs.load(.monotonic));
        try storage.extras.ensureTotalCapacity(testing.allocator, 128);
        const cells = storage.cells.ptr;
        const arena = storage.extras.items.ptr;
        const capacity = storage.extras.capacity;
        const offset = storage.cells[0].cluster_offset;
        const original_cell = line.cell(0);
        var count = line.get(0).extras.?.len;
        for (case.followers) |follower| {
            try terminal.feed(follower);
            count += 1;
            try testing.expectEqual(storage, line.row.storage);
            try testing.expectEqual(@as(usize, 1), storage.refs.load(.monotonic));
            try testing.expectEqual(cells, storage.cells.ptr);
            try testing.expectEqual(arena, storage.extras.items.ptr);
            try testing.expectEqual(capacity, storage.extras.capacity);
            try testing.expectEqual(offset, storage.cells[0].cluster_offset);
            try testing.expectEqualDeep(original_cell, line.cell(0));
            try testing.expectEqualSlices(u32, case.extras[0..count], line.get(0).extras.?);
        }
    }
}

test "native cluster append detaches shared rows and preserves retained arena and cell values" {
    inline for (.{ false, true }) |snapshot| {
        var terminal = try Terminal.init(testing.allocator, 32, 3, 10);
        defer terminal.deinit();
        try terminal.feed("e\u{301}");
        const line = terminal.buffer().liveLine(0);
        try line.row.storage.extras.ensureTotalCapacity(testing.allocator, 128);
        const retained = if (snapshot) try line.cloneSnapshot() else try line.clone();
        defer retained.release();
        const shared_storage = retained.row.storage;
        const shared_cells = shared_storage.cells.ptr;
        const shared_arena = shared_storage.extras.items.ptr;
        const shared_capacity = shared_storage.extras.capacity;
        const original_cell = retained.cell(0);
        try testing.expectEqual(shared_storage, line.row.storage);
        try testing.expectEqual(@as(usize, 2), shared_storage.refs.load(.monotonic));

        try terminal.feed("\u{308}");
        // Both allocations remain owned: inequality cannot be allocator reuse.
        try testing.expect(line.row.storage != shared_storage);
        try testing.expect(line.row.storage.cells.ptr != shared_cells);
        try testing.expect(line.row.storage.extras.items.ptr != shared_arena);
        try testing.expectEqual(@as(usize, 1), line.row.storage.refs.load(.monotonic));
        try testing.expectEqual(@as(usize, 1), shared_storage.refs.load(.monotonic));
        try testing.expectEqual(shared_storage, retained.row.storage);
        try testing.expectEqual(shared_cells, retained.row.storage.cells.ptr);
        try testing.expectEqual(shared_arena, retained.row.storage.extras.items.ptr);
        try testing.expectEqual(shared_capacity, retained.row.storage.extras.capacity);
        try testing.expectEqualDeep(original_cell, retained.cell(0));
        try testing.expectEqualSlices(u32, &.{0x301}, retained.get(0).extras.?);
        try testing.expectEqualSlices(u32, &.{ 0x301, 0x308 }, line.get(0).extras.?);

        try line.row.storage.extras.ensureTotalCapacity(testing.allocator, 128);
        const detached_arena = line.row.storage.extras.items.ptr;
        const detached_capacity = line.row.storage.extras.capacity;
        try terminal.feed("\u{305}");
        try testing.expectEqual(detached_arena, line.row.storage.extras.items.ptr);
        try testing.expectEqual(detached_capacity, line.row.storage.extras.capacity);
        try testing.expectEqualSlices(u32, &.{ 0x301, 0x308, 0x305 }, line.get(0).extras.?);
        try testing.expectEqualSlices(u32, &.{0x301}, retained.get(0).extras.?);
    }
}

test "native cluster append pending and reverse witnesses own extras independently of row arena" {
    inline for (.{ false, true }) |reverse| {
        var terminal = try Terminal.init(testing.allocator, 1, 3, 10);
        defer terminal.deinit();
        try terminal.feed(if (reverse) "e\u{301}A\x1bM\x1bM" else "e\u{301}");
        const line = terminal.buffer().liveLine(if (reverse) 1 else 0);
        const owner = if (reverse) &printing.reverseWitness(&terminal).*.?.cell else &terminal.print_state.pendingWrapOwnerWitness.?.cell;
        try testing.expectEqualSlices(u32, &.{0x301}, line.get(0).extras.?);
        try testing.expectEqualSlices(u32, &.{0x301}, owner.extras.?);
        try testing.expect(owner.extras.?.ptr != line.get(0).extras.?.ptr);
        // Save a real owning value before feed refreshes/replaces the witness.
        var retained_owner = try owner.clone(testing.allocator);
        defer retained_owner.deinit(testing.allocator);
        try testing.expect(retained_owner.extras.?.ptr != owner.extras.?.ptr);
        const storage = line.row.storage;
        try storage.extras.ensureTotalCapacity(testing.allocator, 128);
        const arena = storage.extras.items.ptr;
        const capacity = storage.extras.capacity;
        try testing.expectEqual(@as(usize, 1), storage.refs.load(.monotonic));

        try terminal.feed("\u{308}");
        try testing.expectEqualSlices(u32, &.{0x301}, retained_owner.extras.?);
        try testing.expectEqualSlices(u32, &.{ 0x301, 0x308 }, line.get(0).extras.?);
        try testing.expectEqual(storage, line.row.storage);
        try testing.expectEqual(arena, storage.extras.items.ptr);
        try testing.expectEqual(capacity, storage.extras.capacity);
        const refreshed = if (reverse) &printing.reverseWitness(&terminal).*.?.cell else &terminal.print_state.pendingWrapOwnerWitness.?.cell;
        try testing.expectEqualSlices(u32, &.{ 0x301, 0x308 }, refreshed.extras.?);
        try testing.expect(refreshed.extras.?.ptr != line.get(0).extras.?.ptr);
        if (reverse) {
            try testing.expectEqual(@as(isize, 0), terminal.buffer().x);
            try testing.expectEqual(@as(isize, 0), terminal.buffer().y);
        } else try testing.expect(terminal.buffer().wrap_pending);
    }
}
