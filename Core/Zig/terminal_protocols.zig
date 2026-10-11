//! Terminal integration for native OSC/DCS/APC support and Kitty reflow
//! witnesses. Host effects are emitted only after owned state is consistent.
const std = @import("std");
const graphics = @import("graphics.zig");
const osc_mod = @import("osc.zig");
const sixel_mod = @import("sixel.zig");
const blocks_mod = @import("blocks.zig");
const Line = @import("line.zig").Line;
const Buffer = @import("buffer.zig").Buffer;
const printing = @import("printing.zig");
const motion = @import("line_motion.zig");
const Allocator = std.mem.Allocator;

pub const State = struct {
    allocator: Allocator,
    kitty: graphics.KittyEngine,
    links: osc_mod.LinkTable,
    sixel: ?*sixel_mod.SixelDecoder = null,
    dcs_kind: enum { none, sixel, decrqss, other } = .none,
    decrqss: std.ArrayList(u8) = .empty,
    inline_budget: graphics.InlineBudget = .{},

    pub fn init(a: Allocator) Allocator.Error!State {
        return .{ .allocator = a, .kitty = .init(a), .links = .init(a) };
    }
    pub fn deinit(self: *State) void {
        self.clearSixel();
        self.kitty.deinit();
        self.links.deinit();
        self.decrqss.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn clearSixel(self: *State) void {
        if (self.sixel) |decoder| {
            decoder.deinit();
            self.allocator.destroy(decoder);
        }
        self.sixel = null;
    }
};

pub fn pruneKittyDisplayReflowImages(t: anytype) void {
    const s = &t.print_state;
    var index: usize = 0;
    while (index < s.kittyDisplayReflowImages.items.len) {
        const identity = s.kittyDisplayReflowImages.items[index].render_id;
        var retained = false;
        for (s.kittyDisplayReflowImageTransfers.items) |transfer| {
            if (transfer.image.render_id == identity) { retained = true; break; }
        }
        if (!retained) {
            for ([_]*Buffer{ &t.normal, &t.alternate }) |screen| {
                if (findImageLine(screen, identity) != null) { retained = true; break; }
            }
        }
        if (retained) { index += 1; continue; }
        var image = s.kittyDisplayReflowImages.orderedRemove(index);
        image.deinit();
    }
    index = 0;
    while (index < s.kittyDisplayReflowImageTransfers.items.len) {
        const identity = s.kittyDisplayReflowImageTransfers.items[index].image.render_id;
        const retained = for (s.kittyDisplayReflowImages.items) |image| {
            if (image.render_id == identity) break true;
        } else false;
        if (retained) { index += 1; continue; }
        var transfer = s.kittyDisplayReflowImageTransfers.orderedRemove(index);
        transfer.deinit();
    }
}

fn hasImage(line: *const Line, identity: u128) bool {
    if (line.images) |images| for (images.items) |image| {
        if (image.render_id == identity) return true;
    };
    return false;
}

fn findImageLine(screen: *const Buffer, identity: u128) ?*Line {
    for (screen.storage.items[screen.line_start..]) |item| if (hasImage(item.?, identity)) return item.?;
    return null;
}

fn containsLine(screen: *const Buffer, line: *Line) bool {
    for (screen.storage.items[screen.line_start..]) |item| if (item.? == line) return true;
    return false;
}

fn removeImages(line: *Line, context: anytype,
    comptime remove: fn (@TypeOf(context), *const graphics.LineImage) bool) Allocator.Error!void {
    var previous = line.images orelse return;
    var count: usize = 0;
    for (previous.items) |image| if (!remove(context, image)) { count += 1; };
    if (count == previous.items.len) return;
    const allocator = line.allocator;
    var retained: std.ArrayList(*graphics.LineImage) = .empty;
    try retained.ensureTotalCapacity(allocator, count);
    for (previous.items) |image| if (!remove(context, image)) { retained.appendAssumeCapacity(image.clone()); };
    line.images = if (count == 0) null else retained;
    line.touch();
    // Original image arrays remain owned here. A host Data deallocator may
    // reset/reflow rows or replace this line's images during any release.
    for (previous.items) |image| image.deinit();
    previous.deinit(allocator);
}

fn removeImage(line: *Line, identity: u128) Allocator.Error!void {
    const Predicate = struct {
        fn matches(id: u128, image: *const graphics.LineImage) bool { return image.render_id == id; }
    };
    try removeImages(line, identity, Predicate.matches);
}

const RetainedRows = struct {
    allocator: Allocator,
    rows: []*Line,
    fn init(allocator: Allocator, screen: *const Buffer) Allocator.Error!RetainedRows {
        const rows = try allocator.alloc(*Line, @intCast(screen.lineCount()));
        for (rows, screen.storage.items[screen.line_start..]) |*out, item| out.* = item.?.retain();
        return .{ .allocator = allocator, .rows = rows };
    }
    fn deinit(self: RetainedRows) void {
        for (self.rows) |line| line.release();
        self.allocator.free(self.rows);
    }
};

fn addLineWitness(a: Allocator, list: *std.ArrayList(*Line), line: *Line) Allocator.Error!void {
    if (std.mem.indexOfScalar(*Line, list.items, line) != null) return;
    try list.ensureUnusedCapacity(a, 1);
    list.appendAssumeCapacity(line.retain());
}

pub fn recordKittyDisplayReflowImage(t: anytype, display: ?graphics.Display, line: *Line) !void {
    const shown = display orelse return;
    if (shown.is_virtual) return;
    const images = line.images orelse return;
    for (images.items) |image| {
        if (!image.is_kitty or image.image_id != shown.image_id or image.placement_id != shown.placement_id) continue;
        const present = for (t.print_state.kittyDisplayReflowImages.items) |existing| {
            if (existing.render_id == image.render_id) break true;
        } else false;
        if (!present) {
            try t.print_state.kittyDisplayReflowImages.ensureUnusedCapacity(t.allocator, 1);
            t.print_state.kittyDisplayReflowImages.appendAssumeCapacity(image.clone());
        }
    }
}

pub fn recordKittyDisplayReflowBoundaries(t: anytype, screen: *Buffer, destination_row: isize) !void {
    var first = destination_row;
    while (first > 0 and screen.liveLine(first).is_wrapped) first -= 1;
    if (screen.scroll_top < first) {
        var row = screen.scroll_top;
        while (row < first) : (row += 1) {
            const line = screen.liveLine(row);
            if (line.is_wrapped) try addLineWitness(t.allocator, &t.print_state.activeMarginReflowBoundaries, line);
        }
    }
    const clipped_top = first == 0 and destination_row > 0 and screen.liveLine(first).is_wrapped;
    var row: isize = if (clipped_top) 1 else first;
    while (row <= destination_row) : (row += 1) {
        const line = screen.liveLine(row);
        if (row == destination_row or line.usedLength() > 0)
            try addLineWitness(t.allocator, &t.print_state.kittyDisplayReflowBoundaries, line);
    }
}

pub fn recordKittyDisplayClippedTopReflowRank(t: anytype, screen: *Buffer, destination_row: isize) !void {
    if (screen != &t.normal or screen.scroll_top != 0 or destination_row <= 0) return;
    var first = destination_row;
    while (first > 0 and screen.liveLine(first).is_wrapped) first -= 1;
    if (first != 0 or !screen.liveLine(0).is_wrapped) return;
    var contains_narrow = false;
    var row: isize = 0;
    while (row <= destination_row and !contains_narrow) : (row += 1) {
        const line = screen.liveLine(row);
        var col: isize = 0;
        const used = @min(line.usedLength(), line.count());
        while (col < used) : (col += 1) {
            if (line.cell(col).width == 1) { contains_narrow = true; break; }
        }
    }
    if (contains_narrow) try addLineWitness(t.allocator, &t.print_state.kittyDisplayClippedTopReflowRanks, screen.liveLine(0));
}

pub fn recordKittyDisplayReflowImageTransfer(t: anytype, display: ?graphics.Display, source: *Line, destination: *Line) !void {
    const shown = display orelse return;
    if (shown.is_virtual or source == destination) return;
    try recordKittyDisplayReflowImage(t, display, source);
    const images = source.images orelse return;
    for (images.items) |image| {
        if (!image.is_kitty or image.image_id != shown.image_id or image.placement_id != shown.placement_id) continue;
        const present = for (t.print_state.kittyDisplayReflowImageTransfers.items) |transfer| {
            if (transfer.image.render_id == image.render_id) break true;
        } else false;
        if (present) continue;
        try t.print_state.kittyDisplayReflowImageTransfers.ensureUnusedCapacity(t.allocator, 1);
        const b = t.buffer();
        t.print_state.kittyDisplayReflowImageTransfers.appendAssumeCapacity(.{
            .image = image.clone(), .source = source.retain(), .destination = destination.retain(),
            .successor = if (b.scroll_bottom + 1 < b.rows) b.liveLine(b.scroll_bottom + 1).retain() else null,
        });
    }
}

pub fn recordKittyDisplayReflowClaim(t: anytype, line: *Line) !void {
    try addLineWitness(t.allocator, &t.print_state.kittyDisplayReflowClaims, line);
}

pub fn materializeKittyDisplayReflowImageTransfers(t: anytype, screen: *Buffer) !void {
    for (t.print_state.kittyDisplayReflowImageTransfers.items) |transfer| {
        if (!containsLine(screen, transfer.destination)) continue;
        const source = findImageLine(screen, transfer.image.render_id) orelse continue;
        if (source == transfer.destination) continue;
        // Retain into the destination before removing the old owner. OOM keeps
        // the original visible marker and the transfer witness intact.
        if (!hasImage(transfer.destination, transfer.image.render_id)) try transfer.destination.appendImage(transfer.image);
        try removeImage(source, transfer.image.render_id);
    }
    var index: usize = 0;
    while (index < t.print_state.kittyDisplayReflowImageTransfers.items.len) {
        if (!containsLine(screen, t.print_state.kittyDisplayReflowImageTransfers.items[index].destination)) { index += 1; continue; }
        var transfer = t.print_state.kittyDisplayReflowImageTransfers.orderedRemove(index);
        transfer.deinit();
    }
}

pub fn reactivateKittyDisplayReflowLines(t: anytype, screen: *Buffer) !void {
    // Reserve the worst case once, before exposing any reactivated row.
    var additions: usize = 0;
    for (t.print_state.kittyDisplayReflowImageTransfers.items) |transfer| {
        if (transfer.successor != null) continue;
        if (!containsLine(screen, transfer.destination)) additions += 1;
        if (!containsLine(screen, transfer.source)) additions += 1;
    }
    if (additions == 0) return;
    try screen.storage.ensureUnusedCapacity(screen.allocator, additions);
    for (t.print_state.kittyDisplayReflowImageTransfers.items) |transfer| {
        if (transfer.successor != null) continue;
        if (!containsLine(screen, transfer.destination)) screen.storage.appendAssumeCapacity(transfer.destination.retain());
        if (!containsLine(screen, transfer.source)) screen.storage.appendAssumeCapacity(transfer.source.retain());
    }
}

pub const SuspendedEntry = struct { image: *graphics.LineImage, line: *Line };
pub const Suspended = struct {
    items: []SuspendedEntry,
    pub fn deinit(self: *Suspended, a: Allocator) void {
        for (self.items) |*entry| { entry.image.deinit(); entry.line.release(); }
        a.free(self.items);
        self.items = &.{};
    }
};

pub fn suspendKittyDisplayReflowImages(t: anytype, screen: *Buffer, materialize: bool) !Suspended {
    if (materialize) try materializeKittyDisplayReflowImageTransfers(t, screen);
    var count: usize = 0;
    for (t.print_state.kittyDisplayReflowImages.items) |image| {
        if (findImageLine(screen, image.render_id) != null) count += 1;
    }
    const entries = try t.allocator.alloc(SuspendedEntry, count);
    var index: usize = 0;
    errdefer {
        for (entries[0..index]) |entry| { entry.image.deinit(); entry.line.release(); }
        t.allocator.free(entries);
    }
    for (t.print_state.kittyDisplayReflowImages.items) |image| {
        const line = findImageLine(screen, image.render_id) orelse continue;
        entries[index] = .{ .image = image.clone(), .line = line.retain() };
        index += 1;
        try removeImage(line, image.render_id);
    }
    std.debug.assert(index == count);
    return .{ .items = entries };
}

pub fn restoreKittyDisplayReflowImages(_: anytype, entries: []const SuspendedEntry, _: *Buffer) !void {
    // Despite the original helper's name, retained source Line objects regain
    // their image even when a height-only resize removed them from live rows.
    for (entries) |entry| if (!hasImage(entry.line, entry.image.render_id)) try entry.line.appendImage(entry.image);
}

pub fn resetGraphics(t: anytype) Allocator.Error!void {
    t.protocol_state.kitty.store.deleteAll();
    for ([_]*Buffer{ &t.normal, &t.alternate }) |screen| {
        const rows = try RetainedRows.init(t.allocator, screen);
        defer rows.deinit();
        for (rows.rows) |line| line.clearImages();
    }
    t.protocol_state.clearSixel();
    t.protocol_state.dcs_kind = .none;
    t.protocol_state.decrqss.clearAndFree(t.allocator);
    t.protocol_state.kitty.cancelChunks();
    t.protocol_state.kitty.chunk_data.clearAndFree(t.allocator);
    t.protocol_state.inline_budget.reset();
    t.markAllDirty();
}

pub fn osc(t: anytype, code: isize, payload: []const u8) anyerror!void {
    // A handler can recursively feed and replace parser string storage.
    const owned = try t.allocator.dupe(u8, payload);
    defer t.allocator.free(owned);
    const action = osc_mod.parse(code, owned);
    if (code == 133) {
        if (action == .block) try handleBlock(t, action.block);
        t.emit(.{ .kind = .osc, .argument = code, .bytes = owned.ptr, .length = owned.len });
        return;
    }
    t.emit(.{ .kind = .osc, .argument = code, .bytes = owned.ptr, .length = owned.len });
    switch (action) {
        .title => |bytes| {
            const text = try osc_mod.normalizeUTF8(t.allocator, bytes);
            defer t.allocator.free(text);
            try t.setTitle(text);
        },
        .current_directory => |bytes| {
            const text = try osc_mod.normalizeUTF8(t.allocator, bytes);
            defer t.allocator.free(text);
            t.emit(.{ .kind = .directory, .bytes = if (text.len == 0) null else text.ptr, .length = text.len });
        },
        .hyperlink => |uri| {
            const id = t.protocol_state.links.open(uri) catch |err| {
                t.active_link_id = 0;
                if (err == error.OutOfMemory) return err;
                return;
            };
            t.active_link_id = id;
        },
        .notification => |notice| {
            const title = try osc_mod.normalizeUTF8(t.allocator, notice.title);
            defer t.allocator.free(title);
            const body = try osc_mod.normalizeUTF8(t.allocator, notice.body);
            defer t.allocator.free(body);
            t.emit(.{ .kind = .notification, .bytes = title.ptr, .length = title.len,
                .bytes2 = body.ptr, .length2 = body.len });
        },
        .clipboard_write_encoded => |encoded| {
            const data = graphics.decodeBase64(t.allocator, encoded, graphics.max_payload_bytes) catch |err| {
                if (err == error.OutOfMemory) return err;
                return;
            };
            defer t.allocator.free(data);
            // An event is not a clipboard operation; the host applies its own
            // permission policy. Query actions never reach this branch.
            t.emit(.{ .kind = .clipboard_write, .bytes = data.ptr, .length = data.len });
        },
        .iterm2 => |bytes| {
            const image = (graphics.decodeITerm2(t.allocator, bytes) catch |err| {
                if (err == error.OutOfMemory) return err;
                return;
            }) orelse return;
            defer image.release();
            try attachImage(t, image);
        },
        else => {},
    }
}

fn handleBlock(t: anytype, marker: osc_mod.BlockMarker) anyerror!void {
    t.synchronizeBlockRowsToScrollback();
    const row = t.buffer().y_base + t.buffer().y;
    switch (marker) {
        .prompt_started => {
            const timestamp = t.now();
            try t.blocks.promptStarted(row, timestamp);
            t.emit(.{ .kind = .blocks_changed });
        },
        .prompt_ended => {
            t.blocks.promptEnded(row, t.buffer().x);
            t.emit(.{ .kind = .blocks_changed });
        },
        .command_started => {
            if (t.blocks.commandStarted(row)) t.emit(.{ .kind = .blocks_changed });
        },
        .command_finished => |exit_code| {
            const timestamp = t.now();
            const block = (t.blocks.commandFinished(row, exit_code, timestamp) orelse return).retain();
            defer block.release();
            t.emit(.{ .kind = .blocks_changed });
            t.emit(.{ .kind = .command_finished, .argument = exit_code orelse 0,
                .argument2 = @intCast(@min(block.index, std.math.maxInt(isize))), .object = block });
            // onCommandFinished may reset or reflow the buffer. The provider
            // sees text captured afterward from this same retained block.
            if (exit_code == null or exit_code.? == 0 or !t.has_failed_command_provider) return;
            const command = try commandText(t, block);
            defer t.allocator.free(command);
            const output = try outputText(t, block);
            defer t.allocator.free(output);
            t.emit(.{ .kind = .failed_command, .argument = exit_code.?,
                .argument2 = @intCast(@min(block.index, std.math.maxInt(isize))),
                .object = block,
                .bytes = command.ptr, .length = command.len, .bytes2 = output.ptr, .length2 = output.len });
        },
    }
}

fn appendCellRange(out: *std.ArrayList(u8), a: Allocator, line: *const Line, first: isize, last: isize) !void {
    const lower = std.math.clamp(first, 0, line.count());
    const upper = @max(lower, @min(last, @min(line.trimmedLength(), line.count())));
    var col = lower;
    while (col < upper) : (col += 1) {
        const value = line.get(col);
        if (value.cell.width == 0) continue;
        if (value.cell.scalar == 0) { try out.append(a, ' '); continue; }
        try @import("cell_text.zig").append(out, a, value.cell.scalar, value.extras);
    }
}

fn trimText(out: *std.ArrayList(u8), include_whitespace: bool) void {
    var iterator = std.unicode.Utf8View.initUnchecked(out.items).iterator();
    var first: ?usize = null;
    var end: usize = 0;
    while (iterator.nextCodepoint()) |scalar| {
        const trimmed = if (include_whitespace) @import("character_sets.zig").trim(scalar) else switch (scalar) {
            0x0a...0x0d, 0x85, 0x2028, 0x2029 => true, else => false,
        };
        if (!trimmed) {
            if (first == null) first = iterator.i - (std.unicode.utf8CodepointSequenceLength(scalar) catch unreachable);
            end = iterator.i;
        }
    }
    const start = first orelse out.items.len;
    const length = if (first != null) end - start else 0;
    std.mem.copyForwards(u8, out.items[0..length], out.items[start..][0..length]);
    out.items.len = length;
}

pub fn commandText(t: anytype, block: *const blocks_mod.Block) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(t.allocator);
    if (block.input_start) |start| {
        var row = @max(0, start.row);
        const end = @min(block.command_row, t.buffer().lineCount());
        while (row < end) : (row += 1) {
            const line = t.buffer().line(row) orelse continue;
            if (row == start.row) {
                try appendCellRange(&out, t.allocator, line, start.col, t.buffer().cols);
            } else {
                const text = try line.trimmedText(t.allocator);
                defer t.allocator.free(text);
                try out.appendSlice(t.allocator, text);
            }
        }
    }
    trimText(&out, true);
    return out.toOwnedSlice(t.allocator);
}

