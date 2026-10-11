//! C adapter for standalone and embedded parsers. The owner route stays native
//! unless the public Swift delegate is replaced; every original callback
//! boundary then resolves the currently installed route again.
const std = @import("std");
const parser = @import("parser.zig");
const Allocator = std.mem.Allocator;
pub const Status = enum(i32) { ok = 0, out_of_memory = 1, invalid_input = 2, disposed = 3, engine_error = 4 };
pub const EventKind = enum(u32) { print = 1, ascii, ascii_crlf, ascii_lines, execute, csi, esc, osc, dcs_hook, dcs_put, dcs_unhook, apc, unicode };
pub const Event = extern struct {
    kind: EventKind,
    argument: isize = 0,
    params: ?[*]const isize = null,
    param_count: usize = 0,
    collect: ?[*]const u8 = null,
    collect_count: usize = 0,
    bytes: ?[*]const u8 = null,
    byte_count: usize = 0,
    first_byte_count: usize = 0,
    /// Only unicode events expose this result, initialized to first_byte_count.
    /// A callback may consume that many or more bytes, up to byte_count.
    consumed: ?*usize = null,
};
pub const Callback = *const fn (?*anyopaque, *const Event) callconv(.c) void;
pub const DelegateRoute = extern struct {
    context: ?*anyopaque = null,
    event: ?Callback = null,
    /// Zero means the owning terminal itself; one means external or nil.
    use_external: u8 = 0,
};

pub const Handle = struct {
    allocator: Allocator,
    value: *parser.Parser,
    owns_parser: bool,
    call_depth: usize = 0,
    disposal_requested: bool = false,

    fn createOwned(a: Allocator) !*Handle {
        const h = try a.create(Handle);
        errdefer a.destroy(h);
        const p = try a.create(parser.Parser);
        errdefer a.destroy(p);
        p.* = try parser.Parser.init(a);
        h.* = .{ .allocator = a, .value = p, .owns_parser = true };
        return h;
    }
    fn createBorrowed(a: Allocator, p: *parser.Parser) !*Handle {
        const h = try a.create(Handle);
        h.* = .{ .allocator = a, .value = p, .owns_parser = false };
        return h;
    }
    fn enter(h: *Handle) bool {
        if (h.disposal_requested) return false;
        h.call_depth += 1;
        return true;
    }
    fn leave(h: *Handle) void {
        std.debug.assert(h.call_depth > 0);
        h.call_depth -= 1;
        if (h.call_depth == 0 and h.disposal_requested) h.destroy();
    }
    fn destroy(h: *Handle) void {
        const a = h.allocator;
        if (h.owns_parser) {
            h.value.deinit();
            a.destroy(h.value);
        }
        a.destroy(h);
    }
};

fn status(err: anyerror) Status {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.InvalidInput => .invalid_input,
        error.Disposed => .disposed,
        else => .engine_error,
    };
}
pub export fn cmdy_zig_parser_create() ?*Handle {
    return Handle.createOwned(std.heap.c_allocator) catch null;
}
/// The caller retains the terminal containing raw for the adapter's lifetime.
pub export fn cmdy_zig_parser_borrow(raw: ?*parser.Parser) ?*Handle {
    return Handle.createBorrowed(std.heap.c_allocator, raw orelse return null) catch null;
}
pub export fn cmdy_zig_parser_free(handle: ?*Handle) void {
    const h = handle orelse return;
    h.disposal_requested = true;
    if (h.call_depth == 0) h.destroy();
}
pub export fn cmdy_zig_parser_reset(handle: ?*Handle) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    h.value.reset();
    return .ok;
}
pub export fn cmdy_zig_parser_state(handle: ?*const Handle) u32 {
    const h = handle orelse return std.math.maxInt(u32);
    if (h.disposal_requested) return std.math.maxInt(u32);
    return @intFromEnum(h.value.state);
}
pub export fn cmdy_zig_parser_can_continue_unicode(handle: ?*const Handle) u8 {
    const h = handle orelse return 0;
    return @intFromBool(!h.disposal_requested and h.value.canContinueOrdinaryUnicodeBatch());
}
const option_fields = [_][]const u8{ "coalesces_printable_ascii", "decodes_contiguous_utf8", "batches_ordinary_unicode", "coalesces_csi_parameters" };
pub export fn cmdy_zig_parser_get_option(handle: ?*const Handle, option: u32) i32 {
    const h = handle orelse return -1;
    if (h.disposal_requested) return -1;
    inline for (option_fields, 1..) |field, key| if (option == key) return @intFromBool(@field(h.value, field));
    return -1;
}
pub export fn cmdy_zig_parser_set_option(handle: ?*Handle, option: u32, value: u8) Status {
    const h = handle orelse return .invalid_input;
    if (h.disposal_requested) return .disposed;
    inline for (option_fields, 1..) |field, key| if (option == key) {
        @field(h.value, field) = value != 0;
        return .ok;
    };
    return .invalid_input;
}
pub export fn cmdy_zig_parser_feed(handle: ?*Handle, bytes: ?[*]const u8, count: usize, context: ?*anyopaque, callback: ?Callback) Status {
    const h = handle orelse return .invalid_input;
    if (!h.enter()) return .disposed;
    defer h.leave();
    const input = if (count == 0) &.{} else (bytes orelse return .invalid_input)[0..count];
    h.value.feed(input, Sink{ .handle = h, .context = context, .callback = callback }) catch |err| return status(err);
    return .ok;
}

