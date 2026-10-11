//! Native asynchronous image cache. Each decoder owns a cache reference until
//! its owner-thread completion, so neither a destroyed renderer nor a recycled
//! host object identity can receive an old decode result.
const std = @import("std");
const cache = @import("render_cache.zig");
const render_worker = @import("render_worker.zig");
const image_bridge = @import("render_image_bridge.zig");
const c = cache.c;
const a = std.heap.c_allocator;
pub const Event = *const fn (?*anyopaque) callconv(.c) void;
const Record = struct { owner: ?*anyopaque, texture: ?*anyopaque = null, last_use: u64 = 0, pending: bool = false, failed: bool = false };
const Signature = struct { kind: u8, width: isize, height: isize, count: usize, head_hash: u32 };
const Kitty = struct { signature: Signature, texture: ?*anyopaque, last_use: u64 };
const OwnedRecord = struct {
    input: *c.CmdyRenderOwnedImageInput,
    texture: ?*anyopaque = null,
    task: ?*Task = null,
    failed: bool = false,
    seen: bool = true,
    fn release(self: OwnedRecord) void {
        c.cmdy_render_image_input_release(self.input);
        c.cmdy_gpu_apple_release(self.texture);
    }
};
const Task = struct {
    cache: *Cache,
    ticket: ?*render_worker.Completion = null,
    captured_image: ?*c.CmdyRenderOwnedImageInput = null,
    identity: usize = 0,
    owner: ?*anyopaque = null,
    image: ?*anyopaque = null,
    bytes: []u8 = &.{},
    signature: ?Signature = null,
    kitty_id: u32 = 0,
    result: ?*anyopaque = null,
    fn dispose(self: *Task) void {
        c.cmdy_gpu_apple_release(self.owner);
        c.cmdy_gpu_apple_release(self.image);
        c.cmdy_gpu_apple_release(self.result);
        c.cmdy_render_image_input_release(self.captured_image);
        a.free(self.bytes);
        a.destroy(self);
    }
};
pub const Cache = struct {
    refs: usize = 1,
    alive: bool = true,
    owner: ?*render_worker.Worker,
    device: ?*anyopaque,
    event: ?Event = null,
    context: ?*anyopaque = null,
    ordinary: std.AutoHashMapUnmanaged(usize, Record) = .empty,
    owned: std.AutoHashMapUnmanaged(usize, OwnedRecord) = .empty,
    kitty: std.AutoHashMapUnmanaged(u32, Kitty) = .empty,
    failures: std.AutoHashMapUnmanaged(Signature, void) = .empty,
    pending: std.AutoHashMapUnmanaged(Signature, void) = .empty,
    attempts: usize = 0,
    clock: u64 = 0,
    pub fn create(device: ?*const anyopaque, owner: ?*render_worker.Worker) ?*Cache {
        const self = a.create(Cache) catch return null;
        self.* = .{ .owner = owner, .device = c.cmdy_gpu_apple_retain(device) };
        return self;
    }
    pub fn destroy(self: *Cache) void {
        self.alive = false;
        self.event = null;
        self.context = null;
        self.release();
    }
    fn release(self: *Cache) void {
        self.refs -= 1;
        if (self.refs != 0) return;
        var ordinary = self.ordinary.valueIterator();
        while (ordinary.next()) |v| {
            c.cmdy_gpu_apple_release(v.owner);
            c.cmdy_gpu_apple_release(v.texture);
        }
        var kitty = self.kitty.valueIterator();
        while (kitty.next()) |v| c.cmdy_gpu_apple_release(v.texture);
        var owned = self.owned.valueIterator();
        while (owned.next()) |v| v.release();
        self.owned.deinit(a);
        self.ordinary.deinit(a);
        self.kitty.deinit(a);
        self.failures.deinit(a);
        self.pending.deinit(a);
        c.cmdy_gpu_apple_release(self.device);
        a.destroy(self);
    }
    pub fn texture(self: *Cache, owner: ?*const anyopaque, image: ?*const anyopaque) ?*anyopaque {
        const object = owner orelse return null;
        const identity = @intFromPtr(object);
        self.clock +%= 1;
        if (self.ordinary.getPtr(identity)) |record| {
            const living = c.cmdy_gpu_apple_weak_load(record.owner);
            defer c.cmdy_gpu_apple_release(living);
            if (living != null) {
                record.last_use = self.clock;
                return record.texture;
            }
            c.cmdy_gpu_apple_release(record.owner);
            c.cmdy_gpu_apple_release(record.texture);
            _ = self.ordinary.remove(identity);
        }
        const weak = c.cmdy_gpu_apple_weak_create(owner) orelse return null;
        self.ordinary.put(a, identity, .{ .owner = weak, .last_use = self.clock, .pending = true }) catch {
            c.cmdy_gpu_apple_release(weak);
            return null;
        };
        const task = a.create(Task) catch {
            if (self.ordinary.getPtr(identity)) |r| {
                r.pending = false;
                r.failed = true;
            }
            return null;
        };
        task.* = .{ .cache = self, .identity = identity, .owner = c.cmdy_gpu_apple_retain(weak), .image = c.cmdy_gpu_apple_retain(image) };
        if (!self.launch(task)) {
            // Capacity/stop is retryable. No decode started and no cache ref was
            // transferred; removing the pending entry preserves a later retry.
            _ = self.ordinary.remove(identity);
            c.cmdy_gpu_apple_release(weak);
            task.dispose();
        }
        return null;
    }
    pub fn kittyTexture(self: *Cache, input: c.CmdyGpuKittyImage) ?*anyopaque {
        const signature = signatureFor(input);
        self.clock +%= 1;
        if (self.kitty.getPtr(input.image_id)) |v| if (std.meta.eql(v.signature, signature)) {
            v.last_use = self.clock;
            return v.texture;
        };
        if (self.failures.contains(signature)) return null;
        if (input.kind != 0) {
            const pixels = if (input.width > 0 and input.height > 0) std.math.mul(usize, @intCast(input.width), @intCast(input.height)) catch 0 else 0;
            if (input.width <= 0 or input.height <= 0 or input.width > 16384 or input.height > 16384 or pixels == 0 or pixels > std.math.maxInt(usize) / 4 or input.byte_count < pixels * 4) {
                self.failures.put(a, signature, {}) catch {};
                return null;
            }
            const result = cache.makeTexture(self.device, input.width, input.height, 70, cache.slice(u8, input.bytes, input.byte_count), input.width * 4) orelse {
                self.failures.put(a, signature, {}) catch {};
                return null;
            };
            self.storeKitty(input.image_id, signature, result);
            return result;
        }
        if (self.pending.contains(signature)) return null;
        const bytes = a.dupe(u8, cache.slice(u8, input.bytes, input.byte_count)) catch return null;
        const task = a.create(Task) catch {
            a.free(bytes);
            return null;
        };
        self.pending.put(a, signature, {}) catch {
            a.free(bytes);
            a.destroy(task);
            return null;
        };
        task.* = .{ .cache = self, .signature = signature, .kitty_id = input.image_id, .bytes = bytes };
        if (!self.launch(task)) {
            _ = self.pending.remove(signature);
            task.dispose();
        }
        return null;
    }
    pub fn beginOwnedFrame(self: *Cache) void {
        var entries = self.owned.valueIterator();
        while (entries.next()) |entry| entry.seen = false;
    }
    pub fn endOwnedFrame(self: *Cache) void {
        var stale: std.ArrayList(usize) = .empty;
        defer stale.deinit(a);
        var entries = self.owned.iterator();
        while (entries.next()) |entry| if (!entry.value_ptr.seen) {
            stale.append(a, entry.key_ptr.*) catch return;
        };
        for (stale.items) |key| if (self.owned.fetchRemove(key)) |entry| entry.value.release();
    }
    /// The retained native handle provides immutable bytes, never an NSImage
    /// or host owner callback. Producer handle reuse also reuses this texture.
    pub fn ownedTexture(self: *Cache, handle: *c.CmdyRenderOwnedImageInput) ?*anyopaque {
        const identity = @intFromPtr(handle);
        if (self.owned.getPtr(identity)) |entry| {
            entry.seen = true;
            return entry.texture;
        }
        const input = c.cmdy_render_image_input_view(handle) orelse return null;
        self.owned.put(a, identity, .{ .input = handle }) catch return null;
        _ = c.cmdy_render_image_input_retain(handle);
        if (input.*.kind == 1) {
            const uploaded = decodeOwned(self.device, input);
            const entry = self.owned.getPtr(identity).?;
            entry.texture = uploaded;
            entry.failed = uploaded == null;
            return uploaded;
        }
        const task = a.create(Task) catch {
            self.owned.fetchRemove(identity).?.value.release();
            return null;
        };
        task.* = .{ .cache = self, .identity = identity, .captured_image = c.cmdy_render_image_input_retain(handle) };
        self.owned.getPtr(identity).?.task = task;
        if (!self.launch(task)) {
            self.owned.fetchRemove(identity).?.value.release();
            task.dispose();
        }
        return null;
    }
    fn launch(self: *Cache, task: *Task) bool {
        if (self.owner) |owner| task.ticket = owner.prepareCompletion(task, ownedComplete, noDispose) orelse return false;
        self.refs += 1;
        if (task.signature == null) self.attempts += 1;
        c.cmdy_gpu_apple_dispatch_background(worker, task);
        return true;
    }
    fn storeKitty(self: *Cache, id: u32, signature: Signature, texture_value: ?*anyopaque) void {
        const old = self.kitty.fetchPut(a, id, .{ .signature = signature, .texture = texture_value, .last_use = self.clock }) catch {
            c.cmdy_gpu_apple_release(texture_value);
            return;
        };
        if (old) |previous| c.cmdy_gpu_apple_release(previous.value.texture);
    }
    pub fn prune(self: *Cache, live: []const u32) void {
        var stale: std.ArrayList(usize) = .empty;
        defer stale.deinit(a);
        var ordinary = self.ordinary.iterator();
        while (ordinary.next()) |v| {
            const object = c.cmdy_gpu_apple_weak_load(v.value_ptr.owner);
            if (object == null) stale.append(a, v.key_ptr.*) catch {} else c.cmdy_gpu_apple_release(object);
        }
        for (stale.items) |key| if (self.ordinary.fetchRemove(key)) |v| {
            c.cmdy_gpu_apple_release(v.value.owner);
            c.cmdy_gpu_apple_release(v.value.texture);
        };
        var expired: std.ArrayList(u32) = .empty;
        defer expired.deinit(a);
        var kitty = self.kitty.iterator();
        while (kitty.next()) |v| if (std.mem.indexOfScalar(u32, live, v.key_ptr.*) == null) {
            expired.append(a, v.key_ptr.*) catch {};
        };
        for (expired.items) |id| if (self.kitty.fetchRemove(id)) |v| c.cmdy_gpu_apple_release(v.value.texture);
        while (self.kitty.count() > 128) {
            var oldest: ?u32 = null;
            var time: u64 = std.math.maxInt(u64);
            var candidates = self.kitty.iterator();
            while (candidates.next()) |v| if (v.value_ptr.last_use < time) {
                oldest = v.key_ptr.*;
                time = v.value_ptr.last_use;
            };
            if (oldest) |id| {
                if (self.kitty.fetchRemove(id)) |v| c.cmdy_gpu_apple_release(v.value.texture);
            } else break;
        }
    }
    pub fn pendingCount(self: *const Cache) usize {
        var n: usize = 0;
        var it = self.ordinary.valueIterator();
        while (it.next()) |v| {
            if (v.pending) n += 1;
        }
        var owned = self.owned.valueIterator();
        while (owned.next()) |v| {
            if (v.task != null) n += 1;
        }
        return n;
    }
};
fn signatureFor(v: c.CmdyGpuKittyImage) Signature {
    var hash: u32 = 2166136261;
    for (cache.slice(u8, v.bytes, @min(4096, v.byte_count))) |b| hash = (hash ^ b) *% 16777619;
    return .{ .kind = v.kind, .width = if (v.kind == 0) 0 else v.width, .height = if (v.kind == 0) 0 else v.height, .count = v.byte_count, .head_hash = hash };
}
fn worker(context: ?*anyopaque) callconv(.c) void {
    const task: *Task = @ptrCast(@alignCast(context.?));
    if (task.captured_image) |handle| {
        task.result = decodeOwned(task.cache.device, c.cmdy_render_image_input_view(handle).?);
    } else if (task.signature != null) {
        if (c.cmdy_gpu_apple_png_image(task.bytes.ptr, task.bytes.len)) |decoded| {
            defer c.cmdy_gpu_apple_release(decoded);
            if (c.cmdy_gpu_apple_image_width(decoded) <= 16384 and c.cmdy_gpu_apple_image_height(decoded) <= 16384)
                task.result = c.cmdy_gpu_apple_image_texture(task.cache.device, decoded);
        }
    } else task.result = c.cmdy_gpu_apple_decode_image(task.cache.device, task.image);
    // The ticket's mutex publishes the result before the owner mutates maps.
    // The owner can dispose task as soon as publish unlocks: no access after it.
    if (task.ticket) |ticket| ticket.publish(.ready) else c.cmdy_gpu_apple_dispatch_main(complete, task);
}
fn decodeOwned(device: ?*const anyopaque, input: *const c.CmdyRenderImageInput) ?*anyopaque {
    const decoded = image_bridge.decodePixels(input.kind, cache.slice(u8, input.bytes, input.byte_count), input.width, input.height) orelse return null;
    defer c.cmdy_gpu_apple_release(decoded);
    return c.cmdy_gpu_apple_image_texture(device, decoded);
}
fn noDispose(_: ?*anyopaque) callconv(.c) void {}
fn ownedComplete(context: ?*anyopaque, _: *render_worker.Worker, _: u32) callconv(.c) void {
    complete(context);
}
fn complete(context: ?*anyopaque) callconv(.c) void {
    const task: *Task = @ptrCast(@alignCast(context.?));
    const self = task.cache;
    defer {
        task.dispose();
        self.release();
    }
    if (!self.alive) return;
    if (task.captured_image != null) {
        const entry = self.owned.getPtr(task.identity) orelse return;
        // Pruning may have removed and reintroduced the same retained handle
        // while an old decode was pending. Only the current task can fill it.
        if (entry.task != task) return;
        entry.task = null;
        entry.failed = task.result == null;
        entry.texture = task.result;
        task.result = null;
        if (entry.texture != null) if (self.event) |event| event(self.context);
        return;
    }
    if (task.signature) |signature| {
        _ = self.pending.remove(signature);
        if (task.result) |texture| {
            self.clock +%= 1;
            self.storeKitty(task.kitty_id, signature, texture);
            task.result = null;
            if (self.event) |event| event(self.context);
        } else self.failures.put(a, signature, {}) catch {};
    } else {
        const owner = c.cmdy_gpu_apple_weak_load(task.owner);
        defer c.cmdy_gpu_apple_release(owner);
        const record = self.ordinary.getPtr(task.identity) orelse return;
        if (owner == null or @intFromPtr(owner.?) != task.identity or record.owner != task.owner) return;
        record.pending = false;
        record.failed = task.result == null;
        if (task.result) |texture| {
            self.clock +%= 1;
            record.last_use = self.clock;
            record.texture = texture;
            task.result = null;
            if (self.event) |event| event(self.context);
        }
    }
}
