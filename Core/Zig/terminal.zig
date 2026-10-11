//! CMDY's native terminal owner. The host supplies platform effects; it does not
//! parse input or own the grid. This file is not selected by the app until the
//! complete engine qualifies against the frozen Swift behavior.
const std = @import("std");
const parser_mod = @import("parser.zig");
const parser_abi = @import("parser_abi.zig");
const buffer_mod = @import("buffer.zig");
const line_mod = @import("line.zig");
const row_mod = @import("row.zig");
const blocks_mod = @import("blocks.zig");
const modes = @import("modes.zig");
const dispatch = @import("dispatch.zig");
const printing = @import("printing.zig");
const protocols = @import("terminal_protocols.zig");
const geometry = @import("terminal_geometry.zig");
const graphics = @import("graphics.zig");
const sixel_mod = @import("sixel.zig");
pub const Cell = row_mod.Cell;
pub const Buffer = buffer_mod.Buffer;
pub const Line = line_mod.Line;
pub const ParserDelegateEvent = parser_abi.Event;
pub const CursorShape = enum(u8) { blink_block, steady_block, blink_underline, steady_underline, blink_bar, steady_bar };
pub const MouseMode = enum(u8) { off, x10, vt200, button_event, any_event };
pub const MouseProtocol = enum(u8) { x10, utf8, sgr, urxvt };
pub const Span = extern struct { first: isize, last: isize };

pub const EventKind = enum(u32) {
    send = 1,
    title,
    directory,
    bell,
    clipboard_write,
    content_changed,
    will_reflow,
    did_reflow,
    notification,
    osc,
    blocks_changed,
    command_finished,
    record_input,
    failed_command,
};
pub const Event = extern struct {
    kind: EventKind,
    argument: isize = 0,
    argument2: isize = 0,
    bytes: ?[*]const u8 = null,
    length: usize = 0,
    bytes2: ?[*]const u8 = null,
    length2: usize = 0,
    /// Borrowed for this callback; object-specific ABI retain extends lifetime.
    object: ?*anyopaque = null,
};
pub const Host = extern struct {
    context: ?*anyopaque = null,
    event: ?*const fn (?*anyopaque, *const Event) callconv(.c) void = null,
    now: ?*const fn (?*anyopaque) callconv(.c) f64 = null,
};