fn payload(kind: EventKind, bytes: []const u8) Event {
    return .{ .kind = kind, .bytes = bytes.ptr, .byte_count = bytes.len };
}
fn sequence(kind: EventKind, argument: isize, params: []const isize, collect: []const u8) Event {
    return .{ .kind = kind, .argument = argument, .params = params.ptr, .param_count = params.len, .collect = collect.ptr, .collect_count = collect.len };
}
const Sink = struct {
    handle: *Handle,
    context: ?*anyopaque,
    callback: ?Callback,
    fn emit(s: Sink, event: Event) !void {
        if (s.handle.disposal_requested) return error.Disposed;
        if (s.callback) |callback| callback(s.context, &event);
        if (s.handle.disposal_requested) return error.Disposed;
    }
    pub fn printScalar(s: Sink, scalar: u32) !void { try s.emit(.{ .kind = .print, .argument = scalar }); }
    pub fn printContiguousUnicode(s: Sink, bytes: []const u8, first: u32, first_byte_count: usize, _: *parser.Parser) !usize {
        var consumed = first_byte_count;
        try s.emit(.{ .kind = .unicode, .argument = first, .bytes = bytes.ptr, .byte_count = bytes.len,
            .first_byte_count = first_byte_count, .consumed = &consumed });
        return consumed;
    }
    pub fn printASCII(s: Sink, bytes: []const u8) !void { try s.emit(payload(.ascii, bytes)); }
    pub fn printASCIIAndCRLF(s: Sink, bytes: []const u8) !void { try s.emit(payload(.ascii_crlf, bytes)); }
    pub fn printASCIILines(s: Sink, bytes: []const u8) !void { try s.emit(payload(.ascii_lines, bytes)); }
    pub fn execute(s: Sink, byte: u8) !void { try s.emit(.{ .kind = .execute, .argument = byte }); }
    pub fn csi(s: Sink, final: u8, params: []const isize, collect: []const u8) !void { try s.emit(sequence(.csi, final, params, collect)); }
    pub fn esc(s: Sink, final: u8, collect: []const u8) !void { try s.emit(sequence(.esc, final, &.{}, collect)); }
    pub fn osc(s: Sink, code: isize, bytes: []const u8) !void { var e = payload(.osc, bytes); e.argument = code; try s.emit(e); }
    pub fn dcsHook(s: Sink, final: u8, params: []const isize, collect: []const u8) !void { try s.emit(sequence(.dcs_hook, final, params, collect)); }
    pub fn dcsPut(s: Sink, bytes: []const u8) !void { try s.emit(payload(.dcs_put, bytes)); }
    pub fn dcsUnhook(s: Sink) !void { try s.emit(.{ .kind = .dcs_unhook }); }
    pub fn apc(s: Sink, bytes: []const u8) !void { try s.emit(payload(.apc, bytes)); }
};

