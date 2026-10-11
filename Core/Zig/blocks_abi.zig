//! Shared semantic block identity and tracker host bridge.
const std = @import("std");
const blocks = @import("blocks.zig");
const Block = blocks.Block;
const Tracker = blocks.BlockTracker;
const a = std.heap.c_allocator;
const LifetimeCallback = *const fn (?*anyopaque, u8) callconv(.c) void;
const RowMap = *const fn (?*anyopaque, isize) callconv(.c) isize;
const Bridge = struct {
    context: *anyopaque,
    callback: LifetimeCallback,
    native_owned: bool = true,
    fn retained(raw_context: *anyopaque, value: *Block) void {
        const bridge: *Bridge = @ptrCast(@alignCast(raw_context));
        if (bridge.native_owned) return;
        bridge.native_owned = true;
        bridge.callback(bridge.context, 1);
        _ = value.refs.fetchSub(1, .monotonic);
    }
    fn finalRelease(raw_context: *anyopaque, value: *Block) bool {
        const bridge: *Bridge = @ptrCast(@alignCast(raw_context));
        std.debug.assert(bridge.native_owned);
        bridge.native_owned = false;
        value.refs.store(1, .release);
        const context = bridge.context;
        const callback = bridge.callback;
        callback(context, 0);
        return true; // Callback may have freed bridge and block.
    }
};
pub const BlockInfo = extern struct {
    index: u64 = 0,
    prompt_row: isize = 0,
    input_row: isize = 0,
    input_col: isize = 0,
    command_row: isize = 0,
    end_row: isize = 0,
    exit_code: isize = 0,
    started_at: f64 = 0,
    finished_at: f64 = 0,
    has_input: u8 = 0,
    has_end: u8 = 0,
    has_exit: u8 = 0,
    has_finished: u8 = 0,
    running: u8 = 0,
};
export fn cmdy_zig_block_create(index: u64, row: isize, timestamp: f64) ?*Block {
    const block = a.create(Block) catch return null;
    block.* = .{ .allocator = a, .index = index, .prompt_row = row, .command_row = row, .started_at = timestamp };
    return block;
}
export fn cmdy_zig_block_retain(block: ?*Block) ?*Block { return if (block) |b| b.retain() else null; }
export fn cmdy_zig_block_release(block: ?*Block) void { if (block) |b| b.release(); }
export fn cmdy_zig_block_info(block: ?*const Block, out: ?*BlockInfo) i32 {
    const b = block orelse return -1;
    (out orelse return -1).* = .{ .index = b.index, .prompt_row = b.prompt_row,
        .input_row = if (b.input_start) |s| s.row else 0, .input_col = if (b.input_start) |s| s.col else 0,
        .command_row = b.command_row, .end_row = b.end_row orelse 0, .exit_code = b.exit_code orelse 0,
        .started_at = b.started_at, .finished_at = b.finished_at orelse 0,
        .has_input = @intFromBool(b.input_start != null), .has_end = @intFromBool(b.end_row != null),
        .has_exit = @intFromBool(b.exit_code != null), .has_finished = @intFromBool(b.finished_at != null), .running = @intFromBool(b.running) };
    return 0;
}
export fn cmdy_zig_block_set_info(block: ?*Block, input: ?*const BlockInfo) i32 {
    const b = block orelse return -1;
    const i = input orelse return -1;
    if (i.has_input > 1 or i.has_end > 1 or i.has_exit > 1 or i.has_finished > 1 or i.running > 1) return -1;
    b.prompt_row = i.prompt_row;
    b.input_start = if (i.has_input != 0) .{ .row = i.input_row, .col = i.input_col } else null;
    b.command_row = i.command_row;
    b.end_row = if (i.has_end != 0) i.end_row else null;
    b.exit_code = if (i.has_exit != 0) i.exit_code else null;
    b.started_at = i.started_at;
    b.finished_at = if (i.has_finished != 0) i.finished_at else null;
    b.running = i.running != 0;
    return 0;
}
export fn cmdy_zig_block_swift_context(block: ?*const Block) ?*anyopaque {
    const observer = (block orelse return null).lifetime_observer orelse return null;
    const bridge: *Bridge = @ptrCast(@alignCast(observer.context));
    return bridge.context;
}
export fn cmdy_zig_block_associate(block: ?*Block, context: ?*anyopaque, callback: ?LifetimeCallback) i32 {
    const b = block orelse return -1;
    if (b.lifetime_observer != null or context == null or callback == null) return -1;
    const bridge = b.allocator.create(Bridge) catch return -2;
    bridge.* = .{ .context = context.?, .callback = callback.? };
    b.lifetime_observer = .{ .context = bridge, .retained = Bridge.retained, .final_release = Bridge.finalRelease };
    return 0;
}
export fn cmdy_zig_block_disassociate(block: ?*Block, context: ?*anyopaque) i32 {
    const b = block orelse return -1;
    const observer = b.lifetime_observer orelse return -1;
    const bridge: *Bridge = @ptrCast(@alignCast(observer.context));
    if (context != bridge.context or bridge.native_owned) return -1;
    b.lifetime_observer = null; b.allocator.destroy(bridge); return 0;
}
export fn cmdy_zig_blocks_create() ?*Tracker {
    const tracker = a.create(Tracker) catch return null; tracker.* = .init(a); return tracker;
}
export fn cmdy_zig_blocks_free(tracker: ?*Tracker) void { if (tracker) |t| { t.deinit(); a.destroy(t); } }
export fn cmdy_zig_blocks_count(tracker: ?*const Tracker) usize { return (tracker orelse return 0).blocks.items.len; }
export fn cmdy_zig_blocks_at(tracker: ?*const Tracker, index: usize) ?*Block {
    const t = tracker orelse return null; return if (index < t.blocks.items.len) t.blocks.items[index].retain() else null;
}
export fn cmdy_zig_blocks_last_completed(tracker: ?*const Tracker) ?*Block { return ((tracker orelse return null).lastCompletedBlock() orelse return null).retain(); }
export fn cmdy_zig_blocks_running(tracker: ?*const Tracker) u8 { return if (tracker) |t| @intFromBool(t.isRunning()) else 0; }
export fn cmdy_zig_blocks_prompt_started(tracker: ?*Tracker, row: isize, timestamp: f64) i32 {
    (tracker orelse return -1).promptStarted(row, timestamp) catch |err| return if (err == error.OutOfMemory) -2 else -1; return 0;
}
export fn cmdy_zig_blocks_prompt_ended(tracker: ?*Tracker, row: isize, col: isize) void { if (tracker) |t| t.promptEnded(row, col); }
export fn cmdy_zig_blocks_command_started(tracker: ?*Tracker, row: isize) u8 { return if (tracker) |t| @intFromBool(t.commandStarted(row)) else 0; }
export fn cmdy_zig_blocks_command_finished(tracker: ?*Tracker, row: isize, exit_code: isize, has_exit: u8, timestamp: f64) ?*Block {
    if (has_exit > 1) return null;
    return ((tracker orelse return null).commandFinished(row, if (has_exit != 0) exit_code else null, timestamp) orelse return null).retain();
}
export fn cmdy_zig_blocks_rebase(tracker: ?*Tracker, dropped: isize) void { if (tracker) |t| t.rebase(dropped); }
export fn cmdy_zig_blocks_reset(tracker: ?*Tracker) void { if (tracker) |t| t.reset(); }
export fn cmdy_zig_blocks_remap(tracker: ?*Tracker, context: ?*anyopaque, callback: ?RowMap) i32 {
    const t = tracker orelse return -1;
    const c = callback orelse return -1;
    // A Swift closure may reenter the tracker. Snapshot object references as
    // Swift's array iteration does; commit the final survivors after callbacks.
    var original: std.ArrayList(*Block) = .empty;
    original.ensureTotalCapacity(t.allocator, t.blocks.items.len) catch return -2;
    for (t.blocks.items) |b| original.appendAssumeCapacity(b.retain());
    var written: usize = 0;
    for (original.items) |b| {
        b.prompt_row = c(context, b.prompt_row);
        b.command_row = c(context, b.command_row);
        if (b.end_row) |row| b.end_row = c(context, row);
        if (b.input_start) |position| b.input_start = .{ .row = c(context, position.row), .col = position.col };
        if (b.prompt_row < 0) { b.release(); continue; }
        original.items[written] = b; written += 1;
    }
    original.items.len = written;
    var previous = t.blocks;
    t.blocks = original;
    t.generation +%= 1;
    for (previous.items) |b| b.release();
    previous.deinit(t.allocator);
    return 0;
}
