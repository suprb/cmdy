//! Engine-owned image bytes and pure Kitty/iTerm2 protocol bookkeeping.
//! This module never imports line/buffer or a platform image/clipboard API.
const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const Error = error{ OutOfMemory, InvalidInput, TooLarge, NoSpace, Missing, IdentityExhausted };

pub const max_encoded_bytes = 96 * 1024 * 1024;
pub const max_payload_bytes = 128 * 1024 * 1024;
pub const max_pixels = 16 * 1024 * 1024;
pub const max_dimension = 16_384;
pub const max_cell_span = 1_024;

pub const Format = enum(u8) { rgba, png };

/// Immutable after construction. Each registry entry, line attachment and
/// detached snapshot owns its own reference; registry deletion is not eviction
/// of bytes still visible through a line or snapshot.
pub const Payload = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    format: Format,
    bytes: []const u8,
    width: u32,
    height: u32,
    /// Original dimensions for the deliberately unvalidated public host API.
    /// Validated protocol constructors keep these equal to width/height.
    source_width: isize,
    source_height: isize,
    host_owner: ?*anyopaque = null,
    host_release: ?*const fn (?*anyopaque) callconv(.c) void = null,

    pub fn createCopy(a: Allocator, format: Format, bytes: []const u8, width: u32, height: u32) Error!*Payload {
        try validatePayload(format, bytes, width, height);
        const copy = try a.dupe(u8, bytes);
        errdefer a.free(copy);
        return createOwned(a, format, copy, width, height);
    }

    /// On success consumes bytes allocated by a. On error caller still owns it.
    pub fn createOwned(a: Allocator, format: Format, bytes: []u8, width: u32, height: u32) Error!*Payload {
        try validatePayload(format, bytes, width, height);
        const value = try a.create(Payload);
        value.* = .{ .allocator = a, .format = format, .bytes = bytes, .width = width, .height = height,
            .source_width = width, .source_height = height };
        return value;
    }

    /// Public LineImage has always permitted arbitrary host-supplied payloads.
    /// PTY decoders must use createCopy/createOwned above, never this path.
    pub fn createHostCopy(a: Allocator, format: Format, bytes: []const u8, width: isize, height: isize) Allocator.Error!*Payload {
        const copy = try a.dupe(u8, bytes);
        errdefer a.free(copy);
        const value = try a.create(Payload);
        value.* = .{ .allocator = a, .format = format, .bytes = copy,
            .width = @intCast(std.math.clamp(width, 0, std.math.maxInt(u32))),
            .height = @intCast(std.math.clamp(height, 0, std.math.maxInt(u32))),
            .source_width = width, .source_height = height };
        return value;
    }

    pub fn retain(self: *Payload) *Payload {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        return self;
    }

    pub fn release(self: *Payload) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const a = self.allocator;
        const owner = self.host_owner;
        const release_owner = self.host_release;
        a.free(self.bytes);
        a.destroy(self);
        // A Data deallocator can reenter the engine. All native payload state
        // is already gone; no access to self is allowed after this callback.
        if (release_owner) |callback| callback(owner);
    }
};

var identity_mutex: std.Thread.Mutex = .{};
var next_render_identity: u128 = 1;

fn renderIdentity() Error!u128 {
    identity_mutex.lock();
    defer identity_mutex.unlock();
    if (next_render_identity == std.math.maxInt(u128)) return error.IdentityExhausted;
    const result = next_render_identity;
    next_render_identity += 1;
    return result;
}

fn renderUUID() [16]u8 {
    var bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&bytes);
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    return bytes;
}

/// A shared live attachment. Public Line.clone and Swift aliases retain this
/// same mutable object; immutable publication calls snapshot() to detach only
/// metadata while keeping payload bytes and the renderer identity stable.
pub const LineImage = struct {
    pub const LifetimeObserver = struct {
        context: *anyopaque,
        retained: *const fn (*anyopaque, *LineImage) void,
        final_release: *const fn (*anyopaque, *LineImage) bool,
    };
    refs: std.atomic.Value(usize) = .init(1),
    lifetime_observer: ?LifetimeObserver = null,
    payload: *Payload,
    render_id: u128,
    /// Public renderer UUID is random across processes, as Swift UUID() was.
    /// The internal monotonic render_id above remains the witness lookup key.
    render_uuid: [16]u8,
    pixel_width: isize,
    pixel_height: isize,
    col: isize,
    is_kitty: bool = false,
    image_id: ?u32 = null,
    placement_id: ?u32 = null,
    z_index: isize = 0,
    offset_x: isize = 0,
    offset_y: isize = 0,

    /// Borrows payload and gives the returned attachment one retained reference.
    pub fn init(payload: *Payload, col: isize) Error!*LineImage {
        const identity = try renderIdentity();
        const result = try payload.allocator.create(LineImage);
        result.* = .{ .payload = payload.retain(), .render_id = identity, .render_uuid = renderUUID(),
            .pixel_width = @intCast(payload.width), .pixel_height = @intCast(payload.height), .col = col };
        return result;
    }

    pub fn clone(self: *LineImage) *LineImage {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        if (self.lifetime_observer) |observer| observer.retained(observer.context, self);
        return self;
    }

    pub fn snapshot(self: *const LineImage) Allocator.Error!*LineImage {
        const copy = try self.payload.allocator.create(LineImage);
        copy.* = .{ .payload = self.payload.retain(), .render_id = self.render_id, .render_uuid = self.render_uuid,
            .pixel_width = self.pixel_width, .pixel_height = self.pixel_height,
            .col = self.col, .is_kitty = self.is_kitty, .image_id = self.image_id,
            .placement_id = self.placement_id, .z_index = self.z_index,
            .offset_x = self.offset_x, .offset_y = self.offset_y };
        return copy;
    }

    pub fn deinit(self: *LineImage) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.lifetime_observer) |observer| if (observer.final_release(observer.context, self)) return;
        const a = self.payload.allocator;
        const payload = self.payload;
        a.destroy(self);
        payload.release();
    }
};