/// Route is read anew for each original delegate boundary. A callback can
/// replace or clear it before the outer feed resumes. Direct owner operations
/// deliberately bypass it, matching the frozen Swift OwnerOutput adapter.
pub fn OwnerSink(comptime T: type) type {
    return struct {
        owner: T,
        route: *DelegateRoute,
        const Self = @This();
        fn external(s: Self, event: Event) bool {
            if (s.route.use_external == 0) return false;
            const context = s.route.context;
            if (s.route.event) |callback| callback(context, &event);
            return true;
        }
        pub fn printScalar(s: Self, scalar: u32) anyerror!void {
            if (!s.external(.{ .kind = .print, .argument = scalar })) try s.owner.printScalar(scalar);
        }
        pub fn printContiguousScalar(s: Self, scalar: u32) anyerror!void { try s.owner.printScalar(scalar); }
        pub fn printContiguousUnicode(s: Self, bytes: []const u8, first: u32, first_byte_count: usize, source: *parser.Parser) anyerror!usize {
            if (@hasDecl(@typeInfo(T).pointer.child, "printOrdinaryUnicode")) {
                const Check = struct {
                    fn canContinue(context: ?*anyopaque) bool {
                        const p: *parser.Parser = @ptrCast(@alignCast(context.?));
                        return p.canContinueOrdinaryUnicodeBatch();
                    }
                };
                return s.owner.printOrdinaryUnicode(bytes, first, first_byte_count,
                    .{ .context = source, .can_continue = Check.canContinue });
            }
            try s.owner.printScalar(first);
            return first_byte_count;
        }
        pub fn printASCII(s: Self, bytes: []const u8) anyerror!void { try s.owner.printASCII(bytes); }
        pub fn printASCIIAndCRLF(s: Self, bytes: []const u8) anyerror!void { try s.owner.printASCIIAndCRLF(bytes); }
        pub fn printASCIILines(s: Self, bytes: []const u8) anyerror!void { try s.owner.printASCIILines(bytes); }
        pub fn executeGroundControl(s: Self, byte: u8) anyerror!void { try s.owner.execute(byte); }
        pub fn execute(s: Self, byte: u8) anyerror!void {
            if (!s.external(.{ .kind = .execute, .argument = byte })) try s.owner.execute(byte);
        }
        pub fn csiOwner(s: Self, final: u8, params: []const isize, collect: []const u8) anyerror!void {
            if (final == 'm') try s.owner.csi(final, params, collect) else try s.csi(final, params, collect);
        }
        pub fn csi(s: Self, final: u8, params: []const isize, collect: []const u8) anyerror!void {
            if (!s.external(sequence(.csi, final, params, collect))) try s.owner.csi(final, params, collect);
        }
        pub fn esc(s: Self, final: u8, collect: []const u8) anyerror!void {
            if (!s.external(sequence(.esc, final, &.{}, collect))) try s.owner.esc(final, collect);
        }
        pub fn osc(s: Self, code: isize, bytes: []const u8) anyerror!void {
            var e = payload(.osc, bytes); e.argument = code;
            if (!s.external(e)) try s.owner.osc(code, bytes);
        }
        pub fn dcsHook(s: Self, final: u8, params: []const isize, collect: []const u8) anyerror!void {
            if (!s.external(sequence(.dcs_hook, final, params, collect))) try s.owner.dcsHook(final, params, collect);
        }
        pub fn dcsPut(s: Self, bytes: []const u8) anyerror!void { if (!s.external(payload(.dcs_put, bytes))) try s.owner.dcsPut(bytes); }
        pub fn dcsUnhook(s: Self) anyerror!void { if (!s.external(.{ .kind = .dcs_unhook })) try s.owner.dcsUnhook(); }
        pub fn apc(s: Self, bytes: []const u8) anyerror!void { if (!s.external(payload(.apc, bytes))) try s.owner.apc(bytes); }
    };
}

