//! Image ownership and host value bridge; parsing and stores remain native.
const std = @import("std");
const graphics = @import("graphics.zig");
const sixel = @import("sixel.zig");
const placeholder = @import("placeholder.zig");
const a = std.heap.c_allocator;
const Payload = graphics.Payload;
const LineImage = graphics.LineImage;
const StoredImage = graphics.Image;
const Store = graphics.KittyGraphicsStore;
const LifetimeCallback = *const fn (?*anyopaque, u8) callconv(.c) void;
const OwnerRelease = *const fn (?*anyopaque) callconv(.c) void;

fn SwiftBridge(comptime T: type) type {
    return struct {
        context: *anyopaque,
        callback: LifetimeCallback,
        native_owned: bool = true,
        const Self = @This();
        fn retained(raw_context: *anyopaque, value: *T) void {
            const bridge: *Self = @ptrCast(@alignCast(raw_context));
            if (bridge.native_owned) return;
            bridge.native_owned = true;
            bridge.callback(bridge.context, 1);
            _ = value.refs.fetchSub(1, .monotonic);
        }
        fn finalRelease(raw_context: *anyopaque, value: *T) bool {
            const bridge: *Self = @ptrCast(@alignCast(raw_context));
            std.debug.assert(bridge.native_owned);
            bridge.native_owned = false;
            value.refs.store(1, .release);
            const context = bridge.context;
            const callback = bridge.callback;
            callback(context, 0);
            // Callback may have freed both bridge and native object.
            return true;
        }
        fn contextOf(value: ?*const T) ?*anyopaque {
            const observer = (value orelse return null).lifetime_observer orelse return null;
            const bridge: *Self = @ptrCast(@alignCast(observer.context));
            return bridge.context;
        }
        fn associate(value: ?*T, context: ?*anyopaque, callback: ?LifetimeCallback) i32 {
            const object = value orelse return -1;
            if (object.lifetime_observer != null or context == null or callback == null) return -1;
            const bridge = object.payload.allocator.create(Self) catch return -2;
            bridge.* = .{ .context = context.?, .callback = callback.? };
            object.lifetime_observer = .{ .context = bridge, .retained = retained, .final_release = finalRelease };
            return 0;
        }
        fn disassociate(value: ?*T, context: ?*anyopaque) i32 {
            const object = value orelse return -1;
            const observer = object.lifetime_observer orelse return -1;
            const bridge: *Self = @ptrCast(@alignCast(observer.context));
            if (context != bridge.context or bridge.native_owned) return -1;
            object.lifetime_observer = null;
            object.payload.allocator.destroy(bridge);
            return 0;
        }
    };
}

pub const PayloadInfo = extern struct {
    bytes: ?[*]const u8 = null,
    count: usize = 0,
    width: isize = 0,
    height: isize = 0,
    format: u8 = 0,
};
pub const ImageInfo = extern struct {
    identity_high: u64 = 0,
    identity_low: u64 = 0,
    pixel_width: isize = 0,
    pixel_height: isize = 0,
    col: isize = 0,
    z_index: isize = 0,
    offset_x: isize = 0,
    offset_y: isize = 0,
    image_id: u32 = 0,
    placement_id: u32 = 0,
    is_kitty: u8 = 0,
    has_image_id: u8 = 0,
    has_placement_id: u8 = 0,
};
pub const StoredImageInfo = extern struct {
    pixel_width: isize = 0,
    pixel_height: isize = 0,
    id: u32 = 0,
    number: u32 = 0,
    has_number: u8 = 0,
};
pub const Placement = extern struct {
    image_id: u32 = 0,
    placement_id: u32 = 0,
    col: isize = 0,
    row: isize = 0,
    cols: isize = 0,
    rows: isize = 0,
    z_index: isize = 0,
    offset_x: isize = 0,
    offset_y: isize = 0,
    is_virtual: u8 = 0,
    is_alternate_buffer: u8 = 0,

    fn native(self: Placement) graphics.Placement {
        return .{ .image_id = self.image_id, .placement_id = self.placement_id,
            .col = self.col, .row = self.row, .cols = self.cols, .rows = self.rows,
            .z_index = self.z_index, .offset_x = self.offset_x, .offset_y = self.offset_y,
            .is_virtual = self.is_virtual != 0, .is_alternate_buffer = self.is_alternate_buffer != 0 };
    }
    fn from(value: graphics.Placement) Placement {
        return .{ .image_id = value.image_id, .placement_id = value.placement_id,
            .col = value.col, .row = value.row, .cols = value.cols, .rows = value.rows,
            .z_index = value.z_index, .offset_x = value.offset_x, .offset_y = value.offset_y,
            .is_virtual = @intFromBool(value.is_virtual), .is_alternate_buffer = @intFromBool(value.is_alternate_buffer) };
    }
};

