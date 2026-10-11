//! Scalar insertion, grapheme ownership, and terminal print provenance.
const std = @import("std");
const lines = @import("line.zig");
const unicode = @import("unicode.zig");
const emoji = @import("emoji.zig");
const motion = @import("line_motion.zig");
const Line = lines.Line;
const Cell = lines.Cell;
const Value = lines.Value;
const Allocator = std.mem.Allocator;
pub const Bounds = struct {
    first: isize,
    last: isize,
    pub fn contains(self: Bounds, value: isize) bool {
        return value >= self.first and value <= self.last;
    }
};
pub const Position = struct { row: isize = 0, x: isize = 0, cols: isize = -1, rows: isize = -1 };
pub const Shape = struct { row: isize, cols: isize, rows: isize };
pub const Authority = enum(u8) { unavailable, available, suspended, blocked };
pub const Role = enum { ordinary, zeroWidth, joiner, textVariation, emojiVariation, variation, regionalIndicator };
pub const AttachmentPhase = enum { activeShift, dormantCoordinate, dormantAfterShift };

/// Own the extras whenever a value survives a row write or a host callback.
pub const OwnedCell = struct {
    cell: Cell,
    extras: ?[]u32 = null,
    pub fn init(a: Allocator, source: Value) !OwnedCell {
        return .{ .cell = source.cell, .extras = if (source.extras) |v| try a.dupe(u32, v) else null };
    }
    pub fn clone(self: *const OwnedCell, a: Allocator) !OwnedCell {
        return init(a, self.value());
    }
    pub fn value(self: *const OwnedCell) Value {
        return .{ .cell = self.cell, .extras = self.extras };
    }
    pub fn deinit(self: *OwnedCell, a: Allocator) void {
        if (self.extras) |v| a.free(v);
        self.extras = null;
    }
};
pub const PendingOwner = struct {
    line: *Line,
    leadColumn: isize,
    cell: OwnedCell,
    cols: isize,
    rows: isize,
    pub fn deinit(self: *PendingOwner, a: Allocator) void {
        self.cell.deinit(a);
        self.line.release();
    }
};
pub const DisplacedCell = struct {
    row: isize,
    column: isize,
    cols: isize,
    rows: isize,
    cell: OwnedCell,
    pub fn deinit(self: *DisplacedCell, a: Allocator) void {
        self.cell.deinit(a);
    }
};
pub const Attachment = struct {
    row: isize,
    column: isize,
    cols: isize,
    rows: isize,
    scalar: u32,
    isAlternateBuffer: bool,
    phase: AttachmentPhase,
};
pub const RejectedOwner = struct {
    line: *Line,
    leadColumn: isize,
    cell: OwnedCell,
    cols: isize,
    rows: isize,
    isAlternateBuffer: bool,
    pub fn deinit(self: *RejectedOwner, a: Allocator) void {
        self.cell.deinit(a);
        self.line.release();
    }
};
pub const ReverseOwner = struct {
    absoluteRow: isize,
    leadColumn: isize,
    line: *Line,
    cell: OwnedCell,
    selectorAuthority: Authority,
    selectorOwnerAdvancedByRelativeMotion: bool,
    selectorRelocationTracksWidthChange: bool,
    activationSerial: u64,
    cols: isize,
    rows: isize,
    isAlternateBuffer: bool,
    pub fn clone(self: *const ReverseOwner, a: Allocator) !ReverseOwner {
        var result = self.*;
        result.cell = try self.cell.clone(a);
        result.line = self.line.retain();
        return result;
    }
    pub fn deinit(self: *ReverseOwner, a: Allocator) void {
        self.cell.deinit(a);
        self.line.release();
    }
};
pub const Departure = struct {
    absoluteRow: isize,
    leadColumn: isize,
    activationSerial: u64,
    cols: isize,
    rows: isize,
    isAlternateBuffer: bool,
};
pub const InsertOwner = struct {
    absoluteRow: isize,
    leadColumn: isize,
    cell: OwnedCell,
    cols: isize,
    rows: isize,
    isAlternateBuffer: bool,
    pub fn deinit(self: *InsertOwner, a: Allocator) void {
        self.cell.deinit(a);
    }
};
pub const Coordinate = struct { row: isize, column: isize };
pub const MarginGeneration = struct {
    witnessLine: *Line,
    retainedBottomRow: isize,
    virtualCells: std.AutoHashMapUnmanaged(Coordinate, Cell) = .empty,
    virtualContentCells: std.AutoHashMapUnmanaged(Coordinate, OwnedCell) = .empty,
    pub fn deinit(self: *MarginGeneration, a: Allocator) void {
        self.witnessLine.release();
        self.virtualCells.deinit(a);
        var values = self.virtualContentCells.valueIterator();
        while (values.next()) |value| value.deinit(a);
        self.virtualContentCells.deinit(a);
    }
};
pub const ImageTransfer = struct {
    image: *@import("graphics.zig").LineImage,
    source: *Line,
    destination: *Line,
    successor: ?*Line,
    pub fn deinit(self: *ImageTransfer) void {
        self.image.deinit();
        self.source.release();
        self.destination.release();
        if (self.successor) |line| line.release();
    }
};
pub const State = struct {
    lastPrintedScalar: ?u32 = null,
    lastWrite: Position = .{},
    noWrapParkedAfterPrint: bool = false,
    pendingCursorUpMoved: bool = false,
    selectorOwnerAdvancedByRelativeMotion: bool = false,
    selectorRelocationTracksWidthChange: bool = false,
    selectorExpansionSettledPhysicalPending: ?Shape = null,
    lastPrintWrappedFromRightOfMargin: bool = false,
    lastPrintAdvancedToFreshRow: bool = false,
    pendingWrapOwnerWitness: ?PendingOwner = null,
    lastPrintAdvancedFromCurrentPendingOwner: bool = false,
    activeMarginReflowBoundaries: std.ArrayList(*Line) = .empty,
    kittyDisplayReflowClaims: std.ArrayList(*Line) = .empty,
    kittyDisplayReflowBoundaries: std.ArrayList(*Line) = .empty,
    kittyDisplayClippedTopReflowRanks: std.ArrayList(*Line) = .empty,
    kittyDisplayReflowImages: std.ArrayList(*@import("graphics.zig").LineImage) = .empty,
    kittyDisplayReflowImageTransfers: std.ArrayList(ImageTransfer) = .empty,
    normalBackwardColumnAttachmentWitness: ?Attachment = null,
    alternateBackwardColumnAttachmentWitness: ?Attachment = null,
    lastWriteDisplacedCell: ?DisplacedCell = null,
    presentationSelectorAuthority: Authority = .unavailable,
    rejectedWidePresentationOwnerWitness: ?RejectedOwner = null,
    bufferActivationSerial: u64 = 0,
    reverseIndexBufferDepartureOwner: ?Departure = null,
    normalReverseIndexOwnerRefreshWitness: ?ReverseOwner = null,
    alternateReverseIndexOwnerRefreshWitness: ?ReverseOwner = null,
    normalInsertLineOwnerRefreshWitness: ?InsertOwner = null,
    alternateInsertLineOwnerRefreshWitness: ?InsertOwner = null,
    marginDeleteGenerations: std.ArrayList(MarginGeneration) = .empty,

    pub fn deinit(s: *State, a: Allocator) void {
        inline for (.{ "pendingWrapOwnerWitness", "lastWriteDisplacedCell", "rejectedWidePresentationOwnerWitness", "normalReverseIndexOwnerRefreshWitness", "alternateReverseIndexOwnerRefreshWitness", "normalInsertLineOwnerRefreshWitness", "alternateInsertLineOwnerRefreshWitness" }) |name| {
            clearOptional(a, &@field(s, name));
        }
        inline for (.{ "activeMarginReflowBoundaries", "kittyDisplayReflowClaims", "kittyDisplayReflowBoundaries", "kittyDisplayClippedTopReflowRanks" }) |name| {
            const list = &@field(s, name);
            for (list.items) |line| line.release();
            list.deinit(a);
        }
        for (s.kittyDisplayReflowImages.items) |image| image.deinit();
        s.kittyDisplayReflowImages.deinit(a);
        for (s.kittyDisplayReflowImageTransfers.items) |*transfer| transfer.deinit();
        s.kittyDisplayReflowImageTransfers.deinit(a);
        for (s.marginDeleteGenerations.items) |*generation| generation.deinit(a);
        s.marginDeleteGenerations.deinit(a);
        s.* = .{};
    }
};

