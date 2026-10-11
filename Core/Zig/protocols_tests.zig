const std = @import("std");
const testing = std.testing;
const blocks = @import("blocks.zig");
const sixel = @import("sixel.zig");
const graphics = @import("graphics.zig");
const osc = @import("osc.zig");

test "blocks record deterministic timestamps and ignore unmatched finishes" {
    var tracker = blocks.BlockTracker.init(testing.allocator);
    defer tracker.deinit();
    try testing.expect(!tracker.commandStarted(1));
    tracker.promptEnded(0, 2);
    try testing.expectEqual(@as(u64, 1), tracker.generation);
    try tracker.promptStarted(2, 7.5);
    tracker.promptEnded(2, 4);
    try testing.expect(tracker.commandStarted(3));
    const finished = tracker.commandFinished(6, 127, 8.25).?.retain();
    defer finished.release();
    try testing.expectEqual(@as(f64, 7.5), finished.started_at);
    try testing.expectEqual(@as(?f64, 8.25), finished.finished_at);
    try testing.expectEqual(@as(?isize, 127), finished.exit_code);
    try testing.expectEqual(blocks.Position{ .row = 2, .col = 4 }, finished.input_start.?);
    try tracker.promptStarted(7, 9);
    const generation = tracker.generation;
    try testing.expectEqual(@as(?*blocks.Block, null), tracker.commandFinished(8, 1, 10));
    try testing.expectEqual(generation, tracker.generation);
    try testing.expectEqual(@as(u64, 1), tracker.lastCompletedBlock().?.index);
    tracker.reset();
    try tracker.promptStarted(0, 12);
    try testing.expectEqual(@as(u64, 3), tracker.blocks.items[0].index);
    try testing.expectEqual(@as(isize, 6), finished.end_row.?);
}

test "blocks remap every anchor, trim negative prompts and preserve identifiers" {
    var tracker = blocks.BlockTracker.init(testing.allocator);
    defer tracker.deinit();
    try tracker.promptStarted(0, 0);
    _ = tracker.commandStarted(1);
    _ = tracker.commandFinished(2, 0, 1);
    try tracker.promptStarted(5, 2);
    tracker.promptEnded(5, 3);
    _ = tracker.commandStarted(6);
    _ = tracker.commandFinished(8, 2, 3);
    tracker.rebase(3);
    try testing.expectEqual(@as(usize, 1), tracker.blocks.items.len);
    try testing.expectEqual(@as(isize, 2), tracker.blocks.items[0].prompt_row);
    const Map = struct { fn apply(offset: isize, row: isize) isize { return row * 2 + offset; } };
    tracker.remapRows(@as(isize, 1), Map.apply);
    const block = tracker.blocks.items[0];
    try testing.expectEqual(@as(isize, 5), block.prompt_row);
    try testing.expectEqual(@as(isize, 7), block.command_row);
    try testing.expectEqual(@as(?isize, 11), block.end_row);
    try testing.expectEqual(blocks.Position{ .row = 5, .col = 3 }, block.input_start.?);
    try testing.expectEqual(@as(u64, 2), block.index);
}

