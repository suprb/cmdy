const std = @import("std");
const Allocator = std.mem.Allocator;
const width_tables = @import("unicode.zig");
const cluster_rules = @import("clusters.zig");
const backing_pool = @import("row_backing_pool.zig");
// Representation bounds, not the initial prototype's 4096-column/1M limits.
const storage_header_bytes = std.mem.alignForward(usize, @sizeOf(Storage), @alignOf(StoredCell));
const max_cols = (std.math.maxInt(usize) - storage_header_bytes) / @sizeOf(StoredCell);
const max_extras = std.math.maxInt(u32) - 1;
const absent = std.math.maxInt(u32);
pub const Error = error{ InvalidInput, OutOfMemory };
var generation = std.atomic.Value(u64).init(0);

pub const Cell = extern struct {
    scalar: u32 = 0,
    fg: u32 = 0,
    bg: u32 = 0,
    underline_color: u32 = 0,
    link_id: u16 = 0,
    width: i8 = 1,
    style: u8 = 0,
    underline_kind: u8 = 0,
    underline_present: u8 = 0,
    reserved: [2]u8 = .{ 0, 0 },
};
pub const StoredCell = extern struct {
    cell: Cell,
    cluster_offset: u32 = absent,
    cluster_count: u32 = 0,
};
pub const Scalar = extern struct { scalar: u32, width: i8, reserved: [3]u8 = .{ 0, 0, 0 } };
pub const PrintResult = extern struct {
    bytes: usize = 0,
    columns: usize = 0,
    count: usize = 0,
    final: Scalar = .{ .scalar = 0, .width = 1 },
    displaced: Cell = .{},
    extras: ?[*]u32 = null,
    extra_count: usize = 0,
    present: u8 = 0,
    fn release(result: *PrintResult, a: Allocator) void {
        if (result.extras) |ptr| a.free(ptr[0..result.extra_count]);
        result.extras = null;
        result.extra_count = 0;
    }
};

// A complete valid scalar, or no consumption. The Swift parser remains the
// owner of partial UTF-8, controls, followers, and callback/reentry boundaries.
inline fn decode(input: []const u8) ?struct { scalar: u32, bytes: usize } {
    if (input.len == 0) return null;
    if (input[0] >= 0x20 and input[0] <= 0x7e) return .{ .scalar = input[0], .bytes = 1 };
    if (input[0] < 0xc2 or input[0] > 0xf4) return null;
    const count = std.unicode.utf8ByteSequenceLength(input[0]) catch return null;
    if (count > input.len) return null;
    return .{ .scalar = std.unicode.utf8Decode(input[0..count]) catch return null, .bytes = count };
}

fn validScalar(s: u32) bool {
    return s <= 0x10ffff and !(s >= 0xd800 and s <= 0xdfff);
}
const EmojiPropertyCache = struct {
    // Two KiB per terminal, including a separately indexed victim table. Both
    // tables retain the complete scalar key; double collisions still miss.
    entries: [256]u32 = @splat(std.math.maxInt(u32)),
    victims: [256]u32 = @splat(std.math.maxInt(u32)),
    fn create(a: Allocator) Error!*EmojiPropertyCache {
        const cache = try a.create(EmojiPropertyCache);
        cache.* = .{};
        return cache;
    }
    fn index(scalar: u32) usize {
        return (scalar *% 0x9e3779b1) >> 24;
    }
    fn victimIndex(scalar: u32) usize {
        const mixed = (scalar ^ (scalar >> 16)) *% 0x85ebca6b;
        return (mixed ^ (mixed >> 13)) >> 24;
    }
    fn get(cache: *const EmojiPropertyCache, scalar: u32) i32 {
        if (!validScalar(scalar)) return -1;
        const entry = cache.entries[index(scalar)];
        if (entry >> 1 == scalar) return @intCast(entry & 1);
        const victim = cache.victims[victimIndex(scalar)];
        return if (victim >> 1 == scalar) @intCast(victim & 1) else 2;
    }
    fn put(cache: *EmojiPropertyCache, scalar: u32, value: u8) i32 {
        if (!validScalar(scalar) or value > 1) return -1;
        const slot = index(scalar);
        const previous = cache.entries[slot];
        if (previous != std.math.maxInt(u32) and previous >> 1 != scalar) {
            cache.victims[victimIndex(previous >> 1)] = previous;
        }
        cache.entries[slot] = (scalar << 1) | value;
        return 0;
    }
};
export fn cmdy_zemoji_cache_create() ?*EmojiPropertyCache {
    return EmojiPropertyCache.create(std.heap.c_allocator) catch null;
}
export fn cmdy_zemoji_cache_free(cache: ?*EmojiPropertyCache) void {
    if (cache) |value| std.heap.c_allocator.destroy(value);
}
export fn cmdy_zemoji_cache_get(cache: ?*const EmojiPropertyCache, scalar: u32) i32 {
    return (cache orelse return -1).get(scalar);
}
export fn cmdy_zemoji_cache_put(cache: ?*EmojiPropertyCache, scalar: u32, value: u8) i32 {
    return (cache orelse return -1).put(scalar, value);
}
export fn cmdy_zunicode_vs16_base(scalar: u32) u8 {
    return @intFromBool(width_tables.isVS16Base(scalar));
}
fn emojiCacheAllocationTrace(a: Allocator) !void {
    const cache = try EmojiPropertyCache.create(a);
    defer a.destroy(cache);
    for (0..10000) |n| {
        const scalar: u32 = @intCast(n);
        try std.testing.expectEqual(@as(i32, 2), cache.get(scalar));
        try std.testing.expectEqual(@as(i32, 0), cache.put(scalar, @intCast(n & 1)));
        try std.testing.expectEqual(@as(i32, @intCast(n & 1)), cache.get(scalar));
    }
}
test "bounded emoji property cache keys every answer and tolerates eviction" {
    try std.testing.expectEqual(@as(usize, 2048), @sizeOf(EmojiPropertyCache));
    try std.testing.checkAllAllocationFailures(std.testing.allocator, emojiCacheAllocationTrace, .{});
    var cache: EmojiPropertyCache = .{};
    try std.testing.expectEqual(@as(i32, 0), cache.put(0x1f469, 1));
    const before = cache.entries;
    try std.testing.expectEqual(@as(i32, -1), cache.put(0x1f469, 2));
    try std.testing.expectEqual(@as(i32, -1), cache.put(0xd800, 1));
    try std.testing.expectEqual(@as(i32, -1), cache.get(0x110000));
    try std.testing.expectEqualSlices(u32, &before, &cache.entries);
    try std.testing.expectEqual(@as(i32, 1), cache.get(0x1f469));
    try std.testing.expectEqual(@as(i32, -1), cmdy_zemoji_cache_get(null, 65));
    cmdy_zemoji_cache_free(null);
}
test "victim cache retains primary collisions and treats double collisions as misses" {
    var cache: EmojiPropertyCache = .{};
    var keys: [16]u32 = undefined;
    var used: [256]bool = @splat(false);
    var count: usize = 0;
    for (0..0x110000) |raw| {
        const scalar: u32 = @intCast(raw);
        if (!validScalar(scalar) or EmojiPropertyCache.index(scalar) != 0) continue;
        const victim = EmojiPropertyCache.victimIndex(scalar);
        if (used[victim]) continue;
        used[victim] = true;
        keys[count] = scalar;
        count += 1;
        if (count == keys.len) break;
    }
    try std.testing.expectEqual(keys.len, count);
    for (keys, 0..) |scalar, i| try std.testing.expectEqual(@as(i32, 0), cache.put(scalar, @intCast(i & 1)));
    for (keys, 0..) |scalar, i| try std.testing.expectEqual(@as(i32, @intCast(i & 1)), cache.get(scalar));

    var double: [4]u32 = undefined;
    count = 0;
    for (0..0x110000) |raw| {
        const scalar: u32 = @intCast(raw);
        if (!validScalar(scalar) or EmojiPropertyCache.index(scalar) != 0 or
            EmojiPropertyCache.victimIndex(scalar) != 0) continue;
        double[count] = scalar;
        count += 1;
        if (count == double.len) break;
    }
    try std.testing.expectEqual(double.len, count);
    cache = .{};
    for (double, 0..) |scalar, i| try std.testing.expectEqual(@as(i32, 0), cache.put(scalar, @intCast(i & 1)));
    try std.testing.expectEqual(@as(i32, 2), cache.get(double[0]));
    try std.testing.expectEqual(@as(i32, 2), cache.get(double[1]));
    try std.testing.expectEqual(@as(i32, 0), cache.get(double[2]));
    try std.testing.expectEqual(@as(i32, 1), cache.get(double[3]));
    const entries = cache.entries;
    const victims = cache.victims;
    try std.testing.expectEqual(@as(i32, -1), cache.put(0xd800, 1));
    try std.testing.expectEqual(@as(i32, -1), cache.put(double[2], 2));
    try std.testing.expectEqualSlices(u32, &entries, &cache.entries);
    try std.testing.expectEqualSlices(u32, &victims, &cache.victims);
}
fn validColor(c: u32) bool {
    return c == 0 or c == 0x03000000 or
        (c >= 0x01000000 and c <= 0x010000ff) or
        (c >= 0x02000000 and c <= 0x02ffffff);
}
fn validCell(c: Cell) bool {
    // Swift Cell publicly stores raw UInt32/Int8 values, including invalid
    // Unicode and unusual widths. Storage preserves them; the parser validates
    // Unicode input and the renderer handles invalid scalar values separately.
    return validColor(c.fg) and validColor(c.bg) and validColor(c.underline_color) and
        c.underline_kind <= 5 and c.underline_present <= 1 and
        (c.underline_present == 1 or c.underline_color == 0) and
        c.reserved[0] == 0 and c.reserved[1] == 0;
}
pub fn stamp() u64 {
    return generation.fetchAdd(1, .monotonic) +% 1;
}

const ASCIIPalette = struct {
    extra: [3]Cell = .{ .{}, .{}, .{} },
    count: u8 = 1,
    indices: []u8,
};
const CompactASCII = struct {
    pen: Cell,
    bytes: []u8,
    // Only directly created engine lines enable multiple attributes. Cold
    // uniform history keeps its existing write admission and dense fallback.
    palette: ?*ASCIIPalette = null,
    fn indexFor(c: *const CompactASCII, pen: Cell) ?u8 {
        if (std.meta.eql(c.pen, pen)) return 0;
        if (c.palette) |palette| {
            for (palette.extra[0 .. palette.count - 1], 1..) |value, index| {
                if (std.meta.eql(value, pen)) return @intCast(index);
            }
        }
        return null;
    }
    fn cellAt(c: *const CompactASCII, column: usize) Cell {
        var result = c.pen;
        if (c.palette) |palette| {
            const index = palette.indices[column];
            std.debug.assert(index < palette.count);
            if (index != 0) result = palette.extra[index - 1];
        }
        result.scalar = c.bytes[column];
        return result;
    }
};
const Storage = struct {
    allocator: Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    cells: []StoredCell,
    // Cold, uniform ASCII history keeps one attribute and one scalar byte per
    // column. Dense ABI cell views are materialized on demand.
    // The uncommon metadata lives inside the compact allocation. Ordinary
    // dense rows carry only a nullable pointer, not its attribute and slice.
    compact_ascii: ?*CompactASCII = null,
    extras: std.ArrayList(u32) = .empty,
    live_extras: usize = 0,
    compacted_extras: usize = 0,
    garbage_possible: bool = false,
    // Conservative: includes present-but-empty extras, not just live scalars.
    maybe_clusters: bool = false,
    pooled_backing: bool = false,

    // Private allocation primitive. Callers initialize complete cells, or use
    // Row's deferred-fill invariant with initialized absent cluster fields.
    // Failure cleanup never reads cell data.
    fn allocate(a: Allocator, cols: usize) Error!*Storage {
        if (cols > max_cols) return error.InvalidInput;
        // Header and cells have the same lifetime. One allocation avoids a
        // separate malloc/free pair for every newly populated terminal row.
        const bytes = storage_header_bytes + cols * @sizeOf(StoredCell);
        const pooled = a.vtable == std.heap.c_allocator.vtable and backing_pool.eligible(bytes);
        const block = if (pooled) try backing_pool.allocate(bytes) else try a.alignedAlloc(u8, .of(Storage), bytes);
        const s: *Storage = @ptrCast(block.ptr);
        const cells = @as([*]StoredCell, @ptrCast(@alignCast(block.ptr + storage_header_bytes)))[0..cols];
        s.* = .{ .allocator = a, .cells = cells, .pooled_backing = pooled };
        return s;
    }
    fn create(a: Allocator, cols: usize, fill: Cell) Error!*Storage {
        if (!validCell(fill)) return error.InvalidInput;
        const s = try allocate(a, cols);
        @memset(s.cells, StoredCell{ .cell = fill });
        return s;
    }
    fn allocateASCII(a: Allocator, cols: usize, pen: Cell) Error!*Storage {
        return allocateASCIIStorage(a, cols, pen, false);
    }
    fn allocateASCIIStorage(a: Allocator, cols: usize, pen: Cell, with_palette: bool) Error!*Storage {
        if (cols > max_cols) return error.InvalidInput;
        const metadata_offset = std.mem.alignForward(usize, storage_header_bytes, @alignOf(CompactASCII));
        const palette_offset = std.mem.alignForward(usize, metadata_offset + @sizeOf(CompactASCII), @alignOf(ASCIIPalette));
        const payload_offset = if (with_palette) palette_offset + @sizeOf(ASCIIPalette) else metadata_offset + @sizeOf(CompactASCII);
        const block = try a.alignedAlloc(u8, .of(Storage), payload_offset + cols + (if (with_palette) cols else 0));
        const s: *Storage = @ptrCast(block.ptr);
        const metadata: *CompactASCII = @ptrCast(@alignCast(block.ptr + metadata_offset));
        metadata.* = .{ .pen = pen, .bytes = block[payload_offset..][0..cols] };
        if (with_palette) {
            const palette: *ASCIIPalette = @ptrCast(@alignCast(block.ptr + palette_offset));
            palette.* = .{ .indices = block[payload_offset + cols ..] };
            @memset(palette.indices, 0);
            metadata.palette = palette;
        }
        s.* = .{ .allocator = a, .cells = &.{}, .compact_ascii = metadata };
        return s;
    }
    fn allocationBytes(s: *const Storage) usize {
        if (s.compact_ascii) |compressed| {
            const metadata_end = std.mem.alignForward(usize, storage_header_bytes, @alignOf(CompactASCII)) + @sizeOf(CompactASCII);
            return if (compressed.palette != null)
                std.mem.alignForward(usize, metadata_end, @alignOf(ASCIIPalette)) + @sizeOf(ASCIIPalette) + compressed.bytes.len * 2
            else metadata_end + compressed.bytes.len;
        }
        return storage_header_bytes + s.cells.len * @sizeOf(StoredCell);
    }
    fn release(s: *Storage) void {
        if (s.refs.fetchSub(1, .acq_rel) == 1) {
            const a = s.allocator;
            const pooled = s.pooled_backing;
            const bytes = s.allocationBytes();
            const block: [*]align(@alignOf(Storage)) u8 = @ptrCast(s);
            s.extras.deinit(a);
            if (pooled) backing_pool.release(@alignCast(block[0..bytes])) else a.free(block[0..bytes]);
        }
    }
    fn duplicateCompact(s: *const Storage) Error!*Storage {
        const ascii_data = s.compact_ascii.?;
        const copy = try Storage.allocateASCIIStorage(s.allocator, ascii_data.bytes.len, ascii_data.pen, ascii_data.palette != null);
        @memcpy(copy.compact_ascii.?.bytes, ascii_data.bytes);
        if (ascii_data.palette) |old| {
            const palette = copy.compact_ascii.?.palette.?;
            palette.extra = old.extra;
            palette.count = old.count;
            @memcpy(palette.indices, old.indices);
        }
        return copy;
    }
    fn duplicate(s: *const Storage) Error!*Storage {
        if (s.compact_ascii) |compressed| {
            const copy = try Storage.allocate(s.allocator, compressed.bytes.len);
            for (copy.cells, 0..) |*cell, index| cell.* = .{ .cell = compressed.cellAt(index) };
            return copy;
        }
        const copy = try Storage.allocate(s.allocator, s.cells.len);
        errdefer copy.release();
        try copy.extras.appendSlice(s.allocator, s.extras.items);
        @memcpy(copy.cells, s.cells);
        copy.live_extras = s.live_extras;
        copy.compacted_extras = s.compacted_extras;
        copy.garbage_possible = s.garbage_possible;
        copy.maybe_clusters = s.maybe_clusters;
        return copy;
    }
    fn removeCluster(s: *Storage, index: usize) void {
        if (s.cells[index].cluster_count != 0) s.garbage_possible = true;
        s.live_extras -= s.cells[index].cluster_count;
    }
    fn clearExtras(s: *Storage) void {
        if (s.extras.capacity > s.cells.len * 4) {
            s.extras.deinit(s.allocator);
            s.extras = .empty;
        } else s.extras.clearRetainingCapacity();
        s.compacted_extras = 0;
        s.garbage_possible = false;
    }
    fn recount(s: *Storage) void {
        s.live_extras = 0;
        s.maybe_clusters = false;
        for (s.cells) |cell| {
            s.live_extras += cell.cluster_count;
            s.maybe_clusters = s.maybe_clusters or cell.cluster_offset != absent;
        }
        if (!s.maybe_clusters) s.clearExtras();
    }
    fn compact(s: *Storage, incoming: usize) Error!void {
        // Preserve shared fill clusters instead of expanding one cluster per
        // column. All allocations finish before any old offset is changed.
        var replacement = try std.ArrayList(u32).initCapacity(s.allocator, @min(s.live_extras, s.extras.items.len) + incoming);
        errdefer replacement.deinit(s.allocator);
        const offsets = try s.allocator.alloc(u32, s.cells.len);
        defer s.allocator.free(offsets);
        var relocated = std.AutoHashMap(u64, u32).init(s.allocator);
        defer relocated.deinit();
        for (s.cells, offsets) |cell, *offset| {
            if (cell.cluster_offset == absent) {
                offset.* = absent;
                continue;
            }
            if (cell.cluster_count == 0) {
                offset.* = 0;
                continue;
            }
            const key = @as(u64, cell.cluster_offset) << 32 | cell.cluster_count;
            const slot = try relocated.getOrPut(key);
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(replacement.items.len);
                // Tail appends can leave multiple valid prefix lengths at one
                // offset. Those distinct ranges may exceed the old physical
                // arena when compressed separately; keep growth fallible here.
                try replacement.appendSlice(s.allocator, s.extras.items[cell.cluster_offset..][0..cell.cluster_count]);
            }
            offset.* = slot.value_ptr.*;
        }
        for (s.cells, offsets) |*cell, offset| cell.cluster_offset = offset;
        s.extras.deinit(s.allocator);
        s.extras = replacement;
        s.compacted_extras = replacement.items.len;
        s.garbage_possible = false;
    }
    fn reserveExtras(s: *Storage, incoming: usize) Error!void {
        if (incoming > max_extras or s.live_extras > max_extras - incoming) return error.InvalidInput;
        if ((s.garbage_possible and s.extras.items.len > @min(s.live_extras, s.compacted_extras) * 2 + s.cells.len * 4) or
            s.extras.items.len > max_extras - incoming)
        {
            try s.compact(incoming);
        }
        try s.extras.ensureUnusedCapacity(s.allocator, incoming);
    }
};

