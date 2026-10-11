//! Same complete-state format as SwiftReference.swift. Build with engine module
//! mapped to an exact frozen Core/Zig/terminal.zig tree; no benchmark shortcuts.
const std = @import("std");
const engine = @import("engine");
const A = std.mem.Allocator;
const V = std.json.Value;
extern "c" fn read(c_int, [*]u8, usize) isize;
extern "c" fn write(c_int, [*]const u8, usize) isize;
fn object(a: A) V { return .{ .object = std.json.ObjectMap.init(a) }; }
fn array(a: A) V { return .{ .array = std.json.Array.init(a) }; }
fn put(value: *V, key: []const u8, item: V) !void { try value.object.put(key, item); }
fn add(value: *V, item: V) !void { try value.array.append(item); }
fn integer(value: anytype) V { return .{ .integer = @intCast(value) }; }
fn boolean(value: bool) V { return .{ .bool = value }; }
fn optInt(value: anytype) V { return if (value) |x| integer(x) else .null; }
fn bytes(a: A, value: []const u8) !V {
    var result = array(a);
    for (value) |byte| try add(&result, integer(byte));
    return result;
}
fn string(value: []const u8) V { return .{ .string = value }; }
fn numbers(a: A, values: anytype) !V {
    var result = array(a);
    for (values) |value| try add(&result, integer(value));
    return result;
}
fn hash(a: A, value: []const u8) !V {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    return string(try a.dupe(u8, &std.fmt.bytesToHex(digest, .lower)));
}
fn attribute(a: A, value: engine.Cell) !V {
    return numbers(a, &[_]i64{ value.fg, value.bg, value.style, value.underline_kind,
        if (value.underline_present != 0) value.underline_color else -1 });
}
fn cell(a: A, value: anytype) !V {
    var result = array(a);
    try add(&result, integer(value.cell.scalar));
    try add(&result, integer(value.cell.width));
    const attr = try attribute(a, value.cell);
    for (attr.array.items) |v| try add(&result, v);
    try add(&result, integer(value.cell.link_id));
    try add(&result, if (value.extras) |extra| integer(extra.len) else integer(-1));
    if (value.extras) |extra| for (extra) |scalar| { try add(&result, integer(scalar)); };
    return result;
}
fn payload(a: A, value: anytype) !V {
    var result = object(a);
    try put(&result, "format", string(@tagName(value.format)));
    try put(&result, "bytes", integer(value.bytes.len));
    try put(&result, "sha256", try hash(a, value.bytes));
    if (value.format == .rgba) {
        try put(&result, "width", integer(value.width));
        try put(&result, "height", integer(value.height));
    }
    return result;
}
fn lineImage(a: A, image: anytype) !V {
    var result = object(a);
    try put(&result, "payload", try payload(a, image.payload));
    try put(&result, "width", integer(image.pixel_width));
    try put(&result, "height", integer(image.pixel_height));
    try put(&result, "col", integer(image.col));
    try put(&result, "kitty", boolean(image.is_kitty));
    try put(&result, "image_id", optInt(image.image_id));
    try put(&result, "placement_id", optInt(image.placement_id));
    try put(&result, "z", integer(image.z_index));
    try put(&result, "offset_x", integer(image.offset_x));
    try put(&result, "offset_y", integer(image.offset_y));
    return result;
}
fn row(a: A, line: *engine.Line, detailed: bool) !V {
    var result = object(a);
    var cells = array(a);
    var digest = std.crypto.hash.sha2.Sha256.init(.{});
    var col: isize = 0;
    while (col < line.count()) : (col += 1) {
        const value = try cell(a, line.get(col));
        for (value.array.items) |part| {
            var encoded: [8]u8 = undefined;
            std.mem.writeInt(i64, &encoded, part.integer, .little);
            digest.update(&encoded);
        }
        if (detailed) try add(&cells, value);
    }
    var digest_bytes: [32]u8 = undefined;
    digest.final(&digest_bytes);
    try put(&result, "count", integer(line.count()));
    try put(&result, "sha256", string(try a.dupe(u8, &std.fmt.bytesToHex(digest_bytes, .lower))));
    try put(&result, "wrapped", boolean(line.is_wrapped));
    try put(&result, "wrap_style", integer(@intFromEnum(line.wrap_style)));
    try put(&result, "render", integer(@intFromEnum(line.render_mode)));
    try put(&result, "images_present", boolean(line.images != null));
    var images = array(a);
    if (line.images) |list| for (list.items) |image| { try add(&images, try lineImage(a, image)); };
    try put(&result, "images", images);
    if (detailed) try put(&result, "cells", cells);
    return result;
}
fn buffer(a: A, b: *engine.Buffer, detailed: bool) !V {
    var result = object(a);
    inline for (.{ "cols", "rows", "x", "y", "y_base", "y_disp", "scroll_top", "scroll_bottom", "margin_left", "margin_right", "max_scrollback" }) |key| try put(&result, key, integer(@field(b, key)));
    try put(&result, "dropped", integer(b.dropped_lines));
    try put(&result, "wrap_pending", boolean(b.wrap_pending));
    try put(&result, "has_scrollback", boolean(b.has_scrollback));
    var tabs: std.ArrayList(isize) = .empty;
    var iterator = b.tab_stops.keyIterator();
    while (iterator.next()) |key| try tabs.append(a, key.*);
    std.mem.sort(isize, tabs.items, {}, std.sort.asc(isize));
    try put(&result, "tabs", try numbers(a, tabs.items));
    var lines = array(a);
    var index: isize = 0;
    while (index < b.lineCount()) : (index += 1) try add(&lines, try row(a, b.line(index).?, detailed));
    try put(&result, "lines", lines);
    var saved: V = .null;
    if (b.saved_cursor) |s| {
        saved = object(a);
        try put(&saved, "x", integer(s.x)); try put(&saved, "y", integer(s.y));
        try put(&saved, "attribute", try attribute(a, s.attribute));
        inline for (.{ "wrap_pending", "origin_mode", "auto_wrap", "margin_mode", "reverse_wraparound" }) |key| try put(&saved, key, boolean(@field(s, key)));
    }
    try put(&result, "saved", saved);
    return result;
}
const Host = struct {
    allocator: A,
    events: V,
    failed: bool = false,
    fn event(context: ?*anyopaque, e: *const engine.Event) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.record(e) catch { self.failed = true; };
    }
    fn now(_: ?*anyopaque) callconv(.c) f64 { return 1.25; }
    fn parserEvent(context: ?*anyopaque, e: *const engine.ParserDelegateEvent) callconv(.c) void {
        const self: *Host = @ptrCast(@alignCast(context.?));
        self.recordParser(e) catch { self.failed = true; };
    }
    fn recordParser(self: *Host, e: *const engine.ParserDelegateEvent) !void {
        const a = self.allocator;
        var value = object(a);
        try put(&value, "kind", string("parser"));
        try put(&value, "method", integer(@intFromEnum(e.kind)));
        try put(&value, "argument", integer(e.argument));
        try put(&value, "params", try numbers(a, if (e.params) |p| p[0..e.param_count] else &[_]isize{}));
        try put(&value, "collect", try bytes(a, if (e.collect) |p| p[0..e.collect_count] else &.{}));
        try put(&value, "bytes", try bytes(a, if (e.bytes) |p| p[0..e.byte_count] else &.{}));
        try add(&self.events, value);
    }
    fn record(self: *Host, e: *const engine.Event) !void {
        const a = self.allocator;
        var value = object(a);
        try put(&value, "kind", string(@tagName(e.kind)));
        const first_bytes: []const u8 = if (e.bytes) |ptr| ptr[0..e.length] else &.{};
        switch (e.kind) {
            .send, .title, .clipboard_write, .record_input => try put(&value, "bytes", try bytes(a, first_bytes)),
            .directory => try put(&value, "bytes", if (e.bytes == null) .null else try bytes(a, first_bytes)),
            .notification => {
                try put(&value, "title", try bytes(a, first_bytes));
                try put(&value, "body", try bytes(a, if (e.bytes2) |p| p[0..e.length2] else &.{}));
            },
            .command_finished => try put(&value, "index", integer(e.argument2)),
            .osc => {
                try put(&value, "code", integer(e.argument));
                try put(&value, "bytes", try bytes(a, first_bytes));
            },
            else => {},
        }
        try add(&self.events, value);
    }
};
fn snapshot(a: A, t: *engine.Terminal, host: *Host, detailed: bool) !V {
    if (host.failed) return error.OutOfMemory;
    var result = object(a);
    try put(&result, "normal", try buffer(a, &t.normal, detailed));
    try put(&result, "alternate", try buffer(a, &t.alternate, detailed));
    try put(&result, "is_alternate", boolean(t.is_alternate));
    try put(&result, "pen", try attribute(a, t.pen));
    var mode_values = object(a);
    inline for (.{ "application_cursor_keys", "origin_mode", "auto_wrap", "insert_mode", "line_feed_mode", "cursor_hidden", "reverse_video", "bracketed_paste", "focus_reporting", "cursor_blink", "synchronized_updates", "allow_80_to_132", "margin_mode", "reverse_wraparound" }) |key| try put(&mode_values, key, boolean(@field(t, key)));
    try put(&result, "modes", mode_values);
    inline for (.{ "cursor_style", "mouse_mode", "mouse_protocol" }) |key| try put(&result, key, integer(@intFromEnum(@field(t, key))));
    try put(&result, "keyboard_normal", try numbers(a, t.keyboard_normal.items));
    try put(&result, "keyboard_alt", try numbers(a, t.keyboard_alt.items));
    try put(&result, "title", try bytes(a, t.title));
    var titles = array(a);
    for (t.title_stack.items) |title| try add(&titles, try bytes(a, title));
    try put(&result, "title_stack", titles);
    var links = array(a);
    for (t.protocol_state.links.entries.items) |link| try add(&links, try bytes(a, link));
    try put(&result, "links", links);
    try put(&result, "active_link_id", integer(t.active_link_id));
    try put(&result, "gl_level", integer(t.gl_level));
    var blocks = array(a);
    for (t.blocks.blocks.items) |block| {
        var value = object(a);
        inline for (.{ "index", "prompt_row", "command_row" }) |key| try put(&value, key, integer(@field(block, key)));
        try put(&value, "input_start", if (block.input_start) |p| try numbers(a, &[_]isize{ p.row, p.col }) else .null);
        try put(&value, "end_row", optInt(block.end_row));
        try put(&value, "exit_code", optInt(block.exit_code));
        try put(&value, "running", boolean(block.running));
        try put(&value, "started_at", .{ .float = block.started_at });
        try put(&value, "finished_at", if (block.finished_at) |f| .{ .float = f } else .null);
        try add(&blocks, value);
    }
    try put(&result, "blocks", blocks);
    try put(&result, "blocks_dropped_checkpoint", integer(t.blocks_dropped_checkpoint));
    try put(&result, "dirty", if (t.consumeDirtyRows()) |d| try numbers(a, &[_]isize{ d.first, d.last }) else .null);
    const store = &t.protocol_state.kitty.store;
    var graphics = object(a);
    var image_keys: std.ArrayList(u32) = .empty;
    try image_keys.appendSlice(a, store.images_by_id.keys());
    std.mem.sort(u32, image_keys.items, {}, std.sort.asc(u32));
    var images = array(a);
    for (image_keys.items) |key| {
        const image = store.images_by_id.get(key).?;
        var value = object(a);
        try put(&value, "id", integer(image.id));
        try put(&value, "number", optInt(image.number));
        try put(&value, "width", integer(image.payload.width));
        try put(&value, "height", integer(image.payload.height));
        try put(&value, "payload", try payload(a, image.payload));
        try add(&images, value);
    }
    try put(&graphics, "images", images);
    var placement_keys: std.ArrayList(u64) = .empty;
    try placement_keys.appendSlice(a, store.placements_by_key.keys());
    std.mem.sort(u64, placement_keys.items, {}, std.sort.asc(u64));
    var placements = array(a);
    for (placement_keys.items) |key| {
        const p = store.placements_by_key.get(key).?;
        var value = object(a);
        inline for (.{ "image_id", "placement_id", "col", "row", "cols", "rows", "offset_x", "offset_y" }) |name| try put(&value, name, integer(@field(p, name)));
        try put(&value, "z", integer(p.z_index));
        try put(&value, "virtual", boolean(p.is_virtual));
        try put(&value, "alternate", boolean(p.is_alternate_buffer));
        try add(&placements, value);
    }
    try put(&graphics, "placements", placements);
    inline for (.{ "payload_bytes", "next_image_id", "next_placement_id" }) |key| try put(&graphics, key, integer(@field(store, key)));
    try put(&result, "graphics", graphics);
    try put(&result, "parser_state", integer(@intFromEnum(t.parser.state)));
    var parser_options = array(a);
    inline for (.{ "coalesces_printable_ascii", "decodes_contiguous_utf8", "batches_ordinary_unicode", "coalesces_csi_parameters" }) |key| {
        try add(&parser_options, boolean(@field(t.parser, key)));
    }
    try put(&result, "parser_options", parser_options);
    try put(&result, "events", host.events);
    host.events = array(a);
    return result;
}
fn requiredInt(value: V, key: []const u8) isize { return @intCast(value.object.get(key).?.integer); }
fn outputAll(data: []const u8) !void {
    var index: usize = 0;
    while (index < data.len) {
        const n = write(1, data[index..].ptr, data.len - index);
        if (n <= 0) return error.WriteFailed;
        index += @intCast(n);
    }
}
pub fn main() !void {
    const alloc = std.heap.c_allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(alloc);
    var scratch: [65536]u8 = undefined;
    while (true) {
        const n = read(0, &scratch, scratch.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        try input.appendSlice(alloc, scratch[0..@intCast(n)]);
    }
    const parsed = try std.json.parseFromSlice(V, alloc, input.items, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    for (parsed.value.array.items) |request| {
        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const a = arena.allocator();
        var t = try engine.Terminal.init(alloc, requiredInt(request, "cols"), requiredInt(request, "rows"), requiredInt(request, "scrollback"));
        defer t.deinit();
        var host = Host{ .allocator = a, .events = array(a) };
        t.host = .{ .context = &host, .event = Host.event, .now = Host.now };
        if (request.object.get("parser_delegate")) |mode| {
            if (!std.mem.eql(u8, mode.string, "owner")) {
                if (!std.mem.eql(u8, mode.string, "custom") and !std.mem.eql(u8, mode.string, "nil")) return error.InvalidDelegate;
                t.parser_delegate = .{ .use_external = 1, .context = &host,
                    .event = if (std.mem.eql(u8, mode.string, "custom")) Host.parserEvent else null };
            }
        }
        if (request.object.get("parser_options")) |options| {
            if (options.array.items.len != 4) return error.InvalidOptions;
            inline for (.{ "coalesces_printable_ascii", "decodes_contiguous_utf8", "batches_ordinary_unicode", "coalesces_csi_parameters" }, 0..) |key, i| {
                @field(t.parser, key) = options.array.items[i].bool;
            }
        }
        const detailed = if (request.object.get("detailed")) |v| v.bool else false;
        var checkpoints = array(a);
        var initial = object(a);
        try put(&initial, "step", integer(-1));
        try put(&initial, "state", try snapshot(a, &t, &host, detailed));
        try add(&checkpoints, initial);
        for (request.object.get("steps").?.array.items, 0..) |step, i| {
            const op = step.object.get("op").?.string;
            if (std.mem.eql(u8, op, "feed")) {
                const encoded = step.object.get("bytes").?.array.items;
                const data = try a.alloc(u8, encoded.len);
                for (encoded, data) |v, *byte| byte.* = @intCast(v.integer);
                try t.feed(data);
            } else if (std.mem.eql(u8, op, "resize")) {
                try t.resize(requiredInt(step, "cols"), requiredInt(step, "rows"));
            } else if (std.mem.eql(u8, op, "viewport")) {
                t.scrollViewport(requiredInt(step, "row"));
            } else if (std.mem.eql(u8, op, "host_message")) {
                try t.insertHostMessage(step.object.get("text").?.string);
            } else if (std.mem.eql(u8, op, "reset")) {
                try t.fullReset();
            } else return error.UnknownOperation;
            if (if (step.object.get("checkpoint")) |v| v.bool else true) {
                var point = object(a);
                try put(&point, "step", integer(i));
                try put(&point, "state", try snapshot(a, &t, &host, detailed));
                try add(&checkpoints, point);
            }
        }
        var result = object(a);
        try put(&result, "name", request.object.get("name").?);
        try put(&result, "checkpoints", checkpoints);
        try outputAll(try std.json.Stringify.valueAlloc(a, result, .{}));
        try outputAll("\n");
    }
}