test "sixel streaming splits match whole payload, palette and transparent canvas" {
    const bytes = "#1;2;100;0;0!3~$#2;2;0;100;0A-?~";
    var whole = sixel.SixelDecoder.init(testing.allocator);
    defer whole.deinit();
    try whole.feed(bytes);
    var expected = (try whole.finish()).?;
    defer expected.deinit();
    for (0..bytes.len + 1) |split| {
        var decoder = sixel.SixelDecoder.init(testing.allocator);
        defer decoder.deinit();
        try decoder.feed(bytes[0..split]);
        try decoder.feed(bytes[split..]);
        var actual = (try decoder.finish()).?;
        defer actual.deinit();
        try testing.expectEqual(expected.width, actual.width);
        try testing.expectEqual(expected.height, actual.height);
        try testing.expectEqualSlices(u8, expected.bytes, actual.bytes);
    }
    try testing.expectEqual(@as(u32, 3), expected.width);
    try testing.expectEqual(@as(u32, 12), expected.height);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, expected.bytes[0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, expected.bytes[3 * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, expected.bytes[6 * 3 * 4 ..][0..4]);
}

test "sixel limits reject sparse canvases and clamp hostile numeric input" {
    var decoder = sixel.SixelDecoder.init(testing.allocator);
    defer decoder.deinit();
    try decoder.feed("!10000~");
    for (0..100) |_| try decoder.feed("-");
    try decoder.feed("~");
    try testing.expect((try decoder.finish()) == null);
    try testing.expect(decoder.rejected);
    try testing.expectEqual(@as(usize, 0), decoder.pixels.count());
    var huge = sixel.SixelDecoder.init(testing.allocator);
    defer huge.deinit();
    try huge.feed("!");
    for (0..128) |_| try huge.feed("9");
    try huge.feed("~");
    var result = (try huge.finish()).?;
    defer result.deinit();
    try testing.expectEqual(@as(u32, 10000), result.width);
    try testing.expectEqual(@as(u32, 6), result.height);
    try testing.expectEqual(sixel.Color{ .r = 0, .g = 0, .b = 255 }, sixel.hlsToRGB(0, 50, 100));
}

test "retained image attachment and snapshot survive store replacement and destruction" {
    const a = testing.allocator;
    var store = graphics.KittyGraphicsStore.init(a);
    const payload = try graphics.Payload.createCopy(a, .rgba, &.{ 255, 0, 0, 255 }, 1, 1);
    try putImage(&store, 1, null, payload);
    var attachment = try graphics.LineImage.init(payload, 3);
    payload.release();
    const shared = attachment.clone();
    defer shared.deinit();
    var snapshot = try attachment.snapshot();
    defer snapshot.deinit();
    attachment.col = 9;
    try testing.expectEqual(@as(isize, 9), shared.col);
    try testing.expectEqual(@as(isize, 3), snapshot.col);
    try testing.expectEqual(attachment.render_id, snapshot.render_id);
    try testing.expectEqualSlices(u8, &attachment.render_uuid, &snapshot.render_uuid);
    try testing.expectEqual(@as(u8, 0x40), attachment.render_uuid[6] & 0xf0);
    try testing.expectEqual(@as(u8, 0x80), attachment.render_uuid[8] & 0xc0);
    const replacement = try graphics.Payload.createCopy(a, .rgba, &.{ 0, 255, 0, 255 }, 1, 1);
    defer replacement.release();
    try putImage(&store, 1, null, replacement);
    store.deinit();
    attachment.deinit();
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, snapshot.payload.bytes);
}

test "Kitty identifier wrap, replacement, and image and placement caps" {
    var store = graphics.KittyGraphicsStore.init(testing.allocator);
    defer store.deinit();
    const payload = try graphics.Payload.createCopy(testing.allocator, .rgba, &.{ 0, 0, 0, 255 }, 1, 1);
    defer payload.release();
    try putImage(&store, 1, 9, payload);
    try putImage(&store, std.math.maxInt(u32), 9, payload);
    try testing.expectEqual(@as(u32, 2), store.next_image_id);
    try testing.expectEqual(std.math.maxInt(u32), store.newestImage(9).?.id);
    const placement: graphics.Placement = .{ .image_id = 1, .placement_id = 1, .col = 0, .row = 0, .cols = 1, .rows = 1 };
    _ = try store.place(placement);
    var last = placement;
    last.placement_id = std.math.maxInt(u32);
    _ = try store.place(last);
    try testing.expectEqual(@as(u32, 2), store.next_placement_id);
    store.limits.placements = 2;
    var third = placement;
    third.placement_id = 3;
    try testing.expectError(error.NoSpace, store.place(third));
    _ = try store.place(placement);
    store.limits.images = 2;
    try testing.expectError(error.NoSpace, putImage(&store, 2, null, payload));
    try putImage(&store, 1, null, payload);
    try testing.expectEqual(@as(usize, 0), store.placements_by_key.count());
    try testing.expectEqual(@as(usize, 8), store.payload_bytes);
    store.deleteImage(1);
    try testing.expectEqual(@as(usize, 4), store.payload_bytes);
}

test "Kitty strict control parsing rejects hostile and ambiguous fields" {
    for ([_][]const u8{ "", "G,", "Gi=-1", "Gi=1,I=2", "Gi=4294967296", "Gi=1_0", "Gs=9223372036854775807", "Gz=2147483648", "Gf=99", "Gq=3", "Gm=01", "Go=q", "Gaa=t", "Ga=tt", "Gt=dd", "Gx=\xff", "G=1" }) |bytes| {
        try testing.expectError(error.InvalidInput, graphics.decodeKittyEnvelope(bytes));
    }
    const control = (try graphics.decodeKittyEnvelope("Ga=T,f=+32,z=-2147483648,q=+2,U=1,C=1,?=ignored;s" )).control;
    try testing.expect(control.action == .transmit_and_place);
    try testing.expectEqual(std.math.minInt(i32), control.z_index);
    try testing.expect(control.virtual_placement and control.no_cursor_move);
}

