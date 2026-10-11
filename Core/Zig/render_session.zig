//! Asynchronous host boundary. GPU and scheduler share one scoped render owner.
//! The host sends copied controls and owned frame inputs, never borrowed state.
const std = @import("std");
const worker = @import("render_worker.zig");
const gpu = @import("render_gpu.zig");
const owned_target = @import("render_gpu_target.zig");
const trace = @import("render_trace.zig");
const geometry = @import("render_geometry.zig");
const deadline_policy = @import("render_session_deadlines.zig");
const delivery_policy = @import("render_delivery_policy.zig");
const priority_policy = @import("render_priority.zig");
const Model = @import("render_model_input.zig").Model;
const frames = @import("render_frame_input.zig");
const cursor_handoff = @import("render_cursor_handoff.zig");
const c = @import("render_shader.zig").c;
const a = std.heap.c_allocator;
const reset_kind = 0xffff_fffe;
const shader_kind = 0xffff_ffff;
const source_kind = 0xffff_fffd;
const feedback_kind = 0xffff_fffc;
const service_kind = 0xffff_fffb;
const timer_draw_kind = 0xffff_fffa;
const viewport_policy = @import("render_viewport_admission.zig");
const Capture = struct { identity: c.CmdyRenderFrameIdentity, draw: c.CmdyRenderDrawStart, revision: u64, ui_revision: u64, pacing_token: u64 };
const deadline_events = [_]u32{ c.CMDY_RENDER_COALESCED_FIRED, c.CMDY_RENDER_RECOVERY_FIRED, c.CMDY_RENDER_KEYBOARD_FIRED, c.CMDY_RENDER_ANIMATION_FIRED };

