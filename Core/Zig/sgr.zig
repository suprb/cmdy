// CMDY's SGR consumption semantics, ported from its independent Swift scanner.
// No operation objects, dictionaries, group arrays, allocation or callbacks.
fn underline(pen: anytype, kind: u8) void {
    pen.underline_kind = kind;
    if (kind == 0) pen.style &= ~@as(u8, 2) else pen.style |= 2;
}
fn indexed(value: isize) ?u32 {
    if (value < 0 or value > 255) return null;
    return 0x01000000 | @as(u32, @intCast(value));
}
fn rgb(r: isize, g: isize, b: isize) ?u32 {
    if (r < 0 or r > 255 or g < 0 or g > 255 or b < 0 or b > 255) return null;
    return 0x02000000 | (@as(u32, @intCast(r)) << 16) |
        (@as(u32, @intCast(g)) << 8) | @as(u32, @intCast(b));
}
fn color(pen: anytype, selector: isize, value: u32) void {
    switch (selector) {
        38 => pen.fg = value,
        48 => pen.bg = value,
        58 => {
            pen.underline_color = value;
            pen.underline_present = 1;
        },
        else => unreachable,
    }
}
fn reset(pen: anytype) void {
    pen.fg = 0;
    pen.bg = 0;
    pen.style = 0;
    pen.underline_kind = 0;
    pen.underline_color = 0;
    pen.underline_present = 0;
}
pub fn apply(pen: anytype, values: []const isize) void {
    if (values.len == 0) return reset(pen);
    var cursor: usize = 0;
    while (cursor < values.len) {
        const selector = values[cursor];
        if (selector == -1) {
            cursor += 1;
            continue;
        }
        if (cursor + 1 < values.len and values[cursor + 1] == -1) {
            var group: [5]isize = undefined;
            var count: usize = 0;
            cursor += 1;
            while (cursor < values.len and values[cursor] == -1) {
                cursor += 1;
                if (cursor == values.len) break;
                if (count < group.len) group[count] = values[cursor];
                count += 1;
                cursor += 1;
            }
            if (selector == 4) {
                if (count == 1 and group[0] >= 0 and group[0] <= 5) underline(pen, @intCast(group[0]));
            } else if (selector == 38 or selector == 48 or selector == 58) {
                const value: ?u32 = if (count == 2 and group[0] == 5) indexed(group[1]) else
                    if (count == 4 and group[0] == 2) rgb(group[1], group[2], group[3]) else
                    if (count == 5 and group[0] == 2 and group[1] == 0) rgb(group[2], group[3], group[4]) else null;
                if (value) |v| color(pen, selector, v);
            }
            continue;
        }
        if (selector == 38 or selector == 48 or selector == 58) {
            const start = cursor;
            cursor += 1;
            if (cursor == values.len) continue;
            const mode = values[cursor];
            cursor += 1;
            if (mode == 5) {
                if (cursor < values.len) {
                    if (indexed(values[cursor])) |v| color(pen, selector, v);
                    cursor += 1;
                }
            } else if (mode == 2 and start + 5 <= values.len) {
                if (rgb(values[start + 2], values[start + 3], values[start + 4])) |v| color(pen, selector, v);
                cursor = start + 5;
            }
            // Truncated RGB owns only selector/mode. Remaining values are SGR.
            continue;
        }
        cursor += 1;
        switch (selector) {
            0 => reset(pen),
            1 => pen.style |= 1,
            2 => pen.style |= 32,
            3 => pen.style |= 64,
            4 => underline(pen, 1),
            5, 6 => pen.style |= 4,
            7 => pen.style |= 8,
            8 => pen.style |= 16,
            9 => pen.style |= 128,
            21 => underline(pen, 2),
            22 => pen.style &= ~@as(u8, 33),
            23 => pen.style &= ~@as(u8, 64),
            24 => underline(pen, 0),
            25 => pen.style &= ~@as(u8, 4),
            27 => pen.style &= ~@as(u8, 8),
            28 => pen.style &= ~@as(u8, 16),
            29 => pen.style &= ~@as(u8, 128),
            30...37 => pen.fg = indexed(selector - 30).?,
            40...47 => pen.bg = indexed(selector - 40).?,
            90...97 => pen.fg = indexed(selector - 90 + 8).?,
            100...107 => pen.bg = indexed(selector - 100 + 8).?,
            39 => pen.fg = 0,
            49 => pen.bg = 0,
            59 => {
                pen.underline_present = 0;
                pen.underline_color = 0;
            },
            else => {},
        }
    }
}