pub fn clearOptional(a: Allocator, pointer: anytype) void {
    if (pointer.*) |*value| value.deinit(a);
    pointer.* = null;
}
pub fn backwardWitness(t: anytype) *?Attachment {
    return if (t.is_alternate) &t.print_state.alternateBackwardColumnAttachmentWitness else &t.print_state.normalBackwardColumnAttachmentWitness;
}
pub fn reverseWitness(t: anytype) *?ReverseOwner {
    return if (t.is_alternate) &t.print_state.alternateReverseIndexOwnerRefreshWitness else &t.print_state.normalReverseIndexOwnerRefreshWitness;
}
pub fn insertWitness(t: anytype) *?InsertOwner {
    return if (t.is_alternate) &t.print_state.alternateInsertLineOwnerRefreshWitness else &t.print_state.normalInsertLineOwnerRefreshWitness;
}
pub fn extrasEqual(a: ?[]const u32, b: ?[]const u32) bool {
    if (a) |x| return if (b) |y| std.mem.eql(u32, x, y) else false;
    return b == null;
}
pub fn cellEqual(a: Value, b: Value) bool {
    return std.meta.eql(a.cell, b.cell) and extrasEqual(a.extras, b.extras);
}
pub fn isRegional(scalar: u32) bool {
    return scalar >= 0x1f1e6 and scalar <= 0x1f1ff;
}
pub fn clusterRole(scalar: u32, width: i8) Role {
    return switch (scalar) {
        0x200d => .joiner,
        0xfe0e => .textVariation,
        0xfe0f => .emojiVariation,
        0xe0100...0xe01ef => .variation,
        else => if (isRegional(scalar)) .regionalIndicator else if (width == 0) .zeroWidth else .ordinary,
    };
}
pub fn printingColumns(t: anytype, column: isize) Bounds {
    const b = t.buffer();
    if (t.margin_mode and column >= b.margin_left) return .{ .first = b.margin_left, .last = b.margin_right };
    return .{ .first = 0, .last = b.cols - 1 };
}
pub const Cluster = struct { row: isize, leadColumn: isize, cell: Value, line: *Line, cursorFollowsLead: bool };
pub fn validatedLastCluster(t: anytype) ?Cluster {
    const b = t.buffer();
    const s = &t.print_state;
    const last = s.lastWrite;
    if (last.rows != b.rows or last.cols != b.cols or last.x < 0 or last.x >= b.cols) return null;
    const scalar = s.lastPrintedScalar orelse return null;
    const line = b.line(last.row) orelse return null;
    var lead = last.x;
    while (lead > 0 and line.cell(lead).width == 0) lead -= 1;
    const value = line.get(lead);
    if (value.cell.width <= 0 or value.cell.scalar != scalar) return null;
    return .{ .row = last.row - b.y_base, .leadColumn = lead, .cell = value, .line = line, .cursorFollowsLead = last.row == b.y_base + b.y and b.x == lead + value.cell.width };
}
pub fn invalidateClusterContinuation(t: anytype, preserve_dormant: bool) void {
    const s = &t.print_state;
    const previous = backwardWitness(t).*;
    backwardWitness(t).* = if (preserve_dormant and previous != null and previous.?.phase != .activeShift) previous else null;
    s.lastPrintedScalar = null;
    s.presentationSelectorAuthority = .unavailable;
    clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastPrintWrappedFromRightOfMargin = false;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    s.selectorOwnerAdvancedByRelativeMotion = false;
    s.selectorRelocationTracksWidthChange = false;
    s.selectorExpansionSettledPhysicalPending = null;
    if (!t.buffer().wrap_pending) clearOptional(t.allocator, &s.pendingWrapOwnerWitness);
}
pub fn refreshPendingWrapOwner(t: anytype, line: *Line, lead: isize) !void {
    const b = t.buffer();
    const slot = &t.print_state.pendingWrapOwnerWitness;
    if (!b.wrap_pending or lead < 0 or lead >= b.cols or line != b.liveLine(b.y)) {
        clearOptional(t.allocator, slot);
        return;
    }
    const value = line.get(lead);
    const bounds = printingColumns(t, lead);
    if (value.cell.scalar == 0 or value.cell.width <= 0 or b.x <= bounds.last) {
        clearOptional(t.allocator, slot);
        return;
    }
    const captured = try OwnedCell.init(t.allocator, value);
    const retained = line.retain();
    clearOptional(t.allocator, slot);
    slot.* = .{ .line = retained, .leadColumn = lead, .cell = captured, .cols = b.cols, .rows = b.rows };
}
pub fn refreshPendingWrapOwnerFromLast(t: anytype) !void {
    if (t.buffer().wrap_pending) if (validatedLastCluster(t)) |cluster| return refreshPendingWrapOwner(t, cluster.line, cluster.leadColumn);
    clearOptional(t.allocator, &t.print_state.pendingWrapOwnerWitness);
}
pub fn pendingWrapOwnerStillOccupiesDeparture(t: anytype) bool {
    const b = t.buffer();
    const bounds = printingColumns(t, b.x);
    const witness = t.print_state.pendingWrapOwnerWitness orelse return false;
    if (!b.wrap_pending or witness.cols != b.cols or witness.rows != b.rows or witness.leadColumn < 0 or witness.leadColumn >= b.cols or
        !bounds.contains(witness.leadColumn) or witness.line != b.liveLine(b.y)) return false;
    const value = witness.line.get(witness.leadColumn);
    return value.cell.scalar == witness.cell.cell.scalar and value.cell.width == witness.cell.cell.width and extrasEqual(value.extras, witness.cell.extras);
}
pub fn clearGlyphIntersecting(t: anytype, column: isize, line: *Line, bounds: Bounds) !void {
    if (!bounds.contains(column) or column < 0 or column >= line.count()) return;
    const cell = line.cell(column);
    if (cell.width == 0 or cell.width == 2) try line.setCell(column, t.eraseCell());
}
pub fn appendCluster(t: anytype, scalar: u32, cluster: *Cluster, requested_width: isize, tracks_cursor: bool) !bool {
    const b = t.buffer();
    const bounds = printingColumns(t, cluster.leadColumn);
    const physical: Bounds = .{ .first = 0, .last = b.cols - 1 };
    const target = std.math.clamp(requested_width, 1, 2);
    const old: isize = cluster.cell.cell.width;
    const applied = if (target == 2 and cluster.leadColumn < physical.last) @as(isize, 2) else if (target == 1) 1 else old;
    const old_cell = cluster.cell.cell;
    // Save every borrowed field needed after mutation before its arena changes.
    cluster.cell.extras = null;
    try cluster.line.appendClusterScalar(scalar, cluster.leadColumn, @intCast(applied));
    if (applied > old) {
        try clearGlyphIntersecting(t, cluster.leadColumn + 1, cluster.line, physical);
        var stub = old_cell;
        stub.scalar = 0;
        stub.width = 0;
        try cluster.line.setCell(cluster.leadColumn + 1, stub);
    }
    const delta = applied - old;
    if (delta != 0 and (cluster.cursorFollowsLead or tracks_cursor)) {
        b.x += delta;
        b.wrap_pending = b.x > bounds.last;
    } else if (delta < 0 and b.wrap_pending and cluster.row == b.y and bounds.first == bounds.last and
        bounds.last == physical.last and cluster.leadColumn == bounds.first and b.x == bounds.last + 1)
    {
        b.x = bounds.last;
        b.wrap_pending = false;
    }
    try refreshPendingWrapOwner(t, cluster.line, cluster.leadColumn);
    t.markDirty(b.y_base + cluster.row);
    return true;
}
pub fn hasCompletedZWJ(value: Value) bool {
    const extras = value.extras orelse return false;
    const last = std.mem.lastIndexOfScalar(u32, extras, 0x200d) orelse return false;
    return last + 1 < extras.len;
}
pub fn hasTrailingSelector(value: Value) bool {
    const extras = value.extras orelse return false;
    return extras.len > 0 and (extras[extras.len - 1] == 0xfe0e or extras[extras.len - 1] == 0xfe0f);
}
pub fn selectorAuthority(value: Value) Authority {
    const extras = value.extras orelse return .available;
    if (extras.len == 0) return .available;
    if (hasTrailingSelector(value)) return .blocked;
    if (hasCompletedZWJ(value) and unicode.isVS16Base(extras[extras.len - 1])) return .available;
    return .suspended;
}

