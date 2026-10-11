const std = @import("std");
const g = @import("render_geometry.zig");
const s = @import("render_schedule.zig");
extern "c" fn CTFontGetAscent(font: *const anyopaque) f64;
extern "c" fn CTFontGetDescent(font: *const anyopaque) f64;
extern "c" fn CTFontGetLeading(font: *const anyopaque) f64;

export fn cmdy_render_visible_rows(rows: i64, lines: i64, top: i64, origin: i64, extra: i64, out: ?[*]g.VisibleRow, capacity: usize) usize {
    const iterator = g.VisibleRows.init(rows, lines, top, origin, extra);
    if (out) |output| for (0..@min(capacity, iterator.count())) |i| {
        output[i] = iterator.at(i).?;
    };
    return iterator.count();
}
export fn cmdy_render_display_row(source: i64, top: i64, rows: i64, out: *i64) bool {
    out.* = g.displayRow(source, top, rows) orelse return false;
    return true;
}
export fn cmdy_render_cache_row(source: i64, origin: i64, out: *i64) bool {
    out.* = g.cacheRow(source, origin) orelse return false;
    return true;
}
export fn cmdy_render_viewport_translation(x: f64, height: f64, top: f64, cell: f64, row: i64, scale: f64) g.Vec2 {
    return g.viewportTranslation(x, height, top, cell, row, scale);
}
export fn cmdy_render_scroll_translation(offset: f64, scale: f64) g.ScrollTranslation {
    return g.smoothScrollTranslation(offset, scale);
}
export fn cmdy_render_effective_scroll(source: f64, held: f64, glide: f64) f64 {
    return g.effectiveScroll(source, held, glide);
}
export fn cmdy_render_decayed_glide(value: f64, elapsed: f64) f64 {
    return g.decayedGlide(value, elapsed);
}
export fn cmdy_render_accumulated_glide(current: f64, impulse: f64, height: f64) f64 {
    return g.accumulatedGlide(current, impulse, height);
}
export fn cmdy_render_scroll_self_animates(glide: f64) bool {
    return g.scrollSelfAnimates(glide);
}
export fn cmdy_render_fringe_rows(offset: f64, height: f64, enabled: bool) i64 {
    return g.fringeRows(offset, height, enabled);
}
export fn cmdy_render_device_top_inset(inset: f64, scale: f64) i64 {
    return g.deviceTopInset(inset, scale);
}
export fn cmdy_render_scissor(width: f64, height: f64, top: f64, bottom: f64, left: f64, scale: f64) g.Scissor {
    return g.scissor(width, height, top, bottom, left, scale);
}
export fn cmdy_render_cursor_opacity(blinks: bool, focused: bool, now: f64, activity: f64, until: f64) f32 {
    return g.cursorOpacity(blinks, focused, now, activity, until);
}
export fn cmdy_render_final_cursor_frame(timer: bool, eligible: bool, focused: bool, visible: bool, now: f64, until: f64) bool {
    return g.finalCursorFrame(timer, eligible, focused, visible, now, until);
}
export fn cmdy_render_cursor_step(from: g.Vec2, to: g.Vec2, draw: bool, smooth: bool, resize: bool, elapsed: f32, speed: f32, maximum: f32, cell: g.Vec2) g.CursorStep {
    return g.cursorStep(from, to, draw, smooth, resize, elapsed, speed, maximum, cell);
}
export fn cmdy_render_selection_rect(lower: i64, upper: i64, columns: i64, width: f64, height: f64, out: *g.Rect) bool {
    out.* = g.selectionRect(lower, upper, columns, width, height) orelse return false;
    return true;
}
export fn cmdy_render_background_fragments(rect: g.Rect, selection: ?*const g.Rect, out: [*]g.Rect) usize {
    var fragments: [2]g.Rect = undefined;
    const count = g.backgroundFragments(rect, if (selection) |value| value.* else null, &fragments);
    @memcpy(out[0..count], fragments[0..count]);
    return count;
}
export fn cmdy_render_cursor_font_height(height: f64, font: *const anyopaque, scale: f64) f64 {
    if (!std.math.isFinite(height) or !std.math.isFinite(scale) or scale <= 0) return 0;
    return g.cursorHeight(height, CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font), scale);
}
export fn cmdy_render_cursor_natural_y(y: f64, height: f64, natural: f64) f64 {
    return g.cursorNaturalY(y, height, natural);
}
export fn cmdy_render_cursor_underline(thickness: f64, scale: f64) f64 {
    return g.cursorUnderline(thickness, scale);
}
export fn cmdy_render_cursor_bar(scale: f64) f64 {
    return g.cursorBar(scale);
}
export fn cmdy_render_line_mode_rect(rect: g.Rect, row: i64, mode: u32, x: f64, y: f64, height: f64) g.Rect {
    return g.lineModeRect(rect, row, mode, x, y, height);
}
export fn cmdy_render_revision_valid(revision: g.Revision, version: u64) bool {
    return g.revisionValid(revision, version);
}
export fn cmdy_render_revision_equal(a: g.Revision, b: g.Revision) bool {
    return g.revisionEqual(a, b);
}
export fn cmdy_render_continuously_animates(mode: i64) bool {
    return s.continuouslyAnimates(mode);
}
export fn cmdy_render_selection_animates(now: f64, until: f64) bool {
    return s.selectionAnimates(now, until);
}
export fn cmdy_render_static_fps(key: bool, thermal: u8, low_power: bool) f64 {
    return s.staticFPS(key, thermal, low_power);
}
export fn cmdy_render_shader_fps(key: bool, thermal: u8, low_power: bool) f64 {
    return s.shaderFPS(key, thermal, low_power);
}
export fn cmdy_render_interactive_fps(key: bool, thermal: u8, low_power: bool, maximum: i64) f64 {
    return s.interactiveFPS(key, thermal, low_power, maximum);
}
export fn cmdy_render_requires_offscreen(mode: i64, builtin: bool, user: bool) bool {
    return s.requiresOffscreen(mode, builtin, user);
}
export fn cmdy_render_cursor_blink_eligible(blinks: bool, hidden: bool, host_hidden: bool, col: i64, columns: i64, row: i64, top: i64, rows: i64) bool {
    return blinks and !hidden and !host_hidden and col >= 0 and col < columns and g.displayRow(row, top, rows) != null;
}
export fn cmdy_render_cursor_inverts_glyph(block: bool, focused: bool, animating: bool) bool {
    return block and focused and !animating;
}
export fn cmdy_render_interactive_request(state: *s.InteractiveRequests) void {
    state.request();
}
export fn cmdy_render_interactive_pending(state: *const s.InteractiveRequests) bool {
    return state.pending();
}
export fn cmdy_render_interactive_queue(state: *s.InteractiveRequests, blocked: bool) bool {
    return state.queueService(blocked);
}
export fn cmdy_render_interactive_begin_service(state: *s.InteractiveRequests) bool {
    return state.beginService();
}
export fn cmdy_render_interactive_begin_draw(state: *s.InteractiveRequests, out: *u64) bool {
    out.* = state.beginDraw() orelse return false;
    return true;
}
export fn cmdy_render_interactive_finish_draw(state: *s.InteractiveRequests, has_generation: bool, generation: u64) void {
    state.finishDraw(if (has_generation) generation else null);
}
export fn cmdy_render_interactive_cancel(state: *s.InteractiveRequests) void {
    state.cancel();
}
export fn cmdy_render_pacer_delay(state: s.FramePacer, now: f64, fps: f64) f64 {
    return state.delay(now, fps);
}
export fn cmdy_render_pacer_mark(state: *s.FramePacer, now: f64) void {
    state.markBuild(now);
}
export fn cmdy_render_pacer_reset(state: *s.FramePacer) void {
    state.reset();
}
export fn cmdy_render_envelope_scroll(state: *s.ScrollEnvelope, pixels: f64, now: f64) void {
    state.noteScroll(pixels, now);
}
export fn cmdy_render_envelope_update(state: *s.ScrollEnvelope, now: f64) void {
    state.update(now);
}

