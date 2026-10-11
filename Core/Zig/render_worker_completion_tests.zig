const std = @import("std");
const t = std.testing;
const m = @import("render_worker.zig");
threadlocal var scope_depth: usize = 0;
fn scope(body: m.Callback, context: ?*anyopaque) callconv(.c) void {
    scope_depth += 1;
    defer scope_depth -= 1;
    body(context);
}
const Log = struct {
    items: [64]u32 = @splat(0),
    count: usize = 0,
    fn append(self: *Log, id: u32) void {
        self.items[self.count] = id;
        self.count += 1;
    }
};
const Event = struct {
    ticket: ?*m.Completion = null,
    log: ?*Log = null,
    id: u32 = 0,
    payload: usize = 0,
    observed: usize = 0,
    runs: usize = 0,
    disposals: usize = 0,
    result: u32 = 999,
    on_owner: bool = false,
    run_scoped: bool = false,
    dispose_scoped: bool = false,
    done: std.Thread.ResetEvent = .{},
    fn prepare(self: *Event, worker: *m.Worker) bool {
        self.ticket = worker.prepareCompletion(self, run, dispose);
        return self.ticket != null;
    }
    fn publish(self: *Event, result: m.CompletionResult) void {
        const ticket = self.ticket.?;
        self.ticket = null;
        ticket.publish(result);
    }
    fn cancelIfReserved(self: *Event) void {
        if (self.ticket != null) self.publish(.cancelled);
    }
    fn run(context: ?*anyopaque, worker: *m.Worker, result: u32) callconv(.c) void {
        const self: *Event = @ptrCast(@alignCast(context.?));
        self.runs += 1;
        self.result = result;
        self.observed = self.payload;
        self.on_owner = worker.isWorkerThread();
        self.run_scoped = scope_depth == 1;
        if (self.log) |log| log.append(self.id);
    }
    fn dispose(context: ?*anyopaque) callconv(.c) void {
        const self: *Event = @ptrCast(@alignCast(context.?));
        self.disposals += 1;
        self.dispose_scoped = scope_depth == 1;
        self.done.set();
    }
    fn expect(self: *Event, result: m.CompletionResult) !void {
        self.done.wait();
        try t.expectEqual(@as(usize, 1), self.runs);
        try t.expectEqual(@as(usize, 1), self.disposals);
        try t.expectEqual(@intFromEnum(result), self.result);
        try t.expect(self.on_owner);
    }
};
const Frame = struct {
    log: ?*Log = null,
    id: u32 = 0,
    blocked: bool = false,
    started: std.Thread.ResetEvent = .{},
    allowed: std.Thread.ResetEvent = .{},
    done: std.Thread.ResetEvent = .{},
    runs: usize = 0,
    reason: u32 = 999,
    run_scoped: bool = false,
    dispose_scoped: bool = false,
    fn task(self: *Frame, worker: *m.Worker) m.Task {
        return .{ .context = self, .run = run, .dispose = dispose, .epoch = worker.currentEpoch() };
    }
    fn run(context: ?*anyopaque, _: *m.Worker, _: u64) callconv(.c) void {
        const self: *Frame = @ptrCast(@alignCast(context.?));
        self.runs += 1;
        self.run_scoped = scope_depth == 1;
        if (self.log) |log| log.append(self.id);
        self.started.set();
        if (self.blocked) self.allowed.wait();
    }
    fn dispose(context: ?*anyopaque, reason: u32) callconv(.c) void {
        const self: *Frame = @ptrCast(@alignCast(context.?));
        self.reason = reason;
        self.dispose_scoped = scope_depth == 1;
        self.done.set();
    }
};

test "reserved completion delivers published data exactly once on owner" {
    const worker = try m.Worker.create(t.allocator);
    var event: Event = .{};
    defer {
        event.cancelIfReserved();
        t.expect(worker.destroy()) catch unreachable;
    }
    try t.expect(event.prepare(worker));
    try t.expectEqual(@as(usize, 1), worker.outstandingCompletions());
    event.payload = 71;
    event.publish(.ready);
    try event.expect(.ready);
    try t.expectEqual(@as(usize, 71), event.observed);
}