pub const Session = struct {
    owner: *worker.Worker,
    admission: std.Thread.Mutex = .{},
    closed: std.atomic.Value(bool) = .init(false),
    source_revision: std.atomic.Value(u64) = .init(1),
    ui_revision: std.atomic.Value(u64) = .init(1),
    // Protected by admission. One latest snapshot, regardless of producer rate.
    model: ?*Model = null,
    feedback: *PresentationRelay,
    close_ticket: *worker.Completion,
    device: ?*anyopaque,
    format: u64,
    samples: usize,
    surface: u64,
    callback: c.CmdyRenderSessionCallback,
    context: ?*anyopaque,
    dispose: c.CmdyRenderWorkerCallback,
    // Fields below are touched only by the worker, including initialization.
    renderer: ?*gpu.Renderer = null,
    delivery: delivery_policy.Policy = .{},
    priority: priority_policy.Policy = .{},
    environment: c.CmdyRenderScheduleEnvironment,
    sequence: u64 = 0,
    pending: ?Capture = null,
    viewport_admission: viewport_policy.OneCallback = .{},
    viewport_environment: ?c.CmdyRenderScheduleEnvironment = null,
    published: ?*Published = null,
    // Pacing, drawable recovery, keyboard feedback and repeating animation
    // share one worker wakeup after immutable content is published.
    deadlines: deadline_policy.Deadlines = .{},
    in_timer: bool = false,
    cursor: cursor_handoff.Handoff = .{},
    model_activity: std.atomic.Value(bool) = .init(false),
    wakeup_driver_attempted: bool = false,

    fn applyPriority(self: *Session) void {
        const next = self.priority.change() orelse return;
        const result = c.cmdy_gpu_apple_set_thread_qos(@intFromEnum(next));
        if (result != 0) std.log.warn("render worker QoS {s} failed: {d}", .{ @tagName(next), result });
    }

    fn armDeadline(self: *Session) bool {
        const due = self.deadlines.earliest() orelse {
            self.owner.cancelWakeup();
            return true;
        };
        const precise = self.renderer.?.schedule.preciseScrollWakeup(
            self.environment.visible, self.environment.key_window,
            self.environment.low_power, self.environment.thermal);
        // Allocate no timer for startup, output, cursor blink or ordinary idle.
        // The existing timed wait remains a fallback if allocation fails.
        if (precise and !self.wakeup_driver_attempted) {
            self.wakeup_driver_attempted = true;
            if (c.cmdy_gpu_apple_wakeup_create(auxiliaryWakeup, self.owner)) |driver| {
                if (!self.owner.installWakeupDriver(.{ .context = driver,
                    .arm = c.cmdy_gpu_apple_wakeup_arm, .cancel = c.cmdy_gpu_apple_wakeup_cancel,
                    .destroy = c.cmdy_gpu_apple_wakeup_destroy }))
                    c.cmdy_gpu_apple_wakeup_destroy(driver);
            }
        }
        const remaining = @max(0.000001, due - c.cmdy_gpu_apple_uptime());
        // Resolve the remaining time after optional first-use allocation, so
        // setup does not postpone the scheduler's already declared deadline.
        const delay: u64 = @intFromFloat(@min(remaining, 3600) * std.time.ns_per_s);
        return self.owner.armWakeupWithPrecision(delay, self, deadlineFired, precise);
    }
    fn fallbackDeadlines(self: *Session, host: *c.CmdyRenderScheduleActions) void {
        self.deadlines.fallback(host, self.environment.now);
        self.owner.cancelWakeup();
    }
    fn auxiliaryWakeup(context: ?*anyopaque) callconv(.c) void {
        const owner: *worker.Worker = @ptrCast(@alignCast(context orelse return));
        _ = owner.signalDueWakeup();
    }
    fn deadlineActions(self: *Session, value: c.CmdyRenderScheduleActions, host: *c.CmdyRenderScheduleActions) void {
        const can_own = self.published != null;
        const changed = self.deadlines.apply(value, host, self.environment.now, can_own);
        const state = &self.renderer.?.schedule;
        // The host's display link ticks display-locked animation.
        const adoptable = if (state.animation_display_locked) null else state.animation_interval;
        const adopted = self.deadlines.adoptAnimation(adoptable, host, self.environment.now, can_own);
        if ((changed or adopted) and !self.armDeadline()) self.fallbackDeadlines(host);
    }
    fn deadlineFired(context: ?*anyopaque) callconv(.c) void {
        const self = cast(context);
        if (self.closed.load(.acquire) or self.renderer == null) return;
        self.synchronizeSource();
        self.synchronizeFeedback();
        self.environment.now = c.cmdy_gpu_apple_uptime();
        for (deadline_policy.kinds, 0..) |kind, index| {
            if (!self.deadlines.takeDue(kind, self.environment.now)) continue;
            self.in_timer = true;
            self.event(deadline_events[index], 0, 0);
            self.in_timer = false;
            if (self.closed.load(.acquire)) return;
        }
        if (!self.armDeadline()) {
            var host = std.mem.zeroes(c.CmdyRenderScheduleActions);
            self.fallbackDeadlines(&host);
            self.emit(c.CMDY_SESSION_ACTIONS, true, 0, null, host, "");
        }
    }

    fn clearPublished(self: *Session) void {
        if (self.published) |value| value.release();
        self.published = null;
    }
    fn synchronizeSource(self: *Session) void {
        const revision = self.source_revision.load(.acquire);
        self.refreshModel(revision);
        if (self.published) |value| if (value.revision != revision) self.clearPublished();
        if (self.pending) |capture| {
            if (capture.revision != revision) {
                // A newer terminal model may invalidate an acquired/encoded frame
                // before commit. Its one bounded retry must preserve UI/epoch
                // fences, and must never refund an in-flight or different draw.
                if (capture.ui_revision != 0 and !self.closed.load(.acquire) and capture.identity.epoch == self.owner.currentEpoch() and
                    capture.ui_revision == self.ui_revision.load(.acquire))
                {
                    _ = self.renderer.?.schedule.refundSourceDraw(capture.pacing_token);
                }
                self.finish(capture, false);
            }
        }
    }
    fn refreshModel(self: *Session, revision: u64) void {
        const published = self.published orelse return;
        if (published.ui_revision != self.ui_revision.load(.acquire)) return;
        self.admission.lock();
        const model = if (self.model) |value| value.retain() else null;
        self.admission.unlock();
        const latest = model orelse return;
        defer latest.release();
        // A rejected model publication may have fallen back to a newer UI
        // capture. Never overlay that capture with older terminal contents.
        if (latest.view.generation < published.model_generation) return;
        if (published.model_generation == latest.view.generation and published.revision == revision) return;
        const updated = latest.apply(a, @ptrCast(@alignCast(published.input))) catch return;
        defer updated.release();
        const next = a.create(Published) catch return;
        const f = updated.metadata.parameters;
        const blink = c.cmdy_render_cursor_blink_eligible(f.cursor_style % 2 == 0, f.cursor_hidden != 0, f.host_cursor_hidden != 0, f.cursor_col, f.grid_cols, f.cursor_source_row, f.display_top_row, f.grid_rows);
        next.* = .{ .input = @ptrCast(updated.retain()), .target = published.target.retain(), .revision = revision, .ui_revision = published.ui_revision, .model_generation = latest.view.generation, .blink = @intFromBool(blink) };
        self.published = next;
        published.release();
    }
    pub fn modelReady(context: ?*anyopaque) callconv(.c) void {
        const self = cast(context);
        if (self.closed.load(.acquire) or self.renderer == null) return;
        self.synchronizeSource();
        self.synchronizeFeedback();
        self.environment.now = c.cmdy_gpu_apple_uptime();
        if (self.model_activity.swap(false, .acq_rel)) self.event(c.CMDY_RENDER_ACTIVITY, 0, 0);
        self.cursorService();
    }
    pub fn cursorService(self: *Session) void {
        if (self.closed.load(.acquire) or self.renderer == null) return;
        const resume_flags = self.cursor.resume_flags.swap(0, .acq_rel);
        if (resume_flags == 0) return;
        self.environment.now = c.cmdy_gpu_apple_uptime();
        self.event(c.CMDY_RENDER_UPDATE_ANIMATION, 0, 0);
        if (resume_flags & 2 != 0) self.event(c.CMDY_RENDER_REQUEST, 0, 0);
    }
    fn synchronizeFeedback(self: *Session) void {
        if (self.feedback.takeRetired()) |token| self.cursor.retired(self, token);
        const failed = self.feedback.take() orelse return;
        if (self.closed.load(.acquire) or self.renderer == null or
            failed.revision != self.source_revision.load(.acquire) or
            failed.identity.epoch != self.owner.currentEpoch() or
            !same(failed.identity, self.renderer.?.committed_identity)) return;
        self.environment.now = c.cmdy_gpu_apple_uptime();
        self.event(c.CMDY_RENDER_DRAWABLE_MISSING, 0, 0);
    }

    fn native(self: *Session) ?*c.CmdyRenderGPU {
        return if (self.renderer) |value| @ptrCast(value) else null;
    }
    fn schedule(self: *Session) *c.CmdyRenderSchedule {
        return @ptrCast(&self.renderer.?.schedule);
    }
    fn identity(self: *Session) c.CmdyRenderFrameIdentity {
        return .{ .surface = self.surface, .epoch = self.owner.currentEpoch(), .sequence = 0 };
    }
    fn emit(self: *Session, kind: u32, success: bool, request: u64, capture: ?Capture, output_actions: c.CmdyRenderScheduleActions, message: []const u8) void {
        if (self.closed.load(.acquire)) return;
        if (kind == c.CMDY_SESSION_ERROR and request == 0) self.delivery.failure();
        var update = std.mem.zeroes(c.CmdyRenderSessionUpdate);
        update.kind = kind;
        update.success = @intFromBool(success);
        update.request_id = request;
        update.source_revision = if (capture) |value| value.revision else self.source_revision.load(.acquire);
        update.identity = if (capture) |value| value.identity else self.identity();
        update.environment = self.environment;
        update.actions = output_actions;
        if (capture) |value| update.draw = value.draw;
        if (self.renderer) |value| {
            update.preset = value.preset;
            update.config = c.cmdy_render_schedule_config(self.schedule());
            update.inspection = c.cmdy_render_schedule_inspect(self.schedule());
            if (kind == c.CMDY_SESSION_INSPECTION) {
                update.row_count = c.cmdy_gpu_rows_count(self.native());
                update.row_bytes = c.cmdy_gpu_rows_bytes(self.native());
            }
        }
        const length = @min(message.len, update.message.len - 1);
        const bytes: *[512]u8 = @ptrCast(&update.message);
        @memcpy(bytes[0..length], message[0..length]);
        if (self.callback) |callback| {
            if (kind == c.CMDY_SESSION_ACTIONS) self.delivery.sentActions(output_actions.flags);
            callback(self.context, &update);
        }
    }
    fn actions(self: *Session, value: c.CmdyRenderScheduleActions, request: u64) void {
        self.hostActions(value, request, false);
    }
    fn hostActions(self: *Session, value: c.CmdyRenderScheduleActions, request: u64, completion: bool) void {
        var combined = value;
        if (self.cursor.reconcile(self)) {
            const additional = c.cmdy_render_schedule_event(self.schedule(), c.CMDY_RENDER_UPDATE_ANIMATION, self.environment, 0, 0);
            combined.flags |= additional.flags;
            if (additional.flags & c.CMDY_RENDER_START_ANIMATION != 0) combined.animation_interval = additional.animation_interval;
        }
        var host = combined;
        self.deadlineActions(combined, &host);
        // Service a manual draw on the owner, avoiding another UI draw roundtrip.
        host.flags &= ~@as(u32, c.CMDY_RENDER_DRAW_MANUAL);
        if (combined.flags & c.CMDY_RENDER_QUEUE_SERVICE != 0 and (self.published != null or self.in_timer)) {
            // Queue behind controls already accepted by this owner. The
            // service reads the latest environment and source revision when
            // it runs; it must not restore the request's stale copied values.
            // An expired owner timer can service a newly invalidated source:
            // begin() requests fresh host capture instead of stale pixels.
            // Preserve the existing host path if the bounded queue is full.
            var command = std.mem.zeroes(c.CmdyRenderSessionCommand);
            command.kind = service_kind;
            if (prepare(self, command, null)) |ticket| {
                ticket.publish(.ready);
                host.flags &= ~@as(u32, c.CMDY_RENDER_QUEUE_SERVICE);
            }
        }
        const model_viewport = if (self.published) |published| published.model_generation != 0 else false;
        if ((self.in_timer or model_viewport) and combined.flags & c.CMDY_RENDER_INVALIDATE_VIEW != 0) {
            // Model activity and a pending draw released by GPU completion
            // use the same owner path as timers once UI state is frozen.
            // Preserve FIFO and use current visibility/source when this runs.
            // If capacity is exhausted, retain the existing host invalidation.
            var command = std.mem.zeroes(c.CmdyRenderSessionCommand);
            command.kind = timer_draw_kind;
            if (prepare(self, command, null)) |ticket| {
                ticket.publish(.ready);
                host.flags &= ~@as(u32, c.CMDY_RENDER_INVALIDATE_VIEW);
            }
        }
        // State is included in every delivered update. A host that opted in
        // needs no wakeup for the owner's intermediate, work-free transitions.
        // Host-work mode keeps completion bookkeeping on the owner unless a
        // diagnostic observer explicitly requests it. Host actions still pass.
        if (self.delivery.actions(self.delivery.hostWork(host.flags, host.preferred_fps), request != 0, completion))
            self.emit(c.CMDY_SESSION_ACTIONS, true, request, null, host, "");
        if (combined.flags & c.CMDY_RENDER_DRAW_MANUAL != 0) self.begin();
    }
    fn event(self: *Session, kind: u32, value: f64, value2: f64) void {
        self.hostActions(c.cmdy_render_schedule_event(self.schedule(), kind, self.environment, value, value2), 0, kind == c.CMDY_RENDER_COMPLETED);
    }
    fn begin(self: *Session) void {
        if (self.closed.load(.acquire) or self.renderer == null) return;
        if (self.cursor.installing.load(.acquire)) return;
        self.synchronizeSource();
        self.synchronizeFeedback();
        if (self.published) |value| {
            // BEGIN_DRAW deliberately avoids another host source read. Focus
            // is part of the current owned scalar publication, not the default
            // false placeholder in that host command's environment.
            self.environment.caret_focused = c.cmdy_render_frame_input_metadata(value.input).*.parameters.caret_focused != 0;
        }
        self.environment.now = c.cmdy_gpu_apple_uptime();
        var action = std.mem.zeroes(c.CmdyRenderScheduleActions);
        const draw = c.cmdy_render_schedule_begin_draw(self.schedule(), self.environment, &action);
        if (!draw.started or draw.outcome != 0) {
            self.actions(action, 0);
            if (draw.started) self.actions(c.cmdy_render_schedule_finish_draw(self.schedule(), draw.generation, false, self.environment), 0);
            return;
        }
        c.cmdy_render_schedule_update_motion(self.schedule(), self.environment.now);
        self.sequence +%= 1;
        if (self.sequence == 0) self.sequence = 1;
        var id = self.identity();
        id.sequence = self.sequence;
        // Bind cancellation eligibility to the retained UI publication. Two
        // separate atomic reads could otherwise pair an old source revision
        // with a concurrently changed UI revision. A fresh host capture has
        // no retained UI identity and therefore receives no model-only refund.
        const capture = Capture{ .identity = id, .draw = draw, .revision = self.source_revision.load(.acquire),
            .ui_revision = if (self.published) |value| value.ui_revision else 0,
            .pacing_token = self.renderer.?.schedule.drawPacingToken() };
        self.pending = capture;
        self.actions(action, 0);
        // An action callback can invalidate/close synchronously.
        if (id.epoch != self.owner.currentEpoch() or capture.revision != self.source_revision.load(.acquire)) return;
        if (self.published) |value| if (value.enqueue(self, capture)) return;
        self.emit(c.CMDY_SESSION_CAPTURE, true, 0, capture, .{}, "");
    }
    fn beginViewport(self: *Session) void {
        self.viewport_admission.clear();self.viewport_environment = null;
        const previous_sequence = self.sequence;
        self.begin();
        const capture = self.pending orelse return;
        if (capture.identity.sequence == previous_sequence) return;
        self.viewport_environment = self.environment;
        self.viewport_admission.arm(.{
            .epoch = capture.identity.epoch, .revision = capture.revision,
            .generation = capture.draw.generation, .sequence = capture.identity.sequence,
        });
    }
    fn consumeViewportCallback(self: *Session) bool {
        const renderer = self.renderer orelse return false;
        const pending_sequence = if (self.pending) |capture| capture.identity.sequence else 0;
        const in_flight_sequence = if (renderer.schedule.frame_in_flight) renderer.committed_identity.sequence else 0;
        const previous_environment = self.viewport_environment;self.viewport_environment = null;
        const same_environment = if (previous_environment) |previous|
            previous.key_window == self.environment.key_window and previous.low_power == self.environment.low_power and
            previous.thermal == self.environment.thermal and previous.maximum_fps == self.environment.maximum_fps and
            previous.cell_height_pixels == self.environment.cell_height_pixels else false;
        const suppressed = self.viewport_admission.consume(.{
            .epoch = self.owner.currentEpoch(), .revision = self.source_revision.load(.acquire),
            .generation = renderer.schedule.requests.generation, .sequence = self.sequence,
        }, pending_sequence, in_flight_sequence,
            same_environment and self.environment.has_view and self.environment.has_source and self.environment.visible);
        return suppressed;
    }
    fn finish(self: *Session, capture: Capture, committed: bool) void {
        self.pending = null;
        self.actions(c.cmdy_render_schedule_finish_draw(self.schedule(), capture.draw.generation, committed, self.environment), 0);
    }
    fn reset(self: *Session, change_epoch: bool) void {
        self.viewport_admission.clear();self.viewport_environment = null;
        if (change_epoch) _ = self.owner.invalidate();
        self.clearPublished();
        if (self.pending) |capture| self.finish(capture, false);
        c.cmdy_gpu_resize(self.native());
        self.event(c.CMDY_RENDER_RESET_PACING, 0, 0);
    }
};

