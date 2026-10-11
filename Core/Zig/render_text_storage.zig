//! GPU-backed glyph atlas storage, allocation policy and upload bytes owned by Zig.
const std = @import("std");
const c = @cImport({
    @cInclude("cmdy_render_text.h");
    @cInclude("platform_gpu.h");
});
const a = std.heap.c_allocator;
const Object = ?*const anyopaque;
const Region = c.CmdyRenderAtlasRegion;
const FreeRect = struct { x: isize, y: isize, w: isize, h: isize };
const Page = struct { generation: u64 = 1, last_touch: u64 = 0, free: std.ArrayList(FreeRect) = .empty };
pub const Atlas = struct {
    size: isize,
    bpp: usize,
    texture: Object,
    pages: []Page,
    preferred: usize = 0,
    clock: u64 = 0,
    evicted: isize = -1,
    frozen: bool,
    cursor_x: isize = 0,
    cursor_y: isize = 0,
    row_height: isize = 0,
    pub fn deinit(self: *Atlas) void {
        for (self.pages) |*page| page.free.deinit(a);
        a.free(self.pages);
        c.cmdy_gpu_apple_release(self.texture);
    }
    fn touch(self: *Atlas, page: usize) void {
        self.clock +%= 1;
        self.pages[page].last_touch = self.clock;
    }
    fn zero(self: *Atlas, page: usize, x: isize, y: isize, w: isize, h: isize) void {
        if (w <= 0 or h <= 0) return;
        const rows: usize = @intCast(@min(32, h));
        const row_bytes: usize = @as(usize, @intCast(w)) * self.bpp;
        const bytes = a.alloc(u8, row_bytes * rows) catch return;
        defer a.free(bytes);
        @memset(bytes, 0);
        var row: isize = 0;
        while (row < h) {
            const count = @min(@as(isize, @intCast(rows)), h - row);
            c.cmdy_gpu_apple_texture_write(self.texture, @intCast(x), @intCast(y + row), @intCast(w), @intCast(count), page, bytes.ptr, row_bytes);
            row += count;
        }
    }
    fn append(self: *Atlas, page: usize, r: FreeRect) !void {
        if (r.w > 0 and r.h > 0) try self.pages[page].free.append(a, r);
    }
    fn carve(self: *Atlas, page: usize, w: isize, h: isize) !?Region {
        var selected: ?usize = null;
        var waste: isize = 0;
        for (self.pages[page].free.items, 0..) |r, i| {
            if (w > r.w or h > r.h) continue;
            const loss = r.w * r.h - w * h;
            if (selected == null or loss < waste or (loss == waste and (r.y < self.pages[page].free.items[selected.?].y or (r.y == self.pages[page].free.items[selected.?].y and r.x < self.pages[page].free.items[selected.?].x)))) {
                selected = i;
                waste = loss;
            }
        }
        const index = selected orelse return null;
        try self.pages[page].free.ensureUnusedCapacity(a, 1);
        const r = self.pages[page].free.orderedRemove(index);
        const rw = r.w - w;
        const rh = r.h - h;
        if (rw > rh) {
            try self.append(page, .{ .x = r.x + w, .y = r.y, .w = rw, .h = r.h });
            try self.append(page, .{ .x = r.x, .y = r.y + h, .w = w, .h = rh });
        } else {
            try self.append(page, .{ .x = r.x + w, .y = r.y, .w = rw, .h = h });
            try self.append(page, .{ .x = r.x, .y = r.y + h, .w = r.w, .h = rh });
        }
        self.touch(page);
        return .{ .page = @intCast(page), .generation = self.pages[page].generation, .x = r.x, .y = r.y, .width = w, .height = h };
    }
    pub fn region(self: *Atlas, w: isize, h: isize) ?Region {
        if (w <= 0 or h <= 0 or w > self.size or h > self.size) return null;
        if (self.frozen) {
            if (self.cursor_x + w > self.size) {
                self.cursor_y += self.row_height;
                self.cursor_x = 0;
                self.row_height = 0;
            }
            if (self.cursor_y + h > self.size) return null;
            const r = Region{ .page = 0, .generation = 1, .x = self.cursor_x, .y = self.cursor_y, .width = w, .height = h };
            self.cursor_x += w;
            self.row_height = @max(self.row_height, h);
            return r;
        }
        self.evicted = -1;
        for (0..self.pages.len) |offset| {
            const page = (self.preferred + offset) % self.pages.len;
            if (self.carve(page, w, h) catch return null) |r| {
                self.preferred = page;
                return r;
            }
        }
        var victim: usize = 0;
        for (self.pages, 0..) |page, i| if (page.last_touch < self.pages[victim].last_touch) {
            victim = i;
        };
        self.zero(victim, 0, 0, self.size, self.size);
        self.pages[victim].free.clearRetainingCapacity();
        self.pages[victim].free.append(a, .{ .x = 0, .y = 0, .w = self.size, .h = self.size }) catch return null;
        self.pages[victim].generation +%= 1;
        self.evicted = @intCast(victim);
        self.preferred = victim;
        return self.carve(victim, w, h) catch null;
    }
    pub fn write(self: *Atlas, r: Region, bytes: []const u8, w: isize, h: isize, padding: isize) void {
        if (r.page < 0 or r.page >= self.pages.len or self.pages[@intCast(r.page)].generation != r.generation or w < 0 or h < 0 or padding < 0 or r.x < 0 or r.y < 0 or r.width <= 0 or r.height <= 0 or r.x > self.size - r.width or r.y > self.size - r.height) return;
        self.zero(@intCast(r.page), r.x, r.y, r.width, r.height);
        const pw = std.math.mul(isize, padding, 2) catch return;
        const cw = @min(w, @max(0, r.width - pw));
        const ch = @min(h, @max(0, r.height - pw));
        if (cw <= 0 or ch <= 0) return;
        const row_bytes = std.math.mul(usize, @intCast(w), self.bpp) catch return;
        const total = std.math.mul(usize, @intCast(h), row_bytes) catch return;
        if (bytes.len < total) return;
        c.cmdy_gpu_apple_texture_write(self.texture, @intCast(r.x + padding), @intCast(r.y + padding), @intCast(cw), @intCast(ch), @intCast(r.page), bytes.ptr, row_bytes);
        self.touch(@intCast(r.page));
    }
    pub fn insert(self: *Atlas, bitmap: *const c.CmdyRenderGlyphBitmapView, padding: isize) ?Region {
        if (bitmap.is_color != 0 or bitmap.width <= 0 or bitmap.height <= 0) return null;
        const total = std.math.mul(usize, @intCast(bitmap.width), @intCast(bitmap.height)) catch return null;
        if (bitmap.byte_count < total * 4) return null;
        const inset = @max(0, padding);
        const double = std.math.mul(isize, inset, 2) catch return null;
        const w = std.math.add(isize, bitmap.width, double) catch return null;
        const h = std.math.add(isize, bitmap.height, double) catch return null;
        const r = self.region(w, h) orelse return null;
        const count = std.math.mul(usize, @intCast(w), @intCast(h)) catch return null;
        const bytes = a.alloc(u8, count) catch return null;
        defer a.free(bytes);
        @memset(bytes, 0);
        var y: isize = 0;
        while (y < bitmap.height) : (y += 1) {
            const source_y = bitmap.height - 1 - y;
            var x: isize = 0;
            while (x < bitmap.width) : (x += 1) bytes[@intCast((y + inset) * w + x + inset)] = bitmap.bytes[@intCast((source_y * bitmap.width + x) * 4 + 3)];
        }
        c.cmdy_gpu_apple_texture_write(self.texture, @intCast(r.x), @intCast(r.y), @intCast(w), @intCast(h), 0, bytes.ptr, @intCast(w));
        return r;
    }
};
pub fn create(device: Object, size: isize, pages: isize, bgra: bool, frozen: bool) ?*Atlas {
    if (size <= 0 or pages <= 0 or size > 32768 or pages > 4096) return null;
    const texture = c.cmdy_gpu_apple_texture(device, @intCast(size), @intCast(size), if (frozen) 0 else @intCast(pages), if (bgra) 80 else 10, 0, 0) orelse return null;
    const states = a.alloc(Page, @intCast(pages)) catch {
        c.cmdy_gpu_apple_release(texture);
        return null;
    };
    for (states) |*page| page.* = .{};
    const result = a.create(Atlas) catch {
        a.free(states);
        c.cmdy_gpu_apple_release(texture);
        return null;
    };
    result.* = .{ .size = size, .bpp = if (bgra) 4 else 1, .texture = texture, .pages = states, .frozen = frozen };
    for (states) |*page| page.free.append(a, .{ .x = 0, .y = 0, .w = size, .h = size }) catch {
        result.deinit();
        a.destroy(result);
        return null;
    };
    if (frozen) result.zero(0, 0, 0, size, size);
    return result;
}
export fn cmdy_render_atlas_create(device: Object, size: isize, pages: isize, bgra: u8, frozen: u8) ?*Atlas {
    return create(device, size, pages, bgra != 0, frozen != 0);
}
export fn cmdy_render_atlas_free(self: ?*Atlas) void {
    if (self) |v| {
        v.deinit();
        a.destroy(v);
    }
}
export fn cmdy_render_atlas_texture(self: ?*const Atlas) Object {
    return if (self) |v| v.texture else null;
}
export fn cmdy_render_atlas_size(self: ?*const Atlas) isize {
    return if (self) |v| v.size else 0;
}
export fn cmdy_render_atlas_evicted_page(self: ?*const Atlas) isize {
    return if (self) |v| v.evicted else -1;
}
export fn cmdy_render_atlas_generation(self: ?*const Atlas, page: isize) u64 {
    const v = self orelse return 0;
    if (page < 0 or page >= v.pages.len) return 0;
    return v.pages[@intCast(page)].generation;
}
export fn cmdy_render_atlas_touch(self: ?*Atlas, page: isize) void {
    const v = self orelse return;
    if (page < 0 or page >= v.pages.len) return;
    v.touch(@intCast(page));
}
export fn cmdy_render_atlas_region(self: ?*Atlas, w: isize, h: isize, out: ?*Region) u8 {
    const v = self orelse return 0;
    const o = out orelse return 0;
    o.* = v.region(w, h) orelse return 0;
    return 1;
}
export fn cmdy_render_atlas_write(self: ?*Atlas, r: ?*const Region, bytes: [*c]const u8, count: usize, w: isize, h: isize, padding: isize) void {
    const v = self orelse return;
    const region = r orelse return;
    if (count > 0 and bytes == null) return;
    v.write(region.*, bytes[0..count], w, h, padding);
}
export fn cmdy_render_atlas_insert_glyph(self: ?*Atlas, bitmap: ?*const c.CmdyRenderGlyphBitmapView, padding: isize, out: ?*Region) u8 {
    const v = self orelse return 0;
    const b = bitmap orelse return 0;
    const o = out orelse return 0;
    o.* = v.insert(b, padding) orelse return 0;
    return 1;
}
const Arena = struct { buffer: Object = null, capacity: usize = 0, offset: usize = 0 };
const Ring = struct {
    device: Object,
    arenas: []Arena,
    active: usize = 0,
    started: bool = false,
    minimum: usize,
    alignment: usize,
    allocations: usize = 0,
    fn begin(self: *Ring) void {
        if (self.started) self.active = (self.active + 1) % self.arenas.len;
        self.started = true;
        self.arenas[self.active].offset = 0;
    }
    fn aligned(self: *Ring, value: usize) ?usize {
        const remainder = value % self.alignment;
        return std.math.add(usize, value, if (remainder == 0) 0 else self.alignment - remainder) catch null;
    }
    fn write(self: *Ring, bytes: ?*const anyopaque, count: usize, out: *usize) Object {
        if (!self.started) self.begin();
        const arena = &self.arenas[self.active];
        const offset = self.aligned(arena.offset) orelse return null;
        const required = std.math.add(usize, offset, count) catch return null;
        if (arena.buffer == null or required > arena.capacity) {
            var capacity = self.minimum;
            while (capacity < required and capacity <= std.math.maxInt(usize) / 2) capacity *= 2;
            capacity = @max(capacity, required);
            const buffer = c.cmdy_gpu_apple_buffer(self.device, capacity) orelse return null;
            c.cmdy_gpu_apple_release(arena.buffer);
            arena.buffer = buffer;
            arena.capacity = capacity;
            arena.offset = 0;
            self.allocations += 1;
        }
        const start = self.aligned(arena.offset) orelse return null;
        if (count > 0) c.cmdy_gpu_apple_buffer_write(arena.buffer, start, bytes, count);
        arena.offset = start + count;
        out.* = start;
        return arena.buffer;
    }
};
export fn cmdy_render_buffer_ring_create(device: Object, frames: usize, minimum: usize, alignment: usize) ?*Ring {
    const result = a.create(Ring) catch return null;
    const arenas = a.alloc(Arena, @max(1, frames)) catch {
        a.destroy(result);
        return null;
    };
    for (arenas) |*arena| arena.* = .{};
    result.* = .{ .device = c.cmdy_gpu_apple_retain(device), .arenas = arenas, .minimum = @max(256, minimum), .alignment = @max(256, alignment) };
    return result;
}
export fn cmdy_render_buffer_ring_free(self: ?*Ring) void {
    if (self) |v| {
        for (v.arenas) |arena| c.cmdy_gpu_apple_release(arena.buffer);
        a.free(v.arenas);
        c.cmdy_gpu_apple_release(v.device);
        a.destroy(v);
    }
}
export fn cmdy_render_buffer_ring_begin(self: ?*Ring) void {
    if (self) |v| v.begin();
}
export fn cmdy_render_buffer_ring_write(self: ?*Ring, bytes: ?*const anyopaque, count: usize, offset: ?*usize) Object {
    const v = self orelse return null;
    return v.write(bytes, count, offset orelse return null);
}
export fn cmdy_render_buffer_ring_allocations(self: ?*const Ring) usize {
    return if (self) |v| v.allocations else 0;
}
