//! Native renderer timing and request ownership. Every clock/environment read
//! is injected; host adapters only own OS timers, queue closures, and views.
const std = @import("std");
pub const geometry = @import("render_geometry.zig");
extern "c" fn exp(x: f64) f64;

pub const InteractiveRequests = extern struct {
    generation: u64 = 0,
    committed_generation: u64 = 0,
    service_is_queued: bool = false,
    is_drawing: bool = false,
    pub fn pending(self: InteractiveRequests) bool { return self.generation != self.committed_generation; }
    pub fn request(self: *InteractiveRequests) void { self.generation +%= 1; }
    pub fn queueService(self: *InteractiveRequests, blocked: bool) bool {
        if (!self.pending() or self.service_is_queued or self.is_drawing or blocked) return false;
        self.service_is_queued = true;
        return true;
    }
    pub fn beginService(self: *InteractiveRequests) bool { self.service_is_queued = false; return self.pending(); }
    pub fn beginDraw(self: *InteractiveRequests) ?u64 {
        if (self.is_drawing) return null;
        self.is_drawing = true;
        return self.generation;
    }
    pub fn finishDraw(self: *InteractiveRequests, committed: ?u64) void {
        if (committed) |generation| { if (self.pending()) self.committed_generation = generation; }
        self.is_drawing = false;
    }
    pub fn cancel(self: *InteractiveRequests) void { self.committed_generation = self.generation; }
};
pub const FramePacer = extern struct {
    last_build_time: f64 = 0,
    has_last_build: bool = false,
    pub fn delay(self: FramePacer, time: f64, fps: f64) f64 {
        if (!std.math.isFinite(time) or !std.math.isFinite(fps) or fps <= 0 or !self.has_last_build) return 0;
        return geometry.smax(f64, 0, self.last_build_time + 1 / fps - time);
    }
    pub fn markBuild(self: *FramePacer, time: f64) void {
        if (!std.math.isFinite(time)) return;
        self.last_build_time = time;
        self.has_last_build = true;
    }
    pub fn reset(self: *FramePacer) void { self.has_last_build = false; }
};
pub const ScrollEnvelope = extern struct {
    velocity: f32 = 0,
    energy: f32 = 0,
    last_event_time: f64 = 0,
    last_update_time: f64 = 0,
    pub fn noteScroll(self: *ScrollEnvelope, pixels: f64, time: f64) void {
        if (!std.math.isFinite(pixels) or !std.math.isFinite(time)) return;
        if (self.last_update_time > 0) self.update(time);
        const impulse: f32 = @floatCast(pixels);
        self.velocity = geometry.smax(f32, -1600, geometry.smin(f32, 1600, self.velocity * 0.35 + impulse * 8));
        self.energy = geometry.smax(f32, 0.15, geometry.smin(f32, 1, self.energy + @abs(impulse) / 48));
        self.last_event_time = time;
        self.last_update_time = time;
    }
    pub fn update(self: *ScrollEnvelope, time: f64) void {
        if (!std.math.isFinite(time)) return;
        if (self.last_update_time <= 0) {
            self.velocity = 0;
            self.energy = 0;
            self.last_update_time = time;
            return;
        }
        const elapsed = geometry.smax(f64, 0, time - self.last_update_time);
        self.velocity *= @as(f32, @floatCast(exp(-elapsed * 7.5)));
        self.energy *= @as(f32, @floatCast(exp(-elapsed * 3.25)));
        self.last_update_time = time;
        if (time - self.last_event_time > 1.5 or @abs(self.velocity) < 0.01 or self.energy < 0.001) {
            self.velocity = 0;
            self.energy = 0;
        }
    }
};

/// Frame intervals a keystroke's response may take before a cursor-only
/// feedback frame is drawn.
pub const keyboard_feedback_frames: f64 = 3;
/// Wheel events closer together than this continue one eased scroll.
pub const wheel_stream_seconds: f64 = 0.12;
pub fn continuouslyAnimates(mode: i64) bool { return mode > 0 and mode <= 67 and mode != 2 and mode != 5 and mode != 6 and mode != 9; }
pub fn selectionAnimates(now: f64, until: f64) bool { return std.math.isFinite(now) and std.math.isFinite(until) and now < until; }
pub fn staticFPS(key: bool, thermal: u8, low_power: bool) f64 {
    return switch (thermal) { 3 => if (key) 20 else 10, 2 => if (key) 30 else 15, else => if (key) 50 else if (low_power) 20 else 30 };
}
pub fn shaderFPS(key: bool, thermal: u8, low_power: bool) f64 {
    return switch (thermal) { 3 => if (key) 20 else 2, 2 => if (key) 30 else 3, else => if (key) 60 else if (low_power) 2 else 5 };
}
/// A focused, unthrottled shader animates at the display's own rate, as
/// Ghostty's renderer does. A frame that misses its refresh then shows one
/// refresh late (16.7 ms at 120 Hz) instead of a whole 60 fps frame late.
pub fn animatedShaderFPS(key: bool, thermal: u8, low_power: bool, maximum: i64) f64 {
    if (!key or low_power or thermal >= 2) return shaderFPS(key, thermal, low_power);
    return @floatFromInt(@min(120, @max(60, maximum)));
}
pub fn interactiveFPS(key: bool, thermal: u8, low_power: bool, maximum: i64) f64 {
    if (!key) return staticFPS(false, thermal, low_power);
    return switch (thermal) { 3 => 20, 2 => 30, else => if (low_power) 60 else @floatFromInt(@min(120, @max(60, maximum))) };
}
pub fn requiresOffscreen(mode: i64, builtin: bool, user: bool) bool {
    if (mode == -1) return user;
    if (mode == 0 or mode == 68) return false;
    return builtin;
}

