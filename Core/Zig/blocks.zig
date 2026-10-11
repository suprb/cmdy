//! Semantic command blocks. No wall clock or host callbacks are read here:
//! timestamps are injected and the caller publishes callbacks after mutation.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Position = struct { row: isize, col: isize };
pub const Block = struct {
    pub const LifetimeObserver = struct {
        context: *anyopaque,
        retained: *const fn (*anyopaque, *Block) void,
        final_release: *const fn (*anyopaque, *Block) bool,
    };
    allocator: Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    lifetime_observer: ?LifetimeObserver = null,
    index: u64,
    prompt_row: isize,
    input_start: ?Position = null,
    command_row: isize,
    end_row: ?isize = null,
    exit_code: ?isize = null,
    running: bool = false,
    started_at: f64,
    finished_at: ?f64 = null,

    pub fn retain(self: *Block) *Block {
        const previous = self.refs.fetchAdd(1, .monotonic);
        std.debug.assert(previous > 0 and previous < std.math.maxInt(usize));
        if (self.lifetime_observer) |observer| observer.retained(observer.context, self);
        return self;
    }

    pub fn release(self: *Block) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.lifetime_observer) |observer| if (observer.final_release(observer.context, self)) return;
        self.allocator.destroy(self);
    }
};
pub const TerminalBlock = Block;

pub const BlockTracker = struct {
    allocator: Allocator,
    blocks: std.ArrayList(*Block) = .empty,
    next_index: u64 = 1,
    generation: u64 = 0,
    /// Optional host limit. The default retains the Swift tracker's semantics.
    max_blocks: usize = std.math.maxInt(usize),

    pub fn init(a: Allocator) BlockTracker { return .{ .allocator = a }; }

    pub fn deinit(self: *BlockTracker) void {
        for (self.blocks.items) |block| block.release();
        self.blocks.deinit(self.allocator);
        self.* = undefined;
    }

    fn changed(self: *BlockTracker) void { self.generation +%= 1; }

    pub fn promptStarted(self: *BlockTracker, row: isize, timestamp: f64) error{ OutOfMemory, TooManyBlocks, IndexExhausted }!void {
        if (self.blocks.items.len >= self.max_blocks) return error.TooManyBlocks;
        if (self.next_index == std.math.maxInt(u64)) return error.IndexExhausted;
        try self.blocks.ensureUnusedCapacity(self.allocator, 1);
        const block = try self.allocator.create(Block);
        block.* = .{ .allocator = self.allocator, .index = self.next_index, .prompt_row = row,
            .command_row = row, .started_at = timestamp };
        self.blocks.appendAssumeCapacity(block);
        self.next_index += 1;
        self.changed();
    }

    /// As in Swift, even an unmatched B emits the state-change notification.
    pub fn promptEnded(self: *BlockTracker, row: isize, col: isize) void {
        if (self.blocks.items.len != 0) self.blocks.items[self.blocks.items.len - 1].input_start = .{ .row = row, .col = col };
        self.changed();
    }

    pub fn commandStarted(self: *BlockTracker, row: isize) bool {
        if (self.blocks.items.len == 0) return false;
        const block = self.blocks.items[self.blocks.items.len - 1];
        block.command_row = row;
        block.running = true;
        self.changed();
        return true;
    }

    /// Returns a borrowed object. Retain before a callback can prune/reset the
    /// tracker; all retained aliases continue observing subsequent row rebases.
    pub fn commandFinished(self: *BlockTracker, row: isize, exit_code: ?isize, timestamp: f64) ?*Block {
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const block = self.blocks.items[i];
            if (!block.running) continue;
            block.end_row = row;
            block.exit_code = exit_code;
            block.running = false;
            block.finished_at = timestamp;
            self.changed();
            return block;
        }
        // A blank Return may emit D without C. Never close a previous command.
        return null;
    }

    pub fn isRunning(self: *const BlockTracker) bool {
        return self.blocks.items.len != 0 and self.blocks.items[self.blocks.items.len - 1].running;
    }

    pub fn lastCompletedBlock(self: *const BlockTracker) ?*Block {
        var i = self.blocks.items.len;
        while (i > 0) {
            i -= 1;
            const block = self.blocks.items[i];
            if (!block.running and block.end_row != null) return block;
        }
        return null;
    }

    pub fn rebase(self: *BlockTracker, dropped: isize) void {
        if (dropped <= 0) return;
        var written: usize = 0;
        for (self.blocks.items) |block| {
            block.prompt_row -|= dropped;
            block.command_row -|= dropped;
            if (block.end_row) |end| block.end_row = end -| dropped;
            if (block.input_start) |start| block.input_start = .{ .row = start.row -| dropped, .col = start.col };
            if (block.prompt_row < 0) { block.release(); continue; }
            self.blocks.items[written] = block;
            written += 1;
        }
        self.blocks.items.len = written;
        self.changed();
    }

    /// map(context,row) must be a pure mapping and must not mutate this tracker.
    pub fn remapRows(self: *BlockTracker, context: anytype, comptime map: fn (@TypeOf(context), isize) isize) void {
        var written: usize = 0;
        for (self.blocks.items) |block| {
            block.prompt_row = map(context, block.prompt_row);
            block.command_row = map(context, block.command_row);
            if (block.end_row) |end| block.end_row = map(context, end);
            if (block.input_start) |start| block.input_start = .{ .row = map(context, start.row), .col = start.col };
            if (block.prompt_row < 0) { block.release(); continue; }
            self.blocks.items[written] = block;
            written += 1;
        }
        self.blocks.items.len = written;
        self.changed();
    }

    pub fn reset(self: *BlockTracker) void {
        for (self.blocks.items) |block| block.release();
        self.blocks.clearRetainingCapacity();
        // Identity is monotonic across reset, matching the original tracker.
        self.changed();
    }

    pub fn handleScrollbackCleared(self: *BlockTracker) void { self.reset(); }
};
