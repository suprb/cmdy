//! Terminal modes and keyboard protocol state; called only by the native engine.
const std = @import("std");

pub fn setModes(t: anytype, params: []const isize, collect: []const u8, enabled: bool) anyerror!void {
    const private = collect.len > 0 and collect[0] == '?';
    for (params) |mode| {
        if (private) {
            try setPrivateMode(t, mode, enabled);
        } else switch (mode) {
            4 => t.insert_mode = enabled,
            20 => t.line_feed_mode = enabled,
            else => {},
        }
    }
}

pub fn setPrivateMode(t: anytype, mode: isize, enabled: bool) anyerror!void {
    switch (mode) {
        1 => t.application_cursor_keys = enabled,
        3 => if (t.allow_80_to_132) {
            try t.resize(if (enabled) 132 else 80, t.buffer().rows);
            try t.fullReset();
        },
        5 => {
            t.reverse_video = enabled;
            t.pen = if (enabled) .{ .fg = 0x03000000, .bg = 0x03000000 } else .{};
        },
        6 => t.origin_mode = enabled,
        7 => t.auto_wrap = enabled,
        9 => t.mouse_mode = if (enabled) .x10 else .off,
        12 => t.cursor_blink = enabled,
        25 => t.cursor_hidden = !enabled,
        40 => t.allow_80_to_132 = enabled,
        45 => if (!enabled or t.auto_wrap) {
            t.reverse_wraparound = enabled;
        },
        69 => t.margin_mode = enabled,
        47, 1047 => {
            if (enabled) try switchToAltBuffer(t, true, false) else try switchToNormalBuffer(t, false);
            t.cursor_hidden = false;
        },
        1000 => t.mouse_mode = if (enabled) .vt200 else .off,
        1002 => t.mouse_mode = if (enabled) .button_event else .off,
        1003 => t.mouse_mode = if (enabled) .any_event else .off,
        1004 => t.focus_reporting = enabled,
        1005, 1006, 1015 => {
            t.mouse_protocol = if (!enabled) .x10 else switch (mode) {
                1005 => .utf8,
                1006 => .sgr,
                else => .urxvt,
            };
            if (!enabled) t.mouse_mode = .off;
        },
        1048 => if (enabled) {
            t.saveCursor();
        } else {
            try t.restoreCursor();
        },
        1049 => {
            if (enabled) try switchToAltBuffer(t, true, true) else try switchToNormalBuffer(t, true);
            t.cursor_hidden = false;
        },
        2004 => t.bracketed_paste = enabled,
        2026 => t.synchronized_updates = enabled,
        else => {},
    }
}

pub fn privateModeValue(t: anytype, mode: isize) bool {
    return switch (mode) {
        1 => t.application_cursor_keys,
        5 => t.reverse_video,
        6 => t.origin_mode,
        7 => t.auto_wrap,
        9 => t.mouse_mode == .x10,
        12 => t.cursor_blink,
        25 => !t.cursor_hidden,
        40 => t.allow_80_to_132,
        47, 1047, 1049 => t.is_alternate,
        45 => t.reverse_wraparound,
        69 => t.margin_mode,
        1000 => t.mouse_mode == .vt200,
        1002 => t.mouse_mode == .button_event,
        1003 => t.mouse_mode == .any_event,
        1004 => t.focus_reporting,
        1005 => t.mouse_protocol == .utf8,
        1006 => t.mouse_protocol == .sgr,
        1015 => t.mouse_protocol == .urxvt,
        2004 => t.bracketed_paste,
        2026 => t.synchronized_updates,
        else => false,
    };
}

pub fn reportMode(t: anytype, mode: isize, private: bool) anyerror!void {
    const status: u8 = if (private) switch (mode) {
        1, 5, 6, 7, 9, 12, 25, 40, 45, 47, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1015, 1047, 1048, 1049, 2004, 2026 => if (privateModeValue(t, mode)) 1 else 2,
        else => 0,
    } else switch (mode) {
        4 => if (t.insert_mode) 1 else 2,
        20 => if (t.line_feed_mode) 1 else 2,
        else => 0,
    };
    var bytes: [96]u8 = undefined;
    const response = std.fmt.bufPrint(&bytes, "\x1b[{s}{d};{d}$y", .{ if (private) "?" else "", mode, status }) catch unreachable;
    try t.sendResponse(response);
}

pub fn switchToAltBuffer(t: anytype, clear: bool, save: bool) anyerror!void {
    if (t.is_alternate) return;
    if (save) t.saveCursor();
    try t.alternate.resizeSimple(t.normal.cols, t.normal.rows, .{});
    t.alternate.x = t.normal.x;
    t.alternate.y = t.normal.y;
    try t.setActiveBuffer(true);
    var r: isize = 0;
    while (r < t.alternate.rows) : (r += 1) {
        const line = t.alternate.liveLine(r);
        try line.fillCell(.{}, 0, null);
        line.setWrapped(false);
        line.clearImages();
        line.setRenderMode(.single);
    }
    _ = clear;
}

pub fn switchToNormalBuffer(t: anytype, restore: bool) anyerror!void {
    if (!t.is_alternate) return;
    t.normal.x = t.alternate.x;
    t.normal.y = @min(t.alternate.y, t.normal.rows - 1);
    try t.setActiveBuffer(false);
    if (restore) try t.restoreCursor();
}

pub fn keyboardFlags(t: anytype) isize {
    const items = if (t.is_alternate) t.keyboard_alt.items else t.keyboard_normal.items;
    return if (items.len == 0) 0 else items[items.len - 1];
}

// Kitty requires finite stacks and oldest-entry eviction at capacity. Reserve
// exactly this bound so attacker-controlled pushes cannot grow retained storage.
pub const keyboard_stack_limit = 64;

pub fn keyboardCSI(t: anytype, final: u8, params: []const isize, collect: []const u8) anyerror!void {
    if (final != 'u' or collect.len == 0) return;
    const stack = if (t.is_alternate) &t.keyboard_alt else &t.keyboard_normal;
    const first = if (params.len == 0) @as(isize, 0) else params[0];
    switch (collect[0]) {
        '?' => {
            var bytes: [64]u8 = undefined;
            try t.sendResponse(std.fmt.bufPrint(&bytes, "\x1b[?{d}u", .{keyboardFlags(t)}) catch unreachable);
        },
        '>' => {
            try stack.ensureTotalCapacityPrecise(t.allocator, keyboard_stack_limit);
            if (stack.items.len == keyboard_stack_limit) _ = stack.orderedRemove(0);
            stack.appendAssumeCapacity(first);
        },
        '<' => {
            const n: usize = @intCast(@max(1, if (params.len == 0) 1 else first));
            stack.shrinkRetainingCapacity(stack.items.len - @min(n, stack.items.len));
        },
        '=' => {
            const mode = if (params.len > 1) params[1] else 1;
            const current = keyboardFlags(t);
            const updated = switch (mode) {
                2 => current | first,
                3 => current & ~first,
                else => first,
            };
            if (stack.items.len == 0) try stack.append(t.allocator, updated) else stack.items[stack.items.len - 1] = updated;
        },
        else => {},
    }
}