pub const Config = extern struct {
    shader_mode: i64 = 0,
    cursor_speed: f32 = 1,
    cursor_max_distance: f32 = 0,
    smooth_cursor: bool = false,
    host_cursor_hidden: bool = false,
    smooth_scroll: bool = true,
    has_user_pipeline: bool = false,
    user_shader_uses_time: bool = false,
};
pub const Environment = extern struct {
    now: f64 = 0,
    cell_height_pixels: f64 = 16,
    maximum_fps: i64 = 60,
    has_view: bool = false,
    has_source: bool = false,
    visible: bool = false,
    key_window: bool = false,
    caret_focused: bool = false,
    low_power: bool = false,
    thermal: u8 = 0,
};
pub const Actions = extern struct {
    flags: u32 = 0,
    animation_interval: f64 = 0,
    coalesced_interval: f64 = 0,
    keyboard_interval: f64 = 0,
    recovery_interval: f64 = 0,
    preferred_fps: i64 = 0,
    pub const invalidate_view: u32 = 1 << 0;
    pub const queue_service: u32 = 1 << 1;
    pub const draw_manual: u32 = 1 << 2;
    pub const stop_animation: u32 = 1 << 3;
    pub const start_animation: u32 = 1 << 4;
    pub const stop_coalesced: u32 = 1 << 5;
    pub const start_coalesced: u32 = 1 << 6;
    pub const stop_keyboard: u32 = 1 << 7;
    pub const start_keyboard: u32 = 1 << 8;
    pub const stop_recovery: u32 = 1 << 9;
    pub const start_recovery: u32 = 1 << 10;
    /// The started animation is shader-only: the host ticks it from the
    /// display link so frames land on refresh boundaries, and the session
    /// does not own its deadline.
    pub const display_locked: u32 = 1 << 11;
};
pub const DrawStart = extern struct { generation: u64 = 0, delay: f64 = 0, outcome: u32 = 0, started: bool = false };
pub const Inspection = extern struct {
    start_time: f64, activity_time: f64, active_until: f64,
    keyboard_feedback_deadline: f64, keyboard_response_deadline: f64,
    direct_until: f64, selection_until: f64, scroll_held: f64, scroll_glide: f64,
    animation_interval: f64, interactive_generation: u64,
    envelope_velocity: f32, envelope_energy: f32,
    has_feedback_deadline: bool, has_response_deadline: bool, cursor_blink_eligible: bool,
    frame_in_flight: bool, redraw_pending: bool, interactive_pending: bool,
    service_queued: bool, drawing: bool,
};