// Keep ordinary/custom allocator Rows byte-for-byte layout compatible. Only
// canonical C-allocator Row.create owns the optional trailing allocation.
const OriginalRowLayout = struct {
    allocator: Allocator,
    storage: *Storage,
    revision: u64,
    deferred: ?Cell = null,
    deferred_from_fill: bool = false,
    valid_start: usize = 0,
    valid_end: usize = 0,
};
const InitialUnderlay = struct { initial: Cell, start: usize, end: usize };
const InitialRowAllocation = struct { row: Row, underlay: InitialUnderlay };
const allocated_underlay: u8 = 1;
const active_underlay: u8 = 2;
comptime {
    if (@sizeOf(Row) != @sizeOf(OriginalRowLayout) or @alignOf(Row) != @alignOf(OriginalRowLayout))
        @compileError("initial underlay changed the ordinary Row layout");
    for (@typeInfo(OriginalRowLayout).@"struct".fields) |field| {
        if (@offsetOf(Row, field.name) != @offsetOf(OriginalRowLayout, field.name))
            @compileError("initial underlay moved an existing Row field: " ++ field.name);
    }
    if (@offsetOf(InitialRowAllocation, "row") != 0 or
        @offsetOf(InitialRowAllocation, "underlay") < @sizeOf(OriginalRowLayout) or
        @sizeOf(InitialUnderlay) != 40 or @sizeOf(InitialRowAllocation) != @sizeOf(Row) + 40 or
        @alignOf(InitialRowAllocation) != @alignOf(Row))
        @compileError("initial underlay does not fit the declared trailing allocation");
}