test "standalone ABI owns parser and borrowed adapter leaves owner intact" {
    const a = std.testing.allocator;
    const h = try Handle.createOwned(a);
    const borrowed = try Handle.createBorrowed(a, h.value);
    try std.testing.expectEqual(Status.ok, cmdy_zig_parser_feed(borrowed, "\x1b[3".ptr, 4, null, null));
    try std.testing.expectEqual(@intFromEnum(parser.State.csi_param), cmdy_zig_parser_state(h));
    cmdy_zig_parser_free(borrowed);
    try std.testing.expectEqual(Status.ok, cmdy_zig_parser_reset(h));
    try std.testing.expectEqual(@intFromEnum(parser.State.ground), cmdy_zig_parser_state(h));
    cmdy_zig_parser_free(h);
}

test "ABI callback may reset reenter retain arguments and request disposal" {
    const Capture = struct {
        h: *Handle,
        count: usize = 0,
        good: bool = true,
        fn event(context: ?*anyopaque, e: *const Event) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(context.?));
            s.count += 1;
            if (s.count == 1) {
                s.good = s.good and e.kind == .csi and e.params.?[0] == 31 and cmdy_zig_parser_state(s.h) == 0;
                s.good = s.good and cmdy_zig_parser_reset(s.h) == .ok;
                const nested = "\x1b[32;44m\x1b[";
                s.good = s.good and cmdy_zig_parser_feed(s.h, nested.ptr, nested.len, context, event) == .ok;
                s.good = s.good and e.params.?[0] == 31 and e.params.?[1] == 1;
            } else if (s.count == 3) cmdy_zig_parser_free(s.h);
        }
    };
    const h = try Handle.createOwned(std.testing.allocator);
    var capture = Capture{ .h = h };
    const input = "\x1b[31;1m0mZ";
    try std.testing.expectEqual(Status.disposed, cmdy_zig_parser_feed(h, input.ptr, input.len, &capture, Capture.event));
    try std.testing.expect(capture.good);
    try std.testing.expectEqual(@as(usize, 3), capture.count);
}

test "ABI validates empty inputs and shares actual native parser options" {
    const h = try Handle.createOwned(std.testing.allocator);
    defer cmdy_zig_parser_free(h);
    try std.testing.expectEqual(Status.ok, cmdy_zig_parser_feed(h, null, 0, null, null));
    try std.testing.expectEqual(Status.invalid_input, cmdy_zig_parser_feed(h, null, 1, null, null));
    try std.testing.expectEqual(Status.invalid_input, cmdy_zig_parser_set_option(h, 100, 0));
    for (1..5) |option| {
        try std.testing.expectEqual(Status.ok, cmdy_zig_parser_set_option(h, @intCast(option), 0));
        try std.testing.expectEqual(@as(i32, 0), cmdy_zig_parser_get_option(h, @intCast(option)));
    }
    try std.testing.expect(!h.value.coalesces_csi_parameters);
    try std.testing.expect(!h.value.batches_ordinary_unicode);
}

test "owner route preserves complete versus chunked and extended dispatch boundaries" {
    const Capture = struct {
        counts: [13]usize = @splat(0),
        fn event(context: ?*anyopaque, e: *const Event) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(context.?));
            s.counts[@intFromEnum(e.kind)] += 1;
        }
    };
    const h = try Handle.createOwned(std.testing.allocator);
    defer cmdy_zig_parser_free(h);
    var native = Capture{};
    var external = Capture{};
    var native_sink = Sink{ .handle = h, .context = &native, .callback = Capture.event };
    var route = DelegateRoute{ .context = &external, .event = Capture.event, .use_external = 1 };
    const owner = OwnerSink(*Sink){ .owner = &native_sink, .route = &route };
    try h.value.feed("A\r\n\r\n\x07\xc3\xa9\x1b[31m\x1b[H", owner);
    try std.testing.expectEqual(@as(usize, 1), native.counts[3]); // ASCII+CRLF
    try std.testing.expectEqual(@as(usize, 2), native.counts[5]); // direct CR/LF
    try std.testing.expectEqual(@as(usize, 1), native.counts[1]); // contiguous UTF8
    try std.testing.expectEqual(@as(usize, 1), native.counts[6]); // prefix SGR
    try std.testing.expectEqual(@as(usize, 1), external.counts[5]); // BEL remains weak
    try std.testing.expectEqual(@as(usize, 1), external.counts[6]); // non-SGR CSI
    try h.value.feed("\xc3", owner);
    try h.value.feed("\xa9\xc0\x1b[3", owner);
    try h.value.feed("1m\x1b[38:5:2m", owner);
    try std.testing.expectEqual(@as(usize, 2), external.counts[1]);
    try std.testing.expectEqual(@as(usize, 3), external.counts[6]);
    h.value.coalesces_printable_ascii = false;
    h.value.coalesces_csi_parameters = false;
    h.value.decodes_contiguous_utf8 = false;
    try h.value.feed("X\xc3\xa9\x1b[32m", owner);
    try std.testing.expectEqual(@as(usize, 4), external.counts[1]);
    try std.testing.expectEqual(@as(usize, 4), external.counts[6]);
    h.value.coalesces_csi_parameters = true;
    const long = "\x1b[" ++ "1;" ** 32 ++ "1m";
    try h.value.feed(long, owner);
    const capped = "\x1b[" ++ "1" ** 256 ++ "m";
    try h.value.feed(capped, owner);
    try std.testing.expectEqual(@as(usize, 6), external.counts[6]);
    try std.testing.expectEqual(@as(usize, 1), native.counts[6]);
    route.event = null; // Explicit nil suppresses only weak delegate events.
    try h.value.feed("X\x07\r\n\x1b[31m", owner);
    try std.testing.expectEqual(@as(usize, 4), native.counts[5]);
    try std.testing.expectEqual(@as(usize, 2), native.counts[6]);
    try std.testing.expectEqual(@as(usize, 4), external.counts[1]);
}