pub const State = struct {
    config: Config = .{},
    requests: InteractiveRequests = .{},
    pacer: FramePacer = .{},
    draw_pacing_serial: u64 = 0,
    draw_pacing: ?struct { token: u64, before: FramePacer, marked_at: f64 } = null,
    source_retry_used: bool = false,
    envelope: ScrollEnvelope = .{},
    start_time: f64,
    recent_activity_until: f64,
    last_cursor_activity: f64,
    cursor_glide_time: f64 = 0,
    cursor_position: ?geometry.Vec2 = null,
    cursor_blink_eligible: bool = false,
    cursor_offloaded: bool = false,
    scroll_held: f64 = 0,
    scroll_glide: f64 = 0,
    scroll_last_time: f64 = 0,
    direct_until: f64 = 0,
    selection_until: f64 = 0,
    feedback_deadline: ?f64 = null,
    response_deadline: ?f64 = null,
    animation_interval: ?f64 = null,
    animation_display_locked: bool = false,
    coalesced_scheduled: bool = false,
    keyboard_scheduled: bool = false,
    recovery_scheduled: bool = false,
    frame_in_flight: bool = false,
    redraw_pending: bool = false,
    /// The last build carried an input response rather than only animation.
    last_build_interactive: bool = false,

    pub fn init(now: f64) State { return .{ .start_time = now, .recent_activity_until = now + 12, .last_cursor_activity = now }; }
    pub fn inspect(self: *const State) Inspection {
        return .{ .start_time = self.start_time, .activity_time = self.last_cursor_activity, .active_until = self.recent_activity_until,
            .keyboard_feedback_deadline = self.feedback_deadline orelse 0, .keyboard_response_deadline = self.response_deadline orelse 0,
            .direct_until = self.direct_until, .selection_until = self.selection_until, .scroll_held = self.scroll_held, .scroll_glide = self.scroll_glide,
            .animation_interval = self.animation_interval orelse 0, .interactive_generation = self.requests.generation,
            .envelope_velocity = self.envelope.velocity, .envelope_energy = self.envelope.energy,
            .has_feedback_deadline = self.feedback_deadline != null, .has_response_deadline = self.response_deadline != null,
            .cursor_blink_eligible = self.cursor_blink_eligible, .frame_in_flight = self.frame_in_flight, .redraw_pending = self.redraw_pending,
            .interactive_pending = self.requests.pending(), .service_queued = self.requests.service_is_queued, .drawing = self.requests.is_drawing };
    }
    fn recordActivity(self: *State, now: f64) void { self.last_cursor_activity = now; self.recent_activity_until = now + 12; }
    pub fn cancelKeyboardFeedback(self: *State, actions: *Actions) void {
        self.keyboard_scheduled = false;
        self.feedback_deadline = null;
        actions.flags |= Actions.stop_keyboard;
    }
    pub fn cancelKeyboardResponse(self: *State, actions: *Actions) void { self.response_deadline = null; self.cancelKeyboardFeedback(actions); }
    pub fn resetPacing(self: *State, actions: *Actions) void {
        self.pacer.reset();
        self.draw_pacing = null;
        self.source_retry_used = false;
        self.coalesced_scheduled = false;
        actions.flags |= Actions.stop_coalesced;
    }
    pub fn requestDraw(self: *State, immediately: bool, env: Environment, actions: *Actions) void {
        if (!env.has_view) return;
        if (immediately) {
            self.requests.request();
            self.coalesced_scheduled = false;
            actions.flags |= Actions.stop_coalesced;
        }
        if (self.requests.pending()) {
            if (!env.visible) { self.cancelKeyboardResponse(actions); self.requests.cancel(); return; }
            if (self.frame_in_flight or self.requests.is_drawing) { self.redraw_pending = true; return; }
            if (self.requests.queueService(self.coalesced_scheduled)) actions.flags |= Actions.queue_service;
            return;
        }
        actions.flags |= Actions.invalidate_view;
    }
    pub fn service(self: *State, env: Environment, actions: *Actions) void {
        if (!self.requests.beginService()) return;
        if (!env.has_view or !env.visible) { self.cancelKeyboardResponse(actions); self.requests.cancel(); return; }
        if (self.frame_in_flight or self.requests.is_drawing) { self.redraw_pending = true; return; }
        actions.flags |= Actions.draw_manual;
    }
    fn nonCursorAnimates(self: *const State, env: Environment) bool {
        return continuouslyAnimates(self.config.shader_mode)
            or (self.config.shader_mode == -1 and self.config.has_user_pipeline and self.config.user_shader_uses_time)
            or selectionAnimates(env.now, self.selection_until)
            or geometry.scrollSelfAnimates(self.scroll_glide)
            or ((self.config.shader_mode == 9 or self.config.shader_mode == 68) and self.envelope.energy > 0);
    }
    pub fn shouldAnimate(self: *const State, env: Environment) bool {
        if (!env.has_view or !env.visible) return false;
        return self.nonCursorAnimates(env)
            or (!self.cursor_offloaded and self.cursor_blink_eligible and env.caret_focused and env.now < self.recent_activity_until);
    }
    pub fn updateAnimation(self: *State, env: Environment, actions: *Actions) void {
        if (!env.visible) { self.cancelKeyboardResponse(actions); self.requests.cancel(); }
        if (!self.shouldAnimate(env)) {
            const final_frame = geometry.finalCursorFrame(self.animation_interval != null, self.cursor_blink_eligible, env.caret_focused, env.visible, env.now, self.recent_activity_until);
            self.animation_interval = null;
            self.animation_display_locked = false;
            actions.flags |= Actions.stop_animation;
            if (final_frame) self.requestDraw(false, env, actions);
            return;
        }
        // Wheel motion uses the same interactive cadence as its frame pacer.
        // Servicing it on the shader timer can miss the next eligible display
        // interval even when the glide has already reached its target.
        const interactive = selectionAnimates(env.now, self.selection_until) or geometry.scrollSelfAnimates(self.scroll_glide);
        const fps = if (interactive) interactiveFPS(env.key_window, env.thermal, env.low_power, @max(1, env.maximum_fps)) else if (self.shaderAnimates()) animatedShaderFPS(env.key_window, env.thermal, env.low_power, @max(1, env.maximum_fps)) else shaderFPS(env.key_window, env.thermal, env.low_power);
        const interval = 1 / geometry.smax(f64, 1, fps);
        // A free-running shader clock beats against the refresh grid: a tick
        // near a refresh boundary lands on alternate refreshes (16.7/25 ms at
        // 60 fps on 120 Hz). Ghostty draws its animations on the display link.
        const locked = !interactive and fps >= 20 and self.shaderAnimates();
        if (self.animation_interval) |old| { if (@abs(old - interval) < 0.0001 and locked == self.animation_display_locked) return; }
        self.animation_interval = interval;
        self.animation_display_locked = locked;
        actions.flags |= Actions.stop_animation | Actions.start_animation;
        if (locked) actions.flags |= Actions.display_locked;
        actions.animation_interval = interval;
    }
    /// A shader, not only the cursor, needs frames at the shader cadence.
    fn shaderAnimates(self: *const State) bool {
        return continuouslyAnimates(self.config.shader_mode)
            or (self.config.shader_mode == -1 and self.config.has_user_pipeline and self.config.user_shader_uses_time)
            or ((self.config.shader_mode == 9 or self.config.shader_mode == 68) and self.envelope.energy > 0);
    }
    pub fn targetFPS(self: *const State, env: Environment, actions: ?*Actions) f64 {
        if (env.now < self.direct_until or geometry.scrollSelfAnimates(self.scroll_glide)) {
            const maximum = @max(1, env.maximum_fps);
            if (actions) |out| out.preferred_fps = maximum;
            return interactiveFPS(env.key_window, env.thermal, env.low_power, maximum);
        }
        if (self.shaderAnimates()) return animatedShaderFPS(env.key_window, env.thermal, env.low_power, @max(1, env.maximum_fps));
        return staticFPS(env.key_window, env.thermal, env.low_power);
    }
    pub fn noteKeyboard(self: *State, env: Environment, actions: *Actions) void {
        self.direct_until = env.now + 0.15;
        self.response_deadline = self.direct_until;
        self.recordActivity(env.now);
        self.updateAnimation(env, actions);
        if (self.keyboard_scheduled or !env.has_view or !env.visible) return;
        // A cursor-only feedback frame drawn just before the application's
        // echo pushes that echo a further display refresh behind it. Give the
        // response a few frame intervals to arrive; its own frame carries the
        // cursor reset. Without a response the reset still draws promptly.
        const interval = keyboard_feedback_frames / geometry.smax(f64, 1, interactiveFPS(env.key_window, env.thermal, env.low_power, env.maximum_fps));
        self.feedback_deadline = env.now + interval;
        self.keyboard_scheduled = true;
        actions.flags |= Actions.start_keyboard;
        actions.keyboard_interval = interval;
    }
    pub fn noteActivity(self: *State, env: Environment, actions: *Actions) void {
        const responds = if (self.response_deadline) |deadline| env.now < deadline else false;
        self.cancelKeyboardResponse(actions);
        self.recordActivity(env.now);
        self.requestDraw(responds, env, actions);
        self.updateAnimation(env, actions);
    }
    pub fn noteScroll(self: *State, pixels: f64, env: Environment, actions: *Actions) void {
        if (!std.math.isFinite(pixels)) return;
        self.direct_until = env.now + 0.15;
        const previous_wheel = self.envelope.last_event_time;
        self.envelope.noteScroll(pixels, env.now);
        // Ease wheel steps that continue a scroll, where an instant jump
        // would read as stutter. An isolated notch lands on its target in
        // its first frame, like Ghostty; an eased first frame would only
        // delay the rows the user asked for by a display refresh.
        const continues = self.scroll_glide != 0 or
            (previous_wheel > 0 and env.now - previous_wheel < wheel_stream_seconds);
        if (self.config.smooth_scroll and continues) {
            self.scroll_glide = geometry.accumulatedGlide(self.scroll_glide, pixels, env.cell_height_pixels);
            self.scroll_last_time = env.now;
        }
        self.requestDraw(false, env, actions);
        self.updateAnimation(env, actions);
    }
    /// Precision is a wakeup hint for a short discrete glide, never an FPS
    /// override. Held gestures, ordinary cursor animation and constrained
    /// power/thermal/background states retain their existing timed wait.
    pub fn preciseScrollWakeup(self: *const State, visible: bool, key_window: bool, low_power: bool, thermal: i64) bool {
        return visible and key_window and !low_power and thermal == 0 and
            self.config.smooth_scroll and self.scroll_held == 0 and
            geometry.scrollSelfAnimates(self.scroll_glide);
    }
    pub fn setHeld(self: *State, pixels: f64, env: Environment, actions: *Actions) void {
        self.scroll_held = if (self.config.smooth_scroll and std.math.isFinite(pixels)) pixels else 0;
        self.requestDraw(false, env, actions);
    }
    pub fn updateHeld(self: *State, pixels: f64, activity: f64, env: Environment, actions: *Actions) void {
        self.scroll_held = if (self.config.smooth_scroll and std.math.isFinite(pixels)) pixels else 0;
        if (std.math.isFinite(activity)) { self.direct_until = env.now + 0.15; self.envelope.noteScroll(activity, env.now); }
        self.requestDraw(false, env, actions);
        self.updateAnimation(env, actions);
    }
    pub fn noteSelection(self: *State, env: Environment, actions: *Actions) void {
        self.direct_until = env.now + 0.15;
        self.selection_until = env.now + 0.15;
        self.requestDraw(false, env, actions);
        self.updateAnimation(env, actions);
    }
    /// The host invokes onScrollOffsetChanged(0) after this state publication,
    /// then requests a draw/update when the returned previous-motion flag is true.
    pub fn cancelScroll(self: *State) bool {
        const had_motion = self.scroll_held != 0 or self.scroll_glide != 0 or self.scroll_last_time != 0;
        self.scroll_held = 0; self.scroll_glide = 0; self.scroll_last_time = 0;
        return had_motion;
    }
    pub fn updateMotion(self: *State, now: f64) void {
        if (self.config.smooth_scroll and self.scroll_held == 0 and self.scroll_glide != 0) {
            if (self.scroll_last_time != 0) self.scroll_glide = geometry.decayedGlide(self.scroll_glide, now - self.scroll_last_time);
            self.scroll_last_time = if (self.scroll_glide == 0) 0 else now;
        }
        self.envelope.update(now);
    }
    pub fn effectiveScroll(self: *const State, source_offset: f64) f64 { return if (self.config.smooth_scroll) geometry.effectiveScroll(source_offset, self.scroll_held, self.scroll_glide) else 0; }
    pub fn cursorStep(self: *State, target: geometry.Vec2, should_draw: bool, live_resize: bool, cell: geometry.Vec2, now: f64) geometry.CursorStep {
        const start = self.cursor_position orelse target;
        const active = should_draw and self.config.smooth_cursor and !live_resize;
        const elapsed: f32 = if (active) @floatCast(now - self.cursor_glide_time) else 0.001;
        if (active) self.cursor_glide_time = now;
        const step = geometry.cursorStep(start, target, should_draw, self.config.smooth_cursor, live_resize, elapsed, self.config.cursor_speed, self.config.cursor_max_distance, cell);
        self.cursor_position = step.position;
        return step;
    }
    pub fn cursorInvalid(self: *State) void { self.cursor_position = null; }
    pub fn opacity(self: *const State, blinks: bool, focused: bool, now: f64) f32 {
        return geometry.cursorOpacity(blinks, focused, now, self.last_cursor_activity, self.recent_activity_until);
    }
    pub fn beginDraw(self: *State, env: Environment, actions: *Actions) DrawStart {
        const generation = self.requests.beginDraw() orelse { self.redraw_pending = true; return .{ .outcome = 1 }; };
        var result = DrawStart{ .generation = generation, .started = true };
        if (self.frame_in_flight) { self.redraw_pending = true; result.outcome = 2; return result; }
        if (!env.has_source or !env.has_view or !env.visible) { self.updateAnimation(env, actions); result.outcome = 3; return result; }
        const fps = self.targetFPS(env, actions);
        // An input response is paced only by an earlier response. A blink or
        // other animation-only build just before it must not hold the
        // response back for the rest of a frame interval; the compositor
        // shows the newest drawable at the next refresh.
        const interactive = self.requests.pending();
        const delay = if (interactive and !self.last_build_interactive) 0 else self.pacer.delay(env.now, fps);
        // Display-locked ticks already arrive one shader interval apart; only
        // their jitter can read as early. Deferring them by that jitter would
        // move the build off the refresh it was ticked for.
        const tolerance: f64 = if (self.animation_display_locked and !interactive) 0.25 / geometry.smax(f64, 1, fps) else 0.00025;
        if (delay > tolerance) {
            self.redraw_pending = true; result.outcome = 4; result.delay = delay;
            if (!self.coalesced_scheduled) {
                self.coalesced_scheduled = true;
                actions.flags |= Actions.start_coalesced;
                // This branch already has a positive, bounded pacing delay.
                // Rounding a sub-millisecond remainder up to one millisecond
                // postpones the existing frame deadline without limiting FPS.
                actions.coalesced_interval = delay;
            }
            return result;
        }
        self.coalesced_scheduled = false;
        actions.flags |= Actions.stop_coalesced;
        self.redraw_pending = false;
        self.draw_pacing_serial +%= 1;
        if (self.draw_pacing_serial == 0) self.draw_pacing_serial = 1;
        self.draw_pacing = .{ .token = self.draw_pacing_serial, .before = self.pacer, .marked_at = env.now };
        self.pacer.markBuild(env.now);
        self.last_build_interactive = interactive;
        return result;
    }
    pub fn drawPacingToken(self: *const State) u64 {
        return if (self.draw_pacing) |reservation| reservation.token else 0;
    }
    /// The session calls only for its current capture after a newer model
    /// invalidates it, with unchanged UI revision and epoch. Permit one retry
    /// between successful commits, so publication churn cannot bypass pacing.
    pub fn refundSourceDraw(self: *State, token: u64) bool {
        const reservation = self.draw_pacing orelse return false;
        if (token == 0 or token != reservation.token or self.source_retry_used or
            !self.requests.is_drawing or self.frame_in_flight or !self.pacer.has_last_build or
            self.pacer.last_build_time != reservation.marked_at) return false;
        self.pacer = reservation.before;
        self.draw_pacing = null;
        self.source_retry_used = true;
        return true;
    }
    pub fn finishDraw(self: *State, generation: u64, did_commit: bool, env: Environment, actions: *Actions) void {
        self.draw_pacing = null;
        if (did_commit) self.source_retry_used = false;
        self.requests.finishDraw(if (did_commit) generation else null);
        if (self.requests.pending() and self.requests.generation != generation) self.requestDraw(false, env, actions);
    }
    pub fn committed(self: *State, env: Environment, actions: *Actions) void {
        self.frame_in_flight = true;
        self.draw_pacing = null;
        self.source_retry_used = false;
        self.cancelKeyboardFeedback(actions);
        self.updateAnimation(env, actions);
    }
    pub fn completeFrame(self: *State, env: Environment, actions: *Actions) void {
        self.frame_in_flight = false;
        if (self.redraw_pending or self.requests.pending()) { self.redraw_pending = false; self.requestDraw(false, env, actions); }
    }
    pub fn drawableMissing(self: *State, actions: *Actions) void {
        if (!self.recovery_scheduled) {
            self.recovery_scheduled = true;
            actions.flags |= Actions.start_recovery;
            actions.recovery_interval = 0.1;
        }
    }
    pub fn drawableAvailable(self: *State, actions: *Actions) void { self.recovery_scheduled = false; actions.flags |= Actions.stop_recovery; }
    pub fn timerFired(self: *State, kind: u32, env: Environment, actions: *Actions) void {
        switch (kind) {
            0 => {
                if (!self.shouldAnimate(env)) { self.updateAnimation(env, actions); return; }
                // Leave the existing response/feedback opportunity free of a
                // cursor-only old-model draw. The repeating timer keeps its
                // cadence; model activity or the unchanged feedback deadline
                // supplies the next draw. Independent animations still run.
                if (self.feedback_deadline) |deadline| {
                    if (env.now < deadline and !self.nonCursorAnimates(env)) return;
                }
                self.requestDraw(false, env, actions);
            },
            1 => { self.coalesced_scheduled = false; self.requestDraw(false, env, actions); },
            2 => {
                self.cancelKeyboardFeedback(actions);
                if (!env.visible) { self.response_deadline = null; return; }
                self.requestDraw(true, env, actions);
            },
            3 => { self.recovery_scheduled = false; self.requestDraw(false, env, actions); },
            else => {},
        }
    }
};

