//! Render-owner deadlines. This contains no clock reads or allocation.
//! The session supplies time and schedules the earliest deadline on its worker.
const std = @import("std");
const schedule = @import("render_schedule.zig");
const Actions = schedule.Actions;

pub const Kind = enum(usize) { coalesced, recovery, keyboard, animation };
pub const kinds = [_]Kind{ .coalesced, .recovery, .keyboard, .animation };
const starts = [_]u32{ Actions.start_coalesced, Actions.start_recovery, Actions.start_keyboard, Actions.start_animation };
const stops = [_]u32{ Actions.stop_coalesced, Actions.stop_recovery, Actions.stop_keyboard, Actions.stop_animation };

pub const Deadlines = struct {
    due: [kinds.len]?f64 = @splat(null),
    owned: [kinds.len]bool = @splat(false),
    animation_interval: ?f64 = null,

    fn start(self: *Deadlines, kind: Kind, interval: f64, now: f64) bool {
        if (!std.math.isFinite(interval) or !std.math.isFinite(now)) return false;
        const cadence = @max(0.000001, interval);
        const next = now + cadence;
        if (!std.math.isFinite(next) or next <= now) return false;
        const index = @intFromEnum(kind);
        self.due[index] = next;
        self.owned[index] = true;
        if (kind == .animation) self.animation_interval = cadence;
        return true;
    }

    pub fn earliest(self: Deadlines) ?f64 {
        var result: ?f64 = null;
        for (self.due) |value| if (value) |time| {
            result = if (result) |previous| @min(previous, time) else time;
        };
        return result;
    }

    /// An owner STOP also cancels any older host timer. Keep the ownership
    /// fence after cancellation/firing: a host callback already in the FIFO
    /// must not restore an obsolete environment or consume a newer request.
    pub fn apply(self: *Deadlines, value: anytype, host: *@TypeOf(value), now: f64, can_own: bool) bool {
        var changed = false;
        const intervals = [_]f64{ value.coalesced_interval, value.recovery_interval, value.keyboard_interval, value.animation_interval };
        for (kinds, 0..) |kind, index| {
            if (value.flags & stops[index] != 0) {
                self.due[index] = null;
                if (kind == .animation) self.animation_interval = null;
                changed = true;
            }
            if (value.flags & starts[index] == 0) continue;
            changed = true;
            self.due[index] = null;
            self.owned[index] = false;
            if (kind == .animation) self.animation_interval = null;
            const host_ticked = kind == .animation and value.flags & Actions.display_locked != 0;
            if (can_own and !host_ticked and self.start(kind, intervals[index], now)) {
                host.flags = (host.flags & ~starts[index]) | stops[index];
            }
        }
        return changed;
    }

    /// Animation may have started on the host before the first immutable
    /// publication. The schedule emits no START when its cadence is unchanged,
    /// so take ownership once that publication becomes available. Later replies
    /// cannot postpone an already owned deadline.
    pub fn adoptAnimation(self: *Deadlines, interval: ?f64, host: anytype, now: f64, can_own: bool) bool {
        if (!can_own or self.owns(.animation)) return false;
        const cadence = interval orelse return false;
        if (!self.start(.animation, cadence, now)) return false;
        host.flags = (host.flags & ~Actions.start_animation) | Actions.stop_animation;
        return true;
    }

    pub fn owns(self: Deadlines, kind: Kind) bool {
        return self.owned[@intFromEnum(kind)];
    }

    pub fn takeDue(self: *Deadlines, kind: Kind, now: f64) bool {
        if (!std.math.isFinite(now)) return false;
        const index = @intFromEnum(kind);
        const time = self.due[index] orelse return false;
        if (time > now) return false;
        self.due[index] = null;
        if (kind == .animation) {
            const cadence = self.animation_interval.?;
            // Preserve cadence, skipping missed frames after a busy worker.
            // A delayed wakeup must never enqueue a burst of catch-up draws.
            var next = time + (@floor((now - time) / cadence) + 1) * cadence;
            if (!std.math.isFinite(next) or next <= now) next = now + cadence;
            if (std.math.isFinite(next) and next > now) self.due[index] = next;
        }
        return true;
    }

    /// If the worker cannot arm its wakeup, preserve the host fallback and
    /// remaining one-shot delays. Repeating animation restarts at its original
    /// cadence, rather than repeating at an arbitrarily short remaining delay.
    pub fn fallback(self: *Deadlines, host: anytype, now: f64) void {
        inline for (kinds, 0..) |kind, index| {
            if (self.due[index]) |time| {
                host.flags |= stops[index] | starts[index];
                const remaining = @max(0.000001, time - now);
                switch (kind) {
                    .coalesced => host.coalesced_interval = remaining,
                    .recovery => host.recovery_interval = remaining,
                    .keyboard => host.keyboard_interval = remaining,
                    .animation => host.animation_interval = self.animation_interval.?,
                }
                self.due[index] = null;
                self.owned[index] = false;
                if (kind == .animation) self.animation_interval = null;
            }
        }
    }
};

