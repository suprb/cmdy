//! Stable snapshot image identity, bounded access ordering and native decoding.
const std = @import("std");
const c = @cImport({
    @cInclude("platform_shape.h");
});
const a = std.heap.c_allocator;
const Object = ?*const anyopaque;
const Entry = struct { context: *anyopaque, drop: *const fn (?*anyopaque) callconv(.c) void };
var cache: std.AutoHashMapUnmanaged([16]u8, Entry) = .empty;
var order: std.ArrayList([16]u8) = .empty;
fn touch(key: [16]u8) void {
    for (order.items, 0..) |v, i| if (std.mem.eql(u8, &key, &v)) {
        _ = order.orderedRemove(i);
        order.appendAssumeCapacity(key);
        return;
    };
}
export fn cmdy_image_bridge_cached(identity: ?*const [16]u8) ?*anyopaque {
    const key = (identity orelse return null).*;
    const entry = cache.get(key) orelse return null;
    touch(key);
    return entry.context;
}
export fn cmdy_image_bridge_cache(identity: ?*const [16]u8, context: ?*anyopaque, drop: ?*const fn (?*anyopaque) callconv(.c) void) u8 {
    const key = (identity orelse return 0).*;
    const value = Entry{ .context = context orelse return 0, .drop = drop orelse return 0 };
    order.ensureTotalCapacity(a, 513) catch return 0;
    const result = cache.getOrPut(a, key) catch return 0;
    if (result.found_existing) {
        const old = result.value_ptr.*;
        result.value_ptr.* = value;
        touch(key);
        old.drop(old.context);
        return 1;
    }
    result.value_ptr.* = value;
    order.appendAssumeCapacity(key);
    if (cache.count() > 512) {
        const oldest = order.orderedRemove(0);
        const old = cache.fetchRemove(oldest).?.value;
        old.drop(old.context);
    }
    return 1;
}
export fn cmdy_image_bridge_clear() void {
    var previous = cache;
    var previous_order = order;
    cache = .empty;
    order = .empty;
    var it = previous.valueIterator();
    while (it.next()) |value| value.drop(value.context);
    previous.deinit(a);
    previous_order.deinit(a);
}
fn release(o: Object) void {
    if (o != null) c.CFRelease(o);
}
fn rgba(bytes: []const u8, width: isize, height: isize, premultiplied: bool) c.CGImageRef {
    if (width <= 0 or height <= 0) return null;
    const stride = std.math.mul(usize, @intCast(width), 4) catch return null;
    const count = std.math.mul(usize, stride, @intCast(height)) catch return null;
    if (count != bytes.len or count > std.math.maxInt(c.CFIndex)) return null;
    const data = c.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer release(data);
    const provider = c.CGDataProviderCreateWithCFData(data) orelse return null;
    defer c.CGDataProviderRelease(provider);
    const space = c.CGColorSpaceCreateDeviceRGB() orelse return null;
    defer c.CGColorSpaceRelease(space);
    return c.CGImageCreate(@intCast(width), @intCast(height), 8, 32, stride, space, if (premultiplied) c.kCGImageAlphaPremultipliedLast else c.kCGImageAlphaLast, provider, null, false, c.kCGRenderingIntentDefault);
}
fn png(bytes: []const u8) c.CGImageRef {
    if (!std.mem.startsWith(u8, bytes, &.{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a }) or bytes.len > std.math.maxInt(c.CFIndex)) return null;
    const data = c.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse return null;
    defer release(data);
    const source = c.CGImageSourceCreateWithData(data, null) orelse return null;
    defer release(source);
    if (c.CGImageSourceGetCount(source) == 0) return null;
    var key = [_]Object{c.kCGImageSourceShouldCache};
    var value = [_]Object{c.kCFBooleanTrue};
    const options = c.CFDictionaryCreate(null, &key, &value, 1, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse return null;
    defer release(options);
    return c.CGImageSourceCreateImageAtIndex(source, 0, options);
}
/// Decode pixels without touching the main-thread image-identity cache. The
/// caller owns the CGImage. Worker uploads use the same format validation,
/// straight-alpha interpretation and transparent fallback as the source bridge.
pub fn decodePixels(kind: u8, bytes: []const u8, width: isize, height: isize) c.CGImageRef {
    return (if (kind == 0) png(bytes) else if (kind == 1) rgba(bytes, width, height, false) else null) orelse rgba(&.{ 0, 0, 0, 0 }, 1, 1, true);
}
export fn cmdy_image_bridge_decode(kind: u8, ptr: ?[*]const u8, count: usize, width: isize, height: isize, declared_width: isize, declared_height: isize) Object {
    if (count > 0 and ptr == null) return null;
    const bytes = if (ptr) |p| p[0..count] else &.{};
    const decoded = decodePixels(kind, bytes, width, height);
    defer if (decoded != null) c.CGImageRelease(decoded);
    return c.cmdy_platform_shape_image(decoded, @floatFromInt(@max(0, declared_width)), @floatFromInt(@max(0, declared_height)));
}
