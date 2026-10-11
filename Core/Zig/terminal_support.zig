//! Platform-neutral mouse protocol encoding.
const std = @import("std");
pub fn sendMouseEvent(t: anytype, button: isize, pressed: bool, motion: bool, modifiers: isize, col: isize, row: isize) anyerror!bool {
    if (t.mouse_mode == .off) return false;
    if (motion) {
        switch (t.mouse_mode) {
            .any_event => {},
            .button_event => if (!pressed and button < 0) {
                return false;
            },
            else => return false,
        }
    } else if (t.mouse_mode == .x10 and !pressed) return false;
    var flags: isize = if (button >= 64 or pressed or t.mouse_protocol == .sgr) button else 3;
    if (motion) flags +|= 32;
    if (modifiers & 1 != 0) flags |= 4;
    if (modifiers & 2 != 0) flags |= 8;
    if (modifiers & 4 != 0) flags |= 16;
    const x = std.math.clamp(col, 0, t.buffer().cols - 1);
    const y = std.math.clamp(row, 0, t.buffer().rows - 1);
    var text: [128]u8 = undefined;
    const bytes: []const u8 = switch (t.mouse_protocol) {
        .sgr => try std.fmt.bufPrint(&text, "\x1b[<{d};{d};{d}{c}", .{ flags, x + 1, y + 1, @as(u8, if (pressed) 'M' else 'm') }),
        .urxvt => try std.fmt.bufPrint(&text, "\x1b[{d};{d};{d}M", .{ flags +| 32, x + 1, y + 1 }),
        .utf8, .x10 => blk: {
            text[0..6].* = .{ 0x1b, 0x5b, 0x4d, @intCast(std.math.clamp(flags +| 32, 0, 255)), @intCast(std.math.clamp(x +| 33, 0, 255)), @intCast(std.math.clamp(y +| 33, 0, 255)) };
            break :blk text[0..6];
        },
    };
    try t.sendResponse(bytes);
    return true;
}