test "coalesced draws preserve the exact pacing deadline without early frames or postponed retries" {
    const t = std.testing;
    for ([_]i64{ 60, 120, 144 }) |maximum| {
        for ([_]bool{ false, true }) |key| {
            for ([_]bool{ false, true }) |low_power| {
                for (0..4) |thermal| {
                    const fps = schedule.interactiveFPS(key, @intCast(thermal), low_power, maximum);
                    const due = 10 + 1 / fps;
                    for ([_]f64{ 0.000251, 0.0003, 0.0005, 0.00075, 0.000999, 0.001, 0.002 }) |remaining| {
                        var state = schedule.State.init(10);
                        state.direct_until = 11;
                        state.pacer.markBuild(10);
                        var env = schedule.Environment{ .now = due - remaining,
                            .has_view = true, .has_source = true, .visible = true,
                            .key_window = key, .low_power = low_power,
                            .thermal = @intCast(thermal), .maximum_fps = maximum };
                        var actions = Actions{};
                        const early = state.beginDraw(env, &actions);
                        try t.expect(early.started and early.outcome == 4);
                        state.finishDraw(early.generation, false, env, &actions);
                        try t.expectEqual(@as(f64, 10), state.pacer.last_build_time);
                        var book = Deadlines{};
                        var host = actions;
                        try t.expect(book.apply(actions, &host, env.now, true));
                        try t.expectApproxEqAbs(due, book.earliest().?, 1e-12);
                        try t.expect(host.flags & Actions.start_coalesced == 0);
                        try t.expect(!book.takeDue(.coalesced, due - 0.000001));

                        // Another request before the deadline must neither
                        // reserve a frame nor restart the one-shot timer.
                        actions = .{};
                        state.requestDraw(false, env, &actions);
                        host = actions;
                        _ = book.apply(actions, &host, env.now, true);
                        try t.expectApproxEqAbs(due, book.earliest().?, 1e-12);
                        env.now = due;
                        try t.expect(book.takeDue(.coalesced, env.now));
                        try t.expect(!book.takeDue(.coalesced, env.now));
                        actions = .{};
                        state.timerFired(1, env, &actions);
                        const eligible = state.beginDraw(env, &actions);
                        try t.expect(eligible.started and eligible.outcome == 0);
                        try t.expectApproxEqAbs(due, state.pacer.last_build_time, 1e-12);
                        state.finishDraw(eligible.generation, true, env, &actions);

                        // A successful draw still consumes its full interval.
                        env.now += 0.0001;
                        actions = .{};
                        const too_soon = state.beginDraw(env, &actions);
                        try t.expect(too_soon.started and too_soon.outcome == 4);
                        try t.expectApproxEqAbs(due + 1 / fps,
                            env.now + actions.coalesced_interval, 1e-12);
                    }
                }
            }
        }
    }
}

