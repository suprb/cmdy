//! Worker-owned callback policy. Suppression changes observation only: the
//! scheduler and GPU still process every action, commit and completion.
const std = @import("std");
const Actions = @import("render_schedule.zig").Actions;
const timer_stops = [_]u32{ Actions.stop_animation, Actions.stop_coalesced, Actions.stop_keyboard, Actions.stop_recovery };
const timer_starts = [_]u32{ Actions.start_animation, Actions.start_coalesced, Actions.start_keyboard, Actions.start_recovery };

pub const Policy = struct {
    essential: bool = false,
    host_work_only: bool = false,
    observe_frames: bool = false,
    healthy_epoch: u64 = 0,
    healthy_revision: u64 = 0,
    stopped_host_timers: u32 = 0,

    pub fn hostWork(self: Policy, flags: u32, preferred_fps: i64) bool {
        // Unknown timer state must receive its first STOP. After an ordered
        // STOP has been delivered, another STOP alone cannot change the host.
        // Keep full action payloads whenever any work, reply or observer needs
        // delivery; START is never elided, even with an unchanged interval.
        const redundant = if (self.host_work_only and !self.observe_frames) self.stopped_host_timers else 0;
        return flags & ~redundant != 0 or preferred_fps > 0;
    }
    pub fn sentActions(self: *Policy, flags: u32) void {
        // Call only for delivered ACTIONS, including explicit replies and
        // worker-wakeup fallback. Other update kinds do not apply host timers.
        for (timer_stops, timer_starts) |stop, start| {
            if (flags & stop != 0) self.stopped_host_timers |= stop;
            if (flags & start != 0) self.stopped_host_timers &= ~stop;
        }
    }

    pub fn actions(self: Policy, host_work: bool, reply: bool, completion: bool) bool {
        return (!self.essential and !self.host_work_only) or host_work or reply or
            (completion and (!self.host_work_only or self.observe_frames));
    }
    pub fn frame(self: *Policy, committed: bool, epoch: u64, revision: u64) bool {
        const notify = !self.host_work_only or self.observe_frames or !committed or
            self.healthy_epoch != epoch or self.healthy_revision != revision;
        // A success from an obsolete scope must not hide a later current
        // success. The host filters frames by both epoch and source revision.
        self.healthy_epoch = if (committed) epoch else 0;
        self.healthy_revision = if (committed) revision else 0;
        return notify;
    }
    pub fn failure(self: *Policy) void {
        // An unscoped/source error also requires a later successful frame to
        // clear the host's failure state, even if its source is unchanged.
        self.healthy_epoch = 0;
        self.healthy_revision = 0;
    }
};

test "legacy and essential retain their completion and frame contracts" {
    for ([_]bool{ false, true }) |essential| {
        var p = Policy{ .essential = essential };
        try std.testing.expect(p.actions(false, false, true));
        try std.testing.expectEqual(!essential, p.actions(false, false, false));
        try std.testing.expect(p.actions(true, false, false));
        try std.testing.expect(p.actions(false, true, false));
        for (0..32) |_| try std.testing.expect(p.frame(true, 1, 1));
    }
}
test "host work mode preserves host work and replies while suppressing idle state" {
    const p = Policy{ .host_work_only = true };
    for ([_]bool{ false, true }) |completion| {
        try std.testing.expect(!p.actions(false, false, completion));
        try std.testing.expect(p.actions(true, false, completion));
        try std.testing.expect(p.actions(false, true, completion));
    }
}
test "healthy frame notification is scoped by epoch and revision" {
    var p = Policy{ .host_work_only = true };
    try std.testing.expect(p.frame(true, 1, 1));
    for (0..1000) |_| try std.testing.expect(!p.frame(true, 1, 1));
    try std.testing.expect(p.frame(true, 2, 1));
    try std.testing.expect(!p.frame(true, 2, 1));
    try std.testing.expect(p.frame(true, 2, 2));
    try std.testing.expect(!p.frame(true, 2, 2));
}
test "every failed frame and subsequent recovery remains visible" {
    var p = Policy{ .host_work_only = true };
    _ = p.frame(true, 1, 1);
    for (0..32) |_| try std.testing.expect(p.frame(false, 1, 1));
    try std.testing.expect(p.frame(true, 1, 1));
    try std.testing.expect(!p.frame(true, 1, 1));
}
test "source errors reset healthy reporting without requiring a new epoch" {
    var p = Policy{ .host_work_only = true };
    _ = p.frame(true, 7, 9);
    p.failure();
    try std.testing.expect(p.frame(true, 7, 9));
    try std.testing.expect(!p.frame(true, 7, 9));
}
test "observation restores frames and completions without all intermediate state" {
    var p = Policy{ .host_work_only = true, .observe_frames = true };
    for (0..32) |_| {
        try std.testing.expect(p.frame(true, 1, 1));
        try std.testing.expect(p.actions(false, false, true));
        try std.testing.expect(!p.actions(false, false, false));
    }
    p.observe_frames = false;
    try std.testing.expect(!p.frame(true, 1, 1));
    try std.testing.expect(!p.actions(false, false, true));
    try std.testing.expect(p.actions(false, true, true));
}

