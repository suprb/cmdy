const std = @import("std");
const t = std.testing;
const m = @import("render_worker.zig");

const Notice = struct {
    worker: *m.Worker,
    entered: std.Thread.ResetEvent = .{},
    allowed: std.Thread.ResetEvent = .{},
    done: std.Thread.ResetEvent = .{},
    calls: usize = 0,
    capacity: usize = 0,
    rearm: bool = false,
    fn cast(p: ?*anyopaque) *Notice {
        return @ptrCast(@alignCast(p.?));
    }
    fn noop(_: ?*anyopaque) callconv(.c) void {}
    fn control(_: ?*anyopaque, _: *m.Worker, _: u32) callconv(.c) void {}
    fn dispose(_: ?*anyopaque, _: u32) callconv(.c) void {}
    fn block(p: ?*anyopaque, _: *m.Worker, _: u64) callconv(.c) void {
        const self = cast(p);
        self.entered.set();
        self.allowed.wait();
    }
    fn run(p: ?*anyopaque) callconv(.c) void {
        const self = cast(p);
        std.debug.assert(self.worker.isWorkerThread());
        self.calls += 1;
        self.capacity = self.worker.outstandingCompletions();
        if (self.rearm and self.calls == 1) {
            const accepted = self.worker.notifyPublication(self, run);
            std.debug.assert(accepted);
        } else self.done.set();
    }
    fn begin(self: *Notice) !void {
        try t.expect(self.worker.submit(.{ .context = self, .run = block, .dispose = dispose, .epoch = self.worker.currentEpoch() }));
        try self.entered.timedWait(2 * std.time.ns_per_s);
    }
};

test "model notification coalesces without allocations when all control slots are reserved" {
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.createWithOptions(allocator.allocator(), null, 1);
    var value: Notice = .{ .worker = worker };
    var ticket: ?*m.Completion = null;
    defer {
        if (ticket) |reserved| reserved.publish(.cancelled);
        value.allowed.set();
        _ = worker.destroy();
    }
    try value.begin();
    ticket = worker.prepareCompletion(&value, Notice.control, Notice.noop).?;
    allocator.fail_index = allocator.alloc_index;
    const before = allocator.alloc_index;
    for (0..4096) |_| try t.expect(worker.notifyPublication(&value, Notice.run));
    value.allowed.set();
    try value.done.timedWait(2 * std.time.ns_per_s);
    try t.expectEqual(@as(usize, 1), value.calls);
    try t.expectEqual(@as(usize, 1), value.capacity);
    try t.expectEqual(before, allocator.alloc_index);
    try t.expect(!allocator.has_induced_failure);
}

test "model callback can rearm itself without holding the mailbox lock" {
    const worker = try m.Worker.create(t.allocator);
    var value: Notice = .{ .worker = worker, .rearm = true };
    defer _ = worker.destroy();
    try t.expect(worker.notifyPublication(&value, Notice.run));
    try value.done.timedWait(2 * std.time.ns_per_s);
    try t.expectEqual(@as(usize, 2), value.calls);
}

test "stop removes queued model notification and refuses late publication" {
    const worker = try m.Worker.create(t.allocator);
    var value: Notice = .{ .worker = worker };
    var destroyed = false;
    defer if (!destroyed) {
        value.allowed.set();
        _ = worker.destroy();
    };
    try value.begin();
    try t.expect(worker.notifyPublication(&value, Notice.run));
    worker.stop();
    try t.expect(!worker.notifyPublication(&value, Notice.run));
    value.allowed.set();
    try t.expect(worker.destroy());
    destroyed = true;
    try t.expectEqual(@as(usize, 0), value.calls);
}
