const std = @import("std");
const testing = std.testing;
const m = @import("render_worker.zig");

const Job = struct {
    blocking: bool = false,
    started: std.Thread.ResetEvent = .{},
    allowed: std.Thread.ResetEvent = .{},
    done: std.Thread.ResetEvent = .{},
    runs: std.atomic.Value(u32) = .init(0),
    disposals: std.atomic.Value(u32) = .init(0),
    reason: std.atomic.Value(u32) = .init(999),
    current_at_end: std.atomic.Value(bool) = .init(false),
    on_worker: std.atomic.Value(bool) = .init(false),

    fn task(self: *Job, epoch: u64) m.Task {
        return .{ .context = self, .run = run, .dispose = dispose, .epoch = epoch };
    }
    fn run(context: ?*anyopaque, worker: *m.Worker, epoch: u64) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        _ = self.runs.fetchAdd(1, .monotonic);
        self.on_worker.store(worker.isWorkerThread(), .release);
        self.started.set();
        if (self.blocking) self.allowed.wait();
        self.current_at_end.store(worker.currentEpoch() == epoch, .release);
    }
    fn dispose(context: ?*anyopaque, reason: u32) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        self.reason.store(reason, .release);
        _ = self.disposals.fetchAdd(1, .release);
        self.done.set();
    }
    fn expect(self: *Job, runs: u32, reason: m.Reason) !void {
        self.done.wait();
        try testing.expectEqual(runs, self.runs.load(.acquire));
        try testing.expectEqual(@as(u32, 1), self.disposals.load(.acquire));
        try testing.expectEqual(@intFromEnum(reason), self.reason.load(.acquire));
    }
};

test "accepted task runs on the dedicated owner and is released exactly once" {
    const worker = try m.Worker.create(testing.allocator);
    defer testing.expect(worker.destroy()) catch unreachable;
    var job: Job = .{};
    try testing.expect(!worker.isWorkerThread());
    try testing.expect(worker.submit(job.task(worker.currentEpoch())));
    try job.expect(1, .executed);
    try testing.expect(job.on_worker.load(.acquire));
    try testing.expect(job.current_at_end.load(.acquire));
}