pub const Dimensions = struct { width: u32, height: u32 };

pub fn validatedPixelCount(width: u32, height: u32) ?usize {
    if (width == 0 or height == 0 or width > max_dimension or height > max_dimension) return null;
    const count = std.math.mul(usize, width, height) catch return null;
    return if (count <= max_pixels) count else null;
}

/// Matches the existing engine's header-level validation. Pixel decoding and
/// CRC validation for display remain the renderer's responsibility.
pub fn pngDimensions(bytes: []const u8) ?Dimensions {
    if (bytes.len < 24 or !std.mem.eql(u8, bytes[0..8], &.{ 0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a }) or
        !std.mem.eql(u8, bytes[8..16], &.{ 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52 })) return null;
    const width = std.mem.readInt(u32, bytes[16..20], .big);
    const height = std.mem.readInt(u32, bytes[20..24], .big);
    _ = validatedPixelCount(width, height) orelse return null;
    return .{ .width = width, .height = height };
}

fn validatePayload(format: Format, bytes: []const u8, width: u32, height: u32) Error!void {
    const count = validatedPixelCount(width, height) orelse return error.InvalidInput;
    if (bytes.len > max_payload_bytes) return error.TooLarge;
    switch (format) {
        .rgba => if (bytes.len != count * 4) return error.InvalidInput,
        .png => {
            const dimensions = pngDimensions(bytes) orelse return error.InvalidInput;
            if (dimensions.width != width or dimensions.height != height) return error.InvalidInput;
        },
    }
}

pub const Image = struct {
    pub const LifetimeObserver = struct {
        context: *anyopaque,
        retained: *const fn (*anyopaque, *Image) void,
        final_release: *const fn (*anyopaque, *Image) bool,
    };
    refs: std.atomic.Value(usize) = .init(1),
    lifetime_observer: ?LifetimeObserver = null,
    id: u32,
    number: ?u32 = null,
    payload: *Payload,
    pixel_width: isize,
    pixel_height: isize,

    pub fn create(payload: *Payload, id: u32, number: ?u32) Allocator.Error!*Image {
        const value = try payload.allocator.create(Image);
        value.* = .{ .id = id, .number = number, .payload = payload.retain(),
            .pixel_width = payload.width, .pixel_height = payload.height };
        return value;
    }
    pub fn clone(self: *Image) *Image {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        if (self.lifetime_observer) |observer| observer.retained(observer.context, self);
        return self;
    }
    pub fn deinit(self: *Image) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.lifetime_observer) |observer| if (observer.final_release(observer.context, self)) return;
        const payload = self.payload;
        payload.allocator.destroy(self);
        payload.release();
    }
};

pub const Placement = struct {
    image_id: u32,
    placement_id: u32 = 0,
    col: isize,
    row: isize,
    cols: isize,
    rows: isize,
    z_index: isize = 0,
    offset_x: isize = 0,
    offset_y: isize = 0,
    is_virtual: bool = false,
    is_alternate_buffer: bool = false,

    pub fn key(self: Placement) u64 { return placementKey(self.image_id, self.placement_id); }
};

pub fn placementKey(image_id: u32, placement_id: u32) u64 {
    return (@as(u64, image_id) << 32) | placement_id;
}

pub const StoreLimits = struct {
    images: usize = 256,
    placements: usize = 4_096,
    payload_bytes: usize = max_payload_bytes,
};