fn empty(_: ?*anyopaque) callconv(.c) void {}
fn pool(body: worker.Callback, context: ?*anyopaque) callconv(.c) void {
    c.cmdy_gpu_apple_scope(body, context);
}
fn cast(context: ?*anyopaque) *Session {
    return @ptrCast(@alignCast(context.?));
}
fn same(left: c.CmdyRenderFrameIdentity, right: c.CmdyRenderFrameIdentity) bool {
    return left.surface == right.surface and left.epoch == right.epoch and left.sequence == right.sequence;
}
fn initialize(context: ?*anyopaque, _: *worker.Worker, _: u32) callconv(.c) void {
    const self = cast(context);
    if (self.closed.load(.acquire)) return;
    self.applyPriority();
    var error_text: [512]u8 = @splat(0);
    const raw = c.cmdy_gpu_create_on_worker(@ptrCast(self.owner), self.device, self.format, self.samples, self.environment.now, &error_text, error_text.len) orelse {
        self.emit(c.CMDY_SESSION_ERROR, false, 0, null, .{}, std.mem.sliceTo(&error_text, 0));
        return;
    };
    self.renderer = @ptrCast(@alignCast(raw));
    self.renderer.?.source_revision = &self.source_revision;
    self.renderer.?.publication_gate = &self.cursor.installing;
    c.cmdy_gpu_set_event(raw, gpuEvent, self);
    self.renderer.?.stale_slot_available = staleSlot;
    self.emit(c.CMDY_SESSION_READY, true, 0, null, .{}, "");
}
fn gpuEvent(context: ?*anyopaque, kind: u32) callconv(.c) void {
    const self = cast(context);
    if (self.closed.load(.acquire)) return;
    self.synchronizeFeedback();
    self.environment.now = c.cmdy_gpu_apple_uptime();
    if (kind == 1) self.event(c.CMDY_RENDER_COMPLETED, 0, 0) else self.event(c.CMDY_RENDER_REQUEST, 0, 0);
    if (kind == 1) self.cursor.tryStart(self);
}
fn staleSlot(context: ?*anyopaque) callconv(.c) void {
    // This contains no stale frame identity, pixels or presented-frame event.
    // It only services current scheduler work now that the GPU slot is free.
    gpuEvent(context, 1);
}
fn closeOwner(context: ?*anyopaque, _: *worker.Worker, _: u32) callconv(.c) void {
    const self = cast(context);
    self.owner.cancelWakeup();
    self.deadlines = .{};
    self.pending = null;
    self.cursor.stop();
    self.clearPublished();
    if (self.renderer) |value| {
        value.source_revision = null;
        value.publication_gate = null;
        value.stale_slot_available = null;
        c.cmdy_gpu_destroy(@ptrCast(value));
        self.renderer = null;
    }
}