/// On success consumes one host owner retain. Invalid input/failure consumes none.
export fn cmdy_zig_payload_create_host(format: u8, bytes: ?[*]const u8, count: usize,
    width: isize, height: isize, owner: ?*anyopaque, release_owner: ?OwnerRelease) ?*Payload {
    if (format > 1 or (count != 0 and bytes == null) or (owner != null and release_owner == null)) return null;
    const payload = Payload.createHostCopy(a, @enumFromInt(format), if (count == 0) &.{} else bytes.?[0..count], width, height) catch return null;
    payload.host_owner = owner;
    payload.host_release = release_owner;
    return payload;
}
export fn cmdy_zig_payload_retain(payload: ?*Payload) ?*Payload { return if (payload) |p| p.retain() else null; }
export fn cmdy_zig_payload_release(payload: ?*Payload) void { if (payload) |p| p.release(); }
export fn cmdy_zig_payload_info(payload: ?*const Payload, out: ?*PayloadInfo) i32 {
    const p = payload orelse return -1;
    (out orelse return -1).* = .{ .bytes = if (p.bytes.len == 0) null else p.bytes.ptr,
        .count = p.bytes.len, .width = p.source_width, .height = p.source_height, .format = @intFromEnum(p.format) };
    return 0;
}
export fn cmdy_zig_image_create_host(payload: ?*Payload, width: isize, height: isize, col: isize) ?*LineImage {
    const image = LineImage.init(payload orelse return null, col) catch return null;
    image.pixel_width = width;
    image.pixel_height = height;
    return image;
}
export fn cmdy_zig_image_retain(image: ?*LineImage) ?*LineImage { return if (image) |i| i.clone() else null; }
export fn cmdy_zig_image_release(image: ?*LineImage) void { if (image) |i| i.deinit(); }
export fn cmdy_zig_image_snapshot(image: ?*const LineImage) ?*LineImage { return (image orelse return null).snapshot() catch null; }
/// Borrowed, valid while image is retained.
export fn cmdy_zig_image_payload(image: ?*const LineImage) ?*Payload { return (image orelse return null).payload; }
export fn cmdy_zig_image_info(image: ?*const LineImage, out: ?*ImageInfo) i32 {
    const i = image orelse return -1;
    (out orelse return -1).* = .{ .identity_high = std.mem.readInt(u64, i.render_uuid[0..8], .big),
        .identity_low = std.mem.readInt(u64, i.render_uuid[8..16], .big),
        .pixel_width = i.pixel_width, .pixel_height = i.pixel_height, .col = i.col,
        .z_index = i.z_index, .offset_x = i.offset_x, .offset_y = i.offset_y,
        .image_id = i.image_id orelse 0, .placement_id = i.placement_id orelse 0,
        .is_kitty = @intFromBool(i.is_kitty), .has_image_id = @intFromBool(i.image_id != null),
        .has_placement_id = @intFromBool(i.placement_id != null) };
    return 0;
}
/// Only mutable placement fields change. Payload, dimensions and identity stay fixed.
export fn cmdy_zig_image_set_info(image: ?*LineImage, input: ?*const ImageInfo) i32 {
    const i = image orelse return -1;
    const v = input orelse return -1;
    if (v.is_kitty > 1 or v.has_image_id > 1 or v.has_placement_id > 1) return -1;
    i.col = v.col; i.z_index = v.z_index; i.offset_x = v.offset_x; i.offset_y = v.offset_y;
    i.is_kitty = v.is_kitty != 0;
    i.image_id = if (v.has_image_id != 0) v.image_id else null;
    i.placement_id = if (v.has_placement_id != 0) v.placement_id else null;
    return 0;
}
export fn cmdy_zig_image_swift_context(image: ?*const LineImage) ?*anyopaque { return SwiftBridge(LineImage).contextOf(image); }
export fn cmdy_zig_image_associate(image: ?*LineImage, context: ?*anyopaque, callback: ?LifetimeCallback) i32 { return SwiftBridge(LineImage).associate(image, context, callback); }
export fn cmdy_zig_image_disassociate(image: ?*LineImage, context: ?*anyopaque) i32 { return SwiftBridge(LineImage).disassociate(image, context); }

