//! One cache job and one installation handshake per render session. Pixels are
//! immutable; the host owns layers and the session owns every scheduling change.
const std = @import("std");
const c = @import("render_shader.zig").c;
const worker = @import("render_worker.zig");
const cache = @import("render_cursor_cache.zig");
const Session = @import("render_session.zig").Session;
const a = std.heap.c_allocator;

const Key = struct {
    token: u64,
    revision: u64,
    epoch: u64,
    generation: u64,
    activity: f64,
    until: f64,
    fn current(self: Key, session: *Session) bool {
        const renderer = session.renderer orelse return false;
        const env = session.environment;
        return self.generation != std.math.maxInt(u64) and !session.closed.load(.acquire) and self.revision == session.source_revision.load(.acquire) and
            self.epoch == session.owner.currentEpoch() and self.generation == session.cursor.generation.load(.acquire) and
            self.activity == renderer.schedule.last_cursor_activity and env.visible and env.key_window and
            env.caret_focused and !env.low_power and env.thermal == 0 and renderer.schedule.config.shader_mode == 0 and
            renderer.schedule.scroll_held == 0 and renderer.schedule.scroll_glide == 0 and env.now >= renderer.schedule.selection_until;
    }
};

pub const Handoff = struct {
    enabled: bool = false,
    engaged: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(1),
    installing: std.atomic.Value(bool) = .init(false),
    removed_token: std.atomic.Value(u64) = .init(0),
    resume_flags: std.atomic.Value(u8) = .init(0), // bit 0 animation, bit 1 draw
    // Only pending_ack is shared under Session.admission. The host consumes it
    // once; close consumes an unanswered offer so a UI callback cannot hold join.
    pending_ack: ?*worker.Completion = null,
    // Everything else belongs to the scoped render owner.
    job: ?*cache.Job = null,
    job_key: ?Key = null,
    attempted: ?Key = null,
    displayed: ?Key = null,
    next_token: u64 = 0,

    pub fn reconcile(self: *Handoff, session: *Session) bool {
        if (!self.enabled) return false;
        if (self.job_key) |key| if (!key.current(session)) if (self.job) |job| c.cmdy_render_cursor_cache_cancel(@ptrCast(job));
        if (self.displayed) |key| if (self.removed_token.load(.acquire) == key.token) { self.displayed = null; };
        if (self.job == null and self.displayed == null and !self.installing.load(.acquire)) self.engaged.store(false, .release);
        const offloaded = if (self.displayed) |key| key.current(session) else false;
        const renderer = session.renderer orelse return false;
        const changed = renderer.schedule.cursor_offloaded != offloaded;
        renderer.schedule.cursor_offloaded = offloaded;
        return changed;
    }
    pub fn retireToken(self: *Handoff, session: *Session) u64 {
        const key = self.displayed orelse return 0;
        return if (!key.current(session)) key.token else 0;
    }
    pub fn retired(self: *Handoff, session: *Session, token: u64) void {
        const key = self.displayed orelse return;
        if (key.token == token) emit(session, key, c.CMDY_SESSION_CURSOR_RETIRED, null);
    }
    pub fn stop(self: *Handoff) void {
        if (self.job) |job| c.cmdy_render_cursor_cache_cancel(@ptrCast(job));
        self.installing.store(false, .release);
        self.displayed = null;
    }
    // Caller holds Session.admission; all accepted completions drain after stop.
    pub fn declinePending(self: *Handoff) void {
        const ticket = self.pending_ack orelse return;
        self.pending_ack = null;
        const ack: *Ack = @ptrCast(@alignCast(ticket.context.?));
        ack.installed = false;
        ticket.publish(.ready);
    }
    pub fn tryStart(self: *Handoff, session: *Session) void {
        if (!self.enabled or self.job != null or self.displayed != null or self.installing.load(.acquire)) return;
        const renderer = session.renderer orelse return;
        const schedule = &renderer.schedule;
        const now = session.environment.now;
        if (session.closed.load(.acquire) or renderer.cursor_continuation or schedule.frame_in_flight or
            schedule.requests.is_drawing or !schedule.cursor_blink_eligible or now < schedule.last_cursor_activity + 1 or
            now + 1.2 >= schedule.recent_activity_until or session.format != 80 or session.samples != 1) return;
        const published = session.published orelse return;
        if (published.revision != session.source_revision.load(.acquire)) return;
        var key = Key{ .token = 0, .revision = published.revision, .epoch = session.owner.currentEpoch(),
            .generation = self.generation.load(.acquire), .activity = schedule.last_cursor_activity, .until = schedule.recent_activity_until };
        if (!key.current(session)) return;
        if (self.attempted) |old| if (old.revision == key.revision and old.epoch == key.epoch and old.generation == key.generation and old.activity == key.activity) return;
        if (self.next_token == std.math.maxInt(u64)) return;
        self.next_token += 1;
        key.token = self.next_token;
        self.attempted = key;
        const context = a.create(Build) catch return;
        context.* = .{ .session = session, .key = key };
        const job = c.cmdy_render_cursor_cache_begin_with_backing(@ptrCast(session.owner), session.device,
            published.input, renderer.preset, key.activity, key.until, Build.completed, context, Build.dispose) orelse {
            a.destroy(context);
            return;
        };
        self.job = @ptrCast(@alignCast(job));
        self.job_key = key;
        self.engaged.store(true, .release);
    }
};