pub const KittyGraphicsStore = struct {
    allocator: Allocator,
    images_by_id: std.AutoArrayHashMapUnmanaged(u32, *Image) = .empty,
    placements_by_key: std.AutoArrayHashMapUnmanaged(u64, Placement) = .empty,
    next_image_id: u32 = 1,
    next_placement_id: u32 = 1,
    payload_bytes: usize = 0,
    limits: StoreLimits = .{},

    pub fn init(a: Allocator) KittyGraphicsStore { return .{ .allocator = a }; }
    pub fn deinit(self: *KittyGraphicsStore) void {
        self.deleteAll();
        self.images_by_id.deinit(self.allocator);
        self.placements_by_key.deinit(self.allocator);
        self.* = undefined;
    }

    /// Borrows image and retains only after all fallible admission work.
    /// A failed replacement preserves both old image and old placements.
    pub fn store(self: *KittyGraphicsStore, image: *Image) Error!void {
        if (image.id == 0) return error.InvalidInput;
        const previous = self.images_by_id.get(image.id);
        const previous_cost = if (previous) |old| old.payload.bytes.len else 0;
        const base = self.payload_bytes -| previous_cost;
        const cost = image.payload.bytes.len;
        if (base > self.limits.payload_bytes or cost > self.limits.payload_bytes - base or
            (previous == null and self.images_by_id.count() >= self.limits.images)) return error.NoSpace;
        try self.images_by_id.ensureTotalCapacity(self.allocator, self.images_by_id.count() + @as(usize, if (previous == null) 1 else 0));
        const owned = image.clone();
        self.images_by_id.putAssumeCapacity(image.id, owned);
        if (previous) |old| {
            self.deletePlacements(image.id);
            // A host payload deallocator can inspect/reenter this store.
            // Publish committed accounting before releasing the old image.
            self.payload_bytes = base + cost;
            self.next_image_id = self.nextAvailableImageID(image.id);
            old.deinit();
            return;
        }
        self.payload_bytes = base + cost;
        self.next_image_id = self.nextAvailableImageID(image.id);
    }

    /// Returns the resolved placement ID (zero requests automatic allocation).
    pub fn place(self: *KittyGraphicsStore, placement: Placement) Error!u32 {
        var value = placement;
        if (value.placement_id == 0) value.placement_id = self.next_placement_id;
        const key = value.key();
        const exists = self.placements_by_key.contains(key);
        if (!exists and self.placements_by_key.count() >= self.limits.placements) return error.NoSpace;
        try self.placements_by_key.ensureTotalCapacity(self.allocator, self.placements_by_key.count() + @as(usize, if (exists) 0 else 1));
        self.placements_by_key.putAssumeCapacity(key, value);
        self.next_placement_id = self.nextAvailablePlacementID(value.placement_id);
        return value.placement_id;
    }

    pub fn deleteImage(self: *KittyGraphicsStore, id: u32) void {
        const index = self.images_by_id.getIndex(id) orelse return;
        const image = self.images_by_id.values()[index];
        self.images_by_id.swapRemoveAt(index);
        self.payload_bytes -|= image.payload.bytes.len;
        self.deletePlacements(id);
        image.deinit();
    }

    pub fn deletePlacements(self: *KittyGraphicsStore, image_id: u32) void {
        var i: usize = 0;
        while (i < self.placements_by_key.count()) {
            if (self.placements_by_key.values()[i].image_id == image_id) self.placements_by_key.swapRemoveAt(i) else i += 1;
        }
    }

    pub fn deleteAll(self: *KittyGraphicsStore) void {
        // Detach first: releasing a Swift-owned payload may recursively mutate
        // this same store. The old map remains valid through those callbacks.
        var previous = self.images_by_id;
        self.images_by_id = .empty;
        for (previous.values()) |image| image.deinit();
        previous.clearRetainingCapacity();
        if (self.images_by_id.count() == 0) {
            self.images_by_id.deinit(self.allocator);
            self.images_by_id = previous;
        } else previous.deinit(self.allocator);
        self.placements_by_key.clearRetainingCapacity();
        self.payload_bytes = 0;
        self.next_image_id = 1;
        self.next_placement_id = 1;
    }

    /// Borrowed value. Retain/clone before changing or destroying the store.
    pub fn newestImage(self: *const KittyGraphicsStore, number: u32) ?*Image {
        var newest: ?*Image = null;
        for (self.images_by_id.values()) |image| {
            if (image.number == number and (newest == null or image.id > newest.?.id)) newest = image;
        }
        return newest;
    }

    pub fn hasPlacement(self: *const KittyGraphicsStore, image_id: u32) bool {
        for (self.placements_by_key.values()) |placement| if (placement.image_id == image_id) return true;
        return false;
    }

    /// Collects before mutation, so allocation failure removes nothing.
    pub fn removePlacements(self: *KittyGraphicsStore, context: anytype, comptime predicate: fn (@TypeOf(context), Placement) bool) Allocator.Error!std.ArrayList(Placement) {
        var removed: std.ArrayList(Placement) = .empty;
        errdefer removed.deinit(self.allocator);
        for (self.placements_by_key.values()) |placement| {
            if (predicate(context, placement)) try removed.append(self.allocator, placement);
        }
        for (removed.items) |placement| _ = self.placements_by_key.swapRemove(placement.key());
        return removed;
    }

    fn nextAvailableImageID(self: *const KittyGraphicsStore, after: u32) u32 {
        var candidate = incrementID(after);
        for (0..self.images_by_id.count() + 1) |_| {
            if (!self.images_by_id.contains(candidate)) return candidate;
            candidate = incrementID(candidate);
        }
        unreachable; // Image count is bounded far below the nonzero ID space.
    }

    fn nextAvailablePlacementID(self: *const KittyGraphicsStore, after: u32) u32 {
        var candidate = incrementID(after);
        for (0..self.placements_by_key.count() + 1) |_| {
            var occupied = false;
            for (self.placements_by_key.values()) |placement| {
                if (placement.placement_id == candidate) { occupied = true; break; }
            }
            if (!occupied) return candidate;
            candidate = incrementID(candidate);
        }
        unreachable;
    }
};

