// Headless Metal correctness. No app, window, input, PTY or performance gate.
#define CMDY_TIMED_CONTRACT_NAME existing_timed_contract
#include "TimedSession.m"
#include <unistd.h>

static CmdyRenderSessionUpdate animation_frame(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        assert(!(value.actions.flags & (CMDY_RENDER_START_ANIMATION | CMDY_RENDER_START_COALESCED |
            CMDY_RENDER_START_RECOVERY | CMDY_RENDER_START_KEYBOARD | CMDY_RENDER_INVALIDATE_VIEW |
            CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_DRAW_MANUAL)));
        assert(value.kind != CMDY_SESSION_CAPTURE && value.kind != CMDY_SESSION_ERROR);
        if (value.kind == CMDY_SESSION_FRAME) {
            assert(value.success);
            gpu_done(t);
            return value;
        }
    }
    assert(false); return (CmdyRenderSessionUpdate){0};
}

static void begin_animation(SessionTest *t, uint64_t request) {
    post(t, CMDY_SESSION_EVENT, CMDY_RENDER_SELECTION, request);
    CmdyRenderSessionUpdate value = matching(t, CMDY_SESSION_ACTIONS, request);
    assert(value.inspection.animation_interval > 0);
    assert(value.actions.flags & CMDY_RENDER_STOP_ANIMATION);
    assert(!(value.actions.flags & CMDY_RENDER_START_ANIMATION));
}

int main(void) {
    assert(existing_timed_contract() == 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; start_layer(&t, device);
        CmdyRenderSessionUpdate first = capture(&t);
        LayerFixture *layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        begin_animation(&t, 1101);
        for (unsigned i = 0; i < 4; i++) {
            (void)animation_frame(&t);
            layer_pixels(device, layer->lastTexture, 255, 0, 0);
        }
        assert(atomic_load(&layer->acquisitions) >= 5);
        cleanup(&t);
        puts("Worker animation: repeated exact-pixel frames without host timer, invalidation, service or capture PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        // The first host timer exists while capture is pending. Publishing the
        // frame must take it over even though its schedule cadence is unchanged.
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SELECTION, 1102);
        CmdyRenderSessionUpdate host = matching(&t, CMDY_SESSION_ACTIONS, 1102);
        assert(host.actions.flags & CMDY_RENDER_START_ANIMATION);
        assert(publish_frame(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1}, 0));
        for (unsigned i = 0; i < 4; i++) {
            (void)animation_frame(&t);
            layer_pixels(device, layer->lastTexture, 0, 255, 0);
        }
        cleanup(&t);
        puts("Worker animation: first publication adopts an already running host animation at unchanged cadence PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1});
        begin_animation(&t, 98); wait_for(t.blocked);
        CmdyRenderSessionCommand obsolete = {.kind = CMDY_SESSION_EVENT,
            .event = CMDY_RENDER_ANIMATION_FIRED, .request_id = 1103, .environment = environment()};
        obsolete.environment.visible = false;
        assert(cmdy_render_session_post(t.session, &obsolete));
        dispatch_semaphore_signal(t.unblock);
        CmdyRenderSessionUpdate ignored = matching(&t, CMDY_SESSION_ACTIONS, 1103);
        assert(ignored.environment.visible && !ignored.actions.flags);
        (void)animation_frame(&t);
        CmdyRenderSessionCommand hidden = {.kind = CMDY_SESSION_EVENT,
            .event = CMDY_RENDER_UPDATE_ANIMATION, .request_id = 1104, .environment = environment()};
        hidden.environment.visible = false;
        assert(cmdy_render_session_post(t.session, &hidden));
        CmdyRenderSessionUpdate stopped = matching(&t, CMDY_SESSION_ACTIONS, 1104);
        assert(!stopped.environment.visible && stopped.inspection.animation_interval == 0);
        assert(stopped.actions.flags & CMDY_RENDER_STOP_ANIMATION);
        obsolete.request_id = 1105; obsolete.environment.visible = true;
        assert(cmdy_render_session_post(t.session, &obsolete));
        ignored = matching(&t, CMDY_SESSION_ACTIONS, 1105);
        assert(!ignored.environment.visible && !ignored.actions.flags);
        CmdyRenderSessionUpdate settled = inspect_layer(&t);
        if (settled.inspection.frame_in_flight) gpu_done(&t);
        unsigned acquisitions = atomic_load(&layer->acquisitions);
        usleep(40000);
        assert(atomic_load(&layer->acquisitions) == acquisitions);
        cleanup(&t);
        puts("Worker animation: stale host ticks cannot restore visibility and hidden windows stop acquiring drawables PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        begin_animation(&t, 98); wait_for(t.blocked);
        uint64_t revision = cmdy_render_session_source_changed(t.session, environment());
        assert(revision == first.source_revision + 1);
        dispatch_semaphore_signal(t.unblock);
        CmdyRenderSessionUpdate fresh = matching(&t, CMDY_SESSION_CAPTURE, 0);
        assert(fresh.source_revision == revision && atomic_load(&layer->acquisitions) == 1);
        publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 0, 1, 1});
        (void)animation_frame(&t); layer_pixels(device, layer->lastTexture, 0, 0, 255);
        cleanup(&t);
        puts("Worker animation: source invalidation requests fresh capture before acquiring or drawing obsolete pixels PASS");

        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        PublicationObservation observation = publication_observation(first);
        publish_initial(&t, first, layer, &observation, (CmdyRenderColor){1, 0, 0, 1});
        unsigned before = atomic_load(&commits);
        begin_animation(&t, 98); wait_for(t.blocked);
        cmdy_render_session_close(t.session); dispatch_semaphore_signal(t.unblock);
        cleanup(&t); wait_for(observation.released);
        assert(atomic_load(&commits) == before && atomic_load(&layer->acquisitions) == 1);
        puts("Worker animation: close cancels the armed repeat and releases its publication without another GPU commit PASS");
    }
    return 0;
}
