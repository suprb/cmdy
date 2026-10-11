//! Optional renderer phase evidence. The native library owns activation,
//! bounded queue reservation, timestamps, sorted JSON records and output.
const std = @import("std");
const c = @cImport({
    @cInclude("dispatch/dispatch.h");
    @cInclude("mach/mach_time.h");
    @cInclude("stdlib.h");
});
const allocator = std.heap.c_allocator;
const limit: usize = 4096;
pub const Field = extern struct { name: [*:0]const u8, value: isize };
const OwnedField = struct { name: [:0]u8, value: isize };
var environment_once = std.once(readEnvironment);
var environment_enabled = false;
var writer_once = std.once(initializeWriter);
var writer: Writer = .{};

fn readEnvironment() void {
    const value = c.getenv("CMDY_FRAME_TRACE") orelse return;
    environment_enabled = value[0] == '1' and value[1] == 0;
}
pub fn enabled() bool {
    environment_once.call();
    return environment_enabled;
}
pub fn now() u64 {
    return if (enabled()) c.mach_absolute_time() else 0;
}

const Writer = struct {
    lock: std.Thread.Mutex = .{},
    reserved: usize = 0,
    queue: c.dispatch_queue_t = null,

    /// Exactly 4096 ordinary events and one terminal limit event. The initial
    /// clock record is separate, matching the frozen Swift writer.
    fn reserve(self: *Writer) enum { ordinary, limit, dropped } {
        self.lock.lock();
        defer self.lock.unlock();
        if (self.reserved > limit) return .dropped;
        const reached_limit = self.reserved == limit;
        self.reserved += 1;
        return if (reached_limit) .limit else .ordinary;
    }
};
const Packet = struct {
    event: [:0]u8,
    started: u64,
    ended: u64,
    fields: []OwnedField,
    fn create(event: []const u8, started: u64, ended: u64, fields: []const Field) !*Packet {
        const packet = try allocator.create(Packet);
        errdefer allocator.destroy(packet);
        packet.event = try allocator.dupeZ(u8, event);
        errdefer allocator.free(packet.event);
        packet.fields = try allocator.alloc(OwnedField, fields.len);
        var copied: usize = 0;
        errdefer {
            for (packet.fields[0..copied]) |field| allocator.free(field.name);
            allocator.free(packet.fields);
        }
        for (fields, 0..) |field, index| {
            packet.fields[index] = .{ .name = try allocator.dupeZ(u8, std.mem.span(field.name)), .value = field.value };
            copied += 1;
        }
        packet.started = started;
        packet.ended = ended;
        return packet;
    }
    fn deinit(self: *Packet) void {
        for (self.fields) |field| allocator.free(field.name);
        allocator.free(self.fields);
        allocator.free(self.event);
        allocator.destroy(self);
    }
};
fn initializeWriter() void {
    const attributes = c.dispatch_queue_attr_make_with_qos_class(null, c.QOS_CLASS_UTILITY, 0);
    writer.queue = c.dispatch_queue_create("com.cmdy.trace.renderer", attributes);
    if (writer.queue) |queue| c.dispatch_async_f(queue, null, writeClock);
}
fn writeClock(_: ?*anyopaque) callconv(.c) void {
    var timebase: c.mach_timebase_info_data_t = .{ .numer = 0, .denom = 0 };
    _ = c.mach_timebase_info(&timebase);
    const timestamp = c.mach_absolute_time();
    const fields = [_]Field{
        .{ .name = "numer", .value = timebase.numer },
        .{ .name = "denom", .value = timebase.denom },
        .{ .name = "maxRecords", .value = limit },
    };
    const bytes = encode(allocator, "clock", timestamp, timestamp, &fields) catch return;
    defer allocator.free(bytes);
    writeBytes(bytes);
}
fn writeBytes(bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = std.posix.write(std.posix.STDERR_FILENO, bytes[offset..]) catch return;
        if (written == 0) return;
        offset += written;
    }
}
fn writePacket(context: ?*anyopaque) callconv(.c) void {
    const packet: *Packet = @ptrCast(@alignCast(context orelse return));
    defer packet.deinit();
    const fields = allocator.alloc(Field, packet.fields.len) catch return;
    defer allocator.free(fields);
    for (packet.fields, fields) |source, *destination| destination.* = .{ .name = source.name, .value = source.value };
    const bytes = encode(allocator, packet.event, packet.started, packet.ended, fields) catch return;
    defer allocator.free(bytes);
    writeBytes(bytes);
}

