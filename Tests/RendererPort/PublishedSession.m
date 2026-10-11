// Actual worker and Metal correctness only; no application/window/input/PTY.
#define CMDY_SESSION_INSTRUMENTED 1
#define CMDY_LAYER_CONTRACT_NAME existing_layer_contract
#include "LayerSession.m"

// Hold one native presentation delivery independently of GPU completion. The
// production relay must recover a current failure and survive a late callback
// after Session has joined, without turning presentation into a join ticket.
typedef struct CapturedFeedback {
    CmdyGpuApplePresented callback;
    void *context;
    CmdyGpuAppleTask dispose;
} CapturedFeedback;
static atomic_bool intercept_feedback;
static CapturedFeedback captured_feedback;
static dispatch_semaphore_t feedback_registered;
void fixture_presented_impl(const void *, CmdyGpuApplePresented, void *, CmdyGpuAppleTask);
void cmdy_gpu_apple_presented(const void *drawable, CmdyGpuApplePresented callback, void *context, CmdyGpuAppleTask dispose) {
    if (atomic_exchange(&intercept_feedback, false)) {
        captured_feedback = (CapturedFeedback){callback, context, dispose};
        dispatch_semaphore_signal(feedback_registered);
    } else fixture_presented_impl(drawable, callback, context, dispose);
}
static void deliver_failed_feedback(void) {
    assert(captured_feedback.callback && captured_feedback.dispose);
    captured_feedback.callback(captured_feedback.context, 0);
    captured_feedback.dispose(captured_feedback.context);
    captured_feedback = (CapturedFeedback){0};
}
static uint32_t actions_until(SessionTest *t, uint32_t kind, uint64_t request) {
    uint32_t flags = 0;
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        flags |= value.actions.flags;
        if (value.kind == kind && value.request_id == request) return flags;
    }
    assert(false); return 0;
}
static uint32_t feedback_barrier(SessionTest *t) {
    post(t, CMDY_SESSION_INSPECT, 0, 704);
    return actions_until(t, CMDY_SESSION_INSPECTION, 704);
}

