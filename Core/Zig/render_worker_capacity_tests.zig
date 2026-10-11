const std = @import("std");
const t = std.testing;
const m = @import("render_worker.zig");

threadlocal var scope_depth: usize = 0;
fn scope(body: m.Callback, context: ?*anyopaque) callconv(.c) void {
    scope_depth += 1;
    defer scope_depth -= 1;
    body(context);
}

const Fixture = struct {
    worker: *m.Worker,
    started: std.Thread.ResetEvent = .{},
    allowed: std.Thread.ResetEvent = .{},
    notified: std.Thread.ResetEvent = .{},
    barrier: std.Thread.ResetEvent = .{},
    notices: usize = 0,
    on_owner: bool = false,
    scoped: bool = false,
    observed_capacity: usize = 0,
    rollback_armed: bool = false,
    stop_on_barrier: bool = false,
    log: [8]u8 = @splat(0),
    count: usize = 0,

    fn cast(context: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(context.?));
    }
    fn noop(_: ?*anyopaque) callconv(.c) void {}
    fn append(self: *Fixture, value: u8) void {
        self.log[self.count] = value;
        self.count += 1;
    }
    fn notice(context: ?*anyopaque) callconv(.c) void {
        const self = cast(context);
        self.notices += 1;
        // These take the mailbox mutex: delivery must hold no worker lock.
        self.on_owner = self.worker.isWorkerThread();
        self.observed_capacity = self.worker.outstandingCompletions();
        self.scoped = scope_depth == 1;
        self.append(3);
        self.notified.set();
    }
    fn control(context: ?*anyopaque, _: *m.Worker, _: u32) callconv(.c) void {
        cast(context).append(1);
    }
    fn block(context: ?*anyopaque, _: *m.Worker, _: u64) callconv(.c) void {
        const self = cast(context);
        self.started.set();
        self.allowed.wait();
    }
    fn frame(context: ?*anyopaque, _: *m.Worker, _: u64) callconv(.c) void {
        const self = cast(context);
        self.append(2);
        if (self.stop_on_barrier) self.worker.stop();
        self.barrier.set();
    }
    fn disposeFrame(_: ?*anyopaque, _: u32) callconv(.c) void {}
    fn startBlock(self: *Fixture) !void {
        try t.expect(self.worker.submit(.{ .context = self, .run = block, .dispose = disposeFrame, .epoch = self.worker.currentEpoch() }));
        try self.started.timedWait(2 * std.time.ns_per_s);
    }
    fn submitBarrier(self: *Fixture) !void {
        try t.expect(self.worker.submit(.{ .context = self, .run = frame, .dispose = disposeFrame, .epoch = self.worker.currentEpoch() }));
    }
    fn wait(self: *Fixture) !void {
        try self.notified.timedWait(2 * std.time.ns_per_s);
    }
    fn rollback(context: ?*anyopaque, worker: *m.Worker, _: u32) callconv(.c) void {
        const self = cast(context);
        const ticket = worker.prepareCompletion(self, control, noop).?;
        self.rollback_armed = worker.notifyWhenCapacityAvailable(self, notice);
        worker.rollbackCompletion(ticket);
    }
};

test "capacity notification is one shot, coalesced, scoped and FIFO" {
    const worker = try m.Worker.createWithOptions(t.allocator, scope, 1);
    var value: Fixture = .{ .worker = worker };
    defer {
        value.allowed.set();
        _ = worker.destroy();
    }
    try value.startBlock();
    const ticket = worker.prepareCompletion(&value, Fixture.control, Fixture.noop).?;
    const armed = worker.notifyWhenCapacityAvailable(&value, Fixture.notice);
    const coalesced = worker.notifyWhenCapacityAvailable(&value, Fixture.notice);
    ticket.publish(.ready);
    try t.expect(armed and coalesced);
    try value.submitBarrier();
    value.allowed.set();
    try value.wait();
    try t.expect(value.on_owner and value.scoped);
    try t.expectEqual(@as(usize, 1), value.notices);
    try t.expectEqual(@as(usize, 0), value.observed_capacity);
    try t.expectEqualSlices(u8, &.{ 1, 2, 3 }, value.log[0..value.count]);
    try t.expect(!worker.notifyWhenCapacityAvailable(&value, Fixture.notice));
}