test "owner route resolves replacements made by an external callback" {
    const Capture = struct {
        route: *DelegateRoute,
        calls: usize = 0,
        fn event(context: ?*anyopaque, _: *const Event) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(context.?));
            s.calls += 1;
            s.route.use_external = 0;
        }
    };
    const h = try Handle.createOwned(std.testing.allocator);
    defer cmdy_zig_parser_free(h);
    var route = DelegateRoute{ .use_external = 1 };
    var native = Capture{ .route = &route };
    var external = Capture{ .route = &route };
    route.context = &external;
    route.event = Capture.event;
    var native_sink = Sink{ .handle = h, .context = &native, .callback = Capture.event };
    try h.value.feed("\x1b[H\x07\x1b[H", OwnerSink(*Sink){ .owner = &native_sink, .route = &route });
    try std.testing.expectEqual(@as(usize, 1), external.calls);
    try std.testing.expectEqual(@as(usize, 2), native.calls);
}

test "Unicode ABI callback returns a validated consumed count and can leave parser state" {
    const Capture = struct {
        h: *Handle,
        calls: usize = 0,
        good: bool = true,
        invalid: bool = false,
        fn event(context: ?*anyopaque, e: *const Event) callconv(.c) void {
            const s: *@This() = @ptrCast(@alignCast(context.?));
            s.calls += 1;
            if (e.kind == .unicode) {
                s.good = s.good and e.argument == 0xe9 and e.first_byte_count == 2;
                if (s.invalid) { e.consumed.?.* = e.byte_count + 1; return; }
                // First scalar insertion may reenter and leave an incomplete
                // sequence. Its remaining bytes must go back to the parser.
                s.good = s.good and cmdy_zig_parser_feed(s.h, "\x1b[".ptr, 2, context, event) == .ok;
                e.consumed.?.* = e.first_byte_count;
            } else if (e.kind == .csi) {
                s.good = s.good and e.argument == 'm' and e.params.?[0] == 31;
            }
        }
    };
    const h = try Handle.createOwned(std.testing.allocator);
    defer cmdy_zig_parser_free(h);
    var capture = Capture{ .h = h };
    const input = "\xc3\xa9" ++ "31m";
    try std.testing.expectEqual(Status.ok, cmdy_zig_parser_feed(h, input.ptr, input.len, &capture, Capture.event));
    try std.testing.expect(capture.good);
    try std.testing.expectEqual(@as(usize, 2), capture.calls);
    try std.testing.expectEqual(@as(u32, 0), cmdy_zig_parser_state(h));
    capture.invalid = true;
    try std.testing.expectEqual(Status.invalid_input, cmdy_zig_parser_feed(h, input.ptr, input.len, &capture, Capture.event));
}
