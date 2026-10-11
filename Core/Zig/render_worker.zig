//! One rendering thread and at most one waiting frame per terminal.
//!
//! An accepted task transfers its context to the worker until `dispose` runs
//! exactly once. Rejected tasks remain the caller's responsibility. Callbacks
//! never run under the mailbox mutex; disposal may run on either the submitting
//! thread or the worker. Packet owners must support release on either thread.
//!
//! Reserve a completion before launching asynchronous work. Publishing/cancelling
//! its one-shot ticket allocates nothing and remains valid after frame stop.
//! Destroy drains all reserved tickets before joining. Callers must eventually
//! publish or cancel every ticket, including on a failed external launch.
//! Stop frame producers before destroy. A callback may submit, invalidate or
//! stop; it must not destroy/join its worker.
const std = @import("std");

pub const Run = *const fn (?*anyopaque, *Worker, u64) callconv(.c) void;
pub const Dispose = *const fn (?*anyopaque, u32) callconv(.c) void;
pub const Callback = *const fn (?*anyopaque) callconv(.c) void;
pub const Scope = *const fn (Callback, ?*anyopaque) callconv(.c) void;
/// Optional one-shot wakeup hint. Arm/cancel must not synchronously call back
/// or wait for a callback: both run under the mailbox lock. Destroy drains all
/// callbacks and runs after the worker joins, before its context is freed.
pub const WakeupDriver = struct {
    context: ?*anyopaque,
    arm: *const fn (?*anyopaque, u64) callconv(.c) void,
    cancel: Callback,
    destroy: Callback,
};
pub const CompletionRun = *const fn (?*anyopaque, *Worker, u32) callconv(.c) void;
pub const CompletionResult = enum(u32) { ready = 0, cancelled = 1 };
pub const Reason = enum(u32) { executed = 0, superseded = 1, invalidated = 2, stopped = 3 };
pub const Task = struct {
    context: ?*anyopaque,
    run: Run,
    dispose: Dispose,
    epoch: u64,

    fn release(self: Task, reason: Reason) void {
        self.dispose(self.context, @intFromEnum(reason));
    }
};

const Node = struct {
    previous: ?*Node = null,
    next: ?*Node = null,
    completion: ?*Completion = null,
};

const Wakeup = struct {
    started: std.time.Instant,
    delay_ns: u64,
    context: ?*anyopaque,
    run: Callback,
    queued: bool = false,

    fn remaining(self: Wakeup) u64 {
        // An unavailable clock after admission makes the wakeup eligible;
        // it must not leave shutdown or pending scheduler work waiting forever.
        const now = std.time.Instant.now() catch return 0;
        return self.delay_ns -| now.since(self.started);
    }
};

const CapacityNotice = struct {
    context: ?*anyopaque,
    run: Callback,
    queued: bool = false,
};

