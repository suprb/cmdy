//! Native VT500 byte parser. This is a port of CMDY's existing parser contract,
//! including its deliberate Latin-1-lead fallback for malformed UTF-8 and its
//! callback publication order. It does not interpret terminal commands.
//!
//! A sink supplies printScalar(u32), printASCII([]const u8), execute(u8),
//! csi(u8, []const isize, []const u8), esc(u8, []const u8),
//! osc(isize, []const u8), dcsHook(u8, []const isize, []const u8),
//! dcsPut([]const u8), dcsUnhook(), and apc([]const u8). Methods may return void
//! or an error union with void. Optional printASCIIAndCRLF and printASCIILines
//! methods preserve the existing coalesced ground-output boundaries.
//! Owner sinks may additionally provide printContiguousScalar,
//! executeGroundControl, and csiOwner to preserve the original owning-terminal
//! fast-path dispatch boundaries when its public delegate is overridden.
//!
//! Callback slices are immutable for the duration of that call, including
//! nested feed/reset calls. A sink retaining data after returning must copy it.
//! feed is not transactional on allocation failure; callers must surface that
//! failure rather than silently pretend the entire input was consumed.
const std = @import("std");
const Allocator = std.mem.Allocator;
// Preserve sink errors exactly. Native terminal operations may report invalid
// state as well as allocation failure; the C ABI owns their explicit mapping.
pub const Error = anyerror;
pub const colon_separator: isize = -1;
pub const max_string_payload: usize = 65_536;
pub const max_params: usize = 256;
pub const max_intermediates: usize = 16;
pub const dcs_flush_size: usize = 4096;

pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    osc_string,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    sos_pm_string,
    apc_string,
};

const PendingUTF8 = struct {
    bytes: [4]u8 = @splat(0),
    count: u3 = 0,
    expected: u3 = 0,

    fn init(lead: u8, expected: u3) PendingUTF8 {
        return .{ .bytes = .{ lead, 0, 0, 0 }, .count = 1, .expected = expected };
    }

    fn append(self: *PendingUTF8, byte: u8) void {
        self.bytes[self.count] = byte;
        self.count += 1;
    }

    fn scalar(self: PendingUTF8) u32 {
        return std.unicode.utf8Decode(self.bytes[0..self.count]) catch self.bytes[0];
    }
};