test "reserved cancellation runs and disposes on owner after stop" {
    const worker = try m.Worker.create(t.allocator);
    var event: Event = .{};
    var rejected: Event = .{};
    defer {
        event.cancelIfReserved();
        rejected.cancelIfReserved();
        t.expect(worker.destroy()) catch unreachable;
    }
    try t.expect(event.prepare(worker));
    worker.stop();
    try t.expect(!rejected.prepare(worker));
    try t.expectEqual(@as(usize, 0), rejected.disposals);
    event.publish(.cancelled);
    try event.expect(.cancelled);
}

test "completion capacity rejection leaves context caller owned" {
    const worker = try m.Worker.createWithOptions(t.allocator, null, 2);
    var one: Event = .{};
    var two: Event = .{};
    var rejected: Event = .{};
    defer {
        one.cancelIfReserved();
        two.cancelIfReserved();
        rejected.cancelIfReserved();
        t.expect(worker.destroy()) catch unreachable;
    }
    try t.expect(one.prepare(worker));
    try t.expect(two.prepare(worker));
    try t.expect(!rejected.prepare(worker));
    try t.expectEqual(@as(usize, 2), worker.outstandingCompletions());
    try t.expectEqual(@as(usize, 0), rejected.runs + rejected.disposals);
    one.publish(.ready);
    two.publish(.cancelled);
    try one.expect(.ready);
    try two.expect(.cancelled);
}

test "completion allocation failure takes no context ownership" {
    var failing = t.FailingAllocator.init(t.allocator, .{ .fail_index = 1 });
    const worker = try m.Worker.create(failing.allocator());
    defer t.expect(worker.destroy()) catch unreachable;
    var event: Event = .{};
    try t.expect(!event.prepare(worker));
    try t.expectEqual(@as(usize, 0), worker.outstandingCompletions());
    try t.expectEqual(@as(usize, 0), event.runs + event.disposals);
    try t.expect(failing.has_induced_failure);
}

test "publish cancel and drain perform no allocations after reservation" {
    var failing = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.create(failing.allocator());
    var one: Event = .{};
    var two: Event = .{};
    var destroyed = false;
    defer if (!destroyed) {
        one.cancelIfReserved();
        two.cancelIfReserved();
        _ = worker.destroy();
    };
    try t.expect(one.prepare(worker));
    try t.expect(two.prepare(worker));
    worker.mutex.lock();
    const allocations = failing.alloc_index;
    failing.fail_index = allocations;
    worker.mutex.unlock();
    worker.stop();
    one.publish(.ready);
    two.publish(.cancelled);
    try t.expect(worker.destroy());
    destroyed = true;
    try one.expect(.ready);
    try two.expect(.cancelled);
    try t.expectEqual(allocations, failing.alloc_index);
    try t.expect(!failing.has_induced_failure);
    try t.expectEqual(failing.allocated_bytes, failing.freed_bytes);
}

test "completion publication and frame submission preserve FIFO order" {
    const worker = try m.Worker.create(t.allocator);
    var active: Frame = .{ .blocked = true };
    var log: Log = .{};
    var first: Event = .{ .log = &log, .id = 1 };
    var last: Event = .{ .log = &log, .id = 3 };
    var middle: Frame = .{ .log = &log, .id = 2 };
    defer {
        active.allowed.set();
        first.cancelIfReserved();
        last.cancelIfReserved();
        _ = worker.destroy();
    }
    try t.expect(worker.submit(active.task(worker)));
    active.started.wait();
    try t.expect(first.prepare(worker));
    try t.expect(last.prepare(worker));
    first.publish(.ready);
    try t.expect(worker.submit(middle.task(worker)));
    last.publish(.ready);
    active.allowed.set();
    try last.expect(.ready);
    middle.done.wait();
    try t.expectEqualSlices(u32, &.{ 1, 2, 3 }, log.items[0..log.count]);
}

test "replacing pending frame moves it behind preceding completion updates" {
    const worker = try m.Worker.create(t.allocator);
    var active: Frame = .{ .blocked = true };
    var log: Log = .{};
    var old: Frame = .{};
    var latest: Frame = .{ .log = &log, .id = 2 };
    var event: Event = .{ .log = &log, .id = 1 };
    defer {
        active.allowed.set();
        event.cancelIfReserved();
        _ = worker.destroy();
    }
    try t.expect(worker.submit(active.task(worker)));
    active.started.wait();
    try t.expect(worker.submit(old.task(worker)));
    try t.expect(event.prepare(worker));
    event.publish(.ready);
    try t.expect(worker.submit(latest.task(worker)));
    old.done.wait();
    try t.expectEqual(@intFromEnum(m.Reason.superseded), old.reason);
    try t.expectEqual(@as(usize, 0), old.runs);
    active.allowed.set();
    latest.done.wait();
    try t.expectEqualSlices(u32, &.{ 1, 2 }, log.items[0..log.count]);
}