pub const Completion = struct {
    worker: *Worker,
    context: ?*anyopaque,
    run: CompletionRun,
    dispose: Callback,
    destroy_storage: *const fn (*Completion, std.mem.Allocator) void = destroyDefault,
    node: Node = .{},
    state: enum { reserved, queued, running } = .reserved,
    result: CompletionResult = .ready,

    /// Consumes this ticket. Do not touch it again, even before this call returns.
    pub fn publish(self: *Completion, result: CompletionResult) void {
        const owner = self.worker;
        owner.mutex.lock();
        std.debug.assert(self.state == .reserved);
        self.state = .queued;
        self.result = result;
        owner.append(&self.node);
        owner.changed.signal();
        owner.mutex.unlock();
    }

    fn invoke(context: ?*anyopaque) callconv(.c) void {
        const self: *Completion = @ptrCast(@alignCast(context.?));
        self.run(self.context, self.worker, @intFromEnum(self.result));
        self.dispose(self.context);
    }

    fn destroyDefault(self: *Completion, allocator: std.mem.Allocator) void {
        allocator.destroy(self);
    }
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    // Serializes only final external publication against invalidate/stop/close.
    // It never covers row preparation and is separate from the mailbox so a
    // Metal completion can publish its reserved ticket during commit.
    publication: std.Thread.Mutex = .{},
    changed: std.Thread.Condition = .{},
    thread: ?std.Thread = null,
    thread_id: ?std.Thread.Id = null,
    pending: ?Task = null,
    frame_node: Node = .{},
    wakeup_node: Node = .{},
    wakeup: ?Wakeup = null,
    wakeup_driver: ?WakeupDriver = null,
    precise_wakeup_armed: bool = false,
    capacity_node: Node = .{},
    capacity_notice: ?CapacityNotice = null,
    publication_node: Node = .{},
    publication_notice: ?CapacityNotice = null,
    head: ?*Node = null,
    tail: ?*Node = null,
    completion_count: usize = 0,
    completion_capacity: usize = 1024,
    scope: ?Scope = null,
    epoch: u64 = 1,
    stopped: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*Worker {
        return createWithOptions(allocator, null, 1024);
    }

    pub fn createWithOptions(allocator: std.mem.Allocator, scope: ?Scope, completion_capacity: usize) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .scope = scope, .completion_capacity = completion_capacity };
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
        return self;
    }

    /// A token for immutable inputs captured during the current surface epoch.
    /// Zero means stopped. This is a snapshot, not a GPU presentation fence.
    pub fn currentEpoch(self: *Worker) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return if (self.stopped) 0 else self.epoch;
    }

    /// Owner-only final publication boundary. On success the caller must call
    /// endPublication, and must not synchronously invalidate/stop/close from
    /// inside it. Only the fixed external commit belongs here, not host code.
    pub fn beginPublication(self: *Worker, epoch: u64) bool {
        self.publication.lock();
        self.mutex.lock();
        const valid = !self.stopped and epoch != 0 and epoch == self.epoch and
            self.thread_id != null and self.thread_id.? == std.Thread.getCurrentId();
        self.mutex.unlock();
        if (!valid) self.publication.unlock();
        return valid;
    }
    pub fn endPublication(self: *Worker) void {
        self.publication.unlock();
    }
    /// Change host content/scalars without invalidating the surface or its
    /// caches. The final commit checks this token under the same short lock.
    /// The caller serializes producers and handles zero without recycling it.
    pub fn advanceRevision(self: *Worker, revision: *std.atomic.Value(u64)) u64 {
        self.publication.lock();
        defer self.publication.unlock();
        const current = revision.load(.acquire);
        if (current == std.math.maxInt(u64)) return 0;
        revision.store(current + 1, .release);
        return current + 1;
    }
    /// Linearize an owned renderer's close request with final publication.
    /// The caller publishes its already-reserved close ticket after this call.
    pub fn closePublication(self: *Worker, flag: *std.atomic.Value(bool)) bool {
        self.publication.lock();
        defer self.publication.unlock();
        return !flag.swap(true, .acq_rel);
    }

    /// The active task may finish; only the newest waiting task is retained.
    pub fn submit(self: *Worker, task: Task) bool {
        self.mutex.lock();
        if (self.stopped or task.epoch == 0 or task.epoch != self.epoch) {
            self.mutex.unlock();
            return false;
        }
        const previous = self.pending;
        if (previous != null) self.remove(&self.frame_node);
        self.pending = task;
        // Move a replaced frame behind already-published completion/control
        // work. New completions cannot indefinitely overtake a waiting frame.
        self.append(&self.frame_node);
        self.changed.signal();
        self.mutex.unlock();
        if (previous) |old| self.invokeFrame(old, false, .superseded);
        return true;
    }

    /// On success context ownership transfers until the worker calls dispose.
    /// On failure (stopped, capacity or allocation) the caller still owns it.
    pub fn prepareCompletion(self: *Worker, context: ?*anyopaque, run: CompletionRun, dispose: Callback) ?*Completion {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped or self.completion_count >= self.completion_capacity) return null;
        const completion = self.allocator.create(Completion) catch return null;
        completion.* = .{ .worker = self, .context = context, .run = run, .dispose = dispose };
        completion.node.completion = completion;
        self.completion_count += 1;
        return completion;
    }

    /// Store a copied payload and its ticket in one allocation. Success adopts
    /// value's resources; rejection leaves them with the caller. The callbacks
    /// borrow the stored value. Dispose releases only resources inside value;
    /// the worker frees the combined storage after both callbacks return.
    pub fn prepareOwnedCompletion(self: *Worker, comptime T: type, value: T, run: CompletionRun, dispose: Callback) ?*Completion {
        const Storage = struct {
            completion: Completion,
            value: T,
            fn destroy(completion: *Completion, allocator: std.mem.Allocator) void {
                const storage: *@This() = @alignCast(@fieldParentPtr("completion", completion));
                allocator.destroy(storage);
            }
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped or self.completion_count >= self.completion_capacity) return null;
        const storage = self.allocator.create(Storage) catch return null;
        storage.* = .{
            .completion = .{ .worker = self, .context = &storage.value, .run = run, .dispose = dispose, .destroy_storage = Storage.destroy },
            .value = value,
        };
        storage.completion.node.completion = &storage.completion;
        self.completion_count += 1;
        return &storage.completion;
    }

    pub fn outstandingCompletions(self: *Worker) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.completion_count;
    }

    /// Arm one allocation-free notification after a full completion queue frees
    /// capacity. Repeated registration by the same observer is coalesced. False
    /// means capacity is already available (retry now), or the worker stopped.
    /// Registration and capacity release share the mailbox lock, so the caller
    /// cannot miss a release between its rejected submission and registration.
    /// The sole observer owns context until its callback, stop or worker join.
    /// Like other callbacks, an already executing notification may finish after
    /// stop. Delivery runs on the scoped owner, outside the mailbox lock.
    pub fn notifyWhenCapacityAvailable(self: *Worker, context: ?*anyopaque, run: Callback) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return false;
        if (self.capacity_notice) |notice| {
            std.debug.assert(notice.context == context and notice.run == run);
            return true;
        }
        if (self.completion_count < self.completion_capacity) return false;
        self.capacity_notice = .{ .context = context, .run = run };
        return true;
    }

    fn queueCapacityNoticeLocked(self: *Worker) void {
        if (self.stopped or self.completion_count >= self.completion_capacity) return;
        if (self.capacity_notice) |*notice| {
            if (!notice.queued) {
                notice.queued = true;
                self.append(&self.capacity_node);
            }
        }
    }

    fn clearCapacityNoticeLocked(self: *Worker) void {
        if (self.capacity_notice) |notice| if (notice.queued) self.remove(&self.capacity_node);
        self.capacity_notice = null;
    }

    /// One coalesced producer notification independent of control capacity.
    /// The session owns context until stop/join. Delivery runs outside the
    /// mutex; posting/replacement allocates nothing and never uses a timer.
    pub fn notifyPublication(self: *Worker, context: ?*anyopaque, run: Callback) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return false;
        if (self.publication_notice) |notice| {
            std.debug.assert(notice.context == context and notice.run == run);
            return true;
        }
        self.publication_notice = .{ .context = context, .run = run, .queued = true };
        self.append(&self.publication_node);
        self.changed.signal();
        return true;
    }
    fn clearPublicationNoticeLocked(self: *Worker) void {
        if (self.publication_notice != null) self.remove(&self.publication_node);
        self.publication_notice = null;
    }

    /// Replace the owner's one-shot wakeup without allocating a control ticket.
    /// The caller owns context until cancellation, execution or worker join.
    /// An expired wakeup enters the FIFO behind already accepted controls and
    /// cannot be overtaken indefinitely by subsequently submitted controls.
    /// Only the owner may arm/cancel; stop cancels a wakeup that has not begun.
    pub fn armWakeup(self: *Worker, delay_ns: u64, context: ?*anyopaque, run: Callback) bool {
        return self.armWakeupWithPrecision(delay_ns, context, run, false);
    }

    /// The ordinary monotonic deadline, condition timeout and FIFO stay
    /// authoritative. A platform hint only wakes a due precise deadline.
    pub fn armWakeupWithPrecision(self: *Worker, delay_ns: u64, context: ?*anyopaque, run: Callback, precise: bool) bool {
        std.debug.assert(self.isWorkerThread());
        const started = std.time.Instant.now() catch return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped) return false;
        self.clearWakeupLocked();
        self.wakeup = .{ .started = started, .delay_ns = delay_ns, .context = context, .run = run };
        if (precise) if (self.wakeup_driver) |driver| {
            self.precise_wakeup_armed = true;
            driver.arm(driver.context, delay_ns);
        };
        return true;
    }

    /// Transfers ownership only on success. Installed lazily by the owner;
    /// failure leaves the platform driver with its caller for disposal.
    pub fn installWakeupDriver(self: *Worker, driver: WakeupDriver) bool {
        std.debug.assert(self.isWorkerThread());
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped or self.wakeup_driver != null) return false;
        self.wakeup_driver = driver;
        return true;
    }

    /// Safe from the driver's queue until its destroy callback has drained.
    /// Early, stale, cancelled and non-precise hints cannot enqueue work.
    pub fn signalDueWakeup(self: *Worker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped or !self.precise_wakeup_armed) return false;
        const value = self.wakeup orelse return false;
        if (value.queued or value.remaining() != 0) return false;
        self.changed.signal();
        return true;
    }

    fn cancelPreciseWakeupLocked(self: *Worker) void {
        if (!self.precise_wakeup_armed) return;
        self.precise_wakeup_armed = false;
        if (self.wakeup_driver) |driver| driver.cancel(driver.context);
    }

    pub fn cancelWakeup(self: *Worker) void {
        std.debug.assert(self.isWorkerThread());
        self.mutex.lock();
        defer self.mutex.unlock();
        self.clearWakeupLocked();
    }

    fn clearWakeupLocked(self: *Worker) void {
        self.cancelPreciseWakeupLocked();
        if (self.wakeup) |value| if (value.queued) self.remove(&self.wakeup_node);
        self.wakeup = null;
    }

    fn queueExpiredWakeupLocked(self: *Worker) void {
        if (self.stopped) return;
        if (self.wakeup) |*value| {
            if (!value.queued and value.remaining() == 0) {
                value.queued = true;
                self.append(&self.wakeup_node);
            }
        }
    }

    /// Owner-only rollback when external work was never launched. Unlike a
    /// published completion, this unqueued reservation is cancelled immediately
    /// so an already-waiting frame does not observe a phantom in-flight slot.
    /// The caller guarantees no external producer can publish this ticket.
    pub fn rollbackCompletion(self: *Worker, completion: *Completion) void {
        std.debug.assert(self.isWorkerThread());
        self.mutex.lock();
        std.debug.assert(completion.worker == self and completion.state == .reserved);
        completion.state = .running;
        completion.result = .cancelled;
        self.mutex.unlock();
        self.invoke(Completion.invoke, completion);
        self.mutex.lock();
        completion.destroy_storage(completion, self.allocator);
        self.completion_count -= 1;
        self.queueCapacityNoticeLocked();
        self.changed.signal();
        self.mutex.unlock();
    }

    /// Resize/source replacement invalidates queued old-surface inputs. Active
    /// work can observe the new epoch before publishing its result. Final native
    /// GPU commits use beginPublication and cannot cross this transition.
    pub fn invalidate(self: *Worker) u64 {
        self.publication.lock();
        self.mutex.lock();
        if (self.stopped) {
            self.mutex.unlock();
            self.publication.unlock();
            return 0;
        }
        const previous = self.pending;
        if (previous != null) self.remove(&self.frame_node);
        self.pending = null;
        if (self.epoch == std.math.maxInt(u64)) {
            // Never recycle a token while an old packet may still exist.
            self.stopped = true;
            self.clearWakeupLocked();
            self.clearCapacityNoticeLocked();
            self.clearPublicationNoticeLocked();
            self.changed.signal();
        } else self.epoch += 1;
        const result = if (self.stopped) 0 else self.epoch;
        self.mutex.unlock();
        self.publication.unlock();
        if (previous) |old| self.invokeFrame(old, false, .invalidated);
        return result;
    }

    pub fn stop(self: *Worker) void {
        self.publication.lock();
        self.mutex.lock();
        self.stopped = true;
        self.clearWakeupLocked();
        self.clearCapacityNoticeLocked();
        self.clearPublicationNoticeLocked();
        const previous = self.pending;
        if (previous != null) self.remove(&self.frame_node);
        self.pending = null;
        self.changed.signal();
        self.mutex.unlock();
        self.publication.unlock();
        if (previous) |old| self.invokeFrame(old, false, .stopped);
    }

    pub fn isWorkerThread(self: *Worker) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.thread_id != null and self.thread_id.? == std.Thread.getCurrentId();
    }

    /// Returns false on the worker thread instead of attempting a self-join.
    /// In that case the external owner remains responsible for destruction.
    pub fn destroy(self: *Worker) bool {
        if (self.isWorkerThread()) return false;
        self.stop();
        self.thread.?.join();
        // A queued platform callback can still inspect the stopped mailbox.
        // Drain it while this allocation and its mutex are still alive.
        if (self.wakeup_driver) |driver| driver.destroy(driver.context);
        const allocator = self.allocator;
        allocator.destroy(self);
        return true;
    }

    fn loop(self: *Worker) void {
        self.mutex.lock();
        self.thread_id = std.Thread.getCurrentId();
        while (true) {
            self.queueExpiredWakeupLocked();
            while (self.head == null and (!self.stopped or self.completion_count != 0)) {
                if (self.wakeup) |value| {
                    self.changed.timedWait(&self.mutex, value.remaining()) catch {};
                } else self.changed.wait(&self.mutex);
                self.queueExpiredWakeupLocked();
            }
            if (self.head == null) {
                std.debug.assert(self.stopped and self.completion_count == 0 and self.pending == null);
                self.mutex.unlock();
                return;
            }
            const node = self.head.?;
            self.remove(node);
            if (node.completion) |completion| {
                std.debug.assert(completion.state == .queued);
                completion.state = .running;
                self.mutex.unlock();
                self.invoke(Completion.invoke, completion);
                self.mutex.lock();
                completion.destroy_storage(completion, self.allocator);
                self.completion_count -= 1;
                self.queueCapacityNoticeLocked();
            } else if (node == &self.capacity_node) {
                const notice = self.capacity_notice.?;
                std.debug.assert(notice.queued and !self.stopped);
                self.capacity_notice = null;
                self.mutex.unlock();
                self.invoke(notice.run, notice.context);
                self.mutex.lock();
            } else if (node == &self.publication_node) {
                const notice = self.publication_notice.?;
                std.debug.assert(!self.stopped);
                self.publication_notice = null;
                self.mutex.unlock();
                self.invoke(notice.run, notice.context);
                self.mutex.lock();
            } else if (node == &self.wakeup_node) {
                const value = self.wakeup.?;
                std.debug.assert(value.queued and !self.stopped);
                self.wakeup = null;
                self.cancelPreciseWakeupLocked();
                self.mutex.unlock();
                self.invoke(value.run, value.context);
                self.mutex.lock();
            } else {
                std.debug.assert(!self.stopped and node == &self.frame_node);
                const task = self.pending.?;
                self.pending = null;
                self.mutex.unlock();
                self.invokeFrame(task, true, .executed);
                self.mutex.lock();
            }
        }
    }

    fn append(self: *Worker, node: *Node) void {
        node.previous = self.tail;
        node.next = null;
        if (self.tail) |tail| tail.next = node else self.head = node;
        self.tail = node;
    }
    fn remove(self: *Worker, node: *Node) void {
        if (node.previous) |previous| previous.next = node.next else self.head = node.next;
        if (node.next) |next| next.previous = node.previous else self.tail = node.previous;
        node.previous = null;
        node.next = null;
    }
    fn invoke(self: *Worker, body: Callback, context: ?*anyopaque) void {
        if (self.scope) |scope| scope(body, context) else body(context);
    }
    fn invokeFrame(self: *Worker, task: Task, execute: bool, reason: Reason) void {
        const Invocation = struct {
            worker: *Worker,
            task: Task,
            execute: bool,
            reason: Reason,
            fn call(context: ?*anyopaque) callconv(.c) void {
                const value: *@This() = @ptrCast(@alignCast(context.?));
                if (value.execute) value.task.run(value.task.context, value.worker, value.task.epoch);
                value.task.release(value.reason);
            }
        };
        var invocation = Invocation{ .worker = self, .task = task, .execute = execute, .reason = reason };
        self.invoke(Invocation.call, &invocation);
    }
};