test "busy renderer retains only the newest pending frame" {
    const worker = try m.Worker.create(testing.allocator);
    var active: Job = .{ .blocking = true };
    defer {
        active.allowed.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    const epoch = worker.currentEpoch();
    var old: Job = .{};
    var latest: Job = .{};
    try testing.expect(worker.submit(active.task(epoch)));
    active.started.wait();
    try testing.expect(worker.submit(old.task(epoch)));
    try testing.expect(worker.submit(latest.task(epoch)));
    try old.expect(0, .superseded);
    try testing.expectEqual(@as(u32, 0), latest.runs.load(.acquire));
    active.allowed.set();
    try active.expect(1, .executed);
    try latest.expect(1, .executed);
}

test "resize invalidates queued inputs and the active publication token" {
    const worker = try m.Worker.create(testing.allocator);
    var active: Job = .{ .blocking = true };
    defer {
        active.allowed.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    const epoch = worker.currentEpoch();
    var old: Job = .{};
    var fresh: Job = .{};
    try testing.expect(worker.submit(active.task(epoch)));
    active.started.wait();
    try testing.expect(worker.submit(old.task(epoch)));
    const next = worker.invalidate();
    try testing.expectEqual(epoch + 1, next);
    try old.expect(0, .invalidated);
    try testing.expect(worker.submit(fresh.task(next)));
    active.allowed.set();
    try active.expect(1, .executed);
    try testing.expect(!active.current_at_end.load(.acquire));
    try fresh.expect(1, .executed);
    try testing.expect(fresh.current_at_end.load(.acquire));
}

test "rejected stale and stopped tasks remain caller-owned" {
    const worker = try m.Worker.create(testing.allocator);
    defer testing.expect(worker.destroy()) catch unreachable;
    var stale: Job = .{};
    const previous = worker.currentEpoch();
    _ = worker.invalidate();
    try testing.expect(!worker.submit(stale.task(previous)));
    try testing.expect(!worker.submit(stale.task(0)));
    try testing.expectEqual(@as(u32, 0), stale.disposals.load(.acquire));
    worker.stop();
    try testing.expectEqual(@as(u64, 0), worker.currentEpoch());
    try testing.expectEqual(@as(u64, 0), worker.invalidate());
    try testing.expect(!worker.submit(stale.task(previous + 1)));
    try testing.expectEqual(@as(u32, 0), stale.runs.load(.acquire));
    try testing.expectEqual(@as(u32, 0), stale.disposals.load(.acquire));
}

test "stop releases waiting frame while active frame can finish safely" {
    const worker = try m.Worker.create(testing.allocator);
    var active: Job = .{ .blocking = true };
    defer {
        active.allowed.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    var waiting: Job = .{};
    const epoch = worker.currentEpoch();
    try testing.expect(worker.submit(active.task(epoch)));
    active.started.wait();
    try testing.expect(worker.submit(waiting.task(epoch)));
    worker.stop();
    worker.stop();
    try waiting.expect(0, .stopped);
    active.allowed.set();
    try active.expect(1, .executed);
    try testing.expect(!active.current_at_end.load(.acquire));
}

test "a render callback can enqueue its successor without deadlocking" {
    const Reentrant = struct {
        next: *Job,
        base: Job = .{},
        accepted: std.atomic.Value(bool) = .init(false),
        fn run(context: ?*anyopaque, worker: *m.Worker, epoch: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.accepted.store(worker.submit(self.next.task(epoch)), .release);
        }
        fn dispose(context: ?*anyopaque, reason: u32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            Job.dispose(&self.base, reason);
        }
    };
    const worker = try m.Worker.create(testing.allocator);
    defer testing.expect(worker.destroy()) catch unreachable;
    var next: Job = .{};
    var first: Reentrant = .{ .next = &next };
    try testing.expect(worker.submit(.{ .context = &first, .epoch = worker.currentEpoch(), .run = Reentrant.run, .dispose = Reentrant.dispose }));
    first.base.done.wait();
    try testing.expect(first.accepted.load(.acquire));
    try next.expect(1, .executed);
}

test "superseded packet disposal can reenter the worker" {
    const Reentrant = struct {
        worker: *m.Worker,
        base: Job = .{},
        observed: u64 = 0,
        fn run(_: ?*anyopaque, _: *m.Worker, _: u64) callconv(.c) void {
            unreachable;
        }
        fn dispose(context: ?*anyopaque, reason: u32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.observed = self.worker.currentEpoch();
            Job.dispose(&self.base, reason);
        }
    };
    const worker = try m.Worker.create(testing.allocator);
    var active: Job = .{ .blocking = true };
    defer {
        active.allowed.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    const epoch = worker.currentEpoch();
    try testing.expect(worker.submit(active.task(epoch)));
    active.started.wait();
    var old: Reentrant = .{ .worker = worker };
    var next: Job = .{};
    try testing.expect(worker.submit(.{ .context = &old, .epoch = epoch, .run = Reentrant.run, .dispose = Reentrant.dispose }));
    try testing.expect(worker.submit(next.task(epoch)));
    try old.base.expect(0, .superseded);
    try testing.expectEqual(epoch, old.observed);
    active.allowed.set();
    try next.expect(1, .executed);
}

test "callback self-join is rejected and external owner can still destroy" {
    const SelfJoin = struct {
        base: Job = .{},
        rejected: std.atomic.Value(bool) = .init(false),
        fn run(context: ?*anyopaque, worker: *m.Worker, _: u64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.rejected.store(!worker.destroy(), .release);
            worker.stop();
        }
        fn dispose(context: ?*anyopaque, reason: u32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            Job.dispose(&self.base, reason);
        }
    };
    const worker = try m.Worker.create(testing.allocator);
    defer testing.expect(worker.destroy()) catch unreachable;
    var job: SelfJoin = .{};
    try testing.expect(worker.submit(.{ .context = &job, .epoch = worker.currentEpoch(), .run = SelfJoin.run, .dispose = SelfJoin.dispose }));
    job.base.done.wait();
    try testing.expect(job.rejected.load(.acquire));
}

test "generation exhaustion stops instead of accepting an old token again" {
    const worker = try m.Worker.create(testing.allocator);
    defer testing.expect(worker.destroy()) catch unreachable;
    worker.mutex.lock();
    worker.epoch = std.math.maxInt(u64);
    worker.mutex.unlock();
    try testing.expectEqual(@as(u64, 0), worker.invalidate());
    var job: Job = .{};
    try testing.expect(!worker.submit(job.task(1)));
    try testing.expectEqual(@as(u32, 0), job.disposals.load(.acquire));
}

test "a burst cannot accumulate a stale render backlog" {
    const worker = try m.Worker.create(testing.allocator);
    var active: Job = .{ .blocking = true };
    defer {
        active.allowed.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    const epoch = worker.currentEpoch();
    try testing.expect(worker.submit(active.task(epoch)));
    active.started.wait();
    var jobs: [128]Job = @splat(.{});
    for (&jobs) |*job| try testing.expect(worker.submit(job.task(epoch)));
    for (jobs[0 .. jobs.len - 1]) |*job| try job.expect(0, .superseded);
    active.allowed.set();
    try jobs[jobs.len - 1].expect(1, .executed);
}

test "destroy waits for the active owner before freeing its state" {
    const Closer = struct {
        worker: *m.Worker,
        finished: std.Thread.ResetEvent = .{},
        destroyed: bool = false,
        fn run(self: *@This()) void {
            self.destroyed = self.worker.destroy();
            self.finished.set();
        }
    };
    const worker = try m.Worker.create(testing.allocator);
    var active: Job = .{ .blocking = true };
    var waiting: Job = .{};
    const epoch = worker.currentEpoch();
    if (!worker.submit(active.task(epoch))) {
        _ = worker.destroy();
        return error.TestUnexpectedResult;
    }
    active.started.wait();
    if (!worker.submit(waiting.task(epoch))) {
        active.allowed.set();
        _ = worker.destroy();
        return error.TestUnexpectedResult;
    }
    var closer: Closer = .{ .worker = worker };
    const thread = std.Thread.spawn(.{}, Closer.run, .{&closer}) catch |err| {
        active.allowed.set();
        _ = worker.destroy();
        return err;
    };
    defer thread.join();
    defer active.allowed.set();
    try waiting.expect(0, .stopped);
    try testing.expect(!closer.finished.isSet());
    active.allowed.set();
    closer.finished.wait();
    try testing.expect(closer.destroyed);
    try active.expect(1, .executed);
}

test "a blocked terminal does not block another terminal worker" {
    const first = try m.Worker.create(testing.allocator);
    var blocked: Job = .{ .blocking = true };
    defer {
        blocked.allowed.set();
        testing.expect(first.destroy()) catch unreachable;
    }
    const second = try m.Worker.create(testing.allocator);
    defer testing.expect(second.destroy()) catch unreachable;
    try testing.expect(first.submit(blocked.task(first.currentEpoch())));
    blocked.started.wait();
    var independent: Job = .{};
    try testing.expect(second.submit(independent.task(second.currentEpoch())));
    try independent.expect(1, .executed);
    try testing.expectEqual(@as(u32, 0), blocked.disposals.load(.acquire));
}