pub fn appendOrdinaryAfterJoiner(t: anytype, scalar: u32) !bool {
    if (!emoji.isZWJComponent(scalar)) return false;
    var cluster = validatedLastCluster(t) orelse return false;
    const extras = cluster.cell.extras orelse return false;
    if (extras.len == 0 or extras[extras.len - 1] != 0x200d or
        (extras.len > 1 and extras[extras.len - 2] == 0x200d) or isRegional(cluster.cell.cell.scalar) or
        std.mem.indexOfScalar(u32, extras, 0x20e3) != null or !emoji.isZWJComponent(cluster.cell.cell.scalar)) return false;
    const restore = t.print_state.presentationSelectorAuthority != .available and unicode.isVS16Base(scalar);
    const appended = try appendCluster(t, scalar, &cluster, cluster.cell.cell.width, false);
    if (appended and restore) t.print_state.presentationSelectorAuthority = .available;
    return appended;
}
pub fn appendToLastCluster(t: anytype, scalar: u32, role: Role) anyerror!bool {
    var cluster = validatedLastCluster(t) orelse return false;
    const s = &t.print_state;
    const b = t.buffer();
    switch (role) {
        .regionalIndicator => {
            if (!isRegional(cluster.cell.cell.scalar)) return false;
            for (cluster.cell.extras orelse &.{}) |value| if (value == 0x200d or isRegional(value)) return false;
            return appendCluster(t, scalar, &cluster, 2, false);
        },
        .emojiVariation => {
            if (s.presentationSelectorAuthority != .available) return true;
            const lead = cluster.cell.cell.scalar;
            if (!emoji.isEmoji(lead)) return false;
            if (hasTrailingSelector(cluster.cell)) {
                s.presentationSelectorAuthority = .blocked;
                return true;
            }
            const expands = unicode.isVS16Base(lead);
            if (!expands and cluster.cell.cell.width != 2) return false;
            if (cluster.cell.cell.width == 2 and !expands and !hasCompletedZWJ(cluster.cell)) {
                s.presentationSelectorAuthority = .blocked;
                return true;
            }
            const beyond = cluster.row == b.y and b.x > cluster.leadColumn + cluster.cell.cell.width;
            const follows = expands and s.selectorOwnerAdvancedByRelativeMotion and beyond;
            const left = cluster.row == b.y and b.x < cluster.leadColumn;
            const relocated = cluster.row != b.y;
            const repositioned_left = expands and s.selectorRelocationTracksWidthChange and left;
            const tracks = expands and s.selectorRelocationTracksWidthChange and
                (s.lastPrintAdvancedToFreshRow or left or relocated or beyond);
            s.selectorOwnerAdvancedByRelativeMotion = false;
            s.selectorRelocationTracksWidthChange = false;
            if (repositioned_left) invalidateClusterContinuation(t, false);
            if (expands and !repositioned_left and try relocateVS16Cluster(t, scalar, cluster, tracks)) {
                s.presentationSelectorAuthority = .blocked;
                return true;
            }
            const width: isize = if (expands) 2 else cluster.cell.cell.width;
            const at_lead = expands and cluster.cell.cell.width == 1 and cluster.row == b.y and b.x == cluster.leadColumn and cluster.leadColumn < b.cols - 1;
            const at_right = cluster.row == b.y and b.x == b.cols - 1 and !b.wrap_pending;
            const old_width = cluster.cell.cell.width;
            const appended = try appendCluster(t, scalar, &cluster, width, follows or tracks or repositioned_left);
            if (appended and at_lead) {
                b.x += 1;
                b.wrap_pending = b.x > printingColumns(t, cluster.leadColumn).last;
            }
            if (appended and old_width == 1 and follows and at_right and t.auto_wrap and
                printingColumns(t, cluster.leadColumn).last == b.cols - 1 and b.x == b.cols and b.wrap_pending)
                s.selectorExpansionSettledPhysicalPending = .{ .row = b.y_base + b.y, .cols = b.cols, .rows = b.rows };
            if (appended) s.presentationSelectorAuthority = .blocked;
            return appended;
        },
        .textVariation => {
            if (s.presentationSelectorAuthority != .available) return true;
            if (!emoji.isEmoji(cluster.cell.cell.scalar)) return false;
            if (hasTrailingSelector(cluster.cell) or (cluster.cell.cell.width == 2 and !hasCompletedZWJ(cluster.cell) and !unicode.isVS16Base(cluster.cell.cell.scalar))) {
                s.presentationSelectorAuthority = .blocked;
                return true;
            }
            const appended = try appendCluster(t, scalar, &cluster, 1, false);
            if (appended) s.presentationSelectorAuthority = .blocked;
            return appended;
        },
        .joiner, .variation, .zeroWidth => {
            const appended = try appendCluster(t, scalar, &cluster, @max(1, cluster.cell.cell.width), false);
            if (appended and s.presentationSelectorAuthority == .available) s.presentationSelectorAuthority = .suspended;
            return appended;
        },
        .ordinary => return false,
    }
}