test "Kitty decode RGB, PNG limits, and bounded deflate" {
    var image = try graphics.decodeKittyImage(testing.allocator, .{ .format = .rgb, .width = 1, .height = 1 }, "/wAA", 3);
    defer image.deinit();
    try testing.expectEqual(@as(u32, 3), image.id);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.payload.bytes);
    try testing.expectError(error.InvalidInput, graphics.decodeKittyImage(testing.allocator, .{ .width = std.math.maxInt(u32), .height = 2 }, "AAAA", 1));
    try testing.expect(graphics.pngDimensions(&([_]u8{0} ** 24)) == null);
    const compressed = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15 };
    const inflated = try graphics.zlibInflated(testing.allocator, &compressed, 32);
    defer testing.allocator.free(inflated);
    try testing.expectEqualStrings("hello", inflated);
    try testing.expectError(error.TooLarge, graphics.zlibInflated(testing.allocator, &compressed, 4));
    try testing.expectError(error.TooLarge, graphics.zlibInflated(testing.allocator, &compressed, 5));
}

test "Kitty chunks retain initial controls and produce owned effects" {
    var engine = graphics.KittyEngine.init(testing.allocator);
    defer engine.deinit();
    const cursor: graphics.CursorContext = .{ .col = 3, .row = 9, .y_base = 6 };
    var first = engine.handle("Ga=T,f=32,s=1,v=1,i=3,p=7,m=1;/wAA", cursor);
    defer first.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), engine.store.images_by_id.count());
    var final = engine.handle("Gm=0; /w==", cursor);
    defer final.deinit(testing.allocator);
    try testing.expectEqual(graphics.ProtocolError.invalid, final.protocol_error.?);
    try testing.expect(engine.chunk_control == null);
    var start_again = engine.handle("Ga=T,f=32,s=1,v=1,i=3,p=7,m=1;/wAA", cursor);
    defer start_again.deinit(testing.allocator);
    var placed = engine.handle("Gm=0;/w==", cursor);
    defer placed.deinit(testing.allocator);
    try testing.expect(placed.should_apply_display_line_motion);
    try testing.expectEqual(@as(?u32, 3), placed.committed_transmission_image_id);
    try testing.expectEqualStrings("\x1b_Gi=3,p=7;OK\x1b\\", placed.reply.?.bytes());
    try testing.expectEqual(@as(isize, 3), placed.display.?.attachment.?.col);
    try testing.expectEqual(@as(isize, 9), engine.store.placements_by_key.values()[0].row);
    var removed = engine.handle("Ga=d,d=I,i=3,p=7;", cursor);
    defer removed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), removed.removed.items.len);
    try testing.expectEqual(@as(usize, 0), engine.store.images_by_id.count());
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, placed.display.?.attachment.?.payload.bytes);
}

test "Kitty query, quiet errors, virtual placement, C=1, and failed placement commit" {
    var engine = graphics.KittyEngine.init(testing.allocator);
    defer engine.deinit();
    const cursor: graphics.CursorContext = .{ .col = 0, .row = 0 };
    var query = engine.handle("Ga=q,s=1,v=1,i=9;/wAA/w==", cursor);
    defer query.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), engine.store.images_by_id.count());
    var virtual = engine.handle("Ga=T,s=1,v=1,i=9,U=1,q=1;/wAA/w==", cursor);
    defer virtual.deinit(testing.allocator);
    try testing.expect(!virtual.should_apply_display_line_motion);
    try testing.expect(virtual.display.?.attachment == null and virtual.reply == null);
    var stationary = engine.handle("Ga=p,i=9,C=1;", cursor);
    defer stationary.deinit(testing.allocator);
    try testing.expect(!stationary.should_apply_display_line_motion);
    try testing.expect(stationary.display.?.attachment != null);
    var missing = engine.handle("Ga=p,i=10,q=1;", cursor);
    defer missing.deinit(testing.allocator);
    try testing.expectEqualStrings("\x1b_Gi=10;ENOENT\x1b\\", missing.reply.?.bytes());
    var silent = engine.handle("Ga=p,i=10,q=2;", cursor);
    defer silent.deinit(testing.allocator);
    try testing.expect(silent.reply == null);
    var failed_placement = engine.handle("Ga=T,s=1,v=1,i=9,c=1025;/wAA/w==", cursor);
    defer failed_placement.deinit(testing.allocator);
    try testing.expectEqual(@as(?u32, 9), failed_placement.committed_transmission_image_id);
    try testing.expectEqual(@as(usize, 2), failed_placement.removed.items.len);
    try testing.expectEqual(graphics.ProtocolError.no_space, failed_placement.protocol_error.?);
    try testing.expect(failed_placement.display == null);
}

test "OSC actions preserve callback data and deny encoded clipboard reads" {
    try testing.expect(osc.parse(52, "c;?") == .none);
    try testing.expectEqualStrings("SGk=", osc.parse(52, "c;SGk=").clipboard_write_encoded);
    try testing.expectEqualStrings("title", osc.parse(2, "title").title);
    try testing.expectEqualStrings("", osc.parse(7, "").current_directory);
    const notification = osc.parse(777, "notify;title;body;rest").notification;
    try testing.expectEqualStrings("title", notification.title);
    try testing.expectEqualStrings("body;rest", notification.body);
    try testing.expectEqual(@as(?isize, -3), osc.parse(133, "D;-3;extra").block.command_finished);
    try testing.expectEqual(@as(?isize, null), osc.parse(133, "D;1_0").block.command_finished);
}