const Operation = struct {
    session: *Session,
    command: c.CmdyRenderSessionCommand,
    source: ?[:0]u8 = null,
    fn dispose(context: ?*anyopaque) callconv(.c) void {
        const self: *Operation = @ptrCast(@alignCast(context.?));
        if (self.source) |source| a.free(source);
    }
    fn run(context: ?*anyopaque, _: *worker.Worker, _: u32) callconv(.c) void {
        const op: *Operation = @ptrCast(@alignCast(context.?));
        const self = op.session;
        if (self.closed.load(.acquire) or self.renderer == null) return;
        const command = op.command;
        if (command.kind == source_kind and command.request_id != self.ui_revision.load(.acquire)) return;
        self.synchronizeSource();
        self.synchronizeFeedback();
        if (self.closed.load(.acquire)) return;
        if (command.kind == feedback_kind) return;
        if (command.kind == c.CMDY_SESSION_OBSERVE_FRAMES) {
            self.delivery.observe_frames = command.event != 0;
            // FIFO synchronization includes an already in-flight frame, so an
            // observer attached mid-frame can recognize its later completion.
            self.emit(c.CMDY_SESSION_ACTIONS, true, command.request_id, null, .{}, "");
            return;
        }
        if (command.kind == c.CMDY_SESSION_INPUT_ACTIVITY) {
            self.renderer.?.input_activity = .{ .keypress_time = command.value, .typing_rate = @floatCast(command.value2) };
            self.emit(c.CMDY_SESSION_ACTIONS, true, command.request_id, null, .{}, "");
            return;
        }
        if (command.kind == timer_draw_kind) {
            self.begin();
            return;
        }
        var stale_host_deadline = false;
        for (deadline_policy.kinds, 0..) |kind, index| {
            if (command.event == deadline_events[index] and self.deadlines.owns(kind)) stale_host_deadline = true;
        }
        if (command.kind == c.CMDY_SESSION_EVENT and stale_host_deadline) {
            // A host Timer may have posted just before its STOP arrived. It
            // cannot consume a newer owner deadline or restore old scalars.
            self.emit(c.CMDY_SESSION_ACTIONS, true, command.request_id, null, .{}, "");
            return;
        }
        if (command.kind == service_kind) {
            self.environment.now = c.cmdy_gpu_apple_uptime();
            self.event(c.CMDY_RENDER_SERVICE, 0, 0);
            return;
        }
        if (command.kind == c.CMDY_SESSION_INSPECT) {
            self.emit(c.CMDY_SESSION_INSPECTION, true, command.request_id, null, .{}, "");
            return;
        }
        self.environment = command.environment;
        // Every host environment includes visibility/window state, but many
        // cheap controls deliberately carry a false focus placeholder. Keep
        // the focus from the last accepted immutable host frame instead.
        if (command.kind != c.CMDY_SESSION_CAPTURE_FAILED) {
            self.priority.surface_known = true;
            self.priority.visible = self.environment.has_view and self.environment.visible;
            self.priority.key_window = self.environment.key_window;
            self.applyPriority();
        }
        var action = std.mem.zeroes(c.CmdyRenderScheduleActions);
        switch (command.kind) {
            c.CMDY_SESSION_EVENT => action = c.cmdy_render_schedule_event(self.schedule(), command.event, self.environment, command.value, command.value2),
            c.CMDY_SESSION_BEGIN_DRAW => {
                if (command.event == c.CMDY_BEGIN_DRAW_VIEWPORT) self.beginViewport()
                else if (!self.consumeViewportCallback()) self.begin();
            },
            c.CMDY_SESSION_CAPTURE_FAILED => {
                const capture = self.pending orelse return;
                if (!same(capture.identity, command.identity)) return;
                self.finish(capture, false);
                if (command.event == 0) {
                    self.event(c.CMDY_RENDER_DRAWABLE_MISSING, 0, 0);
                } else if (command.event == 1) self.emit(c.CMDY_SESSION_ERROR, false, command.request_id, capture, .{}, "Source frame capture failed");
            },
            c.CMDY_SESSION_CONFIG => {
                self.reset(true);
                var config = command.config;
                const current = c.cmdy_render_schedule_config(self.schedule());
                config.has_user_pipeline = current.has_user_pipeline;
                config.user_shader_uses_time = current.user_shader_uses_time;
                c.cmdy_render_schedule_set_config(self.schedule(), config);
                self.event(c.CMDY_RENDER_UPDATE_ANIMATION, 0, 0);
                self.event(c.CMDY_RENDER_REQUEST, 0, 0);
            },
            c.CMDY_SESSION_PRESET => {
                self.reset(true);
                c.cmdy_gpu_set_preset(self.native(), command.event);
                self.event(c.CMDY_RENDER_REQUEST, 0, 0);
            },
            c.CMDY_SESSION_CANCEL_SCROLL => {
                if (c.cmdy_render_schedule_cancel_scroll(self.schedule())) {
                    self.event(c.CMDY_RENDER_REQUEST, 0, 0);
                    self.event(c.CMDY_RENDER_UPDATE_ANIMATION, 0, 0);
                }
            },
            c.CMDY_SESSION_CLEAR_ROWS => {
                self.reset(true);
                c.cmdy_gpu_rows_clear(self.native());
                self.event(c.CMDY_RENDER_REQUEST, 0, 0);
            },
            reset_kind => {
                self.reset(false);
                self.event(c.CMDY_RENDER_REQUEST, 0, 0);
            },
            source_kind => {
                // Newer source notifications already provide their own FIFO
                // environment. An obsolete control must not replace it.
                if (command.request_id != self.ui_revision.load(.acquire)) return;
                self.event(c.CMDY_RENDER_REQUEST, 0, 0);
            },
            shader_kind => {
                var error_text: [512]u8 = @splat(0);
                const source: [*c]const u8 = if (op.source) |text| text.ptr else null;
                const loaded = c.cmdy_gpu_load_shader(self.native(), source, &error_text, error_text.len) != 0;
                if (!loaded) {
                    self.emit(c.CMDY_SESSION_ERROR, false, command.request_id, null, .{}, std.mem.sliceTo(&error_text, 0));
                    return;
                }
                self.reset(true);
                self.event(c.CMDY_RENDER_UPDATE_ANIMATION, 0, 0);
                self.event(c.CMDY_RENDER_REQUEST, 0, 0);
            },
            else => unreachable,
        }
        self.actions(action, command.request_id);
    }
};
fn prepare(self: *Session, command: c.CmdyRenderSessionCommand, source: ?[:0]u8) ?*worker.Completion {
    return self.owner.prepareOwnedCompletion(Operation, .{ .session = self, .command = command, .source = source }, Operation.run, Operation.dispose);
}

// Independent of Session: a presentation callback may arrive after its join.
const LayerPresentation = struct {
    value: c.CmdyRenderLayerPresentation,
    callback: c.CmdyRenderLayerPresented,
    context: ?*anyopaque,
    dispose_context: c.CmdyRenderWorkerCallback,
    fn presented(context: ?*anyopaque, when: f64) callconv(.c) void {
        const self: *LayerPresentation = @ptrCast(@alignCast(context.?));
        var value = self.value;
        value.presented_time = when;
        self.callback.?(self.context, &value);
    }
    fn dispose(context: ?*anyopaque) callconv(.c) void {
        const self: *LayerPresentation = @ptrCast(@alignCast(context.?));
        if (self.dispose_context) |release| release(self.context);
        a.destroy(self);
    }
};