test "published keyboard response owns one deadline and further keys cannot postpone it" {
    const t = std.testing;
    var state = schedule.State.init(10);
    var env = schedule.Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var book = Deadlines{};
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    var host = actions;
    try t.expect(book.apply(actions, &host, env.now, true));
    try t.expectEqual(@as(?f64, 10 + schedule.keyboard_feedback_frames / 120.0), book.earliest());
    try t.expect(host.flags & Actions.start_keyboard == 0);
    try t.expect(host.flags & Actions.stop_keyboard != 0);
    for (1..6) |index| {
        env.now = 10 + @as(f64, @floatFromInt(index)) * 0.0001;
        actions = .{};
        state.noteKeyboard(env, &actions);
        host = actions;
        _ = book.apply(actions, &host, env.now, true);
        try t.expectEqual(@as(?f64, 10 + schedule.keyboard_feedback_frames / 120.0), book.earliest());
    }
    try t.expect(!book.takeDue(.keyboard, 10.001));
    env.now = 10 + schedule.keyboard_feedback_frames / 120.0;
    try t.expect(book.takeDue(.keyboard, env.now));
    actions = .{};
    state.timerFired(2, env, &actions);
    host = actions;
    _ = book.apply(actions, &host, env.now, true);
    try t.expect(state.requests.pending());
    try t.expectEqual(@as(?f64, null), state.feedback_deadline);
    try t.expect(!book.takeDue(.keyboard, env.now + 1));
    try t.expect(book.owns(.keyboard));
}

test "publication commit and hidden view cancel keyboard wakeups without losing the stale-host fence" {
    const t = std.testing;
    for ([_]bool{ false, true }) |hide| {
        var state = schedule.State.init(5);
        var env = schedule.Environment{ .now = 5, .has_view = true, .has_source = true, .visible = true };
        var book = Deadlines{};
        var actions = Actions{};
        state.noteKeyboard(env, &actions);
        var host = actions;
        _ = book.apply(actions, &host, env.now, true);
        actions = .{};
        if (hide) {
            env.visible = false;
            state.updateAnimation(env, &actions);
        } else state.committed(env, &actions);
        host = actions;
        _ = book.apply(actions, &host, env.now, true);
        try t.expectEqual(@as(?f64, null), book.earliest());
        try t.expect(!book.takeDue(.keyboard, 10));
        try t.expect(book.owns(.keyboard));
        try t.expect(!state.keyboard_scheduled);
    }
}

test "worker wakeup failure returns all live deadlines with their remaining delay" {
    const t = std.testing;
    var book = Deadlines{};
    const actions = Actions{ .flags = Actions.start_coalesced | Actions.start_recovery | Actions.start_keyboard, .coalesced_interval = 0.02, .recovery_interval = 0.1, .keyboard_interval = 0.01 };
    var host = actions;
    _ = book.apply(actions, &host, 0, true);
    try t.expectEqual(@as(?f64, 0.01), book.earliest());
    host = .{};
    book.fallback(&host, 0.005);
    try t.expectEqual(actions.flags, host.flags & actions.flags);
    try t.expectApproxEqAbs(@as(f64, 0.015), host.coalesced_interval, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.095), host.recovery_interval, 1e-12);
    try t.expectApproxEqAbs(@as(f64, 0.005), host.keyboard_interval, 1e-12);
    try t.expectEqual(@as(?f64, null), book.earliest());
    for (kinds) |kind| try t.expect(!book.owns(kind));
}

test "unpublished source keeps host feedback and a new fallback request releases the ownership fence" {
    const t = std.testing;
    const actions = Actions{ .flags = Actions.start_keyboard, .keyboard_interval = 0.01 };
    var book = Deadlines{};
    var host = actions;
    _ = book.apply(actions, &host, 0, true);
    try t.expect(book.takeDue(.keyboard, 0.02));
    try t.expect(book.owns(.keyboard));
    host = actions;
    _ = book.apply(actions, &host, 1, false);
    try t.expectEqual(actions, host);
    try t.expect(!book.owns(.keyboard));
    try t.expectEqual(@as(?f64, null), book.earliest());
}