export fn cmdy_zig_stored_image_create(payload: ?*Payload, id: u32, number: u32, has_number: u8, width: isize, height: isize) ?*StoredImage {
    if (has_number > 1) return null;
    const image = StoredImage.create(payload orelse return null, id, if (has_number != 0) number else null) catch return null;
    image.pixel_width = width; image.pixel_height = height;
    return image;
}
export fn cmdy_zig_stored_image_retain(image: ?*StoredImage) ?*StoredImage { return if (image) |i| i.clone() else null; }
export fn cmdy_zig_stored_image_release(image: ?*StoredImage) void { if (image) |i| i.deinit(); }
export fn cmdy_zig_stored_image_payload(image: ?*const StoredImage) ?*Payload { return (image orelse return null).payload; }
export fn cmdy_zig_stored_image_info(image: ?*const StoredImage, out: ?*StoredImageInfo) i32 {
    const i = image orelse return -1;
    (out orelse return -1).* = .{ .id = i.id, .number = i.number orelse 0,
        .has_number = @intFromBool(i.number != null), .pixel_width = i.pixel_width, .pixel_height = i.pixel_height };
    return 0;
}
export fn cmdy_zig_stored_image_swift_context(image: ?*const StoredImage) ?*anyopaque { return SwiftBridge(StoredImage).contextOf(image); }
export fn cmdy_zig_stored_image_associate(image: ?*StoredImage, context: ?*anyopaque, callback: ?LifetimeCallback) i32 { return SwiftBridge(StoredImage).associate(image, context, callback); }
export fn cmdy_zig_stored_image_disassociate(image: ?*StoredImage, context: ?*anyopaque) i32 { return SwiftBridge(StoredImage).disassociate(image, context); }

export fn cmdy_zig_graphics_create() ?*Store {
    const store = a.create(Store) catch return null; store.* = .init(a); return store;
}
export fn cmdy_zig_graphics_free(store: ?*Store) void { if (store) |s| { s.deinit(); a.destroy(s); } }
export fn cmdy_zig_graphics_get(store: ?*const Store, field: u32) usize {
    const s = store orelse return 0;
    return switch (field) { 0 => s.next_image_id, 1 => s.next_placement_id, 2 => s.payload_bytes,
        3 => s.images_by_id.count(), 4 => s.placements_by_key.count(), else => 0 };
}
export fn cmdy_zig_graphics_image_at(store: ?*const Store, index: usize) ?*StoredImage {
    const s = store orelse return null;
    return if (index < s.images_by_id.count()) s.images_by_id.values()[index].clone() else null;
}
export fn cmdy_zig_graphics_image(store: ?*const Store, id: u32) ?*StoredImage {
    return ((store orelse return null).images_by_id.get(id) orelse return null).clone();
}
export fn cmdy_zig_graphics_newest(store: ?*const Store, number: u32) ?*StoredImage {
    return ((store orelse return null).newestImage(number) orelse return null).clone();
}
export fn cmdy_zig_graphics_placement_at(store: ?*const Store, index: usize, out: ?*Placement) i32 {
    const s = store orelse return -1;
    if (index >= s.placements_by_key.count()) return 0;
    (out orelse return -1).* = .from(s.placements_by_key.values()[index]); return 1;
}
export fn cmdy_zig_graphics_store(store: ?*Store, image: ?*StoredImage) i32 {
    (store orelse return -1).store(image orelse return -1) catch |err| return if (err == error.OutOfMemory) -2 else 0;
    return 1;
}
export fn cmdy_zig_graphics_place(store: ?*Store, placement: ?*const Placement) i32 {
    const p = placement orelse return -1;
    if (p.is_virtual > 1 or p.is_alternate_buffer > 1) return -1;
    _ = (store orelse return -1).place(p.native()) catch |err| return if (err == error.OutOfMemory) -2 else 0;
    return 1;
}
export fn cmdy_zig_graphics_delete_image(store: ?*Store, id: u32) void { if (store) |s| s.deleteImage(id); }
export fn cmdy_zig_graphics_delete_placements(store: ?*Store, id: u32) void { if (store) |s| s.deletePlacements(id); }
export fn cmdy_zig_graphics_delete_all(store: ?*Store) void { if (store) |s| s.deleteAll(); }
export fn cmdy_zig_graphics_has_placement(store: ?*const Store, id: u32) u8 { return if (store) |s| @intFromBool(s.hasPlacement(id)) else 0; }
export fn cmdy_zig_graphics_remove_placement(store: ?*Store, image_id: u32, placement_id: u32, out: ?*Placement) i32 {
    const s = store orelse return -1;
    const index = s.placements_by_key.getIndex(graphics.placementKey(image_id, placement_id)) orelse return 0;
    const value = s.placements_by_key.values()[index];
    s.placements_by_key.swapRemoveAt(index);
    if (out) |o| o.* = .from(value);
    return 1;
}