pub const Row = struct {
    allocator: Allocator,
    storage: *Storage,
    revision: u64,
    deferred: ?Cell = null,
    // Initial deferral is a storage detail. Only a later logical fill had a
    // discard mutation in the eager representation; preserve that boundary.
    deferred_from_fill: bool = false,
    // Allocation bit follows the Row address, never a backing-storage swap.
    // The inactive trailing payload is not initialized or read.
    underlay_flags: u8 = 0,
    valid_start: usize = 0,
    valid_end: usize = 0,

    pub fn create(a: Allocator, cols: usize, initial: Cell) Error!*Row {
        if (!validCell(initial)) return error.InvalidInput;
        const s = try Storage.allocate(a, cols);
        errdefer s.release();
        // ASCII writes replace Cell payloads while preserving cluster fields.
        // Initialize those fields now; logical reads mask every unwritten Cell
        // until a contiguous write or materialization supplies its contents.
        for (s.cells) |*cell| {
            cell.cluster_offset = absent;
            cell.cluster_count = 0;
        }
        // Storage.create read the caller's fill after backing allocation and
        // before Row allocation. One initialized payload stages the same read.
        if (cols != 0) s.cells[0].cell = initial;
        // Allocator.ptr may be undefined for the canonical allocator. Only
        // compare the vtable, at the existing second allocation boundary.
        const with_underlay = a.vtable == std.heap.c_allocator.vtable;
        const r = if (with_underlay) &(try a.create(InitialRowAllocation)).row else try a.create(Row);
        r.* = .{ .allocator = a, .storage = s, .revision = stamp(), .deferred = if (cols == 0) null else s.cells[0].cell, .underlay_flags = if (with_underlay) allocated_underlay else 0 };
        return r;
    }
    // Engine Line creation may begin with a complete compact backing. No
    // dense-to-compact history scan, deferred initial underlay, or custom
    // allocator boundary changes are introduced. General Row.create is kept.
    pub fn createForLine(a: Allocator, cols: usize, initial: Cell) Error!*Row {
        if (a.vtable != std.heap.c_allocator.vtable or cols < 64 or
            initial.scalar > 0x7f or initial.width != 1) return create(a, cols, initial);
        if (!validCell(initial)) return error.InvalidInput;
        return createCompactInitial(a, cols, initial);
    }
    fn createCompactInitial(a: Allocator, cols: usize, initial: Cell) Error!*Row {
        var pen = initial;
        pen.scalar = 0;
        const storage = try Storage.allocateASCIIStorage(a, cols, pen, true);
        errdefer storage.release();
        @memset(storage.compact_ascii.?.bytes, @intCast(initial.scalar));
        const row = try a.create(Row);
        row.* = .{ .allocator = a, .storage = storage, .revision = stamp() };
        return row;
    }
    pub fn destroy(r: *Row) void {
        r.storage.release();
        if (r.underlay_flags & allocated_underlay != 0) {
            const allocation: *InitialRowAllocation = @fieldParentPtr("row", r);
            r.allocator.destroy(allocation);
        } else r.allocator.destroy(r);
    }
    fn clearUnderlay(r: *Row) void {
        r.underlay_flags &= ~active_underlay;
    }
    fn initialUnderlay(r: *Row) *InitialUnderlay {
        std.debug.assert(r.underlay_flags & allocated_underlay != 0);
        const allocation: *InitialRowAllocation = @fieldParentPtr("row", r);
        return &allocation.underlay;
    }
    fn preserveInitialUnderlay(r: *Row) void {
        if (r.deferred == null or r.deferred_from_fill) return;
        if (r.underlay_flags & allocated_underlay == 0) {
            r.materializeInitial();
            return;
        }
        std.debug.assert(r.storage.refs.load(.acquire) == 1 and !r.storage.maybe_clusters);
        r.initialUnderlay().* = .{ .initial = r.deferred.?, .start = r.valid_start, .end = r.valid_end };
        r.underlay_flags |= active_underlay;
    }
    // U tracks all initialized original backing, including writes hidden by
    // subsequent fills. Fill only a physical gap before joining a new write.
    fn prepareUnderlayWrite(r: *Row, start: usize, end: usize) void {
        if (r.underlay_flags & active_underlay == 0) return;
        std.debug.assert(r.deferred != null and r.deferred_from_fill and
            r.storage.refs.load(.acquire) == 1 and !r.storage.maybe_clusters);
        const u = r.initialUnderlay();
        if (u.start == u.end) {
            u.start = start;
            u.end = end;
            return;
        }
        if (start > u.end) @memset(r.storage.cells[u.end..start], StoredCell{ .cell = u.initial });
        if (end < u.start) @memset(r.storage.cells[end..u.start], StoredCell{ .cell = u.initial });
        u.start = @min(u.start, start);
        u.end = @max(u.end, end);
    }
    // Restore the eager physical backing without committing the logical F/V.
    // Discard and partial row-batch replacement expose this original backing.
    fn restoreInitialUnderlay(r: *Row) void {
        if (r.underlay_flags & active_underlay == 0) return;
        std.debug.assert(r.deferred != null and r.storage.refs.load(.acquire) == 1 and !r.storage.maybe_clusters);
        const u = r.initialUnderlay();
        @memset(r.storage.cells[0..u.start], StoredCell{ .cell = u.initial });
        @memset(r.storage.cells[u.end..], StoredCell{ .cell = u.initial });
        r.clearUnderlay();
    }
    pub fn createBytes(a: Allocator, input: []const u8, cols: usize, pen: Cell, tail: Cell) Error!*Row {
        if (input.len > cols or !validCell(pen) or !validCell(tail)) return error.InvalidInput;
        const s = try Storage.allocate(a, cols);
        errdefer s.release();
        for (input, s.cells[0..input.len]) |byte, *cell| {
            cell.* = .{ .cell = pen };
            cell.cell.scalar = byte;
            cell.cell.width = 1;
        }
        @memset(s.cells[input.len..], StoredCell{ .cell = tail });
        const r = try a.create(Row);
        r.* = .{ .allocator = a, .storage = s, .revision = stamp() };
        return r;
    }
    pub fn clone(r: *const Row) Error!*Row {
        const copy = try r.snapshot();
        copy.revision = stamp();
        return copy;
    }
    /// A read-only publication preserves the observed revision and does not
    /// consume a mutation stamp. Materialize deferred fills in detached storage.
    pub fn snapshot(r: *const Row) Error!*Row {
        if (r.deferred) |cell| {
            // A retained snapshot is fully materialized and read-only. Never
            // modify the owner's backing memory while taking a snapshot.
            if (!validCell(cell)) return error.InvalidInput;
            if (try r.compactLogicalSnapshot(cell)) |copy| return copy;
            const storage = try Storage.allocate(r.allocator, r.columnCount());
            errdefer storage.release();
            const copy = try r.allocator.create(Row);
            copy.* = .{ .allocator = r.allocator, .storage = storage, .revision = r.revision };
            // Keep the captured fill and the post-allocation source reads in
            // their original order. Initialize each destination cell once.
            @memset(copy.storage.cells[0..r.valid_start], StoredCell{ .cell = cell });
            if (r.isCompact()) {
                for (copy.storage.cells[r.valid_start..r.valid_end], r.valid_start..) |*target, index|
                    target.* = r.physicalStored(index);
            } else @memcpy(copy.storage.cells[r.valid_start..r.valid_end], r.storage.cells[r.valid_start..r.valid_end]);
            @memset(copy.storage.cells[r.valid_end..], StoredCell{ .cell = cell });
            return copy;
        }
        const copy = try r.allocator.create(Row);
        _ = r.storage.refs.fetchAdd(1, .monotonic);
        copy.* = .{ .allocator = r.allocator, .storage = r.storage, .revision = r.revision };
        return copy;
    }
    pub fn fromSnapshotCells(a: Allocator, cells: []const StoredCell, extras: []const u32, revision: u64) Error!*Row {
        if (extras.len > max_extras) return error.InvalidInput;
        var live_extras: usize = 0;
        var maybe_clusters = false;
        for (cells) |cell| {
            if (!validCell(cell.cell)) return error.InvalidInput;
            if (cell.cluster_offset == absent) {
                if (cell.cluster_count != 0) return error.InvalidInput;
            } else {
                if (cell.cluster_offset > extras.len or cell.cluster_count > extras.len - cell.cluster_offset or
                    cell.cluster_count > max_extras - live_extras) return error.InvalidInput;
                live_extras += cell.cluster_count;
                maybe_clusters = true;
            }
        }
        const storage = try Storage.allocate(a, cells.len);
        errdefer storage.release();
        @memcpy(storage.cells, cells);
        try storage.extras.appendSlice(a, extras);
        storage.live_extras = live_extras;
        storage.compacted_extras = extras.len;
        storage.maybe_clusters = maybe_clusters;
        const row = try a.create(Row);
        row.* = .{ .allocator = a, .storage = storage, .revision = revision };
        return row;
    }
    pub fn isCompact(r: *const Row) bool {
        return r.storage.compact_ascii != null;
    }
    /// Preserve both logical values and the physical backing exposed by discard.
    /// Shared storage and cluster-bearing rows retain their existing ownership.
    pub fn compactASCII(r: *Row) Error!bool {
        if (r.isCompact() or r.columnCount() < 64 or r.storage.maybe_clusters or
            r.storage.refs.load(.acquire) != 1) return false;
        var pen = r.compressionValue(0).cell;
        pen.scalar = 0;
        if (pen.width != 1) return false;
        for (0..r.columnCount()) |col| {
            const value = r.compressionValue(col);
            var attribute = value.cell;
            if (attribute.scalar > 0x7f or attribute.width != 1 or value.cluster_offset != absent) return false;
            attribute.scalar = 0;
            if (!std.meta.eql(attribute, pen)) return false;
        }
        const compressed = try Storage.allocateASCII(r.allocator, r.columnCount(), pen);
        for (compressed.compact_ascii.?.bytes, 0..) |*byte, col| byte.* = @intCast(r.compressionValue(col).cell.scalar);
        r.storage.release();
        r.storage = compressed;
        r.clearUnderlay();
        // Later fills preserve their independently observable physical tail.
        // Initial deferral only masked uninitialized memory; the packed bytes
        // now contain those initial values, so that mask can be retired.
        if (!r.deferred_from_fill) {
            r.deferred = null;
            r.valid_start = 0;
            r.valid_end = 0;
        }
        return true;
    }
    fn physicalStored(r: *const Row, index: usize) StoredCell {
        if (r.storage.compact_ascii) |compressed| {
            return .{ .cell = compressed.cellAt(index) };
        }
        return r.storage.cells[index];
    }
    fn compressionValue(r: *Row, index: usize) StoredCell {
        if (!r.deferred_from_fill) return r.logical(index);
        if (r.underlay_flags & active_underlay != 0) {
            const u = r.initialUnderlay();
            if (index < u.start or index >= u.end) return .{ .cell = u.initial };
        }
        return r.physicalStored(index);
    }
    fn physicalSnapshot(r: *const Row) Error!*Row {
        const storage = try r.storage.duplicate();
        errdefer storage.release();
        const result = try r.allocator.create(Row);
        result.* = .{ .allocator = r.allocator, .storage = storage, .revision = r.revision };
        return result;
    }
    fn compactLogicalSnapshot(r: *const Row, cell: Cell) Error!?*Row {
        const compact = r.storage.compact_ascii orelse return null;
        if (cell.scalar > 0x7f or cell.width != 1) return null;
        if (compact.palette != null) return r.paletteLogicalSnapshot(cell, compact);
        var attribute = cell;
        attribute.scalar = 0;
        if (r.valid_start != r.valid_end and !std.meta.eql(attribute, compact.pen)) return null;
        const storage = try Storage.allocateASCII(r.allocator, r.columnCount(), attribute);
        errdefer storage.release();
        const copy = try r.allocator.create(Row);
        copy.* = .{ .allocator = r.allocator, .storage = storage, .revision = r.revision };
        const ascii_values = storage.compact_ascii.?.bytes;
        @memset(ascii_values[0..r.valid_start], @intCast(cell.scalar));
        for (ascii_values[r.valid_start..r.valid_end], r.valid_start..) |*byte, index|
            byte.* = @intCast(r.physicalStored(index).cell.scalar);
        @memset(ascii_values[r.valid_end..], @intCast(cell.scalar));
        return copy;
    }
    fn paletteLogicalSnapshot(r: *const Row, cell: Cell, compact: *const CompactASCII) Error!?*Row {
        var attribute = cell;
        attribute.scalar = 0;
        const has_values = r.valid_start != r.valid_end;
        const old = compact.palette.?;
        const fill_index: u8 = if (!has_values) 0 else compact.indexFor(attribute) orelse blk: {
            if (old.count == 4) return null;
            break :blk old.count;
        };
        const storage = try Storage.allocateASCIIStorage(r.allocator, r.columnCount(), if (has_values) compact.pen else attribute, true);
        errdefer storage.release();
        const copy = try r.allocator.create(Row);
        copy.* = .{ .allocator = r.allocator, .storage = storage, .revision = r.revision };
        const target = storage.compact_ascii.?;
        const palette = target.palette.?;
        if (has_values) {
            palette.extra = old.extra;
            palette.count = old.count;
            if (fill_index == palette.count) {
                palette.extra[fill_index - 1] = attribute;
                palette.count += 1;
            }
            @memcpy(target.bytes[r.valid_start..r.valid_end], compact.bytes[r.valid_start..r.valid_end]);
            @memcpy(palette.indices[r.valid_start..r.valid_end], old.indices[r.valid_start..r.valid_end]);
        }
        @memset(target.bytes[0..r.valid_start], @intCast(cell.scalar));
        @memset(target.bytes[r.valid_end..], @intCast(cell.scalar));
        @memset(palette.indices[0..r.valid_start], fill_index);
        @memset(palette.indices[r.valid_end..], fill_index);
        return copy;
    }
    fn tryCompactBytes(r: *Row, start: usize, input: []const u8, pen: Cell) Error!bool {
        const compact = r.storage.compact_ascii orelse return false;
        var attribute = pen;
        attribute.scalar = 0;
        attribute.width = 1; // The ordinary byte writer always emits width one.
        const palette_index = compact.indexFor(attribute) orelse blk: {
            const palette = compact.palette orelse return false;
            if (palette.count == 4) return false;
            break :blk palette.count;
        };
        const end = start + input.len;
        // A gap commits the logical fill into the original backing. Preserve
        // that operation and its mixed attributes through the dense fallback.
        if (r.deferred != null and r.valid_start != r.valid_end and
            (start > r.valid_end or end < r.valid_start)) return false;
        if (r.storage.refs.load(.acquire) != 1) {
            const copy = try r.storage.duplicateCompact();
            r.storage.release();
            r.storage = copy;
        }
        const destination = r.storage.compact_ascii.?;
        if (destination.palette) |palette| {
            if (palette_index == palette.count) {
                palette.extra[palette_index - 1] = attribute;
                palette.count += 1;
            }
            @memset(palette.indices[start..end], palette_index);
        }
        std.mem.copyForwards(u8, destination.bytes[start..end], input);
        if (r.deferred != null) {
            if (r.valid_start == r.valid_end) {
                r.valid_start = start;
                r.valid_end = end;
            } else {
                r.valid_start = @min(r.valid_start, start);
                r.valid_end = @max(r.valid_end, end);
            }
            if (r.valid_start == 0 and r.valid_end == r.columnCount()) {
                r.deferred = null;
                r.deferred_from_fill = false;
            }
        }
        r.revision = stamp();
        return true;
    }
    fn ensureDense(r: *Row) Error!void {
        if (!r.isCompact()) return;
        const dense = try r.storage.duplicate();
        r.storage.release();
        r.storage = dense;
    }
    fn unique(r: *Row) Error!void {
        try r.ensureDense();
        if (r.storage.refs.load(.acquire) == 1) return;
        const copy = try r.storage.duplicate();
        r.storage.release();
        r.storage = copy;
        r.clearUnderlay();
    }
    fn validRange(r: *const Row, start: usize, count: usize) bool {
        return start <= r.columnCount() and count <= r.columnCount() - start;
    }
    pub fn materialize(r: *Row) Error!void {
        try r.ensureDense();
        const cell = r.deferred orelse return;
        try r.unique();
        @memset(r.storage.cells[0..r.valid_start], StoredCell{ .cell = cell });
        @memset(r.storage.cells[r.valid_end..], StoredCell{ .cell = cell });
        r.clearUnderlay();
        r.deferred = null;
        r.deferred_from_fill = false;
        r.valid_start = 0;
        r.valid_end = 0;
        // Deferred rows are admitted only when physical cluster references
        // are all absent. Materialization is not a new logical mutation.
    }
    fn materializeInitial(r: *Row) void {
        if (r.deferred == null or r.deferred_from_fill) return;
        // Initial storage cannot be shared: publication of a deferred row
        // always detaches. Preserve eager backing before dropping its fill or
        // replacing that fill with another deferred operation.
        std.debug.assert(r.storage.refs.load(.acquire) == 1);
        r.materialize() catch unreachable;
    }
    pub fn set(r: *Row, index: usize, cell: Cell, extras: ?[]const u32) Error!void {
        if (index >= r.columnCount() or !validCell(cell)) return error.InvalidInput;
        if (extras) |values| {
            if (values.len > max_extras) return error.InvalidInput;
            // Conservative admission reserves before removing the old cluster.
            if (r.storage.live_extras > max_extras - values.len) return error.InvalidInput;
        }
        try r.materialize();
        try r.unique();
        const s = r.storage;
        if (extras) |values| try s.reserveExtras(values.len);
        s.removeCluster(index);
        var stored = StoredCell{ .cell = cell };
        if (extras) |values| {
            stored.cluster_offset = @intCast(s.extras.items.len);
            stored.cluster_count = @intCast(values.len);
            s.extras.appendSliceAssumeCapacity(values);
            s.live_extras += values.len;
            s.maybe_clusters = true;
        }
        s.cells[index] = stored;
        r.revision = stamp();
    }
    pub fn bytes(r: *Row, start: usize, input: []const u8, pen: Cell) Error!void {
        if (!r.validRange(start, input.len) or !validCell(pen)) return error.InvalidInput;
        if (input.len == 0) return;
        if (try r.tryCompactBytes(start, input, pen)) return;
        const end = start + input.len;
        if (r.deferred != null and r.valid_start != r.valid_end and
            (start > r.valid_end or end < r.valid_start))
        {
            try r.materialize();
        }
        try r.unique();
        r.prepareUnderlayWrite(start, end);
        const s = r.storage;
        if (!s.maybe_clusters) {
            for (input, s.cells[start..][0..input.len]) |byte, *cell| {
                // Preserve the already-absent cluster fields and remove the
                // per-cell live-count dependency from the ordinary write loop.
                cell.cell = pen;
                cell.cell.scalar = byte;
                cell.cell.width = 1;
            }
        } else {
            s.garbage_possible = true;
            for (input, s.cells[start..][0..input.len]) |byte, *cell| {
                s.live_extras -= cell.cluster_count;
                cell.* = .{ .cell = pen };
                cell.cell.scalar = byte;
                cell.cell.width = 1;
            }
            if (start == 0 and input.len == s.cells.len) {
                s.maybe_clusters = false;
                s.clearExtras();
            }
        }
        if (r.deferred != null) {
            if (r.valid_start == r.valid_end) {
                r.valid_start = start;
                r.valid_end = end;
            } else {
                r.valid_start = @min(r.valid_start, start);
                r.valid_end = @max(r.valid_end, end);
            }
            if (r.valid_start == 0 and r.valid_end == s.cells.len) {
                r.clearUnderlay();
                r.deferred = null;
                r.deferred_from_fill = false;
            }
        }
        r.revision = stamp();
    }
    pub fn unicode(r: *Row, start: usize, input: []const Scalar, pen: Cell, stub: Cell) Error!void {
        if (input.len > max_cols or !validCell(pen) or !validCell(stub)) return error.InvalidInput;
        var columns: usize = 0;
        for (input) |value| {
            if (!validScalar(value.scalar) or (value.width != 1 and value.width != 2)) return error.InvalidInput;
            columns += @intCast(value.width);
        }
        if (!r.validRange(start, columns)) return error.InvalidInput;
        if (input.len == 0) return;
        try r.writeValidatedUnicode(start, input, columns, pen, stub);
    }
    // Both callers establish valid scalars, widths, attributes and the complete
    // destination range before entering. The UTF-8 scanner already has those
    // facts, so it need not rescan its temporary scalar array for validation.
    fn writeValidatedUnicode(r: *Row, start: usize, input: []const Scalar, columns: usize, pen: Cell, stub: Cell) Error!void {
        try r.materialize();
        try r.unique();
        const s = r.storage;
        if (s.maybe_clusters) {
            writeUnicodeCells(s, start, input, pen, stub, true);
        } else {
            // Cluster-free rows have no live extras to subtract per column.
            // Preserve their absent fields, as the ASCII writer already does.
            writeUnicodeCells(s, start, input, pen, stub, false);
        }
        if (start == 0 and columns == s.cells.len) {
            s.maybe_clusters = false;
            s.clearExtras();
        }
        r.revision = stamp();
    }
    fn writeUnicodeCells(s: *Storage, start: usize, input: []const Scalar, pen: Cell, stub: Cell, comptime clusters: bool) void {
        var column = start;
        for (input) |value| {
            if (clusters) {
                s.removeCluster(column);
                s.cells[column] = .{ .cell = pen };
            } else s.cells[column].cell = pen;
            s.cells[column].cell.scalar = value.scalar;
            s.cells[column].cell.width = value.width;
            column += 1;
            if (value.width == 2) {
                if (clusters) {
                    s.removeCluster(column);
                    s.cells[column] = .{ .cell = stub };
                } else s.cells[column].cell = stub;
                s.cells[column].cell.scalar = 0;
                s.cells[column].cell.width = 0;
                s.cells[column].cell.link_id = 0;
                column += 1;
            }
        }
    }
    pub fn printUTF8(r: *Row, start: usize, available: usize, input: []const u8, limit: usize, pen: Cell, stub: Cell) Error!PrintResult {
        if (!r.validRange(start, available) or limit == 0 or limit > 65 or
            !validCell(pen) or !validCell(stub)) return error.InvalidInput;
        if (!r.storage.maybe_clusters) {
            return r.printCleanUTF8(start, available, input, limit, pen, stub);
        }
        var result: PrintResult = .{};
        var values: [65]Scalar = undefined;
        while (result.count < limit) {
            const value = decode(input[result.bytes..]) orelse break;
            const width = width_tables.ordinaryWidth(value.scalar);
            if (width != 1 and width != 2) break;
            const columns: usize = @intCast(width);
            if (columns > available - result.columns) break;
            result.final = .{ .scalar = value.scalar, .width = width };
            values[result.count] = result.final;
            result.count += 1;
            result.columns += columns;
            result.bytes += value.bytes;
        }
        if (result.count == 0) return result;
        const displaced = r.logical(start + result.columns - @as(usize, @intCast(result.final.width)));
        result.displaced = displaced.cell;
        result.present = if (displaced.cluster_offset == absent) 0 else 1;
        result.extra_count = displaced.cluster_count;
        if (displaced.cluster_count != 0) {
            const extras = try r.allocator.dupe(u32, r.storage.extras.items[displaced.cluster_offset..][0..displaced.cluster_count]);
            result.extras = extras.ptr;
        }
        errdefer result.release(r.allocator);
        try r.writeValidatedUnicode(start, values[0..result.count], result.columns, pen, stub);
        return result;
    }
    fn printCleanUTF8(r: *Row, start: usize, available: usize, input: []const u8, limit: usize, pen: Cell, stub: Cell) Error!PrintResult {
        var result: PrintResult = .{};
        var value = decode(input) orelse return result;
        var width = width_tables.ordinaryWidth(value.scalar);
        if ((width != 1 and width != 2) or @as(usize, @intCast(width)) > available) return result;
        // No cluster can require a displaced-extras allocation. Complete every
        // fallible detach/materialization before writing the first scalar; the
        // rest of this run has no allocation, callback or intermediate owner.
        try r.materialize();
        try r.unique();
        const s = r.storage;
        while (true) {
            const column = start + result.columns;
            result.count += 1;
            result.columns += @intCast(width);
            result.bytes += value.bytes;
            // Look ahead before overwriting the current lead. Only the final
            // lead is observable in the result; avoid reading every other cell.
            const next = if (result.count < limit) decode(input[result.bytes..]) else null;
            const next_width = if (next) |decoded| width_tables.ordinaryWidth(decoded.scalar) else 0;
            const continues = (next_width == 1 or next_width == 2) and
                @as(usize, @intCast(next_width)) <= available - result.columns;
            if (!continues) result.displaced = s.cells[column].cell;
            s.cells[column].cell = pen;
            s.cells[column].cell.scalar = value.scalar;
            s.cells[column].cell.width = width;
            if (width == 2) {
                s.cells[column + 1].cell = stub;
                s.cells[column + 1].cell.scalar = 0;
                s.cells[column + 1].cell.width = 0;
                s.cells[column + 1].cell.link_id = 0;
            }
            result.final = .{ .scalar = value.scalar, .width = width };
            if (!continues) break;
            value = next.?;
            width = next_width;
        }
        r.revision = stamp();
        return result;
    }
    pub fn fill(r: *Row, start: usize, count: usize, cell: Cell) Error!void {
        if (!r.validRange(start, count) or !validCell(cell)) return error.InvalidInput;
        if (count == 0) return;
        if (start == 0 and count == r.columnCount() and !r.storage.maybe_clusters) {
            r.preserveInitialUnderlay();
            // Logical fill belongs to this handle. Previously cloned handles
            // retain their old contents; the next write detaches shared data.
            r.deferred = cell;
            r.deferred_from_fill = true;
            r.valid_start = 0;
            r.valid_end = 0;
            r.revision = stamp();
            return;
        }
        try r.materialize();
        try r.unique();
        const s = r.storage;
        if (s.maybe_clusters) s.garbage_possible = true;
        for (s.cells[start..][0..count]) |*value| {
            s.live_extras -= value.cluster_count;
            value.* = .{ .cell = cell };
        }
        if (start == 0 and count == s.cells.len) {
            s.clearExtras();
            s.maybe_clusters = false;
        }
        r.revision = stamp();
    }
    pub fn resize(r: *Row, cols: usize, cell: Cell) Error!void {
        if (cols > max_cols or !validCell(cell)) return error.InvalidInput;
        try r.materialize();
        if (cols == r.columnCount()) {
            r.revision = stamp();
            return;
        }
        const copy = try Storage.create(r.allocator, cols, cell);
        errdefer copy.release();
        const count = @min(cols, r.columnCount());
        var live: usize = 0;
        for (r.storage.cells[0..count]) |value| live += value.cluster_count;
        var relocated = std.AutoHashMap(u64, u32).init(r.allocator);
        defer relocated.deinit();
        for (r.storage.cells[0..count], copy.cells[0..count]) |value, *dest| {
            dest.* = value;
            if (value.cluster_offset != absent) {
                copy.maybe_clusters = true;
                if (value.cluster_count == 0) {
                    dest.cluster_offset = 0;
                    continue;
                }
                const key = @as(u64, value.cluster_offset) << 32 | value.cluster_count;
                const slot = try relocated.getOrPut(key);
                if (!slot.found_existing) {
                    slot.value_ptr.* = @intCast(copy.extras.items.len);
                    try copy.extras.appendSlice(r.allocator, r.storage.extras.items[value.cluster_offset..][0..value.cluster_count]);
                }
                dest.cluster_offset = slot.value_ptr.*;
            }
        }
        copy.live_extras = live;
        copy.compacted_extras = copy.extras.items.len;
        r.storage.release();
        r.storage = copy;
        r.clearUnderlay();
        r.revision = stamp();
    }

    pub fn logical(r: *const Row, index: usize) StoredCell {
        if (r.deferred) |cell| {
            if (index < r.valid_start or index >= r.valid_end) return .{ .cell = cell };
        }
        return r.physicalStored(index);
    }
    pub fn resizeValue(r: *Row, cols: usize, cell: Cell, extras: ?[]const u32) Error!void {
        if (extras == null or cols <= r.columnCount()) return r.resize(cols, cell);
        const replacement = try r.clone();
        defer replacement.destroy();
        const old_count = r.columnCount();
        try replacement.resize(cols, cell);
        try replacement.fillValue(old_count, cols - old_count, cell, extras);
        std.mem.swap(*Storage, &r.storage, &replacement.storage);
        r.clearUnderlay();
        r.deferred = null;
        r.deferred_from_fill = false;
        r.valid_start = 0;
        r.valid_end = 0;
        r.revision = stamp();
    }
    pub fn fillValue(r: *Row, start: usize, count: usize, cell: Cell, extras: ?[]const u32) Error!void {
        const values = extras orelse return r.fill(start, count, cell);
        if (!r.validRange(start, count) or !validCell(cell) or values.len > max_extras)
            return error.InvalidInput;
        if (count == 0) return;
        if (values.len != 0 and count > max_extras / values.len) return error.InvalidInput;
        try r.materialize();
        var removed: usize = 0;
        for (r.storage.cells[start..][0..count]) |old| removed += old.cluster_count;
        const added = values.len * count;
        if (r.storage.live_extras - removed > max_extras - added) return error.InvalidInput;
        try r.unique();
        const s = r.storage;
        try s.reserveExtras(values.len);
        const offset: u32 = @intCast(s.extras.items.len);
        s.extras.appendSliceAssumeCapacity(values);
        @memset(s.cells[start..][0..count], StoredCell{
            .cell = cell,
            .cluster_offset = offset,
            .cluster_count = @intCast(values.len),
        });
        s.live_extras = s.live_extras - removed + added;
        if (removed != 0) s.garbage_possible = true;
        s.maybe_clusters = true;
        r.revision = stamp();
    }
    pub fn appendScalar(r: *Row, index: usize, scalar: u32, width: i8) Error!void {
        if (index >= r.columnCount()) return error.InvalidInput;
        try r.materialize();
        try r.unique();
        const s = r.storage;
        const count: usize = s.cells[index].cluster_count;
        if (count >= max_extras) return error.InvalidInput;
        // Appending at the arena tail preserves every existing prefix, even
        // when another cell shares that prefix. Retained rows already detached
        // above. Re-read after reserve because compaction can move a cluster.
        var old = s.cells[index];
        const was_tail = old.cluster_offset != absent and old.cluster_offset + count == s.extras.items.len;
        try s.reserveExtras(if (was_tail) 1 else count + 1);
        old = s.cells[index];
        var is_tail = old.cluster_offset != absent and old.cluster_offset + count == s.extras.items.len;
        if (was_tail and !is_tail) {
            try s.reserveExtras(count + 1);
            old = s.cells[index];
            is_tail = old.cluster_offset != absent and old.cluster_offset + count == s.extras.items.len;
        }
        const offset: u32 = if (is_tail) old.cluster_offset else @intCast(s.extras.items.len);
        if (!is_tail and count != 0) s.extras.appendSliceAssumeCapacity(s.extras.items[old.cluster_offset..][0..count]);
        if (!is_tail and count != 0) s.garbage_possible = true;
        s.extras.appendAssumeCapacity(scalar);
        s.cells[index].cluster_offset = offset;
        s.cells[index].cluster_count = @intCast(count + 1);
        s.cells[index].cell.width = width;
        s.live_extras += 1;
        s.maybe_clusters = true;
        r.revision = stamp();
    }
    pub fn continueCluster(r: *Row, input: cluster_rules.Input) Error!cluster_rules.Result {
        if (!cluster_rules.valid(input) or !validScalar(input.scalar) or
            !validScalar(input.expected_scalar)) return error.InvalidInput;
        const columns = r.columnCount();
        if (input.owner_column >= columns or input.cursor_x >= columns) return .{};
        var lead = input.owner_column;
        var stored = r.logical(lead);
        while (lead > 0 and stored.cell.width == 0) {
            lead -= 1;
            stored = r.logical(lead);
        }
        const old = stored.cell;
        if ((old.width != 1 and old.width != 2) or old.scalar != input.expected_scalar or
            input.cursor_x != lead + @as(usize, @intCast(old.width))) return .{};
        const extras = if (stored.cluster_offset == absent) &.{} else r.storage.extras.items[stored.cluster_offset..][0..stored.cluster_count];
        const decision = cluster_rules.decide(input, old.scalar, old.width, extras);
        if (!decision.handled) return .{};
        var result = cluster_rules.Result{
            .handled = 1,
            .lead_column = lead,
            .cursor_x = input.cursor_x,
            .generation = r.revision,
            .selector_authority = decision.authority,
        };
        if (!decision.append) return result;
        // All potentially failing allocation finishes inside appendScalar
        // before the first logical change. Stub repair and state publication
        // below allocate nothing and cannot invoke caller code.
        try r.appendScalar(lead, input.scalar, decision.width);
        if (decision.width > old.width) {
            var stub = old;
            stub.scalar = 0;
            stub.width = 0;
            r.storage.removeCluster(lead + 1);
            r.storage.cells[lead + 1] = .{ .cell = stub };
        }
        result.cursor_x = lead + @as(usize, @intCast(decision.width));
        result.wrap_pending = @intFromBool(result.cursor_x == columns);
        result.generation = r.revision;
        result.mutated = 1;
        return result;
    }
    pub fn edit(r: *Row, start: usize, count: usize, end: usize, insert: bool, cell: Cell, extras: ?[]const u32) Error!void {
        if (end > r.columnCount() or start > end or count > end - start or !validCell(cell)) return error.InvalidInput;
        if (count == 0) return;
        const values = extras orelse &.{};
        if (values.len > max_extras or (values.len != 0 and count > max_extras / values.len)) return error.InvalidInput;
        try r.materialize();
        // Conservative admission before any content change; Swift compatibility
        // storage handles values exceeding the compact representation.
        if (r.storage.live_extras > max_extras - values.len * count) return error.InvalidInput;
        try r.unique();
        const s = r.storage;
        try s.reserveExtras(values.len);
        const offset: u32 = @intCast(s.extras.items.len);
        s.extras.appendSliceAssumeCapacity(values);
        const blank = StoredCell{ .cell = cell, .cluster_offset = if (extras != null) offset else absent, .cluster_count = @intCast(values.len) };
        if (s.maybe_clusters) s.garbage_possible = true;
        if (insert) {
            std.mem.copyBackwards(StoredCell, s.cells[start + count .. end], s.cells[start .. end - count]);
            @memset(s.cells[start..][0..count], blank);
        } else {
            std.mem.copyForwards(StoredCell, s.cells[start .. end - count], s.cells[start + count .. end]);
            @memset(s.cells[end - count .. end], blank);
        }
        s.recount();
        r.revision = stamp();
    }
    pub fn copyColumns(r: *Row, source: *const Row, start: usize, count: usize) Error!void {
        if (!r.validRange(start, count) or !source.validRange(start, count)) return error.InvalidInput;
        if (count == 0) return;
        const saved = try source.clone();
        defer saved.destroy();
        try saved.materialize();
        var incoming: std.ArrayList(u32) = .empty;
        defer incoming.deinit(r.allocator);
        var relocated = std.AutoHashMap(u64, u32).init(r.allocator);
        defer relocated.deinit();
        var logical_incoming: usize = 0;
        for (saved.storage.cells[start..][0..count]) |cell| {
            logical_incoming += cell.cluster_count;
            if (cell.cluster_count == 0) continue;
            const key = @as(u64, cell.cluster_offset) << 32 | cell.cluster_count;
            const slot = try relocated.getOrPut(key);
            if (!slot.found_existing) {
                slot.value_ptr.* = @intCast(incoming.items.len);
                try incoming.appendSlice(r.allocator, saved.storage.extras.items[cell.cluster_offset..][0..cell.cluster_count]);
            }
        }
        if (logical_incoming > max_extras) return error.InvalidInput;
        try r.materialize();
        var removed: usize = 0;
        for (r.storage.cells[start..][0..count]) |cell| removed += cell.cluster_count;
        if (r.storage.live_extras - removed > max_extras - logical_incoming) return error.InvalidInput;
        try r.unique();
        const s = r.storage;
        try s.reserveExtras(incoming.items.len);
        const base: u32 = @intCast(s.extras.items.len);
        s.extras.appendSliceAssumeCapacity(incoming.items);
        for (saved.storage.cells[start..][0..count], s.cells[start..][0..count]) |cell, *dest| {
            dest.* = cell;
            if (cell.cluster_offset != absent) {
                const key = @as(u64, cell.cluster_offset) << 32 | cell.cluster_count;
                dest.cluster_offset = if (cell.cluster_count == 0) 0 else base + relocated.get(key).?;
                s.maybe_clusters = true;
            }
        }
        s.live_extras = s.live_extras - removed + logical_incoming;
        if (removed != 0) s.garbage_possible = true;
        r.revision = stamp();
    }

    pub const Value = struct {
        cell: Cell = .{},
        // Borrow valid until this row next mutates. Null and present-but-empty
        // remain distinct, matching public Cell.clusterExtras semantics.
        extras: ?[]const u32 = null,
    };
    pub fn columnCount(r: *const Row) usize {
        return if (r.storage.compact_ascii) |compressed| compressed.bytes.len else r.storage.cells.len;
    }
    pub fn readValue(r: *const Row, index: usize) Value {
        if (index >= r.columnCount()) return .{};
        const stored = r.logical(index);
        return .{ .cell = stored.cell, .extras = if (stored.cluster_offset == absent) null else r.storage.extras.items[stored.cluster_offset..][0..stored.cluster_count] };
    }
    pub fn ownsExtras(r: *const Row, extras: []const u32) bool {
        if (extras.len == 0 or r.storage.extras.items.len == 0) return false;
        const address = @intFromPtr(extras.ptr);
        const start = @intFromPtr(r.storage.extras.items.ptr);
        return address >= start and address < start + r.storage.extras.items.len * @sizeOf(u32);
    }
    pub fn usedLength(r: *const Row, include_width: bool) isize {
        var index = r.columnCount();
        while (index > 0) {
            index -= 1;
            const cell = r.logical(index).cell;
            if (cell.scalar != 0) return @as(isize, @intCast(index)) +
                (if (include_width) @as(isize, cell.width) else 1);
        }
        return 0;
    }
    pub fn discardDeferred(r: *Row) void {
        r.materializeInitial();
        if (r.deferred != null) {
            r.restoreInitialUnderlay();
            r.deferred = null;
            r.deferred_from_fill = false;
            r.valid_start = 0;
            r.valid_end = 0;
            r.revision = stamp();
        }
    }
};