const Packet = struct {
    session: *Session,
    input: *c.CmdyRenderOwnedFrameInput,
    target: ?*c.CmdyRenderOwnedTarget = null,
    layer: ?*anyopaque = null,
    presented: c.CmdyRenderLayerPresented = null,
    presentation_context: ?*anyopaque = null,
    presentation_dispose: c.CmdyRenderWorkerCallback = null,
    identity: c.CmdyRenderFrameIdentity,
    revision: u64,
    publication: ?*Published = null,
    install_publication: bool = false,
    blink: u8,
    environment: c.CmdyRenderScheduleEnvironment,
    fn modelGeneration(self: *const Packet) u64 {
        const input: *const frames.Frame = @ptrCast(@alignCast(self.input));
        return if (input.viewportInput()) |viewport| viewport.settings.model_generation else 0;
    }
    fn traceFrame(self: *const Packet, event_name: [:0]const u8, started: u64) void {
        if (!trace.enabled()) return;
        const metadata = c.cmdy_render_frame_input_metadata(self.input).*;
        trace.record(event_name, started, &.{
            .{ .name = "surface", .value = @intCast(self.identity.surface) },
            .{ .name = "epoch", .value = @intCast(self.identity.epoch) },
            .{ .name = "sequence", .value = @intCast(self.identity.sequence) },
            .{ .name = "revision", .value = @intCast(self.revision) },
            .{ .name = "generation", .value = @intCast(self.modelGeneration()) },
            .{ .name = "frame", .value = @intCast(metadata.parameters.trace_started) },
        });
    }
    fn dispose(context: ?*anyopaque, _: u32) callconv(.c) void {
        const self: *Packet = @ptrCast(@alignCast(context.?));
        c.cmdy_render_frame_input_release(self.input);
        c.cmdy_render_target_release(self.target);
        c.cmdy_gpu_apple_release(self.layer);
        if (self.presentation_dispose) |release| release(self.presentation_context);
        if (self.publication) |value| value.release();
        a.destroy(self);
    }
    fn missing(self: *Packet, capture: Capture) void {
        const session = self.session;
        session.finish(capture, false);
        if (!session.closed.load(.acquire) and capture.identity.epoch == session.owner.currentEpoch())
            session.event(c.CMDY_RENDER_DRAWABLE_MISSING, 0, 0);
    }
    fn observe(self: *Packet, drawable: *anyopaque, info: c.CmdyGpuAppleTargetInfo) bool {
        // A successful GPU commit can still produce no on-screen presentation
        // (notably the first drawable while a native layer is becoming visible).
        // Recovery must not depend on unrelated subsequent content or blinking.
        const feedback = a.create(PresentationFeedback) catch return false;
        feedback.* = .{ .relay = self.session.feedback.retain(), .value = .{ .identity = self.identity, .revision = self.revision }, .generation = self.modelGeneration(), .cursor_token = self.session.cursor.retireToken(self.session) };
        c.cmdy_gpu_apple_presented(drawable, PresentationFeedback.presented, feedback, PresentationFeedback.dispose);
        if (self.publication) |value| {
            if (value.target.presented_callback == null) return true;
            const delivery = a.create(LayerPresentation) catch return false;
            delivery.* = .{ .callback = Published.presented, .context = value.retain(), .dispose_context = Published.disposeContext, .value = .{ .identity = self.identity, .drawable_id = c.cmdy_gpu_apple_drawable_id(drawable), .pixel_width = info.width, .pixel_height = info.height, .presented_time = 0 } };
            c.cmdy_gpu_apple_presented(drawable, LayerPresentation.presented, delivery, LayerPresentation.dispose);
            return true;
        }
        const callback = self.presented orelse return true;
        const delivery = a.create(LayerPresentation) catch return false;
        delivery.* = .{ .callback = callback, .context = self.presentation_context, .dispose_context = self.presentation_dispose, .value = .{ .identity = self.identity, .drawable_id = c.cmdy_gpu_apple_drawable_id(drawable), .pixel_width = info.width, .pixel_height = info.height, .presented_time = 0 } };
        self.presentation_context = null;
        self.presentation_dispose = null;
        c.cmdy_gpu_apple_presented(drawable, LayerPresentation.presented, delivery, LayerPresentation.dispose);
        return true;
    }
    fn run(context: ?*anyopaque, _: *worker.Worker, epoch: u64) callconv(.c) void {
        const packet: *Packet = @ptrCast(@alignCast(context.?));
        const service_started = trace.now();
        const self = packet.session;
        if (self.closed.load(.acquire) or self.renderer == null) return;
        const capture = self.pending orelse return;
        if (epoch != capture.identity.epoch or !same(packet.identity, capture.identity) or
            packet.revision != capture.revision or packet.revision != self.source_revision.load(.acquire)) return;
        if (self.cursor.installing.load(.acquire)) { self.finish(capture, false); return; }
        if (packet.publication == null or packet.install_publication) {
            // Only a newly accepted host capture may replace focus. Worker
            // redraws reuse their publication, and an old packet must never
            // restore visibility/key-window state after a newer host control.
            self.priority.focused = c.cmdy_render_frame_input_metadata(packet.input).*.parameters.caret_focused != 0;
            self.applyPriority();
        }
        if (packet.install_publication) {
            self.clearPublished();
            self.published = packet.publication.?.retain();
            self.refreshModel(packet.revision);
            // A UI capture can have observed an older model snapshot. Overlay
            // the latest terminal content before acquiring its drawable.
            if (self.published) |latest| {
                const input = c.cmdy_render_frame_input_retain(latest.input).?;
                c.cmdy_render_frame_input_release(packet.input);
                packet.input = input;
                packet.blink = latest.blink;
            }
        }
        self.environment = packet.environment;
        packet.traceFrame("worker.frameService", service_started);
        var acquired: ?*c.CmdyRenderOwnedTarget = null;
        defer c.cmdy_render_target_release(acquired);
        if (packet.layer) |layer| {
            // The only blocking acquisition is outside admission/commit locks.
            // A concurrent resize/close can invalidate the epoch immediately.
            if (epoch != self.owner.currentEpoch() or packet.revision != self.source_revision.load(.acquire)) return;
            const drawable = c.cmdy_gpu_apple_layer_next_drawable(layer) orelse {
                if (!self.closed.load(.acquire) and epoch == self.owner.currentEpoch() and packet.revision == self.source_revision.load(.acquire)) packet.missing(capture);
                return;
            };
            defer c.cmdy_gpu_apple_release(drawable);
            if (self.closed.load(.acquire) or epoch != self.owner.currentEpoch() or packet.revision != self.source_revision.load(.acquire)) return;
            const pass = c.cmdy_gpu_apple_drawable_pass(drawable) orelse {
                packet.missing(capture);
                return;
            };
            defer c.cmdy_gpu_apple_release(pass);
            acquired = c.cmdy_render_target_capture(packet.identity, drawable, pass, null) orelse {
                packet.missing(capture);
                return;
            };
            const target: *owned_target.Target = @ptrCast(@alignCast(acquired.?));
            const frame = c.cmdy_render_frame_input_metadata(packet.input).?;
            if (frame[0].parameters.width != @as(f64, @floatFromInt(target.info.width)) or
                frame[0].parameters.height != @as(f64, @floatFromInt(target.info.height)))
            {
                packet.missing(capture);
                return;
            }
            if (!packet.observe(drawable, target.info)) {
                self.finish(capture, false);
                self.emit(c.CMDY_SESSION_ERROR, false, 0, capture, .{}, "Presentation observer allocation failed");
                return;
            }
        }
        if (self.closed.load(.acquire) or epoch != self.owner.currentEpoch() or packet.revision != self.source_revision.load(.acquire)) return;
        self.event(c.CMDY_RENDER_DRAWABLE_AVAILABLE, 0, 0);
        c.cmdy_gpu_cursor_blink(self.native(), packet.blink);
        self.renderer.?.drawing_revision = packet.revision;
        defer self.renderer.?.drawing_revision = 0;
        const submit_started = trace.now();
        const committed = c.cmdy_gpu_draw_target(self.native(), packet.input, acquired orelse packet.target) != 0;
        packet.traceFrame(if (committed) "worker.frameSubmitted" else "worker.frameRejected", submit_started);
        if (!committed and packet.revision != self.source_revision.load(.acquire)) return;
        if (committed) self.event(c.CMDY_RENDER_COMMITTED, 0, 0);
        self.finish(capture, committed);
        if (!committed and epoch == self.owner.currentEpoch()) self.event(c.CMDY_RENDER_DRAWABLE_MISSING, 0, 0);
        if (self.delivery.frame(committed, capture.identity.epoch, capture.revision))
            self.emit(c.CMDY_SESSION_FRAME, committed, 0, capture, .{}, "");
    }
};