export fn cmdy_zig_sixel_create() ?*sixel.SixelDecoder {
    const decoder = a.create(sixel.SixelDecoder) catch return null; decoder.* = .init(a); return decoder;
}
export fn cmdy_zig_sixel_free(decoder: ?*sixel.SixelDecoder) void { if (decoder) |d| { d.deinit(); a.destroy(d); } }
export fn cmdy_zig_sixel_feed(decoder: ?*sixel.SixelDecoder, bytes: ?[*]const u8, count: usize) i32 {
    if (count != 0 and bytes == null) return -1;
    (decoder orelse return -1).feed(if (count == 0) &.{} else bytes.?[0..count]) catch return -2; return 0;
}
export fn cmdy_zig_sixel_finish(decoder: ?*sixel.SixelDecoder) ?*Payload {
    var image = ((decoder orelse return null).finish() catch return null) orelse return null;
    // Sixel's public decoder has its own canvas bounds. Terminal attachment
    // separately validates inline-image bounds; do not narrow this public API.
    const payload = a.create(Payload) catch { image.deinit(); return null; };
    payload.* = .{ .allocator = a, .format = .rgba, .bytes = image.bytes,
        .width = image.width, .height = image.height, .source_width = image.width, .source_height = image.height };
    return payload;
}
export fn cmdy_zig_sixel_hls(h: isize, l: isize, s: isize, out: ?[*]u8) void {
    const result = out orelse return;
    const color = sixel.hlsToRGBSigned(h, l, s);
    result[0] = color.r; result[1] = color.g; result[2] = color.b;
}
export fn cmdy_zig_png_dimensions(bytes: ?[*]const u8, count: usize, width: ?*isize, height: ?*isize) u8 {
    if (count != 0 and bytes == null) return 0;
    const d = graphics.pngDimensions(if (count == 0) &.{} else bytes.?[0..count]) orelse return 0;
    (width orelse return 0).* = d.width; (height orelse return 0).* = d.height; return 1;
}

export fn cmdy_zig_zlib_inflated(bytes: ?[*]const u8, count: usize, limit: isize) ?*Payload {
    if (limit <= 0 or (count != 0 and bytes == null)) return null;
    const decoded = graphics.zlibInflated(a, if (count == 0) &.{} else bytes.?[0..count], @intCast(limit)) catch return null;
    const payload = a.create(Payload) catch { a.free(decoded); return null; };
    // Opaque owned byte result; no image admission or display is implied.
    payload.* = .{ .allocator = a, .format = .rgba, .bytes = decoded, .width = 0, .height = 0,
        .source_width = 0, .source_height = 0 };
    return payload;
}

export fn cmdy_zig_placeholder_decode(state: ?*placeholder.State, scalar: u32,
    foreground: u32, underline: u32, has_underline: u8, marks: ?[*]const u32, count: usize,
    row: isize, column: isize, out: ?*placeholder.Value) u8 {
    const s = state orelse return 0;
    if (has_underline > 1 or count > 3 or (count != 0 and marks == null) or out == null) {
        s.reset(); return 0;
    }
    const value = s.decode(scalar, foreground, if (has_underline != 0) underline else null,
        if (count == 0) &.{} else marks.?[0..count], row, column) orelse return 0;
    out.?.* = value; return 1;
}