pub fn outputText(t: anytype, block: *const blocks_mod.Block) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(t.allocator);
    if (block.end_row) |last| {
        var row = @max(0, block.command_row);
        const end = @min(last, t.buffer().lineCount());
        while (row < end) : (row += 1) {
            const line = t.buffer().line(row) orelse continue;
            if (row > block.command_row and !line.is_wrapped) try out.append(t.allocator, '\n');
            const text = try line.trimmedText(t.allocator);
            defer t.allocator.free(text);
            try out.appendSlice(t.allocator, text);
        }
    }
    trimText(&out, false);
    return out.toOwnedSlice(t.allocator);
}

pub fn dcsHook(t: anytype, final: u8, _: []const isize, collect: []const u8) !void {
    const state = &t.protocol_state;
    if (final == 'q' and collect.len == 0) {
        const decoder = try t.allocator.create(sixel_mod.SixelDecoder);
        decoder.* = .init(t.allocator);
        state.clearSixel();
        state.sixel = decoder;
        state.dcs_kind = .sixel;
    } else if (final == 'q' and std.mem.eql(u8, collect, "$")) {
        state.dcs_kind = .decrqss;
        state.decrqss.clearRetainingCapacity();
    } else state.dcs_kind = .other;
}

pub fn dcsPut(t: anytype, bytes: []const u8) !void {
    const state = &t.protocol_state;
    switch (state.dcs_kind) {
        .sixel => if (state.sixel) |decoder| try decoder.feed(bytes),
        .decrqss => {
            if (state.decrqss.items.len > 4096 or bytes.len > 4096 - state.decrqss.items.len) {
                state.decrqss.clearAndFree(t.allocator);
                state.dcs_kind = .other;
                return;
            }
            try state.decrqss.appendSlice(t.allocator, bytes);
        },
        else => {},
    }
}