pub const ScalarPrintMetadata = struct {
    width: i8,
    role: Role,
    isEmojiComponent: bool,
    pub fn permitsOrdinaryUnicodeBatch(self: ScalarPrintMetadata) bool {
        return (self.width == 1 or self.width == 2) and self.role == .ordinary and !self.isEmojiComponent;
    }
};
pub fn scalarPrintMetadata(scalar: u32) ScalarPrintMetadata {
    // Printable ASCII has fixed width and cannot continue a ZWJ sequence,
    // including the keycap bases '#', '*' and digits.
    if (scalar >= 0x20 and scalar <= 0x7e)
        return .{ .width = 1, .role = .ordinary, .isEmojiComponent = false };
    const width = unicode.width(scalar);
    if (width < 0) return .{ .width = width, .role = .ordinary, .isEmojiComponent = false };
    const role = clusterRole(scalar, width);
    return .{ .width = width, .role = role, .isEmojiComponent = role == .ordinary and emoji.isZWJComponent(scalar) };
}
pub fn ordinaryPrintModesEnabled(t: anytype) bool {
    return t.auto_wrap and !t.insert_mode and !t.margin_mode;
}
pub fn printScalar(t: anytype, scalar: u32) anyerror!void {
    try printScalarWithMetadata(t, scalar, scalarPrintMetadata(scalar));
}
pub fn printScalarWithMetadata(t: anytype, scalar: u32, metadata: ScalarPrintMetadata) anyerror!void {
    const width = metadata.width;
    if (width < 0) {
        invalidateClusterContinuation(t, false);
        return;
    }
    const role = metadata.role;
    const restored = role != .ordinary and try motion.restoreReverseIndexOwnerRefreshWitnessForFollower(t);
    if (role != .ordinary and try appendToLastCluster(t, scalar, role)) {
        try motion.rebaseActiveReverseIndexOwnerRefreshWitness(t, .{});
        return;
    }
    if (role == .emojiVariation) return;
    if (role == .ordinary and metadata.isEmojiComponent and try appendOrdinaryAfterJoiner(t, scalar)) {
        try motion.rebaseActiveReverseIndexOwnerRefreshWitness(t, .{});
        return;
    }
    if (width <= 0) {
        invalidateClusterContinuation(t, true);
        return;
    }
    if (restored) clearOptional(t.allocator, reverseWitness(t));
    try insertCellDirect(t, .{ .cell = t.penCell(scalar, @min(2, width)) });
}

pub fn isValidScalar(scalar: u32) bool {
    return scalar <= 0x10ffff and (scalar < 0xd800 or scalar > 0xdfff);
}
pub fn relocateVS16Cluster(t: anytype, scalar: u32, cluster: Cluster, tracks_cursor: bool) anyerror!bool {
    const b = t.buffer();
    const s = &t.print_state;
    const bounds = printingColumns(t, cluster.leadColumn);
    const absolute = b.y_base + cluster.row;
    const displaced_matches = if (s.lastWriteDisplacedCell) |v| v.row == absolute and v.column == cluster.leadColumn and v.cols == b.cols and v.rows == b.rows else false;
    const overwrote_wide = displaced_matches and s.lastWriteDisplacedCell.?.cell.cell.width == 2;
    const intersects_wide = cluster.leadColumn + 1 < b.cols and cluster.line.cell(cluster.leadColumn + 1).width != 1;
    if (s.lastPrintWrappedFromRightOfMargin or !s.lastPrintAdvancedToFreshRow or !s.lastPrintAdvancedFromCurrentPendingOwner or
        overwrote_wide or intersects_wide or cluster.cell.cell.width != 1 or cluster.leadColumn != bounds.first or cluster.row <= 0 or
        !cluster.cursorFollowsLead or !cluster.line.is_wrapped) return false;
    const destination = b.liveLine(cluster.row - 1);
    const prior = destination.get(bounds.last);
    if (prior.cell.scalar != 0 or prior.extras != null or prior.cell.width != 1 or prior.cell.link_id != 0) return false;
    const source = cluster.cell.cell;
    const extras = cluster.cell.extras orelse &.{};
    const appended = try t.allocator.alloc(u32, extras.len + 1);
    defer t.allocator.free(appended);
    @memcpy(appended[0..extras.len], extras);
    appended[extras.len] = scalar;
    var relocated = source;
    relocated.width = 1;
    try destination.set(bounds.last, .{ .cell = relocated, .extras = appended });
    if (displaced_matches) {
        try cluster.line.set(cluster.leadColumn, s.lastWriteDisplacedCell.?.cell.value());
    } else {
        var blank = source;
        blank.scalar = 0;
        blank.width = 1;
        blank.link_id = 0;
        try cluster.line.setCell(cluster.leadColumn, blank);
    }
    cluster.line.setWrapped(false);
    b.y = cluster.row - 1;
    b.x = bounds.last + 1 + @as(isize, if (tracks_cursor) 1 else 0);
    b.wrap_pending = true;
    s.lastWrite = .{ .row = b.y_base + b.y, .x = bounds.last, .cols = b.cols, .rows = b.rows };
    clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    try refreshPendingWrapOwner(t, destination, bounds.last);
    t.markDirty(absolute);
    t.markDirty(b.y_base + b.y);
    return true;
}

pub fn clearSelectorOwnerRelativeForwardMotion(t: anytype) void {
    t.print_state.selectorOwnerAdvancedByRelativeMotion = false;
    t.print_state.selectorRelocationTracksWidthChange = false;
}
pub fn recordSelectorOwnerRelativeForwardMotion(t: anytype, old_x: isize) void {
    if (validatedLastCluster(t) == null) {
        clearSelectorOwnerRelativeForwardMotion(t);
        return;
    }
    if (t.buffer().x <= old_x) return;
    t.print_state.selectorOwnerAdvancedByRelativeMotion = true;
    t.print_state.selectorRelocationTracksWidthChange = true;
}
pub fn recordSelectorOwnerRelativeBackwardMotion(t: anytype, old_x: isize, old_y: isize) void {
    const c = validatedLastCluster(t) orelse {
        clearSelectorOwnerRelativeForwardMotion(t);
        return;
    };
    const b = t.buffer();
    if (b.x == old_x and b.y == old_y) return;
    if (c.row == b.y) {
        if (b.x < c.leadColumn) t.print_state.selectorRelocationTracksWidthChange = true else if (b.x <= c.leadColumn + c.cell.cell.width) t.print_state.selectorRelocationTracksWidthChange = false;
    }
}
pub fn recordSelectorOwnerAbsoluteMotion(t: anytype, old_x: isize, old_y: isize) void {
    const b = t.buffer();
    if (b.x == old_x and b.y == old_y) return;
    t.print_state.selectorOwnerAdvancedByRelativeMotion = false;
    const c = validatedLastCluster(t) orelse {
        t.print_state.selectorRelocationTracksWidthChange = false;
        return;
    };
    t.print_state.selectorRelocationTracksWidthChange = c.row != b.y or c.leadColumn != b.x;
}
pub fn recordSelectorOwnerVerticalMotion(t: anytype, old_absolute: isize) void {
    if (t.buffer().y_base + t.buffer().y == old_absolute) return;
    t.print_state.selectorOwnerAdvancedByRelativeMotion = false;
    t.print_state.selectorRelocationTracksWidthChange = validatedLastCluster(t) != null;
}
pub fn recordSelectorOwnerStrictLeftReposition(t: anytype, old_x: isize, old_y: isize) void {
    const b = t.buffer();
    if (b.x == old_x and b.y == old_y) return;
    t.print_state.selectorOwnerAdvancedByRelativeMotion = false;
    const c = validatedLastCluster(t) orelse {
        t.print_state.selectorRelocationTracksWidthChange = false;
        return;
    };
    if (c.row != b.y) return;
    t.print_state.selectorRelocationTracksWidthChange = b.x < c.leadColumn;
}