fn incrementID(id: u32) u32 { return if (id == std.math.maxInt(u32)) 1 else id + 1; }

pub const KittyAction = union(enum) { transmit, transmit_and_place, place, delete, query, unsupported: u8 };
pub const KittyFormat = enum(u8) { rgb = 24, rgba = 32, png = 100 };
pub const KittyCompression = enum { none, zlib };
pub const ProtocolError = enum {
    invalid, missing, too_large, no_space,
    pub fn code(self: ProtocolError) []const u8 {
        return switch (self) { .invalid => "EINVAL", .missing => "ENOENT", .too_large => "E2BIG", .no_space => "ENOSPC" };
    }
};

pub const KittyControl = struct {
    action: KittyAction = .transmit,
    format: KittyFormat = .rgba,
    image_id: u32 = 0,
    image_number: u32 = 0,
    placement_id: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    cell_cols: u32 = 0,
    cell_rows: u32 = 0,
    source_x: u32 = 0,
    source_y: u32 = 0,
    z_index: i32 = 0,
    more: bool = false,
    quiet: u2 = 0,
    virtual_placement: bool = false,
    offset_x: u32 = 0,
    offset_y: u32 = 0,
    no_cursor_move: bool = false,
    compression: KittyCompression = .none,
    transmission: u8 = 'd',
    delete_what: u8 = 'a',
};

pub const KittyEnvelope = struct { control: KittyControl, payload: []const u8 };

pub fn decodeKittyEnvelope(bytes: []const u8) Error!KittyEnvelope {
    if (bytes.len == 0 or bytes[0] != 'G') return error.InvalidInput;
    const body = bytes[1..];
    const separator = std.mem.indexOfScalar(u8, body, ';') orelse body.len;
    const controls = body[0..separator];
    for (controls) |byte| if (byte > 0x7f) return error.InvalidInput;
    var control: KittyControl = .{};
    if (controls.len != 0) {
        var pairs = std.mem.splitScalar(u8, controls, ',');
        while (pairs.next()) |pair| {
            if (pair.len < 2 or pair[1] != '=') return error.InvalidInput;
            const value = pair[2..];
            switch (pair[0]) {
                'a' => {
                    if (value.len != 1) return error.InvalidInput;
                    control.action = switch (value[0]) { 't' => .transmit, 'T' => .transmit_and_place,
                        'p' => .place, 'd' => .delete, 'q' => .query, else => .{ .unsupported = value[0] } };
                },
                'f' => control.format = switch (try decimalSigned(i64, value)) { 24 => .rgb, 32 => .rgba, 100 => .png, else => return error.InvalidInput },
                'i' => control.image_id = try decimalUnsigned(value),
                'I' => control.image_number = try decimalUnsigned(value),
                'p' => control.placement_id = try decimalUnsigned(value),
                's' => control.width = try decimalUnsigned(value),
                'v' => control.height = try decimalUnsigned(value),
                'c' => control.cell_cols = try decimalUnsigned(value),
                'r' => control.cell_rows = try decimalUnsigned(value),
                'x' => control.source_x = try decimalUnsigned(value),
                'y' => control.source_y = try decimalUnsigned(value),
                'z' => control.z_index = try decimalSigned(i32, value),
                'm' => control.more = try boolean(value),
                'q' => {
                    const quiet = try decimalSigned(i64, value);
                    if (quiet < 0 or quiet > 2) return error.InvalidInput;
                    control.quiet = @intCast(quiet);
                },
                'U' => control.virtual_placement = try boolean(value),
                'X' => control.offset_x = try decimalUnsigned(value),
                'Y' => control.offset_y = try decimalUnsigned(value),
                'C' => control.no_cursor_move = try boolean(value),
                'o' => { if (!std.mem.eql(u8, value, "z")) return error.InvalidInput; control.compression = .zlib; },
                't' => { if (value.len != 1) return error.InvalidInput; control.transmission = value[0]; },
                'd' => { if (value.len != 1) return error.InvalidInput; control.delete_what = value[0]; },
                else => {}, // Unknown well-formed single-byte keys are ignored.
            }
        }
    }
    if (control.image_id != 0 and control.image_number != 0) return error.InvalidInput;
    return .{ .control = control, .payload = if (separator == body.len) body[body.len..] else body[separator + 1 ..] };
}

fn decimalUnsigned(bytes: []const u8) Error!u32 {
    if (bytes.len == 0) return error.InvalidInput;
    for (bytes) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInput;
    return std.fmt.parseInt(u32, bytes, 10) catch error.InvalidInput;
}

pub fn decimalSigned(comptime T: type, bytes: []const u8) Error!T {
    if (bytes.len == 0) return error.InvalidInput;
    const digits = if (bytes[0] == '-' or bytes[0] == '+') bytes[1..] else bytes;
    if (digits.len == 0) return error.InvalidInput;
    for (digits) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidInput;
    return std.fmt.parseInt(T, bytes, 10) catch error.InvalidInput;
}

fn boolean(value: []const u8) Error!bool {
    if (value.len != 1 or (value[0] != '0' and value[0] != '1')) return error.InvalidInput;
    return value[0] == '1';
}