fn status(result: Error!void) i32 {
    result catch |err| return if (err == error.OutOfMemory) -2 else -1;
    return 0;
}
fn slice(comptime T: type, pointer: ?[*]const T, count: usize, limit: usize) Error![]const T {
    if (count > limit) return error.InvalidInput;
    if (count == 0) return &.{};
    return (pointer orelse return error.InvalidInput)[0..count];
}
export fn cmdy_zrow_create(cols: usize, fill: ?*const Cell) ?*Row {
    return Row.create(std.heap.c_allocator, cols, (fill orelse return null).*) catch null;
}
export fn cmdy_zrow_create_bytes(bytes: ?[*]const u8, count: usize, cols: usize, pen: ?*const Cell, fill: ?*const Cell) ?*Row {
    const input = slice(u8, bytes, count, max_cols) catch return null;
    return Row.createBytes(std.heap.c_allocator, input, cols, (pen orelse return null).*, (fill orelse return null).*) catch null;
}
const ASCIIRecord = extern struct { offset: usize = 0, count: usize = 0 };
const ASCIISlot = extern struct { row: ?*Row = null, generation: u64 = 0 };
const ascii_batch_limit = 64;

fn planASCII(input: []const u8, cols: usize, records: []ASCIIRecord) usize {
    var offset: usize = 0;
    var count: usize = 0;
    while (offset < input.len and count < records.len) {
        const start = offset;
        while (offset < input.len and input[offset] >= 0x20 and input[offset] <= 0x7e) : (offset += 1) {}
        const length = offset - start;
        if (length == 0 or length > cols or input.len - offset < 2 or
            input[offset] != '\r' or input[offset + 1] != '\n') break;
        records[count] = .{ .offset = start, .count = length };
        count += 1;
        offset += 2;
    }
    return count;
}

fn writeASCIIRows(a: Allocator, input: []const u8, cols: usize, records: []const ASCIIRecord, slots: []ASCIISlot, pen: Cell, fill: Cell) Error!void {
    if (cols > max_cols or records.len == 0 or records.len > ascii_batch_limit or
        records.len != slots.len or !validCell(pen) or !validCell(fill)) return error.InvalidInput;
    // Validate the complete plan before preparing or mutating any row.
    var expected_offset: usize = 0;
    for (records, slots, 0..) |record, slot, index| {
        if (record.offset != expected_offset or record.offset > input.len or record.count == 0 or
            record.count > cols or record.count > input.len - record.offset) return error.InvalidInput;
        const end = record.offset + record.count;
        if (input.len - end < 2 or input[end] != '\r' or input[end + 1] != '\n') return error.InvalidInput;
        for (input[record.offset..end]) |byte| if (byte < 0x20 or byte > 0x7e) return error.InvalidInput;
        expected_offset = end + 2;
        if (slot.row) |row| {
            if (row.columnCount() != cols) return error.InvalidInput;
            for (slots[0..index]) |previous| if (previous.row == row) return error.InvalidInput;
        }
    }
    var prepared: [ascii_batch_limit]?*Row = @splat(null);
    var prepared_compact: [ascii_batch_limit]bool = @splat(false);
    defer for (prepared[0..records.len]) |row| {
        if (row) |value| value.destroy();
    };
    // Full replacement never copies obsolete cluster arenas. Shared rows get
    // freshly populated storage; uniquely owned rows reuse their allocation.
    for (records, slots, 0..) |record, slot, index| {
        if (slot.row != null and slot.row.?.isCompact() and slot.row.?.storage.refs.load(.acquire) == 1) {
            const replacement = try slot.row.?.physicalSnapshot();
            prepared[index] = replacement;
            prepared_compact[index] = true;
            try replacement.materialize();
            for (input[record.offset..][0..record.count], replacement.storage.cells[0..record.count]) |byte, *cell| {
                cell.* = .{ .cell = pen };
                cell.cell.scalar = byte;
                cell.cell.width = 1;
            }
            replacement.deferred = if (record.count == cols) null else fill;
            replacement.deferred_from_fill = replacement.deferred != null;
            replacement.valid_start = 0;
            replacement.valid_end = record.count;
        } else if (slot.row == null or slot.row.?.storage.refs.load(.acquire) != 1) {
            const allocator = if (slot.row) |row| row.allocator else a;
            prepared[index] = try Row.createBytes(allocator, input[record.offset..][0..record.count], cols, pen, fill);
        }
    }
    // Nothing below can fail or call Swift. Publish only after preparation.
    for (records, slots, 0..) |record, *slot, index| {
        if (slot.row) |row| {
            if (prepared[index]) |replacement| {
                std.mem.swap(*Storage, &row.storage, &replacement.storage);
                row.clearUnderlay();
                row.deferred = if (prepared_compact[index]) replacement.deferred else null;
                row.deferred_from_fill = prepared_compact[index] and replacement.deferred_from_fill;
                row.valid_start = if (prepared_compact[index]) replacement.valid_start else 0;
                row.valid_end = if (prepared_compact[index]) replacement.valid_end else 0;
            } else {
                if (record.count < cols) {
                    // All fallible preparation has finished. Restore I/U,
                    // not F/V, so a later discard sees the original backing.
                    row.restoreInitialUnderlay();
                    row.materializeInitial();
                } else row.clearUnderlay();
                const storage = row.storage;
                if (storage.maybe_clusters) {
                    @memset(storage.cells[record.count..], StoredCell{ .cell = fill });
                    storage.clearExtras();
                    storage.live_extras = 0;
                    storage.maybe_clusters = false;
                    row.deferred = null;
                    row.deferred_from_fill = false;
                    row.valid_start = 0;
                    row.valid_end = 0;
                } else {
                    row.deferred = if (record.count == cols) null else fill;
                    row.deferred_from_fill = row.deferred != null;
                    row.valid_start = 0;
                    row.valid_end = record.count;
                }
                for (input[record.offset..][0..record.count], storage.cells[0..record.count]) |byte, *cell| {
                    cell.* = .{ .cell = pen };
                    cell.cell.scalar = byte;
                    cell.cell.width = 1;
                }
            }
            row.revision = stamp();
        } else {
            slot.row = prepared[index].?;
            prepared[index] = null;
        }
        slot.generation = slot.row.?.revision;
    }
}

export fn cmdy_zascii_plan(bytes: ?[*]const u8, count: usize, cols: usize, records: ?[*]ASCIIRecord, capacity: usize) usize {
    if (capacity > ascii_batch_limit or cols > max_cols or count == 0 or capacity == 0) return 0;
    return planASCII((bytes orelse return 0)[0..count], cols, (records orelse return 0)[0..capacity]);
}
export fn cmdy_zascii_write_rows(bytes: ?[*]const u8, count: usize, cols: usize, records: ?[*]const ASCIIRecord, slots: ?[*]ASCIISlot, rows: usize, pen: ?*const Cell, fill: ?*const Cell) i32 {
    if (rows == 0 or rows > ascii_batch_limit) return -1;
    return status(writeASCIIRows(std.heap.c_allocator, (bytes orelse return -1)[0..count], cols, (records orelse return -1)[0..rows], (slots orelse return -1)[0..rows], (pen orelse return -1).*, (fill orelse return -1).*));
}

test "ASCII plans stop at incomplete invalid empty and over-wide records" {
    var records: [64]ASCIIRecord = undefined;
    const good = "a\r\nbcd\r\nZ\r\n";
    try std.testing.expectEqual(@as(usize, 3), planASCII(good, 3, &records));
    try std.testing.expectEqual(ASCIIRecord{ .offset = 8, .count = 1 }, records[2]);
    try std.testing.expectEqual(@as(usize, 1), planASCII(good, 2, &records));
    try std.testing.expectEqual(@as(usize, 2), planASCII(good, 3, records[0..2]));
    for ([_][]const u8{ "x", "x\r", "x\n", "\r\n", "x\x7f\r\n", "\xc3\xa9\r\n" }) |bad| {
        try std.testing.expectEqual(@as(usize, 0), planASCII(bad, 10, &records));
    }
}

fn asciiBatchAllocationTrace(a: Allocator) !void {
    const unique = try Row.create(a, 7, .{ .scalar = 'U' });
    defer unique.destroy();
    try unique.set(1, .{ .scalar = 'e' }, &.{0x301});
    const shared = try Row.create(a, 7, .{ .scalar = 'S' });
    defer shared.destroy();
    const snapshot = try shared.clone();
    defer snapshot.destroy();
    var slots = [_]ASCIISlot{ .{ .row = unique }, .{ .row = shared }, .{} };
    defer if (slots[2].row) |row| row.destroy();
    const unique_revision = unique.revision;
    const shared_revision = shared.revision;
    var records: [3]ASCIIRecord = undefined;
    const input = "ab\r\nc\r\ndef\r\n";
    _ = planASCII(input, 7, &records);
    writeASCIIRows(a, input, 7, &records, &slots, .{ .fg = 0x01000003, .link_id = 17 }, .{ .bg = 0x01000004 }) catch |err| {
        try std.testing.expectEqual(unique_revision, unique.revision);
        try std.testing.expectEqual(shared_revision, shared.revision);
        try std.testing.expectEqual(@as(u32, 'U'), unique.storage.cells[0].cell.scalar);
        try std.testing.expectEqual(@as(u32, 0x301), unique.storage.extras.items[0]);
        try std.testing.expectEqual(@as(u32, 'S'), shared.storage.cells[0].cell.scalar);
        try std.testing.expectEqual(@as(?*Row, null), slots[2].row);
        try std.testing.expectEqual(@as(u64, 0), slots[0].generation);
        return err;
    };
    try std.testing.expect(slots[0].row == unique and slots[1].row == shared);
    try std.testing.expectEqual(@as(u32, 'S'), snapshot.storage.cells[0].cell.scalar);
    for (slots, records) |slot, record| {
        const row = slot.row.?;
        try row.materialize();
        try std.testing.expectEqual(slot.generation, row.revision);
        try std.testing.expect(!row.storage.maybe_clusters);
        try std.testing.expectEqual(@as(usize, 0), row.storage.live_extras);
        for (row.storage.cells, 0..) |cell, col| {
            try std.testing.expectEqual(absent, cell.cluster_offset);
            if (col < record.count) {
                try std.testing.expectEqual(@as(u32, input[record.offset + col]), cell.cell.scalar);
                try std.testing.expectEqual(@as(u16, 17), cell.cell.link_id);
            } else {
                try std.testing.expectEqual(@as(u32, 0), cell.cell.scalar);
                try std.testing.expectEqual(@as(u32, 0x01000004), cell.cell.bg);
            }
        }
    }
}
test "ASCII row batches preserve snapshots and all allocation failure boundaries" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, asciiBatchAllocationTrace, .{});
}
test "invalid ASCII row plans and aliased handles do not partially mutate" {
    const row = try Row.create(std.testing.allocator, 4, .{ .scalar = 'Z' });
    defer row.destroy();
    const revision = row.revision;
    var records = [_]ASCIIRecord{ .{ .offset = 0, .count = 1 }, .{ .offset = 3, .count = 1 } };
    var slots = [_]ASCIISlot{ .{ .row = row }, .{ .row = row } };
    try std.testing.expectError(error.InvalidInput, writeASCIIRows(std.testing.allocator, "a\r\nb\r\n", 4, &records, &slots, .{}, .{}));
    slots[1].row = null;
    records[1].count = 7;
    try std.testing.expectError(error.InvalidInput, writeASCIIRows(std.testing.allocator, "a\r\nb\r\n", 4, &records, &slots, .{}, .{}));
    try std.testing.expectEqual(revision, row.revision);
    try std.testing.expectEqual(@as(u32, 'Z'), row.storage.cells[0].cell.scalar);
    try std.testing.expectEqual(@as(?*Row, null), slots[1].row);
}
export fn cmdy_zunicode_width(scalar: u32) i8 {
    return width_tables.width(scalar);
}
export fn cmdy_zpen_apply_sgr(pen: ?*Cell, values: ?[*]const isize, count: usize) i32 {
    const pointer = pen orelse return -1;
    if (!validCell(pointer.*)) return -1;
    const input = slice(isize, values, count, std.math.maxInt(usize) / @sizeOf(isize)) catch return -1;
    var value = pointer.*;
    @import("sgr.zig").apply(&value, input);
    pointer.* = value;
    return 0;
}
export fn cmdy_zrow_print_utf8(row: ?*Row, start: usize, available: usize, bytes: ?[*]const u8, count: usize, limit: usize, pen: ?*const Cell, stub: ?*const Cell, result: ?*PrintResult) i32 {
    const out = result orelse return -1;
    out.* = .{};
    const r = row orelse return -1;
    const input = slice(u8, bytes, count, max_cols) catch return -1;
    out.* = r.printUTF8(start, available, input, limit, (pen orelse return -1).*, (stub orelse return -1).*) catch |err| return status(err);
    return 0;
}
export fn cmdy_zprint_release(result: ?*PrintResult) void {
    if (result) |out| out.release(std.heap.c_allocator);
}
export fn cmdy_zrow_clone(row: ?*const Row) ?*Row {
    return (row orelse return null).clone() catch null;
}
export fn cmdy_zrow_free(row: ?*Row) void {
    if (row) |r| r.destroy();
}
export fn cmdy_zrow_count(row: ?*const Row) usize {
    return (row orelse return 0).columnCount();
}
export fn cmdy_zrow_generation(row: ?*const Row) u64 {
    return (row orelse return 0).revision;
}
export fn cmdy_zrow_prepare_read(row: ?*Row) i32 {
    return status((row orelse return -1).materialize());
}
export fn cmdy_zrow_allocated_bytes(row: ?*const Row) usize {
    const r = row orelse return 0;
    const row_bytes: usize = if (r.underlay_flags & allocated_underlay != 0) @sizeOf(InitialRowAllocation) else @sizeOf(Row);
    return row_bytes + r.storage.allocationBytes() + r.storage.extras.capacity * @sizeOf(u32);
}
export fn cmdy_zrow_cells(row: ?*const Row, count: ?*usize) ?[*]const StoredCell {
    const out = count orelse return null;
    out.* = 0;
    const r = row orelse return null;
    // Borrowing an unprepared deferred row must never expose stale cells.
    if (r.deferred != null or r.isCompact()) return null;
    out.* = r.columnCount();
    return if (out.* == 0) null else r.storage.cells.ptr;
}
export fn cmdy_zrow_extras(row: ?*const Row, count: ?*usize) ?[*]const u32 {
    const out = count orelse return null;
    out.* = 0;
    const r = row orelse return null;
    out.* = r.storage.extras.items.len;
    return if (out.* == 0) null else r.storage.extras.items.ptr;
}
export fn cmdy_zrow_set(row: ?*Row, col: usize, cell: ?*const Cell, extra: ?[*]const u32, count: usize, present: u8) i32 {
    if (present > 1 or (present == 0 and count != 0)) return -1;
    const values = slice(u32, extra, count, max_extras) catch return -1;
    return status((row orelse return -1).set(col, (cell orelse return -1).*, if (present == 1) values else null));
}
export fn cmdy_zrow_write_bytes(row: ?*Row, col: usize, bytes: ?[*]const u8, count: usize, pen: ?*const Cell) i32 {
    const input = slice(u8, bytes, count, max_cols) catch return -1;
    return status((row orelse return -1).bytes(col, input, (pen orelse return -1).*));
}
export fn cmdy_zrow_write_unicode(row: ?*Row, col: usize, values: ?[*]const Scalar, count: usize, pen: ?*const Cell, stub: ?*const Cell) i32 {
    const input = slice(Scalar, values, count, max_cols) catch return -1;
    return status((row orelse return -1).unicode(col, input, (pen orelse return -1).*, (stub orelse return -1).*));
}
export fn cmdy_zrow_fill(row: ?*Row, start: usize, count: usize, cell: ?*const Cell) i32 {
    return status((row orelse return -1).fill(start, count, (cell orelse return -1).*));
}
export fn cmdy_zrow_resize(row: ?*Row, cols: usize, cell: ?*const Cell) i32 {
    return status((row orelse return -1).resize(cols, (cell orelse return -1).*));
}
export fn cmdy_zrow_next_generation() u64 {
    return stamp();
}
export fn cmdy_zrow_discard_deferred(row: ?*Row) void {
    if (row) |r| r.discardDeferred();
}
export fn cmdy_zrow_geometry(row: ?*const Row, col: usize) Scalar {
    const r = row orelse return .{ .scalar = 0, .width = 1 };
    if (col >= r.columnCount()) return .{ .scalar = 0, .width = 1 };
    const cell = r.logical(col).cell;
    return .{ .scalar = cell.scalar, .width = cell.width };
}
export fn cmdy_zrow_read(row: ?*const Row, col: usize, cell: ?*Cell, extra: ?*?[*]const u32, count: ?*usize, present: ?*u8) i32 {
    const r = row orelse return -1;
    if (col >= r.columnCount() or cell == null or extra == null or count == null or present == null) return -1;
    const stored = r.logical(col);
    cell.?.* = stored.cell;
    count.?.* = stored.cluster_count;
    present.?.* = if (stored.cluster_offset == absent) 0 else 1;
    extra.?.* = if (stored.cluster_count == 0) null else r.storage.extras.items.ptr + stored.cluster_offset;
    return 0;
}
export fn cmdy_zrow_append_scalar(row: ?*Row, col: usize, scalar: u32, width: i8) i32 {
    return status((row orelse return -1).appendScalar(col, scalar, width));
}
export fn cmdy_zrow_continue_cluster(row: ?*Row, input: ?*const cluster_rules.Input, result: ?*cluster_rules.Result) i32 {
    const out = result orelse return -1;
    out.* = .{};
    const r = row orelse return -1;
    var facts = (input orelse return -1).*;
    facts.lead_is_vs16_base = @intFromBool(width_tables.isVS16Base(facts.expected_scalar));
    facts.scalar_is_vs16_base = @intFromBool(width_tables.isVS16Base(facts.scalar));
    out.* = r.continueCluster(facts) catch |err| return switch (err) {
        error.InvalidInput => -1,
        error.OutOfMemory => -2,
    };
    return 0;
}
export fn cmdy_zrow_fill_value(row: ?*Row, start: usize, count: usize, cell: ?*const Cell, extra: ?[*]const u32, extra_count: usize, present: u8) i32 {
    if (present > 1 or (present == 0 and extra_count != 0)) return -1;
    const values = slice(u32, extra, extra_count, max_extras) catch return -1;
    return status((row orelse return -1).fillValue(start, count, (cell orelse return -1).*, if (present == 1) values else null));
}
export fn cmdy_zrow_resize_value(row: ?*Row, cols: usize, cell: ?*const Cell, extra: ?[*]const u32, extra_count: usize, present: u8) i32 {
    if (present > 1 or (present == 0 and extra_count != 0)) return -1;
    const values = slice(u32, extra, extra_count, max_extras) catch return -1;
    return status((row orelse return -1).resizeValue(cols, (cell orelse return -1).*, if (present == 1) values else null));
}
export fn cmdy_zrow_edit(row: ?*Row, start: usize, count: usize, end: usize, insert: u8, cell: ?*const Cell, extra: ?[*]const u32, extra_count: usize, present: u8) i32 {
    if (insert > 1 or present > 1 or (present == 0 and extra_count != 0)) return -1;
    const values = slice(u32, extra, extra_count, max_extras) catch return -1;
    return status((row orelse return -1).edit(start, count, end, insert == 1, (cell orelse return -1).*, if (present == 1) values else null));
}
export fn cmdy_zrow_copy_columns(row: ?*Row, source: ?*const Row, start: usize, count: usize) i32 {
    return status((row orelse return -1).copyColumns(source orelse return -1, start, count));
}
export fn cmdy_zrow_used_length(row: ?*const Row, include_width: u8) isize {
    const r = row orelse return 0;
    var index = r.columnCount();
    while (index > 0) {
        index -= 1;
        const cell = r.logical(index).cell;
        if (cell.scalar != 0) return @as(isize, @intCast(index)) + (if (include_width == 1) @as(isize, cell.width) else 1);
    }
    return 0;
}

