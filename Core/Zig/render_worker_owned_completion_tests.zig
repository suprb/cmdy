const std = @import("std");
const t = std.testing;
const m = @import("render_worker.zig");

const Log = struct {
    values: [8]u32 = @splat(0),
    count: usize = 0,
    disposed: usize = 0,
    cancelled: usize = 0,
    fn run(context: ?*anyopaque, _: *m.Worker, result: u32) callconv(.c) void {
        const value: *Value = @ptrCast(@alignCast(context.?));
        value.log.values[value.log.count] = value.id;
        value.log.count += 1;
        value.log.cancelled += @intFromBool(result == @intFromEnum(m.CompletionResult.cancelled));
    }
    fn dispose(context: ?*anyopaque) callconv(.c) void {
        const value: *Value = @ptrCast(@alignCast(context.?));
        value.log.disposed += 1;
    }
};
const Value = struct { log: *Log, id: u32 };

test "owned completion uses one allocation and drains without allocating" {
    var accounting = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.create(accounting.allocator());
    var log: Log = .{};
    const before = accounting.allocations;
    const ticket = worker.prepareOwnedCompletion(Value, .{ .log = &log, .id = 17 }, Log.run, Log.dispose).?;
    const after = accounting.allocations;
    accounting.fail_index = accounting.alloc_index;
    ticket.publish(.ready);
    try t.expect(worker.destroy());
    try t.expectEqual(before + 1, after);
    try t.expectEqual(@as(usize, 1), log.count);
    try t.expectEqual(@as(usize, 1), log.disposed);
    try t.expectEqual(@as(u32, 17), log.values[0]);
    try t.expectEqual(after, accounting.allocations);
    try t.expect(!accounting.has_induced_failure);
    try t.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

test "owned and borrowed completion payloads preserve FIFO publication order" {
    const worker = try m.Worker.create(t.allocator);
    var log: Log = .{};
    var borrowed = Value{ .log = &log, .id = 2 };
    const last = worker.prepareOwnedCompletion(Value, .{ .log = &log, .id = 3 }, Log.run, Log.dispose).?;
    const first = worker.prepareOwnedCompletion(Value, .{ .log = &log, .id = 1 }, Log.run, Log.dispose).?;
    const middle = worker.prepareCompletion(&borrowed, Log.run, Log.dispose).?;
    first.publish(.ready);
    middle.publish(.cancelled);
    last.publish(.ready);
    try t.expect(worker.destroy());
    try t.expectEqualSlices(u32, &.{ 1, 2, 3 }, log.values[0..log.count]);
    try t.expectEqual(@as(usize, 3), log.disposed);
    try t.expectEqual(@as(usize, 1), log.cancelled);
}

test "owned completion capacity and stop rejection do not allocate or adopt payload" {
    var accounting = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.createWithOptions(accounting.allocator(), null, 1);
    var accepted: Log = .{};
    var rejected: Log = .{};
    const ticket = worker.prepareOwnedCompletion(Value, .{ .log = &accepted, .id = 1 }, Log.run, Log.dispose).?;
    const allocations = accounting.allocations;
    const full = worker.prepareOwnedCompletion(Value, .{ .log = &rejected, .id = 2 }, Log.run, Log.dispose);
    worker.stop();
    const stopped = worker.prepareOwnedCompletion(Value, .{ .log = &rejected, .id = 3 }, Log.run, Log.dispose);
    ticket.publish(.cancelled);
    try t.expect(worker.destroy());
    try t.expect(full == null and stopped == null);
    try t.expectEqual(allocations, accounting.allocations);
    try t.expectEqual(@as(usize, 0), rejected.count + rejected.disposed);
    try t.expectEqual(@as(usize, 1), accepted.cancelled);
    try t.expectEqual(@as(usize, 1), accepted.disposed);
    try t.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

test "owned completion allocation failure leaves payload caller owned" {
    var accounting = t.FailingAllocator.init(t.allocator, .{ .fail_index = 1 });
    const worker = try m.Worker.create(accounting.allocator());
    var log: Log = .{};
    const ticket = worker.prepareOwnedCompletion(Value, .{ .log = &log, .id = 1 }, Log.run, Log.dispose);
    const outstanding = worker.outstandingCompletions();
    try t.expect(worker.destroy());
    try t.expect(ticket == null);
    try t.expect(accounting.has_induced_failure);
    try t.expectEqual(@as(usize, 0), outstanding);
    try t.expectEqual(@as(usize, 0), log.count + log.disposed);
    try t.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

test "owned completion respects payload alignment and releases nested resources" {
    const Aligned = struct {
        bytes: []u8 align(64),
        aligned: *bool,
        disposed: *bool,
        fn run(context: ?*anyopaque, _: *m.Worker, _: u32) callconv(.c) void {
            const value: *@This() = @ptrCast(@alignCast(context.?));
            value.aligned.* = @intFromPtr(value) % @alignOf(@This()) == 0 and
                std.mem.eql(u8, value.bytes, "owned shader payload");
        }
        fn dispose(context: ?*anyopaque) callconv(.c) void {
            const value: *@This() = @ptrCast(@alignCast(context.?));
            t.allocator.free(value.bytes);
            value.disposed.* = true;
        }
    };
    const bytes = try t.allocator.dupe(u8, "owned shader payload");
    const worker = try m.Worker.create(t.allocator);
    var aligned = false;
    var disposed = false;
    const ticket = worker.prepareOwnedCompletion(Aligned, .{ .bytes = bytes, .aligned = &aligned, .disposed = &disposed }, Aligned.run, Aligned.dispose).?;
    ticket.publish(.ready);
    try t.expect(worker.destroy());
    try t.expect(aligned and disposed);
}

test "owner rollback destroys combined storage exactly once" {
    const Rollback = struct {
        log: *Log,
        outstanding_after: usize = 99,
        fn run(context: ?*anyopaque, worker: *m.Worker, _: u32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            const ticket = worker.prepareOwnedCompletion(Value, .{ .log = self.log, .id = 7 }, Log.run, Log.dispose).?;
            worker.rollbackCompletion(ticket);
            self.outstanding_after = worker.outstandingCompletions();
        }
        fn dispose(_: ?*anyopaque) callconv(.c) void {}
    };
    var accounting = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.create(accounting.allocator());
    var log: Log = .{};
    var rollback = Rollback{ .log = &log };
    worker.prepareCompletion(&rollback, Rollback.run, Rollback.dispose).?.publish(.ready);
    // Join only after rollback's owner callback ran; destroy stops admission.
    while (worker.outstandingCompletions() != 0) std.Thread.yield() catch {};
    try t.expect(worker.destroy());
    try t.expectEqual(@as(usize, 1), rollback.outstanding_after);
    try t.expectEqual(@as(usize, 1), log.cancelled);
    try t.expectEqual(@as(usize, 1), log.disposed);
    try t.expectEqual(accounting.allocated_bytes, accounting.freed_bytes);
}

test "concurrent owned completion producers keep each accepted sequence and release once" {
    const producers = 4;
    const iterations = 2000;
    const Shared = struct { next: [producers]usize = @splat(0), disposed: usize = 0, ordered: bool = true };
    const Item = struct {
        shared: *Shared,
        producer: usize,
        index: usize,
        fn run(context: ?*anyopaque, _: *m.Worker, _: u32) callconv(.c) void {
            const value: *@This() = @ptrCast(@alignCast(context.?));
            if (value.shared.next[value.producer] != value.index) value.shared.ordered = false;
            value.shared.next[value.producer] += 1;
        }
        fn dispose(context: ?*anyopaque) callconv(.c) void {
            const value: *@This() = @ptrCast(@alignCast(context.?));
            value.shared.disposed += 1;
        }
        fn produce(worker: *m.Worker, shared: *Shared, producer: usize) void {
            for (0..iterations) |index| {
                while (true) {
                    if (worker.prepareOwnedCompletion(@This(), .{ .shared = shared, .producer = producer, .index = index }, run, dispose)) |ticket| {
                        ticket.publish(.ready);
                        break;
                    }
                    std.Thread.yield() catch {};
                }
            }
        }
    };
    const worker = try m.Worker.createWithOptions(t.allocator, null, 8);
    var shared: Shared = .{};
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Item.produce, .{ worker, &shared, index });
    for (threads) |thread| thread.join();
    try t.expect(worker.destroy());
    try t.expect(shared.ordered);
    try t.expectEqual(@as(usize, producers * iterations), shared.disposed);
    for (shared.next) |count| try t.expectEqual(@as(usize, iterations), count);
}