pub fn decodeBase64(a: Allocator, bytes: []const u8, limit: usize) Error![]u8 {
    // Preserve Foundation's byte decoder, including extra trailing padding,
    // ignored unused bits and a third-position pad followed by a fourth value.
    // Unknown characters and incomplete quartets still fail. iTerm2 filters
    // unknown characters explicitly before reaching this shared decoder.
    const size = try base64Pass(bytes, null, limit);
    const decoded = try a.alloc(u8, size);
    errdefer a.free(decoded);
    _ = try base64Pass(bytes, decoded, limit);
    return decoded;
}

fn base64Value(byte: u8) Error!u8 {
    return switch (byte) {
        'A'...'Z' => byte - 'A', 'a'...'z' => byte - 'a' + 26,
        '0'...'9' => byte - '0' + 52, '+' => 62, '/' => 63,
        else => error.InvalidInput,
    };
}

fn onlyPadding(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != '=') return false;
    return true;
}

fn base64Pass(bytes: []const u8, destination: ?[]u8, limit: usize) Error!usize {
    var offset: usize = 0;
    var written: usize = 0;
    while (offset < bytes.len) {
        if (bytes[offset] == '=' and onlyPadding(bytes[offset..])) {
            if (offset != 0) return written;
            if (bytes.len < 4) return error.InvalidInput;
            if (limit == 0) return error.TooLarge;
            if (destination) |out| out[0] = 0;
            return 1;
        }
        if (bytes.len - offset < 4) return error.InvalidInput;
        const part = bytes[offset..][0..4];
        const a = try base64Value(part[0]);
        const b = try base64Value(part[1]);
        const c = if (part[2] == '=') 0 else try base64Value(part[2]);
        const d = if (part[3] == '=') 0 else try base64Value(part[3]);
        const count: usize = 1 + @as(usize, @intFromBool(part[2] != '=')) + @as(usize, @intFromBool(part[3] != '='));
        if (written > limit or count > limit - written) return error.TooLarge;
        if (destination) |out| {
            var index = written;
            out[index] = (a << 2) | (b >> 4);
            index += 1;
            if (part[2] != '=') { out[index] = (b << 4) | (c >> 2); index += 1; }
            if (part[3] != '=') out[index] = (c << 6) | d;
        }
        written += count;
        offset += 4;
        if (part[2] == '=' or part[3] == '=') {
            if (!onlyPadding(bytes[offset..])) return error.InvalidInput;
            return written;
        }
    }
    return written;
}

/// The Swift implementation strips the RFC1950 wrapper and decodes raw
/// deflate, and requires strictly less than the cap. Preserve that behavior.
pub fn zlibInflated(a: Allocator, bytes: []const u8, max_output_size: usize) Error![]u8 {
    if (bytes.len <= 6 or max_output_size == 0) return error.TooLarge;
    const raw = bytes[2 .. bytes.len - 4];
    return inflateRaw(a, raw, max_output_size) catch |err| switch (err) {
        error.Truncated => blk: {
            // Compression's raw decoder tolerates an omitted final zero byte
            // containing only end-of-block padding. Add one zero only after a
            // genuine input-exhaustion error; never retry invalid codes/limits.
            const padded = try a.alloc(u8, raw.len + 1);
            defer a.free(padded);
            @memcpy(padded[0..raw.len], raw);
            padded[raw.len] = 0;
            break :blk inflateRaw(a, padded, max_output_size) catch |retry| switch (retry) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.TooLarge,
            };
        },
        else => |failure| failure,
    };
}

fn inflateRaw(a: Allocator, raw: []const u8, max_output_size: usize) (Error || error{Truncated})![]u8 {
    var reader = std.Io.Reader.fixed(raw);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder = std.compress.flate.Decompress.init(&reader, .raw, &window);
    const output = decoder.reader.allocRemaining(a, .limited(max_output_size)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ReadFailed => {
            if (decoder.err) |decode_error| {
                if (decode_error == error.EndOfStream and decoder.final_block and
                    decoder.remaining_bits > 0 and decoder.next_bits == 0) return error.Truncated;
            }
            return error.TooLarge;
        },
        else => return error.TooLarge,
    };
    if (output.len == 0) { a.free(output); return error.TooLarge; }
    return output;
}

/// Owns the returned image payload. Does not advance store identifiers.
pub fn decodeKittyImage(a: Allocator, control: KittyControl, base64: []const u8, next_image_id: u32) Error!*Image {
    if (control.transmission != 'd' or base64.len > max_encoded_bytes) return error.InvalidInput;
    const encoded = try decodeBase64(a, base64, max_payload_bytes);
    defer a.free(encoded);
    const data = if (control.compression == .zlib) try zlibInflated(a, encoded, max_payload_bytes) else encoded;
    defer if (control.compression == .zlib) a.free(data);
    const id = if (control.image_id == 0) next_image_id else control.image_id;
    const number: ?u32 = if (control.image_number == 0) null else control.image_number;
    const payload: *Payload = switch (control.format) {
        .png => blk: {
            const dimensions = pngDimensions(data) orelse return error.InvalidInput;
            break :blk try Payload.createCopy(a, .png, data, dimensions.width, dimensions.height);
        },
        .rgba => try Payload.createCopy(a, .rgba, data, control.width, control.height),
        .rgb => blk: {
            const pixels = validatedPixelCount(control.width, control.height) orelse return error.InvalidInput;
            if (pixels * 3 != data.len) return error.InvalidInput;
            const rgba = try a.alloc(u8, pixels * 4);
            errdefer a.free(rgba);
            for (0..pixels) |i| rgba[i * 4 ..][0..4].* = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
            break :blk try Payload.createOwned(a, .rgba, rgba, control.width, control.height);
        },
    };
    defer payload.release();
    return try Image.create(payload, id, number);
}