test "C layout is explicit and plain data" {
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Cell));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(StoredCell));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Scalar));
    try std.testing.expectEqual(@as(usize, 18), @offsetOf(Cell, "width"));
}
test "retained storage survives mutation and original destruction" {
    const r = try Row.create(std.testing.allocator, 4, .{});
    const saved = try r.clone();
    defer saved.destroy();
    try r.set(0, .{ .scalar = 0x1f9d1, .width = 2 }, &.{ 0x200d, 0x1f33e });
    try std.testing.expectEqual(@as(u32, 0), saved.storage.cells[0].cell.scalar);
    const cluster = try r.clone();
    defer cluster.destroy();
    try r.bytes(0, "abcd", .{ .fg = 0x02010203 });
    r.destroy();
    try std.testing.expectEqualSlices(u32, &.{ 0x200d, 0x1f33e }, cluster.storage.extras.items);
    try std.testing.expectEqual(@as(u32, 0x1f9d1), cluster.storage.cells[0].cell.scalar);
}
test "cluster churn compacts and preserves nil versus empty" {
    const r = try Row.create(std.testing.allocator, 8, .{});
    defer r.destroy();
    for (0..10000) |_| try r.set(0, .{ .scalar = 65 }, &.{ 0x301, 0x302 });
    try std.testing.expect(r.storage.extras.capacity < 256);
    try r.set(1, .{ .scalar = 66 }, &.{});
    try std.testing.expect(r.storage.cells[1].cluster_offset != absent);
    try r.resize(16, .{});
    try std.testing.expect(r.storage.cells[1].cluster_offset != absent);
    try std.testing.expectEqual(@as(u32, 0), r.storage.cells[1].cluster_count);
    try std.testing.expectEqual(absent, r.storage.cells[2].cluster_offset);
}
test "invalid calls do not alter contents or generation" {
    const r = try Row.create(std.testing.allocator, 4, .{});
    defer r.destroy();
    const old = r.revision;
    try std.testing.expectError(error.InvalidInput, r.bytes(4, "a", .{}));
    try std.testing.expectError(error.InvalidInput, r.fill(std.math.maxInt(usize), 2, .{}));
    try std.testing.expectError(error.InvalidInput, r.set(0, .{ .reserved = .{ 1, 0 } }, null));
    try std.testing.expectError(error.InvalidInput, r.set(0, .{ .underline_kind = 255 }, null));
    try std.testing.expectError(error.InvalidInput, r.set(0, .{ .fg = 0xff000000 }, null));
    try std.testing.expectError(error.InvalidInput, r.unicode(0, &.{.{ .scalar = 0x4e00, .width = 3 }}, .{}, .{}));
    try std.testing.expectError(error.InvalidInput, r.resize(max_cols + 1, .{}));
    try std.testing.expectEqual(old, r.revision);
    try std.testing.expectEqual(@as(i32, -1), cmdy_zrow_write_bytes(r, 0, null, 1, &.{}));
    try std.testing.expectEqual(@as(i32, -1), cmdy_zrow_set(r, 0, &.{}, null, 0, 2));
    cmdy_zrow_free(null);
}
fn readAndRelease(row: *Row) void {
    defer row.destroy();
    for (0..10000) |_| {
        std.testing.expectEqual(@as(u32, 65), row.storage.cells[0].cell.scalar) catch @panic("snapshot changed");
        std.testing.expectEqual(@as(u32, 0x301), row.storage.extras.items[0]) catch @panic("cluster changed");
    }
}
test "immutable handles support concurrent reads and release" {
    const row = try Row.create(std.testing.allocator, 120, .{});
    defer row.destroy();
    try row.set(0, .{ .scalar = 65 }, &.{0x301});
    const saved = try row.clone();
    const worker = std.Thread.spawn(.{}, readAndRelease, .{saved}) catch |err| {
        saved.destroy();
        return err;
    };
    defer worker.join();
    for (0..1000) |_| try row.set(0, .{ .scalar = 66 }, &.{0x302});
}
test "wide stubs have their own attributes and no link" {
    const r = try Row.create(std.testing.allocator, 3, .{});
    defer r.destroy();
    try r.unicode(1, &.{.{ .scalar = 0x4e00, .width = 2 }}, .{ .fg = 0x02010203, .link_id = 17 }, .{ .bg = 0x02040506, .link_id = 19 });
    try std.testing.expectEqual(@as(i8, 2), r.storage.cells[1].cell.width);
    try std.testing.expectEqual(@as(i8, 0), r.storage.cells[2].cell.width);
    try std.testing.expectEqual(@as(u32, 0x02040506), r.storage.cells[2].cell.bg);
    try std.testing.expectEqual(@as(u16, 0), r.storage.cells[2].cell.link_id);
}
fn allocationTrace(a: Allocator) !void {
    const r = try Row.create(a, 8, .{});
    defer r.destroy();
    try r.set(0, .{ .scalar = 65 }, &.{ 0x301, 0x302 });
    const saved = try r.clone();
    defer saved.destroy();
    const revision = r.revision;
    r.set(0, .{ .scalar = 66 }, &.{0x303}) catch |err| {
        try std.testing.expectEqual(revision, r.revision);
        try std.testing.expectEqual(@as(u32, 65), r.storage.cells[0].cell.scalar);
        return err;
    };
    try std.testing.expectEqual(@as(u32, 65), saved.storage.cells[0].cell.scalar);
    try r.resize(16, .{});
    for (0..80) |_| try r.set(0, .{ .scalar = 67 }, &.{ 0x304, 0x305 });
    try r.resize(0, .{});
}
test "every allocation failure releases ownership and preserves failed mutation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationTrace, .{});
}
test "deferred spans, gaps, snapshots and read preparation preserve values" {
    const r = try Row.create(std.testing.allocator, 8, .{ .scalar = 90 });
    defer r.destroy();
    const before = try r.clone();
    defer before.destroy();
    try r.fill(0, 8, .{ .bg = 0x02010203 });
    try r.bytes(2, "ab", .{});
    try r.bytes(4, "cd", .{});
    const during = try r.clone();
    defer during.destroy();
    try r.bytes(7, "X", .{}); // Disjoint island requires materialization.
    const revision = r.revision;
    try r.materialize();
    try std.testing.expectEqual(revision, r.revision);
    try std.testing.expectEqual(@as(u32, 0), r.storage.cells[0].cell.scalar);
    try std.testing.expectEqual(@as(u32, 97), r.storage.cells[2].cell.scalar);
    try std.testing.expectEqual(@as(u32, 88), r.storage.cells[7].cell.scalar);
    try std.testing.expectEqual(@as(u32, 0), during.storage.cells[7].cell.scalar);
    try std.testing.expectEqual(@as(u32, 90), before.storage.cells[2].cell.scalar);
    try r.fill(0, 8, .{});
    var count: usize = 99;
    try std.testing.expect(cmdy_zrow_cells(r, &count) == null);
    try std.testing.expectEqual(@as(usize, 0), count);
    try std.testing.expectEqual(@as(i32, 0), cmdy_zrow_prepare_read(r));
    try std.testing.expect(cmdy_zrow_cells(r, &count) != null);
}
test "present empty clusters cannot enter the absent-cluster fast path" {
    const r = try Row.create(std.testing.allocator, 4, .{});
    defer r.destroy();
    try r.set(0, .{ .scalar = 65 }, &.{});
    try std.testing.expect(r.storage.maybe_clusters);
    try r.bytes(0, "B", .{});
    try std.testing.expectEqual(absent, r.storage.cells[0].cluster_offset);
    try r.fill(0, 4, .{});
    try std.testing.expect(!r.storage.maybe_clusters);
}
fn deferredAllocationTrace(a: Allocator) !void {
    const r = try Row.create(a, 8, .{ .scalar = 65 });
    defer r.destroy();
    const old = try r.clone();
    defer old.destroy();
    try r.fill(0, 8, .{ .scalar = 66 });
    const saved = try r.clone();
    defer saved.destroy();
    const revision = r.revision;
    r.materialize() catch |err| {
        try std.testing.expectEqual(revision, r.revision);
        try std.testing.expectEqual(@as(u32, 66), r.deferred.?.scalar);
        return err;
    };
    try std.testing.expectEqual(@as(u32, 65), old.storage.cells[0].cell.scalar);
    try std.testing.expectEqual(@as(u32, 66), saved.storage.cells[0].cell.scalar);
}
test "deferred allocation failures keep logical values and snapshots" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, deferredAllocationTrace, .{});
}

test "snapshot publication preserves every deferred span and complete cell attributes" {
    const blank: Cell = .{ .scalar = 0, .fg = 0x02010203, .bg = 0x01000004, .underline_color = 0x02040506, .link_id = 73, .width = -7, .style = 0xff, .underline_kind = 3, .underline_present = 1 };
    const pen: Cell = .{ .fg = 0x01000002, .bg = 0x02070809, .link_id = 41, .style = 5 };
    const spans = [_]struct { start: usize, bytes: []const u8 }{
        .{ .start = 0, .bytes = "" },         .{ .start = 0, .bytes = "AB" },
        .{ .start = 2, .bytes = "CDE" },      .{ .start = 6, .bytes = "FG" },
        .{ .start = 0, .bytes = "HIJKLMNO" },
    };
    for (spans) |span| {
        const row = try Row.create(std.testing.allocator, 8, .{ .scalar = 'Z' });
        defer row.destroy();
        try row.materialize();
        const before = try row.snapshot();
        defer before.destroy();
        try row.fill(0, 8, blank);
        try row.bytes(span.start, span.bytes, pen);
        var expected: [8]StoredCell = undefined;
        for (&expected, 0..) |*cell, column| cell.* = row.logical(column);
        const revision = row.revision;
        const owner_storage = row.storage;
        const owner_fill = row.deferred;
        const sequence = generation.load(.monotonic);
        const saved = try row.snapshot();
        defer saved.destroy();
        try std.testing.expectEqual(sequence, generation.load(.monotonic));
        try std.testing.expectEqual(revision, saved.revision);
        try std.testing.expectEqual(revision, row.revision);
        try std.testing.expectEqual(owner_storage, row.storage);
        try std.testing.expectEqualDeep(owner_fill, row.deferred);
        try std.testing.expect(saved.deferred == null);
        for (expected, saved.storage.cells, 0..) |value, actual, column| {
            try std.testing.expectEqualDeep(value, actual);
            try std.testing.expectEqual(@as(u32, 'Z'), before.logical(column).cell.scalar);
        }
        // Follow publication with a disjoint write, a cluster, and a full fill.
        try row.bytes(7, "X", .{});
        try row.set(0, .{ .scalar = 'e' }, &.{0x301});
        try row.fill(0, 8, .{ .scalar = 'Q' });
        for (expected, saved.storage.cells) |value, actual| try std.testing.expectEqualDeep(value, actual);
    }
    const empty = try Row.create(std.testing.allocator, 0, blank);
    defer empty.destroy();
    const saved_empty = try empty.snapshot();
    defer saved_empty.destroy();
    try std.testing.expectEqual(@as(usize, 0), saved_empty.columnCount());
    try std.testing.expectEqual(empty.revision, saved_empty.revision);
}

fn snapshotPublicationAllocationTrace(a: Allocator) !void {
    const row = try Row.create(a, 8, .{ .scalar = 'Z' });
    defer row.destroy();
    try row.materialize();
    const before = try row.snapshot();
    defer before.destroy();
    try row.fill(0, 8, .{ .bg = 0x01000004, .link_id = 17 });
    try row.bytes(2, "BC", .{ .fg = 0x02010203 });
    var expected: [8]StoredCell = undefined;
    for (&expected, 0..) |*cell, column| cell.* = row.logical(column);
    const revision = row.revision;
    const storage = row.storage;
    const saved = row.snapshot() catch |err| {
        try std.testing.expectEqual(revision, row.revision);
        try std.testing.expectEqual(storage, row.storage);
        try std.testing.expectEqual(@as(usize, 2), row.valid_start);
        try std.testing.expectEqual(@as(usize, 4), row.valid_end);
        for (expected, 0..) |value, column| {
            try std.testing.expectEqualDeep(value, row.logical(column));
            try std.testing.expectEqual(@as(u32, 'Z'), before.logical(column).cell.scalar);
        }
        return err;
    };
    defer saved.destroy();
    try row.bytes(7, "X", .{});
    for (expected, saved.storage.cells) |value, actual| try std.testing.expectEqualDeep(value, actual);
}

test "snapshot publication allocation failures preserve deferred owners and retained storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, snapshotPublicationAllocationTrace, .{});
}

test "snapshot publication preserves allocator reentry fill span backing and revision read order" {
    const Mutation = struct {
        child: Allocator,
        owner: ?*Row = null,
        mode: enum { extend, refill, detach },
        trigger_bytes: usize,
        armed: bool = false,
        changes: usize = 0,
        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const result = self.child.rawAlloc(len, alignment, address);
            if (result != null and self.armed and len == self.trigger_bytes) {
                self.armed = false;
                self.changes += 1;
                const row = self.owner.?;
                switch (self.mode) {
                    .extend => row.bytes(4, "D", .{}) catch @panic("extend failed"),
                    .refill => {
                        row.fill(0, 8, .{ .bg = 0x01000007 }) catch @panic("refill failed");
                        row.bytes(5, "E", .{}) catch @panic("refill write failed");
                    },
                    .detach => row.bytes(2, "BC", .{}) catch @panic("detach failed"),
                }
            }
            return result;
        }
        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.child.rawResize(memory, alignment, len, address);
        }
        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.child.rawRemap(memory, alignment, len, address);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.child.rawFree(memory, alignment, address);
        }
    };
    for ([_]@FieldType(Mutation, "mode"){ .extend, .refill, .detach }) |mode| {
        for ([_]usize{ storage_header_bytes + 8 * @sizeOf(StoredCell), @sizeOf(Row) }) |trigger| {
            var mutation = Mutation{ .child = std.testing.allocator, .mode = mode, .trigger_bytes = trigger };
            const row = try Row.create(mutation.allocator(), 8, .{ .scalar = 'Z' });
            defer row.destroy();
            try row.materialize();
            const before = try row.snapshot();
            defer before.destroy();
            try row.fill(0, 8, .{ .bg = 0x01000004 });
            if (mode != .detach) try row.bytes(2, "BC", .{});
            mutation.owner = row;
            mutation.armed = true;
            const saved = try row.snapshot();
            defer saved.destroy();
            try std.testing.expectEqual(@as(usize, 1), mutation.changes);
            try std.testing.expectEqual(row.revision, saved.revision);
            for (0..8) |column| {
                var expected: Cell = .{ .bg = 0x01000004 };
                if (mode == .refill) {
                    if (column == 5) expected = .{ .scalar = 'E' };
                } else if (column == 2 or column == 3 or (mode == .extend and column == 4)) {
                    expected = .{ .scalar = @as(u32, @intCast(column)) + 'B' - 2 };
                }
                try std.testing.expectEqualDeep(StoredCell{ .cell = expected }, saved.logical(column));
                try std.testing.expectEqual(@as(u32, 'Z'), before.logical(column).cell.scalar);
            }
            if (mode == .refill) try std.testing.expectEqual(@as(u32, 0x01000007), row.logical(0).cell.bg);
            if (mode == .detach) try std.testing.expect(row.storage != before.storage);
        }
    }
}

fn expectRowValuesEqual(actual: *const Row, expected: *const Row) !void {
    try std.testing.expectEqual(expected.columnCount(), actual.columnCount());
    for (0..actual.columnCount()) |column| {
        const a = actual.readValue(column);
        const e = expected.readValue(column);
        try std.testing.expectEqualDeep(e.cell, a.cell);
        try std.testing.expectEqual(e.extras == null, a.extras == null);
        if (e.extras) |values| try std.testing.expectEqualSlices(u32, values, a.extras.?);
    }
    try std.testing.expectEqual(expected.usedLength(false), actual.usedLength(false));
    try std.testing.expectEqual(expected.usedLength(true), actual.usedLength(true));
}

test "fresh row values match eager storage through every mutation and publication path" {
    const blank: Cell = .{ .scalar = 'Z', .fg = 0x02010203, .bg = 0x01000004, .underline_color = 0x02040506, .link_id = 73, .width = 1, .style = 0xff, .underline_kind = 3, .underline_present = 1 };
    const pen: Cell = .{ .fg = 0x01000002, .bg = 0x02070809, .link_id = 41, .style = 5 };
    const Mode = enum { read, bytes, full_bytes, unicode, utf8, fill, empty_cluster, cluster, resize, insert, delete, copy };
    for (std.enums.values(Mode)) |mode| {
        for ([_]bool{ false, true }) |retain| {
            const actual = try Row.create(std.testing.allocator, 8, blank);
            defer actual.destroy();
            // createBytes remains eager and independently fills the whole tail.
            const expected = try Row.createBytes(std.testing.allocator, "", 8, .{}, blank);
            defer expected.destroy();
            try expectRowValuesEqual(actual, expected);
            for (actual.storage.cells) |cell| {
                try std.testing.expectEqual(absent, cell.cluster_offset);
                try std.testing.expectEqual(@as(u32, 0), cell.cluster_count);
            }
            var count: usize = 99;
            const exposed = cmdy_zrow_cells(actual, &count);
            if (actual.deferred != null) {
                try std.testing.expect(exposed == null);
                try std.testing.expectEqual(@as(usize, 0), count);
            }
            const actual_before = if (retain) try actual.snapshot() else null;
            defer if (actual_before) |row| row.destroy();
            const expected_before = if (retain) try expected.snapshot() else null;
            defer if (expected_before) |row| row.destroy();
            for ([_]*Row{ actual, expected }) |row| {
                switch (mode) {
                    .read => {},
                    .bytes => {
                        try row.bytes(2, "BC", pen);
                        try row.bytes(4, "D", pen);
                        try row.bytes(7, "X", pen);
                    },
                    .full_bytes => {
                        // Metadata-only reset permits publication after a full
                        // overwrite. The cluster fields must survive this path.
                        row.discardDeferred();
                        try row.bytes(0, "12345678", pen);
                    },
                    .unicode => try row.unicode(2, &.{ .{ .scalar = 0x3b1, .width = 1 }, .{ .scalar = 0x754c, .width = 2 } }, pen, .{ .bg = 0x03000000, .width = 0 }),
                    .utf8 => {
                        var result = try row.printUTF8(2, 6, "α界B", 65, pen, .{ .bg = 0x03000000, .width = 0 });
                        defer result.release(std.testing.allocator);
                        try std.testing.expectEqualDeep(blank, result.displaced);
                        try std.testing.expectEqual(@as(u8, 0), result.present);
                    },
                    .fill => {
                        try row.fill(2, 3, .{ .scalar = 'F', .bg = 0x01000007 });
                        try row.fill(0, 8, .{ .bg = 0x020a0b0c });
                        try row.bytes(4, "GH", pen);
                    },
                    .empty_cluster => {
                        try row.set(1, .{ .scalar = 'E' }, &.{});
                        try row.fillValue(4, 2, .{ .scalar = 'F' }, &.{});
                        try row.bytes(1, "B", pen);
                    },
                    .cluster => {
                        try row.appendScalar(1, 0x301, 1);
                        try row.fillValue(4, 2, .{ .scalar = 'e' }, &.{ 0x301, 0x302 });
                        try row.appendScalar(4, 0x303, 1);
                    },
                    .resize => {
                        try row.resize(3, .{});
                        try row.resizeValue(10, .{ .scalar = 'R', .bg = 0x01000007 }, &.{0x301});
                    },
                    .insert => try row.edit(1, 2, 7, true, .{ .scalar = 'I' }, &.{0x301}),
                    .delete => try row.edit(1, 2, 7, false, .{ .scalar = 'D' }, &.{}),
                    .copy => {
                        const source = try Row.createBytes(std.testing.allocator, "abcdefgh", 8, pen, .{});
                        defer source.destroy();
                        try source.set(2, .{ .scalar = 'e' }, &.{0x301});
                        try row.copyColumns(source, 1, 6);
                    },
                }
            }
            try expectRowValuesEqual(actual, expected);
            if (actual_before) |row| try expectRowValuesEqual(row, expected_before.?);
            const published = try actual.snapshot();
            defer published.destroy();
            try std.testing.expect(published.deferred == null);
            try expectRowValuesEqual(published, expected);
            const revision = actual.revision;
            try std.testing.expectEqual(@as(i32, 0), cmdy_zrow_prepare_read(actual));
            try std.testing.expectEqual(revision, actual.revision);
            try std.testing.expect(cmdy_zrow_cells(actual, &count) != null);
            try std.testing.expectEqual(actual.columnCount(), count);
            try expectRowValuesEqual(actual, expected);
        }
    }
}

