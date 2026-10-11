//! Cell.text exposes only String.first from the cell's valid Unicode scalars.
//! Storage is intentionally more permissive than an extended grapheme cluster:
//! zero-width format controls and manually supplied extras can contain breaks.
//! This is a text projection, never a mutation of the raw cell representation.
const std = @import("std");
const properties = @import("grapheme_properties.zig");
const Allocator = std.mem.Allocator;
const Class = enum(u4) { other, cr, lf, control, extend, zwj, regional, prepend, spacing, l, v, t, lv, lvt };
const Indic = enum(u2) { none, consonant, extend, linker };
const Property = packed struct(u8) { kind: Class, pictographic: bool, indic: Indic, reserved: u1 };

fn property(scalar: u32) Property {
    return @bitCast(properties.property(scalar));
}
pub fn validScalar(scalar: u32) bool {
    return scalar <= 0x10ffff and !(scalar >= 0xd800 and scalar <= 0xdfff);
}
fn control(kind: Class) bool {
    return kind == .cr or kind == .lf or kind == .control;
}

/// UAX #29 extended grapheme rules, revision 45. The state retains exactly the
/// left-context suffixes needed by RI pairing, pictographic ZWJ, and Indic GB9c.
pub const State = struct {
    previous: Class = .other,
    regional_odd: bool = false,
    pictographic_extend_suffix: bool = false,
    pictographic_zwj_suffix: bool = false,
    indic_suffix: enum { none, consonant, linked } = .none,

    pub fn init(first: u32) State {
        var result: State = .{};
        result.accept(property(first));
        return result;
    }
    pub fn continues(self: *State, scalar: u32) bool {
        const current = property(scalar);
        const before = self.previous;
        const after = current.kind;
        const keep = if (before == .cr and after == .lf)
            true // GB3
        else if (control(before) or control(after))
            false // GB4, GB5
        else if (before == .l and (after == .l or after == .v or after == .lv or after == .lvt))
            true // GB6
        else if ((before == .lv or before == .v) and (after == .v or after == .t))
            true // GB7
        else if ((before == .lvt or before == .t) and after == .t)
            true // GB8
        else if (after == .extend or after == .zwj or after == .spacing or before == .prepend)
            true // GB9, GB9a, GB9b
        else if (current.indic == .consonant and self.indic_suffix == .linked)
            true // GB9c
        else if (current.pictographic and self.pictographic_zwj_suffix)
            true // GB11
        else if (before == .regional and after == .regional and self.regional_odd)
            true // GB12, GB13
        else
            false; // GB999
        if (keep) self.accept(current);
        return keep;
    }
    fn accept(self: *State, current: Property) void {
        self.regional_odd = current.kind == .regional and
            (self.previous != .regional or !self.regional_odd);
        self.pictographic_zwj_suffix = current.kind == .zwj and self.pictographic_extend_suffix;
        self.pictographic_extend_suffix = current.pictographic or
            (current.kind == .extend and self.pictographic_extend_suffix);
        switch (current.indic) {
            .none => self.indic_suffix = .none,
            .consonant => self.indic_suffix = .consonant,
            .extend => {},
            .linker => if (self.indic_suffix != .none) { self.indic_suffix = .linked; },
        }
        self.previous = current.kind;
    }
};

fn appendScalar(output: *std.ArrayList(u8), allocator: Allocator, scalar: u32) Allocator.Error!void {
    var bytes: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(@intCast(scalar), &bytes) catch unreachable;
    try output.appendSlice(allocator, bytes[0..length]);
}

/// Append the original Cell.text projection. Blank cells produce an empty
/// string; a nonzero invalid lead produces a space and ignores all extras.
/// Invalid extras are omitted before segmentation, as in Unicode.Scalar init.
pub fn append(output: *std.ArrayList(u8), allocator: Allocator, lead: u32, extras: ?[]const u32) Allocator.Error!void {
    if (lead == 0) return;
    if (!validScalar(lead)) return output.append(allocator, ' ');
    try appendScalar(output, allocator, lead);
    var state = State.init(lead);
    for (extras orelse &.{}) |scalar| {
        if (!validScalar(scalar)) continue;
        if (!state.continues(scalar)) break;
        try appendScalar(output, allocator, scalar);
    }
}