/// Callers which construct expensive fields guard this call with enabled().
/// Swift's public compatibility facade preserves its lazy autoclosure too.
pub fn record(event: [:0]const u8, started: u64, fields: []const Field) void {
    if (!enabled() or started == 0) return;
    recordEnded(event, started, c.mach_absolute_time(), fields);
}
pub fn recordEnded(event: [:0]const u8, started: u64, ended: u64, fields: []const Field) void {
    if (!enabled() or started == 0) return;
    writer_once.call();
    const queue = writer.queue orelse return;
    const reservation = writer.reserve();
    const max_fields = [_]Field{.{ .name = "maxRecords", .value = limit }};
    const packet = switch (reservation) {
        .ordinary => Packet.create(event, started, ended, fields) catch return,
        .limit => Packet.create("limit", started, ended, &max_fields) catch return,
        .dropped => return,
    };
    c.dispatch_async_f(queue, packet, writePacket);
}
fn emptyTask(_: ?*anyopaque) callconv(.c) void {}
pub fn flush() void {
    if (!@atomicLoad(bool, &writer_once.done, .acquire)) return;
    if (writer.queue) |queue| c.dispatch_sync_f(queue, null, emptyTask);
}

fn lessThan(_: void, left: Field, right: Field) bool {
    return std.mem.order(u8, std.mem.span(left.name), std.mem.span(right.name)) == .lt;
}
/// Encode only on the serial writer. Object keys use the frozen sorted order;
/// integer values retain pointer-sized signed semantics and tick fields UInt64.
fn encode(gpa: std.mem.Allocator, event: []const u8, started: u64, ended: u64, fields: []const Field) ![]u8 {
    const sorted = try gpa.dupe(Field, fields);
    defer gpa.free(sorted);
    std.mem.sort(Field, sorted, {}, lessThan);
    var output: std.Io.Writer.Allocating = .init(gpa);
    defer output.deinit();
    try output.writer.writeAll("CMDY_FRAME_TRACE ");
    var json: std.json.Stringify = .{ .writer = &output.writer };
    try json.beginObject();
    try json.objectField("component");
    try json.write("renderer");
    try json.objectField("durationTicks");
    try json.write(if (ended >= started) ended - started else 0);
    try json.objectField("ended");
    try json.write(ended);
    try json.objectField("event");
    try json.write(event);
    try json.objectField("fields");
    try json.beginObject();
    for (sorted) |field| {
        try json.objectField(std.mem.span(field.name));
        try json.write(field.value);
    }
    try json.endObject();
    try json.objectField("started");
    try json.write(started);
    try json.endObject();
    try output.writer.writeByte('\n');
    return output.toOwnedSlice();
}
export fn cmdy_render_trace_enabled() u8 {
    return @intFromBool(enabled());
}
export fn cmdy_render_trace_now() u64 {
    return now();
}
export fn cmdy_render_trace_record(event: ?[*:0]const u8, started: u64, fields: [*c]const Field, count: usize) void {
    if (!enabled() or started == 0) return;
    const name = event orelse return;
    if (count != 0 and fields == null) return;
    record(std.mem.span(name), started, fields[0..count]);
}
export fn cmdy_render_trace_record_ended(event: ?[*:0]const u8, started: u64, ended: u64, fields: [*c]const Field, count: usize) void {
    if (!enabled() or started == 0) return;
    const name = event orelse return;
    if (count != 0 and fields == null) return;
    recordEnded(std.mem.span(name), started, ended, fields[0..count]);
}
export fn cmdy_render_trace_flush() void {
    flush();
}

test "bounded reservation emits precisely one limit event" {
    var value: Writer = .{};
    for (0..limit) |_| try std.testing.expectEqual(.ordinary, value.reserve());
    try std.testing.expectEqual(.limit, value.reserve());
    for (0..100) |_| try std.testing.expectEqual(.dropped, value.reserve());
    try std.testing.expectEqual(limit + 1, value.reserved);
}
test "trace JSON preserves sorted keys integer values escaped strings and saturated durations" {
    const fields = [_]Field{ .{ .name = "z", .value = std.math.minInt(isize) }, .{ .name = "a", .value = 7 } };
    const bytes = try encode(std.testing.allocator, "probe\"\n", 20, 10, &fields);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("CMDY_FRAME_TRACE {\"component\":\"renderer\",\"durationTicks\":0,\"ended\":10,\"event\":\"probe\\\"\\n\",\"fields\":{\"a\":7,\"z\":-9223372036854775808},\"started\":20}\n", bytes);
}
test "trace field packets copy caller storage before asynchronous ownership" {
    var event = [_:0]u8{ 'r', 'o', 'w' };
    var name = [_:0]u8{ 'c', 'o', 'l' };
    var fields = [_]Field{.{ .name = &name, .value = 42 }};
    const packet = try Packet.create(&event, 10, 11, &fields);
    defer packet.deinit();
    event[0] = 'x';
    name[0] = 'y';
    fields[0].value = 99;
    try std.testing.expectEqualStrings("row", packet.event);
    try std.testing.expectEqualStrings("col", packet.fields[0].name);
    try std.testing.expectEqual(@as(isize, 42), packet.fields[0].value);
}