pub const EditOptions = struct {
    refreshSelectorMotion: bool = false,
    preserveBackwardAttachmentCoordinateOnInvalidation: bool = false,
    preserveLineRotationOwnerOnInvalidation: bool = false,
    refreshLineRotationOwnerAtSavedCoordinate: bool = false,
};
pub const EditGuard = struct {
    owner: Position,
    affected: bool,
    options: EditOptions,
    displaced_line: ?InsertOwner = null,
    dormant_line: ?Position = null,
    dormant_refresh: ?Attachment = null,
    dormant_backward: ?Attachment = null,
    pub fn deinit(self: *EditGuard, a: Allocator) void {
        clearOptional(a, &self.displaced_line);
    }
};
pub fn beginCellEdit(t: anytype, rows: Bounds, columns: Bounds, options: EditOptions) anyerror!EditGuard {
    const b = t.buffer();
    const s = &t.print_state;
    var guard = EditGuard{ .owner = s.lastWrite, .affected = s.lastPrintedScalar != null and s.lastWrite.rows == b.rows and
        s.lastWrite.cols == b.cols and rows.contains(s.lastWrite.row - b.y_base) and columns.contains(s.lastWrite.x), .options = options };
    errdefer guard.deinit(t.allocator);
    if (options.preserveLineRotationOwnerOnInvalidation and guard.affected) {
        if (validatedLastCluster(t)) |c| guard.displaced_line = .{ .absoluteRow = s.lastWrite.row, .leadColumn = c.leadColumn, .cell = try OwnedCell.init(t.allocator, c.cell), .cols = b.cols, .rows = b.rows, .isAlternateBuffer = t.is_alternate };
    }
    if (options.refreshLineRotationOwnerAtSavedCoordinate) {
        if (insertWitness(t).*) |w| {
            if (w.cols == b.cols and w.rows == b.rows and w.isAlternateBuffer == t.is_alternate and
                rows.contains(w.absoluteRow - b.y_base) and columns.contains(w.leadColumn))
                guard.dormant_line = .{ .row = w.absoluteRow, .x = w.leadColumn, .cols = w.cols, .rows = w.rows };
        }
    }
    if (options.preserveBackwardAttachmentCoordinateOnInvalidation) {
        if (backwardWitness(t).*) |w| {
            if (w.phase != .activeShift and w.cols == b.cols and w.rows == b.rows and w.isAlternateBuffer == t.is_alternate and
                rows.contains(w.row - b.y_base) and columns.contains(w.column)) guard.dormant_refresh = w;
        }
        if (backwardWitness(t).* == null or backwardWitness(t).*.?.phase != .activeShift) {
            if (validatedLastCluster(t)) |c| {
                if (rows.contains(c.row) and columns.contains(c.leadColumn)) guard.dormant_backward = .{ .row = s.lastWrite.row, .column = c.leadColumn, .cols = b.cols, .rows = b.rows, .scalar = s.lastPrintedScalar.?, .isAlternateBuffer = t.is_alternate, .phase = .dormantCoordinate };
            }
        }
    }
    return guard;
}
pub fn endCellEdit(t: anytype, guard: *EditGuard) anyerror!bool {
    const b = t.buffer();
    const s = &t.print_state;
    const refreshed: Position = if (guard.affected) guard.owner else if (guard.dormant_refresh) |w|
        .{ .row = w.row, .x = w.column, .cols = w.cols, .rows = w.rows }
    else
        guard.dormant_line orelse return false;
    const line = b.line(refreshed.row);
    const cell = if (line != null and refreshed.x >= 0 and refreshed.x < line.?.count()) line.?.get(refreshed.x) else null;
    if (cell == null or cell.?.cell.width <= 0 or cell.?.cell.scalar == 0 or !isValidScalar(cell.?.cell.scalar)) {
        invalidateClusterContinuation(t, true);
        s.lastWrite = .{};
        if (guard.affected and guard.dormant_backward != null) backwardWitness(t).* = guard.dormant_backward else if (guard.dormant_refresh) |w| backwardWitness(t).* = w;
        if (guard.displaced_line != null) {
            clearOptional(t.allocator, insertWitness(t));
            insertWitness(t).* = guard.displaced_line;
            guard.displaced_line = null;
        }
        return true;
    }
    clearOptional(t.allocator, insertWitness(t));
    const advanced = refreshed.row == b.y_base + b.y and b.x > refreshed.x + cell.?.cell.width;
    backwardWitness(t).* = null;
    s.lastPrintedScalar = cell.?.cell.scalar;
    s.presentationSelectorAuthority = selectorAuthority(cell.?);
    s.lastWrite = refreshed;
    clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastPrintWrappedFromRightOfMargin = false;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    if (guard.options.refreshSelectorMotion) {
        s.selectorOwnerAdvancedByRelativeMotion = advanced;
        s.selectorRelocationTracksWidthChange = advanced;
    } else if (guard.dormant_refresh != null) {
        const cursor_row = b.y_base + b.y;
        s.selectorOwnerAdvancedByRelativeMotion = cursor_row == refreshed.row and advanced;
        s.selectorRelocationTracksWidthChange = cursor_row != refreshed.row or b.x < refreshed.x or advanced;
    }
    return true;
}

pub const BackwardShiftGuard = struct {
    pub fn deinit(_: *BackwardShiftGuard, _: Allocator) void {}
};
pub fn beginBackwardColumnShift(t: anytype, rows: Bounds, columns: Bounds) anyerror!BackwardShiftGuard {
    const b = t.buffer();
    const s = &t.print_state;
    const slot = backwardWitness(t);
    if (slot.*) |w| {
        const current = w.cols == b.cols and w.rows == b.rows and w.isAlternateBuffer == t.is_alternate and
            columns.contains(w.column) and rows.contains(w.row - b.y_base) and (w.phase != .activeShift or
            (w.row == s.lastWrite.row and w.column == s.lastWrite.x and s.lastPrintedScalar != null and w.scalar == s.lastPrintedScalar.?));
        if (!current) slot.* = null;
    }
    if (slot.* == null) {
        if (validatedLastCluster(t)) |c| {
            if (rows.contains(c.row) and columns.contains(c.leadColumn)) slot.* = .{ .row = s.lastWrite.row, .column = c.leadColumn, .cols = b.cols, .rows = b.rows, .scalar = s.lastPrintedScalar.?, .isAlternateBuffer = t.is_alternate, .phase = .activeShift };
        }
    }
    if (slot.* == null) {
        if (insertWitness(t).*) |w| {
            if (w.cols == b.cols and w.rows == b.rows and w.isAlternateBuffer == t.is_alternate and
                rows.contains(w.absoluteRow - b.y_base) and columns.contains(w.leadColumn) and isValidScalar(w.cell.cell.scalar))
                slot.* = .{ .row = w.absoluteRow, .column = w.leadColumn, .cols = w.cols, .rows = w.rows, .scalar = w.cell.cell.scalar, .isAlternateBuffer = w.isAlternateBuffer, .phase = .dormantCoordinate };
        }
    }
    return .{};
}
pub fn endBackwardColumnShift(t: anytype, _: *BackwardShiftGuard) anyerror!void {
    const b = t.buffer();
    const s = &t.print_state;
    const w = backwardWitness(t).* orelse return;
    if (w.cols != b.cols or w.rows != b.rows or w.isAlternateBuffer != t.is_alternate) return;
    const line = b.line(w.row) orelse return;
    if (w.column < 0 or w.column >= line.count()) return;
    const cell = line.get(w.column);
    if (cell.cell.width <= 0 or cell.cell.scalar == 0 or !isValidScalar(cell.cell.scalar)) {
        var dormant = w;
        dormant.phase = .dormantAfterShift;
        invalidateClusterContinuation(t, false);
        s.lastWrite = .{};
        backwardWitness(t).* = dormant;
        return;
    }
    if (insertWitness(t).*) |v| {
        if (v.absoluteRow == w.row and v.leadColumn == w.column and v.cols == w.cols and v.rows == w.rows and
            v.isAlternateBuffer == w.isAlternateBuffer) clearOptional(t.allocator, insertWitness(t));
    }
    s.lastPrintedScalar = cell.cell.scalar;
    s.presentationSelectorAuthority = selectorAuthority(cell);
    s.lastWrite = .{ .row = w.row, .x = w.column, .cols = w.cols, .rows = w.rows };
    clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastPrintWrappedFromRightOfMargin = false;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    s.selectorExpansionSettledPhysicalPending = null;
    var active = w;
    active.scalar = cell.cell.scalar;
    active.phase = .activeShift;
    backwardWitness(t).* = active;
}

