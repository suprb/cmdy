//! Streaming DCS q sixel decoder. Pure bounded math; no image frameworks.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Color = struct { r: u8, g: u8, b: u8 };
pub const max_colored_pixels = 1_000_000;
pub const max_canvas_pixels = 4_000_000;
pub const max_width = 10_000;
pub const max_bands = 4_000;
pub const max_palette_entries = 4_096;

pub const Image = struct {
    allocator: Allocator,
    bytes: []u8,
    width: u32,
    height: u32,
    pub fn deinit(self: *Image) void { self.allocator.free(self.bytes); self.* = undefined; }
};

pub const SixelDecoder = struct {
    allocator: Allocator,
    palette: [max_palette_entries]?Color = @splat(null),
    current_color: u32 = 0,
    x: u32 = 0,
    band: u32 = 0,
    max_x: u32 = 0,
    max_y: isize = -1,
    pixels: std.AutoHashMapUnmanaged(u32, Color) = .empty,
    repeat_count: ?u32 = null,
    pending_numbers: [5]u32 = @splat(0),
    pending_count: usize = 0,
    collecting_number: bool = false,
    number_value: u32 = 0,
    is_repeat: bool = false,
    mode: enum { data, color_intro, raster_intro } = .data,
    rejected: bool = false,

    pub fn init(a: Allocator) SixelDecoder {
        var self: SixelDecoder = .{ .allocator = a };
        const defaults = [_]Color{
            .{ .r = 0, .g = 0, .b = 0 }, .{ .r = 51, .g = 51, .b = 204 },
            .{ .r = 204, .g = 33, .b = 33 }, .{ .r = 51, .g = 204, .b = 51 },
            .{ .r = 204, .g = 51, .b = 204 }, .{ .r = 51, .g = 204, .b = 204 },
            .{ .r = 204, .g = 204, .b = 51 }, .{ .r = 120, .g = 120, .b = 120 },
            .{ .r = 69, .g = 69, .b = 69 }, .{ .r = 87, .g = 87, .b = 153 },
            .{ .r = 153, .g = 69, .b = 69 }, .{ .r = 87, .g = 153, .b = 87 },
            .{ .r = 153, .g = 87, .b = 153 }, .{ .r = 87, .g = 153, .b = 153 },
            .{ .r = 153, .g = 153, .b = 87 }, .{ .r = 204, .g = 204, .b = 204 },
        };
        for (defaults, 0..) |color, i| self.palette[i] = color;
        return self;
    }

    pub fn deinit(self: *SixelDecoder) void {
        self.pixels.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *SixelDecoder, bytes: []const u8) Allocator.Error!void {
        errdefer self.reject();
        for (bytes) |byte| try self.step(byte);
    }

    fn step(self: *SixelDecoder, byte: u8) Allocator.Error!void {
        switch (byte) {
            '#' => { self.flushNumber(); self.applyPending(); self.mode = .color_intro; self.pending_count = 0; },
            '"' => { self.flushNumber(); self.applyPending(); self.mode = .raster_intro; self.pending_count = 0; },
            '!' => {
                self.flushNumber(); self.applyPending(); self.mode = .data;
                self.collecting_number = true; self.number_value = 0; self.is_repeat = true;
            },
            '$' => { self.flushNumber(); self.applyPending(); self.x = 0; },
            '-' => { self.flushNumber(); self.applyPending(); self.x = 0; self.band = @min(self.band + 1, max_bands - 1); },
            '0'...'9' => {
                if (!self.collecting_number) { self.collecting_number = true; self.number_value = 0; }
                self.number_value = @intCast(@min(@as(u64, 0x7fffffff), @as(u64, self.number_value) * 10 + byte - '0'));
            },
            ';' => self.flushNumber(),
            0x3f...0x7e => { self.flushNumber(); self.applyPending(); try self.drawSixel(byte - 0x3f); },
            else => {},
        }
    }

    fn flushNumber(self: *SixelDecoder) void {
        if (!self.collecting_number) return;
        if (self.is_repeat) {
            self.repeat_count = self.number_value;
            self.is_repeat = false;
        } else if (self.pending_count < self.pending_numbers.len) {
            self.pending_numbers[self.pending_count] = self.number_value;
            self.pending_count += 1;
        }
        self.collecting_number = false;
        self.number_value = 0;
    }

    fn applyPending(self: *SixelDecoder) void {
        switch (self.mode) {
            .color_intro => {
                if (self.pending_count == 0) return;
                const index = self.pending_numbers[0];
                if (index < max_palette_entries and self.pending_count >= 5) {
                    const p = self.pending_numbers;
                    if (p[1] == 2) {
                        self.palette[index] = .{ .r = percent(p[2]), .g = percent(p[3]), .b = percent(p[4]) };
                    } else if (p[1] == 1) {
                        self.palette[index] = hlsToRGB(p[2], p[3], p[4]);
                    }
                }
                self.current_color = index;
                self.pending_count = 0;
                self.mode = .data;
            },
            .raster_intro => { self.pending_count = 0; self.mode = .data; },
            .data => {},
        }
    }

    fn drawSixel(self: *SixelDecoder, bits: u8) Allocator.Error!void {
        const repeat = self.repeat_count orelse 1;
        self.repeat_count = null;
        if (self.rejected) return;
        const color = if (self.current_color < max_palette_entries)
            self.palette[self.current_color] orelse Color{ .r = 255, .g = 255, .b = 255 }
        else Color{ .r = 255, .g = 255, .b = 255 };
        const count = @min(@max(1, repeat), max_width - self.x);
        for (0..count) |_| {
            const proposed_width = @max(self.max_x, self.x + 1);
            if (self.max_y >= 0 and !canvasFits(proposed_width, @intCast(self.max_y + 1))) { self.reject(); return; }
            for (0..6) |bit| {
                if (bits & (@as(u8, 1) << @intCast(bit)) == 0) continue;
                const y: u32 = self.band * 6 + @as(u32, @intCast(bit));
                if (!canvasFits(proposed_width, @intCast(@max(self.max_y, y) + 1))) { self.reject(); return; }
                const key = y * max_width + self.x;
                if (!self.pixels.contains(key) and self.pixels.count() >= max_colored_pixels) { self.reject(); return; }
                try self.pixels.put(self.allocator, key, color);
                self.max_y = @max(self.max_y, y);
            }
            self.x += 1;
            self.max_x = proposed_width;
        }
    }

    /// Every successful result owns a distinct RGBA buffer, including repeated
    /// finish calls. Transparent untouched pixels are initialized to zero.
    pub fn finish(self: *SixelDecoder) Allocator.Error!?Image {
        self.flushNumber();
        self.applyPending();
        if (self.rejected or self.max_x == 0 or self.max_y < 0 or self.pixels.count() == 0) return null;
        const width = self.max_x;
        const height: u32 = @intCast(self.max_y + 1);
        if (!canvasFits(width, height)) return null;
        const rgba = try self.allocator.alloc(u8, @as(usize, width) * height * 4);
        @memset(rgba, 0);
        var it = self.pixels.iterator();
        while (it.next()) |entry| {
            const y = entry.key_ptr.* / max_width;
            const x = entry.key_ptr.* % max_width;
            if (x >= width or y >= height) continue;
            const offset = (@as(usize, y) * width + x) * 4;
            const color = entry.value_ptr.*;
            rgba[offset..][0..4].* = .{ color.r, color.g, color.b, 255 };
        }
        return .{ .allocator = self.allocator, .bytes = rgba, .width = width, .height = height };
    }

    fn reject(self: *SixelDecoder) void {
        self.rejected = true;
        self.pixels.clearAndFree(self.allocator);
    }
};