export fn cmdy_render_worker_create() ?*Worker {
    return Worker.create(std.heap.c_allocator) catch null;
}
export fn cmdy_render_worker_create_with_scope(scope: ?Scope) ?*Worker {
    return Worker.createWithOptions(std.heap.c_allocator, scope, 1024) catch null;
}
export fn cmdy_render_worker_prepare_completion(raw: ?*Worker, context: ?*anyopaque, run: ?CompletionRun, dispose: ?Callback) ?*Completion {
    const self = raw orelse return null;
    return self.prepareCompletion(context, run orelse return null, dispose orelse return null);
}
export fn cmdy_render_worker_complete(completion: ?*Completion) void {
    if (completion) |value| value.publish(.ready);
}
export fn cmdy_render_worker_cancel_completion(completion: ?*Completion) void {
    if (completion) |value| value.publish(.cancelled);
}
export fn cmdy_render_worker_outstanding_completions(raw: ?*Worker) usize {
    return if (raw) |self| self.outstandingCompletions() else 0;
}
export fn cmdy_render_worker_epoch(raw: ?*Worker) u64 {
    return if (raw) |self| self.currentEpoch() else 0;
}
export fn cmdy_render_worker_submit(raw: ?*Worker, epoch: u64, context: ?*anyopaque, run: ?Run, dispose: ?Dispose) u8 {
    const self = raw orelse return 0;
    return @intFromBool(self.submit(.{ .context = context, .epoch = epoch, .run = run orelse return 0, .dispose = dispose orelse return 0 }));
}
export fn cmdy_render_worker_invalidate(raw: ?*Worker) u64 {
    return if (raw) |self| self.invalidate() else 0;
}
export fn cmdy_render_worker_stop(raw: ?*Worker) void {
    if (raw) |self| self.stop();
}
export fn cmdy_render_worker_destroy(raw: ?*Worker) u8 {
    return if (raw) |self| @intFromBool(self.destroy()) else 1;
}

test {
    _ = @import("render_worker_tests.zig");
    _ = @import("render_worker_completion_tests.zig");
    _ = @import("render_worker_publication_tests.zig");
    _ = @import("render_worker_deadline_tests.zig");
    _ = @import("render_worker_capacity_tests.zig");
    _ = @import("render_worker_model_tests.zig");
    _ = @import("render_worker_owned_completion_tests.zig");
}