pub fn dcsUnhook(t: anytype) anyerror!void {
    defer { t.protocol_state.dcs_kind = .none; t.protocol_state.clearSixel(); }
    switch (t.protocol_state.dcs_kind) {
        .sixel => {
            const decoder = t.protocol_state.sixel orelse return;
            var image = (try decoder.finish()) orelse return;
            // Transfer the decoder result to a refcounted owner before any
            // line-feed/host callback can destroy the streaming decoder.
            const payload = graphics.Payload.createOwned(t.allocator, .rgba, image.bytes, image.width, image.height) catch |err| {
                image.deinit();
                if (err == error.OutOfMemory) return err;
                return;
            };
            defer payload.release();
            try attachImage(t, payload);
        },
        .decrqss => {
            var storage: [96]u8 = undefined;
            const request = t.protocol_state.decrqss.items;
            const response = if (std.mem.eql(u8, request, "m")) "\x1bP1$r0m\x1b\\"
                else if (std.mem.eql(u8, request, "r")) try std.fmt.bufPrint(&storage, "\x1bP1$r{d};{d}r\x1b\\", .{ t.buffer().scroll_top + 1, t.buffer().scroll_bottom + 1 })
                else if (std.mem.eql(u8, request, " q")) try std.fmt.bufPrint(&storage, "\x1bP1$r{d} q\x1b\\", .{@intFromEnum(t.cursor_style) + 1})
                else "\x1bP0$r\x1b\\";
            try t.sendResponse(response);
        },
        else => {},
    }
}