test "hyperlinks keep old IDs and close rather than alias on exhaustion" {
    var links = osc.LinkTable.init(testing.allocator);
    defer links.deinit();
    links.max_entries = 2;
    try testing.expectEqual(@as(u16, 1), try links.open("https://one"));
    try testing.expectEqual(@as(u16, 0), try links.open(""));
    try testing.expectEqual(@as(u16, 2), try links.open("https://two"));
    try testing.expectError(error.NoSpace, links.open("https://three"));
    try testing.expectEqual(@as(u16, 0), links.active_link_id);
    try testing.expectEqualStrings("https://one", links.uri(1).?);
    try testing.expectEqualStrings("https://two", links.uri(2).?);
    try testing.expect(links.uri(0) == null and links.uri(3) == null);
    links.reset();
    try testing.expectEqual(@as(u16, 1), try links.open("new"));
}

test "UTF8 repair uses Unicode maximal subparts" {
    const input = [_]u8{ 0xe1, 0x80, 'A', 0xf0, 0x80, 0xed, 0xa0, 0x80, 0xf0, 0x9f, 0x92 };
    const repaired = try osc.normalizeUTF8(testing.allocator, &input);
    defer testing.allocator.free(repaired);
    try testing.expectEqualStrings("\u{fffd}A\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}\u{fffd}", repaired);
}

fn allocations(a: std.mem.Allocator) !void {
    var tracker = blocks.BlockTracker.init(a);
    defer tracker.deinit();
    for (0..20) |i| try tracker.promptStarted(@intCast(i), @floatFromInt(i));
    var decoder = sixel.SixelDecoder.init(a);
    defer decoder.deinit();
    try decoder.feed("#1;2;100;0;0!4~");
    var sixel_image = (try decoder.finish()).?;
    defer sixel_image.deinit();
    var image = try graphics.decodeKittyImage(a, .{ .format = .rgb, .width = 1, .height = 1 }, "/wAA", 1);
    defer image.deinit();
    var store = graphics.KittyGraphicsStore.init(a);
    defer store.deinit();
    try store.store(image);
    _ = try store.place(.{ .image_id = 1, .col = 0, .row = 0, .cols = 1, .rows = 1 });
    var links = osc.LinkTable.init(a);
    defer links.deinit();
    _ = try links.open("https://\xff");
    const predicate = struct { fn yes(_: void, _: graphics.Placement) bool { return true; } }.yes;
    var removed = try store.removePlacements({}, predicate);
    defer removed.deinit(a);
}

test "protocol construction and store mutation survive every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocations, .{});
}

test "PNG and iTerm2 require real dimensions and preserve encoded payload ownership" {
    const png = [_]u8{ 0x89, 'P', 'N', 'G', 13, 10, 26, 10, 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 1, 0, 0, 0, 2 };
    try testing.expectEqual(graphics.Dimensions{ .width = 1, .height = 2 }, graphics.pngDimensions(&png).?);
    var hostile = png;
    std.mem.writeInt(u32, hostile[16..20], 0x7fffffff, .big);
    try testing.expect(graphics.pngDimensions(&hostile) == null);
    var image = try graphics.decodeKittyImage(testing.allocator, .{ .format = .png }, "iVBORw0KGgoAAAANSUhEUgAAAAEAAAAC", 1);
    defer image.deinit();
    try testing.expectEqual(graphics.Format.png, image.payload.format);
    try testing.expectEqualSlices(u8, &png, image.payload.bytes);
    const inline_image = (try graphics.decodeITerm2(testing.allocator, "File=name=x;inline=1:iVBO Rw0K\nGgoAAAANSUhEUgAAAAEAAAAC")).?;
    defer inline_image.release();
    try testing.expectEqualSlices(u8, &png, inline_image.bytes);
    try testing.expect((try graphics.decodeITerm2(testing.allocator, "File=inline=0:iVBORw0KGgoAAAANSUhEUgAAAAEAAAAC")) == null);
    try testing.expect((try graphics.decodeITerm2(testing.allocator, "File=inline=1:AAAA")) == null);
    var budget: graphics.InlineBudget = .{ .limit = png.len };
    try testing.expect(budget.accept(inline_image));
    try testing.expect(!budget.accept(inline_image));
    budget.reset();
    try testing.expect(budget.accept(inline_image));
}