test "keyboard echo coalesces and older frame cannot consume reentrant input" {
    var state = State.init(10);
    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    const deadline = state.feedback_deadline;
    env.now += 0.001;
    state.noteKeyboard(env, &actions);
    try std.testing.expectEqual(deadline, state.feedback_deadline);
    state.noteActivity(env, &actions);
    try std.testing.expectEqual(@as(u64, 1), state.requests.generation);
    try std.testing.expect(state.feedback_deadline == null);
    const draw = state.beginDraw(env, &actions);
    try std.testing.expect(draw.started and draw.outcome == 0);
    state.requestDraw(true, env, &actions);
    state.finishDraw(draw.generation, true, env, &actions);
    try std.testing.expect(state.requests.pending());
    state.requests.cancel();
    state.requests.finishDraw(draw.generation);
    try std.testing.expect(!state.requests.pending());
}
test "an animation-only build does not pace the next input response" {
    var state = State.init(10);
    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    // A blink/animation frame builds with no response pending.
    const blink = state.beginDraw(env, &actions);
    try std.testing.expect(blink.started and blink.outcome == 0);
    state.finishDraw(blink.generation, true, env, &actions);
    env.now += 0.002;
    state.noteActivity(env, &actions);
    try std.testing.expect(state.requests.pending());
    const response = state.beginDraw(env, &actions);
    try std.testing.expect(response.started and response.outcome == 0);
    state.finishDraw(response.generation, true, env, &actions);
    // A second response within the interval is still paced by the first.
    env.now += 0.002;
    state.noteKeyboard(env, &actions);
    state.noteActivity(env, &actions);
    const paced = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), paced.outcome);
}
test "generation wraps and held scroll does not manufacture animation" {
    var requests = InteractiveRequests{ .generation = std.math.maxInt(u64), .committed_generation = std.math.maxInt(u64) };
    requests.request();
    try std.testing.expectEqual(@as(u64, 0), requests.generation);
    try std.testing.expect(requests.pending());
    var state = State.init(10);
    const env = Environment{ .now = 30, .has_view = true, .visible = true };
    var actions = Actions{};
    state.setHeld(12, env, &actions);
    try std.testing.expect(!state.shouldAnimate(env));
    try std.testing.expectEqual(@as(f64, 12), state.effectiveScroll(0));
}