test "each timer preserves first stop and every restart before omitting duplicate stops" {
    const t = std.testing;
    var p = Policy{ .host_work_only = true };
    for (timer_stops, timer_starts) |stop, start| {
        try t.expect(p.hostWork(stop, 0));
        p.sentActions(stop);
        for (0..16) |_| try t.expect(!p.hostWork(stop, 0));
        try t.expect(p.hostWork(start, 0));
        p.sentActions(start);
        try t.expect(p.hostWork(start, 0));
        try t.expect(p.hostWork(stop, 0));
        p.sentActions(stop | start);
        try t.expect(p.hostWork(stop, 0));
        p.sentActions(stop);
        try t.expect(!p.hostWork(stop, 0));
    }
}

test "other host work replies and observers preserve complete action payloads" {
    const t = std.testing;
    var p = Policy{ .host_work_only = true };
    const stops = Actions.stop_animation | Actions.stop_coalesced | Actions.stop_keyboard | Actions.stop_recovery;
    p.sentActions(stops);
    try t.expect(!p.hostWork(stops, 0));
    for ([_]u32{ Actions.invalidate_view, Actions.queue_service, Actions.draw_manual, 1 << 31 }) |work|
        try t.expect(p.hostWork(stops | work, 0));
    try t.expect(p.hostWork(stops, 60));
    try t.expect(p.actions(p.hostWork(stops, 0), true, false));
    p.observe_frames = true;
    try t.expect(p.hostWork(stops, 0));
    p.sentActions(Actions.start_recovery);
    p.observe_frames = false;
    try t.expect(p.hostWork(Actions.stop_recovery, 0));
    try t.expect(!p.hostWork(Actions.stop_keyboard, 0));
    for ([_]bool{ false, true }) |essential| {
        var legacy = Policy{ .essential = essential };
        legacy.sentActions(stops);
        try t.expect(legacy.hostWork(stops, 0));
    }
}

test "filtered delivery preserves independent host timer lifetimes over mixed action traces" {
    const t = std.testing;
    var random = std.Random.DefaultPrng.init(0x53544f5054494d45);
    const rng = random.random();
    var p = Policy{ .host_work_only = true };
    var reference: [4]u64 = @splat(0);
    var delivered: [4]u64 = @splat(0);
    var suppressed: usize = 0;
    for (1..100001) |step| {
        const flags = rng.int(u32) & 0x7ff;
        const fps: i64 = if (rng.uintLessThan(u8, 16) == 0) 120 else 0;
        const reply = rng.uintLessThan(u8, 16) == 0;
        p.observe_frames = rng.uintLessThan(u8, 32) == 0;
        const send = p.actions(p.hostWork(flags, fps), reply, false);
        for (timer_stops, timer_starts, 0..) |stop, start, index| {
            if (flags & stop != 0) reference[index] = 0;
            if (flags & start != 0) reference[index] = @intCast(step);
            if (send) {
                if (flags & stop != 0) delivered[index] = 0;
                if (flags & start != 0) delivered[index] = @intCast(step);
            }
        }
        if (send) p.sentActions(flags) else {
            suppressed += 1;
            try t.expect(!reply and fps == 0);
            try t.expect(flags & (Actions.invalidate_view | Actions.queue_service | Actions.draw_manual) == 0);
        }
        try t.expectEqualSlices(u64, &reference, &delivered);
    }
    try t.expect(suppressed > 100);
}