fn freshRowAllocationTrace(a: Allocator) !void {
    const row = try Row.create(a, 8, .{ .scalar = 'Z', .bg = 0x01000004 });
    defer row.destroy();
    const before = try row.snapshot();
    defer before.destroy();
    try row.bytes(2, "BC", .{ .link_id = 71 });
    var expected: [8]StoredCell = undefined;
    for (&expected, 0..) |*cell, column| cell.* = row.logical(column);
    const revision = row.revision;
    row.set(7, .{ .scalar = 'e' }, &.{0x301}) catch |err| {
        try std.testing.expectEqual(revision, row.revision);
        for (expected, 0..) |value, column| try std.testing.expectEqualDeep(value, row.logical(column));
        return err;
    };
    const clustered = try row.snapshot();
    defer clustered.destroy();
    const cluster_revision = row.revision;
    row.fill(0, 8, .{ .scalar = 'Q' }) catch |err| {
        try std.testing.expectEqual(cluster_revision, row.revision);
        try expectRowValuesEqual(row, clustered);
        return err;
    };
    for (0..8) |column| try std.testing.expectEqual(@as(u32, 'Z'), before.logical(column).cell.scalar);
    try std.testing.expectEqualSlices(u32, &.{0x301}, clustered.readValue(7).extras.?);
    try row.resize(12, .{ .scalar = 'R' });
    try std.testing.expectEqual(@as(u32, 'Q'), row.logical(7).cell.scalar);
    try std.testing.expectEqual(@as(u32, 'R'), row.logical(8).cell.scalar);
}

test "fresh row allocation failures preserve initialized values clusters and retained owners" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, freshRowAllocationTrace, .{});
}

test "initial deferral retains eager backing through discard fill and ASCII row replacement" {
    const initial: Cell = .{ .scalar = 'Z', .bg = 0x01000004, .link_id = 71, .style = 3 };
    const pen: Cell = .{ .fg = 0x01000002, .link_id = 17 };
    const fill: Cell = .{ .scalar = 'F', .bg = 0x02010203 };
    const Transition = enum { none, fill, partial_batch, full_batch };
    for ([_]bool{ false, true }) |partial| {
        for (std.enums.values(Transition)) |transition| {
            for ([_]bool{ false, true }) |use_abi| {
                var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
                const row = try Row.create(failing.allocator(), 8, initial);
                defer row.destroy();
                var expected: [8]StoredCell = @splat(.{ .cell = initial });
                if (partial) {
                    try row.bytes(2, "BC", pen);
                    for ("BC", expected[2..4]) |byte, *cell| {
                        cell.cell = pen;
                        cell.cell.scalar = byte;
                    }
                }
                switch (transition) {
                    .none => {},
                    .fill => try row.fill(0, 8, fill),
                    .partial_batch, .full_batch => {
                        const input: []const u8 = if (transition == .partial_batch) "PQ\r\n" else "12345678\r\n";
                        var records: [1]ASCIIRecord = undefined;
                        try std.testing.expectEqual(@as(usize, 1), planASCII(input, 8, &records));
                        var slots = [_]ASCIISlot{.{ .row = row }};
                        try writeASCIIRows(failing.allocator(), input, 8, &records, &slots, pen, fill);
                        for (input[0..records[0].count], expected[0..records[0].count]) |byte, *cell| {
                            cell.cell = pen;
                            cell.cell.scalar = byte;
                        }
                    },
                }
                const sequence = generation.load(.monotonic);
                const allocations = failing.alloc_index;
                failing.fail_index = allocations;
                if (use_abi) cmdy_zrow_discard_deferred(row) else row.discardDeferred();
                try std.testing.expectEqual(allocations, failing.alloc_index);
                try std.testing.expect(!failing.has_induced_failure);
                failing.fail_index = std.math.maxInt(usize);
                const discard_stamp: u64 = if (transition == .fill or transition == .partial_batch) 1 else 0;
                try std.testing.expectEqual(sequence + discard_stamp, generation.load(.monotonic));
                var count: usize = 99;
                const physical = cmdy_zrow_cells(row, &count).?;
                try std.testing.expectEqual(@as(usize, 8), count);
                const published = try row.snapshot();
                defer published.destroy();
                for (expected, 0..) |value, column| {
                    try std.testing.expectEqualDeep(value, row.logical(column));
                    try std.testing.expectEqualDeep(value, physical[column]);
                    try std.testing.expectEqualDeep(value, published.logical(column));
                    try std.testing.expect(row.readValue(column).extras == null);
                }
            }
        }
    }
}

test "fresh row metadata discard preserves the full overwrite mutation boundary" {
    for ([_]bool{ false, true }) |filled| {
        for ([_]bool{ false, true }) |use_abi| {
            const row = try Row.create(std.testing.allocator, 8, .{ .scalar = 'Z' });
            defer row.destroy();
            if (filled) try row.fill(0, 8, .{ .scalar = 'F' });
            try row.bytes(0, "BC", .{});
            const sequence = generation.load(.monotonic);
            if (use_abi) cmdy_zrow_discard_deferred(row) else row.discardDeferred();
            try row.bytes(0, "12345678", .{});
            try std.testing.expectEqual(sequence + @as(u64, if (filled) 2 else 1), row.revision);
            for ("12345678", 0..) |byte, column| try std.testing.expectEqual(@as(u32, byte), row.logical(column).cell.scalar);
        }
    }
}

test "fresh row creation preserves fill read between allocator callbacks" {
    const Mutation = struct {
        child: Allocator,
        source: *Cell,
        trigger: usize,
        calls: usize = 0,
        fn allocator(self: *@This()) Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            const result = self.child.rawAlloc(len, alignment, address);
            if (result != null) {
                self.calls += 1;
                if (self.calls == self.trigger) self.source.* = .{ .scalar = 'X', .bg = 0x01000007 };
            }
            return result;
        }
        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.child.rawResize(memory, alignment, len, address);
        }
        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(context));
            return self.child.rawRemap(memory, alignment, len, address);
        }
        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.child.rawFree(memory, alignment, address);
        }
    };
    for ([_]usize{ 1, 2 }) |trigger| {
        var fill: Cell = .{ .scalar = 'Z', .bg = 0x01000004, .link_id = 71 };
        const expected: Cell = if (trigger == 1) .{ .scalar = 'X', .bg = 0x01000007 } else fill;
        var mutation = Mutation{ .child = std.testing.allocator, .source = &fill, .trigger = trigger };
        const row = try Row.create(mutation.allocator(), 120, fill);
        defer row.destroy();
        try std.testing.expectEqual(@as(usize, 2), mutation.calls);
        try std.testing.expectEqual(@as(u32, 'X'), fill.scalar);
        for (0..120) |column| try std.testing.expectEqualDeep(StoredCell{ .cell = expected }, row.logical(column));
        try row.materialize();
        for (row.storage.cells) |cell| try std.testing.expectEqualDeep(StoredCell{ .cell = expected }, cell);
    }
}

test "full Line operations preserve raw cells, margin boundaries and retained values" {
    const r = try Row.create(std.testing.allocator, 8, .{});
    defer r.destroy();
    try r.bytes(0, "abcdefgh", .{});
    try r.set(3, .{ .scalar = 0xffffffff, .width = -17, .link_id = 41 }, &.{ 0xd800, 0xffffffff });
    const saved = try r.clone();
    defer saved.destroy();
    try r.edit(1, 2, 7, true, .{ .scalar = 88 }, &.{0x301});
    try std.testing.expectEqual(@as(u32, 97), r.logical(0).cell.scalar);
    try std.testing.expectEqual(@as(u32, 104), r.logical(7).cell.scalar);
    try std.testing.expectEqual(@as(u32, 88), r.logical(1).cell.scalar);
    try std.testing.expectEqual(@as(u32, 0xffffffff), r.logical(5).cell.scalar);
    try r.edit(2, 3, 7, false, .{}, &.{});
    try std.testing.expectEqual(@as(u32, 0xffffffff), r.logical(2).cell.scalar);
    try std.testing.expect(r.logical(6).cluster_offset != absent);
    try r.copyColumns(saved, 1, 6);
    try r.appendScalar(3, 0x110000, 127);
    const stored = r.logical(3);
    try std.testing.expectEqual(@as(i8, 127), stored.cell.width);
    try std.testing.expectEqualSlices(u32, &.{ 0xd800, 0xffffffff, 0x110000 }, r.storage.extras.items[stored.cluster_offset..][0..stored.cluster_count]);
    try std.testing.expectEqual(@as(u32, 2), saved.logical(3).cluster_count);
    try r.copyColumns(r, 0, 8);
    try std.testing.expectEqual(@as(u32, 3), r.logical(3).cluster_count);
    try r.resizeValue(8192, .{ .scalar = 90 }, &.{0x302});
    try std.testing.expectEqual(@as(usize, 8192), r.columnCount());
    try std.testing.expectEqual(@as(u32, 1), r.logical(8191).cluster_count);
    try r.resize(4096, .{});
    try std.testing.expect(r.storage.extras.items.len < 32);
}

test "shared cluster fills stay compact through churn, resize and copying" {
    const r = try Row.create(std.testing.allocator, 120, .{});
    defer r.destroy();
    const values = [_]u32{0x301} ** 128;
    try r.fillValue(0, 120, .{ .scalar = 65 }, &values);
    const saved = try r.clone();
    defer saved.destroy();
    for (0..5000) |_| try r.set(0, .{ .scalar = 66 }, &.{0x302});
    try std.testing.expect(r.storage.extras.capacity < 2048);
    try std.testing.expectEqual(@as(usize, 128), saved.storage.extras.items.len);
    try r.resizeValue(6000, .{}, &values);
    try std.testing.expect(r.storage.extras.items.len < 512);
    const copied = try Row.create(std.testing.allocator, 120, .{});
    defer copied.destroy();
    try copied.copyColumns(saved, 0, 120);
    try std.testing.expectEqual(@as(usize, 128), copied.storage.extras.items.len);
    try copied.fill(0, 120, .{});
    try std.testing.expect(copied.storage.extras.capacity <= 480);
}

fn completeAllocationTrace(a: Allocator) !void {
    const r = try Row.create(a, 8, .{});
    defer r.destroy();
    try r.fillValue(0, 8, .{ .scalar = 65 }, &.{ 0x301, 0x302 });
    const saved = try r.clone();
    defer saved.destroy();
    const before = r.revision;
    r.edit(1, 2, 7, true, .{ .scalar = 66 }, &.{0x303}) catch |err| {
        try std.testing.expectEqual(before, r.revision);
        try std.testing.expectEqual(@as(u32, 65), r.logical(1).cell.scalar);
        return err;
    };
    try r.appendScalar(1, 0x304, 2);
    try r.copyColumns(saved, 2, 4);
    try r.resizeValue(80, .{ .scalar = 67 }, &.{0x305});
    for (0..80) |_| try r.set(1, .{ .scalar = 68 }, &.{ 0x306, 0x307 });
    try std.testing.expectEqual(@as(u32, 65), saved.logical(1).cell.scalar);
    try std.testing.expectEqual(@as(usize, 2), saved.storage.extras.items.len);
}
test "complete Line allocation failures preserve ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, completeAllocationTrace, .{});
}

test "tail cluster appends reuse native capacity and keep shared prefixes immutable" {
    const row = try Row.create(std.testing.allocator, 8, .{});
    defer row.destroy();
    try row.fillValue(0, 8, .{ .scalar = 101 }, &.{0x301});
    try row.storage.extras.ensureTotalCapacity(std.testing.allocator, 128);
    const cells = row.storage.cells.ptr;
    const arena = row.storage.extras.items.ptr;
    const offset = row.storage.cells[0].cluster_offset;
    for (0..64) |_| try row.appendScalar(0, 0x308, 1);
    try std.testing.expectEqual(cells, row.storage.cells.ptr);
    try std.testing.expectEqual(arena, row.storage.extras.items.ptr);
    try std.testing.expectEqual(offset, row.storage.cells[0].cluster_offset);
    try std.testing.expectEqual(@as(usize, 65), row.storage.extras.items.len);
    for (row.storage.cells[1..]) |cell| {
        try std.testing.expectEqual(@as(u32, 1), cell.cluster_count);
        try std.testing.expectEqual(@as(u32, 0x301), row.storage.extras.items[cell.cluster_offset]);
    }
    const retained = try row.clone();
    defer retained.destroy();
    try row.appendScalar(0, 0x309, 1);
    try std.testing.expect(row.storage != retained.storage);
    try std.testing.expectEqual(@as(u32, 65), retained.storage.cells[0].cluster_count);
    try std.testing.expectEqual(@as(u32, 66), row.storage.cells[0].cluster_count);
    try std.testing.expectEqual(@as(u32, 0x308), retained.storage.extras.items[64]);
    try std.testing.expectEqual(@as(u32, 0x309), row.storage.extras.items[65]);
}

test "UTF-8 runs stop before invalid partial control follower and wide boundary" {
    const row = try Row.create(std.testing.allocator, 120, .{});
    defer row.destroy();
    const stops = [_][]const u8{ "\x1b", "\x00", "\xc0\xaf", "\xed\xa0\x80", "\xf4\x90\x80\x80", "\xe7\x95", "\xcc\x81", "\xef\xb8\x8f", "\xf0\x9f\x87\xba" };
    for (stops) |stop| {
        const input = try std.mem.concat(std.testing.allocator, u8, &.{ "α界", stop, "abc" });
        defer std.testing.allocator.free(input);
        var result = try row.printUTF8(0, 120, input, 65, .{}, .{});
        defer result.release(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 5), result.bytes);
        try std.testing.expectEqual(@as(usize, 3), result.columns);
        try std.testing.expectEqual(@as(usize, 2), result.count);
    }
    const revision = row.revision;
    var empty = try row.printUTF8(119, 1, "界", 65, .{}, .{});
    defer empty.release(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.bytes);
    try std.testing.expectEqual(revision, row.revision);
    var limited = try row.printUTF8(0, 120, "abcdef", 3, .{}, .{});
    defer limited.release(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), limited.bytes);
}

test "validated Unicode writes match scalar writes across shared deferred and clustered rows" {
    const pen: Cell = .{ .fg = 0x02010203, .bg = 0x01000007, .link_id = 17, .style = 3 };
    const stub: Cell = .{ .fg = 0x01000004, .bg = 0x02040506, .link_id = 19 };
    for (0..4) |mode| {
        for (0..5) |start| {
            const row = try Row.create(std.testing.allocator, 8, .{ .scalar = 65 });
            defer row.destroy();
            const oracle = try Row.create(std.testing.allocator, 8, .{ .scalar = 65 });
            defer oracle.destroy();
            for ([_]*Row{ row, oracle }) |owner| {
                if (mode == 1) {
                    try owner.fill(0, 8, .{ .scalar = 90 });
                    try owner.bytes(0, "x", .{});
                } else if (mode == 2) {
                    try owner.set(1, .{ .scalar = 65 }, &.{});
                } else if (mode == 3) {
                    try owner.fillValue(0, 8, .{ .scalar = 101 }, &.{ 0x301, 0x308 });
                }
            }
            var previous: [8]StoredCell = undefined;
            for (&previous, 0..) |*cell, column| cell.* = row.logical(column);
            const saved = try row.clone();
            defer saved.destroy();
            var result = try row.printUTF8(start, 8 - start, "α界b", 65, pen, stub);
            defer result.release(std.testing.allocator);
            try std.testing.expectEqual(@as(usize, 4), result.columns);
            try std.testing.expectEqualDeep(previous[start + 3].cell, result.displaced);
            var lead = pen;
            lead.scalar = 0x3b1;
            lead.width = 1;
            try oracle.set(start, lead, null);
            lead.scalar = 0x754c;
            lead.width = 2;
            try oracle.set(start + 1, lead, null);
            var tail = stub;
            tail.scalar = 0;
            tail.width = 0;
            tail.link_id = 0;
            try oracle.set(start + 2, tail, null);
            lead.scalar = 98;
            lead.width = 1;
            try oracle.set(start + 3, lead, null);
            for (0..8) |column| {
                const actual = row.logical(column);
                const expected = oracle.logical(column);
                try std.testing.expectEqualDeep(expected.cell, actual.cell);
                try std.testing.expectEqual(expected.cluster_offset == absent, actual.cluster_offset == absent);
                try std.testing.expectEqual(expected.cluster_count, actual.cluster_count);
                if (actual.cluster_count > 0) {
                    try std.testing.expectEqualSlices(u32, oracle.storage.extras.items[expected.cluster_offset..][0..expected.cluster_count], row.storage.extras.items[actual.cluster_offset..][0..actual.cluster_count]);
                }
                try std.testing.expectEqualDeep(previous[column], saved.logical(column));
            }
            try std.testing.expectEqual(oracle.storage.live_extras, row.storage.live_extras);
        }
    }
    const row = try Row.create(std.testing.allocator, 8, .{ .scalar = 65 });
    defer row.destroy();
    const revision = row.revision;
    try std.testing.expectError(error.InvalidInput, row.unicode(0, &.{ .{ .scalar = 66, .width = 1 }, .{ .scalar = 0xd800, .width = 1 } }, pen, stub));
    try std.testing.expectError(error.InvalidInput, row.unicode(0, &.{ .{ .scalar = 66, .width = 1 }, .{ .scalar = 67, .width = 0 } }, pen, stub));
    try std.testing.expectEqual(revision, row.revision);
    for (0..8) |column| try std.testing.expectEqual(@as(u32, 65), row.logical(column).cell.scalar);
}

fn printAllocationTrace(a: Allocator) !void {
    const row = try Row.createBytes(a, "α", 8, .{}, .{});
    defer row.destroy();
    try row.fillValue(0, 8, .{ .scalar = 101 }, &.{ 0x301, 0x308 });
    const retained = try row.clone();
    defer retained.destroy();
    const revision = row.revision;
    var result = row.printUTF8(0, 8, "α界", 65, .{ .fg = 0x01000003 }, .{}) catch |err| {
        try std.testing.expectEqual(revision, row.revision);
        try std.testing.expectEqual(@as(u32, 101), row.logical(0).cell.scalar);
        try std.testing.expectEqual(@as(u32, 2), row.logical(0).cluster_count);
        return err;
    };
    defer result.release(a);
    try std.testing.expectEqualSlices(u32, &.{ 0x301, 0x308 }, result.extras.?[0..result.extra_count]);
    try std.testing.expectEqual(@as(u32, 101), retained.logical(0).cell.scalar);
    try row.fill(0, 8, .{});
    try std.testing.expectEqualSlices(u32, &.{ 0x301, 0x308 }, result.extras.?[0..result.extra_count]);
}
test "fused UTF-8 and one-pass row allocation failures preserve owners and values" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, printAllocationTrace, .{});
}