test "Kitty deletion selectors match points, rows, columns, z-index and virtual ownership" {
    const cases = [_]struct { selector: u8, expected: usize }{
        .{ .selector = 'x', .expected = 3 }, .{ .selector = 'y', .expected = 3 },
        .{ .selector = 'p', .expected = 2 }, .{ .selector = 'q', .expected = 1 },
        .{ .selector = 'z', .expected = 3 }, .{ .selector = 'c', .expected = 1 },
        .{ .selector = 'a', .expected = 3 }, .{ .selector = 'i', .expected = 0 },
    };
    for (cases) |case| {
        var engine = graphics.KittyEngine.init(testing.allocator);
        defer engine.deinit();
        const positions = [_]struct { col: isize, row: isize, z: isize, virtual: bool }{
            .{ .col = 2, .row = 14, .z = 3, .virtual = false },
            .{ .col = 2, .row = 14, .z = 7, .virtual = true },
            .{ .col = 9, .row = 14, .z = 3, .virtual = false },
            .{ .col = 2, .row = 20, .z = 3, .virtual = false },
        };
        for (positions, 1..) |position, index| _ = try engine.store.place(.{ .image_id = 1,
            .placement_id = @intCast(index), .col = position.col, .row = position.row,
            .cols = 2, .rows = 3, .z_index = position.z, .is_virtual = position.virtual });
        var bytes: [64]u8 = undefined;
        const command = try std.fmt.bufPrint(&bytes, "Ga=d,d={c},x=3,y=5,z=3,q=2;", .{case.selector});
        var result = engine.handle(command, .{ .col = 3, .row = 15, .y_base = 10 });
        defer result.deinit(testing.allocator);
        try testing.expectEqual(case.expected, result.removed.items.len);
        try testing.expect(!result.should_apply_display_line_motion);
        try testing.expectEqual(@as(usize, 4) - case.expected, engine.store.placements_by_key.count());
    }
}

test "Kitty invalid chunk resets, non-Kitty APC retains chunks, and caps reject atomically" {
    var engine = graphics.KittyEngine.init(testing.allocator);
    defer engine.deinit();
    engine.chunk_limit = 6;
    const cursor: graphics.CursorContext = .{ .col = 0, .row = 0 };
    var initial = engine.handle("Gm=1,i=2,s=1,v=1;/wAA", cursor);
    defer initial.deinit(testing.allocator);
    var ignored = engine.handle("not Kitty", cursor);
    defer ignored.deinit(testing.allocator);
    try testing.expect(engine.chunk_control != null);
    var overflow = engine.handle("Gm=0;/w==", cursor);
    defer overflow.deinit(testing.allocator);
    try testing.expectEqual(graphics.ProtocolError.too_large, overflow.protocol_error.?);
    try testing.expectEqualStrings("\x1b_Gi=2;E2BIG\x1b\\", overflow.reply.?.bytes());
    try testing.expect(engine.chunk_control == null and engine.chunk_data.items.len == 0);
    var second = engine.handle("Gm=1,i=2,s=1,v=1;/wAA", cursor);
    defer second.deinit(testing.allocator);
    var invalid = engine.handle("Gi=-1;", cursor);
    defer invalid.deinit(testing.allocator);
    try testing.expect(invalid.reply == null);
    try testing.expect(engine.chunk_control == null and engine.chunk_data.items.len == 0);
}

test "block admission errors leave identities and generation unchanged" {
    var tracker = blocks.BlockTracker.init(testing.allocator);
    defer tracker.deinit();
    tracker.max_blocks = 1;
    try tracker.promptStarted(0, 0);
    const generation = tracker.generation;
    try testing.expectError(error.TooManyBlocks, tracker.promptStarted(1, 1));
    try testing.expectEqual(generation, tracker.generation);
    try testing.expectEqual(@as(u64, 2), tracker.next_index);
    tracker.reset();
    tracker.next_index = std.math.maxInt(u64);
    try testing.expectError(error.IndexExhausted, tracker.promptStarted(2, 2));
    try testing.expectEqual(@as(usize, 0), tracker.blocks.items.len);
}

test "failed Kitty transmission does not erase the old image or its placements" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const a = failing.allocator();
    var engine = graphics.KittyEngine.init(a);
    defer engine.deinit();
    const cursor: graphics.CursorContext = .{ .col = 0, .row = 0 };
    var first = engine.handle("Ga=T,i=3,s=1,v=1;/wAA/w==", cursor);
    defer first.deinit(a);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    var replacement = engine.handle("Ga=T,i=3,s=1,v=1;AP8A/w==", cursor);
    defer replacement.deinit(a);
    try testing.expect(replacement.allocation_failed);
    try testing.expect(replacement.committed_transmission_image_id == null);
    try testing.expectEqual(@as(usize, 0), replacement.removed.items.len);
    try testing.expectEqual(@as(usize, 1), engine.store.placements_by_key.count());
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, engine.store.images_by_id.get(3).?.payload.bytes);
}