pub fn retainForwardColumnShiftTail(t: anytype, tail: Value, source_col: isize, destination_col: isize, row: isize, min_col: isize) anyerror!void {
    const b = t.buffer();
    const s = &t.print_state;
    if (insertWitness(t).*) |w| {
        if (w.cols == b.cols and w.rows == b.rows and w.isAlternateBuffer == t.is_alternate) return;
    }
    const current_geometry = s.lastWrite.rows == b.rows and s.lastWrite.cols == b.cols;
    if (s.lastPrintedScalar != null and current_geometry and s.lastWrite.row != b.y_base + row and validatedLastCluster(t) != null) return;
    if (s.lastPrintedScalar != null and current_geometry and s.lastWrite.row == b.y_base + row and s.lastWrite.x < min_col) return;
    const source_was_owner = current_geometry and s.lastWrite.row == b.y_base + row and s.lastWrite.x == source_col;
    const contiguous = if (destination_col == 0) true else if (destination_col > 0 and destination_col < b.cols) blk: {
        const prior = b.liveLine(row).cell(destination_col - 1);
        break :blk prior.scalar != 0 or prior.width == 0;
    } else false;
    if (source_was_owner or !contiguous or destination_col < min_col or destination_col < 0 or destination_col >= b.cols or
        tail.cell.width != 1 or tail.cell.scalar == 0 or !isValidScalar(tail.cell.scalar))
    {
        invalidateClusterContinuation(t, false);
        s.lastWrite = .{};
        return;
    }
    backwardWitness(t).* = null;
    s.lastPrintedScalar = tail.cell.scalar;
    s.presentationSelectorAuthority = selectorAuthority(tail);
    s.lastWrite = .{ .row = b.y_base + row, .x = destination_col, .cols = b.cols, .rows = b.rows };
    clearOptional(t.allocator, &s.lastWriteDisplacedCell);
}

pub fn isCompletePresentationOwner(value: Value) bool {
    if (value.cell.width <= 0 or !isValidScalar(value.cell.scalar) or unicode.width(value.cell.scalar) != 1 or
        !unicode.isVS16Base(value.cell.scalar) or !emoji.isZWJComponent(value.cell.scalar)) return false;
    const extras = value.extras orelse return false;
    if (extras.len == 0 or extras[extras.len - 1] == 0x200d) return false;
    for (extras) |scalar| if (scalar == 0xfe0e or scalar == 0xfe0f) return true;
    return false;
}
pub fn preservesPresentationOwnerAcrossRejectedWide(t: anytype, source: Value) anyerror!bool {
    const b = t.buffer();
    const s = &t.print_state;
    if (t.auto_wrap) return false;
    const columns = printingColumns(t, b.x);
    if (b.cols <= 0 or b.rows <= 0 or b.x < columns.last or b.x > b.cols or source.cell.width != 2 or
        (source.extras != null and source.extras.?.len > 0) or !isValidScalar(source.cell.scalar) or unicode.width(source.cell.scalar) != 2) return false;
    const c = validatedLastCluster(t) orelse return false;
    const extras = c.cell.extras orelse return false;
    var has_selector = false;
    for (extras) |scalar| if (scalar == 0xfe0e or scalar == 0xfe0f) {
        has_selector = true;
        break;
    };
    if (!has_selector) return false;
    if (isCompletePresentationOwner(c.cell)) {
        const copy = try OwnedCell.init(t.allocator, c.cell);
        const retained = c.line.retain();
        clearOptional(t.allocator, &s.rejectedWidePresentationOwnerWitness);
        s.rejectedWidePresentationOwnerWitness = .{ .line = retained, .leadColumn = c.leadColumn, .cell = copy, .cols = b.cols, .rows = b.rows, .isAlternateBuffer = t.is_alternate };
        return true;
    }
    if (extras.len == 0 or extras[extras.len - 1] != 0x200d) return false;
    const before: Value = .{ .cell = c.cell.cell, .extras = extras[0 .. extras.len - 1] };
    if (s.rejectedWidePresentationOwnerWitness) |w| {
        if (w.cols == b.cols and w.rows == b.rows and w.isAlternateBuffer == t.is_alternate and w.line == c.line and
            w.leadColumn == c.leadColumn and cellEqual(w.cell.value(), before)) return true;
    }
    if (s.lastWriteDisplacedCell) |d| return d.row == s.lastWrite.row and d.column == c.leadColumn and d.cols == b.cols and
        d.rows == b.rows and isCompletePresentationOwner(d.cell.value()) and cellEqual(d.cell.value(), before);
    return false;
}
pub fn restoreClusterContinuationAfterRejectedWide(t: anytype) void {
    const b = t.buffer();
    const s = &t.print_state;
    const prior = s.presentationSelectorAuthority;
    if (prior == .suspended or prior == .blocked) s.presentationSelectorAuthority = .unavailable;
    const last = s.lastWrite;
    if (s.lastPrintedScalar != null or last.rows != b.rows or last.cols != b.cols or last.x < 0 or last.x >= b.cols) return;
    const line = b.line(last.row) orelse return;
    const cell = line.cell(last.x);
    if (cell.width <= 0 or !isValidScalar(cell.scalar)) return;
    s.lastPrintedScalar = cell.scalar;
    s.presentationSelectorAuthority = if (prior == .available) .available else .unavailable;
}
pub fn insertCellDirect(t: anytype, source: Value) anyerror!void {
    const b = t.buffer();
    const s = &t.print_state;
    // A caller may be repeating a value borrowed from the very row being edited.
    var owned_source = try OwnedCell.init(t.allocator, source);
    defer owned_source.deinit(t.allocator);
    const value = owned_source.value();
    const parked = s.noWrapParkedAfterPrint;
    if (try preservesPresentationOwnerAcrossRejectedWide(t, value)) return;
    const preserve_reverse = motion.reverseIndexOwnerRefreshIsDisplaced(t);
    const suppress_up = s.pendingCursorUpMoved;
    const suppress_settled = if (s.selectorExpansionSettledPhysicalPending) |w|
        w.row == b.y_base + b.y and w.cols == b.cols and w.rows == b.rows and b.x == b.cols and b.wrap_pending and t.auto_wrap
    else
        false;
    s.selectorExpansionSettledPhysicalPending = null;
    s.pendingCursorUpMoved = false;
    s.lastPrintWrappedFromRightOfMargin = false;
    s.lastPrintAdvancedToFreshRow = false;
    s.lastPrintAdvancedFromCurrentPendingOwner = false;
    if (b.cols <= 0 or b.rows <= 0 or !isValidScalar(value.cell.scalar)) {
        invalidateClusterContinuation(t, false);
        return;
    }
    b.y = std.math.clamp(b.y, 0, b.rows - 1);
    var columns = printingColumns(t, b.x);
    const started_exterior = t.margin_mode and t.auto_wrap and !b.wrap_pending and b.x > columns.last and b.x < b.cols;
    var advanced = false;
    var advanced_bottom = false;
    const width: isize = std.math.clamp(@as(isize, value.cell.width), 1, 2);
    if (!t.auto_wrap and width == 2 and b.x > columns.last) {
        restoreClusterContinuationAfterRejectedWide(t);
        return;
    }
    s.noWrapParkedAfterPrint = false;
    b.x = @max(b.x, columns.first);
    if (b.wrap_pending and b.x <= columns.last) b.wrap_pending = false;
    const pending_owner_current = if (b.wrap_pending and b.x > columns.last) pendingWrapOwnerStillOccupiesDeparture(t) else !parked;
    if (b.wrap_pending or b.x > columns.last) {
        if (t.auto_wrap) {
            advanced_bottom = try advanceForPendingWrap(t, columns);
            columns = printingColumns(t, b.x);
            advanced = true;
        } else {
            b.x = columns.last;
            b.wrap_pending = false;
        }
    }
    var clipped_wide = false;
    if (width == 2 and b.x == columns.last) {
        if (columns.first == columns.last and advanced) clipped_wide = b.x == b.cols - 1 else {
            if (!t.auto_wrap) {
                b.wrap_pending = false;
                restoreClusterContinuationAfterRejectedWide(t);
                return;
            }
            advanced_bottom = try advanceForPendingWrap(t, columns) or advanced_bottom;
            columns = printingColumns(t, b.x);
            advanced = true;
            clipped_wide = columns.first == columns.last and b.x == b.cols - 1;
        }
    }
    const lead = std.math.clamp(b.x, columns.first, columns.last);
    const spills = width == 2 and columns.first == columns.last and advanced and lead < b.cols - 1;
    const glyph_bounds: Bounds = if (spills) .{ .first = 0, .last = b.cols - 1 } else columns;
    const physical_width: isize = if (clipped_wide) 1 else width;
    if (lead + physical_width - 1 > glyph_bounds.last) {
        invalidateClusterContinuation(t, false);
        return;
    }
    const line = b.liveLine(b.y);
    var displaced = try OwnedCell.init(t.allocator, line.get(lead));
    defer displaced.deinit(t.allocator);
    if (t.insert_mode) {
        try line.insertCells(lead, physical_width, if (t.margin_mode) b.margin_right else glyph_bounds.last, .{ .cell = t.eraseCell() });
        if (line.cell(b.cols - 1).width == 2) try line.setCell(b.cols - 1, .{ .bg = 0x03000000 });
        const replacement = try OwnedCell.init(t.allocator, line.get(lead));
        displaced.deinit(t.allocator);
        displaced = replacement;
    } else {
        try clearGlyphIntersecting(t, lead, line, glyph_bounds);
        if (physical_width == 2) try clearGlyphIntersecting(t, lead + 1, line, glyph_bounds);
    }
    var cell = value.cell;
    cell.width = @intCast(width);
    try line.set(lead, .{ .cell = cell, .extras = value.extras });
    if (physical_width == 2) try line.setCell(lead + 1, .{ .width = 0, .bg = 0x03000000 });
    clearOptional(t.allocator, &s.rejectedWidePresentationOwnerWitness);
    motion.finishPrintReverseIndexOwnerRefresh(t, preserve_reverse, b.y_base + b.y, lead);
    backwardWitness(t).* = null;
    s.lastPrintedScalar = value.cell.scalar;
    s.presentationSelectorAuthority = .available;
    s.lastWrite = .{ .row = b.y_base + b.y, .x = lead, .cols = b.cols, .rows = b.rows };
    s.selectorOwnerAdvancedByRelativeMotion = false;
    s.selectorRelocationTracksWidthChange = false;
    clearOptional(t.allocator, &s.lastWriteDisplacedCell);
    s.lastWriteDisplacedCell = .{ .row = b.y_base + b.y, .column = lead, .cols = b.cols, .rows = b.rows, .cell = displaced };
    displaced.extras = null; // ownership moved
    s.lastPrintWrappedFromRightOfMargin = started_exterior and advanced;
    s.lastPrintAdvancedToFreshRow = advanced and !suppress_up and !suppress_settled;
    s.lastPrintAdvancedFromCurrentPendingOwner = advanced and pending_owner_current;
    if (advanced_bottom and t.hasNarrowMargins()) {
        var y = b.scroll_top;
        while (y <= b.scroll_bottom) : (y += 1) {
            const affected = b.liveLine(y);
            if (affected.is_wrapped) try retainUniqueLine(t.allocator, &s.activeMarginReflowBoundaries, affected);
        }
    }
    b.x = lead + physical_width;
    b.wrap_pending = b.x > columns.last and t.auto_wrap;
    try refreshPendingWrapOwner(t, line, lead);
    s.noWrapParkedAfterPrint = !t.auto_wrap and b.x > columns.last;
    t.markDirty(b.y_base + b.y);
}