fn cleanPrintAllocationTrace(a: Allocator) !void {
    for ([_]bool{ false, true }) |deferred| {
        const row = try Row.create(a, 8, .{ .scalar = 65 });
        defer row.destroy();
        const saved = try row.clone();
        defer saved.destroy();
        if (deferred) try row.fill(0, 8, .{ .scalar = 90 });
        const original = row.logical(1).cell;
        const revision = row.revision;
        var result = row.printUTF8(1, 7, "α界b", 65, .{}, .{}) catch |err| {
            try std.testing.expectEqual(revision, row.revision);
            for (0..8) |column| try std.testing.expectEqualDeep(original, row.logical(column).cell);
            return err;
        };
        defer result.release(a);
        try std.testing.expectEqualDeep(original, result.displaced);
        try std.testing.expectEqual(@as(u8, 0), result.present);
        try std.testing.expectEqual(@as(usize, 0), result.extra_count);
        try std.testing.expect(result.extras == null);
        try std.testing.expectEqual(@as(u32, 0x3b1), row.logical(1).cell.scalar);
        try std.testing.expectEqual(@as(i8, 0), row.logical(3).cell.width);
        for (0..8) |column| try std.testing.expectEqual(@as(u32, 65), saved.logical(column).cell.scalar);
    }
}
test "direct clean UTF-8 writes preserve shared and deferred owners on allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, cleanPrintAllocationTrace, .{});
}

test "storage header and aligned cells share an allocation across clone and resize" {
    for ([_]usize{ 0, 1, 120, 8192 }) |columns| {
        const row = try Row.create(std.testing.allocator, columns, .{ .scalar = 65 });
        defer row.destroy();
        try std.testing.expectEqual(@intFromPtr(row.storage) + storage_header_bytes, @intFromPtr(row.storage.cells.ptr));
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(row.storage.cells.ptr) % @alignOf(StoredCell));
        const retained = try row.clone();
        defer retained.destroy();
        try row.resizeValue(columns + 3, .{ .scalar = 66 }, null);
        try std.testing.expectEqual(columns, retained.storage.cells.len);
        if (columns > 0) try std.testing.expectEqual(@as(u32, 65), retained.logical(0).cell.scalar);
        try std.testing.expectEqual(@as(u32, 66), row.logical(columns).cell.scalar);
    }
}

test "SGR grouped and truncated forms preserve operand ownership and cell metadata" {
    var pen: Cell = .{ .scalar = 0xffffffff, .width = -17, .link_id = 42 };
    const sequence = [_]isize{ 38, -1, 2, -1, 0, -1, 10, -1, 20, -1, 30, 4, -1, 3, 58, 5, 201 };
    try std.testing.expectEqual(@as(i32, 0), cmdy_zpen_apply_sgr(&pen, &sequence, sequence.len));
    try std.testing.expectEqual(@as(u32, 0x020a141e), pen.fg);
    try std.testing.expectEqual(@as(u32, 0x010000c9), pen.underline_color);
    try std.testing.expectEqual(@as(u8, 3), pen.underline_kind);
    try std.testing.expectEqual(@as(u8, 2), pen.style);
    const partial = [_]isize{ 38, 2, 1, 4 };
    try std.testing.expectEqual(@as(i32, 0), cmdy_zpen_apply_sgr(&pen, &partial, partial.len));
    try std.testing.expectEqual(@as(u32, 0x020a141e), pen.fg);
    try std.testing.expectEqual(@as(u8, 3), pen.style);
    try std.testing.expectEqual(@as(i32, -1), cmdy_zpen_apply_sgr(&pen, null, 1));
    try std.testing.expectEqual(@as(u8, 3), pen.style);
    try std.testing.expectEqual(@as(i32, 0), cmdy_zpen_apply_sgr(&pen, null, 0));
    try std.testing.expectEqual(@as(u8, 0), pen.style);
    try std.testing.expectEqual(@as(u8, 0), pen.underline_present);
    try std.testing.expectEqual(@as(u32, 0xffffffff), pen.scalar);
    try std.testing.expectEqual(@as(i8, -17), pen.width);
    try std.testing.expectEqual(@as(u16, 42), pen.link_id);
}

fn selectorInput() cluster_rules.Input {
    return .{ .owner_column = 0, .cursor_x = 1, .expected_scalar = 0x2764, .scalar = 0xfe0f, .role = 4, .selector_authority = 1, .lead_is_emoji = 1, .lead_is_vs16_base = 1, .scalar_is_emoji_component = 0, .scalar_is_vs16_base = 0 };
}
test "cluster transaction expands repairs cursor and retains old owners" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(cluster_rules.Input));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(cluster_rules.Result));
    const row = try Row.create(std.testing.allocator, 4, .{});
    defer row.destroy();
    const lead = Cell{ .scalar = 0x2764, .fg = 0x01000002, .bg = 0x02010203, .link_id = 17 };
    try row.set(0, lead, null);
    try row.set(1, .{ .scalar = 0x754c, .width = 2 }, &.{0x301});
    const saved = try row.clone();
    defer saved.destroy();
    const result = try row.continueCluster(selectorInput());
    try std.testing.expectEqual(@as(u8, 1), result.handled);
    try std.testing.expectEqual(@as(u8, 1), result.mutated);
    try std.testing.expectEqual(@as(usize, 2), result.cursor_x);
    try std.testing.expectEqual(@as(u8, 3), result.selector_authority);
    try std.testing.expectEqual(@as(i8, 2), row.logical(0).cell.width);
    var stub = lead;
    stub.scalar = 0;
    stub.width = 0;
    try std.testing.expectEqualDeep(stub, row.logical(1).cell);
    try std.testing.expectEqual(absent, row.logical(1).cluster_offset);
    try std.testing.expectEqualDeep(lead, saved.logical(0).cell);
    try std.testing.expectEqual(@as(u32, 1), saved.logical(1).cluster_count);
    const edge = try Row.create(std.testing.allocator, 2, .{});
    defer edge.destroy();
    try edge.set(0, lead, null);
    try std.testing.expectEqual(@as(u8, 1), (try edge.continueCluster(selectorInput())).wrap_pending);
}
test "cluster transaction consumes blocked selectors without mutation and defers stale geometry" {
    const row = try Row.create(std.testing.allocator, 8, .{});
    defer row.destroy();
    try row.set(0, .{ .scalar = 0x2764 }, null);
    const revision = row.revision;
    var input = selectorInput();
    input.selector_authority = 2;
    const consumed = try row.continueCluster(input);
    try std.testing.expectEqual(@as(u8, 1), consumed.handled);
    try std.testing.expectEqual(@as(u8, 0), consumed.mutated);
    try std.testing.expectEqual(revision, row.revision);
    input = selectorInput();
    input.cursor_x = 3;
    try std.testing.expectEqual(@as(u8, 0), (try row.continueCluster(input)).handled);
    input = selectorInput();
    input.expected_scalar = 65;
    try std.testing.expectEqual(@as(u8, 0), (try row.continueCluster(input)).handled);
    input.role = 255;
    var output = cluster_rules.Result{ .handled = 1, .mutated = 1 };
    try std.testing.expectEqual(@as(i32, -1), cmdy_zrow_continue_cluster(row, &input, &output));
    try std.testing.expectEqualDeep(cluster_rules.Result{}, output);
    try std.testing.expectEqual(revision, row.revision);
}
test "cluster transaction pairs regional indicators and joins complete emoji sequences" {
    const row = try Row.create(std.testing.allocator, 8, .{});
    defer row.destroy();
    try row.set(0, .{ .scalar = 0x1f1fa, .width = 2 }, null);
    var input = selectorInput();
    input.cursor_x = 2;
    input.expected_scalar = 0x1f1fa;
    input.scalar = 0x1f1f8;
    input.role = 6;
    const pair = try row.continueCluster(input);
    try std.testing.expectEqual(@as(u8, 1), pair.mutated);
    const revision = row.revision;
    try std.testing.expectEqual(@as(u8, 0), (try row.continueCluster(input)).handled);
    try std.testing.expectEqual(revision, row.revision);
    try row.set(0, .{ .scalar = 0x1f469, .width = 2 }, &.{0x200d});
    input.expected_scalar = 0x1f469;
    input.scalar = 0x1f4bb;
    input.role = 0;
    input.selector_authority = 2;
    input.scalar_is_emoji_component = 1;
    const joined = try row.continueCluster(input);
    try std.testing.expectEqual(@as(u8, 1), joined.mutated);
    try std.testing.expectEqual(@as(u32, 2), row.logical(0).cluster_count);
    try row.set(0, .{ .scalar = 0x1f469, .width = 2 }, &.{ 0x200d, 0x200d });
    try std.testing.expectEqual(@as(u8, 0), (try row.continueCluster(input)).handled);
}
fn clusterTransactionAllocationTrace(a: Allocator) !void {
    const row = try Row.create(a, 8, .{});
    defer row.destroy();
    try row.set(0, .{ .scalar = 0x2764 }, null);
    try row.set(1, .{ .scalar = 0x754c, .width = 2 }, &.{0x301});
    const saved = try row.clone();
    defer saved.destroy();
    const revision = row.revision;
    const result = row.continueCluster(selectorInput()) catch |err| {
        try std.testing.expectEqual(revision, row.revision);
        for (0..8) |column| try std.testing.expectEqualDeep(saved.logical(column), row.logical(column));
        try std.testing.expectEqualSlices(u32, saved.storage.extras.items, row.storage.extras.items);
        return err;
    };
    try std.testing.expectEqual(@as(u8, 1), result.mutated);
    try std.testing.expectEqual(@as(i8, 1), saved.logical(0).cell.width);
    try std.testing.expectEqual(@as(u32, 1), saved.logical(1).cluster_count);
}
test "cluster transaction allocation failures preserve logical rows and generation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, clusterTransactionAllocationTrace, .{});
}


// Cross-revision regressions: these same tests also run in the frozen baseline.
test "underlay repeated fill preserves older writes and initializes physical gaps" {
    const initial: Cell = .{ .scalar = 'Z', .fg = 0x02010203, .bg = 0x01000004,
        .underline_color = 0x02030405, .underline_present = 1, .underline_kind = 5,
        .link_id = 93, .width = -17, .style = 0xff };
    for ([_]bool{ false, true }) |raw_api| {
        const r = try Row.create(std.heap.c_allocator, 8, initial);
        defer r.destroy();
        try r.bytes(2, "BC", .{ .link_id = 7 });
        try r.fill(0, 8, .{ .scalar = 'F' });
        try r.bytes(0, "Q", .{ .fg = 0x01000003 });
        try r.fill(0, 8, .{ .scalar = 'G' });
        try r.bytes(6, "T", .{ .bg = 0x01000002 });
        try r.fill(0, 8, .{ .scalar = 'H' });
        for (0..8) |i| try std.testing.expectEqual(@as(u32, 'H'), r.logical(i).cell.scalar);
        var n: usize = 17;
        try std.testing.expect(cmdy_zrow_cells(r, &n) == null);
        try std.testing.expectEqual(@as(usize, 0), n);
        const before = generation.load(.monotonic);
        if (raw_api) cmdy_zrow_discard_deferred(r) else r.discardDeferred();
        try std.testing.expectEqual(before + 1, generation.load(.monotonic));
        const cells = cmdy_zrow_cells(r, &n).?;
        try std.testing.expectEqual(@as(usize, 8), n);
        for (0..8) |i| {
            const want: Cell = switch (i) {
                0 => .{ .scalar = 'Q', .fg = 0x01000003 },
                2 => .{ .scalar = 'B', .link_id = 7 },
                3 => .{ .scalar = 'C', .link_id = 7 },
                6 => .{ .scalar = 'T', .bg = 0x01000002 },
                else => initial,
            };
            try std.testing.expectEqualDeep(StoredCell{ .cell = want }, cells[i]);
            try std.testing.expectEqualDeep(want, r.readValue(i).cell);
        }
        const next = generation.load(.monotonic);
        r.discardDeferred();
        try std.testing.expectEqual(next, generation.load(.monotonic));
    }
}

test "underlay detached snapshot preserves fill and owner discard backing" {
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.bytes(2, "BC", .{});
    try r.fill(0, 8, .{ .scalar = 'F', .bg = 0x01000004 });
    try r.bytes(0, "Q", .{});
    const revision = r.revision;
    const stamp_before = generation.load(.monotonic);
    const saved = try r.snapshot();
    defer saved.destroy();
    try std.testing.expectEqual(stamp_before, generation.load(.monotonic));
    try std.testing.expectEqual(revision, saved.revision);
    try std.testing.expect(saved.storage != r.storage);
    r.discardDeferred();
    for ("QZBCZZZZ", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
    const retained = try saved.snapshot();
    defer retained.destroy();
    try std.testing.expect(saved.storage == retained.storage);
    try saved.set(3, .{ .scalar = 'e' }, &.{ 0x301, 0x302 });
    try std.testing.expect(saved.storage != retained.storage);
    try std.testing.expectEqualSlices(u32, &.{ 0x301, 0x302 }, saved.readValue(3).extras.?);
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u32, if (i == 0) 'Q' else 'F'), retained.logical(i).cell.scalar);
        try std.testing.expect(retained.readValue(i).extras == null);
    }
}

test "underlay disjoint logical writes commit current fill before second write" {
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.bytes(2, "BC", .{});
    try r.fill(0, 8, .{ .scalar = 'F' });
    try r.bytes(1, "X", .{});
    try r.bytes(5, "Y", .{});
    const stamp_before = generation.load(.monotonic);
    r.discardDeferred();
    try std.testing.expectEqual(stamp_before, generation.load(.monotonic));
    for ("FXFFFYFF", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
}

test "underlay prepared raw borrow and full overwrite expose complete physical cells" {
    for ([_]bool{ false, true }) |overwrite| {
        const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
        defer r.destroy();
        try r.bytes(2, "BC", .{});
        try r.fill(0, 8, .{ .scalar = 'F' });
        try r.bytes(0, "Q", .{});
        if (overwrite) try r.bytes(0, "12345678", .{ .link_id = 19 });
        const before = generation.load(.monotonic);
        try std.testing.expectEqual(@as(i32, 0), cmdy_zrow_prepare_read(r));
        try std.testing.expectEqual(before, generation.load(.monotonic));
        var count: usize = 0;
        const cells = cmdy_zrow_cells(r, &count).?;
        try std.testing.expectEqual(@as(usize, 8), count);
        const wanted: []const u8 = if (overwrite) "12345678" else "QFFFFFFF";
        for (wanted, cells[0..count]) |c, cell| {
            try std.testing.expectEqual(@as(u32, c), cell.cell.scalar);
            try std.testing.expectEqual(absent, cell.cluster_offset);
            try std.testing.expectEqual(@as(u32, 0), cell.cluster_count);
        }
        r.discardDeferred();
        try std.testing.expectEqual(before, generation.load(.monotonic));
    }
}

test "underlay present empty and nonempty clusters take materialized paths" {
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.fill(0, 8, .{ .scalar = 'F' });
    try r.bytes(2, "A", .{});
    try r.set(2, .{ .scalar = 'A' }, &.{});
    try std.testing.expect(r.deferred == null and r.storage.maybe_clusters);
    try std.testing.expect(r.readValue(2).extras != null);
    try std.testing.expectEqual(@as(usize, 0), r.readValue(2).extras.?.len);
    const saved = try r.snapshot();
    defer saved.destroy();
    try r.appendScalar(2, 0x301, 1);
    try std.testing.expectEqualSlices(u32, &.{0x301}, r.readValue(2).extras.?);
    try std.testing.expectEqual(@as(usize, 0), saved.readValue(2).extras.?.len);
    try r.fillValue(0, 8, .{ .scalar = 'G' }, &.{});
    try std.testing.expect(r.deferred == null and r.storage.maybe_clusters);
    r.discardDeferred();
    for (0..8) |i| {
        try std.testing.expectEqual(@as(u32, 'G'), r.readValue(i).cell.scalar);
        try std.testing.expect(r.readValue(i).extras != null);
    }
}

test "underlay partial and full batches preserve eager discard semantics" {
    for ([_]bool{ false, true }) |full| {
        const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
        defer r.destroy();
        try r.bytes(2, "BC", .{});
        try r.fill(0, 8, .{ .scalar = 'F' });
        try r.bytes(6, "T", .{});
        try r.fill(0, 8, .{ .scalar = 'G' });
        const input: []const u8 = if (full) "12345678\r\n" else "PQ\r\n";
        var records: [1]ASCIIRecord = undefined;
        try std.testing.expectEqual(@as(usize, 1), planASCII(input, 8, &records));
        var slots = [_]ASCIISlot{.{ .row = r }};
        try writeASCIIRows(std.heap.c_allocator, input, 8, &records, &slots, .{}, .{ .scalar = 'H' });
        const before = generation.load(.monotonic);
        r.discardDeferred();
        try std.testing.expectEqual(before + @as(u64, if (full) 0 else 1), generation.load(.monotonic));
        const wanted: []const u8 = if (full) "12345678" else "PQBCZZTZ";
        for (wanted, 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
    }
}

test "underlay partial batch allocation failure preserves original logical and physical state" {
    for (0..2) |fail_at| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_at });
        const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
        defer r.destroy();
        try r.bytes(2, "BC", .{});
        try r.fill(0, 8, .{ .scalar = 'F' });
        try r.bytes(6, "T", .{});
        const before = generation.load(.monotonic);
        const input = "PQ\r\nRS\r\n";
        var records: [2]ASCIIRecord = undefined;
        try std.testing.expectEqual(@as(usize, 2), planASCII(input, 8, &records));
        var slots = [_]ASCIISlot{ .{ .row = r }, .{} };
        try std.testing.expectError(error.OutOfMemory, writeASCIIRows(failing.allocator(), input, 8, &records, &slots, .{}, .{}));
        try std.testing.expect(slots[1].row == null);
        try std.testing.expectEqual(before, generation.load(.monotonic));
        for ("FFFFFFTF", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
        r.discardDeferred();
        for ("ZZBCZZTZ", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
    }
}

const UnderlayAllocatorTrace = struct {
    child: Allocator,
    owner: ?*Row = null,
    triggered: bool = false,
    calls: usize = 0,
    freed: usize = 0,
    allocations: [16]usize = @splat(0),
    frees: [16]usize = @splat(0),
    fn allocator(self: *@This()) Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.allocations[self.calls] = len;
        self.calls += 1;
        const result = self.child.rawAlloc(len, alignment, address);
        if (result != null and !self.triggered) {
            if (self.owner) |owner| {
                self.triggered = true;
                owner.fill(0, 8, .{ .scalar = 'G' }) catch @panic("reentry fill");
                owner.bytes(5, "R", .{}) catch @panic("reentry write");
            }
        }
        return result;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.child.rawResize(memory, alignment, len, address);
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.child.rawRemap(memory, alignment, len, address);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.frees[self.freed] = memory.len;
        self.freed += 1;
        self.child.rawFree(memory, alignment, address);
    }
};