const FailedPresentation = struct { identity: c.CmdyRenderFrameIdentity, revision: u64 };

// Presentation is not a worker-join ticket: a drawable callback may arrive long
// after GPU completion and after Session's destroy. Detach under this short lock
// before joining, so late callbacks retain only this inert relay. Notification
// never takes admission/publication locks or reads mutable owner state.
const PresentationRelay = struct {
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Thread.Mutex = .{},
    session: ?*Session,
    failure: ?FailedPresentation = null,
    retired_cursor: ?u64 = null,
    latest: c.CmdyRenderFrameIdentity = .{ .surface = 0, .epoch = 0, .sequence = 0 },

    fn retain(self: *PresentationRelay) *PresentationRelay {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    fn release(self: *PresentationRelay) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) a.destroy(self);
    }
    fn detach(self: *PresentationRelay) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.session = null;
        self.failure = null;
        self.retired_cursor = null;
    }
    fn takeRetired(self: *PresentationRelay) ?u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const token = self.retired_cursor;
        self.retired_cursor = null;
        return token;
    }
    fn retireCursor(self: *PresentationRelay, token: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.session orelse return;
        if (session.closed.load(.acquire)) return;
        self.retired_cursor = token;
        _ = session.owner.notifyPublication(session, Session.modelReady);
    }
    fn take(self: *PresentationRelay) ?FailedPresentation {
        self.mutex.lock();
        defer self.mutex.unlock();
        const result = self.failure;
        self.failure = null;
        return result;
    }
    fn notify(self: *PresentationRelay, value: FailedPresentation) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.session orelse return;
        if (session.closed.load(.acquire)) return;
        if (value.identity.epoch < self.latest.epoch or
            (value.identity.epoch == self.latest.epoch and value.identity.sequence <= self.latest.sequence)) return;
        self.latest = value.identity;
        self.failure = value;
        // Keep the coalesced failure even when a control ticket cannot be
        // allocated. Every later owner control/GPU completion also drains it.
        // Holding the relay lock keeps Session alive until prepare/publish end;
        // the reserved completion then protects the worker through its join.
        var command = std.mem.zeroes(c.CmdyRenderSessionCommand);
        command.kind = feedback_kind;
        if (prepare(session, command, null)) |ticket| ticket.publish(.ready);
    }
};

const PresentationFeedback = struct {
    relay: *PresentationRelay,
    value: FailedPresentation,
    generation: u64,
    cursor_token: u64,
    fn presented(context: ?*anyopaque, when: f64) callconv(.c) void {
        const self: *PresentationFeedback = @ptrCast(@alignCast(context.?));
        if (trace.enabled()) trace.record("worker.framePresented", trace.now(), &.{
            .{ .name = "surface", .value = @intCast(self.value.identity.surface) },
            .{ .name = "epoch", .value = @intCast(self.value.identity.epoch) },
            .{ .name = "sequence", .value = @intCast(self.value.identity.sequence) },
            .{ .name = "revision", .value = @intCast(self.value.revision) },
            .{ .name = "generation", .value = @intCast(self.generation) },
            .{ .name = "presentedNanoseconds", .value = if (std.math.isFinite(when) and when > 0) geometry.boundedInt(when * 1_000_000_000) else 0 },
        });
        if (!std.math.isFinite(when) or when <= 0) self.relay.notify(self.value)
        else if (self.cursor_token != 0) self.relay.retireCursor(self.cursor_token);
    }
    fn dispose(context: ?*anyopaque) callconv(.c) void {
        const self: *PresentationFeedback = @ptrCast(@alignCast(context.?));
        self.relay.release();
        a.destroy(self);
    }
};

// This owner is independent of Session: presentation deliveries can outlive its
// join. Nested frame content and caller context are released only once.
const PublicationTarget = struct {
    refs: std.atomic.Value(usize) = .init(1),
    layer: *anyopaque,
    presented_callback: c.CmdyRenderLayerPresented,
    context: ?*anyopaque,
    dispose_context: c.CmdyRenderWorkerCallback,
    fn retain(self: *PublicationTarget) *PublicationTarget {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    fn release(self: *PublicationTarget) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        c.cmdy_gpu_apple_release(self.layer);
        if (self.dispose_context) |dispose| dispose(self.context);
        a.destroy(self);
    }
};
const Published = struct {
    refs: std.atomic.Value(usize) = .init(1),
    input: *c.CmdyRenderOwnedFrameInput,
    target: *PublicationTarget,
    revision: u64,
    ui_revision: u64,
    model_generation: u64 = 0,
    blink: u8,

    fn retain(self: *Published) *Published {
        _ = self.refs.fetchAdd(1, .monotonic);
        return self;
    }
    fn release(self: *Published) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        c.cmdy_render_frame_input_release(self.input);
        self.target.release();
        a.destroy(self);
    }
    fn disposeContext(context: ?*anyopaque) callconv(.c) void {
        const self: *Published = @ptrCast(@alignCast(context.?));
        self.release();
    }
    fn presented(context: ?*anyopaque, value: [*c]const c.CmdyRenderLayerPresentation) callconv(.c) void {
        const self: *Published = @ptrCast(@alignCast(context.?));
        if (self.target.presented_callback) |callback| callback(self.target.context, value);
    }
    fn packet(self: *Published, session: *Session, input: *c.CmdyRenderOwnedFrameInput, environment: c.CmdyRenderScheduleEnvironment, install: bool) ?*Packet {
        const result = a.create(Packet) catch return null;
        result.* = .{ .session = session, .input = c.cmdy_render_frame_input_retain(input).?, .layer = c.cmdy_gpu_apple_retain(self.target.layer), .identity = c.cmdy_render_frame_input_metadata(input).*.identity, .revision = self.revision, .publication = self.retain(), .install_publication = install, .blink = self.blink, .environment = environment };
        return result;
    }
    fn enqueue(self: *Published, session: *Session, capture: Capture) bool {
        if (self.revision != capture.revision) return false;
        const view = c.cmdy_render_frame_input_metadata(self.input).*;
        if (view.identity.epoch != capture.identity.epoch or view.parameters.live_resize != 0 or view.parameters.scroll_pixels != 0) return false;
        const config = c.cmdy_render_schedule_config(session.schedule());
        const motion = c.cmdy_render_schedule_inspect(session.schedule());
        // A scroll can expose uncaptured fringe rows. Host capture remains
        // necessary until that content range has its own publication contract.
        if (config.smooth_scroll and (motion.scroll_held != 0 or motion.scroll_glide != 0)) return false;
        var metadata = view;
        metadata.identity = capture.identity;
        metadata.rows = null;
        metadata.row_count = 0;
        metadata.parameters.kitty_images = null;
        metadata.parameters.kitty_image_count = 0;
        metadata.parameters.kitty_placements = null;
        metadata.parameters.kitty_placement_count = 0;
        metadata.parameters.live_kitty_ids = null;
        metadata.parameters.live_kitty_count = 0;
        metadata.parameters.now = session.environment.now;
        metadata.parameters.shader_energy = motion.envelope_energy;
        metadata.parameters.shader_velocity = motion.envelope_velocity;
        metadata.parameters.trace_started = trace.now();
        const input = c.cmdy_render_frame_input_reuse(self.input, &metadata, null) orelse return false;
        defer c.cmdy_render_frame_input_release(input);
        const next = self.packet(session, input, session.environment, false) orelse return false;
        if (!session.owner.submit(.{ .context = next, .run = Packet.run, .dispose = Packet.dispose, .epoch = capture.identity.epoch })) {
            Packet.dispose(next, 0);
            return false;
        }
        return true;
    }
};