test "capacity released before registration requests immediate retry" {
    const worker = try m.Worker.createWithOptions(t.allocator, null, 1);
    var value: Fixture = .{ .worker = worker };
    defer {
        value.allowed.set();
        _ = worker.destroy();
    }
    try value.startBlock();
    const ticket = worker.prepareCompletion(&value, Fixture.control, Fixture.noop).?;
    ticket.publish(.ready);
    try value.submitBarrier();
    value.allowed.set();
    try value.barrier.timedWait(2 * std.time.ns_per_s);
    try t.expect(!worker.notifyWhenCapacityAvailable(&value, Fixture.notice));
    try t.expectEqual(@as(usize, 0), value.notices);
}

test "capacity registration and delivery need no allocations" {
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.createWithOptions(allocator.allocator(), null, 1);
    var value: Fixture = .{ .worker = worker };
    var destroyed = false;
    defer if (!destroyed) {
        value.allowed.set();
        _ = worker.destroy();
    };
    try value.startBlock();
    const ticket = worker.prepareCompletion(&value, Fixture.control, Fixture.noop).?;
    worker.mutex.lock();
    const allocations = allocator.alloc_index;
    allocator.fail_index = allocations;
    worker.mutex.unlock();
    const armed = worker.notifyWhenCapacityAvailable(&value, Fixture.notice);
    ticket.publish(.ready);
    try t.expect(armed);
    value.allowed.set();
    try value.wait();
    try t.expect(worker.destroy());
    destroyed = true;
    try t.expectEqual(allocations, allocator.alloc_index);
    try t.expect(!allocator.has_induced_failure);
    try t.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "stop cancels a capacity notification and drains reserved controls" {
    const worker = try m.Worker.createWithOptions(t.allocator, null, 1);
    var value: Fixture = .{ .worker = worker };
    var destroyed = false;
    defer if (!destroyed) {
        value.allowed.set();
        _ = worker.destroy();
    };
    try value.startBlock();
    const ticket = worker.prepareCompletion(&value, Fixture.control, Fixture.noop).?;
    const armed = worker.notifyWhenCapacityAvailable(&value, Fixture.notice);
    worker.stop();
    const stopped = !worker.notifyWhenCapacityAvailable(&value, Fixture.notice);
    ticket.publish(.cancelled);
    try t.expect(armed and stopped);
    value.allowed.set();
    try t.expect(worker.destroy());
    destroyed = true;
    try t.expectEqual(@as(usize, 0), value.notices);
    try t.expectEqualSlices(u8, &.{1}, value.log[0..value.count]);
}

test "owner rollback releases capacity to its waiting observer" {
    const worker = try m.Worker.createWithOptions(t.allocator, scope, 2);
    var value: Fixture = .{ .worker = worker };
    defer _ = worker.destroy();
    const ticket = worker.prepareCompletion(&value, Fixture.rollback, Fixture.noop).?;
    ticket.publish(.ready);
    try value.wait();
    try t.expect(value.rollback_armed and value.on_owner and value.scoped);
    try t.expectEqual(@as(usize, 1), value.notices);
    try t.expectEqual(@as(usize, 0), value.observed_capacity);
}

test "stop removes a capacity notification already queued behind a frame" {
    const worker = try m.Worker.createWithOptions(t.allocator, null, 1);
    var value: Fixture = .{ .worker = worker, .stop_on_barrier = true };
    var destroyed = false;
    defer if (!destroyed) {
        value.allowed.set();
        _ = worker.destroy();
    };
    try value.startBlock();
    const ticket = worker.prepareCompletion(&value, Fixture.control, Fixture.noop).?;
    const armed = worker.notifyWhenCapacityAvailable(&value, Fixture.notice);
    ticket.publish(.ready);
    try t.expect(armed);
    try value.submitBarrier();
    value.allowed.set();
    try value.barrier.timedWait(2 * std.time.ns_per_s);
    try t.expect(worker.destroy());
    destroyed = true;
    try t.expectEqual(@as(usize, 0), value.notices);
    try t.expectEqualSlices(u8, &.{ 1, 2 }, value.log[0..value.count]);
}

test "allocation failure with spare capacity does not arm a spinning retry" {
    var allocator = t.FailingAllocator.init(t.allocator, .{ .fail_index = 1 });
    const worker = try m.Worker.createWithOptions(allocator.allocator(), null, 1);
    var value: Fixture = .{ .worker = worker };
    defer _ = worker.destroy();
    try t.expect(worker.prepareCompletion(&value, Fixture.control, Fixture.noop) == null);
    try t.expect(allocator.has_induced_failure);
    try t.expect(!worker.notifyWhenCapacityAvailable(&value, Fixture.notice));
    try t.expectEqual(@as(usize, 0), value.notices);
}
