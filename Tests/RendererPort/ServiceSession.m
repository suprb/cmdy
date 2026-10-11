// Headless real Metal tests. No application, window, input, PTY or timing gate.
#include "cmdy_render_session.h"
static void service_fixture_update(void *, const CmdyRenderSessionUpdate *);
#define CMDY_TEST_SESSION_UPDATE service_fixture_update
#define CMDY_PUBLICATION_CONTRACT_NAME existing_publication_contract
#include "PublishedSession.m"

static atomic_bool pause_service_draw;
static atomic_uint owner_pacing_starts;
static dispatch_semaphore_t service_draw_started, service_draw_resume;
static void service_fixture_update(void *context, const CmdyRenderSessionUpdate *value) {
    (void)context;
    if (value->actions.coalesced_interval > 0 && !(value->actions.flags & CMDY_RENDER_START_COALESCED))
        atomic_fetch_add(&owner_pacing_starts, 1);
    if (value->kind == CMDY_SESSION_ACTIONS && value->inspection.drawing &&
        atomic_exchange(&pause_service_draw, false)) {
        dispatch_semaphore_signal(service_draw_started); wait_for(service_draw_resume);
    }
}

static CmdyRenderSessionUpdate service_frame(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = next(t);
        assert(!(value.actions.flags & (CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_DRAW_MANUAL)));
        assert(value.kind != CMDY_SESSION_CAPTURE && value.kind != CMDY_SESSION_ERROR);
        if (value.kind == CMDY_SESSION_FRAME) { assert(value.success); gpu_done(t); return value; }
    }
    assert(false); return (CmdyRenderSessionUpdate){0};
}

static void request_service(SessionTest *t, uint64_t request) {
    post(t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 0);
    post(t, CMDY_SESSION_EVENT, CMDY_RENDER_REQUEST_IMMEDIATE, request);
}

