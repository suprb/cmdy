// Headless correctness: no NSApplication, windows, input, PTY or clipboard.
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#include "cmdy_render_session.h"
#include "platform_gpu.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct SessionTest {
    CmdyRenderSession *session;
    pthread_mutex_t lock;
    pthread_t owner;
    bool has_owner;
    CmdyRenderSessionUpdate updates[256];
    size_t read, written;
    dispatch_semaphore_t changed, blocked, unblock;
    atomic_uint disposed;
    const void *texture, *pass;
} SessionTest;
static void wait_for(dispatch_semaphore_t value) {
    assert(dispatch_semaphore_wait(value, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0);
}
static CmdyRenderScheduleEnvironment environment(void) {
    return (CmdyRenderScheduleEnvironment){.now = NSProcessInfo.processInfo.systemUptime,
        .cell_height_pixels = 8, .maximum_fps = 120, .has_view = true,
        .has_source = true, .visible = true, .key_window = true};
}
static void update(void *context, const CmdyRenderSessionUpdate *value) {
    SessionTest *t = context; assert(!NSThread.isMainThread);
    if (!t->has_owner) { t->owner = pthread_self(); t->has_owner = true; }
    assert(pthread_equal(t->owner, pthread_self()));
    // The callback can reject self-join without stopping or freeing the owner.
    if (value->request_id == 97) assert(!cmdy_render_session_destroy(t->session));
    pthread_mutex_lock(&t->lock); assert(t->written - t->read < 256);
    t->updates[t->written++ % 256] = *value; pthread_mutex_unlock(&t->lock);
    dispatch_semaphore_signal(t->changed);
#ifdef CMDY_TEST_SESSION_UPDATE
    CMDY_TEST_SESSION_UPDATE(context, value);
#endif
    if (value->request_id == 98) { dispatch_semaphore_signal(t->blocked); wait_for(t->unblock); }
}
static void disposed(void *context) { atomic_fetch_add(&((SessionTest *)context)->disposed, 1); }
static void setup(SessionTest *t, id<MTLDevice> device) {
    *t = (SessionTest){.lock = PTHREAD_MUTEX_INITIALIZER,
        .changed = dispatch_semaphore_create(0), .blocked = dispatch_semaphore_create(0),
        .unblock = dispatch_semaphore_create(0)};
    t->texture = cmdy_gpu_apple_texture((__bridge const void *)device, 8, 8, 0, MTLPixelFormatBGRA8Unorm, 1, 0);
    t->pass = cmdy_gpu_apple_pass(t->texture); assert(t->texture && t->pass);
    t->session = cmdy_render_session_create((__bridge const void *)device, MTLPixelFormatBGRA8Unorm,
        1, 79, environment().now, update, t, disposed); assert(t->session);
}
static CmdyRenderSessionUpdate next(SessionTest *t) {
    wait_for(t->changed); pthread_mutex_lock(&t->lock); assert(t->read < t->written);
    CmdyRenderSessionUpdate value = t->updates[t->read++ % 256]; pthread_mutex_unlock(&t->lock);
    return value;
}
static CmdyRenderSessionUpdate matching(SessionTest *t, uint32_t kind, uint64_t request) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        if (value.kind == kind && value.request_id == request) return value;
    }
    assert(false); return (CmdyRenderSessionUpdate){0};
}
static void post(SessionTest *t, uint32_t kind, uint32_t event, uint64_t request) {
    CmdyRenderSessionCommand command = {.kind = kind, .event = event, .request_id = request, .environment = environment()};
    assert(cmdy_render_session_post(t->session, &command));
}
static CmdyRenderSessionUpdate capture(SessionTest *t) {
    post(t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 0);
    post(t, CMDY_SESSION_BEGIN_DRAW, 0, 0);
    CmdyRenderSessionUpdate value = matching(t, CMDY_SESSION_CAPTURE, 0);
    assert(value.success && value.draw.started && value.draw.outcome == 0 && value.inspection.drawing);
    assert(value.identity.surface == 79 && value.identity.epoch == cmdy_render_session_epoch(t->session));
    return value;
}
static void submit(SessionTest *t, CmdyRenderFrameIdentity identity, CmdyRenderColor color) {
    CmdyRenderFrameInput input = {.identity = identity};
    input.parameters = (CmdyGpuFrame){.width = 8, .height = 8, .scale = 1, .cell_width = 8,
        .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1,
        .image_scale = 1, .background = color, .now = environment().now};
    uint32_t status = 99;
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture(&input, &status); assert(frame && status == 0);
    CmdyRenderOwnedTarget *target = cmdy_render_target_capture(identity, NULL, t->pass, &status); assert(target && status == 0);
    assert(cmdy_render_session_submit(t->session, frame, target, 0, environment()));
    cmdy_render_frame_input_release(frame); cmdy_render_target_release(target);
}
static void gpu_done(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        if (value.kind == CMDY_SESSION_ACTIONS && !value.inspection.frame_in_flight) return;
    }
    assert(false);
}
static void pixels(SessionTest *t, uint8_t r, uint8_t g, uint8_t b) {
    uint8_t bytes[256];
    [(__bridge id<MTLTexture>)t->texture getBytes:bytes bytesPerRow:32 fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    for (unsigned i = 0; i < sizeof(bytes); i += 4)
        assert(bytes[i] == b && bytes[i+1] == g && bytes[i+2] == r && bytes[i+3] == 255);
}
static void *join_session(void *context) {
    SessionTest *t = context; assert(cmdy_render_session_destroy(t->session)); return NULL;
}
static void cleanup(SessionTest *t) {
    pthread_t joiner; assert(!pthread_create(&joiner, NULL, join_session, t)); assert(!pthread_join(joiner, NULL));
    assert(atomic_load(&t->disposed) == 1); t->session = NULL;
    cmdy_gpu_apple_release(t->pass); cmdy_gpu_apple_release(t->texture);
    pthread_mutex_destroy(&t->lock);
}

#ifdef CMDY_SESSION_INSTRUMENTED
static atomic_bool watch_completion, pause_encode;
static atomic_uint commits;
static dispatch_semaphore_t completed, continue_completion, encoded, continue_encode;
void fixture_commit_impl(const void *, const void *, CmdyGpuAppleCompletion, void *);
void fixture_encoder_end_impl(const void *);
typedef struct Completion { CmdyGpuAppleCompletion callback; void *context; bool watched; } Completion;
static void completion(void *context, double start, double end) {
    Completion *box = context;
    if (box->watched) { dispatch_semaphore_signal(completed); wait_for(continue_completion); }
    box->callback(box->context, start, end); free(box);
}
void cmdy_gpu_apple_commit(const void *buffer, const void *drawable, CmdyGpuAppleCompletion callback, void *context) {
    Completion *box = malloc(sizeof(*box)); assert(box);
    *box = (Completion){callback, context, atomic_exchange(&watch_completion, false)};
    atomic_fetch_add(&commits, 1); fixture_commit_impl(buffer, drawable, completion, box);
}
void cmdy_gpu_apple_encoder_end(const void *encoder) {
    fixture_encoder_end_impl(encoder);
    if (atomic_exchange(&pause_encode, false)) { dispatch_semaphore_signal(encoded); wait_for(continue_encode); }
}
static void races(id<MTLDevice> device) {
    completed = dispatch_semaphore_create(0); continue_completion = dispatch_semaphore_create(0);
    encoded = dispatch_semaphore_create(0); continue_encode = dispatch_semaphore_create(0);
    SessionTest t; setup(&t, device); assert(matching(&t, CMDY_SESSION_READY, 0).success);
    uint64_t frames = cmdy_gpu_counter(0);
    CmdyRenderSessionUpdate old = capture(&t);
    atomic_store(&watch_completion, true); submit(&t, old.identity, (CmdyRenderColor){1, 0, 0, 1});
    assert(matching(&t, CMDY_SESSION_FRAME, 0).success); wait_for(completed);
    uint64_t epoch = cmdy_render_session_invalidate(t.session, environment()); assert(epoch == old.identity.epoch + 1);
    // A keyboard request establishes the interactive generation that SERVICE
    // consumes. A plain redraw uses INVALIDATE_VIEW instead of this queue.
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_REQUEST_IMMEDIATE, 0);
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SERVICE, 33);
    CmdyRenderSessionUpdate busy = matching(&t, CMDY_SESSION_ACTIONS, 33);
    assert(busy.inspection.frame_in_flight && busy.inspection.redraw_pending && !busy.inspection.drawing);
    dispatch_semaphore_signal(continue_completion);
    CmdyRenderSessionUpdate free_slot = {0};
    for (unsigned i = 0; i < 256; i++) {
        free_slot = next(&t);
        assert(free_slot.identity.epoch == epoch);
        if (!free_slot.inspection.frame_in_flight && (free_slot.actions.flags & CMDY_RENDER_QUEUE_SERVICE)) break;
    }
    assert(!free_slot.inspection.frame_in_flight && (free_slot.actions.flags & CMDY_RENDER_QUEUE_SERVICE));
    assert(cmdy_gpu_counter(0) == frames); // Old completion did not become a presented frame.
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 0);
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SERVICE, 0);
    CmdyRenderSessionUpdate fresh = matching(&t, CMDY_SESSION_CAPTURE, 0); assert(fresh.identity.epoch == epoch);
    submit(&t, fresh.identity, (CmdyRenderColor){0, 0, 1, 1});
    assert(matching(&t, CMDY_SESSION_FRAME, 0).success); gpu_done(&t); pixels(&t, 0, 0, 255);
    assert(cmdy_gpu_counter(0) == frames + 1); cleanup(&t);

    setup(&t, device); assert(matching(&t, CMDY_SESSION_READY, 0).success);
    fresh = capture(&t); unsigned before = atomic_load(&commits);
    atomic_store(&pause_encode, true); submit(&t, fresh.identity, (CmdyRenderColor){0, 1, 0, 1}); wait_for(encoded);
    cmdy_render_session_close(t.session); assert(cmdy_render_session_epoch(t.session) == 0);
    dispatch_semaphore_signal(continue_encode); cleanup(&t); assert(atomic_load(&commits) == before);
    puts("Session races: stale GPU slot wakes current work; close during encoding prevents commit PASS");
}
#endif

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; setup(&t, device); CmdyRenderSessionUpdate ready = matching(&t, CMDY_SESSION_READY, 0); assert(ready.success);
        CmdyRenderSessionCommand inspection = {.kind = CMDY_SESSION_INSPECT, .request_id = 71, .environment = environment()};
        inspection.environment.now += 1000000;
        assert(cmdy_render_session_post(t.session, &inspection));
        CmdyRenderSessionUpdate inspected = next(&t);
        assert(inspected.kind == CMDY_SESSION_INSPECTION && inspected.request_id == 71);
        assert(inspected.environment.now == ready.environment.now);
        assert(inspected.environment.visible == ready.environment.visible);
        assert(inspected.inspection.start_time == ready.inspection.start_time);
        assert(inspected.row_count == 0 && inspected.row_bytes == 0);
        post(&t, CMDY_SESSION_CANCEL_SCROLL, 0, 72);
        CmdyRenderSessionUpdate cancelled = next(&t);
        assert(cancelled.kind == CMDY_SESSION_ACTIONS && cancelled.request_id == 72 && cancelled.actions.flags == 0);
        puts("Session: inspection preserves owner environment; no-motion cancellation emits no draw/timer actions PASS");
        // Hold the owner so mutation definitely precedes command execution.
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        CmdyRenderSessionCommand config = {.kind = CMDY_SESSION_CONFIG, .request_id = 11, .environment = environment(), .config = ready.config};
        config.config.cursor_speed = 17; config.config.has_user_pipeline = true;
        assert(cmdy_render_session_post(t.session, &config)); config.config.cursor_speed = 999;
        dispatch_semaphore_signal(t.unblock);
        CmdyRenderSessionUpdate configured = matching(&t, CMDY_SESSION_ACTIONS, 11);
        assert(configured.config.cursor_speed == 17 && !configured.config.has_user_pipeline);
        post(&t, CMDY_SESSION_PRESET, 3, 12); assert(matching(&t, CMDY_SESSION_ACTIONS, 12).preset == 3);
        CmdyRenderSessionUpdate first = capture(&t); submit(&t, first.identity, (CmdyRenderColor){1, 0, 0, 1});
        assert(matching(&t, CMDY_SESSION_FRAME, 0).success); gpu_done(&t); pixels(&t, 255, 0, 0);
        CmdyRenderSessionUpdate failed = capture(&t);
        CmdyRenderSessionCommand failure = {.kind = CMDY_SESSION_CAPTURE_FAILED, .event = 1,
            .request_id = 13, .identity = failed.identity, .environment = environment()};
        assert(cmdy_render_session_post(t.session, &failure));
        CmdyRenderSessionUpdate error = matching(&t, CMDY_SESSION_ERROR, 13); assert(!error.success && !error.inspection.drawing && error.message[0]);
        CmdyRenderSessionUpdate old = capture(&t);
        uint64_t epoch = cmdy_render_session_invalidate(t.session, environment()); assert(epoch == old.identity.epoch + 1);
        CmdyRenderSessionUpdate fresh = capture(&t); assert(fresh.identity.epoch == epoch && fresh.identity.sequence > old.identity.sequence);
        submit(&t, fresh.identity, (CmdyRenderColor){0, 1, 0, 1}); assert(matching(&t, CMDY_SESSION_FRAME, 0).success);
        gpu_done(&t); pixels(&t, 0, 255, 0);
        assert(cmdy_render_session_shader(t.session, NULL, 0, 14, environment()));
        assert(!matching(&t, CMDY_SESSION_ACTIONS, 14).config.has_user_pipeline);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 97); (void)matching(&t, CMDY_SESSION_ACTIONS, 97);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_RESET_PACING, .environment = environment()};
        unsigned accepted = 0; while (accepted < 2048 && cmdy_render_session_post(t.session, &command)) accepted++;
        assert(accepted > 0 && accepted < 1024);
        uint64_t unchanged = cmdy_render_session_epoch(t.session);
        assert(!cmdy_render_session_invalidate(t.session, environment()) && cmdy_render_session_epoch(t.session) == unchanged);
        cmdy_render_session_close(t.session); cmdy_render_session_close(t.session);
        assert(!cmdy_render_session_post(t.session, &command) && cmdy_render_session_epoch(t.session) == 0);
        dispatch_semaphore_signal(t.unblock); cleanup(&t);
        for (unsigned i = 0; i < 4; i++) { setup(&t, device); cmdy_render_session_close(t.session); cleanup(&t); }
        puts("Session: scoped owner, copied controls, capture/render pixels, capture error recovery, epoch replacement, shader control, bounded queue, reserved close and drain PASS");
#ifdef CMDY_SESSION_INSTRUMENTED
        races(device);
#endif
    }
    return 0;
}