fn formatAllocations(a: std.mem.Allocator) !void {
    const compressed = [_]u8{ 0x78, 0x9c, 0xcb, 0x48, 0xcd, 0xc9, 0xc9, 0x07, 0x00, 0x06, 0x2c, 0x02, 0x15 };
    const bytes = try graphics.zlibInflated(a, &compressed, 32);
    defer a.free(bytes);
    const image = (try graphics.decodeITerm2(a, "File=inline=1:iVBO Rw0K\nGgoAAAANSUhEUgAAAAEAAAAC")).?;
    defer image.release();
    const owned = try a.dupe(u8, &.{ 0, 0, 0, 255 });
    const payload = graphics.Payload.createOwned(a, .rgba, owned, 1, 1) catch |err| { a.free(owned); return err; };
    defer payload.release();
    var attachment = try graphics.LineImage.init(payload, 0);
    defer attachment.deinit();
    var snapshot = attachment.clone();
    defer snapshot.deinit();
}

test "compressed and ignored-character formats survive every allocation failure" {
    try testing.checkAllAllocationFailures(testing.allocator, formatAllocations, .{});
}

test "native terminal protocol integration places images and serves bounded DCS requests" {
    const Terminal = @import("terminal.zig").Terminal;
    var terminal = try Terminal.init(testing.allocator, 8, 3, 10);
    defer terminal.deinit();
    try terminal.feed("\x1bPq~\x1b\\");
    try testing.expectEqual(@as(isize, 1), terminal.buffer().y);
    try testing.expectEqual(@as(u32, 6), terminal.buffer().line(0).?.images.?.items[0].payload.height);
    try terminal.feed("\x1b_Ga=T,i=7,s=1,v=1,q=2;/wAA/w==\x1b\\D");
    try testing.expectEqual(@as(usize, 1), terminal.protocol_state.kitty.store.images_by_id.count());
    try testing.expectEqual(@as(u32, 'D'), terminal.buffer().line(2).?.cell(0).scalar);
    try terminal.dcsHook('q', &.{}, "$");
    var huge: [4097]u8 = @splat('m');
    try terminal.dcsPut(&huge);
    try testing.expectEqual(@as(usize, 0), terminal.protocol_state.decrqss.items.len);
    try terminal.dcsUnhook();
    try @import("terminal_protocols.zig").resetGraphics(&terminal);
    try testing.expectEqual(@as(usize, 0), terminal.protocol_state.kitty.store.images_by_id.count());
    try testing.expect(terminal.buffer().line(0).?.images == null);
}

test "native terminal blocks expose wrapped command and output to host events" {
    const tm = @import("terminal.zig");
    const Capture = struct {
        command: [128]u8 = undefined,
        command_len: usize = 0,
        output: [128]u8 = undefined,
        output_len: usize = 0,
        completed: usize = 0,
        fn callback(context: ?*anyopaque, event: *const tm.Event) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (event.kind != .failed_command) return;
            self.completed += 1;
            self.command_len = @min(event.length, self.command.len);
            self.output_len = @min(event.length2, self.output.len);
            if (event.bytes) |bytes| @memcpy(self.command[0..self.command_len], bytes[0..self.command_len]);
            if (event.bytes2) |bytes| @memcpy(self.output[0..self.output_len], bytes[0..self.output_len]);
        }
    };
    var captured: Capture = .{};
    var terminal = try tm.Terminal.init(testing.allocator, 8, 5, 20);
    defer terminal.deinit();
    terminal.host = .{ .context = &captured, .event = Capture.callback };
    terminal.has_failed_command_provider = true;
    try terminal.feed("\x1b]133;A\x07$ \x1b]133;B\x07missing-cmd\r\n\x1b]133;C\x07failed\r\n\x1b]133;D;127\x07");
    try testing.expectEqualStrings("missing-cmd", captured.command[0..captured.command_len]);
    try testing.expectEqualStrings("failed", captured.output[0..captured.output_len]);
    try terminal.feed("\x1b]133;A\x07\x1b]133;D;127\x07");
    try testing.expectEqual(@as(usize, 1), captured.completed);
}

