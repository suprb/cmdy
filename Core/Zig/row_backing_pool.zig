//! Dense row backing with explicit mapping lifetimes. Compact rows, extras and
//! custom allocators remain on their existing allocation paths.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const slab_bytes: usize = 256 * 1024;
const minimum_slot: usize = 256;
const maximum_slot: usize = 64 * 1024;
const class_count = 9;
const shard_count = 4;
const Bytes = []align(16) u8;

const Slab = struct {
    previous: ?*Slab = null,
    next: ?*Slab = null,
    empty_previous: ?*Slab = null,
    empty_next: ?*Slab = null,
    bucket: *Bucket,
    pool: *Pool,
    allocator: Allocator,
    free_head: ?[*]align(16) u8 = null,
    slot_bytes: usize,
    capacity: usize,
    next_slot: usize = 1,
    live: usize = 0,
    cached: bool = false,
};
const Bucket = struct {
    mutex: std.Thread.Mutex = .{},
    available: ?*Slab = null,
    mapped_slabs: usize = 0,
    live_allocations: usize = 0,
    empty: ?*Slab = null,
    empty_count: usize = 0,

    fn cacheEmpty(self: *Bucket, slab: *Slab) void {
        std.debug.assert(slab.live == 0 and !slab.cached);
        slab.cached = true;
        slab.empty_previous = null;
        slab.empty_next = self.empty;
        if (self.empty) |next| next.empty_previous = slab;
        self.empty = slab;
        self.empty_count += 1;
        // Every slot is free. Reuse their already committed pages in order.
        slab.free_head = null;
        slab.next_slot = 1;
    }
    fn uncacheEmpty(self: *Bucket, slab: *Slab) void {
        std.debug.assert(slab.cached and slab.live == 0);
        if (slab.empty_previous) |previous| {
            previous.empty_next = slab.empty_next;
        } else self.empty = slab.empty_next;
        if (slab.empty_next) |next| next.empty_previous = slab.empty_previous;
        slab.empty_previous = null;
        slab.empty_next = null;
        slab.cached = false;
        self.empty_count -= 1;
        _ = slab.pool.cached_empty.fetchSub(1, .monotonic);
    }

    fn insert(self: *Bucket, slab: *Slab) void {
        slab.previous = null;
        slab.next = self.available;
        if (self.available) |next| next.previous = slab;
        self.available = slab;
    }
    fn remove(self: *Bucket, slab: *Slab) void {
        if (slab.previous) |previous| {
            previous.next = slab.next;
        } else {
            std.debug.assert(self.available == slab);
            self.available = slab.next;
        }
        if (slab.next) |next| next.previous = slab.previous;
        slab.previous = null;
        slab.next = null;
    }
};
comptime {
    if (@sizeOf(Slab) > minimum_slot or @alignOf(Slab) > 16)
        @compileError("row backing metadata exceeds its reserved slot");
}

pub fn eligible(bytes: usize) bool {
    return bytes > 0 and bytes <= maximum_slot;
}
fn classIndex(bytes: usize) usize {
    std.debug.assert(eligible(bytes));
    return std.math.log2_int_ceil(usize, @max(bytes, minimum_slot)) - 8;
}
fn slabFor(pointer: [*]const u8) *Slab {
    return @ptrFromInt(std.mem.alignBackward(usize, @intFromPtr(pointer), slab_bytes));
}
pub fn allocationBytes(pointer: [*]const u8) usize {
    return slabFor(pointer).slot_bytes;
}