test "cursor pulse leaves the first keyboard response opportunity free" {
    var state = State.init(10);
    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .caret_focused = true, .maximum_fps = 120 };
    state.cursor_blink_eligible = true;
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    const deadline = state.feedback_deadline;
    const cadence = state.animation_interval;
    env.now += 0.004;
    actions = .{};
    state.timerFired(0, env, &actions);
    try std.testing.expectEqual(@as(u32, 0), actions.flags);
    try std.testing.expectEqual(deadline, state.feedback_deadline);
    try std.testing.expectEqual(cadence, state.animation_interval);
    try std.testing.expect(!state.pacer.has_last_build);
    try std.testing.expectEqual(geometry.cursorOpacity(true, true, env.now, 10, 22), state.opacity(true, true, env.now));
    state.noteActivity(env, &actions);
    try std.testing.expect(state.requests.pending());
    try std.testing.expect(actions.flags & Actions.queue_service != 0);
    try std.testing.expect(state.feedback_deadline == null);
    const response = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 0), response.outcome);
    state.finishDraw(response.generation, true, env, &actions);
    actions = .{};
    env.now += 0.017;
    state.timerFired(0, env, &actions);
    try std.testing.expect(actions.flags & Actions.invalidate_view != 0);
}

test "repeated keys cannot extend cursor deferral or the no-echo feedback deadline" {
    for ([_]Environment{
        .{ .key_window = true, .maximum_fps = 120 },
        .{ .key_window = true, .maximum_fps = 120, .low_power = true },
        .{ .key_window = true, .thermal = 2 },
        .{ .key_window = true, .thermal = 3 },
        .{ .key_window = false, .low_power = true },
    }) |conditions| {
        var state = State.init(20);
        state.cursor_blink_eligible = true;
        var env = conditions;
        env.now = 20; env.has_view = true; env.has_source = true; env.visible = true; env.caret_focused = true;
        var actions = Actions{};
        state.noteKeyboard(env, &actions);
        const deadline = state.feedback_deadline.?;
        for (1..101) |index| {
            env.now = 20 + (deadline - 20) * @as(f64, @floatFromInt(index)) / 200;
            actions = .{};
            state.noteKeyboard(env, &actions);
            try std.testing.expectEqual(@as(u32, 0), actions.flags);
            try std.testing.expectEqual(deadline, state.feedback_deadline.?);
            state.timerFired(0, env, &actions);
            try std.testing.expectEqual(@as(u32, 0), actions.flags);
        }
        env.now = deadline;
        actions = .{};
        state.timerFired(0, env, &actions);
        try std.testing.expect(actions.flags & Actions.invalidate_view != 0);
        actions = .{};
        state.timerFired(2, env, &actions);
        try std.testing.expect(state.requests.pending());
        try std.testing.expect(actions.flags & Actions.queue_service != 0);
        try std.testing.expect(state.feedback_deadline == null);
    }
}