export fn cmdy_render_session_create(device: ?*const anyopaque, format: u64, samples: usize, surface: u64, now: f64, callback: c.CmdyRenderSessionCallback, context: ?*anyopaque, dispose: c.CmdyRenderWorkerCallback) ?*Session {
    return cmdy_render_session_create_with_options(device, format, samples, surface, now, 0, callback, context, dispose);
}
export fn cmdy_render_session_create_with_options(device: ?*const anyopaque, format: u64, samples: usize, surface: u64, now: f64, options: u32, callback: c.CmdyRenderSessionCallback, context: ?*anyopaque, dispose: c.CmdyRenderWorkerCallback) ?*Session {
    if (options & ~@as(u32, c.CMDY_SESSION_ESSENTIAL_UPDATES | c.CMDY_SESSION_HOST_WORK_UPDATES | c.CMDY_SESSION_CURSOR_CACHE_UPDATES) != 0) return null;
    if (device == null or surface == 0 or samples == 0 or callback == null or !std.math.isFinite(now)) return null;
    const self = a.create(Session) catch return null;
    const feedback = a.create(PresentationRelay) catch {
        a.destroy(self);
        return null;
    };
    feedback.* = .{ .session = self };
    const owner = worker.Worker.createWithOptions(a, pool, 1024) catch {
        feedback.release();
        a.destroy(self);
        return null;
    };
    self.* = .{ .owner = owner, .feedback = feedback, .close_ticket = undefined, .device = c.cmdy_gpu_apple_retain(device), .format = format, .samples = samples, .surface = surface, .callback = callback, .context = context, .dispose = dispose, .environment = std.mem.zeroes(c.CmdyRenderScheduleEnvironment) };
    self.delivery = .{ .essential = options & c.CMDY_SESSION_ESSENTIAL_UPDATES != 0,
        .host_work_only = options & c.CMDY_SESSION_HOST_WORK_UPDATES != 0 };
    self.environment.now = now;
    self.cursor.enabled = options & c.CMDY_SESSION_CURSOR_CACHE_UPDATES != 0;
    self.close_ticket = owner.prepareCompletion(self, closeOwner, empty) orelse {
        _ = owner.destroy();
        c.cmdy_gpu_apple_release(self.device);
        feedback.release();
        a.destroy(self);
        return null;
    };
    const start = owner.prepareCompletion(self, initialize, empty) orelse {
        self.closed.store(true, .release);
        self.close_ticket.publish(.cancelled);
        _ = owner.destroy();
        c.cmdy_gpu_apple_release(self.device);
        feedback.release();
        a.destroy(self);
        return null;
    };
    start.publish(.ready);
    return self;
}
export fn cmdy_render_session_epoch(raw: ?*Session) u64 {
    return if (raw) |self| self.owner.currentEpoch() else 0;
}
export fn cmdy_render_session_source_revision(raw: ?*Session) u64 {
    return if (raw) |self| if (self.closed.load(.acquire)) 0 else self.source_revision.load(.acquire) else 0;
}
fn capacityAvailable(context: ?*anyopaque) callconv(.c) void {
    const self = cast(context);
    self.emit(c.CMDY_SESSION_CAPACITY_AVAILABLE, true, 0, null, .{}, "");
}
export fn cmdy_render_session_wait_for_capacity(raw: ?*Session) u8 {
    const self = raw orelse return 0;
    if (self.closed.load(.acquire)) return 0;
    return @intFromBool(self.owner.notifyWhenCapacityAvailable(self, capacityAvailable));
}
export fn cmdy_render_session_post(raw: ?*Session, command: [*c]const c.CmdyRenderSessionCommand) u8 {
    const self = raw orelse return 0;
    if (command == null or command[0].kind > c.CMDY_SESSION_OBSERVE_FRAMES or
        (command[0].kind == c.CMDY_SESSION_OBSERVE_FRAMES and command[0].event > 1) or
        (command[0].kind == c.CMDY_SESSION_EVENT and command[0].event > c.CMDY_RENDER_DRAWABLE_AVAILABLE) or
        (command[0].kind == c.CMDY_SESSION_PRESET and command[0].event > 5) or
        (command[0].kind == c.CMDY_SESSION_INPUT_ACTIVITY and
            (!std.math.isFinite(command[0].value) or command[0].value < 0 or
                !std.math.isFinite(command[0].value2) or command[0].value2 < 0 or command[0].value2 > std.math.floatMax(f32)))) return 0;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire)) return 0;
    const ticket = prepare(self, command[0], null) orelse return 0;
    ticket.publish(.ready);
    return 1;
}
export fn cmdy_render_session_shader(raw: ?*Session, source: [*c]const u8, length: usize, request: u64, environment: c.CmdyRenderScheduleEnvironment) u8 {
    const self = raw orelse return 0;
    if ((length != 0 and source == null) or length > 1024 * 1024) return 0;
    const text: ?[:0]u8 = if (length == 0) null else a.dupeZ(u8, source[0..length]) catch return 0;
    var adopted = false;
    defer if (!adopted) {
        if (text) |value| a.free(value);
    };
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire)) return 0;
    var command = std.mem.zeroes(c.CmdyRenderSessionCommand);
    command.kind = shader_kind;
    command.request_id = request;
    command.environment = environment;
    const ticket = prepare(self, command, text) orelse return 0;
    adopted = true;
    ticket.publish(.ready);
    return 1;
}
export fn cmdy_render_session_submit(raw: ?*Session, input: ?*c.CmdyRenderOwnedFrameInput, target: ?*c.CmdyRenderOwnedTarget, blink: u8, environment: c.CmdyRenderScheduleEnvironment) u8 {
    const self = raw orelse return 0;
    if (input == null or target == null) return 0;
    const view = c.cmdy_render_frame_input_metadata(input);
    if (view == null or view[0].identity.surface != self.surface) return 0;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire)) return 0;
    const packet = a.create(Packet) catch return 0;
    packet.* = .{ .session = self, .input = c.cmdy_render_frame_input_retain(input).?, .target = c.cmdy_render_target_retain(target).?, .identity = view[0].identity, .revision = self.source_revision.load(.acquire), .blink = blink, .environment = environment };
    if (!self.owner.submit(.{ .context = packet, .run = Packet.run, .dispose = Packet.dispose, .epoch = packet.identity.epoch })) {
        Packet.dispose(packet, 0);
        return 0;
    }
    return 1;
}
export fn cmdy_render_session_submit_layer(raw: ?*Session, input: ?*c.CmdyRenderOwnedFrameInput, layer: ?*const anyopaque, blink: u8, environment: c.CmdyRenderScheduleEnvironment, presented: c.CmdyRenderLayerPresented, presentation_context: ?*anyopaque, presentation_dispose: c.CmdyRenderWorkerCallback) u8 {
    const self = raw orelse return 0;
    if (input == null or layer == null) return 0;
    if (presented == null and (presentation_context != null or presentation_dispose != null)) return 0;
    const view = c.cmdy_render_frame_input_metadata(input);
    if (view == null or view[0].identity.surface != self.surface) return 0;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire)) return 0;
    const retained_layer = c.cmdy_gpu_apple_layer_retain(layer) orelse return 0;
    const packet = a.create(Packet) catch {
        c.cmdy_gpu_apple_release(retained_layer);
        return 0;
    };
    packet.* = .{ .session = self, .input = c.cmdy_render_frame_input_retain(input).?, .layer = retained_layer, .identity = view[0].identity, .revision = self.source_revision.load(.acquire), .blink = blink, .environment = environment, .presented = presented, .presentation_context = presentation_context, .presentation_dispose = presentation_dispose };
    if (!self.owner.submit(.{ .context = packet, .run = Packet.run, .dispose = Packet.dispose, .epoch = packet.identity.epoch })) {
        // A rejected submission never takes the caller's presentation context.
        packet.presentation_dispose = null;
        Packet.dispose(packet, 0);
        return 0;
    }
    return 1;
}
export fn cmdy_render_session_publish_layer(raw: ?*Session, input: ?*c.CmdyRenderOwnedFrameInput, revision: u64, layer: ?*const anyopaque, blink: u8, environment: c.CmdyRenderScheduleEnvironment, presented: c.CmdyRenderLayerPresented, context: ?*anyopaque, dispose: c.CmdyRenderWorkerCallback) u8 {
    const self = raw orelse return 0;
    if (input == null or layer == null or revision == 0) return 0;
    if (presented == null and (context != null or dispose != null)) return 0;
    const view = c.cmdy_render_frame_input_metadata(input);
    if (view == null or view[0].identity.surface != self.surface) return 0;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire) or revision != self.source_revision.load(.acquire) or view[0].identity.epoch != self.owner.currentEpoch()) return 0;
    const retained_layer = c.cmdy_gpu_apple_layer_retain(layer) orelse return 0;
    const target = a.create(PublicationTarget) catch {
        c.cmdy_gpu_apple_release(retained_layer);
        return 0;
    };
    target.* = .{ .layer = retained_layer, .presented_callback = presented, .context = context, .dispose_context = null };
    defer target.release();
    const value = a.create(Published) catch return 0;
    value.* = .{ .input = c.cmdy_render_frame_input_retain(input).?, .target = target.retain(), .revision = revision, .ui_revision = self.ui_revision.load(.acquire), .blink = blink };
    const native_frame: *const frames.Frame = @ptrCast(@alignCast(input.?));
    if (native_frame.viewportInput()) |viewport| value.model_generation = viewport.settings.model_generation;
    var adopted = false;
    defer {
        if (adopted) target.dispose_context = dispose;
        value.release();
    }
    const packet = value.packet(self, input.?, environment, true) orelse return 0;
    if (!self.owner.submit(.{ .context = packet, .run = Packet.run, .dispose = Packet.dispose, .epoch = view[0].identity.epoch })) {
        Packet.dispose(packet, 0);
        return 0;
    }
    adopted = true;
    return 1;
}
export fn cmdy_render_session_source_changed(raw: ?*Session, environment: c.CmdyRenderScheduleEnvironment) u64 {
    const self = raw orelse return 0;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire)) return 0;
    const current = self.source_revision.load(.acquire);
    if (current == std.math.maxInt(u64)) return 0;
    var command = std.mem.zeroes(c.CmdyRenderSessionCommand);
    command.kind = source_kind;
    command.request_id = current + 1;
    command.environment = environment;
    const ticket = prepare(self, command, null);
    const revision = self.owner.advanceRevision(&self.source_revision);
    self.ui_revision.store(revision, .release);
    std.debug.assert(revision == command.request_id);
    // The invalidation fence cannot be dropped under allocation/capacity
    // pressure. Any subsequent owner control reconciles the new revision; the
    // host always requests a draw through its normal retry queue as well.
    if (ticket) |value| value.publish(.ready);
    return revision;
}
export fn cmdy_render_session_publish_model(raw: ?*Session, input: ?*const c.CmdyRenderModelInput) u8 {
    const publication_started = trace.now();
    const self = raw orelse return 0;
    const source = input orelse return 0;
    const model = Model.create(a, @ptrCast(source)) catch return 0;
    var previous: ?*Model = null;
    defer if (previous) |old| old.release();
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire) or self.source_revision.load(.acquire) == std.math.maxInt(u64) or
        (self.model != null and source.generation <= self.model.?.view.generation))
    {
        model.release();
        return 0;
    }
    previous = self.model;
    self.model = model;
    _ = self.owner.advanceRevision(&self.source_revision);
    self.model_activity.store(true, .release);
    const notified = self.owner.notifyPublication(self, Session.modelReady);
    std.debug.assert(notified);
    if (trace.enabled()) trace.record("worker.modelPublished", publication_started, &.{
        .{ .name = "surface", .value = @intCast(self.surface) },
        .{ .name = "generation", .value = @intCast(source.generation) },
        .{ .name = "revision", .value = @intCast(self.source_revision.load(.acquire)) },
    });
    return 1;
}
export fn cmdy_render_session_invalidate(raw: ?*Session, environment: c.CmdyRenderScheduleEnvironment) u64 {
    const self = raw orelse return 0;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.load(.acquire)) return 0;
    var command = std.mem.zeroes(c.CmdyRenderSessionCommand);
    command.kind = reset_kind;
    command.environment = environment;
    const ticket = prepare(self, command, null) orelse return 0;
    const epoch = self.owner.invalidate();
    ticket.publish(.ready);
    return epoch;
}
export fn cmdy_render_session_close(raw: ?*Session) void {
    const self = raw orelse return;
    self.admission.lock();
    defer self.admission.unlock();
    if (self.closed.swap(true, .acq_rel)) return;
    self.cursor.declinePending();
    self.owner.stop();
    self.close_ticket.publish(.ready);
}
export fn cmdy_render_session_cursor_generation(raw: ?*Session) u64 {
    return if (raw) |self| if (self.closed.load(.acquire)) 0 else self.cursor.generation.load(.acquire) else 0;
}
export fn cmdy_render_session_cursor_respond(raw: ?*Session, token: u64, installed: u8) u8 {
    if (installed > 1) return 0;
    return if (raw) |self| @intFromBool(cursor_handoff.respond(self, token, installed != 0)) else 0;
}
export fn cmdy_render_session_cursor_cancel(raw: ?*Session, token: u64, removed: u8, request_draw: u8) void {
    if (removed > 1 or request_draw > 1) return;
    if (raw) |self| cursor_handoff.cancel(self, token, removed != 0, request_draw != 0);
}
export fn cmdy_render_session_destroy(raw: ?*Session) u8 {
    const self = raw orelse return 1;
    if (self.owner.isWorkerThread()) return 0;
    self.feedback.detach();
    cmdy_render_session_close(self);
    if (!self.owner.destroy()) return 0;
    if (self.model) |model| model.release();
    c.cmdy_gpu_apple_release(self.device);
    self.feedback.release();
    if (self.dispose) |dispose| dispose(self.context);
    a.destroy(self);
    return 1;
}