pub const Pool = struct {
    allocator: Allocator = std.heap.page_allocator,
    buckets: [shard_count][class_count]Bucket = @splat(@splat(.{})),
    empty_slab_limit: usize = 0,
    cached_empty: std.atomic.Value(usize) = .init(0),
    reuse_owners: std.atomic.Value(usize) = .init(0),
    require_reuse_owner: bool = false,

    pub fn beginReuseOwner(self: *Pool) void {
        _ = self.reuse_owners.fetchAdd(1, .acq_rel);
    }
    pub fn endReuseOwner(self: *Pool) void {
        const before = self.reuse_owners.fetchSub(1, .acq_rel);
        std.debug.assert(before > 0);
        // Closing a terminal clears at most the global cache bound. Live row
        // snapshots remain owned, and are reclaimed by their later release.
        _ = self.trimEmpty(self.empty_slab_limit);
    }

    pub fn allocate(self: *Pool, bytes: usize, shard: usize) Allocator.Error!Bytes {
        std.debug.assert(shard < shard_count);
        const index = classIndex(bytes);
        const bucket = &self.buckets[shard][index];
        bucket.mutex.lock();
        defer bucket.mutex.unlock();
        const slab = bucket.available orelse new: {
            const mapping = try self.allocator.alignedAlloc(u8, .fromByteUnits(slab_bytes), slab_bytes);
            const created: *Slab = @ptrCast(mapping.ptr);
            const slot_bytes = minimum_slot << @intCast(index);
            created.* = .{ .bucket = bucket, .pool = self, .allocator = self.allocator,
                .slot_bytes = slot_bytes, .capacity = slab_bytes / slot_bytes - 1 };
            bucket.insert(created);
            bucket.mapped_slabs += 1;
            break :new created;
        };
        if (slab.cached) bucket.uncacheEmpty(slab);
        const pointer: [*]align(16) u8 = if (slab.free_head) |recycled| free: {
            slab.free_head = @as(*?[*]align(16) u8, @ptrCast(recycled)).*;
            break :free recycled;
        } else fresh: {
            std.debug.assert(slab.next_slot <= slab.capacity);
            const base: [*]u8 = @ptrCast(slab);
            const fresh_pointer: [*]align(16) u8 = @alignCast(base + slab.next_slot * slab.slot_bytes);
            slab.next_slot += 1;
            break :fresh fresh_pointer;
        };
        slab.live += 1;
        bucket.live_allocations += 1;
        if (slab.live == slab.capacity) bucket.remove(slab);
        return pointer[0..bytes];
    }

    pub fn mappedBytes(self: *Pool) usize {
        var count: usize = 0;
        for (&self.buckets) |*shard| for (shard) |*bucket| {
            bucket.mutex.lock();
            count += bucket.mapped_slabs;
            bucket.mutex.unlock();
        };
        return count * slab_bytes;
    }

    /// Idle maintenance only. Empty-list lookup is constant work per bucket;
    /// at most maximum mappings are unmapped, without traversing live slabs.
    pub fn trimEmpty(self: *Pool, maximum: usize) usize {
        if (maximum == 0 or self.cached_empty.load(.monotonic) == 0) return 0;
        var removed: usize = 0;
        for (&self.buckets) |*shard| for (shard) |*bucket| {
            while (removed < maximum) {
                bucket.mutex.lock();
                const slab = bucket.empty orelse {
                    bucket.mutex.unlock();
                    break;
                };
                bucket.uncacheEmpty(slab);
                bucket.remove(slab);
                bucket.mapped_slabs -= 1;
                bucket.mutex.unlock();
                unmap(slab);
                removed += 1;
            }
            if (removed == maximum) return removed;
        };
        return removed;
    }
};

fn unmap(slab: *Slab) void {
    const allocator = slab.allocator;
    const mapping: [*]align(slab_bytes) u8 = @alignCast(@as([*]u8, @ptrCast(slab)));
    allocator.free(mapping[0..slab_bytes]);
}

pub fn release(memory: Bytes) void {
    const slab = slabFor(memory.ptr);
    const bucket = slab.bucket;
    std.debug.assert(memory.len > 0 and memory.len <= slab.slot_bytes);
    std.debug.assert((@intFromPtr(memory.ptr) - @intFromPtr(slab)) % slab.slot_bytes == 0);
    bucket.mutex.lock();
    std.debug.assert(slab.live > 0);
    if (slab.live == slab.capacity) bucket.insert(slab);
    slab.live -= 1;
    bucket.live_allocations -= 1;
    if (slab.live == 0) {
        // An empty bucket has no owners that can reuse its pages. Detach all
        // mappings under the lock, then unmap them before the final release
        // returns. This also handles a snapshot freed on another thread.
        const has_reuse_owner = slab.pool.reuse_owners.load(.acquire) != 0;
        if (bucket.live_allocations == 0 and !has_reuse_owner) {
            var pending = bucket.available;
            bucket.available = null;
            bucket.empty = null;
            bucket.mapped_slabs = 0;
            _ = slab.pool.cached_empty.fetchSub(bucket.empty_count, .monotonic);
            bucket.empty_count = 0;
            bucket.mutex.unlock();
            while (pending) |value| {
                std.debug.assert(value.live == 0);
                pending = value.next;
                unmap(value);
            }
            return;
        }
        if (slab.pool.empty_slab_limit > 0 and
            (!slab.pool.require_reuse_owner or has_reuse_owner)) {
            const reserved = slab.pool.cached_empty.fetchAdd(1, .monotonic);
            if (reserved < slab.pool.empty_slab_limit) {
                bucket.cacheEmpty(slab);
                bucket.mutex.unlock();
                return;
            }
            _ = slab.pool.cached_empty.fetchSub(1, .monotonic);
        }
        bucket.remove(slab);
        bucket.mapped_slabs -= 1;
        bucket.mutex.unlock();
        unmap(slab);
    } else {
        @as(*?[*]align(16) u8, @ptrCast(memory.ptr)).* = slab.free_head;
        slab.free_head = memory.ptr;
        bucket.mutex.unlock();
    }
}