pub const Parser = struct {
    allocator: Allocator,
    state: State = .ground,
    params: std.ArrayList(isize) = .empty,
    collect: std.ArrayList(u8) = .empty,
    osc_buffer: std.ArrayList(u8) = .empty,
    apc_buffer: std.ArrayList(u8) = .empty,
    dcs_buffer: std.ArrayList(u8) = .empty,
    osc_pending_escape: bool = false,
    apc_pending_escape: bool = false,
    dcs_pending_escape: bool = false,
    utf8_pending: PendingUTF8 = .{},
    coalesces_printable_ascii: bool = true,
    decodes_contiguous_utf8: bool = true,
    // The scalar path remains the reference implementation until a native
    // ordinary-Unicode batch sink is installed. This flag is shared with the
    // embedded parser, rather than being a facade-only diagnostic switch.
    batches_ordinary_unicode: bool = true,
    coalesces_csi_parameters: bool = true,

    pub fn init(allocator: Allocator) Error!Parser {
        var self: Parser = .{ .allocator = allocator };
        // reset and entering a sequence never need to allocate the seed slot.
        try self.params.append(allocator, 0);
        return self;
    }

    pub fn deinit(self: *Parser) void {
        self.params.deinit(self.allocator);
        self.collect.deinit(self.allocator);
        self.osc_buffer.deinit(self.allocator);
        self.apc_buffer.deinit(self.allocator);
        self.dcs_buffer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reset(self: *Parser) void {
        self.state = .ground;
        self.clearSequence();
        self.utf8_pending = .{};
        // Match the existing reset contract: string buffers and pending ST
        // flags are replaced when their corresponding string is entered.
    }

    pub fn canContinueOrdinaryUnicodeBatch(self: *const Parser) bool {
        return self.state == .ground and self.utf8_pending.expected == 0;
    }

    fn clearSequence(self: *Parser) void {
        self.params.clearRetainingCapacity();
        self.params.appendAssumeCapacity(0);
        self.collect.clearRetainingCapacity();
    }

    fn enterEscape(self: *Parser) void {
        self.utf8_pending = .{};
        self.clearSequence();
        self.state = .escape;
    }

    pub fn feed(self: *Parser, bytes: []const u8, sink: anytype) Error!void {
        var index: usize = 0;
        while (index < bytes.len) {
            if (self.coalesces_printable_ascii and self.canContinueOrdinaryUnicodeBatch() and printableASCII(bytes[index])) {
                const start = index;
                index = printableASCIIEnd(bytes, index);
                if (bytes.len - index >= 2 and bytes[index] == '\r' and bytes[index + 1] == '\n') {
                    const after_first = index + 2;
                    var batch_end = after_first;
                    var batch_lines: usize = 1;
                    var scan = after_first;
                    while (scan < bytes.len and printableASCII(bytes[scan])) {
                        scan = printableASCIIEnd(bytes, scan);
                        if (bytes.len - scan < 2 or bytes[scan] != '\r' or bytes[scan + 1] != '\n') break;
                        batch_end = scan + 2;
                        batch_lines += 1;
                        scan = batch_end;
                    }
                    if (batch_lines > 1) {
                        try printASCIILines(sink, bytes[start..batch_end]);
                        index = batch_end;
                        continue;
                    }
                    try printASCIIAndCRLF(sink, bytes[start..index]);
                    index = after_first;
                    continue;
                }
                try result(sink.printASCII(bytes[start..index]));
            } else if (if (self.decodes_contiguous_utf8 and self.canContinueOrdinaryUnicodeBatch()) contiguousUTF8(bytes[index..]) else null) |decoded| {
                if (@hasDecl(SinkType(@TypeOf(sink)), "printContiguousUnicode") and self.batches_ordinary_unicode) {
                    const consumed = try sink.printContiguousUnicode(bytes[index..], decoded.scalar, decoded.count, self);
                    if (consumed < decoded.count or consumed > bytes.len - index) return error.InvalidInput;
                    index += consumed;
                } else {
                    index += decoded.count;
                    // No parser state is held across the scalar callback. A
                    // nested feed may establish a partial scalar or sequence.
                    if (@hasDecl(SinkType(@TypeOf(sink)), "printContiguousScalar")) {
                        try result(sink.printContiguousScalar(decoded.scalar));
                    } else try result(sink.printScalar(decoded.scalar));
                }
            } else if (self.coalesces_csi_parameters and self.canContinueOrdinaryUnicodeBatch() and
                bytes.len - index >= 2 and bytes[index] == 0x1b and bytes[index + 1] == '[')
            {
                const prefix = try self.consumeCSIParameterPrefix(bytes, index);
                index = prefix.end;
                if (prefix.final) |final| {
                    self.state = .ground;
                    if (@hasDecl(SinkType(@TypeOf(sink)), "csiOwner")) {
                        var parameters: [32]isize = undefined;
                        const values = parameters[0..self.params.items.len];
                        @memcpy(values, self.params.items);
                        try result(sink.csiOwner(final, values, &.{}));
                    } else try self.dispatchParameters(final, sink, false);
                }
            } else if (@hasDecl(SinkType(@TypeOf(sink)), "executeGroundControl") and
                self.canContinueOrdinaryUnicodeBatch() and (bytes[index] == '\r' or bytes[index] == '\n'))
            {
                try result(sink.executeGroundControl(bytes[index]));
                index += 1;
            } else {
                try self.step(bytes[index], sink);
                index += 1;
            }
        }
    }

    fn consumeCSIParameterPrefix(self: *Parser, bytes: []const u8, start: usize) Error!struct { end: usize, final: ?u8 } {
        var values: [32]isize = undefined;
        var index = start + 2;
        const limit = start + @min(bytes.len - start, 256);
        var count: usize = 0;
        var value: isize = 0;
        var has_parameter_byte = false;
        var final: ?u8 = null;
        while (index < limit) {
            const byte = bytes[index];
            if (byte >= '0' and byte <= '9') {
                value = @min(0xffff, value * 10 + byte - '0');
                has_parameter_byte = true;
            } else if (byte == ';') {
                if (count + 1 >= values.len) break;
                values[count] = value;
                count += 1;
                value = 0;
                has_parameter_byte = true;
            } else if (byte >= 0x40 and byte <= 0x7e) {
                final = byte;
                index += 1;
                break;
            } else break;
            index += 1;
        }
        values[count] = value;
        count += 1;
        try self.params.ensureTotalCapacity(self.allocator, count);
        self.params.clearRetainingCapacity();
        self.params.appendSliceAssumeCapacity(values[0..count]);
        self.collect.clearRetainingCapacity();
        self.state = if (has_parameter_byte) .csi_param else .csi_entry;
        return .{ .end = index, .final = final };
    }

    fn step(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (self.state) {
            .ground => try self.stepGround(b, sink),
            .escape => try self.stepEscape(b, sink),
            .escape_intermediate => try self.stepEscapeIntermediate(b, sink),
            .csi_entry => try self.stepCSIEntry(b, sink),
            .csi_param => try self.stepCSIParam(b, sink),
            .csi_intermediate => try self.stepCSIIntermediate(b, sink),
            .csi_ignore => try self.stepCSIIgnore(b, sink),
            .osc_string => try self.stepOSC(b, sink),
            .dcs_entry => try self.stepDCSEntry(b, sink),
            .dcs_param => try self.stepDCSParam(b, sink),
            .dcs_intermediate => try self.stepDCSIntermediate(b, sink),
            .dcs_passthrough => try self.stepDCSPassthrough(b, sink),
            .dcs_ignore => self.stepDCSIgnore(b),
            .sos_pm_string => self.stepSOSPM(b),
            .apc_string => try self.stepAPC(b, sink),
        }
    }

    fn divertC1(self: *Parser, b: u8) bool {
        switch (b) {
            0x90 => {
                self.clearSequence();
                self.state = .dcs_entry;
            },
            0x9b => {
                self.clearSequence();
                self.state = .csi_entry;
            },
            0x9d => {
                self.osc_buffer.clearRetainingCapacity();
                self.osc_pending_escape = false;
                self.state = .osc_string;
            },
            0x98, 0x9e => self.state = .sos_pm_string,
            0x9f => {
                self.apc_buffer.clearRetainingCapacity();
                self.apc_pending_escape = false;
                self.state = .apc_string;
            },
            0x80...0x8f, 0x91...0x97, 0x99...0x9a, 0x9c, 0xa0...0xff => self.state = .ground,
            else => return false,
        }
        return true;
    }

    fn stepGround(self: *Parser, b: u8, sink: anytype) Error!void {
        if (self.utf8_pending.expected > 0) {
            if (b == 0x1b) {
                self.enterEscape();
                return;
            }
            if (b < 0x20) {
                try result(sink.execute(b));
                return;
            }
            // Malformed completions consume their entire expected tail and
            // print the Latin-1 lead. C0 bytes above do not consume tail slots.
            self.utf8_pending.append(b);
            if (self.utf8_pending.count == self.utf8_pending.expected) {
                const pending = self.utf8_pending;
                self.utf8_pending = .{};
                try result(sink.printScalar(pending.scalar()));
            }
            return;
        }
        switch (b) {
            0x1b => self.enterEscape(),
            0x00...0x1a, 0x1c...0x1f => try result(sink.execute(b)),
            0x20...0x7f => try result(sink.printScalar(b)),
            0x80...0x9f => {}, // Raw C1 is inert in ground; decoded C1 prints.
            0xc2...0xdf => self.utf8_pending = PendingUTF8.init(b, 2),
            0xe0...0xef => self.utf8_pending = PendingUTF8.init(b, 3),
            0xf0...0xf4 => self.utf8_pending = PendingUTF8.init(b, 4),
            else => try result(sink.printScalar(b)),
        }
    }

    fn stepEscape(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => {
                self.state = .ground;
                try result(sink.execute(b));
            },
            0x00...0x17, 0x19, 0x1c...0x1f => try result(sink.execute(b)),
            0x20...0x2f => {
                try self.collect.append(self.allocator, b);
                self.state = .escape_intermediate;
            },
            0x5b, 0x9b => {
                self.clearSequence();
                self.state = .csi_entry;
            },
            0x5d, 0x9d => {
                self.osc_buffer.clearRetainingCapacity();
                self.state = .osc_string;
            },
            0x50, 0x90 => {
                self.clearSequence();
                self.state = .dcs_entry;
            },
            0x58, 0x5e, 0x98, 0x9e => self.state = .sos_pm_string,
            0x5f, 0x9f => {
                self.apc_buffer.clearRetainingCapacity();
                self.apc_pending_escape = false;
                self.state = .apc_string;
            },
            else => {
                self.state = .ground;
                try self.dispatchESC(b, sink);
            },
        }
    }

    fn stepEscapeIntermediate(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => {
                self.state = .ground;
                try result(sink.execute(b));
            },
            0x00...0x17, 0x19, 0x1c...0x1f => try result(sink.execute(b)),
            0x20...0x2f => try self.collect.append(self.allocator, b),
            else => {
                self.state = .ground;
                try self.dispatchESC(b, sink);
            },
        }
    }

    fn dispatchESC(self: *Parser, final: u8, sink: anytype) Error!void {
        var stack: [max_intermediates]u8 = undefined;
        const collected = try snapshot(u8, self.allocator, self.collect.items, &stack);
        defer if (collected.len > stack.len) self.allocator.free(collected);
        try result(sink.esc(final, collected));
    }

    fn dispatchParameters(self: *Parser, final: u8, sink: anytype, comptime dcs: bool) Error!void {
        // CSI's final colon may add two slots at count 255, so its actual
        // accepted maximum is 257. DCS retains its existing uncapped lists.
        var param_stack: [max_params + 1]isize = undefined;
        var collect_stack: [max_intermediates]u8 = undefined;
        const parameters = try snapshot(isize, self.allocator, self.params.items, &param_stack);
        defer if (parameters.len > param_stack.len) self.allocator.free(parameters);
        const collected = try snapshot(u8, self.allocator, self.collect.items, &collect_stack);
        defer if (collected.len > collect_stack.len) self.allocator.free(collected);
        if (dcs) {
            try result(sink.dcsHook(final, parameters, collected));
        } else {
            try result(sink.csi(final, parameters, collected));
        }
    }

    fn dispatchCSI(self: *Parser, final: u8, sink: anytype) Error!void {
        self.state = .ground;
        try self.dispatchParameters(final, sink, false);
    }

    fn stepCSIEntry(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => {
                self.state = .ground;
                try result(sink.execute(b));
            },
            0x00...0x17, 0x19, 0x1c...0x1f => try result(sink.execute(b)),
            0x30...0x39 => {
                self.params.items[self.params.items.len - 1] = b - 0x30;
                self.state = .csi_param;
            },
            0x3b => {
                try self.params.append(self.allocator, 0);
                self.state = .csi_param;
            },
            0x3a, 0x3c...0x3f => {
                // A colon in entry is collected, unlike a later separator.
                try self.collect.append(self.allocator, b);
                self.state = .csi_param;
            },
            0x20...0x2f => {
                try self.collect.append(self.allocator, b);
                self.state = .csi_intermediate;
            },
            0x40...0x7e => try self.dispatchCSI(b, sink),
            0x80...0xff => _ = self.divertC1(b),
            else => self.state = .csi_ignore,
        }
    }

    fn stepCSIParam(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => {
                self.state = .ground;
                try result(sink.execute(b));
            },
            0x00...0x17, 0x19, 0x1c...0x1f => try result(sink.execute(b)),
            0x30...0x39 => self.accumulateDigit(b),
            0x3b => if (self.params.items.len < max_params) {
                try self.params.append(self.allocator, 0);
            },
            0x3a => if (self.params.items.len < max_params) {
                try self.params.appendSlice(self.allocator, &.{ colon_separator, 0 });
            },
            0x3c...0x3f => self.state = .csi_ignore,
            0x20...0x2f => {
                if (self.collect.items.len < max_intermediates) try self.collect.append(self.allocator, b);
                self.state = .csi_intermediate;
            },
            0x40...0x7e => try self.dispatchCSI(b, sink),
            0x80...0xff => _ = self.divertC1(b),
            else => self.state = .csi_ignore,
        }
    }

    fn accumulateDigit(self: *Parser, b: u8) void {
        const slot = self.params.items.len - 1;
        self.params.items[slot] = @min(0xffff, self.params.items[slot] * 10 + @as(isize, b - 0x30));
    }

    fn stepCSIIntermediate(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => {
                self.state = .ground;
                try result(sink.execute(b));
            },
            0x00...0x17, 0x19, 0x1c...0x1f => try result(sink.execute(b)),
            0x20...0x2f => if (self.collect.items.len < max_intermediates) {
                try self.collect.append(self.allocator, b);
            },
            0x40...0x7e => try self.dispatchCSI(b, sink),
            0x80...0xff => self.state = .ground,
            else => self.state = .csi_ignore,
        }
    }

    fn stepCSIIgnore(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => {
                self.state = .ground;
                try result(sink.execute(b));
            },
            0x00...0x17, 0x19, 0x1c...0x1f => try result(sink.execute(b)),
            0x40...0x7e => self.state = .ground,
            0x80...0xff => _ = self.divertC1(b),
            else => {},
        }
    }

    fn stepOSC(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x07 => try self.dispatchOSC(sink),
            0x1b => {
                self.state = .osc_string;
                self.osc_pending_escape = true;
            },
            0x18, 0x1a => {
                self.osc_buffer.clearRetainingCapacity();
                self.osc_pending_escape = false;
                self.state = .ground;
            },
            else => {
                if (self.osc_pending_escape) {
                    self.osc_pending_escape = false;
                    if (b == 0x5c) {
                        try self.dispatchOSC(sink);
                        return;
                    }
                    self.osc_buffer.clearRetainingCapacity();
                    self.enterEscape();
                    try self.step(b, sink);
                    return;
                }
                if (self.osc_buffer.items.len < max_string_payload) try self.osc_buffer.append(self.allocator, b);
            },
        }
    }

    fn dispatchOSC(self: *Parser, sink: anytype) Error!void {
        // OSC historically calls the sink while still in osc_string, then
        // clears even state established by nested feed. Keep that ordering.
        defer {
            self.osc_buffer.clearRetainingCapacity();
            self.osc_pending_escape = false;
            self.state = .ground;
        }
        var code: isize = 0;
        var index: usize = 0;
        var saw_digit = false;
        while (index < self.osc_buffer.items.len and self.osc_buffer.items[index] >= '0' and self.osc_buffer.items[index] <= '9') : (index += 1) {
            code = @min(0x10ffff, code * 10 + @as(isize, self.osc_buffer.items[index] - '0'));
            saw_digit = true;
        }
        if (index < self.osc_buffer.items.len and self.osc_buffer.items[index] == ';') {
            index += 1;
        } else if (!saw_digit) {
            code = -1;
        }
        const payload = try self.allocator.dupe(u8, self.osc_buffer.items[index..]);
        defer self.allocator.free(payload);
        try result(sink.osc(code, payload));
    }

    fn stepDCSEntry(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => self.state = .ground,
            0x00...0x17, 0x19, 0x1c...0x1f => {},
            0x30...0x39 => {
                self.params.items[self.params.items.len - 1] = b - '0';
                self.state = .dcs_param;
            },
            0x3b => {
                try self.params.append(self.allocator, 0);
                self.state = .dcs_param;
            },
            0x3c...0x3f => {
                try self.collect.append(self.allocator, b);
                self.state = .dcs_param;
            },
            0x20...0x2f => {
                try self.collect.append(self.allocator, b);
                self.state = .dcs_intermediate;
            },
            0x40...0x7e => try self.hookDCS(b, sink),
            else => self.state = .dcs_ignore,
        }
    }

    fn stepDCSParam(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => self.state = .ground,
            0x00...0x17, 0x19, 0x1c...0x1f => {},
            0x30...0x39 => self.accumulateDigit(b),
            0x3b => try self.params.append(self.allocator, 0),
            0x3a, 0x3c...0x3f => self.state = .dcs_ignore,
            0x20...0x2f => {
                try self.collect.append(self.allocator, b);
                self.state = .dcs_intermediate;
            },
            0x40...0x7e => try self.hookDCS(b, sink),
            else => self.state = .dcs_ignore,
        }
    }

    fn stepDCSIntermediate(self: *Parser, b: u8, sink: anytype) Error!void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => self.state = .ground,
            0x00...0x17, 0x19, 0x1c...0x1f => {},
            0x20...0x2f => try self.collect.append(self.allocator, b),
            0x40...0x7e => try self.hookDCS(b, sink),
            else => self.state = .dcs_ignore,
        }
    }

    fn hookDCS(self: *Parser, final: u8, sink: anytype) Error!void {
        try self.dispatchParameters(final, sink, true);
        self.dcs_buffer.clearRetainingCapacity();
        self.dcs_pending_escape = false;
        self.state = .dcs_passthrough;
    }

    fn stepDCSPassthrough(self: *Parser, b: u8, sink: anytype) Error!void {
        if (self.dcs_pending_escape) {
            self.dcs_pending_escape = false;
            if (b == 0x5c) {
                try self.flushDCS(sink);
                try result(sink.dcsUnhook());
                self.state = .ground;
                return;
            }
            try self.dcs_buffer.append(self.allocator, 0x1b);
        }
        switch (b) {
            0x1b => self.dcs_pending_escape = true,
            0x18, 0x1a => {
                try self.flushDCS(sink);
                try result(sink.dcsUnhook());
                self.state = .ground;
            },
            else => {
                try self.dcs_buffer.append(self.allocator, b);
                if (self.dcs_buffer.items.len >= dcs_flush_size) try self.flushDCS(sink);
            },
        }
    }

    fn flushDCS(self: *Parser, sink: anytype) Error!void {
        if (self.dcs_buffer.items.len == 0) return;
        const payload = try self.allocator.dupe(u8, self.dcs_buffer.items);
        defer self.allocator.free(payload);
        try result(sink.dcsPut(payload));
        self.dcs_buffer.clearRetainingCapacity();
    }

    fn stepDCSIgnore(self: *Parser, b: u8) void {
        switch (b) {
            0x1b => self.dcs_pending_escape = true,
            0x18, 0x1a => self.state = .ground,
            0x5c => if (self.dcs_pending_escape) {
                self.dcs_pending_escape = false;
                self.state = .ground;
            },
            else => self.dcs_pending_escape = false,
        }
    }

    fn stepSOSPM(self: *Parser, b: u8) void {
        switch (b) {
            0x1b => self.enterEscape(),
            0x18, 0x1a => self.state = .ground,
            0x80...0x9f => _ = self.divertC1(b),
            else => {},
        }
    }

    fn stepAPC(self: *Parser, b: u8, sink: anytype) Error!void {
        if (self.apc_pending_escape) {
            self.apc_pending_escape = false;
            if (b == 0x5c) {
                try self.dispatchAPC(sink);
                return;
            }
            self.apc_buffer.clearRetainingCapacity();
            self.enterEscape();
            try self.step(b, sink);
            return;
        }
        switch (b) {
            0x1b => {
                // APC delivery happens at ESC, not at the following ST final.
                try self.dispatchAPC(sink);
                self.state = .escape;
            },
            0x18, 0x1a => {
                self.apc_buffer.clearRetainingCapacity();
                self.apc_pending_escape = false;
                self.state = .ground;
            },
            0x80...0x9f => {
                self.apc_buffer.clearRetainingCapacity();
                self.apc_pending_escape = false;
                _ = self.divertC1(b);
            },
            else => if (self.apc_buffer.items.len < max_string_payload) {
                try self.apc_buffer.append(self.allocator, b);
            },
        }
    }

    fn dispatchAPC(self: *Parser, sink: anytype) Error!void {
        const payload = try self.allocator.dupe(u8, self.apc_buffer.items);
        defer self.allocator.free(payload);
        self.apc_buffer.clearRetainingCapacity();
        self.apc_pending_escape = false;
        self.state = .ground;
        try result(sink.apc(payload));
    }
};