pub fn attachImage(t: anytype, payload: *graphics.Payload) anyerror!void {
    if (!t.protocol_state.inline_budget.accept(payload)) return;
    const original_buffer = t.buffer();
    const rows = @max(1, (payload.height + 19) / 20);
    var image = try graphics.LineImage.init(payload, original_buffer.x);
    defer image.deinit();
    for (0..rows - 1) |_| try motion.lineFeed(t);
    // Keep the buffer captured before lineFeed just as the Swift handler does;
    // an application callback may have selected another active buffer.
    try original_buffer.liveLine(original_buffer.y).appendImage(image);
    try motion.lineFeed(t);
    original_buffer.x = 0;
}

pub fn apc(t: anytype, bytes: []const u8) anyerror!void {
    const b = t.buffer();
    const raw_col = b.x;
    const source_row = b.y;
    const source_line = b.liveLine(source_row).retain();
    defer source_line.release();
    var result = try handleAPCResult(t, bytes);
    defer result.deinit(t.allocator);
    try applyKittyLineGeneration(t, &result, source_line);
    if (result.should_apply_display_line_motion) {
        b.x = raw_col;
        b.y = source_row;
        try applyKittyDisplayLineMotion(t, result.display, source_line);
    }
    if (result.allocation_failed) return error.OutOfMemory;
}