test "invalidation drops stale frame but preserves queued completions" {
    const worker = try m.Worker.create(t.allocator);
    var active: Frame = .{ .blocked = true };
    var waiting: Frame = .{};
    var event: Event = .{};
    defer {
        active.allowed.set();
        event.cancelIfReserved();
        _ = worker.destroy();
    }
    try t.expect(worker.submit(active.task(worker)));
    active.started.wait();
    try t.expect(worker.submit(waiting.task(worker)));
    try t.expect(event.prepare(worker));
    event.publish(.ready);
    _ = worker.invalidate();
    waiting.done.wait();
    try t.expectEqual(@intFromEnum(m.Reason.invalidated), waiting.reason);
    active.allowed.set();
    try event.expect(.ready);
}

test "destroy drains tickets published by independent external producers" {
    const Sender = struct {
        fn send(events: []Event) void {
            for (events) |*event| {
                event.payload = event.id + 1000;
                event.publish(if (event.id % 2 == 0) .ready else .cancelled);
            }
        }
    };
    const worker = try m.Worker.create(t.allocator);
    var events: [32]Event = @splat(.{});
    for (&events, 0..) |*event, index| {
        event.id = @intCast(index);
        try t.expect(event.prepare(worker));
    }
    worker.stop();
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| thread.* = try std.Thread.spawn(.{}, Sender.send, .{events[index * 8 ..][0..8]});
    try t.expect(worker.destroy());
    for (threads) |thread| thread.join();
    for (&events) |*event| {
        try event.expect(if (event.id % 2 == 0) .ready else .cancelled);
        try t.expectEqual(@as(usize, event.id + 1000), event.observed);
    }
}

test "completion callback can reserve publish invalidate and stop without deadlock" {
    const Reentrant = struct {
        next: *Event,
        done: std.Thread.ResetEvent = .{},
        rejected_join: bool = false,
        fn run(context: ?*anyopaque, worker: *m.Worker, _: u32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(self.next.prepare(worker));
            self.next.publish(.ready);
            _ = worker.invalidate();
            self.rejected_join = !worker.destroy();
            worker.stop();
        }
        fn dispose(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.done.set();
        }
    };
    const worker = try m.Worker.create(t.allocator);
    defer _ = worker.destroy();
    var next: Event = .{};
    var initial: Reentrant = .{ .next = &next };
    const ticket = worker.prepareCompletion(&initial, Reentrant.run, Reentrant.dispose).?;
    ticket.publish(.ready);
    initial.done.wait();
    try next.expect(.ready);
    try t.expect(initial.rejected_join);
}

test "callback scope encloses frame completion and producer-side disposal" {
    const worker = try m.Worker.createWithOptions(t.allocator, scope, 8);
    var active: Frame = .{ .blocked = true };
    var old: Frame = .{};
    var latest: Frame = .{};
    var event: Event = .{};
    defer {
        active.allowed.set();
        event.cancelIfReserved();
        _ = worker.destroy();
    }
    try t.expect(worker.submit(active.task(worker)));
    active.started.wait();
    try t.expect(worker.submit(old.task(worker)));
    try t.expect(worker.submit(latest.task(worker)));
    old.done.wait();
    try t.expect(old.dispose_scoped);
    try t.expect(event.prepare(worker));
    event.publish(.ready);
    active.allowed.set();
    try event.expect(.ready);
    active.done.wait();
    latest.done.wait();
    try t.expect(active.run_scoped and active.dispose_scoped and latest.run_scoped and latest.dispose_scoped);
    try t.expect(event.run_scoped and event.dispose_scoped);
    try t.expectEqual(@as(usize, 0), scope_depth);
}

test "epoch exhaustion still drains a previously reserved completion" {
    const worker = try m.Worker.create(t.allocator);
    var event: Event = .{};
    defer {
        event.cancelIfReserved();
        _ = worker.destroy();
    }
    try t.expect(event.prepare(worker));
    worker.mutex.lock();
    worker.epoch = std.math.maxInt(u64);
    worker.mutex.unlock();
    try t.expectEqual(@as(u64, 0), worker.invalidate());
    event.publish(.ready);
    try event.expect(.ready);
}