fn expectText(expected: []const u8, lead: u32, extras: ?[]const u32) !void {
    var result: std.ArrayList(u8) = .empty;
    defer result.deinit(std.testing.allocator);
    try append(&result, std.testing.allocator, lead, extras);
    try std.testing.expectEqualStrings(expected, result.items);
}

test "text projection stops at format controls without changing raw extras" {
    const extras = [_]u32{ 0x301, 0x200b, 0x308 };
    try expectText("A\u{301}", 'A', &extras);
    try std.testing.expectEqual(@as(u32, 0x200b), extras[1]);
    try expectText("A\u{200c}\u{200d}\u{301}", 'A', &.{ 0x200c, 0x200d, 0x301 });
    for ([_]u32{ 0x200b, 0x200e, 0x2028, 0x2060 }) |scalar| try expectText("A", 'A', &.{ scalar, 0x301 });
}

test "text projection preserves CRLF Hangul Indic and pictographic contexts" {
    try expectText("\r\n", 13, &.{ 10, 0x301 });
    try expectText("\u{1100}\u{1161}\u{11a8}", 0x1100, &.{ 0x1161, 0x11a8, 'A' });
    try expectText("\u{915}\u{94d}\u{937}\u{93f}", 0x915, &.{ 0x94d, 0x937, 0x93f, 'A' });
    try expectText("\u{1f469}\u{301}\u{200d}\u{1f33e}", 0x1f469, &.{ 0x301, 0x200d, 0x1f33e });
    try expectText("A\u{200d}", 'A', &.{ 0x200d, 0x1f33e });
    try expectText("\u{1f469}\u{200d}\u{200d}", 0x1f469, &.{ 0x200d, 0x200d, 0x1f33e });
    try expectText("\u{1f1e6}\u{1f1e7}", 0x1f1e6, &.{ 0x1f1e7, 0x1f1e8 });
    try expectText("\u{1f1e6}\u{301}", 0x1f1e6, &.{ 0x301, 0x1f1e7 });
}

test "raw invalid leads and extras match Cell.text" {
    try expectText("", 0, &.{ 'A', 0x301 });
    try expectText(" ", 0x110000, &.{ 0x301 });
    try expectText(" ", 0xd800, &.{ 'A' });
    try expectText("A\u{301}", 'A', &.{ 0xd800, 0x110000, 0x301, 'B' });
    try expectText("A", 'A', &.{ 0, 0x301 });
}

test "all Unicode 16 grapheme boundary conformance cases" {
    const bytes = @embedFile("testdata/grapheme_break_tests.bin");
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < bytes.len) {
        const length = bytes[offset];
        const mask = bytes[offset + 1];
        offset += 2;
        const first = std.mem.readInt(u32, bytes[offset..][0..4], .little);
        offset += 4;
        var state = State.init(first);
        try std.testing.expect(mask & 1 != 0);
        for (1..length) |i| {
            const scalar = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            offset += 4;
            const expected_break = mask & (@as(u8, 1) << @intCast(i)) != 0;
            const actual_break = !state.continues(scalar);
            try std.testing.expectEqual(expected_break, actual_break);
            if (actual_break) state = State.init(scalar);
        }
        try std.testing.expect(mask & (@as(u8, 1) << @intCast(length)) != 0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1093), count);
}

fn allocationTrace(allocator: Allocator) !void {
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    var extras: [1000]u32 = @splat(0x301);
    extras[999] = 0x200b;
    try append(&output, allocator, 'A', &extras);
    try std.testing.expectEqual(@as(usize, 1999), output.items.len);
}
test "text projection cleans up every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrace, .{});
}