test "replacing keyboard deadline preserves independent pacing and recovery timers" {
    const t = std.testing;
    var book = Deadlines{};
    var actions = Actions{ .flags = Actions.start_coalesced | Actions.start_recovery | Actions.start_keyboard, .coalesced_interval = 0.02, .recovery_interval = 0.1, .keyboard_interval = 0.01 };
    var host = actions;
    _ = book.apply(actions, &host, 0, true);
    actions = .{ .flags = Actions.stop_keyboard | Actions.start_keyboard, .keyboard_interval = 0.05 };
    host = actions;
    _ = book.apply(actions, &host, 0.001, true);
    try t.expectEqual(@as(?f64, 0.02), book.earliest());
    try t.expect(!book.takeDue(.keyboard, 0.01));
    try t.expect(book.takeDue(.coalesced, 0.02));
    try t.expect(book.takeDue(.keyboard, 0.052));
    try t.expect(book.takeDue(.recovery, 0.1));
    try t.expectEqual(@as(?f64, null), book.earliest());
}

test "owner animation repeats at its cadence and skips missed frames without catch-up bursts" {
    const t = std.testing;
    var book = Deadlines{};
    const actions = Actions{ .flags = Actions.start_animation, .animation_interval = 0.125 };
    var host = actions;
    _ = book.apply(actions, &host, 10, true);
    try t.expectEqual(Actions.stop_animation, host.flags);
    try t.expect(!book.takeDue(.animation, 10.124));
    try t.expect(book.takeDue(.animation, 10.125));
    try t.expectEqual(@as(?f64, 10.25), book.earliest());
    try t.expect(book.takeDue(.animation, 10.76));
    try t.expectEqual(@as(?f64, 10.875), book.earliest());
    try t.expect(!book.takeDue(.animation, 10.76));
    try t.expect(book.owns(.animation));
}

test "deferring a cursor-only pulse keeps cadence and the existing keyboard wakeup" {
    var state = schedule.State.init(50);
    state.cursor_blink_eligible = true;
    var env = schedule.Environment{ .now = 50, .has_view = true, .has_source = true, .visible = true, .key_window = true, .caret_focused = true, .maximum_fps = 120 };
    var book = Deadlines{};
    var actions = Actions{};
    state.updateAnimation(env, &actions);
    var host = actions;
    _ = book.apply(actions, &host, env.now, true);
    const first_pulse = book.earliest().?;
    env.now = first_pulse - 0.002;
    actions = .{};
    state.noteKeyboard(env, &actions);
    host = actions;
    _ = book.apply(actions, &host, env.now, true);
    const keyboard = state.feedback_deadline.?;
    env.now = first_pulse;
    try std.testing.expect(book.takeDue(.animation, env.now));
    actions = .{};
    state.timerFired(0, env, &actions);
    try std.testing.expectEqual(@as(u32, 0), actions.flags);
    host = actions;
    _ = book.apply(actions, &host, env.now, true);
    var next_pulse = book.due[@intFromEnum(Kind.animation)];
    try std.testing.expectEqual(@as(?f64, first_pulse + 1.0 / 60.0), next_pulse);
    // Pulses inside the response window stay cursor-only and are deferred.
    while (next_pulse.? < keyboard) {
        try std.testing.expectEqual(next_pulse, book.earliest());
        env.now = next_pulse.?;
        try std.testing.expect(book.takeDue(.animation, env.now));
        actions = .{};
        state.timerFired(0, env, &actions);
        try std.testing.expectEqual(@as(u32, 0), actions.flags);
        try std.testing.expect(!state.requests.pending());
        next_pulse = book.due[@intFromEnum(Kind.animation)];
    }
    try std.testing.expectEqual(@as(?f64, keyboard), book.earliest());
    env.now = keyboard;
    try std.testing.expect(book.takeDue(.keyboard, env.now));
    actions = .{};
    state.timerFired(2, env, &actions);
    try std.testing.expect(state.requests.pending());
    host = actions;
    _ = book.apply(actions, &host, env.now, true);
    try std.testing.expectEqual(next_pulse, book.earliest());
}