pub const Terminal = struct {
    allocator: std.mem.Allocator,
    normal: Buffer,
    alternate: Buffer,
    parser: parser_mod.Parser,
    parser_delegate: parser_abi.DelegateRoute = .{},
    host: Host = .{},
    /// Subscription only: all block mutations and generation updates still run.
    /// Raw native hosts receive every event unless they explicitly opt out.
    block_change_events_enabled: bool = true,
    is_alternate: bool = false,
    pen: Cell = .{},
    application_cursor_keys: bool = false,
    origin_mode: bool = false,
    auto_wrap: bool = true,
    insert_mode: bool = false,
    line_feed_mode: bool = false,
    cursor_hidden: bool = false,
    reverse_video: bool = false,
    bracketed_paste: bool = false,
    focus_reporting: bool = false,
    cursor_blink: bool = true,
    cursor_style: CursorShape = .blink_block,
    mouse_mode: MouseMode = .off,
    mouse_protocol: MouseProtocol = .x10,
    synchronized_updates: bool = false,
    allow_80_to_132: bool = true,
    margin_mode: bool = false,
    reverse_wraparound: bool = false,
    keyboard_normal: std.ArrayList(isize) = .empty,
    keyboard_alt: std.ArrayList(isize) = .empty,
    title: []u8 = &.{},
    title_stack: std.ArrayList([]u8) = .empty,
    links: std.ArrayList([]u8) = .empty,
    active_link_id: u16 = 0,
    blocks: blocks_mod.BlockTracker,
    blocks_dropped_checkpoint: isize = 0,
    writing_host_message: bool = false,
    has_failed_command_provider: bool = false,
    recording: bool = false,
    gl_level: u8 = 0,
    dirty: ?Span = null,
    print_state: printing.State = .{},
    protocol_state: protocols.State,

    pub fn init(a: std.mem.Allocator, cols: isize, rows: isize, scrollback: isize) !Terminal {
        var normal = try Buffer.init(a, cols, rows, true, scrollback);
        errdefer normal.deinit();
        var alternate = try Buffer.init(a, cols, rows, true, 1);
        errdefer alternate.deinit();
        var parser = try parser_mod.Parser.init(a);
        errdefer parser.deinit();
        normal.margin_left = 0;
        normal.margin_right = cols - 1;
        const protocol_state = try protocols.State.init(a);
        // Register only after every fallible constructor succeeds. The cache
        // follows terminal lifetime, including screen clears between bursts.
        if (a.vtable == std.heap.c_allocator.vtable)
            @import("row_backing_pool.zig").beginTerminal();
        return .{
            .allocator = a,
            .normal = normal,
            .alternate = alternate,
            .parser = parser,
            .blocks = blocks_mod.BlockTracker.init(a),
            .protocol_state = protocol_state,
        };
    }

    pub fn deinit(t: *Terminal) void {
        const pooled = t.allocator.vtable == std.heap.c_allocator.vtable;
        defer if (pooled) @import("row_backing_pool.zig").endTerminal();
        t.print_state.deinit(t.allocator);
        t.protocol_state.deinit();
        t.parser.deinit();
        t.normal.deinit();
        t.alternate.deinit();
        t.blocks.deinit();
        t.keyboard_normal.deinit(t.allocator);
        t.keyboard_alt.deinit(t.allocator);
        t.allocator.free(t.title);
        for (t.title_stack.items) |entry| t.allocator.free(entry);
        t.title_stack.deinit(t.allocator);
        for (t.links.items) |entry| t.allocator.free(entry);
        t.links.deinit(t.allocator);
    }

    pub fn buffer(t: *Terminal) *Buffer {
        return if (t.is_alternate) &t.alternate else &t.normal;
    }
    pub fn constBuffer(t: *const Terminal) *const Buffer {
        return if (t.is_alternate) &t.alternate else &t.normal;
    }
    pub fn usingMargins(t: *const Terminal) bool {
        return t.origin_mode and t.margin_mode;
    }
    pub fn hasNarrowMargins(t: *const Terminal) bool {
        const b = t.constBuffer();
        return t.margin_mode and (b.margin_left > 0 or b.margin_right < b.cols - 1);
    }
    pub fn eraseCell(t: *const Terminal) Cell {
        return .{ .bg = t.pen.bg };
    }
    pub fn penCell(t: *const Terminal, scalar: u32, width: i8) Cell {
        var cell = t.pen;
        cell.scalar = scalar;
        cell.width = width;
        cell.link_id = t.active_link_id;
        return cell;
    }

    pub fn emit(t: *Terminal, event: Event) void {
        // No borrowed grid access survives this call. Event bytes are owned by
        // the caller for the duration; nested engine calls may mutate t.
        if (event.kind == .blocks_changed and !t.block_change_events_enabled) return;
        const host = t.host;
        if (host.event) |callback| callback(host.context, &event);
    }
    pub fn now(t: *Terminal) f64 {
        const host = t.host;
        return if (host.now) |callback| callback(host.context) else 0;
    }
    pub fn sendResponse(t: *Terminal, bytes: []const u8) !void {
        t.emit(.{ .kind = .send, .bytes = bytes.ptr, .length = bytes.len });
    }
    pub fn setTitle(t: *Terminal, bytes: []const u8) !void {
        const value = try t.allocator.dupe(u8, bytes);
        t.allocator.free(t.title);
        t.title = value;
        // Callback data must not alias t.title: a nested title change releases it.
        const delivered = try t.allocator.dupe(u8, value);
        defer t.allocator.free(delivered);
        t.emit(.{ .kind = .title, .bytes = delivered.ptr, .length = delivered.len });
    }

    pub fn feed(t: *Terminal, bytes: []const u8) anyerror!void {
        if (t.recording) t.emit(.{ .kind = .record_input, .bytes = bytes.ptr, .length = bytes.len });
        var sink = parser_abi.OwnerSink(*Terminal){ .owner = t, .route = &t.parser_delegate };
        try t.parser.feed(bytes, &sink);
        t.synchronizeBlockRowsToScrollback();
        t.emit(.{ .kind = .content_changed });
    }
    pub fn synchronizeBlockRowsToScrollback(t: *Terminal) void {
        const current = t.normal.dropped_lines;
        if (current < t.blocks_dropped_checkpoint) {
            t.blocks_dropped_checkpoint = current;
            return;
        }
        const dropped = current - t.blocks_dropped_checkpoint;
        if (dropped > 0) {
            t.blocks.rebase(dropped);
            t.emit(.{ .kind = .blocks_changed });
        }
        t.blocks_dropped_checkpoint = current;
    }
    pub fn markDirty(t: *Terminal, row: isize) void {
        if (t.dirty) |*span| {
            span.first = @min(span.first, row);
            span.last = @max(span.last, row);
        } else t.dirty = .{ .first = row, .last = row };
    }
    pub fn markDirtyRange(t: *Terminal, first: isize, last: isize) void {
        t.markDirty(first);
        t.markDirty(last);
    }
    pub fn markAllDirty(t: *Terminal) void {
        const b = t.buffer();
        t.dirty = .{ .first = b.y_disp, .last = b.y_disp + b.rows - 1 };
    }
    pub fn consumeDirtyRows(t: *Terminal) ?Span {
        const result = t.dirty;
        t.dirty = null;
        return result;
    }
    pub fn scrollViewport(t: *Terminal, requested: isize) void {
        const b = t.buffer();
        const next = std.math.clamp(requested, 0, b.y_base);
        if (next == b.y_disp) return;
        b.y_disp = next;
        t.emit(.{ .kind = .content_changed });
    }
    fn markControlDamage(t: *Terminal, previous_row: isize, previous_base: isize) void {
        const b = t.buffer();
        const scrolled = b.y_base - previous_base;
        if (scrolled > 0 and scrolled < b.rows) t.markDirtyRange(b.y_base + b.rows - scrolled, b.y_base + b.rows - 1) else if (scrolled != 0) t.markAllDirty() else {
            t.markDirty(previous_row);
            t.markDirty(b.y_base + b.y);
        }
    }

    // Parser sinks. These calls stay inside the Zig compilation unit.
    pub fn printScalar(t: *Terminal, scalar: u32) anyerror!void {
        try printing.printScalar(t, scalar);
        t.markDirty(t.buffer().y_base + t.buffer().y);
    }
    pub fn printOrdinaryUnicode(t: *Terminal, bytes: []const u8, first: u32, first_byte_count: usize,
        continuation: ?@import("ordinary_printing.zig").Continuation) anyerror!usize
    {
        return @import("ordinary_printing.zig").print(t, bytes, first, first_byte_count, continuation);
    }
    pub fn printASCII(t: *Terminal, bytes: []const u8) anyerror!void {
        try printing.printASCII(t, bytes);
    }
    pub fn printASCIIAndCRLF(t: *Terminal, bytes: []const u8) anyerror!void {
        try t.printASCII(bytes);
        const b = t.buffer();
        const row = b.y_base + b.y;
        const base = b.y_base;
        try t.executeControl(0x0d);
        try t.executeControl(0x0a);
        t.markControlDamage(row, base);
    }
    pub fn printASCIILines(t: *Terminal, bytes: []const u8) anyerror!void {
        var start: usize = 0;
        while (start < bytes.len) {
            const end = std.mem.indexOfScalarPos(u8, bytes, start, 0x0d) orelse return;
            try t.printASCIIAndCRLF(bytes[start..end]);
            start = @min(end + 2, bytes.len);
        }
    }
    pub fn execute(t: *Terminal, byte: u8) anyerror!void {
        const b = t.buffer();
        const row = b.y_base + b.y;
        const base = b.y_base;
        try t.executeControl(byte);
        t.markControlDamage(row, base);
    }
    pub fn csi(t: *Terminal, final: u8, params: []const isize, collect: []const u8) anyerror!void {
        if (final == 'm') {
            if (collect.len == 0) @import("sgr.zig").apply(&t.pen, params);
            t.markDirty(t.buffer().y_base + t.buffer().y);
            return;
        }
        const before = t.buffer().y_base + t.buffer().y;
        try dispatch.csi(t, final, params, collect);
        const b = t.buffer();
        const row = b.y_base + b.y;
        switch (final) {
            'L', 'M', 'S', 'T', 'r', 'p' => t.markAllDirty(),
            'J' => switch (if (params.len > 0) params[0] else 0) {
                2, 3 => t.markAllDirty(),
                1 => t.markDirtyRange(b.y_base, @max(b.y_base, row)),
                else => t.markDirtyRange(@min(row, b.y_base + b.rows - 1), b.y_base + b.rows - 1),
            },
            'h', 'l' => {
                const entire = for (params) |p| {
                    if (p == 3 or p == 5 or p == 47 or p == 1047 or p == 1049) break true;
                } else false;
                if (entire) t.markAllDirty() else {
                    t.markDirty(before);
                    t.markDirty(row);
                }
            },
            else => {
                t.markDirty(before);
                t.markDirty(row);
            },
        }
    }
    pub fn esc(t: *Terminal, final: u8, collect: []const u8) anyerror!void {
        const base = t.buffer().y_base;
        try dispatch.esc(t, final, collect);
        if (t.buffer().y_base != base or std.mem.indexOfScalar(u8, "c8MDE69", final) != null) t.markAllDirty() else t.markDirty(t.buffer().y_base + t.buffer().y);
    }
    pub const osc = protocols.osc;
    pub const dcsHook = protocols.dcsHook;
    pub const dcsPut = protocols.dcsPut;
    pub const dcsUnhook = protocols.dcsUnhook;
    pub const apc = protocols.apc;
    pub const resize = geometry.resize;
    pub const insertHostMessage = printing.insertHostMessage;
    pub const executeControl = printing.executeControl;
    pub const setActiveBuffer = printing.setActiveBuffer;
    pub const saveCursor = dispatch.saveCursor;
    pub const restoreCursor = dispatch.restoreCursor;
    pub const fullReset = dispatch.fullReset;
    pub const softReset = dispatch.softReset;
    pub const keyboardFlags = modes.keyboardFlags;
};