#ifndef CMDY_SERVICE_CONTRACT_NAME
#define CMDY_SERVICE_CONTRACT_NAME main
#endif
int CMDY_SERVICE_CONTRACT_NAME(void) {
    assert(existing_publication_contract() == 0);
    service_draw_started = dispatch_semaphore_create(0);
    service_draw_resume = dispatch_semaphore_create(0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t; start_layer(&t, device);
        CmdyRenderSessionUpdate first = capture(&t);
        LayerFixture *layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        uint64_t sequence = first.identity.sequence;
        for (unsigned i = 0; i < 12; i++) {
            request_service(&t, 810 + i);
            CmdyRenderSessionUpdate frame = service_frame(&t);
            assert(frame.identity.sequence > sequence && frame.source_revision == first.source_revision);
            sequence = frame.identity.sequence;
            layer_pixels(device, layer->lastTexture, 255, 0, 0);
        }
        assert(atomic_load(&layer->acquisitions) == 13);
        cleanup(&t);
        puts("Worker service: 12 ordered real-pixel draws without host service, begin-draw or capture requests PASS");

        // Park the worker before the request. The hide control is already
        // queued when the request creates its deferred owner service ticket.
        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1});
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 98); wait_for(t.blocked);
        (void)matching(&t, CMDY_SESSION_ACTIONS, 98);
        request_service(&t, 830);
        CmdyRenderSessionCommand hidden = {.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_UPDATE_ANIMATION,
            .request_id = 831, .environment = environment()};
        hidden.environment.visible = false; assert(cmdy_render_session_post(t.session, &hidden));
        dispatch_semaphore_signal(t.unblock);
        assert(!(actions_until(&t, CMDY_SESSION_ACTIONS, 830) & CMDY_RENDER_QUEUE_SERVICE));
        (void)matching(&t, CMDY_SESSION_ACTIONS, 831);
        CmdyRenderSessionUpdate after = inspect_layer(&t);
        assert(!after.environment.visible && !after.inspection.service_queued && !after.inspection.drawing);
        assert(atomic_load(&layer->acquisitions) == 1);
        request_service(&t, 832); (void)service_frame(&t);
        layer_pixels(device, layer->lastTexture, 0, 255, 0);
        cleanup(&t);
        puts("Worker service: queued visibility changes cancel old work and a later visible request restores current pixels PASS");

        // The synchronous source fence wins while a service ticket is queued.
        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        request_service(&t, 98); wait_for(t.blocked);
        assert(!(actions_until(&t, CMDY_SESSION_ACTIONS, 98) & CMDY_RENDER_QUEUE_SERVICE));
        uint64_t revision = cmdy_render_session_source_changed(t.session, environment());
        assert(revision == first.source_revision + 1);
        dispatch_semaphore_signal(t.unblock);
        CmdyRenderSessionUpdate fresh = matching(&t, CMDY_SESSION_CAPTURE, 0);
        assert(fresh.source_revision == revision && atomic_load(&layer->acquisitions) == 1);
        publish_initial(&t, fresh, layer, NULL, (CmdyRenderColor){0, 0, 1, 1});
        layer_pixels(device, layer->lastTexture, 0, 0, 255);
        request_service(&t, 833); (void)service_frame(&t); cleanup(&t);
        puts("Worker service: source changes before queued service reject retained content and request the current host capture PASS");

        // Closing while the request callback is parked must cancel its already
        // queued service and release the publication without any new commit.
        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        PublicationObservation observation = publication_observation(first);
        publish_initial(&t, first, layer, &observation, (CmdyRenderColor){1, 0, 0, 1});
        unsigned before = atomic_load(&commits);
        request_service(&t, 98); wait_for(t.blocked);
        assert(!(actions_until(&t, CMDY_SESSION_ACTIONS, 98) & CMDY_RENDER_QUEUE_SERVICE));
        cmdy_render_session_close(t.session); dispatch_semaphore_signal(t.unblock);
        cleanup(&t); wait_for(observation.released);
        assert(atomic_load(&commits) == before && atomic_load(&layer->acquisitions) == 1);
        puts("Worker service: close cancels queued owner service, releases publication and joins without a new GPU commit PASS");

        // A newer request arrives after draw begin, before its frame is queued.
        // Fill the control queue while that frame is inside nextDrawable. The
        // frame cannot reserve a GPU completion, and its newer request cannot
        // reserve an owner service. Its host fallback must survive both limits.
        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        publish_initial(&t, first, layer, NULL, (CmdyRenderColor){1, 0, 0, 1});
        atomic_store(&pause_service_draw, true); atomic_store(&layer->blockNext, true);
        request_publication_draw(&t); wait_for(service_draw_started);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_REQUEST_IMMEDIATE, 834);
        dispatch_semaphore_signal(service_draw_resume); wait_for(layer->entered);
        (void)matching(&t, CMDY_SESSION_ACTIONS, 834);
        CmdyRenderSessionCommand hold = {.kind = CMDY_SESSION_EVENT, .event = CMDY_RENDER_RESET_PACING,
            .request_id = 98, .environment = environment()};
        unsigned accepted = 0;
        while (accepted < 2048 && cmdy_render_session_post(t.session, &hold)) accepted++;
        assert(accepted > 0 && accepted < 1024);
        dispatch_semaphore_signal(layer->resume);
        uint32_t fallback = 0;
        for (unsigned i = 0; i < accepted; i++) {
            wait_for(t.blocked); fallback |= actions_until(&t, CMDY_SESSION_ACTIONS, 98);
            dispatch_semaphore_signal(t.unblock);
        }
        assert(fallback & CMDY_RENDER_QUEUE_SERVICE);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 0);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SERVICE, 835);
        (void)service_frame(&t); layer_pixels(device, layer->lastTexture, 255, 0, 0);
        cleanup(&t);
        puts("Worker service: saturated control queue preserves exactly the host fallback and renders after ordered drain PASS");
    }
    return 0;
}