test "owner animation adopts an unchanged host cadence at first publication without postponing it later" {
    const t = std.testing;
    var state = schedule.State.init(5);
    state.config.shader_mode = 1;
    const env = schedule.Environment{ .now = 5, .has_view = true, .has_source = true, .visible = true, .key_window = true };
    var actions = Actions{};
    state.updateAnimation(env, &actions);
    var host = actions;
    var book = Deadlines{};
    _ = book.apply(actions, &host, env.now, false);
    try t.expect(host.flags & Actions.start_animation != 0);
    try t.expect(!book.adoptAnimation(state.animation_interval, &host, 5.001, false));
    try t.expect(book.adoptAnimation(state.animation_interval, &host, 5.002, true));
    try t.expect(host.flags & Actions.start_animation == 0);
    try t.expect(host.flags & Actions.stop_animation != 0);
    const due = book.earliest();
    actions = .{};
    state.updateAnimation(env, &actions);
    try t.expectEqual(@as(u32, 0), actions.flags);
    host = actions;
    try t.expect(!book.adoptAnimation(state.animation_interval, &host, 5.003, true));
    try t.expectEqual(due, book.earliest());
    try t.expectEqual(@as(u32, 0), host.flags);
}

test "owner animation hidden and expired activity cancel repetition but retain the stale-host fence" {
    const t = std.testing;
    for ([_]bool{ false, true }) |hidden| {
        var state = schedule.State.init(20);
        state.selection_until = 20.05;
        var env = schedule.Environment{ .now = 20, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
        var actions = Actions{};
        state.updateAnimation(env, &actions);
        var host = actions;
        var book = Deadlines{};
        _ = book.apply(actions, &host, env.now, true);
        env.now = if (hidden) 20.01 else 20.06;
        env.visible = !hidden;
        try t.expect(book.takeDue(.animation, env.now));
        actions = .{};
        state.timerFired(0, env, &actions);
        host = actions;
        _ = book.apply(actions, &host, env.now, true);
        try t.expectEqual(@as(?f64, null), book.earliest());
        try t.expectEqual(@as(?f64, null), state.animation_interval);
        try t.expect(!book.takeDue(.animation, env.now + 1));
        try t.expect(book.owns(.animation));
        try t.expect(host.flags & Actions.stop_animation != 0);
    }
}

test "owner animation power and focus cadence changes replace only their own deadline" {
    const t = std.testing;
    var state = schedule.State.init(30);
    state.config.shader_mode = 1;
    var env = schedule.Environment{ .now = 30, .has_view = true, .has_source = true, .visible = true, .key_window = true };
    var actions = Actions{ .flags = Actions.start_keyboard, .keyboard_interval = 0.01 };
    state.updateAnimation(env, &actions);
    var book = Deadlines{};
    var host = actions;
    _ = book.apply(actions, &host, env.now, true);
    env.now += 0.001;
    env.key_window = false;
    env.low_power = true;
    actions = .{};
    state.updateAnimation(env, &actions);
    host = actions;
    _ = book.apply(actions, &host, env.now, true);
    try t.expectEqual(@as(?f64, 0.5), book.animation_interval);
    try t.expect(book.takeDue(.keyboard, 30.01));
    try t.expect(!book.takeDue(.animation, 30.02));
    try t.expect(book.takeDue(.animation, 30.501));
    try t.expectApproxEqAbs(@as(f64, 31.001), book.earliest().?, 1e-12);
}

test "owner animation wakeup fallback preserves repeat cadence and independent one-shot delay" {
    const t = std.testing;
    var book = Deadlines{};
    const actions = Actions{ .flags = Actions.start_animation | Actions.start_keyboard, .animation_interval = 0.125, .keyboard_interval = 0.25 };
    var host = actions;
    _ = book.apply(actions, &host, 40, true);
    host = .{};
    book.fallback(&host, 40.124);
    try t.expectEqual(actions.flags, host.flags & actions.flags);
    try t.expectEqual(@as(f64, 0.125), host.animation_interval);
    try t.expectApproxEqAbs(@as(f64, 0.126), host.keyboard_interval, 1e-12);
    try t.expectEqual(@as(?f64, null), book.animation_interval);
    try t.expectEqual(@as(?f64, null), book.earliest());
    for (kinds) |kind| try t.expect(!book.owns(kind));
}

test "owner animation fallback start releases old cadence and permits later publication adoption" {
    const t = std.testing;
    var book = Deadlines{};
    var actions = Actions{ .flags = Actions.start_animation, .animation_interval = 0.125 };
    var host = actions;
    _ = book.apply(actions, &host, 50, true);
    actions.animation_interval = 0.25;
    host = actions;
    _ = book.apply(actions, &host, 50.001, false);
    try t.expectEqual(actions, host);
    try t.expectEqual(@as(?f64, null), book.earliest());
    try t.expectEqual(@as(?f64, null), book.animation_interval);
    try t.expect(!book.owns(.animation));
    try t.expect(book.adoptAnimation(0.25, &host, 50.002, true));
    try t.expectEqual(@as(?f64, 50.252), book.earliest());
}

test "owner animation simultaneous one-shot deadlines fire once without consuming repeat ownership" {
    const t = std.testing;
    var book = Deadlines{};
    const actions = Actions{ .flags = Actions.start_animation | Actions.start_keyboard | Actions.start_recovery | Actions.start_coalesced, .animation_interval = 0.125, .keyboard_interval = 0.125, .coalesced_interval = 0.125, .recovery_interval = 0.25 };
    var host = actions;
    _ = book.apply(actions, &host, 60, true);
    for (kinds) |kind| {
        try t.expectEqual(kind != .recovery, book.takeDue(kind, 60.125));
        try t.expect(!book.takeDue(kind, 60.125));
    }
    try t.expectEqual(@as(?f64, 60.25), book.earliest());
    try t.expect(book.takeDue(.recovery, 60.25));
    try t.expect(book.takeDue(.animation, 60.25));
    try t.expectEqual(@as(?f64, 60.375), book.earliest());
}

test "owner animation rejects unrepresentable deadlines and nonfinite wakeup time" {
    const t = std.testing;
    var book = Deadlines{};
    var host = Actions{};
    try t.expect(!book.adoptAnimation(std.math.inf(f64), &host, 70, true));
    try t.expect(!book.adoptAnimation(0.125, &host, std.math.floatMax(f64), true));
    try t.expectEqual(@as(?f64, null), book.earliest());
    try t.expect(!book.owns(.animation));
    try t.expect(book.adoptAnimation(0.125, &host, 70, true));
    try t.expect(!book.takeDue(.animation, std.math.nan(f64)));
    try t.expectEqual(@as(?f64, 70.125), book.earliest());
}

test "display-locked animation stays with the host's display link" {
    const t = std.testing;
    var book = Deadlines{};
    const actions = Actions{ .flags = Actions.start_animation | Actions.display_locked, .animation_interval = 1.0 / 60.0 };
    var host = actions;
    _ = book.apply(actions, &host, 10, true);
    try t.expect(!book.owns(.animation));
    try t.expect(host.flags & Actions.start_animation != 0 and host.flags & Actions.display_locked != 0);
    try t.expect(!book.adoptAnimation(null, &host, 10, true));
    try t.expect(!book.owns(.animation));
}
