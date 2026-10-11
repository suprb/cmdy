//! Immutable bounded viewport publication. Mutable terminal/buffer owners are
//! borrowed only during capture; render owners share one atomic snapshot handle.
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Line = @import("line.zig").Line;
pub const Error = error{ InvalidInput, OutOfMemory };

pub const Snapshot = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    first: isize,
    lines: []*Line,

    pub fn capture(allocator: std.mem.Allocator, buffer: *const Buffer, first: isize, count: usize) Error!*Snapshot {
        if (first < 0 or count > @as(usize, std.math.maxInt(isize)) / @sizeOf(*Line)) return error.InvalidInput;
        if (count != 0 and (first >= buffer.lineCount() or count > @as(usize, @intCast(buffer.lineCount() - first))))
            return error.InvalidInput;
        const lines = try allocator.alloc(*Line, count);
        var captured: usize = 0;
        errdefer {
            for (lines[0..captured]) |frozen| frozen.release();
            allocator.free(lines);
        }
        for (lines, 0..) |*slot, index| {
            const source = buffer.line(first + @as(isize, @intCast(index))) orelse return error.InvalidInput;
            slot.* = try source.renderSnapshotWithImages();
            captured += 1;
        }
        const self = try allocator.create(Snapshot);
        self.* = .{ .allocator = allocator, .first = first, .lines = lines };
        return self;
    }
    pub fn retain(self: *Snapshot) *Snapshot {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        return self;
    }
    pub fn release(self: *Snapshot) void {
        const previous = self.refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        const allocator = self.allocator;
        for (self.lines) |frozen| frozen.release();
        allocator.free(self.lines);
        allocator.destroy(self);
    }
    pub fn line(self: *const Snapshot, index: usize) ?*const Line {
        return if (index < self.lines.len) self.lines[index] else null;
    }
};

test {
    _ = @import("buffer_snapshot_tests.zig");
}