/// Raw graphics handler: attachment/replies and historical rectangle cursor
/// motion, without the parser's generation retirement and logical-row motion.
pub fn handleAPC(t: anytype, bytes: []const u8) anyerror!bool {
    var result = try handleAPCResult(t, bytes);
    defer result.deinit(t.allocator);
    if (result.allocation_failed) return error.OutOfMemory;
    return result.should_apply_display_line_motion;
}

pub fn handleAPCResult(t: anytype, bytes: []const u8) anyerror!graphics.KittyResult {
    const initial = t.buffer();
    var result = t.protocol_state.kitty.handleForTerminal(bytes, .{ .col = initial.x,
        .row = initial.y_base + initial.y, .y_base = initial.y_base, .is_alternate_buffer = t.is_alternate });
    errdefer result.deinit(t.allocator);
    if (result.display) |*display| {
        // A replaced host payload may have changed cursor/buffer while store()
        // committed. Swift resolves the placement buffer after that callback.
        const b = t.buffer();
        const source_row = b.y;
        if (t.protocol_state.kitty.store.placements_by_key.getPtr(graphics.placementKey(display.image_id, display.placement_id))) |placement| {
            placement.col = b.x; placement.row = b.y_base + b.y; placement.is_alternate_buffer = t.is_alternate;
        }
        if (display.attachment) |image| {
            image.col = b.x;
            const source_line = b.liveLine(source_row).retain();
            defer source_line.release();
            // Reserve/retain before releasing any replaced line attachment.
            try source_line.appendImage(image);
            try removeOtherPlacements(source_line, image);
            t.markDirty(b.y_base + source_row);
        }
        if (result.should_apply_display_line_motion) {
            b.x = 0;
            b.y = @min(b.rows - 1, @max(0, b.y + display.rows));
        }
    }
    if (result.strip_deleted_placements) {
        const Predicate = struct {
            fn matches(removed: []const graphics.Placement, image: *const graphics.LineImage) bool {
                if (!image.is_kitty or image.image_id == null or image.placement_id == null) return false;
                for (removed) |placement| if (image.image_id == placement.image_id and image.placement_id == placement.placement_id) return true;
                return false;
            }
        };
        for ([_]*Buffer{ &t.normal, &t.alternate }) |screen| {
            const rows = try RetainedRows.init(t.allocator, screen);
            defer rows.deinit();
            for (rows.rows) |line| try removeImages(line, @as([]const graphics.Placement, result.removed.items), Predicate.matches);
        }
        t.markAllDirty();
    }
    t.protocol_state.kitty.deleteResultData(&result);
    // The existing graphics handler replies before parser-owned generation
    // bookkeeping. Keep that callback boundary and its captured source row.
    if (result.reply) |reply| try t.sendResponse(reply.bytes());
    return result;
}