test "failure provider captures text after the finished callback mutates rows" {
    const tm = @import("terminal.zig");
    const Capture = struct {
        terminal: *tm.Terminal,
        seen_finished: bool = false,
        seen_provider: bool = false,
        failed: bool = false,
        fn callback(context: ?*anyopaque, event: *const tm.Event) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            switch (event.kind) {
                .command_finished => {
                    self.seen_finished = true;
                    const line = self.terminal.buffer().line(0).?;
                    line.writeASCII("new", 2, .{}) catch { self.failed = true; };
                    // The retained event block must remain valid after reset.
                    self.terminal.blocks.reset();
                },
                .failed_command => {
                    self.seen_provider = true;
                    self.failed = self.failed or !self.seen_finished or
                        !std.mem.eql(u8, event.bytes.?[0..event.length], "new") or event.object == null;
                },
                else => {},
            }
        }
    };
    var terminal = try tm.Terminal.init(testing.allocator, 12, 5, 20);
    defer terminal.deinit();
    var capture: Capture = .{ .terminal = &terminal };
    terminal.host = .{ .context = &capture, .event = Capture.callback };
    terminal.has_failed_command_provider = true;
    try terminal.feed("\x1b]133;A\x07$ \x1b]133;B\x07old\r\n\x1b]133;C\x07failure\r\n\x1b]133;D;1\x07");
    try testing.expect(capture.seen_finished and capture.seen_provider and !capture.failed);
}

fn putImage(store: *graphics.KittyGraphicsStore, id: u32, number: ?u32, payload: *graphics.Payload) !void {
    const image = try graphics.Image.create(payload, id, number);
    defer image.deinit();
    try store.store(image);
}

test "host payload release can replace buffers during graphics removal" {
    const tm = @import("terminal.zig");
    const bm = @import("buffer.zig");
    const Callback = struct {
        terminal: *tm.Terminal,
        releases: usize = 0,
        failed: bool = false,
        fn release(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.releases += 1;
            // Every replacement array must be published before this callback.
            if (self.terminal.normal.line(0).?.images != null) self.failed = true;
            const replacement = bm.Buffer.init(testing.allocator, 12, 3, true, 20) catch {
                self.failed = true; return;
            };
            var previous = self.terminal.normal;
            self.terminal.normal = replacement;
            previous.deinit();
        }
    };
    for ([_]bool{ false, true }) |kitty_delete| {
        var terminal = try tm.Terminal.init(testing.allocator, 12, 3, 20);
        defer terminal.deinit();
        var callback: Callback = .{ .terminal = &terminal };
        const payload = try graphics.Payload.createHostCopy(testing.allocator, .rgba, &.{ 1, 2, 3, 255 }, 1, 1);
        payload.host_owner = &callback;
        payload.host_release = Callback.release;
        const image = try graphics.LineImage.init(payload, 0);
        image.is_kitty = true; image.image_id = 3; image.placement_id = 1;
        try terminal.normal.line(0).?.appendImage(image);
        image.deinit(); payload.release();
        const tail = terminal.normal.line(2).?.retain();
        defer tail.release();
        const tail_payload = try graphics.Payload.createCopy(testing.allocator, .rgba, &.{ 9, 8, 7, 255 }, 1, 1);
        const tail_image = try graphics.LineImage.init(tail_payload, 0);
        tail_image.is_kitty = true; tail_image.image_id = 3; tail_image.placement_id = 2;
        try tail.appendImage(tail_image);
        tail_image.deinit(); tail_payload.release();
        if (kitty_delete) {
            _ = try terminal.protocol_state.kitty.store.place(.{ .image_id = 3, .placement_id = 1, .col = 0, .row = 0, .cols = 1, .rows = 1 });
            _ = try terminal.protocol_state.kitty.store.place(.{ .image_id = 3, .placement_id = 2, .col = 0, .row = 2, .cols = 1, .rows = 1 });
            try terminal.feed("\x1b_Ga=d,d=i,i=3,q=2\x1b\\");
        } else try @import("terminal_protocols.zig").resetGraphics(&terminal);
        try testing.expectEqual(@as(usize, 1), callback.releases);
        try testing.expect(!callback.failed);
        // Swift's captured row array keeps visiting the old rows even though
        // the callback replaced the live buffer in the middle of iteration.
        try testing.expect(tail.images == null);
        try testing.expectEqual(@as(isize, 3), terminal.normal.lineCount());
    }
}

test "store replacement publishes accounting and clear owns old map through payload callbacks" {
    const Callback = struct {
        store: *graphics.KittyGraphicsStore,
        replacement: *graphics.Image,
        count: usize = 0,
        failed: bool = false,
        fn release(context: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.count += 1;
            if (self.store.images_by_id.count() != 0) self.failed = true;
            self.store.store(self.replacement) catch { self.failed = true; };
        }
    };
    var store = graphics.KittyGraphicsStore.init(testing.allocator);
    defer store.deinit();
    const replacement_payload = try graphics.Payload.createCopy(testing.allocator, .rgba, &.{ 4, 5, 6, 255 }, 1, 1);
    defer replacement_payload.release();
    const replacement = try graphics.Image.create(replacement_payload, 2, null);
    defer replacement.deinit();
    var callback: Callback = .{ .store = &store, .replacement = replacement };
    const payload = try graphics.Payload.createCopy(testing.allocator, .rgba, &.{ 1, 2, 3, 255 }, 1, 1);
    payload.host_owner = &callback; payload.host_release = Callback.release;
    try putImage(&store, 1, null, payload);
    payload.release();
    store.deleteAll();
    try testing.expectEqual(@as(usize, 1), callback.count);
    try testing.expect(!callback.failed and store.images_by_id.contains(2));
    // Swift clears accounting after the image-array release callback. A later
    // replacement/deletion must saturate stale accounting rather than underflow.
    try testing.expectEqual(@as(usize, 0), store.payload_bytes);
    try store.store(replacement);
    try testing.expectEqual(@as(usize, 4), store.payload_bytes);
    store.deleteImage(2);
    try testing.expectEqual(@as(usize, 0), store.payload_bytes);
}

