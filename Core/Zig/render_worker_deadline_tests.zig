const std = @import("std");
const t = std.testing;
const m = @import("render_worker.zig");

threadlocal var scope_depth: usize = 0;
fn scope(body: m.Callback, context: ?*anyopaque) callconv(.c) void {
    scope_depth += 1;
    defer scope_depth -= 1;
    body(context);
}

const Mode = enum { single, replace, ordered, queued_cancel, saturated, rearm, stop };
const Fixture = struct {
    worker: *m.Worker,
    mode: Mode,
    ready: std.Thread.ResetEvent = .{},
    allowed: std.Thread.ResetEvent = .{},
    done: std.Thread.ResetEvent = .{},
    late: ?*m.Completion = null,
    fired: usize = 0,
    obsolete: usize = 0,
    log: [8]u32 = @splat(0),
    count: usize = 0,
    on_owner: bool = false,
    scoped: bool = false,
    arm_ok: bool = false,
    capacity_rejected: bool = false,

    fn append(self: *Fixture, value: u32) void {
        self.log[self.count] = value;
        self.count += 1;
    }
    fn cast(context: ?*anyopaque) *Fixture {
        return @ptrCast(@alignCast(context.?));
    }
    fn noop(_: ?*anyopaque) callconv(.c) void {}
    fn obsoleteWake(context: ?*anyopaque) callconv(.c) void {
        cast(context).obsolete += 1;
    }
    fn wake(context: ?*anyopaque) callconv(.c) void {
        const self = cast(context);
        self.fired += 1;
        self.on_owner = self.worker.isWorkerThread();
        self.scoped = scope_depth == 1;
        if (self.mode == .ordered) {
            self.append(3);
        } else if (self.mode == .rearm and self.fired < 5) {
            self.arm_ok = self.arm_ok and self.worker.armWakeup(0, self, wake);
            if (!self.arm_ok) self.done.set();
        } else self.done.set();
    }
    fn install(context: ?*anyopaque, worker: *m.Worker, _: u32) callconv(.c) void {
        const self = cast(context);
        switch (self.mode) {
            .replace => {
                self.arm_ok = worker.armWakeup(0, self, obsoleteWake);
                worker.cancelWakeup();
                self.arm_ok = self.arm_ok and worker.armWakeup(0, self, obsoleteWake);
                self.arm_ok = self.arm_ok and worker.armWakeup(std.time.ns_per_ms, self, wake);
            },
            .stop => self.arm_ok = worker.armWakeup(3600 * std.time.ns_per_s, self, wake),
            .single, .saturated => self.arm_ok = worker.armWakeup(std.time.ns_per_ms, self, wake),
            else => self.arm_ok = worker.armWakeup(0, self, wake),
        }
        if (self.mode == .saturated) {
            const unexpected = worker.prepareCompletion(self, install, noop);
            self.capacity_rejected = unexpected == null;
            if (unexpected) |value| value.publish(.cancelled);
        }
        self.ready.set();
        if (self.mode == .ordered or self.mode == .queued_cancel) self.allowed.wait();
    }
    fn first(context: ?*anyopaque, worker: *m.Worker, _: u32) callconv(.c) void {
        const self = cast(context);
        self.append(1);
        if (self.mode == .ordered) {
            const ticket = self.late.?;
            self.late = null;
            ticket.publish(.ready);
        } else worker.cancelWakeup();
    }
    fn second(context: ?*anyopaque, _: *m.Worker, _: u32) callconv(.c) void {
        const self = cast(context);
        self.append(2);
        if (self.mode == .queued_cancel) self.done.set();
    }
    fn last(context: ?*anyopaque, _: *m.Worker, _: u32) callconv(.c) void {
        const self = cast(context);
        self.append(4);
        self.done.set();
    }
    fn start(self: *Fixture) !void {
        const ticket = self.worker.prepareCompletion(self, install, noop) orelse return error.NoCapacity;
        ticket.publish(.ready);
        try self.ready.timedWait(2 * std.time.ns_per_s);
    }
    fn wait(self: *Fixture) !void {
        try self.done.timedWait(2 * std.time.ns_per_s);
    }
};