fn removeOtherPlacements(line: *Line, newest: *graphics.LineImage) Allocator.Error!void {
    const Predicate = struct {
        fn matches(latest: *graphics.LineImage, image: *const graphics.LineImage) bool {
            return image.render_id != latest.render_id and image.is_kitty and
                image.image_id == latest.image_id and image.placement_id == latest.placement_id;
        }
    };
    try removeImages(line, newest, Predicate.matches);
}

fn applyKittyLineGeneration(t: anytype, result: *const graphics.KittyResult, source: *Line) Allocator.Error!void {
    if (result.committed_transmission_image_id == null and result.removed.items.len == 0) return;
    const Context = struct {
        result: *const graphics.KittyResult,
        is_source: bool,
        fn matches(context: @This(), image: *const graphics.LineImage) bool {
            if (!image.is_kitty or image.image_id == null or image.placement_id == null) return false;
            if (context.result.display) |display| {
                if (!display.is_virtual and context.is_source and image.image_id == display.image_id and image.placement_id == display.placement_id) return false;
            }
            const removed_key = for (context.result.removed.items) |placement| {
                if (image.image_id == placement.image_id and image.placement_id == placement.placement_id) break true;
            } else false;
            return image.image_id == context.result.committed_transmission_image_id or removed_key;
        }
    };
    for ([_]*Buffer{ &t.normal, &t.alternate }) |screen| {
        const rows = try RetainedRows.init(t.allocator, screen);
        defer rows.deinit();
        for (rows.rows) |line| try removeImages(line, Context{ .result = result, .is_source = line == source }, Context.matches);
    }
    pruneKittyDisplayReflowImages(t);
    t.markAllDirty();
}