/// A borrowed OSC 1337 payload becomes one owned PNG payload; unknown base64
/// characters are ignored just as Foundation's iTerm2 decoder does.
pub fn decodeITerm2(a: Allocator, bytes: []const u8) Error!?*Payload {
    if (!std.mem.startsWith(u8, bytes, "File=")) return null;
    const colon = std.mem.indexOfScalar(u8, bytes, ':') orelse return null;
    if (colon < 5) return null;
    var inline_image = false;
    var pairs = std.mem.splitScalar(u8, bytes[5..colon], ';');
    while (pairs.next()) |pair| if (std.mem.eql(u8, pair, "inline=1")) { inline_image = true; };
    if (!inline_image) return null;
    const body = bytes[colon + 1 ..];
    var filtered: std.ArrayList(u8) = .empty;
    defer filtered.deinit(a);
    for (body) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '+' and byte != '/' and byte != '=') continue;
        // The payload cap bounds decoded bytes; reserve no attacker-sized
        // unfiltered array before checking it.
        if (filtered.items.len >= (max_encoded_bytes / 3 + 1) * 4) return error.TooLarge;
        try filtered.append(a, byte);
    }
    const decoded = try decodeBase64(a, filtered.items, max_encoded_bytes);
    errdefer a.free(decoded);
    const dimensions = pngDimensions(decoded) orelse { a.free(decoded); return null; };
    return try Payload.createOwned(a, .png, decoded, dimensions.width, dimensions.height);
}

pub const InlineBudget = struct {
    payload_bytes: usize = 0,
    limit: usize = max_payload_bytes,
    pub fn accept(self: *InlineBudget, payload: *const Payload) bool {
        if (self.payload_bytes > self.limit or payload.bytes.len > self.limit - self.payload_bytes) return false;
        if (payload.format == .png and payload.bytes.len > max_encoded_bytes) return false;
        self.payload_bytes += payload.bytes.len;
        return true;
    }
    pub fn reset(self: *InlineBudget) void { self.payload_bytes = 0; }
};

pub const CursorContext = struct {
    col: isize,
    /// Absolute row, including scrollback, of the live cursor.
    row: isize,
    y_base: isize = 0,
    is_alternate_buffer: bool = false,
};

pub const Reply = struct {
    storage: [128]u8 = undefined,
    len: usize = 0,
    pub fn bytes(self: *const Reply) []const u8 { return self.storage[0..self.len]; }
};

pub fn kittyReply(control: KittyControl, image_id: ?u32, failure: ?ProtocolError) ?Reply {
    if ((failure == null and control.quiet >= 1) or (failure != null and control.quiet >= 2)) return null;
    var result: Reply = .{};
    var writer = std.Io.Writer.fixed(&result.storage);
    writer.writeAll("\x1b_G") catch unreachable;
    const resolved_image_id = image_id orelse control.image_id;
    var comma = false;
    if (resolved_image_id != 0) {
        writer.print("i={d}", .{resolved_image_id}) catch unreachable;
        comma = true;
    }
    if (control.image_number != 0) {
        if (comma) writer.writeByte(',') catch unreachable;
        writer.print("I={d}", .{control.image_number}) catch unreachable;
        comma = true;
    }
    if (control.placement_id != 0) {
        if (comma) writer.writeByte(',') catch unreachable;
        writer.print("p={d}", .{control.placement_id}) catch unreachable;
    }
    writer.print(";{s}\x1b\\", .{if (failure) |err| err.code() else "OK"}) catch unreachable;
    result.len = writer.end;
    return result;
}

pub const Display = struct {
    image_id: u32,
    placement_id: u32,
    is_virtual: bool,
    cols: isize,
    rows: isize,
    /// Present only for a nonvirtual placement, with one owned payload ref.
    attachment: ?*LineImage = null,

    pub fn deinit(self: *Display) void {
        if (self.attachment) |attachment| attachment.deinit();
        self.* = undefined;
    }
};

/// Host applies removed placement keys and an optional display attachment, then
/// cursor/logical-line motion, then publishes the reply. deinit releases only
/// effects not moved into the buffer (set attachment=null after transferring).
pub const KittyResult = struct {
    should_apply_display_line_motion: bool = false,
    committed_transmission_image_id: ?u32 = null,
    display: ?Display = null,
    removed: std.ArrayList(Placement) = .empty,
    reply: ?Reply = null,
    protocol_error: ?ProtocolError = null,
    allocation_failed: bool = false,
    strip_deleted_placements: bool = false,
    delete_data: bool = false,

    pub fn deinit(self: *KittyResult, a: Allocator) void {
        if (self.display) |*display| display.deinit();
        self.removed.deinit(a);
        self.* = undefined;
    }
};

