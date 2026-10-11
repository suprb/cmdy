//! Direct operations used by the existing @testable engine contract. Their
//! implementation is shared with normal parser dispatch, not a Swift fallback.
const std = @import("std");
const abi = @import("terminal_abi.zig");
const printing = @import("printing.zig");
const row = @import("row.zig");
const dispatch = @import("dispatch.zig");
const motion = @import("line_motion.zig");
const a = std.heap.c_allocator;

fn status(err: anyerror) abi.Status {
    return if (err == error.OutOfMemory) .out_of_memory else .engine_error;
}
pub export fn cmdy_zig_terminal_operation(handle: ?*abi.Handle, operation: u32,
    first: isize, second: isize, third: isize, params: ?[*]const isize, count: usize) abi.Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const values: []const isize = if (count == 0) &.{} else (params orelse return .invalid_input)[0..count];
    const t = &h.value;
    const result: anyerror!void = switch (operation) {
        1 => @import("sgr.zig").apply(&t.pen, values),
        2 => printing.printScalar(t, std.math.cast(u32, first) orelse return .invalid_input),
        3 => @import("modes.zig").setPrivateMode(t, first, second != 0),
        4 => dispatch.setCursorPosition(t, first, second),
        5 => dispatch.marginModeShift(t, first != 0, second, third),
        6 => dispatch.marginModeScroll(t, first != 0),
        7 => motion.engineScrollUp(t, first != 0, second != 0, third != 0),
        8 => motion.engineScrollDown(t, first != 0),
        9 => motion.lineFeed(t),
        10 => motion.indexLineFeed(t),
        11 => motion.reverseLineFeed(t),
        else => return .invalid_input,
    };
    result catch |err| return status(err);
    return .ok;
}
pub export fn cmdy_zig_terminal_insert_cell(handle: ?*abi.Handle, cell: ?*const row.Cell,
    extras: ?[*]const u32, count: usize, present: u8) abi.Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const value = cell orelse return .invalid_input;
    const tail: []const u32 = if (count == 0) &.{} else (extras orelse return .invalid_input)[0..count];
    printing.insertCellDirect(&h.value, .{ .cell = value.*, .extras = if (present != 0) tail else null }) catch |err| return status(err);
    return .ok;
}
pub export fn cmdy_zig_terminal_cell_edit(handle: ?*abi.Handle, first_row: isize, last_row: isize,
    first_col: isize, last_col: isize, flags: u8, context: ?*anyopaque,
    callback: ?*const fn (?*anyopaque) callconv(.c) void, handled: ?*u8) abi.Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    if (first_row > last_row or first_col > last_col) return .invalid_input;
    var guard = printing.beginCellEdit(&h.value, .{ .first = first_row, .last = last_row },
        .{ .first = first_col, .last = last_col }, .{
            .refreshSelectorMotion = flags & 1 != 0,
            .preserveBackwardAttachmentCoordinateOnInvalidation = flags & 2 != 0,
            .preserveLineRotationOwnerOnInvalidation = flags & 4 != 0,
            .refreshLineRotationOwnerAtSavedCoordinate = flags & 8 != 0,
        }) catch |err| return status(err);
    defer guard.deinit(a);
    if (callback) |edit| edit(context);
    const result = printing.endCellEdit(&h.value, &guard) catch |err| return status(err);
    if (handled) |out| out.* = @intFromBool(result);
    return .ok;
}
pub export fn cmdy_zig_terminal_witness_count(handle: ?*abi.Handle, kind: u32) usize {
    const h = abi.liveHandle(handle) orelse return 0;
    return switch (kind) {
        1 => h.value.print_state.activeMarginReflowBoundaries.items.len,
        2 => h.value.print_state.kittyDisplayReflowClaims.items.len,
        3 => h.value.print_state.kittyDisplayReflowBoundaries.items.len,
        4 => h.value.print_state.kittyDisplayClippedTopReflowRanks.items.len,
        5 => h.value.print_state.kittyDisplayReflowImages.items.len,
        else => 0,
    };
}
pub export fn cmdy_zig_terminal_witness(handle: ?*abi.Handle, kind: u32, index: usize) ?*anyopaque {
    const h = abi.liveHandle(handle) orelse return null;
    if (index >= cmdy_zig_terminal_witness_count(h, kind)) return null;
    return switch (kind) {
        1 => h.value.print_state.activeMarginReflowBoundaries.items[index].retain(),
        2 => h.value.print_state.kittyDisplayReflowClaims.items[index].retain(),
        3 => h.value.print_state.kittyDisplayReflowBoundaries.items[index].retain(),
        4 => h.value.print_state.kittyDisplayClippedTopReflowRanks.items[index].retain(),
        5 => h.value.print_state.kittyDisplayReflowImages.items[index].clone(),
        else => null,
    };
}