export fn cmdy_render_schedule_create(now: f64) ?*s.State {
    const value = std.heap.c_allocator.create(s.State) catch return null;
    value.* = s.State.init(now);
    return value;
}
export fn cmdy_render_schedule_destroy(state: *s.State) void {
    std.heap.c_allocator.destroy(state);
}
export fn cmdy_render_schedule_default_config() s.Config {
    return .{};
}
export fn cmdy_render_schedule_project_target_fps(config: s.Config, inspection: s.Inspection, env: s.Environment) f64 {
    var state = s.State.init(inspection.start_time);
    state.config = config;
    state.direct_until = inspection.direct_until;
    state.scroll_glide = inspection.scroll_glide;
    state.envelope.energy = inspection.envelope_energy;
    return state.targetFPS(env, null);
}
export fn cmdy_render_schedule_config(state: *const s.State) s.Config {
    return state.config;
}
export fn cmdy_render_schedule_set_config(state: *s.State, config: s.Config) void {
    state.config = config;
}
export fn cmdy_render_schedule_inspect(state: *const s.State) s.Inspection {
    return state.inspect();
}
export fn cmdy_render_schedule_event(state: *s.State, event: u32, env: s.Environment, value: f64, value2: f64) s.Actions {
    var actions = s.Actions{};
    switch (event) {
        0 => state.requestDraw(false, env, &actions),
        1 => state.requestDraw(true, env, &actions),
        2 => state.noteActivity(env, &actions),
        3 => state.noteKeyboard(env, &actions),
        4 => state.cancelKeyboardResponse(&actions),
        5 => state.noteScroll(value, env, &actions),
        6 => state.setHeld(value, env, &actions),
        7 => state.updateHeld(value, value2, env, &actions),
        8 => state.noteSelection(env, &actions),
        9 => state.updateAnimation(env, &actions),
        10 => state.resetPacing(&actions),
        11 => state.service(env, &actions),
        12...15 => state.timerFired(event - 12, env, &actions),
        16 => state.committed(env, &actions),
        17 => state.completeFrame(env, &actions),
        18 => state.drawableMissing(&actions),
        19 => state.drawableAvailable(&actions),
        else => {},
    }
    return actions;
}
export fn cmdy_render_schedule_begin_draw(state: *s.State, env: s.Environment, actions: *s.Actions) s.DrawStart {
    actions.* = .{};
    return state.beginDraw(env, actions);
}
export fn cmdy_render_schedule_finish_draw(state: *s.State, generation: u64, did_commit: bool, env: s.Environment) s.Actions {
    var actions = s.Actions{};
    state.finishDraw(generation, did_commit, env, &actions);
    return actions;
}
export fn cmdy_render_schedule_target_fps(state: *const s.State, env: s.Environment, actions: *s.Actions) f64 {
    actions.* = .{};
    return state.targetFPS(env, actions);
}
export fn cmdy_render_schedule_should_animate(state: *const s.State, env: s.Environment) bool {
    return state.shouldAnimate(env);
}
export fn cmdy_render_schedule_cancel_scroll(state: *s.State) bool {
    return state.cancelScroll();
}
export fn cmdy_render_schedule_update_motion(state: *s.State, now: f64) void {
    state.updateMotion(now);
}
export fn cmdy_render_schedule_effective_scroll(state: *const s.State, offset: f64) f64 {
    return state.effectiveScroll(offset);
}

test {
    _ = s;
}
