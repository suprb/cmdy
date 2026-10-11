// Deterministic clock and actual worker/Metal ownership. No NSApplication,
// windows, input, PTY, clipboard or wall-time performance gate.
#include "cmdy_render_session.h"
static void cancelled_pacing_update(void *, const CmdyRenderSessionUpdate *);
#define CMDY_TEST_SESSION_UPDATE cancelled_pacing_update
#define CMDY_MODEL_CONTRACT_NAME predecessor_model_contract
#include "ModelPublishedSession.m"

static atomic_uint_fast64_t clock_nanoseconds;
static atomic_bool forbid_pacing;
static atomic_uint pacing_starts;
static atomic_uint fixture_stage;
static dispatch_semaphore_t pacing_observed;
double fixture_uptime_impl(void);
double cmdy_gpu_apple_uptime(void) {
    uint64_t value = atomic_load(&clock_nanoseconds);
    return value ? (double)value / 1e9 : fixture_uptime_impl();
}
static void cancelled_pacing_update(void *context, const CmdyRenderSessionUpdate *value) {
    (void)context;
    if (value->actions.coalesced_interval > 0) {
        if (atomic_load(&forbid_pacing)) fprintf(stderr,
            "Unexpected pacing at fixture stage %u, time %.6f, revision %llu, request %llu, drawing %u, in-flight %u\n",
            atomic_load(&fixture_stage), value->environment.now, (unsigned long long)value->source_revision,
            (unsigned long long)value->request_id, value->inspection.drawing, value->inspection.frame_in_flight);
        assert(!atomic_load(&forbid_pacing) && "cancelled model attempt consumed a pacing interval");
        atomic_fetch_add(&pacing_starts, 1);
        dispatch_semaphore_signal(pacing_observed);
    }
}
static void reset_at(SessionTest *t, uint64_t nanoseconds) {
    atomic_store(&clock_nanoseconds, nanoseconds);
    post(t, CMDY_SESSION_EVENT, CMDY_RENDER_RESET_PACING, 970);
    (void)matching(t, CMDY_SESSION_ACTIONS, 970);
    // Drain only observation signals already produced by earlier cases.
    while (dispatch_semaphore_wait(pacing_observed, DISPATCH_TIME_NOW) == 0) {}
}
static LayerFixture *start_at(SessionTest *t, id<MTLDevice> device, uint64_t nanoseconds) {
    // Each case owns a fresh session and starts with its clock already frozen.
    // Advancing a reused session between cases can fire a pending presentation
    // recovery, consuming the retry before the deliberately paused model draw.
    atomic_store(&clock_nanoseconds, nanoseconds);
    start_layer(t, device);
    LayerFixture *layer = layer_for(t, device);
    publish_ui(t, capture(t), layer, 1, 0xff0000);
    reset_at(t, nanoseconds);
    return layer;
}

int main(void) {
    assert(NSApp == nil);
    completed = dispatch_semaphore_create(0); continue_completion = dispatch_semaphore_create(0);
    encoded = dispatch_semaphore_create(0); continue_encode = dispatch_semaphore_create(0);
    feedback_registered = dispatch_semaphore_create(0); pacing_observed = dispatch_semaphore_create(0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
        SessionTest t;
        LayerFixture *layer = start_at(&t, device, 100000000000);

        // Freeze scheduler time at a single instant. The obsolete attempt must
        // never submit; its replacement must commit without a pacing deadline.
        atomic_store(&fixture_stage, 1);
        unsigned before = atomic_load(&commits);
        atomic_store(&forbid_pacing, true);
        atomic_store(&pause_encode, true);
        assert(publish_model(&t, 2, 0xff0000, false)); wait_for(encoded);
        assert(publish_model(&t, 3, 0x00ff00, false));
        dispatch_semaphore_signal(continue_encode);
        (void)model_frame(&t); layer_pixels(device, layer->lastTexture, 0, 255, 0);
        assert(atomic_load(&commits) == before + 1);
        atomic_store(&forbid_pacing, false);
        cleanup(&t);
        puts("Cancelled pacing: newer model replaces an encoded obsolete frame at the same clock instant, with one exact-pixel commit PASS");

        // A second cancellation before any successful commit must consume its
        // reservation. Only advancing the injected clock releases that draw.
        layer = start_at(&t, device, 101000000000);
        atomic_store(&fixture_stage, 2);
        before = atomic_load(&commits);
        atomic_store(&forbid_pacing, true);
        atomic_store(&pause_encode, true);
        assert(publish_model(&t, 4, 0xff0000, false)); wait_for(encoded);
        atomic_store(&fixture_stage, 3);
        assert(publish_model(&t, 5, 0x00ff00, false));
        atomic_store(&pause_encode, true);
        atomic_store(&fixture_stage, 4);
        dispatch_semaphore_signal(continue_encode); wait_for(encoded);
        atomic_store(&fixture_stage, 5);
        atomic_store(&forbid_pacing, false);
        unsigned paced_before = atomic_load(&pacing_starts);
        assert(publish_model(&t, 6, 0x0000ff, false));
        dispatch_semaphore_signal(continue_encode); wait_for(pacing_observed);
        assert(atomic_load(&pacing_starts) == paced_before + 1);
        assert(atomic_load(&commits) == before);
        atomic_store(&clock_nanoseconds, 101021000000);
        (void)model_frame(&t); layer_pixels(device, layer->lastTexture, 0, 0, 255);
        assert(atomic_load(&commits) == before + 1);
        cleanup(&t);
        puts("Cancelled pacing: repeated model cancellation retains its interval and commits only the latest pixels after clock advance PASS");

        // UI invalidation is outside the model-only refund. It requires a new
        // host capture after the original reservation, not an immediate retry.
        layer = start_at(&t, device, 102000000000);
        atomic_store(&fixture_stage, 6);
        before = atomic_load(&commits);
        atomic_store(&pause_encode, true);
        assert(publish_model(&t, 7, 0xff0000, false)); wait_for(encoded);
        uint64_t revision = cmdy_render_session_source_changed(t.session, environment());
        post(&t, CMDY_SESSION_BEGIN_DRAW, 0, 0);
        dispatch_semaphore_signal(continue_encode); wait_for(pacing_observed);
        assert(atomic_load(&commits) == before);
        atomic_store(&clock_nanoseconds, 102021000000);
        post(&t, CMDY_SESSION_BEGIN_DRAW, 0, 0);
        CmdyRenderSessionUpdate fresh = matching(&t, CMDY_SESSION_CAPTURE, 0);
        assert(fresh.source_revision == revision);
        publish_ui(&t, fresh, layer, 8, 0x00ff00);
        layer_pixels(device, layer->lastTexture, 0, 255, 0);
        assert(atomic_load(&commits) == before + 1);
        puts("Cancelled pacing: UI revision changes retain pacing and require a fresh host capture before exact pixels commit PASS");

        cleanup(&t);
        assert(NSApp == nil);
        puts("Cancelled pacing: worker ownership, one commit per replacement, cleanup and no application lifecycle PASS");
    }
    return 0;
}