test "owner deadline wakes an idle worker in its callback scope" {
    const worker = try m.Worker.createWithOptions(t.allocator, scope, 2);
    var value: Fixture = .{ .worker = worker, .mode = .single };
    defer _ = worker.destroy();
    try value.start();
    try value.wait();
    try t.expect(value.on_owner and value.scoped);
    try t.expectEqual(@as(usize, 1), value.fired);
}

test "owner deadline cancellation and replacement suppress obsolete callbacks" {
    const worker = try m.Worker.create(t.allocator);
    var value: Fixture = .{ .worker = worker, .mode = .replace };
    defer _ = worker.destroy();
    try value.start();
    try value.wait();
    try t.expectEqual(@as(usize, 0), value.obsolete);
    try t.expectEqual(@as(usize, 1), value.fired);
}

test "expired deadline preserves accepted FIFO controls and precedes later arrivals" {
    const worker = try m.Worker.create(t.allocator);
    var value: Fixture = .{ .worker = worker, .mode = .ordered };
    defer {
        value.allowed.set();
        _ = worker.destroy();
    }
    try value.start();
    const one = worker.prepareCompletion(&value, Fixture.first, Fixture.noop).?;
    const two = worker.prepareCompletion(&value, Fixture.second, Fixture.noop).?;
    value.late = worker.prepareCompletion(&value, Fixture.last, Fixture.noop).?;
    one.publish(.ready);
    two.publish(.ready);
    value.allowed.set();
    try value.wait();
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, value.log[0..value.count]);
    try t.expectEqual(@as(usize, 1), value.fired);
}

test "accepted control cancels a deadline already waiting in the FIFO" {
    const worker = try m.Worker.create(t.allocator);
    var value: Fixture = .{ .worker = worker, .mode = .queued_cancel };
    defer {
        value.allowed.set();
        _ = worker.destroy();
    }
    try value.start();
    const one = worker.prepareCompletion(&value, Fixture.first, Fixture.noop).?;
    const two = worker.prepareCompletion(&value, Fixture.second, Fixture.noop).?;
    one.publish(.ready);
    two.publish(.ready);
    value.allowed.set();
    try value.wait();
    try t.expectEqualSlices(u32, &.{ 1, 2 }, value.log[0..value.count]);
    try t.expectEqual(@as(usize, 0), value.fired);
}

test "deadline requires neither allocator nor completion capacity after admission" {
    var allocator = t.FailingAllocator.init(t.allocator, .{});
    const worker = try m.Worker.createWithOptions(allocator.allocator(), null, 1);
    var value: Fixture = .{ .worker = worker, .mode = .saturated };
    var destroyed = false;
    defer if (!destroyed) {
        _ = worker.destroy();
    };
    const ticket = worker.prepareCompletion(&value, Fixture.install, Fixture.noop).?;
    const count = allocator.alloc_index;
    allocator.fail_index = count;
    ticket.publish(.ready);
    try value.wait();
    try t.expect(worker.destroy());
    destroyed = true;
    try t.expect(value.arm_ok and value.capacity_rejected);
    try t.expectEqual(count, allocator.alloc_index);
    try t.expect(!allocator.has_induced_failure);
    try t.expectEqual(allocator.allocated_bytes, allocator.freed_bytes);
}

test "deadline can rearm itself on the owner without another producer" {
    const worker = try m.Worker.create(t.allocator);
    var value: Fixture = .{ .worker = worker, .mode = .rearm };
    defer _ = worker.destroy();
    try value.start();
    try value.wait();
    try t.expect(value.arm_ok and value.on_owner);
    try t.expectEqual(@as(usize, 5), value.fired);
}

test "worker shutdown cancels a future deadline without waiting for it" {
    const worker = try m.Worker.create(t.allocator);
    var value: Fixture = .{ .worker = worker, .mode = .stop };
    var destroyed = false;
    defer if (!destroyed) {
        _ = worker.destroy();
    };
    try value.start();
    try t.expect(worker.destroy());
    destroyed = true;
    try t.expectEqual(@as(usize, 0), value.fired);
}
