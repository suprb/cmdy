//! Direct Swift VTParserDelegate entry to native ordinary Unicode batches.
const std = @import("std");
const engine_abi = @import("terminal_abi.zig");
const ordinary = @import("ordinary_printing.zig");
const Handle = engine_abi.Handle;
const Status = engine_abi.Status;
pub const Callback = *const fn (?*anyopaque) callconv(.c) u8;
const Continuation = struct {
    context: ?*anyopaque,
    callback: Callback,
    fn check(context: ?*anyopaque) bool {
        const c: *const Continuation = @ptrCast(@alignCast(context.?));
        return c.callback(c.context) != 0;
    }
};

pub export fn cmdy_zig_terminal_print_ordinary_unicode(handle: ?*Handle, bytes: ?[*]const u8, count: usize,
    first: u32, first_byte_count: usize, context: ?*anyopaque, can_continue: ?Callback, consumed: ?*usize) Status
{
    const h = handle orelse return .invalid_input;
    const out = consumed orelse return .invalid_input;
    out.* = 0;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const input = if (count == 0) &.{} else (bytes orelse return .invalid_input)[0..count];
    var c = Continuation{ .context = context, .callback = can_continue orelse undefined };
    const continuation: ?ordinary.Continuation = if (can_continue != null) .{ .context = &c, .can_continue = Continuation.check } else null;
    out.* = ordinary.print(&h.value, input, first, first_byte_count, continuation) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidInput => .invalid_input,
        else => .engine_error,
    };
    return .ok;
}

test "ordinary Unicode C ABI reports actual consumed bytes and continuation checks" {
    const h = engine_abi.cmdy_zig_terminal_create(20, 4, 0).?;
    defer engine_abi.cmdy_zig_terminal_free(h);
    var consumed: usize = 999;
    const text = "\xc3\xa9" ++ "ABC";
    try std.testing.expectEqual(Status.ok, cmdy_zig_terminal_print_ordinary_unicode(h, text.ptr, text.len, 0xe9, 2, null, null, &consumed));
    try std.testing.expectEqual(text.len, consumed);
    try std.testing.expectEqual(@as(isize, 4), h.value.buffer().x);
    try std.testing.expectEqual(@as(u32, 'C'), h.value.buffer().liveLine(0).get(3).cell.scalar);
    const Check = struct {
        calls: usize = 0,
        fn stop(context: ?*anyopaque) callconv(.c) u8 {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            return 0;
        }
    };
    var check = Check{};
    try std.testing.expectEqual(Status.ok, cmdy_zig_terminal_print_ordinary_unicode(h, text.ptr, text.len, 0xe9, 2, &check, Check.stop, &consumed));
    try std.testing.expectEqual(@as(usize, 2), consumed);
    try std.testing.expect(check.calls > 0);
    try std.testing.expectEqual(@as(isize, 5), h.value.buffer().x);
    try std.testing.expectEqual(Status.invalid_input, cmdy_zig_terminal_print_ordinary_unicode(h, null, 1, 'A', 1, null, null, &consumed));
    try std.testing.expectEqual(@as(usize, 0), consumed);
    try std.testing.expectEqual(Status.invalid_input, cmdy_zig_terminal_print_ordinary_unicode(h, text.ptr, text.len, 0xe9, 0, null, null, &consumed));
}