/// Native protocol state. No host callbacks run while mutable storage is
/// borrowed. A transmission that commits before a placement fails is reported
/// explicitly, matching the existing Swift engine's partial-success behavior.
pub const KittyEngine = struct {
    allocator: Allocator,
    store: KittyGraphicsStore,
    chunk_control: ?KittyControl = null,
    chunk_data: std.ArrayList(u8) = .empty,
    chunk_limit: usize = max_encoded_bytes,

    pub fn init(a: Allocator) KittyEngine { return .{ .allocator = a, .store = .init(a) }; }
    pub fn deinit(self: *KittyEngine) void {
        self.store.deinit();
        self.chunk_data.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn reset(self: *KittyEngine) void { self.store.deleteAll(); self.cancelChunks(); }
    pub fn cancelChunks(self: *KittyEngine) void {
        self.chunk_control = null;
        self.chunk_data.clearRetainingCapacity();
    }

    pub fn handle(self: *KittyEngine, bytes: []const u8, cursor: CursorContext) KittyResult {
        return self.handleInternal(bytes, cursor, false);
    }

    /// Terminal row attachments must be removed before uppercase selectors
    /// release stored data, because host payload destruction can reenter.
    pub fn handleForTerminal(self: *KittyEngine, bytes: []const u8, cursor: CursorContext) KittyResult {
        return self.handleInternal(bytes, cursor, true);
    }

    fn handleInternal(self: *KittyEngine, bytes: []const u8, cursor: CursorContext, defer_data_delete: bool) KittyResult {
        if (bytes.len == 0 or bytes[0] != 'G') return .{};
        const envelope = decodeKittyEnvelope(bytes) catch { self.cancelChunks(); return .{}; };
        const control = envelope.control;
        switch (control.action) {
            .delete => {
                self.cancelChunks();
                var result: KittyResult = .{};
                result.removed = self.delete(control, cursor) catch |err| {
                    setFailure(&result, control, null, err);
                    return result;
                };
                const normalized = std.ascii.toLower(control.delete_what);
                result.strip_deleted_placements = normalized != 'i' and normalized != 'n' or
                    control.image_id != 0 or (control.image_number != 0 and self.store.newestImage(control.image_number) != null);
                result.delete_data = std.ascii.isUpper(control.delete_what);
                if (!defer_data_delete) self.deleteResultData(&result);
                result.reply = kittyReply(control, null, null);
                return result;
            },
            .transmit, .transmit_and_place, .query => return self.receive(control, envelope.payload, cursor),
            .place => {
                var result: KittyResult = .{};
                const image = self.resolveImage(control) orelse { setFailure(&result, control, null, error.Missing); return result; };
                result.display = self.place(image, control, cursor) catch |err| { setFailure(&result, control, image.id, err); return result; };
                result.should_apply_display_line_motion = !control.virtual_placement and !control.no_cursor_move;
                result.reply = kittyReply(control, image.id, null);
                return result;
            },
            .unsupported => { var result: KittyResult = .{}; setFailure(&result, control, null, error.InvalidInput); return result; },
        }
    }

    fn receive(self: *KittyEngine, control: KittyControl, payload: []const u8, cursor: CursorContext) KittyResult {
        if (self.chunk_control) |initial| {
            self.appendChunk(payload) catch |err| {
                self.cancelChunks();
                var result: KittyResult = .{};
                setFailure(&result, initial, null, err);
                return result;
            };
            if (control.more) return .{};
            // Detach before decoding/storage: releasing a replaced host image
            // may recursively begin another transmission on this engine.
            var encoded = self.chunk_data;
            self.chunk_data = .empty;
            self.chunk_control = null;
            defer encoded.deinit(self.allocator);
            return self.finishTransmission(initial, encoded.items, cursor);
        }
        if (control.more) {
            self.appendChunk(payload) catch |err| {
                self.cancelChunks();
                var result: KittyResult = .{};
                setFailure(&result, control, null, err);
                return result;
            };
            self.chunk_control = control;
            return .{};
        }
        return self.finishTransmission(control, payload, cursor);
    }

    fn appendChunk(self: *KittyEngine, bytes: []const u8) Error!void {
        if (self.chunk_data.items.len > self.chunk_limit or bytes.len > self.chunk_limit - self.chunk_data.items.len) return error.TooLarge;
        try self.chunk_data.appendSlice(self.allocator, bytes);
    }

    fn finishTransmission(self: *KittyEngine, control: KittyControl, encoded: []const u8, cursor: CursorContext) KittyResult {
        var result: KittyResult = .{};
        var image = decodeKittyImage(self.allocator, control, encoded, self.store.next_image_id) catch |err| {
            setFailure(&result, control, null, err);
            return result;
        };
        defer image.deinit();
        if (control.action == .query) {
            result.reply = kittyReply(control, image.id, null);
            return result;
        }
        // Retain every replaced key before store() removes its records. A
        // failed reserve/store keeps the old image, placements and effects.
        for (self.store.placements_by_key.values()) |placement| {
            if (placement.image_id == image.id) result.removed.append(self.allocator, placement) catch |err| {
                result.removed.clearRetainingCapacity();
                setFailure(&result, control, image.id, err);
                return result;
            };
        }
        self.store.store(image) catch |err| {
            result.removed.clearRetainingCapacity();
            setFailure(&result, control, image.id, err);
            return result;
        };
        result.committed_transmission_image_id = image.id;
        if (control.action == .transmit_and_place) {
            result.display = self.place(image, control, cursor) catch |err| {
                setFailure(&result, control, image.id, err);
                return result;
            };
            result.should_apply_display_line_motion = !control.virtual_placement and !control.no_cursor_move;
        }
        result.reply = kittyReply(control, image.id, null);
        return result;
    }

    pub fn resolveImage(self: *const KittyEngine, control: KittyControl) ?*Image {
        if (control.image_id != 0) return self.store.images_by_id.get(control.image_id);
        if (control.image_number != 0) return self.store.newestImage(control.image_number);
        return null;
    }

    fn place(self: *KittyEngine, image: *Image, control: KittyControl, cursor: CursorContext) Error!Display {
        const cols: isize = if (control.cell_cols > 0) control.cell_cols else 1;
        const rows: isize = if (control.cell_rows > 0) control.cell_rows else 1;
        if (cols == 0 or rows == 0 or cols > max_cell_span or rows > max_cell_span) return error.NoSpace;
        const placement_id = if (control.placement_id == 0) self.store.next_placement_id else control.placement_id;
        var attachment: ?*LineImage = null;
        errdefer if (attachment) |value| value.deinit();
        if (!control.virtual_placement) {
            attachment = try LineImage.init(image.payload, cursor.col);
            attachment.?.pixel_width = image.pixel_width;
            attachment.?.pixel_height = image.pixel_height;
            attachment.?.is_kitty = true;
            attachment.?.image_id = image.id;
            attachment.?.placement_id = placement_id;
            attachment.?.z_index = control.z_index;
            attachment.?.offset_x = control.offset_x;
            attachment.?.offset_y = control.offset_y;
        }
        _ = try self.store.place(.{ .image_id = image.id, .placement_id = placement_id,
            .col = cursor.col, .row = cursor.row, .cols = cols, .rows = rows,
            .z_index = control.z_index, .offset_x = control.offset_x, .offset_y = control.offset_y,
            .is_virtual = control.virtual_placement, .is_alternate_buffer = cursor.is_alternate_buffer });
        return .{ .image_id = image.id, .placement_id = placement_id, .is_virtual = control.virtual_placement,
            .cols = cols, .rows = rows, .attachment = attachment };
    }

    fn delete(self: *KittyEngine, control: KittyControl, cursor: CursorContext) Allocator.Error!std.ArrayList(Placement) {
        const target_image_id: ?u32 = if (control.image_id != 0) control.image_id else
            if (control.image_number != 0) (if (self.store.newestImage(control.image_number)) |image| image.id else null) else null;
        const context = DeleteContext{ .control = control, .cursor = cursor, .target_image_id = target_image_id };
        const removed = try self.store.removePlacements(context, DeleteContext.matches);
        return removed;
    }

    pub fn deleteResultData(self: *KittyEngine, result: *const KittyResult) void {
        if (!result.delete_data) return;
        for (result.removed.items) |placement| {
            if (!self.store.hasPlacement(placement.image_id)) self.store.deleteImage(placement.image_id);
        }
    }
};

const DeleteContext = struct {
    control: KittyControl,
    cursor: CursorContext,
    target_image_id: ?u32,
    fn matches(self: DeleteContext, placement: Placement) bool {
        const control = self.control;
        const selector = std.ascii.toLower(control.delete_what);
        const source_row = self.cursor.y_base +| @as(isize, control.source_y);
        return switch (selector) {
            'i', 'n' => self.target_image_id != null and placement.image_id == self.target_image_id.? and
                (control.placement_id == 0 or placement.placement_id == control.placement_id),
            'z' => placement.z_index == control.z_index,
            'x' => contains(placement.col, placement.cols, control.source_x),
            'y' => contains(placement.row, placement.rows, source_row),
            'p', 'q' => contains(placement.col, placement.cols, control.source_x) and contains(placement.row, placement.rows, source_row) and
                (selector != 'q' or placement.z_index == control.z_index),
            'c' => !placement.is_virtual and contains(placement.col, placement.cols, self.cursor.col) and contains(placement.row, placement.rows, self.cursor.row),
            else => !placement.is_virtual,
        };
    }
};

fn contains(start: isize, length: isize, value: isize) bool {
    // Wider arithmetic preserves interval membership at hostile isize limits.
    return value >= start and @as(i128, value) < @as(i128, start) + length;
}

fn setFailure(result: *KittyResult, control: KittyControl, image_id: ?u32, err: Error) void {
    result.protocol_error = switch (err) {
        error.InvalidInput => .invalid, error.Missing => .missing, error.TooLarge => .too_large,
        error.NoSpace, error.OutOfMemory, error.IdentityExhausted => .no_space,
    };
    result.allocation_failed = err == error.OutOfMemory;
    result.reply = kittyReply(control, image_id, result.protocol_error);
}