fn result(value: anytype) Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .void => {},
        .error_union => try value,
        else => @compileError("Parser sink methods must return void or an error union with void"),
    }
}

fn snapshot(comptime T: type, allocator: Allocator, input: []const T, stack: []T) Error![]const T {
    if (input.len > stack.len) return try allocator.dupe(T, input);
    @memcpy(stack[0..input.len], input);
    return stack[0..input.len];
}

fn printableASCII(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x7e;
}

fn printableASCIIEnd(bytes: []const u8, start: usize) usize {
    var end = start;
    while (end < bytes.len and printableASCII(bytes[end])) : (end += 1) {}
    return end;
}

pub fn contiguousUTF8(bytes: []const u8) ?struct { scalar: u32, count: usize } {
    if (bytes.len == 0 or bytes[0] < 0xc2 or bytes[0] > 0xf4) return null;
    const count = std.unicode.utf8ByteSequenceLength(bytes[0]) catch return null;
    if (bytes.len < count) return null;
    return .{ .scalar = std.unicode.utf8Decode(bytes[0..count]) catch return null, .count = count };
}

fn SinkType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |p| p.child,
        else => T,
    };
}

fn printASCIIAndCRLF(sink: anytype, bytes: []const u8) Error!void {
    if (@hasDecl(SinkType(@TypeOf(sink)), "printASCIIAndCRLF")) {
        try result(sink.printASCIIAndCRLF(bytes));
    } else {
        try result(sink.printASCII(bytes));
        try result(sink.execute('\r'));
        try result(sink.execute('\n'));
    }
}

fn printASCIILines(sink: anytype, bytes: []const u8) Error!void {
    if (@hasDecl(SinkType(@TypeOf(sink)), "printASCIILines")) {
        try result(sink.printASCIILines(bytes));
    } else {
        var index: usize = 0;
        while (index < bytes.len) {
            const start = index;
            index = printableASCIIEnd(bytes, index);
            try printASCIIAndCRLF(sink, bytes[start..index]);
            if (bytes.len - index < 2) return;
            index += 2;
        }
    }
}
