// Headless callback, actual Metal and lifetime contracts. No app/window/input or timing gate.
#include "cmdy_render_session.h"
#include "ObservedSessionFactory.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>

static atomic_bool fail_encoder;
void *fixture_encoder_impl(const void *, const void *);
void *cmdy_gpu_apple_encoder(const void *buffer, const void *pass) {
    if (atomic_exchange(&fail_encoder, false)) return NULL;
    return fixture_encoder_impl(buffer, pass);
}

static uint32_t delivery_options;
static atomic_bool count_updates;
static atomic_uint actions_count, state_count, frame_count, failure_count, stopped_timer_count;
static void observe_delivery(void *context, const CmdyRenderSessionUpdate *value) {
    (void)context;
    if (!atomic_load(&count_updates) || value->request_id != 0) return;
    if (value->kind == CMDY_SESSION_ACTIONS) {
        atomic_fetch_add(&actions_count, 1);
        if (!value->actions.flags && !value->actions.preferred_fps) atomic_fetch_add(&state_count, 1);
        const uint32_t stops = CMDY_RENDER_STOP_ANIMATION | CMDY_RENDER_STOP_COALESCED |
            CMDY_RENDER_STOP_KEYBOARD | CMDY_RENDER_STOP_RECOVERY;
        if (value->actions.flags && !(value->actions.flags & ~stops) && !value->actions.preferred_fps)
            atomic_fetch_add(&stopped_timer_count, 1);
    }
    if (value->kind == CMDY_SESSION_FRAME) {
        atomic_fetch_add(&frame_count, 1);
        if (!value->success) atomic_fetch_add(&failure_count, 1);
    }
}
static CmdyRenderSession *host_create(const void *device, uint64_t format, size_t samples,
    uint64_t surface, double now, CmdyRenderSessionCallback callback, void *context,
    CmdyRenderWorkerCallback dispose) {
    return create_observed_session(device, format, samples, surface, now,
        delivery_options, callback, context, dispose);
}
#define cmdy_render_session_create host_create
#define CMDY_TEST_SESSION_UPDATE observe_delivery
#define CMDY_MODEL_CONTRACT_NAME diagnostic_model_contract
#include "ModelPublishedSession.m"
#undef cmdy_render_session_create

