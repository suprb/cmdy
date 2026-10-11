//! Stateful left-to-right Kitty Unicode placeholder decoding. Value state is
//! copied by the Swift facade, so decoder copies never share inheritance.
const std = @import("std");
pub const Value = extern struct {
    row: isize = 0,
    col: isize = 0,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    placeholder_row: isize = 0,
    placeholder_col: isize = 0,
    msb: isize = 0,
};
pub const State = extern struct {
    physical_row: isize = 0,
    physical_col: isize = 0,
    placeholder_row: isize = 0,
    placeholder_col: isize = 0,
    msb: isize = 0,
    foreground: u32 = 0,
    underline: u32 = 0,
    has_underline: u8 = 0,
    valid: u8 = 0,

    pub fn reset(self: *State) void { self.* = .{}; }
    fn invalidate(self: *State) ?Value { self.reset(); return null; }
    pub fn decode(self: *State, scalar: u32, foreground: u32, underline: ?u32,
        marks: []const u32, row: isize, column: isize) ?Value {
        const low_image_id = encodedColor(foreground) orelse return self.invalidate();
        if (row < 0 or column < 0 or scalar != 0x10eeee or low_image_id == 0 or marks.len > 3) return self.invalidate();
        var values: [3]isize = undefined;
        for (marks, 0..) |mark, index| values[index] = diacriticIndex(mark) orelse return self.invalidate();
        const preceding = self.valid != 0 and self.physical_row == row and
            self.physical_col < std.math.maxInt(isize) and self.physical_col + 1 == column and
            self.foreground == foreground and (self.has_underline != 0) == (underline != null) and
            (underline == null or self.underline == underline.?);
        var placeholder_row: isize = undefined;
        var placeholder_col: isize = undefined;
        var msb: isize = 0;
        switch (marks.len) {
            0 => {
                if (!preceding or self.placeholder_col >= 255) return self.invalidate();
                placeholder_row = self.placeholder_row; placeholder_col = self.placeholder_col + 1; msb = self.msb;
            },
            1 => {
                placeholder_row = values[0]; placeholder_col = 0;
                if (preceding and self.placeholder_row == placeholder_row and self.placeholder_col < 255) {
                    placeholder_col = self.placeholder_col + 1; msb = self.msb;
                }
            },
            2 => {
                placeholder_row = values[0]; placeholder_col = values[1];
                if (preceding and self.placeholder_row == placeholder_row and self.placeholder_col < 255 and
                    self.placeholder_col + 1 == placeholder_col) msb = self.msb;
            },
            3 => { placeholder_row = values[0]; placeholder_col = values[1]; msb = values[2]; },
            else => unreachable,
        }
        self.* = .{ .physical_row = row, .physical_col = column, .placeholder_row = placeholder_row,
            .placeholder_col = placeholder_col, .msb = msb, .foreground = foreground,
            .underline = underline orelse 0, .has_underline = @intFromBool(underline != null), .valid = 1 };
        return .{ .row = row, .col = column, .image_id = low_image_id | (@as(u32, @intCast(msb)) << 24),
            .placement_id = if (underline) |color| encodedColor(color) orelse 0 else 0,
            .placeholder_row = placeholder_row, .placeholder_col = placeholder_col, .msb = msb };
    }
};

fn encodedColor(color: u32) ?u32 {
    return switch (color >> 24) { 1 => color & 0xff, 2 => color & 0xffffff, else => null };
}

fn diacriticIndex(scalar: u32) ?isize {
    var low: usize = 0;
    var high: usize = official_diacritics.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const value = official_diacritics[middle];
        if (value < scalar) low = middle + 1 else high = middle;
    }
    if (low >= official_diacritics.len or low > 255 or official_diacritics[low] != scalar) return null;
    return @intCast(low);
}