test "independent shader selection and scroll animations continue during keyboard feedback" {
    for (0..6) |kind| {
        var state = State.init(30);
        state.cursor_blink_eligible = true;
        switch (kind) {
            0 => state.config.shader_mode = 1,
            1 => { state.config.shader_mode = -1; state.config.has_user_pipeline = true; state.config.user_shader_uses_time = true; },
            2 => { state.config.shader_mode = 9; state.envelope.energy = 0.5; },
            3 => { state.config.shader_mode = 68; state.envelope.energy = 0.5; },
            4 => state.selection_until = 31,
            5 => state.scroll_glide = 10,
            else => unreachable,
        }
        var env = Environment{ .now = 30, .has_view = true, .has_source = true, .visible = true, .key_window = true, .caret_focused = true, .maximum_fps = 120 };
        var actions = Actions{};
        state.noteKeyboard(env, &actions);
        const deadline = state.feedback_deadline;
        env.now += 0.001;
        actions = .{};
        state.timerFired(0, env, &actions);
        try std.testing.expect(actions.flags & Actions.invalidate_view != 0);
        try std.testing.expectEqual(deadline, state.feedback_deadline);
    }
}

test "cursor deferral preserves hidden cancellation and GPU ownership" {
    var state = State.init(40);
    state.cursor_blink_eligible = true;
    var env = Environment{ .now = 40, .has_view = true, .has_source = true, .visible = true, .key_window = true, .caret_focused = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    env.now += 0.001;
    env.visible = false;
    actions = .{};
    state.timerFired(0, env, &actions);
    try std.testing.expect(actions.flags & Actions.stop_animation != 0);
    try std.testing.expect(state.feedback_deadline == null);
    try std.testing.expect(!state.keyboard_scheduled);
    env.visible = true;
    state.noteKeyboard(env, &actions);
    state.frame_in_flight = true;
    actions = .{};
    state.noteActivity(env, &actions);
    try std.testing.expect(state.requests.pending() and state.redraw_pending);
    try std.testing.expect(actions.flags & (Actions.queue_service | Actions.draw_manual) == 0);
    const blocked = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 2), blocked.outcome);
    state.finishDraw(blocked.generation, false, env, &actions);
    state.completeFrame(env, &actions);
    try std.testing.expect(actions.flags & Actions.queue_service != 0);
}

test "cancelled model draw restores prior pacing and replacement remains paced after commit" {
    var state = State.init(60);
    var env = Environment{ .now = 60, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    const first = state.beginDraw(env, &actions);
    state.committed(env, &actions);
    state.finishDraw(first.generation, true, env, &actions);
    state.completeFrame(env, &actions);
    env.now += 0.020;
    const obsolete = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 0), obsolete.outcome);
    const token = state.drawPacingToken();
    try std.testing.expect(token != 0);
    try std.testing.expect(!state.refundSourceDraw(token + 1));
    try std.testing.expect(state.refundSourceDraw(token));
    try std.testing.expectEqual(@as(f64, 60), state.pacer.last_build_time);
    try std.testing.expect(!state.refundSourceDraw(token));
    state.finishDraw(obsolete.generation, false, env, &actions);
    env.now += 0.001;
    const replacement = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 0), replacement.outcome);
    try std.testing.expect(!state.refundSourceDraw(token));
    state.committed(env, &actions);
    state.finishDraw(replacement.generation, true, env, &actions);
    state.completeFrame(env, &actions);
    env.now += 0.001;
    const paced = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), paced.outcome);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0 / 120.0 - 0.001), paced.delay, 0.000001);
    state.finishDraw(paced.generation, false, env, &actions);
}

test "only one cancelled-source retry is free until a successful commit" {
    var state = State.init(70);
    var env = Environment{ .now = 70, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    const first = state.beginDraw(env, &actions);
    try std.testing.expect(state.refundSourceDraw(state.drawPacingToken()));
    state.finishDraw(first.generation, false, env, &actions);
    const retry = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 0), retry.outcome);
    try std.testing.expect(!state.refundSourceDraw(state.drawPacingToken()));
    state.finishDraw(retry.generation, false, env, &actions);
    env.now += 0.001;
    const deferred = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), deferred.outcome);
    state.finishDraw(deferred.generation, false, env, &actions);
    env.now += 0.020;
    const committed = state.beginDraw(env, &actions);
    state.committed(env, &actions);
    state.finishDraw(committed.generation, true, env, &actions);
    state.completeFrame(env, &actions);
    env.now += 0.020;
    const next = state.beginDraw(env, &actions);
    try std.testing.expect(state.refundSourceDraw(state.drawPacingToken()));
    state.finishDraw(next.generation, false, env, &actions);
}