static uint64_t inspect_request = 2000;
static CmdyRenderSessionUpdate inspect_current(SessionTest *t) {
    uint64_t id = ++inspect_request;
    post(t, CMDY_SESSION_INSPECT, 0, id);
    return matching(t, CMDY_SESSION_INSPECTION, id);
}
static void wait_retired(SessionTest *t) {
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = inspect_current(t);
        if (!value.inspection.frame_in_flight && !value.inspection.drawing) return;
    }
    assert(false);
}
static CmdyRenderSessionUpdate set_observation(SessionTest *t, bool enabled) {
    uint64_t id = ++inspect_request;
    post(t, CMDY_SESSION_OBSERVE_FRAMES, enabled, id);
    return matching(t, CMDY_SESSION_ACTIONS, id);
}
static void reset_counts(void) {
    atomic_store(&actions_count, 0); atomic_store(&state_count, 0);
    atomic_store(&frame_count, 0); atomic_store(&failure_count, 0);
    atomic_store(&stopped_timer_count, 0);
}
static void start_watched_frame(SessionTest *t) {
    unsigned before = atomic_load(&commits);
    atomic_store(&watch_completion, true);
    request_publication_draw(t);
    wait_for(completed); // Real GPU completion is paused before native retirement.
    assert(atomic_load(&commits) == before + 1);
    assert(inspect_current(t).inspection.frame_in_flight);
}
static void finish_watched_frame(SessionTest *t, LayerFixture *layer, id<MTLDevice> device) {
    dispatch_semaphore_signal(continue_completion);
    wait_retired(t);
    layer_pixels(device, layer->lastTexture, 255, 0, 0);
}
static void unpublished_timer_transitions(id<MTLDevice> device, bool quiet) {
    SessionTest t; start_layer(&t, device);
    set_observation(&t, false);
    reset_counts(); atomic_store(&count_updates, true);
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_CANCEL_KEYBOARD, 0);
    assert(matching(&t, CMDY_SESSION_ACTIONS, 0).actions.flags & CMDY_RENDER_STOP_KEYBOARD);
    inspect_current(&t); // FIFO barrier also completes the callback counter hook.
    assert(atomic_load(&actions_count) == 1);
    for (unsigned i = 0; i < 8; i++) post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_CANCEL_KEYBOARD, 0);
    inspect_current(&t);
    assert(atomic_load(&actions_count) == (quiet ? 1 : 9));

    // Before publication, keyboard feedback still belongs to the host. Every
    // START and the first STOP after it must survive in the non-observed mode.
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_KEYBOARD, 0);
    CmdyRenderSessionUpdate started = matching(&t, CMDY_SESSION_ACTIONS, 0);
    assert(started.actions.flags & CMDY_RENDER_START_KEYBOARD);
    assert(started.actions.keyboard_interval > 0 && started.inspection.has_feedback_deadline);
    inspect_current(&t);
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_CANCEL_KEYBOARD, 0);
    CmdyRenderSessionUpdate stopped = matching(&t, CMDY_SESSION_ACTIONS, 0);
    assert(stopped.actions.flags & CMDY_RENDER_STOP_KEYBOARD);
    assert(!stopped.inspection.has_feedback_deadline);
    inspect_current(&t);
    const unsigned transitions = atomic_load(&actions_count);
    for (unsigned i = 0; i < 8; i++) post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_CANCEL_KEYBOARD, 0);
    inspect_current(&t);
    assert(atomic_load(&actions_count) == transitions + (quiet ? 0 : 8));

    set_observation(&t, true);
    const unsigned before_observed = atomic_load(&actions_count);
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_CANCEL_KEYBOARD, 0);
    inspect_current(&t);
    assert(atomic_load(&actions_count) == before_observed + 1);
    set_observation(&t, false);
    post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_CANCEL_KEYBOARD, 0);
    inspect_current(&t);
    assert(atomic_load(&actions_count) == before_observed + (quiet ? 1 : 2));
    atomic_store(&count_updates, false);
    cleanup(&t);
    puts("Host work: unpublished host timer starts and stops survive while duplicate cancellations and observation transitions remain correct PASS");
}
int main(int argc, char **argv) {
    assert(argc == 2);
    delivery_options = (uint32_t)strtoul(argv[1], NULL, 10);
    assert(delivery_options >= 1 && delivery_options <= 3);
    // Keep the existing rendering/epoch/source/teardown contracts in all modes
    // with observation explicitly enabled where they wait for every frame.
    assert(predecessor_publication_contract() == 0);
    assert(diagnostic_model_contract() == 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        completed = dispatch_semaphore_create(0); continue_completion = dispatch_semaphore_create(0);
        SessionTest t; start_layer(&t, device);
        assert(publish_model(&t, 1, 0xff0000, false));
        CmdyRenderSessionUpdate first = capture(&t);
        LayerFixture *layer = layer_for(&t, device);
        publish_ui(&t, first, layer, 1, 0xff0000);
        assert(!set_observation(&t, false).inspection.frame_in_flight);
        CmdyRenderSessionCommand invalid = {.kind = CMDY_SESSION_OBSERVE_FRAMES, .event = 2};
        assert(!cmdy_render_session_post(t.session, &invalid));
        reset_counts(); atomic_store(&count_updates, true);
        unsigned before = atomic_load(&commits);
        for (unsigned i = 0; i < 16; i++) {
            start_watched_frame(&t);
            finish_watched_frame(&t, layer, device);
        }
        atomic_store(&count_updates, false);
        assert(atomic_load(&commits) == before + 16 && atomic_load(&failure_count) == 0);
        const bool quiet = delivery_options & CMDY_SESSION_HOST_WORK_UPDATES;
        assert(atomic_load(&frame_count) == (quiet ? 0 : 16));
        assert(atomic_load(&state_count) == (quiet ? 0 : 16));
        printf("HOST_WORK_COUNTS {\"options\":%u,\"gpuFrames\":16,\"exactPixels\":16,\"actions\":%u,\"stateOnly\":%u,\"frames\":%u,\"stopOnlyActions\":%u}\n",
            delivery_options, atomic_load(&actions_count), atomic_load(&state_count), atomic_load(&frame_count), atomic_load(&stopped_timer_count));
        puts("Host work: sixteen real GPU completions and exact pixels preserve explicit inspection while quiet frame/state callbacks vanish PASS");

        // Attach while an actual frame is in flight. The ordered reply must
        // expose that state before the corresponding completion is released.
        reset_counts(); atomic_store(&count_updates, true);
        start_watched_frame(&t);
        CmdyRenderSessionUpdate enabled = set_observation(&t, true);
        assert(enabled.inspection.frame_in_flight);
        finish_watched_frame(&t, layer, device);
        assert(atomic_load(&state_count) == 1);
        // Subsequent observed frames have both start and completion delivery.
        unsigned observed_frames = atomic_load(&frame_count);
        for (unsigned i = 0; i < 4; i++) {
            start_watched_frame(&t); finish_watched_frame(&t, layer, device);
        }
        assert(atomic_load(&frame_count) == observed_frames + 4 && atomic_load(&state_count) == 5);
        atomic_store(&count_updates, false);
        assert(!set_observation(&t, false).inspection.frame_in_flight);
        puts("Host work: FIFO observation enable during GPU flight, subsequent frames and disable preserve native state PASS");

        // Missing drawables retry on the owner without an application error.
        // Wait for an actual recovery commit, not an old texture or host state.
        before = atomic_load(&commits);
        unsigned acquired = atomic_load(&layer->acquisitions);
        atomic_store(&watch_completion, true);
        atomic_store(&layer->missingNext, true);
        request_publication_draw(&t);
        wait_for(completed);
        assert(atomic_load(&commits) == before + 1);
        assert(atomic_load(&layer->acquisitions) >= acquired + 2);
        finish_watched_frame(&t, layer, device);
        puts("Host work: missing drawable recovers on the worker with an actual GPU commit and exact pixels PASS");

        // An encoder failure is a real failed FRAME. It must remain visible,
        // followed by healthy recovery even when duplicate success is suppressed.
        before = atomic_load(&commits);
        atomic_store(&watch_completion, true);
        atomic_store(&fail_encoder, true);
        request_publication_draw(&t);
        CmdyRenderSessionUpdate failed = matching(&t, CMDY_SESSION_FRAME, 0);
        assert(!failed.success);
        wait_for(completed);
        CmdyRenderSessionUpdate recovered = matching(&t, CMDY_SESSION_FRAME, 0);
        assert(recovered.success && atomic_load(&commits) == before + 1);
        finish_watched_frame(&t, layer, device);
        puts("Host work: encoder failure and successful recovery still reach the host with exact pixels PASS");

        // Replies and timer ownership transitions remain observable.
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SELECTION, 3101);
        CmdyRenderSessionUpdate timer = matching(&t, CMDY_SESSION_ACTIONS, 3101);
        assert(timer.actions.flags & CMDY_RENDER_STOP_ANIMATION);
        CmdyRenderSessionCommand hidden = {.kind = CMDY_SESSION_EVENT,
            .event = CMDY_RENDER_UPDATE_ANIMATION, .request_id = 3102, .environment = environment()};
        hidden.environment.visible = false; assert(cmdy_render_session_post(t.session, &hidden));
        CmdyRenderSessionUpdate stopped = matching(&t, CMDY_SESSION_ACTIONS, 3102);
        assert(!stopped.environment.visible && stopped.inspection.animation_interval == 0);
        assert(stopped.actions.flags & CMDY_RENDER_STOP_ANIMATION);
        post(&t, CMDY_SESSION_CANCEL_SCROLL, 0, 3103);
        CmdyRenderSessionUpdate reply = matching(&t, CMDY_SESSION_ACTIONS, 3103);
        assert(reply.success);
        cleanup(&t);
        puts("Host work: explicit replies, timer STOP, visibility and owned shutdown remain intact PASS");
        unpublished_timer_transitions(device, quiet);
    }
    return 0;
}