fn canvasFits(width: u32, height: u32) bool {
    return width > 0 and height > 0 and @as(u64, width) * height <= max_canvas_pixels;
}

fn percent(value: u32) u8 { return @intCast(@min(255, @as(u64, value) * 255 / 100)); }
fn channelByte(value: f64) u8 {
    return if (value <= 0) 0 else if (value >= 255) 255 else @intFromFloat(value);
}

pub fn hlsToRGB(h: u32, l: u32, s: u32) Color {
    return hlsToRGBSigned(h, l, s);
}

pub fn hlsToRGBSigned(h: isize, l: isize, s: isize) Color {
    const hue = @rem(@as(f64, @floatFromInt(h)) + 240, 360) / 360;
    const light = @as(f64, @floatFromInt(l)) / 100;
    const sat = @as(f64, @floatFromInt(s)) / 100;
    if (sat == 0) {
        const value = channelByte(light * 255);
        return .{ .r = value, .g = value, .b = value };
    }
    const q = if (light < 0.5) light * (1 + sat) else light + sat - light * sat;
    const p = 2 * light - q;
    return .{ .r = hlsChannel(hue + 1.0 / 3.0, p, q), .g = hlsChannel(hue, p, q), .b = hlsChannel(hue - 1.0 / 3.0, p, q) };
}

fn hlsChannel(input: f64, p: f64, q: f64) u8 {
    var t = input;
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    const value = if (t < 1.0 / 6.0) p + (q - p) * 6 * t else if (t < 0.5) q else if (t < 2.0 / 3.0) p + (q - p) * (2.0 / 3.0 - t) * 6 else p;
    return channelByte(value * 255);
}