pub fn retainUniqueLine(a: Allocator, list: *std.ArrayList(*Line), line: *Line) !void {
    if (std.mem.indexOfScalar(*Line, list.items, line) != null) return;
    try list.append(a, line);
    _ = line.retain();
}
pub fn removeLine(list: *std.ArrayList(*Line), line: *Line) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i] == line) {
            const removed = list.orderedRemove(i);
            removed.release();
        } else i += 1;
    }
}
pub fn containsLine(screen: anytype, line: *Line) bool {
    var i: isize = 0;
    while (i < screen.lineCount()) : (i += 1) if (screen.line(i) == line) return true;
    return false;
}
pub fn clearActiveMarginReflowBoundary(t: anytype, line: *Line) void {
    removeLine(&t.print_state.activeMarginReflowBoundaries, line);
}
pub fn clearSupersededKittyDisplayReflowState(t: anytype, line: *Line) void {
    removeLine(&t.print_state.kittyDisplayReflowBoundaries, line);
    removeLine(&t.print_state.kittyDisplayClippedTopReflowRanks, line);
    removeLine(&t.print_state.kittyDisplayReflowClaims, line);
}
pub fn hasKittyDisplayReflowClaim(t: anytype, line: *Line) bool {
    return std.mem.indexOfScalar(*Line, t.print_state.kittyDisplayReflowClaims.items, line) != null;
}
pub fn clearKittyDisplayReflowBoundary(t: anytype, line: *Line) void {
    removeLine(&t.print_state.kittyDisplayReflowBoundaries, line);
}
pub fn isEffectiveKittyDisplayReflowDeparture(t: anytype, line: *Line, screen: anytype) bool {
    if (line.usedLength() > 0) return true;
    if (screen != &t.normal) return false;
    var row: isize = 0;
    while (row < screen.lineCount()) : (row += 1) {
        if (screen.line(row) == line) {
            for (t.blocks.blocks.items) |block| if (block.prompt_row == row or block.command_row == row) return true;
            return false;
        }
    }
    return false;
}
pub fn demoteKittyDisplayReflowClaimToBoundary(t: anytype, line: *Line) !void {
    if (!hasKittyDisplayReflowClaim(t, line)) return;
    try retainUniqueLine(t.allocator, &t.print_state.kittyDisplayReflowBoundaries, line);
    removeLine(&t.print_state.kittyDisplayReflowClaims, line);
}
pub fn clearKittyDisplayReflowClaims(t: anytype, screen: anytype) void {
    inline for (.{ "kittyDisplayReflowClaims", "kittyDisplayReflowBoundaries", "kittyDisplayClippedTopReflowRanks" }) |name| {
        const list = &@field(t.print_state, name);
        var i: usize = 0;
        while (i < list.items.len) {
            if (containsLine(screen, list.items[i])) {
                const removed = list.orderedRemove(i);
                removed.release();
            } else i += 1;
        }
    }
    @import("terminal_protocols.zig").pruneKittyDisplayReflowImages(t);
}
pub fn retireKittyDisplayReflowClaimDisplacedFromBottom(t: anytype, previous: *Line, screen: anytype) void {
    if (containsLine(screen, previous) and screen.liveLine(screen.scroll_bottom) == previous) return;
    removeLine(&t.print_state.kittyDisplayReflowClaims, previous);
    const list = &t.print_state.kittyDisplayReflowImageTransfers;
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].source == previous) {
            var removed = list.orderedRemove(i);
            removed.deinit();
        } else i += 1;
    }
}
pub fn advanceForPendingWrap(t: anytype, columns: Bounds) anyerror!bool {
    const b = t.buffer();
    const consumed_pending = b.wrap_pending;
    const began_exterior = !consumed_pending and b.x > columns.last;
    const advanced_bottom = b.y == b.scroll_bottom;
    const whole_bottom = advanced_bottom and !t.hasNarrowMargins() and b.x >= columns.last;
    const scroll_below = b.wrap_pending and pendingWrapOwnerStillOccupiesDeparture(t) and b.scroll_top < b.scroll_bottom and
        b.y > b.scroll_bottom and (b.scroll_top == 0 or b.y < b.rows - 1);
    const scroll_stored = t.margin_mode and t.auto_wrap and !b.wrap_pending and b.margin_right < b.cols - 1 and b.x == b.cols - 1 and b.y > b.scroll_bottom;
    if (scroll_below) {
        try motion.engineScrollUp(t, false, true, false);
    } else if (scroll_stored) {
        try motion.engineScrollUp(t, true, true, false);
    } else if (advanced_bottom) {
        try motion.engineScrollUp(t, true, true, false);
        b.y = b.scroll_bottom;
        if (whole_bottom) {
            const destination = b.liveLine(b.scroll_bottom);
            clearActiveMarginReflowBoundary(t, destination);
            clearSupersededKittyDisplayReflowState(t, destination);
        }
    } else if (b.y < b.rows - 1) {
        const departure = b.liveLine(b.y);
        b.y += 1;
        const destination = b.liveLine(b.y);
        if (consumed_pending) {
            if (t.hasNarrowMargins()) {
                clearSupersededKittyDisplayReflowState(t, destination);
            } else {
                const claimed = hasKittyDisplayReflowClaim(t, destination);
                clearSupersededKittyDisplayReflowState(t, destination);
                if (!claimed and b.y + 1 < b.rows) clearSupersededKittyDisplayReflowState(t, b.liveLine(b.y + 1));
            }
        } else if (hasKittyDisplayReflowClaim(t, destination)) {
            if (t.hasNarrowMargins() and !began_exterior) {
                if (isEffectiveKittyDisplayReflowDeparture(t, departure, b)) clearSupersededKittyDisplayReflowState(t, destination) else {
                    clearKittyDisplayReflowBoundary(t, departure);
                    try demoteKittyDisplayReflowClaimToBoundary(t, destination);
                }
            } else {
                clearKittyDisplayReflowBoundary(t, departure);
                try demoteKittyDisplayReflowClaimToBoundary(t, destination);
            }
        } else clearSupersededKittyDisplayReflowState(t, destination);
        destination.setWrapped(true);
        clearActiveMarginReflowBoundary(t, destination);
    }
    b.x = columns.first;
    b.wrap_pending = false;
    invalidateClusterContinuation(t, false);
    return advanced_bottom;
}

