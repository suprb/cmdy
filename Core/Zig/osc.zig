//! Parsed OSC actions plus the engine's hyperlink table. Action strings borrow
//! the parser payload; the host must copy them before asynchronous delivery.
//! No platform APIs or real clipboard reads/writes exist in this module.
const std = @import("std");
const graphics = @import("graphics.zig");
const Allocator = std.mem.Allocator;

pub const BlockMarker = union(enum) {
    prompt_started,
    prompt_ended,
    command_started,
    command_finished: ?isize,
};

pub const Action = union(enum) {
    none,
    title: []const u8,
    current_directory: []const u8,
    hyperlink: []const u8,
    notification: struct { title: []const u8, body: []const u8 },
    /// Encoded write request only. Caller may decode after its host policy
    /// allows it; a query ('?') never produces an action.
    clipboard_write_encoded: []const u8,
    iterm2: []const u8,
    block: BlockMarker,
};

pub fn parse(code: isize, payload: []const u8) Action {
    switch (code) {
        0, 2 => return .{ .title = payload },
        7 => return .{ .current_directory = payload },
        8 => {
            const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return .none;
            return .{ .hyperlink = payload[separator + 1 ..] };
        },
        9 => return if (payload.len == 0) .none else .{ .notification = .{ .title = payload, .body = "" } },
        99 => {
            const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return .none;
            const body = payload[separator + 1 ..];
            return if (body.len == 0) .none else .{ .notification = .{ .title = body, .body = "" } };
        },
        777 => {
            const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return .none;
            if (!std.mem.eql(u8, payload[0..separator], "notify")) return .none;
            const rest = payload[separator + 1 ..];
            const body_separator = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
            return .{ .notification = .{ .title = rest[0..body_separator], .body = if (body_separator == rest.len) "" else rest[body_separator + 1 ..] } };
        },
        52 => {
            const separator = std.mem.indexOfScalar(u8, payload, ';') orelse return .none;
            const encoded = payload[separator + 1 ..];
            if (std.mem.eql(u8, encoded, "?")) return .none;
            return .{ .clipboard_write_encoded = encoded };
        },
        133 => {
            if (payload.len == 0) return .none;
            const marker: BlockMarker = switch (payload[0]) {
                'A' => .prompt_started,
                'B' => .prompt_ended,
                'C' => .command_started,
                'D' => blk: {
                    const separator = std.mem.indexOfScalar(u8, payload, ';') orelse break :blk .{ .command_finished = null };
                    const rest = payload[separator + 1 ..];
                    const end = std.mem.indexOfScalar(u8, rest, ';') orelse rest.len;
                    break :blk .{ .command_finished = graphics.decimalSigned(isize, rest[0..end]) catch null };
                },
                else => return .none,
            };
            return .{ .block = marker };
        },
        1337 => return .{ .iterm2 = payload },
        else => return .none,
    }
}

pub const LinkTable = struct {
    allocator: Allocator,
    entries: std.ArrayList([]const u8) = .empty,
    active_link_id: u16 = 0,
    bytes: usize = 0,
    max_entries: usize = std.math.maxInt(u16),
    max_bytes: usize = 128 * 1024 * 1024,

    pub fn init(a: Allocator) LinkTable { return .{ .allocator = a }; }
    pub fn deinit(self: *LinkTable) void {
        self.reset();
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Every open gets a fresh ID, matching existing semantics. IDs are never
    /// recycled while old cells can still reference them. At u16 exhaustion,
    /// disable the new run instead of aliasing an unrelated retained URI.
    pub fn open(self: *LinkTable, address: []const u8) error{ OutOfMemory, NoSpace }!u16 {
        if (address.len == 0) { self.active_link_id = 0; return 0; }
        errdefer self.active_link_id = 0;
        if (self.entries.items.len >= @min(self.max_entries, std.math.maxInt(u16)) or self.bytes > self.max_bytes or address.len > self.max_bytes - self.bytes) return error.NoSpace;
        const normalized = try normalizeUTF8(self.allocator, address);
        errdefer self.allocator.free(normalized);
        if (normalized.len > self.max_bytes - self.bytes) return error.NoSpace;
        try self.entries.append(self.allocator, normalized);
        self.bytes += normalized.len;
        self.active_link_id = @intCast(self.entries.items.len);
        return self.active_link_id;
    }

    /// Returned URI borrows the table. Copy it before table destruction/reset.
    pub fn uri(self: *const LinkTable, id: u16) ?[]const u8 {
        if (id == 0 or id > self.entries.items.len) return null;
        return self.entries.items[id - 1];
    }

    pub fn reset(self: *LinkTable) void {
        for (self.entries.items) |entry| self.allocator.free(entry);
        self.entries.clearRetainingCapacity();
        self.active_link_id = 0;
        self.bytes = 0;
    }
};

/// Unicode maximal-subpart replacement, matching String(decoding:as:UTF8).
pub fn normalizeUTF8(a: Allocator, bytes: []const u8) Allocator.Error![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return a.dupe(u8, bytes);
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(a);
    var index: usize = 0;
    while (index < bytes.len) {
        const first = bytes[index];
        if (first < 0x80) { try output.append(a, first); index += 1; continue; }
        const expected: usize = if (first >= 0xc2 and first <= 0xdf) 2 else if (first >= 0xe0 and first <= 0xef) 3 else if (first >= 0xf0 and first <= 0xf4) 4 else 0;
        var valid_prefix: usize = 1;
        if (expected > 0) {
            while (valid_prefix < expected and index + valid_prefix < bytes.len) : (valid_prefix += 1) {
                const byte = bytes[index + valid_prefix];
                if (byte < 0x80 or byte > 0xbf) break;
                if (valid_prefix == 1 and ((first == 0xe0 and byte < 0xa0) or (first == 0xed and byte >= 0xa0) or
                    (first == 0xf0 and byte < 0x90) or (first == 0xf4 and byte >= 0x90))) break;
            }
        }
        if (expected > 0 and valid_prefix == expected) {
            try output.appendSlice(a, bytes[index..][0..expected]);
            index += expected;
        } else {
            try output.appendSlice(a, "\xef\xbf\xbd");
            index += valid_prefix;
        }
    }
    return output.toOwnedSlice(a);
}