test "committed reset and ordinary failure paths cannot refund an old draw" {
    var state = State.init(80);
    var env = Environment{ .now = 80, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var actions = Actions{};
    const first = state.beginDraw(env, &actions);
    const committed_token = state.drawPacingToken();
    state.committed(env, &actions);
    try std.testing.expect(!state.refundSourceDraw(committed_token));
    state.finishDraw(first.generation, true, env, &actions);
    state.completeFrame(env, &actions);
    env.now += 0.021;
    const failed = state.beginDraw(env, &actions);
    const failed_token = state.drawPacingToken();
    state.finishDraw(failed.generation, false, env, &actions);
    try std.testing.expect(!state.refundSourceDraw(failed_token));
    env.now += 0.001;
    const paced = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), paced.outcome);
    state.finishDraw(paced.generation, false, env, &actions);
    env.now += 0.021;
    const reset = state.beginDraw(env, &actions);
    const old_token = state.drawPacingToken();
    state.resetPacing(&actions);
    try std.testing.expect(!state.refundSourceDraw(old_token));
    state.finishDraw(reset.generation, false, env, &actions);
    const fresh = state.beginDraw(env, &actions);
    try std.testing.expect(!state.refundSourceDraw(old_token));
    state.frame_in_flight = true;
    try std.testing.expect(!state.refundSourceDraw(state.drawPacingToken()));
    state.frame_in_flight = false;
    try std.testing.expect(state.refundSourceDraw(state.drawPacingToken()));
    state.finishDraw(fresh.generation, false, env, &actions);
}

test "cancelled-publication churn stays bounded at each power and thermal frame rate" {
    for ([_]Environment{
        .{ .key_window = true, .maximum_fps = 120 },
        .{ .key_window = true, .maximum_fps = 120, .low_power = true },
        .{ .key_window = true, .thermal = 2 },
        .{ .key_window = true, .thermal = 3 },
    }) |conditions| {
        var state = State.init(90);
        var env = conditions;
        env.has_view = true; env.has_source = true; env.visible = true;
        var actions = Actions{};
        var attempts: usize = 0;
        var refunds: usize = 0;
        for (0..1000) |index| {
            env.now = 90 + @as(f64, @floatFromInt(index)) / 1000;
            state.noteKeyboard(env, &actions);
            for (0..2) |_| {
                const draw = state.beginDraw(env, &actions);
                if (draw.outcome == 0) {
                    attempts += 1;
                    if (state.refundSourceDraw(state.drawPacingToken())) refunds += 1;
                } else try std.testing.expectEqual(@as(u32, 4), draw.outcome);
                state.finishDraw(draw.generation, false, env, &actions);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), refunds);
        const fps = interactiveFPS(env.key_window, env.thermal, env.low_power, env.maximum_fps);
        try std.testing.expect(@as(f64, @floatFromInt(attempts)) <= fps + 2);
        try std.testing.expect(@as(f64, @floatFromInt(attempts)) >= fps * 0.8);
    }
}

test "refund restores successful-frame history when the thermal rate changes" {
    var state = State.init(100);
    var env = Environment{ .now = 100, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteKeyboard(env, &actions);
    const first = state.beginDraw(env, &actions);
    state.committed(env, &actions);
    state.finishDraw(first.generation, true, env, &actions);
    state.completeFrame(env, &actions);
    env.now += 0.010;
    const obsolete = state.beginDraw(env, &actions);
    try std.testing.expect(state.refundSourceDraw(state.drawPacingToken()));
    state.finishDraw(obsolete.generation, false, env, &actions);
    env.thermal = 3;
    env.now += 0.001;
    const limited = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), limited.outcome);
    try std.testing.expectApproxEqAbs(@as(f64, 0.039), limited.delay, 0.000001);
    state.finishDraw(limited.generation, false, env, &actions);
}

test "wheel response settles without changing held motion or pacing policy" {
    var state = State.init(10);
    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120, .cell_height_pixels = 40 };
    var actions = Actions{};
    // A preceding notch makes this a continuing scroll, which eases.
    state.noteScroll(0, env, &actions);
    state.noteScroll(120, env, &actions);
    try std.testing.expect(state.shouldAnimate(env));
    try std.testing.expectEqual(@as(f64, 50), state.effectiveScroll(0));
    state.updateMotion(10.001);
    const first = state.effectiveScroll(0);
    try std.testing.expect(first >= 0.5 and first < 50);
    // A subsequent opposite wheel impulse reverses the bounded offset rather
    // than overshooting the newest model viewport or extending its old tail.
    env.now = 10.002;
    state.noteScroll(-120, env, &actions);
    try std.testing.expect(state.effectiveScroll(0) < 0);
    state.updateMotion(env.now + 1.0 / 60.0);
    try std.testing.expectEqual(@as(f64, 0), state.effectiveScroll(0));
    try std.testing.expectEqual(@as(f64, 0), state.scroll_last_time);
    try std.testing.expect(!state.shouldAnimate(env));
    for ([_]u8{ 0, 2, 3 }) |thermal| {
        for ([_]bool{ false, true }) |low_power| {
            env.thermal = thermal;
            env.low_power = low_power;
            try std.testing.expectEqual(interactiveFPS(true, thermal, low_power, 120), state.targetFPS(env, null));
        }
    }
    state.updateHeld(12.25, 3, env, &actions);
    state.updateMotion(env.now + 5);
    try std.testing.expectEqual(@as(f64, 12.25), state.effectiveScroll(0));
    try std.testing.expect(!state.shouldAnimate(env));
    try std.testing.expect(state.cancelScroll());
    try std.testing.expectEqual(@as(f64, 0), state.effectiveScroll(0));
    state.config.smooth_scroll = false;
    state.noteScroll(120, env, &actions);
    try std.testing.expectEqual(@as(f64, 0), state.effectiveScroll(0));
    try std.testing.expect(!state.shouldAnimate(env));
}

