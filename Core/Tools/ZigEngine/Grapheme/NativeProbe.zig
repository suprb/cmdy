const std = @import("std");
const text = @import("cell_text");
export fn cmdy_grapheme_probe(first: u32, extras: ?[*]const u32, count: usize, output: [*]u8, capacity: usize) isize {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(std.heap.c_allocator);
    const tail: []const u32 = if (count == 0) &.{} else (extras orelse return -1)[0..count];
    text.append(&bytes, std.heap.c_allocator, first, tail) catch return -1;
    if (bytes.items.len > capacity) return -2;
    @memcpy(output[0..bytes.items.len], bytes.items);
    return @intCast(bytes.items.len);
}