pub fn applyKittyDisplayLineMotion(t: anytype, display: ?graphics.Display, source_line: *Line) anyerror!void {
    const b = t.buffer();
    const old_base = b.y_base;
    const old_row = old_base + b.y;
    const fill = t.eraseCell();
    const eligible = b.x >= b.margin_left and b.x <= b.margin_right;
    var mutated_rows = false;
    if (b.y == b.scroll_bottom) {
        if (eligible) {
            if (t.hasNarrowMargins()) {
                const destination = if (b.scroll_bottom > b.scroll_top) b.liveLine(b.scroll_bottom - 1).retain() else null;
                defer if (destination) |line| line.release();
                const wrapped = if (destination) |line| line.is_wrapped else false;
                const virtual_delete = for (t.print_state.marginDeleteGenerations.items) |generation| {
                    if (generation.witnessLine == source_line) break true;
                } else false;
                try recordKittyDisplayReflowImage(t, display, source_line);
                if (wrapped) {
                    try recordKittyDisplayReflowBoundaries(t, b, b.scroll_bottom - 1);
                    try recordKittyDisplayReflowImageTransfer(t, display, source_line, destination.?);
                }
                try motion.scrollNarrowSlices(t, .toward_top, fill, false, !wrapped);
                if (wrapped) {
                    if (virtual_delete) try recordKittyDisplayReflowBoundaries(t, b, b.scroll_bottom - 1);
                    try recordKittyDisplayClippedTopReflowRank(t, b, b.scroll_bottom - 1);
                    try recordKittyDisplayReflowClaim(t, b.liveLine(b.scroll_bottom));
                }
            } else if (b.scroll_top == 0 and !b.has_scrollback) {
                const viewport_at_bottom = b.y_disp == b.y_base;
                const insertion = std.math.clamp(b.y_base + b.scroll_bottom + 1, 0, b.lineCount());
                try b.storage.ensureUnusedCapacity(b.allocator, 1);
                const blank = try Line.create(t.allocator, b.cols, fill);
                b.storage.insertAssumeCapacity(b.line_start + @as(usize, @intCast(insertion)), blank);
                b.y_base += 1;
                if (viewport_at_bottom) b.y_disp = b.y_base;
            } else try b.scrollUp(fill, false, true);
            if (!t.hasNarrowMargins()) {
                for (t.print_state.marginDeleteGenerations.items) |*generation| generation.deinit(t.allocator);
                t.print_state.marginDeleteGenerations.clearRetainingCapacity();
            }
            mutated_rows = true;
        }
    } else if (b.y < b.rows - 1) b.y += 1;
    b.x = 0;
    b.wrap_pending = false;
    t.print_state.noWrapParkedAfterPrint = false;
    printing.recordSelectorOwnerVerticalMotion(t, old_row);
    if (mutated_rows) t.markDirtyRange(old_base + b.scroll_top, @max(old_base + b.scroll_bottom, b.y_base + b.scroll_bottom));
    t.markDirty(old_row);
    t.markDirty(b.y_base + b.y);
}