test "wheel animation timer follows interactive budgets then restores shader cadence" {
    for ([_]i64{ 60, 120, 144 }) |maximum| {
        for ([_]bool{ false, true }) |key| {
            for ([_]bool{ false, true }) |low_power| {
                for ([_]u8{ 0, 1, 2, 3 }) |thermal| {
                    var state = State.init(10);
                    state.config.shader_mode = 1;
                    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = key, .maximum_fps = maximum, .low_power = low_power, .thermal = thermal, .cell_height_pixels = 40 };
                    var actions = Actions{};
                    state.updateAnimation(env, &actions);
                    try std.testing.expectEqual(1 / animatedShaderFPS(key, thermal, low_power, maximum), state.animation_interval.?);
                    // A preceding notch makes this a continuing, eased scroll.
                    state.noteScroll(0, env, &actions);
                    state.noteScroll(120, env, &actions);
                    try std.testing.expectEqual(1 / interactiveFPS(key, thermal, low_power, maximum), state.animation_interval.?);
                    state.updateMotion(env.now + 1.0 / 60.0);
                    env.now += 1.0 / 60.0;
                    state.updateAnimation(env, &actions);
                    try std.testing.expectEqual(1 / animatedShaderFPS(key, thermal, low_power, maximum), state.animation_interval.?);
                    state.config.shader_mode = 0;
                    state.updateAnimation(env, &actions);
                    try std.testing.expect(state.animation_interval == null);
                    try std.testing.expect((actions.flags & Actions.stop_animation) != 0);
                }
            }
        }
    }
}

test "an isolated wheel notch lands immediately while a continuing scroll eases" {
    const t = std.testing;
    var state = State.init(10);
    state.config.smooth_scroll = true;
    var env = Environment{ .now = 20, .has_view = true, .has_source = true, .visible = true, .key_window = true, .cell_height_pixels = 40, .maximum_fps = 120 };
    var actions = Actions{};
    state.noteScroll(80, env, &actions);
    try t.expectEqual(@as(f64, 0), state.scroll_glide);
    try t.expect(!geometry.scrollSelfAnimates(state.scroll_glide));
    env.now += 0.03;
    state.noteScroll(80, env, &actions);
    try t.expect(geometry.scrollSelfAnimates(state.scroll_glide));
    // After the stream settles, the next isolated notch is immediate again.
    state.updateMotion(env.now + 0.2);
    try t.expectEqual(@as(f64, 0), state.scroll_glide);
    env.now += 1;
    state.noteScroll(-80, env, &actions);
    try t.expectEqual(@as(f64, 0), state.scroll_glide);
    // Disabled smoothing never eases.
    var plain = State.init(10);
    plain.config.smooth_scroll = false;
    env.now = 30;
    plain.noteScroll(80, env, &actions);
    env.now += 0.01;
    plain.noteScroll(80, env, &actions);
    try t.expectEqual(@as(f64, 0), plain.scroll_glide);
}

test "focused shader animation is display-locked; interactive and slow cadences are not" {
    var state = State.init(10);
    state.config.shader_mode = 1;
    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120, .cell_height_pixels = 40 };
    var actions = Actions{};
    state.updateAnimation(env, &actions);
    try std.testing.expect(state.animation_display_locked);
    try std.testing.expect(actions.flags & Actions.display_locked != 0);
    // An unfocused window's 5 fps cadence stays on the plain timer.
    env.key_window = false;
    actions = .{};
    state.updateAnimation(env, &actions);
    try std.testing.expect(!state.animation_display_locked);
    try std.testing.expect(actions.flags & Actions.start_animation != 0 and actions.flags & Actions.display_locked == 0);
    // A wheel glide uses the interactive cadence and its own pacing.
    env.key_window = true;
    state.noteScroll(0, env, &actions);
    actions = .{};
    state.noteScroll(120, env, &actions);
    try std.testing.expect(!state.animation_display_locked);
    try std.testing.expect(actions.flags & Actions.display_locked == 0);
    state.config.shader_mode = 0;
    _ = state.cancelScroll();
    state.updateMotion(env.now + 5);
    env.now += 5;
    actions = .{};
    state.updateAnimation(env, &actions);
    try std.testing.expect(!state.animation_display_locked);
}

test "cursor blink pulses keep the session-owned timer" {
    var state = State.init(50);
    state.cursor_blink_eligible = true;
    const env = Environment{ .now = 50, .has_view = true, .has_source = true, .visible = true, .key_window = true, .caret_focused = true, .maximum_fps = 120 };
    var actions = Actions{};
    state.updateAnimation(env, &actions);
    try std.testing.expect(actions.flags & Actions.start_animation != 0);
    try std.testing.expect(!state.animation_display_locked and actions.flags & Actions.display_locked == 0);
}

test "display-locked shader ticks are not deferred by their jitter" {
    var state = State.init(10);
    state.config.shader_mode = 1;
    var env = Environment{ .now = 10, .has_view = true, .has_source = true, .visible = true, .key_window = true, .maximum_fps = 120, .cell_height_pixels = 40 };
    var actions = Actions{};
    state.updateAnimation(env, &actions);
    state.pacer.markBuild(10);
    try std.testing.expectEqual(@as(f64, 120), state.targetFPS(env, null));
    // A tick 1 ms ahead of the 120 fps interval builds now.
    env.now = 10 + 1.0 / 120.0 - 0.001;
    actions = .{};
    var start = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 0), start.outcome);
    // A tick far ahead of the interval is still paced.
    state.frame_in_flight = false;
    state.requests = .{};
    state.pacer.markBuild(env.now);
    env.now += 0.004;
    actions = .{};
    start = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), start.outcome);
    // Without the display lock the old sub-millisecond bound applies.
    state.animation_display_locked = false;
    state.requests = .{};
    state.redraw_pending = false;
    state.coalesced_scheduled = false;
    state.pacer.markBuild(10);
    env.now = 10 + 1.0 / 120.0 - 0.001;
    actions = .{};
    start = state.beginDraw(env, &actions);
    try std.testing.expectEqual(@as(u32, 4), start.outcome);
}

test "focused shaders animate at the display rate; throttled windows keep their budget" {
    try std.testing.expectEqual(@as(f64, 120), animatedShaderFPS(true, 0, false, 120));
    try std.testing.expectEqual(@as(f64, 60), animatedShaderFPS(true, 0, false, 60));
    try std.testing.expectEqual(@as(f64, 120), animatedShaderFPS(true, 1, false, 144));
    try std.testing.expectEqual(shaderFPS(true, 0, true), animatedShaderFPS(true, 0, true, 120));
    try std.testing.expectEqual(shaderFPS(true, 2, false), animatedShaderFPS(true, 2, false, 120));
    try std.testing.expectEqual(shaderFPS(false, 0, false), animatedShaderFPS(false, 0, false, 120));
}