typedef struct PublicationObservation {
    atomic_uint callbacks, releases;
    dispatch_semaphore_t released;
    uint64_t epoch, first_sequence;
} PublicationObservation;
static PublicationObservation publication_observation(CmdyRenderSessionUpdate requested) {
    return (PublicationObservation){.released = dispatch_semaphore_create(0),
        .epoch = requested.identity.epoch, .first_sequence = requested.identity.sequence};
}
static void publication_presented(void *context, const CmdyRenderLayerPresentation *value) {
    PublicationObservation *o = context;
    assert(value->identity.surface == 79 && value->identity.epoch == o->epoch);
    assert(value->identity.sequence >= o->first_sequence && value->pixel_width == 8 && value->pixel_height == 8);
    atomic_fetch_add(&o->callbacks, 1);
}
static void publication_released(void *context) {
    PublicationObservation *o = context;
    assert(atomic_fetch_add(&o->releases, 1) == 0);
    dispatch_semaphore_signal(o->released);
}
static CmdyRenderOwnedFrameInput *publication_frame(CmdyRenderSessionUpdate requested, CmdyRenderColor color, unsigned dynamic) {
    // Even this visually empty row retains resolved native font/color and a
    // real GPU cache entry. Caller storage/handles die before worker execution.
    NSFont *font = [NSFont fontWithName:@"Menlo" size:8]; assert(font);
    CmdyRenderRowInput text = {.cols = 1, .width = 8, .height = 8, .cell_width = 8,
        .cell_height = 8, .scale = 1, .normal_font = (__bridge const void *)font,
        .foreground = (__bridge const void *)NSColor.whiteColor, .coverage_exponent = 1.35};
    uint32_t status = 99;
    CmdyRenderOwnedRowInput *owned = cmdy_render_input_capture(&text, &status);
    assert(owned && status == CMDY_RENDER_INPUT_OK);
    CmdyRenderFrameRowInput row = {.key = {.absolute_row = 0, .version = 77, .cols = 1,
        .width = 8, .height = 8, .font_name = "Menlo"}, .font_name_bytes = 5, .revision = {77, 7}, .text = owned};
    CmdyRenderFrameInput input = {.identity = requested.identity, .rows = &row, .row_count = 1};
    input.parameters = (CmdyGpuFrame){.width = 8, .height = 8, .scale = 1, .cell_width = 8,
        .cell_height = 8, .grid_rows = 1, .grid_cols = 1, .cursor_hidden = 1,
        .image_scale = 1, .background = color, .now = environment().now,
        .live_resize = dynamic == 1, .scroll_pixels = dynamic == 2 ? 1 : 0};
    CmdyRenderOwnedFrameInput *frame = cmdy_render_frame_input_capture(&input, &status);
    assert(frame && status == CMDY_RENDER_INPUT_OK);
    cmdy_render_input_release(owned);
    input.parameters.background = (CmdyRenderColor){0, 0, 0, 0}; row.key.version = 999;
    return frame;
}
static bool publish_frame(SessionTest *t, CmdyRenderSessionUpdate requested, CAMetalLayer *layer,
                          PublicationObservation *o, CmdyRenderColor color, unsigned dynamic) {
    CmdyRenderOwnedFrameInput *frame = publication_frame(requested, color, dynamic);
    bool accepted = cmdy_render_session_publish_layer(t->session, frame, requested.source_revision,
        (__bridge const void *)layer, 0, environment(), o ? publication_presented : NULL, o,
        o ? publication_released : NULL);
    cmdy_render_frame_input_release(frame);
    return accepted;
}
static void request_publication_draw(SessionTest *t) {
    post(t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 0);
    post(t, CMDY_SESSION_BEGIN_DRAW, 0, 0);
}
static CmdyRenderSessionUpdate worker_frame(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        // A reused draw must never ask the host for source/frame data.
        assert(value.kind != CMDY_SESSION_CAPTURE && value.kind != CMDY_SESSION_ERROR);
        if (value.kind == CMDY_SESSION_FRAME) { assert(value.success); gpu_done(t); return value; }
    }
    assert(false); return (CmdyRenderSessionUpdate){0};
}
static CmdyRenderSessionUpdate native_timer_frame(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        assert(!(value.actions.flags & (CMDY_RENDER_START_COALESCED | CMDY_RENDER_START_RECOVERY |
            CMDY_RENDER_INVALIDATE_VIEW | CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_DRAW_MANUAL)));
        assert(value.kind != CMDY_SESSION_CAPTURE && value.kind != CMDY_SESSION_ERROR);
        if (value.kind == CMDY_SESSION_FRAME) { assert(value.success); gpu_done(t); return value; }
    }
    assert(false); return (CmdyRenderSessionUpdate){0};
}
static void publish_initial(SessionTest *t, CmdyRenderSessionUpdate requested, LayerFixture *layer,
                            PublicationObservation *o, CmdyRenderColor color) {
    assert(publish_frame(t, requested, layer, o, color, 0));
    assert(matching(t, CMDY_SESSION_FRAME, 0).success); gpu_done(t);
}