test "raw APC preserves rectangle cursor effects while parser owns history motion" {
    const tm = @import("terminal.zig");
    const protocols = @import("terminal_protocols.zig");
    var raw = try tm.Terminal.init(testing.allocator, 12, 5, 20);
    defer raw.deinit();
    var parsed = try tm.Terminal.init(testing.allocator, 12, 5, 20);
    defer parsed.deinit();
    raw.normal.x = 7; raw.normal.y = 4;
    parsed.normal.x = 7; parsed.normal.y = 4;
    const bytes = "Ga=T,f=32,s=1,v=1,i=7,r=3,q=2;AQIDBA==";
    try testing.expect(try protocols.handleAPC(&raw, bytes));
    try protocols.apc(&parsed, bytes);
    try testing.expectEqual(@as(isize, 0), raw.normal.x);
    try testing.expectEqual(@as(isize, 4), raw.normal.y);
    try testing.expectEqual(@as(isize, 0), raw.normal.y_base);
    try testing.expectEqual(@as(isize, 1), parsed.normal.y_base);
    try testing.expectEqual(@as(isize, 5), raw.normal.lineCount());
    try testing.expectEqual(@as(isize, 6), parsed.normal.lineCount());
}

test "raw transmit keeps old row attachment and omitted Kitty spans are one cell" {
    const tm = @import("terminal.zig");
    const protocols = @import("terminal_protocols.zig");
    var terminal = try tm.Terminal.init(testing.allocator, 12, 5, 20);
    defer terminal.deinit();
    try testing.expect(!(try protocols.handleAPC(&terminal, "Ga=T,f=32,s=1,v=1,i=7,C=1,q=2;AQIDBA==")));
    const row = terminal.normal.line(0).?;
    const old = row.images.?.items[0].clone();
    defer old.deinit();
    try testing.expect(!(try protocols.handleAPC(&terminal, "Ga=t,f=32,s=1,v=1,i=7,q=2;BAUGBw==")));
    try testing.expect(row.images.?.items[0] == old);
    try protocols.apc(&terminal, "Ga=t,f=32,s=1,v=1,i=7,q=2;BAUGBw==");
    try testing.expect(row.images == null);
    const stored = terminal.protocol_state.kitty.store.images_by_id.get(7).?;
    stored.pixel_width = 900; stored.pixel_height = 800;
    try testing.expect(try protocols.handleAPC(&terminal, "Ga=p,i=7,q=2"));
    const placement = terminal.protocol_state.kitty.store.placements_by_key.values()[0];
    try testing.expectEqual(@as(isize, 1), placement.cols);
    try testing.expectEqual(@as(isize, 1), placement.rows);
    try testing.expectEqual(@as(isize, 1), terminal.normal.y);
}

test "raw uppercase Kitty deletion removes attachments and data before its reply" {
    const tm = @import("terminal.zig");
    const protocols = @import("terminal_protocols.zig");
    const Capture = struct {
        terminal: *tm.Terminal,
        replies: usize = 0,
        failed: bool = false,
        fn callback(context: ?*anyopaque, event: *const tm.Event) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (event.kind != .send) return;
            self.replies += 1;
            self.failed = self.failed or self.terminal.normal.line(0).?.images != null or
                self.terminal.protocol_state.kitty.store.images_by_id.count() != 0;
        }
    };
    var terminal = try tm.Terminal.init(testing.allocator, 12, 5, 20);
    defer terminal.deinit();
    _ = try protocols.handleAPC(&terminal, "Ga=T,f=32,s=1,v=1,i=7,C=1,q=2;AQIDBA==");
    var capture: Capture = .{ .terminal = &terminal };
    terminal.host = .{ .context = &capture, .event = Capture.callback };
    try testing.expect(!(try protocols.handleAPC(&terminal, "Ga=d,d=I,i=7")));
    try testing.expectEqual(@as(usize, 1), capture.replies);
    try testing.expect(!capture.failed);
}
