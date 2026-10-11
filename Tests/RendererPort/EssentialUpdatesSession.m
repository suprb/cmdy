// Headless Metal contract and callback counts. No app, window, input or timing gate.
#include "cmdy_render_session.h"
#include <assert.h>
#include <stdbool.h>
#include <stdlib.h>

static bool essential_updates;
static CmdyRenderSession *delivery_create(const void *device, uint64_t format,
    size_t samples, uint64_t surface, double now, CmdyRenderSessionCallback callback,
    void *context, CmdyRenderWorkerCallback dispose) {
#ifdef CMDY_DELIVERY_BASELINE
    assert(!essential_updates);
    return cmdy_render_session_create(device, format, samples, surface, now, callback, context, dispose);
#else
    return cmdy_render_session_create_with_options(device, format, samples, surface, now,
        essential_updates ? CMDY_SESSION_ESSENTIAL_UPDATES : 0, callback, context, dispose);
#endif
}
#define cmdy_render_session_create delivery_create
#define CMDY_MODEL_CONTRACT_NAME existing_model_contract
#include "ModelPublishedSession.m"
#undef cmdy_render_session_create

typedef struct DeliveryCounts {
    unsigned updates, actions, state_only, frames, completions;
} DeliveryCounts;
static CmdyRenderSessionUpdate observed(SessionTest *t, DeliveryCounts *counts) {
    CmdyRenderSessionUpdate value = next(t);
    counts->updates++;
    if (value.actions.flags & (CMDY_RENDER_START_ANIMATION | CMDY_RENDER_START_COALESCED | CMDY_RENDER_START_RECOVERY | CMDY_RENDER_START_KEYBOARD | CMDY_RENDER_INVALIDATE_VIEW | CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_DRAW_MANUAL)) fprintf(stderr, "unexpected transition: kind=%u flags=%u request=%llu animation=%f visible=%d frame=%d drawing=%d\n", value.kind, value.actions.flags, (unsigned long long)value.request_id, value.inspection.animation_interval, value.environment.visible, value.inspection.frame_in_flight, value.inspection.drawing);
    assert(value.kind != CMDY_SESSION_CAPTURE && value.kind != CMDY_SESSION_ERROR);
    assert(!(value.actions.flags & (CMDY_RENDER_START_ANIMATION | CMDY_RENDER_START_COALESCED |
        CMDY_RENDER_START_RECOVERY | CMDY_RENDER_START_KEYBOARD | CMDY_RENDER_INVALIDATE_VIEW |
        CMDY_RENDER_QUEUE_SERVICE | CMDY_RENDER_DRAW_MANUAL)));
    if (value.kind == CMDY_SESSION_ACTIONS) {
        counts->actions++;
        if (!value.request_id && !value.actions.flags && value.actions.preferred_fps == 0)
            counts->state_only++;
    }
    return value;
}
static void observed_frame(SessionTest *t, DeliveryCounts *counts) {
    bool frame = false, completed = false;
    for (unsigned i = 0; i < 256; i++) {
        CmdyRenderSessionUpdate value = observed(t, counts);
        if (value.kind == CMDY_SESSION_FRAME) {
            assert(!frame && value.success && value.inspection.frame_in_flight);
            frame = true; counts->frames++;
        } else if (frame && value.kind == CMDY_SESSION_ACTIONS && !value.inspection.frame_in_flight) {
            completed = true; counts->completions++; break;
        }
    }
    assert(frame && completed);
}

int main(int argc, char **argv) {
    assert(argc == 2 && (argv[1][0] == '0' || argv[1][0] == '1') && argv[1][1] == 0);
    essential_updates = argv[1][0] == '1';
    // Reuse the actual owner/source/epoch/presentation/disposal contract in both modes.
    assert(predecessor_publication_contract() == 0);
    assert(existing_model_contract() == 0);
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); assert(device);
#ifndef CMDY_DELIVERY_BASELINE
        SessionTest rejected = {0};
        assert(!cmdy_render_session_create_with_options((__bridge const void *)device,
            MTLPixelFormatBGRA8Unorm, 1, 79, environment().now, 1u << 31, update, &rejected, disposed));
        assert(!cmdy_render_session_create_with_options((__bridge const void *)device,
            MTLPixelFormatBGRA8Unorm, 1, 79, environment().now, UINT32_MAX, update, &rejected, disposed));
        assert(atomic_load(&rejected.disposed) == 0 && !rejected.has_owner);
        puts("Essential updates: unknown factory options leave context ownership with the caller PASS");
