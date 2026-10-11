const std = @import("std");
const testing = std.testing;
const m = @import("render_worker.zig");

const Job = struct {
    preparing: std.Thread.ResetEvent = .{},
    allow_prepare: std.Thread.ResetEvent = .{},
    publishing: std.Thread.ResetEvent = .{},
    allow_publish: std.Thread.ResetEvent = .{},
    done: std.Thread.ResetEvent = .{},
    close_flag: std.atomic.Value(bool) = .init(false),
    accepted: bool = false,
    committed: bool = false,
    order: *std.atomic.Value(u32),
    committed_order: u32 = 0,
    fn task(self: *Job, epoch: u64) m.Task {
        return .{ .context = self, .epoch = epoch, .run = run, .dispose = dispose };
    }
    fn run(context: ?*anyopaque, worker: *m.Worker, epoch: u64) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        self.preparing.set();
        self.allow_prepare.wait();
        self.accepted = worker.beginPublication(epoch);
        if (!self.accepted) return;
        defer worker.endPublication();
        if (self.close_flag.load(.acquire)) return;
        self.publishing.set();
        self.allow_publish.wait();
        self.committed = true;
        self.committed_order = self.order.fetchAdd(1, .seq_cst) + 1;
    }
    fn dispose(context: ?*anyopaque, _: u32) callconv(.c) void {
        const self: *Job = @ptrCast(@alignCast(context.?));
        self.done.set();
    }
};

test "invalidation finishes during preparation and rejects its final publication" {
    const worker = try m.Worker.create(testing.allocator);
    var order: std.atomic.Value(u32) = .init(0);
    var job: Job = .{ .order = &order };
    defer {
        job.allow_prepare.set();
        job.allow_publish.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    try testing.expect(worker.submit(job.task(1)));
    job.preparing.wait();
    try testing.expectEqual(@as(u64, 2), worker.invalidate());
    job.allow_prepare.set();
    job.done.wait();
    try testing.expect(!job.accepted and !job.committed);
}

test "stop finishes during preparation and rejects its final publication" {
    const worker = try m.Worker.create(testing.allocator);
    var order: std.atomic.Value(u32) = .init(0);
    var job: Job = .{ .order = &order };
    defer {
        job.allow_prepare.set();
        job.allow_publish.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    try testing.expect(worker.submit(job.task(1)));
    job.preparing.wait();
    worker.stop();
    job.allow_prepare.set();
    job.done.wait();
    try testing.expect(!job.accepted and !job.committed);
}

const Invalidator = struct {
    worker: *m.Worker,
    order: *std.atomic.Value(u32),
    started: std.Thread.ResetEvent = .{},
    result: u64 = 0,
    returned_order: u32 = 0,
    fn run(self: *Invalidator) void {
        self.started.set();
        self.result = self.worker.invalidate();
        self.returned_order = self.order.fetchAdd(1, .seq_cst) + 1;
    }
};

test "final publication and invalidation have a single total order" {
    const worker = try m.Worker.create(testing.allocator);
    var order: std.atomic.Value(u32) = .init(0);
    var job: Job = .{ .order = &order };
    defer {
        job.allow_prepare.set();
        job.allow_publish.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    job.allow_prepare.set();
    try testing.expect(worker.submit(job.task(1)));
    job.publishing.wait();
    const obtained = worker.publication.tryLock();
    if (obtained) worker.publication.unlock();
    try testing.expect(!obtained);
    var invalidator: Invalidator = .{ .worker = worker, .order = &order };
    const thread = try std.Thread.spawn(.{}, Invalidator.run, .{&invalidator});
    invalidator.started.wait();
    job.allow_publish.set();
    job.done.wait();
    thread.join();
    try testing.expect(job.committed and invalidator.result == 2);
    try testing.expectEqual(@as(u32, 1), job.committed_order);
    try testing.expectEqual(@as(u32, 2), invalidator.returned_order);
}

const Callback = struct {
    done: std.Thread.ResetEvent = .{},
    result: u32 = 999,
    disposed: bool = false,
    fn run(context: ?*anyopaque, worker: *m.Worker, result: u32) callconv(.c) void {
        const self: *Callback = @ptrCast(@alignCast(context.?));
        std.debug.assert(worker.isWorkerThread());
        self.result = result;
    }
    fn dispose(context: ?*anyopaque) callconv(.c) void {
        const self: *Callback = @ptrCast(@alignCast(context.?));
        self.disposed = true;
        self.done.set();
    }
};

test "completion publication and mailbox queries work while final publication is held" {
    const worker = try m.Worker.create(testing.allocator);
    var order: std.atomic.Value(u32) = .init(0);
    var job: Job = .{ .order = &order };
    defer {
        job.allow_prepare.set();
        job.allow_publish.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    var callback: Callback = .{};
    const ticket = worker.prepareCompletion(&callback, Callback.run, Callback.dispose).?;
    job.allow_prepare.set();
    try testing.expect(worker.submit(job.task(1)));
    job.publishing.wait();
    try testing.expectEqual(@as(u64, 1), worker.currentEpoch());
    ticket.publish(.ready);
    try testing.expectEqual(@as(usize, 1), worker.outstandingCompletions());
    job.allow_publish.set();
    callback.done.wait();
    try testing.expect(callback.disposed and callback.result == 0);
}

test "off-owner publication is rejected and renderer close is ordered and idempotent" {
    const worker = try m.Worker.create(testing.allocator);
    var order: std.atomic.Value(u32) = .init(0);
    var job: Job = .{ .order = &order };
    defer {
        job.allow_prepare.set();
        job.allow_publish.set();
        testing.expect(worker.destroy()) catch unreachable;
    }
    try testing.expect(!worker.beginPublication(1));
    try testing.expect(worker.submit(job.task(1)));
    job.preparing.wait();
    try testing.expect(worker.closePublication(&job.close_flag));
    try testing.expect(!worker.closePublication(&job.close_flag));
    job.allow_prepare.set();
    job.done.wait();
    try testing.expect(job.accepted and !job.committed);
}

const Rollback = struct {
    done: std.Thread.ResetEvent = .{},
    callback: Callback = .{},
    count_after: usize = 99,
    fn run(context: ?*anyopaque, worker: *m.Worker, _: u64) callconv(.c) void {
        const self: *Rollback = @ptrCast(@alignCast(context.?));
        const ticket = worker.prepareCompletion(&self.callback, Callback.run, Callback.dispose).?;
        worker.rollbackCompletion(ticket);
        self.count_after = worker.outstandingCompletions();
        std.debug.assert(self.callback.disposed and self.callback.result == 1);
    }
    fn dispose(context: ?*anyopaque, _: u32) callconv(.c) void {
        const self: *Rollback = @ptrCast(@alignCast(context.?));
        self.done.set();
    }
};
test "unlaunched completion rollback releases its slot before the current frame returns" {
    const worker = try m.Worker.createWithOptions(testing.allocator, null, 1);
    defer testing.expect(worker.destroy()) catch unreachable;
    var rollback: Rollback = .{};
    try testing.expect(worker.submit(.{ .context = &rollback, .epoch = 1, .run = Rollback.run, .dispose = Rollback.dispose }));
    rollback.done.wait();
    try testing.expectEqual(@as(usize, 0), rollback.count_after);
    var second: Callback = .{};
    const ticket = worker.prepareCompletion(&second, Callback.run, Callback.dispose).?;
    ticket.publish(.cancelled);
    second.done.wait();
    try testing.expect(second.result == 1 and second.disposed);
}
