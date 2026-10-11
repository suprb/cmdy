//! Keep absolute row coordinates while omitting transparent trailing columns.
const std = @import("std");

pub fn width(bytes: []const u8, stride: usize, height: usize, atlas_required: bool) usize {
    std.debug.assert(stride > 0 and height > 0 and bytes.len / stride >= height);
    var end: usize = 0;
    for (0..height) |y| {
        if (std.mem.lastIndexOfNone(u8, bytes[y * stride + end ..][0 .. stride - end], &.{0})) |last| {
            end += last + 1;
            if (end == stride) return stride;
        }
    }
    if (end == 0 and !atlas_required) return 0;
    // Linear and nearest clamp-to-edge sampling beyond the stored area must
    // see zero, including cursor inversion and DEC line-mode sample spans.
    return @min(stride, end + 1);
}

test "coverage storage keeps every row's ink and a transparent clamp border" {
    const pixels = [_]u8{
        10, 0, 20, 0, 0, 0, 0, 0,
        0, 0, 0,  0, 0, 7, 0, 0,
        0, 1, 0,  0, 0, 0, 0, 0,
    };
    try std.testing.expectEqual(@as(usize, 7), width(&pixels, 8, 3, false));
    for (0..3) |y| for (0..8) |x| {
        try std.testing.expectEqual(pixels[y * 8 + x], pixels[y * 8 + @min(x, 6)]);
    };
}

test "coverage storage preserves right-edge ink and empty DEC atlas eligibility" {
    try std.testing.expectEqual(@as(usize, 4), width(&.{ 0, 0, 0, 1 }, 4, 1, false));
    try std.testing.expectEqual(@as(usize, 4), width(&.{ 0, 0, 1, 0 }, 4, 1, false));
    try std.testing.expectEqual(@as(usize, 0), width(&.{ 0, 0, 0, 0 }, 2, 2, false));
    try std.testing.expectEqual(@as(usize, 1), width(&.{ 0, 0, 0, 0 }, 2, 2, true));
    try std.testing.expectEqual(@as(usize, 1), width(&.{1}, 1, 1, false));
}