#ifndef CMDY_PUBLICATION_CONTRACT_NAME
#define CMDY_PUBLICATION_CONTRACT_NAME main
#endif
int CMDY_PUBLICATION_CONTRACT_NAME(void) {
    assert(existing_layer_contract() == 0);
    feedback_registered = dispatch_semaphore_create(0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; start_layer(&t, device);
        CmdyRenderSessionUpdate first = capture(&t); assert(first.source_revision == 1);
        PublicationObservation o = publication_observation(first);
        LayerFixture *layer = layer_for(&t, device);
        publish_initial(&t, first, layer, &o, (CmdyRenderColor){1, 0, 0, 1});
        uint64_t sequence = first.identity.sequence;
        for (unsigned i = 0; i < 12; i++) {
            request_publication_draw(&t);
            CmdyRenderSessionUpdate result = worker_frame(&t);
            assert(result.source_revision == first.source_revision && result.identity.sequence > sequence);
            assert(result.identity.epoch == first.identity.epoch); sequence = result.identity.sequence;
            layer_pixels(device, layer->lastTexture, 255, 0, 0);
        }
        assert(atomic_load(&layer->acquisitions) == 13 && atomic_load(&o.releases) == 0);
        CmdyRenderSessionUpdate cached = inspect_layer(&t); assert(cached.row_count == 1);
        uint64_t revision = cmdy_render_session_source_changed(t.session, environment());
        assert(revision == first.source_revision + 1 && cmdy_render_session_epoch(t.session) == first.identity.epoch);
        CmdyRenderSessionUpdate changed = inspect_layer(&t);
        assert(changed.source_revision == revision && changed.row_count == cached.row_count && changed.row_bytes == cached.row_bytes);
        assert(!publish_frame(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1}, 0));
        CmdyRenderSessionUpdate fresh = capture(&t); assert(fresh.source_revision == revision);
        publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 0, 1, 1});
        request_publication_draw(&t); (void)worker_frame(&t); layer_pixels(device, layer->lastTexture, 0, 0, 255);
        cleanup(&t); wait_for(o.released);
        puts("Publication: 12 worker redraws without host capture, increasing identities, retained row/style and real pixels PASS");
        puts("Publication: source replacement rejects old token, preserves epoch and GPU row residency, then renders current pixels PASS");

        start_layer(&t, device); first = capture(&t); o = publication_observation(first); layer = layer_for(&t, device);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        assert(publish_frame(&t, first, layer, &o, (CmdyRenderColor){1, 0, 0, 1}, 0));
        assert(cmdy_render_session_source_changed(t.session, environment()) == first.source_revision + 1);
        dispatch_semaphore_signal(t.unblock); changed = inspect_layer(&t);
        assert(!changed.inspection.drawing && atomic_load(&layer->acquisitions) == 0);
        cleanup(&t); wait_for(o.released);
        puts("Publication: queued stale publication releases its context without drawable acquisition PASS");

        start_layer(&t, device); first = capture(&t); o = publication_observation(first); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, &o, (CmdyRenderColor){1, 0, 0, 1});
        atomic_store(&layer->blockNext, true); request_publication_draw(&t); wait_for(layer->entered);
        unsigned before = atomic_load(&commits);
        assert(cmdy_render_session_source_changed(t.session, environment()) == first.source_revision + 1);
        assert(cmdy_render_session_epoch(t.session) == first.identity.epoch && atomic_load(&o.releases) == 0);
        dispatch_semaphore_signal(layer->resume); changed = inspect_layer(&t);
        assert(!changed.inspection.drawing && atomic_load(&commits) == before);
        cleanup(&t); wait_for(o.released);
        puts("Publication: source replacement returns during reused drawable acquisition and prevents obsolete commit PASS");

        for (unsigned boundary = 0; boundary < 3; boundary++) {
            start_layer(&t, device); first = capture(&t); o = publication_observation(first); layer = layer_for(&t, device);
            publish_initial(&t, first, layer, &o, (CmdyRenderColor){1, 0, 0, 1});
            before = atomic_load(&commits); atomic_store(&pause_encode, true);
            request_publication_draw(&t); wait_for(encoded);
            if (boundary == 0) assert(cmdy_render_session_source_changed(t.session, environment()) == first.source_revision + 1);
            else if (boundary == 1) assert(cmdy_render_session_invalidate(t.session, environment()) == first.identity.epoch + 1);
            else cmdy_render_session_close(t.session);
            dispatch_semaphore_signal(continue_encode);
            if (boundary != 2) {
                changed = inspect_layer(&t); assert(!changed.inspection.drawing && !changed.inspection.frame_in_flight);
                assert(atomic_load(&commits) == before);
                fresh = capture(&t); publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 1, 0, 1});
                layer_pixels(device, layer->lastTexture, 0, 255, 0);
            }
            cleanup(&t); wait_for(o.released);
            assert(atomic_load(&commits) == before + (boundary == 2 ? 0 : 1));
        }
        puts("Publication: source change, resize and close during encoding cancel final submission and release the GPU slot PASS");

        for (unsigned dynamic = 1; dynamic <= 2; dynamic++) {
            start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
            assert(publish_frame(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1}, dynamic));
            assert(matching(&t, CMDY_SESSION_FRAME, 0).success); gpu_done(&t);
            fresh = capture(&t); assert(fresh.identity.sequence > first.identity.sequence);
            assert(atomic_load(&layer->acquisitions) == 1); cleanup(&t);
        }
        puts("Publication: live resize and translated content request host capture instead of reusing an incomplete row range PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device); o = publication_observation(first);
        CmdyRenderSessionUpdate wrong = first; wrong.source_revision = 0;
        assert(!publish_frame(&t, wrong, layer, &o, (CmdyRenderColor){1, 0, 0, 1}, 0));
        wrong = first; wrong.source_revision++;
        assert(!publish_frame(&t, wrong, layer, &o, (CmdyRenderColor){1, 0, 0, 1}, 0));
        layer.presentsWithTransaction = YES;
        assert(!publish_frame(&t, first, layer, &o, (CmdyRenderColor){1, 0, 0, 1}, 0));
        assert(atomic_load(&o.releases) == 0 && atomic_load(&layer->acquisitions) == 0);
        publication_released(&o); cleanup(&t);
        puts("Publication: zero/future revisions and unsafe layers reject without adopting the caller context PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        (void)matching(&t, CMDY_SESSION_ACTIONS, 98);
        CmdyRenderSessionCommand command = {.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_RESET_PACING,
            .request_id = 98, .environment = environment()};
        unsigned accepted = 0; while (accepted < 2048 && cmdy_render_session_post(t.session, &command)) accepted++;
        assert(accepted > 0 && accepted < 1024);
        revision = cmdy_render_session_source_changed(t.session, environment());
        assert(revision == first.source_revision + 1);
        assert(cmdy_render_session_source_revision(t.session) == revision);
        assert(cmdy_render_session_epoch(t.session) == first.identity.epoch);
        assert(!publish_frame(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1}, 0));
        dispatch_semaphore_signal(t.unblock);
        // Throttle only fixture callbacks so its small observation ring cannot
        // overflow while the full real native control queue drains.
        for (unsigned i = 0; i < accepted; i++) {
            wait_for(t.blocked); changed = matching(&t, CMDY_SESSION_ACTIONS, 98);
            assert(changed.source_revision == revision); dispatch_semaphore_signal(t.unblock);
        }
        changed = inspect_layer(&t); assert(changed.row_count == 1 && !changed.inspection.drawing);
        fresh = capture(&t); assert(fresh.source_revision == revision);
        publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 0, 1, 1});
        layer_pixels(device, layer->lastTexture, 0, 0, 255);
        cmdy_render_session_close(t.session); assert(cmdy_render_session_source_changed(t.session, environment()) == 0);
        cleanup(&t);
        puts("Publication: full control queue still fences source changes, rejects old input, preserves rows and recovers current pixels PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        atomic_store(&intercept_feedback, true);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1}); wait_for(feedback_registered);
        deliver_failed_feedback();
        uint32_t recovery_actions = feedback_barrier(&t);
        assert((recovery_actions & CMDY_RENDER_STOP_RECOVERY) && !(recovery_actions & CMDY_RENDER_START_RECOVERY));
        (void)native_timer_frame(&t);
        layer_pixels(device, layer->lastTexture, 255, 0, 0); cleanup(&t);
        puts("Presentation feedback: current unpresented drawable schedules recovery and redraws retained pixels without host capture PASS");

        for (unsigned boundary = 0; boundary < 3; boundary++) {
            start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
            atomic_store(&intercept_feedback, true);
            publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1}); wait_for(feedback_registered);
            if (boundary == 0) assert(cmdy_render_session_source_changed(t.session, environment()) == first.source_revision + 1);
            else if (boundary == 1) assert(cmdy_render_session_invalidate(t.session, environment()) == first.identity.epoch + 1);
            else cleanup(&t); // Must join while the callback is still withheld.
            deliver_failed_feedback();
            if (boundary != 2) {
                assert(!(feedback_barrier(&t) & (CMDY_RENDER_START_RECOVERY | CMDY_RENDER_STOP_RECOVERY)));
                assert(atomic_load(&layer->acquisitions) == 1); cleanup(&t);
            }
        }
        puts("Presentation feedback: obsolete source/epoch callbacks cannot request recovery; a callback after session destroy is safely detached PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        atomic_store(&intercept_feedback, true);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1}); wait_for(feedback_registered);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        (void)matching(&t, CMDY_SESSION_ACTIONS, 98);
        accepted = 0; while (accepted < 2048 && cmdy_render_session_post(t.session, &command)) accepted++;
        assert(accepted > 0 && accepted < 1024);
        deliver_failed_feedback(); dispatch_semaphore_signal(t.unblock);
        uint32_t feedback_actions = 0;
        for (unsigned i = 0; i < accepted; i++) {
            wait_for(t.blocked); feedback_actions |= actions_until(&t, CMDY_SESSION_ACTIONS, 98);
            dispatch_semaphore_signal(t.unblock);
        }
        assert((feedback_actions & CMDY_RENDER_STOP_RECOVERY) && !(feedback_actions & CMDY_RENDER_START_RECOVERY));
        (void)native_timer_frame(&t);
        layer_pixels(device, layer->lastTexture, 255, 0, 0); cleanup(&t);
        puts("Presentation feedback: a full control queue retains the failure and recovers current pixels when owner work resumes PASS");
    }
    return 0;
}