#endif
        SessionTest t; start_layer(&t, device);
        assert(publish_model(&t, 1, 0xff0000, false));
        CmdyRenderSessionUpdate first = capture(&t);
        LayerFixture *layer = layer_for(&t, device);
        publish_ui(&t, first, layer, 1, 0xff0000);
        DeliveryCounts counts = {0};
        for (unsigned i = 0; i < 16; i++) {
            request_publication_draw(&t);
            observed_frame(&t, &counts);
            layer_pixels(device, layer->lastTexture, 255, 0, 0);
        }
        assert(counts.frames == 16 && counts.completions == 16);
        if (essential_updates) assert(counts.state_only == counts.completions);
        else assert(counts.state_only > counts.completions);
        printf("DELIVERY_COUNTS {\"essential\":%s,\"updates\":%u,\"actions\":%u,\"stateOnly\":%u,\"frames\":%u,\"completions\":%u}\n",
            essential_updates ? "true" : "false", counts.updates, counts.actions,
            counts.state_only, counts.frames, counts.completions);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SELECTION, 1201);
        CmdyRenderSessionUpdate animation = matching(&t, CMDY_SESSION_ACTIONS, 1201);
        assert(animation.inspection.animation_interval > 0);
        assert(animation.actions.flags & CMDY_RENDER_STOP_ANIMATION);
        assert(!(animation.actions.flags & CMDY_RENDER_START_ANIMATION));
        CmdyRenderSessionCommand hidden = {.kind = CMDY_SESSION_EVENT,
            .event = CMDY_RENDER_UPDATE_ANIMATION, .request_id = 1202, .environment = environment()};
        hidden.environment.visible = false;
        assert(cmdy_render_session_post(t.session, &hidden));
        CmdyRenderSessionUpdate stopped = matching(&t, CMDY_SESSION_ACTIONS, 1202);
        assert(!stopped.environment.visible && stopped.inspection.animation_interval == 0);
        assert(stopped.actions.flags & CMDY_RENDER_STOP_ANIMATION);
        post(&t, CMDY_SESSION_CANCEL_SCROLL, 0, 1203);
        CmdyRenderSessionUpdate empty_reply = matching(&t, CMDY_SESSION_ACTIONS, 1203);
        assert(empty_reply.success && empty_reply.actions.flags == 0);
        CmdyRenderSessionUpdate inspected = inspect_layer(&t);
        assert(inspected.row_count > 0 && !inspected.inspection.drawing);
        cleanup(&t);
        assert(atomic_load(&t.disposed) == 1);
        puts("Essential updates: sixteen exact-pixel owner frames, GPU completion, timer STOP, empty explicit reply, inspection and owned teardown PASS");

        // Before publication, the host must still receive an animation START;
        // the first immutable frame then transfers that timer to the owner.
        start_layer(&t, device); first = capture(&t); layer = layer_for(&t, device);
        post(&t, CMDY_SESSION_EVENT, CMDY_RENDER_SELECTION, 1210);
        CmdyRenderSessionUpdate host = matching(&t, CMDY_SESSION_ACTIONS, 1210);
        assert(host.actions.flags & CMDY_RENDER_START_ANIMATION);
        assert(publish_frame(&t, first, layer, NULL, (CmdyRenderColor){0, 1, 0, 1}, 0));
        uint32_t actions = actions_until(&t, CMDY_SESSION_FRAME, 0);
        assert(actions & CMDY_RENDER_STOP_ANIMATION); gpu_done(&t);
        counts = (DeliveryCounts){0}; observed_frame(&t, &counts);
        layer_pixels(device, layer->lastTexture, 0, 255, 0);
        cleanup(&t);
        puts("Essential updates: initial host timer START and ordered owner adoption STOP survive reduced state delivery PASS");
    }
    return 0;
}