const Build = struct {
    session: *Session,
    key: Key,
    fn dispose(context: ?*anyopaque) callconv(.c) void { a.destroy(@as(*Build, @ptrCast(@alignCast(context.?)))); }
    fn completed(context: ?*anyopaque, result: u32, images: ?*c.CmdyRenderCursorFrames) callconv(.c) void {
        const self: *Build = @ptrCast(@alignCast(context.?));
        const session = self.session;
        const handoff = &session.cursor;
        if (handoff.job) |job| c.cmdy_render_cursor_cache_release(@ptrCast(job));
        handoff.job = null;
        handoff.job_key = null;
        if (result != c.CMDY_CURSOR_CACHE_READY or images == null or !self.key.current(session)) return;
        const ticket = session.owner.prepareOwnedCompletion(Ack, .{ .session = session, .key = self.key }, Ack.run, Ack.dispose) orelse return;
        session.admission.lock();
        if (session.closed.load(.acquire)) {
            session.admission.unlock();
            ticket.publish(.cancelled);
            return;
        }
        std.debug.assert(handoff.pending_ack == null);
        handoff.pending_ack = ticket;
        // The worker serializes all GPU encoding. Until the host has either
        // installed the complete backing or rejected this offer, new packets
        // retain their pending draw request and cannot publish newer pixels.
        handoff.installing.store(true, .release);
        session.admission.unlock();
        emit(session, self.key, c.CMDY_SESSION_CURSOR_CACHE, images);
    }
};
const Ack = struct {
    session: *Session,
    key: Key,
    installed: bool = false,
    fn dispose(_: ?*anyopaque) callconv(.c) void {}
    fn run(context: ?*anyopaque, _: *worker.Worker, _: u32) callconv(.c) void {
        const self: *Ack = @ptrCast(@alignCast(context.?));
        const session = self.session;
        session.cursor.installing.store(false, .release);
        if (session.closed.load(.acquire) or session.renderer == null) return;
        // An input/model change after the host's last check may have made this
        // backing obsolete. Keep its token so the first newer presentation can
        // retire it, but do not suppress live rendering for obsolete content.
        if (self.installed) session.cursor.displayed = self.key;
        session.cursor.resume_flags.store(3, .release);
        session.cursorService();
    }
};
fn emit(session: *Session, key: Key, kind: u32, images: ?*c.CmdyRenderCursorFrames) void {
    if (session.closed.load(.acquire)) return;
    var update = std.mem.zeroes(c.CmdyRenderSessionUpdate);
    update.kind = kind;
    update.success = 1;
    update.source_revision = key.revision;
    update.identity = .{ .surface = session.surface, .epoch = key.epoch, .sequence = 0 };
    update.cursor_token = key.token;
    update.cursor_generation = key.generation;
    update.cursor_frames = images;
    update.environment = session.environment;
    if (session.callback) |callback| callback(session.context, &update);
}

pub fn respond(session: *Session, token: u64, installed: bool) bool {
    session.admission.lock();
    defer session.admission.unlock();
    if (session.closed.load(.acquire)) return false;
    const ticket = session.cursor.pending_ack orelse return false;
    const ack: *Ack = @ptrCast(@alignCast(ticket.context.?));
    if (token == 0 or ack.key.token != token) return false;
    session.cursor.pending_ack = null;
    ack.installed = installed;
    ticket.publish(.ready);
    return true;
}
pub fn cancel(session: *Session, token: u64, removed: bool, request_draw: bool) void {
    session.admission.lock();
    defer session.admission.unlock();
    if (session.closed.load(.acquire) or !session.cursor.enabled) return;
    const generation = session.cursor.generation.load(.acquire);
    if (generation != std.math.maxInt(u64)) session.cursor.generation.store(generation + 1, .release);
    if (removed and token != 0) session.cursor.removed_token.store(token, .release);
    if (!session.cursor.engaged.load(.acquire) and !request_draw) return;
    _ = session.cursor.resume_flags.fetchOr(if (request_draw) 3 else 1, .acq_rel);
    _ = session.owner.notifyPublication(session, Session.modelReady);
}
