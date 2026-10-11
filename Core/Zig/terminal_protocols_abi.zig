//! Raw graphics helpers retain the same reentrant engine call guard as the
//! public terminal ABI, independently of parser-owned APC bookkeeping.
const engine = @import("terminal_abi.zig");
const protocols = @import("terminal_protocols.zig");

pub export fn cmdy_zig_terminal_handle_apc(handle: ?*engine.Handle, bytes: ?[*]const u8,
    count: usize, out: ?*u8) engine.Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    if ((count != 0 and bytes == null) or out == null) return .invalid_input;
    out.?.* = 0;
    const motion = protocols.handleAPC(&h.value, if (count == 0) &.{} else bytes.?[0..count]) catch |err| {
        return switch (err) { error.OutOfMemory => .out_of_memory, error.InvalidInput => .invalid_input, else => .engine_error };
    };
    out.?.* = @intFromBool(motion);
    return .ok;
}