// At most 64 MiB across all classes/shards while a terminal is alive. This
// covers a full ordinary dense history without eager allocation. A screen
// clear may release every row in one producer's bucket without ending the
// terminal. Idle maintenance and terminal destruction trim cached mappings.
var shared_pool: Pool = .{ .empty_slab_limit = 256, .require_reuse_owner = true };
var next_shard = std.atomic.Value(usize).init(0);
threadlocal var thread_shard: ?usize = null;

pub fn allocate(bytes: usize) Allocator.Error!Bytes {
    const shard = thread_shard orelse assign: {
        const value = next_shard.fetchAdd(1, .monotonic) % shard_count;
        thread_shard = value;
        break :assign value;
    };
    return shared_pool.allocate(bytes, shard);
}
pub fn mappedBytes() usize {
    return shared_pool.mappedBytes();
}
pub fn trimEmpty(maximum: usize) usize {
    return shared_pool.trimEmpty(maximum);
}
pub fn hasCachedEmpty() bool {
    return shared_pool.cached_empty.load(.monotonic) != 0;
}
pub fn beginTerminal() void {
    shared_pool.beginReuseOwner();
}
pub fn endTerminal() void {
    shared_pool.endReuseOwner();
}

test "reuse ownership spans an empty bucket and ends without retained mappings" {
    var pool: Pool = .{ .empty_slab_limit = 2, .require_reuse_owner = true };
    pool.beginReuseOwner();
    var owner = true;
    defer if (owner) pool.endReuseOwner();
    var memory: ?Bytes = try pool.allocate(3936, 0);
    defer if (memory) |value| release(value);
    const pointer = memory.?.ptr;
    release(memory.?);
    memory = null;
    try std.testing.expectEqual(slab_bytes, pool.mappedBytes());
    try std.testing.expectEqual(@as(usize, 1), pool.cached_empty.load(.monotonic));
    memory = try pool.allocate(3936, 0);
    try std.testing.expectEqual(pointer, memory.?.ptr);
    release(memory.?);
    memory = null;
    pool.endReuseOwner();
    owner = false;
    try std.testing.expectEqual(@as(usize, 0), pool.mappedBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.cached_empty.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 0), pool.reuse_owners.load(.monotonic));
}

test "bounded empty slab reuse trims without touching live slots" {
    var pool: Pool = .{ .empty_slab_limit = 2 };
    const capacity = slab_bytes / 4096 - 1;
    var values: [4 * capacity + 1]?Bytes = @splat(null);
    defer for (&values) |*value| if (value.*) |memory| release(memory);
    for (&values) |*value| {
        value.* = try pool.allocate(3936, 0);
        @memset(value.*.?, 0x79);
    }
    for (values[0 .. values.len - 1], 0..) |value, i| {
        release(value.?);
        values[i] = null;
    }
    try std.testing.expectEqual(@as(usize, 2), pool.cached_empty.load(.monotonic));
    try std.testing.expectEqual(3 * slab_bytes, pool.mappedBytes());
    try std.testing.expectEqual(@as(usize, 1), pool.trimEmpty(1));
    try std.testing.expectEqual(2 * slab_bytes, pool.mappedBytes());
    values[0] = try pool.allocate(3936, 0);
    try std.testing.expectEqual(2 * slab_bytes, pool.mappedBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.cached_empty.load(.monotonic));
    for (values[values.len - 1].?) |byte| try std.testing.expectEqual(@as(u8, 0x79), byte);
    release(values[0].?);
    values[0] = null;
    try std.testing.expectEqual(@as(usize, 0), pool.trimEmpty(0));
    release(values[values.len - 1].?);
    values[values.len - 1] = null;
    try std.testing.expectEqual(@as(usize, 0), pool.mappedBytes());
    try std.testing.expectEqual(@as(usize, 0), pool.cached_empty.load(.monotonic));
}