test "underlay wrapped allocators preserve original allocation lengths count and destruction order" {
    for ([_]Allocator{ std.testing.allocator, std.heap.c_allocator }) |child| {
        for ([_]usize{ 0, 1, 8, 120 }) |cols| {
            var trace = UnderlayAllocatorTrace{ .child = child };
            const r = try Row.create(trace.allocator(), cols, .{ .scalar = 'Z' });
            try std.testing.expectEqual(@as(usize, 2), trace.calls);
            const backing = storage_header_bytes + cols * @sizeOf(StoredCell);
            try std.testing.expectEqualSlices(usize, &.{ backing, 80 }, trace.allocations[0..trace.calls]);
            if (cols > 0) {
                try r.fill(0, cols, .{ .scalar = 'F' });
                try r.bytes(cols - 1, "X", .{});
                r.discardDeferred();
            }
            try std.testing.expectEqual(@as(usize, 2), trace.calls);
            r.destroy();
            try std.testing.expectEqualSlices(usize, &.{ backing, 80 }, trace.frees[0..trace.freed]);
        }
    }
}

test "underlay mixed allocator batch reentry precedes physical normalization" {
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.bytes(2, "BC", .{});
    try r.fill(0, 8, .{ .scalar = 'F' });
    var trace = UnderlayAllocatorTrace{ .child = std.testing.allocator, .owner = r };
    const input = "PQ\r\nXY\r\n";
    var records: [2]ASCIIRecord = undefined;
    try std.testing.expectEqual(@as(usize, 2), planASCII(input, 8, &records));
    var slots = [_]ASCIISlot{ .{ .row = r }, .{} };
    try writeASCIIRows(trace.allocator(), input, 8, &records, &slots, .{}, .{ .scalar = 'H' });
    defer slots[1].row.?.destroy();
    try std.testing.expect(trace.triggered);
    try std.testing.expectEqual(@as(usize, 2), trace.calls);
    try std.testing.expectEqualSlices(usize, &.{ storage_header_bytes + 8 * @sizeOf(StoredCell), 80 }, trace.allocations[0..trace.calls]);
    r.discardDeferred();
    for ("PQBCZRZZ", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
    for ("XYHHHHHH", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), slots[1].row.?.logical(i).cell.scalar);
}

test "underlay backing replacements keep snapshots independent and borrowed extras owned" {
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.bytes(2, "BC", .{});
    try r.fill(0, 8, .{ .scalar = 'F' });
    try r.resizeValue(10, .{ .scalar = 'e' }, &.{0x301});
    try std.testing.expect(r.deferred == null);
    for (0..8) |i| try std.testing.expectEqual(@as(u32, 'F'), r.logical(i).cell.scalar);
    try std.testing.expectEqualSlices(u32, &.{0x301}, r.readValue(9).extras.?);
    const retained = try r.snapshot();
    defer retained.destroy();
    try r.bytes(0, "Q", .{});
    try std.testing.expectEqual(@as(u32, 'F'), retained.logical(0).cell.scalar);
    try r.resize(4, .{});
    r.discardDeferred();
    for ("QFFF", 0..) |c, i| try std.testing.expectEqual(@as(u32, c), r.logical(i).cell.scalar);
}

test "underlay canonical allocator context is not inspected and zero writes do not mutate" {
    const a: Allocator = .{ .ptr = undefined, .vtable = std.heap.c_allocator.vtable };
    for ([_]usize{ 0, 1, 120 }) |cols| {
        const r = try Row.create(a, cols, .{ .scalar = 'Z' });
        defer r.destroy();
        const revision = r.revision;
        try r.bytes(0, "", .{});
        try r.fill(0, 0, .{});
        try std.testing.expectEqual(revision, r.revision);
        if (cols > 0) {
            try r.fill(0, cols, .{ .scalar = 'F' });
            r.discardDeferred();
            for (0..cols) |i| try std.testing.expectEqual(@as(u32, 'Z'), r.logical(i).cell.scalar);
        }
    }
}


test "underlay layout and requested byte accounting follow allocation address across swaps" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(Row));
    try std.testing.expectEqual(@as(usize, 77), @offsetOf(Row, "underlay_flags"));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(InitialUnderlay));
    for ([_]usize{ 0, 1, 8, 120 }) |cols| {
        const r = try Row.create(std.heap.c_allocator, cols, .{ .scalar = 'Z' });
        defer r.destroy();
        try std.testing.expectEqual(allocated_underlay, r.underlay_flags);
        try std.testing.expectEqual(@as(usize, 120) + @sizeOf(Storage) + cols * @sizeOf(StoredCell), cmdy_zrow_allocated_bytes(r));
        const snap = try r.snapshot();
        defer snap.destroy();
        try std.testing.expectEqual(@as(u8, 0), snap.underlay_flags);
        try std.testing.expectEqual(@as(usize, 80) + @sizeOf(Storage) + cols * @sizeOf(StoredCell), cmdy_zrow_allocated_bytes(snap));
        const made = try Row.createBytes(std.heap.c_allocator, "", cols, .{}, .{});
        defer made.destroy();
        try std.testing.expectEqual(@as(u8, 0), made.underlay_flags);
        const imported = try Row.fromSnapshotCells(std.heap.c_allocator, snap.storage.cells, &.{}, 93);
        defer imported.destroy();
        try std.testing.expectEqual(@as(u8, 0), imported.underlay_flags);
        try r.resize(cols + 2, .{});
        try std.testing.expectEqual(allocated_underlay, r.underlay_flags);
        try std.testing.expectEqual(@as(usize, 120) + @sizeOf(Storage) + (cols + 2) * @sizeOf(StoredCell), cmdy_zrow_allocated_bytes(r));
    }
}

test "underlay active state persists across fills but clears on logical commit and replacement" {
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.bytes(2, "BC", .{});
    try r.fill(0, 8, .{ .scalar = 'F' });
    try std.testing.expectEqual(allocated_underlay | active_underlay, r.underlay_flags);
    try std.testing.expectEqualDeep(InitialUnderlay{ .initial = .{ .scalar = 'Z' }, .start = 2, .end = 4 }, r.initialUnderlay().*);
    try r.bytes(0, "Q", .{});
    try r.fill(0, 8, .{ .scalar = 'G' });
    try std.testing.expectEqual(@as(usize, 0), r.initialUnderlay().start);
    try std.testing.expectEqual(@as(usize, 4), r.initialUnderlay().end);
    try std.testing.expectEqual(@as(u32, 'Z'), r.storage.cells[1].cell.scalar);
    const saved = try r.snapshot();
    defer saved.destroy();
    try std.testing.expectEqual(allocated_underlay | active_underlay, r.underlay_flags);
    try std.testing.expectEqual(@as(u8, 0), saved.underlay_flags);
    try r.resizeValue(10, .{ .scalar = 'e' }, &.{0x301});
    try std.testing.expectEqual(allocated_underlay, r.underlay_flags);
    try std.testing.expectEqual(@as(usize, 120) + @sizeOf(Storage) + 10 * @sizeOf(StoredCell) + r.storage.extras.capacity * 4, cmdy_zrow_allocated_bytes(r));
    const retained = try r.snapshot();
    defer retained.destroy();
    try r.bytes(0, "X", .{});
    try std.testing.expectEqual(allocated_underlay, r.underlay_flags);
    try std.testing.expectEqual(@as(u8, 0), retained.underlay_flags);
}

test "underlay partial batch failure does not normalize backing before fallible preparation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const r = try Row.create(std.heap.c_allocator, 8, .{ .scalar = 'Z' });
    defer r.destroy();
    try r.bytes(2, "BC", .{});
    try r.fill(0, 8, .{ .scalar = 'F' });
    const input = "PQ\r\nRS\r\n";
    var records: [2]ASCIIRecord = undefined;
    _ = planASCII(input, 8, &records);
    var slots = [_]ASCIISlot{ .{ .row = r }, .{} };
    try std.testing.expectError(error.OutOfMemory, writeASCIIRows(failing.allocator(), input, 8, &records, &slots, .{}, .{}));
    try std.testing.expectEqual(allocated_underlay | active_underlay, r.underlay_flags);
    try std.testing.expectEqual(@as(usize, 2), r.initialUnderlay().start);
    try std.testing.expectEqual(@as(usize, 4), r.initialUnderlay().end);
}


test "underlay transition matrix matches unchanged custom allocator backing and stamps" {
    const Op = enum { fill_f, fill_g, left, right, discard, materialize };
    const operations = std.enums.values(Op);
    // All four-operation sequences cover repeated fills, both gap directions,
    // logical-span materialization and discard at every relative position.
    for (0..1296) |sequence| {
        const initial: Cell = .{ .scalar = 'Z', .bg = 0x01000007, .width = -3, .link_id = 91 };
        const actual = try Row.create(std.heap.c_allocator, 8, initial);
        defer actual.destroy();
        const original = try Row.create(std.testing.allocator, 8, initial);
        defer original.destroy();
        try actual.bytes(2, "BC", .{});
        try original.bytes(2, "BC", .{});
        var code = sequence;
        for (0..4) |_| {
            const op = operations[code % operations.len];
            code /= operations.len;
            var deltas: [2]u64 = undefined;
            for ([_]*Row{ actual, original }, &deltas) |row, *delta| {
                const before = generation.load(.monotonic);
                switch (op) {
                    .fill_f => try row.fill(0, 8, .{ .scalar = 'F', .style = 0x5a }),
                    .fill_g => try row.fill(0, 8, .{ .scalar = 'G', .fg = 0x02010203 }),
                    .left => try row.bytes(0, "Q", .{ .link_id = 3 }),
                    .right => try row.bytes(6, "T", .{ .link_id = 4 }),
                    .discard => row.discardDeferred(),
                    .materialize => try row.materialize(),
                }
                delta.* = generation.load(.monotonic) -% before;
            }
            try std.testing.expectEqual(deltas[1], deltas[0]);
            try expectRowValuesEqual(actual, original);
        }
        actual.discardDeferred();
        original.discardDeferred();
        try actual.materialize();
        try original.materialize();
        for (actual.storage.cells, original.storage.cells) |a, b| try std.testing.expectEqualDeep(b, a);
    }
}

test "direct initial ASCII factory preserves fallback and initialized physical contents" {
    for ([_]usize{ 0, 8, 63, 64, 120, 257 }) |cols| {
        for ([_]Cell{ .{}, .{ .scalar = 'Z', .fg = 0x01000003 }, .{ .scalar = 0x754c, .width = 2 }, .{ .width = -3 } }) |initial| {
            const actual = try Row.createForLine(std.heap.c_allocator, cols, initial);
            defer actual.destroy();
            const expected = try Row.create(std.testing.allocator, cols, initial);
            defer expected.destroy();
            try std.testing.expectEqual(cols >= 64 and initial.scalar <= 0x7f and initial.width == 1, actual.isCompact());
            try expectRowValuesEqual(actual, expected);
            actual.discardDeferred(); expected.discardDeferred();
            try actual.materialize(); try expected.materialize();
            for (actual.storage.cells, expected.storage.cells) |a, e| try std.testing.expectEqualDeep(e, a);
        }
    }
    const custom = try Row.createForLine(std.testing.allocator, 120, .{});
    defer custom.destroy();
    try std.testing.expect(!custom.isCompact());
    const general = try Row.create(std.heap.c_allocator, 120, .{});
    defer general.destroy();
    try std.testing.expect(!general.isCompact());
    try std.testing.expectError(error.InvalidInput, Row.createForLine(std.heap.c_allocator, 120, .{ .fg = 0xffffffff }));
}
test "direct initial ASCII values revisions and retained snapshots match dense across operation sequences" {
    const Op = enum { fill, left, right, discard, snapshot, materialize };
    const operations = std.enums.values(Op);
    for ([_]usize{64, 120}) |cols| {
        for ([_]Cell{ .{ .scalar = 'Z' }, .{ .scalar = 'Q', .bg = 0x01000007 } }) |initial| {
            for (0..216) |sequence| {
                const actual = try Row.createForLine(std.heap.c_allocator, cols, initial);
                defer actual.destroy();
                const expected = try Row.create(std.testing.allocator, cols, initial);
                defer expected.destroy();
                var pen = initial; pen.scalar = 0;
                try actual.bytes(2, "BC", pen); try expected.bytes(2, "BC", pen);
                try std.testing.expect(actual.isCompact());
                const old_actual = try actual.snapshot(); defer old_actual.destroy();
                const old_expected = try expected.snapshot(); defer old_expected.destroy();
                var code = sequence;
                for (0..3) |_| {
                    const op = operations[code % operations.len]; code /= operations.len;
                    var deltas: [2]u64 = undefined;
                    for ([_]*Row{actual, expected}, &deltas) |row, *delta| {
                        const before = generation.load(.monotonic);
                        switch (op) {
                            .fill => try row.fill(0, cols, .{ .scalar = 'F', .style = 0x5a }),
                            .left => try row.bytes(0, "Q", pen),
                            .right => try row.bytes(cols-2, "TY", .{ .link_id = 4 }),
                            .discard => row.discardDeferred(),
                            .snapshot => { const frozen = try row.snapshot(); defer frozen.destroy(); try expectRowValuesEqual(row, frozen); },
                            .materialize => try row.materialize(),
                        }
                        delta.* = generation.load(.monotonic) -% before;
                    }
                    try std.testing.expectEqual(deltas[1], deltas[0]);
                    try expectRowValuesEqual(actual, expected);
                    try expectRowValuesEqual(old_actual, old_expected);
                }
                actual.discardDeferred(); expected.discardDeferred();
                try actual.materialize(); try expected.materialize();
                for (actual.storage.cells, expected.storage.cells) |a, e| try std.testing.expectEqualDeep(e, a);
            }
        }
    }
}
test "direct initial ASCII falls back for rich writes resize and row batch without changing values" {
    const Op = enum { unicode, cluster, resize, batch, complete_ascii, gap, changed_pen };
    for (std.enums.values(Op)) |op| {
        const actual = try Row.createForLine(std.heap.c_allocator, 120, .{ .scalar = 'Z' }); defer actual.destroy();
        const expected = try Row.create(std.testing.allocator, 120, .{ .scalar = 'Z' }); defer expected.destroy();
        for ([_]*Row{actual, expected}) |row| {
            try row.bytes(2, "BC", .{});
            switch (op) {
                .unicode => try row.unicode(5, &.{.{ .scalar = 0x754c, .width = 2 }}, .{}, .{ .width = 0 }),
                .cluster => try row.set(4, .{ .scalar = 'e' }, &.{0x301}),
                .resize => try row.resize(128, .{ .scalar = 'R' }),
                .batch => { const records = [_]ASCIIRecord{.{ .offset = 0, .count = 5 }}; var slots = [_]ASCIISlot{.{ .row = row }}; try writeASCIIRows(std.testing.allocator, "hello\r\n", 120, &records, &slots, .{}, .{}); },
                .complete_ascii => try row.bytes(0, "A" ** 120, .{}),
                .gap => { try row.fill(0, 120, .{ .scalar = 'F', .style = 1 }); try row.bytes(1, "X", .{}); try row.bytes(20, "Y", .{}); },
                .changed_pen => try row.bytes(8, "color", .{ .fg = 0x01000003 }),
            }
        }
        try expectRowValuesEqual(actual, expected);
        actual.discardDeferred(); expected.discardDeferred();
        try actual.materialize(); try expected.materialize();
        for (actual.storage.cells, expected.storage.cells) |a, e| try std.testing.expectEqualDeep(e, a);
    }
}
fn directCompactAllocationTrace(a: Allocator) !void {
    const row = try Row.createCompactInitial(a, 120, .{ .scalar = 'Z' }); defer row.destroy();
    const frozen = try row.snapshot(); defer frozen.destroy();
    row.bytes(1, "abc", .{}) catch |err| {
        try expectRowValuesEqual(row, frozen); return err;
    };
    const before_dense = try row.snapshot(); defer before_dense.destroy();
    row.bytes(4, "color", .{ .fg = 0x01000003 }) catch |err| {
        try expectRowValuesEqual(row, before_dense); return err;
    };
    try std.testing.expectEqual(@as(u32, 'Z'), frozen.logical(1).cell.scalar);
    try row.set(12, .{ .scalar = 'e' }, &.{0x301});
    try row.resize(128, .{});
}
test "direct compact creation copy on write and dense fallback preserve allocation failure atomicity" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, directCompactAllocationTrace, .{});
}

test "initial ASCII palette preserves four attributes and falls back on fifth with retained owners" {
    const row = try Row.createForLine(std.heap.c_allocator, 120, .{ .scalar = 'Z' }); defer row.destroy();
    const reference = try Row.create(std.testing.allocator, 120, .{ .scalar = 'Z' }); defer reference.destroy();
    for (0..4) |i| {
        const pen: Cell = .{ .fg = if (i == 0) 0 else 0x01000000 + @as(u32, @intCast(i)) };
        try row.bytes(i * 3, "abc", pen); try reference.bytes(i * 3, "abc", pen);
        try std.testing.expect(row.isCompact()); try expectRowValuesEqual(row, reference);
    }
    const retained = try row.snapshot(); defer retained.destroy();
    const expected_retained = try reference.snapshot(); defer expected_retained.destroy();
    try row.bytes(19, "fifth", .{ .fg = 0x01000009 }); try reference.bytes(19, "fifth", .{ .fg = 0x01000009 });
    try std.testing.expect(!row.isCompact()); try expectRowValuesEqual(row, reference);
    try expectRowValuesEqual(retained, expected_retained);
}
test "palette logical snapshots preserve mixed physical tails and incompatible fill fallback" {
    for ([_]bool{false, true}) |full_palette| {
        const row = try Row.createForLine(std.heap.c_allocator, 120, .{ .scalar = 'Z' }); defer row.destroy();
        const reference = try Row.create(std.testing.allocator, 120, .{ .scalar = 'Z' }); defer reference.destroy();
        for (0..if (full_palette) @as(usize, 3) else 1) |i| {
            const pen: Cell = .{ .fg = 0x01000001 + @as(u32, @intCast(i)) };
            try row.bytes(i * 3, "abc", pen); try reference.bytes(i * 3, "abc", pen);
        }
        for ([_]*Row{row, reference}) |value| {
            try value.fill(0, 120, .{ .scalar = 'F', .bg = 0x01000005 });
            try value.bytes(1, "XY", .{ .fg = 0x01000001 });
        }
        const frozen = try row.snapshot(); defer frozen.destroy();
        const expected_frozen = try reference.snapshot(); defer expected_frozen.destroy();
        try expectRowValuesEqual(frozen, expected_frozen);
        try std.testing.expectEqual(!full_palette, frozen.isCompact());
        row.discardDeferred(); reference.discardDeferred();
        try expectRowValuesEqual(row, reference); try expectRowValuesEqual(frozen, expected_frozen);
        try row.materialize(); try reference.materialize();
        for (row.storage.cells, reference.storage.cells) |actual, expected| try std.testing.expectEqualDeep(expected, actual);
    }
}
fn paletteAllocationTrace(a: Allocator) !void {
    const row = try Row.createCompactInitial(a, 120, .{ .scalar = 'Z' }); defer row.destroy();
    try row.bytes(1, "red", .{ .fg = 0x01000001 });
    const frozen = try row.snapshot(); defer frozen.destroy();
    row.bytes(5, "blue", .{ .fg = 0x01000002 }) catch |err| { try expectRowValuesEqual(row, frozen); return err; };
    try row.bytes(9, "green", .{ .fg = 0x01000003 });
    const before_dense = try row.snapshot(); defer before_dense.destroy();
    row.bytes(16, "fifth", .{ .fg = 0x01000004 }) catch |err| { try expectRowValuesEqual(row, before_dense); return err; };
    const sparse = try Row.createCompactInitial(a, 120, .{}); defer sparse.destroy();
    try sparse.bytes(1, "old", .{ .fg = 0x01000001 });
    try sparse.fill(0, 120, .{ .scalar = 'F', .bg = 0x01000006 });
    try sparse.bytes(2, "new", .{ .fg = 0x01000002 });
    const snapshot = try sparse.snapshot(); defer snapshot.destroy();
    try expectRowValuesEqual(sparse, snapshot);
}
test "palette growth copy on write snapshot and overflow preserve allocation failure atomicity" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, paletteAllocationTrace, .{});
}