pub fn printASCII(t: anytype, bytes: []const u8) anyerror!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const byte = bytes[offset];
        if (byte < 0x20 or byte > 0x7e) {
            // Public direct calls preserve literal byte-to-scalar semantics.
            try printScalar(t, byte);
            offset += 1;
        } else {
            // The shared transaction falls back at modes, wraps and witnesses;
            // its ASCII entry never decodes subsequent bytes as UTF-8.
            offset += try @import("ordinary_printing.zig").printASCII(t, bytes[offset..]);
        }
    }
    t.markDirty(t.buffer().y_base + t.buffer().y);
}
pub fn setActiveBuffer(t: anytype, alternate: bool) anyerror!void {
    if (t.is_alternate != alternate) {
        try motion.captureReverseIndexBufferDeparture(t);
        t.is_alternate = alternate;
        t.print_state.bufferActivationSerial +%= 1;
    }
}
pub const executeControl = motion.executeControl;
pub fn engineScrollUp(t: anytype, wrapped: bool) anyerror!void {
    try motion.engineScrollUp(t, wrapped, true, false);
}
pub fn engineScrollDown(t: anytype) anyerror!void {
    try motion.engineScrollDown(t, false);
}
pub const indexLineFeed = motion.indexLineFeed;
pub const reverseLineFeed = motion.reverseLineFeed;
pub const rebindMarginDeleteGenerationWitnesses = motion.rebindMarginDeleteGenerationWitnesses;
pub const refreshInsertLineOwnerAfterUpwardLineRotation = motion.refreshInsertLineOwnerAfterUpwardLineRotation;
pub const clearActiveReverseIndexOwnerRefreshWitness = motion.clearActiveReverseIndexOwnerRefreshWitness;
pub const clearReverseIndexOwnerRefreshWitnesses = motion.clearReverseIndexOwnerRefreshWitnesses;
pub fn clearBackwardColumnAttachmentWitness(t: anytype) void {
    backwardWitness(t).* = null;
}

fn hostNewline(t: anytype) anyerror!void {
    try executeControl(t, 0x0d);
    try executeControl(t, 0x0a);
}
fn hostSoftWrap(t: anytype) anyerror!void {
    const b = t.buffer();
    b.x = 0;
    if (b.y >= b.scroll_bottom) try engineScrollUp(t, true) else {
        b.y += 1;
        b.liveLine(b.y).setWrapped(true);
    }
    b.liveLine(b.y).wrap_style = .words;
    b.liveLine(b.y).touch();
}
fn hostPrintWord(t: anytype, word: []const u32) anyerror!void {
    if (word.len == 0) return;
    var width: isize = 0;
    for (word) |scalar| width +|= @max(0, @as(isize, unicode.width(scalar)));
    const b = t.buffer();
    if (width < b.cols and b.x > 0 and b.x +| width > b.cols) try hostSoftWrap(t);
    for (word) |scalar| try printScalar(t, scalar);
}
pub fn insertHostMessage(t: anytype, text: []const u8) anyerror!void {
    if (t.is_alternate or text.len == 0) return;
    const sets = @import("character_sets.zig");
    const valid = try @import("osc.zig").normalizeUTF8(t.allocator, text);
    defer t.allocator.free(valid);
    const view = try std.unicode.Utf8View.init(valid);
    var iterator = view.iterator();
    var scalars: std.ArrayList(u32) = .empty;
    defer scalars.deinit(t.allocator);
    while (iterator.nextCodepoint()) |scalar| try scalars.append(t.allocator, scalar);
    var start: usize = 0;
    var end = scalars.items.len;
    while (start < end and sets.trim(scalars.items[start])) start += 1;
    while (end > start and sets.trim(scalars.items[end - 1])) end -= 1;
    if (start == end) return;
    const saved_pen = t.pen;
    const saved_link = t.active_link_id;
    const saved_state = t.writing_host_message;
    t.pen = .{ .style = 32 };
    t.active_link_id = 0;
    t.writing_host_message = true;
    defer {
        t.pen = saved_pen;
        t.active_link_id = saved_link;
        t.writing_host_message = saved_state;
    }
    if (t.buffer().x != 0) try hostNewline(t);
    var word_start = start;
    var current = start;
    while (current < end) : (current += 1) {
        const scalar = scalars.items[current];
        if (scalar == '\n' or scalar == '\r' or sets.whitespace(scalar)) {
            try hostPrintWord(t, scalars.items[word_start..current]);
            if (scalar == '\n') try hostNewline(t) else if (scalar == '\r') try executeControl(t, 0x0d) else try printScalar(t, scalar);
            word_start = current + 1;
        }
    }
    try hostPrintWord(t, scalars.items[word_start..end]);
    try hostNewline(t);
    t.markAllDirty();
    t.emit(.{ .kind = .content_changed });
}