test "row backing classes preserve alignment and untouched live allocations" {
    var pool: Pool = .{};
    defer std.debug.assert(pool.mappedBytes() == 0);
    const sizes = [_]usize{ 1, 255, 256, 257, 511, 512, 513, 1024, 2048, 3936, 4096, 4097, 8192, 16384, 32768, 65536 };
    var values: [sizes.len]?Bytes = @splat(null);
    defer for (&values) |*value| if (value.*) |memory| release(memory);
    for (sizes, 0..) |size, i| {
        const memory = try pool.allocate(size, i % shard_count);
        values[i] = memory;
        @memset(memory, @intCast(i + 1));
        try std.testing.expect(@intFromPtr(memory.ptr) % 16 == 0);
        try std.testing.expect(allocationBytes(memory.ptr) >= size);
    }
    for (values, 0..) |value, i| for (value.?) |byte| try std.testing.expectEqual(@as(u8, @intCast(i + 1)), byte);
    try std.testing.expect(!eligible(0) and !eligible(maximum_slot + 1));
}

test "row backing unmaps only after the last live slot and recycles holes" {
    var pool: Pool = .{};
    defer std.debug.assert(pool.mappedBytes() == 0);
    const capacity = slab_bytes / 4096 - 1;
    var values: [capacity + 1]?Bytes = @splat(null);
    defer for (&values) |*value| if (value.*) |memory| release(memory);
    for (&values, 0..) |*value, i| {
        value.* = try pool.allocate(3936, 0);
        @memset(value.*.?, @intCast(i));
    }
    try std.testing.expectEqual(2 * slab_bytes, pool.mappedBytes());
    const hole = values[1].?.ptr;
    release(values[1].?);
    values[1] = try pool.allocate(3936, 0);
    try std.testing.expectEqual(hole, values[1].?.ptr);
    for (2..capacity) |i| {
        release(values[i].?);
        values[i] = null;
    }
    release(values[1].?);
    values[1] = null;
    try std.testing.expectEqual(2 * slab_bytes, pool.mappedBytes());
    for (values[0].?) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    release(values[0].?);
    values[0] = null;
    try std.testing.expectEqual(slab_bytes, pool.mappedBytes());
    for (values[capacity].?) |byte| try std.testing.expectEqual(@as(u8, capacity), byte);
    release(values[capacity].?);
    values[capacity] = null;
    try std.testing.expectEqual(@as(usize, 0), pool.mappedBytes());
}

fn failureTrace(allocator: Allocator) !void {
    var pool: Pool = .{ .allocator = allocator };
    defer std.debug.assert(pool.mappedBytes() == 0);
    var values: [7]?Bytes = @splat(null);
    defer for (&values) |*value| if (value.*) |memory| release(memory);
    for (&values) |*value| value.* = try pool.allocate(maximum_slot, 0);
    try std.testing.expectEqual(3 * slab_bytes, pool.mappedBytes());
}
test "row backing allocation failure preserves existing slabs and cleanup" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, failureTrace, .{});
}

const ReleaseWork = struct {
    values: []?Bytes,
    fn run(self: ReleaseWork) void {
        for (self.values) |*value| {
            if (value.*) |memory| release(memory);
            value.* = null;
        }
    }
};
test "row backing supports concurrent release by threads other than its allocator" {
    var pool: Pool = .{};
    defer std.debug.assert(pool.mappedBytes() == 0);
    var values: [4][80]?Bytes = @splat(@splat(null));
    defer for (&values) |*group| for (group) |*value| if (value.*) |memory| release(memory);
    for (&values, 0..) |*group, i| for (group, 0..) |*value, j| {
        value.* = try pool.allocate(3936, j % shard_count);
        @memset(value.*.?, @intCast(i + j));
    };
    for (values, 0..) |group, i| for (group, 0..) |value, j| {
        for (value.?) |byte| try std.testing.expectEqual(@as(u8, @intCast(i + j)), byte);
    };
    var threads: [4]?std.Thread = @splat(null);
    {
        defer for (threads) |thread| if (thread) |started| started.join();
        for (&threads, &values) |*thread, *group| thread.* = try std.Thread.spawn(.{}, ReleaseWork.run, .{ReleaseWork{ .values = group }});
    }
    try std.testing.expectEqual(@as(usize, 0), pool.mappedBytes());
}