// Normative Kitty graphics protocol data: the ordered row/column combining
// diacritics from the official specification,
// https://sw.kovidgoyal.net/kitty/_downloads/f0a0de9ec8d9ff4456206db8e0814937/rowcolumn-diacritics.txt
// Pinned to the original CMDY Swift table (Kitty's Unicode-6-derived order).
const official_diacritics = [_]u32{
        0x305, 0x30D, 0x30E, 0x310, 0x312, 0x33D, 0x33E, 0x33F,
        0x346, 0x34A, 0x34B, 0x34C, 0x350, 0x351, 0x352, 0x357,
        0x35B, 0x363, 0x364, 0x365, 0x366, 0x367, 0x368, 0x369,
        0x36A, 0x36B, 0x36C, 0x36D, 0x36E, 0x36F, 0x483, 0x484,
        0x485, 0x486, 0x487, 0x592, 0x593, 0x594, 0x595, 0x597,
        0x598, 0x599, 0x59C, 0x59D, 0x59E, 0x59F, 0x5A0, 0x5A1,
        0x5A8, 0x5A9, 0x5AB, 0x5AC, 0x5AF, 0x5C4, 0x610, 0x611,
        0x612, 0x613, 0x614, 0x615, 0x616, 0x617, 0x657, 0x658,
        0x659, 0x65A, 0x65B, 0x65D, 0x65E, 0x6D6, 0x6D7, 0x6D8,
        0x6D9, 0x6DA, 0x6DB, 0x6DC, 0x6DF, 0x6E0, 0x6E1, 0x6E2,
        0x6E4, 0x6E7, 0x6E8, 0x6EB, 0x6EC, 0x730, 0x732, 0x733,
        0x735, 0x736, 0x73A, 0x73D, 0x73F, 0x740, 0x741, 0x743,
        0x745, 0x747, 0x749, 0x74A, 0x7EB, 0x7EC, 0x7ED, 0x7EE,
        0x7EF, 0x7F0, 0x7F1, 0x7F3, 0x816, 0x817, 0x818, 0x819,
        0x81B, 0x81C, 0x81D, 0x81E, 0x81F, 0x820, 0x821, 0x822,
        0x823, 0x825, 0x826, 0x827, 0x829, 0x82A, 0x82B, 0x82C,
        0x82D, 0x951, 0x953, 0x954, 0xF82, 0xF83, 0xF86, 0xF87,
        0x135D, 0x135E, 0x135F, 0x17DD, 0x193A, 0x1A17, 0x1A75, 0x1A76,
        0x1A77, 0x1A78, 0x1A79, 0x1A7A, 0x1A7B, 0x1A7C, 0x1B6B, 0x1B6D,
        0x1B6E, 0x1B6F, 0x1B70, 0x1B71, 0x1B72, 0x1B73, 0x1CD0, 0x1CD1,
        0x1CD2, 0x1CDA, 0x1CDB, 0x1CE0, 0x1DC0, 0x1DC1, 0x1DC3, 0x1DC4,
        0x1DC5, 0x1DC6, 0x1DC7, 0x1DC8, 0x1DC9, 0x1DCB, 0x1DCC, 0x1DD1,
        0x1DD2, 0x1DD3, 0x1DD4, 0x1DD5, 0x1DD6, 0x1DD7, 0x1DD8, 0x1DD9,
        0x1DDA, 0x1DDB, 0x1DDC, 0x1DDD, 0x1DDE, 0x1DDF, 0x1DE0, 0x1DE1,
        0x1DE2, 0x1DE3, 0x1DE4, 0x1DE5, 0x1DE6, 0x1DFE, 0x20D0, 0x20D1,
        0x20D4, 0x20D5, 0x20D6, 0x20D7, 0x20DB, 0x20DC, 0x20E1, 0x20E7,
        0x20E9, 0x20F0, 0x2CEF, 0x2CF0, 0x2CF1, 0x2DE0, 0x2DE1, 0x2DE2,
        0x2DE3, 0x2DE4, 0x2DE5, 0x2DE6, 0x2DE7, 0x2DE8, 0x2DE9, 0x2DEA,
        0x2DEB, 0x2DEC, 0x2DED, 0x2DEE, 0x2DEF, 0x2DF0, 0x2DF1, 0x2DF2,
        0x2DF3, 0x2DF4, 0x2DF5, 0x2DF6, 0x2DF7, 0x2DF8, 0x2DF9, 0x2DFA,
        0x2DFB, 0x2DFC, 0x2DFD, 0x2DFE, 0x2DFF, 0xA66F, 0xA67C, 0xA67D,
        0xA6F0, 0xA6F1, 0xA8E0, 0xA8E1, 0xA8E2, 0xA8E3, 0xA8E4, 0xA8E5,
        0xA8E6, 0xA8E7, 0xA8E8, 0xA8E9, 0xA8EA, 0xA8EB, 0xA8EC, 0xA8ED,
        0xA8EE, 0xA8EF, 0xA8F0, 0xA8F1, 0xAAB0, 0xAAB2, 0xAAB3, 0xAAB7,
        0xAAB8, 0xAABE, 0xAABF, 0xAAC1, 0xFE20, 0xFE21, 0xFE22, 0xFE23,
        0xFE24, 0xFE25, 0xFE26, 0x10A0F, 0x10A38, 0x1D185, 0x1D186, 0x1D187,
        0x1D188, 0x1D189, 0x1D1AA, 0x1D1AB, 0x1D1AC, 0x1D1AD, 0x1D242, 0x1D243,
        0x1D244,
};

test "placeholder table boundaries, inheritance, reset and value copies" {
    const testing = std.testing;
    var state: State = .{};
    const first = state.decode(0x10eeee, 0x0100002a, 0x02010203, &.{ 0x305, 0x30d, 0x30e }, 9, 4).?;
    try testing.expectEqual(@as(u32, 0x0200002a), first.image_id);
    try testing.expectEqual(@as(u32, 0x010203), first.placement_id);
    try testing.expectEqual(@as(isize, 1), first.placeholder_col);
    var copy = state;
    state.reset();
    const inherited = copy.decode(0x10eeee, 0x0100002a, 0x02010203, &.{}, 9, 5).?;
    try testing.expectEqual(@as(isize, 2), inherited.placeholder_col);
    try testing.expectEqual(@as(isize, 2), inherited.msb);
    try testing.expect(state.decode(0x10eeee, 0x0100002a, 0x02010203, &.{}, 9, 5) == null);
    try testing.expect(copy.decode(0x10eeee, 0x0100002b, null, &.{}, 9, 6) == null);
    try testing.expectEqual(@as(isize, 255), state.decode(0x10eeee, 0x02010203, null, &.{0xa8e5}, 0, 0).?.placeholder_row);
    try testing.expect(state.decode(0x10eeee, 0x02010203, null, &.{0xa8e6}, 0, 1) == null);
    try testing.expect(state.decode(0x10eeee, 0x02010203, null, &.{0x300}, 0, 2) == null);
    try testing.expect(state.decode(0x10eeee, 0x01000000, null, &.{0x305}, 0, 3) == null);
    for (official_diacritics[0..256], 0..) |scalar, index| try testing.expectEqual(@as(?isize, @intCast(index)), diacriticIndex(scalar));
}
